#!/usr/bin/env bash
# shellcheck shell=bash

traffic_validate_table_name() {
  [[ "$SBM_TRAFFIC_TABLE" =~ ^[a-zA-Z_][a-zA-Z0-9_]{0,47}$ ]]
}

traffic_usage_validate() {
  local file=$1
  jq -e '
    type == "object"
    and .schema_version == 1
    and (.updated_at | type == "string")
    and (.nodes | type == "object")
    and all(.nodes[];
      type == "object"
      and (.cycle_id | type == "number" and floor == . and . >= 1)
      and (.upload_bytes | type == "number" and floor == . and . >= 0 and . <= 9000000000000000)
      and (.download_bytes | type == "number" and floor == . and . >= 0 and . <= 9000000000000000))
  ' "$file" >/dev/null 2>&1
}

traffic_usage_init_unlocked() {
  local tmp
  mkdir -p "$(dirname "$SBM_TRAFFIC_USAGE")"
  if [[ -e "$SBM_TRAFFIC_USAGE" ]]; then
    traffic_usage_validate "$SBM_TRAFFIC_USAGE" || die "流量用量账本损坏：$SBM_TRAFFIC_USAGE"
    return 0
  fi
  tmp=$(mktemp "$(dirname "$SBM_TRAFFIC_USAGE")/.traffic-usage.XXXXXX")
  jq -n --arg now "$(now_iso)" '{schema_version:1,updated_at:$now,nodes:{}}' >"$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$SBM_TRAFFIC_USAGE"
}

traffic_cycle_id() {
  local reset_day=$1 year month day
  year=$(date -u +%Y); month=$(date -u +%m); day=$(date -u +%d)
  printf '%d\n' "$((10#$year * 12 + 10#$month - (10#$day < 10#$reset_day ? 1 : 0)))"
}

traffic_object_prefix() {
  local id=$1 digest
  digest=$(printf '%s' "$id" | sha256sum | awk '{print substr($1,1,16)}')
  printf 'sbm_%s\n' "$digest"
}

traffic_parse_size() {
  local raw=${1^^} number unit multiplier max=9000000000000000
  raw=${raw//[[:space:]]/}
  [[ "$raw" =~ ^([1-9][0-9]*)(B|K|KB|KIB|M|MB|MIB|G|GB|GIB|T|TB|TIB|P|PB|PIB)?$ ]] || return 1
  number=${BASH_REMATCH[1]}; unit=${BASH_REMATCH[2]:-B}
  ((${#number} <= 16)) || return 1
  case "$unit" in
    B) multiplier=1 ;;
    K|KB|KIB) multiplier=1024 ;;
    M|MB|MIB) multiplier=1048576 ;;
    G|GB|GIB) multiplier=1073741824 ;;
    T|TB|TIB) multiplier=1099511627776 ;;
    P|PB|PIB) multiplier=1125899906842624 ;;
  esac
  (( 10#$number <= max / multiplier )) || return 1
  printf '%d\n' "$((10#$number * multiplier))"
}

traffic_parse_rate() {
  local raw=${1^^} number unit multiplier max=1000000000000
  raw=${raw//[[:space:]]/}; raw=${raw//BIT\/S/BPS}; raw=${raw//BITS\/S/BPS}
  [[ "$raw" =~ ^([1-9][0-9]*)(BPS|K|M|G|KBPS|MBPS|GBPS)?$ ]] || return 1
  number=${BASH_REMATCH[1]}; unit=${BASH_REMATCH[2]:-M}
  ((${#number} <= 13)) || return 1
  case "$unit" in
    BPS) multiplier=1 ;;
    K|KBPS) multiplier=1000 ;;
    M|MBPS) multiplier=1000000 ;;
    G|GBPS) multiplier=1000000000 ;;
  esac
  (( 10#$number <= max / multiplier )) || return 1
  printf '%d\n' "$((10#$number * multiplier))"
}

traffic_nullable_size() {
  local value=${1,,}
  case "$value" in unlimited|none|off|0) printf 'null\n';; *) traffic_parse_size "$1";; esac
}

traffic_nullable_rate() {
  local value=${1,,}
  case "$value" in unlimited|none|off|0) printf 'null\n';; *) traffic_parse_rate "$1";; esac
}

