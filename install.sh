#!/usr/bin/env bash
set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

APP_NAME="oo"
MENU_VERSION="2026.09.25.1"
INSTALL_ROOT="/etc/oo"
LEGACY_INSTALL_ROOTS=("/etc/XboardNode-Plus" "/etc/xboard-node")
# Only migration code uses historical names. Never create a second running unit.
LEGACY_SERVICE_NAME="xboard-node.service"
LEGACY_SERVICE_PATH="/etc/systemd/system/${LEGACY_SERVICE_NAME}"
LEGACY_BINARY_PATH="/usr/local/bin/xboard-node"
LEGACY_CLI_PATH="/usr/local/bin/xbctl"
LEGACY_CLI_LINK="/usr/bin/xbctl"
LEGACY_PREPARED=0
LEGACY_WAS_ACTIVE=0
LEGACY_WAS_ENABLED=0
INSTALL_MUTATED=0
BACKUP_DIR="${INSTALL_ROOT}/backups"
INSTALL_META="${INSTALL_ROOT}/install-meta.json"
CONFIG_FILE="${INSTALL_ROOT}/config.yml"
CREDENTIALS_FILE="${INSTALL_ROOT}/credentials.env"
BINARY_PATH="/usr/local/bin/oo-node"
SERVICE_NAME="oo.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
CLI_PATH="/usr/local/bin/ooctl"
OO_PATH="/usr/local/bin/oo"
OO_LINK_PATH="/usr/bin/oo"
INSTALLER_COPY_PATH="${INSTALL_ROOT}/install.sh"
CLI_BINARY_SOURCE=""
DEFAULT_HEALTH_PORT=auto
DEFAULT_KERNEL="auto"
DEFAULT_MODE="node"
DEFAULT_ACTION="menu"
DEFAULT_RELEASE_VERSION="latest"
DEFAULT_LOG_LEVEL="info"
DEFAULT_KERNEL_LOG_LEVEL="warn"
DEFAULT_DOWNLOAD_BASE="https://node.xboardnext.com/oo/releases"

ACTION="${DEFAULT_ACTION}"
MODE=""
PANEL_URL=""
TOKEN=""
NODE_ID=""
NODE_TYPE=""
MACHINE_ID=""
KERNEL_TYPE="${DEFAULT_KERNEL}"
RELEASE_VERSION="${DEFAULT_RELEASE_VERSION}"
HEALTH_PORT="${DEFAULT_HEALTH_PORT}"
HEALTH_ENABLED=1
RUNTIME_GOMEMLIMIT="${OO_NODE_GOMEMLIMIT:-}"
RUNTIME_GOGC="${OO_NODE_GOGC:-}"
BINARY_SOURCE=""
CLI_BINARY_SOURCE=""
FORCE_RECONFIGURE=0
REPLACE_INSTANCE=""
PURGE=0
YES=0
ARCH=""
OS=""
DOWNLOAD_URL=""
CURRENT_STATE="fresh"
TMP_DIR=""
BACKUP_PATH=""
SERVICE_EXISTED=0
CLEANUP_DONE=0

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} ${BOLD}$1${NC}"; }

detect_total_mem_mib() {
    if [ -r /proc/meminfo ]; then
        awk '/MemTotal:/ { printf "%d", ($2 + 1023) / 1024; exit }' /proc/meminfo 2>/dev/null || true
    fi
}

default_runtime_gomemlimit() {
    local mem_mib="${1:-$(detect_total_mem_mib)}"
    case "$mem_mib" in
        ''|*[!0-9]*) mem_mib=0 ;;
    esac

    if [ "$mem_mib" -gt 0 ] && [ "$mem_mib" -le 512 ]; then
        echo "160MiB"
    elif [ "$mem_mib" -gt 0 ] && [ "$mem_mib" -le 1024 ]; then
        echo "256MiB"
    elif [ "$mem_mib" -gt 0 ] && [ "$mem_mib" -le 2048 ]; then
        echo "384MiB"
    elif [ "$mem_mib" -gt 0 ] && [ "$mem_mib" -le 4096 ]; then
        echo "512MiB"
    elif [ "$mem_mib" -gt 4096 ]; then
        echo "768MiB"
    else
        echo "256MiB"
    fi
}

apply_runtime_defaults() {
    if [ -z "$RUNTIME_GOMEMLIMIT" ]; then
        RUNTIME_GOMEMLIMIT="$(default_runtime_gomemlimit)"
    fi
    if [ -z "$RUNTIME_GOGC" ]; then
        RUNTIME_GOGC="75"
    fi
    case "$RUNTIME_GOGC" in
        ''|*[!0-9]*)
            log_error "--gogc must be a positive integer"
            exit 1
            ;;
    esac
    if [ "$RUNTIME_GOGC" -le 0 ]; then
        log_error "--gogc must be a positive integer"
        exit 1
    fi
    log_info "Runtime memory tuning: GOMEMLIMIT=${RUNTIME_GOMEMLIMIT}, GOGC=${RUNTIME_GOGC}"
}

cleanup_tmp() {
    if [ "$CLEANUP_DONE" -eq 1 ]; then
        return
    fi
    CLEANUP_DONE=1
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
}

load_health_port_from_config() {
    local cfg_path="$1"
    if [ ! -f "$cfg_path" ]; then
        return
    fi
    local parsed
    if [ -x "$CLI_PATH" ]; then
        parsed=$("$CLI_PATH" config health-port --config "$cfg_path" 2>/dev/null || true)
    else
        parsed=$(grep -m1 'health_port:' "$cfg_path" 2>/dev/null | sed 's/.*health_port:[[:space:]]*//' | tr -cd '0-9' || true)
    fi
    if [ -n "$parsed" ] && [ "$parsed" -ge 0 ] 2>/dev/null; then
        HEALTH_PORT="$parsed"
        if [ "$HEALTH_PORT" -eq 0 ]; then
            HEALTH_ENABLED=0
        else
            HEALTH_ENABLED=1
        fi
    fi
}

