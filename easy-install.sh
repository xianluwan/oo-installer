#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="oo"
REPO="xboardnext999/oo"
DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://github.com/xianluwan/oo-installer/releases/download/v1.0.0}"
INSTALL_ROOT="/etc/oo"
CONFIG_FILE="${INSTALL_ROOT}/config.yml"
CREDENTIALS_FILE="${INSTALL_ROOT}/credentials.env"
META_FILE="${INSTALL_ROOT}/install-meta.json"
BINARY_PATH="/usr/local/bin/oo-node"
CLI_PATH="/usr/local/bin/ooctl"
OO_PATH="/usr/local/bin/oo"
INSTALLER_COPY_PATH="${INSTALL_ROOT}/install.sh"
SERVICE_NAME="oo.service"
# Read-only recognition of pre-rename Nginx assets; never duplicate their ports.
LEGACY_SNI_GLOB='/etc/nginx/stream.d/xboard-node-trojan-sni*.conf'
LEGACY_CAMOUFLAGE_CONF='/etc/nginx/conf.d/xboard-node-camouflage.conf'
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"

MODE="machine"
PANEL_URL=""
TOKEN=""
MACHINE_ID=""
RELAY_NODES=""
NODE_ID=""
NODE_TYPE=""
DOMAIN=""
VERSION="latest"
KERNEL="auto"
HEALTH_PORT="auto"
RUNTIME_GOMEMLIMIT="${OO_NODE_GOMEMLIMIT:-}"
RUNTIME_GOGC="${OO_NODE_GOGC:-}"
TEMPLATE="random"
FALLBACK_TARGET="127.0.0.1:8080"
TROJAN_UPSTREAM="127.0.0.1:10443"
TROJAN_UPSTREAM_EXPLICIT=0
WEB_UPSTREAM="127.0.0.1:8443"
LISTEN_PORT="443"
ACME_HTTP_PORT="18080"
ACME_HTTP_PORT_EXPLICIT=0
CERT_WAIT_SECONDS="180"
SKIP_NGINX=0
RESUME_NGINX=0
REPAIR_NGINX=0
TARGET_INSTANCE=""
TARGET_MODE=""
REPLACE_INSTANCE=""
QUIET=0

log() { printf '[%s] %s\n' "$1" "$2"; }
die() { log ERROR "$1" >&2; exit 1; }
run_visible() {
    if [ "$QUIET" -eq 1 ]; then
        "$@" >/dev/null 2>&1
    else
        "$@"
    fi
}

service_unit_exists() {
    [ -f "$SERVICE_PATH" ] && return 0
    systemctl cat "$SERVICE_NAME" >/dev/null 2>&1
}

usage() {
    cat <<'HELP'
oo easy installer

Usage:
  sudo bash easy-install.sh --panel URL --token TOKEN --machine-id ID --domain DOMAIN

Options:
  --mode machine|node          Install mode (default: machine)
  --panel URL                  Panel URL
  --token TOKEN                Machine or node token
  --machine-id ID              Machine ID for machine mode
  --relay-nodes IDS            Confirmed relay entries, e.g. 403,404; skip local listeners, keep panel records
  --node-id ID                 Node ID for node mode
  --node-type TYPE             Optional node type for node mode
  --domain DOMAIN              Public Trojan SNI / camouflage domain
  --version VERSION            Release version or latest (default: latest)
  --kernel auto|singbox|xray   Kernel type (default: auto)
  --health-port PORT           Health port, auto selects a free port; 0 disables (default: auto)
  --gomemlimit VALUE           Runtime GOMEMLIMIT value (default: auto by host memory)
  --gogc VALUE                 Runtime GOGC percent (default: 75)
  --template NAME              Camouflage template: random, cloud, studio, docs, commerce, status
  --fallback-target HOST:PORT  Local camouflage HTTP target (default: 127.0.0.1:8080)
  --trojan-upstream HOST:PORT  Local Trojan TLS inbound (default: 127.0.0.1:10443)
  --listen-port PORT          External shared SNI port (default: 443)
  --web-upstream HOST:PORT     Local HTTPS upstream for unmatched SNI (default: 127.0.0.1:8443)
  --acme-http-port PORT        Local HTTP-01 renewal port behind nginx (default: 18080)
  --cert-wait SECONDS          Wait for Trojan TLS certificate (default: 180)
  --skip-nginx                 Install node only, skip nginx camouflage/SNI setup
  --resume-nginx               Finish nginx setup for an existing /etc/oo install; no reinstall or token required
  --repair-nginx               Repair missing nginx base configuration only; keep oo bindings and certificates
  --instance ID                Existing instance for --resume-nginx (required when multiple instances exist)
  --replace-instance ID        Replace only this mistaken binding (backs up existing configuration)
  --quiet                      Hide package manager and service command output
  --help                       Show help

Example:
  curl -fL https://node.xboardnext.com/oo/dev/easy-install.sh | sudo bash -s -- \
    --panel https://www.baiyunfast.com \
    --token YOUR_TOKEN \
    --machine-id 12 \
    --domain sg3.oone.us
HELP
}

