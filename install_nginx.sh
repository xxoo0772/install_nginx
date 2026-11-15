#!/usr/bin/env bash

#====================================================
# 企业级 Nginx 源码编译部署脚本
# - 单文件、无 env 依赖
# - 单证书；证书路径支持按域名模板自动替换
# - stream SNI 监听 TCP HTTPS_PORT（默认 443），默认只启用 main 主站
# - HTTP/3 默认关闭，避免与其他服务抢占 UDP 端口
# - HTTP→HTTPS 跳转支持 main/base/list/all 模式
# - 场景模板安装到 conf.d/*.conf.example
# - 默认交互：先询问基础域名，再输入主站子域名
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

# ---------- 组件校验值（版本与校验值需保持一致） ----------
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
# 0=交互（推荐）；1=无交互（需填写 BASE_DOMAIN 或完整 PRIMARY_DOMAIN + 证书路径）
NON_INTERACTIVE="0"

# 基础域名（根域名）：例如 abc.com
# 交互模式下会首先询问该项；主站域名将自动由“主站子域名 + 基础域名”拼接而成
BASE_DOMAIN=""

# 主站子域名：例如 main → main.abc.com
# 留空或填写 @ 表示直接使用基础域名 abc.com
MAIN_SUBDOMAIN="main"

# 主站完整域名：一般无需填写
# 留空时自动按「MAIN_SUBDOMAIN.BASE_DOMAIN」生成；填写后以填写值为准
PRIMARY_DOMAIN=""

# ---------- 证书路径模板（推荐） ----------
# 默认证书/私钥路径模板：安装时自动替换以下占位符，无需手工输入完整路径：
#   __BASE_DOMAIN__     → 基础域名，例如 abc.com
#   __PRIMARY_DOMAIN__  → 主站完整域名，例如 main.abc.com
#
# 默认模板示例（基础域名 abc.com 时）：
#   证书 → /etc/letsencrypt/abc.com/fullchain.cer
#   私钥 → /etc/letsencrypt/abc.com/abc.com.key
#
# 如使用 certbot 默认目录，可改成：
#   SSL_CERT_PATH_TPL="/etc/letsencrypt/live/__BASE_DOMAIN__/fullchain.pem"
#   SSL_KEY_PATH_TPL="/etc/letsencrypt/live/__BASE_DOMAIN__/privkey.pem"
SSL_CERT_PATH_TPL="/etc/letsencrypt/__BASE_DOMAIN__/fullchain.cer"
SSL_KEY_PATH_TPL="/etc/letsencrypt/__BASE_DOMAIN__/__BASE_DOMAIN__.key"

# 最终证书/私钥路径：留空则使用上面的模板自动生成
# 如需手动指定某个固定文件，直接填写绝对路径即可（填写后优先使用填写值）
SSL_CERT_PATH=""
SSL_KEY_PATH=""

# ---------- 监听端口 ----------
# 对外 HTTPS/TLS 端口：stream 监听该端口，HTTP 跳转也指向该端口
HTTPS_PORT="443"
# HTTP 源端口：HTTP_REDIRECT=1 时监听该端口
HTTP_REDIRECT_PORT="80"

# HTTP → HTTPS 跳转
# 0=关闭；1=按 HTTP_REDIRECT_MODE 生成
HTTP_REDIRECT="1"
# 跳转模式：
#   main=仅主站域名
#   base=基础域名 + 主站域名
#   list=HTTP_REDIRECT_DOMAINS 中列出的域名
#   all=所有域名（default_server）
HTTP_REDIRECT_MODE="main"
# list 模式域名列表，空格分隔，例如 "abc.com www.abc.com api.abc.com"
HTTP_REDIRECT_DOMAINS=""

# main 站点内部监听端口（仅本机回环，不可使用 80/443）
MAIN_BACKEND_PORT="1111"
# 内部回环地址：IPv4 使用 127.0.0.1；IPv6 使用 "[::1]"
MAIN_BACKEND_ADDR="127.0.0.1"

# IPv6：1=同时监听 IPv4/IPv6；0=仅监听 IPv4
IPV6_ENABLE="1"

# HTTP/3：默认关闭，避免与其他服务抢占 UDP 端口
# 0=关闭（推荐，仅使用 TCP + HTTP/2）
# 1=启用（会额外监听 UDP HTTP3_PORT；如冲突请修改 HTTP3_PORT）
HTTP3_ENABLE="0"
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
# 这些变量会在 prepare_config_values() 中根据部署参数生成，
# 再通过 apply_placeholders() 替换到生成的 Nginx 配置模板中。
# 这样同一份模板既能带中文注释，又能按需开关 HTTP/3、OCSP 等功能。
#
# stream 对外监听 IPv6 行：IPV6_ENABLE=1 时生成，否则为空
STREAM_LISTEN_V6_LINE=""
# 真实 IP 的 IPv6 回环来源行：IPV6_ENABLE=1 时生成
REALIP_V6_LINE=""
# HTTP/3 监听行：启用时形如 "listen 443 quic;"，关闭时为空字符串（不渲染）
HTTP3_LISTEN_V4=""
HTTP3_LISTEN_V6=""
# HTTP/3 相关指令：启用时输出 http3/quic_retry，关闭时为空
HTTP3_ON_LINE=""
QUIC_RETRY_LINE=""
# HTTP/3 启用状态说明：作为中文注释渲染到主站配置中
HTTP3_COMMENT_LINE="# HTTP/3 未启用（默认），不监听 UDP，避免与其他 QUIC 服务抢占端口"
# Alt-Svc 响应头：启用 HTTP/3 时告知浏览器可使用 h3 协议访问
ALT_SVC_LINE=""
# OCSP Stapling 指令行：根据证书是否携带 OCSP URL 自动生成 on/off
SSL_STAPLING_LINE="ssl_stapling off;"
SSL_STAPLING_VERIFY_LINE="ssl_stapling_verify off;"
# journald 日志行：系统存在 /dev/log 时才生成，否则为空
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
READLINE_SUPPORTED=""

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

detect_readline_support() {
    [[ -n "${READLINE_SUPPORTED}" ]] && return 0
    local dummy=""
    local rc=0
    IFS= read -r -e -t 0 dummy </dev/null 2>/dev/null || rc=$?
    if [[ "${rc}" == "0" || "${rc}" == "1" ]]; then
        READLINE_SUPPORTED=1
    else
        READLINE_SUPPORTED=0
    fi
}

