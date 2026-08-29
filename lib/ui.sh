#!/usr/bin/env bash
# shellcheck shell=bash

ui_pause() { [[ -t 0 ]] && { printf '\n按 Enter 返回…'; read -r _; }; }
ui_clear() { [[ -t 1 ]] && clear || true; }
ui_header() {
  local service_state enabled mux_state traffic_count notify_state health_state
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
  traffic_count=$(jq '[.nodes[]? | select(.traffic.enabled==true)] | length' "$SBM_STATE")
  printf '  流量控制 %-36s\n' "${traffic_count} 个节点"
  notify_state=$(jq -r 'if .notifications.enabled then .notifications.provider else "off" end' "$SBM_STATE")
  health_state=$(jq -r 'if .health.enabled then "on" else "off" end' "$SBM_STATE")
  printf '  通知 %-18s 健康检查 %-16s\n' "$notify_state" "$health_state"
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
  local choice domain address port name id obfs method security security_choice snell_obfs_choice snell_obfs_host
  local hy2_obfs_choice hy2_min_packet_size hy2_max_packet_size hy2_disable_chrome hy2_bbr_profile hy2_brutal_debug
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
    '10. Snell v5（需要 sing-box 1.14+）' \
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
      printf '1. 2022-blake3-aes-128-gcm\n2. 2022-blake3-aes-256-gcm（默认）\n3. 2022-blake3-chacha20-poly1305\n'; prompt_value method '选择方法' '2'
      case "$method" in 1) method=2022-blake3-aes-128-gcm;; 2) method=2022-blake3-aes-256-gcm;; 3) method=2022-blake3-chacha20-poly1305;; *) log_error '选择无效'; return;; esac
      node_add ss --name "$name" --address "$address" --port "$port" --method "$method"
      ;;
    3)
      prompt_value name '节点名称' 'AnyTLS'; ui_select_certificate_domain domain || return; prompt_value address '客户端连接地址' "$(ui_client_address_default "$domain")"; ui_prompt_port port tcp 'TCP 端口' 443 8443 9443 10443
      node_add anytls --name "$name" --domain "$domain" --address "$address" --port "$port"
      ;;
    4)
      prompt_value name '节点名称' 'Hysteria2'; ui_select_certificate_domain domain || return; prompt_value address '客户端连接地址' "$(ui_client_address_default "$domain")"; ui_prompt_port port udp 'UDP 端口' 443 8443 9443 10443
      printf '1. 不启用混淆（默认）\n2. Salamander\n3. Gecko（1.14+，可调包长）\n'; prompt_value hy2_obfs_choice '选择 Hysteria2 混淆' '1'
      local -a hy2_args=(hy2 --name "$name" --domain "$domain" --address "$address" --port "$port")
      case "$hy2_obfs_choice" in
        1) ;;
        2) hy2_args+=(--obfs salamander) ;;
        3)
          prompt_value hy2_min_packet_size 'Gecko 最小包长' '512'; prompt_value hy2_max_packet_size 'Gecko 最大包长' '1200'
          hy2_args+=(--obfs gecko --obfs-min-packet-size "$hy2_min_packet_size" --obfs-max-packet-size "$hy2_max_packet_size") ;;
        *) log_error '选择无效'; return ;;
      esac
      prompt_value hy2_disable_chrome '关闭 Chrome QUIC 指纹伪装？(y/N)' 'N'
      [[ "$hy2_disable_chrome" =~ ^[Yy]$ ]] && hy2_args+=(--disable-chrome-parrot)
      printf '1. standard（默认）\n2. conservative\n3. aggressive\n4. 不显式设置\n'; prompt_value hy2_bbr_profile 'BBR profile' '4'
      case "$hy2_bbr_profile" in
        1) hy2_args+=(--bbr-profile standard) ;;
        2) hy2_args+=(--bbr-profile conservative) ;;
        3) hy2_args+=(--bbr-profile aggressive) ;;
        4) ;;
        *) log_error '选择无效'; return ;;
      esac
      prompt_value hy2_brutal_debug '启用 Hysteria Brutal 调试日志？(y/N)' 'N'
      [[ "$hy2_brutal_debug" =~ ^[Yy]$ ]] && hy2_args+=(--brutal-debug)
      node_add "${hy2_args[@]}"
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
          security=reality; prompt_value domain 'Reality SNI' 'www.apple.com'; prompt_value address '客户端连接地址' "$(ui_client_address_default '')"; ui_prompt_port port tcp 'TCP 端口' 443 8443 9443 10443
          prompt_value handshake_server 'Reality 握手域名' 'www.apple.com'; prompt_value handshake_port 'Reality 握手端口' '443'
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
    10)
      prompt_value name '节点名称' 'Snell'; prompt_value address '客户端连接地址（域名或 IP）' "$(ui_client_address_default '')"; ui_prompt_port port tcp 'TCP 端口' 6160 443 8443 9443 10443
      printf '1. 不启用 HTTP 混淆（默认）\n2. HTTP 混淆\n'; prompt_value snell_obfs_choice '选择混淆' '1'
      case "$snell_obfs_choice" in
        1) obfs=none; node_add snell --name "$name" --address "$address" --port "$port" --obfs none ;;
        2) prompt_value snell_obfs_host 'HTTP 混淆 Host' 'bing.com'; node_add snell --name "$name" --address "$address" --port "$port" --obfs http --obfs-host "$snell_obfs_host" ;;
        *) log_error '选择无效';;
      esac
      ;;
    0) return;; *) log_error '选择无效';;
  esac
}

