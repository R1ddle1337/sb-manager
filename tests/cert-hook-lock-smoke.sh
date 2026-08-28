#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export SBM_PREFIX="$ROOT/usr/local" SBM_LIB="$PROJECT" SBM_BIN_DIR="$ROOT/usr/local/bin"
export SBM_ETC="$ROOT/etc/sb-manager" SBM_VAR="$ROOT/var/lib/sb-manager" SBM_RUN="$ROOT/run/sb-manager"
export SBM_GENERATED_DIR="$SBM_ETC/generated" SBM_STATE="$SBM_ETC/state.json" SBM_CONFIG="$SBM_ETC/generated/config.json"
export SBM_SECRETS="$SBM_ETC/secrets" SBM_CERTS="$SBM_ETC/certs" SBM_BACKUPS="$SBM_VAR/backups" SBM_EXPORTS="$SBM_VAR/exports" SBM_CACHE="$SBM_VAR/cache"
export SBM_CORE_DIR="$ROOT/cores" SBM_LOCK="$SBM_RUN/manager.lock" SBM_SKIP_INIT=1 SBM_SKIP_SYSTEMD=1 SBM_TEST_MODE=1 NO_COLOR=1
export SBM_SING_BOX_BIN="${SBM_TEST_SING_BOX:?Set SBM_TEST_SING_BOX}"

source "$PROJECT/lib/common.sh"
source "$PROJECT/lib/service.sh"
source "$PROJECT/lib/state.sh"
source "$PROJECT/lib/cert.sh"
state_init
mkdir -p "$SBM_CERTS/hook.example.com"
openssl req -x509 -newkey rsa:2048 -nodes -days 3 -subj '/CN=hook.example.com' \
  -addext 'subjectAltName=DNS:hook.example.com' \
  -keyout "$SBM_CERTS/hook.example.com/key.pem" \
  -out "$SBM_CERTS/hook.example.com/fullchain.pem" >/dev/null 2>&1
mkdir -p "$SBM_BIN_DIR"
ln -sfn "$PROJECT/sb" "$SBM_BIN_DIR/sb"

exec 9>"$SBM_LOCK"
flock -x 9
timeout 3 env SBM_SKIP_STATE_INIT=1 SBM_LIB="$PROJECT" SBM_ETC="$SBM_ETC" SBM_VAR="$SBM_VAR" SBM_RUN="$SBM_RUN" \
  SBM_CERTS="$SBM_CERTS" SBM_SECRETS="$SBM_SECRETS" SBM_SING_BOX_BIN="$SBM_SING_BOX_BIN" \
  SBM_SKIP_INIT=1 SBM_TEST_MODE=1 bash "$PROJECT/sb" cert hook hook.example.com >/dev/null
flock -u 9
exec 9>&-
printf 'CERT HOOK LOCK SMOKE PASSED\n'
