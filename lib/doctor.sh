#!/usr/bin/env bash
# shellcheck shell=bash

check_line() {
  local level=$1; shift
  case "$level" in PASS) printf '%s[PASS]%s %s\n' "$C_GREEN" "$C_RESET" "$*";; WARN) printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*";; FAIL) printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*";; esac
}

status_summary() {
  local sb_ver cf_ver nodes enabled certs mode
  sb_ver=$(core_current_version || true); cf_ver=$(cloudflared_current_version || true)
  nodes=$(jq '.nodes|length' "$SBM_STATE"); enabled=$(jq '[.nodes[]|select(.enabled)]|length' "$SBM_STATE"); certs=$(jq '.certificates|length' "$SBM_STATE"); mode=$(jq -r '.tunnel.mode' "$SBM_STATE")
  printf '%sSB Manager %s%s\n' "$C_BOLD" "$SBM_VERSION" "$C_RESET"
  printf 'sing-box     : %s (%s)\n' "${sb_ver:-未安装}" "$([[ "$SBM_SKIP_SYSTEMD" == 1 ]] && echo 测试模式 || (service_active "$SBM_SERVICE" && echo 运行中 || echo 未运行))"
  printf 'cloudflared  : %s (Tunnel: %s)\n' "${cf_ver:-未安装}" "$mode"
  printf '节点          : %s 个，启用 %s 个\n' "$nodes" "$enabled"
  printf '证书          : %s 个\n' "$certs"
  if [[ -s "$SBM_VAR/updates/sing-box.json" ]]; then
    local pending
    pending=$(jq -r '.latest // ""' "$SBM_VAR/updates/sing-box.json" 2>/dev/null || true)
    [[ -n "$pending" && "$pending" != "$sb_ver" ]] && printf '可用更新      : sing-box %s\n' "$pending"
  fi
}

doctor_run() {
  local failures=0 warnings=0 tmp node id protocol port kind domain path end epoch days
  printf '%s\n' '---- sb doctor ----'
  if jq -e . "$SBM_STATE" >/dev/null 2>&1; then check_line PASS '状态文件 JSON 有效'; else check_line FAIL '状态文件损坏'; ((failures++)); fi
  if [[ -x "$SBM_SING_BOX_BIN" ]]; then check_line PASS "sing-box $(core_current_version)"; else check_line FAIL 'sing-box 核心缺失'; ((failures++)); fi
  if [[ -x "$SBM_CLOUDFLARED_BIN" ]]; then check_line PASS "cloudflared $(cloudflared_current_version)"; else check_line WARN 'cloudflared 未安装或链接缺失'; ((warnings++)); fi
  tmp=$(mktemp "$SBM_RUN/doctor-config.XXXXXX")
  if render_config_from_state "$SBM_STATE" "$tmp" >/dev/null 2>&1 && core_validate_config_with "$SBM_SING_BOX_BIN" "$tmp" "$SBM_RUN/doctor-check.log"; then check_line PASS 'sing-box 配置渲染与语法检查通过'; else check_line FAIL "配置检查失败，详见 $SBM_RUN/doctor-check.log"; ((failures++)); fi
  rm -f "$tmp"
  if [[ "$SBM_SKIP_SYSTEMD" != 1 ]]; then
    if service_active "$SBM_SERVICE"; then check_line PASS "$SBM_SERVICE 正在运行"; else check_line FAIL "$SBM_SERVICE 未运行"; ((failures++)); fi
  fi
  while IFS= read -r node; do
    id=$(jq -r '.id' <<<"$node"); protocol=$(jq -r '.protocol' <<<"$node"); port=$(jq -r '.port' <<<"$node")
    [[ $(jq -r '.enabled' <<<"$node") == true ]] || { check_line WARN "$id 已停用"; ((warnings++)); continue; }
    while IFS= read -r kind; do
      if host_port_in_use "$kind" "$port"; then check_line PASS "$id 监听 ${port}/${kind^^}"; else check_line FAIL "$id 未监听 ${port}/${kind^^}"; ((failures++)); fi
    done < <(node_transport_kinds "$node")
    if [[ "$protocol" == anytls || "$protocol" == hysteria2 ]]; then
      domain=$(jq -r '.domain' <<<"$node"); path="$SBM_CERTS/$domain/fullchain.pem"
      if [[ -s "$path" ]]; then
        end=$(openssl x509 -in "$path" -noout -enddate 2>/dev/null | cut -d= -f2-); epoch=$(date -d "$end" +%s 2>/dev/null || echo 0); days=$(( (epoch-$(date +%s))/86400 ))
        if (( days < 7 )); then check_line FAIL "$domain 证书仅剩 $days 天"; ((failures++)); elif (( days < 20 )); then check_line WARN "$domain 证书剩余 $days 天"; ((warnings++)); else check_line PASS "$domain 证书剩余 $days 天"; fi
      else check_line FAIL "$domain 证书缺失"; ((failures++)); fi
    fi
    if [[ "$protocol" != vmess-ws-cf && -z $(jq -r '.server_address // ""' <<<"$node") ]]; then
      check_line WARN "$id 未设置客户端服务器地址"; ((warnings++))
    else
      local endpoint
      if [[ "$protocol" == vmess-ws-cf ]]; then endpoint=$(jq -r '.domain // ""' <<<"$node"); else endpoint=$(jq -r '.server_address // ""' <<<"$node"); fi
      if [[ -n "$endpoint" && "$endpoint" =~ [A-Za-z] ]]; then
        if getent ahosts "$endpoint" >/dev/null 2>&1; then check_line PASS "$id 的地址可解析：$endpoint"; else check_line WARN "$id 的地址当前无法解析：$endpoint"; ((warnings++)); fi
      fi
    fi
  done < <(jq -c '.nodes[]?' "$SBM_STATE")
  if command_exists timedatectl; then
    if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qx yes; then check_line PASS '系统时间已同步'; else check_line WARN '无法确认系统时间已同步'; ((warnings++)); fi
  fi
  if [[ $(jq -r '.tunnel.mode' "$SBM_STATE") != none && "$SBM_SKIP_SYSTEMD" != 1 ]]; then
    if service_active "$SBM_TUNNEL_SERVICE"; then check_line PASS 'Cloudflare Tunnel 服务运行中'; else check_line FAIL 'Cloudflare Tunnel 已配置但服务未运行'; ((failures++)); fi
  fi
  printf '\n结果：%s 个失败，%s 个警告。\n' "$failures" "$warnings"
  (( failures == 0 ))
}

show_logs() {
  local target=${1:-all} lines=${2:-100}
  [[ "$SBM_SKIP_SYSTEMD" != 1 ]] || { log_warn '测试模式下没有 systemd 日志。'; return; }
  case "$target" in
    singbox|core) journalctl -u "$SBM_SERVICE" -n "$lines" --no-pager -l ;;
    tunnel|cloudflared) journalctl -u "$SBM_TUNNEL_SERVICE" -n "$lines" --no-pager -l ;;
    all) journalctl -u "$SBM_SERVICE" -u "$SBM_TUNNEL_SERVICE" -n "$lines" --no-pager -l ;;
    follow) journalctl -u "$SBM_SERVICE" -u "$SBM_TUNNEL_SERVICE" -f ;;
    *) die "日志目标应为 all、singbox、tunnel 或 follow。";;
  esac
}
