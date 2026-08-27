#!/usr/bin/env bash
# shellcheck shell=bash

node_share_uri() {
  local id=$1 node secret protocol
  node=$(state_get_node "$id"); [[ -n "$node" ]] || die "节点不存在：$id"
  secret=$(state_get_secret "$id"); protocol=$(jq -r '.protocol' <<<"$node")
  case "$protocol" in
    vmess-ws-cf) protocol_vmess_share "$node" "$secret" ;;
    shadowsocks) protocol_ss_share "$node" "$secret" ;;
    anytls) protocol_anytls_share "$node" "$secret" ;;
    hysteria2) protocol_hy2_share "$node" "$secret" ;;
  esac
}

node_client_outbound() {
  local id=$1 node secret protocol
  node=$(state_get_node "$id"); [[ -n "$node" ]] || die "节点不存在：$id"
  secret=$(state_get_secret "$id"); protocol=$(jq -r '.protocol' <<<"$node")
  case "$protocol" in
    vmess-ws-cf) protocol_vmess_client_outbound "$node" "$secret" ;;
    shadowsocks) protocol_ss_client_outbound "$node" "$secret" ;;
    anytls) protocol_anytls_client_outbound "$node" "$secret" ;;
    hysteria2) protocol_hy2_client_outbound "$node" "$secret" ;;
  esac
}

node_share() {
  local id=$1 qr=${2:-0} uri out_dir outbound
  uri=$(node_share_uri "$id") || return 1
  out_dir="$SBM_EXPORTS/nodes/$id"; mkdir -p "$out_dir"; chmod 0700 "$out_dir" 2>/dev/null || true
  printf '%s\n' "$uri" >"$out_dir/share.txt"; chmod 0600 "$out_dir/share.txt"
  outbound=$(node_client_outbound "$id")
  printf '%s\n' "$outbound" | jq . >"$out_dir/outbound.json"; chmod 0600 "$out_dir/outbound.json"
  printf '\n%s节点：%s%s\n\n%s\n\n' "$C_BOLD" "$id" "$C_RESET" "$uri"
  printf 'sing-box 客户端 outbound：%s\n' "$out_dir/outbound.json"
  if [[ "$qr" == 1 ]]; then
    if command_exists qrencode; then qrencode -t ANSIUTF8 "$uri"; else log_warn "未安装 qrencode，无法显示二维码。"; fi
  fi
}

node_share_all() {
  local node id uri file="$SBM_EXPORTS/links.txt" tmp
  mkdir -p "$SBM_EXPORTS"; tmp=$(mktemp "$SBM_EXPORTS/.links.XXXXXX")
  while IFS= read -r node; do
    id=$(jq -r '.id' <<<"$node")
    if uri=$(node_share_uri "$id" 2>/dev/null); then printf '%s\n' "$uri" >>"$tmp"; fi
  done < <(jq -c '.nodes[]? | select(.enabled==true)' "$SBM_STATE")
  chmod 0600 "$tmp"; mv "$tmp" "$file"
  cat "$file"
  printf '\n已保存：%s\n' "$file"
}

export_all_outbounds() {
  local arr='[]' node id ob out="$SBM_EXPORTS/outbounds.json"
  while IFS= read -r node; do
    id=$(jq -r '.id' <<<"$node")
    ob=$(node_client_outbound "$id")
    arr=$(jq -c --argjson x "$ob" '. + [$x]' <<<"$arr")
  done < <(jq -c '.nodes[]? | select(.enabled==true)' "$SBM_STATE")
  printf '%s\n' "$arr" | jq . >"$out"; chmod 0600 "$out"
  log_ok "已导出客户端 outbound 数组：$out"
}
