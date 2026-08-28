#!/usr/bin/env bash
# shellcheck shell=bash

check_line() {
  local level=$1
  shift
  case "$level" in
    PASS) printf '%s[PASS]%s %s\n' "$C_GREEN" "$C_RESET" "$*" ;;
    WARN) printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" ;;
    FAIL) printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" ;;
  esac
}

status_summary() {
  local sb_ver cf_ver nodes enabled certs mode service_state backend mux_state mux_port
  sb_ver=$(core_current_version || true)
  cf_ver=$(cloudflared_current_version || true)
  nodes=$(jq '.nodes|length' "$SBM_STATE")
  enabled=$(state_enabled_count)
  certs=$(jq '.certificates|length' "$SBM_STATE")
  mode=$(jq -r '.tunnel.mode' "$SBM_STATE")
  mux_state=$(jq -r '.nginx_stream.enabled // false' "$SBM_STATE")
  mux_port=$(jq -r '.nginx_stream.port // 443' "$SBM_STATE")
  backend=$(init_system_label)
  if [[ "$SBM_SKIP_INIT" == 1 ]]; then
    service_state='测试模式'
  elif (( enabled == 0 )) && [[ $(jq -r '.api.enabled // false' "$SBM_STATE") != true ]]; then
    service_state='待机（无启用节点）'
  elif service_active "$SBM_SERVICE"; then
    service_state='运行中'
  else
    service_state='未运行'
  fi
  printf '%sSB Manager %s%s\n' "$C_BOLD" "$SBM_VERSION" "$C_RESET"
  printf '服务管理      : %s\n' "$backend"
  printf 'sing-box     : %s (%s)\n' "${sb_ver:-未安装}" "$service_state"
  printf 'cloudflared  : %s (Tunnel: %s)\n' "${cf_ver:-未安装}" "$mode"
  printf '节点          : %s 个，启用 %s 个\n' "$nodes" "$enabled"
  printf '证书          : %s 个\n' "$certs"
  printf 'Nginx复用     : %s (%s/TCP)\n' "$([[ "$mux_state" == true ]] && echo '启用' || echo '停用')" "$mux_port"
  if [[ -s "$SBM_VAR/updates/sing-box.json" ]]; then
    local pending
    pending=$(jq -r '.latest // ""' "$SBM_VAR/updates/sing-box.json" 2>/dev/null || true)
    [[ -n "$pending" && "$pending" != "$sb_ver" ]] && printf '可用更新      : sing-box %s\n' "$pending"
  fi
}

