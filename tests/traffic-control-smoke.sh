#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

export SBM_PREFIX="$ROOT/usr/local" SBM_LIB="$PROJECT" SBM_BIN_DIR="$ROOT/usr/local/bin"
export SBM_ETC="$ROOT/etc/sb-manager" SBM_VAR="$ROOT/var/lib/sb-manager" SBM_RUN="$ROOT/run/sb-manager"
export SBM_STATE="$SBM_ETC/state.json" SBM_GENERATED_DIR="$SBM_ETC/generated"
export SBM_CONFIG="$SBM_GENERATED_DIR/config.json"
export SBM_SECRETS="$SBM_ETC/secrets" SBM_CERTS="$SBM_ETC/certs" SBM_BACKUPS="$SBM_VAR/backups"
export SBM_EXPORTS="$SBM_VAR/exports" SBM_CACHE="$SBM_VAR/cache" SBM_CORE_DIR="$ROOT/cores"
export SBM_LOCK="$SBM_RUN/manager.lock" SBM_SING_BOX_BIN=/bin/true SBM_SKIP_INIT=1 SBM_TEST_MODE=1 NO_COLOR=1
export SBM_SERVICE_USER
SBM_SERVICE_USER=$(id -un)

source "$PROJECT/lib/common.sh"
source "$PROJECT/lib/service.sh"
source "$PROJECT/lib/state.sh"
source "$PROJECT/lib/nginx_stream.sh"
source "$PROJECT/protocols/vmess_ws_cf.sh"
source "$PROJECT/protocols/shadowsocks.sh"
source "$PROJECT/protocols/anytls.sh"
source "$PROJECT/protocols/hysteria2.sh"
source "$PROJECT/protocols/trojan.sh"
source "$PROJECT/protocols/tuic.sh"
source "$PROJECT/protocols/vless.sh"
source "$PROJECT/protocols/naive.sh"
source "$PROJECT/protocols/shadowtls.sh"
source "$PROJECT/protocols/snell.sh"
source "$PROJECT/lib/render.sh"
source "$PROJECT/lib/core.sh"
source "$PROJECT/lib/node.sh"
source "$PROJECT/lib/traffic.sh"
source "$PROJECT/lib/tunnel.sh"
source "$PROJECT/lib/subscription.sh"
source "$PROJECT/lib/backup.sh"

state_init
node_add ss --id traffic-tcp --port 28388 --address 192.0.2.1 >/dev/null
traffic_set traffic-tcp --quota 100G --reset-day 7 --upload-rate 20M --download-rate 80Mbps --quota-mode total >/dev/null
jq -e '.nodes[] | select(.id=="traffic-tcp") | .traffic == {
  configured:true,enabled:true,quota_bytes:107374182400,quota_mode:"total",reset_day:7,
  upload_rate_bps:20000000,download_rate_bps:80000000
}' "$SBM_STATE" >/dev/null

mkdir -p "$SBM_CERTS/udp.example.com"
printf 'certificate\n' >"$SBM_CERTS/udp.example.com/fullchain.pem"
printf 'key\n' >"$SBM_CERTS/udp.example.com/key.pem"
node_add hy2 --id traffic-udp --port 24443 --domain udp.example.com --address 192.0.2.2 >/dev/null
traffic_set traffic-udp --quota 2T --quota-mode download --rate 50M --reset-day 1 >/dev/null

rules="$ROOT/traffic.nft"
traffic_render_nft_script 0 >"$rules"
nft -c -f "$rules"
grep -Eq 'input meta l4proto tcp tcp dport 28388 .*counter name' "$rules"
grep -Eq 'output meta l4proto tcp tcp sport 28388 .*quota name' "$rules"
grep -Eq 'input meta l4proto udp udp dport 24443 .*counter name' "$rules"
grep -Eq 'output meta l4proto udp udp sport 24443 .*quota name' "$rules"
! grep -Eq 'input meta l4proto udp udp dport 24443 .*quota name' "$rules"
grep -Eq 'rate over 2500000 bytes/second' "$rules"
grep -Eq 'rate over 10000000 bytes/second' "$rules"

