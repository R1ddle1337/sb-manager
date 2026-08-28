#!/usr/bin/env bash
# shellcheck shell=bash

SBM_PREFIX="${SBM_PREFIX:-/usr/local}"
SBM_LIB="${SBM_LIB:-${SBM_PREFIX}/lib/sb-manager}"
SBM_BIN_DIR="${SBM_BIN_DIR:-${SBM_PREFIX}/bin}"
if [[ -z ${SBM_VERSION:-} ]]; then
  if [[ -r "$SBM_LIB/VERSION" ]]; then SBM_VERSION=$(tr -d '[:space:]' <"$SBM_LIB/VERSION" 2>/dev/null || true); fi
  SBM_VERSION=${SBM_VERSION:-0.1.0-alpha.25}
fi
SBM_ETC="${SBM_ETC:-/etc/sb-manager}"
SBM_VAR="${SBM_VAR:-/var/lib/sb-manager}"
SBM_RUN="${SBM_RUN:-/run/sb-manager}"
SBM_SYSTEMD_DIR="${SBM_SYSTEMD_DIR:-/etc/systemd/system}"
SBM_OPENRC_DIR="${SBM_OPENRC_DIR:-/etc/init.d}"
SBM_PERIODIC_DIR="${SBM_PERIODIC_DIR:-/etc/periodic}"
SBM_OPENRC_RUNLEVEL="${SBM_OPENRC_RUNLEVEL:-default}"
SBM_LOG_DIR="${SBM_LOG_DIR:-/var/log/sb-manager}"
SBM_STATE="${SBM_STATE:-${SBM_ETC}/state.json}"
SBM_GENERATED_DIR="${SBM_GENERATED_DIR:-${SBM_ETC}/generated}"
SBM_CONFIG="${SBM_CONFIG:-${SBM_GENERATED_DIR}/config.json}"
SBM_SECRETS="${SBM_SECRETS:-${SBM_ETC}/secrets}"
SBM_CERTS="${SBM_CERTS:-${SBM_ETC}/certs}"
SBM_BACKUPS="${SBM_BACKUPS:-${SBM_VAR}/backups}"
SBM_EXPORTS="${SBM_EXPORTS:-${SBM_VAR}/exports}"
SBM_CACHE="${SBM_CACHE:-${SBM_VAR}/cache}"
SBM_CORE_DIR="${SBM_CORE_DIR:-${SBM_LIB}/cores}"
SBM_LOCK="${SBM_LOCK:-${SBM_RUN}/manager.lock}"
SBM_SING_BOX_BIN="${SBM_SING_BOX_BIN:-${SBM_BIN_DIR}/sing-box}"
SBM_CLOUDFLARED_BIN="${SBM_CLOUDFLARED_BIN:-${SBM_BIN_DIR}/cloudflared}"
SBM_SERVICE="${SBM_SERVICE:-sb-sing-box.service}"
SBM_TUNNEL_SERVICE="${SBM_TUNNEL_SERVICE:-sb-cloudflared.service}"
SBM_SERVICE_USER="${SBM_SERVICE_USER:-sbmanager}"
SBM_INIT_SYSTEM="${SBM_INIT_SYSTEM:-auto}"
SBM_SKIP_INIT="${SBM_SKIP_INIT:-${SBM_SKIP_SYSTEMD:-0}}"
SBM_SKIP_SYSTEMD="${SBM_SKIP_SYSTEMD:-$SBM_SKIP_INIT}" # backward compatibility
SBM_SINGBOX_LOG="${SBM_SINGBOX_LOG:-$SBM_LOG_DIR/sing-box.log}"
SBM_SINGBOX_ERROR_LOG="${SBM_SINGBOX_ERROR_LOG:-$SBM_LOG_DIR/sing-box.err.log}"
SBM_TUNNEL_LOG="${SBM_TUNNEL_LOG:-$SBM_LOG_DIR/cloudflared.log}"
SBM_TUNNEL_ERROR_LOG="${SBM_TUNNEL_ERROR_LOG:-$SBM_LOG_DIR/cloudflared.err.log}"
SBM_NGINX_STREAM_LOG="${SBM_NGINX_STREAM_LOG:-$SBM_LOG_DIR/nginx-stream.log}"
SBM_NGINX_STREAM_ERROR_LOG="${SBM_NGINX_STREAM_ERROR_LOG:-$SBM_LOG_DIR/nginx-stream.err.log}"
SBM_LOGROTATE_FILE="${SBM_LOGROTATE_FILE:-$(dirname "$SBM_ETC")/logrotate.d/sb-manager}"
SBM_SUBSCRIPTIONS="${SBM_SUBSCRIPTIONS:-$SBM_VAR/subscriptions}"
SBM_SUBSCRIPTION_SERVICE="${SBM_SUBSCRIPTION_SERVICE:-sb-subscription.service}"
SBM_SUBSCRIPTION_PORT="${SBM_SUBSCRIPTION_PORT:-9080}"
SBM_NGINX_STREAM_SERVICE="${SBM_NGINX_STREAM_SERVICE:-sb-nginx-stream.service}"
SBM_NGINX_STREAM_CONFIG="${SBM_NGINX_STREAM_CONFIG:-$SBM_ETC/nginx-stream.conf}"
SBM_NGINX_STREAM_RUNTIME_DIR="${SBM_NGINX_STREAM_RUNTIME_DIR:-/run/sb-manager-nginx}"
SBM_NGINX_STREAM_PID="${SBM_NGINX_STREAM_PID:-$SBM_NGINX_STREAM_RUNTIME_DIR/nginx.pid}"
SBM_NGINX_STREAM_BIN="${SBM_NGINX_STREAM_BIN:-/usr/sbin/nginx}"
SBM_NGINX_STREAM_OPENRC_BIN="${SBM_NGINX_STREAM_OPENRC_BIN:-$SBM_VAR/nginx-stream/nginx}"
SBM_TRAFFIC_USAGE="${SBM_TRAFFIC_USAGE:-$SBM_VAR/traffic-usage.json}"
SBM_TRAFFIC_TABLE="${SBM_TRAFFIC_TABLE:-sb_manager_traffic}"
SBM_TRAFFIC_SERVICE="${SBM_TRAFFIC_SERVICE:-sb-traffic.service}"
SBM_FAIL2BAN_SERVICE="${SBM_FAIL2BAN_SERVICE:-fail2ban.service}"
SBM_FAIL2BAN_CONFIG="${SBM_FAIL2BAN_CONFIG:-/etc/fail2ban/jail.d/sb-manager-sshd.local}"