doctor_repair_runtime() {
  require_root
  local candidate preflight_rc=0
  log_info "修复核心链接、路径权限、配置权限与 $(init_system_label) 运行状态…"
  if [[ ! -x "$SBM_SING_BOX_BIN" ]]; then
    candidate=$(find "$SBM_CORE_DIR/sing-box" -mindepth 2 -maxdepth 2 -type f -name sing-box -perm -u+x -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1 {sub(/^[^ ]+ /, ""); print; exit}')
    [[ -n "$candidate" ]] || die '未找到可用于修复的 sing-box 核心，请重新执行安装命令。'
    ln -sfn "$candidate" "$SBM_SING_BOX_BIN"
  fi
  if [[ ! -x "$SBM_CLOUDFLARED_BIN" ]]; then
    candidate=$(find "$SBM_CORE_DIR/cloudflared" -mindepth 2 -maxdepth 2 -type f -name cloudflared -perm -u+x -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1 {sub(/^[^ ]+ /, ""); print; exit}')
    [[ -z "$candidate" ]] || ln -sfn "$candidate" "$SBM_CLOUDFLARED_BIN"
  fi
  ensure_program_permissions
  prepare_singbox_binary_for_backend "$(readlink -f "$SBM_SING_BOX_BIN")"
  if [[ $(jq -r '.nginx_stream.enabled // false' "$SBM_STATE" 2>/dev/null || true) == true ]] && declare -F nginx_stream_prepare_binary_for_backend >/dev/null 2>&1; then
    nginx_stream_prepare_binary_for_backend "$SBM_NGINX_STREAM_BIN" "$(effective_init_system)"
  fi
  if id "$SBM_SERVICE_USER" >/dev/null 2>&1; then
    set_group_if_exists "$SBM_SERVICE_USER" "$SBM_ETC"
    set_group_if_exists "$SBM_SERVICE_USER" "$SBM_GENERATED_DIR"
    set_group_if_exists "$SBM_SERVICE_USER" "$SBM_CERTS"
    set_group_if_exists "$SBM_SERVICE_USER" "$SBM_CONFIG"
    set_group_if_exists "$SBM_SERVICE_USER" "$SBM_VAR"
    chmod 0750 "$SBM_ETC" "$SBM_GENERATED_DIR" "$SBM_CERTS" "$SBM_VAR" 2>/dev/null || true
    chmod 0640 "$SBM_CONFIG" 2>/dev/null || true
    if [[ -d "$SBM_VAR/cloudflared-home" ]]; then
      chown "$SBM_SERVICE_USER":"$SBM_SERVICE_USER" "$SBM_VAR/cloudflared-home" 2>/dev/null || true
      chmod 0750 "$SBM_VAR/cloudflared-home" 2>/dev/null || true
    fi
    if [[ -d "$SBM_LOG_DIR" ]]; then
      chown "$SBM_SERVICE_USER":"$SBM_SERVICE_USER" "$SBM_LOG_DIR" 2>/dev/null || true
      chmod 0750 "$SBM_LOG_DIR" 2>/dev/null || true
    fi
  fi
  render_current_config
  service_user_can_execute_core || die "$SBM_SERVICE_USER 仍无法执行 sing-box 核心。"
  service_user_can_read_config || die "$SBM_SERVICE_USER 仍无法读取生成配置。"
  if [[ "$SBM_SKIP_INIT" != 1 ]]; then
    service_exists "$SBM_SERVICE" || die "缺少 $(service_file_path "$SBM_SERVICE")，请重新执行安装命令。"
    service_stop "$SBM_SERVICE"
    service_reload_manager
    service_reset_failed "$SBM_SERVICE"
    if [[ $(init_system 2>/dev/null || true) == systemd ]]; then
      systemd_exec_preflight "$SBM_SING_BOX_BIN" || preflight_rc=$?
      case "$preflight_rc" in
        0) ;;
        2) log_warn 'systemd-run 不可用，跳过沙箱执行预检。' ;;
        *) runtime_exec_diagnostics "$SBM_SING_BOX_BIN"; die 'systemd 沙箱仍无法执行 sing-box。' ;;
      esac
      preflight_rc=0
      systemd_runtime_preflight "$SBM_SING_BOX_BIN" "$SBM_CONFIG" || preflight_rc=$?
      case "$preflight_rc" in
        0) ;;
        2) log_warn 'systemd-run 不可用，跳过实际启动预检。' ;;
        *) runtime_exec_diagnostics "$SBM_SING_BOX_BIN"; die 'sing-box 仍无法在 systemd 沙箱中完成实际启动。' ;;
      esac
    fi
    singbox_service_reconcile
    if declare -F nginx_stream_reconcile >/dev/null 2>&1; then nginx_stream_reconcile; fi
    if [[ $(jq -r '.tunnel.mode' "$SBM_STATE") != none ]]; then tunnel_reconcile 1; fi
  fi
  log_ok '自动修复流程完成。'
}

doctor_service_failure_detail() {
  local unit=$1 backend
  backend=$(init_system 2>/dev/null || true)
  if [[ "$backend" == systemd ]]; then
    local active_state sub_state result exec_status
    active_state=$(systemctl show "$unit" -p ActiveState --value 2>/dev/null || echo unknown)
    sub_state=$(systemctl show "$unit" -p SubState --value 2>/dev/null || echo unknown)
    result=$(systemctl show "$unit" -p Result --value 2>/dev/null || echo unknown)
    exec_status=$(systemctl show "$unit" -p ExecMainStatus --value 2>/dev/null || echo unknown)
    printf '%s/%s，Result=%s，ExecMainStatus=%s\n' "$active_state" "$sub_state" "$result" "$exec_status"
  elif [[ "$backend" == openrc ]]; then
    rc-service "$(service_native_name "$unit")" status 2>&1 | tail -n1 || printf 'OpenRC inactive\n'
  else
    printf 'unknown\n'
  fi
}