traffic_format_bytes() {
  local bytes=${1:-0}
  awk -v n="$bytes" 'BEGIN {
    split("B KiB MiB GiB TiB PiB", u, " "); i=1;
    while (n >= 1024 && i < 6) {n/=1024; i++}
    if (i == 1) printf "%.0f %s", n, u[i]; else printf "%.2f %s", n, u[i]
  }'
}

traffic_format_rate() {
  local bps=${1:-null}
  [[ "$bps" != null ]] || { printf '不限'; return; }
  awk -v n="$bps" 'BEGIN {
    split("bit/s Kbit/s Mbit/s Gbit/s Tbit/s", u, " "); i=1;
    while (n >= 1000 && i < 5) {n/=1000; i++}
    if (n == int(n)) printf "%.0f %s", n, u[i]; else printf "%.2f %s", n, u[i]
  }'
}

traffic_nft_table_exists() {
  command_exists nft && nft list table inet "$SBM_TRAFFIC_TABLE" >/dev/null 2>&1
}

traffic_nft_counter_bytes() {
  local name=$1 value
  value=$(nft -j list counter inet "$SBM_TRAFFIC_TABLE" "$name" 2>/dev/null | jq -r --arg name "$name" '
    [.nftables[]?.counter? | select(.name==$name) | .bytes] | first // empty
  ') || return 1
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$value"
}

traffic_nft_object_exists() {
  local type=$1 name=$2
  nft list "$type" inet "$SBM_TRAFFIC_TABLE" "$name" >/dev/null 2>&1
}

traffic_runtime_complete() {
  local node id prefix quota upload_rate download_rate
  traffic_nft_table_exists || return 1
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    id=$(jq -r '.id' <<<"$node"); prefix=$(traffic_object_prefix "$id")
    traffic_nft_object_exists counter "${prefix}_up" || return 1
    traffic_nft_object_exists counter "${prefix}_down" || return 1
    quota=$(jq -r '.traffic.quota_bytes' <<<"$node")
    upload_rate=$(jq -r '.traffic.upload_rate_bps' <<<"$node")
    download_rate=$(jq -r '.traffic.download_rate_bps' <<<"$node")
    [[ "$quota" == null ]] || traffic_nft_object_exists quota "${prefix}_quota" || return 1
    [[ "$upload_rate" == null ]] || traffic_nft_object_exists limit "${prefix}_up_rate" || return 1
    [[ "$download_rate" == null ]] || traffic_nft_object_exists limit "${prefix}_down_rate" || return 1
  done < <(jq -c '.nodes[]? | select(.enabled==true and .traffic.enabled==true)' "$SBM_STATE")
}

traffic_usage_put_node() {
  local file=$1 id=$2 cycle=$3 upload=$4 download=$5 next
  next=$(mktemp "$(dirname "$file")/.traffic-node.XXXXXX")
  jq --arg id "$id" --argjson cycle "$cycle" --argjson upload "$upload" --argjson download "$download" '
    .nodes[$id]={cycle_id:$cycle,upload_bytes:$upload,download_bytes:$download}
  ' "$file" >"$next"
  chmod 0600 "$next"
  mv -f "$next" "$file"
}

traffic_checkpoint_unlocked() {
  local tmp next node id reset_day cycle stored_cycle upload download prefix table_present=0
  traffic_usage_init_unlocked
  traffic_validate_table_name || die "无效 nftables 表名：$SBM_TRAFFIC_TABLE"
  if traffic_nft_table_exists; then table_present=1; fi
  tmp=$(mktemp "$(dirname "$SBM_TRAFFIC_USAGE")/.traffic-checkpoint.XXXXXX")
  cp -f "$SBM_TRAFFIC_USAGE" "$tmp"
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    id=$(jq -r '.id' <<<"$node"); reset_day=$(jq -r '.traffic.reset_day' <<<"$node")
    cycle=$(traffic_cycle_id "$reset_day")
    stored_cycle=$(jq -r --arg id "$id" '.nodes[$id].cycle_id // 0' "$tmp")
    (( stored_cycle > 0 )) || stored_cycle=$cycle
    upload=$(jq -r --arg id "$id" '.nodes[$id].upload_bytes // 0' "$tmp")
    download=$(jq -r --arg id "$id" '.nodes[$id].download_bytes // 0' "$tmp")
    if (( table_present )); then
      prefix=$(traffic_object_prefix "$id")
      upload=$(traffic_nft_counter_bytes "${prefix}_up" 2>/dev/null || printf '%s' "$upload")
      download=$(traffic_nft_counter_bytes "${prefix}_down" 2>/dev/null || printf '%s' "$download")
    fi
    traffic_usage_put_node "$tmp" "$id" "$stored_cycle" "$upload" "$download"
  done < <(jq -c '.nodes[]? | select(.traffic.configured==true)' "$SBM_STATE")
  next=$(mktemp "$(dirname "$SBM_TRAFFIC_USAGE")/.traffic-prune.XXXXXX")
  jq --slurpfile state "$SBM_STATE" --arg now "$(now_iso)" '
    .updated_at=$now
    | .nodes |= with_entries(select(.key as $id | $state[0].nodes | any(.id==$id and .traffic.configured==true)))
  ' "$tmp" >"$next"
  chmod 0600 "$next"
  mv -f "$next" "$SBM_TRAFFIC_USAGE"
  rm -f "$tmp"
}

traffic_validate_state() {
  local state=$1
  jq -e '
    all(.nodes[]?;
      if .traffic.configured then true
      else
        .traffic.enabled == false
        and .traffic.quota_bytes == null
        and .traffic.quota_mode == "total"
        and .traffic.reset_day == 1
        and .traffic.upload_rate_bps == null
        and .traffic.download_rate_bps == null
      end)
  ' "$state" >/dev/null || die '节点流量控制状态无效。'
}

traffic_reset_due_unlocked() {
  local node id reset_day current stored changed=0
  TRAFFIC_RESET_CHANGED=0
  traffic_usage_init_unlocked
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    id=$(jq -r '.id' <<<"$node"); reset_day=$(jq -r '.traffic.reset_day' <<<"$node")
    current=$(traffic_cycle_id "$reset_day")
    stored=$(jq -r --arg id "$id" '.nodes[$id].cycle_id // 0' "$SBM_TRAFFIC_USAGE")
    if [[ "$stored" != "$current" ]]; then
      traffic_usage_put_node "$SBM_TRAFFIC_USAGE" "$id" "$current" 0 0
      changed=1
      TRAFFIC_RESET_CHANGED=1
      log_info "已按每月 ${reset_day} 日策略重置流量统计：$id"
    fi
  done < <(jq -c '.nodes[]? | select(.traffic.configured==true)' "$SBM_STATE")
  (( changed == 0 )) || chmod 0600 "$SBM_TRAFFIC_USAGE"
}

traffic_active_count() {
  jq '[.nodes[]? | select(.enabled==true and .traffic.enabled==true)] | length' "$SBM_STATE"
}

traffic_emit_match_rules() {
  local chain=$1 kind=$2 direction=$3 port=$4 counter=$5 quota=${6:-} limit=${7:-} loopback=${8:-0}
  local port_expr match_prefix=''
  if [[ "$direction" == upload ]]; then port_expr="dport $port"; else port_expr="sport $port"; fi
  if [[ "$loopback" == 1 ]]; then match_prefix='oifname "lo" '; fi
  printf 'add rule inet %s %s %smeta l4proto %s %s %s counter name %s\n' \
    "$SBM_TRAFFIC_TABLE" "$chain" "$match_prefix" "$kind" "$kind" "$port_expr" "$counter"
  if [[ -n "$quota" ]]; then
    printf 'add rule inet %s %s %smeta l4proto %s %s %s quota name %s drop\n' \
      "$SBM_TRAFFIC_TABLE" "$chain" "$match_prefix" "$kind" "$kind" "$port_expr" "$quota"
  fi
  if [[ -n "$limit" ]]; then
    printf 'add rule inet %s %s %smeta l4proto %s %s %s limit name %s drop\n' \
      "$SBM_TRAFFIC_TABLE" "$chain" "$match_prefix" "$kind" "$kind" "$port_expr" "$limit"
  fi
}

traffic_render_nft_script() {
  local table_exists=${1:-0}
  local node runtime_node id port prefix upload download total quota quota_mode upload_rate download_rate loopback
  local upload_bytes download_bytes upload_burst download_burst quota_name quota_used upload_limit download_limit kind
  (( table_exists == 0 )) || printf 'delete table inet %s\n' "$SBM_TRAFFIC_TABLE"
  printf 'add table inet %s\n' "$SBM_TRAFFIC_TABLE"
  printf 'add chain inet %s input { type filter hook input priority 10; policy accept; }\n' "$SBM_TRAFFIC_TABLE"
  printf 'add chain inet %s output { type filter hook output priority 10; policy accept; }\n' "$SBM_TRAFFIC_TABLE"
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    id=$(jq -r '.id' <<<"$node"); runtime_node=$node
    if declare -F nginx_stream_effective_node >/dev/null 2>&1; then
      runtime_node=$(nginx_stream_effective_node "$SBM_STATE" "$node")
    fi
    port=$(jq -r '.port' <<<"$runtime_node"); prefix=$(traffic_object_prefix "$id")
    loopback=0
    if [[ $(jq -r '.listen' <<<"$runtime_node") == 127.0.0.1 ]]; then loopback=1; fi
    upload=$(jq -r --arg id "$id" '.nodes[$id].upload_bytes // 0' "$SBM_TRAFFIC_USAGE")
    download=$(jq -r --arg id "$id" '.nodes[$id].download_bytes // 0' "$SBM_TRAFFIC_USAGE")
    quota=$(jq -r '.traffic.quota_bytes' <<<"$node"); quota_mode=$(jq -r '.traffic.quota_mode' <<<"$node")
    upload_rate=$(jq -r '.traffic.upload_rate_bps' <<<"$node"); download_rate=$(jq -r '.traffic.download_rate_bps' <<<"$node")
    printf 'add counter inet %s %s_up { packets 0 bytes %s }\n' "$SBM_TRAFFIC_TABLE" "$prefix" "$upload"
    printf 'add counter inet %s %s_down { packets 0 bytes %s }\n' "$SBM_TRAFFIC_TABLE" "$prefix" "$download"
    quota_name=''
    if [[ "$quota" != null ]]; then
      if [[ "$quota_mode" == download ]]; then total=$download; else total=$((upload + download)); fi
      quota_used=$total; (( quota_used <= quota )) || quota_used=$quota
      quota_name="${prefix}_quota"
      printf 'add quota inet %s %s { over %s bytes used %s bytes }\n' "$SBM_TRAFFIC_TABLE" "$quota_name" "$quota" "$quota_used"
    fi
    upload_limit=''; download_limit=''
    if [[ "$upload_rate" != null ]]; then
      upload_bytes=$(((upload_rate + 7) / 8)); upload_burst=$((upload_bytes / 10))
      (( upload_burst >= 65536 )) || upload_burst=65536
      (( upload_burst <= 16777216 )) || upload_burst=16777216
      upload_limit="${prefix}_up_rate"
      printf 'add limit inet %s %s { rate over %s bytes/second burst %s bytes ; }\n' "$SBM_TRAFFIC_TABLE" "$upload_limit" "$upload_bytes" "$upload_burst"
    fi
    if [[ "$download_rate" != null ]]; then
      download_bytes=$(((download_rate + 7) / 8)); download_burst=$((download_bytes / 10))
      (( download_burst >= 65536 )) || download_burst=65536
      (( download_burst <= 16777216 )) || download_burst=16777216
      download_limit="${prefix}_down_rate"
      printf 'add limit inet %s %s { rate over %s bytes/second burst %s bytes ; }\n' "$SBM_TRAFFIC_TABLE" "$download_limit" "$download_bytes" "$download_burst"
    fi
    while IFS= read -r kind; do
      if (( loopback )); then
        traffic_emit_match_rules output "$kind" upload "$port" "${prefix}_up" "$([[ "$quota_mode" == total ]] && printf '%s' "$quota_name")" "$upload_limit" 1
      else
        traffic_emit_match_rules input "$kind" upload "$port" "${prefix}_up" "$([[ "$quota_mode" == total ]] && printf '%s' "$quota_name")" "$upload_limit"
      fi
      traffic_emit_match_rules output "$kind" download "$port" "${prefix}_down" "$([[ -n "$quota_name" ]] && printf '%s' "$quota_name")" "$download_limit" "$loopback"
    done < <(node_transport_kinds "$runtime_node")
  done < <(jq -c '.nodes[]? | select(.enabled==true and .traffic.enabled==true)' "$SBM_STATE")
}

traffic_delete_table_unlocked() {
  command_exists nft || return 0
  nft delete table inet "$SBM_TRAFFIC_TABLE" >/dev/null 2>&1 || true
}

traffic_apply_unlocked() {
  local script table_exists=0
  traffic_usage_init_unlocked
  traffic_validate_table_name || die "无效 nftables 表名：$SBM_TRAFFIC_TABLE"
  if (( $(traffic_active_count) == 0 )); then
    traffic_delete_table_unlocked
    return 0
  fi
  if [[ "$SBM_SKIP_INIT" != 1 ]] && ! command_exists nft && declare -F dependency_require_feature >/dev/null 2>&1; then
    dependency_require_feature traffic || die '流量控制需要 nftables；请运行 sb deps install traffic。'
  fi
  require_command nft; require_command sha256sum
  script=$(mktemp "$SBM_RUN/traffic-rules.XXXXXX")
  if traffic_nft_table_exists; then table_exists=1; fi
  traffic_render_nft_script "$table_exists" >"$script"
  if ! nft -c -f "$script" >"$SBM_RUN/traffic-check.log" 2>&1; then
    log_error 'nftables 流量控制规则检查失败：'
    sed -n '1,80p' "$SBM_RUN/traffic-check.log" >&2 || true
    rm -f "$script"
    return 1
  fi
  if ! nft -f "$script" >"$SBM_RUN/traffic-apply.log" 2>&1; then
    log_error 'nftables 流量控制规则应用失败：'
    sed -n '1,80p' "$SBM_RUN/traffic-apply.log" >&2 || true
    rm -f "$script"
    return 1
  fi
  rm -f "$script"
}

traffic_reconcile_unlocked() {
  local checkpoint=${1:-1}
  [[ "$checkpoint" == 0 ]] || traffic_checkpoint_unlocked
  traffic_reset_due_unlocked
  traffic_apply_unlocked
}

traffic_reconcile() { with_lock traffic_reconcile_unlocked 1; }
traffic_checkpoint() { with_lock traffic_checkpoint_unlocked; }

traffic_tick_unlocked() {
  local active table_present=0
  traffic_checkpoint_unlocked
  traffic_reset_due_unlocked
  active=$(traffic_active_count)
  if traffic_nft_table_exists; then table_present=1; fi
  if (( TRAFFIC_RESET_CHANGED == 1 || (active > 0 && table_present == 0) || (active == 0 && table_present == 1) )) \
    || { (( active > 0 )) && ! traffic_runtime_complete; }; then
    traffic_apply_unlocked
  fi
  if declare -F notification_traffic_check_unlocked >/dev/null 2>&1; then
    notification_traffic_check_unlocked || true
  fi
}

traffic_usage_rebase_node_unlocked() {
  local id=$1 reset_day=$2 cycle upload download
  traffic_usage_init_unlocked
  cycle=$(traffic_cycle_id "$reset_day")
  upload=$(jq -r --arg id "$id" '.nodes[$id].upload_bytes // 0' "$SBM_TRAFFIC_USAGE")
  download=$(jq -r --arg id "$id" '.nodes[$id].download_bytes // 0' "$SBM_TRAFFIC_USAGE")
  traffic_usage_put_node "$SBM_TRAFFIC_USAGE" "$id" "$cycle" "$upload" "$download"
  chmod 0600 "$SBM_TRAFFIC_USAGE"
}

_traffic_set() {
  local id=$1; shift
  local node quota reset_day upload_rate download_rate quota_mode candidate value
  state_node_exists "$id" || die "节点不存在：$id"
  node=$(state_get_node "$id")
  quota=$(jq -r '.traffic.quota_bytes' <<<"$node"); reset_day=$(jq -r '.traffic.reset_day' <<<"$node")
  upload_rate=$(jq -r '.traffic.upload_rate_bps' <<<"$node"); download_rate=$(jq -r '.traffic.download_rate_bps' <<<"$node")
  quota_mode=$(jq -r '.traffic.quota_mode' <<<"$node")
  while (($#)); do
    case "$1" in
      --quota)
        value=${2:?缺少配额值}; quota=$(traffic_nullable_size "$value") || die "无效配额：$value（示例：100G、2T、unlimited）"
        shift 2
        ;;
      --reset-day)
        value=${2:?缺少重置日}; [[ "$value" =~ ^[0-9]+$ ]] && (( 1 <= 10#$value && 10#$value <= 28 )) || die '每月重置日必须是 1-28。'
        reset_day=$((10#$value)); shift 2
        ;;
      --rate)
        value=${2:?缺少速率}; value=$(traffic_nullable_rate "$value") || die "无效速率：${2:-}（示例：50M、1Gbps、unlimited）"
        upload_rate=$value; download_rate=$value; shift 2
        ;;
      --upload-rate)
        value=${2:?缺少上行速率}; upload_rate=$(traffic_nullable_rate "$value") || die "无效上行速率：$value"
        shift 2
        ;;
      --download-rate)
        value=${2:?缺少下行速率}; download_rate=$(traffic_nullable_rate "$value") || die "无效下行速率：$value"
        shift 2
        ;;
      --quota-mode)
        quota_mode=${2:?缺少配额统计模式}; [[ "$quota_mode" == total || "$quota_mode" == download ]] || die '配额统计模式必须是 total 或 download。'
        shift 2
        ;;
      --dry-run) export SBM_DRY_RUN=1; shift ;;
      *) die "未知流量控制参数：$1" ;;
    esac
  done
  if [[ "$SBM_SKIP_INIT" != 1 ]] && ! command_exists nft && declare -F dependency_require_feature >/dev/null 2>&1; then
    dependency_require_feature traffic || die '流量控制需要 nftables；请运行 sb deps install traffic。'
  fi
  [[ "$SBM_SKIP_INIT" == 1 ]] || { require_command nft; require_command sha256sum; }
  if [[ ${SBM_DRY_RUN:-0} != 1 ]]; then
    traffic_usage_init_unlocked
  fi
  if [[ ${SBM_DRY_RUN:-0} != 1 && "$SBM_SKIP_INIT" != 1 ]]; then
    traffic_checkpoint_unlocked
    traffic_reset_due_unlocked
  fi
  if [[ "$quota" != null && -s "$SBM_TRAFFIC_USAGE" ]]; then
    local used_upload used_download used_billable
    used_upload=$(jq -r --arg id "$id" '.nodes[$id].upload_bytes // 0' "$SBM_TRAFFIC_USAGE")
    used_download=$(jq -r --arg id "$id" '.nodes[$id].download_bytes // 0' "$SBM_TRAFFIC_USAGE")
    if [[ "$quota_mode" == download ]]; then used_billable=$used_download; else used_billable=$((used_upload + used_download)); fi
    (( quota >= used_billable )) || log_warn "新配额不高于 $id 当前已用量（$(traffic_format_bytes "$used_billable")）；该节点会立即进入配额耗尽状态。"
  fi
  candidate=$(state_candidate)
  jq --arg id "$id" --argjson quota "$quota" --argjson reset "$reset_day" \
    --argjson upload "$upload_rate" --argjson download "$download_rate" --arg mode "$quota_mode" '
    (.nodes[] | select(.id==$id) | .traffic)={
      configured:true,enabled:true,quota_bytes:$quota,quota_mode:$mode,reset_day:$reset,
      upload_rate_bps:$upload,download_rate_bps:$download
    }
  ' "$SBM_STATE" >"$candidate"
  if [[ ${SBM_DRY_RUN:-0} == 1 ]]; then
    config_preview_candidate "$candidate"
    rm -f "$candidate"
    return 0
  fi
  traffic_usage_rebase_node_unlocked "$id" "$reset_day"
  if ! apply_candidate_state "$candidate" "traffic-set-$id"; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  log_ok "已应用节点流量控制：$id"
}