while [ $# -gt 0 ]; do
    case "$1" in
        --mode) MODE="$2"; shift 2 ;;
        --panel|-a) PANEL_URL="$2"; shift 2 ;;
        --token|-t) TOKEN="$2"; shift 2 ;;
        --machine-id) MACHINE_ID="$2"; shift 2 ;;
        --relay-nodes) RELAY_NODES="$2"; shift 2 ;;
        --node-id|-n) NODE_ID="$2"; shift 2 ;;
        --node-type|-T) NODE_TYPE="$2"; shift 2 ;;
        --domain) DOMAIN="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --kernel|-k) KERNEL="$2"; shift 2 ;;
        --health-port) HEALTH_PORT="$2"; shift 2 ;;
        --gomemlimit) RUNTIME_GOMEMLIMIT="$2"; shift 2 ;;
        --gogc) RUNTIME_GOGC="$2"; shift 2 ;;
        --template) TEMPLATE="$2"; shift 2 ;;
        --fallback-target) FALLBACK_TARGET="$2"; shift 2 ;;
        --trojan-upstream) TROJAN_UPSTREAM="$2"; TROJAN_UPSTREAM_EXPLICIT=1; shift 2 ;;
        --web-upstream) WEB_UPSTREAM="$2"; shift 2 ;;
        --listen-port) LISTEN_PORT="$2"; shift 2 ;;
        --acme-http-port) ACME_HTTP_PORT="$2"; ACME_HTTP_PORT_EXPLICIT=1; shift 2 ;;
        --cert-wait) CERT_WAIT_SECONDS="$2"; shift 2 ;;
        --skip-nginx) SKIP_NGINX=1; shift ;;
        --resume-nginx) RESUME_NGINX=1; shift ;;
        --repair-nginx) REPAIR_NGINX=1; shift ;;
        --instance) TARGET_INSTANCE="$2"; shift 2 ;;
        --replace-instance) REPLACE_INSTANCE="$2"; shift 2 ;;
        --quiet) QUIET=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "Please run with sudo or as root"
if [ "$RESUME_NGINX" -eq 0 ] && [ "$REPAIR_NGINX" -eq 0 ]; then
[ -n "$PANEL_URL" ] || die "--panel is required"
[ -n "$TOKEN" ] || die "--token is required"

case "$MODE" in
    machine)
        [ -n "$MACHINE_ID" ] || die "--machine-id is required in machine mode"
        ;;
    node)
        [ -n "$NODE_ID" ] || die "--node-id is required in node mode"
        ;;
    *)
        die "--mode must be machine or node"
        ;;
esac
else
    [ "$SKIP_NGINX" -eq 0 ] || die "--resume-nginx cannot be combined with --skip-nginx"
    [ -z "$PANEL_URL$TOKEN$MACHINE_ID$NODE_ID" ] || die "--resume-nginx uses existing bindings; do not pass panel, token or IDs"
fi

