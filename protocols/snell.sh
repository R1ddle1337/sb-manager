#!/usr/bin/env bash
# shellcheck shell=bash

# sing-box 1.14+ uses Snell v5 on the server and Snell v4 on clients.  The
# wire protocol is compatible; v5 is the server-side version that exposes the
# optional HTTP obfuscation setting.
protocol_snell_render() {
  local node=$1 credentials=$2 node_secret=${3:-'{}'} obfs_mode base
  obfs_mode=$(jq -r '.obfs_mode // "none"' <<<"$node")
  base=$(jq -n \
    --arg tag "in-$(jq -r '.id' <<<"$node")" \
    --arg listen "$(jq -r '.listen // "::"' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" \
    --arg psk "$(jq -r '.psk' <<<"$node_secret")" \
    --argjson users "$(jq '[.[] | {name,userkey}]' <<<"$credentials")" \
    --arg obfs_mode "$obfs_mode" \
    '{type:"snell",tag:$tag,listen:$listen,listen_port:$port,version:5,psk:$psk,users:$users,obfs_mode:$obfs_mode}')
  printf '%s\n' "$base"
}

protocol_snell_share() {
  local node=$1 secret=$2 node_secret=${3:-'{}'} address port psk userkey name hp uri obfs_mode obfs_host
  address=$(jq -r '.server_address // ""' <<<"$node")
  port=$(jq -r '.port' <<<"$node")
  psk=$(jq -r '.psk' <<<"$node_secret")
  userkey=$(jq -r '.userkey' <<<"$secret")
  name=$(jq -r '.name' <<<"$node")
  [[ -n "$address" ]] || { log_warn "节点 $(jq -r '.id' <<<"$node") 尚未配置服务器地址。"; return 1; }
  hp=$(format_hostport "$address" "$port")
  uri="snell://$(urlencode "$psk")@${hp}?version=4&userkey=$(urlencode "$userkey")"
  obfs_mode=$(jq -r '.obfs_mode // "none"' <<<"$node")
  if [[ "$obfs_mode" == http ]]; then
    obfs_host=$(jq -r '.obfs_host // "bing.com"' <<<"$node")
    uri+="&obfs=http&obfs-host=$(urlencode "$obfs_host")"
  fi
  printf '%s#%s\n' "$uri" "$(urlencode "$name")"
}

protocol_snell_client_outbound() {
  local node=$1 secret=$2 node_secret=${3:-'{}'} base obfs_mode obfs_host
  obfs_mode=$(jq -r '.obfs_mode // "none"' <<<"$node")
  obfs_host=$(jq -r '.obfs_host // "bing.com"' <<<"$node")
  base=$(jq -n \
    --arg tag "proxy-$(jq -r '.id' <<<"$node")" \
    --arg server "$(jq -r '.server_address // ""' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" \
    --arg psk "$(jq -r '.psk' <<<"$node_secret")" \
    --arg userkey "$(jq -r '.userkey' <<<"$secret")" \
    --arg obfs_mode "$obfs_mode" \
    '{type:"snell",tag:$tag,server:$server,server_port:$port,version:4,psk:$psk,userkey:$userkey,reuse:false,network:"tcp",obfs_mode:$obfs_mode}')
  if [[ "$obfs_mode" == http ]]; then
    jq --arg host "$obfs_host" '. + {obfs_host:$host}' <<<"$base"
  else
    printf '%s\n' "$base"
  fi
}
