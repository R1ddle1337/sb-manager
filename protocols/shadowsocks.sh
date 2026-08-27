#!/usr/bin/env bash
# shellcheck shell=bash

protocol_ss_render() {
  local node=$1 secret=$2
  jq -n \
    --arg tag "in-$(jq -r '.id' <<<"$node")" \
    --arg listen "$(jq -r '.listen // "::"' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" \
    --arg network "$(jq -r '.network // "tcp"' <<<"$node")" \
    --arg method "$(jq -r '.method' <<<"$node")" \
    --arg password "$(jq -r '.password' <<<"$secret")" \
    --argjson mux "$(jq -r '.multiplex // true' <<<"$node")" \
    '{
      type:"shadowsocks", tag:$tag, listen:$listen, listen_port:$port,
      network:$network, method:$method, password:$password,
      multiplex:{enabled:$mux}
    }'
}

protocol_ss_share() {
  local node=$1 secret=$2 address port method password name userinfo hp
  address=$(jq -r '.server_address // ""' <<<"$node")
  port=$(jq -r '.port' <<<"$node")
  method=$(jq -r '.method' <<<"$node")
  password=$(jq -r '.password' <<<"$secret")
  name=$(jq -r '.name' <<<"$node")
  [[ -n "$address" ]] || { log_warn "节点 $(jq -r '.id' <<<"$node") 尚未配置服务器地址。"; return 1; }
  userinfo=$(printf '%s:%s' "$method" "$password" | base64url_nowrap)
  hp=$(format_hostport "$address" "$port")
  printf 'ss://%s@%s#%s\n' "$userinfo" "$hp" "$(urlencode "$name")"
}

protocol_ss_client_outbound() {
  local node=$1 secret=$2
  jq -n \
    --arg tag "proxy-$(jq -r '.id' <<<"$node")" \
    --arg server "$(jq -r '.server_address // ""' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" \
    --arg method "$(jq -r '.method' <<<"$node")" \
    --arg password "$(jq -r '.password' <<<"$secret")" \
    --argjson mux "$(jq -r '.multiplex // true' <<<"$node")" \
    '{type:"shadowsocks",tag:$tag,server:$server,server_port:$port,method:$method,password:$password,multiplex:{enabled:$mux}}'
}
