#!/usr/bin/env bash
# shellcheck shell=bash

SBM_BBR_SYSCTL_CONFIG="${SBM_BBR_SYSCTL_CONFIG:-/etc/sysctl.d/99-sb-manager-bbr.conf}"
SBM_BBR_BACKUP_DIR="${SBM_BBR_BACKUP_DIR:-$SBM_VAR/bbr}"
SBM_BBR_BACKUP_META="${SBM_BBR_BACKUP_META:-$SBM_BBR_BACKUP_DIR/previous.json}"
SBM_BBR_BACKUP_CONFIG="${SBM_BBR_BACKUP_CONFIG:-$SBM_BBR_BACKUP_DIR/previous.conf}"
SBM_BBR_SYSCTL_CMD="${SBM_BBR_SYSCTL_CMD:-sysctl}"
SBM_BBR_MODPROBE_CMD="${SBM_BBR_MODPROBE_CMD:-modprobe}"
SBM_BBR_MARKER='# Managed by sb-manager; use sb bbr disable to restore previous values.'

bbr_sysctl_get() { "$SBM_BBR_SYSCTL_CMD" -n "$1" 2>/dev/null; }
bbr_config_managed() { grep -Fqx "$SBM_BBR_MARKER" "$SBM_BBR_SYSCTL_CONFIG" 2>/dev/null; }
bbr_backup_valid() {
  [[ -s "$SBM_BBR_BACKUP_META" ]] &&
    jq -e '.schema_version==1 and (.config_existed|type=="boolean") and (.qdisc|type=="string") and (.congestion_control|type=="string")' \
      "$SBM_BBR_BACKUP_META" >/dev/null 2>&1
}

bbr_available() {
  local available
  available=$(bbr_sysctl_get net.ipv4.tcp_available_congestion_control || true)
  [[ " $available " == *' bbr '* ]]
}

bbr_status() {
  local qdisc cc available enabled
  qdisc=$(bbr_sysctl_get net.core.default_qdisc || true)
  cc=$(bbr_sysctl_get net.ipv4.tcp_congestion_control || true)
  available=$(bbr_sysctl_get net.ipv4.tcp_available_congestion_control || true)
  enabled=false
  [[ "$qdisc" == fq && "$cc" == bbr ]] && enabled=true
  if [[ ${1:-0} == 1 ]]; then
    jq -n --arg qdisc "$qdisc" --arg cc "$cc" --arg available "$available" --arg config "$SBM_BBR_SYSCTL_CONFIG" \
      --argjson enabled "$enabled" '{enabled:$enabled,qdisc:$qdisc,congestion_control:$cc,available:$available,managed_config:$config}'
  else
    printf 'BBR：%s\n当前 qdisc：%s\n当前拥塞控制：%s\n可用算法：%s\n管理配置：%s\n' \
      "$([[ "$enabled" == true ]] && echo '已启用' || echo '未启用')" "${qdisc:--}" "${cc:--}" "${available:--}" "$SBM_BBR_SYSCTL_CONFIG"
  fi
}

bbr_save_previous() {
  local qdisc=$1 cc=$2 existed=false meta_tmp config_tmp
  mkdir -p "$SBM_BBR_BACKUP_DIR"
  chmod 0700 "$SBM_BBR_BACKUP_DIR"
  if [[ -e "$SBM_BBR_SYSCTL_CONFIG" ]]; then
    existed=true
    config_tmp=$(mktemp "$SBM_BBR_BACKUP_DIR/.previous-conf.XXXXXX")
    cp -p "$SBM_BBR_SYSCTL_CONFIG" "$config_tmp"
    mv -f "$config_tmp" "$SBM_BBR_BACKUP_CONFIG"
  else
    rm -f "$SBM_BBR_BACKUP_CONFIG"
  fi
  meta_tmp=$(mktemp "$SBM_BBR_BACKUP_DIR/.previous-json.XXXXXX")
  jq -n --arg qdisc "$qdisc" --arg cc "$cc" --argjson existed "$existed" \
    '{schema_version:1,qdisc:$qdisc,congestion_control:$cc,config_existed:$existed}' >"$meta_tmp"
  chmod 0600 "$meta_tmp"
  mv -f "$meta_tmp" "$SBM_BBR_BACKUP_META"
}

bbr_apply_config() {
  "$SBM_BBR_SYSCTL_CMD" -p "$SBM_BBR_SYSCTL_CONFIG" >"$SBM_RUN/bbr-sysctl.log" 2>&1 || {
    log_error "应用 BBR sysctl 配置失败，详见 $SBM_RUN/bbr-sysctl.log"
    return 1
  }
}

