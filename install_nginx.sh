#!/usr/bin/env bash

#====================================================
# 企业级 Nginx 源码编译部署脚本
# - 单文件、无 env 依赖
# - 单证书、不拷贝证书
# - stream SNI 只监听 443，默认只启用 main 主站
# - 场景模板安装到 conf.d/*.conf.example
# - 默认交互；直接编辑下方配置块即可覆盖版本与参数
#====================================================

set -Eeuo pipefail
umask 027

# ============================================================
# 可修改配置（直接编辑本区块即可）
# ============================================================

# ---------- 组件版本 ----------
NGINX_VER="1.31.8"
OPENSSL_VER="3.5.9"
JEMALLOC_VER="5.4.0"
FANCYINDEX_VER="0.6.0"
DAV_EXT_VER="3.0.0"
HEADERS_MORE_VER="0.41"
NGX_BROTLI_REF="v1.0.0rc"

# ---------- 组件校验值（换版本时同步更新） ----------
# Nginx
NGINX_TARBALL_SHA256="0652b760b3b772d2ec17b47c2fc15d9a95e6fe35cd5b877eadc1a62d9bc75af1"
# OpenSSL
OPENSSL_TARBALL_SHA256="603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a"
# jemalloc
JEMALLOC_TARBALL_SHA256="200776fac271093e7c2f21edd6d62657ecd2be578d9328633f2a86bfa6ef4f1d"
# ngx-fancyindex
FANCYINDEX_TARBALL_SHA256="d212fdc1393261612126def3e091c376adeda5646130b4240093f47b550bc5ef"
# nginx-dav-ext-module
DAV_EXT_TARBALL_SHA256="d2499d94d82d4e4eac8425d799e52883131ae86a956524040ff2fd230ef9f859"
# headers-more-nginx-module
HEADERS_MORE_TARBALL_SHA256="800eba641c29b89dfd00a97ccac314a2b7768bdd85ea37ed819452494a5633cd"
# ngx_brotli commit pin
NGX_BROTLI_COMMIT="25f86f0bac1101b6512135eac5f93c49c63609e3"

# ---------- 部署参数 ----------
# 0=交互（推荐）；1=无交互（需填写 PRIMARY_DOMAIN/SSL_CERT_PATH/SSL_KEY_PATH）
NON_INTERACTIVE="0"
# 留空则交互询问
PRIMARY_DOMAIN=""
SSL_CERT_PATH=""
SSL_KEY_PATH=""
# 1=生成 80 → 443 跳转
HTTP_REDIRECT="1"
# main 站点内部监听端口
MAIN_BACKEND_PORT="1111"
# HTTP/3
HTTP3_ENABLE="1"
HTTP3_PORT="443"
# OCSP：auto/on/off
OCSP_STAPLING="auto"
# 供应链与证书校验
STRICT_SUPPLYCHAIN="1"
STRICT_CERT_SAN="1"
# 安装失败回滚 / 安装后清理编译产物
ROLLBACK_ON_ERROR="1"
CLEAN_BUILD_ARTIFACTS="1"
# Fail2Ban 模板
ENABLE_FAIL2BAN_TEMPLATE="1"
F2B_MAXRETRY="6"
F2B_FINDTIME="10m"
F2B_BANTIME="12h"
F2B_IGNOREIP="127.0.0.1/8 ::1"

#================= 路径 =================
SRC_DIR="/usr/local/src"
NGINX_DIR="/etc/nginx"
NGINX_CONF_DIR="${NGINX_DIR}/conf.d"
NGINX_STREAM_DIR="${NGINX_DIR}/stream.conf.d"
NGINX_SNIPPET_DIR="${NGINX_DIR}/snippets"
NGINX_SSL_DIR="${NGINX_DIR}/ssl"
NGINX_STATE_DIR="/var/lib/nginx"
LOG_DIR="/var/log/nginx"
WEB_MAIN_ROOT="/var/www/html"
WEB_WEBDAV_ROOT="/var/www/webdav"

#================= 运行状态 =================
RUN_MODE="install"
FORCE_UNINSTALL="0"
PRESERVE_WWW="0"
UNINSTALL_CONFIRM_PHRASE="UNINSTALL NGINX"
INSTALL_IN_PROGRESS=0
INSTALL_COMPLETED=0
ROLLBACK_IN_PROGRESS=0
BACKUP_DIR=""
HAD_PREVIOUS_NGINX=0
CC_WARN_OPT=""
THREADS="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)"

#================= 渲染占位符 =================
HTTP3_LISTEN_V4=""
HTTP3_LISTEN_V6=""
ALT_SVC_LINE=""
SSL_STAPLING_LINE="ssl_stapling off;"
SSL_STAPLING_VERIFY_LINE="ssl_stapling_verify off;"
SYSLOG_ACCESS_LINE=""
SYSLOG_ERROR_LINE=""

#================= UI =================
C_RESET=""
C_BLUE=""
C_CYAN=""
C_GREEN=""
C_YELLOW=""
C_RED=""
STEP_TOTAL=17
STEP_CURRENT=0

setup_ui() {
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        C_RESET=$'\033[0m'
        C_BLUE=$'\033[34m'
        C_CYAN=$'\033[36m'
        C_GREEN=$'\033[32m'
        C_YELLOW=$'\033[33m'
        C_RED=$'\033[31m'
    fi
}

ui_info()  { printf "%b[信息]%b %s\n" "$C_BLUE" "$C_RESET" "$*"; }
ui_ok()    { printf "%b[成功]%b %s\n" "$C_GREEN" "$C_RESET" "$*"; }
ui_warn()  { printf "%b[警告]%b %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
ui_err()   { printf "%b[错误]%b %s\n" "$C_RED" "$C_RESET" "$*" >&2; }
ui_step()  {
    STEP_CURRENT=$((STEP_CURRENT + 1))
    printf "%b[%d/%d]%b %s\n" "$C_CYAN" "$STEP_CURRENT" "$STEP_TOTAL" "$C_RESET" "$*"
}

read_input() {
    local var="$1"
    if [[ -r /dev/tty ]]; then
        IFS= read -r "$var" </dev/tty || true
    else
        IFS= read -r "$var" || true
    fi
}

require_interactive_tty() {
    [[ "${NON_INTERACTIVE}" == "1" ]] && return 0
    if [[ ! -t 0 && ! -r /dev/tty ]]; then
        ui_err "当前没有可交互终端"
        ui_err "请设置 NON_INTERACTIVE=\"1\" 并在脚本顶部填写域名/证书，或使用 --yes 强制卸载"
        exit 1
    fi
}

prompt_value() {
    local label="$1"
    local default="${2:-}"
    local value=""
    if [[ -n "${default}" ]]; then
        printf "%b%s%b [%b%s%b]: " "$C_CYAN" "$label" "$C_RESET" "$C_GREEN" "$default" "$C_RESET" >&2
    else
        printf "%b%s%b: " "$C_CYAN" "$label" "$C_RESET" >&2
    fi
    read_input value
    printf '%s' "${value:-${default}}"
}

prompt_yes_no() {
    local label="$1"
    local default="${2:-Y}"
    local hint="[Y/n]"
    local answer=""
    [[ "${default}" =~ ^[Nn] ]] && hint="[y/N]"
    printf "%b%s%b %b%s%b " "$C_CYAN" "$label" "$C_RESET" "$C_GREEN" "$hint" "$C_RESET" >&2
    read_input answer
    answer="${answer:-${default}}"
    [[ "${answer}" =~ ^[Yy]([Ee][Ss])?$ ]]
}

on_error() {
    local exit_code="$1"
    local line_no="$2"
    ui_err "脚本在第 ${line_no} 行失败，退出码=${exit_code}"

    if [[ "${RUN_MODE}" == "install" \
        && "${INSTALL_IN_PROGRESS}" == "1" \
        && "${INSTALL_COMPLETED}" == "0" \
        && "${ROLLBACK_ON_ERROR}" == "1" \
        && "${ROLLBACK_IN_PROGRESS}" == "0" ]]; then
        ROLLBACK_IN_PROGRESS=1
        ui_warn "检测到安装中断，开始自动回滚"
        uninstall_generated_artifacts "0" "rollback"
    fi

    exit "${exit_code}"
}
trap 'on_error $? $LINENO' ERR

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --uninstall)
                RUN_MODE="uninstall"
                shift
                ;;
            --yes|-y)
                FORCE_UNINSTALL=1
                shift
                ;;
            --preserve-www)
                PRESERVE_WWW=1
                shift
                ;;
            --interactive)
                NON_INTERACTIVE=0
                shift
                ;;
            --non-interactive)
                NON_INTERACTIVE=1
                shift
                ;;
            --help|-h)
                cat <<'EOF_HELP'
