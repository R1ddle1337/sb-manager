#!/usr/bin/env bash
# shellcheck shell=bash

SBM_TUNNEL_TOKEN_FILE="${SBM_TUNNEL_TOKEN_FILE:-$SBM_SECRETS/cloudflared.token}"
SBM_QUICK_REFRESH_SERVICE="${SBM_QUICK_REFRESH_SERVICE:-sb-quick-tunnel-refresh.service}"
SBM_QUICK_REFRESH_TIMER="${SBM_QUICK_REFRESH_TIMER:-sb-quick-tunnel-refresh.timer}"
SBM_QUICK_REFRESH_PERIODIC="${SBM_QUICK_REFRESH_PERIODIC:-$SBM_PERIODIC_DIR/15min/sb-quick-tunnel-refresh}"

write_quick_refresh_schedule() {
  case "$(effective_init_system)" in
    systemd)
      mkdir -p "$SBM_SYSTEMD_DIR"
      cat >"$SBM_SYSTEMD_DIR/$SBM_QUICK_REFRESH_SERVICE" <<EOF_UNIT
[Unit]
Description=Refresh sb-manager Quick Tunnel hostname
After=$SBM_TUNNEL_SERVICE

[Service]
Type=oneshot
ExecStart=$SBM_BIN_DIR/sb tunnel refresh-auto
EOF_UNIT
      cat >"$SBM_SYSTEMD_DIR/$SBM_QUICK_REFRESH_TIMER" <<EOF_UNIT
[Unit]
Description=Periodically refresh sb-manager Quick Tunnel hostname

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
RandomizedDelaySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF_UNIT
      chmod 0644 "$SBM_SYSTEMD_DIR/$SBM_QUICK_REFRESH_SERVICE" "$SBM_SYSTEMD_DIR/$SBM_QUICK_REFRESH_TIMER"
      ;;
    openrc)
      mkdir -p "$(dirname "$SBM_QUICK_REFRESH_PERIODIC")"
      cat >"$SBM_QUICK_REFRESH_PERIODIC" <<EOF_JOB
#!/bin/sh
exec $SBM_BIN_DIR/sb tunnel refresh-auto >/dev/null 2>&1
EOF_JOB
      chmod 0755 "$SBM_QUICK_REFRESH_PERIODIC"
      ;;
  esac
}

quick_refresh_disable() {
  case "$(effective_init_system)" in
    systemd)
      if [[ "$SBM_SKIP_INIT" != 1 ]]; then systemctl disable --now "$SBM_QUICK_REFRESH_TIMER" >/dev/null 2>&1 || true; fi
      rm -f "$SBM_SYSTEMD_DIR/$SBM_QUICK_REFRESH_SERVICE" "$SBM_SYSTEMD_DIR/$SBM_QUICK_REFRESH_TIMER"
      ;;
    openrc) rm -f "$SBM_QUICK_REFRESH_PERIODIC" ;;
  esac
}

require_vmess_node() {
  local id=$1 node
  node=$(state_get_node "$id"); [[ -n "$node" ]] || die "节点不存在：$id"
  [[ $(jq -r '.protocol' <<<"$node") == vmess-ws-cf ]] || die 'Cloudflare Tunnel 仅用于 VMess-WS-CF 节点。'
  printf '%s\n' "$node"
}

write_tunnel_unit() {
  local mode=$1 node_id=$2 node port unit token_path backend dependency start_post
  cloudflared_require
  node=$(require_vmess_node "$node_id")
  port=$(jq -r '.port' <<<"$node")
  backend=$(effective_init_system)
  mkdir -p "$SBM_VAR/cloudflared-home" "$SBM_LOG_DIR"
  case "$backend" in
    systemd)
      unit="$SBM_SYSTEMD_DIR/$SBM_TUNNEL_SERVICE"
      mkdir -p "$SBM_SYSTEMD_DIR"
      if [[ "$mode" == fixed ]]; then
        token_path=$SBM_TUNNEL_TOKEN_FILE
        cat >"$unit" <<EOF_UNIT