rollback_install() {
    log_warn "Rolling back installation"
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    if [ "$SERVICE_EXISTED" -eq 0 ]; then systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true; fi
    if [ -n "$BACKUP_PATH" ] && [ -d "$BACKUP_PATH" ]; then
        if [ -f "$BACKUP_PATH/oo-node" ]; then
            install -m 755 "$BACKUP_PATH/oo-node" "$BINARY_PATH"
        else
            rm -f "$BINARY_PATH"
        fi
        if [ -f "$BACKUP_PATH/config.yml" ]; then
            install -m 600 "$BACKUP_PATH/config.yml" "$CONFIG_FILE"
        else
            rm -f "$CONFIG_FILE"
        fi
        if [ -f "$BACKUP_PATH/credentials.env" ]; then
            install -m 600 "$BACKUP_PATH/credentials.env" "$CREDENTIALS_FILE"
        else
            rm -f "$CREDENTIALS_FILE"
        fi
        if [ -f "$BACKUP_PATH/install-meta.json" ]; then
            install -m 644 "$BACKUP_PATH/install-meta.json" "$INSTALL_META"
        else
            rm -f "$INSTALL_META"
        fi
        if [ -f "$BACKUP_PATH/ooctl" ]; then
            install -m 755 "$BACKUP_PATH/ooctl" "$CLI_PATH"
        else
            rm -f "$CLI_PATH"
        fi
        if [ -f "$BACKUP_PATH/${SERVICE_NAME}" ]; then
            install -m 644 "$BACKUP_PATH/${SERVICE_NAME}" "$SERVICE_PATH"
        else
            rm -f "$SERVICE_PATH"
        fi
        if [ -f "$BACKUP_PATH/installer" ]; then install -m 755 "$BACKUP_PATH/installer" "$INSTALLER_COPY_PATH"; fi
        if [ -f "$BACKUP_PATH/launcher" ]; then install -m 755 "$BACKUP_PATH/launcher" "$OO_PATH"; fi
    fi
    load_health_port_from_config "$CONFIG_FILE"
    systemctl daemon-reload || true
    if [ "$LEGACY_PREPARED" -eq 1 ]; then
        rollback_legacy_service
        return
    fi
    if [ "$SERVICE_EXISTED" -eq 1 ] || [ -f "$SERVICE_PATH" ]; then
        systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
        systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true
        if ! wait_for_health; then
            log_error "Rollback completed but restored service did not become healthy"
            show_recent_logs
            return 1
        fi
    else
        systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi
    log_warn "Rollback complete"
}

on_error() {
    local exit_code=$?
    local line_no=${1:-unknown}
    if [ "$exit_code" -ne 0 ]; then
        trap - ERR
        set +e
        log_error "Install failed at line ${line_no} (exit=${exit_code})"
        if [ -n "$BACKUP_PATH" ] && { [ "$INSTALL_MUTATED" -eq 1 ] || [ "$LEGACY_PREPARED" -eq 1 ]; }; then
            rollback_install || true
        fi
    fi
    cleanup_tmp
    exit "$exit_code"
}
trap 'on_error $LINENO' ERR
trap cleanup_tmp EXIT

usage() {
    cat <<'HELP'

  oo 节点管理

  ACTIONS:
    menu         Show the interactive management menu (default)
    install      Install or reconcile the configured deployment (default)
    upgrade      Upgrade binary and restart service
    uninstall    Remove installed service and binary (config kept unless --purge)
    status       Show current installation status
    help         Show this help

  MODES (auto-detected from --node-id or --machine-id if omitted):
    --mode node      Panel single-node mode (default)
    --mode machine   Panel machine mode

  REQUIRED FOR NODE MODE:
    --panel, -a      Panel URL
    --token, -t      Panel server token
    --node-id, -n    Node ID

  REQUIRED FOR MACHINE MODE:
    --panel, -a       Panel URL
    --token, -t       Machine token
    --machine-id      Machine ID

  OPTIONAL:
    --node-type, -T     Explicit node type for node mode (HTTP: http; SOCKS5: socks or socks5)
    --kernel, -k        auto, singbox or xray (default: auto)
    --version           Release version or latest (default: latest)
    --binary            Use a local oo-node binary path instead of downloading
    --ooctl-binary      Use a local ooctl binary path instead of downloading
    --health-port       Local health port (default: auto, use 0 to disable)
    --gomemlimit        Runtime GOMEMLIMIT value, e.g. 256MiB
    --gogc              Runtime GOGC value, e.g. 50
    --force-reconfigure Overwrite an existing install even if mode/target changed
    --purge             With uninstall, delete /etc/oo too
    --yes, -y           Non-interactive confirmation for destructive operations

  EXAMPLES:
    sudo bash install.sh
    sudo oo
    sudo bash install.sh install --panel https://panel.example.com --token TOKEN --node-id 1
    sudo bash install.sh --panel https://panel.example.com --token TOKEN --machine-id 1
    sudo bash install.sh upgrade
    sudo bash install.sh uninstall --purge --yes

HELP
}

parse_args() {
    local positional=()
    while [ $# -gt 0 ]; do
        case "$1" in
            menu|install|upgrade|uninstall|status|help)
                ACTION="$1"
                shift
                ;;
            --mode)
                MODE="$2"
                shift 2
                ;;
            --panel|-a|--api)
                PANEL_URL="$2"
                shift 2
                ;;
            --token|-t)
                TOKEN="$2"
                shift 2
                ;;
            --node-id|-n)
                NODE_ID="$2"
                shift 2
                ;;
            --node-type|-T)
                NODE_TYPE="$2"
                shift 2
                ;;
            --machine-id)
                MACHINE_ID="$2"
                shift 2
                ;;
            --kernel|-k)
                KERNEL_TYPE="$2"
                shift 2
                ;;
            --version)
                RELEASE_VERSION="$2"
                shift 2
                ;;
            --binary)
                BINARY_SOURCE="$2"
                shift 2
                ;;
            --ooctl-binary|--xbctl-binary)
                CLI_BINARY_SOURCE="$2"
                shift 2
                ;;
            --replace-instance)
                REPLACE_INSTANCE="$2"
                shift 2
                ;;
            --health-port)
                HEALTH_PORT="$2"
                shift 2
                ;;
            --gomemlimit)
                RUNTIME_GOMEMLIMIT="$2"
                shift 2
                ;;
            --gogc)
                RUNTIME_GOGC="$2"
                shift 2
                ;;
            --force-reconfigure)
                FORCE_RECONFIGURE=1
                shift
                ;;
            --purge)
                PURGE=1
                shift
                ;;
            --yes|-y)
                YES=1
                shift
                ;;
            --help|-h)
                ACTION="help"
                shift
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done

    if [ ${#positional[@]} -gt 0 ] && [ "$ACTION" = "install" ]; then
        ACTION="${positional[0]}"
    fi

    # Keep the previous one-line installer syntax compatible: providing
    # connection parameters means install even though the no-argument default
    # now opens the interactive menu.
    if [ "$ACTION" = "menu" ] && { [ -n "$PANEL_URL" ] || [ -n "$TOKEN" ] || [ -n "$NODE_ID" ] || [ -n "$MACHINE_ID" ]; }; then
        ACTION="install"
    fi

    case "$KERNEL_TYPE" in
        auto|Auto|AUTO) KERNEL_TYPE="auto" ;;
        singbox|SingBox|SINGBOX) KERNEL_TYPE="singbox" ;;
        xray|Xray|XRAY) KERNEL_TYPE="xray" ;;
        *) ;;
    esac

    # Auto-detect mode from arguments when --mode is not specified.
    if [ -z "$MODE" ]; then
        if [ -n "$MACHINE_ID" ]; then
            MODE="machine"
        else
            MODE="node"
        fi
    fi

    case "$MODE" in
        node|machine) ;;
        *)
            log_error "Unsupported mode: $MODE"
            usage
            exit 1
            ;;
    esac
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "Please run as root or with sudo"
        exit 1
    fi
}

detect_arch() {
    local raw
    raw=$(uname -m)
    case "$raw" in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *)
            log_error "Unsupported architecture: $raw"
            exit 1
            ;;
    esac
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS="$ID"
    else
        OS="unknown"
    fi
}

