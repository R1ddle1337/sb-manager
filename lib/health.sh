#!/usr/bin/env bash
# shellcheck shell=bash

health_issue() {
  jq -cn --arg severity "$1" --arg code "$2" --arg component "$3" --arg message "$4" \
    '{severity:$severity,code:$code,component:$component,message:$message}'
}

health_resource_metrics_json() {
  local disk_used disk_avail disk_pct inode_pct mem_total mem_available mem_pct load cores fd_used fd_max fd_pct banned restarts
  disk_used=0; disk_avail=0; disk_pct=0; inode_pct=0
  disk_pct=$(df -Pk "$SBM_VAR" 2>/dev/null | awk 'NR==2 {print $5}')
  disk_pct=${disk_pct%%%}; [[ "$disk_pct" =~ ^[0-9]+$ ]] || disk_pct=0
  inode_pct=$(df -Pi "$SBM_VAR" 2>/dev/null | awk 'NR==2 {print $5}')
  inode_pct=${inode_pct%%%}; [[ "$inode_pct" =~ ^[0-9]+$ ]] || inode_pct=0
  mem_total=0; mem_available=0
  if [[ -r /proc/meminfo ]]; then
    mem_total=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)
    mem_available=$(awk '/^MemAvailable:/ {print $2; found=1; exit} /^MemFree:/ && !fallback {fallback=$2} END {if (!found) print fallback+0}' /proc/meminfo)
  fi
  if [[ "$mem_total" =~ ^[0-9]+$ && "$mem_total" -gt 0 ]]; then mem_pct=$(( (mem_total-mem_available)*100/mem_total )); else mem_pct=0; fi
  load=$(awk '{print $1}' /proc/loadavg 2>/dev/null || printf '0')
  cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || printf 1)
  [[ "$cores" =~ ^[0-9]+$ && "$cores" -gt 0 ]] || cores=1
  fd_used=0; fd_max=0; fd_pct=0
  if [[ -r /proc/sys/fs/file-nr ]]; then read -r fd_used _ fd_max < /proc/sys/fs/file-nr; fi
  if [[ "$fd_max" =~ ^[0-9]+$ && "$fd_max" -gt 0 ]]; then fd_pct=$((fd_used*100/fd_max)); fi
  banned=0
  if command_exists fail2ban-client; then banned=$(fail2ban-client status sshd 2>/dev/null | awk -F: '/Currently banned/ {gsub(/ /,"",$2); print $2; exit}'); fi
  [[ "$banned" =~ ^[0-9]+$ ]] || banned=0
  restarts=0
  if [[ "$SBM_SKIP_INIT" != 1 ]] && command_exists systemctl; then restarts=$(systemctl show "$SBM_SERVICE" -p NRestarts --value 2>/dev/null || printf 0); fi
  [[ "$restarts" =~ ^[0-9]+$ ]] || restarts=0
  jq -n --argjson disk_used_percent "$disk_pct" --argjson inode_used_percent "$inode_pct" --argjson memory_used_percent "$mem_pct" \
    --arg load "$load" --argjson cpu_cores "$cores" --argjson fd_used "$fd_used" --argjson fd_max "$fd_max" \
    --argjson fd_used_percent "$fd_pct" --argjson fail2ban_banned "$banned" --argjson service_restarts "$restarts" \
    '{disk_used_percent:$disk_used_percent,inode_used_percent:$inode_used_percent,memory_used_percent:$memory_used_percent,
      load_1m:($load|tonumber),cpu_cores:$cpu_cores,file_descriptors:{used:$fd_used,max:$fd_max,used_percent:$fd_used_percent},
      fail2ban_banned:$fail2ban_banned,service_restarts:$service_restarts}'
}

