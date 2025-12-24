#!/bin/bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

# --- 核心配置 (如需改版本，改这里即可) ---
VERSION="v5.0.1"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RESET='\033[0m'

# --- 基础函数 ---
get_system_type() {
    if [ -f /etc/debian_version ]; then
        echo "debian"
    elif [ -f /etc/redhat-release ]; then
        echo "centos"
    else
        echo "unknown"
    fi
}

wait_for_package_manager() {
    local system_type=$(get_system_type)
    if [ "$system_type" = "debian" ]; then
        while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
            echo -e "${YELLOW}等待其他 apt 进程完成...${RESET}"
            sleep 1
        done
    fi
}

install_required_packages() {
    local system_type=$(get_system_type)
    echo -e "${GREEN}正在检查并安装必要软件包...${RESET}"
    
    if [ "$system_type" = "debian" ]; then
        apt-get update
        apt-get install -y wget unzip curl
    elif [ "$system_type" = "centos" ]; then
        yum -y update
        yum -y install wget unzip curl
    else
        echo -e "${RED}不支持的系统类型${RESET}"
        exit 1
    fi
}

check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}请以 root 权限运行此脚本。${RESET}"
        exit 1
    fi
}

# --- 状态检查函数 ---
check_snell_installed() {
    if [ -f "/usr/local/bin/snell-server" ]; then
        return 0
    else
        return 1
    fi
}

check_snell_running() {
    systemctl is-active --quiet "snell.service"
    return $?
}

# --- 操作函数 ---
start_snell() {
    systemctl start "snell.service"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Snell 启动成功${RESET}"
    else
        echo -e "${RED}Snell 启动失败${RESET}"
    fi
}

stop_snell() {
    systemctl stop "snell.service"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Snell 停止成功${RESET}"
    else
        echo -e "${RED}Snell 停止失败${RESET}"
    fi
}

install_snell() {
    echo -e "${GREEN}=== 开始安装 Snell (${VERSION}) ===${RESET}"

    wait_for_package_manager
    install_required_packages

    ARCH=$(arch)
    if [[ ${ARCH} == "x86_64" ]]; then
        ARCH="amd64"
    elif [[ ${ARCH} == "aarch64" ]]; then
        ARCH="aarch64"
    else
        echo -e "${RED}不支持的架构: ${ARCH}${RESET}"
        exit 1
    fi

    SNELL_URL="https://dl.nssurge.com/snell/snell-server-${VERSION}-linux-${ARCH}.zip"

    echo -e "正在下载: ${SNELL_URL}"
    wget --no-check-certificate "${SNELL_URL}" -O snell-server.zip

    if [ $? -ne 0 ]; then
        echo -e "${RED}下载失败，请检查网络。${RESET}"
        rm -f snell-server.zip
        exit 1
    fi

    unzip -o snell-server.zip -d /usr/local/bin
    rm snell-server.zip
    chmod +x /usr/local/bin/snell-server

    # 生成随机配置
    RANDOM_PORT=$(shuf -i 30000-65000 -n 1)
    RANDOM_PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)

    mkdir -p /etc/snell
    cat > /etc/snell/snell-server.conf << EOF
[snell-server]
listen = ::0:${RANDOM_PORT}
psk = ${RANDOM_PSK}
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

    echo -e "${GREEN}Snell 安装并启动成功！${RESET}"
    show_config
}

update_snell() {
    if [ ! -f "/usr/local/bin/snell-server" ]; then
        echo -e "${YELLOW}Snell 未安装，无法更新。${RESET}"
        return
    fi

    echo -e "${GREEN}正在更新 Snell 至 ${VERSION} ...${RESET}"
    systemctl stop snell
    wait_for_package_manager
    install_required_packages

    ARCH=$(arch)
    if [[ ${ARCH} == "x86_64" ]]; then
        ARCH="amd64"
    elif [[ ${ARCH} == "aarch64" ]]; then
        ARCH="aarch64"
    fi

    SNELL_URL="https://dl.nssurge.com/snell/snell-server-${VERSION}-linux-${ARCH}.zip"
    
    wget --no-check-certificate "${SNELL_URL}" -O snell-server.zip
    unzip -o snell-server.zip -d /usr/local/bin
    rm snell-server.zip
    chmod +x /usr/local/bin/snell-server
    
    systemctl restart snell
    echo -e "${GREEN}Snell 更新成功${RESET}"
    show_config
}

