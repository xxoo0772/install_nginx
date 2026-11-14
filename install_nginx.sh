#!/usr/bin/env bash

#====================================================
# 企业级 Nginx 源码编译部署脚本
# 目标系统: Debian 11+/13
# 核心特性: PCRE2 + QuicTLS + Brotli + WebDAV + Systemd 沙箱
#====================================================

set -Eeuo pipefail
umask 027

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/env}"

#================= 版本参数（可用环境变量覆盖，升级时同步更新哈希/commit） =================
NGINX_VER="${NGINX_VER:-1.31.8}"
JEMALLOC_VER="${JEMALLOC_VER:-5.4.0}"
FANCYINDEX_VER="${FANCYINDEX_VER:-0.6.0}"
DAV_EXT_VER="${DAV_EXT_VER:-3.0.0}"
HEADERS_MORE_VER="${HEADERS_MORE_VER:-0.41}"
OPENSSL_VER="${OPENSSL_VER:-3.5.9}"
NGX_BROTLI_REF="${NGX_BROTLI_REF:-v1.0.0rc}"

#================= 路径参数 =================
SRC_DIR="/usr/local/src"
NGINX_DIR="/etc/nginx"
NGINX_CONF_DIR="${NGINX_DIR}/conf.d"
NGINX_STREAM_DIR="${NGINX_DIR}/stream.conf.d"
NGINX_SSL_DIR="${NGINX_DIR}/ssl"
NGINX_STATE_DIR="/var/lib/nginx"

#================= 安全策略参数 =================
# STRICT_SUPPLYCHAIN=1: 未提供哈希值就拒绝继续（推荐生产环境）
# STRICT_SUPPLYCHAIN=0: 仅警告并继续（测试环境）
STRICT_SUPPLYCHAIN="${STRICT_SUPPLYCHAIN:-1}"
# STRICT_CERT_SAN=1: 证书 SAN 未覆盖目标域名时拒绝执行（推荐生产环境）
STRICT_CERT_SAN="${STRICT_CERT_SAN:-1}"

# 如需严格校验，请填写准确 SHA256（留空会触发 STRICT_SUPPLYCHAIN 逻辑）
NGINX_TARBALL_SHA256="${NGINX_TARBALL_SHA256:-}"
JEMALLOC_TARBALL_SHA256="${JEMALLOC_TARBALL_SHA256:-}"
FANCYINDEX_TARBALL_SHA256="${FANCYINDEX_TARBALL_SHA256:-}"
DAV_EXT_TARBALL_SHA256="${DAV_EXT_TARBALL_SHA256:-}"
HEADERS_MORE_TARBALL_SHA256="${HEADERS_MORE_TARBALL_SHA256:-}"
OPENSSL_TARBALL_SHA256="${OPENSSL_TARBALL_SHA256:-}"

# Git 仓库 commit 固定点（建议生产环境务必填写）
NGX_BROTLI_COMMIT="${NGX_BROTLI_COMMIT:-}"

THREADS="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)"
# 编译告警选项（按编译器能力动态探测，兼容 GCC 10 / 11+）
CC_WARN_OPT=""

#================= 交互输入（可用环境变量预置） =================
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
MAIN_DOMAIN="${MAIN_DOMAIN:-}"
DAV_DOMAIN="${DAV_DOMAIN:-}"
API_DOMAIN="${API_DOMAIN:-}"
TUN_DOMAIN="${TUN_DOMAIN:-}"

MAIN_CERT_SRC="${MAIN_CERT_SRC:-}"
MAIN_KEY_SRC="${MAIN_KEY_SRC:-}"
DAV_CERT_SRC="${DAV_CERT_SRC:-}"
DAV_KEY_SRC="${DAV_KEY_SRC:-}"
API_CERT_SRC="${API_CERT_SRC:-}"
API_KEY_SRC="${API_KEY_SRC:-}"
TUN_CERT_SRC="${TUN_CERT_SRC:-}"
TUN_KEY_SRC="${TUN_KEY_SRC:-}"
# 证书复用开关：1=若未显式提供则复用主站证书，0=必须单独提供
DAV_REUSE_MAIN_CERT="${DAV_REUSE_MAIN_CERT:-1}"
API_REUSE_MAIN_CERT="${API_REUSE_MAIN_CERT:-1}"
TUN_REUSE_MAIN_CERT="${TUN_REUSE_MAIN_CERT:-1}"
VLESS_UPSTREAM="${VLESS_UPSTREAM:-http://127.0.0.1:10000}"

#================= HTTP/3 (QUIC) =================
# 1=启用 Nginx HTTP/3；0=不监听 UDP（适用于其他应用占用 443/udp）
HTTP3_ENABLE="${HTTP3_ENABLE:-1}"
# Nginx QUIC 监听端口；若 443/udp 被占用，可改为 8443 等并放行防火墙
HTTP3_PORT="${HTTP3_PORT:-443}"

#================= 内部 Stream/web_mux 端口（可避开主机其他应用） =================
MAIN_MUX_PORT="${MAIN_MUX_PORT:-1111}"
WEB_MUX_PORT="${WEB_MUX_PORT:-7443}"
TUN_MUX_PORT="${TUN_MUX_PORT:-9443}"

#================= OCSP stapling =================
# auto=证书含 OCSP URL 时启用；on=强制启用；off=关闭
OCSP_STAPLING="${OCSP_STAPLING:-auto}"

MAIN_CERT_DST=""
MAIN_KEY_DST=""
DAV_CERT_DST=""
DAV_KEY_DST=""
API_CERT_DST=""
API_KEY_DST=""
TUN_CERT_DST=""
TUN_KEY_DST=""
CAN_START_NGINX=1
SKIP_START_REASON=""

#================= WebDAV 暴力破解防护（Fail2Ban） =================
ENABLE_FAIL2BAN_TEMPLATE="${ENABLE_FAIL2BAN_TEMPLATE:-1}"
F2B_MAXRETRY="${F2B_MAXRETRY:-6}"
F2B_FINDTIME="${F2B_FINDTIME:-10m}"
F2B_BANTIME="${F2B_BANTIME:-12h}"
F2B_IGNOREIP="${F2B_IGNOREIP:-127.0.0.1/8 ::1}"
# 编译缓存清理：1=安装成功后清理 /usr/local/src 下本脚本下载的临时源码，0=保留
CLEAN_BUILD_ARTIFACTS="${CLEAN_BUILD_ARTIFACTS:-1}"

#================= 运行模式 =================
RUN_MODE="install"
FORCE_UNINSTALL="${FORCE_UNINSTALL:-0}"
PRESERVE_WWW="${PRESERVE_WWW:-0}"
UNINSTALL_CONFIRM_PHRASE="UNINSTALL NGINX"
INSTALL_IN_PROGRESS=0
INSTALL_COMPLETED=0
ROLLBACK_ON_ERROR="${ROLLBACK_ON_ERROR:-1}"
BACKUP_DIR=""
HAD_PREVIOUS_NGINX=0
ROLLBACK_IN_PROGRESS=0

#================= 彩色输出 =================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[36m"
RESET="\033[0m"

log_info()  { echo -e "${BLUE}[信息]${RESET} $*"; }
log_ok()    { echo -e "${GREEN}[成功]${RESET} $*"; }
log_warn()  { echo -e "${YELLOW}[警告]${RESET} $*"; }
log_err()   { echo -e "${RED}[错误]${RESET} $*" >&2; }

load_env_file() {
    local required="${1:-1}"
    local env_file="${ENV_FILE}"

    if [[ ! -f "${env_file}" ]]; then
        # 兼容旧文件名（迁移期）
        if [[ "${env_file}" == "${SCRIPT_DIR}/env" && -f "${SCRIPT_DIR}/nginx-build.env" ]]; then
            env_file="${SCRIPT_DIR}/nginx-build.env"
            log_warn "检测到旧版 nginx-build.env，建议执行: mv nginx-build.env env"
        elif [[ "${required}" == "0" ]]; then
            log_warn "未找到配置文件 ${env_file}，卸载模式将使用脚本默认值"
            return 0
        else
            log_err "未找到配置文件: ${env_file}"
            log_err "请先执行: cp ${SCRIPT_DIR}/env.example ${SCRIPT_DIR}/env"
            log_err "然后编辑 ${SCRIPT_DIR}/env，填入你的域名与证书路径"
            log_err "也可通过 ENV_FILE=/path/to/env 指定其他配置文件"
            exit 1
        fi
    fi

    local perms
    perms="$(stat -c '%a' "${env_file}" 2>/dev/null || true)"
    if [[ -n "${perms}" && "${perms}" =~ [2367]$ ]]; then
        log_warn "配置文件 ${env_file} 对组或其他用户可写，建议执行: chmod 600 ${env_file}"
    fi

    log_info "加载配置文件: ${env_file}"
    set -a
    # shellcheck disable=SC1090
    if ! source "${env_file}"; then
        set +a
        log_err "配置文件加载失败: ${env_file}"
        exit 1
    fi
    set +a
}

