#!/usr/bin/env bash
set -Eeuo pipefail
# Use verified official assets in isolated local/container paths only.
ASSETS=${SBM_TEST_COMPONENT_ASSETS:?Set SBM_TEST_COMPONENT_ASSETS to verified Sub-Store assets}
source "$(dirname "${BASH_SOURCE[0]}")/feature-fixture.sh"
pids=()
cleanup() { for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done; rm -rf "$ROOT"; }
trap cleanup EXIT
export SBM_SUBSTORE_NODE
SBM_SUBSTORE_NODE=$(command -v node)
export SBM_SUBSCRIPTION_PORT=$((30000 + RANDOM % 8000))
store_port=$((40000 + RANDOM % 8000))
remote_port=$((50000 + RANDOM % 8000))
dependency_require_feature() { return 0; }
substore_download_asset() {
  local repo=$1 version=$2 asset=$3 output=$4 file
  if [[ "$asset" == sub-store.bundle.js ]]; then file=sub-store.bundle.js; else file=frontend.zip; fi
  verify_asset_digest "$ASSETS/$file" "sha256:$(jq -r '.sha256' "$ASSETS/$file.meta.json")" || return 1
  cp "$ASSETS/$file" "$output"
  cat "$ASSETS/$file.meta.json"
}
node_add ss --id local-node --port 28561 --address 192.0.2.11 >/dev/null
substore_install latest latest "$store_port" >/dev/null
"$SBM_SUBSTORE_DIR/run.sh" >"$ROOT/store.log" 2>&1 & pids+=("$!")
for ((i=0;i<60;i++)); do substore_resource_list sub >"$ROOT/subs" 2>/dev/null && break; sleep 0.2; done
jq -e 'type=="array"' "$ROOT/subs" >/dev/null
mkdir -p "$SBM_SUBSCRIPTIONS"
python3 "$PROJECT/libexec/subscription_server.py" --root "$SBM_SUBSCRIPTIONS" --port "$SBM_SUBSCRIPTION_PORT" >"$ROOT/local-http.log" 2>&1 & pids+=("$!")
with_lock _substore_sync sb-manager
local_count=$(find "$SBM_SUBSCRIPTIONS" -name '*.meta.json' | wc -l)
with_lock _substore_sync sb-manager
[[ $(find "$SBM_SUBSCRIPTIONS" -name '*.meta.json' | wc -l) == "$local_count" ]]
substore_api GET /api/sub/sb-manager | jq -e '.data.source=="remote" and .data.content==""' >/dev/null
substore_source_check sb-manager >"$ROOT/check"
substore_api GET '/download/collection/sb-manager-all?target=JSON&noCache=true' | jq -e 'length==1 and .[0].server=="192.0.2.11"' >/dev/null
node_set local-node --address 192.0.2.12 >/dev/null
substore_api GET '/download/collection/sb-manager-all?target=JSON' | jq -e 'length==1 and .[0].server=="192.0.2.12"' >/dev/null

# A second HTTP server represents another sb-manager behind an SSH forward.
remote_token=$(random_password 36)
remote_digest=$(printf '%s' "$remote_token" | sha256sum | awk '{print $1}')
mkdir -p "$ROOT/remote"
jq -n '{schema_version:1,live:true,mode:"mixed",expires_at_epoch:null}' >"$ROOT/remote/$remote_digest.meta.json"
remote_link="ss://$(printf 'aes-128-gcm:remote-test-password' | base64 | tr -d '\n')@198.51.100.21:28562#remote-node"
jq -n --arg links "$remote_link" '{substore:$links}' >"$ROOT/remote/live.json"
python3 "$PROJECT/libexec/subscription_server.py" --root "$ROOT/remote" --port "$remote_port" >"$ROOT/remote-http.log" 2>&1 & pids+=("$!")
remote_url="http://127.0.0.1:$remote_port/sub/$remote_token?format=substore"
for ((i=0;i<30;i++)); do curl -fsS "$remote_url" >/dev/null 2>&1 && break; sleep 0.1; done
substore_cli source add remote-node "$remote_url"
substore_api GET '/download/collection/sb-manager-all?target=JSON' | jq -e 'length==2 and any(.[];.server=="198.51.100.21")' >/dev/null
printf '%s\n' '{"name":"sb-manager-all","subscriptions":["remote-node","sb-manager"],"firstSubFlow":false}' >"$ROOT/ordered-collection"
substore_resource_write collection sb-manager-all "$ROOT/ordered-collection" true
substore_cli source add remote-node "$remote_url"
substore_api GET /api/collection/sb-manager-all | jq -e '.data.subscriptions==["remote-node","sb-manager"] and .data.firstSubFlow==false' >/dev/null
jq '.substore |= sub("198.51.100.21";"198.51.100.22")' "$ROOT/remote/live.json" >"$ROOT/remote/new.json"
mv "$ROOT/remote/new.json" "$ROOT/remote/live.json"
substore_api GET '/download/collection/sb-manager-all?target=JSON' | jq -e 'length==2 and any(.[];.server=="198.51.100.22")' >/dev/null
substore_cli source list --json >"$ROOT/source-list"
! grep -Fq "$remote_token" "$ROOT/source-list"
jq -e 'any(.[];.name=="remote-node" and .collections==["sb-manager-all"])' "$ROOT/source-list" >/dev/null

# Failure after updating the source restores its old URL and collection.
substore_api GET /api/sub/remote-node | jq '.data' >"$ROOT/before-source"
substore_api GET /api/collection/sb-manager-all | jq '.data' >"$ROOT/before-collection"
(
  # Save our own tool wrapper, then inject one API failure after source mutation.
  eval "$(declare -f substore_api | sed '1s/substore_api/substore_api_real/')"
  substore_api() {
    if [[ "$1" == PATCH && "$2" == /api/collection/sb-manager-all && ! -e "$ROOT/injected" ]]; then
      touch "$ROOT/injected"; return 1
    fi
    substore_api_real "$@"
  }
  expect_failure substore_cli source add remote-node 'https://example.com/new-token' >"$ROOT/rollback.log" 2>&1
)
substore_api GET /api/sub/remote-node | jq '.data' >"$ROOT/after-source"
substore_api GET /api/collection/sb-manager-all | jq '.data' >"$ROOT/after-collection"
cmp "$ROOT/before-source" "$ROOT/after-source"
cmp "$ROOT/before-collection" "$ROOT/after-collection"
for invalid in 'file:///etc/passwd' 'http://example.com/sub/token' 'https://user:password@example.com/token' $'https://example.com/\nsecret'; do
  expect_failure substore_cli source add invalid "$invalid" >"$ROOT/invalid.log" 2>&1
done
substore_cli source remove remote-node >/dev/null
substore_api GET /api/collection/sb-manager-all | jq -e '.data.subscriptions==["sb-manager"]' >/dev/null
substore_api GET '/download/collection/sb-manager-all?target=JSON' | jq -e 'length==1' >/dev/null
printf 'REAL SUBSTORE SOURCES AND LIVE MERGE PASSED\n'
