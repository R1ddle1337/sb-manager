#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
REAL=${SBM_TEST_SING_BOX:?Set SBM_TEST_SING_BOX}

export SBM_PREFIX="$ROOT/usr/local" SBM_LIB="$PROJECT" SBM_BIN_DIR="$ROOT/usr/local/bin"
export SBM_ETC="$ROOT/etc/sb-manager" SBM_VAR="$ROOT/var/lib/sb-manager" SBM_RUN="$ROOT/run/sb-manager"
export SBM_STATE="$SBM_ETC/state.json" SBM_GENERATED_DIR="$SBM_ETC/generated"
export SBM_CONFIG="$SBM_GENERATED_DIR/config.json" SBM_SECRETS="$SBM_ETC/secrets" SBM_CERTS="$SBM_ETC/certs"
export SBM_BACKUPS="$SBM_VAR/backups" SBM_EXPORTS="$SBM_VAR/exports" SBM_CACHE="$SBM_VAR/cache"
export SBM_CORE_DIR="$ROOT/cores" SBM_LOCK="$SBM_RUN/manager.lock" SBM_SKIP_INIT=1 NO_COLOR=1
export SBM_SING_BOX_BIN="$SBM_BIN_DIR/sing-box"

mkdir -p "$SBM_BIN_DIR" "$SBM_CORE_DIR/sing-box/9.9.9" "$SBM_CORE_DIR/sing-box/10.0.0"
install -m 0755 "$REAL" "$ROOT/real-sing-box"
cat >"$SBM_CORE_DIR/sing-box/9.9.9/sing-box" <<'EOF_OLD'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ${1:-} == version ]]; then
  printf 'sing-box version 9.9.9\n'
  exit 0
fi
if [[ ${1:-} == check ]]; then
  config=${3:-}
  grep -q '"level"[[:space:]]*:[[:space:]]*"debug"' "$config" && exit 1
fi
exec "REAL_CORE_PATH" "$@"
EOF_OLD
cat >"$SBM_CORE_DIR/sing-box/10.0.0/sing-box" <<'EOF_NEW'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ${1:-} == version ]]; then
  printf 'sing-box version 10.0.0\n'
  exit 0
fi
exec "REAL_CORE_PATH" "$@"
EOF_NEW
sed -i "s#REAL_CORE_PATH#$ROOT/real-sing-box#g" "$SBM_CORE_DIR/sing-box/9.9.9/sing-box" "$SBM_CORE_DIR/sing-box/10.0.0/sing-box"
chmod 0755 "$SBM_CORE_DIR/sing-box/9.9.9/sing-box" "$SBM_CORE_DIR/sing-box/10.0.0/sing-box"
ln -s "$SBM_CORE_DIR/sing-box/9.9.9/sing-box" "$SBM_SING_BOX_BIN"

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

state_init
render_current_config
[[ $(core_current_version) == 9.9.9 ]]
core_switch_to 10.0.0 >/dev/null
[[ $(core_current_version) == 10.0.0 ]]

# Simulate a post-upgrade configuration that only the new core accepts.
jq '.log.level="debug"' "$SBM_CONFIG" >"$SBM_CONFIG.new"
mv "$SBM_CONFIG.new" "$SBM_CONFIG"
[[ $(jq -r '.log.level' "$SBM_CONFIG") == debug ]]
core_rollback >/dev/null
[[ $(core_current_version) == 9.9.9 ]]
[[ $(jq -r '.log.level' "$SBM_CONFIG") == info ]]
"$SBM_SING_BOX_BIN" check -c "$SBM_CONFIG"
printf 'CORE PAIRED ROLLBACK SMOKE PASSED\n'
