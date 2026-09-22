#!/usr/bin/env bash
set -Eeuo pipefail
# Run in an isolated container/VM. Assets must already be digest-verified.
ASSETS=${SBM_TEST_COMPONENT_ASSETS:?Set SBM_TEST_COMPONENT_ASSETS}
source "$(dirname "${BASH_SOURCE[0]}")/feature-fixture.sh"
pids=()
cleanup() { for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done; rm -rf "$ROOT"; }
trap cleanup EXIT
dependency_require_feature() { return 0; }
substore_download_asset() {
  local repo=$1 version=$2 asset=$3 output=$4 file
  if [[ "$asset" == sub-store.bundle.js ]]; then file=sub-store.bundle.js; else file=frontend.zip; fi
  verify_asset_digest "$ASSETS/$file" "sha256:$(jq -r '.sha256' "$ASSETS/$file.meta.json")" || return 1
  cp "$ASSETS/$file" "$output"
  cat "$ASSETS/$file.meta.json"
}
node_add mixed --id local-mixed --port 28781 >/dev/null
node_add socks --id local-socks --port 28782 >/dev/null
node_add http --id local-http --port 28783 >/dev/null
"$SBM_SING_BOX_BIN" run -c "$SBM_CONFIG" >"$ROOT/core.log" 2>&1 & pids+=("$!")
printf 'proxy-forward-ok\n' >"$ROOT/probe.txt"
python3 -m http.server 28784 --bind 127.0.0.1 --directory "$ROOT" >"$ROOT/http.log" 2>&1 & pids+=("$!")
for ((i=0;i<30;i++)); do curl -fsS --max-time 1 http://127.0.0.1:28784/probe.txt >/dev/null 2>&1 && break; sleep 0.2; done
for id in local-socks local-http local-mixed; do
  proxy=$(node_share_uri "$id"); proxy=${proxy%%#*}
  curl -fsS --max-time 5 --noproxy '' --proxy "$proxy" http://127.0.0.1:28784/probe.txt | grep -Fxq proxy-forward-ok
done
# Authentication must remain mandatory on all three proxy inbounds.
if curl -fsS --max-time 2 --noproxy '' --proxy http://127.0.0.1:28783 http://127.0.0.1:28784/probe.txt >/dev/null 2>&1; then exit 1; fi
printf 'REAL PROXY HANDSHAKES PASSED\n'

export SBM_SUBSCRIPTION_PORT=28787
substore_install latest latest 28785 >/dev/null
"$SBM_SUBSTORE_DIR/run.sh" >"$ROOT/substore.log" 2>&1 & pids+=("$!")
for ((i=0;i<50;i++)); do
  if substore_api GET /api/subs >"$ROOT/subs.json" 2>/dev/null; then break; fi
  sleep 0.2
done
if ! jq -e '.status=="success"' "$ROOT/subs.json" >/dev/null; then tail -20 "$ROOT/substore.log"; exit 1; fi
curl -fsS --max-time 3 http://127.0.0.1:28785/ | grep -qi '<html'
code=$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:28785/api/subs)
[[ "$code" == 404 ]]
with_lock _substore_sync sb-manager
substore_api GET /api/sub/sb-manager | jq -e '.status=="success" and .data.source=="remote" and (.data.url|contains("format=substore"))' >/dev/null
python3 "$PROJECT/libexec/subscription_server.py" --root "$SBM_SUBSCRIPTIONS" --port "$SBM_SUBSCRIPTION_PORT" >"$ROOT/subscription.log" 2>&1 & pids+=("$!")
for ((i=0;i<30;i++)); do
  if substore_api GET '/download/sb-manager?target=JSON&noCache=true' >"$ROOT/parsed-nodes.json" 2>/dev/null; then break; fi
  sleep 0.2
done
jq -e 'length==3' "$ROOT/parsed-nodes.json" >/dev/null
with_lock _substore_sync sb-manager
printf 'REAL SUBSTORE UI AND SYNC PASSED\n'

verify_asset_digest "$ASSETS/cloudflared" "sha256:$(jq -r '.sha256' "$ASSETS/cloudflared.meta.json")"
cp "$ASSETS/cloudflared" "$SBM_CLOUDFLARED_BIN"; chmod +x "$SBM_CLOUDFLARED_BIN"
uuid=11111111-2222-3333-4444-555555555555
jq -n --arg id "$uuid" '{AccountTag:"00000000000000000000000000000000",TunnelID:$id,TunnelSecret:"c2VjcmV0"}' >"$ROOT/credentials.json"
tunnel_routes_cli managed "$uuid" "$ROOT/credentials.json" >/dev/null
tunnel_routes_cli route add ui sub.example.com http://127.0.0.1:28785 >/dev/null
tunnel_routes_cli route add api sub.example.com http://127.0.0.1:28784 '^/api/' >/dev/null
"$SBM_CLOUDFLARED_BIN" tunnel --config "$SBM_TUNNEL_INGRESS" ingress validate >/dev/null
cp "$SBM_STATE" "$ROOT/before.json"
expect_failure tunnel_routes_cli route add invalid bad.example.com http://127.0.0.1:28784 '^/['
cmp "$SBM_STATE" "$ROOT/before.json"
printf 'REAL CLOUDFLARED INGRESS VALIDATION PASSED\n'

iperf3 -s -B 127.0.0.1 -p 28786 >"$ROOT/iperf.log" 2>&1 & pids+=("$!")
sleep 0.3
network_speed 127.0.0.1 28786 1 1 up 1 | jq -e '.bits_per_second>0' >/dev/null
network_speed 127.0.0.1 28786 1 2 down 1 | jq -e '.bits_per_second>0' >/dev/null
printf 'REAL IPERF3 BIDIRECTIONAL BENCHMARKS PASSED\n'