ui_manage_nodes() {
  local id action value remark region purpose line tags
  ui_select_node id || return
  node_show "$id"
  printf '\n1. 显示分享链接\n2. 启用\n3. 停用\n4. 修改端口\n5. 修改客户端地址\n6. 修改名称\n7. 修改备注、地区与标签\n8. 轮换凭据\n9. 删除\n0. 返回\n'
  prompt_value action '选择操作' '0'
  case "$action" in
    1) node_share "$id" 1;; 2) node_enable "$id";; 3) node_disable "$id";;
    4) prompt_value value '新端口' ''; node_set "$id" --port "$value";;
    5) prompt_value value '新地址' ''; node_set "$id" --address "$value";;
    6) prompt_value value '新名称' ''; node_set "$id" --name "$value";;
    7)
      remark=$(jq -r '.metadata.remark' <<<"$(state_get_node "$id")"); region=$(jq -r '.metadata.region' <<<"$(state_get_node "$id")")
      purpose=$(jq -r '.metadata.purpose' <<<"$(state_get_node "$id")"); line=$(jq -r '.metadata.line' <<<"$(state_get_node "$id")")
      tags=$(jq -r '.metadata.tags|join(",")' <<<"$(state_get_node "$id")")
      prompt_value remark '备注' "$remark"; prompt_value region '地区' "$region"; prompt_value purpose '用途' "$purpose"
      prompt_value line '线路/运营商' "$line"; prompt_value tags '标签（逗号分隔）' "$tags"
      node_set "$id" --remark "$remark" --region "$region" --purpose "$purpose" --line "$line" --tags "$tags"
      ;;
    8) confirm '轮换后旧链接会立即失效，继续？' N && node_rotate "$id";;
    9) confirm "确认删除 $id？" N && node_delete "$id";;
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

ui_client_export_menu() {
  local mode_choice mode output dns_mode dns_address
  printf '1. 导出 mixed 客户端配置\n2. 导出 TUN 客户端配置\n0. 返回\n'
  prompt_value mode_choice '选择客户端配置模式' '1'
  case "$mode_choice" in
    1) mode=mixed; output="$SBM_EXPORTS/client-mixed.json";;
    2) mode=tun; output="$SBM_EXPORTS/client-tun.json";;
    0) return;;
    *) log_error '选择无效'; return;;
  esac
  prompt_value output '输出文件' "$output"
  dns_mode=hijack; dns_address=''
  if [[ "$mode" == tun ]] && version_ge "$(core_current_version)" 1.14.0-rc.1; then
    printf '1. hijack（默认，设置系统 DNS 并劫持 53 端口）\n2. native（仅设置系统 DNS）\n3. disabled（不改系统 DNS）\n'
    prompt_value dns_mode 'TUN DNS 模式' '1'
    case "$dns_mode" in 1) dns_mode=hijack;; 2) dns_mode=native;; 3) dns_mode=disabled;; *) log_error '选择无效'; return;; esac
    if [[ "$dns_mode" != disabled ]]; then prompt_value dns_address 'DNS 地址（留空使用自动地址）' ''; fi
  fi
  export_client_config "$output" "$mode" "$dns_mode" "$dns_address"
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
  local c p v path
  printf '1. 检查 sing-box 更新\n2. 更新 sing-box 最新版\n3. 指定 sing-box 版本\n4. 回滚 sing-box\n5. 设置自动更新策略\n6. 更新 cloudflared\n7. 更新 acme.sh\n8. 导出 sing-box 1.14 JSON Schema\n9. 查看核心 build tags 与能力\n0. 返回\n'
  prompt_value c '选择操作' '0'
  case "$c" in
    1) core_check_update || true;; 2) core_update latest;; 3) prompt_value v '版本号，如 1.14.0-rc.1' ''; core_update "$v";; 4) core_rollback;;
    5) printf 'manual / notify / patch / stable\n'; prompt_value p '策略' 'notify'; core_set_policy "$p";; 6) cloudflared_update;; 7) acme_update;;
    8) prompt_value path 'Schema 输出文件' "$SBM_EXPORTS/sing-box-schema.json"; core_schema "$path";;
    9) core_capabilities;;
  esac
}

