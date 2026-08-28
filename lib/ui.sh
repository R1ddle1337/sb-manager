#!/usr/bin/env bash
# shellcheck shell=bash

ui_pause() { [[ -t 0 ]] && { printf '\n按 Enter 返回…'; read -r _; }; }
ui_clear() { [[ -t 1 ]] && clear || true; }
ui_header() {
  local service_state enabled
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
  printf '%s╰─────────────────────────────────────────────────────╯%s\n\n' "$C_CYAN" "$C_RESET"
}

ui_select_node() {
  local __var=$1 id
  node_list
  prompt_value id '输入节点 ID' ''
  state_node_exists "$id" || { log_error "节点不存在：$id"; return 1; }
  printf -v "$__var" '%s' "$id"
}

ui_require_certificate() {
  local domain=$1
  if [[ ! -s "$SBM_CERTS/$domain/fullchain.pem" || ! -s "$SBM_CERTS/$domain/key.pem" ]]; then
    log_error "尚无 $domain 的完整证书，请先在“域名与证书”中签发。"
    return 1
  fi
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
  local handshake_server handshake_port congestion_control network strict_mode wildcard_sni default_addr
  default_addr=$(jq -r '.settings.default_server_address // ""' "$SBM_STATE")
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
      prompt_value name '节点名称' 'VMess WS Cloudflare'; prompt_value domain '固定 Tunnel 域名（Quick Tunnel 可留空）' ''; prompt_value address '客户端 add 地址（留空则同域名）' "$domain"
      local args=(vmess --name "$name")
      [[ -n "$domain" ]] && args+=(--domain "$domain")
      [[ -n "$address" ]] && args+=(--address "$address")
      node_add "${args[@]}"
      ;;
    2)
      prompt_value name '节点名称' 'Shadowsocks 2022'; prompt_value address '客户端连接地址（域名或 IP）' "$default_addr"; ui_prompt_port port tcp 'TCP 端口' 8388 8389 8390 8443
      printf '1. 2022-blake3-aes-128-gcm（默认）\n2. 2022-blake3-aes-256-gcm\n3. 2022-blake3-chacha20-poly1305\n'; prompt_value method '选择方法' '1'
      case "$method" in 1) method=2022-blake3-aes-128-gcm;; 2) method=2022-blake3-aes-256-gcm;; 3) method=2022-blake3-chacha20-poly1305;; *) log_error '选择无效'; return;; esac
      node_add ss --name "$name" --address "$address" --port "$port" --method "$method"
      ;;
    3)
      prompt_value name '节点名称' 'AnyTLS'; prompt_value domain 'TLS 域名（必须已签发证书）' ''; prompt_value address '客户端连接地址' "${default_addr:-$domain}"; ui_prompt_port port tcp 'TCP 端口' 443 8443 9443 10443
      ui_require_certificate "$domain" || return
      node_add anytls --name "$name" --domain "$domain" --address "$address" --port "$port"
      ;;
    4)
      prompt_value name '节点名称' 'Hysteria2'; prompt_value domain 'TLS 域名（必须已签发证书）' ''; prompt_value address '客户端连接地址' "${default_addr:-$domain}"; ui_prompt_port port udp 'UDP 端口' 443 8443 9443 10443
      ui_require_certificate "$domain" || return
      prompt_value obfs '启用 salamander 混淆？(y/N)' 'N'
      if [[ "$obfs" =~ ^[Yy]$ ]]; then node_add hy2 --name "$name" --domain "$domain" --address "$address" --port "$port" --obfs salamander; else node_add hy2 --name "$name" --domain "$domain" --address "$address" --port "$port"; fi
      ;;
    5)
      prompt_value name '节点名称' 'Trojan'; prompt_value domain 'TLS 域名（必须已签发证书）' ''
      prompt_value address '客户端连接地址' "${default_addr:-$domain}"; ui_prompt_port port tcp 'TCP 端口' 443 8443 9443 10443
      ui_require_certificate "$domain" || return
      node_add trojan --name "$name" --domain "$domain" --address "$address" --port "$port"
      ;;
    6)
      prompt_value name '节点名称' 'TUIC'; prompt_value domain 'TLS 域名（必须已签发证书）' ''
      prompt_value address '客户端连接地址' "${default_addr:-$domain}"; ui_prompt_port port udp 'UDP 端口' 443 8443 9443 10443
      printf '1. cubic（默认）\n2. new_reno\n3. bbr\n'; prompt_value congestion_control '拥塞控制' '1'
      case "$congestion_control" in 1) congestion_control=cubic;; 2) congestion_control=new_reno;; 3) congestion_control=bbr;; *) log_error '选择无效'; return;; esac
      ui_require_certificate "$domain" || return
      node_add tuic --name "$name" --domain "$domain" --address "$address" --port "$port" --congestion-control "$congestion_control"
      ;;
    7)
      prompt_value name '节点名称' 'VLESS'; prompt_value domain 'TLS 域名或 Reality SNI' ''
      prompt_value address '客户端连接地址' "${default_addr:-$domain}"; ui_prompt_port port tcp 'TCP 端口' 443 8443 9443 10443
      printf '1. TLS（需要本地证书）\n2. Reality（使用 Reality 密钥对）\n'; prompt_value security_choice '选择安全层' '1'
      case "$security_choice" in
        1)
          security=tls; ui_require_certificate "$domain" || return
          node_add vless --name "$name" --domain "$domain" --address "$address" --port "$port" --security "$security"
          ;;
        2)
          security=reality; prompt_value handshake_server 'Reality 握手域名' ''; prompt_value handshake_port 'Reality 握手端口' '443'
          node_add vless --name "$name" --domain "$domain" --address "$address" --port "$port" --security "$security" --handshake-server "$handshake_server" --handshake-port "$handshake_port"
          ;;
        *) log_error '选择无效';;
      esac
      ;;
    8)
      prompt_value name '节点名称' 'NaiveProxy'; prompt_value domain 'TLS 域名（必须已签发证书）' ''
      prompt_value address '客户端连接地址' "${default_addr:-$domain}"
      printf '1. HTTPS/TCP（默认）\n2. QUIC/UDP\n'; prompt_value security_choice '选择传输' '1'
      case "$security_choice" in 1) network=tcp;; 2) network=udp;; *) log_error '选择无效'; return;; esac
      ui_prompt_port port "$network" '端口' 443 8443 9443 10443
      ui_require_certificate "$domain" || return
      node_add naive --name "$name" --domain "$domain" --address "$address" --port "$port" --network "$network"
      ;;
    9)
      prompt_value name '节点名称' 'ShadowTLS'; prompt_value handshake_server '握手目标域名' ''; prompt_value handshake_port '握手目标端口' '443'
      prompt_value address '客户端连接地址' "${default_addr:-$handshake_server}"; ui_prompt_port port tcp 'TCP 端口' 443 8443 9443 10443
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

ui_settings_menu() {
  local c v
  printf '1. 设置默认服务器地址\n2. 修改日志级别\n0. 返回\n'; prompt_value c '选择操作' '0'
  case "$c" in
    1) prompt_value v '域名或 IP' ''; settings_set_default_address "$v";;
    2) prompt_value v '日志级别 (trace/debug/info/warn/error/fatal/panic)' 'info'; settings_set_log_level "$v";;
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
      4) node_list; local id; prompt_value id '节点 ID（输入 all 导出全部）' 'all'; [[ "$id" == all ]] && { node_share_all; export_all_outbounds; } || node_share "$id" 1;;
      5) ui_cert_menu;; 6) ui_tunnel_menu;; 7) ui_update_menu;; 8) show_logs all 100;; 9) ui_doctor_menu;; 10) ui_backup_menu;; 11) ui_settings_menu;;
      12) ui_uninstall_menu; [[ ${SBM_UNINSTALLED:-0} == 1 ]] && return;;
      0) return;; *) log_error '选择无效';;
    esac
    ui_pause
  done
}