traffic_set() {
  local id=$1; shift
  if [[ ${SBM_DRY_RUN:-0} == 1 ]]; then with_lock _traffic_set "$id" "$@"; else with_state_transaction traffic-set _traffic_set "$id" "$@"; fi
}

_traffic_disable() {
  local id=$1 candidate
  state_node_exists "$id" || die "节点不存在：$id"
  candidate=$(state_candidate)
  jq --arg id "$id" '(.nodes[] | select(.id==$id) | .traffic.enabled)=false' "$SBM_STATE" >"$candidate"
  if ! apply_candidate_state "$candidate" "traffic-disable-$id"; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  log_ok "已停用节点流量监控与限制：$id"
}

traffic_disable() { with_state_transaction traffic-disable _traffic_disable "$1"; }

_traffic_remove() {
  local id=$1 candidate tmp
  state_node_exists "$id" || die "节点不存在：$id"
  candidate=$(state_candidate)
  jq --arg id "$id" '(.nodes[] | select(.id==$id) | .traffic)={
    configured:false,enabled:false,quota_bytes:null,quota_mode:"total",reset_day:1,
    upload_rate_bps:null,download_rate_bps:null
  }' "$SBM_STATE" >"$candidate"
  if ! apply_candidate_state "$candidate" "traffic-remove-$id"; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  traffic_usage_init_unlocked
  tmp=$(mktemp "$(dirname "$SBM_TRAFFIC_USAGE")/.traffic-remove.XXXXXX")
  jq --arg id "$id" 'del(.nodes[$id])' "$SBM_TRAFFIC_USAGE" >"$tmp"
  chmod 0600 "$tmp"; mv -f "$tmp" "$SBM_TRAFFIC_USAGE"
  log_ok "已移除节点流量控制配置与累计用量：$id"
}

