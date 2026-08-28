#!/usr/bin/env bash
# shellcheck shell=bash

protocol_vless_generate_reality_secret() {
  local output private public
  output=$("$SBM_SING_BOX_BIN" generate reality-keypair 2>/dev/null) || die 'Reality 密钥生成失败。'
  private=$(awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}' <<<"$output")
  public=$(awk -F': *' 'tolower($1) ~ /public/ {print $2; exit}' <<<"$output")
  [[ -n "$private" && -n "$public" ]] || die '无法解析 Reality 密钥。'
  jq -n --arg private "$private" --arg public "$public" --arg short_id "$(random_hex 4)" \
    '{reality_private_key:$private,reality_public_key:$public,reality_short_id:$short_id}'
}

protocol_vless_render() {
  local node=$1 credentials=$2 node_secret=$3 security domain flow base cert_dir
  security=$(jq -r '.security' <<<"$node"); domain=$(jq -r '.domain' <<<"$node"); flow=$(jq -r '.flow // ""' <<<"$node")
  base=$(jq -n --arg tag "in-$(jq -r '.id' <<<"$node")" --arg listen "$(jq -r '.listen // "::"' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" --arg flow "$flow" \
    --argjson users "$(jq --arg flow "$flow" '[.[] | {name,uuid,flow:$flow}]' <<<"$credentials")" \
    '{type:"vless",tag:$tag,listen:$listen,listen_port:$port,users:$users}')
  if [[ "$security" == reality ]]; then
    jq --arg domain "$domain" --arg server "$(jq -r '.handshake_server' <<<"$node")" \
      --argjson port "$(jq -r '.handshake_port' <<<"$node")" --arg private "$(jq -r '.reality_private_key' <<<"$node_secret")" \
      --arg short_id "$(jq -r '.reality_short_id' <<<"$node_secret")" \
      '. + {tls:{enabled:true,server_name:$domain,reality:{enabled:true,handshake:{server:$server,server_port:$port},private_key:$private,short_id:[$short_id],max_time_difference:"1m"}}}' <<<"$base"
  else
    cert_dir="$SBM_CERTS/$domain"
    jq --arg domain "$domain" --arg cert "$cert_dir/fullchain.pem" --arg key "$cert_dir/key.pem" \
      '. + {tls:{enabled:true,server_name:$domain,certificate_path:$cert,key_path:$key}}' <<<"$base"
  fi
}

protocol_vless_share() {
  local node=$1 secret=$2 node_secret=$3 address domain port uuid flow security uri
  address=$(jq -r '.server_address' <<<"$node"); domain=$(jq -r '.domain' <<<"$node"); port=$(jq -r '.port' <<<"$node")
  uuid=$(jq -r '.uuid' <<<"$secret"); flow=$(jq -r '.flow // ""' <<<"$node"); security=$(jq -r '.security' <<<"$node")
  uri="vless://${uuid}@$(format_hostport "$address" "$port")?encryption=none&security=${security}&type=tcp&sni=$(urlencode "$domain")"
  [[ -z "$flow" ]] || uri+="&flow=$(urlencode "$flow")"
  if [[ "$security" == reality ]]; then
    uri+="&pbk=$(urlencode "$(jq -r '.reality_public_key' <<<"$node_secret")")&sid=$(urlencode "$(jq -r '.reality_short_id' <<<"$node_secret")")&fp=chrome"
  fi
  printf '%s#%s\n' "$uri" "$(urlencode "$(jq -r '.name' <<<"$node")")"
}

protocol_vless_client_outbound() {
  local node=$1 secret=$2 node_secret=$3 security domain flow base
  security=$(jq -r '.security' <<<"$node"); domain=$(jq -r '.domain' <<<"$node"); flow=$(jq -r '.flow // ""' <<<"$node")
  base=$(jq -n --arg tag "proxy-$(jq -r '.id' <<<"$node")" --arg server "$(jq -r '.server_address' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" --arg uuid "$(jq -r '.uuid' <<<"$secret")" --arg flow "$flow" \
    '{type:"vless",tag:$tag,server:$server,server_port:$port,uuid:$uuid,flow:$flow,network:"tcp"}')
  if [[ "$security" == reality ]]; then
    jq --arg domain "$domain" --arg public "$(jq -r '.reality_public_key' <<<"$node_secret")" \
      --arg short_id "$(jq -r '.reality_short_id' <<<"$node_secret")" \
      '. + {tls:{enabled:true,server_name:$domain,utls:{enabled:true,fingerprint:"chrome"},reality:{enabled:true,public_key:$public,short_id:$short_id}}}' <<<"$base"
  else
    jq --arg domain "$domain" '. + {tls:{enabled:true,server_name:$domain}}' <<<"$base"
  fi
}
