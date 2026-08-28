#!/usr/bin/env bash
# shellcheck shell=bash

firewall_snapshot_dir() { printf '%s/firewall\n' "$SBM_VAR"; }

firewall_snapshot_iptables() {
  local dir=$1 stamp=$2 tool
  mkdir -p "$dir"
  chmod 0700 "$dir" 2>/dev/null || true
  for tool in iptables ip6tables; do
    if command_exists "${tool}-save"; then
      "${tool}-save" >"$dir/${stamp}-${tool}.rules" 2>/dev/null || true
      chmod 0600 "$dir/${stamp}-${tool}.rules" 2>/dev/null || true
    fi
  done
}

firewall_list_protocol_ports() {
  local node id protocol name enabled port kind route public_port
  printf '%-18s %-18s %-8s %-6s %-8s %s\n' 'ID' '协议' '状态' '协议' '端口' '客户端地址'
  printf '%-18s %-18s %-8s %-6s %-8s %s\n' '------------------' '------------------' '--------' '------' '--------' '------------'
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    id=$(jq -r '.id' <<<"$node")
    protocol=$(jq -r '.protocol' <<<"$node")
    name=$(node_protocol_label "$protocol")
    enabled=$(jq -r 'if .enabled then "启用" else "停用" end' <<<"$node")
    port=$(jq -r '.port' <<<"$node")
    if [[ "$enabled" == 启用 ]] && declare -F nginx_stream_route_for_node >/dev/null 2>&1 && nginx_stream_state_enabled "$SBM_STATE"; then
      route=$(nginx_stream_route_for_node "$SBM_STATE" "$id")
      if [[ -n "$route" ]]; then port=$(jq -r '.nginx_stream.port' "$SBM_STATE"); fi
    fi
    while IFS= read -r kind; do
      printf '%-18s %-18s %-8s %-6s %-8s %s\n' "$id" "$name" "$enabled" "${kind^^}" "$port" "$(jq -r '(.domain // .server_address // .client_address // "-")' <<<"$node")"
    done < <(node_transport_kinds "$node")
  done < <(state_list_nodes)
}

firewall_collect_protocol_ports() {
  local node id port kind route
  while IFS= read -r node; do
    [[ -n "$node" && $(jq -r '.enabled' <<<"$node") == true ]] || continue
    id=$(jq -r '.id' <<<"$node")
    port=$(jq -r '.port' <<<"$node")
    if declare -F nginx_stream_route_for_node >/dev/null 2>&1 && nginx_stream_state_enabled "$SBM_STATE"; then
      route=$(nginx_stream_route_for_node "$SBM_STATE" "$id")
      [[ -z "$route" ]] || port=$(jq -r '.nginx_stream.port' "$SBM_STATE")
    fi
    while IFS= read -r kind; do printf '%s\t%s\n' "$port" "$kind"; done < <(node_transport_kinds "$node")
  done < <(state_list_nodes)
}

firewall_ufw_allow_protocol_ports() {
  local assume_yes=${1:-0} port kind count=0
  command_exists ufw || die '未安装 UFW；请使用发行版包管理器安装（Alpine：apk add ufw）。'
  if [[ "$assume_yes" != 1 ]]; then
    confirm '将为所有启用协议端口执行 UFW allow，继续？' N || return 0
  fi
  while IFS=$'\t' read -r port kind; do
    [[ -n "$port" && -n "$kind" ]] || continue
    ufw allow "${port}/${kind}" >/dev/null
    log_ok "UFW 已允许 ${port}/${kind^^}"
    count=$((count + 1))
  done < <(firewall_collect_protocol_ports | sort -u)
  (( count > 0 )) || log_warn '没有启用中的协议端口可加入 UFW。'
}

firewall_is_blanket_deny() {
  local target='' token skip=0
  for token in "$@"; do
    if (( skip == 1 )); then skip=0; continue; fi
    case "$token" in
      -j) continue;;
      DROP|REJECT) target=$token;;
      --reject-with) skip=1;;
      --reject-with=*) continue;;
      *) return 1;;
    esac
  done
  [[ "$target" == DROP || "$target" == REJECT ]]
}

firewall_clear_iptables_input_deny() {
  local assume_yes=${1:-0} stamp dir tool line policy spec changed=0
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die '清理 iptables 规则需要 root 权限。'
  if [[ "$assume_yes" != 1 ]]; then
    confirm '将备份并移除 INPUT 链的全局 DROP/REJECT，必要时把策略改为 ACCEPT，继续？' N || return 0
  fi
  command_exists iptables || die '未找到 iptables。'
  stamp=$(now_stamp); dir=$(firewall_snapshot_dir); firewall_snapshot_iptables "$dir" "$stamp"
  printf 'iptables 规则备份：%s/%s-{iptables,ip6tables}.rules\n' "$dir" "$stamp"
  for tool in iptables ip6tables; do
    command_exists "$tool" || continue
    mapfile -t lines < <("$tool" -S INPUT 2>/dev/null || true)
    for line in "${lines[@]}"; do
      [[ "$line" == -A\ INPUT\ * ]] || continue
      read -r -a spec <<<"${line#-A INPUT }"
      firewall_is_blanket_deny "${spec[@]}" || continue
      "$tool" -D INPUT "${spec[@]}" || true
      log_ok "已移除 ${tool} INPUT 全局 ${spec[*]}"
      changed=1
    done
    policy=$("$tool" -S INPUT 2>/dev/null | awk '$1=="-P" && $2=="INPUT" {print $3; exit}')
    if [[ "$policy" == DROP || "$policy" == REJECT ]]; then
      "$tool" -P INPUT ACCEPT
      log_ok "已将 ${tool} INPUT 默认策略改为 ACCEPT（原策略：$policy）"
      changed=1
    fi
  done
  (( changed == 1 )) || log_warn '未发现 INPUT 链的全局 DROP/REJECT；规则未改变。'
}
