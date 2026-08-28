#!/usr/bin/env bash
# shellcheck shell=bash

protocol_shadowtls_render() {
  local node=$1 credentials=$2
  jq -n --arg tag "in-$(jq -r '.id' <<<"$node")" --arg listen "$(jq -r '.listen // "::"' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" --argjson users "$(jq '[.[] | {name,password}]' <<<"$credentials")" \
    --arg server "$(jq -r '.handshake_server' <<<"$node")" --argjson server_port "$(jq -r '.handshake_port' <<<"$node")" \
    --argjson strict "$(jq -r '.strict_mode // true' <<<"$node")" --arg wildcard "$(jq -r '.wildcard_sni // "off"' <<<"$node")" \
    '{type:"shadowtls",tag:$tag,listen:$listen,listen_port:$port,version:3,users:$users,
      handshake:{server:$server,server_port:$server_port},strict_mode:$strict,wildcard_sni:$wildcard}'
}

protocol_shadowtls_share() {
  local node=$1 secret=$2 address port password name hp sni
  address=$(jq -r '.server_address' <<<"$node"); port=$(jq -r '.port' <<<"$node"); password=$(jq -r '.password' <<<"$secret")
  name=$(jq -r '.name' <<<"$node"); sni=$(jq -r '.handshake_server' <<<"$node"); hp=$(format_hostport "$address" "$port")
  printf 'shadowtls://%s@%s?version=3&sni=%s#%s\n' "$(urlencode "$password")" "$hp" "$(urlencode "$sni")" "$(urlencode "$name")"
}

protocol_shadowtls_client_outbound() {
  local node=$1 secret=$2
  jq -n --arg tag "proxy-$(jq -r '.id' <<<"$node")" --arg server "$(jq -r '.server_address' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" --arg password "$(jq -r '.password' <<<"$secret")" \
    --arg sni "$(jq -r '.handshake_server' <<<"$node")" \
    '{type:"shadowtls",tag:$tag,server:$server,server_port:$port,version:3,password:$password,
      tls:{enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:"chrome"}}}'
}