[Unit]
Description=sb-manager Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SBM_SERVICE_USER
Group=$SBM_SERVICE_USER
Environment=HOME=$SBM_VAR/cloudflared-home
ExecStart=$SBM_CLOUDFLARED_BIN tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token-file $token_path
Restart=on-failure
RestartSec=5s
TasksMax=512
MemoryAccounting=true
TasksAccounting=true
UMask=0027
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadOnlyPaths=$SBM_ETC
ReadWritePaths=$SBM_VAR/cloudflared-home

[Install]
WantedBy=multi-user.target
EOF_UNIT
      else
        cat >"$unit" <<EOF_UNIT
[Unit]
Description=sb-manager Cloudflare Quick Tunnel
After=network-online.target $SBM_SERVICE
Wants=network-online.target
Requires=$SBM_SERVICE

[Service]
Type=simple
User=$SBM_SERVICE_USER
Group=$SBM_SERVICE_USER
Environment=HOME=$SBM_VAR/cloudflared-home
ExecStart=$SBM_CLOUDFLARED_BIN tunnel --no-autoupdate --edge-ip-version auto --protocol http2 --url http://127.0.0.1:$port
Restart=on-failure
RestartSec=5s
TasksMax=512
MemoryAccounting=true
TasksAccounting=true
UMask=0027
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadOnlyPaths=$SBM_ETC
ReadWritePaths=$SBM_VAR/cloudflared-home

[Install]
WantedBy=multi-user.target
EOF_UNIT
      fi
      chmod 0644 "$unit"
      ;;
    openrc)
      unit="$SBM_OPENRC_DIR/$(service_native_name "$SBM_TUNNEL_SERVICE")"
      mkdir -p "$SBM_OPENRC_DIR"
      dependency='after firewall'
      start_post=''
      if [[ "$mode" == fixed ]]; then
        write_openrc_supervised_service \
          "$unit" 'sb-manager Cloudflare Tunnel' 'sb-manager Cloudflare fixed Tunnel' \
          "$SBM_CLOUDFLARED_BIN" "tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token-file $SBM_TUNNEL_TOKEN_FILE" \
          "$SBM_SERVICE_USER" "$SBM_TUNNEL_LOG" "$SBM_TUNNEL_ERROR_LOG" "$dependency" '' "$SBM_VAR/cloudflared-home"
      else
        dependency="need $(service_native_name "$SBM_SERVICE")"
        start_post=$(cat <<EOF_POST

start_post() {
  (
    sleep 4
    "$SBM_BIN_DIR/sb" tunnel refresh-auto >/dev/null 2>&1 || true
  ) &
}
EOF_POST
)
        write_openrc_supervised_service \
          "$unit" 'sb-manager Cloudflare Quick Tunnel' 'sb-manager Cloudflare Quick Tunnel' \
          "$SBM_CLOUDFLARED_BIN" "tunnel --no-autoupdate --edge-ip-version auto --protocol http2 --url http://127.0.0.1:$port" \
          "$SBM_SERVICE_USER" "$SBM_TUNNEL_LOG" "$SBM_TUNNEL_ERROR_LOG" "$dependency" "$start_post" "$SBM_VAR/cloudflared-home"
      fi
      ;;
    *) die "未知服务后端：$backend" ;;
  esac
}

_tunnel_update_state() {
  local mode=$1 id=$2 domain=${3:-} address=${4:-} candidate
  candidate=$(state_candidate)
  jq --arg mode "$mode" --arg id "$id" --arg domain "$domain" --arg address "$address" '
    .tunnel.mode=$mode | .tunnel.node_id=$id |
    .tunnel.domain=(if $domain=="" then null else $domain end) |
    .tunnel.client_address=(if $address=="" then null else $address end) |
    (.nodes[]|select(.id==$id)|.domain)=$domain |
    (.nodes[]|select(.id==$id)|.client_address)=(if $address=="" then $domain else $address end)
  ' "$SBM_STATE" >"$candidate"
  if ! apply_candidate_state "$candidate" "tunnel-$mode"; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
}

