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
printf 'UI MENU SMOKE PASSED\n'
