#!/usr/bin/env bash
# shellcheck shell=bash

node_expiry_validate_state() {
  jq -e 'all(.nodes[]?; (.expiry // {at:null,suspended:false,resume_enabled:false}) |
    type=="object" and (.at==null or (.at|type=="number" and floor==. and .>0 and .<=253402300799))
    and (.suspended|type=="boolean") and (.resume_enabled|type=="boolean"))' "$1" >/dev/null || {
    log_error '节点到期策略无效。'; return 1;
  }
}

_node_expiry_set() {
  local id=$1 at=$2 candidate
  state_node_exists "$id" || die "节点不存在：$id"
  candidate=$(state_candidate) || return 1
  jq --arg id "$id" --argjson at "$at" '.nodes |= map(if .id==$id then
    .enabled=(if (.expiry.suspended // false) then (.expiry.resume_enabled // false) else .enabled end)
    | .expiry={at:$at,suspended:false,resume_enabled:false} else . end)' "$SBM_STATE" >"$candidate" || return 1
  if [[ ${SBM_DRY_RUN:-0} == 1 ]]; then config_preview_candidate "$candidate"; rm -f "$candidate"; return; fi
  if ! apply_candidate_state "$candidate" "expiry-$id"; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  log_ok "已更新节点到期策略：$id"
}

node_expiry_set() {
  if [[ ${SBM_DRY_RUN:-0} == 1 ]]; then with_lock _node_expiry_set "$@"
  else with_state_transaction node-expiry _node_expiry_set "$@"; fi
}

_node_expiry_suspend() {
  local now=$1 candidate
  candidate=$(state_candidate) || return 1
  jq --argjson now "$now" '.nodes |= map(if .expiry.at!=null and .expiry.at<=$now and (.expiry.suspended|not) then
    .expiry.resume_enabled=.enabled | .expiry.suspended=true | .enabled=false else . end)' "$SBM_STATE" >"$candidate" || return 1
  if ! apply_candidate_state "$candidate" node-expired; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
}

node_expiry_tick_unlocked() {
  local now row id at key message
  now=$(date +%s)
  if jq -e --argjson now "$now" 'any(.nodes[]?; .expiry.at!=null and .expiry.at<=$now and (.expiry.suspended|not))' "$SBM_STATE" >/dev/null; then
    _state_transaction_run node-expired _node_expiry_suspend "$now" || return 1
  fi
  [[ $(jq -r '.notifications.enabled // false' "$SBM_STATE") == true ]] || return 0
  notification_events_init_unlocked || return 1
  while IFS= read -r row; do
    id=$(jq -r '.id' <<<"$row"); at=$(jq -r '.expiry.at' <<<"$row")
    if (( at <= now )); then key="expiry:$id:$at:expired"; message="节点 $id 已到期，已停用；配置和凭据已保留。"
    else key="expiry:$id:$at:warning"; message="节点 $id 将于 $(jq -nr --argjson at "$at" '$at|todateiso8601') 到期，请及时续期。"; fi
    jq -e --arg key "$key" '.sent[$key]!=null' "$SBM_NOTIFICATION_EVENTS" >/dev/null && continue
    if notification_send node_expiry "$message"; then notification_event_record_unlocked "$key" || return 1; fi
  done < <(jq -c --argjson now "$now" '.nodes[]? | select(.expiry.at!=null and .expiry.at<=$now+259200)' "$SBM_STATE")
}

node_expiry_cli() {
  local id=${1:-} option=${2:-} value=${3:-} at now
  [[ -n "$id" ]] || usage_die '用法：sb node expiry ID [--days N|--at UTC_TIMESTAMP|--clear]'
  state_node_exists "$id" || usage_die "节点不存在：$id"
  if [[ $# == 1 ]]; then state_get_node "$id" | jq '{id,enabled,expiry:(.expiry // {at:null,suspended:false,resume_enabled:false})}'; return; fi
  now=$(date +%s)
  case "$option" in
    --clear) [[ $# == 2 ]] || usage_die '--clear 不接受额外参数'; at=null;;
    --days)
      [[ $# == 3 && "$value" =~ ^[1-9][0-9]{0,3}$ ]] && (( value <= 3650 )) || usage_die '续期天数必须为 1–3650。'
      at=$(jq -r --arg id "$id" --argjson now "$now" '.nodes[]|select(.id==$id)|[.expiry.at // 0,$now]|max' "$SBM_STATE")
      at=$((at + value*86400));;
    --at)
      [[ $# == 3 && "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || usage_die '时间须使用 UTC 格式，如 2027-01-01T00:00:00Z。'
      at=$(jq -ner --arg at "$value" '$at|fromdateiso8601') || usage_die '到期时间无效。'
      (( at > now )) || usage_die '到期时间必须晚于当前时间。';;
    *) usage_die '用法：sb node expiry ID [--days N|--at UTC_TIMESTAMP|--clear]';;
  esac
  node_expiry_set "$id" "$at"
}