ensure_systemd() {
    if ! command -v systemctl >/dev/null 2>&1; then
        log_error "systemd is required for this installer"
        exit 1
    fi
    if [ ! -d /run/systemd/system ]; then
        log_error "This host does not appear to be running systemd"
        exit 1
    fi
}

migrate_legacy_install_root() {
    if [ -d "$INSTALL_ROOT" ]; then
        return
    fi
    local legacy_root
    for legacy_root in "${LEGACY_INSTALL_ROOTS[@]}"; do
        if [ -d "$legacy_root" ]; then
            # Preserve embedded certificate/config paths in older installations.
            # An alias avoids moving live data before the transactional upgrade.
            log_step "沿用已有配置目录，建立 oo 兼容入口"
            ln -s "$legacy_root" "$INSTALL_ROOT"
            return
        fi
    done
}

run_with_retry() {
    local attempts="$1"
    local delay="$2"
    shift 2
    local i=1
    while [ "$i" -le "$attempts" ]; do
        if "$@"; then
            return 0
        fi
        if [ "$i" -lt "$attempts" ]; then
            log_warn "Command failed, retrying in ${delay}s: $*"
            sleep "$delay"
        fi
        i=$((i + 1))
    done
    return 1
}

install_dependencies() {
    case "$OS" in
        ubuntu|debian)
            DEBIAN_FRONTEND=noninteractive run_with_retry 10 3 apt-get update -qq
            DEBIAN_FRONTEND=noninteractive run_with_retry 10 3 apt-get install -y -qq curl wget ca-certificates >/dev/null 2>&1
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf >/dev/null 2>&1; then
                run_with_retry 5 3 dnf install -y -q curl wget ca-certificates >/dev/null 2>&1
            else
                run_with_retry 5 3 yum install -y -q curl wget ca-certificates >/dev/null 2>&1
            fi
            ;;
        *)
            log_warn "OS ${OS} is not in the official support set; continuing best-effort"
            ;;
    esac
}

ensure_dirs() {
    mkdir -p "$INSTALL_ROOT" "$BACKUP_DIR"
    chmod 700 "$INSTALL_ROOT"
}

validate_positive_int() {
    local label="$1"
    local value="$2"
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -le 0 ]; then
        log_error "${label} must be a positive integer, got: ${value}"
        exit 1
    fi
}

validate_install_request() {
    if [ -z "$PANEL_URL" ]; then
        log_error "Panel URL is required"
        exit 1
    fi
    if [ -z "$TOKEN" ]; then
        log_error "Token is required"
        exit 1
    fi
    if [ "$HEALTH_PORT" != auto ] && ! [[ "$HEALTH_PORT" =~ ^[0-9]+$ ]]; then
        log_error "health-port must be a non-negative integer"
        exit 1
    fi
    if [ "$HEALTH_PORT" = 0 ]; then
        HEALTH_ENABLED=0
    fi
    case "$KERNEL_TYPE" in
        auto|singbox|xray) ;;
        *)
            log_error "Kernel must be auto, singbox or xray"
            exit 1
            ;;
    esac
    case "$MODE" in
        node)
            validate_positive_int "Node ID" "$NODE_ID"
            ;;
        machine)
            validate_positive_int "Machine ID" "$MACHINE_ID"
            ;;
    esac
}

detect_current_state() {
    local has_binary=0 has_config=0 has_service=0
    [ -x "$BINARY_PATH" ] && has_binary=1
    [ -f "$CONFIG_FILE" ] && has_config=1
    [ -f "$SERVICE_PATH" ] && has_service=1

    if [ "$has_binary" -eq 0 ] && [ "$has_config" -eq 0 ] && [ "$has_service" -eq 0 ]; then
        CURRENT_STATE="fresh"
    elif [ "$has_binary" -eq 1 ] && [ "$has_config" -eq 1 ] && [ "$has_service" -eq 1 ]; then
        CURRENT_STATE="installed"
    else
        CURRENT_STATE="partial"
    fi
}

require_reconfigure_confirmation() {
    return
}

select_binary_source() {
    if [ -n "$BINARY_SOURCE" ]; then
        if [ ! -f "$BINARY_SOURCE" ]; then
            log_error "Binary source not found: $BINARY_SOURCE"
            exit 1
        fi
        echo "$BINARY_SOURCE"
        return
    fi
    if [ -f "./oo-node" ]; then
        echo "./oo-node"
        return
    fi
    if [ -f "./oo-node-linux-${ARCH}" ]; then
        echo "./oo-node-linux-${ARCH}"
        return
    fi
    echo ""
}

resolve_download_url() {
    local artifact="$1"
    if [ "$RELEASE_VERSION" = "latest" ]; then
        DOWNLOAD_URL="${DEFAULT_DOWNLOAD_BASE}/latest/download/${artifact}"
    else
        DOWNLOAD_URL="${DEFAULT_DOWNLOAD_BASE}/download/${RELEASE_VERSION}/${artifact}"
    fi
}

stage_binary() {
    local staged="$TMP_DIR/oo-node"
    local local_src
    local_src=$(select_binary_source)
    if [ -n "$local_src" ]; then
        log_step "Using local binary: ${local_src}"
        cp "$local_src" "$staged"
    else
        resolve_download_url "oo-node-linux-${ARCH}"
        log_step "Downloading binary: ${DOWNLOAD_URL}"
        if ! curl -fsSL "$DOWNLOAD_URL" -o "$staged"; then
            log_error "Failed to download binary from ${DOWNLOAD_URL}"
            exit 1
        fi
    fi
    chmod +x "$staged"
    if ! "$staged" -v >/dev/null 2>&1; then
        log_error "Downloaded binary failed version check"
        exit 1
    fi
}

stage_ooctl() {
    local staged="$TMP_DIR/ooctl"
    local local_src=""
    if [ -n "$CLI_BINARY_SOURCE" ]; then
        if [ ! -f "$CLI_BINARY_SOURCE" ]; then
            log_error "ooctl binary source not found: $CLI_BINARY_SOURCE"
            exit 1
        fi
        local_src="$CLI_BINARY_SOURCE"
    elif [ -f "./ooctl" ]; then
        local_src="./ooctl"
    elif [ -f "./ooctl-linux-${ARCH}" ]; then
        local_src="./ooctl-linux-${ARCH}"
    fi
    if [ -n "$local_src" ]; then
        log_step "Using local ooctl binary: ${local_src}"
        cp "$local_src" "$staged"
    else
        resolve_download_url "ooctl-linux-${ARCH}"
        log_step "Downloading ooctl: ${DOWNLOAD_URL}"
        if ! curl -fsSL "$DOWNLOAD_URL" -o "$staged"; then
            log_error "Failed to download ooctl from ${DOWNLOAD_URL}"
            exit 1
        fi
    fi
    chmod +x "$staged"
    if ! "$staged" version > /dev/null 2>&1; then
        log_error "Downloaded ooctl failed version check"
        exit 1
    fi
}

