#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || { echo 'REAL SYSTEMD EXEC SKIPPED: sudo unavailable'; exit 0; }
  exec sudo env SBM_TEST_SING_BOX="${SBM_TEST_SING_BOX:?Set SBM_TEST_SING_BOX}" NO_COLOR=1 bash "$0"
fi

pid1=$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ' || true)
if [[ "$pid1" != systemd ]] || ! systemctl show-environment >/dev/null 2>&1; then
  echo 'REAL SYSTEMD EXEC SKIPPED: systemd is not PID 1'
  exit 0
fi

REAL=${SBM_TEST_SING_BOX:?Set SBM_TEST_SING_BOX}
ROOT=$(mktemp -d /var/tmp/sb-manager-systemd-exec.XXXXXX)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

export SBM_PREFIX="$ROOT/usr/local"
export SBM_LIB="$ROOT/usr/local/lib/sb-manager"
export SBM_BIN_DIR="$ROOT/usr/local/bin"
export SBM_ETC="$ROOT/etc/sb-manager"
export SBM_VAR="$ROOT/var/lib/sb-manager"
export SBM_RUN="$ROOT/run/sb-manager"
export SBM_CORE_DIR="$SBM_LIB/cores"
export SBM_SING_BOX_BIN="$SBM_BIN_DIR/sing-box"
export SBM_SERVICE_USER=daemon
export SBM_INIT_SYSTEM=systemd
export SBM_INIT_SYSTEM_RESOLVED=systemd
export SBM_SKIP_INIT=0
export NO_COLOR=1

mkdir -p "$SBM_BIN_DIR" "$SBM_CORE_DIR/sing-box/test" "$SBM_ETC" "$SBM_RUN" "$SBM_VAR"
chmod 0755 "$ROOT" "$ROOT/usr" "$ROOT/usr/local" "$SBM_BIN_DIR" \
  "$ROOT/usr/local/lib" "$SBM_LIB" "$SBM_CORE_DIR" "$SBM_CORE_DIR/sing-box" \
  "$SBM_CORE_DIR/sing-box/test" "$ROOT/etc" "$SBM_ETC" "$ROOT/run" "$SBM_RUN" \
  "$ROOT/var" "$ROOT/var/lib" "$SBM_VAR"
install -m 0755 "$REAL" "$SBM_CORE_DIR/sing-box/test/sing-box"
ln -s "$SBM_CORE_DIR/sing-box/test/sing-box" "$SBM_SING_BOX_BIN"

# shellcheck source=lib/common.sh
source "$PROJECT/lib/common.sh"
source "$PROJECT/lib/service.sh"
source "$PROJECT/lib/runtime-security.sh"

# Reproduce an upgraded installation carrying a stale OpenRC-style file
# capability, then verify the systemd preparation removes it.
setcap 'cap_net_bind_service=+ep' "$(readlink -f "$SBM_SING_BOX_BIN")"
getcap "$(readlink -f "$SBM_SING_BOX_BIN")" | grep -q cap_net_bind_service
prepare_singbox_binary_for_backend "$SBM_SING_BOX_BIN" systemd
[[ -z $(getcap "$(readlink -f "$SBM_SING_BOX_BIN")" 2>/dev/null) ]]

# This invokes the real system manager with the same critical hardening and
# capability settings used by sb-sing-box.service.
systemd_exec_preflight "$SBM_SING_BOX_BIN"

printf 'REAL SYSTEMD EXEC PASSED\n'
