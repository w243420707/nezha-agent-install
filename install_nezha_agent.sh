#! /bin/bash

set -euo pipefail

SCRIPT_VERSION="${SCRIPT_VERSION:-2026.07.25.2}"
AGENT_VERSION="${AGENT_VERSION:-v2.2.3}"
AGENT_DIR="/opt/nezha/agent"
NZ_TLS="${NZ_TLS:-true}"
APT_LOCK_TIMEOUT="${APT_LOCK_TIMEOUT:-300}"

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

disable_apt_suite_sources() {
    local suite="$1"
    local changed=1
    local backup_suffix
    backup_suffix="$(date +%Y%m%d%H%M%S)"

    for source_file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
        [ -f "$source_file" ] || continue
        if ${SUDO} grep -Eq "^[[:space:]]*deb(-src)?[[:space:]].*[[:space:]]${suite}([[:space:]]|$)" "$source_file"; then
            warn "检测到失效软件源 ${suite}: ${source_file}，正在备份并禁用..."
            ${SUDO} cp "$source_file" "${source_file}.bak.${backup_suffix}"
            ${SUDO} sed -i -E "/^[[:space:]]*deb(-src)?[[:space:]].*[[:space:]]${suite}([[:space:]]|$)/ s/^/# disabled by nezha-agent installer: /" "$source_file"
            changed=0
        fi
    done

    for source_file in /etc/apt/sources.list.d/*.sources; do
        [ -f "$source_file" ] || continue
        if ${SUDO} grep -Eq "^[[:space:]]*Suites:[[:space:]].*(^|[[:space:]])${suite}([[:space:]]|$)" "$source_file"; then
            warn "检测到失效软件源 ${suite}: ${source_file}，正在备份并禁用..."
            ${SUDO} cp "$source_file" "${source_file}.bak.${backup_suffix}"
            ${SUDO} sed -i -E "/^[[:space:]]*Enabled:/ s/Enabled:.*/Enabled: no/" "$source_file"
            if ! ${SUDO} grep -Eq "^[[:space:]]*Enabled:" "$source_file"; then
                printf '\nEnabled: no\n' | ${SUDO} tee -a "$source_file" >/dev/null
            fi
            changed=0
        fi
    done

    return "$changed"
}

heal_apt_sources() {
    local log_file="$1"
    local healed=1
    local suites

    suites="$(
        sed -nE \
            -e "s/^E: The repository '.* ([^ ]+) Release'.*no longer has a Release file\\./\\1/p" \
            -e "s/^E: The repository '.* ([^ ]+) Release'.*does not have a Release file\\./\\1/p" \
            -e "s/^Err:[0-9]+ .* ([^ ]+) Release$/\\1/p" \
            "$log_file" | sort -u
    )"

    if [ -z "$suites" ]; then
        return 1
    fi

    while IFS= read -r suite; do
        [ -n "$suite" ] || continue
        if disable_apt_suite_sources "$suite"; then
            healed=0
        fi
    done <<EOF
$suites
EOF

    return "$healed"
}

apt_update_with_self_heal() {
    local log_file
    log_file="$(mktemp)"

    if ${SUDO} apt-get -o DPkg::Lock::Timeout="$APT_LOCK_TIMEOUT" update 2>&1 | tee "$log_file"; then
        rm -f "$log_file"
        return 0
    fi

    warn "apt-get update 失败，正在尝试自动修复失效软件源..."

    if heal_apt_sources "$log_file"; then
        warn "已禁用失效 apt 软件源，重新更新软件包索引..."
        rm -f "$log_file"
        ${SUDO} apt-get -o DPkg::Lock::Timeout="$APT_LOCK_TIMEOUT" update
        return
    fi

    rm -f "$log_file"
    return 1
}

is_apt_locked() {
    local lock_file
    local pids

    if ! command -v fuser >/dev/null 2>&1; then
        return 1
    fi

    for lock_file in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock; do
        [ -e "$lock_file" ] || continue
        pids="$(${SUDO} fuser "$lock_file" 2>/dev/null || true)"
        if [ -n "$pids" ]; then
            warn "apt/dpkg 锁被占用: ${lock_file}，占用进程: ${pids}"
            return 0
        fi
    done

    return 1
}

wait_for_apt_locks() {
    local waited=0
    local interval=5

    while is_apt_locked; do
        if [ "$waited" -ge "$APT_LOCK_TIMEOUT" ]; then
            error "等待 apt/dpkg 锁释放超时 (${APT_LOCK_TIMEOUT} 秒)"
            return 1
        fi

        warn "系统正在执行 apt/dpkg 操作，等待 ${interval} 秒后重试..."
        sleep "$interval"
        waited=$((waited + interval))
    done

    return 0
}

