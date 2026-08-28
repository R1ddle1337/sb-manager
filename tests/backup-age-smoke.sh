#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

export SBM_PREFIX="$ROOT/usr/local" SBM_LIB="$PROJECT" SBM_BIN_DIR="$ROOT/usr/local/bin"
export SBM_ETC="$ROOT/etc/sb-manager" SBM_VAR="$ROOT/var/lib/sb-manager" SBM_RUN="$ROOT/run/sb-manager"
export SBM_STATE="$SBM_ETC/state.json" SBM_GENERATED_DIR="$SBM_ETC/generated"
export SBM_CONFIG="$SBM_GENERATED_DIR/config.json" SBM_SECRETS="$SBM_ETC/secrets" SBM_CERTS="$SBM_ETC/certs"
export SBM_BACKUPS="$SBM_VAR/backups" SBM_EXPORTS="$SBM_VAR/exports" SBM_CACHE="$SBM_VAR/cache"
export SBM_CORE_DIR="$ROOT/cores" SBM_LOCK="$SBM_RUN/manager.lock" SBM_SUBSCRIPTIONS="$SBM_VAR/subscriptions"
export SBM_SING_BOX_BIN="${SBM_TEST_SING_BOX:?Set SBM_TEST_SING_BOX}" SBM_SKIP_INIT=1 NO_COLOR=1
export SBM_SERVICE_USER
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
source "$PROJECT/lib/tunnel.sh"
source "$PROJECT/lib/subscription.sh"
source "$PROJECT/lib/backup.sh"

command -v age >/dev/null
command -v age-keygen >/dev/null
state_init
node_add ss --id age-test --name 'Before backup' --port 28388 --address 192.0.2.1 >/dev/null
secret_path=$(state_user_secret_path age-test default)
secret_hash=$(sha256sum "$secret_path" | awk '{print $1}')
secret_value=$(jq -r '.password' "$secret_path")

age-keygen -o "$ROOT/identity.txt" >/dev/null 2>&1
recipient=$(sed -n 's/^# public key: //p' "$ROOT/identity.txt")
[[ "$recipient" == age1* ]]
archive="$ROOT/sb-manager-backup.tar.gz.age"
backup_create "$archive" "$recipient" >/dev/null
backup_is_age "$archive"
! grep -aFq "$secret_value" "$archive"

node_set age-test --name 'After backup' >/dev/null
changed_hash=$(sha256sum "$SBM_STATE" | awk '{print $1}')
age-keygen -o "$ROOT/wrong-identity.txt" >/dev/null 2>&1
if backup_restore "$archive" 1 "$ROOT/wrong-identity.txt" >/dev/null 2>&1; then
  echo 'encrypted restore unexpectedly accepted the wrong identity' >&2
  exit 1
fi
[[ $(sha256sum "$SBM_STATE" | awk '{print $1}') == "$changed_hash" ]]
[[ $(jq -r '.nodes[]|select(.id=="age-test")|.name' "$SBM_STATE") == 'After backup' ]]

backup_restore "$archive" 1 "$ROOT/identity.txt" >/dev/null
[[ $(jq -r '.nodes[]|select(.id=="age-test")|.name' "$SBM_STATE") == 'Before backup' ]]
[[ $(sha256sum "$secret_path" | awk '{print $1}') == "$secret_hash" ]]
"$SBM_SING_BOX_BIN" check -c "$SBM_CONFIG"
printf 'AGE BACKUP SMOKE PASSED\n'
