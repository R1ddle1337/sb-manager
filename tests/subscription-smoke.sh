#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(mktemp -d)
server_pid=''
trap '[[ -z "$server_pid" ]] || kill "$server_pid" 2>/dev/null || true; rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export SBM_LIB="$PROJECT" SBM_PREFIX="$ROOT/usr/local" SBM_BIN_DIR="$ROOT/usr/local/bin"
export SBM_ETC="$ROOT/etc/sb-manager" SBM_VAR="$ROOT/var/lib/sb-manager" SBM_RUN="$ROOT/run/sb-manager"
export SBM_STATE="$SBM_ETC/state.json" SBM_GENERATED_DIR="$SBM_ETC/generated"
export SBM_CONFIG="$SBM_GENERATED_DIR/config.json"
export SBM_SECRETS="$SBM_ETC/secrets" SBM_CERTS="$SBM_ETC/certs" SBM_BACKUPS="$SBM_VAR/backups" SBM_EXPORTS="$SBM_VAR/exports" SBM_CACHE="$SBM_VAR/cache"
export SBM_CORE_DIR="$ROOT/cores" SBM_LOCK="$SBM_RUN/manager.lock" SBM_SYSTEMD_DIR="$ROOT/etc/systemd/system" SBM_OPENRC_DIR="$ROOT/etc/init.d"
export SBM_SUBSCRIPTIONS="$SBM_VAR/subscriptions" SBM_SUBSCRIPTION_PORT=19080 SBM_SKIP_INIT=1 NO_COLOR=1
export SBM_SERVICE_USER SBM_SING_BOX_BIN="${SBM_TEST_SING_BOX:?Set SBM_TEST_SING_BOX}"
SBM_SERVICE_USER=$(id -un)

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
source "$PROJECT/lib/node.sh"
source "$PROJECT/lib/export.sh"
source "$PROJECT/lib/subscription.sh"

state_init
node_add ss --id sub-test --port 28388 --address 192.0.2.1 >/dev/null
created=$(subscription_create 24h mixed)
token=$(sed -n 's#.*127\.0\.0\.1:19080/sub/##p' <<<"$created")
[[ "$token" =~ ^[A-Za-z0-9_-]{32,128}$ ]]
digest=$(printf '%s' "$token" | sha256sum | awk '{print $1}')
[[ -s "$SBM_SUBSCRIPTIONS/$digest.profile.json" && -s "$SBM_SUBSCRIPTIONS/$digest.meta.json" ]]

python3 "$PROJECT/libexec/subscription_server.py" --root "$SBM_SUBSCRIPTIONS" --listen 127.0.0.1 --port "$SBM_SUBSCRIPTION_PORT" >"$ROOT/server.log" 2>&1 &
server_pid=$!
for _ in {1..20}; do curl -fsS "http://127.0.0.1:$SBM_SUBSCRIPTION_PORT/sub/$token" -o "$ROOT/fetched.json" && break; sleep 0.1; done
cmp "$ROOT/fetched.json" "$SBM_SUBSCRIPTIONS/$digest.profile.json"
"$SBM_SING_BOX_BIN" check -c "$ROOT/fetched.json"
! grep -Fq "$token" "$ROOT/server.log"
subscription_revoke "$token" >/dev/null
[[ $(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$SBM_SUBSCRIPTION_PORT/sub/$token") == 404 ]]
printf 'SUBSCRIPTION SMOKE PASSED\n'
