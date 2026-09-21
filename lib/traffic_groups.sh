#!/usr/bin/env bash
# shellcheck shell=bash

traffic_groups_validate() {
  jq -e '. as $state | (.traffic_groups // []) as $groups |
    ($groups|type=="array" and length<=64) and
    (($groups|map(.id)|unique|length)==($groups|length)) and
    (($groups|[.[].nodes[]]|unique|length)==($groups|[.[].nodes[]]|length)) and
    all($groups[]; . as $g |
      (.id|type=="string" and test("^[a-z0-9][a-z0-9._-]{0,47}$")) and
      (.quota_bytes|type=="number" and floor==. and .>=1 and .<=9000000000000000) and
      (.quota_mode|IN("total","download")) and
      (.reset_day|type=="number" and floor==. and .>=1 and .<=28) and
      (.nodes|type=="array" and length>0 and length<=128) and
      all(.nodes[]; . as $id | any($state.nodes[]; .id==$id and .traffic.configured and .traffic.enabled)))' "$1" >/dev/null || {
    log_error '共享配额组无效：成员必须存在且启用流量统计，每个节点只能属于一个组。'; return 1;
  }
}

traffic_group_prefix() { printf 'g_%s\n' "$(printf '%s' "$1" | sha256sum | cut -c1-16)"; }

traffic_group_usage_put() {
  local file=$1 id=$2 cycle=$3 up=$4 down=$5 tmp
  tmp=$(mktemp "$(dirname "$file")/.group-usage.XXXXXX") || return 1
  if ! jq --arg id "$id" --argjson cycle "$cycle" --argjson up "$up" --argjson down "$down" \
    '.groups[$id]={cycle_id:$cycle,upload_bytes:$up,download_bytes:$down}' "$file" >"$tmp" ||
    ! chmod 0600 "$tmp" || ! mv "$tmp" "$file"; then rm -f "$tmp"; return 1; fi
}

traffic_groups_checkpoint() {
  local group id prefix cycle up down table=0
  traffic_nft_table_exists && table=1
  while IFS= read -r group; do
    id=$(jq -r '.id' <<<"$group"); prefix=$(traffic_group_prefix "$id")
    cycle=$(jq -r --arg id "$id" '.groups[$id].cycle_id // 0' "$SBM_TRAFFIC_USAGE")
    (( cycle != 0 )) || cycle=$(traffic_cycle_id "$(jq -r '.reset_day' <<<"$group")")
    up=$(jq -r --arg id "$id" '.groups[$id].upload_bytes // 0' "$SBM_TRAFFIC_USAGE")
    down=$(jq -r --arg id "$id" '.groups[$id].download_bytes // 0' "$SBM_TRAFFIC_USAGE")
    if (( table )); then
      up=$(traffic_nft_counter_bytes "${prefix}_up" || printf '%s' "$up")
      down=$(traffic_nft_counter_bytes "${prefix}_down" || printf '%s' "$down")
    fi
    traffic_group_usage_put "$SBM_TRAFFIC_USAGE" "$id" "$cycle" "$up" "$down" || return 1
  done < <(jq -c '.traffic_groups[]?' "$SBM_STATE")
}

traffic_groups_reset_due() {
  local group id cycle previous
  while IFS= read -r group; do
    id=$(jq -r '.id' <<<"$group"); cycle=$(traffic_cycle_id "$(jq -r '.reset_day' <<<"$group")")
    previous=$(jq -r --arg id "$id" '.groups[$id].cycle_id // 0' "$SBM_TRAFFIC_USAGE")
    if [[ "$cycle" != "$previous" ]]; then
      traffic_group_usage_put "$SBM_TRAFFIC_USAGE" "$id" "$cycle" 0 0 || return 1
      TRAFFIC_RESET_CHANGED=1
    fi
  done < <(jq -c '.traffic_groups[]?' "$SBM_STATE")
}

traffic_groups_render_objects() {
  local group id prefix up down used quota mode
  while IFS= read -r group; do
    id=$(jq -r '.id' <<<"$group"); prefix=$(traffic_group_prefix "$id")
    quota=$(jq -r '.quota_bytes' <<<"$group"); mode=$(jq -r '.quota_mode' <<<"$group")
    up=$(jq -r --arg id "$id" '.groups[$id].upload_bytes // 0' "$SBM_TRAFFIC_USAGE")
    down=$(jq -r --arg id "$id" '.groups[$id].download_bytes // 0' "$SBM_TRAFFIC_USAGE")
    used=$down; [[ "$mode" != total ]] || used=$((up+down)); (( used <= quota )) || used=$quota
    printf 'add counter inet %s %s_up { packets 0 bytes %s }\n' "$SBM_TRAFFIC_TABLE" "$prefix" "$up"
    printf 'add counter inet %s %s_down { packets 0 bytes %s }\n' "$SBM_TRAFFIC_TABLE" "$prefix" "$down"
    printf 'add quota inet %s %s_quota { over %s bytes used %s bytes }\n' "$SBM_TRAFFIC_TABLE" "$prefix" "$quota" "$used"
  done < <(jq -c '.traffic_groups[]?' "$SBM_STATE")
}

