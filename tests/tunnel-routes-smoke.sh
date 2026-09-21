#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/feature-fixture.sh"
cat >"$SBM_CLOUDFLARED_BIN" <<'EOF_CF'
#!/usr/bin/env bash
[[ ${FAKE_CF_FAIL:-0} != 1 ]]
EOF_CF
chmod +x "$SBM_CLOUDFLARED_BIN"
id=11111111-2222-3333-4444-555555555555
jq -n --arg id "$id" '{AccountTag:"account",TunnelID:$id,TunnelSecret:"secret"}' >"$ROOT/credentials.json"
tunnel_routes_cli managed "$id" "$ROOT/credentials.json"
tunnel_routes_cli route add web app.example.com http://127.0.0.1:3001
tunnel_routes_cli route add api app.example.com http://127.0.0.1:9080 '^/api/'
jq -e '.ingress[0].path=="^/api/" and .ingress[1].hostname=="app.example.com" and .ingress[-1].service=="http_status:404"' "$SBM_TUNNEL_INGRESS" >/dev/null
[[ $(stat -c '%a' "$SBM_TUNNEL_CREDENTIALS") == 640 ]]
grep -Fq -- '--config' "$SBM_SYSTEMD_DIR/$SBM_TUNNEL_SERVICE"
SBM_TEST_INIT_BACKEND=openrc write_managed_tunnel_unit
grep -Fq 'supervisor=supervise-daemon' "$SBM_OPENRC_DIR/sb-cloudflared"
cp "$SBM_STATE" "$ROOT/before.json"
expect_failure tunnel_routes_cli route add unsafe test.example.com http://198.51.100.1:80
expect_failure tunnel_routes_cli route add bad 'bad domain' http://127.0.0.1:3001
expect_failure tunnel_routes_cli route add collision app.example.com http://127.0.0.1:80
expect_failure env FAKE_CF_FAIL=1 bash "$PROJECT/sb" tunnel route add fail x.example.com http://127.0.0.1:8080
cmp "$ROOT/before.json" "$SBM_STATE"
tunnel_routes_cli route remove api
jq -e '.tunnel.routes|length==1' "$SBM_STATE" >/dev/null
printf 'TUNNEL ROUTES SMOKE PASSED\n'
