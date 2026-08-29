#!/usr/bin/env bash
# shellcheck shell=bash

firewall_snapshot_dir() { printf '%s/firewall\n' "$SBM_VAR"; }

firewall_detect_ssh_ports() {
  local value port
  if [[ -n ${SBM_SSH_PORTS:-} ]]; then
    tr ', ' '\n\n' <<<"$SBM_SSH_PORTS"
  else
    if [[ -n ${SSH_CONNECTION:-} ]]; then
      awk '{print $4}' <<<"$SSH_CONNECTION"
    fi
    if command_exists sshd; then
      sshd -T 2>/dev/null | awk '$1=="port" {print $2}' || true
    fi
    if command_exists ss; then
      ss -H -ltnp 2>/dev/null | awk '/sshd/ {
        address=$4
        sub(/^.*:/, "", address)
        if (address ~ /^[0-9]+$/) print address
      }' || true
    fi
  fi | while IFS= read -r value; do
    port=${value//[[:space:]]/}
    validate_port "$port" && printf '%s\n' "$port"
  done | sort -nu
}

firewall_ssh_ports_or_default() {
  local ports
  ports=$(firewall_detect_ssh_ports)
  if [[ -z "$ports" ]]; then
    log_warn '未能探测到 sshd 监听端口，将安全回退到 22/TCP。'
    printf '22\n'
  else
    printf '%s\n' "$ports"
  fi
}

firewall_ssh_ports_csv() { firewall_ssh_ports_or_default | paste -sd, -; }

firewall_snapshot_iptables() {
  local dir=$1 stamp=$2 tool
  mkdir -p "$dir"
  chmod 0700 "$dir" 2>/dev/null || true
  for tool in iptables ip6tables; do
    if command_exists "${tool}-save"; then
      "${tool}-save" >"$dir/${stamp}-${tool}.rules" 2>/dev/null || true
      chmod 0600 "$dir/${stamp}-${tool}.rules" 2>/dev/null || true
    fi
  done
}

firewall_list_protocol_ports() {
  local node id protocol name enabled port kind route public_port
  printf '%-18s %-18s %-8s %-6s %-8s %s\n' 'ID' '协议' '状态' '协议' '端口' '客户端地址'
  printf '%-18s %-18s %-8s %-6s %-8s %s\n' '------------------' '------------------' '--------' '------' '--------' '------------'
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    id=$(jq -r '.id' <<<"$node")
    protocol=$(jq -r '.protocol' <<<"$node")
    name=$(node_protocol_label "$protocol")
    enabled=$(jq -r 'if .enabled then "启用" else "停用" end' <<<"$node")
    port=$(jq -r '.port' <<<"$node")
    if [[ "$enabled" == 启用 ]] && declare -F nginx_stream_route_for_node >/dev/null 2>&1 && nginx_stream_state_enabled "$SBM_STATE"; then
      route=$(nginx_stream_route_for_node "$SBM_STATE" "$id")
      if [[ -n "$route" ]]; then port=$(jq -r '.nginx_stream.port' "$SBM_STATE"); fi
    fi
    while IFS= read -r kind; do
      printf '%-18s %-18s %-8s %-6s %-8s %s\n' "$id" "$name" "$enabled" "${kind^^}" "$port" "$(jq -r '(.domain // .server_address // .client_address // "-")' <<<"$node")"
    done < <(node_transport_kinds "$node")
  done < <(state_list_nodes)
}

firewall_collect_protocol_ports() {
  local node id port kind route
  while IFS= read -r node; do
    [[ -n "$node" && $(jq -r '.enabled' <<<"$node") == true ]] || continue
    id=$(jq -r '.id' <<<"$node")
    port=$(jq -r '.port' <<<"$node")
    if declare -F nginx_stream_route_for_node >/dev/null 2>&1 && nginx_stream_state_enabled "$SBM_STATE"; then
      route=$(nginx_stream_route_for_node "$SBM_STATE" "$id")
      [[ -z "$route" ]] || port=$(jq -r '.nginx_stream.port' "$SBM_STATE")
    fi
    while IFS= read -r kind; do printf '%s\t%s\n' "$port" "$kind"; done < <(node_transport_kinds "$node")
  done < <(state_list_nodes)
}

