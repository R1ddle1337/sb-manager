#!/usr/bin/env bash
# shellcheck shell=bash

remove_manager_owned_link() {
  local link=$1 target
  [[ -L "$link" ]] || return 0
  target=$(readlink "$link" 2>/dev/null || true)
  if [[ "$target" == *"$SBM_LIB/"* ]]; then rm -f -- "$link"; fi
}

delete_service_account() {
  local passwd_entry account_home
  passwd_entry=$(account_entry "$SBM_SERVICE_USER" || true)
  account_home=$(cut -d: -f6 <<<"$passwd_entry")
  if [[ -n "$passwd_entry" && "$account_home" == "$SBM_VAR" ]]; then
    if command_exists userdel; then userdel "$SBM_SERVICE_USER" >/dev/null 2>&1 || true
    elif command_exists deluser; then deluser "$SBM_SERVICE_USER" >/dev/null 2>&1 || true; fi
    if group_exists "$SBM_SERVICE_USER"; then
      if command_exists groupdel; then groupdel "$SBM_SERVICE_USER" >/dev/null 2>&1 || true
      elif command_exists delgroup; then delgroup "$SBM_SERVICE_USER" >/dev/null 2>&1 || true; fi
    fi
  elif [[ -n "$passwd_entry" ]]; then
    log_warn "保留同名系统用户 $SBM_SERVICE_USER：其 home 不是 $SBM_VAR，可能并非由本项目创建。"
  fi
}

