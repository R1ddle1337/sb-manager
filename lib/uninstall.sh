#!/usr/bin/env bash
# shellcheck shell=bash

remove_manager_owned_link() {
  local link=$1 target
  [[ -L "$link" ]] || return 0
  target=$(readlink "$link" 2>/dev/null || true)
  if [[ "$target" == *"$SBM_LIB/"* ]]; then
    rm -f -- "$link"
  fi
}

uninstall_manager() {
  [[ ${SBM_TEST_MODE:-0} == 1 ]] || require_root
  local purge=${1:-0} assume_yes=${2:-0} message
  case "$purge" in 0|1) ;; *) die '卸载模式无效。' ;; esac

  if [[ "$purge" == 1 ]]; then
    message='确认彻底卸载并删除全部配置、证书、密钥、核心和备份？'
  else
    message='确认卸载 sb-manager 程序？配置、证书、密钥和备份将保留'
  fi
  if [[ "$assume_yes" != 1 ]]; then
    confirm "$message" N || return 0
  fi

  local units=(
    "$SBM_SERVICE"
    "$SBM_TUNNEL_SERVICE"
    sb-core-update.service
    sb-core-update.timer
    sb-acme-renew.service
    sb-acme-renew.timer
    sb-quick-tunnel-refresh.service
    sb-quick-tunnel-refresh.timer
  )
  if [[ "$SBM_SKIP_SYSTEMD" != 1 ]]; then
    systemctl disable --now "${units[@]}" >/dev/null 2>&1 || true
    rm -f \
      "$SBM_SYSTEMD_DIR/$SBM_SERVICE" \
      "$SBM_SYSTEMD_DIR/$SBM_TUNNEL_SERVICE" \
      "$SBM_SYSTEMD_DIR/sb-core-update.service" \
      "$SBM_SYSTEMD_DIR/sb-core-update.timer" \
      "$SBM_SYSTEMD_DIR/sb-acme-renew.service" \
      "$SBM_SYSTEMD_DIR/sb-acme-renew.timer" \
      "$SBM_SYSTEMD_DIR/sb-quick-tunnel-refresh.service" \
      "$SBM_SYSTEMD_DIR/sb-quick-tunnel-refresh.timer"
    systemctl daemon-reload || true
    systemctl reset-failed "${units[@]}" >/dev/null 2>&1 || true
  fi

  remove_manager_owned_link "$SBM_SING_BOX_BIN"
  remove_manager_owned_link "$SBM_CLOUDFLARED_BIN"
  remove_manager_owned_link "$SBM_BIN_DIR/sb"
  rm -rf -- "$SBM_LIB" "$SBM_RUN"

  if [[ "$purge" == 1 ]]; then
    rm -rf -- "$SBM_ETC" "$SBM_VAR"
    if [[ ${SBM_TEST_MODE:-0} != 1 ]]; then
      local passwd_entry account_home
      passwd_entry=$(getent passwd "$SBM_SERVICE_USER" 2>/dev/null || true)
      account_home=$(cut -d: -f6 <<<"$passwd_entry")
      if [[ -n "$passwd_entry" && "$account_home" == "$SBM_VAR" ]]; then
        userdel "$SBM_SERVICE_USER" >/dev/null 2>&1 || true
        groupdel "$SBM_SERVICE_USER" >/dev/null 2>&1 || true
      elif [[ -n "$passwd_entry" ]]; then
        log_warn "保留同名系统用户 $SBM_SERVICE_USER：其 home 不是 $SBM_VAR，可能并非由本项目创建。"
      fi
    fi
    log_ok 'sb-manager、全部配置、证书、密钥、核心和备份已彻底删除。'
  else
    log_ok "程序已卸载；数据保留在 $SBM_ETC 和 $SBM_VAR。"
    log_info '重新运行一键安装命令可恢复程序并继续使用原有数据。'
  fi
  SBM_UNINSTALLED=1
}
