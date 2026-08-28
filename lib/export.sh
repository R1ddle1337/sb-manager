#!/usr/bin/env bash
# shellcheck shell=bash

node_share_uri() {
  local id=$1 user_id=${2:-} node user secret node_secret='{}' protocol
  node=$(state_get_node "$id"); [[ -n "$node" ]] || die "节点不存在：$id"
  [[ -n "$user_id" ]] || user_id=$(jq -r 'first(.users[] | select(.enabled==true) | .id) // empty' <<<"$node")
  [[ -n "$user_id" ]] || die "节点没有启用用户：$id"
  user=$(state_get_user "$id" "$user_id"); secret=$(jq -s '.[0]+.[1]' <(printf '%s\n' "$user") <(state_get_user_secret "$id" "$user_id"))
  [[ ! -r $(state_secret_path "$id") ]] || node_secret=$(state_get_secret "$id")
  protocol=$(jq -r '.protocol' <<<"$node")
  case "$protocol" in
    vmess-ws-cf) protocol_vmess_share "$node" "$secret" "$node_secret" ;;
    shadowsocks) protocol_ss_share "$node" "$secret" "$node_secret" ;;
    anytls) protocol_anytls_share "$node" "$secret" "$node_secret" ;;
    hysteria2) protocol_hy2_share "$node" "$secret" "$node_secret" ;;
    trojan) protocol_trojan_share "$node" "$secret" ;;
    tuic) protocol_tuic_share "$node" "$secret" ;;
    vless) protocol_vless_share "$node" "$secret" "$node_secret" ;;
    naive) protocol_naive_share "$node" "$secret" ;;
    shadowtls) protocol_shadowtls_share "$node" "$secret" ;;
  esac
}

node_client_outbound() {
  local id=$1 user_id=${2:-} node user secret node_secret='{}' protocol outbound tag
  node=$(state_get_node "$id"); [[ -n "$node" ]] || die "节点不存在：$id"
  [[ -n "$user_id" ]] || user_id=$(jq -r 'first(.users[] | select(.enabled==true) | .id) // empty' <<<"$node")
  [[ -n "$user_id" ]] || die "节点没有启用用户：$id"
  user=$(state_get_user "$id" "$user_id"); secret=$(jq -s '.[0]+.[1]' <(printf '%s\n' "$user") <(state_get_user_secret "$id" "$user_id"))
  [[ ! -r $(state_secret_path "$id") ]] || node_secret=$(state_get_secret "$id")
  protocol=$(jq -r '.protocol' <<<"$node")
  case "$protocol" in
    vmess-ws-cf) outbound=$(protocol_vmess_client_outbound "$node" "$secret" "$node_secret") ;;
    shadowsocks) outbound=$(protocol_ss_client_outbound "$node" "$secret" "$node_secret") ;;
    anytls) outbound=$(protocol_anytls_client_outbound "$node" "$secret" "$node_secret") ;;
    hysteria2) outbound=$(protocol_hy2_client_outbound "$node" "$secret" "$node_secret") ;;
    trojan) outbound=$(protocol_trojan_client_outbound "$node" "$secret") ;;
    tuic) outbound=$(protocol_tuic_client_outbound "$node" "$secret") ;;
    vless) outbound=$(protocol_vless_client_outbound "$node" "$secret" "$node_secret") ;;
    naive) outbound=$(protocol_naive_client_outbound "$node" "$secret") ;;
    shadowtls) outbound=$(protocol_shadowtls_client_outbound "$node" "$secret") ;;
    *) die "不支持导出的协议：$protocol" ;;
  esac
  tag="proxy-${id}-${user_id}"
  jq --arg tag "$tag" '.tag=$tag' <<<"$outbound"
}

node_share() {
  local id=$1 qr=${2:-0} user_id=${3:-} uri out_dir outbound
  [[ -n "$user_id" ]] || user_id=$(jq -r --arg id "$id" 'first(.nodes[] | select(.id==$id) | .users[] | select(.enabled==true) | .id) // empty' "$SBM_STATE")
  uri=$(node_share_uri "$id" "$user_id") || return 1
  out_dir="$SBM_EXPORTS/nodes/$id/$user_id"; mkdir -p "$out_dir"; chmod 0700 "$out_dir" 2>/dev/null || true
  printf '%s\n' "$uri" >"$out_dir/share.txt"; chmod 0600 "$out_dir/share.txt"
  outbound=$(node_client_outbound "$id" "$user_id")
  printf '%s\n' "$outbound" | jq . >"$out_dir/outbound.json"; chmod 0600 "$out_dir/outbound.json"
  printf '\n%s节点/用户：%s/%s%s\n\n%s\n\n' "$C_BOLD" "$id" "$user_id" "$C_RESET" "$uri"
  printf 'sing-box 客户端 outbound：%s\n' "$out_dir/outbound.json"
  if [[ "$qr" == 1 ]]; then
    if command_exists qrencode; then qrencode -t ANSIUTF8 "$uri"; else log_warn "未安装 qrencode，无法显示二维码。"; fi
  fi
}