tunnel_extract_domain() {
  local output=''
  case "$(init_system 2>/dev/null || true)" in
    systemd)
      output=$(journalctl -u "$SBM_TUNNEL_SERVICE" --since '-24 hours' --no-pager 2>/dev/null || true)
      ;;
    openrc)
      output=$(cat "$SBM_TUNNEL_LOG" "$SBM_TUNNEL_ERROR_LOG" 2>/dev/null || true)
      ;;
    *) return 1 ;;
  esac
  grep -Eo 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' <<<"$output" | tail -n1 | sed 's#https://##'
}

tunnel_start_enabled() {
  service_reload_manager
  service_enable "$SBM_TUNNEL_SERVICE" || true
  service_restart "$SBM_TUNNEL_SERVICE"
  service_wait_active "$SBM_TUNNEL_SERVICE" 30 2 || { service_failure_report "$SBM_TUNNEL_SERVICE"; return 1; }
}

_tunnel_setup_fixed() {
  local id=$1 domain=$2 token=${3:-} address=${4:-} node port tmp
  cloudflared_require
  node=$(require_vmess_node "$id"); port=$(jq -r '.port' <<<"$node")
  validate_domain "$domain" || die "无效 Tunnel 域名：$domain"
  [[ -n "$token" ]] || prompt_secret token 'Cloudflare Tunnel Token'
  [[ -n "$token" ]] || die 'Tunnel Token 不能为空。'
  [[ -n "$address" ]] || address=$domain
  tmp=$(mktemp "$SBM_SECRETS/.cloudflared-token.XXXXXX")
  printf '%s\n' "$token" >"$tmp"
  chmod 0640 "$tmp"
  set_group_if_exists "$SBM_SERVICE_USER" "$tmp"
  mv "$tmp" "$SBM_TUNNEL_TOKEN_FILE"
  quick_refresh_disable
  _tunnel_update_state fixed "$id" "$domain" "$address"
  write_tunnel_unit fixed "$id"
  if [[ "$SBM_SKIP_INIT" != 1 ]]; then tunnel_start_enabled || die 'cloudflared 未能启动。'; fi
  log_ok '固定 Tunnel 服务已启动。'
  printf '\n请在 Cloudflare Tunnel 控制台配置 Published application：\n'
  printf '  Hostname    : %s\n' "$domain"
  printf '  Service URL : http://127.0.0.1:%s\n' "$port"
}
tunnel_setup_fixed() { with_state_transaction tunnel-fixed _tunnel_setup_fixed "$@"; }

_tunnel_setup_quick() {
  local id=$1 domain='' i
  cloudflared_require
  require_vmess_node "$id" >/dev/null
  _tunnel_update_state quick "$id" '' ''
  write_tunnel_unit quick "$id"
  write_quick_refresh_schedule
  if [[ "$SBM_SKIP_INIT" != 1 ]]; then
    tunnel_start_enabled || die 'Quick Tunnel 未能启动。'
    if [[ $(init_system) == systemd ]]; then
      systemctl enable "$SBM_QUICK_REFRESH_TIMER" >/dev/null
      systemctl restart "$SBM_QUICK_REFRESH_TIMER"
    fi
    for ((i=0; i<30; i++)); do
      domain=$(tunnel_extract_domain || true)
      [[ -n "$domain" ]] && break
      sleep 1
    done
    if [[ -n "$domain" ]]; then
      _tunnel_update_state quick "$id" "$domain" "$domain"
      log_ok "Quick Tunnel：$domain"
    else
      log_warn '尚未从日志中取得 trycloudflare.com 域名；运行 sb tunnel refresh。'
    fi
  fi
}
tunnel_setup_quick() { with_state_transaction tunnel-quick _tunnel_setup_quick "$@"; }

