#!/usr/bin/env bash
# shellcheck shell=bash

uninstall_manager() {
  require_root
  local purge=${1:-0} message
  if [[ "$purge" == 1 ]]; then message="确认彻底卸载并删除全部配置、证书、密钥和备份？"; else message="确认卸载 sb-manager？配置和密钥将保留"; fi
  confirm "$message" N || return 0
  if [[ "$SBM_SKIP_SYSTEMD" != 1 ]]; then
    systemctl disable --now "$SBM_SERVICE" "$SBM_TUNNEL_SERVICE" sb-core-update.timer sb-acme-renew.timer sb-quick-tunnel-refresh.timer >/dev/null 2>&1 || true
    rm -f "$SBM_SYSTEMD_DIR/$SBM_SERVICE" "$SBM_SYSTEMD_DIR/$SBM_TUNNEL_SERVICE" \
      "$SBM_SYSTEMD_DIR/sb-core-update.service" "$SBM_SYSTEMD_DIR/sb-core-update.timer" \
      "$SBM_SYSTEMD_DIR/sb-acme-renew.service" "$SBM_SYSTEMD_DIR/sb-acme-renew.timer" \
      "$SBM_SYSTEMD_DIR/sb-quick-tunnel-refresh.service" "$SBM_SYSTEMD_DIR/sb-quick-tunnel-refresh.timer"
    systemctl daemon-reload || true
  fi
  [[ -L "$SBM_SING_BOX_BIN" && $(readlink -f "$SBM_SING_BOX_BIN") == "$SBM_LIB"/* ]] && rm -f "$SBM_SING_BOX_BIN"
  [[ -L "$SBM_CLOUDFLARED_BIN" && $(readlink -f "$SBM_CLOUDFLARED_BIN") == "$SBM_LIB"/* ]] && rm -f "$SBM_CLOUDFLARED_BIN"
  rm -f "$SBM_BIN_DIR/sb"
  rm -rf "$SBM_LIB"
  if [[ "$purge" == 1 ]]; then
    rm -rf "$SBM_ETC" "$SBM_VAR"
    userdel "$SBM_SERVICE_USER" >/dev/null 2>&1 || true
    log_ok '程序、配置和密钥已全部删除。'
  else
    log_ok "程序已卸载；数据保留在 $SBM_ETC 和 $SBM_VAR。"
  fi
}