firewall_ufw_allow_protocol_ports() {
  local assume_yes=${1:-0} port kind count=0
  command_exists ufw || die '未安装 UFW；请使用发行版包管理器安装（Alpine：apk add ufw）。'
  if [[ "$assume_yes" != 1 ]]; then
    confirm '将为所有启用协议端口执行 UFW allow，继续？' N || return 0
  fi
  while IFS=$'\t' read -r port kind; do
    [[ -n "$port" && -n "$kind" ]] || continue
    ufw allow "${port}/${kind}" >/dev/null
    log_ok "UFW 已允许 ${port}/${kind^^}"
    count=$((count + 1))
  done < <(firewall_collect_protocol_ports | sort -u)
  (( count > 0 )) || log_warn '没有启用中的协议端口可加入 UFW。'
}

firewall_package_install() {
  local package=$1
  if [[ -n ${SBM_FIREWALL_PACKAGE_INSTALLER:-} ]]; then
    "$SBM_FIREWALL_PACKAGE_INSTALLER" "$package"
  elif command_exists apk; then
    apk add --no-cache "$package"
  elif command_exists apt-get; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$package"
  elif command_exists dnf; then
    dnf install -y "$package"
  elif command_exists yum; then
    yum install -y "$package"
  elif command_exists pacman; then
    pacman -Sy --noconfirm --needed "$package"
  elif command_exists zypper; then
    zypper --non-interactive install "$package"
  else
    die '未找到支持的包管理器（apk、apt-get、dnf、yum、pacman 或 zypper）。'
  fi
}

firewall_snapshot_fail2ban() {
  local dir=$1 stamp=$2
  [[ -f "$SBM_FAIL2BAN_CONFIG" ]] || return 0
  mkdir -p "$dir"
  cp -a "$SBM_FAIL2BAN_CONFIG" "$dir/${stamp}-fail2ban-sshd.local"
  chmod 0600 "$dir/${stamp}-fail2ban-sshd.local" 2>/dev/null || true
}

firewall_snapshot_ufw() {
  local dir=$1 stamp=$2
  command_exists ufw || return 0
  mkdir -p "$dir"
  ufw status numbered >"$dir/${stamp}-ufw.status" 2>/dev/null || true
  chmod 0600 "$dir/${stamp}-ufw.status" 2>/dev/null || true
}

firewall_fail2ban_log_config() {
  local backend=${1:-auto}
  if [[ "$backend" == systemd ]]; then
    local unit=ssh.service
    if command_exists systemctl && ! systemctl cat ssh.service >/dev/null 2>&1 && systemctl cat sshd.service >/dev/null 2>&1; then unit=sshd.service; fi
    printf '%s\n' 'backend = systemd' "journalmatch = _SYSTEMD_UNIT=$unit"
  elif [[ -f /var/log/auth.log ]]; then
    printf '%s\n' 'backend = auto' 'logpath = /var/log/auth.log'
  elif [[ -f /var/log/secure ]]; then
    printf '%s\n' 'backend = auto' 'logpath = /var/log/secure'
  else
    printf '%s\n' 'backend = auto' 'logpath = /var/log/messages'
  fi
}