_tunnel_refresh_quick() {
  local mode id domain
  mode=$(jq -r '.tunnel.mode' "$SBM_STATE"); [[ "$mode" == quick ]] || die '当前不是 Quick Tunnel。'
  id=$(jq -r '.tunnel.node_id' "$SBM_STATE")
  domain=$(tunnel_extract_domain || true)
  [[ -n "$domain" ]] || die 'cloudflared 日志中未找到 Quick Tunnel 域名。'
  _tunnel_update_state quick "$id" "$domain" "$domain"
  log_ok "已刷新 Quick Tunnel 域名：$domain"
}
tunnel_refresh_quick() { with_state_transaction tunnel-refresh _tunnel_refresh_quick; }

_tunnel_refresh_auto() {
  [[ $(jq -r '.tunnel.mode' "$SBM_STATE") == quick ]] || return 0
  local id domain current
  id=$(jq -r '.tunnel.node_id // ""' "$SBM_STATE"); [[ -n "$id" ]] || return 0
  domain=$(tunnel_extract_domain || true)
  [[ -n "$domain" ]] || { log_warn 'Quick Tunnel 域名尚未出现在日志中。'; return 0; }
  current=$(jq -r '.tunnel.domain // ""' "$SBM_STATE")
  [[ "$current" == "$domain" ]] || _tunnel_update_state quick "$id" "$domain" "$domain"
}
tunnel_refresh_auto() { with_lock _tunnel_refresh_auto; }

_tunnel_stop() {
  local candidate
  if [[ "$SBM_SKIP_INIT" != 1 ]]; then
    service_disable "$SBM_TUNNEL_SERVICE"
    service_stop "$SBM_TUNNEL_SERVICE"
    if [[ $(init_system) == systemd ]]; then systemctl disable --now "$SBM_QUICK_REFRESH_TIMER" >/dev/null 2>&1 || true; fi
  fi
  rm -f \
    "$SBM_SYSTEMD_DIR/$SBM_TUNNEL_SERVICE" \
    "$SBM_SYSTEMD_DIR/$SBM_QUICK_REFRESH_SERVICE" \
    "$SBM_SYSTEMD_DIR/$SBM_QUICK_REFRESH_TIMER" \
    "$SBM_OPENRC_DIR/$(service_native_name "$SBM_TUNNEL_SERVICE")" \
    "$SBM_QUICK_REFRESH_PERIODIC"
  service_reload_manager || true
  candidate=$(state_candidate)
  jq '
    . as $root |
    if .tunnel.mode=="quick" and .tunnel.node_id!=null then
      (.tunnel.node_id) as $id |
      (.nodes[]|select(.id==$id)|.domain)="" |
      (.nodes[]|select(.id==$id)|.client_address)=""
    else . end |
    .tunnel={mode:"none",node_id:null,domain:null,client_address:null,protocol:"http2"}
  ' "$SBM_STATE" >"$candidate"
  if ! apply_candidate_state "$candidate" tunnel-stop; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  log_ok 'Cloudflare Tunnel 已停止；节点本身仍保留。'
}
tunnel_stop() { with_state_transaction tunnel-stop _tunnel_stop; }

_tunnel_set_token() {
  local token=${1:-} tmp
  [[ $(jq -r '.tunnel.mode' "$SBM_STATE") == fixed ]] || die '当前不是固定 Tunnel。'
  [[ -n "$token" ]] || prompt_secret token '新的 Cloudflare Tunnel Token'
  [[ -n "$token" ]] || die 'Token 不能为空。'
  tmp=$(mktemp "$SBM_SECRETS/.cloudflared-token.XXXXXX")
  printf '%s\n' "$token" >"$tmp"
  chmod 0640 "$tmp"
  set_group_if_exists "$SBM_SERVICE_USER" "$tmp"
  mv "$tmp" "$SBM_TUNNEL_TOKEN_FILE"
  service_try_restart "$SBM_TUNNEL_SERVICE"
  log_ok 'Tunnel Token 已更换。'
}
tunnel_set_token() { with_state_transaction tunnel-token _tunnel_set_token "$@"; }

