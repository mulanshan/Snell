# --- 核心配置 ---
VERSION="v5.0.1"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RESET='\033[0m'

# --- 基础检查 ---
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}错误：请以 root 用户运行此脚本。${RESET}"
        exit 1
    fi
}

# --- Ubuntu 专属依赖安装 ---
install_dependencies() {
    echo -e "${GREEN}正在检查系统环境 (Ubuntu/Debian)...${RESET}"
    
    # 检测并等待 apt 锁释放 (解决 Ubuntu 常见占用问题)
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
        echo -e "${YELLOW}检测到 apt 被占用，正在等待释放...${RESET}"
        sleep 2
    done

    echo -e "${GREEN}更新软件源并安装依赖...${RESET}"
    # 使用非交互模式安装，避免卡住
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y wget unzip curl
}

# --- 核心功能函数 ---
check_installed() {
    if [ -f "/usr/local/bin/snell-server" ]; then return 0; else return 1; fi
}

check_running() {
    systemctl is-active --quiet "snell.service"
    return $?
}

start_snell() {
    systemctl start snell
    echo -e "${GREEN}服务已启动${RESET}"
}

stop_snell() {
    systemctl stop snell
    echo -e "${GREEN}服务已停止${RESET}"
}

install_snell() {
    echo -e "${GREEN}=== 开始安装 Snell (${VERSION}) ===${RESET}"

    install_dependencies

    # 架构检测 (针对 AMD64)
    ARCH=$(arch)
    if [[ ${ARCH} == "x86_64" || ${ARCH} == "amd64" ]]; then
        ARCH_TAG="amd64"
    elif [[ ${ARCH} == "aarch64" || ${ARCH} == "arm64" ]]; then
        ARCH_TAG="aarch64"
    else
        echo -e "${RED}不支持的架构: ${ARCH}${RESET}"
        exit 1
    fi

    # 下载
    SNELL_URL="https://dl.nssurge.com/snell/snell-server-${VERSION}-linux-${ARCH_TAG}.zip"
    echo -e "正在下载: ${SNELL_URL}"
    
    wget --no-check-certificate "${SNELL_URL}" -O snell-server.zip
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载失败，请检查网络连接。${RESET}"
        rm -f snell-server.zip
        exit 1
    fi

    unzip -o snell-server.zip -d /usr/local/bin
    rm snell-server.zip
    chmod +x /usr/local/bin/snell-server

    # --- 端口选择 ---
    echo -e "----------------------------------------"
    read -p "请输入端口号 (1-65535) [留空则随机]: " USER_PORT
    if [[ -z "${USER_PORT}" ]]; then
        PORT=$(shuf -i 30000-65000 -n 1)
        echo -e "已选择随机端口: ${GREEN}${PORT}${RESET}"
    else
        PORT=${USER_PORT}
        echo -e "已选择指定端口: ${GREEN}${PORT}${RESET}"
    fi
    echo -e "----------------------------------------"

    # 生成配置
    PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
    mkdir -p /etc/snell
    cat > /etc/snell/snell-server.conf << EOF
[snell-server]
listen = ::0:${PORT}
psk = ${PSK}
ipv6 = true
obfs = off
EOF

    # 配置 Systemd
    cat > /etc/systemd/system/snell.service << EOF
[Unit]
Description=Snell Proxy Service
After=network.target

[Service]
Type=simple
User=root
Group=root
LimitNOFILE=32768
ExecStart=/usr/local/bin/snell-server -c /etc/snell/snell-server.conf
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable snell
    systemctl restart snell

    echo -e "${GREEN}安装完成！${RESET}"
    show_config
}

update_snell() {
    if ! check_installed; then
        echo -e "${YELLOW}未安装 Snell，无法更新。${RESET}"
        return
    fi

    echo -e "${GREEN}正在更新至 ${VERSION}...${RESET}"
    systemctl stop snell
    install_dependencies
    
    # 仅下载替换二进制文件
    wget --no-check-certificate "https://dl.nssurge.com/snell/snell-server-${VERSION}-linux-amd64.zip" -O snell-server.zip
    unzip -o snell-server.zip -d /usr/local/bin
    rm snell-server.zip
    chmod +x /usr/local/bin/snell-server
    
    systemctl restart snell
    echo -e "${GREEN}更新成功！${RESET}"
    show_config
}

uninstall_snell() {
    echo -e "${YELLOW}正在卸载...${RESET}"
    systemctl stop snell
    systemctl disable snell
    rm -f /etc/systemd/system/snell.service
    systemctl daemon-reload
    rm -f /usr/local/bin/snell-server
    rm -rf /etc/snell
    echo -e "${GREEN}卸载完毕。${RESET}"
}

show_config() {
    CONF="/etc/snell/snell-server.conf"
    if [ ! -f "${CONF}" ]; then echo -e "${RED}配置文件不存在${RESET}"; return; fi

    # 实时读取配置
    PORT_LINE=$(grep 'listen' ${CONF})
    PORT=$(echo "$PORT_LINE" | awk -F':' '{print $NF}' | tr -d ' ')
    PSK=$(grep 'psk' ${CONF} | cut -d'=' -f2 | tr -d ' ')
    OBFS=$(grep 'obfs' ${CONF} | cut -d'=' -f2 | tr -d ' ')
    
    HOST_IP=$(curl -s4m8 ip.sb || curl -s4m8 ifconfig.me)
    
    if [[ "$OBFS" == "http" ]]; then OBFS_PART=", obfs=http"; SHOW_OBFS="http"; else OBFS_PART=""; SHOW_OBFS="off"; fi

    echo -e "${GREEN}=== Snell 配置信息 ===${RESET}"
    echo -e "IP 地址 : ${HOST_IP}"
    echo -e "端口    : ${PORT}"
    echo -e "PSK 密钥: ${PSK}"
    echo -e "混淆    : ${SHOW_OBFS}"
    echo -e "${GREEN}======================${RESET}"
    echo -e "Surge 托管配置:"
    echo -e "${YELLOW}Snell = snell, ${HOST_IP}, ${PORT}, psk=${PSK}, version=5${OBFS_PART}, reuse=true${RESET}"
    echo -e "${GREEN}======================${RESET}"
}

# --- 菜单逻辑 ---
show_menu() {
    clear
    if check_installed; then
        STATUS="${GREEN}已安装${RESET}"
        VER=$(/usr/local/bin/snell-server -v 2>&1 | grep -o 'v[0-9.]*')
        if check_running; then RUNSTATE="${GREEN}运行中${RESET}"; else RUNSTATE="${RED}未运行${RESET}"; fi
    else
        STATUS="${RED}未安装${RESET}"; RUNSTATE="${RED}未运行${RESET}"; VER="-"
    fi

    echo -e "${GREEN}=== Snell 管理脚本 (Ubuntu AMD专用版) ===${RESET}"
    echo -e "状态: ${STATUS} | 运行: ${RUNSTATE} | 版本: ${GREEN}${VER}${RESET}"
    echo ""
    echo "1. 安装 Snell"
    echo "2. 卸载 Snell"
    echo "3. 启停控制"
    echo "4. 更新 Snell"
    echo "5. 查看配置"
    echo "0. 退出"
    echo -e "${GREEN}=========================================${RESET}"
    read -p "请输入选项: " choice

    case "${choice}" in
        1) install_snell ;;
        2) uninstall_snell ;;
        3) if check_running; then stop_snell; else start_snell; fi ;;
        4) update_snell ;;
        5) show_config ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
    echo ""; read -p "按回车继续..."
}

check_root
while true; do show_menu; done
