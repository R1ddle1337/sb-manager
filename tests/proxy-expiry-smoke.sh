#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/feature-fixture.sh"

node_add socks --id proxy-socks --port 28481 >/dev/null
node_add http --id proxy-http --port 28482 >/dev/null
node_add mixed --id proxy-mixed --port 28483 >/dev/null
jq -e '[.inbounds[]|select(.type=="socks" or .type=="http" or .type=="mixed")]|length==3 and all(.[]; .listen=="127.0.0.1" and (.users|length)==1 and (.users[0].password|length)>20)' "$SBM_CONFIG" >/dev/null
for id in proxy-socks proxy-http proxy-mixed; do
  node_share_uri "$id" >/dev/null
  node_client_outbound "$id" | jq -e '.username!=null and .password!=null' >/dev/null
  [[ $(stat -c '%a' "$(state_user_secret_path "$id" default)") == 600 ]]
done
[[ $(node_transport_kinds "$(state_get_node proxy-socks)") == tcp ]]
traffic_set proxy-socks --quota 1G >/dev/null
jq -e '.route.rules[0].network=="udp" and .route.rules[0].action=="reject" and .route.rules[0].inbound==["in-proxy-socks"]' "$SBM_CONFIG" >/dev/null
node_client_outbound proxy-socks | jq -e '.network=="tcp"' >/dev/null
export_client_config "$ROOT/client.json" mixed >/dev/null
node_user_add proxy-socks second >/dev/null
node_rotate proxy-http >/dev/null
node_template_save proxy-template proxy-http >/dev/null
node_template_add proxy-template templated --port 28484 >/dev/null
jq -e '.nodes[]|select(.id=="templated")|.listen=="127.0.0.1"' "$SBM_STATE" >/dev/null
expect_failure node_add http --id bad-listen --port 28485 --listen '$(id)'
cp "$SBM_STATE" "$ROOT/before.json"
expect_failure node_add socks --id duplicate --port 28481
cmp "$ROOT/before.json" "$SBM_STATE"

node_expiry_cli proxy-socks --days 1 >/dev/null
original_secret=$(sha256sum "$(state_user_secret_path proxy-socks default)")
# Move the expiry into the past without waiting; the periodic tick performs suspension.
jq '.nodes |= map(if .id=="proxy-socks" then .expiry.at=1 else . end)' "$SBM_STATE" >"$ROOT/state.new"
mv "$ROOT/state.new" "$SBM_STATE"
expect_failure node_enable proxy-socks
with_lock node_expiry_tick_unlocked
jq -e '.nodes[]|select(.id=="proxy-socks")|(.enabled|not) and .expiry.suspended and .expiry.resume_enabled' "$SBM_STATE" >/dev/null
! jq -e 'any(.inbounds[]; .tag=="in-proxy-socks")' "$SBM_CONFIG" >/dev/null
node_expiry_cli proxy-socks --days 2 >/dev/null
jq -e '.nodes[]|select(.id=="proxy-socks")|.enabled and (.expiry.suspended|not)' "$SBM_STATE" >/dev/null
[[ "$original_secret" == "$(sha256sum "$(state_user_secret_path proxy-socks default)")" ]]
# A manually disabled node stays disabled through expiry and renewal.
node_disable proxy-http
node_expiry_cli proxy-http --days 1 >/dev/null
jq '.nodes |= map(if .id=="proxy-http" then .expiry.at=1 else . end)' "$SBM_STATE" >"$ROOT/state.new"
mv "$ROOT/state.new" "$SBM_STATE"
with_lock node_expiry_tick_unlocked
node_expiry_cli proxy-http --clear >/dev/null
jq -e '.nodes[]|select(.id=="proxy-http")|(.enabled|not) and .expiry.at==null' "$SBM_STATE" >/dev/null
expect_failure node_expiry_cli proxy-http --days 0
expect_failure node_expiry_cli proxy-http --at 2020-01-01T00:00:00Z
printf 'PROXY AND EXPIRY SMOKE PASSED\n'
