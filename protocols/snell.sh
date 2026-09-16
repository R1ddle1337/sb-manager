#!/usr/bin/env bash
# shellcheck shell=bash

# sing-box 1.14+ supports Snell v5 and v6. Version 5 uses HTTP obfuscation and
# exports a compatible v4 client; version 6 uses traffic shaping and exports v6.
protocol_snell_multiuser() {
  local node=$1
  [[ $(jq '[.users[]? | select(.enabled==true)] | length' <<<"$node") -gt 1 ]]
}

protocol_snell_render() {
  local node=$1 credentials=$2 node_secret=${3:-'{}'} obfs_mode snell_version snell_mode base multiuser
  obfs_mode=$(jq -r '.obfs_mode // "none"' <<<"$node")
  snell_version=$(jq -r '.snell_version // 5' <<<"$node")
  snell_mode=$(jq -r '.snell_mode // "default"' <<<"$node")
  multiuser=false
  protocol_snell_multiuser "$node" && multiuser=true
  base=$(jq -n \
    --arg tag "in-$(jq -r '.id' <<<"$node")" \
    --arg listen "$(jq -r '.listen // "::"' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" \
    --arg psk "$(jq -r '.psk' <<<"$node_secret")" \
    --argjson users "$(jq '[.[] | {name,userkey}]' <<<"$credentials")" \
    --arg obfs_mode "$obfs_mode" --arg mode "$snell_mode" --argjson version "$snell_version" --argjson multiuser "$multiuser" \
    '{type:"snell",tag:$tag,listen:$listen,listen_port:$port,version:$version,psk:$psk}
     | if $multiuser then . + {users:$users} else . end
     | if $version == 6 then . + {mode:$mode} else . + {obfs_mode:$obfs_mode} end')
  printf '%s\n' "$base"
}

protocol_snell_share() {
  local node=$1 secret=$2 node_secret=${3:-'{}'} address port psk userkey name hp uri obfs_mode obfs_host snell_version snell_mode multiuser
  address=$(jq -r '.server_address // ""' <<<"$node")
  port=$(jq -r '.port' <<<"$node")
  psk=$(jq -r '.psk' <<<"$node_secret")
  userkey=$(jq -r '.userkey' <<<"$secret")
  name=$(jq -r '.name' <<<"$node")
  [[ -n "$address" ]] || { log_warn "节点 $(jq -r '.id' <<<"$node") 尚未配置服务器地址。"; return 1; }
  hp=$(format_hostport "$address" "$port")
  snell_version=$(jq -r '.snell_version // 5' <<<"$node")
  snell_mode=$(jq -r '.snell_mode // "default"' <<<"$node")
  multiuser=false
  protocol_snell_multiuser "$node" && multiuser=true
  if [[ "$snell_version" == 6 ]]; then
    uri="snell://$(urlencode "$psk")@${hp}?version=6&mode=$(urlencode "$snell_mode")&reuse=false"
    if [[ "$multiuser" == true ]]; then
      uri+="&userkey=$(urlencode "$userkey")"
    fi
  else
    uri="snell://$(urlencode "$psk")@${hp}?version=4&reuse=false"
    if [[ "$multiuser" == true ]]; then
      uri+="&userkey=$(urlencode "$userkey")"
    fi
  fi
  obfs_mode=$(jq -r '.obfs_mode // "none"' <<<"$node")
  if [[ "$snell_version" != 6 && "$obfs_mode" == http ]]; then
    obfs_host=$(jq -r '.obfs_host // "bing.com"' <<<"$node")
    uri+="&obfs=http&obfs-host=$(urlencode "$obfs_host")"
  fi
  printf '%s#%s\n' "$uri" "$(urlencode "$name")"
}

protocol_snell_client_outbound() {
  local node=$1 secret=$2 node_secret=${3:-'{}'} base obfs_mode obfs_host snell_version snell_mode client_version multiuser
  obfs_mode=$(jq -r '.obfs_mode // "none"' <<<"$node")
  obfs_host=$(jq -r '.obfs_host // "bing.com"' <<<"$node")
  snell_version=$(jq -r '.snell_version // 5' <<<"$node")
  snell_mode=$(jq -r '.snell_mode // "default"' <<<"$node")
  client_version=4
  [[ "$snell_version" == 6 ]] && client_version=6
  multiuser=false
  protocol_snell_multiuser "$node" && multiuser=true
  base=$(jq -n \
    --arg tag "proxy-$(jq -r '.id' <<<"$node")" \
    --arg server "$(jq -r '.server_address // ""' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" \
    --arg psk "$(jq -r '.psk' <<<"$node_secret")" \
    --arg userkey "$(jq -r '.userkey' <<<"$secret")" \
    --arg obfs_mode "$obfs_mode" --arg mode "$snell_mode" --argjson version "$client_version" --argjson multiuser "$multiuser" \
    '{type:"snell",tag:$tag,server:$server,server_port:$port,version:$version,psk:$psk,reuse:false,network:"tcp"}
     | if $multiuser then . + {userkey:$userkey} else . end
     | if $version == 6 then . + {mode:$mode} else . + {obfs_mode:$obfs_mode} end')
  if [[ "$snell_version" != 6 && "$obfs_mode" == http ]]; then
    jq --arg host "$obfs_host" '. + {obfs_host:$host}' <<<"$base"
  else
    printf '%s\n' "$base"
  fi
}

protocol_snell_surge_share() {
  local node=$1 secret=$2 node_secret=${3:-'{}'} address port psk name snell_version obfs_mode obfs_host client_version snell_mode
  address=$(jq -r '.server_address // ""' <<<"$node")
  port=$(jq -r '.port' <<<"$node")
  psk=$(jq -r '.psk' <<<"$node_secret")
  name=$(jq -r '.name' <<<"$node")
  snell_version=$(jq -r '.snell_version // 5' <<<"$node")
  [[ "$snell_version" == 5 || "$snell_version" == 6 ]] || return 1
  protocol_snell_multiuser "$node" && return 1
  obfs_mode=$(jq -r '.obfs_mode // "none"' <<<"$node")
  obfs_host=$(jq -r '.obfs_host // "bing.com"' <<<"$node")
  snell_mode=$(jq -r '.snell_mode // "default"' <<<"$node")
  client_version=4
  [[ "$snell_version" == 6 ]] && client_version=6
  printf '%s = snell, %s, %s, psk=%s, version=%s, reuse=false' "$name" "$address" "$port" "$psk" "$client_version"
  if [[ "$snell_version" == 5 && "$obfs_mode" == http ]]; then
    printf ', obfs=http, obfs-host=%s' "$obfs_host"
  fi
  if [[ "$snell_version" == 6 ]]; then
    printf ', mode=%s' "$snell_mode"
  fi
  printf '\n'
}

protocol_snell_mihomo_share() {
  local node=$1 secret=$2 node_secret=${3:-'{}'} address port psk name snell_version obfs_mode obfs_host
  address=$(jq -r '.server_address // ""' <<<"$node")
  port=$(jq -r '.port' <<<"$node")
  psk=$(jq -r '.psk' <<<"$node_secret")
  name=$(jq -r '.name' <<<"$node")
  snell_version=$(jq -r '.snell_version // 5' <<<"$node")
  [[ "$snell_version" == 5 ]] || return 1
  protocol_snell_multiuser "$node" && return 1
  obfs_mode=$(jq -r '.obfs_mode // "none"' <<<"$node")
  obfs_host=$(jq -r '.obfs_host // "bing.com"' <<<"$node")
  jq -n --arg name "$name" --arg server "$address" --argjson port "$port" --arg psk "$psk" \
    --arg obfs "$obfs_mode" --arg host "$obfs_host" \
    '{name:$name,type:"snell",server:$server,port:$port,psk:$psk,version:4,reuse:false}
     | if $obfs == "http" then . + {"obfs-opts":{mode:"http",host:$host}} else . end'
}
