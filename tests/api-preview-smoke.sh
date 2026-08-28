#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(mktemp -d)
runtime_pid=''
trap '[[ -z "$runtime_pid" ]] || kill "$runtime_pid" 2>/dev/null || true; rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export SBM_LIB="$PROJECT" SBM_PREFIX="$ROOT/usr/local" SBM_BIN_DIR="$ROOT/usr/local/bin"
export SBM_ETC="$ROOT/etc/sb-manager" SBM_VAR="$ROOT/var/lib/sb-manager" SBM_RUN="$ROOT/run/sb-manager"
export SBM_STATE="$SBM_ETC/state.json" SBM_GENERATED_DIR="$SBM_ETC/generated"
export SBM_CONFIG="$SBM_GENERATED_DIR/config.json" SBM_SECRETS="$SBM_ETC/secrets" SBM_CERTS="$SBM_ETC/certs"
export SBM_BACKUPS="$SBM_VAR/backups" SBM_EXPORTS="$SBM_VAR/exports" SBM_CACHE="$SBM_VAR/cache" SBM_CORE_DIR="$ROOT/cores"
export SBM_LOCK="$SBM_RUN/manager.lock" SBM_SKIP_INIT=1 SBM_SERVICE_USER=sbmanager NO_COLOR=1
export SBM_SING_BOX_BIN="${SBM_TEST_SING_BOX:?Set SBM_TEST_SING_BOX}"

source "$PROJECT/lib/common.sh"
source "$PROJECT/lib/service.sh"
source "$PROJECT/lib/state.sh"
source "$PROJECT/protocols/vmess_ws_cf.sh"
source "$PROJECT/protocols/shadowsocks.sh"
source "$PROJECT/protocols/anytls.sh"
source "$PROJECT/protocols/hysteria2.sh"
source "$PROJECT/protocols/trojan.sh"
source "$PROJECT/protocols/tuic.sh"
source "$PROJECT/protocols/vless.sh"
source "$PROJECT/protocols/naive.sh"
source "$PROJECT/protocols/shadowtls.sh"
source "$PROJECT/lib/render.sh"
source "$PROJECT/lib/core.sh"
source "$PROJECT/lib/api.sh"

version_ge "$(core_current_version)" 1.14.0-rc.1
state_init
api_enable 19090 false >/dev/null
jq -e '.http_clients[0].tag=="http-direct" and .services[0].type=="api" and .services[0].listen=="127.0.0.1" and (.services[0].secret|length>32)' "$SBM_CONFIG" >/dev/null
"$SBM_SING_BOX_BIN" check -c "$SBM_CONFIG"
state_runtime_required

"$SBM_SING_BOX_BIN" run -c "$SBM_CONFIG" >"$ROOT/api.log" 2>&1 &
runtime_pid=$!
for _ in {1..30}; do kill -0 "$runtime_pid" 2>/dev/null || { cat "$ROOT/api.log" >&2; exit 1; }; ss -H -ltn | awk '{print $4}' | grep -Fxq '127.0.0.1:19090' && break; sleep 0.1; done
ss -H -ltn | awk '{print $4}' | grep -Fxq '127.0.0.1:19090'
! ss -H -ltn | awk '{print $4}' | grep -Fxq '0.0.0.0:19090'
kill "$runtime_pid"; wait "$runtime_pid" 2>/dev/null || true; runtime_pid=''

candidate=$(state_candidate)
jq '.api.dashboard=true' "$SBM_STATE" >"$candidate"
apply_candidate_state "$candidate" api-dashboard-preview >/dev/null
jq -e '.services[0].dashboard.enabled==true and .services[0].dashboard.http_client=="http-direct"' "$SBM_CONFIG" >/dev/null
api_disable >/dev/null
[[ ! -e $(state_secret_path api) ]]
printf 'API PREVIEW SMOKE PASSED\n'
