#!/usr/bin/env bash
# shellcheck shell=bash

SBM_NETWORK_IPERF_CMD="${SBM_NETWORK_IPERF_CMD:-iperf3}"
SBM_NETWORK_HISTORY="${SBM_NETWORK_HISTORY:-$SBM_VAR/network-tests}"

_network_save_result() {
  local result=$1 id=$2 tmp
  mkdir -p "$SBM_NETWORK_HISTORY" || return 1
  chmod 0700 "$SBM_NETWORK_HISTORY" || return 1
  tmp=$(mktemp "$SBM_NETWORK_HISTORY/.result.XXXXXX") || return 1
  if ! printf '%s\n' "$result" >"$tmp" || ! chmod 0600 "$tmp" || ! mv "$tmp" "$SBM_NETWORK_HISTORY/$id.json"; then
    rm -f "$tmp"; return 1
  fi
}

network_speed() {
  local host=$1 port=$2 seconds=$3 streams=$4 direction=$5 json=$6 output result id tuning='{}' rc=0
  local -a args
  [[ ${#host} -le 253 && "$host" =~ ^[a-zA-Z0-9:][a-zA-Z0-9.:%_-]*$ ]] || usage_die '测速目标必须是主机名或 IP。'
  [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 )) || usage_die '测速端口必须为 1–65535。'
  [[ "$seconds" =~ ^[1-9][0-9]?$ ]] && (( seconds <= 30 )) || usage_die '测速时长必须为 1–30 秒。'
  [[ "$streams" =~ ^[1-9][0-9]?$ ]] && (( streams <= 16 )) || usage_die '连接数必须为 1–16。'
  case "$direction" in up|down) ;; *) usage_die '测速方向必须是 up 或 down。';; esac
  [[ ${SBM_DRY_RUN:-0} == 0 ]] || usage_die 'speed 不接受 --dry-run。'
  command_exists "$SBM_NETWORK_IPERF_CMD" || { log_error '缺少 iperf3；运行 sb deps install benchmark。'; return 1; }
  require_command "$SBM_NETWORK_TIMEOUT_CMD"; require_command flock
  args=(-c "$host" -p "$port" -t "$seconds" -P "$streams" --connect-timeout 5000 -J)
  [[ "$direction" != down ]] || args+=(-R)
  output=$(LC_ALL=C "$SBM_NETWORK_TIMEOUT_CMD" "$((seconds + 15))" "$SBM_NETWORK_IPERF_CMD" "${args[@]}" 2>&1) || rc=$?
  if (( rc != 0 )) || ! jq -e '.error==null and (.end.sum_received.bits_per_second|type=="number" and .>=0)' <<<"$output" >/dev/null 2>&1; then
    log_error "iperf3 测速失败（退出码 $rc）；请检查目标 iperf3 服务与网络。"
    return 1
  fi
  if declare -F tcp_tuning_status >/dev/null 2>&1; then tuning=$(tcp_tuning_status 1 2>/dev/null || printf '{}'); fi
  id="$(now_stamp)-$(random_hex 4)"
  result=$(jq --arg id "$id" --arg now "$(now_iso)" --arg host "$host" --arg direction "$direction" \
    --argjson port "$port" --argjson seconds "$seconds" --argjson streams "$streams" --argjson tuning "$tuning" \
    '{schema_version:1,id:$id,created_at:$now,target:$host,port:$port,seconds:$seconds,streams:$streams,direction:$direction,
      bits_per_second:.end.sum_received.bits_per_second,bytes:.end.sum_received.bytes,
      retransmits:(.end.sum_sent.retransmits // null),tcp_tuning:$tuning,iperf:.}' <<<"$output") || return 1
  with_lock _network_save_result "$result" "$id" || return 1
  if [[ "$json" == 1 ]]; then printf '%s\n' "$result"; else
    jq -r '"测速记录：\(.id)","目标：\(.target):\(.port)，方向：\(.direction)，连接：\(.streams)，时长：\(.seconds)s",
      "接收吞吐：\((.bits_per_second/1000000*100|round)/100) Mbps；重传：\(.retransmits // "无数据")"' <<<"$result"
  fi
}

network_history() {
  local file
  for file in "$SBM_NETWORK_HISTORY"/*.json; do
    [[ -f "$file" ]] || continue
    jq -c 'del(.iperf,.tcp_tuning)' "$file" || return 1
  done | jq -s 'sort_by(.created_at)|reverse'
}

network_compare() {
  local a=$1 b=$2 json=${3:-0} result id
  for id in "$a" "$b"; do
    [[ "$id" =~ ^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{8}$ && -f "$SBM_NETWORK_HISTORY/$id.json" ]] || usage_die "测速记录不存在：$id"
  done
  result=$(jq -en --slurpfile a "$SBM_NETWORK_HISTORY/$a.json" --slurpfile b "$SBM_NETWORK_HISTORY/$b.json" '
    $a[0] as $a | $b[0] as $b |
    if ([$a.target,$a.port,$a.seconds,$a.streams,$a.direction] != [$b.target,$b.port,$b.seconds,$b.streams,$b.direction])
    then error("只能比较相同目标、方向、时长和连接数的记录") else
    {before:$a.id,after:$b.id,before_mbps:($a.bits_per_second/1000000),after_mbps:($b.bits_per_second/1000000),
     change_percent:(if $a.bits_per_second==0 then null else (($b.bits_per_second/$a.bits_per_second-1)*100) end)} end') || return 1
  if [[ "$json" == 1 ]]; then printf '%s\n' "$result"; else
    jq -r '"前：\(.before_mbps) Mbps → 后：\(.after_mbps) Mbps",
      "变化：\(if .change_percent==null then "无法计算（基线为零）" else ((.change_percent*100|round)/100|tostring)+"%" end)",
      "测速受线路和对端负载影响，请在相同条件下多次比较。"' <<<"$result"
  fi
}

network_benchmark_cli() {
  local action=$1 host='' port=5201 seconds=10 streams=1 direction=up json=${SBM_OUTPUT_JSON:-0}
  shift
  case "$action" in
    history) [[ $# == 0 || ( $# == 1 && "$1" == --json ) ]] || usage_die '用法：sb network history [--json]'; network_history; return;;
    compare)
      [[ $# == 2 || ( $# == 3 && "$3" == --json ) ]] || usage_die '用法：sb network compare BEFORE AFTER [--json]'
      [[ $# != 3 ]] || json=1
      network_compare "$1" "$2" "$json"; return;;
    speed) [[ $# -ge 1 ]] || usage_die '用法：sb network speed HOST [--port N] [--seconds 1-30] [--streams 1-16] [--direction up|down] [--json]'; host=$1; shift;;
    *) return 2;;
  esac
  while (($#)); do
    case "$1" in
      --port|--seconds|--streams|--direction)
        [[ $# -ge 2 ]] || usage_die "参数 $1 缺少值。"
        case "$1" in --port) port=$2;; --seconds) seconds=$2;; --streams) streams=$2;; --direction) direction=$2;; esac
        shift 2;;
      --json) json=1; shift;;
      *) usage_die "未知测速参数：$1";;
    esac
  done
  network_speed "$host" "$port" "$seconds" "$streams" "$direction" "$json"
}