ui_api_menu() {
  local c port dashboard path command
  api_status
  printf '\n1. 启用 API\n2. 启用 API + Dashboard\n3. 停用 API/Dashboard\n4. 显示 API 令牌\n5. 查看 API 服务状态\n6. 查看 API outbounds\n7. 导出 sing-box JSON Schema\n0. 返回\n'
  prompt_value c '选择操作' '0'
  case "$c" in
    1|2)
      port=$(jq -r '.api.port // 9090' "$SBM_STATE")
      prompt_value port 'API loopback 端口' "$port"
      if [[ "$c" == 2 ]]; then api_enable "$port" true; else api_enable "$port" false; fi
      ;;
    3) confirm '确认停用 API/Dashboard？' N && api_disable;;
    4) api_show_token;;
    5) api_cli status;;
    6) api_cli outbounds;;
    7) path="$SBM_EXPORTS/sing-box-schema.json"; prompt_value path 'Schema 输出文件' "$path"; core_schema "$path";;
  esac
}

ui_doctor_menu() {
  local c
  printf '1. 运行完整诊断\n2. 自动修复权限、配置与服务\n3. 低风险自动修复（不改防火墙/SSH/内核）\n4. 协调/重启 sing-box 服务\n5. 查看 sing-box 最近日志\n0. 返回\n'
  prompt_value c '选择操作' '0'
  case "$c" in
    1) doctor_run || true;;
    2) doctor_run 1 || true;;
    3) doctor_run 0 0 1 || true;;
    4) singbox_service_reconcile && status_summary || true;;
    5) show_logs singbox 100;;
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
  local c v strategy_choice dns_choice dns_value
  printf '1. 设置默认服务器地址\n2. 修改日志级别\n3. Nginx Stream 443/TCP 多协议复用\n4. 出站 IP 优先级\n5. 配置校验与差异预览\n6. sing-box 1.14 DNS 优化\n0. 返回\n'; prompt_value c '选择操作' '0'
  case "$c" in
    1) prompt_value v '域名或 IP' ''; settings_set_default_address "$v";;
    2) prompt_value v '日志级别 (trace/debug/info/warn/error/fatal/panic)' 'info'; settings_set_log_level "$v";;
    3) ui_nginx_stream_menu;;
    4)
      printf '1. IPv4 优先（默认）\n2. IPv6 优先\n3. 仅 IPv4\n'; prompt_value strategy_choice '选择出站 IP 策略' '1'
      case "$strategy_choice" in 1) settings_set_outbound_ip_strategy prefer_ipv4;; 2) settings_set_outbound_ip_strategy prefer_ipv6;; 3) settings_set_outbound_ip_strategy ipv4_only;; *) log_error '选择无效';; esac
      ;;
    5)
      printf '1. 校验当前配置\n2. 查看已安装配置与当前状态差异\n3. 查看 state.json（敏感字段已遮蔽）\n0. 返回\n'; prompt_value v '选择操作' '0'
      case "$v" in 1) config_validate || true;; 2) config_diff || true;; 3) config_redact <"$SBM_STATE";; esac
      ;;
    6)
      printf '1. 查看 DNS 1.14 设置\n2. 开启 optimistic DNS\n3. 关闭 optimistic DNS\n4. 设置 optimistic 缓存窗口\n5. 设置 DNS 查询超时\n0. 返回\n'; prompt_value dns_choice '选择操作' '0'
      case "$dns_choice" in
        1) settings_show_addresses 1 | jq '{dns_optimistic,dns_optimistic_timeout,dns_timeout}';;
        2) settings_set_dns optimistic true;;
        3) settings_set_dns optimistic false;;
        4) prompt_value dns_value '缓存窗口（如 3d）' '3d'; settings_set_dns optimistic-timeout "$dns_value";;
        5) prompt_value dns_value 'DNS 超时（如 10s）' '10s'; settings_set_dns timeout "$dns_value";;
      esac
      ;;
  esac
}