health_resource_issues() {
  local metrics disk_min inode_max mem_max load_max fd_max banned_max restart_max load cores
  metrics=$(health_resource_metrics_json)
  disk_min=$(jq -r '.health.resources.disk_min_free_percent' "$SBM_STATE")
  inode_max=$(jq -r '.health.resources.inode_max_percent' "$SBM_STATE")
  mem_max=$(jq -r '.health.resources.memory_max_percent' "$SBM_STATE")
  load_max=$(jq -r '.health.resources.cpu_load_per_core_max' "$SBM_STATE")
  fd_max=$(jq -r '.health.resources.file_descriptors_max_percent' "$SBM_STATE")
  banned_max=$(jq -r '.health.resources.fail2ban_banned_warn' "$SBM_STATE")
  restart_max=$(jq -r '.health.resources.service_restart_warn' "$SBM_STATE")
  load=$(jq -r '.load_1m' <<<"$metrics"); cores=$(jq -r '.cpu_cores' <<<"$metrics")
  awk -v value="$(jq -r '.disk_used_percent' <<<"$metrics")" -v max="$((100-disk_min))" 'BEGIN {exit !(value > max)}' && health_issue warning resource_disk_low resource "数据目录剩余磁盘空间低于 ${disk_min}%。"
  (( $(jq -r '.inode_used_percent' <<<"$metrics") > inode_max )) && health_issue warning resource_inode_high resource "数据目录 inode 使用率超过 ${inode_max}%。"
  (( $(jq -r '.memory_used_percent' <<<"$metrics") > mem_max )) && health_issue warning resource_memory_high resource "内存使用率超过 ${mem_max}%。"
  awk -v value="$load" -v max="$load_max" -v cores="$cores" 'BEGIN {exit !(value > max*cores)}' && health_issue warning resource_load_high resource "系统 1 分钟负载超过每核 ${load_max}。"
  (( $(jq -r '.file_descriptors.used_percent' <<<"$metrics") > fd_max )) && health_issue warning resource_fd_high resource "系统文件描述符使用率超过 ${fd_max}%。"
  (( $(jq -r '.fail2ban_banned' <<<"$metrics") >= banned_max )) && health_issue warning security_banned_high fail2ban "Fail2ban 当前封禁 IP 数达到 $(jq -r '.fail2ban_banned' <<<"$metrics")。"
  (( $(jq -r '.service_restarts' <<<"$metrics") >= restart_max )) && health_issue warning service_restart_high sing-box "sing-box 累计自动重启次数达到 $(jq -r '.service_restarts' <<<"$metrics")。"
  return 0
}

health_node_runtime() {
  local node=$1 runtime_node kind
  runtime_node=$node
  if declare -F nginx_stream_effective_node >/dev/null 2>&1; then
    runtime_node=$(nginx_stream_effective_node "$SBM_STATE" "$node")
  fi
  while IFS= read -r kind; do
    singbox_port_in_use "$kind" "$(jq -r '.port' <<<"$runtime_node")" || return 1
  done < <(node_transport_kinds "$runtime_node")
}

health_collect_json() {
  local enabled node id cert domain path days warn_days mode
  {
    if [[ "$SBM_SKIP_INIT" != 1 ]]; then
      enabled=$(state_enabled_count)
      if state_runtime_required && ! service_active "$SBM_SERVICE"; then
        health_issue error singbox_inactive sing-box '存在启用节点或 API，但 sing-box 服务未运行。'
      elif (( enabled > 0 )) && service_active "$SBM_SERVICE"; then
        while IFS= read -r node; do
          id=$(jq -r '.id' <<<"$node")
          health_node_runtime "$node" || health_issue error "node_not_listening:$id" node "节点 $id 的监听端口未就绪。"
        done < <(state_enabled_nodes "$SBM_STATE")
      fi
      if [[ $(jq -r '.nginx_stream.enabled // false' "$SBM_STATE") == true ]] && ! service_active "$SBM_NGINX_STREAM_SERVICE"; then
        health_issue error nginx_stream_inactive nginx-stream 'Nginx Stream 已启用但服务未运行。'
      fi
      mode=$(jq -r '.tunnel.mode' "$SBM_STATE")
      if [[ "$mode" != none ]] && ! service_active "$SBM_TUNNEL_SERVICE"; then
        health_issue error tunnel_inactive cloudflared 'Cloudflare Tunnel 已配置但服务未运行。'
      fi
    fi

    warn_days=$(jq -r '.health.certificate_warn_days // 21' "$SBM_STATE")
    while IFS= read -r cert; do
      [[ -n "$cert" ]] || continue
      domain=$(jq -r '.domain' <<<"$cert")
      path=$(jq -r '.certificate_path // empty' <<<"$cert")
      [[ -s "$path" ]] || path="$SBM_CERTS/$domain/fullchain.pem"
      if [[ ! -s "$path" ]]; then
        health_issue error "certificate_missing:$domain" certificate "证书文件缺失：$domain。"
      elif ! days=$(x509_days_remaining "$path" 2>/dev/null); then
        health_issue error "certificate_invalid:$domain" certificate "证书无法解析或已经过期：$domain。"
      elif (( days < 0 )); then
        health_issue error "certificate_expired:$domain" certificate "证书已经过期：$domain。"
      elif (( days <= warn_days )); then
        health_issue warning "certificate_expiring:$domain" certificate "证书 $domain 剩余 $days 天。"
      fi
    done < <(jq -c '.certificates[]?' "$SBM_STATE")

    if command_exists ufw && ! ufw status 2>/dev/null | grep -qi '^status: active'; then
      health_issue warning ufw_inactive ufw 'UFW 已安装但未启用。'
    fi
    if command_exists fail2ban-client && ! fail2ban-client status sshd >/dev/null 2>&1; then
      health_issue warning fail2ban_sshd_inactive fail2ban 'Fail2ban 的 sshd jail 未运行。'
    fi
    if (( $(jq '[.nodes[]? | select(.enabled==true and .traffic.enabled==true)] | length' "$SBM_STATE") > 0 )); then
      if ! command_exists nft; then
        health_issue error traffic_nft_missing traffic '流量控制已启用，但系统缺少 nft。'
      elif ! traffic_runtime_complete; then
        health_issue error traffic_rules_missing traffic '流量控制规则不完整，请运行 sb traffic reconcile。'
      fi
    fi
    health_resource_issues "$SBM_STATE"
  } | jq -s 'sort_by(.severity,.code)'
}

