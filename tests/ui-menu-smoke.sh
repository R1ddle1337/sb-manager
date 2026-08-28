#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export SBM_STATE="$ROOT/state.json" SBM_CERTS="$ROOT/certs" NO_COLOR=1
printf '%s\n' '{"settings":{"default_server_address":""}}' >"$SBM_STATE"

source "$PROJECT/lib/common.sh"
source "$PROJECT/lib/ui.sh"

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
  'ShadowTLS v3'; do
  grep -Fq "$label" <<<"$menu"
done
[[ $(grep -Ec '^[1-9]\. ' <<<"$menu") == 9 ]]
settings_menu=$(ui_settings_menu)
grep -Fq 'Nginx Stream 443/TCP 多协议复用' <<<"$settings_menu"

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
printf 'UI MENU SMOKE PASSED\n'
