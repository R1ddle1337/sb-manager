#!/usr/bin/env bash
# shellcheck shell=bash

ui_pause() { [[ -t 0 ]] && { printf '\n按 Enter 返回…'; read -r _; }; }
ui_clear() { [[ -t 1 ]] && clear || true; }
ui_header() {
  local service_state enabled mux_state
  ui_clear
  enabled=$(state_enabled_count)
  if [[ "$SBM_SKIP_INIT" == 1 ]]; then
    service_state='测试'
  elif (( enabled == 0 )); then
    service_state='待机'
  elif service_active "$SBM_SERVICE"; then
    service_state='运行中'
  else
    service_state='未运行'
  fi
  printf '%s╭──────────────────── sb-manager ────────────────────╮%s\n' "$C_CYAN" "$C_RESET"
  printf '  版本 %-18s sing-box %-16s\n' "$SBM_VERSION" "$(core_current_version || echo '-')"
  printf '  服务管理 %-16s\n' "$(init_system_label)"
  printf '  服务 %-18s Tunnel %-18s\n' "$service_state" "$(jq -r '.tunnel.mode' "$SBM_STATE")"
  mux_state=$(jq -r 'if .nginx_stream.enabled then ((.nginx_stream.port|tostring) + "/TCP") else "off" end' "$SBM_STATE")
  printf '  Nginx Stream %-36s\n' "$mux_state"
  printf '%s╰─────────────────────────────────────────────────────╯%s\n\n' "$C_CYAN" "$C_RESET"
}