health_result_json() {
  local issues=$1 metrics=${2:-}
  [[ -n "$metrics" ]] || metrics=$(health_resource_metrics_json)
  jq -n --arg now "$(now_iso)" --argjson enabled "$(jq -r '.health.enabled // false' "$SBM_STATE")" --argjson issues "$issues" --argjson metrics "$metrics" '
    {checked_at:$now,monitoring_enabled:$enabled,healthy:([ $issues[] | select(.severity=="error") ] | length == 0),resources:$metrics,issues:$issues,
     summary:{errors:([$issues[]|select(.severity=="error")]|length),warnings:([$issues[]|select(.severity=="warning")]|length)}}
  '
}

health_check() {
  local json=${1:-0} issues result errors
  issues=$(health_collect_json)
  result=$(health_result_json "$issues")
  errors=$(jq -r '.summary.errors' <<<"$result")
  if [[ "$json" == 1 ]]; then
    printf '%s\n' "$result"
  else
    if [[ $(jq -r '.issues|length' <<<"$result") == 0 ]]; then
      check_line PASS '定时健康检查未发现异常。'
    else
      while IFS=$'\t' read -r severity message; do
        if [[ "$severity" == error ]]; then check_line FAIL "$message"; else check_line WARN "$message"; fi
      done < <(jq -r '.issues[] | [.severity,.message] | @tsv' <<<"$result")
    fi
    printf '结果：%s 个错误，%s 个警告。\n' "$errors" "$(jq -r '.summary.warnings' <<<"$result")"
  fi
  (( errors == 0 ))
}

_health_set_enabled() {
  local value=$1 warn_days=${2:-} candidate
  candidate=$(state_candidate)
  if [[ -n "$warn_days" ]]; then
    [[ "$warn_days" =~ ^[0-9]+$ ]] && (( 1 <= 10#$warn_days && 10#$warn_days <= 365 )) || die '证书预警天数必须是 1-365。'
    jq --argjson value "$value" --argjson days "$warn_days" '.health.enabled=$value | .health.certificate_warn_days=$days' "$SBM_STATE" >"$candidate"
  else
    jq --argjson value "$value" '.health.enabled=$value' "$SBM_STATE" >"$candidate"
  fi
  if ! apply_candidate_state "$candidate" health-settings; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  if [[ "$value" == true ]]; then log_ok '定时健康检查已启用。'; else log_ok '定时健康检查已停用。'; fi
}
health_enable() { with_state_transaction health-enable _health_set_enabled true "${1:-}"; }
health_disable() { with_state_transaction health-disable _health_set_enabled false; }

_health_configure_resources() {
  local candidate key value jq_filter='.'
  while (($#)); do
    key=$1; value=${2:?缺少阈值}; shift 2
    case "$key" in
      --disk-free) [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 99 )) || die '磁盘剩余阈值必须是 1-99。'; jq_filter+=" | .health.resources.disk_min_free_percent=$value" ;;
      --inode-max) [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 100 )) || die 'inode 阈值必须是 1-100。'; jq_filter+=" | .health.resources.inode_max_percent=$value" ;;
      --memory-max) [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 100 )) || die '内存阈值必须是 1-100。'; jq_filter+=" | .health.resources.memory_max_percent=$value" ;;
      --load-per-core) [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || die '负载阈值必须是数字。'; jq_filter+=" | .health.resources.cpu_load_per_core_max=$value" ;;
      --fd-max) [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 100 )) || die '文件描述符阈值必须是 1-100。'; jq_filter+=" | .health.resources.file_descriptors_max_percent=$value" ;;
      --banned-warn) [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 )) || die '封禁数量阈值必须大于 0。'; jq_filter+=" | .health.resources.fail2ban_banned_warn=$value" ;;
      --restart-warn) [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 )) || die '重启次数阈值必须大于 0。'; jq_filter+=" | .health.resources.service_restart_warn=$value" ;;
      *) die "未知健康阈值参数：$key" ;;
    esac
  done
  candidate=$(state_candidate); jq "$jq_filter" "$SBM_STATE" >"$candidate"
  if ! apply_candidate_state "$candidate" health-resources; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"; log_ok '资源与安全告警阈值已更新。'
}
health_configure_resources() { with_state_transaction health-resources _health_configure_resources "$@"; }

