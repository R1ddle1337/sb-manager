#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/feature-fixture.sh"
export SBM_TC_CMD="$ROOT/bin/tc" FAKE_TC_ROOT="$ROOT"
printf '[{"kind":"noqueue","handle":"0:","root":true,"options":{}}]\n' >"$ROOT/qdisc.json"
cat >"$SBM_TC_CMD" <<'EOF_TC'
#!/usr/bin/env bash
set -eu
root=${FAKE_TC_ROOT:?}
printf '%s\n' "$*" >>"$root/tc.log"
if [[ "$1" == -j ]]; then
  if [[ "$2" == qdisc ]]; then cat "$root/qdisc.json"; else printf '[]\n'; fi
  exit 0
fi
if [[ ${FAKE_TC_FAIL:-0} == 1 && "$1 $2" == 'filter add' && ! -f "$root/failed-once" ]]; then touch "$root/failed-once"; exit 1; fi
if [[ "$1 $2" == 'qdisc replace' && "$*" == *'root handle 5b00:'* ]]; then
  printf '[{"kind":"htb","handle":"5b00:","root":true,"options":{}}]\n' >"$root/qdisc.json"
elif [[ "$1 $2" == 'qdisc del' ]]; then
  printf '[{"kind":"noqueue","handle":"0:","root":true,"options":{}}]\n' >"$root/qdisc.json"
fi
EOF_TC
chmod +x "$SBM_TC_CMD"
node_add socks --id shape-direct --listen 0.0.0.0 --address 192.0.2.1 --port 28681 >/dev/null
node_add http --id shape-local --port 28682 >/dev/null
traffic_set shape-direct --download-rate 50M >/dev/null
traffic_set shape-local --download-rate 20M >/dev/null
shaping_cli plan eth0 --capacity 1G | jq -e '.nodes[0].id=="shape-direct" and .excluded[0].id=="shape-local"' >/dev/null
[[ ! -e "$ROOT/tc.log" ]]
shaping_cli enable eth0 --capacity 1G >/dev/null
jq -e '.shaping.enabled' "$SBM_STATE" >/dev/null
grep -Fq 'protocol ipv6' "$ROOT/tc.log"
grep -Fq 'rate 50000000bit' "$ROOT/tc.log"
traffic_usage_init_unlocked
traffic_render_nft_script 0 >"$ROOT/rules"
grep -Fq 'oifname != "eth0"' "$ROOT/rules"
[[ $(stat -c '%a' "$SBM_SHAPING_DIR/baseline.json") == 600 ]]
cp "$SBM_STATE" "$ROOT/before.json"
expect_failure env FAKE_TC_FAIL=1 bash "$PROJECT/sb" traffic shaping enable eth0 --capacity 500M
cmp "$ROOT/before.json" "$SBM_STATE"
jq -e '.[0].handle=="5b00:"' "$ROOT/qdisc.json" >/dev/null
shaping_cli disable >/dev/null
jq -e '.[0].kind=="noqueue"' "$ROOT/qdisc.json" >/dev/null
[[ ! -e "$SBM_SHAPING_DIR/baseline.json" ]]
printf '[{"kind":"cake","handle":"1:","root":true,"options":{}}]\n' >"$ROOT/qdisc.json"
expect_failure shaping_cli enable eth0 --capacity 1G
jq -e '.[0].kind=="cake"' "$ROOT/qdisc.json" >/dev/null
expect_failure shaping_cli plan lo --capacity 1G
printf 'SHAPING SMOKE PASSED\n'