traffic_groups_runtime_complete() {
  local id prefix
  while IFS= read -r id; do
    prefix=$(traffic_group_prefix "$id")
    traffic_nft_object_exists counter "${prefix}_up" && traffic_nft_object_exists counter "${prefix}_down" &&
      traffic_nft_object_exists quota "${prefix}_quota" || return 1
  done < <(jq -r '.traffic_groups[]?.id' "$SBM_STATE")
}

_traffic_group_set() {
  local id=$1 members=$2 quota=$3 day=$4 mode=$5 candidate nodes
  validate_node_id "$id" || usage_die '配额组 ID 无效。'
  quota=$(traffic_parse_size "$quota") || usage_die '共享配额必须是正数，例如 500G。'
  [[ "$day" =~ ^[1-9][0-9]?$ ]] && (( day <= 28 )) || usage_die '重置日必须为 1–28。'
  [[ "$mode" == total || "$mode" == download ]] || usage_die '配额模式必须为 total 或 download。'
  nodes=$(jq -cn --arg nodes "$members" '$nodes|split(",")') || return 1
  candidate=$(state_candidate) || return 1
  jq --arg id "$id" --argjson nodes "$nodes" --argjson quota "$quota" --argjson day "$day" --arg mode "$mode" '
    .traffic_groups=((.traffic_groups // [])|map(select(.id!=$id)))+[{id:$id,nodes:$nodes,quota_bytes:$quota,reset_day:$day,quota_mode:$mode}]
    | .nodes |= map(if (.id as $id|$nodes|index($id))!=null then .traffic.configured=true | .traffic.enabled=true else . end)' "$SBM_STATE" >"$candidate" || return 1
  traffic_groups_validate "$candidate" || { rm -f "$candidate"; return 1; }
  if [[ ${SBM_DRY_RUN:-0} == 1 ]]; then config_preview_candidate "$candidate"; rm -f "$candidate"; return; fi
  # Preserve this cycle when changing membership, mode, quota or reset day.
  traffic_checkpoint_unlocked || return 1
  traffic_reset_due_unlocked || return 1
  [[ "$SBM_SKIP_INIT" == 1 || "$TRAFFIC_RESET_CHANGED" == 0 ]] || traffic_apply_unlocked || return 1
  if ! jq -e --arg id "$id" 'any(.traffic_groups[]?;.id==$id)' "$SBM_STATE" >/dev/null &&
    [[ $(jq -r --arg id "$id" '.groups[$id].cycle_id // 0' "$SBM_TRAFFIC_USAGE") != "$(traffic_cycle_id "$day")" ]]; then
    traffic_group_usage_put "$SBM_TRAFFIC_USAGE" "$id" "$(traffic_cycle_id "$day")" 0 0 || return 1
  fi
  traffic_group_usage_put "$SBM_TRAFFIC_USAGE" "$id" "$(traffic_cycle_id "$day")" \
    "$(jq -r --arg id "$id" '.groups[$id].upload_bytes // 0' "$SBM_TRAFFIC_USAGE")" \
    "$(jq -r --arg id "$id" '.groups[$id].download_bytes // 0' "$SBM_TRAFFIC_USAGE")" || return 1
  if ! apply_candidate_state "$candidate" "group-$id"; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  log_ok "共享流量配额已更新：$id"
}

_traffic_group_remove() {
  local id=$1 candidate
  jq -e --arg id "$id" 'any(.traffic_groups[]?;.id==$id)' "$SBM_STATE" >/dev/null || usage_die '配额组不存在。'
  candidate=$(state_candidate) || return 1
  jq --arg id "$id" '.traffic_groups |= map(select(.id!=$id))' "$SBM_STATE" >"$candidate" || return 1
  if ! apply_candidate_state "$candidate" "group-remove-$id"; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  # Keep its usage record; recreating the ID must not silently clear a quota.
}

_traffic_group_reset() {
  local id=$1 day
  day=$(jq -er --arg id "$id" '.traffic_groups[]?|select(.id==$id)|.reset_day' "$SBM_STATE") || usage_die '配额组不存在。'
  traffic_checkpoint_unlocked || return 1
  traffic_group_usage_put "$SBM_TRAFFIC_USAGE" "$id" "$(traffic_cycle_id "$day")" 0 0 || return 1
  [[ "$SBM_SKIP_INIT" == 1 ]] || traffic_apply_unlocked
}

_traffic_group_status() {
  traffic_checkpoint_unlocked || return 1
  traffic_reset_due_unlocked || return 1
  [[ "$SBM_SKIP_INIT" == 1 || "$TRAFFIC_RESET_CHANGED" == 0 ]] || traffic_apply_unlocked || return 1
  jq --slurpfile usage "$SBM_TRAFFIC_USAGE" '[.traffic_groups[]? | . as $g |
    ($usage[0].groups[.id] // {upload_bytes:0,download_bytes:0}) as $u |
    (if .quota_mode=="download" then $u.download_bytes else $u.upload_bytes+$u.download_bytes end) as $used |
    .+{used_bytes:$used,remaining_bytes:([.quota_bytes-$used,0]|max),exhausted:($used>=.quota_bytes)}]' "$SBM_STATE"
}

traffic_group_cli() {
  local action=${1:-status} id='' members='' quota='' day=1 mode=total
  (($# == 0)) || shift
  case "$action" in
    status|list) [[ $# == 0 || ( $# == 1 && "$1" == --json ) ]] || usage_die '用法：sb traffic group status [--json]'; with_lock _traffic_group_status; return;;
    remove|reset)
      [[ $# == 1 ]] || usage_die '用法：sb traffic group remove|reset ID'
      [[ ${SBM_DRY_RUN:-0} == 0 ]] || usage_die '该操作不接受 --dry-run'
      with_state_transaction "group-$action" "_traffic_group_$action" "$1"; return;;
    set) [[ $# -ge 1 ]] || usage_die '缺少配额组 ID'; id=$1; shift;;
    *) usage_die '用法：sb traffic group set|remove|reset|status';;
  esac
  while (($#)); do
    [[ $# -ge 2 ]] || usage_die "参数 $1 缺少值"
    case "$1" in --nodes) members=$2;; --quota) quota=$2;; --reset-day) day=$2;; --quota-mode) mode=$2;; *) usage_die "未知参数：$1";; esac
    shift 2
  done
  [[ -n "$members" && -n "$quota" ]] || usage_die '用法：sb traffic group set ID --nodes NODE1,NODE2 --quota 500G [--reset-day 1] [--quota-mode total|download]'
  if [[ ${SBM_DRY_RUN:-0} == 1 ]]; then with_lock _traffic_group_set "$id" "$members" "$quota" "$day" "$mode"
  else with_state_transaction group-set _traffic_group_set "$id" "$members" "$quota" "$day" "$mode"; fi
}

traffic_group_notifications() {
  local group id quota used cycle threshold key
  [[ $(jq -r '.notifications.enabled // false' "$SBM_STATE") == true ]] || return 0
  notification_events_init_unlocked || return 1
  while IFS= read -r group; do
    id=$(jq -r '.id' <<<"$group"); quota=$(jq -r '.quota_bytes' <<<"$group")
    used=$(jq -r --arg id "$id" --arg mode "$(jq -r '.quota_mode' <<<"$group")" \
      '.groups[$id] // {upload_bytes:0,download_bytes:0}|if $mode=="download" then .download_bytes else .upload_bytes+.download_bytes end' "$SBM_TRAFFIC_USAGE")
    cycle=$(traffic_cycle_id "$(jq -r '.reset_day' <<<"$group")")
    while IFS= read -r threshold; do
      # jq avoids overflowing Bash integer arithmetic for very large counters.
      jq -en --argjson used "$used" --argjson quota "$quota" --argjson threshold "$threshold" '$used/$quota*100 >= $threshold' >/dev/null || continue
      key="traffic-group:$id:$cycle:$threshold"
      jq -e --arg key "$key" '.sent[$key]!=null' "$SBM_NOTIFICATION_EVENTS" >/dev/null && continue
      if notification_send traffic_group "共享配额组 $id 的本周期用量已达到 $threshold%。"; then notification_event_record_unlocked "$key" || return 1; fi
    done < <(jq -r '.notifications.traffic_thresholds[]' "$SBM_STATE")
  done < <(jq -c '.traffic_groups[]?' "$SBM_STATE")
}