# A routed node is accounted on its effective loopback backend, not on the
# shared Nginx Stream public port.
nginx_stream_effective_node() { jq '.port=29999 | .listen="127.0.0.1"' <<<"$2"; }
traffic_render_nft_script 0 >"$rules"
grep -Eq 'output oifname "lo" meta l4proto tcp tcp dport 29999 .*counter name' "$rules"
grep -Eq 'output oifname "lo" meta l4proto tcp tcp sport 29999 .*counter name' "$rules"
! grep -Eq 'dport (28388|24443) .*counter name' "$rules"
nft -c -f "$rules"

# Runtime counters are checkpointed independently from configuration state.
traffic_nft_table_exists() { return 0; }
traffic_nft_counter_bytes() {
  case "$1" in *_up) printf '1234\n';; *_down) printf '5678\n';; *) return 1;; esac
}
traffic_checkpoint_unlocked
jq -e '.nodes["traffic-tcp"].upload_bytes==1234 and .nodes["traffic-tcp"].download_bytes==5678' "$SBM_TRAFFIC_USAGE" >/dev/null
status=$(traffic_status_json_unlocked traffic-tcp)
jq -e '.[0].total_bytes==6912 and .[0].billable_bytes==6912' <<<"$status" >/dev/null

# A lower quota is accepted but starts exhausted; nft cannot seed a quota with
# used bytes greater than its ceiling, so rendering clamps the kernel seed.
jq '.nodes[0].traffic.quota_bytes=1' "$SBM_STATE" >"$ROOT/state-lower.json"
cp "$ROOT/state-lower.json" "$SBM_STATE"
traffic_render_nft_script 0 >"$rules"
grep -Eq 'quota .*over 1 bytes used 1 bytes' "$rules"
nft -c -f "$rules"

# The protected usage journal follows the normal backup/restore path.
archive="$ROOT/traffic-backup.tar.gz"
backup_create "$archive" >/dev/null
tar -tzf "$archive" | grep -Eq '^\./var/traffic-usage.json$'
tmp=$(mktemp)
jq '.nodes["traffic-tcp"].upload_bytes=999999' "$SBM_TRAFFIC_USAGE" >"$tmp"
mv "$tmp" "$SBM_TRAFFIC_USAGE"
backup_restore "$archive" 1 >/dev/null
jq -e '.nodes["traffic-tcp"].upload_bytes==1234' "$SBM_TRAFFIC_USAGE" >/dev/null

# Month rollover clears the journal before rules are rebuilt.
current_cycle=$(traffic_cycle_id 7)
tmp=$(mktemp)
jq --argjson cycle "$((current_cycle - 1))" '.nodes["traffic-tcp"].cycle_id=$cycle' "$SBM_TRAFFIC_USAGE" >"$tmp"
mv "$tmp" "$SBM_TRAFFIC_USAGE"
traffic_reset_due_unlocked
jq -e --argjson cycle "$current_cycle" '.nodes["traffic-tcp"].cycle_id==$cycle and .nodes["traffic-tcp"].upload_bytes==0 and .nodes["traffic-tcp"].download_bytes==0' "$SBM_TRAFFIC_USAGE" >/dev/null

traffic_disable traffic-tcp >/dev/null
jq -e '.nodes[] | select(.id=="traffic-tcp") | .traffic.configured and (.traffic.enabled|not)' "$SBM_STATE" >/dev/null
traffic_remove traffic-tcp >/dev/null
jq -e '.nodes[] | select(.id=="traffic-tcp") | (.traffic.configured|not) and (.traffic.quota_bytes==null)' "$SBM_STATE" >/dev/null

printf 'TRAFFIC CONTROL SMOKE PASSED\n'
