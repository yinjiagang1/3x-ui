#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

xui_folder="${XUI_MAIN_FOLDER:=/usr/local/x-ui}"
xui_service="${XUI_SERVICE:=/etc/systemd/system}"

# 请勿编辑此配置
b_source="${BASH_SOURCE[0]}"
while [ -h "$b_source" ]; do
    b_dir="$(cd -P "$(dirname "$b_source")" >/dev/null 2>&1 && pwd || pwd -P)"
    b_source="$(readlink "$b_source")"
    [[ $b_source != /* ]] && b_source="$b_dir/$b_source"
done
cur_dir="$(cd -P "$(dirname "$b_source")" >/dev/null 2>&1 && pwd || pwd -P)"
script_name=$(basename "$0")

# 检查命令是否存在
_command_exists() {
    type "$1" &>/dev/null
}

# 失败报错并退出脚本
_fail() {
    local msg=${1}
    echo -e "${red}${msg}${plain}"
    exit 2
}

# 检查 root 权限
[[ $EUID -ne 0 ]] && _fail "致命错误：请使用 root 权限运行此脚本。"

if _command_exists curl; then
    curl_bin=$(which curl)
else
    _fail "错误：找不到 'curl' 命令。"
fi

# 检查操作系统并设置 release 变量
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
    elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    _fail "无法检查系统操作系统，请联系作者！"
fi
echo "操作系统版本为：$release"

arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64) echo 'amd64' ;;
        i*86 | x86) echo '386' ;;
        armv8* | armv8 | arm64 | aarch64) echo 'arm64' ;;
        armv7* | armv7 | arm) echo 'armv7' ;;
        armv6* | armv6) echo 'armv6' ;;
        armv5* | armv5) echo 'armv5' ;;
        s390x) echo 's390x' ;;
        *) echo -e "${red}不支持的 CPU 架构！${plain}" && rm -f "${cur_dir}/${script_name}" >/dev/null 2>&1 && exit 2;;
    esac
}

echo "架构：$(arch)"

# 简单助手函数
is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0 || return 1
}
is_ipv6() {
    [[ "$1" =~ : ]] && return 0 || return 1
}
is_ip() {
    is_ipv4 "$1" || is_ipv6 "$1"
}
is_domain() {
    [[ "$1" =~ ^([A-Za-z0-9](-*[A-Za-z0-9])*\.)+(xn--[a-z0-9]{2,}|[A-Za-z]{2,})$ ]] && return 0 || return 1
}

# 端口助手函数
is_port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk -v p=":${port}$" '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -lnt 2>/dev/null | awk -v p=":${port} " '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:${port} -sTCP:LISTEN >/dev/null 2>&1 && return 0
    fi
    return 1
}

gen_random_string() {
    local length="$1"
    local random_string=$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w "$length" | head -n 1)
    echo "$random_string"
}

install_base() {
    echo -e "${green}正在更新并安装依赖包...${plain}"
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update >/dev/null 2>&1 && apt-get install -y -q curl tar tzdata socat >/dev/null 2>&1
        ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf -y update >/dev/null 2>&1 && dnf install -y -q curl tar tzdata socat >/dev/null 2>&1
        ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum -y update >/dev/null 2>&1 && yum install -y -q curl tar tzdata socat >/dev/null 2>&1
            else
                dnf -y update >/dev/null 2>&1 && dnf install -y -q curl tar tzdata socat >/dev/null 2>&1
            fi
        ;;
        arch | manjaro | parch)
            pacman -Syu >/dev/null 2>&1 && pacman -Syu --noconfirm curl tar tzdata socat >/dev/null 2>&1
        ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper refresh >/dev/null 2>&1 && zypper -q install -y curl tar timezone socat >/dev/null 2>&1
        ;;
        alpine)
            apk update >/dev/null 2>&1 && apk add curl tar tzdata socat >/dev/null 2>&1
        ;;
        *)
            apt-get update >/dev/null 2>&1 && apt install -y -q curl tar tzdata socat >/dev/null 2>&1
        ;;
    esac
}

install_acme() {
    echo -e "${green}正在安装用于 SSL 证书管理的 acme.sh...${plain}"
    cd ~ || return 1
    curl -s https://get.acme.sh | sh >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${red}安装 acme.sh 失败${plain}"
        return 1
    else
        echo -e "${green}acme.sh 安装成功${plain}"
    fi
    return 0
}

setup_ssl_certificate() {
    local domain="$1"
    local server_ip="$2"
    local existing_port="$3"
    local existing_webBasePath="$4"
    
    echo -e "${green}正在设置 SSL 证书...${plain}"
    
    # 检查 acme.sh 是否已安装
    if ! command -v ~/.acme.sh/acme.sh &>/dev/null; then
        install_acme
        if [ $? -ne 0 ]; then
            echo -e "${yellow}安装 acme.sh 失败，跳过 SSL 设置${plain}"
            return 1
        fi
    fi
    
    # 创建证书目录
    local certPath="/root/cert/${domain}"
    mkdir -p "$certPath"
    
    # 签发证书
    echo -e "${green}正在为 ${domain} 签发 SSL 证书...${plain}"
    echo -e "${yellow}注意：80 端口必须开放且可从互联网访问${plain}"
    
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force >/dev/null 2>&1
    ~/.acme.sh/acme.sh --issue -d ${domain} --listen-v6 --standalone --httpport 80 --force
    
    if [ $? -ne 0 ]; then
        echo -e "${yellow}为 ${domain} 签发证书失败${plain}"
        echo -e "${yellow}请确保 80 端口已开放，稍后尝试运行 x-ui 重新设置${plain}"
        rm -rf ~/.acme.sh/${domain} 2>/dev/null
        rm -rf "$certPath" 2>/dev/null
        return 1
    fi
    
    # 安装证书
    ~/.acme.sh/acme.sh --installcert -d ${domain} \
        --key-file /root/cert/${domain}/privkey.pem \
        --fullchain-file /root/cert/${domain}/fullchain.pem \
        --reloadcmd "systemctl restart x-ui" >/dev/null 2>&1
    
    if [ $? -ne 0 ]; then
        echo -e "${yellow}安装证书失败${plain}"
        return 1
    fi
    
    # 启用自动续期
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1
    chmod 600 $certPath/privkey.pem 2>/dev/null
    chmod 644 $certPath/fullchain.pem 2>/dev/null
    
    # 为面板设置证书
    local webCertFile="/root/cert/${domain}/fullchain.pem"
    local webKeyFile="/root/cert/${domain}/privkey.pem"
    
    if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
        ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile" >/dev/null 2>&1
        echo -e "${green}SSL 证书已成功安装并配置！${plain}"
        return 0
    else
        echo -e "${yellow}找不到证书文件${plain}"
        return 1
    fi
}

# 签发 Let's Encrypt IP 证书（短期模式，有效期约 6 天）
# 需要 acme.sh 并开放 80 端口进行 HTTP-01 验证
setup_ip_certificate() {
    local ipv4="$1"
    local ipv6="$2"  # 可选

    echo -e "${green}正在设置 Let's Encrypt IP 证书（短期模式）...${plain}"
    echo -e "${yellow}注意：IP 证书有效期约为 6 天，并将自动续期。${plain}"
    echo -e "${yellow}默认监听器为 80 端口。如果您选择其他端口，请确保外部 80 端口转发到该端口。${plain}"

    # 检查 acme.sh
    if ! command -v ~/.acme.sh/acme.sh &>/dev/null; then
        install_acme
        if [ $? -ne 0 ]; then
            echo -e "${red}安装 acme.sh 失败${plain}"
            return 1
        fi
    fi

    # 验证 IP 地址
    if [[ -z "$ipv4" ]]; then
        echo -e "${red}需要提供 IPv4 地址${plain}"
        return 1
    fi

    if ! is_ipv4 "$ipv4"; then
        echo -e "${red}无效的 IPv4 地址: $ipv4${plain}"
        return 1
    fi

    # 创建证书目录
    local certDir="/root/cert/ip"
    mkdir -p "$certDir"

    # 构建域名参数
    local domain_args="-d ${ipv4}"
    if [[ -n "$ipv6" ]] && is_ipv6 "$ipv6"; then
        domain_args="${domain_args} -d ${ipv6}"
        echo -e "${green}包含 IPv6 地址: ${ipv6}${plain}"
    fi

    # 设置自动续期的重载命令
    local reloadCmd="systemctl restart x-ui 2>/dev/null || rc-service x-ui restart 2>/dev/null || true"

    # 选择 ACME HTTP-01 监听端口
    local WebPort=""
    read -rp "用于 ACME HTTP-01 验证的端口（默认 80）: " WebPort
    WebPort="${WebPort:-80}"
    if ! [[ "${WebPort}" =~ ^[0-9]+$ ]] || ((WebPort < 1 || WebPort > 65535)); then
        echo -e "${red}提供的端口无效。将回退到 80。${plain}"
        WebPort=80
    fi
    echo -e "${green}使用端口 ${WebPort} 进行独立验证。${plain}"
    if [[ "${WebPort}" -ne 80 ]]; then
        echo -e "${yellow}提醒：Let's Encrypt 仍会连接 80 端口；请将外部 80 端口转发到 ${WebPort}。${plain}"
    fi

    # 确保所选端口可用
    while true; do
        if is_port_in_use "${WebPort}"; then
            echo -e "${yellow}端口 ${WebPort} 目前正被占用。${plain}"

            local alt_port=""
            read -rp "请输入另一个用于 acme.sh 独立验证的端口（留空则中止）: " alt_port
            alt_port="${alt_port// /}"
            if [[ -z "${alt_port}" ]]; then
                echo -e "${red}端口 ${WebPort} 忙；无法继续。${plain}"
                return 1
            fi
            if ! [[ "${alt_port}" =~ ^[0-9]+$ ]] || ((alt_port < 1 || alt_port > 65535)); then
                echo -e "${red}提供的端口无效。${plain}"
                return 1
            fi
            WebPort="${alt_port}"
            continue
        else
            echo -e "${green}端口 ${WebPort} 可用，准备进行独立验证。${plain}"
            break
        fi
    done

    # 签发短期 IP 证书
    echo -e "${green}正在为 ${ipv4} 签发 IP 证书...${plain}"
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force >/dev/null 2>&1
    
    ~/.acme.sh/acme.sh --issue \
        ${domain_args} \
        --standalone \
        --server letsencrypt \
        --certificate-profile shortlived \
        --days 6 \
        --httpport ${WebPort} \
        --force

    if [ $? -ne 0 ]; then
        echo -e "${red}签发 IP 证书失败${plain}"
        echo -e "${yellow}请确保端口 ${WebPort} 可访问（或从外部 80 端口转发）${plain}"
        rm -rf ~/.acme.sh/${ipv4} 2>/dev/null
        [[ -n "$ipv6" ]] && rm -rf ~/.acme.sh/${ipv6} 2>/dev/null
        rm -rf ${certDir} 2>/dev/null
        return 1
    fi

    echo -e "${green}证书签发成功，正在安装...${plain}"

    # 安装证书
    ~/.acme.sh/acme.sh --installcert -d ${ipv4} \
        --key-file "${certDir}/privkey.pem" \
        --fullchain-file "${certDir}/fullchain.pem" \
        --reloadcmd "${reloadCmd}" 2>&1 || true

    # 验证证书文件是否存在
    if [[ ! -f "${certDir}/fullchain.pem" || ! -f "${certDir}/privkey.pem" ]]; then
        echo -e "${red}安装后找不到证书文件${plain}"
        rm -rf ~/.acme.sh/${ipv4} 2>/dev/null
        [[ -n "$ipv6" ]] && rm -rf ~/.acme.sh/${ipv6} 2>/dev/null
        rm -rf ${certDir} 2>/dev/null
        return 1
    fi
    
    echo -e "${green}证书文件安装成功${plain}"

    # 启用自动升级
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1

    chmod 600 ${certDir}/privkey.pem 2>/dev/null
    chmod 644 ${certDir}/fullchain.pem 2>/dev/null

    # 为面板配置证书路径
    echo -e "${green}正在为面板设置证书路径...${plain}"
    ${xui_folder}/x-ui cert -webCert "${certDir}/fullchain.pem" -webCertKey "${certDir}/privkey.pem"
    if [ $? -ne 0 ]; then
        echo -e "${yellow}警告：无法自动设置证书路径。${plain}"
        echo -e "${yellow}您可能需要在面板设置中手动设置它们。${plain}"
        echo -e "${yellow}证书路径: ${certDir}/fullchain.pem${plain}"
        echo -e "${yellow}密钥路径: ${certDir}/privkey.pem${plain}"
    else
        echo -e "${green}证书路径设置成功！${plain}"
    fi

    echo -e "${green}IP 证书已成功安装并配置！${plain}"
    echo -e "${green}证书有效期约为 6 天，通过 acme.sh 定时任务自动续期。${plain}"
    echo -e "${yellow}面板将在每次续期后自动重启。${plain}"
    return 0
}

# 手动 SSL 域名证书签发
ssl_cert_issue() {
    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep 'webBasePath:' | awk -F': ' '{print $2}' | tr -d '[:space:]' | sed 's#^/##')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep 'port:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
    
    # 检查 acme.sh
    if ! command -v ~/.acme.sh/acme.sh &>/dev/null; then
        echo "找不到 acme.sh。正在安装..."
        cd ~ || return 1
        curl -s https://get.acme.sh | sh
        if [ $? -ne 0 ]; then
            echo -e "${red}安装 acme.sh 失败${plain}"
            return 1
        else
            echo -e "${green}acme.sh 安装成功${plain}"
        fi
    fi

    # 获取域名并验证
    local domain=""
    while true; do
        read -rp "请输入您的域名: " domain
        domain="${domain// /}"
        
        if [[ -z "$domain" ]]; then
            echo -e "${red}域名不能为空。请重试。${plain}"
            continue
        fi
        
        if ! is_domain "$domain"; then
            echo -e "${red}域名格式无效: ${domain}。请输入有效的域名。${plain}"
            continue
        fi
        
        break
    done
    echo -e "${green}您的域名是: ${domain}，正在检查...${plain}"

    # 检查是否已存在证书
    local currentCert=$(~/.acme.sh/acme.sh --list | tail -1 | awk '{print $1}')
    if [ "${currentCert}" == "${domain}" ]; then
        local certInfo=$(~/.acme.sh/acme.sh --list)
        echo -e "${red}系统已有该域名的证书。无法重复签发。${plain}"
        echo -e "${yellow}当前证书详情：${plain}"
        echo "$certInfo"
        return 1
    else
        echo -e "${green}您的域名已准备好，现在开始签发证书...${plain}"
    fi

    # 创建证书目录
    certPath="/root/cert/${domain}"
    if [ ! -d "$certPath" ]; then
        mkdir -p "$certPath"
    else
        rm -rf "$certPath"
        mkdir -p "$certPath"
    fi

    # 选择验证端口
    local WebPort=80
    read -rp "请选择使用的端口（默认 80）: " WebPort
    if [[ ${WebPort} -gt 65535 || ${WebPort} -lt 1 ]]; then
        echo -e "${yellow}您输入的 ${WebPort} 无效，将使用默认端口 80。${plain}"
        WebPort=80
    fi
    echo -e "${green}将使用端口: ${WebPort} 签发证书。请确保该端口已开启。${plain}"

    # 临时停止面板
    echo -e "${yellow}正在临时停止面板...${plain}"
    systemctl stop x-ui 2>/dev/null || rc-service x-ui stop 2>/dev/null

    # 签发证书
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force
    ~/.acme.sh/acme.sh --issue -d ${domain} --listen-v6 --standalone --httpport ${WebPort} --force
    if [ $? -ne 0 ]; then
        echo -e "${red}签发证书失败，请检查日志。${plain}"
        rm -rf ~/.acme.sh/${domain}
        systemctl start x-ui 2>/dev/null || rc-service x-ui start 2>/dev/null
        return 1
    else
        echo -e "${green}签发证书成功，正在安装证书...${plain}"
    fi

    # 设置重载命令
    reloadCmd="systemctl restart x-ui || rc-service x-ui restart"
    echo -e "${green}ACME 默认重载命令为: ${yellow}systemctl restart x-ui || rc-service x-ui restart${plain}"
    echo -e "${green}此命令将在每次证书签发和续期时运行。${plain}"
    read -rp "是否修改 ACME 的重载命令 (--reloadcmd)? (y/n): " setReloadcmd
    if [[ "$setReloadcmd" == "y" || "$setReloadcmd" == "Y" ]]; then
        echo -e "\n${green}\t1.${plain} 预设：systemctl reload nginx ; systemctl restart x-ui"
        echo -e "${green}\t2.${plain} 输入自定义命令"
        echo -e "${green}\t0.${plain} 保持默认重载命令"
        read -rp "请选择一个选项: " choice
        case "$choice" in
        1)
            echo -e "${green}重载命令为：systemctl reload nginx ; systemctl restart x-ui${plain}"
            reloadCmd="systemctl reload nginx ; systemctl restart x-ui"
            ;;
        2)
            echo -e "${yellow}建议将 x-ui 重启命令放在最后${plain}"
            read -rp "请输入您的自定义重载命令: " reloadCmd
            echo -e "${green}重载命令为：${reloadCmd}${plain}"
            ;;
        *)
            echo -e "${green}保持默认重载命令${plain}"
            ;;
        esac
    fi

    # 安装证书
    ~/.acme.sh/acme.sh --installcert -d ${domain} \
        --key-file /root/cert/${domain}/privkey.pem \
        --fullchain-file /root/cert/${domain}/fullchain.pem --reloadcmd "${reloadCmd}"

    if [ $? -ne 0 ]; then
        echo -e "${red}安装证书失败，退出。${plain}"
        rm -rf ~/.acme.sh/${domain}
        systemctl start x-ui 2>/dev/null || rc-service x-ui start 2>/dev/null
        return 1
    else
        echo -e "${green}安装证书成功，正在开启自动续期...${plain}"
    fi

    # 启用自动续期
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    if [ $? -ne 0 ]; then
        echo -e "${yellow}自动续期设置出现问题，证书详情：${plain}"
        ls -lah /root/cert/${domain}/
        chmod 600 $certPath/privkey.pem
        chmod 644 $certPath/fullchain.pem
    else
        echo -e "${green}自动续期设置成功，证书详情：${plain}"
        ls -lah /root/cert/${domain}/
        chmod 600 $certPath/privkey.pem
        chmod 644 $certPath/fullchain.pem
    fi

    # 重启面板
    systemctl start x-ui 2>/dev/null || rc-service x-ui start 2>/dev/null

    # 提示设置面板路径
    read -rp "是否为面板设置此证书? (y/n): " setPanel
    if [[ "$setPanel" == "y" || "$setPanel" == "Y" ]]; then
        local webCertFile="/root/cert/${domain}/fullchain.pem"
        local webKeyFile="/root/cert/${domain}/privkey.pem"

        if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
            ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
            echo -e "${green}已为面板设置证书路径${plain}"
            echo -e "${green}证书文件: $webCertFile${plain}"
            echo -e "${green}私钥文件: $webKeyFile${plain}"
            echo ""
            echo -e "${green}访问地址: https://${domain}:${existing_port}/${existing_webBasePath}${plain}"
            echo -e "${yellow}面板将重启以应用 SSL 证书...${plain}"
            systemctl restart x-ui 2>/dev/null || rc-service x-ui restart 2>/dev/null
        else
            echo -e "${red}错误：找不到域名的证书或私钥文件：$domain。${plain}"
        fi
    else
        echo -e "${yellow}跳过面板路径设置。${plain}"
    fi
    
    return 0
}

# 统一交互式 SSL 设置
prompt_and_setup_ssl() {
    local panel_port="$1"
    local web_base_path="$2"
    local server_ip="$3"

    local ssl_choice=""

    echo -e "${yellow}请选择 SSL 证书设置方式：${plain}"
    echo -e "${green}1.${plain} Let's Encrypt 域名证书 (90 天有效期，自动续期)"
    echo -e "${green}2.${plain} Let's Encrypt IP 证书 (6 天有效期，自动续期)"
    echo -e "${green}3.${plain} 自定义 SSL 证书 (提供现有文件路径)"
    echo -e "${blue}注意：${plain} 选项 1 和 2 需要开启 80 端口。选项 3 需要手动输入路径。"
    read -rp "请选择一个选项 (默认 2 为 IP): " ssl_choice
    ssl_choice="${ssl_choice// /}"
    
    if [[ "$ssl_choice" != "1" && "$ssl_choice" != "3" ]]; then
        ssl_choice="2"
    fi

    case "$ssl_choice" in
    1)
        echo -e "${green}正在使用 Let's Encrypt 为域名申请证书...${plain}"
        ssl_cert_issue
        local cert_domain=$(~/.acme.sh/acme.sh --list 2>/dev/null | tail -1 | awk '{print $1}')
        if [[ -n "${cert_domain}" ]]; then
            SSL_HOST="${cert_domain}"
            echo -e "${green}✓ SSL 证书配置成功，域名：${cert_domain}${plain}"
        else
            echo -e "${yellow}SSL 设置可能已完成，但域名提取失败${plain}"
            SSL_HOST="${server_ip}"
        fi
        ;;
    2)
        echo -e "${green}正在使用 Let's Encrypt 为 IP 申请证书（短期模式）...${plain}"
        
        local ipv6_addr=""
        read -rp "是否有 IPv6 地址需要包含？(留空则跳过): " ipv6_addr
        ipv6_addr="${ipv6_addr// /}"
        
        if [[ $release == "alpine" ]]; then
            rc-service x-ui stop >/dev/null 2>&1
        else
            systemctl stop x-ui >/dev/null 2>&1
        fi
        
        setup_ip_certificate "${server_ip}" "${ipv6_addr}"
        if [ $? -eq 0 ]; then
            SSL_HOST="${server_ip}"
            echo -e "${green}✓ Let's Encrypt IP 证书配置成功${plain}"
        else
            echo -e "${red}✗ IP 证书设置失败。请检查 80 端口是否已开启。${plain}"
            SSL_HOST="${server_ip}"
        fi
        
        if [[ $release == "alpine" ]]; then
            rc-service x-ui restart >/dev/null 2>&1
        else
            systemctl restart x-ui >/dev/null 2>&1
        fi
        ;;
    3)
        echo -e "${green}使用现有的自定义证书...${plain}"
        local custom_cert=""
        local custom_key=""
        local custom_domain=""

        read -rp "请输入证书签发的域名: " custom_domain
        custom_domain="${custom_domain// /}"

        while true; do
            read -rp "请输入证书路径 (关键词: .crt / fullchain): " custom_cert
            custom_cert=$(echo "$custom_cert" | tr -d '"' | tr -d "'")

            if [[ -f "$custom_cert" && -r "$custom_cert" && -s "$custom_cert" ]]; then
                break
            elif [[ ! -f "$custom_cert" ]]; then
                echo -e "${red}错误：文件不存在！请重试。${plain}"
            elif [[ ! -r "$custom_cert" ]]; then
                echo -e "${red}错误：文件存在但不可读（检查权限）！${plain}"
            else
                echo -e "${red}错误：文件为空！${plain}"
            fi
        done

        while true; do
            read -rp "请输入私钥路径 (关键词: .key / privatekey): " custom_key
            custom_key=$(echo "$custom_key" | tr -d '"' | tr -d "'")

            if [[ -f "$custom_key" && -r "$custom_key" && -s "$custom_key" ]]; then
                break
            elif [[ ! -f "$custom_key" ]]; then
                echo -e "${red}错误：文件不存在！请重试。${plain}"
            elif [[ ! -r "$custom_key" ]]; then
                echo -e "${red}错误：文件存在但不可读（检查权限）！${plain}"
            else
                echo -e "${red}错误：文件为空！${plain}"
            fi
        done

        ${xui_folder}/x-ui cert -webCert "$custom_cert" -webCertKey "$custom_key" >/dev/null 2>&1

        if [[ -n "$custom_domain" ]]; then
            SSL_HOST="$custom_domain"
        else
            SSL_HOST="${server_ip}"
        fi

        echo -e "${green}✓ 自定义证书路径已应用。${plain}"
        echo -e "${yellow}注意：您需要自行负责这些外部文件的续期。${plain}"

        systemctl restart x-ui >/dev/null 2>&1 || rc-service x-ui restart >/dev/null 2>&1
        ;;
    *)
        echo -e "${red}选项无效。跳过 SSL 设置。${plain}"
        SSL_HOST="${server_ip}"
        ;;
    esac
}

config_after_update() {
    echo -e "${yellow}x-ui 设置：${plain}"
    ${xui_folder}/x-ui setting -show true
    ${xui_folder}/x-ui migrate
    
    local existing_cert=$(${xui_folder}/x-ui setting -getCert true 2>/dev/null | grep 'cert:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk $2)
    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk $2 | sed 's#^/##')
    
    local URL_lists=(
        "https://api4.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://v4.api.ipinfo.io/ip"
        "https://ipv4.myexternalip.com/raw"
        "https://4.ident.me"
        "https://check-host.net/ip"
    )
    local server_ip=""
    for ip_address in "${URL_lists[@]}"; do
        local response=$(curl -s -w "\n%{http_code}" --max-time 3 "${ip_address}" 2>/dev/null)
        local http_code=$(echo "$response" | tail -n1)
        local ip_result=$(echo "$response" | head -n-1 | tr -d '[:space:]')
        if [[ "${http_code}" == "200" && -n "${ip_result}" ]]; then
            server_ip="${ip_result}"
            break
        fi
    done
    
    if [[ ${#existing_webBasePath} -lt 4 ]]; then
        echo -e "${yellow}根路径 (WebBasePath) 缺失或太短。正在生成新路径...${plain}"
        local config_webBasePath=$(gen_random_string 18)
        ${xui_folder}/x-ui setting -webBasePath "${config_webBasePath}"
        existing_webBasePath="${config_webBasePath}"
        echo -e "${green}新根路径: ${config_webBasePath}${plain}"
    fi
    
    if [[ -z "$existing_cert" ]]; then
        echo ""
        echo -e "${red}═══════════════════════════════════════════${plain}"
        echo -e "${red}      ⚠ 未检测到 SSL 证书 ⚠               ${plain}"
        echo -e "${red}═══════════════════════════════════════════${plain}"
        echo -e "${yellow}为了安全，所有面板都必须配置 SSL 证书。${plain}"
        echo -e "${yellow}Let's Encrypt 现在同时支持域名和 IP 地址！${plain}"
        echo ""
        
        if [[ -z "${server_ip}" ]]; then
            echo -e "${red}检测服务器 IP 失败${plain}"
            echo -e "${yellow}请手动配置 SSL，使用命令：x-ui${plain}"
            return
        fi
        
        prompt_and_setup_ssl "${existing_port}" "${existing_webBasePath}" "${server_ip}"
        
        echo ""
        echo -e "${green}═══════════════════════════════════════════${plain}"
        echo -e "${green}      面板访问信息                         ${plain}"
        echo -e "${green}═══════════════════════════════════════════${plain}"
        echo -e "${green}访问地址: https://${SSL_HOST}:${existing_port}/${existing_webBasePath}${plain}"
        echo -e "${green}═══════════════════════════════════════════${plain}"
        echo -e "${yellow}⚠ SSL 证书：已启用并配置${plain}"
    else
        echo -e "${green}SSL 证书已配置。${plain}"
        local cert_domain=$(basename "$(dirname "$existing_cert")")
        echo ""
        echo -e "${green}═══════════════════════════════════════════${plain}"
        echo -e "${green}      面板访问信息                         ${plain}"
        echo -e "${green}═══════════════════════════════════════════${plain}"
        echo -e "${green}访问地址: https://${cert_domain}:${existing_port}/${existing_webBasePath}${plain}"
        echo -e "${green}═══════════════════════════════════════════${plain}"
    fi
}

update_x-ui() {
    cd ${xui_folder%/x-ui}/
    
    if [ -f "${xui_folder}/x-ui" ]; then
        current_xui_version=$(${xui_folder}/x-ui -v)
        echo -e "${green}当前 x-ui 版本：${current_xui_version}${plain}"
    else
        _fail "错误：当前 x-ui 版本未知"
    fi
    
    echo -e "${green}正在下载新版 x-ui...${plain}"
    
    tag_version=$(${curl_bin} -Ls "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ ! -n "$tag_version" ]]; then
        echo -e "${yellow}尝试通过 IPv4 获取版本...${plain}"
        tag_version=$(${curl_bin} -4 -Ls "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ ! -n "$tag_version" ]]; then
            _fail "错误：获取 x-ui 版本失败，可能是由于 GitHub API 限制，请稍后再试"
        fi
    fi
    echo -e "获取到 x-ui 最新版本：${tag_version}，开始安装..."
    ${curl_bin} -fLRo ${xui_folder}-linux-$(arch).tar.gz https://github.com/MHSanaei/3x-ui/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz 2>/dev/null
    if [[ $? -ne 0 ]]; then
        echo -e "${yellow}尝试通过 IPv4 获取版本...${plain}"
        ${curl_bin} -4fLRo ${xui_folder}-linux-$(arch).tar.gz https://github.com/MHSanaei/3x-ui/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz 2>/dev/null
        if [[ $? -ne 0 ]]; then
            _fail "错误：下载 x-ui 失败，请确保您的服务器可以访问 GitHub"
        fi
    fi
    
    if [[ -e ${xui_folder}/ ]]; then
        echo -e "${green}正在停止 x-ui...${plain}"
        if [[ $release == "alpine" ]]; then
            if [ -f "/etc/init.d/x-ui" ]; then
                rc-service x-ui stop >/dev/null 2>&1
                rc-update del x-ui >/dev/null 2>&1
                echo -e "${green}正在删除旧的服务单元版本...${plain}"
                rm -f /etc/init.d/x-ui >/dev/null 2>&1
            else
                rm x-ui-linux-$(arch).tar.gz -f >/dev/null 2>&1
                _fail "错误：未安装 x-ui 服务单元。"
            fi
        else
            if [ -f "${xui_service}/x-ui.service" ]; then
                systemctl stop x-ui >/dev/null 2>&1
                systemctl disable x-ui >/dev/null 2>&1
                echo -e "${green}正在删除旧的 systemd 单元版本...${plain}"
                rm ${xui_service}/x-ui.service -f >/dev/null 2>&1
                systemctl daemon-reload >/dev/null 2>&1
            else
                rm x-ui-linux-$(arch).tar.gz -f >/dev/null 2>&1
                _fail "错误：未安装 x-ui systemd 单元。"
            fi
        fi
        echo -e "${green}正在删除旧版 x-ui...${plain}"
        rm ${xui_folder} -f >/dev/null 2>&1
        rm ${xui_folder}/x-ui.service -f >/dev/null 2>&1
        rm ${xui_folder}/x-ui.service.debian -f >/dev/null 2>&1
        rm ${xui_folder}/x-ui.service.arch -f >/dev/null 2>&1
        rm ${xui_folder}/x-ui.service.rhel -f >/dev/null 2>&1
        rm ${xui_folder}/x-ui -f >/dev/null 2>&1
        rm ${xui_folder}/x-ui.sh -f >/dev/null 2>&1
        echo -e "${green}正在删除旧版 xray...${plain}"
        rm ${xui_folder}/bin/xray-linux-amd64 -f >/dev/null 2>&1
        echo -e "${green}正在删除旧的 README 和 LICENSE 文件...${plain}"
        rm ${xui_folder}/bin/README.md -f >/dev/null 2>&1
        rm ${xui_folder}/bin/LICENSE -f >/dev/null 2>&1
    else
        rm x-ui-linux-$(arch).tar.gz -f >/dev/null 2>&1
        _fail "错误：x-ui 未安装。"
    fi
    
    echo -e "${green}正在安装新版 x-ui...${plain}"
    tar zxvf x-ui-linux-$(arch).tar.gz >/dev/null 2>&1
    rm x-ui-linux-$(arch).tar.gz -f >/dev/null 2>&1
    cd x-ui >/dev/null 2>&1
    chmod +x x-ui >/dev/null 2>&1
    
    if [[ $(arch) == "armv5" || $(arch) == "armv6" || $(arch) == "armv7" ]]; then
        mv bin/xray-linux-$(arch) bin/xray-linux-arm >/dev/null 2>&1
        chmod +x bin/xray-linux-arm >/dev/null 2>&1
    fi
    
    chmod +x x-ui bin/xray-linux-$(arch) >/dev/null 2>&1
    
    echo -e "${green}正在下载并安装 x-ui.sh 脚本...${plain}"
    ${curl_bin} -fLRo /usr/bin/x-ui https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.sh >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        echo -e "${yellow}尝试通过 IPv4 获取 x-ui...${plain}"
        ${curl_bin} -4fLRo /usr/bin/x-ui https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.sh >/dev/null 2>&1
        if [[ $? -ne 0 ]]; then
            _fail "错误：下载 x-ui.sh 脚本失败，请确保您的服务器可以访问 GitHub"
        fi
    fi
    
    chmod +x ${xui_folder}/x-ui.sh >/dev/null 2>&1
    chmod +x /usr/bin/x-ui >/dev/null 2>&1
    mkdir -p /var/log/x-ui >/dev/null 2>&1
    
    echo -e "${green}正在更改所有者...${plain}"
    chown -R root:root ${xui_folder} >/dev/null 2>&1
    
    if [ -f "${xui_folder}/bin/config.json" ]; then
        echo -e "${green}正在更改配置文件权限...${plain}"
        chmod 640 ${xui_folder}/bin/config.json >/dev/null 2>&1
    fi
    
    if [[ $release == "alpine" ]]; then
        echo -e "${green}正在下载并安装启动单元 x-ui.rc...${plain}"
        ${curl_bin} -fLRo /etc/init.d/x-ui https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.rc >/dev/null 2>&1
        if [[ $? -ne 0 ]]; then
            ${curl_bin} -4fLRo /etc/init.d/x-ui https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.rc >/dev/null 2>&1
            if [[ $? -ne 0 ]]; then
                _fail "错误：下载启动单元 x-ui.rc 失败，请确保您的服务器可以访问 GitHub"
            fi
        fi
        chmod +x /etc/init.d/x-ui >/dev/null 2>&1
        chown root:root /etc/init.d/x-ui >/dev/null 2>&1
        rc-update add x-ui >/dev/null 2>&1
        rc-service x-ui start >/dev/null 2>&1
    else
        if [ -f "x-ui.service" ]; then
            echo -e "${green}正在安装 systemd 单元...${plain}"
            cp -f x-ui.service ${xui_service}/ >/dev/null 2>&1
            if [[ $? -ne 0 ]]; then
                echo -e "${red}复制 x-ui.service 失败${plain}"
                exit 1
            fi
        else
            service_installed=false
            case "${release}" in
                ubuntu | debian | armbian)
                    if [ -f "x-ui.service.debian" ]; then
                        echo -e "${green}正在安装 Debian 系 systemd 单元...${plain}"
                        cp -f x-ui.service.debian ${xui_service}/x-ui.service >/dev/null 2>&1
                        if [[ $? -eq 0 ]]; then
                            service_installed=true
                        fi
                    fi
                ;;
                arch | manjaro | parch)
                    if [ -f "x-ui.service.arch" ]; then
                        echo -e "${green}正在安装 Arch 系 systemd 单元...${plain}"
                        cp -f x-ui.service.arch ${xui_service}/x-ui.service >/dev/null 2>&1
                        if [[ $? -eq 0 ]]; then
                            service_installed=true
                        fi
                    fi
                ;;
                *)
                    if [ -f "x-ui.service.rhel" ]; then
                        echo -e "${green}正在安装 RHEL 系 systemd 单元...${plain}"
                        cp -f x-ui.service.rhel ${xui_service}/x-ui.service >/dev/null 2>&1
                        if [[ $? -eq 0 ]]; then
                            service_installed=true
                        fi
                    fi
                ;;
            esac
            
            if [ "$service_installed" = false ]; then
                echo -e "${yellow}tar.gz 中未找到服务文件，正在从 GitHub 下载...${plain}"
                case "${release}" in
                    ubuntu | debian | armbian)
                        ${curl_bin} -4fLRo ${xui_service}/x-ui.service https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.service.debian >/dev/null 2>&1
                    ;;
                    arch | manjaro | parch)
                        ${curl_bin} -4fLRo ${xui_service}/x-ui.service https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.service.arch >/dev/null 2>&1
                    ;;
                    *)
                        ${curl_bin} -4fLRo ${xui_service}/x-ui.service https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.service.rhel >/dev/null 2>&1
                    ;;
                esac
                
                if [[ $? -ne 0 ]]; then
                    echo -e "${red}从 GitHub 安装 x-ui.service 失败${plain}"
                    exit 1
                fi
            fi
        fi
        chown root:root ${xui_service}/x-ui.service >/dev/null 2>&1
        chmod 644 ${xui_service}/x-ui.service >/dev/null 2>&1
        systemctl daemon-reload >/dev/null 2>&1
        systemctl enable x-ui >/dev/null 2>&1
        systemctl start x-ui >/dev/null 2>&1
    fi
    
    config_after_update
    
    echo -e "${green}x-ui ${tag_version}${plain} 更新完成，正在运行..."
    echo -e ""
    echo -e "┌───────────────────────────────────────────────────────┐
│  ${blue}x-ui 控制菜单用法 (子命令)：${plain}                          │
│                                                       │
│  ${blue}x-ui${plain}              - 管理脚本菜单                     │
│  ${blue}x-ui start${plain}        - 启动                             │
│  ${blue}x-ui stop${plain}         - 停止                             │
│  ${blue}x-ui restart${plain}      - 重启                             │
│  ${blue}x-ui status${plain}       - 当前状态                         │
│  ${blue}x-ui settings${plain}     - 当前设置                         │
│  ${blue}x-ui enable${plain}       - 开启开机自启                     │
│  ${blue}x-ui disable${plain}      - 关闭开机自启                     │
│  ${blue}x-ui log${plain}          - 查看日志                         │
│  ${blue}x-ui banlog${plain}       - 查看 Fail2ban 封禁日志           │
│  ${blue}x-ui update${plain}       - 更新                             │
│  ${blue}x-ui legacy${plain}       - 遗留版本                         │
│  ${blue}x-ui install${plain}      - 安装                             │
│  ${blue}x-ui uninstall${plain}    - 卸载                             │
└───────────────────────────────────────────────────────┘"
}

echo -e "${green}运行中...${plain}"
install_base
update_x-ui $1
