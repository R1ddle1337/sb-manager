#!/usr/bin/env bash
# shellcheck shell=bash

ui_pause() { [[ -t 0 ]] && { printf '\n按 Enter 返回…'; read -r _; }; }
ui_clear() { [[ -t 1 ]] && clear || true; }
ui_header() {
  ui_clear
  printf '%s╭──────────────────── sb-manager ────────────────────╮%s\n' "$C_CYAN" "$C_RESET"
  printf '  版本 %-18s sing-box %-16s\n' "$SBM_VERSION" "$(core_current_version || echo '-')"
  printf '  服务 %-18s Tunnel %-18s\n' "$([[ "$SBM_SKIP_SYSTEMD" == 1 ]] && echo 测试 || (service_active "$SBM_SERVICE" && echo 运行中 || echo 未运行))" "$(jq -r '.tunnel.mode' "$SBM_STATE")"
  printf '%s╰─────────────────────────────────────────────────────╯%s\n\n' "$C_CYAN" "$C_RESET"
}

ui_select_node() {
  local __var=$1 id
  node_list
  prompt_value id '输入节点 ID' ''
  state_node_exists "$id" || { log_error "节点不存在：$id"; return 1; }
  printf -v "$__var" '%s' "$id"
}

ui_add_node() {
  local choice domain address port name id obfs method
  printf '1. VMess + WebSocket + Cloudflare Tunnel\n2. Shadowsocks 2022\n3. AnyTLS\n4. Hysteria2\n0. 返回\n'
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
      prompt_value name '节点名称' 'Shadowsocks 2022'; prompt_value address '客户端连接地址（域名或 IP）' "$(jq -r '.settings.default_server_address // ""' "$SBM_STATE")"; prompt_value port 'TCP 端口' '8388'
      printf '1. 2022-blake3-aes-128-gcm（默认）\n2. 2022-blake3-aes-256-gcm\n3. 2022-blake3-chacha20-poly1305\n'; prompt_value method '选择方法' '1'
      case "$method" in 1) method=2022-blake3-aes-128-gcm;; 2) method=2022-blake3-aes-256-gcm;; 3) method=2022-blake3-chacha20-poly1305;; *) log_error '选择无效'; return;; esac
      node_add ss --name "$name" --address "$address" --port "$port" --method "$method"
      ;;
    3)
      prompt_value name '节点名称' 'AnyTLS'; prompt_value domain 'TLS 域名（必须已签发证书）' ''; local default_addr; default_addr=$(jq -r '.settings.default_server_address // ""' "$SBM_STATE"); [[ -n "$default_addr" ]] || default_addr=$domain; prompt_value address '客户端连接地址' "$default_addr"; prompt_value port 'TCP 端口' '443'
      if [[ ! -s "$SBM_CERTS/$domain/fullchain.pem" ]]; then log_error "尚无 $domain 的证书，请先在“域名与证书”中签发。"; return; fi
      node_add anytls --name "$name" --domain "$domain" --address "$address" --port "$port"
      ;;
    4)
      prompt_value name '节点名称' 'Hysteria2'; prompt_value domain 'TLS 域名（必须已签发证书）' ''; local default_addr; default_addr=$(jq -r '.settings.default_server_address // ""' "$SBM_STATE"); [[ -n "$default_addr" ]] || default_addr=$domain; prompt_value address '客户端连接地址' "$default_addr"; prompt_value port 'UDP 端口' '443'
      if [[ ! -s "$SBM_CERTS/$domain/fullchain.pem" ]]; then log_error "尚无 $domain 的证书，请先在“域名与证书”中签发。"; return; fi
      prompt_value obfs '启用 salamander 混淆？(y/N)' 'N'
      if [[ "$obfs" =~ ^[Yy]$ ]]; then node_add hy2 --name "$name" --domain "$domain" --address "$address" --port "$port" --obfs salamander; else node_add hy2 --name "$name" --domain "$domain" --address "$address" --port "$port"; fi
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
    2) prompt_value v '日志级别 (trace/debug/info/warn/error/fatal/panic)' 'info'; local candidate; candidate=$(state_candidate); jq --arg v "$v" '.settings.log_level=$v' "$SBM_STATE" >"$candidate"; with_lock apply_candidate_state "$candidate" log-level; rm -f "$candidate";;
  esac
}

ui_main() {
  [[ -t 0 ]] || { sb_help; return; }
  local choice
  while true; do
    ui_header
    printf '1. 查看运行状态\n2. 添加协议节点\n3. 管理现有节点\n4. 分享链接与客户端导出\n5. 域名与证书管理\n6. Cloudflare Tunnel 管理\n7. 核心与组件更新\n8. 日志\n9. 诊断与修复\n10. 备份与恢复\n11. 全局设置\n0. 退出\n\n'
    prompt_value choice '请选择' '0'
    case "$choice" in
      1) status_summary; node_list;; 2) ui_add_node;; 3) ui_manage_nodes;;
      4) node_list; local id; prompt_value id '节点 ID（输入 all 导出全部）' 'all'; [[ "$id" == all ]] && { node_share_all; export_all_outbounds; } || node_share "$id" 1;;
      5) ui_cert_menu;; 6) ui_tunnel_menu;; 7) ui_update_menu;; 8) show_logs all 100;; 9) doctor_run || true;; 10) ui_backup_menu;; 11) ui_settings_menu;; 0) return;; *) log_error '选择无效';;
    esac
    ui_pause
  done
}