uninstall_manager() {
  [[ ${SBM_TEST_MODE:-0} == 1 ]] || require_root
  local purge=${1:-0} assume_yes=${2:-0} message backend
  case "$purge" in 0|1) ;; *) die '卸载模式无效。' ;; esac

  if [[ "$purge" == 1 ]]; then
    message='确认彻底卸载并删除全部配置、证书、密钥、核心和备份？'
  else
    message='确认卸载 sb-manager 程序？配置、证书、密钥和备份将保留'
  fi
  if [[ "$assume_yes" != 1 ]]; then confirm "$message" N || return 0; fi

  if [[ -e "$SBM_BBR_SYSCTL_CONFIG" || -s "$SBM_BBR_BACKUP_META" ]]; then
    bbr_restore_previous || die "无法恢复 BBR 启用前的 sysctl；卸载已取消，请检查 $SBM_BBR_BACKUP_DIR。"
    log_info '已恢复 BBR 启用前的 sysctl 配置。'
  fi

  backend=$(init_system 2>/dev/null || true)
  if [[ "$SBM_SKIP_INIT" != 1 ]] && declare -F traffic_delete_table_unlocked >/dev/null 2>&1; then
    if jq -e '.schema_version==2 and (.nodes|type=="array")' "$SBM_STATE" >/dev/null 2>&1; then
      traffic_checkpoint_unlocked || log_warn '卸载前流量计数同步失败。'
    else
      log_warn '状态文件无效，跳过卸载前流量计数同步。'
    fi
    traffic_delete_table_unlocked || true
  fi
  if [[ "$SBM_SKIP_INIT" != 1 ]]; then
    service_disable "$SBM_TUNNEL_SERVICE" || true
    service_stop "$SBM_TUNNEL_SERVICE" || true
    service_disable "$SBM_SERVICE" || true
    service_stop "$SBM_SERVICE" || true
    service_disable "$SBM_NGINX_STREAM_SERVICE" || true
    service_stop "$SBM_NGINX_STREAM_SERVICE" || true
    service_disable "$SBM_SUBSCRIPTION_SERVICE" || true
    service_stop "$SBM_SUBSCRIPTION_SERVICE" || true
    service_disable "$SBM_TRAFFIC_SERVICE" || true
    service_stop "$SBM_TRAFFIC_SERVICE" || true
    if [[ "$backend" == systemd ]]; then
      systemctl disable --now sb-core-update.timer sb-acme-renew.timer sb-quick-tunnel-refresh.timer sb-traffic-sync.timer sb-health-check.timer >/dev/null 2>&1 || true
      systemctl reset-failed "$SBM_SERVICE" "$SBM_TUNNEL_SERVICE" "$SBM_NGINX_STREAM_SERVICE" "$SBM_TRAFFIC_SERVICE" >/dev/null 2>&1 || true
    fi
  fi

  # Remove definitions for both backends so a migrated installation cannot
  # leave stale services behind.
  rm -f \
    "$SBM_SYSTEMD_DIR/$SBM_SERVICE" \
    "$SBM_SYSTEMD_DIR/$SBM_TUNNEL_SERVICE" \
    "$SBM_SYSTEMD_DIR/$SBM_NGINX_STREAM_SERVICE" \
    "$SBM_SYSTEMD_DIR/sb-core-update.service" \
    "$SBM_SYSTEMD_DIR/sb-core-update.timer" \
    "$SBM_SYSTEMD_DIR/sb-acme-renew.service" \
    "$SBM_SYSTEMD_DIR/sb-acme-renew.timer" \
    "$SBM_SYSTEMD_DIR/sb-quick-tunnel-refresh.service" \
    "$SBM_SYSTEMD_DIR/sb-quick-tunnel-refresh.timer" \
    "$SBM_SYSTEMD_DIR/$SBM_SUBSCRIPTION_SERVICE" \
    "$SBM_SYSTEMD_DIR/$SBM_TRAFFIC_SERVICE" \
    "$SBM_SYSTEMD_DIR/sb-traffic-sync.service" \
    "$SBM_SYSTEMD_DIR/sb-traffic-sync.timer" \
    "$SBM_SYSTEMD_DIR/$SBM_HEALTH_SERVICE" \
    "$SBM_SYSTEMD_DIR/sb-health-check.timer" \
    "$SBM_OPENRC_DIR/sb-sing-box" \
    "$SBM_OPENRC_DIR/sb-cloudflared" \
    "$SBM_OPENRC_DIR/$(service_native_name "$SBM_NGINX_STREAM_SERVICE")" \
    "$SBM_OPENRC_DIR/$(service_native_name "$SBM_SUBSCRIPTION_SERVICE")" \
    "$SBM_OPENRC_DIR/$(service_native_name "$SBM_TRAFFIC_SERVICE")" \
    "$SBM_PERIODIC_DIR/daily/sb-core-update" \
    "$SBM_PERIODIC_DIR/daily/sb-acme-renew" \
    "$SBM_PERIODIC_DIR/15min/sb-quick-tunnel-refresh" \
    "$SBM_PERIODIC_DIR/15min/sb-traffic-sync" \
    "$SBM_PERIODIC_DIR/15min/sb-health-check" \
    "$SBM_LOGROTATE_FILE"
  service_reload_manager || true

  remove_manager_owned_link "$SBM_SING_BOX_BIN"
  remove_manager_owned_link "$SBM_CLOUDFLARED_BIN"
  remove_manager_owned_link "$SBM_BIN_DIR/sb"
  rm -f -- "$SBM_NGINX_STREAM_OPENRC_BIN"
  rmdir -- "$(dirname "$SBM_NGINX_STREAM_OPENRC_BIN")" 2>/dev/null || true
  rm -rf -- "$SBM_LIB" "$SBM_RUN"

  if [[ "$purge" == 1 ]]; then
    rm -rf -- "$SBM_ETC" "$SBM_VAR" "$SBM_LOG_DIR"
    [[ ${SBM_TEST_MODE:-0} == 1 ]] || delete_service_account
    log_ok 'sb-manager、全部配置、证书、密钥、核心、日志和备份已彻底删除。'
  else
    log_ok "程序已卸载；数据保留在 $SBM_ETC 和 $SBM_VAR。"
    log_info '重新运行一键安装命令可恢复程序并继续使用原有数据。'
  fi
  SBM_UNINSTALLED=1
}