on_error() {
    local exit_code="$1"
    local line_no="$2"
    log_err "脚本在第 ${line_no} 行失败，退出码=${exit_code}"

    if [[ "${RUN_MODE}" == "install" && "${INSTALL_IN_PROGRESS}" == "1" && "${INSTALL_COMPLETED}" == "0" && "${ROLLBACK_ON_ERROR}" == "1" && "${ROLLBACK_IN_PROGRESS}" == "0" ]]; then
        ROLLBACK_IN_PROGRESS=1
        log_warn "检测到安装中断，开始自动回滚到未安装状态"
        uninstall_generated_artifacts "0" "rollback"
    fi

    exit "${exit_code}"
}
trap 'on_error $? $LINENO' ERR

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_err "必须以 root 身份执行"
        exit 1
    fi
}

require_cmds() {
    local cmds=(apt-get curl wget git tar make gcc g++ sha256sum systemctl openssl)
    local c
    for c in "${cmds[@]}"; do
        command -v "${c}" >/dev/null 2>&1 || {
            log_err "缺少命令: ${c}"
            exit 1
        }
    done
}

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
            --help|-h)
                cat <<'EOF_HELP'
Usage:
  install_nginx.sh                 # 安装/部署模式（自动加载同目录 env）
  install_nginx.sh --interactive   # 安装时交互输入缺失参数
  install_nginx.sh --uninstall     # 卸载模式（会删除安装产物）
  install_nginx.sh --uninstall -y  # 非交互强制卸载
  install_nginx.sh --uninstall --preserve-www

Environment:
  ENV_FILE=/path/to/env            # 指定配置文件（默认：脚本同目录/env）
EOF_HELP
                exit 0
                ;;
            *)
                log_err "未知参数: $1"
                log_err "可用参数: --interactive, --uninstall, --preserve-www, --yes|-y, --help|-h"
                exit 1
                ;;
        esac
    done
}

escape_sed_replacement() {
    printf '%s' "$1" | sed -e 's/[\\/&|]/\\&/g'
}

validate_domain_or_exit() {
    local v="$1"
    local label="$2"
    if [[ ! "${v}" =~ ^[A-Za-z0-9.-]+$ ]]; then
        log_err "${label} 格式不合法: ${v}"
        exit 1
    fi
}

validate_http3_or_exit() {
    if [[ "${HTTP3_ENABLE}" != "0" && "${HTTP3_ENABLE}" != "1" ]]; then
        log_err "HTTP3_ENABLE 只能是 0 或 1，当前: ${HTTP3_ENABLE}"
        exit 1
    fi
    if [[ ! "${HTTP3_PORT}" =~ ^[0-9]+$ ]] || (( HTTP3_PORT < 1 || HTTP3_PORT > 65535 )); then
        log_err "HTTP3_PORT 必须是 1-65535，当前: ${HTTP3_PORT}"
        exit 1
    fi
}

validate_internal_settings_or_exit() {
    local name port
    for name in MAIN_MUX_PORT WEB_MUX_PORT TUN_MUX_PORT; do
        port="${!name}"
        if [[ ! "${port}" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            log_err "${name} 必须是 1-65535，当前: ${port}"
            exit 1
        fi
    done
    if [[ "${OCSP_STAPLING}" != "auto" && "${OCSP_STAPLING}" != "on" && "${OCSP_STAPLING}" != "off" ]]; then
        log_err "OCSP_STAPLING 只能是 auto/on/off，当前: ${OCSP_STAPLING}"
        exit 1
    fi
    if [[ "${MAIN_MUX_PORT}" == "${WEB_MUX_PORT}" || "${MAIN_MUX_PORT}" == "${TUN_MUX_PORT}" || "${WEB_MUX_PORT}" == "${TUN_MUX_PORT}" ]]; then
        log_err "MAIN_MUX_PORT / WEB_MUX_PORT / TUN_MUX_PORT 不能相同"
        exit 1
    fi
    local public_port
    for public_port in 443 2096 2099 8443; do
        if [[ "${MAIN_MUX_PORT}" == "${public_port}" || "${WEB_MUX_PORT}" == "${public_port}" || "${TUN_MUX_PORT}" == "${public_port}" ]]; then
            log_err "内部端口不能与公开监听端口冲突: ${public_port}"
            exit 1
        fi
    done
}

check_http3_port_available() {
    [[ "${HTTP3_ENABLE}" == "1" ]] || return 0
    command -v ss >/dev/null 2>&1 || return 0

    # 重装场景：旧 Nginx 自身占用该端口是正常的
    if [[ -f /run/nginx.pid ]]; then
        local nginx_pid
        nginx_pid="$(cat /run/nginx.pid 2>/dev/null || true)"
        if [[ -n "${nginx_pid}" ]] && kill -0 "${nginx_pid}" 2>/dev/null; then
            return 0
        fi
    fi

    if ss -lunH "sport = :${HTTP3_PORT}" 2>/dev/null | grep -q .; then
        log_err "UDP/${HTTP3_PORT} 已被占用，Nginx HTTP/3 无法绑定"
        ss -lunp "sport = :${HTTP3_PORT}" 2>/dev/null | sed 's/^/[udp] /' || true
        log_err "处理方式：设置 HTTP3_ENABLE=0（关闭 Nginx HTTP/3），或设置 HTTP3_PORT=<其他 UDP 端口>"
        exit 1
    fi
}

check_internal_tcp_ports() {
    command -v ss >/dev/null 2>&1 || return 0

    local entry port label out
    for entry in "443:HTTPS" "2096:stream" "2099:stream" "8443:stream" \
                 "${MAIN_MUX_PORT}:main_mux" "${WEB_MUX_PORT}:web_mux" "${TUN_MUX_PORT}:tun_mux"; do
        port="${entry%%:*}"
        label="${entry#*:}"
        out="$(ss -lntp "sport = :${port}" 2>/dev/null | tail -n +2 || true)"
        [[ -z "${out}" ]] && continue
        if printf '%s\n' "${out}" | grep -qv 'nginx'; then
            log_err "TCP/${port} (${label}) 已被非 Nginx 进程占用："
            printf '%s\n' "${out}" | sed 's/^/[tcp] /' >&2
            log_err "请释放该端口；内部端口可通过 MAIN_MUX_PORT/WEB_MUX_PORT/TUN_MUX_PORT 调整"
            exit 1
        fi
    done
    log_info "TCP 端口检查通过（现有 Nginx 占用将在启动前安全停止）"
}

ensure_ports_free_or_exit() {
    command -v ss >/dev/null 2>&1 || return 0

    local entry port label out
    for entry in "443:HTTPS" "2096:stream" "2099:stream" "8443:stream" \
                 "${MAIN_MUX_PORT}:main_mux" "${WEB_MUX_PORT}:web_mux" "${TUN_MUX_PORT}:tun_mux"; do
        port="${entry%%:*}"
        label="${entry#*:}"
        out="$(ss -lntp "sport = :${port}" 2>/dev/null | tail -n +2 || true)"
        if [[ -n "${out}" ]]; then
            log_err "TCP/${port} (${label}) 在停止旧 Nginx 后仍被占用："
            printf '%s\n' "${out}" | sed 's/^/[tcp] /' >&2
            log_err "请先停止占用进程；内部端口可通过 MAIN_MUX_PORT/WEB_MUX_PORT/TUN_MUX_PORT 调整"
            exit 1
        fi
    done
}

require_readable_file_or_exit() {
    local f="$1"
    local label="$2"
    if [[ -z "${f}" || ! -f "${f}" || ! -r "${f}" ]]; then
        log_err "${label} 不存在或不可读: ${f}"
        exit 1
    fi
}

check_version_currency() {
    local warnings=""
    local minor=""
    local ossl_minor=""
    if [[ "${NGINX_VER}" =~ ^1\.([0-9]+)\. ]]; then
        minor="${BASH_REMATCH[1]}"
        if (( minor < 29 )); then
            warnings+="Nginx ${NGINX_VER} 缺少 HTTP/3/WebDAV/TLS 等安全修复，建议升级到 1.29+；"
        fi
    fi
    if [[ "${OPENSSL_VER}" =~ ^3\.([0-9]+)\. ]]; then
        ossl_minor="${BASH_REMATCH[1]}"
        if (( ossl_minor < 5 )); then
            warnings+="OpenSSL ${OPENSSL_VER} 不支持原生服务端 QUIC，建议使用 3.5 LTS；"
        fi
    fi
    if [[ -n "${warnings}" ]]; then
        log_warn "版本时效性提示：${warnings}"
        log_warn "升级时请同步更新 NGINX_VER / OPENSSL_VER、各 SHA256 与 commit pin，否则严格供应链模式会拒绝执行"
    fi
}

backup_existing_installation() {
    if [[ -e "${NGINX_DIR}" || -e /etc/systemd/system/nginx.service ]]; then
        HAD_PREVIOUS_NGINX=1
        BACKUP_DIR="/var/backups/nginx-install-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "${BACKUP_DIR}"
        if [[ -e "${NGINX_DIR}" ]]; then
            cp -a "${NGINX_DIR}" "${BACKUP_DIR}/etc-nginx"
        fi
        if [[ -e /etc/systemd/system/nginx.service ]]; then
            cp -a /etc/systemd/system/nginx.service "${BACKUP_DIR}/nginx.service"
        fi
        if [[ -e /etc/logrotate.d/nginx ]]; then
            cp -a /etc/logrotate.d/nginx "${BACKUP_DIR}/logrotate-nginx"
        fi
        log_warn "检测到既有 Nginx 安装，已备份到 ${BACKUP_DIR}（回滚将从该备份恢复）"
    else
        log_info "未检测到既有 Nginx 安装，可安全执行全新部署"
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
        if [[ "${san}" == "${domain}" ]]; then
            return 0
        fi
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
    local label="$4"

    if ! openssl x509 -in "${cert}" -noout >/dev/null 2>&1; then
        log_err "${label}证书无法解析: ${cert}"
        exit 1
    fi
    if ! openssl pkey -in "${key}" -noout >/dev/null 2>&1; then
        log_err "${label}私钥无法解析: ${key}"
        exit 1
    fi
    if ! openssl x509 -in "${cert}" -noout -checkend 0 >/dev/null 2>&1; then
        log_err "${label}证书已过期: ${cert}"
        exit 1
    fi
    if ! openssl x509 -in "${cert}" -noout -checkend 1209600 >/dev/null 2>&1; then
        log_warn "${label}证书将在 14 天内过期，请及时续期: ${cert}"
    fi
    if ! cert_and_key_match "${cert}" "${key}"; then
        log_err "${label}证书与私钥不匹配: ${cert} / ${key}"
        exit 1
    fi
    if ! cert_covers_domain "${cert}" "${domain}"; then
        if [[ "${STRICT_CERT_SAN}" == "1" ]]; then
            log_err "${label}证书 SAN 未覆盖域名 ${domain}: ${cert}"
            log_err "请提供覆盖该域名的证书，或设置 STRICT_CERT_SAN=0 仅告警"
            exit 1
        fi
        log_warn "${label}证书 SAN 未覆盖域名 ${domain}，当前为宽松模式继续"
    else
        log_ok "${label}证书校验通过（域名 ${domain}）"
    fi
}

certs_support_ocsp() {
    local cert found=0
    for cert in "${MAIN_CERT_SRC}" "${DAV_CERT_SRC}" "${API_CERT_SRC}" "${TUN_CERT_SRC}"; do
        [[ -z "${cert}" ]] && continue
        found=1
        if ! openssl x509 -in "${cert}" -noout -ocsp_uri 2>/dev/null | grep -q .; then
            return 1
        fi
    done
    [[ "${found}" == "1" ]]
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


check_os_compat() {
    if [[ ! -r /etc/os-release ]]; then
        log_err "无法识别系统版本（/etc/os-release 不存在）"
        exit 1
    fi

    # shellcheck disable=SC1091
    source /etc/os-release

    case "${ID:-}" in
        debian)
            local ver="${VERSION_ID%%.*}"
            if (( ver < 11 )); then
                log_err "Debian 版本过低，要求 Debian 11+"
                exit 1
            fi
            ;;
        ubuntu)
            local ver="${VERSION_ID%%.*}"
            if (( ver < 22 )); then
                log_err "Ubuntu 版本过低，要求 Ubuntu 22.04+"
                exit 1
            fi
            ;;
        *)
            log_warn "当前系统 ID=${ID:-unknown}，未在声明兼容列表内，将继续执行"
            ;;
    esac

    log_ok "系统兼容性检查通过 (${PRETTY_NAME:-unknown})"
}

