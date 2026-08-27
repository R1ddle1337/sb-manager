#!/usr/bin/env bash
# shellcheck shell=bash

node_transport_kinds() {
  local node=$1 protocol network
  protocol=$(jq -r '.protocol' <<<"$node")
  case "$protocol" in
    vmess-ws-cf|anytls) printf 'tcp\n' ;;
    hysteria2) printf 'udp\n' ;;
    shadowsocks)
      network=$(jq -r '.network // "tcp"' <<<"$node")
      case "$network" in tcp) printf 'tcp\n';; udp) printf 'udp\n';; *) printf 'tcp\nudp\n';; esac
      ;;
    *) return 1 ;;
  esac
}

validate_state_semantics() {
  local state=$1 ids count node id protocol port domain cert_dir kind key
  state_validate "$state"
  ids=$(jq -r '.nodes[].id' "$state" | sort)
  count=$(printf '%s\n' "$ids" | sed '/^$/d' | uniq -d | wc -l)
  (( count == 0 )) || die "状态中存在重复节点 ID。"

  declare -A occupied=()
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    id=$(jq -r '.id' <<<"$node")
    protocol=$(jq -r '.protocol' <<<"$node")
    port=$(jq -r '.port' <<<"$node")
    validate_node_id "$id" || die "节点 ID 不规范：$id"
    validate_port "$port" || die "节点 $id 的端口无效：$port"
    case "$protocol" in vmess-ws-cf|shadowsocks|anytls|hysteria2) ;; *) die "节点 $id 使用未知协议：$protocol" ;; esac
    if [[ $(jq -r '.enabled' <<<"$node") == true ]]; then
      while IFS= read -r kind; do
        key="$kind:$port"
        [[ -z ${occupied[$key]+x} ]] || die "端口冲突：$id 与 ${occupied[$key]} 同时占用 ${port}/${kind^^}。"
        occupied[$key]=$id
      done < <(node_transport_kinds "$node")
      if [[ "$protocol" == anytls || "$protocol" == hysteria2 ]]; then
        domain=$(jq -r '.domain // ""' <<<"$node")
        validate_domain "$domain" || die "节点 $id 的 TLS 域名无效：$domain"
        cert_dir="$SBM_CERTS/$domain"
        [[ -s "$cert_dir/fullchain.pem" && -s "$cert_dir/key.pem" ]] || die "节点 $id 缺少证书：$cert_dir/{fullchain.pem,key.pem}"
      fi
      [[ -r "$(state_secret_path "$id")" ]] || die "节点 $id 缺少密钥文件。"
    fi
  done < <(jq -c '.nodes[]?' "$state")
}

render_inbound_for_node() {
  local node=$1 secret=$2 protocol
  protocol=$(jq -r '.protocol' <<<"$node")
  case "$protocol" in
    vmess-ws-cf) protocol_vmess_render "$node" "$secret" ;;
    shadowsocks) protocol_ss_render "$node" "$secret" ;;
    anytls) protocol_anytls_render "$node" "$secret" ;;
    hysteria2) protocol_hy2_render "$node" "$secret" ;;
    *) die "未知协议：$protocol" ;;
  esac
}

render_config_from_state() {
  local state=$1 output=$2 node secret inbound inbounds='[]' log_level
  validate_state_semantics "$state"
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    secret=$(state_get_secret "$(jq -r '.id' <<<"$node")")
    inbound=$(render_inbound_for_node "$node" "$secret")
    inbounds=$(jq -c --argjson x "$inbound" '. + [$x]' <<<"$inbounds")
  done < <(jq -c '.nodes[]? | select(.enabled==true)' "$state")
  log_level=$(jq -r '.settings.log_level // "info"' "$state")
  jq -n --arg level "$log_level" --argjson inbounds "$inbounds" '{
    log:{level:$level,timestamp:true},
    inbounds:$inbounds,
    outbounds:[{type:"direct",tag:"direct"}],
    route:{final:"direct"}
  }' >"$output"
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
