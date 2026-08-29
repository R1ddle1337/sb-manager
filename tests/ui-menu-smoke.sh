#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export SBM_STATE="$ROOT/state.json" SBM_CERTS="$ROOT/certs" NO_COLOR=1
printf '%s\n' '{"settings":{"default_server_address":""}}' >"$SBM_STATE"

source "$PROJECT/lib/common.sh"
source "$PROJECT/lib/node.sh"
source "$PROJECT/lib/ui.sh"
source "$PROJECT/protocols/snell.sh"
source "$PROJECT/lib/firewall.sh"
state_list_nodes() { jq -c '.nodes[]?' "$SBM_STATE"; }
state_node_exists() { jq -e --arg id "$1" '.nodes[]? | select(.id==$id)' "$SBM_STATE" >/dev/null; }

# Select protocol 0 so the menu is rendered without creating a node.
prompt_value() { printf -v "$1" '%s' "${3:-0}"; }
menu=$(ui_add_node)
for label in \
  'VMess + WebSocket + Cloudflare Tunnel' \
  'Shadowsocks 2022' \
  'AnyTLS' \
  'Hysteria2' \
  'Trojan TLS' \
  'TUIC' \
  'VLESS' \
  'NaiveProxy' \
  'ShadowTLS v3' \
  'Snell v5/v6（需要 sing-box 1.14+）'; do
  grep -Fq "$label" <<<"$menu"
done
[[ $(grep -Ec '^[1-9][0-9]*\. ' <<<"$menu") == 10 ]]
settings_menu=$(ui_settings_menu)
grep -Fq 'Nginx Stream 443/TCP 多协议复用' <<<"$settings_menu"
grep -Fq '出站 IP 优先级' <<<"$settings_menu"
grep -Fq 'Hysteria2 UDP 缓冲区优化' <<<"$settings_menu"
firewall_menu=$(ui_firewall_menu)
grep -Fq '查看所有协议端口' <<<"$firewall_menu"
grep -Fq 'UFW allow' <<<"$firewall_menu"
grep -Fq '安装并启用 Fail2ban' <<<"$firewall_menu"
grep -Fq '安装并启用 UFW' <<<"$firewall_menu"
traffic_status() { printf 'traffic-status\n'; }
traffic_menu=$(ui_traffic_menu)
grep -Fq '配置/启用节点流量控制' <<<"$traffic_menu"
grep -Fq '立即重置节点统计' <<<"$traffic_menu"
notification_status() { printf 'notification-status\n'; }
health_status() { printf 'health-status\n'; }
notification_menu=$(ui_notification_health_menu)
grep -Fq '配置 Telegram 通知' <<<"$notification_menu"
grep -Fq '启用定时健康检查' <<<"$notification_menu"

# A busy preferred port must fall back to the next documented alternate.
node_port_in_state() { [[ "$2" == 443 ]]; }
host_port_in_use() { return 1; }
node_choose_port() { printf '20000\n'; }
[[ $(ui_port_default tcp 443 8443 9443) == 8443 ]]

# Valid certificates are presented as numbered choices and Enter selects the first one.
mkdir -p "$SBM_CERTS/alpha.example.com" "$SBM_CERTS/beta.example.com"
for domain in alpha.example.com beta.example.com; do
  openssl req -x509 -newkey rsa:2048 -nodes -days 3 -subj "/CN=$domain" \
    -addext "subjectAltName=DNS:$domain" \
    -keyout "$SBM_CERTS/$domain/key.pem" -out "$SBM_CERTS/$domain/fullchain.pem" >/dev/null 2>&1
done
jq '.certificates=[{domain:"beta.example.com"},{domain:"alpha.example.com"}]' "$SBM_STATE" >"$ROOT/state.new"
mv "$ROOT/state.new" "$SBM_STATE"
selected=''
ui_select_certificate_domain selected >"$ROOT/cert-selector.out"
[[ "$selected" == alpha.example.com ]]
grep -Fq '1. alpha.example.com' "$ROOT/cert-selector.out"
grep -Fq '2. beta.example.com' "$ROOT/cert-selector.out"

# Nodes are selected by a stable display number; direct IDs remain accepted for scripts.
jq '.nodes=[{id:"alpha-node",name:"Alpha",protocol:"anytls"},{id:"beta-node",name:"Beta",protocol:"trojan"}]' "$SBM_STATE" >"$ROOT/state.new"
mv "$ROOT/state.new" "$SBM_STATE"
selected_node=''
ui_select_node selected_node >"$ROOT/node-selector.out"
[[ "$selected_node" == alpha-node ]]
grep -Eq '^1\. alpha-node[[:space:]]+AnyTLS$' "$ROOT/node-selector.out"
grep -Eq '^2\. beta-node[[:space:]]+Trojan TLS$' "$ROOT/node-selector.out"
node_share() { printf 'shared=%s\n' "$1"; }
node_share_all() { printf 'shared=all\n'; }
export_all_outbounds() { printf 'exported=all\n'; }
ui_share_export_menu >"$ROOT/share-selector.out"
grep -Fq 'shared=alpha-node' "$ROOT/share-selector.out"

# Domain endpoints take precedence; address-only nodes default to the detected public IPv4.
jq '.settings.public_ipv4="198.51.100.10"' "$SBM_STATE" >"$ROOT/state.new"
mv "$ROOT/state.new" "$SBM_STATE"
[[ $(ui_client_address_default 'tls.example.com') == tls.example.com ]]
[[ $(ui_client_address_default '') == 198.51.100.10 ]]
printf 'UI MENU SMOKE PASSED\n'