render_config() {
    local init_args=(
        config init
        --mode "$MODE"
        --panel-url "$PANEL_URL"
        --kernel "${KERNEL_TYPE:-auto}"
        --health-port "${HEALTH_PORT:-0}"
        --token "$TOKEN"
        --version "$RELEASE_VERSION"
        --output "$TMP_DIR/config.yml"
        --credentials-out "$TMP_DIR/credentials.env"
        --meta "$TMP_DIR/install-meta.json"
        --install-root "$INSTALL_ROOT"
        --verify-panel true
    )
    if [ -f "$CONFIG_FILE" ]; then
        init_args+=(--config "$CONFIG_FILE")
    fi
    if [ -f "$CREDENTIALS_FILE" ]; then
        init_args+=(--credentials-in "$CREDENTIALS_FILE")
    fi
    [ -z "$REPLACE_INSTANCE" ] || init_args+=(--replace-instance "$REPLACE_INSTANCE")
    if [ "$MODE" = "machine" ]; then
        init_args+=(--machine-id "$MACHINE_ID")
    else
        init_args+=(--node-id "$NODE_ID")
        if [ -n "$NODE_TYPE" ]; then
            init_args+=(--node-type "$NODE_TYPE")
        fi
    fi
    if [ -n "$RUNTIME_GOMEMLIMIT" ]; then
        init_args+=(--gomemlimit "$RUNTIME_GOMEMLIMIT")
    fi
    if [ -n "$RUNTIME_GOGC" ] && [ "$RUNTIME_GOGC" -gt 0 ] 2>/dev/null; then
        init_args+=(--gogc "$RUNTIME_GOGC")
    fi

    local output
    output=$("$TMP_DIR/ooctl" "${init_args[@]}") || {
        log_error "ooctl config init failed"
        exit 1
    }

    INSTANCE_ID=$(echo "$output" | grep '^INSTANCE_ID=' | cut -d= -f2-)
    HEALTH_PORT=$(echo "$output" | grep '^HEALTH_PORT=' | cut -d= -f2-)
    [[ "$HEALTH_PORT" =~ ^[0-9]+$ ]] || { log_error "Missing allocated health port; update ooctl"; exit 1; }
    chmod 600 "$TMP_DIR/credentials.env"
}

render_service() {
    cat >"$TMP_DIR/${SERVICE_NAME}" <<EOF_UNIT
[Unit]
Description=oo Node Backend
Documentation=https://node.xboardnext.com/oo/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_ROOT}
EnvironmentFile=-${CREDENTIALS_FILE}
Environment=GODEBUG=madvdontneed=1
ExecStart=${BINARY_PATH} -c ${CONFIG_FILE}
Restart=always
RestartSec=5
LimitNOFILE=1048576
NoNewPrivileges=true
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF_UNIT
}

backup_existing_state() {
    BACKUP_PATH="${BACKUP_DIR}/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_PATH"
    chmod 700 "$BACKUP_PATH"
    [ ! -f "$INSTALLER_COPY_PATH" ] || cp -p "$INSTALLER_COPY_PATH" "$BACKUP_PATH/installer"
    [ ! -f "$OO_PATH" ] || cp -p "$OO_PATH" "$BACKUP_PATH/launcher"
    if [ -x "$BINARY_PATH" ]; then
        cp "$BINARY_PATH" "$BACKUP_PATH/oo-node"
    fi
    if [ -x "$CLI_PATH" ]; then
        cp "$CLI_PATH" "$BACKUP_PATH/ooctl"
    fi
    if [ -f "$CONFIG_FILE" ]; then
        cp "$CONFIG_FILE" "$BACKUP_PATH/config.yml"
    fi
    if [ -f "$CREDENTIALS_FILE" ]; then
        cp "$CREDENTIALS_FILE" "$BACKUP_PATH/credentials.env"
    fi
    if [ -f "$INSTALL_META" ]; then
        cp "$INSTALL_META" "$BACKUP_PATH/install-meta.json"
    fi
    if [ -f "$SERVICE_PATH" ]; then
        cp "$SERVICE_PATH" "$BACKUP_PATH/${SERVICE_NAME}"
        SERVICE_EXISTED=1
    else
        SERVICE_EXISTED=0
    fi
}

stop_existing_service() {
    if [ -f "$SERVICE_PATH" ] || systemctl is-active "$SERVICE_NAME" >/dev/null 2>&1; then
        systemctl stop "$SERVICE_NAME"
    fi
}

prepare_legacy_service() {
    [ -f "$LEGACY_SERVICE_PATH" ] || {
        if systemctl is-active --quiet "$LEGACY_SERVICE_NAME"; then
            log_error "旧服务使用了非标准配置，停止自动迁移，请先检查服务路径"
            return 1
        fi
        return 0
    }
    if [ -e "$SERVICE_PATH" ] || [ -e "$BINARY_PATH" ] || [ -e "$CLI_PATH" ]; then
        log_error "检测到新旧两套安装，未停止任何服务；请先确认要保留哪套"
        return 1
    fi
    grep -Eq "^ExecStart=${LEGACY_BINARY_PATH}([[:space:]]|$)" "$LEGACY_SERVICE_PATH" || {
        log_error "旧服务不是标准安装，未自动迁移"; return 1;
    }
    if [ -n "$(systemctl show "$LEGACY_SERVICE_NAME" -p DropInPaths --value)" ]; then
        log_error "旧服务包含自定义覆盖配置，未自动迁移，请先检查"; return 1
    fi
    cp -p "$LEGACY_SERVICE_PATH" "$BACKUP_PATH/legacy.service"
    [ ! -f "$LEGACY_BINARY_PATH" ] || cp -p "$LEGACY_BINARY_PATH" "$BACKUP_PATH/legacy-core"
    [ ! -f "$LEGACY_CLI_PATH" ] || cp -p "$LEGACY_CLI_PATH" "$BACKUP_PATH/legacy-cli"
    systemctl is-active --quiet "$LEGACY_SERVICE_NAME" && LEGACY_WAS_ACTIVE=1
    systemctl is-enabled --quiet "$LEGACY_SERVICE_NAME" && LEGACY_WAS_ENABLED=1
    LEGACY_PREPARED=1
    log_step "迁移旧服务到 oo.service（配置、Token、证书保持不变）"
    systemctl stop "$LEGACY_SERVICE_NAME" || return 1
    if systemctl is-active --quiet "$LEGACY_SERVICE_NAME"; then
        log_error "旧服务尚未停止，禁止启动第二套服务"; return 1
    fi
    systemctl disable "$LEGACY_SERVICE_NAME"
}

rollback_legacy_service() {
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    [ ! -f "$BACKUP_PATH/legacy.service" ] || install -m 644 "$BACKUP_PATH/legacy.service" "$LEGACY_SERVICE_PATH"
    [ ! -f "$BACKUP_PATH/legacy-core" ] || install -m 755 "$BACKUP_PATH/legacy-core" "$LEGACY_BINARY_PATH"
    [ ! -f "$BACKUP_PATH/legacy-cli" ] || install -m 755 "$BACKUP_PATH/legacy-cli" "$LEGACY_CLI_PATH"
    systemctl daemon-reload
    if [ "$LEGACY_WAS_ENABLED" -eq 1 ]; then systemctl enable "$LEGACY_SERVICE_NAME"; fi
    if [ "$LEGACY_WAS_ACTIVE" -eq 1 ]; then systemctl start "$LEGACY_SERVICE_NAME"; fi
    log_warn "已回滚到升级前服务，原配置保留"
}

