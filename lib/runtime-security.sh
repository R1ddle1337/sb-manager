#!/usr/bin/env bash
# shellcheck shell=bash

# systemd grants CAP_NET_BIND_SERVICE through the service unit. OpenRC has no
# equivalent ambient-capability facility, so only the OpenRC backend uses a
# file capability on the sing-box executable. Keeping a stale file capability
# on the systemd backend can make execve fail under NoNewPrivileges/LSM rules.

singbox_resolved_binary() {
  local binary=${1:-$SBM_SING_BOX_BIN} target
  target=$(readlink -f "$binary" 2>/dev/null || true)
  [[ -n "$target" ]] || target=$binary
  printf '%s\n' "$target"
}

singbox_file_capabilities() {
  local target
  target=$(singbox_resolved_binary "${1:-$SBM_SING_BOX_BIN}")
  [[ -e "$target" ]] || return 0
  command_exists getcap || return 0
  getcap "$target" 2>/dev/null || true
}

clear_singbox_file_capabilities() {
  local target caps
  target=$(singbox_resolved_binary "${1:-$SBM_SING_BOX_BIN}")
  [[ -e "$target" ]] || return 0
  command_exists getcap || return 0
  caps=$(getcap "$target" 2>/dev/null || true)
  [[ -n "$caps" ]] || return 0
  command_exists setcap || die "检测到 sing-box 文件能力，但缺少 setcap，无法安全清理：$target"
  setcap -r "$target" || die "无法清除 sing-box 文件能力：$target"
  log_info "已清除 systemd 后端不需要的 sing-box 文件能力：$target"
}

apply_singbox_bind_capability() {
  local target
  target=$(singbox_resolved_binary "${1:-$SBM_SING_BOX_BIN}")
  command_exists setcap || die 'OpenRC 低权限服务需要 setcap；请安装 Alpine 的 libcap 包。'
  setcap 'cap_net_bind_service=+ep' "$target" || die "无法为 sing-box 设置低端口能力：$target"
}

prepare_singbox_binary_for_backend() {
  local binary=${1:-$SBM_SING_BOX_BIN} backend=${2:-} target
  target=$(singbox_resolved_binary "$binary")
  [[ -f "$target" && -x "$target" ]] || return 1
  ensure_program_permissions
  chmod 0755 "$target"
  if [[ -z "$backend" ]]; then
    backend=$(init_system 2>/dev/null || true)
    [[ -n "$backend" && "$backend" != none ]] || backend=$(effective_init_system)
  fi
  case "$backend" in
    systemd)
      clear_singbox_file_capabilities "$target"
      ;;
    openrc)
      apply_singbox_bind_capability "$target"
      ;;
    none|'')
      ;;
    *)
      die "无法为未知服务后端准备 sing-box 核心：$backend"
      ;;
  esac
}

systemd_exec_preflight() {
  local binary=${1:-$SBM_SING_BOX_BIN} unit log rc
  [[ ${SBM_SKIP_INIT:-0} != 1 ]] || return 2
  [[ $(init_system 2>/dev/null || true) == systemd ]] || return 2
  command_exists systemd-run || return 2
  command_exists systemctl || return 2
  systemctl show-environment >/dev/null 2>&1 || return 2

  unit="sb-manager-exec-preflight-${BASHPID:-$$}-${RANDOM}"
  ensure_runtime_dirs
  log="$SBM_RUN/${unit}.log"
  rc=0
  systemd-run \
    --quiet \
    --wait \
    --collect \
    --pipe \
    --unit="$unit" \
    --property=Type=oneshot \
    --property="User=$SBM_SERVICE_USER" \
    --property="Group=$SBM_SERVICE_USER" \
    --property=NoNewPrivileges=yes \
    --property=AmbientCapabilities=CAP_NET_BIND_SERVICE \
    --property=CapabilityBoundingSet=CAP_NET_BIND_SERVICE \
    --property=PrivateTmp=yes \
    --property=ProtectHome=yes \
    --property=ProtectSystem=strict \
    --property=ProtectKernelTunables=yes \
    --property=ProtectKernelModules=yes \
    --property=ProtectControlGroups=yes \
    --property=LockPersonality=yes \
    --property=RestrictSUIDSGID=yes \
    --property=RestrictRealtime=yes \
    --property="RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX" \
    --property="ReadOnlyPaths=$SBM_ETC $SBM_LIB" \
    "$binary" version >"$log" 2>&1 || rc=$?
  if (( rc == 0 )); then
    rm -f "$log"
    return 0
  fi
  log_error "sing-box 未通过 systemd 沙箱执行预检（退出码 $rc）。"
  [[ -s "$log" ]] && cat "$log" >&2
  return 1
}

runtime_exec_diagnostics() {
  local binary=${1:-$SBM_SING_BOX_BIN} target caps
  target=$(singbox_resolved_binary "$binary")
  printf '%s\n' '---- sing-box 执行诊断 ----' >&2
  printf '命令路径：%s\n真实路径：%s\n' "$binary" "$target" >&2
  ls -ld "$binary" "$target" 2>/dev/null >&2 || true
  if command_exists namei; then
    namei -l "$binary" >&2 || true
  fi
  caps=$(singbox_file_capabilities "$target")
  printf '文件能力：%s\n' "${caps:-无}" >&2
  if command_exists findmnt; then
    findmnt -T "$target" -o TARGET,SOURCE,FSTYPE,OPTIONS -n >&2 || true
  fi
  if command_exists systemctl && [[ $(init_system 2>/dev/null || true) == systemd ]]; then
    systemctl show "$SBM_SERVICE" \
      -p ActiveState -p SubState -p Result -p ExecMainCode -p ExecMainStatus \
      --no-pager >&2 2>/dev/null || true
  fi
}
