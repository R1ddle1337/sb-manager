#!/usr/bin/env bash
# shellcheck shell=bash

node_transport_kinds() {
  local node=$1 protocol network
  protocol=$(jq -r '.protocol' <<<"$node")
  case "$protocol" in
    vmess-ws-cf|anytls|trojan|vless|shadowtls) printf 'tcp\n' ;;
    hysteria2|tuic) printf 'udp\n' ;;
    naive) jq -r '.network // "tcp"' <<<"$node" ;;
    shadowsocks)
      network=$(jq -r '.network // "tcp"' <<<"$node")
      case "$network" in tcp) printf 'tcp\n';; udp) printf 'udp\n';; *) printf 'tcp\nudp\n';; esac
      ;;
    *) return 1 ;;
  esac
}

validate_state_semantics() {
  local state=$1 ids count node id protocol port domain cert_dir kind key user_ids user_id enabled_users
  state_validate "$state"
  ids=$(jq -r '.nodes[].id' "$state" | sort)
  count=$(printf '%s\n' "$ids" | sed '/^$/d' | uniq -d | wc -l)
  (( count == 0 )) || die "状态中存在重复节点 ID。"
  if [[ $(jq -r '.api.enabled // false' "$state") == true ]]; then
    version_ge "$(core_current_version)" 1.14.0-rc.1 || die 'sing-box API/Dashboard 需要 1.14+ 核心。'
    [[ -r "$(state_secret_path api)" ]] || die 'API secret 文件缺失。'
  fi

  declare -A occupied=()
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    id=$(jq -r '.id' <<<"$node")
    protocol=$(jq -r '.protocol' <<<"$node")
    port=$(jq -r '.port' <<<"$node")
    validate_node_id "$id" || die "节点 ID 不规范：$id"
    validate_port "$port" || die "节点 $id 的端口无效：$port"
    case "$protocol" in vmess-ws-cf|shadowsocks|anytls|hysteria2|trojan|tuic|vless|naive|shadowtls) ;; *) die "节点 $id 使用未知协议：$protocol" ;; esac
    user_ids=$(jq -r '.users[].id' <<<"$node" | sort)
    count=$(printf '%s\n' "$user_ids" | sed '/^$/d' | uniq -d | wc -l)
    (( count == 0 )) || die "节点 $id 存在重复用户 ID。"
    if [[ $(jq -r '.enabled' <<<"$node") == true ]]; then
      enabled_users=$(jq '[.users[] | select(.enabled==true)] | length' <<<"$node")
      (( enabled_users > 0 )) || die "启用节点 $id 至少需要一个启用用户。"
      while IFS= read -r kind; do
        key="$kind:$port"
        [[ -z ${occupied[$key]+x} ]] || die "端口冲突：$id 与 ${occupied[$key]} 同时占用 ${port}/${kind^^}。"
        occupied[$key]=$id
      done < <(node_transport_kinds "$node")
      if [[ "$protocol" == anytls || "$protocol" == hysteria2 || "$protocol" == trojan || "$protocol" == tuic || "$protocol" == naive || ("$protocol" == vless && $(jq -r '.security' <<<"$node") == tls) ]]; then
        domain=$(jq -r '.domain // ""' <<<"$node")
        validate_domain "$domain" || die "节点 $id 的 TLS 域名无效：$domain"
        cert_dir="$SBM_CERTS/$domain"
        [[ -s "$cert_dir/fullchain.pem" && -s "$cert_dir/key.pem" ]] || die "节点 $id 缺少证书：$cert_dir/{fullchain.pem,key.pem}"
      fi
      while IFS= read -r user_id; do
        [[ -r "$(state_user_secret_path "$id" "$user_id")" ]] || die "节点 $id 的用户 $user_id 缺少密钥文件。"
      done < <(jq -r '.users[] | select(.enabled==true) | .id' <<<"$node")
      if [[ "$protocol" == hysteria2 || ("$protocol" == vless && $(jq -r '.security' <<<"$node") == reality) ]]; then
        [[ -r "$(state_secret_path "$id")" ]] || die "节点 $id 缺少协议级密钥文件。"
      fi
    fi
  done < <(jq -c '.nodes[]?' "$state")
}

node_enabled_credentials() {
  local node=$1 node_id user user_id secret credentials='[]'
  node_id=$(jq -r '.id' <<<"$node")
  while IFS= read -r user; do
    user_id=$(jq -r '.id' <<<"$user")
    secret=$(state_get_user_secret "$node_id" "$user_id")
    credentials=$(jq -c --argjson user "$user" --argjson secret "$secret" '. + [$user + $secret]' <<<"$credentials")
  done < <(jq -c '.users[] | select(.enabled==true)' <<<"$node")
  printf '%s\n' "$credentials"
}

