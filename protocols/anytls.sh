#!/usr/bin/env bash
# shellcheck shell=bash

protocol_anytls_render() {
  local node=$1 credentials=$2 domain cert_dir
  domain=$(jq -r '.domain' <<<"$node")
  cert_dir="$SBM_CERTS/$domain"
  jq -n \
    --arg tag "in-$(jq -r '.id' <<<"$node")" \
    --arg listen "$(jq -r '.listen // "::"' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" \
    --argjson users "$(jq '[.[] | {name,password}]' <<<"$credentials")" \
    --arg domain "$domain" \
    --arg cert "$cert_dir/fullchain.pem" --arg key "$cert_dir/key.pem" \
    '{
      type:"anytls", tag:$tag, listen:$listen, listen_port:$port,
      users:$users,
      tls:{enabled:true,server_name:$domain,certificate_path:$cert,key_path:$key}
    }'
}

protocol_anytls_share() {
  local node=$1 secret=$2 address domain port password name hp
  address=$(jq -r '.server_address // ""' <<<"$node")
  domain=$(jq -r '.domain' <<<"$node")
  port=$(jq -r '.port' <<<"$node")
  password=$(jq -r '.password' <<<"$secret")
  name=$(jq -r '.name' <<<"$node")
  [[ -n "$address" ]] || { log_warn "节点 $(jq -r '.id' <<<"$node") 尚未配置服务器地址。"; return 1; }
  hp=$(format_hostport "$address" "$port")
  printf 'anytls://%s@%s?security=tls&sni=%s&fp=chrome&insecure=0#%s\n' \
    "$(urlencode "$password")" "$hp" "$(urlencode "$domain")" "$(urlencode "$name")"
}

protocol_anytls_client_outbound() {
  local node=$1 secret=$2
  jq -n \
    --arg tag "proxy-$(jq -r '.id' <<<"$node")" \
    --arg server "$(jq -r '.server_address // ""' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" \
    --arg password "$(jq -r '.password' <<<"$secret")" \
    --arg domain "$(jq -r '.domain' <<<"$node")" \
    '{type:"anytls",tag:$tag,server:$server,server_port:$port,password:$password,tls:{enabled:true,server_name:$domain,utls:{enabled:true,fingerprint:"chrome"}}}'
}
