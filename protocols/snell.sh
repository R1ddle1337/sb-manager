#!/usr/bin/env bash
# shellcheck shell=bash

# sing-box 1.14+ supports Snell v5 and v6. Version 5 uses HTTP obfuscation and
# exports a compatible v4 client; version 6 uses traffic shaping and exports v6.
protocol_snell_render() {
  local node=$1 credentials=$2 node_secret=${3:-'{}'} obfs_mode snell_version snell_mode base
  obfs_mode=$(jq -r '.obfs_mode // "none"' <<<"$node")
  snell_version=$(jq -r '.snell_version // 5' <<<"$node")
  snell_mode=$(jq -r '.snell_mode // "default"' <<<"$node")
  base=$(jq -n \
    --arg tag "in-$(jq -r '.id' <<<"$node")" \
    --arg listen "$(jq -r '.listen // "::"' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" \
    --arg psk "$(jq -r '.psk' <<<"$node_secret")" \
    --argjson users "$(jq '[.[] | {name,userkey}]' <<<"$credentials")" \
    --arg obfs_mode "$obfs_mode" --arg mode "$snell_mode" --argjson version "$snell_version" \
    '{type:"snell",tag:$tag,listen:$listen,listen_port:$port,version:$version,psk:$psk,users:$users}
     | if $version == 6 then . + {mode:$mode} else . + {obfs_mode:$obfs_mode} end')
  printf '%s\n' "$base"
}

protocol_snell_share() {
  local node=$1 secret=$2 node_secret=${3:-'{}'} address port psk userkey name hp uri obfs_mode obfs_host snell_version snell_mode
  address=$(jq -r '.server_address // ""' <<<"$node")
  port=$(jq -r '.port' <<<"$node")
  psk=$(jq -r '.psk' <<<"$node_secret")
  userkey=$(jq -r '.userkey' <<<"$secret")
  name=$(jq -r '.name' <<<"$node")
  [[ -n "$address" ]] || { log_warn "节点 $(jq -r '.id' <<<"$node") 尚未配置服务器地址。"; return 1; }
  hp=$(format_hostport "$address" "$port")
  snell_version=$(jq -r '.snell_version // 5' <<<"$node")
  snell_mode=$(jq -r '.snell_mode // "default"' <<<"$node")
  if [[ "$snell_version" == 6 ]]; then
    uri="snell://$(urlencode "$psk")@${hp}?version=6&userkey=$(urlencode "$userkey")&mode=$(urlencode "$snell_mode")"
  else
    uri="snell://$(urlencode "$psk")@${hp}?version=4&userkey=$(urlencode "$userkey")"
  fi
  obfs_mode=$(jq -r '.obfs_mode // "none"' <<<"$node")
  if [[ "$snell_version" != 6 && "$obfs_mode" == http ]]; then
    obfs_host=$(jq -r '.obfs_host // "bing.com"' <<<"$node")
    uri+="&obfs=http&obfs-host=$(urlencode "$obfs_host")"
  fi
  printf '%s#%s\n' "$uri" "$(urlencode "$name")"
}

protocol_snell_client_outbound() {
  local node=$1 secret=$2 node_secret=${3:-'{}'} base obfs_mode obfs_host snell_version snell_mode client_version
  obfs_mode=$(jq -r '.obfs_mode // "none"' <<<"$node")
  obfs_host=$(jq -r '.obfs_host // "bing.com"' <<<"$node")
  snell_version=$(jq -r '.snell_version // 5' <<<"$node")
  snell_mode=$(jq -r '.snell_mode // "default"' <<<"$node")
  client_version=4
  [[ "$snell_version" == 6 ]] && client_version=6
  base=$(jq -n \
    --arg tag "proxy-$(jq -r '.id' <<<"$node")" \
    --arg server "$(jq -r '.server_address // ""' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" \
    --arg psk "$(jq -r '.psk' <<<"$node_secret")" \
    --arg userkey "$(jq -r '.userkey' <<<"$secret")" \
    --arg obfs_mode "$obfs_mode" --arg mode "$snell_mode" --argjson version "$client_version" \
    '{type:"snell",tag:$tag,server:$server,server_port:$port,version:$version,psk:$psk,userkey:$userkey,reuse:false,network:"tcp"}
     | if $version == 6 then . + {mode:$mode} else . + {obfs_mode:$obfs_mode} end')
  if [[ "$snell_version" != 6 && "$obfs_mode" == http ]]; then
    jq --arg host "$obfs_host" '. + {obfs_host:$host}' <<<"$base"
  else
    printf '%s\n' "$base"
  fi
}