_bbr_enable() {
  local qdisc cc tmp
  bbr_available || {
    command_exists "$SBM_BBR_MODPROBE_CMD" || die '内核未提供 BBR，且系统缺少 modprobe。'
    "$SBM_BBR_MODPROBE_CMD" tcp_bbr >/dev/null 2>&1 || true
    bbr_available || die '当前内核不支持 BBR；请安装包含 tcp_bbr 的内核模块后重试。'
  }
  qdisc=$(bbr_sysctl_get net.core.default_qdisc || true)
  cc=$(bbr_sysctl_get net.ipv4.tcp_congestion_control || true)
  if [[ -e "$SBM_BBR_BACKUP_META" ]] && ! bbr_backup_valid; then
    die "BBR 备份元数据损坏：$SBM_BBR_BACKUP_META"
  fi
  if [[ ! -s "$SBM_BBR_BACKUP_META" ]]; then bbr_save_previous "$qdisc" "$cc"; fi
  mkdir -p "$(dirname "$SBM_BBR_SYSCTL_CONFIG")" "$SBM_RUN"
  tmp=$(mktemp "$(dirname "$SBM_BBR_SYSCTL_CONFIG")/.sb-manager-bbr.XXXXXX")
  printf '%s\n' "$SBM_BBR_MARKER" \
    'net.core.default_qdisc=fq' 'net.ipv4.tcp_congestion_control=bbr' >"$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$SBM_BBR_SYSCTL_CONFIG"
  bbr_apply_config || { bbr_restore_previous; die 'BBR 启用失败，已尝试恢复启用前配置。'; }
  qdisc=$(bbr_sysctl_get net.core.default_qdisc || true); cc=$(bbr_sysctl_get net.ipv4.tcp_congestion_control || true)
  [[ "$qdisc" == fq && "$cc" == bbr ]] || { bbr_restore_previous; die 'BBR sysctl 校验失败，已尝试恢复启用前配置。'; }
  log_ok 'BBR 已启用（fq + tcp_congestion_control=bbr）。'
}
bbr_enable() { with_lock _bbr_enable; }

bbr_restore_previous() {
  local existed qdisc cc
  [[ -s "$SBM_BBR_BACKUP_META" ]] || {
    if bbr_config_managed; then
      log_error "BBR 备份元数据缺失，拒绝删除托管配置：$SBM_BBR_BACKUP_META"
      return 1
    fi
    return 0
  }
  bbr_backup_valid || { log_error "BBR 备份元数据损坏：$SBM_BBR_BACKUP_META"; return 1; }
  existed=$(jq -r '.config_existed' "$SBM_BBR_BACKUP_META") || return 1
  qdisc=$(jq -r '.qdisc' "$SBM_BBR_BACKUP_META") || return 1
  cc=$(jq -r '.congestion_control' "$SBM_BBR_BACKUP_META") || return 1
  if [[ "$existed" == true ]]; then
    [[ -f "$SBM_BBR_BACKUP_CONFIG" ]] || { log_error 'BBR 原配置备份缺失。'; return 1; }
    cp -p "$SBM_BBR_BACKUP_CONFIG" "$SBM_BBR_SYSCTL_CONFIG" || return 1
    bbr_apply_config || return 1
  else
    rm -f "$SBM_BBR_SYSCTL_CONFIG"
  fi
  [[ -z "$qdisc" ]] || "$SBM_BBR_SYSCTL_CMD" -w "net.core.default_qdisc=$qdisc" >/dev/null 2>&1 || return 1
  [[ -z "$cc" ]] || "$SBM_BBR_SYSCTL_CMD" -w "net.ipv4.tcp_congestion_control=$cc" >/dev/null 2>&1 || return 1
  rm -f "$SBM_BBR_BACKUP_META" "$SBM_BBR_BACKUP_CONFIG"
}

_bbr_disable() {
  if [[ ! -s "$SBM_BBR_BACKUP_META" ]] && ! bbr_config_managed; then
    log_warn 'BBR 未由 sb-manager 管理，无需停用。'
    return 0
  fi
  bbr_restore_previous || die '恢复 BBR 启用前配置失败；已保留备份，请检查 sysctl 日志后重试。'
  log_ok 'BBR 已停用并恢复启用前的 sysctl 配置。'
}
bbr_disable() { with_lock _bbr_disable; }
