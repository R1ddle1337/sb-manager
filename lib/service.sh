#!/usr/bin/env bash
# shellcheck shell=bash

# Service-manager abstraction.  Logical service names keep their systemd
# suffixes for backward compatibility; OpenRC transparently strips them.

init_system_detect() {
  local requested=${SBM_INIT_SYSTEM:-auto} pid1
  [[ ${SBM_SKIP_INIT:-0} == 1 ]] && { printf 'none\n'; return 0; }
  case "$requested" in
    systemd|openrc|none) printf '%s\n' "$requested"; return 0 ;;
    auto|'') ;;
    *) die "未知服务管理器：$requested（支持 auto、systemd、openrc）" ;;
  esac
  pid1=$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ' || true)
  if command_exists systemctl && [[ "$pid1" == systemd ]]; then
    printf 'systemd\n'
  elif command_exists rc-service && command_exists rc-update && { [[ -e /run/openrc/softlevel ]] || [[ "$pid1" == init || "$pid1" == openrc-init ]]; }; then
    printf 'openrc\n'
  else
    return 1
  fi
}

init_system() {
  if [[ -n ${SBM_INIT_SYSTEM_RESOLVED:-} ]]; then
    printf '%s\n' "$SBM_INIT_SYSTEM_RESOLVED"
    return 0
  fi
  init_system_detect
}

effective_init_system() {
  local backend
  backend=$(init_system 2>/dev/null || true)
  if [[ -z "$backend" || "$backend" == none ]]; then backend=${SBM_TEST_INIT_BACKEND:-systemd}; fi
  printf '%s\n' "$backend"
}

init_system_label() {
  case "$(init_system 2>/dev/null || true)" in
    systemd) printf 'systemd\n' ;;
    openrc) printf 'OpenRC\n' ;;
    none) printf '测试/跳过\n' ;;
    *) printf '未知\n' ;;
  esac
}

require_init_system() {
  [[ ${SBM_SKIP_INIT:-0} == 1 ]] && return 0
  local detected
  detected=$(init_system_detect) || die '未检测到可用的 systemd 或 OpenRC。Alpine 需要以 OpenRC 启动，普通精简容器不受支持。'
  case "$detected" in
    systemd)
      command_exists systemctl || die '未发现 systemctl。'
      ;;
    openrc)
      command_exists rc-service || die '未发现 rc-service；请安装 openrc。'
      command_exists rc-update || die '未发现 rc-update；请安装 openrc。'
      command_exists openrc-run || [[ -x /sbin/openrc-run ]] || die '未发现 openrc-run；请安装 openrc。'
      ;;
  esac
  SBM_INIT_SYSTEM_RESOLVED=$detected
  export SBM_INIT_SYSTEM_RESOLVED
}

# Backward-compatible name retained for third-party callers.
require_systemd() { require_init_system; }

service_native_name() {
  local name=$1
  if [[ $(init_system 2>/dev/null || true) == openrc ]]; then
    name=${name%.service}
    name=${name%.timer}
  fi
  printf '%s\n' "$name"
}

service_file_path() {
  local unit=$1
  case "$(init_system 2>/dev/null || true)" in
    systemd) printf '%s/%s\n' "$SBM_SYSTEMD_DIR" "$unit" ;;
    openrc) printf '%s/%s\n' "$SBM_OPENRC_DIR" "$(service_native_name "$unit")" ;;
    *) return 1 ;;
  esac
}

service_manager_present() {
  [[ ${SBM_SKIP_INIT:-0} != 1 ]] || return 1
  case "$(init_system 2>/dev/null || true)" in
    systemd) command_exists systemctl ;;
    openrc) command_exists rc-service && command_exists rc-update ;;
    *) return 1 ;;
  esac
}

# Legacy helper retained for modules/tests which still call it.
is_systemd_present() { [[ $(init_system 2>/dev/null || true) == systemd ]] && service_manager_present; }

service_exists() {
  local unit=$1 native path
  native=$(service_native_name "$unit")
  case "$(init_system 2>/dev/null || true)" in
    systemd)
      path="$SBM_SYSTEMD_DIR/$unit"
      [[ -f "$path" ]] || { service_manager_present && systemctl cat "$unit" >/dev/null 2>&1; }
      ;;
    openrc)
      [[ -f "$SBM_OPENRC_DIR/$native" ]]
      ;;
    none) return 1 ;;
    *) return 1 ;;
  esac
}