tunnel_reconcile_after_rollback() {
  local mode
  [[ "$SBM_SKIP_INIT" == 1 ]] && return 0
  mode=$(jq -r '.tunnel.mode // "none"' "$SBM_STATE")
  if [[ "$mode" == none ]]; then
    if [[ "$SBM_SKIP_INIT" != 1 ]]; then
      service_disable "$SBM_TUNNEL_SERVICE"
      service_stop "$SBM_TUNNEL_SERVICE"
    fi
    quick_refresh_disable
    rm -f "$SBM_SYSTEMD_DIR/$SBM_TUNNEL_SERVICE" "$SBM_OPENRC_DIR/$(service_native_name "$SBM_TUNNEL_SERVICE")"
    service_reload_manager || true
  else
    tunnel_reconcile 1
  fi
}

tunnel_reconcile() {
  local start=${1:-1} mode id
  mode=$(jq -r '.tunnel.mode // "none"' "$SBM_STATE")
  id=$(jq -r '.tunnel.node_id // ""' "$SBM_STATE")
  case "$mode" in
    none) return 0 ;;
    fixed)
      [[ -x "$SBM_CLOUDFLARED_BIN" ]] || { log_warn 'Cloudflare Tunnel 已配置，但 cloudflared 尚未安装；运行 sb cloudflared install。'; return 1; }
      [[ -n "$id" ]] || { log_warn '固定 Tunnel 状态缺少节点 ID。'; return 1; }
      [[ -s "$SBM_TUNNEL_TOKEN_FILE" ]] || { log_warn '固定 Tunnel Token 文件缺失，未启动 Tunnel。'; return 1; }
      quick_refresh_disable
      write_tunnel_unit fixed "$id"
      ;;
    quick)
      [[ -x "$SBM_CLOUDFLARED_BIN" ]] || { log_warn 'Quick Tunnel 已配置，但 cloudflared 尚未安装；运行 sb cloudflared install。'; return 1; }
      [[ -n "$id" ]] || { log_warn 'Quick Tunnel 状态缺少节点 ID。'; return 1; }
      write_tunnel_unit quick "$id"
      write_quick_refresh_schedule
      ;;
    *) log_warn "未知 Tunnel 模式：$mode"; return 1 ;;
  esac
  [[ "$SBM_SKIP_INIT" == 1 ]] && return 0
  service_reload_manager
  if [[ "$start" == 1 ]]; then
    tunnel_start_enabled
    if [[ "$mode" == quick && $(init_system) == systemd ]]; then
      systemctl enable "$SBM_QUICK_REFRESH_TIMER" >/dev/null
      systemctl restart "$SBM_QUICK_REFRESH_TIMER"
    fi
  fi
}

tunnel_status() {
  local json=${1:-0}
  if [[ "$json" == 1 ]]; then
    local state='off'
    if [[ $(jq -r '.tunnel.mode' "$SBM_STATE") != none ]]; then
      if [[ "$SBM_SKIP_INIT" == 1 ]]; then state=test; elif service_active "$SBM_TUNNEL_SERVICE"; then state=running; else state=stopped; fi
    fi
    jq --arg state "$state" '.tunnel + {service_state:$state}' "$SBM_STATE"
    return
  fi
  printf '模式：%s\n节点：%s\n域名：%s\n客户端地址：%s\n' \
    "$(jq -r '.tunnel.mode' "$SBM_STATE")" "$(jq -r '.tunnel.node_id // "-"' "$SBM_STATE")" \
    "$(jq -r '.tunnel.domain // "-"' "$SBM_STATE")" "$(jq -r '.tunnel.client_address // "-"' "$SBM_STATE")"
  if [[ "$SBM_SKIP_INIT" != 1 ]] && service_exists "$SBM_TUNNEL_SERVICE"; then service_status_text "$SBM_TUNNEL_SERVICE" || true; fi
}
