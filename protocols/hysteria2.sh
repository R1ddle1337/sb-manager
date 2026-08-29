#!/usr/bin/env bash
# shellcheck shell=bash

protocol_hy2_render() {
  local node=$1 credentials=$2 node_secret=$3 domain cert_dir base obfs_type obfs_password masquerade min_packet_size max_packet_size bbr_profile brutal_debug
  domain=$(jq -r '.domain' <<<"$node")
  cert_dir="$SBM_CERTS/$domain"
  obfs_type=$(jq -r '.obfs.type // ""' <<<"$node")
  obfs_password=$(jq -r '.obfs_password // ""' <<<"$node_secret")
  masquerade=$(jq -r '.masquerade // ""' <<<"$node")
  base=$(jq -n \
    --arg tag "in-$(jq -r '.id' <<<"$node")" \
    --arg listen "$(jq -r '.listen // "::"' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" \
    --argjson users "$(jq '[.[] | {name,password}]' <<<"$credentials")" \
    --arg domain "$domain" \
    --arg cert "$cert_dir/fullchain.pem" --arg key "$cert_dir/key.pem" \
    '{
      type:"hysteria2",tag:$tag,listen:$listen,listen_port:$port,
      users:$users,
      tls:{enabled:true,server_name:$domain,certificate_path:$cert,key_path:$key}
    }')
  if [[ -n "$obfs_type" ]]; then
    if [[ "$obfs_type" == gecko ]]; then
      min_packet_size=$(jq -r '.obfs.min_packet_size // 512' <<<"$node")
      max_packet_size=$(jq -r '.obfs.max_packet_size // 1200' <<<"$node")
      base=$(jq --arg t "$obfs_type" --arg p "$obfs_password" --argjson min "$min_packet_size" --argjson max "$max_packet_size" \
        '. + {obfs:{type:$t,password:$p,min_packet_size:$min,max_packet_size:$max}}' <<<"$base")
    else
      base=$(jq --arg t "$obfs_type" --arg p "$obfs_password" '. + {obfs:{type:$t,password:$p}}' <<<"$base")
    fi
  fi
  if [[ -n "$masquerade" ]]; then
    base=$(jq --arg m "$masquerade" '. + {masquerade:$m}' <<<"$base")
  fi
  bbr_profile=$(jq -r '.bbr_profile // ""' <<<"$node")
  brutal_debug=$(jq -r '.brutal_debug // false' <<<"$node")
  [[ -z "$bbr_profile" ]] || base=$(jq --arg p "$bbr_profile" '. + {bbr_profile:$p}' <<<"$base")
  [[ "$brutal_debug" != true ]] || base=$(jq '. + {brutal_debug:true}' <<<"$base")
  printf '%s\n' "$base"
}

protocol_hy2_share() {
  local node=$1 secret=$2 node_secret=${3:-'{}'} address domain port password name hp uri obfs_type obfs_password
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
    obfs_password=$(jq -r '.obfs_password // ""' <<<"$node_secret")
    uri+="&obfs=$(urlencode "$obfs_type")&obfs-password=$(urlencode "$obfs_password")"
  fi
  printf '%s#%s\n' "$uri" "$(urlencode "$name")"
}

protocol_hy2_client_outbound() {
  local node=$1 secret=$2 node_secret=${3:-'{}'} base obfs_type min_packet_size max_packet_size disable_chrome_parrot bbr_profile brutal_debug
  base=$(jq -n \
    --arg tag "proxy-$(jq -r '.id' <<<"$node")" \
    --arg server "$(jq -r '.server_address // ""' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" \
    --arg password "$(jq -r '.password' <<<"$secret")" \
    --arg domain "$(jq -r '.domain' <<<"$node")" \
    '{type:"hysteria2",tag:$tag,server:$server,server_port:$port,password:$password,tls:{enabled:true,server_name:$domain}}')
  obfs_type=$(jq -r '.obfs.type // ""' <<<"$node")
  if [[ -n "$obfs_type" ]]; then
    if [[ "$obfs_type" == gecko ]]; then
      min_packet_size=$(jq -r '.obfs.min_packet_size // 512' <<<"$node")
      max_packet_size=$(jq -r '.obfs.max_packet_size // 1200' <<<"$node")
      base=$(jq --arg t "$obfs_type" --arg p "$(jq -r '.obfs_password // ""' <<<"$node_secret")" --argjson min "$min_packet_size" --argjson max "$max_packet_size" \
        '. + {obfs:{type:$t,password:$p,min_packet_size:$min,max_packet_size:$max}}' <<<"$base")
    else
      base=$(jq --arg t "$obfs_type" --arg p "$(jq -r '.obfs_password // ""' <<<"$node_secret")" '. + {obfs:{type:$t,password:$p}}' <<<"$base")
    fi
  fi
  disable_chrome_parrot=$(jq -r '.disable_chrome_parrot // false' <<<"$node")
  if [[ "$disable_chrome_parrot" == true ]]; then
    base=$(jq '. + {disable_chrome_parrot:true}' <<<"$base")
  fi
  bbr_profile=$(jq -r '.bbr_profile // ""' <<<"$node")
  brutal_debug=$(jq -r '.brutal_debug // false' <<<"$node")
  [[ -z "$bbr_profile" ]] || base=$(jq --arg p "$bbr_profile" '. + {bbr_profile:$p}' <<<"$base")
  [[ "$brutal_debug" != true ]] || base=$(jq '. + {brutal_debug:true}' <<<"$base")
  printf '%s\n' "$base"
}