if [[ -t 1 && "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
  C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''
fi

log_info() { printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$*" >&2; }
log_ok() { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
log_warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error() { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die() { log_error "$*"; exit 1; }

command_exists() { command -v "$1" >/dev/null 2>&1; }
require_command() { command_exists "$1" || die "缺少命令：$1"; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "此操作需要 root 权限，请使用 sudo。"; }
ensure_runtime_dirs() {
  mkdir -p "$SBM_RUN" "$SBM_CACHE" "$SBM_BACKUPS" "$SBM_EXPORTS"
}

with_lock() {
  local fn=$1; shift
  ensure_runtime_dirs
  exec 9>"$SBM_LOCK"
  flock -x 9
  local rc=0
  "$fn" "$@" || rc=$?
  flock -u 9 || true
  exec 9>&-
  return "$rc"
}

now_iso() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
now_stamp() { date -u +'%Y%m%dT%H%M%SZ'; }

json_compact() { jq -c .; }
json_pretty() { jq .; }

extract_semver() {
  local text=$1
  if [[ $text =~ ([0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    return 1
  fi
}

random_hex() {
  local bytes=${1:-16}
  openssl rand -hex "$bytes"
}
random_password() {
  local bytes=${1:-24}
  openssl rand -base64 "$bytes" | tr -d '\n' | tr '/+' '_-'
}
random_uuid() {
  if [[ -x "$SBM_SING_BOX_BIN" ]]; then
    "$SBM_SING_BOX_BIN" generate uuid 2>/dev/null && return 0
  fi
  if command_exists uuidgen; then uuidgen | tr 'A-Z' 'a-z'; return 0; fi
  local h
  h=$(openssl rand -hex 16)
  printf '%s-%s-4%s-%x%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:13:3}" "$(( (0x${h:16:1} & 3) | 8 ))" "${h:17:3}" "${h:20:12}"
}
ss2022_key() {
  local method=$1 bytes
  case "$method" in
    2022-blake3-aes-128-gcm) bytes=16 ;;
    2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) bytes=32 ;;
    *) die "不支持的 Shadowsocks 2022 方法：$method" ;;
  esac
  openssl rand -base64 "$bytes" | tr -d '\n'
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 ))
}
validate_node_id() { [[ "$1" =~ ^[a-z0-9][a-z0-9._-]{0,47}$ ]]; }
validate_domain() {
  local d=${1%.}
  [[ ${#d} -le 253 && "$d" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}
validate_address() {
  local a=$1
  [[ -n "$a" && "$a" != *[[:space:]]* ]]
}
validate_ipv4() {
  local ip=$1 a b c d extra octet
  IFS=. read -r a b c d extra <<<"$ip"
  [[ -z ${extra:-} && -n ${a:-} && -n ${b:-} && -n ${c:-} && -n ${d:-} ]] || return 1
  for octet in "$a" "$b" "$c" "$d"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] && ((10#$octet <= 255)) || return 1
  done
}
validate_ipv6() {
  local ip=$1
  [[ "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
  if command_exists python3; then
    python3 -c 'import ipaddress,sys; ipaddress.IPv6Address(sys.argv[1])' "$ip" >/dev/null 2>&1
  else
    [[ "$ip" =~ ^([0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}$ ]]
  fi
}

detect_public_ipv4() {
  local value=${SBM_PUBLIC_IPV4:-} url
  validate_ipv4 "$value" && { printf '%s\n' "$value"; return; }
  for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.co/ip; do
    value=$(curl -4 --fail --silent --show-error --location --connect-timeout 3 --max-time 6 "$url" 2>/dev/null | tr -d '\r[:space:]' || true)
    validate_ipv4 "$value" && { printf '%s\n' "$value"; return; }
  done
  return 1
}
detect_public_ipv6() {
  local value=${SBM_PUBLIC_IPV6:-} url
  [[ ${SBM_DISABLE_IPV6_DETECTION:-0} != 1 ]] || return 1
  validate_ipv6 "$value" && { printf '%s\n' "$value"; return; }
  for url in https://api64.ipify.org https://ipv6.icanhazip.com https://ifconfig.co/ip; do
    value=$(curl -6 --fail --silent --show-error --location --connect-timeout 3 --max-time 6 "$url" 2>/dev/null | tr -d '\r[:space:]' || true)
    validate_ipv6 "$value" && { printf '%s\n' "$value"; return; }
  done
  return 1
}
normalize_ws_path() {
  local p=$1
  [[ "$p" == /* ]] || p="/$p"
  printf '%s\n' "$p"
}

urlencode() { jq -rn --arg v "$1" '$v|@uri'; }
base64_nowrap() { base64 | tr -d '\n'; }
base64url_nowrap() { base64 | tr -d '\n=' | tr '+/' '-_'; }

format_hostport() {
  local host=$1 port=$2
  if [[ "$host" == *:* && "$host" != \[*\] ]]; then printf '[%s]:%s' "$host" "$port"; else printf '%s:%s' "$host" "$port"; fi
}

ensure_program_permissions() {
  local path
  for path in "$(dirname "$SBM_LIB")" "$SBM_LIB" "$SBM_BIN_DIR" "$SBM_CORE_DIR"; do
    [[ -d "$path" ]] && chmod 0755 "$path"
  done
  if [[ -d "$SBM_CORE_DIR" ]]; then
    find "$SBM_CORE_DIR" -type d -exec chmod 0755 {} +
    find "$SBM_CORE_DIR" -type f \( -name sing-box -o -name cloudflared -o -name libcronet.so \) -exec chmod 0755 {} +
  fi
}
validate_runtime_binary_path() {
  local label=$1 path=$2
  [[ -n "$path" ]] || die "$label 安装结果为空。"
  [[ "$path" != *$'\n'* && "$path" == /* ]] || die "$label 安装结果不是单一绝对路径：$(printf %q "$path")"
  [[ -x "$path" ]] || die "$label 可执行文件不存在或不可执行：$path"
}
service_user_can_execute_core() {
  local target_uid
  id "$SBM_SERVICE_USER" >/dev/null 2>&1 || return 1
  target_uid=$(id -u "$SBM_SERVICE_USER")
  if [[ ${EUID:-$(id -u)} == "$target_uid" ]]; then
    "$SBM_SING_BOX_BIN" version >/dev/null 2>&1
  elif command_exists runuser; then
    runuser -u "$SBM_SERVICE_USER" -- "$SBM_SING_BOX_BIN" version >/dev/null 2>&1
  else
    su -s /bin/sh -c "'$SBM_SING_BOX_BIN' version >/dev/null 2>&1" "$SBM_SERVICE_USER"
  fi
}
service_user_can_read_config() {
  local target_uid
  id "$SBM_SERVICE_USER" >/dev/null 2>&1 || return 1
  target_uid=$(id -u "$SBM_SERVICE_USER")
  if [[ ${EUID:-$(id -u)} == "$target_uid" ]]; then
    [[ -r "$SBM_CONFIG" ]]
  elif command_exists runuser; then
    runuser -u "$SBM_SERVICE_USER" -- test -r "$SBM_CONFIG"
  else
    su -s /bin/sh -c "test -r '$SBM_CONFIG'" "$SBM_SERVICE_USER"
  fi
}

safe_install_file() {
  local src=$1 dst=$2 mode=${3:-0644}
  mkdir -p "$(dirname "$dst")"
  local tmp="${dst}.tmp.$$"
  install -m "$mode" "$src" "$tmp"
  mv -f "$tmp" "$dst"
}

group_exists() {
  local group=$1
  if command_exists getent; then getent group "$group" >/dev/null 2>&1; else grep -qE "^${group}:" /etc/group 2>/dev/null; fi
}
account_entry() {
  local user=$1
  if command_exists getent; then getent passwd "$user" 2>/dev/null; else grep -E "^${user}:" /etc/passwd 2>/dev/null; fi
}
host_resolves() {
  local host=$1
  if command_exists getent; then getent ahosts "$host" >/dev/null 2>&1 || getent hosts "$host" >/dev/null 2>&1
  elif command_exists nslookup; then nslookup "$host" >/dev/null 2>&1
  else return 1; fi
}
portable_date_epoch() {
  local value=$1
  if date -d "$value" +%s >/dev/null 2>&1; then date -d "$value" +%s
  elif command_exists gdate && gdate -d "$value" +%s >/dev/null 2>&1; then gdate -d "$value" +%s
  else return 1; fi
}
x509_days_remaining() {
  local cert=$1 end epoch now
  end=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2-) || return 1
  epoch=$(portable_date_epoch "$end") || return 1
  now=$(date +%s)
  printf '%s\n' "$(( (epoch-now)/86400 ))"
}

set_owner_if_exists() {
  local owner=$1 path=$2
  if id "$owner" >/dev/null 2>&1; then chown "$owner" "$path" 2>/dev/null || true; fi
}
set_group_if_exists() {
  local group=$1 path=$2
  if group_exists "$group"; then chgrp "$group" "$path" 2>/dev/null || true; fi
}

version_lt() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | sed -n '1p')" != "$2" && "$1" != "$2" ]]; }
version_ge() { ! version_lt "$1" "$2"; }

confirm() {
  local prompt=$1 default=${2:-N} reply
  if [[ ! -t 0 ]]; then [[ "$default" =~ ^[Yy]$ ]]; return; fi
  if [[ "$default" =~ ^[Yy]$ ]]; then read -r -p "$prompt [Y/n] " reply; reply=${reply:-Y}; else read -r -p "$prompt [y/N] " reply; reply=${reply:-N}; fi
  [[ "$reply" =~ ^[Yy]$ ]]
}

prompt_value() {
  local __var=$1 prompt=$2 default=${3:-} input_value
  if [[ -n "$default" ]]; then read -r -p "$prompt [$default]: " input_value; input_value=${input_value:-$default}; else read -r -p "$prompt: " input_value; fi
  printf -v "$__var" '%s' "$input_value"
}
prompt_secret() {
  local __var=$1 prompt=$2 value
  read -r -s -p "$prompt: " value; printf '\n'
  printf -v "$__var" '%s' "$value"
}

mask_secret() {
  local s=$1
  if ((${#s} <= 10)); then printf '********'; else printf '%s****%s' "${s:0:4}" "${s: -4}"; fi
}
