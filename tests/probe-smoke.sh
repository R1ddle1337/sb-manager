#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(mktemp -d)
trap '[[ -z ${runtime_pid:-} ]] || kill "$runtime_pid" 2>/dev/null || true; rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export SBM_PREFIX="$ROOT/usr/local" SBM_LIB="$PROJECT" SBM_BIN_DIR="$ROOT/usr/local/bin"
export SBM_ETC="$ROOT/etc/sb-manager" SBM_VAR="$ROOT/var/lib/sb-manager" SBM_RUN="$ROOT/run/sb-manager"
export SBM_STATE="$SBM_ETC/state.json" SBM_GENERATED_DIR="$SBM_ETC/generated"
export SBM_CONFIG="$SBM_GENERATED_DIR/config.json"
export SBM_SECRETS="$SBM_ETC/secrets" SBM_CERTS="$SBM_ETC/certs" SBM_BACKUPS="$SBM_VAR/backups" SBM_EXPORTS="$SBM_VAR/exports" SBM_CACHE="$SBM_VAR/cache"
export SBM_CORE_DIR="$ROOT/cores" SBM_LOCK="$SBM_RUN/manager.lock" SBM_SING_BOX_BIN="${SBM_TEST_SING_BOX:?Set SBM_TEST_SING_BOX}"
export SBM_SKIP_INIT=1 SBM_SKIP_SYSTEMD=1 NO_COLOR=1

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
source "$PROJECT/lib/doctor.sh"

state_init
port=$((30000 + RANDOM % 10000))
node_add ss --id probe-test --port "$port" --address 127.0.0.1 >/dev/null
"$SBM_SING_BOX_BIN" run -c "$SBM_CONFIG" >"$ROOT/runtime.log" 2>&1 &
runtime_pid=$!
for _ in {1..30}; do
  kill -0 "$runtime_pid" 2>/dev/null || { cat "$ROOT/runtime.log" >&2; exit 1; }
  ss -H -ltn | grep -Eq ":${port}\\b" && break
  sleep 0.1
done
output=$(doctor_probe probe-test 2>&1)
grep -q "probe-test 地址为 IP" <<<"$output"
grep -q "probe-test 本机监听 ${port}/TCP" <<<"$output"
grep -q '结果：0 个失败' <<<"$output"
printf 'PROBE SMOKE PASSED\n'
