#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
REAL=${SBM_TEST_SING_BOX:?Set SBM_TEST_SING_BOX}

export SBM_TEST_MODE=1 SBM_SKIP_INIT=1 SBM_SKIP_SYSTEMD=1 SBM_TEST_SING_BOX="$REAL"
export SBM_INSTALL_PROFILE=minimal SBM_INSTALL_CLOUDFLARED=0 NO_COLOR=1
export SBM_PREFIX="$ROOT/usr/local" SBM_LIB="$ROOT/usr/local/lib/sb-manager" SBM_BIN_DIR="$ROOT/usr/local/bin"
export SBM_ETC="$ROOT/etc/sb-manager" SBM_VAR="$ROOT/var/lib/sb-manager" SBM_RUN="$ROOT/run/sb-manager"
export SBM_SYSTEMD_DIR="$ROOT/etc/systemd/system" SBM_OPENRC_DIR="$ROOT/etc/init.d" SBM_PERIODIC_DIR="$ROOT/etc/periodic"
export SBM_LOG_DIR="$ROOT/var/log/sb-manager" SBM_STATE="$SBM_ETC/state.json" SBM_GENERATED_DIR="$SBM_ETC/generated"
export SBM_CONFIG="$SBM_GENERATED_DIR/config.json" SBM_SECRETS="$SBM_ETC/secrets" SBM_CERTS="$SBM_ETC/certs"
export SBM_BACKUPS="$SBM_VAR/backups" SBM_EXPORTS="$SBM_VAR/exports" SBM_CACHE="$SBM_VAR/cache"
export SBM_CORE_DIR="$SBM_LIB/cores" SBM_LOCK="$SBM_RUN/manager.lock" SBM_SERVICE_USER=root
export SBM_SING_BOX_BIN="$SBM_BIN_DIR/sing-box" SBM_CLOUDFLARED_BIN="$SBM_BIN_DIR/cloudflared"

bash "$PROJECT/setup.sh" --no-menu --no-start

[[ -x "$SBM_BIN_DIR/sb" && -x "$SBM_SING_BOX_BIN" ]]
[[ ! -e "$SBM_CLOUDFLARED_BIN" && ! -d "$SBM_CORE_DIR/cloudflared" ]]
[[ ! -d "$SBM_LIB/tests" && ! -d "$SBM_LIB/docs" && ! -d "$SBM_LIB/sing-box-official-docs-cn" ]]
[[ -f "$SBM_CONFIG" && -s "$SBM_STATE" ]]
"$SBM_BIN_DIR/sb" cloudflared status | grep -q '未安装（按需执行'
"$SBM_BIN_DIR/sb" deps status --json | jq -e 'type=="array" and length >= 5' >/dev/null

# A Tunnel request must fail with an actionable opt-in hint, without silently
# downloading the 40MB optional binary or changing tunnel state.
"$SBM_BIN_DIR/sb" node add vmess --id minimal-vm --port 29123 --domain cdn.example.com --address cdn.example.com >/dev/null
if "$SBM_BIN_DIR/sb" tunnel quick minimal-vm >/dev/null 2>&1; then
  echo 'Tunnel unexpectedly succeeded without cloudflared' >&2
  exit 1
fi
[[ $(jq -r '.tunnel.mode' "$SBM_STATE") == none ]]

printf 'MINIMAL INSTALL SMOKE PASSED\n'