Usage:
  install_nginx.sh                     # 交互安装
  install_nginx.sh --non-interactive   # 无交互安装（需在脚本顶部填写域名/证书）
  install_nginx.sh --uninstall         # 卸载（交互确认）
  install_nginx.sh --uninstall --yes   # 强制卸载
  install_nginx.sh --uninstall --preserve-www

Environment:
  NO_COLOR=1                           # 关闭彩色输出
EOF_HELP
                exit 0
                ;;
            *)
                ui_err "未知参数: $1"
                ui_err "可用参数: --interactive, --non-interactive, --uninstall, --preserve-www, --yes|-y, --help|-h"
                exit 1
                ;;
        esac
    done
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        ui_err "必须以 root 身份执行"
        exit 1
    fi
}

escape_sed_replacement() {
    printf '%s' "$1" | sed -e 's/[\\/&|]/\\&/g'
}

validate_domain_or_exit() {
    local v="$1"
    local label="$2"
    if [[ ! "${v}" =~ ^[A-Za-z0-9.-]+$ ]]; then
        ui_err "${label} 格式不合法: ${v}"
        exit 1
    fi
}

validate_settings() {
    local name port

    if [[ "${NON_INTERACTIVE}" != "0" && "${NON_INTERACTIVE}" != "1" ]]; then
        ui_err "NON_INTERACTIVE 只能是 0 或 1"
        exit 1
    fi
    if [[ "${HTTP_REDIRECT}" != "0" && "${HTTP_REDIRECT}" != "1" ]]; then
        ui_err "HTTP_REDIRECT 只能是 0 或 1"
        exit 1
    fi
    if [[ "${HTTP3_ENABLE}" != "0" && "${HTTP3_ENABLE}" != "1" ]]; then
        ui_err "HTTP3_ENABLE 只能是 0 或 1"
        exit 1
    fi
    for name in HTTP3_PORT MAIN_BACKEND_PORT; do
        port="${!name}"
        if [[ ! "${port}" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            ui_err "${name} 必须是 1-65535，当前: ${port}"
            exit 1
        fi
    done
    if [[ "${MAIN_BACKEND_PORT}" == "443" || "${MAIN_BACKEND_PORT}" == "80" ]]; then
        ui_err "MAIN_BACKEND_PORT 不能是 443 或 80"
        exit 1
    fi
    if [[ "${OCSP_STAPLING}" != "auto" && "${OCSP_STAPLING}" != "on" && "${OCSP_STAPLING}" != "off" ]]; then
        ui_err "OCSP_STAPLING 只能是 auto/on/off"
        exit 1
    fi
}

check_os_compat() {
    if [[ ! -r /etc/os-release ]]; then
        ui_err "无法识别系统版本（/etc/os-release 不存在）"
        exit 1
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID:-}" in
        debian)
            local ver="${VERSION_ID%%.*}"
            if (( ver < 11 )); then
                ui_err "Debian 版本过低，要求 Debian 11+"
                exit 1
            fi
            ;;
        ubuntu)
            local ver="${VERSION_ID%%.*}"
            if (( ver < 22 )); then
                ui_err "Ubuntu 版本过低，要求 Ubuntu 22.04+"
                exit 1
            fi
            ;;
        *)
            ui_warn "当前系统 ID=${ID:-unknown}，未在兼容列表内，将继续执行"
            ;;
    esac
    ui_ok "系统兼容性检查通过 (${PRETTY_NAME:-unknown})"
}

install_dependencies() {
    ui_step "安装编译依赖"
    apt-get update -y
    apt-get install -y --no-install-recommends \
        ca-certificates build-essential libpcre2-dev zlib1g-dev \
        libssl-dev wget git curl lsof cmake pkg-config openssl iproute2 \
        logrotate libunwind-dev perl libxml2-dev libxslt1-dev \
        apache2-utils

    if ! id -u www-data >/dev/null 2>&1; then
        useradd -r -s /usr/sbin/nologin www-data
        ui_ok "已创建 www-data 用户"
    else
        ui_info "www-data 用户已存在"
    fi
}

require_cmds() {
    local cmds=(apt-get curl wget git tar make gcc g++ sha256sum systemctl openssl)
    local c
    for c in "${cmds[@]}"; do
        command -v "${c}" >/dev/null 2>&1 || {
            ui_err "缺少命令: ${c}"
            exit 1
        }
    done
}

check_version_currency() {
    local warnings=""
    local minor=""
    local ossl_minor=""
    if [[ "${NGINX_VER}" =~ ^1\.([0-9]+)\. ]]; then
        minor="${BASH_REMATCH[1]}"
        if (( minor < 29 )); then
            warnings+="Nginx ${NGINX_VER} 缺少 HTTP/3/WebDAV/TLS 等安全修复；"
        fi
    fi
    if [[ "${OPENSSL_VER}" =~ ^3\.([0-9]+)\. ]]; then
        ossl_minor="${BASH_REMATCH[1]}"
        if (( ossl_minor < 5 )); then
            warnings+="OpenSSL ${OPENSSL_VER} 不支持原生服务端 QUIC；"
        fi
    fi
    if [[ -n "${warnings}" ]]; then
        ui_warn "版本时效性提示：${warnings}"
    fi
}

check_http3_port_available() {
    [[ "${HTTP3_ENABLE}" == "1" ]] || return 0
    command -v ss >/dev/null 2>&1 || return 0

    if [[ -f /run/nginx.pid ]]; then
        local nginx_pid
        nginx_pid="$(cat /run/nginx.pid 2>/dev/null || true)"
        if [[ -n "${nginx_pid}" ]] && kill -0 "${nginx_pid}" 2>/dev/null; then
            return 0
        fi
    fi

    if ss -lunH "sport = :${HTTP3_PORT}" 2>/dev/null | grep -q .; then
        ui_err "UDP/${HTTP3_PORT} 已被占用，Nginx HTTP/3 无法绑定"
        ss -lunp "sport = :${HTTP3_PORT}" 2>/dev/null | sed 's/^/[udp] /' >&2 || true
        ui_err "请设置 HTTP3_ENABLE=0，或使用 HTTP3_PORT=<其他 UDP 端口>"
        exit 1
    fi
}

check_tcp_ports_available() {
    command -v ss >/dev/null 2>&1 || return 0

    local ports=(443 "${MAIN_BACKEND_PORT}")
    [[ "${HTTP_REDIRECT}" == "1" ]] && ports+=(80)

    local port out
    for port in "${ports[@]}"; do
        out="$(ss -lntp "sport = :${port}" 2>/dev/null | tail -n +2 || true)"
        [[ -z "${out}" ]] && continue
        if printf '%s\n' "${out}" | grep -qv 'nginx'; then
            ui_err "TCP/${port} 已被非 Nginx 进程占用："
            printf '%s\n' "${out}" | sed 's/^/[tcp] /' >&2
            ui_err "请释放该端口，或调整 MAIN_BACKEND_PORT / HTTP_REDIRECT"
            exit 1
        fi
    done
}

ensure_ports_free_or_exit() {
    command -v ss >/dev/null 2>&1 || return 0

    local ports=(443 "${MAIN_BACKEND_PORT}")
    [[ "${HTTP_REDIRECT}" == "1" ]] && ports+=(80)

    local port out
    for port in "${ports[@]}"; do
        out="$(ss -lntp "sport = :${port}" 2>/dev/null | tail -n +2 || true)"
        if [[ -n "${out}" ]]; then
            ui_err "TCP/${port} 在停止旧 Nginx 后仍被占用："
            printf '%s\n' "${out}" | sed 's/^/[tcp] /' >&2
            exit 1
        fi
    done

    if [[ "${HTTP3_ENABLE}" == "1" ]]; then
        out="$(ss -lunH "sport = :${HTTP3_PORT}" 2>/dev/null || true)"
        if [[ -n "${out}" ]]; then
            ui_err "UDP/${HTTP3_PORT} 在停止旧 Nginx 后仍被占用："
            ss -lunp "sport = :${HTTP3_PORT}" 2>/dev/null | sed 's/^/[udp] /' >&2 || true
            exit 1
        fi
    fi
}

require_readable_file_or_exit() {
    local f="$1"
    local label="$2"
    if [[ -z "${f}" || ! -f "${f}" || ! -r "${f}" ]]; then
        ui_err "${label} 不存在或不可读: ${f}"
        exit 1
    fi
}