ui_select_node() {
  local __var=$1 allow_all=${2:-0} selected_id choice node i
  local -a ids=()
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    selected_id=$(jq -r '.id' <<<"$node")
    ids+=("$selected_id")
    printf '%d. %-18s %s\n' "${#ids[@]}" "$selected_id" "$(node_protocol_label "$(jq -r '.protocol' <<<"$node")")"
  done < <(state_list_nodes)
  ((${#ids[@]} > 0)) || { log_warn '当前没有节点。'; return 1; }
  [[ "$allow_all" == 1 ]] && printf 'a. 全部节点\n'
  printf 'm. 手动输入节点 ID\n0. 返回\n'
  prompt_value choice '选择节点' '1'
  case "$choice" in
    0) return 1;;
    a|A)
      [[ "$allow_all" == 1 ]] || { log_error '选择无效'; return 1; }
      selected_id=all
      ;;
    m|M) prompt_value selected_id '输入节点 ID' '';;
    * )
      if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && (( choice <= ${#ids[@]} )); then
        selected_id=${ids[$((choice - 1))]}
      else
        selected_id=$choice
      fi
      ;;
  esac
  [[ "$selected_id" == all ]] || state_node_exists "$selected_id" || { log_error "节点不存在：$selected_id"; return 1; }
  printf -v "$__var" '%s' "$selected_id"
}

ui_client_address_default() {
  local domain=${1:-} ipv4 fallback
  [[ -n "$domain" ]] && { printf '%s\n' "$domain"; return 0; }
  ipv4=$(jq -r '.settings.public_ipv4 // ""' "$SBM_STATE")
  [[ -n "$ipv4" ]] || ipv4=$(detect_public_ipv4 2>/dev/null || true)
  [[ -n "$ipv4" ]] && { printf '%s\n' "$ipv4"; return 0; }
  fallback=$(jq -r '.settings.default_server_address // ""' "$SBM_STATE")
  printf '%s\n' "$fallback"
}

ui_require_certificate() {
  local domain=$1
  if [[ ! -s "$SBM_CERTS/$domain/fullchain.pem" || ! -s "$SBM_CERTS/$domain/key.pem" ]]; then
    log_error "尚无 $domain 的完整证书，请先在“域名与证书”中签发。"
    return 1
  fi
}

ui_select_certificate_domain() {
  local __var=$1 choice selected_domain days i cert_domain
  local -a domains=()
  while IFS= read -r cert_domain; do
    [[ -n "$cert_domain" ]] || continue
    [[ -s "$SBM_CERTS/$cert_domain/fullchain.pem" && -s "$SBM_CERTS/$cert_domain/key.pem" ]] || continue
    openssl x509 -in "$SBM_CERTS/$cert_domain/fullchain.pem" -noout -checkend 0 >/dev/null 2>&1 || continue
    domains+=("$cert_domain")
  done < <(jq -r '[.certificates[]?.domain] | unique[]' "$SBM_STATE")

  if ((${#domains[@]} == 0)); then
    log_warn '没有发现可用的已签发证书，请先在“域名与证书”中签发。'
    prompt_value domain '手动输入 TLS 域名' ''
    ui_require_certificate "$domain" || return 1
    printf -v "$__var" '%s' "$domain"
    return 0
  fi

  printf '可用的 TLS 证书：\n'
  for ((i=0; i<${#domains[@]}; i++)); do
    selected_domain=${domains[$i]}
    days=$(x509_days_remaining "$SBM_CERTS/$selected_domain/fullchain.pem" 2>/dev/null || printf '?')
    printf '%d. %s（剩余 %s 天）\n' "$((i + 1))" "$selected_domain" "$days"
  done
  printf 'm. 手动输入域名\n0. 返回\n'
  prompt_value choice '选择 TLS 证书域名' '1'
  case "$choice" in
    m|M)
      prompt_value selected_domain 'TLS 域名（必须已有证书）' ''
      ;;
    0) return 1;;
    * )
      [[ "$choice" =~ ^[1-9][0-9]*$ ]] || { log_error '选择无效'; return 1; }
      (( choice <= ${#domains[@]} )) || { log_error '选择无效'; return 1; }
      selected_domain=${domains[$((choice - 1))]}
      ;;
  esac
  ui_require_certificate "$selected_domain" || return 1
  printf -v "$__var" '%s' "$selected_domain"
}

ui_port_default() {
  local kind=$1; shift
  local port
  for port in "$@"; do
    if ! node_port_in_state "$kind" "$port" && ! host_port_in_use "$kind" "$port"; then
      printf '%s\n' "$port"
      return 0
    fi
  done
  node_choose_port "$kind"
}

ui_prompt_port() {
  local __var=$1 kind=$2 label=$3 suggested
  shift 3
  suggested=$(ui_port_default "$kind" "$@")
  prompt_value "$__var" "$label（推荐 $suggested）" "$suggested"
}

ui_add_node() {
  local choice domain address port name id obfs method security security_choice
  local handshake_server handshake_port congestion_control network strict_mode wildcard_sni
  printf '%s\n' \
    '1. VMess + WebSocket + Cloudflare Tunnel' \
    '2. Shadowsocks 2022' \
    '3. AnyTLS' \
    '4. Hysteria2' \
    '5. Trojan TLS' \
    '6. TUIC（QUIC）' \
    '7. VLESS（TLS/Reality）' \
    '8. NaiveProxy（HTTPS/QUIC）' \
    '9. ShadowTLS v3' \
    '0. 返回'
  prompt_value choice '选择协议' '0'
  case "$choice" in
    1)
      prompt_value name '节点名称' 'VMess WS Cloudflare'; prompt_value domain '固定 Tunnel 域名（Quick Tunnel 可留空）' ''; prompt_value address '客户端连接地址' "$(ui_client_address_default "$domain")"
      local args=(vmess --name "$name")
      [[ -n "$domain" ]] && args+=(--domain "$domain")
      [[ -n "$address" ]] && args+=(--address "$address")
      node_add "${args[@]}"
      ;;
    2)
      prompt_value name '节点名称' 'Shadowsocks 2022'; prompt_value address '客户端连接地址（域名或 IP）' "$(ui_client_address_default '')"; ui_prompt_port port tcp 'TCP 端口' 8388 8389 8390 8443
      printf '1. 2022-blake3-aes-128-gcm（默认）\n2. 2022-blake3-aes-256-gcm\n3. 2022-blake3-chacha20-poly1305\n'; prompt_value method '选择方法' '1'
      case "$method" in 1) method=2022-blake3-aes-128-gcm;; 2) method=2022-blake3-aes-256-gcm;; 3) method=2022-blake3-chacha20-poly1305;; *) log_error '选择无效'; return;; esac
      node_add ss --name "$name" --address "$address" --port "$port" --method "$method"
      ;;
    3)
      prompt_value name '节点名称' 'AnyTLS'; ui_select_certificate_domain domain || return; prompt_value address '客户端连接地址' "$(ui_client_address_default "$domain")"; ui_prompt_port port tcp 'TCP 端口' 443 8443 9443 10443
      node_add anytls --name "$name" --domain "$domain" --address "$address" --port "$port"
      ;;
    4)
      prompt_value name '节点名称' 'Hysteria2'; ui_select_certificate_domain domain || return; prompt_value address '客户端连接地址' "$(ui_client_address_default "$domain")"; ui_prompt_port port udp 'UDP 端口' 443 8443 9443 10443
      prompt_value obfs '启用 salamander 混淆？(y/N)' 'N'
      if [[ "$obfs" =~ ^[Yy]$ ]]; then node_add hy2 --name "$name" --domain "$domain" --address "$address" --port "$port" --obfs salamander; else node_add hy2 --name "$name" --domain "$domain" --address "$address" --port "$port"; fi
      ;;
    5)
      prompt_value name '节点名称' 'Trojan'; ui_select_certificate_domain domain || return
      prompt_value address '客户端连接地址' "$(ui_client_address_default "$domain")"; ui_prompt_port port tcp 'TCP 端口' 443 8443 9443 10443
      node_add trojan --name "$name" --domain "$domain" --address "$address" --port "$port"
      ;;
    6)
      prompt_value name '节点名称' 'TUIC'; ui_select_certificate_domain domain || return
      prompt_value address '客户端连接地址' "$(ui_client_address_default "$domain")"; ui_prompt_port port udp 'UDP 端口' 443 8443 9443 10443
      printf '1. cubic（默认）\n2. new_reno\n3. bbr\n'; prompt_value congestion_control '拥塞控制' '1'
      case "$congestion_control" in 1) congestion_control=cubic;; 2) congestion_control=new_reno;; 3) congestion_control=bbr;; *) log_error '选择无效'; return;; esac
      node_add tuic --name "$name" --domain "$domain" --address "$address" --port "$port" --congestion-control "$congestion_control"
      ;;
    7)
      prompt_value name '节点名称' 'VLESS'
      printf '1. TLS（需要本地证书）\n2. Reality（使用 Reality 密钥对）\n'; prompt_value security_choice '选择安全层' '1'
      case "$security_choice" in
        1)
          security=tls; ui_select_certificate_domain domain || return
          prompt_value address '客户端连接地址' "$(ui_client_address_default "$domain")"; ui_prompt_port port tcp 'TCP 端口' 443 8443 9443 10443
          node_add vless --name "$name" --domain "$domain" --address "$address" --port "$port" --security "$security"
          ;;
        2)
          security=reality; prompt_value domain 'Reality SNI' ''; prompt_value address '客户端连接地址' "$(ui_client_address_default '')"; ui_prompt_port port tcp 'TCP 端口' 443 8443 9443 10443
          prompt_value handshake_server 'Reality 握手域名' ''; prompt_value handshake_port 'Reality 握手端口' '443'
          node_add vless --name "$name" --domain "$domain" --address "$address" --port "$port" --security "$security" --handshake-server "$handshake_server" --handshake-port "$handshake_port"
          ;;
        *) log_error '选择无效';;
      esac
      ;;
    8)
      prompt_value name '节点名称' 'NaiveProxy'; ui_select_certificate_domain domain || return
      prompt_value address '客户端连接地址' "$(ui_client_address_default "$domain")"
      printf '1. HTTPS/TCP（默认）\n2. QUIC/UDP\n'; prompt_value security_choice '选择传输' '1'
      case "$security_choice" in 1) network=tcp;; 2) network=udp;; *) log_error '选择无效'; return;; esac
      ui_prompt_port port "$network" '端口' 443 8443 9443 10443
      node_add naive --name "$name" --domain "$domain" --address "$address" --port "$port" --network "$network"
      ;;
    9)
      prompt_value name '节点名称' 'ShadowTLS'; prompt_value handshake_server '握手目标域名' ''; prompt_value handshake_port '握手目标端口' '443'
      prompt_value address '客户端连接地址' "$(ui_client_address_default '')"; ui_prompt_port port tcp 'TCP 端口' 443 8443 9443 10443
      prompt_value strict_mode '严格模式（true/false）' 'true'; prompt_value wildcard_sni '通配 SNI（off/authed/all）' 'off'
      node_add shadowtls --name "$name" --address "$address" --port "$port" --handshake-server "$handshake_server" --handshake-port "$handshake_port" --strict-mode "$strict_mode" --wildcard-sni "$wildcard_sni"
      ;;
    0) return;; *) log_error '选择无效';;
  esac
}