firewall_setup_fail2ban() {
  local assume_yes=${1:-0} backend tmp stamp dir service_state ssh_ports
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die '安装和配置 Fail2ban 需要 root 权限。'
  if [[ "$assume_yes" != 1 ]]; then
    confirm '将安装并启用 Fail2ban，仅保护 SSH：3 分钟内失败 5 次后永久封禁 IP，继续？' N || return 0
  fi
  if ! command_exists fail2ban-client; then
    log_info '正在安装 Fail2ban…'
    firewall_package_install fail2ban
  fi
  command_exists fail2ban-client || die 'Fail2ban 安装后仍未找到 fail2ban-client。'
  stamp=$(now_stamp); dir=$(firewall_snapshot_dir)
  firewall_snapshot_iptables "$dir" "$stamp"
  firewall_snapshot_fail2ban "$dir" "$stamp"
  backend=auto
  if [[ "$(effective_init_system 2>/dev/null || true)" == systemd && -x $(command -v journalctl 2>/dev/null || true) ]]; then backend=systemd; fi
  mkdir -p "$(dirname "$SBM_FAIL2BAN_CONFIG")"
  ssh_ports=$(firewall_ssh_ports_csv)
  tmp=$(mktemp "$(dirname "$SBM_FAIL2BAN_CONFIG")/.sb-manager-sshd.XXXXXX")
  {
    printf '%s\n' '[sshd]' 'enabled = true' "port = $ssh_ports" 'filter = sshd'
    firewall_fail2ban_log_config "$backend"
    local banaction=iptables-multiport
    [[ -f /etc/fail2ban/action.d/nftables-multiport.conf ]] && banaction=nftables-multiport
    printf '%s\n' 'findtime = 180' 'maxretry = 5' 'bantime = -1' "banaction = $banaction" 'action = %(action_)s'
  } >"$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$SBM_FAIL2BAN_CONFIG"
  if command_exists fail2ban-client; then
    fail2ban-client -t >/dev/null 2>"$SBM_RUN/fail2ban-check.log" || {
      log_error 'Fail2ban 配置检查失败：'
      sed -n '1,80p' "$SBM_RUN/fail2ban-check.log" >&2 || true
      return 1
    }
  fi
  if [[ "$SBM_SKIP_INIT" != 1 ]]; then
    service_enable "$SBM_FAIL2BAN_SERVICE" || true
    if service_active "$SBM_FAIL2BAN_SERVICE"; then
      service_restart "$SBM_FAIL2BAN_SERVICE"
    else
      service_start "$SBM_FAIL2BAN_SERVICE"
    fi
  fi
  service_state='未启动（测试/跳过服务管理器）'
  [[ "$SBM_SKIP_INIT" != 1 ]] && service_state=$(service_status_text "$SBM_FAIL2BAN_SERVICE" 2>/dev/null || printf '已请求启动')
  log_ok "Fail2ban 已配置：SSH ${ssh_ports//,/、}/TCP，3 分钟内失败 5 次永久封禁（$SBM_FAIL2BAN_CONFIG）"
  printf '服务状态：%s\n' "$service_state"
}

firewall_setup_ufw() {
  local assume_yes=${1:-0} dry_run=${2:-0} port kind count=0 stamp dir ssh_ports protocol_ports
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die '安装和配置 UFW 需要 root 权限。'
  ssh_ports=$(firewall_ssh_ports_or_default)
  protocol_ports=$(firewall_collect_protocol_ports | sort -u)
  printf 'UFW 变更预览：\n'
  printf '  SSH 探测端口：%s/TCP\n' "$(paste -sd',' <<<"$ssh_ports")"
  printf '  基础 Web 端口：80/TCP、443/TCP\n'
  printf '  兼容放行端口：22/TCP\n'
  if [[ -n "$protocol_ports" ]]; then
    while IFS=$'\t' read -r port kind; do printf '  协议端口：%s/%s\n' "$port" "${kind^^}"; done <<<"$protocol_ports"
  else
    printf '  协议端口：无\n'
  fi
  printf '  当前规则将保存到：%s/\n' "$(firewall_snapshot_dir)"
  if [[ "$dry_run" == 1 ]]; then
    command_exists ufw || printf '  UFW 尚未安装，正式执行时会安装。\n'
    return 0
  fi
  if [[ "$assume_yes" != 1 ]]; then
    confirm '确认按上述预览安装并启用 UFW？' N || return 0
  fi
  if ! command_exists ufw; then
    log_info '正在安装 UFW…'
    firewall_package_install ufw
  fi
  command_exists ufw || die 'UFW 安装后仍未找到 ufw。'
  stamp=$(now_stamp); dir=$(firewall_snapshot_dir)
  firewall_snapshot_iptables "$dir" "$stamp"
  firewall_snapshot_ufw "$dir" "$stamp"
  while IFS= read -r port; do
    [[ -n "$port" ]] || continue
    ufw allow "$port/tcp" >/dev/null
    log_ok "UFW 已允许 ${port}/TCP"
  done < <(printf '%s\n' 22 80 443 "$ssh_ports" | sort -nu)
  while IFS=$'\t' read -r port kind; do
    [[ -n "$port" && -n "$kind" ]] || continue
    ufw allow "${port}/${kind}" >/dev/null
    count=$((count + 1))
  done <<<"$protocol_ports"
  if ! ufw status 2>/dev/null | grep -qi '^status: active'; then
    ufw --force enable >/dev/null
    log_ok 'UFW 已启用。'
  else
    log_info 'UFW 已处于启用状态。'
  fi
  log_ok "UFW 已放行 SSH 实际监听端口、22/TCP、80/TCP、443/TCP；协议端口额外放行 ${count} 条。"
  log_warn '请确认云安全组也已放行 SSH 实际监听端口和所需协议端口。'
}

