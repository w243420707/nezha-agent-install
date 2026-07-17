#! /bin/bash

set -euo pipefail

AGENT_VERSION="0.20.12"
AGENT_DIR="/opt/nezha-agent"
ZIP="/tmp/nezha-agent.zip"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

detect_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt-get"
        PKG_INSTALL="install -y"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
        PKG_INSTALL="install -y"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
        PKG_INSTALL="install -y"
    elif command -v apk >/dev/null 2>&1; then
        PKG_MANAGER="apk"
        PKG_INSTALL="add"
    elif command -v zypper >/dev/null 2>&1; then
        PKG_MANAGER="zypper"
        PKG_INSTALL="install -y"
    else
        error "不支持的包管理器，请手动安装依赖"
        exit 1
    fi
}

install_dependencies() {
    local missing_deps=()
    for dep in "$@"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps+=("$dep")
        fi
    done

    if [ ${#missing_deps[@]} -eq 0 ]; then
        return
    fi

    info "检测到缺少依赖: ${missing_deps[*]}"
    info "正在自动安装依赖..."
    ${SUDO} "$PKG_MANAGER" "$PKG_INSTALL" "${missing_deps[@]}"
}

get_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        SUDO=""
    elif command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        error "需要 root 权限或 sudo 命令"
        exit 1
    fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l) ARCH="armv7" ;;
        *) 
            error "不支持的架构: $(uname -m)"
            exit 1
            ;;
    esac
}

main() {
    echo "========================================="
    echo "      Nezha Agent 一键安装脚本"
    echo "      版本: ${AGENT_VERSION}"
    echo "========================================="

    info "获取权限..."
    get_sudo

    info "检测包管理器..."
    detect_package_manager

    info "检查并安装依赖..."
    install_dependencies "curl" "unzip"

    info "检测系统架构..."
    detect_arch

    if [ -z "${NZ_SERVER:-}" ]; then
        read -p "请输入 Nezha 服务端地址 (例如: server.example.com:5555): " NZ_SERVER
        if [ -z "$NZ_SERVER" ]; then
            error "服务端地址不能为空"
            exit 1
        fi
    else
        info "使用环境变量中的服务端地址"
    fi

    if [ -z "${NZ_CLIENT_SECRET:-}" ]; then
        read -p "请输入客户端密钥 (Client Secret): " NZ_CLIENT_SECRET
        if [ -z "$NZ_CLIENT_SECRET" ]; then
            error "客户端密钥不能为空"
            exit 1
        fi
    else
        info "使用环境变量中的客户端密钥"
    fi

    if [ -z "${NZ_TLS:-}" ]; then
        read -p "是否启用 TLS (true/false，默认 true): " NZ_TLS
    fi
    NZ_TLS=${NZ_TLS:-true}

    URL="https://github.com/nezhahq/agent/releases/download/v${AGENT_VERSION}/nezha-agent_${AGENT_VERSION}_linux_${ARCH}.zip"

    echo ""
    info "开始安装 Nezha Agent ${AGENT_VERSION} (${ARCH})..."
    info "服务端: ${NZ_SERVER}"
    info "TLS: ${NZ_TLS}"

    info "创建安装目录..."
    ${SUDO} mkdir -p "$AGENT_DIR"

    info "下载 Agent 压缩包..."
    curl -L --fail --connect-timeout 20 --max-time 120 "$URL" -o "$ZIP"

    info "解压到安装目录..."
    ${SUDO} unzip -qo "$ZIP" -d "$AGENT_DIR"
    rm -f "$ZIP"

    info "设置执行权限..."
    ${SUDO} chmod +x "$AGENT_DIR/nezha-agent"

    CONFIG="$AGENT_DIR/config.yml"

    if [ -f "$CONFIG" ]; then
        warn "检测到已有配置文件，正在备份..."
        ${SUDO} cp "$CONFIG" "$CONFIG.bak.$(date +%Y%m%d%H%M%S)"
    fi

    info "生成配置文件..."
    ${SUDO} cat > "$CONFIG" <<EOF
client_secret: $NZ_CLIENT_SECRET
server: $NZ_SERVER
tls: $NZ_TLS
disable_command_execute: true
disable_nat: true
disable_auto_update: true
disable_force_update: true
EOF

    ${SUDO} chmod 600 "$CONFIG"

    info "安装服务..."
    ${SUDO} env NZ_SERVER="$NZ_SERVER" NZ_TLS="$NZ_TLS" NZ_CLIENT_SECRET="$NZ_CLIENT_SECRET" "$AGENT_DIR/nezha-agent" service -c "$CONFIG" install

    if command -v systemctl >/dev/null 2>&1; then
        info "重启服务 (systemctl)..."
        ${SUDO} systemctl restart nezha-agent.service 2>/dev/null || true
    fi

    info "重启服务..."
    ${SUDO} "$AGENT_DIR/nezha-agent" service -c "$CONFIG" restart 2>/dev/null || true

    echo ""
    echo "========================================="
    echo -e "${GREEN}[SUCCESS] Nezha Agent ${AGENT_VERSION} 固定版安装并加固完成。${NC}"
    echo "========================================="
    echo ""
    info "配置文件路径: ${CONFIG}"
    info "服务状态查看: systemctl status nezha-agent"
}

main "$@"