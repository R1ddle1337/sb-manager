#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(mktemp -d)
runtime_pid=''
trap '[[ -z "$runtime_pid" ]] || kill "$runtime_pid" 2>/dev/null || true; rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export SBM_PREFIX="$ROOT/usr/local" SBM_LIB="$PROJECT" SBM_BIN_DIR="$ROOT/usr/local/bin"
export SBM_ETC="$ROOT/etc/sb-manager" SBM_VAR="$ROOT/var/lib/sb-manager" SBM_RUN="$ROOT/run/sb-manager"
export SBM_STATE="$SBM_ETC/state.json"
export SBM_GENERATED_DIR="$SBM_ETC/generated"
export SBM_CONFIG="$SBM_GENERATED_DIR/config.json"
export SBM_SECRETS="$SBM_ETC/secrets" SBM_CERTS="$SBM_ETC/certs" SBM_BACKUPS="$SBM_VAR/backups" SBM_EXPORTS="$SBM_VAR/exports" SBM_CACHE="$SBM_VAR/cache" SBM_CORE_DIR="$ROOT/cores"
export SBM_LOCK="$SBM_RUN/manager.lock" SBM_SKIP_INIT=1 SBM_SKIP_SYSTEMD=1 SBM_SERVICE_USER=sbmanager NO_COLOR=1
export SBM_SING_BOX_BIN="${SBM_TEST_SING_BOX:?Set SBM_TEST_SING_BOX}"

source "$PROJECT/lib/common.sh"
source "$PROJECT/lib/service.sh"
source "$PROJECT/lib/state.sh"
source "$PROJECT/protocols/snell.sh"
source "$PROJECT/lib/render.sh"
source "$PROJECT/lib/core.sh"
source "$PROJECT/lib/node.sh"
source "$PROJECT/lib/export.sh"

version_ge "$(core_current_version)" 1.14.0-rc.1
state_init
node_add snell --id snell-test --name 'Snell test' --port 24616 --address 192.0.2.1
node_add snell --id snell-http-test --name 'Snell HTTP test' --port 24617 --address 192.0.2.1 --obfs http --obfs-host example.com

[[ $(jq '.nodes|length' "$SBM_STATE") == 2 ]]
[[ $(jq -r '.nodes[]|select(.id=="snell-test")|.obfs_mode' "$SBM_STATE") == none ]]
[[ $(jq -r '.nodes[]|select(.id=="snell-http-test")|.obfs_mode' "$SBM_STATE") == http ]]
[[ $(jq -r '.nodes[]|select(.id=="snell-http-test")|.obfs_host' "$SBM_STATE") == example.com ]]
jq -e '.inbounds[]|select(.tag=="in-snell-test")|.type=="snell" and .version==5 and (.psk|length)>=24 and .users[0].userkey' "$SBM_CONFIG" >/dev/null
jq -e '.inbounds[]|select(.tag=="in-snell-http-test")|.obfs_mode=="http" and (.obfs_host|not)' "$SBM_CONFIG" >/dev/null
"$SBM_SING_BOX_BIN" check -c "$SBM_CONFIG"
"$SBM_SING_BOX_BIN" run -c "$SBM_CONFIG" >"$ROOT/runtime.log" 2>&1 &
runtime_pid=$!
for _ in {1..50}; do
  kill -0 "$runtime_pid" 2>/dev/null || { sed -n '1,120p' "$ROOT/runtime.log" >&2; exit 1; }
  if ss -H -ltn 2>/dev/null | grep -q ':24616[[:space:]]' && ss -H -ltn 2>/dev/null | grep -q ':24617[[:space:]]'; then break; fi
  sleep 0.1
done
ss -H -ltn 2>/dev/null | grep -q ':24616[[:space:]]'
ss -H -ltn 2>/dev/null | grep -q ':24617[[:space:]]'
kill "$runtime_pid"; wait "$runtime_pid" 2>/dev/null || true; runtime_pid=''

for id in snell-test snell-http-test; do
  node_share_uri "$id" | grep -Eq '^snell://.*version=4&userkey='
  node_client_outbound "$id" | jq -e '.type=="snell" and .version==4 and .reuse==false and .network=="tcp" and (.psk|length)>=24 and (.userkey|length)>=24' >/dev/null
  ob=$(node_client_outbound "$id")
  cfg="$ROOT/client-$id.json"
  jq -n --argjson ob "$ob" --argjson port "$((20800 + RANDOM % 1000))" \
    '{log:{level:"error"},inbounds:[{type:"mixed",tag:"mixed-in",listen:"127.0.0.1",listen_port:$port}],outbounds:[$ob],route:{final:$ob.tag}}' >"$cfg"
  "$SBM_SING_BOX_BIN" check -c "$cfg"
done
node_user_add snell-test alice 'Alice Snell'
[[ $(jq '.nodes[]|select(.id=="snell-test")|.users|length' "$SBM_STATE") == 2 ]]
node_rotate snell-test alice
[[ $(jq -r '.userkey|length' "$(state_user_secret_path snell-test alice)") -ge 24 ]]

printf 'SNELL PREVIEW SMOKE PASSED\n'
