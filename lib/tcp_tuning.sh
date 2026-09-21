#!/usr/bin/env bash
# shellcheck shell=bash

# BDP-based TCP autotuning, independent of BBR and UDP socket limits.
SBM_TCP_SYSCTL_CONFIG="${SBM_TCP_SYSCTL_CONFIG:-/etc/sysctl.d/99-sb-manager-tcp.conf}"
SBM_TCP_BACKUP_DIR="${SBM_TCP_BACKUP_DIR:-$SBM_VAR/tcp-tuning}"
SBM_TCP_SYSCTL_CMD="${SBM_TCP_SYSCTL_CMD:-sysctl}"
SBM_TCP_MEMINFO="${SBM_TCP_MEMINFO:-/proc/meminfo}"
SBM_TCP_CGROUP_MEMORY_FILES="${SBM_TCP_CGROUP_MEMORY_FILES:-/sys/fs/cgroup/memory.max:/sys/fs/cgroup/memory/memory.limit_in_bytes}"
SBM_TCP_SYSCTL_DIRS="${SBM_TCP_SYSCTL_DIRS:-/etc/sysctl.d:/run/sysctl.d:/usr/local/lib/sysctl.d:/usr/lib/sysctl.d:/lib/sysctl.d}"
SBM_TCP_SYSCTL_MAIN="${SBM_TCP_SYSCTL_MAIN:-/etc/sysctl.conf}"
SBM_TCP_MARKER='# Managed by sb-manager; use sb tcp disable to restore previous values.'

tcp_tuning_keys() {
  printf '%s\n' net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_moderate_rcvbuf net.ipv4.tcp_mtu_probing
}

tcp_tuning_get() {
  local value
  value=$("$SBM_TCP_SYSCTL_CMD" -n "$1" 2>/dev/null) || return 1
  awk '{$1=$1; print}' <<<"$value"
}

tcp_tuning_managed() { grep -Fqx "$SBM_TCP_MARKER" "$SBM_TCP_SYSCTL_CONFIG" 2>/dev/null; }

tcp_tuning_values_valid() {
  jq -e '
    type=="object" and
    (keys==["net.ipv4.tcp_moderate_rcvbuf","net.ipv4.tcp_mtu_probing","net.ipv4.tcp_rmem","net.ipv4.tcp_wmem"]) and
    ([.["net.ipv4.tcp_rmem"],.["net.ipv4.tcp_wmem"]] | all(.[];
      type=="string" and test("^[0-9]{1,10} [0-9]{1,10} [0-9]{1,10}$") and
      (split(" ")|map(tonumber)|.[0]<=.[1] and .[1]<=.[2] and .[2]<=2147483647))) and
    (.["net.ipv4.tcp_moderate_rcvbuf"] | .=="0" or .=="1") and
    (.["net.ipv4.tcp_mtu_probing"] | .=="0" or .=="1" or .=="2")' >/dev/null
}

tcp_tuning_current() {
  local key value values='{}'
  while IFS= read -r key; do
    value=$(tcp_tuning_get "$key") || { log_error "当前内核无法读取 $key。"; return 1; }
    values=$(jq -c --arg key "$key" --arg value "$value" '.+{($key):$value}' <<<"$values") || return 1
  done < <(tcp_tuning_keys)
  tcp_tuning_values_valid <<<"$values" || { log_error '当前 TCP sysctl 数值无效。'; return 1; }
  printf '%s\n' "$values"
}