cert_covers_domain() {
    local cert="$1"
    local domain="${2,,}"
    local sans san suffix prefix
    sans="$(openssl x509 -in "${cert}" -noout -text 2>/dev/null \
        | awk '/X509v3 Subject Alternative Name/{getline; print}' \
        | tr ',' '\n' \
        | sed -E 's/^[[:space:]]*DNS://; s/^[[:space:]]+//; s/[[:space:]]+$//' \
        | grep -v '^$' || true)"
    if [[ -z "${sans}" ]]; then
        sans="$(openssl x509 -in "${cert}" -noout -subject 2>/dev/null \
            | sed -E 's/.*CN[[:space:]]*=[[:space:]]*//' | tr -d ' ')"
    fi
    for san in ${sans}; do
        san="${san,,}"
        [[ "${san}" == "${domain}" ]] && return 0
        if [[ "${san}" == \*.* ]]; then
            suffix="${san#\*.}"
            if [[ "${domain}" == *".${suffix}" ]]; then
                prefix="${domain%.${suffix}}"
                if [[ -n "${prefix}" && "${prefix}" != *.* ]]; then
                    return 0
                fi
            fi
        fi
    done
    return 1
}

cert_and_key_match() {
    local cert="$1"
    local key="$2"
    local cert_fp key_fp
    cert_fp="$(openssl x509 -in "${cert}" -noout -pubkey 2>/dev/null \
        | openssl pkey -pubin -outform PEM 2>/dev/null | openssl dgst -sha256 || true)"
    key_fp="$(openssl pkey -in "${key}" -pubout -outform PEM 2>/dev/null \
        | openssl dgst -sha256 || true)"
    [[ -n "${cert_fp}" && "${cert_fp}" == "${key_fp}" ]]
}

validate_cert_material() {
    local cert="$1"
    local key="$2"
    local domain="$3"

    require_readable_file_or_exit "${cert}" "证书"
    require_readable_file_or_exit "${key}" "私钥"

    if ! openssl x509 -in "${cert}" -noout >/dev/null 2>&1; then
        ui_err "证书无法解析: ${cert}"
        exit 1
    fi
    if ! openssl pkey -in "${key}" -noout >/dev/null 2>&1; then
        ui_err "私钥无法解析: ${key}"
        exit 1
    fi
    if ! openssl x509 -in "${cert}" -noout -checkend 0 >/dev/null 2>&1; then
        ui_err "证书已过期: ${cert}"
        exit 1
    fi
    if ! openssl x509 -in "${cert}" -noout -checkend 1209600 >/dev/null 2>&1; then
        ui_warn "证书将在 14 天内过期，请及时续期"
    fi
    if ! cert_and_key_match "${cert}" "${key}"; then
        ui_err "证书与私钥不匹配"
        exit 1
    fi
    if ! cert_covers_domain "${cert}" "${domain}"; then
        if [[ "${STRICT_CERT_SAN}" == "1" ]]; then
            ui_err "证书 SAN 未覆盖域名 ${domain}: ${cert}"
            exit 1
        fi
        ui_warn "证书 SAN 未覆盖域名 ${domain}，宽松模式继续"
    fi
    ui_ok "证书校验通过（域名 ${domain}）"
}

certs_support_ocsp() {
    [[ -n "${SSL_CERT_PATH}" ]] || return 1
    openssl x509 -in "${SSL_CERT_PATH}" -noout -ocsp_uri 2>/dev/null | grep -q .
}

