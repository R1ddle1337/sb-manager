#!/usr/bin/env bash
# shellcheck shell=bash

SBM_TC_CMD="${SBM_TC_CMD:-tc}"
SBM_SHAPING_DIR="${SBM_SHAPING_DIR:-$SBM_VAR/shaping}"

shaping_validate_state() {
  jq -e '(.shaping // {enabled:false,interface:"",capacity_bps:1000000000}) |
    (.enabled|type=="boolean") and (.interface|type=="string") and
    (if .enabled then (.interface|test("^[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,14}$") and .!="lo") else true end) and
    (.capacity_bps|type=="number" and floor==. and .>=1000 and .<=1000000000000)' "$1" >/dev/null
}

shaping_plan() {
  local interface=$1 rate=$2
  [[ "$interface" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,14}$ && "$interface" != lo ]] || usage_die '无效整形网卡；不能接管 lo。'
  rate=$(traffic_parse_rate "$rate") || usage_die '网卡容量无效，例如 1G。'
  (( rate >= 1000 )) || usage_die '网卡容量至少 1000 bit/s。'
  jq --arg interface "$interface" --argjson capacity "$rate" '
    . as $state |
    [.nodes[] | select(.enabled and .traffic.enabled and .traffic.download_rate_bps!=null) |
      . as $node | {id,port,protocol,network:(.network // "tcp"),rate_bps:.traffic.download_rate_bps,
      eligible:(.listen!="127.0.0.1" and .listen!="::1" and
        ([$state.nginx_stream.routes[]?|select(.node_id==$node.id)]|length)==0)}] as $nodes |
    {interface:$interface,capacity_bps:$capacity,direction:"download",
     nodes:[$nodes[]|select(.eligible)],excluded:[$nodes[]|select(.eligible|not)],
     note:"仅整形所选网卡上直连节点的下行；上行和 loopback 回源仍使用 nftables 限速。"}' "$SBM_STATE"
}

# Recreate only known kernel default qdiscs; never interpret saved shell text.
shaping_qdisc_options() {
  local row=$1 key value kind
  kind=$(jq -r '.kind' <<<"$row")
  while IFS=$'\t' read -r key value; do
    case "$kind:$key" in
      fq_codel:limit|fq_codel:flows|fq_codel:quantum|fq_codel:memory_limit|fq_codel:drop_batch|fq:limit|fq:flow_limit|fq:buckets|fq:orphan_mask|fq:quantum|fq:initial_quantum)
        [[ "$value" =~ ^[0-9]+$ ]] || return 1; printf '%s\n%s\n' "$key" "$value";;
      fq_codel:target|fq_codel:interval|fq_codel:ce_threshold|fq:refill_delay|fq:ce_threshold|fq:horizon)
        [[ "$value" =~ ^[0-9]+$ ]] || return 1; printf '%s\n%sus\n' "$key" "$value";;
      fq:timer_slack) [[ "$value" =~ ^[0-9]+$ ]] || return 1; printf 'timer_slack\n%sns\n' "$value";;
      fq:maxrate) [[ "$value" =~ ^[0-9]+$ ]] || return 1; [[ "$value" == 4294967295 ]] || printf 'maxrate\n%sbit\n' "$((value*8))";;
      fq_codel:ecn|fq:pacing|fq:horizon_drop)
        [[ "$value" == true || "$value" == false ]] || return 1
        if [[ "$value" == true ]]; then printf '%s\n' "$key"; else printf 'no%s\n' "$key"; fi;;
      *) log_error "无法无损恢复 qdisc 参数 $kind:$key，拒绝接管。"; return 1;;
    esac
  done < <(jq -r '.options // {}|to_entries[]|[.key,(.value|tostring)]|@tsv' <<<"$row")
}

shaping_capture() {
  local interface=$1 rows row tmp
  [[ ! -e "$SBM_SHAPING_DIR/baseline.json" ]] || return 0
  rows=$("$SBM_TC_CMD" -j qdisc show dev "$interface" | jq '[.[]|select(.kind!="clsact" and .kind!="ingress")]') || return 1
  if ! jq -e 'length>0 and any(.[];.root==true) and all(.[];
    .handle=="0:" and (.kind|IN("noqueue","mq","fq","fq_codel")))' <<<"$rows" >/dev/null; then
    # Restoring fq/fq_codel can allocate a new handle. Only accept that exact
    # manager-restored tree, never an unrelated tree with the same qdisc kind.
    [[ -f "$SBM_SHAPING_DIR/restored.json" ]] && jq -e --arg interface "$interface" --argjson live "$rows" '
      def canonical: map({kind,handle,parent,root,options})|sort_by(.handle,.parent);
      .interface==$interface and ((.qdiscs|canonical)==($live|canonical))' "$SBM_SHAPING_DIR/restored.json" >/dev/null || {
      log_error '网卡已有自定义队列，拒绝接管；只支持内核默认或管理器恢复的队列。'; return 1;
    }
  fi
  [[ $("$SBM_TC_CMD" -j filter show dev "$interface" | jq 'length') == 0 ]] || { log_error '网卡已有 root 过滤器，拒绝接管。'; return 1; }
  while IFS= read -r row; do shaping_qdisc_options "$row" >/dev/null || return 1; done < <(jq -c '.[]' <<<"$rows")
  mkdir -p "$SBM_SHAPING_DIR" && chmod 0700 "$SBM_SHAPING_DIR" || return 1
  tmp=$(mktemp "$SBM_SHAPING_DIR/.baseline.XXXXXX") || return 1
  jq -n --arg interface "$interface" --argjson qdiscs "$rows" '{schema_version:1,interface:$interface,qdiscs:$qdiscs}' >"$tmp" &&
    chmod 0600 "$tmp" && mv "$tmp" "$SBM_SHAPING_DIR/baseline.json"
}

