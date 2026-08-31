#!/usr/bin/env bash
# shellcheck shell=bash

subscription_duration_seconds() {
  local value=$1 number unit
  [[ "$value" =~ ^([1-9][0-9]*)([hd])$ ]] || die '有效期格式应为 24h 或 7d。'
  number=${BASH_REMATCH[1]}; unit=${BASH_REMATCH[2]}
  [[ "$unit" == h ]] && printf '%s\n' "$((number * 3600))" || printf '%s\n' "$((number * 86400))"
}

subscription_write_service() {
  local python unit backend
  if ! command_exists python3 && ! command_exists python && declare -F dependency_require_feature >/dev/null 2>&1; then
    dependency_require_feature subscription || die '订阅服务需要 python3；请运行 sb deps install subscription。'
  fi
  python=$(command -v python3 || command -v python || true)
  [[ -n "$python" ]] || die '订阅服务需要 python3。'
  backend=$(effective_init_system)
  mkdir -p "$SBM_SUBSCRIPTIONS"
  chown root:"$SBM_SERVICE_USER" "$SBM_SUBSCRIPTIONS" 2>/dev/null || true
  chmod 0750 "$SBM_SUBSCRIPTIONS"
  case "$backend" in
    systemd)
      unit="$SBM_SYSTEMD_DIR/$SBM_SUBSCRIPTION_SERVICE"
      mkdir -p "$SBM_SYSTEMD_DIR"
      cat >"$unit" <<EOF_UNIT
[Unit]
Description=sb-manager loopback subscription service
After=network.target

[Service]
Type=simple
User=$SBM_SERVICE_USER
Group=$SBM_SERVICE_USER
ExecStart=$python $SBM_LIB/libexec/subscription_server.py --root $SBM_SUBSCRIPTIONS --listen 127.0.0.1 --port $SBM_SUBSCRIPTION_PORT
Restart=on-failure
RestartSec=3s
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
ReadOnlyPaths=$SBM_SUBSCRIPTIONS $SBM_LIB
TasksMax=128
MemoryMax=128M
UMask=0027

[Install]
WantedBy=multi-user.target
EOF_UNIT
      chmod 0644 "$unit"
      ;;
    openrc)
      write_openrc_supervised_service "$SBM_OPENRC_DIR/$(service_native_name "$SBM_SUBSCRIPTION_SERVICE")" \
        'sb-manager subscription' 'sb-manager loopback subscription service' "$python" \
        "$SBM_LIB/libexec/subscription_server.py --root $SBM_SUBSCRIPTIONS --listen 127.0.0.1 --port $SBM_SUBSCRIPTION_PORT" \
        "$SBM_SERVICE_USER" "$SBM_LOG_DIR/subscription.log" "$SBM_LOG_DIR/subscription.err.log" 'after firewall'
      ;;
  esac
}

subscription_reconcile() {
  local start=${1:-1} backend
  if ! find "$SBM_SUBSCRIPTIONS" -maxdepth 1 -type f -name '*.meta.json' -print -quit 2>/dev/null | grep -q .; then
    if [[ "$SBM_SKIP_INIT" != 1 ]] && service_exists "$SBM_SUBSCRIPTION_SERVICE"; then
      backend=$(effective_init_system)
      service_disable "$SBM_SUBSCRIPTION_SERVICE" || true
      service_stop "$SBM_SUBSCRIPTION_SERVICE" || true
      case "$backend" in
        systemd) rm -f "$SBM_SYSTEMD_DIR/$SBM_SUBSCRIPTION_SERVICE" ;;
        openrc) rm -f "$SBM_OPENRC_DIR/$(service_native_name "$SBM_SUBSCRIPTION_SERVICE")" ;;
      esac
      service_reload_manager || true
    fi
    return 0
  fi
  subscription_write_service
  [[ "$SBM_SKIP_INIT" == 1 || "$start" != 1 ]] && return 0
  service_reload_manager
  service_enable "$SBM_SUBSCRIPTION_SERVICE"
  service_restart "$SBM_SUBSCRIPTION_SERVICE"
  service_wait_active "$SBM_SUBSCRIPTION_SERVICE" 20 || return 1
}

