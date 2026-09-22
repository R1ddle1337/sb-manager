#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/feature-fixture.sh"
server_pid=''
cleanup() { [[ -z "$server_pid" ]] || { kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; }; rm -rf "$ROOT"; }
trap cleanup EXIT
export SBM_SUBSCRIPTION_PORT=$((30000 + RANDOM % 20000))
node_add ss --id live-node --port 28471 --address 192.0.2.1 >/dev/null
subscription_create_cli never mixed --live >"$ROOT/created"
token=$(sed -n 's#^本机 URL：.*/sub/##p' "$ROOT/created")
[[ "$token" =~ ^[A-Za-z0-9_-]{32,128}$ ]]
digest=$(printf '%s' "$token" | sha256sum | awk '{print $1}')
meta="$SBM_SUBSCRIPTIONS/$digest.meta.json"
jq -e '.live and .expires_at_epoch==null' "$meta" >/dev/null
[[ $(stat -c '%a' "$meta") == 640 && $(stat -c '%a' "$SBM_SUBSCRIPTIONS/live.json") == 640 ]]
[[ ! -e "$SBM_SUBSCRIPTIONS/$digest.profile.json" ]]
subscription_create_cli 24h mixed >"$ROOT/snapshot-created"
snapshot_token=$(sed -n 's#^本机 URL：.*/sub/##p' "$ROOT/snapshot-created")
snapshot_digest=$(printf '%s' "$snapshot_token" | sha256sum | awk '{print $1}')
cp "$SBM_SUBSCRIPTIONS/$snapshot_digest.profile.json" "$ROOT/snapshot-original"
subscription_create_cli never tun --live --base-url https://feed.example.test >"$ROOT/public-created"
grep -Fq '远程 Sub-Store URL：https://feed.example.test/sub/' "$ROOT/public-created"
SBM_INIT_SYSTEM_RESOLVED=openrc subscription_write_service
grep -Fq -- '--listen 127.0.0.1' "$SBM_OPENRC_DIR/sb-subscription"
SBM_INIT_SYSTEM_RESOLVED=systemd subscription_write_service
grep -Fq 'ProtectSystem=strict' "$SBM_SYSTEMD_DIR/$SBM_SUBSCRIPTION_SERVICE"

python3 "$PROJECT/libexec/subscription_server.py" --root "$SBM_SUBSCRIPTIONS" --port "$SBM_SUBSCRIPTION_PORT" >"$ROOT/http.log" 2>&1 &
server_pid=$!
url="http://127.0.0.1:$SBM_SUBSCRIPTION_PORT/sub/$token"
for ((i=0;i<40;i++)); do curl -fsS "$url" -o "$ROOT/fetched.json" 2>/dev/null && break; sleep 0.1; done
jq -e '.outbounds[0].server=="192.0.2.1"' "$ROOT/fetched.json" >/dev/null
node_set live-node --address 192.0.2.2 --port 28472 >/dev/null
curl -fsS "$url" | jq -e '.outbounds[0].server=="192.0.2.2" and .outbounds[0].server_port==28472' >/dev/null
cmp "$SBM_SUBSCRIPTIONS/$snapshot_digest.profile.json" "$ROOT/snapshot-original"
jq -e '.profiles.tun.outbounds[0].server_port==28472' "$SBM_SUBSCRIPTIONS/live.json" >/dev/null
curl -fsS "$url?format=substore" -o "$ROOT/before-links"
node_rotate live-node >/dev/null
curl -fsS "$url?format=substore" -o "$ROOT/after-links"
! cmp -s "$ROOT/before-links" "$ROOT/after-links"
node_add ss --id another-node --port 28473 --address 192.0.2.3 >/dev/null
curl -fsS "$url" | jq -e '.outbounds|length==3' >/dev/null
node_disable live-node >/dev/null
curl -fsS "$url" | jq -e '.outbounds|length==2' >/dev/null
node_delete another-node >/dev/null
curl -fsS "$url" | jq -e '.outbounds==[{type:"direct",tag:"direct"}]' >/dev/null
node_enable live-node >/dev/null

backup_create "$ROOT/live-backup.tar.gz" >/dev/null
node_set live-node --address 192.0.2.99 >/dev/null
backup_restore "$ROOT/live-backup.tar.gz" 1 >/dev/null
curl -fsS "$url" | jq -e '.outbounds[0].server=="192.0.2.2"' >/dev/null

# Failed validation/publication and dry-run must preserve the previous feed.
cp "$SBM_STATE" "$ROOT/before-state"
cp "$SBM_SUBSCRIPTIONS/live.json" "$ROOT/before-bundle"
cp "$(state_user_secret_path live-node default)" "$ROOT/before-secret"
SBM_DRY_RUN=1 node_set live-node --name preview-only >/dev/null
cmp "$SBM_SUBSCRIPTIONS/live.json" "$ROOT/before-bundle"
expect_failure node_set live-node --port invalid >"$ROOT/validation.log" 2>&1
cmp "$SBM_SUBSCRIPTIONS/live.json" "$ROOT/before-bundle"
(
  subscription_refresh_live() { return 1; }
  expect_failure node_set live-node --name unpublished >"$ROOT/publication.log" 2>&1
  expect_failure node_rotate live-node >"$ROOT/rotation.log" 2>&1
)
cmp "$SBM_STATE" "$ROOT/before-state"
cmp "$SBM_SUBSCRIPTIONS/live.json" "$ROOT/before-bundle"
cmp "$(state_user_secret_path live-node default)" "$ROOT/before-secret"

before_count=$(find "$SBM_SUBSCRIPTIONS" -name '*.meta.json' | wc -l)
(
  subscription_reconcile() { return 1; }
  expect_failure subscription_create_cli never mixed --live >"$ROOT/create-failure.log" 2>&1
)
[[ $(find "$SBM_SUBSCRIPTIONS" -name '*.meta.json' | wc -l) == "$before_count" ]]
expect_failure subscription_create_cli never mixed >"$ROOT/duration.log" 2>&1
expect_failure subscription_create_cli 999999999999999999d mixed >"$ROOT/oversized.log" 2>&1
subscription_list 1 | jq -e 'any(.[];.live and .status=="active" and .expires_at_epoch==null)' >/dev/null
SBM_DRY_RUN=1 expect_failure subscription_revoke "${digest:0:12}" >"$ROOT/revoke-dry-run.log" 2>&1
[[ -f "$meta" ]]
jq '.expires_at_epoch="invalid"' "$meta" >"$ROOT/invalid-expiry"
mv "$ROOT/invalid-expiry" "$meta"
subscription_list 1 | jq -e 'any(.[];.live and .status=="invalid")' >/dev/null
[[ $(curl -s -o /dev/null -w '%{http_code}' "$url") == 404 ]]
jq '.expires_at_epoch=1' "$meta" >"$ROOT/live-expired"
mv "$ROOT/live-expired" "$meta"
[[ $(curl -s -o /dev/null -w '%{http_code}' "$url") == 410 ]]
subscription_revoke "${digest:0:12}" >/dev/null
[[ $(curl -s -o /dev/null -w '%{http_code}' "$url") == 404 ]]
jq '.expires_at_epoch=1' "$SBM_SUBSCRIPTIONS/$snapshot_digest.meta.json" >"$ROOT/expired"
mv "$ROOT/expired" "$SBM_SUBSCRIPTIONS/$snapshot_digest.meta.json"
[[ $(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$SBM_SUBSCRIPTION_PORT/sub/$snapshot_token") == 410 ]]
! grep -Fq "$token" "$ROOT/http.log"
printf 'LIVE SUBSCRIPTION SMOKE PASSED\n'