if [ "$SKIP_NGINX" -eq 0 ] && [ "$REPAIR_NGINX" -eq 0 ]; then
    [ -n "$DOMAIN" ] || die "--domain is required unless --skip-nginx is used"
    [[ "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || die "--domain must be a hostname, without URL scheme or spaces"
fi

validate_port() {
    local name="$1"
    local value="$2"
    case "$value" in
        ''|*[!0-9]*) die "${name} must be a numeric port" ;;
    esac
    [ "$value" -ge 1 ] && [ "$value" -le 65535 ] || die "${name} must be between 1 and 65535"
}

if [ "$SKIP_NGINX" -eq 0 ]; then
    validate_port "--acme-http-port" "$ACME_HTTP_PORT"
    validate_port "--listen-port" "$LISTEN_PORT"
    LISTEN_PORT=$((10#$LISTEN_PORT))
    if [ "$REPAIR_NGINX" -eq 0 ]; then
        [ "$LISTEN_PORT" != "${TROJAN_UPSTREAM##*:}" ] || die "外部端口不能与 Trojan 内部服务端口相同"
        [ "$LISTEN_PORT" != "${WEB_UPSTREAM##*:}" ] || die "外部端口与 HTTPS 回落端口冲突，请设置不同的 --web-upstream"
        [ "$LISTEN_PORT" != 80 ] || die "80 端口保留给 HTTP-01 证书验证"
    fi
    if [ "$MODE" = node ] && [ "$REPAIR_NGINX" -eq 0 ] && { compgen -G '/etc/nginx/stream.d/oo-node-trojan-sni*.conf' >/dev/null || compgen -G "$LEGACY_SNI_GLOB" >/dev/null; }; then
        [ "$TROJAN_UPSTREAM_EXPLICIT" -eq 1 ] && [ "$ACME_HTTP_PORT_EXPLICIT" -eq 1 ] || die "已有 SNI 服务：请明确指定 --trojan-upstream 和 --acme-http-port，避免沿用其他服务的端口"
    fi
fi

detect_total_mem_mib() {
    if [ -r /proc/meminfo ]; then
        awk '/MemTotal:/ { printf "%d\n", $2 / 1024 }' /proc/meminfo
        return
    fi
    echo 0
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
        ''|*[!0-9]*) die "--gogc must be a positive integer" ;;
    esac
    [ "$RUNTIME_GOGC" -gt 0 ] || die "--gogc must be a positive integer"
    log INFO "Runtime memory tuning: GOMEMLIMIT=${RUNTIME_GOMEMLIMIT}, GOGC=${RUNTIME_GOGC}"
}

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) die "Unsupported architecture: $ARCH" ;;
esac

ASSET_BASE="${DOWNLOAD_BASE}"

TMP_DIR="$(mktemp -d)"
NGINX_STOPPED_BY_INSTALLER=0
cleanup_installer() {
    local result=$?
    trap - EXIT
    if [ "$NGINX_STOPPED_BY_INSTALLER" -eq 1 ]; then
        if nginx -t; then
            systemctl start nginx || log WARN "未能恢复 Nginx，请检查服务状态"
        else
            log WARN "Nginx 配置检查失败，未强行启动；请恢复安装前备份"
        fi
    fi
    rm -rf "$TMP_DIR"
    exit "$result"
}
trap cleanup_installer EXIT

download_asset() {
    local name="$1"
    local dest="$2"
    log STEP "Downloading ${name}"
    curl -fL --retry 5 --retry-delay 2 -o "$dest" "${ASSET_BASE}/${name}"
    chmod +x "$dest"
}

install_packages() {
    # Repair missing conffiles before ordinary apt configuration hooks run.
    if [ "$SKIP_NGINX" -eq 0 ] && command -v nginx >/dev/null 2>&1; then
        ensure_nginx_base
    fi
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        log STEP "Updating apt package index"
        run_visible apt-get update
        log STEP "Installing packages: ca-certificates curl nginx libnginx-mod-stream openssl dnsutils"
        run_visible apt-get install -y ca-certificates curl nginx libnginx-mod-stream openssl dnsutils
    else
        log WARN "apt-get not found; please install curl, nginx, nginx stream module and dig manually"
    fi
}

valid_ipv4_lines() {
    awk '{ip=$1; n=split(ip,a,"."); ok=(n==4); for(i=1;i<=n;i++) if(a[i]!~/^[0-9]+$/ || a[i]>255) ok=0; if(ok) print ip}' | sort -u
}

refresh_local_dns_cache() {
    # Best effort only: never restart network services or rewrite resolv.conf/hosts.
    command -v timeout >/dev/null 2>&1 || return 0
    if command -v resolvectl >/dev/null 2>&1; then
        if timeout 3 resolvectl flush-caches >/dev/null 2>&1; then
            log INFO "Flushed systemd-resolved local DNS cache"
        fi
    fi
    if command -v nscd >/dev/null 2>&1; then
        if timeout 3 nscd -i hosts >/dev/null 2>&1; then
            log INFO "Invalidated nscd hosts cache"
        fi
    fi
}

resolve_domain_ipv4() {
    local local_ips="" public_ips="" reply status answers resolver negatives=0
    if command -v getent >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
        local_ips="$(timeout 4 getent ahostsv4 "$DOMAIN" 2>/dev/null | valid_ipv4_lines || true)"
    fi
    # Query both public resolvers on every attempt, including when local DNS
    # returns an old positive answer. Their upstream caches cannot be flushed here.
    if command -v dig >/dev/null 2>&1; then
        for resolver in 1.1.1.1 8.8.8.8; do
            reply="$(dig @"$resolver" "$DOMAIN" A +time=2 +tries=1 +noall +comments +answer 2>/dev/null || true)"
            status="$(printf '%s\n' "$reply" | sed -n 's/.*status: \([A-Z]*\),.*/\1/p' | head -n 1)"
            answers="$(printf '%s\n' "$reply" | awk '$4=="A" {print $5}' | valid_ipv4_lines)"
            if [ "$status" = "NOERROR" ] && [ -n "$answers" ]; then
                public_ips="${public_ips}${answers}
"
            elif [ "$status" = "NXDOMAIN" ] || { [ "$status" = "NOERROR" ] && [ -z "$answers" ]; }; then
                negatives=$((negatives + 1))
            fi
        done
    fi
    public_ips="$(printf '%s' "$public_ips" | valid_ipv4_lines)"
    if [ -n "$public_ips" ]; then
        if [ "$public_ips" != "$local_ips" ] || [ "$negatives" -gt 0 ]; then
            log WARN "DNS answers differ or local DNS is stale; using public A records for this check. DNS propagation may still be in progress." >&2
        fi
        printf '%s\n' "$public_ips"
        return 0
    fi
    if [ "$negatives" -gt 0 ] && [ -n "$local_ips" ]; then
        log WARN "Local and public DNS disagree; waiting before continuing" >&2
        return 3
    fi
    if [ "$negatives" -eq 2 ]; then return 2; fi
    if [ -n "$local_ips" ] && [ "$negatives" -eq 0 ]; then
        log WARN "Public DNS unavailable; using the freshly queried local resolver" >&2
        printf '%s\n' "$local_ips"
        return 0
    fi
    return 3
}

is_reserved_ipv4() {
    local ip="$1"
    local a b c d
    IFS=. read -r a b c d <<EOF_IP
${ip}
EOF_IP
    case "$ip" in
        0.*|10.*|127.*|169.254.*|192.168.*|192.0.2.*|198.51.100.*|203.0.113.*|255.*)
            return 0
            ;;
    esac
    if [ "$a" = "100" ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ]; then
        return 0
    fi
    if [ "$a" = "172" ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ]; then
        return 0
    fi
    if [ "$a" = "198" ] && { [ "$b" = "18" ] || [ "$b" = "19" ]; }; then
        return 0
    fi
    if [ "$a" -ge 224 ]; then
        return 0
    fi
    return 1
}