verify_sha256_or_policy() {
    local file="$1"
    local expected_sha="$2"

    if [[ -n "${expected_sha}" ]]; then
        local actual_sha
        actual_sha="$(sha256sum "${file}" | awk '{print $1}')"
        if [[ "${actual_sha}" != "${expected_sha}" ]]; then
            log_err "SHA256 校验失败: ${file}"
            log_err "期望: ${expected_sha}"
            log_err "实际: ${actual_sha}"
            exit 1
        fi
        log_ok "SHA256 校验通过: ${file}"
        return
    fi

    if [[ "${STRICT_SUPPLYCHAIN}" == "1" ]]; then
        log_err "严格供应链模式已启用，但未提供 ${file} 的 SHA256"
        log_err "请设置对应环境变量后重试，或显式设置 STRICT_SUPPLYCHAIN=0（仅测试环境）"
        exit 1
    fi

    log_warn "未提供 ${file} 的 SHA256，当前为非严格模式，继续执行"
}

clone_with_optional_pin() {
    local repo_url="$1"
    local dest_dir="$2"
    local ref="$3"
    local expected_commit="$4"

    [[ -d "${dest_dir}" ]] && rm -rf "${dest_dir}"

    if [[ -n "${expected_commit}" ]]; then
        # 优先按精确 commit 抓取，避免分支/tag 漂移
        if git init -q "${dest_dir}" 2>/dev/null \
            && git -C "${dest_dir}" remote add origin "${repo_url}" 2>/dev/null \
            && git -C "${dest_dir}" fetch --depth 1 origin "${expected_commit}" >/dev/null 2>&1; then
            git -C "${dest_dir}" checkout -q FETCH_HEAD
        else
            log_warn "无法按 commit 直接抓取，回退到 ref=${ref} 克隆: ${dest_dir}"
            rm -rf "${dest_dir}"
            git clone --depth 1 -b "${ref}" "${repo_url}" "${dest_dir}"
        fi
        local actual_commit
        actual_commit="$(git -C "${dest_dir}" rev-parse HEAD)"
        if [[ "${actual_commit}" != "${expected_commit}" ]]; then
            log_err "仓库 commit 校验失败: ${dest_dir}"
            log_err "期望: ${expected_commit}"
            log_err "实际: ${actual_commit}"
            exit 1
        fi
        log_ok "仓库 commit 校验通过: ${dest_dir}"
    else
        git clone --depth 1 -b "${ref}" "${repo_url}" "${dest_dir}"
        if [[ "${STRICT_SUPPLYCHAIN}" == "1" ]]; then
            log_err "严格供应链模式启用，但 ${dest_dir} 未设置 commit 固定点"
            exit 1
        fi
        log_warn "${dest_dir} 未设置 commit 固定点，当前为非严格模式，继续执行"
    fi
}

install_dependencies() {
    log_info "安装编译依赖"
    apt-get update -y
    apt-get install -y --no-install-recommends \
        ca-certificates build-essential libpcre2-dev zlib1g-dev \
        libssl-dev wget git curl lsof cmake pkg-config openssl \
        logrotate libunwind-dev perl libxml2-dev libxslt1-dev \
        apache2-utils

    if ! id -u www-data >/dev/null 2>&1; then
        useradd -r -s /usr/sbin/nologin www-data
        log_ok "已创建 www-data 用户"
    else
        log_info "www-data 用户已存在，跳过创建"
    fi

    log_ok "依赖安装完成"
}

