#!/bin/bash

set -Eeuo pipefail

readonly CONFIG_DIR="/etc/changevps"
readonly CONFIG_FILE="${CONFIG_DIR}/changevps.conf"
readonly CHECK_SCRIPT="/usr/local/sbin/changevps-check"
readonly SERVICE_FILE="/etc/systemd/system/changevps.service"
readonly TIMER_FILE="/etc/systemd/system/changevps.timer"
readonly LOGROTATE_FILE="/etc/logrotate.d/changevps"
readonly LOG_FILE="/var/log/changevps.log"

TEMP_DIR=""

die() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "请使用 root 用户或 sudo 运行此脚本"
}

uninstall_changevps() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now changevps.timer >/dev/null 2>&1 || true
    fi

    rm -f -- "$TIMER_FILE" "$SERVICE_FILE" "$CHECK_SCRIPT" "$CONFIG_FILE" "$LOGROTATE_FILE" "$LOG_FILE"
    rmdir -- "$CONFIG_DIR" 2>/dev/null || true

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
        systemctl reset-failed changevps.service >/dev/null 2>&1 || true
    fi

    printf 'changevps 已删除。\n'
}

validate_url() {
    local url="$1"

    [[ "$url" == http://* || "$url" == https://* ]] || return 1
    [[ "$url" != *[$'\t\r\n ']* ]] || return 1
    [[ "$url" != *\\* ]] || return 1
}

cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}

install_dependencies() {
    local packages=()

    command -v ping >/dev/null 2>&1 || packages+=(iputils-ping)
    command -v curl >/dev/null 2>&1 || packages+=(curl)

    if (( ${#packages[@]} > 0 )); then
        printf '正在安装依赖：%s\n' "${packages[*]}"
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
    fi
}

install_changevps() {
    local changeip_url interval_minutes

    [[ -r /etc/os-release ]] || die "无法确认当前操作系统"
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == "debian" ]] || die "此安装脚本仅支持 Debian"
    [[ -d /run/systemd/system ]] || die "当前 Debian 系统未使用 systemd"
    command -v apt-get >/dev/null 2>&1 || die "未找到 apt-get"

    printf '请输入完整的 Change IP URL（输入内容不会显示）：'
    IFS= read -r -s changeip_url
    printf '\n'
    validate_url "$changeip_url" || die "URL 必须是无空格的完整 http/https 地址"

    printf '请输入检测间隔分钟数 [60]：'
    IFS= read -r interval_minutes
    interval_minutes="${interval_minutes:-60}"
    [[ "$interval_minutes" =~ ^[1-9][0-9]*$ ]] || die "检测间隔必须是正整数"
    (( ${#interval_minutes} <= 6 )) || die "检测间隔不能超过 525600 分钟"
    (( interval_minutes <= 525600 )) || die "检测间隔不能超过 525600 分钟"

    install_dependencies

    TEMP_DIR="$(mktemp -d)"
    trap cleanup EXIT

    cat > "${TEMP_DIR}/changevps-check" <<'CHECK_SCRIPT_EOF'
#!/bin/bash

set -u

readonly CONFIG_FILE="/etc/changevps/changevps.conf"
readonly LOG_FILE="/var/log/changevps.log"
readonly PING_HOST="baidu.com"

log_message() {
    printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"
}

if [[ ! -r "$CONFIG_FILE" ]]; then
    log_message "configuration file is missing or unreadable"
    exit 1
fi

IFS= read -r CHANGEIP_URL < "$CONFIG_FILE"
if [[ -z "$CHANGEIP_URL" ]]; then
    log_message "Change IP URL is empty"
    exit 1
fi

if ping -c 4 -W 3 "$PING_HOST" >/dev/null 2>&1; then
    log_message "ping $PING_HOST OK, no action"
    exit 0
fi

log_message "ping $PING_HOST timeout, requesting IP change"
HTTP_CODE="$(
    curl --silent \
        --output /dev/null \
        --write-out '%{http_code}' \
        --connect-timeout 10 \
        --max-time 30 \
        "$CHANGEIP_URL" 2>/dev/null
)"
CURL_STATUS=$?

if (( CURL_STATUS == 0 )); then
    log_message "Change IP request completed, HTTP $HTTP_CODE"
else
    log_message "Change IP request failed, curl exit $CURL_STATUS"
    exit "$CURL_STATUS"
fi
CHECK_SCRIPT_EOF

    cat > "${TEMP_DIR}/changevps.service" <<'SERVICE_EOF'
[Unit]
Description=Check connectivity and request an IP change
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/changevps-check
User=root
Group=root
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadOnlyPaths=/etc/changevps/changevps.conf
ReadWritePaths=/var/log/changevps.log
SERVICE_EOF

    cat > "${TEMP_DIR}/changevps.timer" <<TIMER_EOF
[Unit]
Description=Run the changevps connectivity check every ${interval_minutes} minute(s)

[Timer]
OnActiveSec=${interval_minutes}min
OnUnitInactiveSec=${interval_minutes}min
AccuracySec=1s
Unit=changevps.service

[Install]
WantedBy=timers.target
TIMER_EOF

    cat > "${TEMP_DIR}/changevps.logrotate" <<'LOGROTATE_EOF'
/var/log/changevps.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 0600 root root
}
LOGROTATE_EOF

    systemctl disable --now changevps.timer >/dev/null 2>&1 || true

    install -d -o root -g root -m 0700 "$CONFIG_DIR"
    printf '%s\n' "$changeip_url" > "$CONFIG_FILE"
    chmod 0600 "$CONFIG_FILE"
    chown root:root "$CONFIG_FILE"

    install -o root -g root -m 0755 "${TEMP_DIR}/changevps-check" "$CHECK_SCRIPT"
    install -o root -g root -m 0644 "${TEMP_DIR}/changevps.service" "$SERVICE_FILE"
    install -o root -g root -m 0644 "${TEMP_DIR}/changevps.timer" "$TIMER_FILE"
    install -o root -g root -m 0644 "${TEMP_DIR}/changevps.logrotate" "$LOGROTATE_FILE"

    if [[ ! -e "$LOG_FILE" ]]; then
        install -o root -g root -m 0600 /dev/null "$LOG_FILE"
    else
        chmod 0600 "$LOG_FILE"
        chown root:root "$LOG_FILE"
    fi

    systemctl daemon-reload
    if command -v systemd-analyze >/dev/null 2>&1; then
        systemd-analyze verify "$SERVICE_FILE" "$TIMER_FILE"
    fi
    systemctl enable --now changevps.timer

    printf '安装完成，每 %s 分钟检测一次。\n' "$interval_minutes"
    printf '日志文件：%s\n' "$LOG_FILE"
}

main() {
    require_root

    case "${1:-install}" in
        install)
            [[ $# -le 1 ]] || die "用法：$0 [install|uninstall]"
            install_changevps
            ;;
        uninstall|--uninstall)
            [[ $# -eq 1 ]] || die "用法：$0 [install|uninstall]"
            uninstall_changevps
            ;;
        *)
            die "用法：$0 [install|uninstall]"
            ;;
    esac
}

main "$@"
