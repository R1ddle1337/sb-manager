#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export SBM_LIB="$PROJECT" SBM_PREFIX="$ROOT/usr/local" SBM_BIN_DIR="$ROOT/usr/local/bin"
export SBM_ETC="$ROOT/etc/sb-manager" SBM_VAR="$ROOT/var/lib/sb-manager" SBM_RUN="$ROOT/run/sb-manager"
export SBM_STATE="$SBM_ETC/state.json" SBM_GENERATED_DIR="$SBM_ETC/generated"
export SBM_CONFIG="$SBM_GENERATED_DIR/config.json" SBM_SECRETS="$SBM_ETC/secrets" SBM_CERTS="$SBM_ETC/certs"
export SBM_BACKUPS="$SBM_VAR/backups" SBM_EXPORTS="$SBM_VAR/exports" SBM_CACHE="$SBM_VAR/cache"
export SBM_CORE_DIR="$ROOT/cores" SBM_LOCK="$SBM_RUN/manager.lock" SBM_SKIP_INIT=1 NO_COLOR=1
export SBM_SING_BOX_BIN="${SBM_TEST_SING_BOX:?Set SBM_TEST_SING_BOX}"

source "$PROJECT/lib/common.sh"
source "$PROJECT/lib/service.sh"
source "$PROJECT/lib/state.sh"
source "$PROJECT/protocols/vmess_ws_cf.sh"
source "$PROJECT/protocols/shadowsocks.sh"
source "$PROJECT/protocols/anytls.sh"
source "$PROJECT/protocols/hysteria2.sh"
source "$PROJECT/lib/render.sh"
source "$PROJECT/lib/core.sh"
source "$PROJECT/lib/node.sh"

state_init
node_add ss --id legacy-ss --port 28388 --address 192.0.2.1
cp "$(state_user_secret_path legacy-ss default)" "$SBM_SECRETS/nodes/legacy-ss.json"
rm -rf "$SBM_SECRETS/users"
jq '.schema_version=1 | .nodes |= map(del(.users,.credential_mode))' "$SBM_STATE" >"$SBM_STATE.v1"
mv "$SBM_STATE.v1" "$SBM_STATE"

state_init
jq -e '.schema_version==2 and (.nodes[0].users[0].id=="default")' "$SBM_STATE" >/dev/null
[[ -s $(state_user_secret_path legacy-ss default) ]]
[[ ! -e $SBM_SECRETS/nodes/legacy-ss.json ]]
render_current_config
"$SBM_SING_BOX_BIN" check -c "$SBM_CONFIG"
find "$SBM_BACKUPS/snapshots" -maxdepth 1 -type d -name '*schema-v1*' | grep -q .

# Older schema-v2 state files are normalized in place when new optional
# manager-owned sections are introduced.
jq 'del(.nginx_stream)' "$SBM_STATE" >"$SBM_STATE.old-v2"
mv "$SBM_STATE.old-v2" "$SBM_STATE"
state_init
jq -e '.nginx_stream=={enabled:false,listen:"::",port:443,routes:[]}' "$SBM_STATE" >/dev/null
printf 'STATE MIGRATION SMOKE PASSED\n'