download_sources() {
    log_info "下载源码并进行供应链校验"
    mkdir -p "${SRC_DIR}"
    cd "${SRC_DIR}"

    # 1) Nginx 主包（必须 HTTPS）
    wget -O "nginx-${NGINX_VER}.tar.gz" "https://nginx.org/download/nginx-${NGINX_VER}.tar.gz"
    verify_sha256_or_policy "nginx-${NGINX_VER}.tar.gz" "${NGINX_TARBALL_SHA256}"
    tar -zxf "nginx-${NGINX_VER}.tar.gz"

    # 2) OpenSSL 3.5 LTS（原生服务端 QUIC，替代已归档的 quictls）
    wget -O "openssl-${OPENSSL_VER}.tar.gz" \
        "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VER}/openssl-${OPENSSL_VER}.tar.gz"
    verify_sha256_or_policy "openssl-${OPENSSL_VER}.tar.gz" "${OPENSSL_TARBALL_SHA256}"
    tar -zxf "openssl-${OPENSSL_VER}.tar.gz"

    # 3) ngx_brotli（Git 仓库 commit pin）
    clone_with_optional_pin "https://github.com/google/ngx_brotli.git" "ngx_brotli" "${NGX_BROTLI_REF}" "${NGX_BROTLI_COMMIT}"
    git -C ngx_brotli submodule update --init --recursive

    # 4) tarball 模块
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

    log_ok "源码下载完成"
}

detect_cc_warn_opt() {
    CC_WARN_OPT=""
    local cc_version major
    cc_version="$(cc --version 2>/dev/null || true)"
    # 仅 GCC 11+ 认识 -Wvla-parameter；GCC 10（Debian 11）不添加该选项
    if [[ "${cc_version}" != *"Free Software Foundation"* && "${cc_version}" != *"gcc version"* && "${cc_version}" != *"GCC"* ]]; then
        log_info "非 GCC 编译器，跳过 -Wno-error=vla-parameter"
        return 0
    fi
    major="$(cc -dumpversion 2>/dev/null | cut -d. -f1 || true)"
    if [[ ! "${major}" =~ ^[0-9]+$ ]] || (( major < 11 )); then
        log_info "GCC ${major:-unknown} < 11，跳过 -Wno-error=vla-parameter"
        return 0
    fi
    CC_WARN_OPT="-Wno-error=vla-parameter"
    log_info "GCC ${major} 启用 -Wno-error=vla-parameter（ngx_brotli 兼容）"
}

compile_jemalloc() {
    log_info "编译并安装 jemalloc"
    cd "${SRC_DIR}/jemalloc-${JEMALLOC_VER}"
    ./configure
    make -j "${THREADS}"
    make install

    echo '/usr/local/lib' > /etc/ld.so.conf.d/local.conf
    ldconfig
    log_ok "jemalloc 安装完成"
}

compile_nginx() {
    log_info "编译并安装 Nginx"
    detect_cc_warn_opt
    cd "${SRC_DIR}/nginx-${NGINX_VER}"

    # 关键要求：configure 参数必须使用 Bash 数组，避免引号展开问题
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

    mkdir -p "${NGINX_CONF_DIR}" "${NGINX_STREAM_DIR}" "${NGINX_SSL_DIR}" "${NGINX_DIR}/conf"
    mkdir -p /var/www/html /var/www/dav
    install -d -m 0750 -o root -g www-data /var/log/nginx
    ensure_runtime_dirs
    chown -R www-data:www-data /var/www/html /var/www/dav
    touch /var/log/nginx/access.log /var/log/nginx/error.log /var/log/nginx/dav_access.log /var/log/nginx/dav_error.log
    chown root:www-data /var/log/nginx/access.log /var/log/nginx/error.log /var/log/nginx/dav_access.log /var/log/nginx/dav_error.log
    chmod 0640 /var/log/nginx/access.log /var/log/nginx/error.log /var/log/nginx/dav_access.log /var/log/nginx/dav_error.log
    chmod 700 "${NGINX_SSL_DIR}"

    # DAV 认证文件按最小权限创建；若已存在且非空则保留，避免重装清空账号
    if [[ ! -s "${NGINX_DIR}/dav.pass.public" ]]; then
        install -m 640 -o root -g www-data /dev/null "${NGINX_DIR}/dav.pass.public"
    else
        chown root:www-data "${NGINX_DIR}/dav.pass.public"
        chmod 640 "${NGINX_DIR}/dav.pass.public"
        log_info "已保留现有 DAV 认证文件: ${NGINX_DIR}/dav.pass.public"
    fi

    log_ok "Nginx 编译安装完成"
}

ensure_runtime_dirs() {
    # Debian 系在沙箱/AppArmor 下更常用 /var/lib/nginx 作为运行态目录
    # 显式设置为 root:www-data + 0770，避免在最小能力集下触发 DAC 拒绝
    install -d -m 0770 -o root -g www-data "${NGINX_STATE_DIR}"
    install -d -m 0770 -o root -g www-data "${NGINX_STATE_DIR}/client_temp"
    install -d -m 0770 -o root -g www-data "${NGINX_STATE_DIR}/proxy_temp"
    install -d -m 0770 -o root -g www-data "${NGINX_STATE_DIR}/fastcgi_temp"
    install -d -m 0770 -o root -g www-data "${NGINX_STATE_DIR}/uwsgi_temp"
    install -d -m 0770 -o root -g www-data "${NGINX_STATE_DIR}/scgi_temp"

}

generate_dhparam() {
    log_info "生成 DH 参数（首次执行耗时较长）"
    if [[ ! -f "${NGINX_SSL_DIR}/dhparam.pem" ]]; then
        openssl dhparam -out "${NGINX_SSL_DIR}/dhparam.pem" 2048
        chmod 600 "${NGINX_SSL_DIR}/dhparam.pem"
        log_ok "DH 参数生成完成"
    else
        log_info "已存在 dhparam.pem，跳过生成"
    fi
}