tcp_tuning_conflicts() {
  local dir file
  local -a dirs
  IFS=: read -r -a dirs <<<"$SBM_TCP_SYSCTL_DIRS"
  for dir in "${dirs[@]}"; do
    for file in "$dir"/*.conf; do
      [[ -f "$file" && "$file" != "$SBM_TCP_SYSCTL_CONFIG" ]] || continue
      awk '/^[[:space:]]*-?net[.\/]ipv4[.\/]tcp_(rmem|wmem|moderate_rcvbuf|mtu_probing)[[:space:]]*=/ {found=1} END {exit !found}' "$file" && printf '%s\n' "$file"
    done
  done
  if [[ -f "$SBM_TCP_SYSCTL_MAIN" ]]; then
    awk '/^[[:space:]]*-?net[.\/]ipv4[.\/]tcp_(rmem|wmem|moderate_rcvbuf|mtu_probing)[[:space:]]*=/ {found=1} END {exit !found}' "$SBM_TCP_SYSCTL_MAIN" && printf '%s\n' "$SBM_TCP_SYSCTL_MAIN"
  fi
  return 0
}

tcp_tuning_plan() {
  local bandwidth=$1 rtt=$2 memory current cap target desired conflicts file limit
  local -a memory_files
  [[ "$bandwidth" =~ ^[1-9][0-9]{0,5}$ ]] && (( bandwidth <= 100000 )) || { log_error '带宽必须是 1–100000 Mbps 的整数。'; return 2; }
  [[ "$rtt" =~ ^[1-9][0-9]{0,3}$ ]] && (( rtt <= 2000 )) || { log_error 'RTT 必须是 1–2000 ms 的整数。'; return 2; }
  memory=$(awk '/^MemTotal:/ {print $2; exit}' "$SBM_TCP_MEMINFO") || return 1
  [[ "$memory" =~ ^[1-9][0-9]{0,12}$ ]] || { log_error '无法读取系统内存容量。'; return 1; }
  IFS=: read -r -a memory_files <<<"$SBM_TCP_CGROUP_MEMORY_FILES"
  for file in "${memory_files[@]}"; do
    [[ -r "$file" ]] || continue
    read -r limit <"$file" || continue
    if [[ "$limit" =~ ^(0|[1-9][0-9]{0,15})$ ]] && (( limit / 1024 < memory )); then memory=$((limit / 1024)); fi
  done
  (( memory >= 32768 )) || { log_error '可用内存限额小于 32 MiB，拒绝自动 TCP 调优。'; return 1; }
  current=$(tcp_tuning_current) || return 1
  # 2 * bandwidth (Mbps) * RTT (ms) / 8, rounded up to whole MiB.
  # The cap is per socket/direction; it is not a total memory reservation.
  desired=$(( ((bandwidth * rtt * 250 + 1048575) / 1048576) * 1048576 ))
  (( desired >= 4194304 )) || desired=4194304
  cap=$(( (memory / 32768) * 1048576 ))
  (( cap <= 67108864 )) || cap=67108864
  target=$desired
  (( target <= cap )) || target=$cap
  jq -e --argjson target "$target" '[.["net.ipv4.tcp_rmem"],.["net.ipv4.tcp_wmem"]] | all(.[]; (split(" ")[1]|tonumber)<=$target)' <<<"$current" >/dev/null || {
    log_error '现有 TCP 默认缓冲区超过内存保护上限，拒绝缩小默认值。'; return 1;
  }
  conflicts=$(tcp_tuning_conflicts | jq -Rsc 'split("\n")|map(select(length>0))') || return 1
  jq -n --argjson current "$current" --argjson bandwidth "$bandwidth" --argjson rtt "$rtt" \
    --argjson memory "$memory" --argjson target "$target" --argjson cap "$cap" --argjson desired "$desired" \
    --argjson conflicts "$conflicts" --arg config "$SBM_TCP_SYSCTL_CONFIG" '
    {bandwidth_mbps:$bandwidth,rtt_ms:$rtt,memory_kib:$memory,buffer_bytes:$target,
     memory_cap_bytes:$cap,capped:($desired>$cap),config:$config,conflicts:$conflicts,current:$current,
     proposed:($current | .["net.ipv4.tcp_rmem"] |= (split(" ")|.[2]=($target|tostring)|join(" ")) |
       .["net.ipv4.tcp_wmem"] |= (split(" ")|.[2]=($target|tostring)|join(" ")) |
       .["net.ipv4.tcp_moderate_rcvbuf"]="1" | .["net.ipv4.tcp_mtu_probing"]="1")}'
}

tcp_tuning_show_plan() {
  if [[ ${2:-0} == 1 ]]; then printf '%s\n' "$1"; return; fi
  jq -r '"TCP 调优预览：\(.bandwidth_mbps) Mbps / RTT \(.rtt_ms) ms",
    "每方向缓冲区上限：\(.buffer_bytes/1048576) MiB（内存限制：\(.memory_cap_bytes/1048576) MiB）",
    (if .capped then "已按内存/64 MiB 上限限制；大带宽高延迟线路可能仍受缓冲区限制。" else empty end),
    (.current as $current | .proposed | to_entries[] | "\(.key): \($current[.key]) → \(.value)"),
    (.conflicts[] | "其他配置也设置了这些参数，重启后请核对：\(.)")' <<<"$1"
}

tcp_tuning_snapshot_valid() {
  local dir=$1
  [[ -f "$dir/values.json" ]] && jq -e '.schema_version==1 and (.config_existed|type=="boolean") and (.baseline_existed|type=="boolean")' "$dir/values.json" >/dev/null 2>&1 &&
    jq '.values' "$dir/values.json" | tcp_tuning_values_valid || return 1
  [[ $(jq -r '.config_existed' "$dir/values.json") == false || -f "$dir/config.conf" ]]
}

tcp_tuning_snapshot() {
  local values=$1 tmp existed=false baseline=false
  [[ ! -L "$SBM_TCP_SYSCTL_CONFIG" ]] || { log_error '拒绝覆盖 TCP sysctl 配置软链接。'; return 1; }
  [[ ! -e "$SBM_TCP_SYSCTL_CONFIG" || -f "$SBM_TCP_SYSCTL_CONFIG" ]] || return 1
  tmp=$(mktemp -d "$SBM_TCP_BACKUP_DIR/.snapshot.XXXXXX") || return 1
  if [[ -f "$SBM_TCP_SYSCTL_CONFIG" ]]; then
    existed=true
    cp -p "$SBM_TCP_SYSCTL_CONFIG" "$tmp/config.conf" || { rm -rf "$tmp"; return 1; }
  fi
  [[ ! -d "$SBM_TCP_BACKUP_DIR/original" ]] || baseline=true
  if ! jq -n --argjson values "$values" --argjson existed "$existed" --argjson baseline "$baseline" \
    '{schema_version:1,config_existed:$existed,baseline_existed:$baseline,values:$values}' >"$tmp/values.json" ||
    ! chmod 0600 "$tmp/values.json" || ! mv "$tmp" "$SBM_TCP_BACKUP_DIR/pending"; then
    rm -rf "$tmp"; return 1
  fi
}

tcp_tuning_verify() {
  local expected=$1 actual
  actual=$(tcp_tuning_current) || return 1
  jq -en --argjson expected "$expected" --argjson actual "$actual" '$expected==$actual' >/dev/null
}

tcp_tuning_restore_snapshot() {
  local dir=$1 key value tmp rc=0 values
  tcp_tuning_snapshot_valid "$dir" || { log_error "TCP 备份损坏或缺失：$dir"; return 1; }
  values=$(jq -c '.values' "$dir/values.json") || return 1
  # Restore only owned keys, never replay unrelated entries from the old file.
  while IFS=$'\t' read -r key value; do
    "$SBM_TCP_SYSCTL_CMD" -w "$key=$value" >>"$SBM_RUN/tcp-sysctl.log" 2>&1 || rc=1
  done < <(jq -r 'to_entries[]|[.key,.value]|@tsv' <<<"$values")
  tcp_tuning_verify "$values" || rc=1
  if [[ $(jq -r '.config_existed' "$dir/values.json") == true ]]; then
    tmp=$(mktemp "$(dirname "$SBM_TCP_SYSCTL_CONFIG")/.sb-tcp-restore.XXXXXX") || return 1
    if ! cp -p "$dir/config.conf" "$tmp" || ! mv -f "$tmp" "$SBM_TCP_SYSCTL_CONFIG"; then rm -f "$tmp"; return 1; fi
  else
    rm -f "$SBM_TCP_SYSCTL_CONFIG" || return 1
  fi
  return "$rc"
}

tcp_tuning_recover() {
  [[ -e "$SBM_TCP_BACKUP_DIR/pending" ]] || return 0
  tcp_tuning_restore_snapshot "$SBM_TCP_BACKUP_DIR/pending" || {
    log_error "TCP 回滚未完成，备份已保留：$SBM_TCP_BACKUP_DIR/pending"; return 1;
  }
  if [[ $(jq -r '.baseline_existed' "$SBM_TCP_BACKUP_DIR/pending/values.json") == false ]]; then
    rm -rf "$SBM_TCP_BACKUP_DIR/original" || return 1
  fi
  rm -rf "$SBM_TCP_BACKUP_DIR/pending"
}

_tcp_tuning_enable() {
  local plan values proposed tmp
  mkdir -p "$SBM_TCP_BACKUP_DIR" "$(dirname "$SBM_TCP_SYSCTL_CONFIG")" || return 1
  chmod 0700 "$SBM_TCP_BACKUP_DIR" || return 1
  tcp_tuning_recover || return 1
  if [[ -e "$SBM_TCP_BACKUP_DIR/original" ]]; then
    tcp_tuning_snapshot_valid "$SBM_TCP_BACKUP_DIR/original" || { log_error 'TCP 原始备份损坏，拒绝覆盖。'; return 1; }
  elif tcp_tuning_managed; then
    log_error 'TCP 原始备份缺失，拒绝覆盖托管配置。'; return 1
  fi
  plan=$(tcp_tuning_plan "$1" "$2") || return $?
  values=$(jq -c '.current' <<<"$plan") || return 1
  proposed=$(jq -c '.proposed' <<<"$plan") || return 1
  tcp_tuning_snapshot "$values" || return 1
  if [[ ! -d "$SBM_TCP_BACKUP_DIR/original" ]]; then
    cp -a "$SBM_TCP_BACKUP_DIR/pending" "$SBM_TCP_BACKUP_DIR/original" || { tcp_tuning_recover; return 1; }
  fi
  tmp=$(mktemp "$(dirname "$SBM_TCP_SYSCTL_CONFIG")/.sb-tcp.XXXXXX") || { tcp_tuning_recover; return 1; }
  if ! { printf '%s\n' "$SBM_TCP_MARKER" && jq -r 'to_entries[]|"\(.key)=\(.value)"' <<<"$proposed"; } >"$tmp" ||
    ! chmod 0644 "$tmp" || ! mv -f "$tmp" "$SBM_TCP_SYSCTL_CONFIG" ||
    ! "$SBM_TCP_SYSCTL_CMD" -p "$SBM_TCP_SYSCTL_CONFIG" >"$SBM_RUN/tcp-sysctl.log" 2>&1 ||
    ! tcp_tuning_verify "$proposed"; then
    rm -f "$tmp"
    tcp_tuning_recover || return 1
    log_error 'TCP 调优失败，已恢复本次操作前的配置和运行值。'; return 1
  fi
  rm -rf "$SBM_TCP_BACKUP_DIR/pending" || return 1
  tcp_tuning_show_plan "$plan"
  log_ok 'TCP 调优已生效；sb tcp disable 可恢复首次启用前的设置。'
}

tcp_tuning_enable() { with_lock _tcp_tuning_enable "$@"; }

_tcp_tuning_disable() {
  tcp_tuning_recover || return 1
  if [[ ! -e "$SBM_TCP_BACKUP_DIR/original" ]]; then
    if tcp_tuning_managed; then log_error 'TCP 原始备份缺失，保留托管配置。'; return 1; fi
    log_warn 'TCP 调优未由 sb-manager 管理，无需恢复。'; return 0
  fi
  tcp_tuning_restore_snapshot "$SBM_TCP_BACKUP_DIR/original" || { log_error 'TCP 恢复失败，已保留备份，请重试。'; return 1; }
  rm -rf "$SBM_TCP_BACKUP_DIR/original" || return 1
  log_ok '已恢复 TCP 调优前的配置和运行值。'
}

tcp_tuning_disable() { with_lock _tcp_tuning_disable; }

tcp_tuning_status() {
  local current proposed='{}' managed=false enabled=false pending=false result
  current=$(tcp_tuning_current) || return 1
  if tcp_tuning_managed; then
    managed=true
    proposed=$(awk -F= '/^net\.ipv4\.tcp_/ {print $1 "\t" $2}' "$SBM_TCP_SYSCTL_CONFIG" |
      jq -Rsc 'split("\n")|map(select(length>0)|split("\t")|{key:.[0],value:.[1]})|from_entries') || return 1
    if tcp_tuning_values_valid <<<"$proposed" && [[ $(jq -n --argjson a "$current" --argjson b "$proposed" '$a==$b') == true ]]; then enabled=true; fi
  fi
  [[ ! -e "$SBM_TCP_BACKUP_DIR/pending" ]] || pending=true
  result=$(jq -n --argjson current "$current" --argjson proposed "$proposed" --argjson managed "$managed" \
    --argjson enabled "$enabled" --argjson pending "$pending" --arg config "$SBM_TCP_SYSCTL_CONFIG" \
    '{managed:$managed,enabled:$enabled,recovery_pending:$pending,current:$current,configured:$proposed,managed_config:$config}') || return 1
  if [[ ${1:-0} == 1 ]]; then printf '%s\n' "$result"; else
    jq -r '"TCP 调优：\(if .enabled then "已生效" elif .managed then "运行值与配置不一致" else "未托管" end)",
      (if .recovery_pending then "存在待恢复事务；下一次启用/停用将先重试恢复。" else empty end),
      (.current|to_entries[]|"\(.key)=\(.value)")' <<<"$result"
  fi
}

tcp_tuning_cli() {
  local action=${1:-status} bandwidth='' rtt='' plan json=${SBM_OUTPUT_JSON:-0} dry_run=${SBM_DRY_RUN:-0}
  (($# == 0)) || shift
  while (($#)); do
    case "$1" in
      --bandwidth) [[ $# -ge 2 ]] || usage_die '--bandwidth 缺少 Mbps 数值'; bandwidth=$2; shift 2;;
      --rtt) [[ $# -ge 2 ]] || usage_die '--rtt 缺少 ms 数值'; rtt=$2; shift 2;;
      --json) json=1; shift;;
      --dry-run) dry_run=1; shift;;
      *) usage_die "未知 TCP 调优参数：$1";;
    esac
  done
  case "$action" in
    plan|enable)
      [[ -n "$bandwidth" && -n "$rtt" ]] || usage_die '用法：sb tcp plan|enable --bandwidth Mbps --rtt MS [--dry-run] [--json]'
      if [[ "$action" == plan || "$dry_run" == 1 ]]; then
        plan=$(tcp_tuning_plan "$bandwidth" "$rtt") || return $?
        tcp_tuning_show_plan "$plan" "$json"
      else
        [[ ${SBM_TEST_MODE:-0} == 1 ]] || require_root
        require_command flock
        if [[ "$json" == 1 ]]; then tcp_tuning_enable "$bandwidth" "$rtt" >&2 && tcp_tuning_status 1
        else tcp_tuning_enable "$bandwidth" "$rtt"; fi
      fi
      ;;
    status|disable)
      [[ -z "$bandwidth$rtt" && "$dry_run" == 0 ]] || usage_die 'status/disable 不接受带宽、RTT 或 --dry-run'
      if [[ "$action" == status ]]; then tcp_tuning_status "$json"
      else
        [[ ${SBM_TEST_MODE:-0} == 1 ]] || require_root
        require_command flock
        if [[ "$json" == 1 ]]; then tcp_tuning_disable >&2 && tcp_tuning_status 1
        else tcp_tuning_disable; fi
      fi
      ;;
    *) usage_die '用法：sb tcp plan|enable --bandwidth Mbps --rtt MS | status [--json] | disable';;
  esac
}
