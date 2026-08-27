#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

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
export SBM_SKIP_INIT=0 SBM_SKIP_SYSTEMD=0 SBM_INIT_SYSTEM=systemd
export SBM_FAKE_SYSTEMCTL_LOG="$ROOT/systemctl.log"
export SBM_FAKE_SYSTEMCTL_ACTIVE="$ROOT/systemctl.active"
export NO_COLOR=1

mkdir -p "$ROOT/bin" "$SBM_SYSTEMD_DIR"
cat >"$ROOT/bin/systemctl" <<'EOF_SYSTEMCTL'
#!/usr/bin/env bash
set -u
cmd=${1:-}; shift || true
printf '%s %s\n' "$cmd" "$*" >>"$SBM_FAKE_SYSTEMCTL_LOG"
case "$cmd" in
  daemon-reload|enable|disable|reset-failed|cat|status) exit 0;;
  restart|start) : >"$SBM_FAKE_SYSTEMCTL_ACTIVE"; exit 0;;
  stop) rm -f "$SBM_FAKE_SYSTEMCTL_ACTIVE"; exit 0;;
  is-enabled) exit 0;;
  is-active)
    quiet=0
    for arg in "$@"; do [[ "$arg" == --quiet ]] && quiet=1; done
    if [[ -f "$SBM_FAKE_SYSTEMCTL_ACTIVE" ]]; then (( quiet )) || printf 'active\n'; exit 0; fi
    (( quiet )) || printf 'inactive\n'
    exit 3
    ;;
  *) exit 0;;
esac
EOF_SYSTEMCTL
chmod +x "$ROOT/bin/systemctl"
export PATH="$ROOT/bin:$PATH"

# shellcheck source=lib/common.sh
source "$PROJECT/lib/common.sh"
source "$PROJECT/lib/service.sh"
source "$PROJECT/lib/state.sh"

# Progress logs must stay on stderr so command substitutions return only paths.
captured=$( { log_info 'download progress'; printf '/tmp/core-path\n'; } 2>/dev/null)
[[ "$captured" == /tmp/core-path ]]

state_init
: >"$SBM_SYSTEMD_DIR/$SBM_SERVICE"

# Fresh install with no enabled nodes is a valid standby state. It must be
# disabled across reboots and must not restart the core.
singbox_service_reconcile
grep -q "disable $SBM_SERVICE" "$SBM_FAKE_SYSTEMCTL_LOG"
grep -q "stop $SBM_SERVICE" "$SBM_FAKE_SYSTEMCTL_LOG"
! grep -q "restart $SBM_SERVICE" "$SBM_FAKE_SYSTEMCTL_LOG"
[[ ! -e "$SBM_FAKE_SYSTEMCTL_ACTIVE" ]]

# Adding the first enabled node starts the core.
tmp=$(mktemp)
jq '.nodes=[{id:"test",enabled:true}]' "$SBM_STATE" >"$tmp"
mv "$tmp" "$SBM_STATE"
singbox_service_reconcile
grep -q "enable $SBM_SERVICE" "$SBM_FAKE_SYSTEMCTL_LOG"
grep -q "restart $SBM_SERVICE" "$SBM_FAKE_SYSTEMCTL_LOG"
[[ -e "$SBM_FAKE_SYSTEMCTL_ACTIVE" ]]

# Disabling the last node returns the service to standby.
tmp=$(mktemp)
jq '(.nodes[0].enabled)=false' "$SBM_STATE" >"$tmp"
mv "$tmp" "$SBM_STATE"
singbox_service_reconcile
[[ ! -e "$SBM_FAKE_SYSTEMCTL_ACTIVE" ]]

printf 'SERVICE LIFECYCLE PASSED\n'