shaping_restore() {
  local interface row kind current parent options_text tmp
  local -a args options
  [[ -f "$SBM_SHAPING_DIR/baseline.json" ]] || return 0
  jq -e '.schema_version==1 and (.interface|test("^[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,14}$")) and (.qdiscs|type=="array")' "$SBM_SHAPING_DIR/baseline.json" >/dev/null || return 1
  interface=$(jq -r '.interface' "$SBM_SHAPING_DIR/baseline.json")
  current=$("$SBM_TC_CMD" -j qdisc show dev "$interface") || return 1
  if jq -e 'any(.[];.root==true and .handle=="5b00:" and .kind=="htb")' <<<"$current" >/dev/null; then
    "$SBM_TC_CMD" qdisc del dev "$interface" root || return 1
  elif [[ ! -f "$SBM_SHAPING_DIR/applied.json" ]]; then return 0
  else
    log_error '整形队列已被其他程序更改，保留备份并拒绝覆盖。'; return 1
  fi
  while IFS= read -r row; do
    kind=$(jq -r '.kind' <<<"$row")
    [[ "$kind" != noqueue && "$kind" != mq ]] || continue
    options_text=$(shaping_qdisc_options "$row") || return 1
    options=(); [[ -z "$options_text" ]] || mapfile -t options <<<"$options_text"
    args=(qdisc replace dev "$interface")
    if [[ $(jq -r '.root // false' <<<"$row") == true ]]; then args+=(root)
    else parent=$(jq -r '.parent' <<<"$row"); [[ "$parent" =~ ^[0-9a-f]*:[0-9a-f]+$ ]] || return 1; args+=(parent "$parent"); fi
    "$SBM_TC_CMD" "${args[@]}" "$kind" "${options[@]}" || return 1
  done < <(jq -c '.qdiscs[]' "$SBM_SHAPING_DIR/baseline.json")
  current=$("$SBM_TC_CMD" -j qdisc show dev "$interface" | jq '[.[]|select(.kind!="clsact" and .kind!="ingress")]') || return 1
  tmp=$(mktemp "$SBM_SHAPING_DIR/.restored.XXXXXX") || return 1
  jq -n --arg interface "$interface" --argjson qdiscs "$current" '{interface:$interface,qdiscs:$qdiscs}' >"$tmp" &&
    chmod 0600 "$tmp" && mv "$tmp" "$SBM_SHAPING_DIR/restored.json" || return 1
  rm -f "$SBM_SHAPING_DIR/applied.json" "$SBM_SHAPING_DIR/baseline.json"
}

shaping_apply_plan() {
  local plan=$1 interface capacity row id=100 filter_priority=1000 rate port kind family current tmp
  interface=$(jq -r '.interface' <<<"$plan"); capacity=$(jq -r '.capacity_bps' <<<"$plan")
  shaping_capture "$interface" || return 1
  [[ $(jq -r '.interface' "$SBM_SHAPING_DIR/baseline.json") == "$interface" ]] || { log_error '更换整形网卡前请先停用原网卡整形。'; return 1; }
  current=$("$SBM_TC_CMD" -j qdisc show dev "$interface") || return 1
  if jq -e 'any(.[];.root==true and .handle=="5b00:" and .kind=="htb")' <<<"$current" >/dev/null; then
    "$SBM_TC_CMD" qdisc del dev "$interface" root || return 1
  elif jq -e 'any(.[];.root==true and .handle!="0:")' <<<"$current" >/dev/null; then
    jq -e --argjson live "$current" '
      def canonical: map(select(.kind!="clsact" and .kind!="ingress")|{kind,handle,parent,root,options})|sort_by(.handle,.parent);
      (.qdiscs|canonical)==($live|canonical)' "$SBM_SHAPING_DIR/baseline.json" >/dev/null || {
      log_error '网卡已有其他程序的 root qdisc，拒绝覆盖。'; return 1;
    }
  fi
  "$SBM_TC_CMD" qdisc replace dev "$interface" root handle 5b00: htb default 1 || return 1
  "$SBM_TC_CMD" class add dev "$interface" parent 5b00: classid 5b00:ffff htb rate "${capacity}bit" ceil "${capacity}bit" || return 1
  "$SBM_TC_CMD" class add dev "$interface" parent 5b00:ffff classid 5b00:1 htb rate "${capacity}bit" ceil "${capacity}bit" || return 1
  while IFS= read -r row; do
    rate=$(jq -r '.rate_bps' <<<"$row"); port=$(jq -r '.port' <<<"$row")
    (( rate <= capacity )) || rate=$capacity
    "$SBM_TC_CMD" class add dev "$interface" parent 5b00:ffff classid "5b00:$id" htb rate "${rate}bit" ceil "${rate}bit" || return 1
    "$SBM_TC_CMD" qdisc add dev "$interface" parent "5b00:$id" fq_codel || return 1
    while IFS= read -r kind; do
      for family in ip ipv6; do
        "$SBM_TC_CMD" filter add dev "$interface" parent 5b00: protocol "$family" pref "$filter_priority" flower ip_proto "$kind" src_port "$port" classid "5b00:$id" || return 1
        filter_priority=$((filter_priority+1))
      done
    done < <(node_transport_kinds "$row")
    id=$((id+1))
  done < <(jq -c '.nodes|sort_by(.id)[]' <<<"$plan")
  tmp=$(mktemp "$SBM_SHAPING_DIR/.applied.XXXXXX") || return 1
  printf '%s\n' "$plan" >"$tmp" && chmod 0600 "$tmp" && mv "$tmp" "$SBM_SHAPING_DIR/applied.json"
}

