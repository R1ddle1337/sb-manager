#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

export SBM_PREFIX="$ROOT/usr/local" SBM_LIB="$PROJECT" SBM_BIN_DIR="$ROOT/usr/local/bin"
export SBM_ETC="$ROOT/etc/sb-manager" SBM_VAR="$ROOT/var/lib/sb-manager" SBM_RUN="$ROOT/run/sb-manager"
export SBM_SYSTEMD_DIR="$ROOT/etc/systemd/system" SBM_OPENRC_DIR="$ROOT/etc/init.d"
export SBM_PERIODIC_DIR="$ROOT/etc/periodic" SBM_LOG_DIR="$ROOT/var/log/sb-manager"
export SBM_STATE="$SBM_ETC/state.json" SBM_GENERATED_DIR="$SBM_ETC/generated"
export SBM_CONFIG="$SBM_GENERATED_DIR/config.json"
export SBM_SECRETS="$SBM_ETC/secrets" SBM_CERTS="$SBM_ETC/certs" SBM_BACKUPS="$SBM_VAR/backups"
export SBM_EXPORTS="$SBM_VAR/exports" SBM_CACHE="$SBM_VAR/cache" SBM_CORE_DIR="$ROOT/cores"
export SBM_LOCK="$SBM_RUN/manager.lock" SBM_SING_BOX_BIN="${SBM_TEST_SING_BOX:?Set SBM_TEST_SING_BOX}"
export SBM_CLOUDFLARED_BIN="$ROOT/bin/cloudflared" SBM_SKIP_INIT=1 SBM_SKIP_SYSTEMD=1 NO_COLOR=1

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
source "$PROJECT/lib/cert.sh"
source "$PROJECT/lib/tunnel.sh"
source "$PROJECT/lib/backup.sh"

state_init
render_current_config

# Both concurrent read-modify-write operations must survive serialization.
settings_set_default_address 192.0.2.10 >/dev/null & p1=$!
core_set_policy patch >/dev/null & p2=$!
wait "$p1"; wait "$p2"
[[ $(jq -r '.settings.default_server_address' "$SBM_STATE") == 192.0.2.10 ]]
[[ $(jq -r '.settings.core_update_policy' "$SBM_STATE") == patch ]]

# Auto-detected public addresses update auto nodes but preserve manual overrides.
export SBM_PUBLIC_IPV4=198.51.100.10 SBM_DISABLE_IPV6_DETECTION=1
settings_set_default_address auto >/dev/null
node_add ss --id auto-address --port 28388 >/dev/null
[[ $(jq -r '.nodes[]|select(.id=="auto-address")|.server_address' "$SBM_STATE") == 198.51.100.10 ]]
[[ $(jq -r '.nodes[]|select(.id=="auto-address")|.server_address_source' "$SBM_STATE") == auto ]]
export SBM_PUBLIC_IPV4=198.51.100.11
settings_detect_public_ip >/dev/null
[[ $(jq -r '.nodes[]|select(.id=="auto-address")|.server_address' "$SBM_STATE") == 198.51.100.11 ]]
node_set auto-address --address 203.0.113.7 >/dev/null
export SBM_PUBLIC_IPV4=198.51.100.12
settings_detect_public_ip >/dev/null
[[ $(jq -r '.nodes[]|select(.id=="auto-address")|.server_address' "$SBM_STATE") == 203.0.113.7 ]]
node_delete auto-address >/dev/null

# A failed operation must restore state, config, secrets, and certificates.
printf '%s\n' '{"sentinel":"before"}' >"$SBM_SECRETS/nodes/sentinel.json"
printf '%s\n' 'certificate-before' >"$SBM_CERTS/sentinel.pem"
state_hash=$(sha256sum "$SBM_STATE" | awk '{print $1}')
config_hash=$(sha256sum "$SBM_CONFIG" | awk '{print $1}')
failing_mutation() {
  printf '%s\n' '{"sentinel":"after"}' >"$SBM_SECRETS/nodes/sentinel.json"
  printf '%s\n' 'certificate-after' >"$SBM_CERTS/sentinel.pem"
  jq '.settings.log_level="debug"' "$SBM_STATE" >"$SBM_STATE.changed"
  mv "$SBM_STATE.changed" "$SBM_STATE"
  return 42
}
if with_state_transaction injected-failure failing_mutation; then
  echo 'failed transaction unexpectedly succeeded' >&2; exit 1
fi
[[ $(jq -r '.sentinel' "$SBM_SECRETS/nodes/sentinel.json") == before ]]
[[ $(cat "$SBM_CERTS/sentinel.pem") == certificate-before ]]
[[ $(sha256sum "$SBM_STATE" | awk '{print $1}') == "$state_hash" ]]
[[ $(sha256sum "$SBM_CONFIG" | awk '{print $1}') == "$config_hash" ]]

# Strict state validation must reject invalid enum values.
bad=$(state_candidate)
jq '.settings.log_level="verbose"' "$SBM_STATE" >"$bad"
if (state_validate "$bad" >/dev/null 2>&1); then
  echo 'invalid state unexpectedly passed validation' >&2; exit 1
fi

# Restore validation must reject links even when paths remain inside etc/.
malicious="$ROOT/malicious"
mkdir -p "$malicious/etc/secrets/nodes" "$malicious/meta"
cp "$SBM_STATE" "$malicious/etc/state.json"
ln -s /etc/passwd "$malicious/etc/secrets/nodes/linked.json"
tar -C "$malicious" -czf "$ROOT/malicious.tar.gz" .
if backup_validate_archive "$ROOT/malicious.tar.gz"; then
  echo 'archive containing a symlink unexpectedly passed validation' >&2; exit 1
fi

printf 'STATE SAFETY SMOKE PASSED\n'
