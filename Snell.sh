#!/bin/bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

# --- 默认设置 ---
DEFAULT_VERSION="v5.0.1"
CONF="/etc/snell/snell-server.conf"
SYSTEMD="/etc/systemd/system/snell.service"
BIN_PATH="/usr/local/bin/snell-server"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# --- 基础检查 ---
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}错误: 请以 root 权限运行此脚本。${PLAIN}"
        exit 1
    fi
}

get_arch() {
    local arch=$(arch)
    case $arch in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "aarch64" ;;
        *) echo "unknown" ;;
    esac
}

install_dependencies() {
    local sys_type="unknown"
    [ -f /etc/debian_version ] && sys_type="debian"
    [ -f /etc/redhat-release ] && sys_type="centos"

    if [ "$sys_type" == "debian" ]; then
        apt-get update -y
        apt-get install -y wget unzip curl
    elif [ "$sys_type" == "centos" ]; then
        yum install -y wget unzip curl
    else
        echo -e "${RED}不支持的系统类型${PLAIN}"
        exit 1
    fi
}

# --- 核心功能 ---

ask_version() {
    echo -e "----------------------------------------"
    echo -e "请选择安装版本"
    read -p "输入版本号 [默认 ${DEFAULT_VERSION}]: " INPUT_VERSION
    if [ -z "${INPUT_VERSION}" ]; then
        VERSION="${DEFAULT_VERSION}"
    else
        VERSION="${INPUT_VERSION}"
    fi
    echo -e "准备安装版本: ${GREEN}${VERSION}${PLAIN}"
}

install_snell() {
    install_dependencies
    
    ARCH=$(get_arch)
    if [ "$ARCH" == "unknown" ]; then
        echo -e "${RED}不支持的架构: $(arch)${PLAIN}"
        exit 1
    fi

    # 1. 询问版本
    ask_version

    # 2. 下载
    rm -f snell-server.zip
    DOWNLOAD_URL="https://dl.nssurge.com/snell/snell-server-${VERSION}-linux-${ARCH}.zip"
    
    echo -e "正在下载: ${DOWNLOAD_URL}"
    wget --no-check-certificate -O snell-server.zip "${DOWNLOAD_URL}"

    if [ $? -ne 0 ]; then
        echo -e "${RED}下载失败！请检查版本号是否存在，或网络连接。${PLAIN}"
        rm -f snell-server.zip
        exit 1
    fi

    # 3. 安装
    unzip -o snell-server.zip
    rm -f snell-server.zip
    chmod +x snell-server
    mv -f snell-server ${BIN_PATH}

    # 4. 配置生成 (仅当配置不存在时触发交互)
    if [ ! -f ${CONF} ]; then
        mkdir -p /etc/snell
        
        # --- 定制 1: 端口选择 ---
        echo -e "----------------------------------------"
        read -p "请输入端口号 (1-65535) [留空则随机]: " USER_PORT
        if [[ -z "${USER_PORT}" ]]; then
            PORT=$(shuf -i 10000-65000 -n 1)
            echo -e "已选择随机端口: ${GREEN}${PORT}${PLAIN}"
        else
            PORT=${USER_PORT}
            echo -e "已选择指定端口: ${GREEN}${PORT}${PLAIN}"
        fi

        # --- 定制 2: IPv6 选择 ---
        echo -e "----------------------------------------"
        read -p "是否开启 IPv6? (y/n) [默认 y]: " USER_IPV6
        if [[ "${USER_IPV6}" == "n" || "${USER_IPV6}" == "N" ]]; then
            IPV6_VAL="false"
            LISTEN_ADDR="0.0.0.0"  # 关闭IPv6时仅监听IPv4
            echo -e "IPv6 开关: ${YELLOW}关闭${PLAIN}"
        else
            IPV6_VAL="true"
            LISTEN_ADDR="::0"      # 开启IPv6时监听双栈
            echo -e "IPv6 开关: ${GREEN}开启${PLAIN}"
        fi

        PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
        
        # 写入配置文件
        cat > ${CONF} <<-EOF
[snell-server]
listen = ${LISTEN_ADDR}:${PORT}
psk = ${PSK}
ipv6 = ${IPV6_VAL}
obfs = http
EOF
        echo -e "${GREEN}配置文件已生成。${PLAIN}"
    else
        echo -e "${YELLOW}检测到现有配置，跳过配置生成（保留旧配置）。${PLAIN}"
    fi

    # 5. Systemd 服务
    cat > ${SYSTEMD} <<-EOF
[Unit]
Description=Snell Proxy Service
After=network.target

[Service]
Type=simple
User=root
Group=root
LimitNOFILE=32768
ExecStart=${BIN_PATH} -c ${CONF}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable snell
    systemctl restart snell

    echo -e "${GREEN}Snell 安装并启动成功！${PLAIN}"
    show_config
}

