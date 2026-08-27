#!/usr/bin/env bash
# shellcheck shell=bash

protocol_vmess_render() {
  local node=$1 secret=$2
  jq -n \
    --arg tag "in-$(jq -r '.id' <<<"$node")" \
    --arg listen "$(jq -r '.listen // "127.0.0.1"' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" \
    --arg name "$(jq -r '.name' <<<"$node")" \
    --arg uuid "$(jq -r '.uuid' <<<"$secret")" \
    --arg path "$(jq -r '.ws_path' <<<"$node")" \
    '{
      type: "vmess",
      tag: $tag,
      listen: $listen,
      listen_port: $port,
      users: [{name: $name, uuid: $uuid}],
      transport: {type: "ws", path: $path}
    }'
}

protocol_vmess_share() {
  local node=$1 secret=$2 domain address name uuid path payload
  domain=$(jq -r '.domain // ""' <<<"$node")
  address=$(jq -r '.client_address // ""' <<<"$node")
  [[ -n "$address" ]] || address=$domain
  name=$(jq -r '.name' <<<"$node")
  uuid=$(jq -r '.uuid' <<<"$secret")
  path=$(jq -r '.ws_path' <<<"$node")
  [[ -n "$domain" && -n "$address" ]] || { log_warn "节点 $(jq -r '.id' <<<"$node") 尚未配置 Tunnel 域名/客户端地址。"; return 1; }
  payload=$(jq -cn \
    --arg ps "$name" --arg add "$address" --arg id "$uuid" --arg host "$domain" --arg path "$path" --arg sni "$domain" \
    '{v:"2",ps:$ps,add:$add,port:"443",id:$id,aid:"0",scy:"auto",net:"ws",type:"none",host:$host,path:$path,tls:"tls",sni:$sni,alpn:"http/1.1",fp:"chrome",insecure:"0"}')
  printf 'vmess://%s\n' "$(printf '%s' "$payload" | base64_nowrap)"
}

protocol_vmess_client_outbound() {
  local node=$1 secret=$2 domain address
  domain=$(jq -r '.domain // ""' <<<"$node")
  address=$(jq -r '.client_address // ""' <<<"$node")
  [[ -n "$address" ]] || address=$domain
  jq -n \
    --arg tag "proxy-$(jq -r '.id' <<<"$node")" \
    --arg server "$address" --arg uuid "$(jq -r '.uuid' <<<"$secret")" \
    --arg host "$domain" --arg path "$(jq -r '.ws_path' <<<"$node")" \
    '{
      type:"vmess", tag:$tag, server:$server, server_port:443, uuid:$uuid, security:"auto",
      tls:{enabled:true, server_name:$host, utls:{enabled:true, fingerprint:"chrome"}},
      transport:{type:"ws", path:$path, headers:{Host:$host}}
    }'
}