health_events_init_unlocked() {
  local tmp
  if [[ -s "$SBM_HEALTH_EVENTS" ]] && jq -e '.schema_version==1 and (.active|type=="array")' "$SBM_HEALTH_EVENTS" >/dev/null 2>&1; then return 0; fi
  tmp=$(mktemp "$SBM_VAR/.health-events.XXXXXX")
  jq -n '{schema_version:1,last_checked:null,active:[]}' >"$tmp"
  chmod 0600 "$tmp"; mv -f "$tmp" "$SBM_HEALTH_EVENTS"
}

health_write_events_unlocked() {
  local active_json=$1 tmp
  tmp=$(mktemp "$SBM_VAR/.health-events.XXXXXX")
  jq --arg now "$(now_iso)" --argjson active "$active_json" '.last_checked=$now | .active=$active' "$SBM_HEALTH_EVENTS" >"$tmp"
  chmod 0600 "$tmp"; mv -f "$tmp" "$SBM_HEALTH_EVENTS"
}

health_tick_unlocked() {
  local issues result old_active new_active new_codes resolved_codes message sent=0 tmp
  [[ $(jq -r '.health.enabled // false' "$SBM_STATE") == true ]] || return 0
  issues=$(health_collect_json)
  result=$(health_result_json "$issues")
  tmp=$(mktemp "$SBM_VAR/.health-report.XXXXXX")
  printf '%s\n' "$result" >"$tmp"; chmod 0600 "$tmp"; mv -f "$tmp" "$SBM_HEALTH_REPORT"
  health_events_init_unlocked
  old_active=$(jq -c '.active | sort' "$SBM_HEALTH_EVENTS")
  new_active=$(jq -c '[.issues[].code] | unique | sort' <<<"$result")
  if [[ "$old_active" != "$new_active" && $(jq -r '.notifications.enabled // false' "$SBM_STATE") == true ]]; then
    new_codes=$(jq -r --argjson old "$old_active" '[.issues[] | select((.code as $c | $old | index($c)) == null) | .message] | join("；")' <<<"$result")
    resolved_codes=$(jq -rn --argjson old "$old_active" --argjson new "$new_active" '$old | map(select(. as $c | $new | index($c) == null)) | join("、")')
    message='sb-manager 健康检查状态变化。'
    [[ -z "$new_codes" ]] || message+=" 新异常：$new_codes。"
    [[ -z "$resolved_codes" ]] || message+=" 已恢复：$resolved_codes。"
    if notification_send health "$message"; then sent=1; else log_warn '健康检查通知发送失败，下一轮将重试。'; fi
  fi
  if [[ "$old_active" == "$new_active" || "$sent" == 1 ]]; then
    health_write_events_unlocked "$new_active"
  else
    health_write_events_unlocked "$old_active"
  fi
}

health_tick() { with_lock health_tick_unlocked; }

health_status() {
  local json=${1:-0} last='null' metrics
  [[ -s "$SBM_HEALTH_REPORT" ]] && last=$(jq -c . "$SBM_HEALTH_REPORT" 2>/dev/null || printf null)
  if [[ "$json" == 1 ]]; then
    jq --argjson last "$last" --argjson metrics "$(health_resource_metrics_json)" '.health + {resources_current:$metrics,last_report:$last}' "$SBM_STATE"
  else
    metrics=$(health_resource_metrics_json)
    printf '定时健康检查：%s\n' "$([[ $(jq -r '.health.enabled' "$SBM_STATE") == true ]] && printf '启用' || printf '停用')"
    printf '证书预警天数：%s\n' "$(jq -r '.health.certificate_warn_days' "$SBM_STATE")"
    printf '资源：磁盘 %s%%，内存 %s%%，负载 %s/%s 核，文件描述符 %s%%，Fail2ban 封禁 %s\n' \
      "$(jq -r '.disk_used_percent' <<<"$metrics")" "$(jq -r '.memory_used_percent' <<<"$metrics")" \
      "$(jq -r '.load_1m' <<<"$metrics")" "$(jq -r '.cpu_cores' <<<"$metrics")" \
      "$(jq -r '.file_descriptors.used_percent' <<<"$metrics")" "$(jq -r '.fail2ban_banned' <<<"$metrics")"
    if [[ "$last" != null ]]; then jq -r '"上次检查：\(.checked_at)，错误 \(.summary.errors)，警告 \(.summary.warnings)"' <<<"$last"; else printf '上次检查：尚未执行\n'; fi
  fi
}