preflight_domain_dns() {
    [ "$SKIP_NGINX" -eq 0 ] || return 0
    log STEP "Checking DNS for ${DOMAIN}"

    local ips="" public_ip ip attempt rc=3
    refresh_local_dns_cache
    for attempt in 1 2 3; do
        if ips="$(resolve_domain_ipv4)"; then rc=0; break; else rc=$?; fi
        if [ "$attempt" -lt 3 ]; then
            log WARN "DNS check not ready (${attempt}/3); retrying in 2 seconds"
            sleep 2
        fi
    done
    if [ "$rc" -eq 2 ]; then
        die "Public DNS currently returns no IPv4 A record for ${DOMAIN}. Check the A record and allow upstream negative-cache TTL to expire; reinstalling does not clear public DNS caches."
    fi
    [ "$rc" -eq 0 ] && [ -n "$ips" ] || die "DNS lookup failed or resolvers disagree for ${DOMAIN}; this does not prove the A record is missing. Check DNS connectivity and propagation, then retry."
    log INFO "DNS A records: $(printf '%s' "$ips" | paste -sd, -)"

    while IFS= read -r ip; do
        [ -n "$ip" ] || continue
        if is_reserved_ipv4 "$ip"; then
            die "Domain ${DOMAIN} resolves to non-public IP ${ip}. Point the A record to this node's public IP before installing."
        fi
    done <<EOF_IPS
${ips}
EOF_IPS

    public_ip="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    if [ -n "$public_ip" ] && ! printf '%s\n' "$ips" | grep -Fxq "$public_ip"; then
        log WARN "Domain ${DOMAIN} resolves to $(printf '%s' "$ips" | paste -sd, -), but this server's detected public IP is ${public_ip}. Certificate issuance may fail if DNS is not pointing here."
    fi
}

stop_nginx_for_acme() {
    [ "$SKIP_NGINX" -eq 0 ] || return 0
    # Machine mode configures per-node HTTP challenge proxies with nginx running.
    [ "$MODE" != machine ] || return 0
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet nginx; then NGINX_STOPPED_BY_INSTALLER=1; fi
        log STEP "Stopping nginx before certificate issuance"
        run_visible systemctl stop nginx || log WARN "nginx stop failed or nginx is not running; continuing"
    fi
}