collect_deploy_inputs() {
    log_info "采集部署参数（可提前用环境变量 MAIN_DOMAIN/DAV_DOMAIN/API_DOMAIN 等预置）"

    if [[ "${NON_INTERACTIVE}" != "1" && -z "${MAIN_DOMAIN}" ]]; then
        read -r -p "请输入主站完整域名（例如 main.abc.com）: " MAIN_DOMAIN
    fi
    if [[ "${NON_INTERACTIVE}" != "1" && -z "${DAV_DOMAIN}" ]]; then
        read -r -p "请输入 WebDAV 完整域名（例如 dav.abc.com）: " DAV_DOMAIN
    fi
    if [[ "${NON_INTERACTIVE}" != "1" && -z "${API_DOMAIN}" ]]; then
        read -r -p "请输入 API 完整域名（例如 api.abc.com）: " API_DOMAIN
    fi
    if [[ "${NON_INTERACTIVE}" != "1" && -z "${TUN_DOMAIN}" ]]; then
        read -r -p "请输入 TUN（Tunnel）完整域名（例如 tun.abc.com）: " TUN_DOMAIN
    fi

    if [[ -z "${MAIN_DOMAIN}" || -z "${DAV_DOMAIN}" || -z "${API_DOMAIN}" || -z "${TUN_DOMAIN}" ]]; then
        log_err "域名参数不完整。请提供 MAIN_DOMAIN、DAV_DOMAIN、API_DOMAIN、TUN_DOMAIN"
        exit 1
    fi

    validate_domain_or_exit "${MAIN_DOMAIN}" "主站域名"
    validate_domain_or_exit "${DAV_DOMAIN}" "WebDAV 域名"
    validate_domain_or_exit "${API_DOMAIN}" "API 域名"
    validate_domain_or_exit "${TUN_DOMAIN}" "TUN（Tunnel）域名"

    if [[ "${NON_INTERACTIVE}" != "1" && -z "${MAIN_CERT_SRC}" ]]; then
        read -r -p "请输入主站证书文件路径（.crt/.pem，全链）: " MAIN_CERT_SRC
    fi
    if [[ "${NON_INTERACTIVE}" != "1" && -z "${MAIN_KEY_SRC}" ]]; then
        read -r -p "请输入主站私钥文件路径（.key）: " MAIN_KEY_SRC
    fi

    if [[ "${NON_INTERACTIVE}" != "1" && -z "${DAV_CERT_SRC}" ]]; then
        read -r -p "请输入 WebDAV 证书文件路径（回车默认使用主站证书）: " DAV_CERT_SRC
    fi
    if [[ "${NON_INTERACTIVE}" != "1" && -z "${DAV_KEY_SRC}" ]]; then
        read -r -p "请输入 WebDAV 私钥文件路径（回车默认使用主站私钥）: " DAV_KEY_SRC
    fi

    if [[ "${NON_INTERACTIVE}" != "1" && -z "${API_CERT_SRC}" ]]; then
        read -r -p "请输入 API 证书文件路径（回车默认使用主站证书）: " API_CERT_SRC
    fi
    if [[ "${NON_INTERACTIVE}" != "1" && -z "${API_KEY_SRC}" ]]; then
        read -r -p "请输入 API 私钥文件路径（回车默认使用主站私钥）: " API_KEY_SRC
    fi
    if [[ "${NON_INTERACTIVE}" != "1" && -z "${TUN_CERT_SRC}" ]]; then
        read -r -p "请输入 TUN（Tunnel）证书文件路径（回车默认使用主站证书）: " TUN_CERT_SRC
    fi
    if [[ "${NON_INTERACTIVE}" != "1" && -z "${TUN_KEY_SRC}" ]]; then
        read -r -p "请输入 TUN（Tunnel）私钥文件路径（回车默认使用主站私钥）: " TUN_KEY_SRC
    fi

    # 支持纯 env 部署：通过复用开关自动继承主站证书
    if [[ "${DAV_REUSE_MAIN_CERT}" == "1" ]]; then
        DAV_CERT_SRC="${DAV_CERT_SRC:-${MAIN_CERT_SRC}}"
        DAV_KEY_SRC="${DAV_KEY_SRC:-${MAIN_KEY_SRC}}"
    fi
    if [[ "${API_REUSE_MAIN_CERT}" == "1" ]]; then
        API_CERT_SRC="${API_CERT_SRC:-${MAIN_CERT_SRC}}"
        API_KEY_SRC="${API_KEY_SRC:-${MAIN_KEY_SRC}}"
    fi
    if [[ "${TUN_REUSE_MAIN_CERT}" == "1" ]]; then
        TUN_CERT_SRC="${TUN_CERT_SRC:-${MAIN_CERT_SRC}}"
        TUN_KEY_SRC="${TUN_KEY_SRC:-${MAIN_KEY_SRC}}"
    fi

    MAIN_CERT_DST="${NGINX_SSL_DIR}/${MAIN_DOMAIN}.crt"
    MAIN_KEY_DST="${NGINX_SSL_DIR}/${MAIN_DOMAIN}.key"
    DAV_CERT_DST="${NGINX_SSL_DIR}/${DAV_DOMAIN}.crt"
    DAV_KEY_DST="${NGINX_SSL_DIR}/${DAV_DOMAIN}.key"
    API_CERT_DST="${NGINX_SSL_DIR}/${API_DOMAIN}.crt"
    API_KEY_DST="${NGINX_SSL_DIR}/${API_DOMAIN}.key"
    TUN_CERT_DST="${NGINX_SSL_DIR}/${TUN_DOMAIN}.crt"
    TUN_KEY_DST="${NGINX_SSL_DIR}/${TUN_DOMAIN}.key"

    if [[ -n "${MAIN_CERT_SRC}" && -n "${MAIN_KEY_SRC}" && -n "${DAV_CERT_SRC}" && -n "${DAV_KEY_SRC}" && -n "${API_CERT_SRC}" && -n "${API_KEY_SRC}" && -n "${TUN_CERT_SRC}" && -n "${TUN_KEY_SRC}" ]]; then
        require_readable_file_or_exit "${MAIN_CERT_SRC}" "主站证书"
        require_readable_file_or_exit "${MAIN_KEY_SRC}" "主站私钥"
        require_readable_file_or_exit "${DAV_CERT_SRC}" "WebDAV 证书"
        require_readable_file_or_exit "${DAV_KEY_SRC}" "WebDAV 私钥"
        require_readable_file_or_exit "${API_CERT_SRC}" "API 证书"
        require_readable_file_or_exit "${API_KEY_SRC}" "API 私钥"
        require_readable_file_or_exit "${TUN_CERT_SRC}" "TUN（Tunnel）证书"
        require_readable_file_or_exit "${TUN_KEY_SRC}" "TUN（Tunnel）私钥"

        validate_cert_material "${MAIN_CERT_SRC}" "${MAIN_KEY_SRC}" "${MAIN_DOMAIN}" "主站"
        validate_cert_material "${DAV_CERT_SRC}" "${DAV_KEY_SRC}" "${DAV_DOMAIN}" "WebDAV"
        validate_cert_material "${API_CERT_SRC}" "${API_KEY_SRC}" "${API_DOMAIN}" "API"
        validate_cert_material "${TUN_CERT_SRC}" "${TUN_KEY_SRC}" "${TUN_DOMAIN}" "TUN（Tunnel）"
    else
        if [[ "${NON_INTERACTIVE}" == "1" ]]; then
            CAN_START_NGINX=0
            SKIP_START_REASON="NON_INTERACTIVE 模式未提供完整证书/私钥路径"
            log_warn "${SKIP_START_REASON}，将仅完成编译与配置写入，不启动 Nginx"
        else
            log_err "交互模式下必须提供完整证书和私钥"
            exit 1
        fi
    fi

    log_ok "部署参数采集完成"
}

import_tls_certs() {
    log_info "导入证书到 ${NGINX_SSL_DIR}"

    if [[ "${CAN_START_NGINX}" != "1" ]]; then
        log_warn "跳过证书导入：${SKIP_START_REASON}"
        return
    fi

    # 证书权限策略：
    # - 证书文件: root:root 0644（公开材料，可读）
    # - 私钥文件: root:root 0600（仅 root 可读，最小权限）
    install -m 644 -o root -g root "${MAIN_CERT_SRC}" "${MAIN_CERT_DST}"
    install -m 600 -o root -g root "${MAIN_KEY_SRC}" "${MAIN_KEY_DST}"
    install -m 644 -o root -g root "${DAV_CERT_SRC}" "${DAV_CERT_DST}"
    install -m 600 -o root -g root "${DAV_KEY_SRC}" "${DAV_KEY_DST}"
    install -m 644 -o root -g root "${API_CERT_SRC}" "${API_CERT_DST}"
    install -m 600 -o root -g root "${API_KEY_SRC}" "${API_KEY_DST}"
    install -m 644 -o root -g root "${TUN_CERT_SRC}" "${TUN_CERT_DST}"
    install -m 600 -o root -g root "${TUN_KEY_SRC}" "${TUN_KEY_DST}"

    log_ok "证书导入完成"
}

