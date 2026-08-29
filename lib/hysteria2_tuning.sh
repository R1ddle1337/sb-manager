#!/usr/bin/env bash
# shellcheck shell=bash

# Hysteria2 官方建议的 Linux UDP socket buffer 上限。只管理这两个键，
# 避免把系统上其他 UDP/TCP 调优混入本项目的恢复范围。
SBM_HY2_UDP_BUFFER_SIZE="${SBM_HY2_UDP_BUFFER_SIZE:-16777216}"
SBM_HY2_UDP_BUFFER_SYSCTL_CONFIG="${SBM_HY2_UDP_BUFFER_SYSCTL_CONFIG:-/etc/sysctl.d/99-hysteria.conf}"
SBM_HY2_UDP_BUFFER_BACKUP_DIR="${SBM_HY2_UDP_BUFFER_BACKUP_DIR:-$SBM_VAR/hysteria2-udp-buffer}"
SBM_HY2_UDP_BUFFER_BACKUP_META="${SBM_HY2_UDP_BUFFER_BACKUP_META:-$SBM_HY2_UDP_BUFFER_BACKUP_DIR/previous.json}"
SBM_HY2_UDP_BUFFER_BACKUP_CONFIG="${SBM_HY2_UDP_BUFFER_BACKUP_CONFIG:-$SBM_HY2_UDP_BUFFER_BACKUP_DIR/previous.conf}"
SBM_HY2_UDP_BUFFER_SYSCTL_CMD="${SBM_HY2_UDP_BUFFER_SYSCTL_CMD:-sysctl}"
SBM_HY2_UDP_BUFFER_MARKER='# Managed by sb-manager; use sb hy2 buffer disable to restore previous values.'

hy2_udp_buffer_sysctl_get() { "$SBM_HY2_UDP_BUFFER_SYSCTL_CMD" -n "$1" 2>/dev/null; }
hy2_udp_buffer_config_managed() { grep -Fqx "$SBM_HY2_UDP_BUFFER_MARKER" "$SBM_HY2_UDP_BUFFER_SYSCTL_CONFIG" 2>/dev/null; }
hy2_udp_buffer_backup_valid() {
  [[ -s "$SBM_HY2_UDP_BUFFER_BACKUP_META" ]] &&
    jq -e '.schema_version==1 and (.config_existed|type=="boolean") and (.rmem_max|type=="string") and (.wmem_max|type=="string")' \
      "$SBM_HY2_UDP_BUFFER_BACKUP_META" >/dev/null 2>&1
}

hy2_udp_buffer_status() {
  local rmem wmem enabled managed
  rmem=$(hy2_udp_buffer_sysctl_get net.core.rmem_max || true)
  wmem=$(hy2_udp_buffer_sysctl_get net.core.wmem_max || true)
  enabled=false
  managed=false
  [[ "$rmem" == "$SBM_HY2_UDP_BUFFER_SIZE" && "$wmem" == "$SBM_HY2_UDP_BUFFER_SIZE" ]] && enabled=true
  hy2_udp_buffer_config_managed && managed=true
  if [[ ${1:-0} == 1 ]]; then
    jq -n --arg rmem "$rmem" --arg wmem "$wmem" --arg size "$SBM_HY2_UDP_BUFFER_SIZE" \
      --arg config "$SBM_HY2_UDP_BUFFER_SYSCTL_CONFIG" --argjson enabled "$enabled" --argjson managed "$managed" \
      '{enabled:$enabled,managed:$managed,rmem_max:$rmem,wmem_max:$wmem,recommended_size:$size,managed_config:$config}'
  else
    printf 'Hysteria2 UDP 缓冲区：%s\nsb-manager 管理：%s\n接收缓冲区上限：%s\n发送缓冲区上限：%s\n官方建议值：%s\n管理配置：%s\n' \
      "$([[ "$enabled" == true ]] && echo '已生效' || echo '未生效')" \
      "$([[ "$managed" == true ]] && echo '是' || echo '否')" \
      "${rmem:--}" "${wmem:--}" "$SBM_HY2_UDP_BUFFER_SIZE" "$SBM_HY2_UDP_BUFFER_SYSCTL_CONFIG"
  fi
}