service_active() {
  local unit=$1 native
  [[ ${SBM_SKIP_INIT:-0} != 1 ]] || return 1
  native=$(service_native_name "$unit")
  case "$(init_system)" in
    systemd) systemctl is-active --quiet "$unit" ;;
    openrc) rc-service "$native" status >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

service_enabled() {
  local unit=$1 native
  [[ ${SBM_SKIP_INIT:-0} != 1 ]] || return 1
  native=$(service_native_name "$unit")
  case "$(init_system)" in
    systemd) systemctl is-enabled --quiet "$unit" 2>/dev/null ;;
    openrc)
      rc-update show "$SBM_OPENRC_RUNLEVEL" 2>/dev/null | awk '{print $1}' | grep -Fxq "$native"
      ;;
    *) return 1 ;;
  esac
}

service_reload_manager() {
  [[ ${SBM_SKIP_INIT:-0} != 1 ]] || return 0
  case "$(init_system)" in
    systemd) systemctl daemon-reload ;;
    openrc) return 0 ;;
  esac
}

service_enable() {
  local unit=$1 native
  [[ ${SBM_SKIP_INIT:-0} != 1 ]] || return 0
  native=$(service_native_name "$unit")
  case "$(init_system)" in
    systemd) systemctl enable "$unit" >/dev/null ;;
    openrc) rc-update add "$native" "$SBM_OPENRC_RUNLEVEL" >/dev/null ;;
  esac
}

service_disable() {
  local unit=$1 native
  [[ ${SBM_SKIP_INIT:-0} != 1 ]] || return 0
  native=$(service_native_name "$unit")
  case "$(init_system)" in
    systemd) systemctl disable "$unit" >/dev/null 2>&1 || true ;;
    openrc) rc-update del "$native" "$SBM_OPENRC_RUNLEVEL" >/dev/null 2>&1 || true ;;
  esac
}

service_start() {
  local unit=$1 native
  [[ ${SBM_SKIP_INIT:-0} != 1 ]] || return 0
  native=$(service_native_name "$unit")
  case "$(init_system)" in
    systemd) systemctl start "$unit" ;;
    openrc) rc-service "$native" start ;;
  esac
}

service_stop() {
  local unit=$1 native
  [[ ${SBM_SKIP_INIT:-0} != 1 ]] || return 0
  native=$(service_native_name "$unit")
  case "$(init_system)" in
    systemd) systemctl stop "$unit" >/dev/null 2>&1 || true ;;
    openrc) rc-service "$native" stop >/dev/null 2>&1 || true ;;
  esac
}

service_restart() {
  local unit=$1 native
  [[ ${SBM_SKIP_INIT:-0} != 1 ]] || return 0
  native=$(service_native_name "$unit")
  service_reload_manager
  case "$(init_system)" in
    systemd) systemctl restart "$unit" ;;
    openrc)
      if service_active "$unit"; then rc-service "$native" restart; else rc-service "$native" start; fi
      ;;
  esac
}

service_try_restart() {
  local unit=$1
  [[ ${SBM_SKIP_INIT:-0} != 1 ]] || return 0
  service_exists "$unit" && service_restart "$unit"
}

service_reset_failed() {
  local unit=$1
  [[ ${SBM_SKIP_INIT:-0} != 1 ]] || return 0
  [[ $(init_system) == systemd ]] && systemctl reset-failed "$unit" >/dev/null 2>&1 || true
}

service_wait_active() {
  local unit=$1 attempts=${2:-20} stable_checks=${3:-3} i stable=0
  [[ ${SBM_SKIP_INIT:-0} != 1 ]] || return 0
  for ((i=0; i<attempts; i++)); do
    if service_active "$unit"; then
      stable=$((stable + 1))
      (( stable >= stable_checks )) && return 0
    else
      stable=0
    fi
    sleep 0.5
  done
  return 1
}

service_status_text() {
  local unit=$1 native
  native=$(service_native_name "$unit")
  case "$(init_system 2>/dev/null || true)" in
    systemd) systemctl status "$unit" --no-pager -l ;;
    openrc) rc-service "$native" status ;;
    *) return 1 ;;
  esac
}