repair_dpkg_state() {
    warn "检测到 dpkg 状态被中断，正在执行 dpkg --configure -a 修复..."
    wait_for_apt_locks || return 1
    ${SUDO} env DEBIAN_FRONTEND=noninteractive dpkg --configure -a
}

apt_install_with_lock_wait() {
    local log_file

    info "apt/dpkg 如被其他进程占用，将最多等待 ${APT_LOCK_TIMEOUT} 秒..."
    wait_for_apt_locks || return 1

    log_file="$(mktemp)"
    if ${SUDO} env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout="$APT_LOCK_TIMEOUT" install -y "$@" 2>&1 | tee "$log_file"; then
        rm -f "$log_file"
        return 0
    fi

    if grep -Eiq "dpkg was interrupted|dpkg --configure -a" "$log_file"; then
        warn "apt 提示 dpkg 配置未完成，修复后重试安装依赖..."
        rm -f "$log_file"
        repair_dpkg_state || return 1
        ${SUDO} env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout="$APT_LOCK_TIMEOUT" install -y "$@"
        return
    fi

    if grep -Eiq "Could not get lock|Unable to acquire.*lock|held by process" "$log_file"; then
        warn "apt/dpkg 锁仍被占用，等待释放后重试安装依赖..."
        rm -f "$log_file"
        wait_for_apt_locks || return 1
        ${SUDO} env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout="$APT_LOCK_TIMEOUT" install -y "$@"
        return
    fi

    rm -f "$log_file"
    return 1
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

    if command -v apt-get >/dev/null 2>&1; then
        if ! apt_update_with_self_heal; then
            warn "apt-get update 仍然失败，继续尝试使用现有软件包索引安装依赖..."
        fi
        if ! apt_install_with_lock_wait "${missing_deps[@]}"; then
            error "依赖安装失败，请检查 apt 软件源、网络连接，或等待系统自动更新完成后重试"
            exit 1
        fi
    elif command -v dnf >/dev/null 2>&1; then
        ${SUDO} dnf install -y "${missing_deps[@]}"
    elif command -v yum >/dev/null 2>&1; then
        ${SUDO} yum install -y "${missing_deps[@]}"
    elif command -v apk >/dev/null 2>&1; then
        ${SUDO} apk add --no-cache "${missing_deps[@]}"
    elif command -v zypper >/dev/null 2>&1; then
        ${SUDO} zypper install -y "${missing_deps[@]}"
    else
        error "不支持的包管理器，请手动安装依赖"
        exit 1
    fi
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
        x86_64|amd64) NZ_ARCH="amd64" ;;
        aarch64|arm64) NZ_ARCH="arm64" ;;
        i386|i686) NZ_ARCH="386" ;;
        armv7l|armv6l|arm) NZ_ARCH="arm" ;;
        *) 
            error "不支持的架构: $(uname -m)"
            exit 1
            ;;
    esac
}

main() {
    echo "========================================="
    echo "      Nezha Agent 一键安装脚本"
    echo "      脚本版本: ${SCRIPT_VERSION}"
    echo "      Agent 版本: ${AGENT_VERSION}"
    echo "========================================="

    info "获取权限..."
    get_sudo

    info "检查并安装依赖..."
    install_dependencies "curl" "unzip"

    info "检测系统架构..."
    detect_arch

    if [ -z "${NZ_SERVER:-}" ]; then
        error "缺少环境变量 NZ_SERVER，请在命令中设置"
        error "示例: NZ_SERVER=\"server:5555\" NZ_CLIENT_SECRET=\"secret\" curl ... | bash"
        exit 1
    fi

    if [ -z "${NZ_CLIENT_SECRET:-}" ]; then
        error "缺少环境变量 NZ_CLIENT_SECRET，请在命令中设置"
        error "示例: NZ_SERVER=\"server:5555\" NZ_CLIENT_SECRET=\"secret\" curl ... | bash"
        exit 1
    fi

    ZIP="/tmp/nezha-agent_linux_${NZ_ARCH}_${AGENT_VERSION}.zip"
    URL="https://github.com/nezhahq/agent/releases/download/${AGENT_VERSION}/nezha-agent_linux_${NZ_ARCH}.zip"

    info "使用配置:"
    info "  版本: ${AGENT_VERSION}"
    info "  服务端: ${NZ_SERVER}"
    info "  TLS: ${NZ_TLS}"

    echo ""
    info "开始安装 Nezha Agent ${AGENT_VERSION} (${NZ_ARCH})..."

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
