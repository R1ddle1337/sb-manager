#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${SBM_TRAFFIC_NETNS:-0} != 1 ]]; then
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'traffic nft real smoke requires root' >&2; exit 1; }
  command -v unshare >/dev/null || { echo 'traffic nft real smoke requires unshare' >&2; exit 1; }
  exec unshare -n env SBM_TRAFFIC_NETNS=1 bash "$0" "$@"
fi

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

export SBM_PREFIX="$ROOT/usr/local" SBM_LIB="$PROJECT" SBM_BIN_DIR="$ROOT/usr/local/bin"
export SBM_ETC="$ROOT/etc/sb-manager" SBM_VAR="$ROOT/var/lib/sb-manager" SBM_RUN="$ROOT/run/sb-manager"
export SBM_STATE="$SBM_ETC/state.json" SBM_GENERATED_DIR="$SBM_ETC/generated"
export SBM_CONFIG="$SBM_GENERATED_DIR/config.json" SBM_SECRETS="$SBM_ETC/secrets" SBM_CERTS="$SBM_ETC/certs"
export SBM_BACKUPS="$SBM_VAR/backups" SBM_EXPORTS="$SBM_VAR/exports" SBM_CACHE="$SBM_VAR/cache"
export SBM_CORE_DIR="$ROOT/cores" SBM_LOCK="$SBM_RUN/manager.lock" SBM_SING_BOX_BIN=/bin/true
export SBM_SKIP_INIT=1 SBM_TEST_MODE=1 SBM_SERVICE_USER=root NO_COLOR=1

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

state_init
SBM_SKIP_INIT=0
node_add ss --id nft-real --port 28388 --address 192.0.2.1 >/dev/null
traffic_set nft-real --quota 1G --upload-rate 10M --download-rate 20M >/dev/null
node_add vmess --id nft-loopback --port 29001 --domain cdn.example.com --address cdn.example.com >/dev/null
traffic_set nft-loopback --quota 1G --rate 20M >/dev/null

ip link set lo up
traffic_reconcile
traffic_tick
nft -j list table inet "$SBM_TRAFFIC_TABLE" | jq -e '
  [.nftables[] | objects | to_entries[] | .value.name? // empty] as $names
  | ($names | any(. == "input")) and ($names | any(. == "output"))
' >/dev/null
prefix=$(traffic_object_prefix nft-real)
nft -j list counter inet "$SBM_TRAFFIC_TABLE" "${prefix}_up" | jq -e '.nftables[]?.counter.bytes==0' >/dev/null
nft -j list counter inet "$SBM_TRAFFIC_TABLE" "${prefix}_down" | jq -e '.nftables[]?.counter.bytes==0' >/dev/null
nft -j list quota inet "$SBM_TRAFFIC_TABLE" "${prefix}_quota" | jq -e '.nftables[]?.quota.bytes==1073741824' >/dev/null
nft -j list limit inet "$SBM_TRAFFIC_TABLE" "${prefix}_up_rate" | jq -e '.nftables[]?.limit.rate==1250000' >/dev/null
nft -j list limit inet "$SBM_TRAFFIC_TABLE" "${prefix}_down_rate" | jq -e '.nftables[]?.limit.rate==2500000' >/dev/null

exercise_listener() {
  local port=$1 server_pid response
  python3 -c '
import socket,sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(1)
c,_=s.accept(); c.recv(4096); c.sendall(b"download-response"); c.close(); s.close()
' "$port" &
  server_pid=$!
  sleep 0.2
  response=$(python3 -c '
import socket,sys
s=socket.create_connection(("127.0.0.1",int(sys.argv[1])))
s.sendall(b"upload-request"); print(s.recv(4096).decode()); s.close()
' "$port")
  wait "$server_pid"
  [[ "$response" == download-response ]]
}

exercise_listener 28388
exercise_listener 29001
nft -j list counter inet "$SBM_TRAFFIC_TABLE" "${prefix}_up" | jq -e '.nftables[]?.counter.bytes>0' >/dev/null
nft -j list counter inet "$SBM_TRAFFIC_TABLE" "${prefix}_down" | jq -e '.nftables[]?.counter.bytes>0' >/dev/null
loop_prefix=$(traffic_object_prefix nft-loopback)
nft -j list counter inet "$SBM_TRAFFIC_TABLE" "${loop_prefix}_up" | jq -e '.nftables[]?.counter.bytes>0' >/dev/null
nft -j list counter inet "$SBM_TRAFFIC_TABLE" "${loop_prefix}_down" | jq -e '.nftables[]?.counter.bytes>0' >/dev/null

traffic_checkpoint
traffic_usage_validate "$SBM_TRAFFIC_USAGE"
jq -e '.nodes["nft-real"].upload_bytes>0 and .nodes["nft-loopback"].download_bytes>0' "$SBM_TRAFFIC_USAGE" >/dev/null
traffic_reset nft-real
traffic_delete_table_unlocked
! traffic_nft_table_exists

printf 'TRAFFIC NFT REAL SMOKE PASSED\n'