render_inbound_for_node() {
  local node=$1 credentials=$2 node_secret=${3:-'{}'} protocol
  protocol=$(jq -r '.protocol' <<<"$node")
  case "$protocol" in
    vmess-ws-cf) protocol_vmess_render "$node" "$credentials" "$node_secret" ;;
    shadowsocks) protocol_ss_render "$node" "$credentials" "$node_secret" ;;
    anytls) protocol_anytls_render "$node" "$credentials" "$node_secret" ;;
    hysteria2) protocol_hy2_render "$node" "$credentials" "$node_secret" ;;
    trojan) protocol_trojan_render "$node" "$credentials" ;;
    tuic) protocol_tuic_render "$node" "$credentials" ;;
    vless) protocol_vless_render "$node" "$credentials" "$node_secret" ;;
    naive) protocol_naive_render "$node" "$credentials" ;;
    shadowtls) protocol_shadowtls_render "$node" "$credentials" ;;
    *) die "未知协议：$protocol" ;;
  esac
}

render_config_from_state() {
  local state=$1 output=$2 node node_id credentials node_secret inbound inbounds='[]' log_level api_enabled api_secret api_port dashboard
  validate_state_semantics "$state"
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    node_id=$(jq -r '.id' <<<"$node")
    credentials=$(node_enabled_credentials "$node")
    node_secret='{}'
    [[ ! -r $(state_secret_path "$node_id") ]] || node_secret=$(state_get_secret "$node_id")
    inbound=$(render_inbound_for_node "$node" "$credentials" "$node_secret")
    inbounds=$(jq -c --argjson x "$inbound" '. + [$x]' <<<"$inbounds")
  done < <(jq -c '.nodes[]? | select(.enabled==true)' "$state")
  log_level=$(jq -r '.settings.log_level // "info"' "$state")
  api_enabled=$(jq -r '.api.enabled // false' "$state")
  api_secret=''; api_port=$(jq -r '.api.port // 9090' "$state"); dashboard=$(jq -r '.api.dashboard // false' "$state")
  [[ "$api_enabled" != true ]] || api_secret=$(state_get_secret api | jq -r '.secret')
  jq -n --arg level "$log_level" --argjson inbounds "$inbounds" --argjson api_enabled "$api_enabled" \
    --arg secret "$api_secret" --argjson api_port "$api_port" --argjson dashboard "$dashboard" --arg dashboard_path "$SBM_VAR/dashboard" '{
    "$schema":"https://sing-box.sagernet.org/schema.json",
    log:{level:$level,timestamp:true},
    inbounds:$inbounds,
    outbounds:[{type:"direct",tag:"direct"}],
    route:{final:"direct"}
  }
  | if $api_enabled then
      .http_clients=[{tag:"http-direct",detour:"direct"}]
      | .route.default_http_client="http-direct"
      | .services=[{
          type:"api",tag:"api-local",listen:"127.0.0.1",listen_port:$api_port,secret:$secret,
          access_control_allow_origin:[("http://127.0.0.1:" + ($api_port|tostring))],
          dashboard:(if $dashboard then {enabled:true,path:$dashboard_path,http_client:"http-direct",update_interval:"1d"} else false end)
        }]
    else . end
  ' >"$output"
  jq -e . "$output" >/dev/null
}

core_validate_config_with() {
  local binary=$1 config=$2 log_file=${3:-$SBM_RUN/check.log}
  [[ -x "$binary" ]] || die "sing-box 核心不存在：$binary"
  if ! "$binary" check -c "$config" >"$log_file" 2>&1; then
    log_error "sing-box 配置检查失败："
    sed -n '1,80p' "$log_file" >&2 || true
    return 1
  fi
}

core_validate_config() { core_validate_config_with "$SBM_SING_BOX_BIN" "$1"; }

apply_candidate_state() {
  local candidate=$1 reason=${2:-change} tmp_config
  tmp_config=$(mktemp "$SBM_RUN/config.candidate.XXXXXX")
  if ! render_config_from_state "$candidate" "$tmp_config"; then rm -f "$tmp_config"; return 1; fi
  if ! core_validate_config "$tmp_config"; then rm -f "$tmp_config"; return 1; fi
  if ! state_install_candidate "$candidate" "$tmp_config" "$reason"; then rm -f "$tmp_config"; return 1; fi
  rm -f "$tmp_config"
  log_ok "配置已应用。"
}

render_current_config() {
  local tmp
  tmp=$(mktemp "$SBM_RUN/config.current.XXXXXX")
  render_config_from_state "$SBM_STATE" "$tmp"
  core_validate_config "$tmp"
  safe_install_file "$tmp" "$SBM_CONFIG" 0640
  set_group_if_exists "$SBM_SERVICE_USER" "$SBM_CONFIG"
  rm -f "$tmp"
}