doctor_network_probe() {
  local node=$1 id protocol address port domain kind mux_route
  id=$(jq -r '.id' <<<"$node")
  protocol=$(jq -r '.protocol' <<<"$node")
  mux_route=''
  if declare -F nginx_stream_route_for_node >/dev/null 2>&1 && nginx_stream_state_enabled "$SBM_STATE"; then
    mux_route=$(nginx_stream_route_for_node "$SBM_STATE" "$id")
  fi
  if [[ -n "$mux_route" ]] && declare -F nginx_stream_public_node >/dev/null 2>&1; then
    node=$(nginx_stream_public_node "$node")
  fi
  port=$(jq -r '.port' <<<"$node")
  if [[ "$protocol" == vmess-ws-cf ]]; then
    address=$(jq -r '.domain // ""' <<<"$node")
    check_line WARN "$id 使用 Cloudflare Tunnel；公网探测应从 Tunnel 外部客户端执行"
    warnings=$((warnings + 1))
    return 0
  fi
  address=$(jq -r '.server_address // ""' <<<"$node")
  [[ -n "$address" ]] || { check_line WARN "$id 未设置可探测的客户端地址"; warnings=$((warnings + 1)); return 0; }
  if [[ "$address" =~ ^[0-9A-Fa-f:.]+$ ]]; then
    check_line WARN "$id 地址为 IP；仅执行本机服务/防火墙检查"
    warnings=$((warnings + 1))
  elif host_resolves "$address"; then
    check_line PASS "$id 地址可解析：$address"
  else
    check_line WARN "$id 地址无法解析：$address"
    warnings=$((warnings + 1))
  fi
  while IFS= read -r kind; do
    if [[ -n "$mux_route" ]]; then
      if service_active "$SBM_NGINX_STREAM_SERVICE" && host_port_in_use tcp "$port"; then
        check_line PASS "$id 通过 Nginx Stream 监听 ${port}/TCP"
      else
        check_line FAIL "$id 的 Nginx Stream 未监听 ${port}/TCP"
        failures=$((failures + 1))
      fi
      continue
    fi
    if host_port_in_use "$kind" "$port"; then
      check_line PASS "$id 本机监听 ${port}/${kind^^}"
    else
      check_line FAIL "$id 本机未监听 ${port}/${kind^^}"
      failures=$((failures + 1))
    fi
  done < <(node_transport_kinds "$node")
  if [[ "$protocol" == anytls ]]; then
    domain=$(jq -r '.domain // ""' <<<"$node")
    if command_exists openssl && [[ -n "$domain" && "$kind" != udp ]]; then
      if timeout 8 openssl s_client -connect "$(format_hostport "$address" "$port")" -servername "$domain" -brief </dev/null >/dev/null 2>&1; then
        check_line PASS "$id TLS 握手成功（本机出口视角）"
      else
        check_line WARN "$id TLS 握手未完成；可能是本机回环、云安全组或服务端策略限制"
        warnings=$((warnings + 1))
      fi
    fi
  fi
}

doctor_probe() {
  local id=${1:-} node failures=0 warnings=0
  [[ -n "$id" ]] || die '用法：sb probe NODE_ID'
  node=$(state_get_node "$id")
  [[ -n "$node" ]] || die "节点不存在：$id"
  printf '%s\n' "---- 节点探测：$id ----"
  doctor_network_probe "$node"
  printf '结果：%s 个失败，%s 个警告。\n' "$failures" "$warnings"
  (( failures == 0 ))
}

doctor_network_summary() {
  local backend=${1:-} active_firewalls=0 name
  for name in nftables ufw firewalld; do
    if [[ "$backend" == systemd ]] && command_exists systemctl && systemctl is-active --quiet "$name" 2>/dev/null; then
      check_line PASS "检测到运行中的防火墙服务：$name"
      active_firewalls=1
    elif [[ "$backend" == openrc ]] && command_exists rc-service && rc-service "$name" status >/dev/null 2>&1; then
      check_line PASS "检测到运行中的防火墙服务：$name"
      active_firewalls=1
    fi
  done
  if (( active_firewalls == 0 )); then
    check_line WARN '未检测到 nftables、ufw 或 firewalld 运行；请确认云安全组和主机策略已限制开放端口'
    warnings=$((warnings + 1))
  fi
  if [[ "$backend" == systemd || "$backend" == openrc ]] && command_exists ss; then
    if ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -Eq '^\[::\]:'; then
      check_line WARN '存在 IPv6 wildcard TCP 监听；请确认 IPv6 安全组和 DNS 暴露符合预期'
      warnings=$((warnings + 1))
    fi
    if ss -H -lun 2>/dev/null | awk '{print $5}' | grep -Eq '^\[::\]:'; then
      check_line WARN '存在 IPv6 wildcard UDP 监听；请确认 IPv6 安全组和 DNS 暴露符合预期'
      warnings=$((warnings + 1))
    fi
  fi
}