update_snell() {
    if [ ! -f "${BIN_PATH}" ]; then
        echo -e "${RED}Snell 未安装，请先执行安装。${PLAIN}"
        return
    fi
    echo -e "${GREEN}=== 更新 Snell ===${PLAIN}"
    install_snell
}

uninstall_snell() {
    echo -e "${YELLOW}正在卸载 Snell...${PLAIN}"
    systemctl stop snell
    systemctl disable snell
    rm -f ${SYSTEMD}
    systemctl daemon-reload
    rm -f ${BIN_PATH}
    rm -rf /etc/snell
    echo -e "${GREEN}卸载完成。${PLAIN}"
}

show_config() {
    if [ ! -f "${CONF}" ]; then
        echo -e "${RED}配置文件不存在。${PLAIN}"
        return
    fi

    # 智能读取端口 (兼容 ::0:端口 和 0.0.0.0:端口 两种格式)
    PORT_LINE=$(grep 'listen' ${CONF})
    PORT=$(echo "$PORT_LINE" | awk -F':' '{print $NF}' | tr -d ' ')
    
    PSK=$(grep 'psk' ${CONF} | cut -d'=' -f2 | tr -d ' ')
    IPV6_STATUS=$(grep 'ipv6' ${CONF} | cut -d'=' -f2 | tr -d ' ')
    
    PUBLIC_IP=$(curl -s4m8 ip.sb || curl -s4m8 ifconfig.me)

    # 获取版本号
    CURRENT_VER_STR=$(${BIN_PATH} -v 2>&1)
    if [[ $CURRENT_VER_STR =~ v([0-9]+) ]]; then
        VER_MAJOR=${BASH_REMATCH[1]}
    else
        VER_MAJOR=5
    fi

    clear
    echo -e "${GREEN}=== Snell 配置信息 ===${PLAIN}"
    echo -e "IP 地址 : ${PUBLIC_IP}"
    echo -e "端口    : ${PORT}"
    echo -e "PSK 密钥: ${PSK}"
    echo -e "IPv6    : ${IPV6_STATUS}"
    echo -e "混淆    : http"
    echo -e "版本    : ${CURRENT_VER_STR}"
    echo -e "${GREEN}======================${PLAIN}"
    echo -e "Surge 托管配置:"
    echo -e "${YELLOW}Snell = snell, ${PUBLIC_IP}, ${PORT}, psk=${PSK}, version=${VER_MAJOR}, obfs=http${PLAIN}"
    echo -e "${GREEN}======================${PLAIN}"
}

show_status() {
    if systemctl is-active --quiet snell; then
        echo -e "运行状态: ${GREEN}运行中${PLAIN}"
    else
        echo -e "运行状态: ${RED}未运行${PLAIN}"
    fi
}

# --- 菜单 ---
show_menu() {
    clear
    echo -e "${GREEN}=== Snell 管理脚本 (定制版) ===${PLAIN}"
    show_status
    echo ""
    echo "1. 安装 Snell"
    echo "2. 更新 Snell"
    echo "3. 卸载 Snell"
    echo "4. 查看 配置信息"
    echo "5. 启动 服务"
    echo "6. 停止 服务"
    echo "7. 重启 服务"
    echo "0. 退出"
    echo ""
    read -p "请输入选项: " choice
    
    case "${choice}" in
        1) install_snell ;;
        2) update_snell ;;
        3) uninstall_snell ;;
        4) show_config ;;
        5) systemctl start snell && echo -e "${GREEN}已启动${PLAIN}" ;;
        6) systemctl stop snell && echo -e "${GREEN}已停止${PLAIN}" ;;
        7) systemctl restart snell && echo -e "${GREEN}已重启${PLAIN}" ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${PLAIN}" ;;
    esac
}

check_root
while true; do
    show_menu
    echo ""
    read -p "按回车键继续..."
done
}

main