finish_legacy_service() {
    [ "$LEGACY_PREPARED" -eq 1 ] || return 0
    # Archive instead of deleting, and only after oo health checks pass.
    local path
    mkdir -p "$BACKUP_PATH/retired"
    for path in "$LEGACY_SERVICE_PATH" "$LEGACY_BINARY_PATH" "$LEGACY_CLI_PATH"; do
        [ ! -e "$path" ] || mv "$path" "$BACKUP_PATH/retired/$(basename "$path")"
    done
    if [ -L "$LEGACY_CLI_LINK" ] && [ "$(readlink "$LEGACY_CLI_LINK")" = "$LEGACY_CLI_PATH" ]; then
        mv "$LEGACY_CLI_LINK" "$BACKUP_PATH/retired/legacy-cli-link"
    fi
    systemctl daemon-reload
    LEGACY_PREPARED=0
    log_info "旧服务已归档，后续请使用 oo 或 oo.service"
}

install_staged_files() {
    INSTALL_MUTATED=1
    stop_existing_service
    install -m 755 "$TMP_DIR/oo-node" "$BINARY_PATH"
    install -m 600 "$TMP_DIR/config.yml" "$CONFIG_FILE"
    install -m 600 "$TMP_DIR/credentials.env" "$CREDENTIALS_FILE"
    install -m 644 "$TMP_DIR/install-meta.json" "$INSTALL_META"
    if [ -f "$0" ] && [ "$(realpath "$0")" != "$(realpath "$INSTALLER_COPY_PATH" 2>/dev/null || echo "$INSTALLER_COPY_PATH")" ]; then
        install -m 755 "$0" "$INSTALLER_COPY_PATH"
    fi
    install -m 755 "$TMP_DIR/ooctl" "$CLI_PATH"
    ln -sf "$CLI_PATH" /usr/bin/ooctl 2>/dev/null || true
    install_oo_launcher
    install -m 644 "$TMP_DIR/${SERVICE_NAME}" "$SERVICE_PATH"
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" > /dev/null 2>&1
}

install_oo_launcher() {
    cat >"$OO_PATH" <<'EOF_OO'
#!/usr/bin/env bash
set -Eeuo pipefail
installer="/etc/oo/install.sh"
if [ ! -x "$installer" ]; then
    echo "oo 管理脚本不存在，请重新运行安装命令。" >&2
    exit 1
fi
if [ "$#" -eq 0 ]; then
    exec "$installer" menu
fi
exec "$installer" "$@"
EOF_OO
    chmod 755 "$OO_PATH"
    ln -sf "$OO_PATH" "$OO_LINK_PATH" 2>/dev/null || true
}

wait_for_health() {
    if ! systemctl is-active "$SERVICE_NAME" >/dev/null 2>&1; then
        return 1
    fi
    if [ "$HEALTH_ENABLED" -eq 0 ]; then
        return 0
    fi
    local attempt=0
    local max_attempts=30
    while [ "$attempt" -lt "$max_attempts" ]; do
        if ! systemctl is-active "$SERVICE_NAME" >/dev/null 2>&1; then
            return 1
        fi
        if curl -fsS "http://127.0.0.1:${HEALTH_PORT}/healthz" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        attempt=$((attempt + 1))
    done
    return 1
}

show_recent_logs() {
    if command -v journalctl >/dev/null 2>&1; then
        journalctl -u "$SERVICE_NAME" -n 30 --no-pager || true
    fi
}

start_service() {
    if systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1; then
        systemctl restart "$SERVICE_NAME"
    else
        systemctl start "$SERVICE_NAME"
    fi
    if ! wait_for_health; then
        log_error "Service failed health check"
        show_recent_logs
        return 1
    fi
}

perform_install() {
    validate_install_request
    detect_current_state
    require_reconfigure_confirmation
    TMP_DIR=$(mktemp -d)
    ensure_dirs
    stage_binary
    stage_ooctl
    apply_runtime_defaults
    render_config
    render_service
    backup_existing_state
    prepare_legacy_service
    install_staged_files
    start_service
    finish_legacy_service
    INSTALL_MUTATED=0

    log_info "Installation succeeded"
    log_info "Service: ${SERVICE_NAME}"
    log_info "Config: ${CONFIG_FILE}"
    log_info "Credentials: ${CREDENTIALS_FILE}"
    if [ "$HEALTH_ENABLED" -eq 1 ]; then
        log_info "Health: http://127.0.0.1:${HEALTH_PORT}/healthz"
    fi
    log_info "CLI: ${CLI_PATH}  (run '${CLI_PATH} list' if ooctl is not in PATH)"
    check_google_connectivity
}

perform_upgrade() {
    load_health_port_from_config "$CONFIG_FILE"
    detect_current_state
    if [ "$CURRENT_STATE" = "fresh" ]; then
        log_warn "No existing install found; falling back to install"
        perform_install
        return
    fi
    TMP_DIR=$(mktemp -d)
    ensure_dirs
    stage_binary
    stage_ooctl
    render_service
    backup_existing_state
    prepare_legacy_service
    INSTALL_MUTATED=1
    stop_existing_service
    install -m 755 "$TMP_DIR/oo-node" "$BINARY_PATH"
    install -m 755 "$TMP_DIR/ooctl" "$CLI_PATH"
    ln -sf "$CLI_PATH" /usr/bin/ooctl 2>/dev/null || true
    if [ -f "$0" ] && [ "$(realpath "$0")" != "$(realpath "$INSTALLER_COPY_PATH" 2>/dev/null || echo "$INSTALLER_COPY_PATH")" ]; then
        install -m 755 "$0" "$INSTALLER_COPY_PATH"
    fi
    install_oo_launcher
    install -m 644 "$TMP_DIR/${SERVICE_NAME}" "$SERVICE_PATH"
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null
    systemctl restart "$SERVICE_NAME"
    if ! wait_for_health; then
        log_error "Upgrade health check failed"
        show_recent_logs
        return 1
    fi
    finish_legacy_service
    INSTALL_MUTATED=0
    log_info "Upgrade succeeded"
    check_google_connectivity
}

confirm_uninstall() {
    if [ "$YES" -eq 1 ]; then
        return
    fi
    echo
    read -r -p "Proceed with uninstall? [y/N]: " answer
    if ! [[ "$answer" =~ ^[Yy]$ ]]; then
        log_warn "Uninstall cancelled"
        exit 0
    fi
}

perform_uninstall() {
    [ -x "$CLI_PATH" ] || { log_error "未找到 ooctl；停止自动卸载，请先修复管理工具"; return 1; }
    "$CLI_PATH" config uninstall-features 2>/dev/null | grep -q safe-uninstall-v1 || { log_error "请先更新 ooctl，旧版本不支持安全卸载"; return 1; }
    local args=(uninstall)
    [ "$PURGE" -eq 1 ] && args+=(--purge)
    [ "$YES" -eq 1 ] && args+=(--yes)
    "$CLI_PATH" "${args[@]}"
}

