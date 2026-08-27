#!/usr/bin/env bash
# shellcheck shell=bash

protocol_hy2_render() {
  local node=$1 secret=$2 domain cert_dir base obfs_type obfs_password masquerade
  domain=$(jq -r '.domain' <<<"$node")
  cert_dir="$SBM_CERTS/$domain"
  obfs_type=$(jq -r '.obfs.type // ""' <<<"$node")
  obfs_password=$(jq -r '.obfs_password // ""' <<<"$secret")
  masquerade=$(jq -r '.masquerade // ""' <<<"$node")
  base=$(jq -n \
    --arg tag "in-$(jq -r '.id' <<<"$node")" \
    --arg listen "$(jq -r '.listen // "::"' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" \
    --arg name "$(jq -r '.name' <<<"$node")" \
    --arg password "$(jq -r '.password' <<<"$secret")" \
    --arg domain "$domain" \
    --arg cert "$cert_dir/fullchain.pem" --arg key "$cert_dir/key.pem" \
    '{
      type:"hysteria2",tag:$tag,listen:$listen,listen_port:$port,
      users:[{name:$name,password:$password}],
      tls:{enabled:true,server_name:$domain,certificate_path:$cert,key_path:$key}
    }')
  if [[ -n "$obfs_type" ]]; then
    base=$(jq --arg t "$obfs_type" --arg p "$obfs_password" '. + {obfs:{type:$t,password:$p}}' <<<"$base")
  fi
  if [[ -n "$masquerade" ]]; then
    base=$(jq --arg m "$masquerade" '. + {masquerade:$m}' <<<"$base")
  fi
  printf '%s\n' "$base"
}

protocol_hy2_share() {
  local node=$1 secret=$2 address domain port password name hp uri obfs_type obfs_password
  address=$(jq -r '.server_address // ""' <<<"$node")
  domain=$(jq -r '.domain' <<<"$node")
  port=$(jq -r '.port' <<<"$node")
  password=$(jq -r '.password' <<<"$secret")
  name=$(jq -r '.name' <<<"$node")
  [[ -n "$address" ]] || { log_warn "节点 $(jq -r '.id' <<<"$node") 尚未配置服务器地址。"; return 1; }
  hp=$(format_hostport "$address" "$port")
  uri="hysteria2://$(urlencode "$password")@${hp}/?sni=$(urlencode "$domain")&insecure=0"
  obfs_type=$(jq -r '.obfs.type // ""' <<<"$node")
  if [[ -n "$obfs_type" ]]; then
    obfs_password=$(jq -r '.obfs_password // ""' <<<"$secret")
    uri+="&obfs=$(urlencode "$obfs_type")&obfs-password=$(urlencode "$obfs_password")"
  fi
  printf '%s#%s\n' "$uri" "$(urlencode "$name")"
}

protocol_hy2_client_outbound() {
  local node=$1 secret=$2 base obfs_type
  base=$(jq -n \
    --arg tag "proxy-$(jq -r '.id' <<<"$node")" \
    --arg server "$(jq -r '.server_address // ""' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" \
    --arg password "$(jq -r '.password' <<<"$secret")" \
    --arg domain "$(jq -r '.domain' <<<"$node")" \
    '{type:"hysteria2",tag:$tag,server:$server,server_port:$port,password:$password,tls:{enabled:true,server_name:$domain}}')
  obfs_type=$(jq -r '.obfs.type // ""' <<<"$node")
  if [[ -n "$obfs_type" ]]; then
    base=$(jq --arg t "$obfs_type" --arg p "$(jq -r '.obfs_password // ""' <<<"$secret")" '. + {obfs:{type:$t,password:$p}}' <<<"$base")
  fi
  printf '%s\n' "$base"
}
