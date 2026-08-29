#!/usr/bin/env bash
# shellcheck shell=bash

template_validate_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9._-]{0,47}$ ]]; }

node_template_safe_defaults() {
  local node=$1
  jq '{name,protocol,domain:(.domain // ""),server_address:(.server_address // ""),client_address:(.client_address // ""),
      port,listen,network:(.network // ""),method:(.method // ""),multiplex:(.multiplex // true),ws_path:(.ws_path // ""),
      obfs:(.obfs.type // ""),obfs_host:(.obfs_host // ""),masquerade:(.masquerade // ""),security:(.security // ""),flow:(.flow // ""),
      handshake_server:(.handshake_server // ""),handshake_port:(.handshake_port // 443),congestion_control:(.congestion_control // .quic_congestion_control // "cubic"),
      strict_mode:(.strict_mode // true),wildcard_sni:(.wildcard_sni // "off"),obfs_mode:(.obfs_mode // "none"),
      metadata:(.metadata // {remark:"",region:"",purpose:"",line:"",tags:[]})}' <<<"$node"
}

_node_template_save() {
  local name=$1 node_id=$2 node defaults candidate
  template_validate_name "$name" || die '模板名称只能包含小写字母、数字、点、下划线和连字符。'
  node=$(state_get_node "$node_id"); [[ -n "$node" ]] || die "节点不存在：$node_id"
  jq -e --arg name "$name" '.node_templates[]? | select(.name==$name)' "$SBM_STATE" >/dev/null && die "模板已存在：$name"
  defaults=$(node_template_safe_defaults "$node")
  candidate=$(state_candidate)
  jq --arg name "$name" --argjson defaults "$defaults" --arg now "$(now_iso)" \
    '.node_templates += [{name:$name,protocol:$defaults.protocol,defaults:$defaults,created_at:$now}]' "$SBM_STATE" >"$candidate"
  if ! apply_candidate_state "$candidate" "template-save-$name"; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  log_ok "已保存节点模板：$name（来源节点：$node_id）"
}
node_template_save() { with_state_transaction template-save _node_template_save "$@"; }

node_template_list() {
  local json=${1:-0}
  if [[ "$json" == 1 ]]; then jq '.node_templates' "$SBM_STATE"; else
    printf '%-20s %-18s %s\n' '模板' '协议' '默认端口'
    jq -r '.node_templates[]? | [.name,.protocol,(.defaults.port|tostring)] | @tsv' "$SBM_STATE" |
      while IFS=$'\t' read -r name protocol port; do printf '%-20s %-18s %s\n' "$name" "$(node_protocol_label "$protocol")" "$port"; done
  fi
}

_node_template_delete() {
  local name=$1 candidate
  template_validate_name "$name" || die '无效模板名称。'
  jq -e --arg name "$name" '.node_templates[]? | select(.name==$name)' "$SBM_STATE" >/dev/null || die "模板不存在：$name"
  candidate=$(state_candidate)
  jq --arg name "$name" '.node_templates |= map(select(.name!=$name))' "$SBM_STATE" >"$candidate"
  if ! apply_candidate_state "$candidate" "template-delete-$name"; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  log_ok "已删除节点模板：$name"
}
node_template_delete() { with_state_transaction template-delete _node_template_delete "$@"; }

node_template_get() { jq -c --arg name "$1" '.node_templates[]? | select(.name==$name)' "$SBM_STATE"; }

node_template_add() {
  local name=$1 id=$2 template defaults protocol value address domain port node_name disabled=0
  shift 2
  template=$(node_template_get "$name"); [[ -n "$template" ]] || die "模板不存在：$name"
  defaults=$(jq -c '.defaults' <<<"$template"); protocol=$(jq -r '.protocol' <<<"$template")
  node_name=$(jq -r '.name // ""' <<<"$defaults"); node_name=${node_name:-$id}
  address=$(jq -r '(.server_address // .client_address // "")' <<<"$defaults"); domain=$(jq -r '.domain // ""' <<<"$defaults"); port=$(jq -r '.port' <<<"$defaults")
  local remark region purpose line tags
  remark=$(jq -r '.metadata.remark // ""' <<<"$defaults"); region=$(jq -r '.metadata.region // ""' <<<"$defaults"); purpose=$(jq -r '.metadata.purpose // ""' <<<"$defaults"); line=$(jq -r '.metadata.line // ""' <<<"$defaults"); tags=$(jq -r '.metadata.tags|join(",")' <<<"$defaults")
  local -a args=("$protocol" --id "$id" --name "$node_name" --port "$port")
  [[ -n "$address" ]] && args+=(--address "$address")
  [[ -n "$domain" ]] && args+=(--domain "$domain")
  case "$protocol" in
    vmess-ws-cf) [[ -n $(jq -r '.ws_path // ""' <<<"$defaults") ]] && args+=(--path "$(jq -r '.ws_path' <<<"$defaults")");;
    shadowsocks) args+=(--method "$(jq -r '.method' <<<"$defaults")" --network "$(jq -r '.network' <<<"$defaults")"); [[ $(jq -r '.multiplex' <<<"$defaults") == true ]] || args+=(--no-mux);;
    hysteria2) [[ -n $(jq -r '.obfs // ""' <<<"$defaults") ]] && args+=(--obfs "$(jq -r '.obfs' <<<"$defaults")"); [[ -n $(jq -r '.masquerade // ""' <<<"$defaults") ]] && args+=(--masquerade "$(jq -r '.masquerade' <<<"$defaults")");;
    vless) args+=(--security "$(jq -r '.security' <<<"$defaults")" --handshake-server "$(jq -r '.handshake_server' <<<"$defaults")" --handshake-port "$(jq -r '.handshake_port' <<<"$defaults")");;
    naive) args+=(--network "$(jq -r '.network' <<<"$defaults")");;
    shadowtls) args+=(--handshake-server "$(jq -r '.handshake_server' <<<"$defaults")" --handshake-port "$(jq -r '.handshake_port' <<<"$defaults")" --strict-mode "$(jq -r '.strict_mode' <<<"$defaults")" --wildcard-sni "$(jq -r '.wildcard_sni' <<<"$defaults")");;
    snell) args+=(--obfs "$(jq -r '.obfs_mode' <<<"$defaults")" --obfs-host "$(jq -r '.obfs_host' <<<"$defaults")");;
    tuic) args+=(--congestion-control "$(jq -r '.congestion_control' <<<"$defaults")");;
  esac
  while (($#)); do
    case "$1" in
      --name|--port|--address|--domain|--remark|--region|--purpose|--line|--tags)
        value=${2:?缺少参数值}; case "$1" in --name) node_name=$value;; --port) port=$value;; --address) address=$value;; --domain) domain=$value;; --remark) remark=$value;; --region) region=$value;; --purpose) purpose=$value;; --line) line=$value;; --tags) tags=$value;; esac; shift 2;;
      --disabled) disabled=1; shift;; *) die "模板创建不支持参数：$1";;
    esac
  done
  # Rebuild common overrides after parsing so no user value is silently lost.
  args=("$protocol" --id "$id" --name "$node_name" --port "$port")
  [[ -n "$address" ]] && args+=(--address "$address"); [[ -n "$domain" ]] && args+=(--domain "$domain")
  case "$protocol" in
    vmess-ws-cf) args+=(--path "$(jq -r '.ws_path' <<<"$defaults")");; shadowsocks) args+=(--method "$(jq -r '.method' <<<"$defaults")" --network "$(jq -r '.network' <<<"$defaults")"); [[ $(jq -r '.multiplex' <<<"$defaults") == true ]] || args+=(--no-mux);;
    hysteria2) [[ -n $(jq -r '.obfs' <<<"$defaults") ]] && args+=(--obfs "$(jq -r '.obfs' <<<"$defaults")"); [[ -n $(jq -r '.masquerade' <<<"$defaults") ]] && args+=(--masquerade "$(jq -r '.masquerade' <<<"$defaults")");;
    vless) args+=(--security "$(jq -r '.security' <<<"$defaults")"); [[ -n $(jq -r '.flow // ""' <<<"$defaults") ]] && args+=(--flow "$(jq -r '.flow' <<<"$defaults")"); [[ $(jq -r '.security' <<<"$defaults") != reality ]] || args+=(--handshake-server "$(jq -r '.handshake_server' <<<"$defaults")" --handshake-port "$(jq -r '.handshake_port' <<<"$defaults")");;
    naive) args+=(--network "$(jq -r '.network' <<<"$defaults")" --congestion-control "$(jq -r '.congestion_control' <<<"$defaults")");; shadowtls) args+=(--handshake-server "$(jq -r '.handshake_server' <<<"$defaults")" --handshake-port "$(jq -r '.handshake_port' <<<"$defaults")" --strict-mode "$(jq -r '.strict_mode' <<<"$defaults")" --wildcard-sni "$(jq -r '.wildcard_sni' <<<"$defaults")");; snell) args+=(--obfs "$(jq -r '.obfs_mode' <<<"$defaults")" --obfs-host "$(jq -r '.obfs_host' <<<"$defaults")");; tuic) args+=(--congestion-control "$(jq -r '.congestion_control' <<<"$defaults")");;
  esac
  args+=(--remark "$remark" --region "$region" --purpose "$purpose" --line "$line" --tags "$tags")
  (( disabled == 0 )) || args+=(--disabled)
  node_add "${args[@]}"
}