ui_template_menu() {
  local c name id tag region
  node_template_list
  printf '\n1. 从节点保存模板\n2. 使用模板创建节点\n3. 删除模板\n4. 按标签启用节点\n5. 按标签停用节点\n0. 返回\n'
  prompt_value c '选择操作' '0'
  case "$c" in
    1) prompt_value name '模板名称' ''; ui_select_node id || return; node_template_save "$name" "$id" ;;
    2) prompt_value name '模板名称' ''; prompt_value id '新节点 ID' ''; node_template_add "$name" "$id" ;;
    3) prompt_value name '模板名称' ''; confirm "确认删除模板 $name？" N && node_template_delete "$name" ;;
    4) prompt_value tag '标签' ''; node_batch_enable "$tag" '' ;;
    5) prompt_value tag '标签' ''; node_batch_disable "$tag" '' ;;
  esac
}

ui_firewall_menu() {
  local c
  printf '1. 查看防火墙组件状态\n2. 查看所有协议端口\n3. 备份并清理 iptables 入站全局禁止\n4. 按所有启用协议端口执行 UFW allow\n5. 安装并启用 Fail2ban（自动探测 SSH，3分钟/5次/永久封禁）\n6. 安装并启用 UFW（安全向导：实际 SSH、22/80/443 及协议端口）\n7. 仅预览 UFW 变更\n0. 返回\n'
  prompt_value c '选择操作' '0'
  case "$c" in
    1) firewall_status ;;
    2) firewall_list_protocol_ports ;;
    3) confirm '将备份并移除 INPUT 链全局 DROP/REJECT，必要时调整默认策略，继续？' N && firewall_clear_iptables_input_deny 1 ;;
    4)
      firewall_list_protocol_ports
      command_exists ufw || { log_error '未安装 UFW；请使用发行版包管理器安装（Alpine：apk add ufw）。'; return; }
      confirm '将为所有启用协议端口执行 UFW allow，继续？' N && firewall_ufw_allow_protocol_ports 1
      ;;
    5) firewall_setup_fail2ban ;;
    6) firewall_setup_ufw ;;
    7) firewall_setup_ufw 0 1 ;;
  esac
}

ui_notification_health_menu() {
  local c provider token destination thresholds warn_days
  notification_status
  health_status
  printf '\n1. 配置 Telegram 通知\n2. 配置企业微信机器人\n3. 配置通用 Webhook\n4. 发送测试通知\n5. 停用通知\n6. 立即检查流量阈值\n7. 启用定时健康检查\n8. 停用定时健康检查\n9. 立即运行健康检查\n10. 配置资源/安全告警阈值\n0. 返回\n'
  prompt_value c '选择操作' '0'
  case "$c" in
    1)
      provider=telegram; prompt_secret token 'Telegram Bot Token'; prompt_value destination 'Telegram Chat ID' ''
      prompt_value thresholds '流量阈值（逗号分隔）' '80,90,100'; notification_configure "$provider" "$token" "$destination" "$thresholds"
      ;;
    2|3)
      [[ "$c" == 2 ]] && provider=wecom || provider=webhook
      prompt_secret token 'Webhook URL'; prompt_value thresholds '流量阈值（逗号分隔）' '80,90,100'
      notification_configure "$provider" "$token" '' "$thresholds"
      ;;
    4) notification_test ;;
    5) notification_disable ;;
    6) with_lock notification_traffic_check_unlocked ;;
    7) warn_days=$(jq -r '.health.certificate_warn_days' "$SBM_STATE"); prompt_value warn_days '证书提前预警天数' "$warn_days"; health_enable "$warn_days" ;;
    8) health_disable ;;
    9) health_check || true ;;
    10)
      local disk_free memory_max load_max
      disk_free=$(jq -r '.health.resources.disk_min_free_percent' "$SBM_STATE"); memory_max=$(jq -r '.health.resources.memory_max_percent' "$SBM_STATE"); load_max=$(jq -r '.health.resources.cpu_load_per_core_max' "$SBM_STATE")
      prompt_value disk_free '磁盘剩余最小百分比' "$disk_free"; prompt_value memory_max '内存最大百分比' "$memory_max"; prompt_value load_max '每核负载最大值' "$load_max"
      health_configure_resources --disk-free "$disk_free" --memory-max "$memory_max" --load-per-core "$load_max"
      ;;
  esac
}

