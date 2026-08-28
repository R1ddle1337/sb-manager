#!/usr/bin/env bash
# shellcheck shell=bash

protocol_tuic_render() {
  local node=$1 credentials=$2 domain cert_dir
  domain=$(jq -r '.domain' <<<"$node"); cert_dir="$SBM_CERTS/$domain"
  jq -n --arg tag "in-$(jq -r '.id' <<<"$node")" --arg listen "$(jq -r '.listen // "::"' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" --argjson users "$(jq '[.[] | {name,uuid,password}]' <<<"$credentials")" \
    --arg cc "$(jq -r '.congestion_control // "cubic"' <<<"$node")" --arg domain "$domain" \
    --arg cert "$cert_dir/fullchain.pem" --arg key "$cert_dir/key.pem" \
    '{type:"tuic",tag:$tag,listen:$listen,listen_port:$port,users:$users,congestion_control:$cc,
      zero_rtt_handshake:false,tls:{enabled:true,server_name:$domain,alpn:["h3"],certificate_path:$cert,key_path:$key}}'
}

protocol_tuic_share() {
  local node=$1 secret=$2 address domain port uuid password name hp
  address=$(jq -r '.server_address' <<<"$node"); domain=$(jq -r '.domain' <<<"$node"); port=$(jq -r '.port' <<<"$node")
  uuid=$(jq -r '.uuid' <<<"$secret"); password=$(jq -r '.password' <<<"$secret"); name=$(jq -r '.name' <<<"$node")
  hp=$(format_hostport "$address" "$port")
  printf 'tuic://%s:%s@%s?congestion_control=%s&udp_relay_mode=native&alpn=h3&sni=%s&allow_insecure=0#%s\n' \
    "$(urlencode "$uuid")" "$(urlencode "$password")" "$hp" "$(urlencode "$(jq -r '.congestion_control' <<<"$node")")" \
    "$(urlencode "$domain")" "$(urlencode "$name")"
}

protocol_tuic_client_outbound() {
  local node=$1 secret=$2
  jq -n --arg tag "proxy-$(jq -r '.id' <<<"$node")" --arg server "$(jq -r '.server_address' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" --arg uuid "$(jq -r '.uuid' <<<"$secret")" \
    --arg password "$(jq -r '.password' <<<"$secret")" --arg cc "$(jq -r '.congestion_control' <<<"$node")" \
    --arg domain "$(jq -r '.domain' <<<"$node")" \
    '{type:"tuic",tag:$tag,server:$server,server_port:$port,uuid:$uuid,password:$password,
      congestion_control:$cc,udp_relay_mode:"native",zero_rtt_handshake:false,
      tls:{enabled:true,server_name:$domain,alpn:["h3"]}}'
}