traffic_remove() { with_state_transaction traffic-remove _traffic_remove "$1"; }

_traffic_reset() {
  local target=$1 node id cycle reset_day backup
  [[ "$target" == all ]] || state_node_exists "$target" || die "节点不存在：$target"
  traffic_checkpoint_unlocked
  backup=$(mktemp "$(dirname "$SBM_TRAFFIC_USAGE")/.traffic-reset-backup.XXXXXX")
  cp -f "$SBM_TRAFFIC_USAGE" "$backup"
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    id=$(jq -r '.id' <<<"$node"); reset_day=$(jq -r '.traffic.reset_day' <<<"$node"); cycle=$(traffic_cycle_id "$reset_day")
    traffic_usage_put_node "$SBM_TRAFFIC_USAGE" "$id" "$cycle" 0 0
  done < <(jq -c --arg id "$target" '.nodes[]? | select(.traffic.configured==true and ($id=="all" or .id==$id))' "$SBM_STATE")
  chmod 0600 "$SBM_TRAFFIC_USAGE"
  if ! traffic_apply_unlocked; then
    mv -f "$backup" "$SBM_TRAFFIC_USAGE"
    traffic_apply_unlocked || true
    return 1
  fi
  rm -f "$backup"
  log_ok "流量统计已重置：$target"
}

