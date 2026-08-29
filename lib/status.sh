#!/usr/bin/env bash
# shellcheck shell=bash

status_service_state() {
  local unit=$1
  if [[ "$SBM_SKIP_INIT" == 1 ]]; then printf 'test\n'
  elif ! service_exists "$unit"; then printf 'not_installed\n'
  elif service_active "$unit"; then printf 'running\n'
  else printf 'stopped\n'; fi
}

status_certificates_json() {
  local cert domain path days valid
  {
    while IFS= read -r cert; do
      [[ -n "$cert" ]] || continue
      domain=$(jq -r '.domain' <<<"$cert")
      path=$(jq -r '.certificate_path // empty' <<<"$cert")
      [[ -s "$path" ]] || path="$SBM_CERTS/$domain/fullchain.pem"
      days=null; valid=false
      if [[ -s "$path" ]] && days=$(x509_days_remaining "$path" 2>/dev/null); then
        (( days >= 0 )) && valid=true
      else
        days=null
      fi
      jq -cn --arg domain "$domain" --arg path "$path" --argjson days "$days" --argjson valid "$valid" \
        '{domain:$domain,path:$path,valid:$valid,days_remaining:$days}'
    done < <(jq -c '.certificates[]?' "$SBM_STATE")
  } | jq -s .
}

status_nodes_json() {
  local traffic_data node runtime_node id kind listening endpoint
  traffic_data=$(traffic_status_json_unlocked all)
  {
    while IFS= read -r node; do
      [[ -n "$node" ]] || continue
      id=$(jq -r '.id' <<<"$node"); runtime_node=$node
      if declare -F nginx_stream_effective_node >/dev/null 2>&1; then runtime_node=$(nginx_stream_effective_node "$SBM_STATE" "$node"); fi
      if [[ $(jq -r '.enabled' <<<"$node") != true ]]; then
        listening=false
      elif [[ "$SBM_SKIP_INIT" == 1 ]]; then
        listening=null
      else
        listening=true
        while IFS= read -r kind; do
          singbox_port_in_use "$kind" "$(jq -r '.port' <<<"$runtime_node")" || listening=false
        done < <(node_transport_kinds "$runtime_node")
      fi
      endpoint=$(jq -r '(.domain // .server_address // .client_address // "")' <<<"$node")
      jq -cn --argjson node "$node" --argjson runtime "$runtime_node" --argjson listening "$listening" \
        --arg endpoint "$endpoint" --argjson traffic "$(jq -c --arg id "$id" '.[]|select(.id==$id)' <<<"$traffic_data")" '
        {id:$node.id,name:$node.name,protocol:$node.protocol,enabled:$node.enabled,listening:$listening,
         listen:$runtime.listen,port:$runtime.port,endpoint:$endpoint,metadata:$node.metadata,
         traffic:($traffic + {percent_used:(if $traffic.quota_bytes==null then null else (($traffic.billable_bytes*10000/$traffic.quota_bytes|floor)/100) end)})}
      '
    done < <(state_list_nodes)
  } | jq -s .
}

status_collect_json_unlocked() {
  local sb_ver cf_ver nodes certs issues enabled_count service_state tunnel_mode nginx_enabled nginx_state tunnel_state
  local ufw_state fail2ban_state traffic_count traffic_state pending=''
  traffic_usage_init_unlocked
  nodes=$(status_nodes_json)
  certs=$(status_certificates_json)
  issues=$(health_collect_json)
  sb_ver=$(core_current_version || true); cf_ver=$(cloudflared_current_version || true)
  enabled_count=$(state_enabled_count)
  if [[ "$SBM_SKIP_INIT" == 1 ]]; then service_state=test
  elif ! state_runtime_required; then service_state=standby
  else service_state=$(status_service_state "$SBM_SERVICE"); fi
  tunnel_mode=$(jq -r '.tunnel.mode' "$SBM_STATE")
  if [[ "$tunnel_mode" == none ]]; then tunnel_state=off; else tunnel_state=$(status_service_state "$SBM_TUNNEL_SERVICE"); fi
  nginx_enabled=$(jq -r '.nginx_stream.enabled // false' "$SBM_STATE")
  if [[ "$nginx_enabled" == true ]]; then nginx_state=$(status_service_state "$SBM_NGINX_STREAM_SERVICE"); else nginx_state=off; fi
  traffic_count=$(jq '[.nodes[]? | select(.traffic.enabled==true)] | length' "$SBM_STATE")
  if (( traffic_count == 0 )); then traffic_state=off
  elif traffic_runtime_complete; then traffic_state=running
  else traffic_state=degraded; fi
  if command_exists ufw; then
    if ufw status 2>/dev/null | grep -qi '^status: active'; then ufw_state=active; else ufw_state=inactive; fi
  else ufw_state=not_installed; fi
  if command_exists fail2ban-client; then
    if fail2ban-client status sshd >/dev/null 2>&1; then fail2ban_state=active; else fail2ban_state=inactive; fi
  else fail2ban_state=not_installed; fi
  if [[ -s "$SBM_VAR/updates/sing-box.json" ]]; then pending=$(jq -r '.latest // ""' "$SBM_VAR/updates/sing-box.json" 2>/dev/null || true); fi
  jq -n --arg now "$(now_iso)" --arg version "$SBM_VERSION" --arg init "$(init_system_label)" \
    --arg sb_ver "$sb_ver" --arg service_state "$service_state" --arg cf_ver "$cf_ver" \
    --arg tunnel_mode "$tunnel_mode" --arg tunnel_state "$tunnel_state" --arg nginx_state "$nginx_state" \
    --argjson nginx_port "$(jq -r '.nginx_stream.port // 443' "$SBM_STATE")" --arg traffic_state "$traffic_state" \
    --argjson traffic_count "$traffic_count" --arg ufw_state "$ufw_state" --arg fail2ban_state "$fail2ban_state" \
    --arg pending "$pending" --argjson enabled_count "$enabled_count" --argjson nodes "$nodes" --argjson certs "$certs" \
    --argjson issues "$issues" --argjson notify "$(notification_status_json)" --argjson health "$(jq -c '.health' "$SBM_STATE")" '
    {manager:{version:$version,checked_at:$now,init_system:$init},
     summary:{nodes:($nodes|length),enabled_nodes:$enabled_count,certificates:($certs|length),issues:($issues|length),
       errors:([$issues[]|select(.severity=="error")]|length),warnings:([$issues[]|select(.severity=="warning")]|length)},
     components:{
       sing_box:{version:(if $sb_ver=="" then null else $sb_ver end),state:$service_state,pending_version:(if $pending=="" then null else $pending end)},
       cloudflared:{version:(if $cf_ver=="" then null else $cf_ver end),mode:$tunnel_mode,state:$tunnel_state},
       nginx_stream:{state:$nginx_state,port:$nginx_port},traffic:{state:$traffic_state,configured_nodes:$traffic_count},
       ufw:{state:$ufw_state},fail2ban:{state:$fail2ban_state},notifications:$notify,health:$health},
     nodes:$nodes,certificates:$certs,issues:$issues}
  '
}