hy2_udp_buffer_save_previous() {
  local rmem=$1 wmem=$2 existed=false meta_tmp config_tmp
  mkdir -p "$SBM_HY2_UDP_BUFFER_BACKUP_DIR"
  chmod 0700 "$SBM_HY2_UDP_BUFFER_BACKUP_DIR"
  if [[ -e "$SBM_HY2_UDP_BUFFER_SYSCTL_CONFIG" ]]; then
    existed=true
    config_tmp=$(mktemp "$SBM_HY2_UDP_BUFFER_BACKUP_DIR/.previous-conf.XXXXXX")
    cp -p "$SBM_HY2_UDP_BUFFER_SYSCTL_CONFIG" "$config_tmp"
    mv -f "$config_tmp" "$SBM_HY2_UDP_BUFFER_BACKUP_CONFIG"
  else
    rm -f "$SBM_HY2_UDP_BUFFER_BACKUP_CONFIG"
  fi
  meta_tmp=$(mktemp "$SBM_HY2_UDP_BUFFER_BACKUP_DIR/.previous-json.XXXXXX")
  jq -n --arg rmem "$rmem" --arg wmem "$wmem" --argjson existed "$existed" \
    '{schema_version:1,rmem_max:$rmem,wmem_max:$wmem,config_existed:$existed}' >"$meta_tmp"
  chmod 0600 "$meta_tmp"
  mv -f "$meta_tmp" "$SBM_HY2_UDP_BUFFER_BACKUP_META"
}

hy2_udp_buffer_apply_config() {
  "$SBM_HY2_UDP_BUFFER_SYSCTL_CMD" -p "$SBM_HY2_UDP_BUFFER_SYSCTL_CONFIG" >"$SBM_RUN/hysteria2-udp-buffer-sysctl.log" 2>&1 || {
    log_error "应用 Hysteria2 UDP 缓冲区 sysctl 配置失败，详见 $SBM_RUN/hysteria2-udp-buffer-sysctl.log"
    return 1
  }
}

_hy2_udp_buffer_enable() {
  local rmem wmem tmp
  [[ "$SBM_HY2_UDP_BUFFER_SIZE" =~ ^[0-9]+$ ]] && (( SBM_HY2_UDP_BUFFER_SIZE > 0 )) || die 'Hysteria2 UDP 缓冲区目标值必须是正整数。'
  rmem=$(hy2_udp_buffer_sysctl_get net.core.rmem_max || true)
  wmem=$(hy2_udp_buffer_sysctl_get net.core.wmem_max || true)
  [[ -n "$rmem" && -n "$wmem" ]] || die '当前内核不支持 net.core.rmem_max/net.core.wmem_max。'
  if [[ -e "$SBM_HY2_UDP_BUFFER_BACKUP_META" ]] && ! hy2_udp_buffer_backup_valid; then
    die "Hysteria2 UDP 缓冲区备份元数据损坏：$SBM_HY2_UDP_BUFFER_BACKUP_META"
  fi
  if [[ ! -s "$SBM_HY2_UDP_BUFFER_BACKUP_META" ]]; then
    hy2_udp_buffer_save_previous "$rmem" "$wmem"
  fi
  mkdir -p "$(dirname "$SBM_HY2_UDP_BUFFER_SYSCTL_CONFIG")" "$SBM_RUN"
  tmp=$(mktemp "$(dirname "$SBM_HY2_UDP_BUFFER_SYSCTL_CONFIG")/.sb-manager-hysteria.XXXXXX")
  printf '%s\n' "$SBM_HY2_UDP_BUFFER_MARKER" \
    "net.core.rmem_max=$SBM_HY2_UDP_BUFFER_SIZE" "net.core.wmem_max=$SBM_HY2_UDP_BUFFER_SIZE" >"$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$SBM_HY2_UDP_BUFFER_SYSCTL_CONFIG"
  hy2_udp_buffer_apply_config || {
    hy2_udp_buffer_restore_previous
    die 'Hysteria2 UDP 缓冲区启用失败，已尝试恢复启用前配置。'
  }
  rmem=$(hy2_udp_buffer_sysctl_get net.core.rmem_max || true)
  wmem=$(hy2_udp_buffer_sysctl_get net.core.wmem_max || true)
  [[ "$rmem" == "$SBM_HY2_UDP_BUFFER_SIZE" && "$wmem" == "$SBM_HY2_UDP_BUFFER_SIZE" ]] || {
    hy2_udp_buffer_restore_previous
    die 'Hysteria2 UDP 缓冲区 sysctl 校验失败，已尝试恢复启用前配置。'
  }
  log_ok "Hysteria2 UDP 缓冲区已启用（${SBM_HY2_UDP_BUFFER_SIZE} 字节）。"
}
hy2_udp_buffer_enable() { with_lock _hy2_udp_buffer_enable; }

