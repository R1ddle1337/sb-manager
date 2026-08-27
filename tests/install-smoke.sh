#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
REAL=${SBM_TEST_SING_BOX:?Set SBM_TEST_SING_BOX}
export SBM_TEST_MODE=1 SBM_SKIP_SYSTEMD=1 SBM_TEST_SING_BOX="$REAL" NO_COLOR=1
export SBM_PREFIX="$ROOT/usr/local"
export SBM_LIB="$ROOT/usr/local/lib/sb-manager"
export SBM_BIN_DIR="$ROOT/usr/local/bin"
export SBM_ETC="$ROOT/etc/sb-manager"
export SBM_VAR="$ROOT/var/lib/sb-manager"
export SBM_RUN="$ROOT/run/sb-manager"
export SBM_SYSTEMD_DIR="$ROOT/etc/systemd/system"
export SBM_STATE="$SBM_ETC/state.json"
export SBM_GENERATED_DIR="$SBM_ETC/generated"
export SBM_CONFIG="$SBM_GENERATED_DIR/config.json"
export SBM_SECRETS="$SBM_ETC/secrets"
export SBM_CERTS="$SBM_ETC/certs"
export SBM_BACKUPS="$SBM_VAR/backups"
export SBM_EXPORTS="$SBM_VAR/exports"
export SBM_CACHE="$SBM_VAR/cache"
export SBM_CORE_DIR="$SBM_LIB/cores"
export SBM_LOCK="$SBM_RUN/manager.lock"
export SBM_SING_BOX_BIN="$SBM_BIN_DIR/sing-box"
export SBM_CLOUDFLARED_BIN="$SBM_BIN_DIR/cloudflared"

bash "$PROJECT/setup.sh" --no-menu --no-start
[[ -x "$SBM_BIN_DIR/sb" && -x "$SBM_SING_BOX_BIN" && -x "$SBM_CLOUDFLARED_BIN" ]]
env -u SBM_LIB "$SBM_BIN_DIR/sb" version | grep -q "0.1.0-alpha.1"
[[ -f "$SBM_SYSTEMD_DIR/sb-sing-box.service" && -f "$SBM_SYSTEMD_DIR/sb-core-update.timer" ]]
"$SBM_BIN_DIR/sb" node add vmess --id persist-test --port 29111 --domain cdn.example.com --address cdn.example.com
[[ $(jq '.nodes|length' "$SBM_STATE") == 1 ]]

# Reinstall/upgrade must preserve state and installed cores.
bash "$PROJECT/setup.sh" --no-menu --no-start
[[ $(jq '.nodes|length' "$SBM_STATE") == 1 ]]
"$SBM_SING_BOX_BIN" check -c "$SBM_CONFIG"

# Exercise core switch and rollback without systemd.
mkdir -p "$SBM_CORE_DIR/sing-box/9.9.9"
cat >"$SBM_CORE_DIR/sing-box/9.9.9/sing-box" <<EOF_WRAPPER
#!/usr/bin/env bash
if [[ \${1:-} == version ]]; then echo 'sing-box version 9.9.9'; exit 0; fi
exec "$REAL" "\$@"
EOF_WRAPPER
chmod +x "$SBM_CORE_DIR/sing-box/9.9.9/sing-box"
# Source installed libraries so we can select local version without network.
source "$SBM_LIB/lib/common.sh"
source "$SBM_LIB/lib/state.sh"
source "$SBM_LIB/protocols/vmess_ws_cf.sh"
source "$SBM_LIB/protocols/shadowsocks.sh"
source "$SBM_LIB/protocols/anytls.sh"
source "$SBM_LIB/protocols/hysteria2.sh"
source "$SBM_LIB/lib/render.sh"
source "$SBM_LIB/lib/core.sh"
old=$(core_current_version)
core_switch_to 9.9.9
[[ $(core_current_version) == 9.9.9 ]]
sleep 1
core_rollback
[[ $(core_current_version) == "$old" ]]

printf 'INSTALL SMOKE PASSED\n'
