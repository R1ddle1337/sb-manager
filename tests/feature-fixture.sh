#!/usr/bin/env bash
# Shared, isolated fixture for optional operations tests. Source this file.
set -Eeuo pipefail
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export SBM_PREFIX="$ROOT/usr/local" SBM_LIB="$PROJECT" SBM_BIN_DIR="$ROOT/bin"
export SBM_ETC="$ROOT/etc/sb-manager" SBM_VAR="$ROOT/var" SBM_RUN="$ROOT/run"
export SBM_SYSTEMD_DIR="$ROOT/systemd" SBM_OPENRC_DIR="$ROOT/init.d" SBM_PERIODIC_DIR="$ROOT/periodic"
export SBM_LOG_DIR="$ROOT/log" SBM_STATE="$SBM_ETC/state.json" SBM_GENERATED_DIR="$SBM_ETC/generated"
export SBM_CONFIG="$SBM_GENERATED_DIR/config.json" SBM_SECRETS="$SBM_ETC/secrets" SBM_CERTS="$SBM_ETC/certs"
export SBM_BACKUPS="$SBM_VAR/backups" SBM_CACHE="$SBM_VAR/cache" SBM_EXPORTS="$SBM_VAR/exports"
export SBM_LOCK="$SBM_RUN/manager.lock" SBM_SUBSCRIPTIONS="$SBM_VAR/subscriptions" SBM_TRAFFIC_USAGE="$SBM_VAR/traffic-usage.json"
export SBM_TEST_MODE=1 SBM_SKIP_INIT=1 SBM_SKIP_SYSTEMD=1 SBM_SERVICE_USER=root NO_COLOR=1
export SBM_SING_BOX_BIN="${SBM_TEST_SING_BOX:-/bin/true}" SBM_CLOUDFLARED_BIN="$ROOT/bin/cloudflared"
export SBM_BBR_SYSCTL_CONFIG="$ROOT/bbr.conf" SBM_HY2_UDP_BUFFER_SYSCTL_CONFIG="$ROOT/hy2.conf" SBM_TCP_SYSCTL_CONFIG="$ROOT/tcp.conf"
mkdir -p "$ROOT/bin"
source "$PROJECT/lib/common.sh"
for script in "$PROJECT"/protocols/*.sh "$PROJECT"/lib/*.sh; do
  [[ "$script" == "$PROJECT/lib/common.sh" ]] || source "$script"
done
state_init
expect_failure() { if ("$@"); then printf 'Unexpected success: %s\n' "$*" >&2; exit 1; fi; }