ui_manage_nodes() {
  local id action value
  ui_select_node id || return
  node_show "$id"
  printf '\n1. 显示分享链接\n2. 启用\n3. 停用\n4. 修改端口\n5. 修改客户端地址\n6. 修改名称\n7. 轮换凭据\n8. 删除\n0. 返回\n'
  prompt_value action '选择操作' '0'
  case "$action" in
    1) node_share "$id" 1;; 2) node_enable "$id";; 3) node_disable "$id";;
    4) prompt_value value '新端口' ''; node_set "$id" --port "$value";;
    5) prompt_value value '新地址' ''; node_set "$id" --address "$value";;
    6) prompt_value value '新名称' ''; node_set "$id" --name "$value";;
    7) confirm '轮换后旧链接会立即失效，继续？' N && node_rotate "$id";;
    8) confirm "确认删除 $id？" N && node_delete "$id";;
  esac
}

ui_share_export_menu() {
  local id
  ui_select_node id 1 || return
  if [[ "$id" == all ]]; then
    node_share_all
    export_all_outbounds
  else
    node_share "$id" 1
  fi
}

ui_cert_menu() {
  local c token zone email domain
  printf '1. 查看证书\n2. 配置 Cloudflare DNS API\n3. 签发/续发域名证书\n4. 立即执行全部续签检查\n5. 查看证书详情\n0. 返回\n'
  prompt_value c '选择操作' '0'
  case "$c" in
    1) cert_list;;
    2) cert_setup_cloudflare;;
    3) prompt_value domain '域名' ''; cert_issue "$domain";;
    4) cert_renew;;
    5) prompt_value domain '域名' ''; cert_inspect "$domain";;
  esac
}