uninstall_snell() {
    echo -e "${YELLOW}正在卸载 Snell...${RESET}"
    systemctl stop snell
    systemctl disable snell
    rm -f /etc/systemd/system/snell.service
    systemctl daemon-reload
    rm -f /usr/local/bin/snell-server
    rm -rf /etc/snell
    echo -e "${GREEN}Snell 卸载成功${RESET}"
}

show_config() {
    CONF="/etc/snell/snell-server.conf"
    if [ ! -f "${CONF}" ]; then
        echo -e "${RED}配置文件不存在${RESET}"
        return
    fi

    # 实时读取真实配置 (比 config.txt 更靠谱)
    PORT_LINE=$(grep 'listen' ${CONF})
    PORT=$(echo "$PORT_LINE" | awk -F':' '{print $NF}' | tr -d ' ')
    PSK=$(grep 'psk' ${CONF} | cut -d'=' -f2 | tr -d ' ')
    IPV6=$(grep 'ipv6' ${CONF} | cut -d'=' -f2 | tr -d ' ')
    OBFS=$(grep 'obfs' ${CONF} | cut -d'=' -f2 | tr -d ' ')
    
    # 获取 IP
    HOST_IP=$(curl -s4m8 ip.sb || curl -s4m8 ifconfig.me)
    
    # 简单的版本号提取 (v5)
    VER_MAJOR="5"

    # 处理 Surge 连接串
    if [[ "$OBFS" == "http" ]]; then
        OBFS_PART=", obfs=http"
    else
        OBFS_PART=""
    fi

    echo -e "${GREEN}=== Snell 配置信息 ===${RESET}"
    echo -e "IP 地址 : ${HOST_IP}"
    echo -e "端口    : ${PORT}"
    echo -e "PSK 密钥: ${PSK}"
    echo -e "IPv6    : ${IPV6}"
    echo -e "混淆    : ${OBFS}"
    echo -e "${GREEN}======================${RESET}"
    echo -e "Surge 托管配置:"
    echo -e "${YELLOW}Snell = snell, ${HOST_IP}, ${PORT}, psk=${PSK}, version=${VER_MAJOR}${OBFS_PART}, reuse=true${RESET}"
    echo -e "${GREEN}======================${RESET}"
}

show_menu() {
    clear
    check_snell_installed
    snell_installed=$?
    check_snell_running
    snell_running=$?

    if [ $snell_installed -eq 0 ]; then
        status_text="${GREEN}已安装${RESET}"
        # 获取当前运行版本
        current_ver=$(/usr/local/bin/snell-server -v 2>&1 | grep -o 'v[0-9.]*')
        version_text="${GREEN}${current_ver}${RESET}"
        
        if [ $snell_running -eq 0 ]; then
            run_text="${GREEN}运行中${RESET}"
        else
            run_text="${RED}未运行${RESET}"
        fi
    else
        status_text="${RED}未安装${RESET}"
        run_text="${RED}未运行${RESET}"
        version_text="—"
    fi

    echo -e "${GREEN}=== Snell 管理工具 (经典版) ===${RESET}"
    echo -e "安装状态: ${status_text}"
    echo -e "运行状态: ${run_text}"
    echo -e "当前版本: ${version_text}"
    echo ""
    echo "1. 安装 Snell 服务"
    echo "2. 卸载 Snell 服务"
    if [ $snell_installed -eq 0 ]; then
        if [ $snell_running -eq 0 ]; then
            echo "3. 停止 Snell 服务"
        else
            echo "3. 启动 Snell 服务"
        fi
    fi
    echo "4. 更新 Snell 服务"
    echo "5. 查看 Snell 配置"
    echo "0. 退出"
    echo -e "${GREEN}=============================${RESET}"
    read -p "请输入选项: " choice
    
    case "${choice}" in
        1) install_snell ;;
        2) 
            if [ $snell_installed -eq 0 ]; then uninstall_snell; else echo -e "${RED}未安装${RESET}"; fi 
            ;;
        3) 
            if [ $snell_installed -eq 0 ]; then
                if [ $snell_running -eq 0 ]; then stop_snell; else start_snell; fi
            else
                echo -e "${RED}未安装${RESET}"
            fi 
            ;;
        4) update_snell ;;
        5) show_config ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
    
    echo ""
    read -p "按回车键继续..."
}

trap 'echo -e "\n${RED}已取消${RESET}"; exit' INT

check_root
while true; do
    show_menu
done