write_nginx_configs() {
    log_info "写入 Nginx 配置"

    # 全局安全策略（0-RTT 已禁用：与 ssl_session_tickets off 保持一致，规避重放风险）
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

    # 真实客户端 IP 识别（stream + proxy_protocol 回传）
    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;
    set_real_ip_from ::1;
    real_ip_recursive on;

    # 企业场景双通道日志：文件落盘 + journald（按 /dev/log 是否存在动态注入）
    access_log /var/log/nginx/access.log;
    __SYSLOG_ACCESS__
    error_log  /var/log/nginx/error.log warn;
    __SYSLOG_ERROR__

    sendfile      on;
    tcp_nopush    on;
    tcp_nodelay   on;
    server_tokens off;

    # 静态资源元数据缓存（WebDAV 目录会在 location 内关闭，避免元数据过期）
    open_file_cache max=10000 inactive=30s;
    open_file_cache_valid 30s;
    open_file_cache_min_uses 2;
    open_file_cache_errors on;

    # 大文件异步 IO（WebDAV/静态下载）
    aio threads;

    # 运行时临时文件目录
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
    # WebDAV 读请求放宽（挂载盘/同步客户端会产生大量 PROPFIND）
    limit_req_zone $binary_remote_addr zone=webdav_read:10m rate=180r/m;
    # 仅对写方法生效的限速键（空键表示不限速）
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
    # 认证爆破防护：放宽到可用阈值，真正封禁交给 auth_delay + fail2ban
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

    # OCSP stapling（证书内需含完整中间链；无外网时仅告警不阻断启动）
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

    cat > "${NGINX_STREAM_DIR}/stream_sni.conf" <<'EOF_STREAM'
map $ssl_preread_server_name $backend_name {
    # 纯写死精确匹配（企业可读性优先）
    __MAIN_DOMAIN__ proxy_main;
    __TUN_DOMAIN__  proxy_tun;
    # API/DAV 统一转发到 web_mux，再由 HTTP server_name 做 L7 分流
    __DAV_DOMAIN__  proxy_web_mux;
    __API_DOMAIN__  proxy_web_mux;
    default         proxy_main;
}

upstream proxy_main { server 127.0.0.1:__MAIN_MUX_PORT__; }
upstream proxy_tun  { server 127.0.0.1:__TUN_MUX_PORT__; }
upstream proxy_web_mux { server 127.0.0.1:__WEB_MUX_PORT__; }

server {
    listen 443 reuseport;
    listen 2096 reuseport;
    listen 2099 reuseport;
    listen 8443 reuseport;

    listen [::]:443 reuseport;
    listen [::]:2096 reuseport;
    listen [::]:2099 reuseport;
    listen [::]:8443 reuseport;

    ssl_preread on;
    proxy_protocol on;
    proxy_connect_timeout 10s;
    # 默认 10m 会切断 TUN（Tunnel）/WebSocket 长连接，显式放宽
    proxy_timeout 1h;
    proxy_pass $backend_name;
}
EOF_STREAM

    cat > "${NGINX_CONF_DIR}/proxy_site.conf" <<'EOF_PROXY'
server {
    listen 127.0.0.1:__MAIN_MUX_PORT__ ssl proxy_protocol;
    # HTTP/3 直连 UDP 443，与 stream 的 TCP SNI 分流并存
    # HTTP/3 监听（由 HTTP3_ENABLE / HTTP3_PORT 动态生成）
    __HTTP3_LISTEN_V4__
    __HTTP3_LISTEN_V6__
    http2 on;
    http3 on;
    quic_retry on;

    server_name __MAIN_DOMAIN__;

    # 传递真实来源 IP 给后端应用（供审计、风控、限流使用）
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    ssl_certificate          __MAIN_CERT__;
    ssl_certificate_key      __MAIN_KEY__;
    ssl_trusted_certificate  __MAIN_CERT__;

    more_clear_headers 'X-Powered-By';

    root /var/www/html;
    index index.html index.htm;

    limit_req zone=one burst=20 nodelay;

    location = /healthz {
        default_type text/plain;
        return 200 "ok\n";
    }

    location = / {
        default_type text/plain;
        return 200 "Welcome to NGINX\n";
    }

    location / {
        try_files $uri $uri/ =404;
    }

    location /ws_endpoint/ {
        proxy_redirect off;
        proxy_read_timeout 1200s;
        proxy_pass http://127.0.0.1:1000;
        proxy_http_version 1.1;

        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $http_host;
    }
}
EOF_PROXY

    cat > "${NGINX_CONF_DIR}/webdav_drive.conf" <<'EOF_DAV'
server {
    # web_mux: API + WebDAV 在同一内网端口按 server_name 分流
    listen 127.0.0.1:__WEB_MUX_PORT__ ssl proxy_protocol;
    # HTTP/3 监听（由 HTTP3_ENABLE / HTTP3_PORT 动态生成）
    __HTTP3_LISTEN_V4__
    __HTTP3_LISTEN_V6__
    http2 on;
    http3 on;
    quic_retry on;

    server_name __DAV_DOMAIN__;

    # 传递真实来源 IP 给后端应用（供审计、风控、限流使用）
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    ssl_certificate          __DAV_CERT__;
    ssl_certificate_key      __DAV_KEY__;
    ssl_trusted_certificate  __DAV_CERT__;

    more_clear_headers 'X-Powered-By';

    access_log /var/log/nginx/dav_access.log;
    __SYSLOG_DAV_ACCESS__
    error_log  /var/log/nginx/dav_error.log;

    location = /healthz {
        auth_basic off;
        default_type text/plain;
        return 200 "ok\n";
    }

    location / {
        root /var/www/dav;
        charset utf-8;

        # WebDAV 需实时元数据，关闭全局 open_file_cache
        open_file_cache off;

        fancyindex on;
        fancyindex_exact_size off;

        # 读请求与写方法分层限速 + 并发控制
        limit_req zone=webdav_read burst=90 nodelay;
        limit_req zone=webdav_write burst=10 nodelay;
        limit_conn conn_per_ip 6;
        # 认证层限速 + 统一延迟，真正封禁交给 fail2ban
        limit_req zone=webdav_auth_limit burst=40 nodelay;
        auth_delay 1200ms;
        # 降低无效连接长占用
        keepalive_timeout 20s;

        client_max_body_size 50G;
        client_body_timeout 3600s;

        create_full_put_path on;
        dav_access user:rw group:r all:r;

        auth_basic "Private Cloud";
        auth_basic_user_file /etc/nginx/dav.pass.public;

        set $dest $http_destination;
        if (-d $request_filename) {
            rewrite ^(.*[^/])$ $1/;
            set $dest $dest/;
        }
        if ($request_method ~ (MOVE|COPY)) {
            more_set_input_headers 'Destination: $dest';
        }
        if ($request_method ~ MKCOL) {
            rewrite ^(.*[^/])$ $1/ break;
        }

        dav_methods PUT DELETE MKCOL COPY MOVE;
        dav_ext_methods PROPFIND OPTIONS LOCK UNLOCK;
        dav_ext_lock zone=webdav;
    }
}
EOF_DAV

    cat > "${NGINX_CONF_DIR}/api_site.conf" <<'EOF_API'
server {
    listen 127.0.0.1:__WEB_MUX_PORT__ ssl proxy_protocol;
    # HTTP/3 监听（由 HTTP3_ENABLE / HTTP3_PORT 动态生成）
    __HTTP3_LISTEN_V4__
    __HTTP3_LISTEN_V6__
    http2 on;
    http3 on;
    quic_retry on;

    server_name __API_DOMAIN__;

    # 传递真实来源 IP 给后端应用（供审计、风控、限流使用）
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    ssl_certificate          __API_CERT__;
    ssl_certificate_key      __API_KEY__;
    ssl_trusted_certificate  __API_CERT__;

    more_clear_headers 'X-Powered-By';

    limit_req zone=one burst=40 nodelay;

    location = / {
        default_type application/json;
        return 200 "{\"status\":\"ok\"}\n";
    }

    location = /healthz {
        default_type text/plain;
        return 200 "ok\n";
    }
}
EOF_API

    cat > "${NGINX_CONF_DIR}/tun_stream_backend.conf" <<'EOF_TUN'
server {
    listen 127.0.0.1:__TUN_MUX_PORT__ ssl proxy_protocol;
    # HTTP/3 监听（由 HTTP3_ENABLE / HTTP3_PORT 动态生成）
    __HTTP3_LISTEN_V4__
    __HTTP3_LISTEN_V6__
    http2 on;
    http3 on;
    quic_retry on;

    server_name __TUN_DOMAIN__;

    # 传递真实来源 IP 给后端应用
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    ssl_certificate          __TUN_CERT__;
    ssl_certificate_key      __TUN_KEY__;
    ssl_trusted_certificate  __TUN_CERT__;

    more_clear_headers 'X-Powered-By';

    location = /healthz {
        default_type text/plain;
        return 200 "ok\n";
    }

    # VLESS 入口（常用于 WS/HTTP Upgrade 场景）
    location /vless {
        proxy_redirect off;
        proxy_http_version 1.1;
        proxy_read_timeout 1200s;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $http_host;
        proxy_pass __VLESS_UPSTREAM__;
    }
}
EOF_TUN

    local esc_main_domain esc_dav_domain esc_api_domain esc_tun_domain
    local esc_main_cert esc_main_key esc_dav_cert esc_dav_key esc_api_cert esc_api_key esc_tun_cert esc_tun_key esc_vless_upstream
    local syslog_access_line="" syslog_error_line="" syslog_dav_access_line=""
    local esc_syslog_access esc_syslog_error esc_syslog_dav_access
    local http3_listen_v4="" http3_listen_v6="" alt_svc_line=""
    local esc_http3_v4 esc_http3_v6 esc_alt_svc
    local esc_main_mux esc_web_mux esc_tun_mux
    local ssl_stapling_line="" ssl_stapling_verify_line=""
    local esc_ssl_stapling esc_ssl_stapling_verify

    # Debian 13 最小化系统可能没有 rsyslog；仅当 /dev/log 存在时才启用 journald 通道
    if [[ -S /dev/log ]]; then
        syslog_access_line="access_log syslog:server=unix:/dev/log,facility=local6,tag=nginx_access,severity=info;"
        syslog_error_line="error_log syslog:server=unix:/dev/log,facility=local5,tag=nginx_error warn;"
        syslog_dav_access_line="access_log syslog:server=unix:/dev/log,facility=local6,tag=nginx_dav_access,severity=info;"
    else
        log_warn "/dev/log 不存在，跳过 journald/syslog 日志通道（仅保留文件日志）"
    fi
    esc_syslog_access="$(escape_sed_replacement "${syslog_access_line}")"
    esc_syslog_error="$(escape_sed_replacement "${syslog_error_line}")"
    esc_syslog_dav_access="$(escape_sed_replacement "${syslog_dav_access_line}")"

    esc_main_domain="$(escape_sed_replacement "${MAIN_DOMAIN}")"
    esc_dav_domain="$(escape_sed_replacement "${DAV_DOMAIN}")"
    esc_api_domain="$(escape_sed_replacement "${API_DOMAIN}")"
    esc_tun_domain="$(escape_sed_replacement "${TUN_DOMAIN}")"
    esc_main_cert="$(escape_sed_replacement "${MAIN_CERT_DST}")"
    esc_main_key="$(escape_sed_replacement "${MAIN_KEY_DST}")"
    esc_dav_cert="$(escape_sed_replacement "${DAV_CERT_DST}")"
    esc_dav_key="$(escape_sed_replacement "${DAV_KEY_DST}")"
    esc_api_cert="$(escape_sed_replacement "${API_CERT_DST}")"
    esc_api_key="$(escape_sed_replacement "${API_KEY_DST}")"
    esc_tun_cert="$(escape_sed_replacement "${TUN_CERT_DST}")"
    esc_tun_key="$(escape_sed_replacement "${TUN_KEY_DST}")"
    esc_vless_upstream="$(escape_sed_replacement "${VLESS_UPSTREAM}")"

    if [[ "${HTTP3_ENABLE}" == "1" ]]; then
        http3_listen_v4="listen ${HTTP3_PORT} quic;"
        http3_listen_v6="listen [::]:${HTTP3_PORT} quic;"
        alt_svc_line="add_header Alt-Svc 'h3=\":${HTTP3_PORT}\"; ma=86400' always;"
    else
        log_warn "HTTP3_ENABLE=0：Nginx 不监听 UDP/${HTTP3_PORT}，请确保其他 QUIC 应用可使用该端口"
    fi
    esc_http3_v4="$(escape_sed_replacement "${http3_listen_v4}")"
    esc_http3_v6="$(escape_sed_replacement "${http3_listen_v6}")"
    esc_alt_svc="$(escape_sed_replacement "${alt_svc_line}")"
    esc_main_mux="$(escape_sed_replacement "${MAIN_MUX_PORT}")"
    esc_web_mux="$(escape_sed_replacement "${WEB_MUX_PORT}")"
    esc_tun_mux="$(escape_sed_replacement "${TUN_MUX_PORT}")"

    local enable_stapling=0
    if [[ "${OCSP_STAPLING}" == "on" ]]; then
        enable_stapling=1
        if ! certs_support_ocsp; then
            log_warn "OCSP_STAPLING=on 但证书缺少 OCSP URL，Nginx 启动时会出现告警"
        fi
    elif [[ "${OCSP_STAPLING}" == "auto" ]] && certs_support_ocsp; then
        enable_stapling=1
    else
        log_info "证书未包含 OCSP URL 或 OCSP_STAPLING=off，已关闭 ssl_stapling"
    fi
    if (( enable_stapling == 1 )); then
        ssl_stapling_line="ssl_stapling on;"
        ssl_stapling_verify_line="ssl_stapling_verify on;"
    else
        ssl_stapling_line="ssl_stapling off;"
        ssl_stapling_verify_line="ssl_stapling_verify off;"
    fi
    esc_ssl_stapling="$(escape_sed_replacement "${ssl_stapling_line}")"
    esc_ssl_stapling_verify="$(escape_sed_replacement "${ssl_stapling_verify_line}")"

    sed -i "s|__MAIN_DOMAIN__|${esc_main_domain}|g; s|__DAV_DOMAIN__|${esc_dav_domain}|g; s|__API_DOMAIN__|${esc_api_domain}|g; s|__TUN_DOMAIN__|${esc_tun_domain}|g" "${NGINX_STREAM_DIR}/stream_sni.conf"
    sed -i "s|__MAIN_DOMAIN__|${esc_main_domain}|g; s|__MAIN_CERT__|${esc_main_cert}|g; s|__MAIN_KEY__|${esc_main_key}|g" "${NGINX_CONF_DIR}/proxy_site.conf"
    sed -i "s|__DAV_DOMAIN__|${esc_dav_domain}|g; s|__DAV_CERT__|${esc_dav_cert}|g; s|__DAV_KEY__|${esc_dav_key}|g" "${NGINX_CONF_DIR}/webdav_drive.conf"
    sed -i "s|__API_DOMAIN__|${esc_api_domain}|g; s|__API_CERT__|${esc_api_cert}|g; s|__API_KEY__|${esc_api_key}|g" "${NGINX_CONF_DIR}/api_site.conf"
    sed -i "s|__TUN_DOMAIN__|${esc_tun_domain}|g; s|__TUN_CERT__|${esc_tun_cert}|g; s|__TUN_KEY__|${esc_tun_key}|g; s|__VLESS_UPSTREAM__|${esc_vless_upstream}|g" "${NGINX_CONF_DIR}/tun_stream_backend.conf"

    sed -i "s|__MAIN_MUX_PORT__|${esc_main_mux}|g" "${NGINX_STREAM_DIR}/stream_sni.conf" "${NGINX_CONF_DIR}/proxy_site.conf"
    sed -i "s|__WEB_MUX_PORT__|${esc_web_mux}|g" "${NGINX_STREAM_DIR}/stream_sni.conf" "${NGINX_CONF_DIR}/webdav_drive.conf" "${NGINX_CONF_DIR}/api_site.conf"
    sed -i "s|__TUN_MUX_PORT__|${esc_tun_mux}|g" "${NGINX_STREAM_DIR}/stream_sni.conf" "${NGINX_CONF_DIR}/tun_stream_backend.conf"

    sed -i "s|__HTTP3_LISTEN_V4__|${esc_http3_v4}|g; s|__HTTP3_LISTEN_V6__|${esc_http3_v6}|g" \
        "${NGINX_CONF_DIR}/proxy_site.conf" \
        "${NGINX_CONF_DIR}/webdav_drive.conf" \
        "${NGINX_CONF_DIR}/api_site.conf" \
        "${NGINX_CONF_DIR}/tun_stream_backend.conf"
    sed -i "s|__ALT_SVC_HEADER__|${esc_alt_svc}|" "${NGINX_DIR}/conf/nginx.conf"
    sed -i "s|__SSL_STAPLING_LINE__|${esc_ssl_stapling}|; s|__SSL_STAPLING_VERIFY_LINE__|${esc_ssl_stapling_verify}|" "${NGINX_DIR}/conf/nginx.conf"

    sed -i "s|__SYSLOG_ACCESS__|${esc_syslog_access}|; s|__SYSLOG_ERROR__|${esc_syslog_error}|" "${NGINX_DIR}/conf/nginx.conf"
    sed -i "s|__SYSLOG_DAV_ACCESS__|${esc_syslog_dav_access}|" "${NGINX_CONF_DIR}/webdav_drive.conf"

    cat > /var/www/html/index.html <<'EOF_MAIN_DEMO'
Welcome to NGINX
EOF_MAIN_DEMO

    log_ok "Nginx 配置文件生成完成"
}

