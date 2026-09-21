#!/usr/bin/env bash
# shellcheck shell=bash

SBM_TUNNEL_CREDENTIALS="${SBM_TUNNEL_CREDENTIALS:-$SBM_SECRETS/cloudflared-credentials.json}"
SBM_TUNNEL_INGRESS="${SBM_TUNNEL_INGRESS:-$SBM_ETC/cloudflared-ingress.json}"

tunnel_routes_validate() {
  local state=$1 row host service path
  [[ $(jq -r '.tunnel.mode' "$state") == managed ]] || return 0
  jq -e '.tunnel | (.tunnel_id|type=="string" and test("^[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$")) and
    (.routes|type=="array" and length<=128) and
    ((.routes|map(.id)|unique|length)==(.routes|length)) and
    ((.routes|map([.hostname,.path])|unique|length)==(.routes|length)) and
    all(.routes[]; (.id|type=="string" and test("^[a-z0-9][a-z0-9._-]{0,47}$")) and
      (.hostname|type=="string") and (.service|type=="string") and
      (.path|type=="string" and length<=512 and (test("[[:cntrl:]]")|not)))' "$state" >/dev/null || {
    log_error 'Tunnel 路由结构无效或存在重复规则。'; return 1;
  }
  while IFS= read -r row; do
    host=$(jq -r '.hostname' <<<"$row"); service=$(jq -r '.service' <<<"$row"); path=$(jq -r '.path' <<<"$row")
    validate_domain "$host" || { log_error "无效 Tunnel 域名：$host"; return 1; }
    [[ "$service" =~ ^https?://(127\.0\.0\.1|localhost|\[::1\]):([1-9][0-9]{0,4})$ ]] && validate_port "${BASH_REMATCH[2]:-0}" || {
      log_error '回源地址必须为 http(s)://127.0.0.1:端口、localhost:端口或 [::1]:端口。'; return 1;
    }
    [[ -z "$path" || "$path" == /* || "$path" == ^/* ]] || { log_error '路径规则须以 / 或 ^/ 开头。'; return 1; }
  done < <(jq -c '.tunnel.routes[]' "$state")
}

tunnel_routes_render() {
  local state=$1
  jq --arg credentials "$SBM_TUNNEL_CREDENTIALS" '.tunnel |
    {tunnel:.tunnel_id,"credentials-file":$credentials,protocol:"http2",
     ingress:([.routes[]|{hostname,service}+(if .path=="" then {} else {path} end)]+[{service:"http_status:404"}])}' "$state"
}

write_managed_tunnel_unit() {
  local tmp backend unit
  cloudflared_require || return 1
  tunnel_routes_validate "$SBM_STATE" || return 1
  [[ -f "$SBM_TUNNEL_CREDENTIALS" ]] || { log_error 'Tunnel 凭据文件缺失。'; return 1; }
  jq -e --arg id "$(jq -r '.tunnel.tunnel_id' "$SBM_STATE")" \
    '.TunnelID==$id and (.TunnelSecret|type=="string" and length>0)' "$SBM_TUNNEL_CREDENTIALS" >/dev/null || return 1
  chmod 0640 "$SBM_TUNNEL_CREDENTIALS" && set_group_if_exists "$SBM_SERVICE_USER" "$SBM_TUNNEL_CREDENTIALS" || return 1
  tmp=$(mktemp "$SBM_ETC/.tunnel-ingress.XXXXXX") || return 1
  if ! tunnel_routes_render "$SBM_STATE" >"$tmp" || ! "$SBM_CLOUDFLARED_BIN" tunnel --config "$tmp" ingress validate >"$SBM_RUN/tunnel-ingress-check.log" 2>&1; then
    rm -f "$tmp"; log_error "Tunnel ingress 校验失败，详见 $SBM_RUN/tunnel-ingress-check.log"; return 1
  fi
  chmod 0640 "$tmp" || return 1
  set_group_if_exists "$SBM_SERVICE_USER" "$tmp" || return 1
  mv "$tmp" "$SBM_TUNNEL_INGRESS" || return 1
  backend=$(effective_init_system)
  mkdir -p "$SBM_VAR/cloudflared-home" "$SBM_LOG_DIR" || return 1
  if id "$SBM_SERVICE_USER" >/dev/null 2>&1; then chown "$SBM_SERVICE_USER:$SBM_SERVICE_USER" "$SBM_VAR/cloudflared-home" || return 1; fi
  if [[ "$backend" == systemd ]]; then
    unit="$SBM_SYSTEMD_DIR/$SBM_TUNNEL_SERVICE"
    mkdir -p "$SBM_SYSTEMD_DIR" || return 1
    cat >"$unit" <<EOF_UNIT
[Unit]
Description=sb-manager multi-service Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
User=$SBM_SERVICE_USER
Group=$SBM_SERVICE_USER
Environment=HOME=$SBM_VAR/cloudflared-home
ExecStart=$SBM_CLOUDFLARED_BIN tunnel --config $SBM_TUNNEL_INGRESS --no-autoupdate run
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=$SBM_VAR/cloudflared-home
UMask=0027

[Install]
WantedBy=multi-user.target
EOF_UNIT
    chmod 0644 "$unit"
  else
    mkdir -p "$SBM_OPENRC_DIR" || return 1
    write_openrc_supervised_service "$SBM_OPENRC_DIR/${SBM_TUNNEL_SERVICE%.service}" \
      'sb-manager Tunnel routes' 'sb-manager multi-service Cloudflare Tunnel' "$SBM_CLOUDFLARED_BIN" \
      "tunnel --config $SBM_TUNNEL_INGRESS --no-autoupdate run" "$SBM_SERVICE_USER" \
      "$SBM_TUNNEL_LOG" "$SBM_TUNNEL_ERROR_LOG" 'after firewall' '' "$SBM_VAR/cloudflared-home"
  fi
}

_tunnel_managed_setup() {
  local id=$1 credentials=$2 candidate tmp
  [[ "$id" =~ ^[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$ ]] || usage_die 'Tunnel UUID 无效。'
  [[ -f "$credentials" ]] && jq -e --arg id "$id" '.TunnelID==$id and (.AccountTag|type=="string" and length>0) and (.TunnelSecret|type=="string" and length>0)' "$credentials" >/dev/null || usage_die '凭据文件无效或 TunnelID 不匹配。'
  cloudflared_require || return 1
  tmp=$(mktemp "$SBM_SECRETS/.tunnel-credentials.XXXXXX") || return 1
  jq '{AccountTag,TunnelID,TunnelSecret}' "$credentials" >"$tmp" || return 1
  chmod 0640 "$tmp" && set_group_if_exists "$SBM_SERVICE_USER" "$tmp" && mv "$tmp" "$SBM_TUNNEL_CREDENTIALS" || return 1
  candidate=$(state_candidate) || return 1
  jq --arg id "$id" '.tunnel={mode:"managed",node_id:null,domain:null,client_address:null,protocol:"http2",tunnel_id:$id,routes:[]}' "$SBM_STATE" >"$candidate" || return 1
  if ! apply_candidate_state "$candidate" tunnel-managed; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  quick_refresh_disable
  tunnel_reconcile 1 || return 1
  log_ok '本地托管 Tunnel 已启用；添加路由后，将对应域名的 CNAME 指向 Tunnel UUID.cfargotunnel.com。'
}

_tunnel_route_edit() {
  local action=$1 id=$2 host=${3:-} service=${4:-} path=${5:-} candidate
  [[ $(jq -r '.tunnel.mode' "$SBM_STATE") == managed ]] || usage_die '请先配置 sb tunnel managed UUID CREDENTIALS_JSON。'
  validate_node_id "$id" || usage_die '路由 ID 无效。'
  candidate=$(state_candidate) || return 1
  if [[ "$action" == add ]]; then
    jq --arg id "$id" --arg host "$host" --arg service "$service" --arg path "$path" '
      .tunnel.routes=(.tunnel.routes|map(select(.id!=$id)))+[{id:$id,hostname:$host,service:$service,path:$path}]
      | .tunnel.routes |= sort_by(if .path=="" then 1 else 0 end)' "$SBM_STATE" >"$candidate" || return 1
  else
    jq -e --arg id "$id" 'any(.tunnel.routes[]; .id==$id)' "$SBM_STATE" >/dev/null || usage_die '路由不存在。'
    jq --arg id "$id" '.tunnel.routes |= map(select(.id!=$id))' "$SBM_STATE" >"$candidate" || return 1
  fi
  tunnel_routes_validate "$candidate" || { rm -f "$candidate"; return 1; }
  if ! apply_candidate_state "$candidate" "tunnel-route-$action"; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  tunnel_reconcile 1
}

tunnel_routes_cli() {
  [[ ${SBM_DRY_RUN:-0} == 0 ]] || usage_die 'Tunnel 路由操作暂不接受 --dry-run。'
  case "${1:-}" in
    managed) [[ $# == 3 ]] || usage_die '用法：sb tunnel managed UUID CREDENTIALS_JSON'; with_state_transaction tunnel-managed _tunnel_managed_setup "$2" "$3";;
    route)
      case "${2:-list}" in
        list) [[ $# -le 3 && ${3:---json} == --json ]] || usage_die '用法：sb tunnel route list [--json]'; jq '.tunnel.routes // []' "$SBM_STATE";;
        add) [[ $# == 5 || $# == 6 ]] || usage_die '用法：sb tunnel route add ID DOMAIN LOCAL_URL [PATH_REGEX]'; with_state_transaction tunnel-route _tunnel_route_edit add "$3" "$4" "$5" "${6:-}";;
        remove) [[ $# == 3 ]] || usage_die '用法：sb tunnel route remove ID'; with_state_transaction tunnel-route _tunnel_route_edit remove "$3";;
        *) usage_die '用法：sb tunnel route list|add|remove';;
      esac;;
    *) return 2;;
  esac
}