read_tty() {
    local __name="$1" __prompt="$2" __secret="${3:-0}" value
    if [ "$__secret" -eq 1 ]; then
        read -r -s -p "$__prompt" value </dev/tty || return 1
        echo >/dev/tty
    else
        read -r -p "$__prompt" value </dev/tty || return 1
    fi
    printf -v "$__name" '%s' "$value"
}

menu_install() {
    local choice="" input=""
    echo
    echo "  1. 单节点模式"
    echo "  2. 机器模式"
    read_tty choice "请选择模式 [1]: "
    case "${choice:-1}" in
        1) MODE="node" ;;
        2) MODE="machine" ;;
        *) log_warn "输入无效"; return ;;
    esac
    read_tty PANEL_URL "面板地址: "
    read_tty TOKEN "通信密钥: " 1
    if [ "$MODE" = "machine" ]; then
        read_tty MACHINE_ID "机器 ID: "
        NODE_ID=""
    else
        read_tty NODE_ID "节点 ID: "
        MACHINE_ID=""
    fi
    read_tty input "内核 [1=自动, 2=sing-box, 3=Xray，默认1]: "
    case "${input:-1}" in
        1) KERNEL_TYPE="auto" ;;
        2) KERNEL_TYPE="singbox" ;;
        3) KERNEL_TYPE="xray" ;;
        *) log_warn "输入无效"; return ;;
    esac
    FORCE_RECONFIGURE=1
    perform_install
}

menu_node_services() {
    local _OO_SELECTED_INSTANCE="" _OO_MENU_LEAVE=0
    while [ "$_OO_MENU_LEAVE" -eq 0 ]; do
        menu_node_services_once || log_warn "操作未完成，已保留在节点管理菜单。"
    done
}

menu_node_services_once() {
    local instance="${_OO_SELECTED_INSTANCE:-}" action="" target="" confirm=""
    local rows="" line="" selected="" index=0
    local ids=()
    if [ -z "$instance" ]; then
    echo "本机节点连接地址（域名:外部端口 → 内部地址；配置记录，不代表实时可用）："
    "$CLI_PATH" nginx routes || log_warn "无法读取节点域名，请先更新管理程序"
    echo "以下网址为面板地址；一个机器实例可以包含多个节点："
    rows=$("$CLI_PATH" list) || rows=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        [[ "$line" =~ ^ID[[:space:]] ]] && continue
        ids+=("${line%%[[:space:]]*}")
        index=$((index + 1))
        printf '%s. %s\n' "$index" "$line"
    done <<< "$rows"
    echo "已删除的实例（在回收站恢复）："
    local deleted_rows="" recycle_key="" deleted_rest=""
    deleted_rows=$("$CLI_PATH" trash list) || return
    while read -r recycle_key deleted_rest; do
        [ -n "$recycle_key" ] || continue
        [[ "$recycle_key" == 回收站* ]] && continue
        printf '  %s\n' "$deleted_rest"
    done <<< "$deleted_rows"
    [ "$index" -gt 0 ] || { echo "没有正在配置的实例，请进入回收站恢复。"; _OO_MENU_LEAVE=1; return 0; }
    local all_index=$((index + 1)) backup="" node_rows="" node_id="" protocol="" port="" policy="" node_choice=""
    local node_ids=()
    echo "$all_index. 删除本机全部实例服务（保留面板数据）"
    read_tty selected "输入实例编号（1、2…，0返回主菜单）: " || { _OO_MENU_LEAVE=1; return; }
    [[ "$selected" =~ ^[0-9]{1,6}$ ]] || { log_warn "请输入列表编号"; return; }
    selected=$((10#$selected))
    if [ "$selected" -eq 0 ]; then _OO_MENU_LEAVE=1; return 0; fi
    if [ "$selected" -eq "$all_index" ]; then
        echo "将删除上面列出的全部本机实例绑定；保留面板记录及证书。"
        read_tty confirm "确认删除全部请输入 YES（其他输入取消）: "
        [[ "$confirm" =~ ^[Yy][Ee][Ss]$ ]] || { echo "已取消，未删除任何服务。"; return 0; }
        backup=$(mktemp -d /root/oo-bindings-backup.XXXXXX) || return
        chmod 700 "$backup"
        tar -czf "$backup/before.tgz" -C "$INSTALL_ROOT" . || return
        echo "备份位置：$backup/before.tgz"
        for instance in "${ids[@]}"; do
            "$CLI_PATH" bind remove "$instance" || { log_warn "删除失败，已停止后续删除，请检查当前列表"; return 1; }
        done
        echo "全部本机实例绑定已删除。"
        _OO_SELECTED_INSTANCE=""
        return 0
    fi
    [ "$selected" -ge 1 ] && [ "$selected" -le "$index" ] || return 0
    instance="${ids[$((selected - 1))]}"
    _OO_SELECTED_INSTANCE="$instance"
    fi
    local backup="" node_rows="" node_id="" protocol="" port="" policy="" node_choice=""
    local node_ids=()
    echo "已选择: $instance"
    echo "1. 查看子节点列表"
    echo "2. 刷新子节点列表"
    echo "3. 删除指定子节点服务"
    echo "4. 恢复指定子节点服务"
    echo "5. 返回机器列表"
    echo "6. 同步该机器的 Trojan 域名分流（新增节点后使用）"
    echo "7. 删除当前机器配置及全部子节点（移入回收站）"
    read_tty action "请选择: " || { _OO_MENU_LEAVE=1; return; }
    if [ "$action" = 7 ]; then
        echo "将删除本机实例：${instance}"
        echo "范围：该实例及其全部本机子节点配置；保留面板记录，其他实例不删除。"
        echo "配置移入回收站，可从主菜单 13 恢复。共享节点进程会重启，其他实例会短暂重连。"
        read_tty confirm "确认删除此实例请输入 YES（其他输入取消）: " || { _OO_MENU_LEAVE=1; return 0; }
        [[ "$confirm" =~ ^[Yy][Ee][Ss]$ ]] || { echo "已取消，未删除实例。"; return 0; }
        if "$CLI_PATH" bind remove "$instance"; then
            echo "实例 ${instance} 已删除并移入回收站，返回机器列表。"
            _OO_SELECTED_INSTANCE=""
        else
            log_warn "实例删除未完成，请查看错误；未继续删除其他实例。"
            return 1
        fi
        return 0
    fi
    if [ "$action" = 5 ]; then _OO_SELECTED_INSTANCE=""; return 0; fi
    if [ "$action" = 1 ]; then action=2; fi
    if [ "$action" = 6 ]; then
        "$CLI_PATH" nginx machine-sync --instance "$instance" || return
        read_tty confirm "确认同步并重启节点进程请输入 YES: "
        [[ "$confirm" =~ ^[Yy][Ee][Ss]$ ]] || { echo "已取消"; return 0; }
        "$CLI_PATH" nginx machine-sync --instance "$instance" --apply
        return
    fi
    case "$action" in 2|3|4) ;; *) log_warn "请输入 1–7"; return 0 ;; esac
    node_rows=$("$CLI_PATH" nodes list --instance "$instance") || return
    local sockets="" running_pid=""
    sockets=$(ss -H -lntup 2>/dev/null) || sockets=""
    running_pid=$(systemctl show "$SERVICE_NAME" -p MainPID --value 2>/dev/null) || running_pid=""
    echo "所有节点（停用保留面板；共享进程监听不等于该节点启动成功）："
    local node_domain="" external_port=""
    while read -r line node_id protocol port node_domain external_port policy; do
        [[ "$node_id" =~ ^[1-9][0-9]*$ ]] || continue
        node_ids+=("$node_id")
        if [[ "$policy" == deleted* ]]; then
            policy="已删除（本机配置已移出，可重新下发恢复）"
        elif [[ "$policy" == deleting* ]]; then
            policy="删除处理中（等待节点进程清理配置）"
        elif [[ "$policy" == disabled* ]]; then
            policy="已停用（保留面板，可恢复）"
        elif [ "$(printf '%s\n' "$node_rows" | awk -v p="$port" '$2 ~ /^[0-9]+$/ && $4==p {n++} END {print n+0}')" -gt 1 ]; then
            policy="端口重复，无法确认该节点运行状态"
        elif [[ "$port" =~ ^[0-9]+$ && "$running_pid" =~ ^[1-9][0-9]*$ ]] && printf '%s\n' "$sockets" | awk -v port="$port" -v pid="$running_pid" '$5 ~ (":" port "$") && index($0,"pid=" pid ",") {found=1} END {exit !found}'; then
            policy="检测到共享进程监听（未确认节点健康）"
        else
            policy="未确认运行（未检测到节点进程监听）"
        fi
        printf '%s. 节点ID：%s  协议：%s  域名：%s  对外端口：%s  内部端口：%s  %s\n' "${#node_ids[@]}" "$node_id" "$protocol" "$node_domain" "$external_port" "$port" "$policy"
    done <<< "$node_rows"
    [ "${#node_ids[@]}" -gt 0 ] || { log_warn "未获取到节点列表，未执行删除"; return 0; }
    [ "$action" != 2 ] || return 0
    read_tty node_choice "选择上面的节点编号（0返回）: "
    [[ "$node_choice" =~ ^[0-9]{1,6}$ ]] || return 0
    node_choice=$((10#$node_choice))
    [ "$node_choice" -ge 1 ] && [ "$node_choice" -le "${#node_ids[@]}" ] || return 0
    target="${node_ids[$((node_choice - 1))]}"
    if [ "$action" = 3 ]; then
        local delete_mode=""
        echo "1. 仅本机停用（保留面板数据，可恢复）"
        echo "2. 删除本机子节点配置（含已停用节点；保留面板记录）"
        echo "0. 取消"
        read_tty delete_mode "请选择删除方式: " || { _OO_MENU_LEAVE=1; return; }
        case "$delete_mode" in
            1) ;;
            2) ;;
            0) echo "已取消"; return 0 ;;
            *) log_warn "请输入 0、1 或 2"; return 0 ;;
        esac
    fi
    local args=(nodes)
    case "$action" in
        3) if [ "$delete_mode" = 2 ]; then args+=(purge); else args+=(delete); fi ;;
        4) args+=(restore) ;;
        *) return ;;
    esac
    args+=(--instance "$instance" --node-id "$target")
    echo "将操作子节点 ID：${target}（机器实例：${instance}；其他子节点不变）"
    read_tty confirm "仅改变本机服务，保留面板数据。确认操作请输入 YES: "
    [[ "$confirm" =~ ^[Yy][Ee][Ss]$ ]] || { echo "已取消，未修改节点。"; return 0; }
    if "$CLI_PATH" "${args[@]}" --yes; then
        if [ "$action" = 3 ]; then
            if [ "$delete_mode" = 2 ]; then
                echo "已提交子节点 ${target} 本机配置删除；节点进程停止该子节点后清理，刷新列表确认。面板记录保留，其他子节点不变。"
            else
                echo "节点 $target 已停用，保留本机配置；可继续选择删除本机配置。"
            fi
        else
            echo "节点 $target 已恢复，正在等待启动；可在列表中查看状态。"
        fi
    else
        log_warn "操作失败，未确认完成，请重新查看节点列表。"
        return 1
    fi
}