traffic_reset() { with_lock _traffic_reset "$1"; }
traffic_tick() { with_lock traffic_tick_unlocked; }

traffic_status_json_unlocked() {
  local target=${1:-all}
  [[ "$target" == all ]] || state_node_exists "$target" || die "节点不存在：$target"
  jq -n --slurpfile state "$SBM_STATE" --slurpfile usage "$SBM_TRAFFIC_USAGE" --arg id "$target" '
    [$state[0].nodes[]
      | select($id=="all" or .id==$id)
      | . as $node
      | ($usage[0].nodes[.id] // {cycle_id:null,upload_bytes:0,download_bytes:0}) as $u
      | (($u.upload_bytes + $u.download_bytes)) as $total
      | (if .traffic.quota_mode=="download" then $u.download_bytes else $total end) as $billable
      | {
          id,name,protocol,node_enabled:.enabled,
          configured:.traffic.configured,traffic_enabled:.traffic.enabled,
          cycle_id:$u.cycle_id,reset_day:.traffic.reset_day,
          upload_bytes:$u.upload_bytes,download_bytes:$u.download_bytes,total_bytes:$total,
          quota_mode:.traffic.quota_mode,quota_bytes:.traffic.quota_bytes,billable_bytes:$billable,
          remaining_bytes:(if .traffic.quota_bytes==null then null else ([.traffic.quota_bytes-$billable,0]|max) end),
          upload_rate_bps:.traffic.upload_rate_bps,download_rate_bps:.traffic.download_rate_bps
        }
    ]
  '
}

_traffic_status() {
  local target=${1:-all} json=${2:-0} data row id state total upload download quota rates reset mode
  traffic_checkpoint_unlocked
  traffic_reset_due_unlocked
  (( TRAFFIC_RESET_CHANGED == 0 )) || traffic_apply_unlocked
  data=$(traffic_status_json_unlocked "$target")
  if [[ "$json" == 1 ]]; then printf '%s\n' "$data"; return 0; fi
  printf '%-18s %-8s %-13s %-13s %-13s %-18s %s\n' 'ID' '状态' '周期用量' '上行' '下行' '配额' '速率(上/下)'
  while IFS= read -r row; do
    id=$(jq -r '.id' <<<"$row")
    state=$(jq -r 'if .traffic_enabled and .node_enabled then "生效" elif .traffic_enabled then "节点停用" elif .configured then "已停用" else "未配置" end' <<<"$row")
    total=$(traffic_format_bytes "$(jq -r '.total_bytes' <<<"$row")")
    upload=$(traffic_format_bytes "$(jq -r '.upload_bytes' <<<"$row")")
    download=$(traffic_format_bytes "$(jq -r '.download_bytes' <<<"$row")")
    quota=$(jq -r '.quota_bytes' <<<"$row"); mode=$(jq -r '.quota_mode' <<<"$row")
    if [[ "$quota" == null ]]; then quota='不限'; else quota="$(traffic_format_bytes "$quota")/$([[ "$mode" == total ]] && echo 双向 || echo 下行)"; fi
    rates="$(traffic_format_rate "$(jq -r '.upload_rate_bps' <<<"$row")")/$(traffic_format_rate "$(jq -r '.download_rate_bps' <<<"$row")")"
    reset=$(jq -r '.reset_day' <<<"$row")
    printf '%-18s %-8s %-13s %-13s %-13s %-18s %s（每月 %s 日）\n' "$id" "$state" "$total" "$upload" "$download" "$quota" "$rates" "$reset"
  done < <(jq -c '.[]' <<<"$data")
}

traffic_status() { with_lock _traffic_status "${1:-all}" "${2:-0}"; }

traffic_doctor_check() {
  local configured
  configured=$(jq '[.nodes[]? | select(.traffic.enabled==true)] | length' "$SBM_STATE")
  (( configured > 0 )) || return 0
  if ! command_exists nft; then
    check_line FAIL '已配置流量控制，但系统缺少 nft 命令'; failures=$((failures + 1)); return 0
  fi
  if [[ -s "$SBM_TRAFFIC_USAGE" ]] && traffic_usage_validate "$SBM_TRAFFIC_USAGE"; then
    check_line PASS '流量用量账本有效'
  else
    check_line FAIL "流量用量账本缺失或损坏：$SBM_TRAFFIC_USAGE"; failures=$((failures + 1))
  fi
  if (( $(traffic_active_count) > 0 )); then
    if [[ "$SBM_SKIP_INIT" != 1 ]] && ! service_exists "$SBM_TRAFFIC_SERVICE"; then
      check_line FAIL "流量控制服务定义缺失：$SBM_TRAFFIC_SERVICE"; failures=$((failures + 1))
    fi
    if traffic_runtime_complete; then check_line PASS "流量控制 nftables 表已加载：$SBM_TRAFFIC_TABLE"
    else check_line FAIL '流量控制规则未加载；运行 sb traffic reconcile'; failures=$((failures + 1)); fi
  fi
}
