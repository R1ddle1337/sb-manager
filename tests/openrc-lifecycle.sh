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
export SBM_OPENRC_DIR="$ROOT/etc/init.d"
export SBM_PERIODIC_DIR="$ROOT/etc/periodic"
export SBM_LOG_DIR="$ROOT/var/log/sb-manager"
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
export SBM_INIT_SYSTEM=openrc SBM_SKIP_INIT=0 SBM_SKIP_SYSTEMD=0
export SBM_FAKE_RC_LOG="$ROOT/openrc.log" SBM_FAKE_RC_STATE="$ROOT/openrc-state"
export NO_COLOR=1

mkdir -p "$ROOT/bin" "$SBM_OPENRC_DIR" "$SBM_FAKE_RC_STATE"
cat >"$ROOT/bin/rc-service" <<'EOF_RC_SERVICE'
#!/usr/bin/env bash
set -u
name=${1:?}; action=${2:-status}
printf 'rc-service %s %s\n' "$name" "$action" >>"$SBM_FAKE_RC_LOG"
case "$action" in
  start|restart) : >"$SBM_FAKE_RC_STATE/active-$name" ;;
  stop) rm -f "$SBM_FAKE_RC_STATE/active-$name" ;;
  status) [[ -f "$SBM_FAKE_RC_STATE/active-$name" ]] ;;
esac
EOF_RC_SERVICE
cat >"$ROOT/bin/rc-update" <<'EOF_RC_UPDATE'
#!/usr/bin/env bash
set -u
action=${1:-show}; name=${2:-}; level=${3:-default}
printf 'rc-update %s %s %s\n' "$action" "$name" "$level" >>"$SBM_FAKE_RC_LOG"
case "$action" in
  add) : >"$SBM_FAKE_RC_STATE/enabled-$name" ;;
  del) rm -f "$SBM_FAKE_RC_STATE/enabled-$name" ;;
  show)
    for f in "$SBM_FAKE_RC_STATE"/enabled-*; do
      [[ -e "$f" ]] || continue
      printf '%s | default\n' "${f##*/enabled-}"
    done
    ;;
esac
EOF_RC_UPDATE
cat >"$ROOT/bin/openrc-run" <<'EOF_OPENRC_RUN'
#!/usr/bin/env sh
exit 0
EOF_OPENRC_RUN
chmod +x "$ROOT/bin/rc-service" "$ROOT/bin/rc-update" "$ROOT/bin/openrc-run"
export PATH="$ROOT/bin:$PATH"

source "$PROJECT/lib/common.sh"
source "$PROJECT/lib/service.sh"
source "$PROJECT/lib/state.sh"

[[ $(init_system) == openrc ]]
state_init
write_openrc_supervised_service \
  "$SBM_OPENRC_DIR/sb-sing-box" test test /bin/true '' "$(id -un)" \
  "$SBM_SINGBOX_LOG" "$SBM_SINGBOX_ERROR_LOG" 'after firewall'

singbox_service_reconcile
grep -q 'rc-update del sb-sing-box default' "$SBM_FAKE_RC_LOG"
grep -q 'rc-service sb-sing-box stop' "$SBM_FAKE_RC_LOG"

candidate=$(mktemp)
jq '.nodes=[{id:"test",enabled:true}]' "$SBM_STATE" >"$candidate"
mv "$candidate" "$SBM_STATE"
singbox_service_reconcile
grep -q 'rc-update add sb-sing-box default' "$SBM_FAKE_RC_LOG"
grep -q 'rc-service sb-sing-box start' "$SBM_FAKE_RC_LOG"
service_active "$SBM_SERVICE"
service_enabled "$SBM_SERVICE"

candidate=$(mktemp)
jq '(.nodes[0].enabled)=false' "$SBM_STATE" >"$candidate"
mv "$candidate" "$SBM_STATE"
singbox_service_reconcile
! service_active "$SBM_SERVICE"
! service_enabled "$SBM_SERVICE"

grep -q '^#!/sbin/openrc-run' "$SBM_OPENRC_DIR/sb-sing-box"
grep -q '^supervisor=supervise-daemon' "$SBM_OPENRC_DIR/sb-sing-box"
grep -q '^command_user=' "$SBM_OPENRC_DIR/sb-sing-box"
printf 'OPENRC LIFECYCLE PASSED\n'