write_fail2ban_templates() {
    if [[ "${ENABLE_FAIL2BAN_TEMPLATE}" != "1" ]]; then
        log_warn "已禁用 Fail2Ban 模板生成（ENABLE_FAIL2BAN_TEMPLATE=${ENABLE_FAIL2BAN_TEMPLATE}）"
        return
    fi

    log_info "生成 Fail2Ban 模板（不自动安装/启动服务）"

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
logpath  = /var/log/nginx/dav_access.log
backend  = auto
maxretry = ${F2B_MAXRETRY}
findtime = ${F2B_FINDTIME}
bantime  = ${F2B_BANTIME}
ignoreip = ${F2B_IGNOREIP}
EOF_F2B_JAIL

    log_ok "Fail2Ban 模板已生成：/etc/nginx/security/fail2ban/"
}

confirm_uninstall_or_exit() {
    if [[ "${PRESERVE_WWW}" == "1" ]]; then
        log_warn "你即将执行卸载（保留 /var/www 数据目录）"
    else
        log_warn "你即将执行彻底卸载，以下内容将被删除："
    fi
    log_warn "1) Nginx 配置/二进制: ${NGINX_DIR}"
    log_warn "2) systemd 单元: /etc/systemd/system/nginx.service"
    log_warn "3) 日志与运行目录: /var/log/nginx /var/lib/nginx"
    if [[ "${PRESERVE_WWW}" == "1" ]]; then
        log_warn "4) Web 目录: 保留 /var/www/html 和 /var/www/dav"
    else
        log_warn "4) Web 目录: /var/www/html /var/www/dav"
    fi
    log_warn "5) 源码目录产物: ${SRC_DIR}/nginx-* ${SRC_DIR}/openssl-* ${SRC_DIR}/ngx_brotli 等"
    log_warn "6) jemalloc 安装产物: /usr/local/lib/libjemalloc* 等"
    log_warn "7) Fail2Ban 相关模板/规则文件（若存在）"

    if [[ "${FORCE_UNINSTALL}" == "1" ]]; then
        log_warn "已启用强制卸载（--yes / FORCE_UNINSTALL=1），跳过人工确认"
        return
    fi

    if [[ "${NON_INTERACTIVE}" == "1" ]]; then
        log_err "NON_INTERACTIVE=1 时必须配合 --yes 或 FORCE_UNINSTALL=1"
        exit 1
    fi

    echo
    echo "为防误操作，请输入确认短语：${UNINSTALL_CONFIRM_PHRASE}"
    read -r -p "> " user_input
    if [[ "${user_input}" != "${UNINSTALL_CONFIRM_PHRASE}" ]]; then
        log_err "确认短语不匹配，已取消卸载"
        exit 1
    fi
}