menu_recycle_bin() {
    local rows="" key="" rest="" choice="" confirm=""
    local keys=()
    rows=$("$CLI_PATH" trash list) || return
    echo "回收站："
    while read -r key rest; do
        [ -n "$key" ] || continue
        [[ "$key" == 回收站* ]] && continue
        keys+=("$key")
        printf '%s. %s\n' "${#keys[@]}" "$rest"
    done <<< "$rows"
    [ "${#keys[@]}" -gt 0 ] || { echo "回收站为空。"; return 0; }
    read_tty choice "输入要恢复的编号（0返回）: "
    [[ "$choice" =~ ^[0-9]{1,6}$ ]] || return 0
    choice=$((10#$choice))
    [ "$choice" -ge 1 ] && [ "$choice" -le "${#keys[@]}" ] || return 0
    read_tty confirm "恢复会检查端口和证书，并重启共享服务。确认输入 YES: "
    [[ "$confirm" =~ ^[Yy][Ee][Ss]$ ]] || { echo "已取消恢复。"; return 0; }
    "$CLI_PATH" trash restore "${keys[$((choice - 1))]}" --yes
}

show_oo_version() {
    if [ -x "$BINARY_PATH" ]; then "$BINARY_PATH" -v; else echo "节点程序：未安装"; fi
    echo "管理菜单版本：$MENU_VERSION"
}

check_google_connectivity() {
    local result="" rc=0 code="" elapsed="" message=""
    # Ignore proxy environment and curlrc: this checks direct server egress,
    # not an end user's authenticated proxy path. Never disable TLS checks.
    if result=$(curl -q --noproxy '*' --proto '=https' --proto-redir '=https' \
        --silent --location --max-redirs 3 --connect-timeout 5 --max-time 15 \
        --output /dev/null --write-out '%{http_code} %{time_total}' \
        https://www.google.com/ 2>/dev/null); then rc=0; else rc=$?; fi
    code="${result%% *}"
    elapsed="${result##* }"
    if [ "$rc" -eq 0 ] && [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
        message="[服务器直连 Google：成功] HTTP ${code}，耗时 ${elapsed} 秒；节点代理链路：未检测。"
    else
        case "$rc" in
            6) message="DNS 解析失败" ;;
            7) message="无法建立连接" ;;
            28) message="连接或响应超时（最多等待15秒）" ;;
            35|60) message="Google HTTPS/TLS 握手或证书校验失败（不是节点入站证书检测）" ;;
            0) message="收到 HTTP ${code:-未知}，未通过可用性检测" ;;
            *) message="请求失败，curl 错误码 $rc" ;;
        esac
        message="[服务器直连 Google：失败] ${message}；节点代理链路：未检测。此结果不触发卸载或回滚。"
    fi
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$message"
    logger -t oo-connectivity -- "$message" || true
    return 0
}