collect_main_inputs() {
    ui_step "采集主站参数"
    require_interactive_tty

    local value=""
    if [[ -z "${PRIMARY_DOMAIN}" ]]; then
        if [[ "${NON_INTERACTIVE}" == "1" ]]; then
            ui_err "NON_INTERACTIVE=1 但未提供 PRIMARY_DOMAIN"
            exit 1
        fi
        while true; do
            value="$(prompt_value "请输入主站域名（例如 main.example.com）")"
            if [[ -z "${value}" ]]; then
                ui_warn "域名不能为空"
                continue
            fi
            if [[ ! "${value}" =~ ^[A-Za-z0-9.-]+$ ]]; then
                ui_warn "域名格式不合法"
                continue
            fi
            PRIMARY_DOMAIN="${value}"
            break
        done
    fi
    validate_domain_or_exit "${PRIMARY_DOMAIN}" "主站域名"

    if [[ -z "${SSL_CERT_PATH}" && "${NON_INTERACTIVE}" == "1" ]]; then
        ui_err "NON_INTERACTIVE=1 但未提供 SSL_CERT_PATH"
        exit 1
    fi
    while true; do
        if [[ -z "${SSL_CERT_PATH}" ]]; then
            SSL_CERT_PATH="$(prompt_value "请输入证书路径（fullchain.pem）")"
        fi
        if [[ -z "${SSL_CERT_PATH}" ]]; then
            ui_warn "证书路径不能为空"
            continue
        fi
        if [[ "${SSL_CERT_PATH}" != /* ]]; then
            ui_warn "请使用绝对路径"
            SSL_CERT_PATH=""
            [[ "${NON_INTERACTIVE}" == "1" ]] && { ui_err "证书路径必须是绝对路径"; exit 1; }
            continue
        fi
        if [[ ! -r "${SSL_CERT_PATH}" ]]; then
            ui_warn "证书不可读: ${SSL_CERT_PATH}"
            SSL_CERT_PATH=""
            [[ "${NON_INTERACTIVE}" == "1" ]] && { ui_err "证书不可读"; exit 1; }
            continue
        fi
        break
    done

    if [[ -z "${SSL_KEY_PATH}" && "${NON_INTERACTIVE}" == "1" ]]; then
        ui_err "NON_INTERACTIVE=1 但未提供 SSL_KEY_PATH"
        exit 1
    fi
    while true; do
        if [[ -z "${SSL_KEY_PATH}" ]]; then
            SSL_KEY_PATH="$(prompt_value "请输入私钥路径（privkey.pem）")"
        fi
        if [[ -z "${SSL_KEY_PATH}" ]]; then
            ui_warn "私钥路径不能为空"
            continue
        fi
        if [[ "${SSL_KEY_PATH}" != /* ]]; then
            ui_warn "请使用绝对路径"
            SSL_KEY_PATH=""
            [[ "${NON_INTERACTIVE}" == "1" ]] && { ui_err "私钥路径必须是绝对路径"; exit 1; }
            continue
        fi
        if [[ ! -r "${SSL_KEY_PATH}" ]]; then
            ui_warn "私钥不可读: ${SSL_KEY_PATH}"
            SSL_KEY_PATH=""
            [[ "${NON_INTERACTIVE}" == "1" ]] && { ui_err "私钥不可读"; exit 1; }
            continue
        fi
        break
    done

    ui_step "校验证书"
    validate_cert_material "${SSL_CERT_PATH}" "${SSL_KEY_PATH}" "${PRIMARY_DOMAIN}"

    if [[ "${NON_INTERACTIVE}" != "1" ]]; then
        local default="N"
        [[ "${HTTP_REDIRECT}" == "1" ]] && default="Y"
        if prompt_yes_no "是否生成 80 → 443 跳转？" "${default}"; then
            HTTP_REDIRECT=1
        else
            HTTP_REDIRECT=0
        fi
    fi
}

backup_existing_installation() {
    if [[ -e "${NGINX_DIR}" || -e /etc/systemd/system/nginx.service ]]; then
        HAD_PREVIOUS_NGINX=1
        BACKUP_DIR="/var/backups/nginx-install-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "${BACKUP_DIR}"
        [[ -e "${NGINX_DIR}" ]] && cp -a "${NGINX_DIR}" "${BACKUP_DIR}/etc-nginx"
        [[ -e /etc/systemd/system/nginx.service ]] && cp -a /etc/systemd/system/nginx.service "${BACKUP_DIR}/nginx.service"
        [[ -e /etc/logrotate.d/nginx ]] && cp -a /etc/logrotate.d/nginx "${BACKUP_DIR}/logrotate-nginx"
        ui_warn "检测到既有 Nginx，已备份到 ${BACKUP_DIR}"
    else
        ui_info "未检测到既有 Nginx，将全新部署"
    fi
}

verify_sha256_or_policy() {
    local file="$1"
    local expected_sha="$2"

    if [[ -n "${expected_sha}" ]]; then
        local actual_sha
        actual_sha="$(sha256sum "${file}" | awk '{print $1}')"
        if [[ "${actual_sha}" != "${expected_sha}" ]]; then
            ui_err "SHA256 校验失败: ${file}"
            ui_err "期望: ${expected_sha}"
            ui_err "实际: ${actual_sha}"
            exit 1
        fi
        ui_ok "SHA256 校验通过: ${file}"
        return
    fi

    if [[ "${STRICT_SUPPLYCHAIN}" == "1" ]]; then
        ui_err "严格供应链模式启用，但未提供 ${file} 的 SHA256"
        exit 1
    fi
    ui_warn "未提供 ${file} 的 SHA256，继续执行"
}

clone_with_optional_pin() {
    local repo_url="$1"
    local dest_dir="$2"
    local ref="$3"
    local expected_commit="$4"

    [[ -d "${dest_dir}" ]] && rm -rf "${dest_dir}"

    if [[ -n "${expected_commit}" ]]; then
        if git init -q "${dest_dir}" 2>/dev/null \
            && git -C "${dest_dir}" remote add origin "${repo_url}" 2>/dev/null \
            && git -C "${dest_dir}" fetch --depth 1 origin "${expected_commit}" >/dev/null 2>&1; then
            git -C "${dest_dir}" checkout -q FETCH_HEAD
        else
            ui_warn "无法按 commit 直接抓取，回退到 ref=${ref} 克隆: ${dest_dir}"
            rm -rf "${dest_dir}"
            git clone --depth 1 -b "${ref}" "${repo_url}" "${dest_dir}"
        fi
        local actual_commit
        actual_commit="$(git -C "${dest_dir}" rev-parse HEAD)"
        if [[ "${actual_commit}" != "${expected_commit}" ]]; then
            ui_err "仓库 commit 校验失败: ${dest_dir}"
            ui_err "期望: ${expected_commit}"
            ui_err "实际: ${actual_commit}"
            exit 1
        fi
        ui_ok "仓库 commit 校验通过: ${dest_dir}"
    else
        git clone --depth 1 -b "${ref}" "${repo_url}" "${dest_dir}"
        if [[ "${STRICT_SUPPLYCHAIN}" == "1" ]]; then
            ui_err "严格供应链模式启用，但 ${dest_dir} 未设置 commit 固定点"
            exit 1
        fi
        ui_warn "${dest_dir} 未设置 commit 固定点，继续执行"
    fi
}

download_sources() {
    ui_step "下载并校验源码"
    mkdir -p "${SRC_DIR}"
    cd "${SRC_DIR}"

    wget -O "nginx-${NGINX_VER}.tar.gz" "https://nginx.org/download/nginx-${NGINX_VER}.tar.gz"
    verify_sha256_or_policy "nginx-${NGINX_VER}.tar.gz" "${NGINX_TARBALL_SHA256}"
    tar -zxf "nginx-${NGINX_VER}.tar.gz"

    wget -O "openssl-${OPENSSL_VER}.tar.gz" \
        "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VER}/openssl-${OPENSSL_VER}.tar.gz"
    verify_sha256_or_policy "openssl-${OPENSSL_VER}.tar.gz" "${OPENSSL_TARBALL_SHA256}"
    tar -zxf "openssl-${OPENSSL_VER}.tar.gz"

    clone_with_optional_pin "https://github.com/google/ngx_brotli.git" "ngx_brotli" "${NGX_BROTLI_REF}" "${NGX_BROTLI_COMMIT}"
    git -C ngx_brotli submodule update --init --recursive

    wget -O "jemalloc-${JEMALLOC_VER}.tar.bz2" \
        "https://github.com/jemalloc/jemalloc/releases/download/${JEMALLOC_VER}/jemalloc-${JEMALLOC_VER}.tar.bz2"
    verify_sha256_or_policy "jemalloc-${JEMALLOC_VER}.tar.bz2" "${JEMALLOC_TARBALL_SHA256}"
    tar -xf "jemalloc-${JEMALLOC_VER}.tar.bz2"

    wget -O "fancyindex.tar.gz" \
        "https://github.com/aperezdc/ngx-fancyindex/archive/refs/tags/v${FANCYINDEX_VER}.tar.gz"
    verify_sha256_or_policy "fancyindex.tar.gz" "${FANCYINDEX_TARBALL_SHA256}"
    tar -zxf fancyindex.tar.gz

    wget -O "dav-ext.tar.gz" \
        "https://github.com/arut/nginx-dav-ext-module/archive/refs/tags/v${DAV_EXT_VER}.tar.gz"
    verify_sha256_or_policy "dav-ext.tar.gz" "${DAV_EXT_TARBALL_SHA256}"
    tar -zxf dav-ext.tar.gz

    wget -O "headers-more.tar.gz" \
        "https://github.com/openresty/headers-more-nginx-module/archive/refs/tags/v${HEADERS_MORE_VER}.tar.gz"
    verify_sha256_or_policy "headers-more.tar.gz" "${HEADERS_MORE_TARBALL_SHA256}"
    tar -zxf headers-more.tar.gz

    ui_ok "源码下载与校验完成"
}

detect_cc_warn_opt() {
    CC_WARN_OPT=""
    local cc_version major
    cc_version="$(cc --version 2>/dev/null || true)"
    if [[ "${cc_version}" != *"Free Software Foundation"* && "${cc_version}" != *"gcc version"* && "${cc_version}" != *"GCC"* ]]; then
        ui_info "非 GCC 编译器，跳过 -Wno-error=vla-parameter"
        return 0
    fi
    major="$(cc -dumpversion 2>/dev/null | cut -d. -f1 || true)"
    if [[ ! "${major}" =~ ^[0-9]+$ ]] || (( major < 11 )); then
        ui_info "GCC ${major:-unknown} < 11，跳过 -Wno-error=vla-parameter"
        return 0
    fi
    CC_WARN_OPT="-Wno-error=vla-parameter"
    ui_info "GCC ${major} 启用 -Wno-error=vla-parameter（ngx_brotli 兼容）"
}

compile_jemalloc() {
    ui_step "编译 jemalloc"
    cd "${SRC_DIR}/jemalloc-${JEMALLOC_VER}"
    ./configure
    make -j "${THREADS}"
    make install
    echo '/usr/local/lib' > /etc/ld.so.conf.d/local.conf
    ldconfig
    ui_ok "jemalloc 安装完成"
}

compile_nginx() {
    ui_step "编译 Nginx"
    detect_cc_warn_opt
    cd "${SRC_DIR}/nginx-${NGINX_VER}"

    CONF_ARGS=(
        "--prefix=${NGINX_DIR}"
        "--user=www-data"
        "--group=www-data"
        "--with-threads"
        "--with-file-aio"
        "--with-http_ssl_module"
        "--with-http_v2_module"
        "--with-http_v3_module"
        "--with-http_realip_module"
        "--with-http_gzip_static_module"
        "--with-http_stub_status_module"
        "--with-http_sub_module"
        "--with-http_dav_module"
        "--with-stream"
        "--with-stream_ssl_module"
        "--with-stream_ssl_preread_module"
        "--with-openssl=../openssl-${OPENSSL_VER}"
        "--with-ld-opt=-ljemalloc"
        "--with-cc-opt=-O3 -fstack-protector-strong -D_FORTIFY_SOURCE=2 ${CC_WARN_OPT}"
        "--add-module=../ngx_brotli"
        "--add-module=../headers-more-nginx-module-${HEADERS_MORE_VER}"
        "--add-module=../nginx-dav-ext-module-${DAV_EXT_VER}"
        "--add-module=../ngx-fancyindex-${FANCYINDEX_VER}"
    )

    ./configure "${CONF_ARGS[@]}"
    make -j "${THREADS}"
    make install

    mkdir -p "${NGINX_CONF_DIR}" "${NGINX_STREAM_DIR}" "${NGINX_SNIPPET_DIR}" "${NGINX_SSL_DIR}" "${NGINX_DIR}/conf"
    mkdir -p "${WEB_MAIN_ROOT}" "${WEB_WEBDAV_ROOT}"
    install -d -m 0750 -o root -g www-data "${LOG_DIR}"
    ensure_runtime_dirs
    chown -R www-data:www-data "${WEB_MAIN_ROOT}" "${WEB_WEBDAV_ROOT}"
    touch "${LOG_DIR}/access.log" "${LOG_DIR}/error.log" "${LOG_DIR}/main_access.log" "${LOG_DIR}/main_error.log"
    chown root:www-data "${LOG_DIR}"/*.log
    chmod 0640 "${LOG_DIR}"/*.log
    chmod 700 "${NGINX_SSL_DIR}"

    ui_ok "Nginx 编译安装完成"
}

ensure_runtime_dirs() {
    install -d -m 0770 -o root -g www-data "${NGINX_STATE_DIR}"
    local d
    for d in client_temp proxy_temp fastcgi_temp uwsgi_temp scgi_temp; do
        install -d -m 0770 -o root -g www-data "${NGINX_STATE_DIR}/${d}"
    done
}

generate_dhparam() {
    ui_step "生成 DH 参数"
    if [[ ! -f "${NGINX_SSL_DIR}/dhparam.pem" ]]; then
        openssl dhparam -out "${NGINX_SSL_DIR}/dhparam.pem" 2048
        chmod 600 "${NGINX_SSL_DIR}/dhparam.pem"
        ui_ok "DH 参数生成完成"
    else
        ui_info "已存在 dhparam.pem，跳过"
    fi
}

prepare_config_values() {
    HTTP3_LISTEN_V4=""
    HTTP3_LISTEN_V6=""
    ALT_SVC_LINE=""
    if [[ "${HTTP3_ENABLE}" == "1" ]]; then
        HTTP3_LISTEN_V4="listen ${HTTP3_PORT} quic;"
        HTTP3_LISTEN_V6="listen [::]:${HTTP3_PORT} quic;"
        ALT_SVC_LINE="add_header Alt-Svc 'h3=\":${HTTP3_PORT}\"; ma=86400' always;"
    fi

    local stapling=0
    if [[ "${OCSP_STAPLING}" == "on" ]]; then
        stapling=1
        if ! certs_support_ocsp; then
            ui_warn "OCSP_STAPLING=on 但证书缺少 OCSP URL，Nginx 启动时会有告警"
        fi
    elif [[ "${OCSP_STAPLING}" == "auto" ]] && certs_support_ocsp; then
        stapling=1
    else
        ui_info "证书未包含 OCSP URL 或 OCSP_STAPLING=off，关闭 ssl_stapling"
    fi
    if (( stapling == 1 )); then
        SSL_STAPLING_LINE="ssl_stapling on;"
        SSL_STAPLING_VERIFY_LINE="ssl_stapling_verify on;"
    else
        SSL_STAPLING_LINE="ssl_stapling off;"
        SSL_STAPLING_VERIFY_LINE="ssl_stapling_verify off;"
    fi

    SYSLOG_ACCESS_LINE=""
    SYSLOG_ERROR_LINE=""
    if [[ -S /dev/log ]]; then
        SYSLOG_ACCESS_LINE="access_log syslog:server=unix:/dev/log,facility=local6,tag=nginx_access,severity=info;"
        SYSLOG_ERROR_LINE="error_log syslog:server=unix:/dev/log,facility=local5,tag=nginx_error warn;"
    else
        ui_warn "/dev/log 不存在，跳过 journald 日志通道（仅保留文件日志）"
    fi
}

apply_placeholders() {
    local file="$1"
    local esc_pd esc_mp esc_cert esc_key esc_v4 esc_v6 esc_alt esc_stap esc_stapv esc_sysa esc_syse

    esc_pd="$(escape_sed_replacement "${PRIMARY_DOMAIN}")"
    esc_mp="$(escape_sed_replacement "${MAIN_BACKEND_PORT}")"
    esc_cert="$(escape_sed_replacement "${SSL_CERT_PATH}")"
    esc_key="$(escape_sed_replacement "${SSL_KEY_PATH}")"
    esc_v4="$(escape_sed_replacement "${HTTP3_LISTEN_V4}")"
    esc_v6="$(escape_sed_replacement "${HTTP3_LISTEN_V6}")"
    esc_alt="$(escape_sed_replacement "${ALT_SVC_LINE}")"
    esc_stap="$(escape_sed_replacement "${SSL_STAPLING_LINE}")"
    esc_stapv="$(escape_sed_replacement "${SSL_STAPLING_VERIFY_LINE}")"
    esc_sysa="$(escape_sed_replacement "${SYSLOG_ACCESS_LINE}")"
    esc_syse="$(escape_sed_replacement "${SYSLOG_ERROR_LINE}")"

    local tmp="${file}.tmp.$$"
    sed -e "s|__PRIMARY_DOMAIN__|${esc_pd}|g" \
        -e "s|__MAIN_BACKEND_PORT__|${esc_mp}|g" \
        -e "s|__SSL_CERT_PATH__|${esc_cert}|g" \
        -e "s|__SSL_KEY_PATH__|${esc_key}|g" \
        -e "s|__HTTP3_LISTEN_V4__|${esc_v4}|g" \
        -e "s|__HTTP3_LISTEN_V6__|${esc_v6}|g" \
        -e "s|__ALT_SVC_HEADER__|${esc_alt}|g" \
        -e "s|__SSL_STAPLING_LINE__|${esc_stap}|g" \
        -e "s|__SSL_STAPLING_VERIFY_LINE__|${esc_stapv}|g" \
        -e "s|__SYSLOG_ACCESS__|${esc_sysa}|g" \
        -e "s|__SYSLOG_ERROR__|${esc_syse}|g" \
        "${file}" > "${tmp}"
    mv "${tmp}" "${file}"
}

write_global_config() {
    ui_step "生成全局配置"
    cat > "${NGINX_DIR}/conf/nginx.conf" <<'EOF_NGINX'
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /run/nginx.pid;

events {
    worker_connections 4096;
    multi_accept on;
}

stream {
    log_format stream_sni '$remote_addr:$remote_port -> $server_addr:$server_port '
                          'sni="$ssl_preread_server_name" backend="$backend_name" '
                          'status=$status bytes_in=$bytes_received bytes_out=$bytes_sent';
    access_log /var/log/nginx/stream_sni.log stream_sni;
    include /etc/nginx/stream.conf.d/*.conf;
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;
    set_real_ip_from ::1;
    real_ip_recursive on;

    access_log /var/log/nginx/access.log;
    __SYSLOG_ACCESS__
    error_log  /var/log/nginx/error.log warn;
    __SYSLOG_ERROR__

    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;
    server_tokens   off;

    open_file_cache max=10000 inactive=30s;
    open_file_cache_valid 30s;
    open_file_cache_min_uses 2;
    open_file_cache_errors on;

    aio threads;

    client_body_temp_path /var/lib/nginx/client_temp;
    proxy_temp_path       /var/lib/nginx/proxy_temp;
    fastcgi_temp_path     /var/lib/nginx/fastcgi_temp;
    uwsgi_temp_path       /var/lib/nginx/uwsgi_temp;
    scgi_temp_path        /var/lib/nginx/scgi_temp;

    client_body_buffer_size      16k;
    client_header_buffer_size    1k;
    large_client_header_buffers  4 8k;
    client_body_timeout          12s;
    client_header_timeout        12s;
    keepalive_timeout            65s;
    send_timeout                 10s;

    limit_req_zone $binary_remote_addr zone=one:10m rate=10r/s;
    limit_req_zone $binary_remote_addr zone=webdav_read:10m rate=180r/m;
    map $request_method $webdav_write_key {
        default   "";
        PUT       $binary_remote_addr;
        DELETE    $binary_remote_addr;
        MKCOL     $binary_remote_addr;
        COPY      $binary_remote_addr;
        MOVE      $binary_remote_addr;
        LOCK      $binary_remote_addr;
        UNLOCK    $binary_remote_addr;
        PROPPATCH $binary_remote_addr;
    }
    limit_req_zone $webdav_write_key zone=webdav_write:10m rate=30r/m;
    limit_req_zone $binary_remote_addr zone=webdav_auth_limit:20m rate=120r/m;
    limit_conn_zone $binary_remote_addr zone=conn_per_ip:10m;
    dav_ext_lock_zone zone=webdav:10m;
    limit_req_status 429;
    limit_conn_status 429;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=(), payment=()" always;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'self';" always;
    __ALT_SVC_HEADER__

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_dhparam /etc/nginx/ssl/dhparam.pem;
    ssl_session_cache shared:SSL:50m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    __SSL_STAPLING_LINE__
    __SSL_STAPLING_VERIFY_LINE__
    resolver 223.5.5.5 1.1.1.1 valid=300s;
    resolver_timeout 5s;

    brotli on;
    brotli_comp_level 6;
    brotli_static on;
    brotli_types application/javascript application/json application/xml text/css text/plain;

    include /etc/nginx/conf.d/*.conf;
}
EOF_NGINX
    apply_placeholders "${NGINX_DIR}/conf/nginx.conf"
    chmod 640 "${NGINX_DIR}/conf/nginx.conf"
}

write_snippets() {
    install -d -m 0755 -o root -g root "${NGINX_SNIPPET_DIR}"

    cat > "${NGINX_SNIPPET_DIR}/ssl.conf" <<'EOF_SSL'
# 统一证书配置（由 install_nginx.sh 生成）
# 证书不会拷贝到 /etc/nginx，直接引用安装时指定的路径
ssl_certificate         __SSL_CERT_PATH__;
ssl_certificate_key     __SSL_KEY_PATH__;
ssl_trusted_certificate __SSL_CERT_PATH__;
EOF_SSL
    apply_placeholders "${NGINX_SNIPPET_DIR}/ssl.conf"
    chmod 640 "${NGINX_SNIPPET_DIR}/ssl.conf"

    cat > "${NGINX_SNIPPET_DIR}/proxy-common.conf" <<'EOF_PROXY_COMMON'
# 反向代理公共配置
proxy_http_version 1.1;
proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_connect_timeout 10s;
proxy_read_timeout    60s;
proxy_send_timeout    60s;
EOF_PROXY_COMMON
    chmod 644 "${NGINX_SNIPPET_DIR}/proxy-common.conf"

    cat > "${NGINX_SNIPPET_DIR}/websocket.conf" <<'EOF_WS_SNIPPET'
# WebSocket / 长连接升级头
proxy_http_version 1.1;
proxy_set_header Upgrade    $http_upgrade;
proxy_set_header Connection "upgrade";
proxy_buffering off;
EOF_WS_SNIPPET
    chmod 644 "${NGINX_SNIPPET_DIR}/websocket.conf"
}

write_main_site() {
    ui_step "生成 main 主站配置"
    cat > "${NGINX_CONF_DIR}/main.conf" <<'EOF_MAIN'
# 主站（main）配置（由 install_nginx.sh 生成）
server {
    listen 127.0.0.1:__MAIN_BACKEND_PORT__ ssl proxy_protocol;
    __HTTP3_LISTEN_V4__
    __HTTP3_LISTEN_V6__
    http2 on;
    http3 on;
    quic_retry on;

    server_name __PRIMARY_DOMAIN__;
    include /etc/nginx/snippets/ssl.conf;

    root /var/www/html;
    index index.html index.htm;

    access_log /var/log/nginx/main_access.log;
    error_log  /var/log/nginx/main_error.log;

    location = /healthz {
        default_type text/plain;
        return 200 "ok\n";
    }

    location / {
        try_files $uri $uri/ =404;
    }

    # 可选：静态资源缓存
    # location ~* \.(css|js|jpg|jpeg|png|gif|svg|ico|woff2?)$ {
    #     expires 30d;
    #     add_header Cache-Control "public, max-age=2592000";
    #     try_files $uri =404;
    # }
}
EOF_MAIN
    apply_placeholders "${NGINX_CONF_DIR}/main.conf"
    chmod 640 "${NGINX_CONF_DIR}/main.conf"
}

write_redirect_site() {
    if [[ "${HTTP_REDIRECT}" == "1" ]]; then
        cat > "${NGINX_CONF_DIR}/redirect-http.conf" <<'EOF_REDIRECT'
# HTTP → HTTPS 跳转
server {
    listen 80;
    listen [::]:80;
    server_name __PRIMARY_DOMAIN__;
    return 301 https://$host$request_uri;
}
EOF_REDIRECT
        apply_placeholders "${NGINX_CONF_DIR}/redirect-http.conf"
        chmod 640 "${NGINX_CONF_DIR}/redirect-http.conf"
    else
        rm -f "${NGINX_CONF_DIR}/redirect-http.conf"
    fi
}

write_stream_sni() {
    ui_step "生成 stream SNI 分流配置"
    cat > "${NGINX_STREAM_DIR}/stream_sni.conf" <<'EOF_STREAM'
# stream SNI 分流（由 install_nginx.sh 生成）
# 默认仅监听 TCP 443
map $ssl_preread_server_name $backend_name {
    __PRIMARY_DOMAIN__ main_backend;
    default            main_backend;
}

upstream main_backend {
    server 127.0.0.1:__MAIN_BACKEND_PORT__;
}

server {
    listen 443 reuseport;
    listen [::]:443 reuseport;

    ssl_preread on;
    proxy_protocol on;
    proxy_connect_timeout 10s;
    proxy_timeout 1h;

    proxy_pass $backend_name;
}
EOF_STREAM
    apply_placeholders "${NGINX_STREAM_DIR}/stream_sni.conf"
    chmod 640 "${NGINX_STREAM_DIR}/stream_sni.conf"
}

install_site_templates() {
    ui_step "安装场景模板"
    rm -f         "${NGINX_CONF_DIR}/ws.conf.example" \
        "${NGINX_CONF_DIR}/webdav.conf.example" \
        "${NGINX_CONF_DIR}/reverse-proxy.conf.example" \
        "${NGINX_CONF_DIR}/README.md"

    cat > "${NGINX_CONF_DIR}/ws.conf.example" <<'EOF_WS_TEMPLATE'
# ============================================================
# WebSocket / 长连接反向代理模板
#
# 使用步骤：
#   1. cp /etc/nginx/conf.d/ws.conf.example /etc/nginx/conf.d/ws.conf
#   2. 修改 server_name、listen 内部端口、proxy_pass 上游地址
#   3. 在 /etc/nginx/stream.conf.d/stream_sni.conf 的 map 中加入该域名，
#      并在 upstream 区域加入对应后端
#   4. nginx -t && systemctl reload nginx
#
# 证书统一来自 /etc/nginx/snippets/ssl.conf
# ============================================================
server {
    listen 127.0.0.1:12001 ssl proxy_protocol;
    http2 on;

    server_name ws.example.com;

    include /etc/nginx/snippets/ssl.conf;

    access_log /var/log/nginx/ws_access.log;
    error_log  /var/log/nginx/ws_error.log;

    location = /healthz {
        default_type text/plain;
        return 200 "ok\n";
    }

    location /ws/ {
        include /etc/nginx/snippets/proxy-common.conf;
        include /etc/nginx/snippets/websocket.conf;

        proxy_pass http://127.0.0.1:9001;

        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }

    # 可选：普通 HTTP 路径
    # location / {
    #     include /etc/nginx/snippets/proxy-common.conf;
    #     proxy_pass http://127.0.0.1:9001;
    # }

    # 可选：限制连接数
    # limit_conn conn_per_ip 10;
}
EOF_WS_TEMPLATE
    chmod 644 "${NGINX_CONF_DIR}/ws.conf.example"

    cat > "${NGINX_CONF_DIR}/webdav.conf.example" <<'EOF_WEBDAV_TEMPLATE'
# ============================================================
# WebDAV 配置模板
#
# 使用步骤：
#   1. cp /etc/nginx/conf.d/webdav.conf.example /etc/nginx/conf.d/webdav.conf
#   2. 修改 server_name、内部端口、root、认证文件路径
#   3. 创建认证文件：
#        htpasswd -B /etc/nginx/.htpasswd.webdav your_user
#   4. 在 stream_sni.conf 的 map 中加入该域名，并添加 upstream
#   5. nginx -t && systemctl reload nginx
#
# 证书统一来自 /etc/nginx/snippets/ssl.conf
# Fail2Ban 模板基于 /var/log/nginx/webdav_access.log
# ============================================================
server {
    listen 127.0.0.1:12002 ssl proxy_protocol;
    http2 on;

    server_name webdav.example.com;

    include /etc/nginx/snippets/ssl.conf;

    root /var/www/webdav;
    charset utf-8;

    access_log /var/log/nginx/webdav_access.log;
    error_log  /var/log/nginx/webdav_error.log;

    location = /healthz {
        auth_basic off;
        default_type text/plain;
        return 200 "ok\n";
    }

    location / {
        auth_basic           "WebDAV";
        auth_basic_user_file /etc/nginx/.htpasswd.webdav;

        dav_methods PUT DELETE MKCOL COPY MOVE;
        dav_ext_methods PROPFIND OPTIONS LOCK UNLOCK;
        dav_ext_lock zone=webdav;

        create_full_put_path on;
        dav_access user:rw group:r all:r;

        client_max_body_size 10G;
        client_body_timeout  3600s;

        limit_req zone=webdav_read burst=90 nodelay;
        limit_req zone=webdav_write burst=10 nodelay;
        limit_req zone=webdav_auth_limit burst=40 nodelay;
        limit_conn conn_per_ip 10;
        auth_delay 1200ms;

        autoindex off;
    }
}
EOF_WEBDAV_TEMPLATE
    chmod 644 "${NGINX_CONF_DIR}/webdav.conf.example"

    cat > "${NGINX_CONF_DIR}/reverse-proxy.conf.example" <<'EOF_REVERSE_TEMPLATE'
# ============================================================
# 通用 HTTP 反向代理模板
#
# 使用步骤：
#   1. cp /etc/nginx/conf.d/reverse-proxy.conf.example /etc/nginx/conf.d/reverse-proxy.conf
#   2. 修改 server_name、内部端口、upstream 地址
#   3. 在 stream_sni.conf 的 map 中加入该域名，并添加 upstream
#   4. nginx -t && systemctl reload nginx
#
# 证书统一来自 /etc/nginx/snippets/ssl.conf
# ============================================================
# 可选：多上游负载均衡
# upstream app_servers {
#     least_conn;
#     server 127.0.0.1:8080;
#     server 127.0.0.1:8081;
#     keepalive 32;
# }

server {
    listen 127.0.0.1:12003 ssl proxy_protocol;
    http2 on;

    server_name app.example.com;

    include /etc/nginx/snippets/ssl.conf;

    access_log /var/log/nginx/proxy_access.log;
    error_log  /var/log/nginx/proxy_error.log;

    client_max_body_size 50m;

    location = /healthz {
        default_type text/plain;
        return 200 "ok\n";
    }

    location / {
        include /etc/nginx/snippets/proxy-common.conf;
        proxy_pass http://127.0.0.1:8080;
        # 使用 upstream 时改为：
        # proxy_pass http://app_servers;

        proxy_read_timeout 60s;
        proxy_send_timeout 60s;

        # 大文件下载可关闭缓冲
        # proxy_buffering off;

        # 如需 WebSocket，取消以下注释：
        # include /etc/nginx/snippets/websocket.conf;
    }

    # 可选：CORS 示例
    # location /backend/ {
    #     include /etc/nginx/snippets/proxy-common.conf;
    #     proxy_pass http://127.0.0.1:8080;
    #     add_header Access-Control-Allow-Origin  "*" always;
    #     add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS" always;
    #     add_header Access-Control-Allow-Headers "Content-Type, Authorization" always;
    #     if ($request_method = OPTIONS) { return 204; }
    # }
}
EOF_REVERSE_TEMPLATE
    chmod 644 "${NGINX_CONF_DIR}/reverse-proxy.conf.example"

    cat > "${NGINX_CONF_DIR}/README.md" <<'EOF_TEMPLATES_README'
# Nginx 站点模板使用说明

默认生效：
- main.conf
- redirect-http.conf（HTTP_REDIRECT=1 时）

可复制模板：
- ws.conf.example（WebSocket / 长连接反代）
- webdav.conf.example（WebDAV）
- reverse-proxy.conf.example（通用 HTTP 反代）

使用：
```bash
cp /etc/nginx/conf.d/ws.conf.example /etc/nginx/conf.d/ws.conf
vim /etc/nginx/conf.d/ws.conf
```

复制后还需要在 `/etc/nginx/stream.conf.d/stream_sni.conf` 中添加域名与 upstream，
端口必须与模板中的 `listen` 一致。

最后执行：
```bash
nginx -t && systemctl reload nginx
```

所有模板统一引用 `/etc/nginx/snippets/ssl.conf`，证书来自安装时指定的路径，不会拷贝。
EOF_TEMPLATES_README
    chmod 644 "${NGINX_CONF_DIR}/README.md"

    ui_ok "模板已安装到 ${NGINX_CONF_DIR}/*.conf.example"
}

write_fail2ban_templates() {
    ui_step "生成 Fail2Ban 模板"
    if [[ "${ENABLE_FAIL2BAN_TEMPLATE}" != "1" ]]; then
        ui_info "已禁用 Fail2Ban 模板生成"
        return
    fi
    install -d -m 0755 -o root -g root /etc/nginx/security/fail2ban/filter.d
    install -d -m 0755 -o root -g root /etc/nginx/security/fail2ban/jail.d

    cat > /etc/nginx/security/fail2ban/filter.d/nginx-webdav-auth.conf <<'EOF_F2B_FILTER'
[Definition]
failregex = ^<HOST> - .* "(GET|HEAD|OPTIONS|PROPFIND|PUT|DELETE|MKCOL|COPY|MOVE|LOCK|UNLOCK) .*" 401 .*
ignoreregex =
EOF_F2B_FILTER

    cat > /etc/nginx/security/fail2ban/jail.d/nginx-webdav-auth.local <<EOF_F2B_JAIL
[nginx-webdav-auth]
enabled  = true
port     = http,https
filter   = nginx-webdav-auth
logpath  = /var/log/nginx/webdav_access.log
backend  = auto
maxretry = ${F2B_MAXRETRY}
findtime = ${F2B_FINDTIME}
bantime  = ${F2B_BANTIME}
ignoreip = ${F2B_IGNOREIP}
EOF_F2B_JAIL

    ui_ok "Fail2Ban 模板已生成：/etc/nginx/security/fail2ban/"
}

confirm_uninstall_or_exit() {
    if [[ "${PRESERVE_WWW}" == "1" ]]; then
        ui_warn "你即将执行卸载（保留 /var/www 数据目录）"
    else
        ui_warn "你即将执行彻底卸载，以下内容将被删除："
    fi
    ui_warn "1) Nginx 配置/模板/二进制: ${NGINX_DIR}"
    ui_warn "2) systemd 单元: /etc/systemd/system/nginx.service"
    ui_warn "3) 日志、运行目录、logrotate"
    if [[ "${PRESERVE_WWW}" == "1" ]]; then
        ui_warn "4) Web 目录: 保留 /var/www/html 和 /var/www/webdav"
    else
        ui_warn "4) Web 目录: /var/www/html /var/www/webdav"
    fi
    ui_warn "5) /usr/local/src 下的源码与压缩包"
    ui_warn "6) jemalloc 安装产物"
    ui_warn "7) Fail2Ban 模板/规则（若存在）"
    ui_warn "证书文件不会被删除（安装时未拷贝证书）"

    if [[ "${FORCE_UNINSTALL}" == "1" ]]; then
        ui_warn "已启用强制卸载，跳过人工确认"
        return
    fi
    if [[ "${NON_INTERACTIVE}" == "1" ]]; then
        ui_err "NON_INTERACTIVE=1 时必须配合 --yes"
        exit 1
    fi
    require_interactive_tty

    printf "\n为防误操作，请输入确认短语：%b%s%b\n" "${C_YELLOW}" "${UNINSTALL_CONFIRM_PHRASE}" "${C_RESET}"
    local user_input
    printf "> " >&2
    read_input user_input
    if [[ "${user_input}" != "${UNINSTALL_CONFIRM_PHRASE}" ]]; then
        ui_err "确认短语不匹配，已取消卸载"
        exit 1
    fi
}

stop_nginx_safely() {
    systemctl stop nginx >/dev/null 2>&1 || true
    local pid_file="/run/nginx.pid"
    local pid=""
    if [[ -f "${pid_file}" ]]; then
        pid="$(cat "${pid_file}" 2>/dev/null || true)"
    fi
    if [[ -z "${pid}" ]] || ! kill -0 "${pid}" 2>/dev/null; then
        return 0
    fi
    kill -QUIT "${pid}" 2>/dev/null || true
    local i
    for i in {1..10}; do
        kill -0 "${pid}" 2>/dev/null || return 0
        sleep 1
    done
    kill -TERM "${pid}" 2>/dev/null || true
    sleep 1
    kill -0 "${pid}" 2>/dev/null && kill -KILL "${pid}" 2>/dev/null || true
}

uninstall_generated_artifacts() {
    local preserve_www="$1"
    local context="$2"

    systemctl disable --now nginx >/dev/null 2>&1 || true
    stop_nginx_safely

    if [[ "${context}" == "rollback" && "${HAD_PREVIOUS_NGINX}" == "1" && -n "${BACKUP_DIR}" && -d "${BACKUP_DIR}/etc-nginx" ]]; then
        rm -rf "${NGINX_DIR}"
        cp -a "${BACKUP_DIR}/etc-nginx" "${NGINX_DIR}"
        if [[ -f "${BACKUP_DIR}/nginx.service" ]]; then
            rm -f /etc/systemd/system/nginx.service
            cp -a "${BACKUP_DIR}/nginx.service" /etc/systemd/system/nginx.service
        fi
        if [[ -f "${BACKUP_DIR}/logrotate-nginx" ]]; then
            cp -a "${BACKUP_DIR}/logrotate-nginx" /etc/logrotate.d/nginx
        else
            rm -f /etc/logrotate.d/nginx
        fi
        systemctl daemon-reload || true
        ui_warn "回滚完成：已恢复安装前的 /etc/nginx 与 systemd 单元"
        return
    fi

    rm -f /etc/systemd/system/nginx.service
    systemctl daemon-reload || true
    systemctl reset-failed nginx >/dev/null 2>&1 || true
    rm -f /etc/logrotate.d/nginx

    rm -rf "${NGINX_DIR}"
    rm -rf "${LOG_DIR}" "${NGINX_STATE_DIR}"
    if [[ "${preserve_www}" != "1" ]]; then
        rm -rf "${WEB_MAIN_ROOT}" "${WEB_WEBDAV_ROOT}"
    fi

    rm -f /etc/fail2ban/filter.d/nginx-webdav-auth.conf
    rm -f /etc/fail2ban/jail.d/nginx-webdav-auth.local
    rm -rf /etc/nginx/security/fail2ban

    rm -rf "${SRC_DIR}/nginx-${NGINX_VER}" \
           "${SRC_DIR}/openssl-${OPENSSL_VER}" \
           "${SRC_DIR}/ngx_brotli" \
           "${SRC_DIR}/jemalloc-${JEMALLOC_VER}" \
           "${SRC_DIR}/ngx-fancyindex-${FANCYINDEX_VER}" \
           "${SRC_DIR}/nginx-dav-ext-module-${DAV_EXT_VER}" \
           "${SRC_DIR}/headers-more-nginx-module-${HEADERS_MORE_VER}"

    rm -f "${SRC_DIR}/nginx-${NGINX_VER}.tar.gz" \
          "${SRC_DIR}/openssl-${OPENSSL_VER}.tar.gz" \
          "${SRC_DIR}/jemalloc-${JEMALLOC_VER}.tar.bz2" \
          "${SRC_DIR}/fancyindex.tar.gz" \
          "${SRC_DIR}/dav-ext.tar.gz" \
          "${SRC_DIR}/headers-more.tar.gz"

    rm -f /usr/local/lib/libjemalloc.so* \
          /usr/local/lib/libjemalloc.a \
          /usr/local/lib/libjemalloc_pic.a \
          /usr/local/lib/pkgconfig/jemalloc.pc \
          /usr/local/bin/jemalloc-config
    rm -rf /usr/local/include/jemalloc

    if [[ -f /etc/ld.so.conf.d/local.conf ]] && grep -q '^/usr/local/lib$' /etc/ld.so.conf.d/local.conf; then
        rm -f /etc/ld.so.conf.d/local.conf
    fi
    ldconfig || true

    if [[ "${context}" == "rollback" ]]; then
        ui_warn "回滚完成：已清理本次安装产生的产物"
    else
        ui_ok "卸载完成"
    fi
}

uninstall_nginx_everything() {
    confirm_uninstall_or_exit
    ui_info "开始卸载 Nginx 及相关产物"
    uninstall_generated_artifacts "${PRESERVE_WWW}" "uninstall"
}

cleanup_build_artifacts_after_install() {
    if [[ "${CLEAN_BUILD_ARTIFACTS}" != "1" ]]; then
        ui_info "已禁用编译临时文件清理"
        return
    fi
    ui_step "清理编译临时文件"
    rm -rf "${SRC_DIR}/nginx-${NGINX_VER}" \
           "${SRC_DIR}/openssl-${OPENSSL_VER}" \
           "${SRC_DIR}/ngx_brotli" \
           "${SRC_DIR}/jemalloc-${JEMALLOC_VER}" \
           "${SRC_DIR}/ngx-fancyindex-${FANCYINDEX_VER}" \
           "${SRC_DIR}/nginx-dav-ext-module-${DAV_EXT_VER}" \
           "${SRC_DIR}/headers-more-nginx-module-${HEADERS_MORE_VER}"
    rm -f "${SRC_DIR}/nginx-${NGINX_VER}.tar.gz" \
          "${SRC_DIR}/openssl-${OPENSSL_VER}.tar.gz" \
          "${SRC_DIR}/jemalloc-${JEMALLOC_VER}.tar.bz2" \
          "${SRC_DIR}/fancyindex.tar.gz" \
          "${SRC_DIR}/dav-ext.tar.gz" \
          "${SRC_DIR}/headers-more.tar.gz"
    ui_ok "编译临时文件清理完成"
}

write_systemd_unit() {
    ui_step "写入 systemd 沙箱服务"
    cat > /etc/systemd/system/nginx.service <<'EOF_SYSTEMD'
[Unit]
Description=The NGINX HTTP and reverse proxy server
After=network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/run/nginx.pid
LogsDirectory=nginx
LogsDirectoryMode=0750
ExecStartPre=/etc/nginx/sbin/nginx -t -e /var/log/nginx/error.log -c /etc/nginx/conf/nginx.conf
ExecStart=/etc/nginx/sbin/nginx -e /var/log/nginx/error.log -c /etc/nginx/conf/nginx.conf
ExecReload=/etc/nginx/sbin/nginx -s reload
ExecStop=/bin/kill -s QUIT $MAINPID

NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectClock=true
ProtectKernelLogs=true
ProtectKernelTunables=true
ProtectControlGroups=true
ProtectProc=invisible
ProcSubset=pid
LockPersonality=true
RestrictNamespaces=true
RestrictSUIDSGID=true
RestrictRealtime=true
SystemCallArchitectures=native
RemoveIPC=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6

CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_SETUID CAP_SETGID
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_SETUID CAP_SETGID

ReadWritePaths=/var/log/nginx/ /run/ /var/www/html/ /var/www/webdav/ /var/lib/nginx/

[Install]
WantedBy=multi-user.target
EOF_SYSTEMD

    systemctl daemon-reload
    systemctl enable nginx
    ui_ok "systemd 服务注册完成"
}

write_logrotate_config() {
    ui_step "写入 logrotate 策略"
    cat > /etc/logrotate.d/nginx <<'EOF_LOGROTATE'
/var/log/nginx/*.log {
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    create 0640 root www-data
    postrotate
        if [ -f /run/nginx.pid ]; then
            kill -USR1 "$(cat /run/nginx.pid)" 2>/dev/null || true
        fi
    endscript
}
EOF_LOGROTATE
    chmod 644 /etc/logrotate.d/nginx
    ui_ok "logrotate 策略已写入"
}

post_check_and_start() {
    ui_step "校验并启动 Nginx"
    ensure_runtime_dirs
    stop_nginx_safely
    ensure_ports_free_or_exit
    /etc/nginx/sbin/nginx -t -e /var/log/nginx/error.log -c /etc/nginx/conf/nginx.conf
    systemctl reset-failed nginx >/dev/null 2>&1 || true
    systemctl start nginx
    systemctl --no-pager --full status nginx >/dev/null
    ui_ok "Nginx 已通过配置测试并成功启动"
    /etc/nginx/sbin/nginx -V 2>&1 | sed 's/^/[nginx -V] /'
}

print_next_steps() {
    local http3_info="禁用"
    [[ "${HTTP3_ENABLE}" == "1" ]] && http3_info="启用，UDP/${HTTP3_PORT}"

    cat <<EOF_NEXT

${C_GREEN}============================================================${C_RESET}
${C_GREEN} 安装完成${C_RESET}
${C_GREEN}============================================================${C_RESET}

主站配置:      ${NGINX_DIR}/conf.d/main.conf
80 跳转:       $([[ "${HTTP_REDIRECT}" == "1" ]] && echo "${NGINX_DIR}/conf.d/redirect-http.conf" || echo "未生成")
Stream 分流:   ${NGINX_DIR}/stream.conf.d/stream_sni.conf
场景模板:      ${NGINX_CONF_DIR}/*.conf.example
模板说明:      ${NGINX_CONF_DIR}/README.md
统一证书:      ${SSL_CERT_PATH}（未拷贝到 /etc/nginx）
HTTP/3:        ${http3_info}

常用命令:
  /etc/nginx/sbin/nginx -t
  systemctl reload nginx
  systemctl status nginx --no-pager
  ss -lntup | grep nginx

使用模板:
  cp ${NGINX_CONF_DIR}/ws.conf.example ${NGINX_CONF_DIR}/ws.conf
  vim ${NGINX_CONF_DIR}/ws.conf
  # 按模板注释在 stream_sni.conf 添加 map/upstream
  /etc/nginx/sbin/nginx -t && systemctl reload nginx

访问测试:
  https://${PRIMARY_DOMAIN}/healthz

Fail2Ban 模板（未自动安装）:
  /etc/nginx/security/fail2ban/

证书续期后:
  systemctl reload nginx

卸载:
  sudo ./install_nginx.sh --uninstall
  sudo ./install_nginx.sh --uninstall --preserve-www
  sudo ./install_nginx.sh --uninstall --yes

EOF_NEXT
}

main() {
    setup_ui

    local arg
    for arg in "$@"; do
        case "${arg}" in
            --help|-h)
                parse_args "$@"
                ;;
        esac
    done

    require_root
    parse_args "$@"

    if [[ "${RUN_MODE}" == "uninstall" ]]; then
        uninstall_nginx_everything
        exit 0
    fi

    ui_step "检查系统兼容性"
    check_os_compat
    install_dependencies
    require_cmds
    validate_settings
    check_version_currency
    collect_main_inputs
    check_http3_port_available
    check_tcp_ports_available
    backup_existing_installation

    INSTALL_IN_PROGRESS=1

    download_sources
    compile_jemalloc
    compile_nginx
    generate_dhparam
    prepare_config_values
    write_global_config
    write_snippets
    write_main_site
    write_redirect_site
    write_stream_sni
    install_site_templates
    write_fail2ban_templates
    write_systemd_unit
    write_logrotate_config
    post_check_and_start
    cleanup_build_artifacts_after_install

    INSTALL_COMPLETED=1
    INSTALL_IN_PROGRESS=0
    print_next_steps
}

main "$@"