status_json() { with_lock status_collect_json_unlocked; }

status_show() {
  local data row usage quota
  data=$(status_json)
  printf '%sSB Manager %s%s\n' "$C_BOLD" "$(jq -r '.manager.version' <<<"$data")" "$C_RESET"
  printf '服务管理      : %s\n' "$(jq -r '.manager.init_system' <<<"$data")"
  printf 'sing-box     : %s (%s)\n' "$(jq -r '.components.sing_box.version // "未安装"' <<<"$data")" "$(jq -r '.components.sing_box.state' <<<"$data")"
  printf 'cloudflared  : %s (Tunnel: %s/%s)\n' "$(jq -r '.components.cloudflared.version // "未安装"' <<<"$data")" "$(jq -r '.components.cloudflared.mode' <<<"$data")" "$(jq -r '.components.cloudflared.state' <<<"$data")"
  printf 'Nginx Stream : %s (%s/TCP)\n' "$(jq -r '.components.nginx_stream.state' <<<"$data")" "$(jq -r '.components.nginx_stream.port' <<<"$data")"
  printf '安全组件      : UFW %s，Fail2ban %s\n' "$(jq -r '.components.ufw.state' <<<"$data")" "$(jq -r '.components.fail2ban.state' <<<"$data")"
  printf '通知/健康检查 : %s/%s\n' "$(jq -r 'if .components.notifications.enabled then .components.notifications.provider else "off" end' <<<"$data")" "$(jq -r 'if .components.health.enabled then "on" else "off" end' <<<"$data")"
  printf '节点/证书/异常: %s（启用 %s）/%s/%s\n\n' "$(jq -r '.summary.nodes' <<<"$data")" "$(jq -r '.summary.enabled_nodes' <<<"$data")" "$(jq -r '.summary.certificates' <<<"$data")" "$(jq -r '.summary.issues' <<<"$data")"
  printf '%-17s %-15s %-7s %-9s %-10s %-12s %s\n' 'ID' '协议' '状态' '端口' '流量' '地区/标签' '名称'
  while IFS= read -r row; do
    usage=$(jq -r 'if .traffic.percent_used==null then "-" else (.traffic.percent_used|tostring)+"%" end' <<<"$row")
    quota=$(jq -r '([.metadata.region]+.metadata.tags | map(select(length>0)) | join(","))' <<<"$row")
    printf '%-17s %-15s %-7s %-9s %-10s %-12s %s\n' "$(jq -r '.id' <<<"$row")" "$(node_protocol_label "$(jq -r '.protocol' <<<"$row")")" \
      "$(jq -r 'if .enabled then (if .listening==false then "异常" else "启用" end) else "停用" end' <<<"$row")" \
      "$(jq -r '.port' <<<"$row")" "$usage" "${quota:--}" "$(jq -r '.name' <<<"$row")"
  done < <(jq -c '.nodes[]' <<<"$data")
  if [[ $(jq -r '.issues|length' <<<"$data") != 0 ]]; then
    printf '\n待处理异常：\n'
    jq -r '.issues[] | "- [\(.severity)] \(.message)"' <<<"$data"
  fi
}

status_summary() { status_show; }
