#!/usr/bin/env bash
set -Eeuo pipefail
# A disposable container with NET_ADMIN, never --network host.
[[ ${SBM_TEST_ISOLATED_NETWORK:-0} == 1 ]] || { echo 'Set SBM_TEST_ISOLATED_NETWORK=1 only in a disposable network namespace.' >&2; exit 1; }
source "$(dirname "${BASH_SOURCE[0]}")/feature-fixture.sh"
cleanup() { tc qdisc del dev sbmtest0 root 2>/dev/null || true; ip link del sbmtest0 2>/dev/null || true; rm -rf "$ROOT"; }
trap cleanup EXIT
ip link add sbmtest0 type veth peer name sbmtest1
ip link set sbmtest0 up
ip link set sbmtest1 up
node_add socks --id shaped --listen 0.0.0.0 --address 192.0.2.1 --port 28881 >/dev/null
traffic_set shaped --download-rate 10M >/dev/null
shaping_cli enable sbmtest0 --capacity 1G >/dev/null
tc -j qdisc show dev sbmtest0 | jq -e 'any(.[];.kind=="htb" and .handle=="5b00:")' >/dev/null
tc -j filter show dev sbmtest0 parent 5b00: | jq -e 'length>=2' >/dev/null
traffic_group_cli set shared --nodes shaped --quota 10M >/dev/null
traffic_render_nft_script 0 >"$ROOT/rules.nft"
nft -c -f "$ROOT/rules.nft"
nft -f "$ROOT/rules.nft"
nft -j list table inet "$SBM_TRAFFIC_TABLE" | jq -e '.nftables|length>0' >/dev/null
shaping_cli disable >/dev/null
tc -j qdisc show dev sbmtest0 | jq -e 'any(.[];.kind=="noqueue")' >/dev/null
nft delete table inet "$SBM_TRAFFIC_TABLE"
printf 'REAL TC AND SHARED NFT QUOTA PASSED\n'