uninstall_generated_artifacts() {
    local preserve_www="$1"   # 1=保留 /var/www, 0=删除
    local context="$2"        # uninstall|rollback

    systemctl disable --now nginx >/dev/null 2>&1 || true
    stop_nginx_safely

    # 回滚时若安装前已存在 Nginx，则恢复备份而不是清空
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
        log_warn "回滚完成：已从 ${BACKUP_DIR} 恢复安装前的 /etc/nginx 与 systemd 单元"
        log_warn "保留 /var/www、/var/log/nginx 等运行数据，请人工确认服务状态"
        return
    fi

    rm -f /etc/systemd/system/nginx.service
    systemctl daemon-reload || true
    systemctl reset-failed nginx >/dev/null 2>&1 || true
    rm -f /etc/logrotate.d/nginx

    rm -rf "${NGINX_DIR}"
    rm -rf /var/log/nginx /var/lib/nginx
    if [[ "${preserve_www}" != "1" ]]; then
        rm -rf /var/www/dav /var/www/html
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
          /usr/local/lib/libjemalloc.dylib \
          /usr/local/lib/pkgconfig/jemalloc.pc \
          /usr/local/bin/jemalloc-config
    rm -rf /usr/local/include/jemalloc

    if [[ -f /etc/ld.so.conf.d/local.conf ]] && grep -q '^/usr/local/lib$' /etc/ld.so.conf.d/local.conf; then
        rm -f /etc/ld.so.conf.d/local.conf
    fi
    ldconfig || true

    if [[ "${context}" == "rollback" ]]; then
        log_warn "回滚完成：已清理本次安装产生的产物"
    else
        log_ok "卸载完成：已清理脚本安装的 Nginx 相关产物"
    fi
}

uninstall_nginx_everything() {
    confirm_uninstall_or_exit
    log_info "开始卸载 Nginx 及相关产物"
    uninstall_generated_artifacts "${PRESERVE_WWW}" "uninstall"
}

cleanup_build_artifacts_after_install() {
    if [[ "${CLEAN_BUILD_ARTIFACTS}" != "1" ]]; then
        log_info "已禁用编译临时文件清理（CLEAN_BUILD_ARTIFACTS=${CLEAN_BUILD_ARTIFACTS}）"
        return
    fi

    log_info "清理编译临时文件（/usr/local/src）"
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
    log_ok "编译临时文件清理完成"
}

write_systemd_unit() {
    log_info "写入 systemd 沙箱服务"
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

# 绑定端口 + worker 降权（setuid/setgid）所需能力
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_SETUID CAP_SETGID
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_SETUID CAP_SETGID

ReadWritePaths=/var/log/nginx/ /run/ /var/www/html/ /var/www/dav/ /var/lib/nginx/

[Install]
WantedBy=multi-user.target
EOF_SYSTEMD

    systemctl daemon-reload
    systemctl enable nginx
    log_ok "systemd 服务注册完成"
}

write_logrotate_config() {
    log_info "写入 logrotate 策略"
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
    log_ok "logrotate 策略已写入 /etc/logrotate.d/nginx（保留 14 天）"
}

post_check_and_start() {
    log_info "执行最终校验并启动服务"

    if [[ "${CAN_START_NGINX}" != "1" ]]; then
        log_warn "跳过 Nginx 启动：${SKIP_START_REASON}"
        return
    fi

    ensure_runtime_dirs
    # 先彻底停止旧实例，避免其优雅退出期间仍占用 7443 等端口导致新进程 bind 失败
    stop_nginx_safely
    ensure_ports_free_or_exit
    /etc/nginx/sbin/nginx -t -e /var/log/nginx/error.log -c /etc/nginx/conf/nginx.conf
    systemctl reset-failed nginx >/dev/null 2>&1 || true
    systemctl start nginx
    systemctl --no-pager --full status nginx >/dev/null

    log_ok "Nginx 已通过配置测试并成功启动"
    /etc/nginx/sbin/nginx -V 2>&1 | sed 's/^/[nginx -V] /'
}

print_next_steps() {
    cat <<EOF_DONE

${GREEN}[完成]${RESET} Nginx 编译与企业级安全部署结束
- 主配置文件: ${NGINX_DIR}/conf/nginx.conf
- SNI 分流配置: ${NGINX_STREAM_DIR}/stream_sni.conf
- 主站示例: ${NGINX_CONF_DIR}/proxy_site.conf
- WebDAV 示例: ${NGINX_CONF_DIR}/webdav_drive.conf
- API 示例: ${NGINX_CONF_DIR}/api_site.conf
- TUN（Tunnel）Stream 示例: ${NGINX_CONF_DIR}/tun_stream_backend.conf

请注意：
1) 生产环境建议保持 STRICT_SUPPLYCHAIN=1，并填充所有 SHA256 / commit 固定点。
2) 请使用 htpasswd 初始化 /etc/nginx/dav.pass.public，例如:
   htpasswd -B /etc/nginx/dav.pass.public your_user
3) 私钥已按 root:root 0600 导入；证书为 root:root 0644。
   证书已校验 SAN/有效期/与私钥匹配（STRICT_CERT_SAN=${STRICT_CERT_SAN}）。
4) 访问测试地址:
   https://${MAIN_DOMAIN}/
   https://${MAIN_DOMAIN}/healthz
   https://${DAV_DOMAIN}/
   https://${DAV_DOMAIN}/healthz
   https://${API_DOMAIN}/
   https://${API_DOMAIN}/healthz
   https://${TUN_DOMAIN}/healthz
   https://${TUN_DOMAIN}/vless
   HTTP/3 测试（HTTP3_ENABLE=${HTTP3_ENABLE}, UDP/${HTTP3_PORT}；需 curl 支持 --http3）:
   curl --http3 -sI https://${MAIN_DOMAIN}/healthz
5) Fail2Ban 模板（未自动安装/启用）:
   /etc/nginx/security/fail2ban/filter.d/nginx-webdav-auth.conf
   /etc/nginx/security/fail2ban/jail.d/nginx-webdav-auth.local
   若你已安装 fail2ban，可复制到 /etc/fail2ban/ 并执行:
   systemctl restart fail2ban && fail2ban-client status nginx-webdav-auth
6) 日志轮转: /etc/logrotate.d/nginx（daily, 保留 14 天）
7) 安装前若已存在 Nginx，备份位于: ${BACKUP_DIR:-未生成备份}
8) NON_INTERACTIVE=1 且未提供完整证书时，脚本不会启动 Nginx。
   请先把证书放到以下路径，再执行启动：
   ${MAIN_CERT_DST}
   ${MAIN_KEY_DST}
   ${DAV_CERT_DST}
   ${DAV_KEY_DST}
   ${API_CERT_DST}
   ${API_KEY_DST}
   ${TUN_CERT_DST}
   ${TUN_KEY_DST}
   启动命令：
   /etc/nginx/sbin/nginx -t -c /etc/nginx/conf/nginx.conf && systemctl restart nginx
EOF_DONE
}

main() {
    local arg
    local need_env=1

    # --help 不需要配置文件；--uninstall 在缺少配置时也可继续
    for arg in "$@"; do
        case "${arg}" in
            --help|-h)
                parse_args "$@"
                ;;
            --uninstall)
                need_env=0
                ;;
        esac
    done

    require_root
    load_env_file "${need_env}"
    parse_args "$@"

    if [[ "${RUN_MODE}" == "uninstall" ]]; then
        uninstall_nginx_everything
        exit 0
    fi

    check_os_compat
    install_dependencies
    require_cmds
    validate_http3_or_exit
    validate_internal_settings_or_exit
    check_http3_port_available
    check_internal_tcp_ports
    check_version_currency
    collect_deploy_inputs
    backup_existing_installation

    INSTALL_IN_PROGRESS=1

    download_sources
    compile_jemalloc
    compile_nginx
    generate_dhparam
    import_tls_certs
    write_nginx_configs
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