nginx_base_state() {
    python3 - "${1:-/etc/nginx/nginx.conf}" <<'PY_NGINX_STATE'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
if p.is_symlink():
    print('custom'); sys.exit()
if not p.exists():
    print('missing'); sys.exit()
text = re.sub(r'#[^\n]*', '', p.read_text())
stub = r'\s*(?:stream\s*\{\s*include\s+/etc/nginx/stream\.d/\*\.conf\s*;\s*\}\s*)?'
print('stub' if re.fullmatch(stub, text) else 'custom')
PY_NGINX_STATE
}

ensure_nginx_base() {
    [ "$SKIP_NGINX" -eq 0 ] || return 0
    local state backup dump build
    command -v python3 >/dev/null || die "修复 Nginx 配置需要 python3"
    state=$(nginx_base_state)
    if [ "$state" = missing ] || [ "$state" = stub ]; then
        export DEBIAN_FRONTEND=noninteractive
        command -v apt-get >/dev/null || die "Nginx 主配置缺失；非 Debian 系统请先恢复发行版配置，未修改 oo"
        backup=$(mktemp -d /root/oo-nginx-base.XXXXXX)
        chmod 700 "$backup"
        [ ! -d /etc/nginx ] || cp -a /etc/nginx "$backup/nginx"
        log INFO "Nginx 配置备份：$backup（保留 oo 配置和证书）"
        [ "$state" != stub ] || mv /etc/nginx/nginx.conf "$backup/nginx.conf.incomplete"
        log STEP "恢复 Nginx 基础配置及 stream 模块；软件包操作可能启停 Nginx"
        run_visible apt-get update || return 1
        run_visible apt-get -o Dpkg::Options::=--force-confmiss install --reinstall -y nginx nginx-common libnginx-mod-stream || return 1
    fi
    # Never replace an arbitrary existing nginx.conf or guess its include layout.
    build=$(nginx -V 2>&1) || return 1
    if [[ "$build" == *--with-stream=dynamic* ]]; then
        dump=$(nginx -T 2>&1) || true
        if ! grep -qE '^[[:space:]]*load_module[[:space:]]+[^;]*ngx_stream_module\.so' <<< "$dump"; then
            [ -f /usr/lib/nginx/modules/ngx_stream_module.so ] || die "stream 模块缺失，请安装与当前 Nginx 版本匹配的模块"
            grep -qE '^[[:space:]]*include[[:space:]]+/etc/nginx/modules-enabled/\*\.conf;' /etc/nginx/nginx.conf || die "自定义主配置缺少模块加载入口；为避免覆盖站点，请人工检查"
            mkdir -p /etc/nginx/modules-enabled
            [ ! -e /etc/nginx/modules-enabled/50-oo-stream.conf ] && [ ! -L /etc/nginx/modules-enabled/50-oo-stream.conf ] || die "已有 oo stream 加载文件，请检查其内容及加载顺序"
            printf '%s\n' 'load_module /usr/lib/nginx/modules/ngx_stream_module.so;' > /etc/nginx/modules-enabled/50-oo-stream.conf
        fi
    elif [[ " $build " != *" --with-stream "* ]]; then
        die "当前 Nginx 不支持 stream，请安装支持 TCP 转发的版本"
    fi
    nginx -t || die "Nginx 配置检查未通过，未继续安装或改动 oo 绑定；请检查上面的具体错误"
}