ui_traffic_menu() {
  local c id quota reset_day upload_rate download_rate mode mode_choice
  traffic_status all
  printf '\n1. 配置/启用节点流量控制\n2. 停用节点流量控制\n3. 立即重置节点统计\n4. 移除配置与累计用量\n5. 重新加载运行规则\n0. 返回\n'
  prompt_value c '选择操作' '0'
  case "$c" in
    1)
      ui_select_node id || return
      quota=$(jq -r --arg id "$id" '.nodes[]|select(.id==$id)|if .traffic.quota_bytes==null then "unlimited" else (.traffic.quota_bytes|tostring)+"B" end' "$SBM_STATE")
      reset_day=$(jq -r --arg id "$id" '.nodes[]|select(.id==$id)|.traffic.reset_day' "$SBM_STATE")
      upload_rate=$(jq -r --arg id "$id" '.nodes[]|select(.id==$id)|if .traffic.upload_rate_bps==null then "unlimited" else (.traffic.upload_rate_bps|tostring)+"bps" end' "$SBM_STATE")
      download_rate=$(jq -r --arg id "$id" '.nodes[]|select(.id==$id)|if .traffic.download_rate_bps==null then "unlimited" else (.traffic.download_rate_bps|tostring)+"bps" end' "$SBM_STATE")
      mode=$(jq -r --arg id "$id" '.nodes[]|select(.id==$id)|.traffic.quota_mode' "$SBM_STATE")
      prompt_value quota '月配额（如 100G；unlimited 不限）' "$quota"
      printf '1. 上行+下行计入配额\n2. 仅下行计入配额\n'
      [[ "$mode" == download ]] && mode_choice=2 || mode_choice=1
      prompt_value mode_choice '配额统计方式' "$mode_choice"
      case "$mode_choice" in 1) mode=total;; 2) mode=download;; *) log_error '选择无效'; return;; esac
      prompt_value reset_day '每月重置日（1-28，UTC）' "$reset_day"
      prompt_value upload_rate '上行限速（如 20M；unlimited 不限）' "$upload_rate"
      prompt_value download_rate '下行限速（如 100M；unlimited 不限）' "$download_rate"
      traffic_set "$id" --quota "$quota" --quota-mode "$mode" --reset-day "$reset_day" --upload-rate "$upload_rate" --download-rate "$download_rate"
      ;;
    2) ui_select_node id || return; traffic_disable "$id" ;;
    3) ui_select_node id 1 || return; confirm "确认清零 $id 的本周期流量统计？" N && traffic_reset "$id" ;;
    4) ui_select_node id || return; confirm "确认移除 $id 的流量控制配置和累计用量？" N && traffic_remove "$id" ;;
    5) traffic_reconcile ;;
  esac
}

ui_main() {
  [[ -t 0 ]] || { sb_help; return; }
  local choice
  while true; do
    ui_header
    printf '1. 查看统一运行状态\n2. 添加协议节点\n3. 管理现有节点\n4. 分享链接与客户端导出\n5. 完整客户端配置导出\n6. 域名与证书管理\n7. Cloudflare Tunnel 管理\n8. 核心与组件更新\n9. sing-box API/Dashboard\n10. 日志\n11. 诊断与修复\n12. 备份与恢复\n13. 全局设置\n14. 防火墙与协议端口\n15. 流量统计、配额与限速\n16. 通知与定时健康检查\n17. 节点模板与批量操作\n18. 卸载与彻底清理\n0. 退出\n\n'
    prompt_value choice '请选择' '0'
    case "$choice" in
      1) status_summary || true;; 2) ui_add_node;; 3) ui_manage_nodes;;
      4) ui_share_export_menu || continue;;
      5) ui_client_export_menu;; 6) ui_cert_menu;; 7) ui_tunnel_menu;; 8) ui_update_menu;; 9) ui_api_menu;; 10) show_logs all 100;; 11) ui_doctor_menu;; 12) ui_backup_menu;; 13) ui_settings_menu;; 14) ui_firewall_menu;; 15) ui_traffic_menu;;
      16) ui_notification_health_menu;;
      17) ui_template_menu;;
      18) ui_uninstall_menu; [[ ${SBM_UNINSTALLED:-0} == 1 ]] && return;;
      0) return;; *) log_error '选择无效';;
    esac
    ui_pause
  done
}
