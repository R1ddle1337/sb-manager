#!/usr/bin/env bash
# shellcheck shell=bash

protocol_proxy_render() {
  jq -n --argjson node "$1" --argjson users "$2" '
    {type:$node.protocol,tag:("in-"+$node.id),listen:$node.listen,listen_port:$node.port,
     users:[$users[]|{username,password}]}'
}

protocol_proxy_share() {
  local node=$1 secret=$2 scheme hostport
  scheme=$(jq -r 'if .protocol=="http" then "http" else "socks5" end' <<<"$node")
  hostport=$(format_hostport "$(jq -r '.server_address' <<<"$node")" "$(jq -r '.port' <<<"$node")")
  printf '%s://%s:%s@%s#%s\n' "$scheme" "$(urlencode "$(jq -r '.username' <<<"$secret")")" \
    "$(urlencode "$(jq -r '.password' <<<"$secret")")" "$hostport" "$(urlencode "$(jq -r '.name' <<<"$node")")"
}

protocol_proxy_client_outbound() {
  jq -n --argjson node "$1" --argjson secret "$2" '
    {type:(if $node.protocol=="http" then "http" else "socks" end),server:$node.server_address,
     server_port:$node.port,username:$secret.username,password:$secret.password}
    | if .type=="socks" then .version="5" | if $node.traffic.enabled then .network="tcp" else . end else . end'
}