ui_tunnel_menu() {
  local c id domain address
  printf '1. 查看 Tunnel 状态\n2. 配置固定 Tunnel\n3. 启动 Quick Tunnel\n4. 刷新 Quick Tunnel 域名\n5. 更换固定 Tunnel Token\n6. 停止 Tunnel\n0. 返回\n'
  prompt_value c '选择操作' '0'
  case "$c" in
    1) tunnel_status;;
    2) ui_select_node id || return; prompt_value domain 'Tunnel 公网域名' ''; prompt_value address '客户端 add 地址' "$domain"; tunnel_setup_fixed "$id" "$domain" '' "$address";;
    3) ui_select_node id || return; tunnel_setup_quick "$id";;
    4) tunnel_refresh_quick;; 5) tunnel_set_token;; 6) confirm '停止 Tunnel？' N && tunnel_stop;;
  esac
}

ui_update_menu() {
  local c p v
  printf '1. 检查 sing-box 更新\n2. 更新 sing-box 稳定版\n3. 指定 sing-box 版本\n4. 回滚 sing-box\n5. 设置自动更新策略\n6. 更新 cloudflared\n7. 更新 acme.sh\n0. 返回\n'
  prompt_value c '选择操作' '0'
  case "$c" in
    1) core_check_update || true;; 2) core_update latest;; 3) prompt_value v '版本号，如 1.13.19' ''; core_update "$v";; 4) core_rollback;;
    5) printf 'manual / notify / patch / stable\n'; prompt_value p '策略' 'notify'; core_set_policy "$p";; 6) cloudflared_update;; 7) acme_update;;
  esac
}

ui_doctor_menu() {
  local c
  printf '1. 运行完整诊断\n2. 自动修复权限、配置与服务\n3. 协调/重启 sing-box 服务\n4. 查看 sing-box 最近日志\n0. 返回\n'
  prompt_value c '选择操作' '0'
  case "$c" in
    1) doctor_run || true;;
    2) doctor_run 1 || true;;
    3) singbox_service_reconcile && status_summary;;
    4) show_logs singbox 100;;
  esac
}