show_simple_logs() {
    local pid="" logs="" network=""
    echo "节点自身检查"
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo "服务：运行中"
    else
        echo "服务：未运行，请检查安装或启动失败原因"
    fi
    pid=$(systemctl show "$SERVICE_NAME" -p MainPID --value 2>/dev/null) || pid=""
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
        if logs=$(journalctl -u "$SERVICE_NAME" "_PID=$pid" --since '5 minutes ago' -n 1000 --no-pager -o cat 2>/dev/null); then
            printf '%s\n' "$logs" | awk '
            /connection: open connection|using outbound\/|outbound\/direct/ {next}
            /ws disconnected|bad handshake|machine ws handshake failed/ {ws=1}
            /ERROR|WARN|failed|Failed|skipped_not_running/ {
                if ($0 ~ /certificate|cert:|cert config|ACME|acme|x509|no TLS/) cert=1
                if ($0 ~ /address already in use|health_port.*used by|bind:.*in use/) port=1
                if ($0 ~ /machine nodes status 40[13]|auth failed|machine.token is required/) auth=1
                if ($0 ~ /skipped_not_running|no users, kernel|failed to start kernel/) start=1
                if ($0 ~ /abnormal user count drop/) sync=1
            }
            END {
                if (ws) print "面板 WSS：最近发生连接失败，请检查连接设置"
                if (cert) print "证书：最近发生申请或加载失败"
                if (port) print "监听端口：存在冲突"
                if (auth) print "面板鉴权：失败，请检查令牌和编号"
                if (start) print "节点入站：未能启动"
                if (sync) print "面板同步：用户数据更新被拒绝"
                if (!(ws || cert || port || auth || start || sync)) print "最近5分钟：未发现节点自身错误"
                print "说明：仅检查当前进程近期日志，不代表所有实例均已连通。"
            }'
        else
            echo "节点日志：无法读取，状态待确认"
        fi
    fi
    network=$(journalctl -t oo-connectivity -n 1 --no-pager -o cat 2>/dev/null) || network=""
    case "$network" in
        *'Google：成功'*) echo "Google直连：上次检测成功" ;;
        *'Google：失败'*) echo "Google直连：上次检测失败" ;;
        *) echo "Google直连：尚无检测结果" ;;
    esac
}

show_menu() {
    local choice="" input="" title_version="未安装"
    if [ -x "$BINARY_PATH" ]; then
        title_version=$("$BINARY_PATH" -v 2>/dev/null | sed -n 's/.*\(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p') || title_version="未知版本"
        title_version="${title_version:-未知版本}"
    fi
    while true; do
        clear 2>/dev/null || true
        echo -e "${CYAN}${BOLD}oo 节点后端管理 ${title_version}：${NC}"
        echo ""
        echo "  1. 新增实例 / 修改同一 ID（健康端口自动分配）"
        echo "  2. 更新程序"
        echo "  3. 查看状态"
        echo "  4. 启动服务"
        echo "  5. 停止服务"
        echo "  6. 重启服务"
        echo "  7. 查看日志（中文简洁 / 原始）"
        echo "  8. 更新 Trojan 伪装网站"
        echo "  9. 卸载程序"
        echo "  10. 查看 / 删除 / 恢复机器内节点服务"
        echo "  11. 查看版本"
        echo "  12. 退出"
        echo "  13. 回收站 / 恢复已删除服务"
        echo ""
        read_tty choice "请输入数字: "
        case "$choice" in
            1) menu_install; return ;;
            10) menu_node_services || log_warn "操作失败，未完成的操作请检查后重试" ;;
            11) show_oo_version ;;
            13) menu_recycle_bin || log_warn "恢复未完成，请检查上述原因" ;;
            2) perform_upgrade; return ;;
            3) perform_status ;;
            4) systemctl start "$SERVICE_NAME"; log_info "服务已启动" ;;
            5) systemctl stop "$SERVICE_NAME"; log_info "服务已停止" ;;
            6) systemctl restart "$SERVICE_NAME"; log_info "服务已重启" ;;
            7)
                echo "1. 节点自身检查（默认）  2. 原始日志  3. 重新检测 Google 直连"
                read_tty input "请选择: "
                case "${input:-1}" in
                    1) show_simple_logs ;;
                    2) journalctl -u "$SERVICE_NAME" -n 100 --no-pager ;;
                    3) check_google_connectivity ;;
                    *) log_warn "请输入 1 或 2" ;;
                esac
                ;;
            8)
                read_tty input "Trojan 域名: "
                if [ -z "$input" ]; then
                    log_warn "域名不能为空"
                elif [ ! -x "$CLI_PATH" ]; then
                    log_error "未找到 ooctl，请先选择 2 更新程序"
                else
                    "$CLI_PATH" nginx camouflage-site --domain "$input" --listen 127.0.0.1:8080 --template random --write --force --test --reload
                    log_info "伪装网站已重新生成"
                fi
                ;;
            9)
                echo "1. 卸载程序，保留配置和证书"
                echo "2. 彻底卸载，归档配置及确认属于 oo 的 Nginx 文件"
                read_tty input "请选择 [默认取消]: "
                case "$input" in
                    1) PURGE=0 ;;
                    2) PURGE=1 ;;
                    *) continue ;;
                esac
                perform_uninstall; return ;;
            12) return ;;
            *) log_warn "请输入 1-13" ;;
        esac
        echo
        read_tty input "按回车键返回菜单..."
    done
}

perform_status() {
    detect_current_state
    echo
    echo -e "${BOLD}${APP_NAME} install status${NC}"
    echo "  state:   ${CURRENT_STATE}"
    if [ -f "$INSTALL_META" ]; then
        echo "  meta:    ${INSTALL_META}"
        if [ -x "$CLI_PATH" ]; then
            "$CLI_PATH" list 2>/dev/null || true
        else
            # Simple key extraction from JSON (no Python needed)
            local val
            for key in config_mode version latest_instance_id instance_count updated_at; do
                val=$(sed -n "s/.*\"${key}\": *\"\{0,1\}\([^\"]*\)\"\{0,1\}.*/\1/p" "$INSTALL_META" | head -1)
                val="${val%,}"  # strip trailing comma from numeric JSON values
                [ -n "$val" ] && echo "  ${key}: ${val}"
            done
        fi
    fi
    if [ -f "$SERVICE_PATH" ]; then
        echo "  service: ${SERVICE_NAME}"
        systemctl status "$SERVICE_NAME" --no-pager || true
    fi
}

main() {
    case "${1:-}" in
        version|--version|-v) show_oo_version; return ;;
        check-network) check_google_connectivity; return ;;
        nodes|list|instance|trash|nginx|start|stop|restart|logs|log|service|health)
            [ -x "$CLI_PATH" ] || { log_error "请先安装或更新 oo"; return 1; }
            exec "$CLI_PATH" "$@" ;;
    esac
    parse_args "$@"
    if [ "$ACTION" = uninstall ]; then
        check_root
        perform_uninstall
        return
    fi
    case "$ACTION" in
        help)
            usage
            exit 0
            ;;
        status)
            ensure_systemd
            perform_status
            exit 0
            ;;
    esac

    check_root
    detect_arch
    detect_os
    ensure_systemd
    install_dependencies
    migrate_legacy_install_root

    case "$ACTION" in
        menu)
            show_menu
            ;;
        install)
            perform_install
            ;;
        upgrade)
            perform_upgrade
            ;;
        uninstall)
            perform_uninstall
            ;;
        *)
            log_error "Unknown action: $ACTION"
            usage
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then main "$@"; fi