hy2_udp_buffer_restore_previous() {
  local existed rmem wmem
  [[ -s "$SBM_HY2_UDP_BUFFER_BACKUP_META" ]] || {
    if hy2_udp_buffer_config_managed; then
      log_error "Hysteria2 UDP 缓冲区备份元数据缺失，拒绝删除托管配置：$SBM_HY2_UDP_BUFFER_BACKUP_META"
      return 1
    fi
    return 0
  }
  hy2_udp_buffer_backup_valid || { log_error "Hysteria2 UDP 缓冲区备份元数据损坏：$SBM_HY2_UDP_BUFFER_BACKUP_META"; return 1; }
  existed=$(jq -r '.config_existed' "$SBM_HY2_UDP_BUFFER_BACKUP_META") || return 1
  rmem=$(jq -r '.rmem_max' "$SBM_HY2_UDP_BUFFER_BACKUP_META") || return 1
  wmem=$(jq -r '.wmem_max' "$SBM_HY2_UDP_BUFFER_BACKUP_META") || return 1
  if [[ "$existed" == true ]]; then
    [[ -f "$SBM_HY2_UDP_BUFFER_BACKUP_CONFIG" ]] || { log_error 'Hysteria2 UDP 缓冲区原配置备份缺失。'; return 1; }
    cp -p "$SBM_HY2_UDP_BUFFER_BACKUP_CONFIG" "$SBM_HY2_UDP_BUFFER_SYSCTL_CONFIG" || return 1
    hy2_udp_buffer_apply_config || return 1
  else
    rm -f "$SBM_HY2_UDP_BUFFER_SYSCTL_CONFIG"
  fi
  [[ -z "$rmem" ]] || "$SBM_HY2_UDP_BUFFER_SYSCTL_CMD" -w "net.core.rmem_max=$rmem" >/dev/null 2>&1 || return 1
  [[ -z "$wmem" ]] || "$SBM_HY2_UDP_BUFFER_SYSCTL_CMD" -w "net.core.wmem_max=$wmem" >/dev/null 2>&1 || return 1
  rm -f "$SBM_HY2_UDP_BUFFER_BACKUP_META" "$SBM_HY2_UDP_BUFFER_BACKUP_CONFIG"
}

_hy2_udp_buffer_disable() {
  if [[ ! -s "$SBM_HY2_UDP_BUFFER_BACKUP_META" ]] && ! hy2_udp_buffer_config_managed; then
    log_warn 'Hysteria2 UDP 缓冲区未由 sb-manager 管理，无需恢复。'
    return 0
  fi
  hy2_udp_buffer_restore_previous || die '恢复 Hysteria2 UDP 缓冲区启用前配置失败；已保留备份，请检查 sysctl 日志后重试。'
  log_ok 'Hysteria2 UDP 缓冲区已停用并恢复启用前的 sysctl 配置。'
}
hy2_udp_buffer_disable() { with_lock _hy2_udp_buffer_disable; }
