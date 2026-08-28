#!/usr/bin/env bash
# shellcheck shell=bash

protocol_naive_render() {
  local node=$1 credentials=$2 domain cert_dir network base
  domain=$(jq -r '.domain' <<<"$node"); cert_dir="$SBM_CERTS/$domain"; network=$(jq -r '.network // "tcp"' <<<"$node")
  base=$(jq -n --arg tag "in-$(jq -r '.id' <<<"$node")" --arg listen "$(jq -r '.listen // "::"' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" --arg network "$network" \
    --argjson users "$(jq '[.[] | {username:(.username // .name),password}]' <<<"$credentials")" \
    --arg domain "$domain" --arg cert "$cert_dir/fullchain.pem" --arg key "$cert_dir/key.pem" \
    '{type:"naive",tag:$tag,listen:$listen,listen_port:$port,network:$network,users:$users,
      tls:{enabled:true,server_name:$domain,certificate_path:$cert,key_path:$key}}')
  if [[ "$network" == udp ]]; then
    jq --arg cc "$(jq -r '.quic_congestion_control // "bbr"' <<<"$node")" '.quic_congestion_control=$cc | .tls.alpn=["h3"]' <<<"$base"
  else
    jq '.tls.alpn=["h2"]' <<<"$base"
  fi
}

protocol_naive_share() {
  local node=$1 secret=$2 address domain port username password name hp scheme
  address=$(jq -r '.server_address' <<<"$node"); domain=$(jq -r '.domain' <<<"$node"); port=$(jq -r '.port' <<<"$node")
  username=$(jq -r '.username' <<<"$secret"); password=$(jq -r '.password' <<<"$secret"); name=$(jq -r '.name' <<<"$node")
  hp=$(format_hostport "$address" "$port"); scheme=naive+https
  [[ $(jq -r '.network' <<<"$node") != udp ]] || scheme=naive+quic
  printf '%s://%s:%s@%s?sni=%s#%s\n' "$scheme" "$(urlencode "$username")" "$(urlencode "$password")" "$hp" "$(urlencode "$domain")" "$(urlencode "$name")"
}

protocol_naive_client_outbound() {
  local node=$1 secret=$2 network quic
  "$SBM_SING_BOX_BIN" version 2>/dev/null | grep -Eq '(^|[,[:space:]])with_naive_outbound([,[:space:]]|$)' || {
    log_error '当前核心缺少 with_naive_outbound，无法导出可验证的 Naive 客户端配置。'; return 1;
  }
  [[ -f "$(dirname "$(readlink -f "$SBM_SING_BOX_BIN")")/libcronet.so" ]] || {
    log_error '当前核心目录缺少 libcronet.so，无法使用 Naive 客户端出站。'; return 1;
  }
  network=$(jq -r '.network' <<<"$node"); [[ "$network" == udp ]] && quic=true || quic=false
  jq -n --arg tag "proxy-$(jq -r '.id' <<<"$node")" --arg server "$(jq -r '.server_address' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" --arg username "$(jq -r '.username' <<<"$secret")" \
    --arg password "$(jq -r '.password' <<<"$secret")" --arg domain "$(jq -r '.domain' <<<"$node")" \
    --arg cc "$(jq -r '.quic_congestion_control // "bbr"' <<<"$node")" --argjson quic "$quic" \
    '{type:"naive",tag:$tag,server:$server,server_port:$port,username:$username,password:$password,
      quic:$quic,quic_congestion_control:(if $quic then $cc else null end),tls:{enabled:true,server_name:$domain}}'
}