node_share_all() {
  local node id user_id uri file="$SBM_EXPORTS/links.txt" tmp
  mkdir -p "$SBM_EXPORTS"; tmp=$(mktemp "$SBM_EXPORTS/.links.XXXXXX")
  while IFS= read -r node; do
    id=$(jq -r '.id' <<<"$node")
    while IFS= read -r user_id; do
      if uri=$(node_share_uri "$id" "$user_id" 2>/dev/null); then printf '%s\n' "$uri" >>"$tmp"; fi
    done < <(jq -r '.users[] | select(.enabled==true) | .id' <<<"$node")
  done < <(jq -c '.nodes[]? | select(.enabled==true)' "$SBM_STATE")
  chmod 0600 "$tmp"; mv "$tmp" "$file"
  cat "$file"
  printf '\n已保存：%s\n' "$file"
}

export_all_outbounds() {
  local arr='[]' node id user_id ob out="$SBM_EXPORTS/outbounds.json"
  while IFS= read -r node; do
    id=$(jq -r '.id' <<<"$node")
    while IFS= read -r user_id; do
      ob=$(node_client_outbound "$id" "$user_id")
      arr=$(jq -c --argjson x "$ob" '. + [$x]' <<<"$arr")
    done < <(jq -r '.users[] | select(.enabled==true) | .id' <<<"$node")
  done < <(jq -c '.nodes[]? | select(.enabled==true)' "$SBM_STATE")
  printf '%s\n' "$arr" | jq . >"$out"; chmod 0600 "$out"
  log_ok "已导出客户端 outbound 数组：$out"
}

export_client_config() {
  local output=${1:-$SBM_EXPORTS/client-config.json} mode=${2:-mixed} node user_id ob outbounds='[]' final inbounds route dns
  [[ "$mode" == mixed || "$mode" == tun ]] || die '客户端模式必须是 mixed 或 tun。'
  mkdir -p "$(dirname "$output")"
  while IFS= read -r node; do
    while IFS= read -r user_id; do
      ob=$(node_client_outbound "$(jq -r '.id' <<<"$node")" "$user_id")
      outbounds=$(jq -c --argjson x "$ob" '. + [$x]' <<<"$outbounds")
    done < <(jq -r '.users[] | select(.enabled==true) | .id' <<<"$node")
  done < <(jq -c '.nodes[]? | select(.enabled==true)' "$SBM_STATE")
  final=$(jq -r 'first(.[]?.tag) // "direct"' <<<"$outbounds")
  dns=$(jq -n '{servers:[{type:"local",tag:"dns-local"}],final:"dns-local",strategy:"prefer_ipv4"}')
  if [[ "$mode" == tun ]]; then
    inbounds=$(jq -n '[{type:"tun",tag:"tun-in",address:["172.19.0.1/30","fdfe:dcba:9876::1/126"],mtu:1500,auto_route:true,strict_route:true,stack:"system"}]')
    route=$(jq -n --arg final "$final" '{auto_detect_interface:true,default_domain_resolver:"dns-local",rules:[{action:"sniff"},{protocol:"dns",action:"hijack-dns"},{ip_is_private:true,action:"route",outbound:"direct"}],final:$final}')
  else
    inbounds=$(jq -n '[{type:"mixed",tag:"mixed-in",listen:"127.0.0.1",listen_port:2080}]')
    route=$(jq -n --arg final "$final" '{default_domain_resolver:"dns-local",final:$final}')
  fi
  jq -n --argjson dns "$dns" --argjson inbounds "$inbounds" --argjson route "$route" --argjson outbounds "$outbounds" '{
    "$schema":"https://sing-box.sagernet.org/schema.json",
    log:{level:"info",timestamp:true},
    dns:$dns,
    inbounds:$inbounds,
    outbounds:($outbounds + [{type:"direct",tag:"direct"}]),
    route:$route
  }' >"$output"
  chmod 0600 "$output"
  core_validate_config "$output"
  log_ok "已导出 $mode 模式 sing-box 客户端配置：$output"
}