doctor_run() {
  local repair=${1:-0} network=${2:-0} failures=0 warnings=0 tmp node runtime_node id protocol port kind domain path days
  local enabled endpoint core_target backend low_port_required=0 caps preflight_rc

  if [[ "$repair" == 1 ]]; then
    if ! (doctor_repair_runtime); then log_error '自动修复未完成，继续输出诊断结果。'; fi
  fi

  printf '%s\n' '---- sb doctor ----'
  backend=$(init_system 2>/dev/null || true)
  if [[ "$SBM_SKIP_INIT" == 1 ]]; then
    check_line PASS '服务管理器检查已跳过（测试模式）'
  elif [[ "$backend" == systemd || "$backend" == openrc ]]; then
    check_line PASS "服务管理器：$(init_system_label)"
  else
    check_line FAIL '未检测到可用的 systemd 或 OpenRC'
    failures=$((failures + 1))
  fi

  if jq -e . "$SBM_STATE" >/dev/null 2>&1; then check_line PASS '状态文件 JSON 有效'; else check_line FAIL '状态文件损坏'; failures=$((failures + 1)); fi

  local sb_version cf_version core_usable=0
  if [[ -x "$SBM_SING_BOX_BIN" ]]; then
    sb_version=$(core_current_version || true)
    if [[ -n "$sb_version" ]]; then check_line PASS "sing-box $sb_version"; core_usable=1
    else check_line FAIL 'sing-box 文件可执行，但无法读取版本信息'; failures=$((failures + 1)); fi
  else
    check_line FAIL 'sing-box 核心链接缺失、损坏或不可执行'
    failures=$((failures + 1))
  fi

  core_target=$(readlink -f "$SBM_SING_BOX_BIN" 2>/dev/null || true)
  if [[ -n "$core_target" && "$core_target" == "$SBM_CORE_DIR"/* && -x "$core_target" ]]; then
    check_line PASS "核心链接目标有效：$core_target"
  else
    check_line FAIL "核心链接目标异常：${core_target:-无法解析}"
    failures=$((failures + 1))
  fi

  if [[ "$backend" == systemd && -n "$core_target" ]]; then
    caps=$(singbox_file_capabilities "$core_target")
    if [[ -z "$caps" ]]; then
      check_line PASS 'systemd 核心未携带 file capabilities（低端口能力由 unit 提供）'
    else
      check_line FAIL "systemd 核心残留 file capabilities，可能触发 203/EXEC：$caps"
      failures=$((failures + 1))
      check_line WARN '运行 sb repair 可安全清除；不会影响节点、证书或密钥'
      warnings=$((warnings + 1))
    fi
  fi

  if [[ "$backend" == systemd && "$SBM_SKIP_INIT" != 1 && -f "$SBM_SYSTEMD_DIR/$SBM_SERVICE" ]]; then
    if systemd_unit_allows_netlink "$SBM_SERVICE"; then
      check_line PASS 'systemd 地址族策略允许 AF_NETLINK 路由监听'
    else
      check_line FAIL 'systemd 地址族策略缺少 AF_NETLINK；sing-box 会在订阅路由更新时退出'
      failures=$((failures + 1))
      check_line WARN '重新运行最新版安装器，或执行临时修复命令更新 RestrictAddressFamilies'
      warnings=$((warnings + 1))
    fi
  fi

  if declare -F nginx_stream_doctor_check >/dev/null 2>&1; then
    nginx_stream_doctor_check
  fi

  if id "$SBM_SERVICE_USER" >/dev/null 2>&1; then
    if service_user_can_execute_core; then check_line PASS "$SBM_SERVICE_USER 可执行 sing-box 核心"
    else check_line FAIL "$SBM_SERVICE_USER 无法执行 sing-box；通常是核心目录缺少遍历权限"; failures=$((failures + 1)); fi
    if service_user_can_read_config; then check_line PASS "$SBM_SERVICE_USER 可读取生成配置"
    else check_line FAIL "$SBM_SERVICE_USER 无法读取 $SBM_CONFIG"; failures=$((failures + 1)); fi
  else
    check_line FAIL "服务用户 $SBM_SERVICE_USER 不存在"
    failures=$((failures + 1))
  fi

  if [[ "$backend" == systemd && "$SBM_SKIP_INIT" != 1 && "$core_usable" == 1 ]]; then
    preflight_rc=0
    systemd_exec_preflight "$SBM_SING_BOX_BIN" || preflight_rc=$?
    case "$preflight_rc" in
      0) check_line PASS 'sing-box 通过 systemd 沙箱执行预检' ;;
      2) check_line WARN 'systemd-run 不可用，未执行沙箱预检'; warnings=$((warnings + 1)) ;;
      *)
        check_line FAIL 'sing-box 无法在与正式服务相同的 systemd 沙箱中执行'
        failures=$((failures + 1))
        runtime_exec_diagnostics "$SBM_SING_BOX_BIN"
        ;;
    esac
  fi

  if [[ -x "$SBM_CLOUDFLARED_BIN" ]]; then
    cf_version=$(cloudflared_current_version || true)
    if [[ -n "$cf_version" ]]; then check_line PASS "cloudflared $cf_version"
    else check_line WARN 'cloudflared 文件存在，但无法读取版本信息'; warnings=$((warnings + 1)); fi
  else
    check_line WARN 'cloudflared 未安装或链接缺失'
    warnings=$((warnings + 1))
  fi

  tmp=$(mktemp "$SBM_RUN/doctor-config.XXXXXX")
  if (( core_usable == 1 )) && (render_config_from_state "$SBM_STATE" "$tmp" >/dev/null 2>&1 && core_validate_config_with "$SBM_SING_BOX_BIN" "$tmp" "$SBM_RUN/doctor-check.log"); then
    check_line PASS 'sing-box 配置渲染与语法检查通过'
  else
    check_line FAIL "配置检查失败，详见 $SBM_RUN/doctor-check.log"
    failures=$((failures + 1))
  fi
  rm -f "$tmp"

  enabled=$(state_enabled_count)
  if [[ "$SBM_SKIP_INIT" != 1 ]]; then
    if ! service_exists "$SBM_SERVICE"; then
      check_line FAIL "服务定义缺失：$(service_file_path "$SBM_SERVICE")"
      failures=$((failures + 1))
    elif (( enabled == 0 )) && [[ $(jq -r '.api.enabled // false' "$SBM_STATE") != true ]]; then
      if service_active "$SBM_SERVICE"; then
        check_line WARN "$(service_native_name "$SBM_SERVICE") 在无启用节点时仍运行；执行 sb repair 可切换到待机"
        warnings=$((warnings + 1))
      elif service_enabled "$SBM_SERVICE"; then
        check_line WARN "$(service_native_name "$SBM_SERVICE") 当前虽已停止，但仍设置为开机启动；执行 sb repair 可彻底切换到待机"
        warnings=$((warnings + 1))
      else
        check_line PASS "暂无启用节点；$(service_native_name "$SBM_SERVICE") 已禁用并保持停止待机"
      fi
    elif service_active "$SBM_SERVICE"; then
      check_line PASS "$(service_native_name "$SBM_SERVICE") 正在运行"
    else
      check_line FAIL "$(service_native_name "$SBM_SERVICE") 未运行（$(doctor_service_failure_detail "$SBM_SERVICE")）"
      failures=$((failures + 1))
      service_failure_report "$SBM_SERVICE"
      runtime_exec_diagnostics "$SBM_SING_BOX_BIN"
      check_line WARN '可运行：sb repair；仍失败时运行：sb logs singbox 100'
      warnings=$((warnings + 1))
    fi
  fi

  while IFS= read -r node; do
    id=$(jq -r '.id' <<<"$node")
    protocol=$(jq -r '.protocol' <<<"$node")
    runtime_node=$node
    if declare -F nginx_stream_effective_node >/dev/null 2>&1; then runtime_node=$(nginx_stream_effective_node "$SBM_STATE" "$node"); fi
    port=$(jq -r '.port' <<<"$runtime_node")
    if [[ $(jq -r '.enabled' <<<"$node") != true ]]; then
      check_line WARN "$id 已停用"
      warnings=$((warnings + 1))
      continue
    fi
    (( port < 1024 )) && low_port_required=1
    while IFS= read -r kind; do
      if singbox_port_in_use "$kind" "$port"; then check_line PASS "$id 由 sing-box 监听 ${port}/${kind^^}"
      elif host_port_in_use "$kind" "$port"; then check_line FAIL "$id 的 ${port}/${kind^^} 被其他进程占用"; failures=$((failures + 1))
      else check_line FAIL "$id 未监听 ${port}/${kind^^}"; failures=$((failures + 1)); fi
    done < <(node_transport_kinds "$runtime_node")

    if [[ "$protocol" == anytls || "$protocol" == hysteria2 ]]; then
      domain=$(jq -r '.domain' <<<"$node")
      path="$SBM_CERTS/$domain/fullchain.pem"
      if [[ -s "$path" ]]; then
        days=$(x509_days_remaining "$path" 2>/dev/null || echo -1)
        if (( days < 0 )); then check_line WARN "$domain 证书有效期无法解析"; warnings=$((warnings + 1))
        elif (( days < 7 )); then check_line FAIL "$domain 证书仅剩 $days 天"; failures=$((failures + 1))
        elif (( days < 20 )); then check_line WARN "$domain 证书剩余 $days 天"; warnings=$((warnings + 1))
        else check_line PASS "$domain 证书剩余 $days 天"; fi
      else
        check_line FAIL "$domain 证书缺失"
        failures=$((failures + 1))
      fi
    fi

    if [[ "$protocol" != vmess-ws-cf && -z $(jq -r '.server_address // ""' <<<"$node") ]]; then
      check_line WARN "$id 未设置客户端服务器地址"
      warnings=$((warnings + 1))
    else
      if [[ "$protocol" == vmess-ws-cf ]]; then endpoint=$(jq -r '.domain // ""' <<<"$node"); else endpoint=$(jq -r '.server_address // ""' <<<"$node"); fi
      if [[ -n "$endpoint" && "$endpoint" =~ [A-Za-z] ]]; then
        if host_resolves "$endpoint"; then check_line PASS "$id 的地址可解析：$endpoint"
        else check_line WARN "$id 的地址当前无法解析：$endpoint"; warnings=$((warnings + 1)); fi
      fi
    fi
  done < <(jq -c '.nodes[]?' "$SBM_STATE")

  if [[ "$network" == 1 ]]; then
    printf '%s\n' '---- 网络探测（本机出口视角）----'
    doctor_network_summary "$backend"
    while IFS= read -r node; do
      [[ -n "$node" ]] && doctor_network_probe "$node"
    done < <(jq -c '.nodes[]? | select(.enabled==true)' "$SBM_STATE")
  fi

  if [[ "$backend" == openrc && "$low_port_required" == 1 ]]; then
    if singbox_has_bind_capability "${core_target:-$SBM_SING_BOX_BIN}"; then check_line PASS 'OpenRC sing-box 核心具备低端口绑定能力'
    else check_line FAIL 'OpenRC sing-box 核心缺少 cap_net_bind_service；运行 sb repair'; failures=$((failures + 1)); fi
  fi
  if [[ "$backend" == openrc && $(jq -r '.nginx_stream.enabled // false' "$SBM_STATE") == true ]] && (( $(jq -r '.nginx_stream.port' "$SBM_STATE") < 1024 )); then
    if nginx_stream_file_capabilities "$SBM_NGINX_STREAM_OPENRC_BIN" | grep -q cap_net_bind_service; then
      check_line PASS 'OpenRC Nginx 核心具备低端口绑定能力'
    else
      check_line FAIL 'OpenRC Nginx 核心缺少 cap_net_bind_service；运行 sb repair'; failures=$((failures + 1))
    fi
  fi

  if command_exists timedatectl; then
    if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qx yes; then check_line PASS '系统时间已同步'
    else check_line WARN '无法确认系统时间已同步'; warnings=$((warnings + 1)); fi
  elif [[ "$backend" == openrc ]]; then
    if service_active chronyd || service_active ntpd || service_active openntpd; then check_line PASS '检测到 OpenRC 时间同步服务运行中'
    else check_line WARN '未检测到运行中的 chronyd/ntpd；请确认系统时间准确'; warnings=$((warnings + 1)); fi
  fi

  local available_kib inode_use manifest
  available_kib=$(df -Pk "$SBM_VAR" 2>/dev/null | awk 'NR==2 {print $4}')
  if [[ "$available_kib" =~ ^[0-9]+$ ]] && (( available_kib < 102400 )); then
    check_line WARN "$SBM_VAR 可用空间不足 100 MiB"; warnings=$((warnings + 1))
  else
    check_line PASS "数据目录磁盘空间充足（${available_kib:-未知} KiB 可用）"
  fi
  inode_use=$(df -Pi "$SBM_VAR" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
  if [[ "$inode_use" =~ ^[0-9]+$ ]] && (( inode_use >= 90 )); then
    check_line WARN "数据目录 inode 使用率 ${inode_use}%"; warnings=$((warnings + 1))
  fi
  manifest="$SBM_VAR/install-manifest.json"
  if [[ -s "$manifest" ]] && jq -e '.schema_version==1 and (.artifacts|type=="array")' "$manifest" >/dev/null 2>&1; then
    check_line PASS '安装资产来源清单有效'
  else
    check_line WARN '尚无完整安装资产来源清单；下次经新版安装器更新后生成'; warnings=$((warnings + 1))
  fi

  if [[ $(jq -r '.tunnel.mode' "$SBM_STATE") != none && "$SBM_SKIP_INIT" != 1 ]]; then
    if service_active "$SBM_TUNNEL_SERVICE"; then check_line PASS 'Cloudflare Tunnel 服务运行中'
    else check_line FAIL 'Cloudflare Tunnel 已配置但服务未运行'; failures=$((failures + 1)); fi
  fi

  if [[ "$SBM_SKIP_INIT" != 1 && -d "$SBM_SUBSCRIPTIONS" ]] && find "$SBM_SUBSCRIPTIONS" -maxdepth 1 -name '*.meta.json' -type f -print -quit | grep -q .; then
    if service_active "$SBM_SUBSCRIPTION_SERVICE"; then
      if ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "^127\\.0\\.0\\.1:${SBM_SUBSCRIPTION_PORT}$|^\\[::1\\]:${SBM_SUBSCRIPTION_PORT}$"; then
        check_line PASS '订阅服务仅监听 loopback'
      else
        check_line FAIL '订阅服务未按预期监听 loopback'; failures=$((failures + 1))
      fi
    else
      check_line FAIL '存在订阅但订阅服务未运行'; failures=$((failures + 1))
    fi
  fi
  if [[ $(jq -r '.api.enabled // false' "$SBM_STATE") == true ]]; then
    local api_port
    api_port=$(jq -r '.api.port' "$SBM_STATE")
    if ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Fxq "127.0.0.1:$api_port"; then
      check_line PASS 'sing-box API 仅监听 loopback'
    else
      check_line FAIL 'sing-box API 未按预期监听 loopback'; failures=$((failures + 1))
    fi
  fi
  printf '\n结果：%s 个失败，%s 个警告。\n' "$failures" "$warnings"
  (( failures == 0 ))
}

doctor_repair() { doctor_run 1; }

show_logs() {
  local target=${1:-all} lines=${2:-100}
  [[ "$SBM_SKIP_INIT" != 1 ]] || { log_warn '测试模式下没有服务日志。'; return; }
  case "$target" in
    singbox|core) service_logs "$SBM_SERVICE" "$lines" 0 ;;
    tunnel|cloudflared) service_logs "$SBM_TUNNEL_SERVICE" "$lines" 0 ;;
    nginx|mux|nginx-stream) service_logs "$SBM_NGINX_STREAM_SERVICE" "$lines" 0 ;;
    all)
      printf '%s\n' '---- sing-box ----'
      service_logs "$SBM_SERVICE" "$lines" 0 || true
      printf '%s\n' '---- cloudflared ----'
      service_logs "$SBM_TUNNEL_SERVICE" "$lines" 0 || true
      if nginx_stream_state_enabled "$SBM_STATE"; then
        printf '%s\n' '---- nginx stream ----'
        service_logs "$SBM_NGINX_STREAM_SERVICE" "$lines" 0 || true
      fi
      ;;
    follow)
      if [[ $(init_system) == systemd ]]; then journalctl -u "$SBM_SERVICE" -u "$SBM_TUNNEL_SERVICE" -u "$SBM_NGINX_STREAM_SERVICE" -f
      else service_logs "$SBM_SERVICE" "$lines" 1; fi
      ;;
    *) die '日志目标应为 all、singbox、tunnel、nginx 或 follow。' ;;
  esac
}