ensure_nginx_stream_include() {
    [ "$SKIP_NGINX" -eq 0 ] || return 0
    [ -s /etc/nginx/nginx.conf ] || die "Nginx 主配置缺失，拒绝创建只有 stream 的配置文件"
    mkdir -p /etc/nginx/stream.d
    local dump
    dump=$(nginx -T 2>&1) || { printf '%s\n' "$dump" >&2; die "Nginx 配置检查失败，未停止服务"; }
    if grep -qE '^[[:space:]]*include[[:space:]]+/etc/nginx/stream\.d/\*\.conf[[:space:]]*;' <<< "$dump"; then
        return 0
    fi
    if grep -qE '^[[:space:]]*stream[[:space:]]*\{' /etc/nginx/nginx.conf 2>/dev/null; then
        die "已有自定义 stream 块但未发现 /etc/nginx/stream.d/*.conf 加载入口；未覆盖，请先补齐入口"
    fi
    cat >> /etc/nginx/nginx.conf <<'EOF_NGINX_STREAM'

stream {
    include /etc/nginx/stream.d/*.conf;
}
EOF_NGINX_STREAM
}

write_service() {
    cat > "$SERVICE_PATH" <<EOF_SERVICE
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
EOF_SERVICE
}

render_config() {
    "$TMP_DIR/ooctl" config install-features 2>/dev/null | grep -q 'safe-reinstall-v1' || die "This installer requires a newer ooctl for safe reinstall; use --version latest"
    local args=(
        config init
        --mode "$MODE"
        --panel-url "$PANEL_URL"
        --kernel "$KERNEL"
        --health-port "$HEALTH_PORT"
        --token "$TOKEN"
        --version "$VERSION"
        --output "$TMP_DIR/config.yml"
        --credentials-out "$TMP_DIR/credentials.env"
        --meta "$TMP_DIR/install-meta.json"
        --install-root "$INSTALL_ROOT"
        --verify-panel true
    )

    [ -f "$CONFIG_FILE" ] && args+=(--config "$CONFIG_FILE")
    [ -f "$CREDENTIALS_FILE" ] && args+=(--credentials-in "$CREDENTIALS_FILE")
    [ -n "$REPLACE_INSTANCE" ] && args+=(--replace-instance "$REPLACE_INSTANCE")

    if [ "$MODE" = "machine" ]; then
        args+=(--machine-id "$MACHINE_ID")
    else
        args+=(--node-id "$NODE_ID")
        [ -n "$NODE_TYPE" ] && args+=(--node-type "$NODE_TYPE")
    fi
    if [ -n "$RUNTIME_GOMEMLIMIT" ]; then
        args+=(--gomemlimit "$RUNTIME_GOMEMLIMIT")
    fi
    if [ -n "$RUNTIME_GOGC" ] && [ "$RUNTIME_GOGC" -gt 0 ] 2>/dev/null; then
        args+=(--gogc "$RUNTIME_GOGC")
    fi

    local output
    output=$("$TMP_DIR/ooctl" "${args[@]}") || return 1
    printf '%s\n' "$output"
    HEALTH_PORT=$(printf '%s\n' "$output" | grep '^HEALTH_PORT=' | cut -d= -f2-)
    [[ "$HEALTH_PORT" =~ ^[0-9]+$ ]] || die "Missing allocated health port; update ooctl"
}

install_node() {
    download_asset "oo-node-linux-${ARCH}" "$TMP_DIR/oo-node"
    download_asset "ooctl-linux-${ARCH}" "$TMP_DIR/ooctl"
    curl -fL "https://raw.githubusercontent.com/xianluwan/oo-installer/main/install.sh" -o "$TMP_DIR/install.sh"
chmod +x "$TMP_DIR/install.sh"
    # Use the same transaction/legacy-service migration for both installers.
    local args=(install --mode "$MODE" --panel "$PANEL_URL" --token "$TOKEN"
        --kernel "$KERNEL" --version "$VERSION" --health-port "$HEALTH_PORT"
        --binary "$TMP_DIR/oo-node" --ooctl-binary "$TMP_DIR/ooctl"
        --gomemlimit "$RUNTIME_GOMEMLIMIT" --gogc "$RUNTIME_GOGC")
    if [ "$MODE" = machine ]; then args+=(--machine-id "$MACHINE_ID");
    else args+=(--node-id "$NODE_ID"); [ -z "$NODE_TYPE" ] || args+=(--node-type "$NODE_TYPE"); fi
    [ -z "$REPLACE_INSTANCE" ] || args+=(--replace-instance "$REPLACE_INSTANCE")
    bash "$TMP_DIR/install.sh" "${args[@]}"
    HEALTH_PORT=$("$CLI_PATH" config health-port --config "$CONFIG_FILE")
}

show_recent_cert_logs() {
    journalctl -u "$SERVICE_NAME" -n 80 --no-pager 2>/dev/null \
        | grep -Ei 'acme|cert|certificate|challenge|obtain|error|failed|unauthorized|success|served key|validations|finalizing' \
        | tail -12 || true
}

panel_auth_failure_seen() {
    local since_ts="$1"
    journalctl -u "$SERVICE_NAME" --since "@${since_ts}" --no-pager 2>/dev/null \
        | grep -Eqi 'machine nodes status 40[13]|initial node discovery:.*status 40[13]|machine instance exited with error.*status 40[13]'
}

wait_for_trojan_certificate() {
    [ "$SKIP_NGINX" -eq 0 ] || return 0
    [ "$TARGET_MODE" != machine ] || return 0
    [ "${CERT_WAIT_SECONDS}" != "0" ] || return 0
    command -v openssl >/dev/null 2>&1 || {
        log WARN "openssl not found; skip Trojan certificate probe"
        return 0
    }

    local host="${TROJAN_UPSTREAM%:*}"
    local port="${TROJAN_UPSTREAM##*:}"
    local start now elapsed last_log
    start="$(date +%s)"
    last_log="$start"
    log STEP "Waiting for Trojan TLS certificate on ${host}:${port} (SNI: ${DOMAIN})"
    while true; do
        if timeout 8 openssl s_client -connect "${host}:${port}" -servername "$DOMAIN" -brief </dev/null 2>&1 | grep -q "Verification: OK"; then
            log INFO "Trojan TLS certificate is ready"
            return 0
        fi
        now="$(date +%s)"
        elapsed=$((now - start))
        if journalctl -u "$SERVICE_NAME" --since "@${start}" --no-pager 2>/dev/null | grep -q 'startup layout validation failed'; then
            die "Node configuration conflict; this is not a TLS certificate failure. Check instance bindings and health ports before retrying."
        fi
        if panel_auth_failure_seen "$start"; then
            log ERROR "Panel rejected the machine credentials. Recent logs:"
            show_recent_cert_logs
            die "Panel returned 401/403 for machine node discovery. Check --panel, --machine-id, and --token, then rerun the installer."
        fi
        if [ $((now - last_log)) -ge 15 ]; then
            log INFO "Still waiting for certificate (${elapsed}s/${CERT_WAIT_SECONDS}s). Recent cert logs:"
            show_recent_cert_logs
            last_log="$now"
        fi
        if [ "$elapsed" -ge "$CERT_WAIT_SECONDS" ]; then
            log ERROR "Recent cert logs before timeout:"
            show_recent_cert_logs
            die "Timed out waiting for Trojan TLS certificate. Check DNS, firewall 80/443, and panel node domain."
        fi
        sleep 5
    done
}

select_nginx_instance() {
    if [ -z "$TARGET_INSTANCE" ]; then
        TARGET_INSTANCE=$(python3 - "$META_FILE" "$RESUME_NGINX" <<'PY_SELECT_INSTANCE'
import json, sys
with open(sys.argv[1]) as f: meta = json.load(f)
items = meta.get('instances', [])
if sys.argv[2] == '0':
    selected = meta.get('latest_instance_id', '')
    if not selected: raise SystemExit('无法确定本次安装实例')
    print(selected)
elif len(items) == 1:
    print(items[0]['id'])
else:
    raise SystemExit('存在多套实例：请使用 --instance 指定实例，使用 oo list 查看编号')
PY_SELECT_INSTANCE
        ) || die "未修改实例配置，请明确指定 --instance"
    fi
    TARGET_MODE=$(python3 - "$META_FILE" "$TARGET_INSTANCE" <<'PY_INSTANCE_MODE'
import json, sys
with open(sys.argv[1]) as f: items = json.load(f).get('instances', [])
matches = [x for x in items if x['id'] == sys.argv[2]]
if len(matches) != 1: raise SystemExit('找不到指定实例')
print(matches[0]['mode'])
PY_INSTANCE_MODE
    ) || die "无法确定实例模式"
}

set_local_acme_http_port() {
    [ "$SKIP_NGINX" -eq 0 ] || return 0
    [ "$TARGET_MODE" != machine ] || return 0
    log STEP "只更新实例 ${TARGET_INSTANCE} 的回落和证书续期端口"
    "$CLI_PATH" config trojan-fallback --config "$CONFIG_FILE" \
        --instance "$TARGET_INSTANCE" --target "$FALLBACK_TARGET" \
        --acme-http-port "$ACME_HTTP_PORT" --restart
}

prepare_nginx_http_site() {
    [ "$SKIP_NGINX" -eq 0 ] || return 0
    if [ -e "/etc/nginx/conf.d/${DOMAIN}-http.conf" ]; then
        grep -Fq "proxy_pass http://127.0.0.1:${ACME_HTTP_PORT};" "/etc/nginx/conf.d/${DOMAIN}-http.conf" || die "该域名已有其他证书验证端口，拒绝覆盖；请使用不同域名或保留原证书验证服务"
        log INFO "保留该域名现有 HTTP 验证与跳转配置"
        return 0
    fi
    local redirect_port=""
    [ "$LISTEN_PORT" = 443 ] || redirect_port=":${LISTEN_PORT}"
    rm -f /etc/nginx/sites-enabled/default
    cat > "/etc/nginx/conf.d/${DOMAIN}-http.conf" <<EOF_HTTP
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        proxy_pass http://127.0.0.1:${ACME_HTTP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
    }

    location / {
        return 301 https://\$host${redirect_port}\$request_uri;
    }
}
EOF_HTTP
    "$CLI_PATH" nginx track-files "/etc/nginx/conf.d/${DOMAIN}-http.conf"
}

configure_nginx() {
    [ "$SKIP_NGINX" -eq 0 ] || return 0
    log STEP "Configuring camouflage site"
    if [ -f /etc/nginx/conf.d/oo-node-camouflage.conf ] || [ -f "${LEGACY_CAMOUFLAGE_CONF:-}" ]; then
        log INFO "Keeping existing camouflage site and nginx server block"
    else
    "$CLI_PATH" nginx camouflage-site \
        --domain "$DOMAIN" \
        --listen "$FALLBACK_TARGET" \
        --template "$TEMPLATE" \
        --write --force --test
    fi

    if [ "$TARGET_MODE" = machine ]; then
        log STEP "按机器内各 Trojan 节点同步域名、独立续期端口及分流"
        "$CLI_PATH" nginx machine-sync --instance "$TARGET_INSTANCE" \
            --relay-nodes "${RELAY_NODES:-}" \
            --listen "$LISTEN_PORT" --acme-base "$ACME_HTTP_PORT" \
            --fallback "$FALLBACK_TARGET" --apply
        log INFO "节点证书正在各自申请或加载；请通过 oo 日志确认结果"
        return 0
    fi
    log STEP "Configuring Trojan fallback"
    "$CLI_PATH" config trojan-fallback --config "$CONFIG_FILE" --instance "$TARGET_INSTANCE" --target "$FALLBACK_TARGET" --restart

    log STEP "Configuring nginx SNI passthrough"
    "$CLI_PATH" nginx trojan-sni \
        --domain "$DOMAIN" \
        --listen "$LISTEN_PORT" \
        --trojan-upstream "$TROJAN_UPSTREAM" \
        --web-upstream "$WEB_UPSTREAM" \
        --write --force --test

    prepare_nginx_http_site
    log STEP "Testing nginx configuration"
    nginx -t
    log STEP "Starting and reloading nginx"
    run_visible systemctl enable --now nginx
    run_visible systemctl reload nginx
}

if [ "$REPAIR_NGINX" -eq 1 ]; then
    ensure_nginx_base
    log INFO "Nginx 基础配置检查通过；未修改 oo 实例或证书。443/SNI 规则仍需核查，不代表转发已恢复。"
    exit 0
fi

if [ "$RESUME_NGINX" -eq 1 ]; then
    [ -f "$CONFIG_FILE" ] && [ -x "$CLI_PATH" ] || die "Existing /etc/oo config and ooctl are required"
    systemctl show "$SERVICE_NAME" -p ExecStart --value | grep -Fq "$CONFIG_FILE" || die "Service does not load $CONFIG_FILE; refusing to change a different install"
    select_nginx_instance
    ensure_nginx_base
    backup_dir="$(mktemp -d /root/oo-nginx-resume.XXXXXX)"
    chmod 700 "$backup_dir"
    tar -czf "$backup_dir/before.tgz" "$INSTALL_ROOT" /etc/nginx
    chmod 600 "$backup_dir/before.tgz"
    log INFO "Configuration backup: $backup_dir/before.tgz"
    wait_for_trojan_certificate
    set_local_acme_http_port
    ensure_nginx_stream_include
    configure_nginx
    log INFO "Existing installation nginx setup completed; binaries and panel bindings were not reinstalled"
    bash "$INSTALL_ROOT/install.sh" check-network || log INFO "Network check unavailable; service configuration was retained"
    exit 0
fi

install_packages
ensure_nginx_base
preflight_domain_dns
ensure_nginx_stream_include
stop_nginx_for_acme
apply_runtime_defaults
install_node
if [ "$SKIP_NGINX" -eq 0 ]; then select_nginx_instance; fi
wait_for_trojan_certificate
set_local_acme_http_port
configure_nginx

log INFO "Installation complete"
bash "$INSTALL_ROOT/install.sh" check-network || log INFO "Network check unavailable; service configuration was retained"
log INFO "Service: ${SERVICE_NAME}"
log INFO "Config: ${CONFIG_FILE}"
log INFO "Health: http://127.0.0.1:${HEALTH_PORT}/healthz"
if [ "$SKIP_NGINX" -eq 0 ]; then
    log INFO "Camouflage: https://${DOMAIN}:${LISTEN_PORT}/"
fi
cat <<'COMMANDS'

常用命令：
  sudo oo                      # 打开编号管理菜单
  sudo oo start                # 启动 oo
  sudo oo restart              # 重启 oo
  sudo oo status               # 查看服务状态
  sudo oo logs                 # 查看实时日志
COMMANDS