shaping_reconcile_unlocked() {
  local plan previous='' rc=0
  if [[ $(jq -r '.shaping.enabled // false' "$SBM_STATE") != true ]]; then shaping_restore; return; fi
  require_command "$SBM_TC_CMD"
  plan=$(shaping_plan "$(jq -r '.shaping.interface' "$SBM_STATE")" "$(jq -r '.shaping.capacity_bps' "$SBM_STATE")bps") || return 1
  if [[ -f "$SBM_SHAPING_DIR/applied.json" ]]; then
    previous=$(cat "$SBM_SHAPING_DIR/applied.json")
    if jq -en --argjson a "$previous" --argjson b "$plan" '$a==$b' >/dev/null &&
      "$SBM_TC_CMD" -j qdisc show dev "$(jq -r '.interface' <<<"$plan")" | jq -e 'any(.[];.root==true and .handle=="5b00:")' >/dev/null; then return 0; fi
  fi
  shaping_apply_plan "$plan" || rc=$?
  if (( rc != 0 )); then
    if [[ -n "$previous" ]]; then shaping_apply_plan "$previous" || log_error "整形回滚失败，备份保留在 $SBM_SHAPING_DIR。"
    else shaping_restore || log_error "队列恢复失败，备份保留在 $SBM_SHAPING_DIR。"; fi
  fi
  return "$rc"
}

_shaping_set() {
  local enabled=$1 interface=${2:-} rate=${3:-1000000000} candidate plan
  candidate=$(state_candidate) || return 1
  if [[ "$enabled" == true ]]; then
    plan=$(shaping_plan "$interface" "$rate") || return 1
    rate=$(jq -r '.capacity_bps' <<<"$plan")
  fi
  jq --argjson enabled "$enabled" --arg interface "$interface" --argjson rate "$rate" \
    '.shaping={enabled:$enabled,interface:$interface,capacity_bps:$rate}' "$SBM_STATE" >"$candidate" || return 1
  if ! apply_candidate_state "$candidate" traffic-shaping; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  # Production transactions already reconciled tc before their nftables rules.
  [[ "$SBM_SKIP_INIT" != 1 ]] || shaping_reconcile_unlocked
}

shaping_cli() {
  local action=${1:-status} plan interface rate
  (($# == 0)) || shift
  case "$action" in
    plan|enable)
      [[ $# == 3 && "$2" == --capacity ]] || usage_die '用法：sb traffic shaping plan|enable IFACE --capacity 1G'
      interface=$1; rate=$3
      plan=$(shaping_plan "$interface" "$rate") || return 1
      if [[ "$action" == plan || ${SBM_DRY_RUN:-0} == 1 ]]; then printf '%s\n' "$plan"; return; fi
      command_exists "$SBM_TC_CMD" || { log_error '缺少 tc；运行 sb deps install shaping。'; return 1; }
      with_state_transaction shaping-enable _shaping_set true "$interface" "$rate";;
    disable) [[ $# == 0 && ${SBM_DRY_RUN:-0} == 0 ]] || usage_die '用法：sb traffic shaping disable'; with_state_transaction shaping-disable _shaping_set false;;
    status) [[ $# == 0 || ( $# == 1 && "$1" == --json ) ]] || usage_die '用法：sb traffic shaping status [--json]'; jq '.shaping // {enabled:false,interface:"",capacity_bps:1000000000}' "$SBM_STATE";;
    *) usage_die '用法：sb traffic shaping plan|enable|disable|status';;
  esac
}