_subscription_create() {
  local duration=${1:-7d} mode=${2:-mixed} seconds now expires token digest profile meta
  seconds=$(subscription_duration_seconds "$duration"); now=$(date +%s); expires=$((now + seconds))
  token=$(random_password 36); digest=$(printf '%s' "$token" | sha256sum | awk '{print $1}')
  mkdir -p "$SBM_SUBSCRIPTIONS"
  profile="$SBM_SUBSCRIPTIONS/$digest.profile.json"; meta="$SBM_SUBSCRIPTIONS/$digest.meta.json"
  export_client_config "$profile" "$mode"
  jq -n --arg id "${digest:0:12}" --arg mode "$mode" --argjson created "$now" --argjson expires "$expires" \
    '{schema_version:1,id:$id,mode:$mode,created_at_epoch:$created,expires_at_epoch:$expires}' >"$meta.tmp"
  chmod 0640 "$profile" "$meta.tmp"
  chgrp "$SBM_SERVICE_USER" "$profile" "$meta.tmp" 2>/dev/null || true
  mv -f "$meta.tmp" "$meta"
  subscription_reconcile 1
  printf '订阅 ID：%s\n有效期至 epoch：%s\n本机 URL：http://127.0.0.1:%s/sub/%s\n' "${digest:0:12}" "$expires" "$SBM_SUBSCRIPTION_PORT" "$token"
  log_warn '订阅令牌只显示一次。不要直接向公网开放该端口；请使用 SSH 转发或受认证的 TLS 代理。'
}
subscription_create() { with_lock _subscription_create "$@"; }

subscription_list() {
  local json=${1:-0} meta now id mode expires status
  now=$(date +%s)
  if [[ "$json" == 1 ]]; then
    for meta in "$SBM_SUBSCRIPTIONS"/*.meta.json; do
      [[ -f "$meta" ]] || continue
      id=$(jq -r '.id' "$meta"); mode=$(jq -r '.mode' "$meta"); expires=$(jq -r '.expires_at_epoch' "$meta")
      (( expires > now )) && status=active || status=expired
      jq -n --arg id "$id" --arg mode "$mode" --argjson expires "$expires" --arg status "$status" '{id:$id,mode:$mode,expires_at_epoch:$expires,status:$status}'
    done | jq -s .
    return
  fi
  printf '%-14s %-8s %-14s %s\n' ID MODE EXPIRES_EPOCH STATUS
  for meta in "$SBM_SUBSCRIPTIONS"/*.meta.json; do
    [[ -f "$meta" ]] || continue
    id=$(jq -r '.id' "$meta"); mode=$(jq -r '.mode' "$meta"); expires=$(jq -r '.expires_at_epoch' "$meta")
    (( expires > now )) && status=active || status=expired
    printf '%-14s %-8s %-14s %s\n' "$id" "$mode" "$expires" "$status"
  done
}

_subscription_revoke() {
  local token=$1 digest
  digest=$(printf '%s' "$token" | sha256sum | awk '{print $1}')
  [[ -f "$SBM_SUBSCRIPTIONS/$digest.meta.json" ]] || die '订阅令牌不存在。'
  rm -f "$SBM_SUBSCRIPTIONS/$digest.meta.json" "$SBM_SUBSCRIPTIONS/$digest.profile.json"
  log_ok "订阅已撤销：${digest:0:12}"
}
subscription_revoke() { with_lock _subscription_revoke "$@"; }

subscription_status() {
  subscription_list "${1:-0}"
  [[ ${1:-0} == 1 ]] && return 0
  if [[ "$SBM_SKIP_INIT" != 1 ]] && service_exists "$SBM_SUBSCRIPTION_SERVICE"; then service_status_text "$SBM_SUBSCRIPTION_SERVICE" || true; fi
}
