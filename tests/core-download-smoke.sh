#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export SBM_PREFIX="$ROOT/usr/local" SBM_LIB="$PROJECT" SBM_BIN_DIR="$ROOT/usr/local/bin"
export SBM_ETC="$ROOT/etc/sb-manager" SBM_VAR="$ROOT/var/lib/sb-manager" SBM_RUN="$ROOT/run/sb-manager"
export SBM_STATE="$SBM_ETC/state.json" SBM_GENERATED_DIR="$SBM_ETC/generated"
export SBM_CONFIG="$SBM_GENERATED_DIR/config.json"
export SBM_SECRETS="$SBM_ETC/secrets" SBM_CERTS="$SBM_ETC/certs" SBM_BACKUPS="$SBM_VAR/backups" SBM_EXPORTS="$SBM_VAR/exports" SBM_CACHE="$SBM_VAR/cache"
export SBM_CORE_DIR="$ROOT/cores" SBM_LOCK="$SBM_RUN/manager.lock" SBM_SKIP_INIT=1 SBM_SKIP_SYSTEMD=1 NO_COLOR=1
source "$PROJECT/lib/common.sh"
source "$PROJECT/lib/service.sh"
source "$PROJECT/lib/core.sh"
mkdir -p "$SBM_CACHE" "$SBM_CORE_DIR"
version=$(tr -d '[:space:]' <"$PROJECT/TESTED_CORE_VERSION")
sb=$(core_download_version "$version")
[[ "$sb" != *$'\n'* ]]
[[ -x "$sb" ]]
"$sb" version | grep -q "$version"
cf=$(cloudflared_download_latest)
[[ "$cf" != *$'\n'* ]]
[[ -x "$cf" ]]
"$cf" version | grep -qi cloudflared
printf 'CORE DOWNLOAD SMOKE PASSED\n'