service_log_files() {
  local unit=$1 native
  native=$(service_native_name "$unit")
  case "$native" in
    sb-sing-box) printf '%s\n%s\n' "$SBM_SINGBOX_LOG" "$SBM_SINGBOX_ERROR_LOG" ;;
    sb-cloudflared) printf '%s\n%s\n' "$SBM_TUNNEL_LOG" "$SBM_TUNNEL_ERROR_LOG" ;;
    sb-nginx-stream) printf '%s\n%s\n' "$SBM_NGINX_STREAM_LOG" "$SBM_NGINX_STREAM_ERROR_LOG" ;;
  esac
}

service_logs() {
  local unit=$1 lines=${2:-100} follow=${3:-0} native
  native=$(service_native_name "$unit")
  case "$(init_system 2>/dev/null || true)" in
    systemd)
      if [[ "$follow" == 1 ]]; then journalctl -u "$unit" -f; else journalctl -u "$unit" -n "$lines" --no-pager -l; fi
      ;;
    openrc)
      local -a files=()
      while IFS= read -r path; do [[ -s "$path" ]] && files+=("$path"); done < <(service_log_files "$unit")
      if ((${#files[@]} == 0)); then log_warn "$native 尚无日志文件。"; return 0; fi
      if [[ "$follow" == 1 ]]; then tail -F "${files[@]}"; else tail -n "$lines" "${files[@]}"; fi
      ;;
    *) log_warn '当前没有可用的服务日志后端。' ;;
  esac
}

service_failure_report() {
  local unit=$1
  [[ ${SBM_SKIP_INIT:-0} != 1 ]] || return 0
  log_error "$(service_native_name "$unit") 启动失败。"
  service_status_text "$unit" >&2 || true
  service_logs "$unit" 80 0 >&2 || true
  command_exists namei && {
    printf '%s\n' '---- 可执行文件路径权限 ----' >&2
    namei -l "$SBM_SING_BOX_BIN" >&2 || true
    printf '%s\n' '---- 配置文件路径权限 ----' >&2
    namei -l "$SBM_CONFIG" >&2 || true
  }
}

ensure_singbox_bind_capability() {
  local binary=${1:-$SBM_SING_BOX_BIN}
  [[ $(init_system 2>/dev/null || true) == openrc ]] || return 0
  command_exists setcap || die 'OpenRC 低权限服务需要 setcap；请安装 Alpine 的 libcap 包。'
  setcap 'cap_net_bind_service=+ep' "$binary" || die "无法为 sing-box 设置低端口能力：$binary"
}

singbox_has_bind_capability() {
  local binary=${1:-$SBM_SING_BOX_BIN}
  command_exists getcap || return 1
  getcap "$binary" 2>/dev/null | grep -q 'cap_net_bind_service'
}

write_openrc_supervised_service() {
  local path=$1 name=$2 description=$3 command=$4 args=$5 user=$6 stdout_log=$7 stderr_log=$8 dependency=${9:-net} start_post=${10:-} home=${11:-$SBM_VAR} start_pre_extra=${12:-} foreground_args=${13:-} foreground_line=''
  [[ -z "$foreground_args" ]] || foreground_line="command_args_foreground=\"$foreground_args\""
  mkdir -p "$(dirname "$path")" "$SBM_LOG_DIR"
  cat >"$path" <<EOF_OPENRC
#!/sbin/openrc-run
name="$name"
description="$description"
supervisor=supervise-daemon
command="$command"
command_args="$args"
${foreground_line}
command_user="$user:$user"
respawn_delay=3
respawn_max=0
output_log="$stdout_log"
error_log="$stderr_log"

export HOME="$home"

depend() {
  need net
  ${dependency}
}

start_pre() {
  checkpath --directory --mode 0750 --owner "$user:$user" "$SBM_LOG_DIR"
  checkpath --file --mode 0640 --owner "$user:$user" "$stdout_log"
  checkpath --file --mode 0640 --owner "$user:$user" "$stderr_log"
  ${start_pre_extra}
}
${start_post}
EOF_OPENRC
  chmod 0755 "$path"
}
