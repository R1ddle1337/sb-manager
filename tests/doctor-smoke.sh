#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
REAL=${SBM_TEST_SING_BOX:?Set SBM_TEST_SING_BOX}

export SBM_PREFIX="$ROOT/usr/local"
export SBM_LIB="$PROJECT"
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
export SBM_CORE_DIR="$ROOT/cores"
export SBM_LOCK="$SBM_RUN/manager.lock"
export SBM_SING_BOX_BIN="$SBM_BIN_DIR/sing-box"
export SBM_CLOUDFLARED_BIN="$SBM_BIN_DIR/cloudflared"
export SBM_SERVICE_USER
SBM_SERVICE_USER=$(id -un)
export SBM_SKIP_INIT=1 SBM_SKIP_SYSTEMD=1 NO_COLOR=1

mkdir -p "$SBM_CORE_DIR/sing-box/test" "$SBM_BIN_DIR"
install -m 0755 "$REAL" "$SBM_CORE_DIR/sing-box/test/sing-box"
ln -s "$SBM_CORE_DIR/sing-box/test/sing-box" "$SBM_SING_BOX_BIN"

# shellcheck source=lib/common.sh
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
source "$PROJECT/lib/doctor.sh"

state_init
render_current_config

# Missing cloudflared deliberately creates the first warning. Under `set -e`,
# unsafe `((warnings++))` used to terminate doctor before its final summary.
output=$(doctor_run 2>&1)
grep -q '\[WARN\] cloudflared' <<<"$output"
grep -q '暂无启用节点\|测试模式' <<<"$output" || true
grep -q '结果：0 个失败' <<<"$output"
printf 'DOCTOR SMOKE PASSED\n'