ui_uninstall_menu() {
  local c phrase
  printf '%s\n' \
    '1. 卸载程序（保留节点、配置、证书、密钥和备份）' \
    '2. 完全卸载（删除程序及全部数据）' \
    '0. 返回'
  prompt_value c '选择操作' '0'
  case "$c" in
    1)
      uninstall_manager 0 0
      ;;
    2)
      printf '%s警告：此操作会删除所有节点、证书、Token、核心和备份，无法撤销。%s\n' "$C_RED" "$C_RESET"
      prompt_value phrase '请输入 DELETE 确认彻底卸载' ''
      [[ "$phrase" == DELETE ]] || { log_warn '确认文字不匹配，已取消。'; return; }
      uninstall_manager 1 1
      ;;
    0) return 0 ;;
    *) log_error '选择无效' ;;
  esac
}

ui_backup_menu() {
  local c path
  printf '1. 创建备份\n2. 从备份恢复\n0. 返回\n'; prompt_value c '选择操作' '0'
  case "$c" in 1) backup_create;; 2) prompt_value path '备份文件路径' ''; confirm '恢复会覆盖当前配置，继续？' N && backup_restore "$path" 1;; esac
}

ui_nginx_stream_menu() {
  local c id sni backend port node
  nginx_stream_status
  printf '\n1. 添加 SNI 路由\n2. 删除 SNI 路由\n3. 启用 443/TCP 复用\n4. 停用 443/TCP 复用\n5. 查看路由\n0. 返回\n'
  prompt_value c '选择操作' '0'
  case "$c" in
    1)
      ui_select_node id || return
      node=$(state_get_node "$id")
      sni=$(nginx_stream_node_sni "$node" 2>/dev/null || true)
      prompt_value sni 'SNI 域名（必须与客户端 server_name 一致）' "$sni"
      prompt_value backend '后端端口（留空自动分配）' ''
      nginx_stream_route_add "$id" "$sni" "$backend"
      ;;
    2)
      prompt_value id '节点 ID' ''
      nginx_stream_route_remove "$id"
      ;;
    3)
      port=$(jq -r '.nginx_stream.port // 443' "$SBM_STATE")
      prompt_value port '公网 TCP 端口' "$port"
      nginx_stream_enable "$port"
      ;;
    4) nginx_stream_disable;;
    5) nginx_stream_route_list;;
  esac
}

ui_settings_menu() {
  local c v strategy_choice
  printf '1. 设置默认服务器地址\n2. 修改日志级别\n3. Nginx Stream 443/TCP 多协议复用\n4. 出站 IP 优先级\n0. 返回\n'; prompt_value c '选择操作' '0'
  case "$c" in
    1) prompt_value v '域名或 IP' ''; settings_set_default_address "$v";;
    2) prompt_value v '日志级别 (trace/debug/info/warn/error/fatal/panic)' 'info'; settings_set_log_level "$v";;
    3) ui_nginx_stream_menu;;
    4)
      printf '1. IPv4 优先（默认）\n2. IPv6 优先\n3. 仅 IPv4\n'; prompt_value strategy_choice '选择出站 IP 策略' '1'
      case "$strategy_choice" in 1) settings_set_outbound_ip_strategy prefer_ipv4;; 2) settings_set_outbound_ip_strategy prefer_ipv6;; 3) settings_set_outbound_ip_strategy ipv4_only;; *) log_error '选择无效';; esac
      ;;
  esac
}

ui_main() {
  [[ -t 0 ]] || { sb_help; return; }
  local choice
  while true; do
    ui_header
    printf '1. 查看运行状态\n2. 添加协议节点\n3. 管理现有节点\n4. 分享链接与客户端导出\n5. 域名与证书管理\n6. Cloudflare Tunnel 管理\n7. 核心与组件更新\n8. 日志\n9. 诊断与修复\n10. 备份与恢复\n11. 全局设置\n12. 卸载与彻底清理\n0. 退出\n\n'
    prompt_value choice '请选择' '0'
    case "$choice" in
      1) status_summary; node_list;; 2) ui_add_node;; 3) ui_manage_nodes;;
      4) ui_share_export_menu || continue;;
      5) ui_cert_menu;; 6) ui_tunnel_menu;; 7) ui_update_menu;; 8) show_logs all 100;; 9) ui_doctor_menu;; 10) ui_backup_menu;; 11) ui_settings_menu;;
      12) ui_uninstall_menu; [[ ${SBM_UNINSTALLED:-0} == 1 ]] && return;;
      0) return;; *) log_error '选择无效';;
    esac
    ui_pause
  done
}