firewall_status() {
  local ufw_state fail2ban_state
  if command_exists ufw; then
    ufw_state=$(ufw status 2>/dev/null | sed -n '1p' || true)
    printf 'UFW       : %s\n' "${ufw_state:-已安装}"
  else
    printf 'UFW       : 未安装\n'
  fi
  if command_exists fail2ban-client; then
    fail2ban_state=$(fail2ban-client status sshd 2>/dev/null | sed -n '1p' || true)
    printf 'Fail2ban  : %s\n' "${fail2ban_state:-已安装}"
    printf '配置文件  : %s\n' "$SBM_FAIL2BAN_CONFIG"
  else
    printf 'Fail2ban  : 未安装\n'
  fi
}

firewall_is_blanket_deny() {
  local target='' token skip=0
  for token in "$@"; do
    if (( skip == 1 )); then skip=0; continue; fi
    case "$token" in
      -j) continue;;
      DROP|REJECT) target=$token;;
      --reject-with) skip=1;;
      --reject-with=*) continue;;
      *) return 1;;
    esac
  done
  [[ "$target" == DROP || "$target" == REJECT ]]
}

firewall_clear_iptables_input_deny() {
  local assume_yes=${1:-0} stamp dir tool line policy spec changed=0
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die '清理 iptables 规则需要 root 权限。'
  if [[ "$assume_yes" != 1 ]]; then
    confirm '将备份并移除 INPUT 链的全局 DROP/REJECT，必要时把策略改为 ACCEPT，继续？' N || return 0
  fi
  command_exists iptables || die '未找到 iptables。'
  stamp=$(now_stamp); dir=$(firewall_snapshot_dir); firewall_snapshot_iptables "$dir" "$stamp"
  printf 'iptables 规则备份：%s/%s-{iptables,ip6tables}.rules\n' "$dir" "$stamp"
  for tool in iptables ip6tables; do
    command_exists "$tool" || continue
    mapfile -t lines < <("$tool" -S INPUT 2>/dev/null || true)
    for line in "${lines[@]}"; do
      [[ "$line" == -A\ INPUT\ * ]] || continue
      read -r -a spec <<<"${line#-A INPUT }"
      firewall_is_blanket_deny "${spec[@]}" || continue
      "$tool" -D INPUT "${spec[@]}" || true
      log_ok "已移除 ${tool} INPUT 全局 ${spec[*]}"
      changed=1
    done
    policy=$("$tool" -S INPUT 2>/dev/null | awk '$1=="-P" && $2=="INPUT" {print $3; exit}')
    if [[ "$policy" == DROP || "$policy" == REJECT ]]; then
      "$tool" -P INPUT ACCEPT
      log_ok "已将 ${tool} INPUT 默认策略改为 ACCEPT（原策略：$policy）"
      changed=1
    fi
  done
  (( changed == 1 )) || log_warn '未发现 INPUT 链的全局 DROP/REJECT；规则未改变。'
}