read_input() {
    local var="$1"
    detect_readline_support
    if [[ "${READLINE_SUPPORTED}" == "1" ]]; then
        if [[ -r /dev/tty ]]; then
            IFS= read -r -e "$var" </dev/tty || true
        else
            IFS= read -r -e "$var" || true
        fi
    else
        if [[ -r /dev/tty ]]; then
            IFS= read -r "$var" </dev/tty || true
        else
            IFS= read -r "$var" || true
        fi
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
    while true; do
        printf "%b%s%b %b%s%b " "$C_CYAN" "$label" "$C_RESET" "$C_GREEN" "$hint" "$C_RESET" >&2
        read_input answer
        answer="${answer:-${default}}"
        if [[ "${answer}" =~ ^[Yy]([Ee][Ss])?$ ]]; then
            return 0
        fi
        if [[ "${answer}" =~ ^[Nn][Oo]?$ ]]; then
            return 1
        fi
        printf "%b请输入 Y 或 N%b\n" "$C_YELLOW" "$C_RESET" >&2
    done
}

prompt_choice() {
    local label="$1"
    local default="$2"
    shift 2
    local -a choices=("$@")
    local i answer default_index=1

    for i in "${!choices[@]}"; do
        if [[ "${choices[$i]}" == "${default}" ]]; then
            default_index=$((i + 1))
        fi
    done

    {
        printf "%b%s%b\n" "$C_CYAN" "$label" "$C_RESET"
        for i in "${!choices[@]}"; do
            printf "  %b%d)%b %s\n" "$C_GREEN" "$((i + 1))" "$C_RESET" "${choices[$i]}"
        done
    } >&2

    while true; do
        printf "%b请输入编号%b [%b%d%b]: " "$C_CYAN" "$C_RESET" "$C_GREEN" "${default_index}" "$C_RESET" >&2
        read_input answer
        answer="${answer:-${default_index}}"
        if [[ "${answer}" =~ ^[0-9]+$ ]] && (( 10#${answer} >= 1 && 10#${answer} <= ${#choices[@]} )); then
            printf '%s' "${choices[$((answer - 1))]}"
            return 0
        fi
        for i in "${choices[@]}"; do
            if [[ "${answer}" == "${i}" ]]; then
                printf '%s' "${answer}"
                return 0
            fi
        done
        printf "%b无效选择，请输入 1-%d 或模式名称%b\n" "$C_YELLOW" "${#choices[@]}" "$C_RESET" >&2
    done
}

prompt_port() {
    local label="$1"
    local default="$2"
    local value=""
    while true; do
        value="$(prompt_value "${label}" "${default}")"
        if [[ "${value}" =~ ^[0-9]+$ ]] && (( 10#${value} >= 1 && 10#${value} <= 65535 )); then
            printf '%s' "${value}"
            return 0
        fi
        printf "%b端口必须是 1-65535 的整数%b\n" "$C_YELLOW" "$C_RESET" >&2
    done
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
  install_nginx.sh                     # 交互安装（先输入基础域名，再输入主站子域名）
  install_nginx.sh --non-interactive   # 无交互安装（需在脚本顶部填写 BASE_DOMAIN/证书模板）
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

# 展开证书路径模板：
#   __BASE_DOMAIN__    → 基础域名（abc.com）
#   __PRIMARY_DOMAIN__ → 主站完整域名（main.abc.com）
expand_path_template() {
    local template="$1"
    template="${template//__BASE_DOMAIN__/${BASE_DOMAIN}}"
    template="${template//__PRIMARY_DOMAIN__/${PRIMARY_DOMAIN}}"
    printf '%s' "${template}"
}

# 如果用户只提供了完整主站域名，则从第一个标签后推导基础域名：
#   main.abc.com → abc.com
derive_base_domain_from_primary() {
    if [[ -z "${BASE_DOMAIN}" && -n "${PRIMARY_DOMAIN}" && "${PRIMARY_DOMAIN}" == *.* ]]; then
        BASE_DOMAIN="${PRIMARY_DOMAIN#*.}"
        ui_info "未填写基础域名，已根据主站域名推导为: ${BASE_DOMAIN}"
    fi
}

# 根据基础域名/主站子域名拼接主站完整域名
build_primary_domain() {
    local sub="${MAIN_SUBDOMAIN:-main}"

    if [[ -z "${sub}" || "${sub}" == "@" ]]; then
        PRIMARY_DOMAIN="${BASE_DOMAIN}"
        return
    fi

    if [[ "${sub}" == "${BASE_DOMAIN}" || "${sub}" == *".${BASE_DOMAIN}" ]]; then
        PRIMARY_DOMAIN="${sub}"
    else
        PRIMARY_DOMAIN="${sub}.${BASE_DOMAIN}"
    fi
}

# 按模板生成证书/私钥路径；若用户已显式填写则优先使用填写值
resolve_cert_paths_from_template() {
    if [[ -z "${SSL_CERT_PATH}" && -n "${SSL_CERT_PATH_TPL}" ]]; then
        SSL_CERT_PATH="$(expand_path_template "${SSL_CERT_PATH_TPL}")"
    fi
    if [[ -z "${SSL_KEY_PATH}" && -n "${SSL_KEY_PATH_TPL}" ]]; then
        SSL_KEY_PATH="$(expand_path_template "${SSL_KEY_PATH_TPL}")"
    fi

    if [[ "${SSL_CERT_PATH}" == *"__BASE_DOMAIN__"* \
        || "${SSL_CERT_PATH}" == *"__PRIMARY_DOMAIN__"* \
        || "${SSL_KEY_PATH}" == *"__BASE_DOMAIN__"* \
        || "${SSL_KEY_PATH}" == *"__PRIMARY_DOMAIN__"* ]]; then
        ui_err "证书路径模板中存在无法替换的占位符，请填写 BASE_DOMAIN 或直接指定证书绝对路径"
        exit 1
    fi
}

validate_settings() {
    local name port domain
    local -a redirect_domains=()

    if [[ "${NON_INTERACTIVE}" != "0" && "${NON_INTERACTIVE}" != "1" ]]; then
        ui_err "NON_INTERACTIVE 只能是 0 或 1"
        exit 1
    fi
    if [[ "${HTTP_REDIRECT}" != "0" && "${HTTP_REDIRECT}" != "1" ]]; then
        ui_err "HTTP_REDIRECT 只能是 0 或 1"
        exit 1
    fi
    if [[ "${IPV6_ENABLE}" != "0" && "${IPV6_ENABLE}" != "1" ]]; then
        ui_err "IPV6_ENABLE 只能是 0 或 1"
        exit 1
    fi
    if [[ "${HTTP3_ENABLE}" != "0" && "${HTTP3_ENABLE}" != "1" ]]; then
        ui_err "HTTP3_ENABLE 只能是 0 或 1"
        exit 1
    fi
    case "${HTTP_REDIRECT_MODE}" in
        main|base|list|all) ;;
        *)
            ui_err "HTTP_REDIRECT_MODE 只能是 main/base/list/all，当前: ${HTTP_REDIRECT_MODE}"
            exit 1
            ;;
    esac
    for name in HTTPS_PORT HTTP_REDIRECT_PORT HTTP3_PORT MAIN_BACKEND_PORT; do
        port="${!name}"
        if [[ ! "${port}" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            ui_err "${name} 必须是 1-65535，当前: ${port}"
            exit 1
        fi
    done
    if [[ "${HTTPS_PORT}" == "${HTTP_REDIRECT_PORT}" ]]; then
        ui_err "HTTPS_PORT 不能与 HTTP_REDIRECT_PORT 相同"
        exit 1
    fi
    if [[ "${MAIN_BACKEND_PORT}" == "443" || "${MAIN_BACKEND_PORT}" == "80" \
        || "${MAIN_BACKEND_PORT}" == "${HTTPS_PORT}" \
        || "${MAIN_BACKEND_PORT}" == "${HTTP_REDIRECT_PORT}" ]]; then
        ui_err "MAIN_BACKEND_PORT 不能是 80、443、HTTPS_PORT 或 HTTP_REDIRECT_PORT"
        exit 1
    fi
    if [[ -z "${MAIN_BACKEND_ADDR}" || "${MAIN_BACKEND_ADDR}" =~ [[:space:]] ]]; then
        ui_err "MAIN_BACKEND_ADDR 不能为空且不能包含空白字符"
        exit 1
    fi
    if [[ "${MAIN_BACKEND_ADDR}" == *:* && "${MAIN_BACKEND_ADDR}" != \[*\] ]]; then
        ui_err 'MAIN_BACKEND_ADDR 的 IPv6 地址需使用 "[::1]" 形式'
        exit 1
    fi
    if [[ "${HTTP_REDIRECT}" == "1" && "${HTTP_REDIRECT_MODE}" == "list" ]]; then
        read -r -a redirect_domains <<< "${HTTP_REDIRECT_DOMAINS}"
        if (( ${#redirect_domains[@]} == 0 )); then
            ui_err "HTTP_REDIRECT_MODE=list 时必须填写 HTTP_REDIRECT_DOMAINS"
            exit 1
        fi
        for domain in "${redirect_domains[@]}"; do
            if [[ ! "${domain}" =~ ^[A-Za-z0-9.-]+$ ]]; then
                ui_err "HTTP_REDIRECT_DOMAINS 中存在非法域名: ${domain}"
                exit 1
            fi
        done
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

    local ports=("${HTTPS_PORT}" "${MAIN_BACKEND_PORT}")
    [[ "${HTTP_REDIRECT}" == "1" ]] && ports+=("${HTTP_REDIRECT_PORT}")

    local port out
    for port in "${ports[@]}"; do
        out="$(ss -lntp "sport = :${port}" 2>/dev/null | tail -n +2 || true)"
        [[ -z "${out}" ]] && continue
        if printf '%s\n' "${out}" | grep -qv 'nginx'; then
            ui_err "TCP/${port} 已被非 Nginx 进程占用："
            printf '%s\n' "${out}" | sed 's/^/[tcp] /' >&2
            ui_err "请释放该端口，或调整 HTTPS_PORT / HTTP_REDIRECT_PORT / MAIN_BACKEND_PORT"
            exit 1
        fi
    done
}

ensure_ports_free_or_exit() {
    command -v ss >/dev/null 2>&1 || return 0

    local ports=("${HTTPS_PORT}" "${MAIN_BACKEND_PORT}")
    [[ "${HTTP_REDIRECT}" == "1" ]] && ports+=("${HTTP_REDIRECT_PORT}")

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
    ui_step "采集域名与证书参数"
    require_interactive_tty

    local value=""

    # 1) 首先询问基础域名（根域名）
    while [[ -z "${BASE_DOMAIN}" ]]; do
        if [[ "${NON_INTERACTIVE}" == "1" ]]; then
            derive_base_domain_from_primary
            [[ -n "${BASE_DOMAIN}" ]] && break
            ui_err "NON_INTERACTIVE=1 但未提供 BASE_DOMAIN（也无法从 PRIMARY_DOMAIN 推导）"
            exit 1
        fi
        value="$(prompt_value "请输入基础域名（例如 abc.com）")"
        if [[ -z "${value}" ]]; then
            ui_warn "基础域名不能为空"
            continue
        fi
        if [[ ! "${value}" =~ ^[A-Za-z0-9.-]+$ ]]; then
            ui_warn "域名格式不合法"
            continue
        fi
        BASE_DOMAIN="${value}"
    done
    validate_domain_or_exit "${BASE_DOMAIN}" "基础域名"

    # 2) 主站只需输入子域名，脚本自动拼接为「子域名.基础域名」
    if [[ -z "${PRIMARY_DOMAIN}" ]]; then
        if [[ "${NON_INTERACTIVE}" != "1" ]]; then
            value="$(prompt_value "请输入主站子域名（例如 main，最终为 main.${BASE_DOMAIN}；输入 @ 使用 ${BASE_DOMAIN}）" "${MAIN_SUBDOMAIN:-main}")"
            MAIN_SUBDOMAIN="${value:-${MAIN_SUBDOMAIN:-main}}"
        fi
        [[ -z "${MAIN_SUBDOMAIN}" ]] && MAIN_SUBDOMAIN="main"
        build_primary_domain
        ui_info "主站域名: ${PRIMARY_DOMAIN}"
    fi
    validate_domain_or_exit "${PRIMARY_DOMAIN}" "主站域名"

    # 3) 对外 HTTPS 端口
    if [[ "${NON_INTERACTIVE}" != "1" ]]; then
        HTTPS_PORT="$(prompt_port "请输入对外 HTTPS 端口" "${HTTPS_PORT}")"
    fi

    # 4) 证书路径：优先使用脚本顶部模板自动生成，用户可直接回车采用默认值
    resolve_cert_paths_from_template

    local cert_default="${SSL_CERT_PATH:-}"
    local key_default="${SSL_KEY_PATH:-}"

    if [[ "${NON_INTERACTIVE}" == "1" ]]; then
        if [[ -z "${SSL_CERT_PATH}" ]]; then
            ui_err "NON_INTERACTIVE=1 但未提供 SSL_CERT_PATH 或可用模板 SSL_CERT_PATH_TPL"
            exit 1
        fi
    else
        while true; do
            value="$(prompt_value "请输入证书路径（回车使用默认值）" "${cert_default}")"
            if [[ -z "${value}" ]]; then
                ui_warn "证书路径不能为空"
                continue
            fi
            if [[ "${value}" != /* ]]; then
                ui_warn "请使用绝对路径"
                cert_default="${value}"
                continue
            fi
            if [[ ! -r "${value}" ]]; then
                ui_warn "证书不可读: ${value}"
                cert_default="${value}"
                continue
            fi
            SSL_CERT_PATH="${value}"
            break
        done
    fi

    if [[ "${NON_INTERACTIVE}" == "1" ]]; then
        if [[ -z "${SSL_KEY_PATH}" ]]; then
            ui_err "NON_INTERACTIVE=1 但未提供 SSL_KEY_PATH 或可用模板 SSL_KEY_PATH_TPL"
            exit 1
        fi
    else
        while true; do
            value="$(prompt_value "请输入私钥路径（回车使用默认值）" "${key_default}")"
            if [[ -z "${value}" ]]; then
                ui_warn "私钥路径不能为空"
                continue
            fi
            if [[ "${value}" != /* ]]; then
                ui_warn "请使用绝对路径"
                key_default="${value}"
                continue
            fi
            if [[ ! -r "${value}" ]]; then
                ui_warn "私钥不可读: ${value}"
                key_default="${value}"
                continue
            fi
            SSL_KEY_PATH="${value}"
            break
        done
    fi

    ui_step "校验证书"
    validate_cert_material "${SSL_CERT_PATH}" "${SSL_KEY_PATH}" "${PRIMARY_DOMAIN}"

    if [[ "${NON_INTERACTIVE}" != "1" ]]; then
        local default="N"
        [[ "${HTTP_REDIRECT}" == "1" ]] && default="Y"
        if prompt_yes_no "是否生成 HTTP → HTTPS 跳转？" "${default}"; then
            HTTP_REDIRECT=1
            HTTP_REDIRECT_MODE="$(prompt_choice "请选择 HTTP → HTTPS 跳转模式（main 仅主站 / base 根域+主站 / list 指定域名 / all 全部）" "${HTTP_REDIRECT_MODE}" main base list all)"
            if [[ "${HTTP_REDIRECT_MODE}" == "list" ]]; then
                while true; do
                    HTTP_REDIRECT_DOMAINS="$(prompt_value "跳转域名列表（空格分隔）" "${HTTP_REDIRECT_DOMAINS}")"
                    if [[ -z "${HTTP_REDIRECT_DOMAINS}" ]]; then
                        ui_warn "list 模式必须填写至少一个域名"
                        continue
                    fi
                    local -a redirect_domain_list=()
                    local domain=""
                    local has_invalid=0
                    read -r -a redirect_domain_list <<< "${HTTP_REDIRECT_DOMAINS}"
                    for domain in "${redirect_domain_list[@]}"; do
                        if [[ ! "${domain}" =~ ^[A-Za-z0-9.-]+$ ]]; then
                            ui_warn "域名格式不合法: ${domain}"
                            has_invalid=1
                        fi
                    done
                    if (( has_invalid == 0 )); then
                        break
                    fi
                done
            fi
            HTTP_REDIRECT_PORT="$(prompt_port "HTTP 跳转源端口" "${HTTP_REDIRECT_PORT}")"
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
    STREAM_LISTEN_V6_LINE=""
    REALIP_V6_LINE=""
    if [[ "${IPV6_ENABLE}" == "1" ]]; then
        STREAM_LISTEN_V6_LINE="listen [::]:${HTTPS_PORT} reuseport ipv6only=on;"
    fi
    if [[ "${IPV6_ENABLE}" == "1" || "${MAIN_BACKEND_ADDR}" == "[::1]" ]]; then
        REALIP_V6_LINE="set_real_ip_from ::1;"
    fi

    HTTP3_LISTEN_V4=""
    HTTP3_LISTEN_V6=""
    HTTP3_ON_LINE=""
    QUIC_RETRY_LINE=""
    ALT_SVC_LINE=""
    HTTP3_COMMENT_LINE="# HTTP/3 未启用（默认），不监听 UDP，避免与其他 QUIC 服务抢占端口"
    if [[ "${HTTP3_ENABLE}" == "1" ]]; then
        HTTP3_LISTEN_V4="listen ${HTTP3_PORT} quic;"
        if [[ "${IPV6_ENABLE}" == "1" ]]; then
            HTTP3_LISTEN_V6="listen [::]:${HTTP3_PORT} quic ipv6only=on;"
        fi
        HTTP3_ON_LINE="http3 on;"
        QUIC_RETRY_LINE="quic_retry on;"
        ALT_SVC_LINE="add_header Alt-Svc 'h3=\":${HTTP3_PORT}\"; ma=86400' always;"
        HTTP3_COMMENT_LINE="# HTTP/3 已启用：额外监听 UDP/${HTTP3_PORT}，浏览器可通过 QUIC 访问"
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
    local esc_pd esc_mp esc_mba esc_https esc_sv6 esc_rv6 esc_cert esc_key esc_v4 esc_v6 esc_h3 esc_qr esc_h3c esc_alt esc_stap esc_stapv esc_sysa esc_syse

    esc_pd="$(escape_sed_replacement "${PRIMARY_DOMAIN}")"
    esc_mp="$(escape_sed_replacement "${MAIN_BACKEND_PORT}")"
    esc_mba="$(escape_sed_replacement "${MAIN_BACKEND_ADDR}")"
    esc_https="$(escape_sed_replacement "${HTTPS_PORT}")"
    esc_sv6="$(escape_sed_replacement "${STREAM_LISTEN_V6_LINE}")"
    esc_rv6="$(escape_sed_replacement "${REALIP_V6_LINE}")"
    esc_cert="$(escape_sed_replacement "${SSL_CERT_PATH}")"
    esc_key="$(escape_sed_replacement "${SSL_KEY_PATH}")"
    esc_v4="$(escape_sed_replacement "${HTTP3_LISTEN_V4}")"
    esc_v6="$(escape_sed_replacement "${HTTP3_LISTEN_V6}")"
    esc_h3="$(escape_sed_replacement "${HTTP3_ON_LINE}")"
    esc_qr="$(escape_sed_replacement "${QUIC_RETRY_LINE}")"
    esc_h3c="$(escape_sed_replacement "${HTTP3_COMMENT_LINE}")"
    esc_alt="$(escape_sed_replacement "${ALT_SVC_LINE}")"
    esc_stap="$(escape_sed_replacement "${SSL_STAPLING_LINE}")"
    esc_stapv="$(escape_sed_replacement "${SSL_STAPLING_VERIFY_LINE}")"
    esc_sysa="$(escape_sed_replacement "${SYSLOG_ACCESS_LINE}")"
    esc_syse="$(escape_sed_replacement "${SYSLOG_ERROR_LINE}")"

    local tmp="${file}.tmp.$$"
    sed -e "s|__PRIMARY_DOMAIN__|${esc_pd}|g" \
        -e "s|__MAIN_BACKEND_PORT__|${esc_mp}|g" \
        -e "s|__MAIN_BACKEND_ADDR__|${esc_mba}|g" \
        -e "s|__HTTPS_PORT__|${esc_https}|g" \
        -e "s|__STREAM_LISTEN_V6__|${esc_sv6}|g" \
        -e "s|__REALIP_V6_LINE__|${esc_rv6}|g" \
        -e "s|__SSL_CERT_PATH__|${esc_cert}|g" \
        -e "s|__SSL_KEY_PATH__|${esc_key}|g" \
        -e "s|__HTTP3_LISTEN_V4__|${esc_v4}|g" \
        -e "s|__HTTP3_LISTEN_V6__|${esc_v6}|g" \
        -e "s|__HTTP3_ON_LINE__|${esc_h3}|g" \
        -e "s|__QUIC_RETRY_LINE__|${esc_qr}|g" \
        -e "s|__HTTP3_COMMENT_LINE__|${esc_h3c}|g" \
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
# ============================================================
# Nginx 全局配置（由 install_nginx.sh 自动生成）
#
# 阅读提示：
#   1. 以 # 开头的行为中文注释，不影响运行；
#   2. 安装时占位符会被替换为实际值；
#   3. 修改配置后请执行：nginx -t && systemctl reload nginx
# ============================================================

# 运行 Nginx worker 的系统用户/用户组
user www-data;

# worker 进程数：auto 表示按 CPU 核心数自动设置
worker_processes auto;

# 每个 worker 可打开的最大文件描述符数量
worker_rlimit_nofile 65535;

# 主进程 PID 文件位置，systemd 依赖该文件
pid /run/nginx.pid;

# ============================================================
# 事件模型：控制连接处理能力
# ============================================================
events {
    # 单个 worker 允许的最大并发连接数
    worker_connections 4096;

    # 尽可能多地接受新连接
    multi_accept on;
}

# ============================================================
# stream 四层代理：TCP __HTTPS_PORT__ 按 SNI 分流到不同后端
# - 仅监听 TCP __HTTPS_PORT__，不占用 UDP
# - 具体域名映射见 /etc/nginx/stream.conf.d/stream_sni.conf
# ============================================================
stream {
    # 记录 SNI、后端名称、流量等字段，便于排障
    log_format stream_sni '$remote_addr:$remote_port -> $server_addr:$server_port '
                          'sni="$ssl_preread_server_name" backend="$backend_name" '
                          'status=$status bytes_in=$bytes_received bytes_out=$bytes_sent';

    # SNI 分流访问日志
    access_log /var/log/nginx/stream_sni.log stream_sni;

    # 引入所有 SNI 分流规则
    include /etc/nginx/stream.conf.d/*.conf;
}

# ============================================================
# HTTP/HTTPS 主配置
# ============================================================
http {
    # MIME 类型映射与默认类型
    include       mime.types;
    default_type  application/octet-stream;

    # ---------- 真实客户端 IP ----------
    # stream 层已开启 proxy_protocol，这里从 PROXY 协议头还原客户端 IP
    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;
    __REALIP_V6_LINE__
    real_ip_recursive on;

    # ---------- 日志 ----------
    # 文件日志
    access_log /var/log/nginx/access.log;
    # journald 日志（仅当系统存在 /dev/log 时生成，否则为空行）
    __SYSLOG_ACCESS__
    error_log  /var/log/nginx/error.log warn;
    __SYSLOG_ERROR__

    # ---------- 文件传输优化 ----------
    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;

    # 隐藏响应头中的 Nginx 版本号
    server_tokens   off;

    # ---------- 打开文件缓存 ----------
    # 减少频繁 stat/open 文件带来的磁盘开销
    open_file_cache max=10000 inactive=30s;
    open_file_cache_valid 30s;
    open_file_cache_min_uses 2;
    open_file_cache_errors on;

    # 使用线程池处理异步文件 I/O
    aio threads;

    # ---------- 临时目录 ----------
    # 大请求体、代理等场景的临时文件位置
    client_body_temp_path /var/lib/nginx/client_temp;
    proxy_temp_path       /var/lib/nginx/proxy_temp;
    fastcgi_temp_path     /var/lib/nginx/fastcgi_temp;
    uwsgi_temp_path       /var/lib/nginx/uwsgi_temp;
    scgi_temp_path        /var/lib/nginx/scgi_temp;

    # ---------- 缓冲区与超时 ----------
    # 请求体/请求头缓冲区大小
    client_body_buffer_size      16k;
    client_header_buffer_size    1k;
    large_client_header_buffers  4 8k;
    # 各类超时时间，防止慢连接长期占用资源
    client_body_timeout          12s;
    client_header_timeout        12s;
    keepalive_timeout            65s;
    send_timeout                 10s;

    # ---------- 限流/限连区域 ----------
    # 普通请求限速：每 IP 每秒 10 个请求
    limit_req_zone $binary_remote_addr zone=one:10m rate=10r/s;
    # WebDAV 读取限速
    limit_req_zone $binary_remote_addr zone=webdav_read:10m rate=180r/m;
    # 仅对 WebDAV 写方法按 IP 限速
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
    # WebDAV 认证失败限速
    limit_req_zone $binary_remote_addr zone=webdav_auth_limit:20m rate=120r/m;
    # 每 IP 并发连接数限制
    limit_conn_zone $binary_remote_addr zone=conn_per_ip:10m;
    # WebDAV 文件锁区域
    dav_ext_lock_zone zone=webdav:10m;
    # 触发限流/限连时返回 429
    limit_req_status 429;
    limit_conn_status 429;

    # ---------- 基础安全响应头 ----------
    # 防止点击劫持
    add_header X-Frame-Options "SAMEORIGIN" always;
    # 禁止浏览器猜测 MIME 类型
    add_header X-Content-Type-Options "nosniff" always;
    # 限制 Referer 泄露
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    # 强制 HTTPS（按需调整 max-age 或去掉 includeSubDomains）
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    # 关闭不必要的浏览器权限
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=(), payment=()" always;
    # 内容安全策略，可按站点实际资源来源调整
    add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'self';" always;

    # ---------- HTTP/3 Alt-Svc 响应头 ----------
    # 仅在 HTTP3_ENABLE=1 时生成；用于告知浏览器可改用 h3 协议访问
    __ALT_SVC_HEADER__

    # ---------- TLS 基础参数 ----------
    # 仅启用 TLS 1.2 / TLS 1.3
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    # 推荐的高强度加密套件
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    # DH 参数文件（安装时自动生成）
    ssl_dhparam /etc/nginx/ssl/dhparam.pem;
    # TLS 会话缓存，减少重复握手开销
    ssl_session_cache shared:SSL:50m;
    ssl_session_timeout 1d;
    # 关闭会话票据，降低前向安全性风险
    ssl_session_tickets off;

    # ---------- OCSP Stapling ----------
    # 证书带 OCSP URL 时自动开启，否则自动关闭（见安装脚本逻辑）
    __SSL_STAPLING_LINE__
    __SSL_STAPLING_VERIFY_LINE__
    # 用于解析 OCSP 服务器域名
    resolver 223.5.5.5 1.1.1.1 valid=300s;
    resolver_timeout 5s;

    # ---------- Brotli 压缩 ----------
    # 动态压缩开关与压缩级别
    brotli on;
    brotli_comp_level 6;
    # 若存在预压缩的 .br 文件则优先直接返回
    brotli_static on;
    brotli_types application/javascript application/json application/xml text/css text/plain;

    # ---------- 站点配置 ----------
    # main.conf、redirect-http.conf 及用户新增站点均放在 conf.d 下
    include /etc/nginx/conf.d/*.conf;
}
EOF_NGINX
    apply_placeholders "${NGINX_DIR}/conf/nginx.conf"
    chmod 640 "${NGINX_DIR}/conf/nginx.conf"
}

write_snippets() {
    install -d -m 0755 -o root -g root "${NGINX_SNIPPET_DIR}"

    cat > "${NGINX_SNIPPET_DIR}/ssl.conf" <<'EOF_SSL'
# ============================================================
# 统一证书配置（由 install_nginx.sh 自动生成）
#
# 说明：
#   - 证书直接引用安装时指定的原始路径
#   - 所有站点、模板统一通过 include 本文件复用同一张证书
#   - 证书续期后只需 systemctl reload nginx，无需改动站点配置
# ============================================================

# 服务器证书（建议使用 fullchain 完整证书链）
ssl_certificate         __SSL_CERT_PATH__;

# 证书对应的私钥
ssl_certificate_key     __SSL_KEY_PATH__;

# 受信任证书链，用于 OCSP Stapling 校验
ssl_trusted_certificate __SSL_CERT_PATH__;
EOF_SSL
    apply_placeholders "${NGINX_SNIPPET_DIR}/ssl.conf"
    chmod 640 "${NGINX_SNIPPET_DIR}/ssl.conf"

    cat > "${NGINX_SNIPPET_DIR}/proxy-common.conf" <<'EOF_PROXY_COMMON'
# ============================================================
# 反向代理公共配置
#
# 作用：统一设置代理协议版本与转发头
# 用法：在 location 中 include /etc/nginx/snippets/proxy-common.conf;
#
# 超时、缓冲区、请求体大小属于场景差异项，在站点模板中单独配置
# ============================================================

# 与上游服务使用 HTTP/1.1，兼容长连接与 WebSocket
proxy_http_version 1.1;

# 转发原始 Host、客户端 IP 与协议类型
proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;

# 上游返回的重定向不自动改写
proxy_redirect off;
EOF_PROXY_COMMON
    chmod 644 "${NGINX_SNIPPET_DIR}/proxy-common.conf"

    cat > "${NGINX_SNIPPET_DIR}/websocket.conf" <<'EOF_WS_SNIPPET'
# ============================================================
# WebSocket / 长连接协议切换配置
#
# 用法：在 location 中先 include proxy-common.conf，再 include 本文件
#       include /etc/nginx/snippets/proxy-common.conf;
#       include /etc/nginx/snippets/websocket.conf;
#
# proxy-common.conf 已提供 proxy_http_version 1.1
# ============================================================

# 传递协议切换头
proxy_set_header Upgrade    $http_upgrade;
proxy_set_header Connection "upgrade";

# 关闭代理缓冲，降低长连接消息延迟
proxy_buffering off;

# 保持与上游的长连接
proxy_socket_keepalive on;
EOF_WS_SNIPPET
    chmod 644 "${NGINX_SNIPPET_DIR}/websocket.conf"
}

write_main_site() {
    ui_step "生成 main 主站配置"
    cat > "${NGINX_CONF_DIR}/main.conf" <<'EOF_MAIN'
# ============================================================
# 主站（main）配置（由 install_nginx.sh 自动生成）
#
# 架构说明：
#   - 外部客户端先连接 stream 层的 TCP __HTTPS_PORT__（见 stream_sni.conf）
#   - stream 层按 SNI 将流量转发到本文件监听的内部回环端口
#   - 本文件只监听 __MAIN_BACKEND_ADDR__，不直接暴露到公网
#
# 当前主站域名：__PRIMARY_DOMAIN__
# 证书配置：由 /etc/nginx/snippets/ssl.conf 统一提供
# ============================================================
server {
    # ---------- 内部监听 ----------
    # 仅绑定本机回环地址，端口由脚本 MAIN_BACKEND_PORT 决定
    # ssl：TLS 握手与解密在此层完成，Nginx 是 TLS 端点；客户端连接不会被中断
    # proxy_protocol：接收 stream 层传来的真实客户端 IP
    listen __MAIN_BACKEND_ADDR__:__MAIN_BACKEND_PORT__ ssl proxy_protocol;

    # ---------- HTTP/3 / QUIC 监听 ----------
    # 由脚本顶部 HTTP3_ENABLE 控制；开启后会额外监听 UDP 端口
    # HTTP/3 的 TLS 握手同样在 Nginx 完成，并非中断客户端访问
    __HTTP3_COMMENT_LINE__
    __HTTP3_LISTEN_V4__
    __HTTP3_LISTEN_V6__

    # ---------- 协议支持 ----------
    # HTTP/2 基于 TCP，始终开启
    http2 on;

    # 以下两条仅在 HTTP/3 启用时生成，关闭时为空
    __HTTP3_ON_LINE__
    __QUIC_RETRY_LINE__

    # ---------- 域名与证书 ----------
    # 主站域名由「主站子域名 + 基础域名」自动拼接
    server_name __PRIMARY_DOMAIN__;

    # 统一证书配置
    include /etc/nginx/snippets/ssl.conf;

    # ---------- 站点根目录 ----------
    # 默认首页文件
    root /var/www/html;
    index index.html index.htm;

    # ---------- 请求体大小 ----------
    # 静态站点通常无需上传，按需调整
    client_max_body_size 10m;

    # ---------- 日志 ----------
    access_log /var/log/nginx/main_access.log;
    error_log  /var/log/nginx/main_error.log;

    # ---------- 健康检查 ----------
    # 用于负载均衡/监控探活，返回纯文本 ok
    location = /healthz {
        default_type text/plain;
        return 200 "ok\n";
    }

    # ---------- 静态文件 ----------
    # 按请求路径查找文件，不存在时返回 404
    location / {
        try_files $uri $uri/ =404;
    }

    # ---------- 可选：静态资源缓存 ----------
    # 启用后可减少重复请求，按需取消注释
    # 注意：location 内一旦使用 add_header，会覆盖 http 层安全响应头
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
    if [[ "${HTTP_REDIRECT}" != "1" ]]; then
        rm -f "${NGINX_CONF_DIR}/redirect-http.conf"
        return
    fi

    local suffix=""
    [[ "${HTTPS_PORT}" != "443" ]] && suffix=":${HTTPS_PORT}"

    local listen_v4_line="    listen ${HTTP_REDIRECT_PORT};"
    local listen_v6_line=""
    if [[ "${IPV6_ENABLE}" == "1" ]]; then
        listen_v6_line="    listen [::]:${HTTP_REDIRECT_PORT} ipv6only=on;"
    fi

    local server_name=""
    local return_line=""

    case "${HTTP_REDIRECT_MODE}" in
        main)
            server_name="${PRIMARY_DOMAIN}"
            return_line="    return 301 https://${PRIMARY_DOMAIN}${suffix}\$request_uri;"
            ;;
        base)
            if [[ "${BASE_DOMAIN}" == "${PRIMARY_DOMAIN}" ]]; then
                server_name="${BASE_DOMAIN}"
            else
                server_name="${BASE_DOMAIN} ${PRIMARY_DOMAIN}"
            fi
            return_line="    return 301 https://\$host${suffix}\$request_uri;"
            ;;
        list)
            server_name="${HTTP_REDIRECT_DOMAINS}"
            return_line="    return 301 https://\$host${suffix}\$request_uri;"
            ;;
        all)
            listen_v4_line="    listen ${HTTP_REDIRECT_PORT} default_server;"
            if [[ "${IPV6_ENABLE}" == "1" ]]; then
                listen_v6_line="    listen [::]:${HTTP_REDIRECT_PORT} default_server ipv6only=on;"
            fi
            server_name="_"
            return_line="    return 301 https://\$host${suffix}\$request_uri;"
            ;;
    esac

    local default_block=""
    if [[ "${HTTP_REDIRECT_MODE}" != "all" ]]; then
        local default_v6_line=""
        if [[ "${IPV6_ENABLE}" == "1" ]]; then
            default_v6_line="    listen [::]:${HTTP_REDIRECT_PORT} default_server ipv6only=on;"
        fi
        default_block=$(cat <<EOF_DEFAULT

# 未匹配域名兜底：直接断开，避免误跳转
server {
    listen ${HTTP_REDIRECT_PORT} default_server;
${default_v6_line}
    server_name _;
    return 444;
}
EOF_DEFAULT
)
    fi

    cat > "${NGINX_CONF_DIR}/redirect-http.conf" <<EOF_REDIRECT
# ============================================================
# HTTP → HTTPS 跳转（由 install_nginx.sh 自动生成）
#
# 模式：${HTTP_REDIRECT_MODE}
# 源端口：${HTTP_REDIRECT_PORT}
# 目标端口：${HTTPS_PORT}
# 关闭方式：脚本顶部设置 HTTP_REDIRECT="0"
# ============================================================
server {
${listen_v4_line}
${listen_v6_line}
    server_name ${server_name};

    # 301 永久跳转，保留原始路径与查询参数
${return_line}
}
${default_block}
EOF_REDIRECT
    chmod 640 "${NGINX_CONF_DIR}/redirect-http.conf"
}

write_stream_sni() {
    ui_step "生成 stream SNI 分流配置"
    cat > "${NGINX_STREAM_DIR}/stream_sni.conf" <<'EOF_STREAM'
# ============================================================
# stream SNI 分流配置（由 install_nginx.sh 自动生成）
#
# 作用：
#   - 仅监听 TCP __HTTPS_PORT__（不占用 UDP）
#   - 在 TLS 握手前读取 SNI 域名
#   - 按域名把流量转发到对应的内部后端
#
# 当前仅启用 main 主站；新增站点时：
#   1. 在 map 中增加「域名 后端名称;」
#   2. 在 upstream 区域增加同名后端
#   3. nginx -t && systemctl reload nginx
# ============================================================

# 根据 SNI 选择后端名称；未匹配的域名默认回到 main 主站
map $ssl_preread_server_name $backend_name {
    __PRIMARY_DOMAIN__ main_backend;
    default            main_backend;
}

# main 主站内部后端：与 conf.d/main.conf 的 listen 地址和端口保持一致
upstream main_backend {
    server __MAIN_BACKEND_ADDR__:__MAIN_BACKEND_PORT__;
}

server {
    # 对外监听 TCP __HTTPS_PORT__，reuseport 提升多 worker 下的分发性能
    listen __HTTPS_PORT__ reuseport;
    __STREAM_LISTEN_V6__

    # 开启 SNI 预读，在不解密 TLS 的情况下拿到域名
    ssl_preread on;

    # 向后端传递 PROXY 协议头，便于还原真实客户端 IP
    proxy_protocol on;

    # 连接后端超时
    proxy_connect_timeout 10s;

    # 长连接保持时间，适配 WebSocket / 大流量场景
    proxy_timeout 1h;

    # 按 map 结果转发
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
    # 如需内部 IPv6 回环，改用：
    # listen [::1]:12001 ssl proxy_protocol;

    http2 on;

    server_name ws.example.com;

    include /etc/nginx/snippets/ssl.conf;

    # 请求体大小
    client_max_body_size 50m;

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

        # 长连接超时
        proxy_connect_timeout 10s;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    # 可选：普通 HTTP 路径
    # location / {
    #     include /etc/nginx/snippets/proxy-common.conf;
    #     proxy_pass http://127.0.0.1:9001;
    #
    #     proxy_connect_timeout 10s;
    #     proxy_read_timeout 60s;
    #     proxy_send_timeout 60s;
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
    # 如需内部 IPv6 回环，改用：
    # listen [::1]:12002 ssl proxy_protocol;

    http2 on;

    server_name webdav.example.com;

    include /etc/nginx/snippets/ssl.conf;

    root /var/www/webdav;
    charset utf-8;

    # 上传大小与超时
    client_max_body_size    10G;
    client_body_buffer_size 128k;
    client_body_timeout     3600s;
    send_timeout            3600s;

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
#     # server [::1]:8080;
#     keepalive 32;
# }

server {
    listen 127.0.0.1:12003 ssl proxy_protocol;
    # 如需内部 IPv6 回环，改用：
    # listen [::1]:12003 ssl proxy_protocol;

    http2 on;

    server_name app.example.com;

    include /etc/nginx/snippets/ssl.conf;

    # 请求体大小与请求体缓冲
    client_max_body_size    50m;
    client_body_buffer_size 128k;

    access_log /var/log/nginx/proxy_access.log;
    error_log  /var/log/nginx/proxy_error.log;

    location = /healthz {
        default_type text/plain;
        return 200 "ok\n";
    }

    location / {
        include /etc/nginx/snippets/proxy-common.conf;
        proxy_pass http://127.0.0.1:8080;
        # 使用 upstream 时改为：
        # proxy_pass http://app_servers;

        # 与上游连接、读写超时
        proxy_connect_timeout 10s;
        proxy_read_timeout    60s;
        proxy_send_timeout    60s;

        # 上游响应缓冲
        proxy_buffer_size       16k;
        proxy_buffers           8 16k;
        proxy_busy_buffers_size 32k;

        # 普通反向代理保持与上游的长连接
        # 启用 WebSocket 时由 websocket.conf 提供该指令
        # proxy_socket_keepalive on;

        # 大文件上传/下载场景按需取消注释
        # proxy_request_buffering off;
        # proxy_max_temp_file_size 0;

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

内部回环默认使用 `127.0.0.1`；如需 IPv6，将模板中的 `listen` 和
`stream_sni.conf` 中的 upstream 地址改为 `[::1]`。

模板中的职责划分：

- `snippets/ssl.conf`：证书、私钥、信任链
- `snippets/proxy-common.conf`：HTTP/1.1、转发头、`proxy_redirect off`
- `snippets/websocket.conf`：Upgrade/Connection、关闭缓冲、上游长连接，需在 `proxy-common.conf` 之后 include
- 超时、缓冲区、请求体大小：在各站点模板中独立配置

最后执行：
```bash
nginx -t && systemctl reload nginx
```

所有模板统一引用 `/etc/nginx/snippets/ssl.conf`，证书直接使用安装时指定的路径。
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
    ui_warn "证书文件保持原位，不会被删除"

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
    local ipv6_info="禁用"
    [[ "${IPV6_ENABLE}" == "1" ]] && ipv6_info="启用，双栈监听"
    local https_suffix=""
    [[ "${HTTPS_PORT}" != "443" ]] && https_suffix=":${HTTPS_PORT}"
    local redirect_info="未生成"
    if [[ "${HTTP_REDIRECT}" == "1" ]]; then
        redirect_info="${HTTP_REDIRECT_MODE}，${HTTP_REDIRECT_PORT} → ${HTTPS_PORT}"
    fi

    cat <<EOF_NEXT

${C_GREEN}============================================================${C_RESET}
${C_GREEN} 安装完成${C_RESET}
${C_GREEN}============================================================${C_RESET}

基础域名:      ${BASE_DOMAIN}
主站子域名:    ${MAIN_SUBDOMAIN}
主站配置:      ${NGINX_DIR}/conf.d/main.conf
主站域名:      ${PRIMARY_DOMAIN}
HTTPS 端口:    ${HTTPS_PORT}
HTTP 跳转:     ${redirect_info}
IPv6:          ${ipv6_info}
Stream 分流:   ${NGINX_DIR}/stream.conf.d/stream_sni.conf (TCP ${HTTPS_PORT})
场景模板:      ${NGINX_CONF_DIR}/*.conf.example
模板说明:      ${NGINX_CONF_DIR}/README.md
统一证书:      ${SSL_CERT_PATH}
统一私钥:      ${SSL_KEY_PATH}
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
  https://${PRIMARY_DOMAIN}${https_suffix}/healthz

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
    check_version_currency
    collect_main_inputs
    validate_settings
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
