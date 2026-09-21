#!/usr/bin/env bash
# shellcheck shell=bash

SBM_NETWORK_PING_CMD="${SBM_NETWORK_PING_CMD:-ping}"
SBM_NETWORK_TIMEOUT_CMD="${SBM_NETWORK_TIMEOUT_CMD:-timeout}"

network_ping_result() {
  # iputils and BusyBox differ in the packet and RTT summary labels.
  # Jitter is the mean absolute difference between consecutive received RTTs.
  awk '
    /time[=<][0-9.]+/ {
      sample=$0; sub(/^.*time[=<]/,"",sample); sub(/[^0-9.].*$/,"",sample)
      if (samples>0) {delta=sample-previous; jitter+=(delta<0 ? -delta : delta)}
      previous=sample; samples++
    }
    /packets transmitted/ {
      sent=$1
      for (i=2;i<=NF;i++) {
        if ($i ~ /^received/) {received=$(i-1); if (received=="packets") received=$(i-2)}
      }
      summary=1
    }
    /^(rtt|round-trip).*=/ {
      line=$0; sub(/^[^=]*=[[:space:]]*/,"",line); split(line,parts,"/")
      min=parts[1]+0; avg=parts[2]+0; max=parts[3]+0; rtt=1
    }
    END {
      if (!summary || sent<1 || received<0 || received>sent) exit 1
      printf "{\"sent\":%d,\"received\":%d,\"loss_percent\":%.3f,",sent,received,100*(sent-received)/sent
      if (rtt) printf "\"rtt_ms\":{\"min\":%.3f,\"avg\":%.3f,\"max\":%.3f},",min,avg,max
      else printf "\"rtt_ms\":null,"
      if (samples>1) printf "\"jitter_ms\":%.3f}",jitter/(samples-1)
      else printf "\"jitter_ms\":null}"
    }'
}

network_ping() {
  local host=$1 count=${2:-10} family=${3:-auto} json=${4:-0} output result rc=0 deadline
  # BusyBox ping has no -n option; the outer timeout also bounds DNS lookups.
  local -a args=()
  [[ ${#host} -le 253 && "$host" =~ ^[a-zA-Z0-9:][a-zA-Z0-9.:%_-]*$ ]] || { log_error '目标必须是主机名或 IP 地址。'; return 2; }
  [[ "$count" =~ ^[1-9][0-9]?$ ]] && (( count <= 30 )) || { log_error '探测次数必须是 1–30。'; return 2; }
  case "$family" in auto) ;; 4|6) args+=("-$family");; *) return 2;; esac
  command_exists "$SBM_NETWORK_PING_CMD" || { log_error '缺少 ping；Debian 可安装 iputils-ping，Alpine 可使用 BusyBox ping。'; return 1; }
  require_command "$SBM_NETWORK_TIMEOUT_CMD"
  deadline=$((count * 2 + 3))
  output=$(LC_ALL=C "$SBM_NETWORK_TIMEOUT_CMD" "$deadline" "$SBM_NETWORK_PING_CMD" "${args[@]}" -c "$count" -W 2 -w "$((deadline-1))" "$host" 2>&1) || rc=$?
  if ! result=$(network_ping_result <<<"$output"); then
    log_error "网络探测未得到有效结果（退出码 $rc）：$output"; return 1
  fi
  result=$(jq --arg target "$host" --arg family "$family" --argjson rc "$rc" \
    '.+{target:$target,ip_family:$family,ping_exit_code:$rc,reachable:(.received>0)}' <<<"$result") || return 1
  if [[ "$json" == 1 ]]; then printf '%s\n' "$result"
  else
    jq -r '"目标：\(.target)（IP：\(.ip_family)）",
      "发出 / 收到：\(.sent) / \(.received)；丢包：\(.loss_percent)%",
      (if .rtt_ms==null then "RTT：无响应" else "RTT 最小 / 平均 / 最大：\(.rtt_ms.min) / \(.rtt_ms.avg) / \(.rtt_ms.max) ms" end),
      "相邻响应 RTT 抖动：\(.jitter_ms // "样本不足") ms"' <<<"$result"
    printf 'ICMP 结果仅供线路诊断；不响应可能是目标禁用了 ICMP。\n'
  fi
  jq -e '.reachable and (.ping_exit_code==0 or .ping_exit_code==1)' <<<"$result" >/dev/null
}

network_cli() {
  case "${1:-}" in speed|history|compare) network_benchmark_cli "$@"; return $?;; esac
  [[ ${1:-} == ping && $# -ge 2 ]] || usage_die '用法：sb network ping HOST [--count 1-30] [--ipv4|--ipv6] [--json]'
  local host=$2 count=10 family=auto json=${SBM_OUTPUT_JSON:-0}
  shift 2
  [[ ${SBM_DRY_RUN:-0} == 0 ]] || usage_die 'network ping 不接受 --dry-run'
  while (($#)); do
    case "$1" in
      --count) [[ $# -ge 2 ]] || usage_die '--count 缺少次数'; count=$2; shift 2;;
      --ipv4|--ipv6) [[ "$family" == auto ]] || usage_die '只能选择一种 IP 协议'; family=${1#--ipv}; shift;;
      --json) json=1; shift;;
      *) usage_die "未知网络诊断参数：$1";;
    esac
  done
  network_ping "$host" "$count" "$family" "$json"
}
