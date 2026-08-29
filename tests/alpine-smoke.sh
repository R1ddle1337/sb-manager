#!/usr/bin/env bash
set -Eeuo pipefail
[[ -f /etc/alpine-release ]] || { echo 'This test must run on Alpine.' >&2; exit 1; }
if command -v apk >/dev/null 2>&1; then
  # The test intentionally runs setup in test mode, so provide the musl
  # compatibility/runtime tools that a clean Alpine image does not contain.
  apk add --no-cache curl ca-certificates jq openssl tar gzip coreutils util-linux procps findutils \
    python3 iproute2 nftables shadow openrc dcron libcap musl-utils gcompat >/dev/null
fi
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
VERSION=$(tr -d '[:space:]' <"$PROJECT/TESTED_CORE_VERSION")

# First verify the exact official assets used by the installer execute on musl.
export SBM_PREFIX="$ROOT/download/usr/local"
export SBM_LIB="$PROJECT"
export SBM_BIN_DIR="$ROOT/download/usr/local/bin"
export SBM_ETC="$ROOT/download/etc/sb-manager"
export SBM_VAR="$ROOT/download/var/lib/sb-manager"
export SBM_RUN="$ROOT/download/run/sb-manager"
export SBM_STATE="$SBM_ETC/state.json"
export SBM_GENERATED_DIR="$SBM_ETC/generated"
export SBM_CONFIG="$SBM_GENERATED_DIR/config.json"
export SBM_SECRETS="$SBM_ETC/secrets"
export SBM_CERTS="$SBM_ETC/certs"
export SBM_BACKUPS="$SBM_VAR/backups"
export SBM_EXPORTS="$SBM_VAR/exports"
export SBM_CACHE="$SBM_VAR/cache"
export SBM_CORE_DIR="$ROOT/download/cores"
export SBM_LOCK="$SBM_RUN/manager.lock"
export SBM_INIT_SYSTEM=openrc SBM_SKIP_INIT=0 SBM_SKIP_SYSTEMD=0 NO_COLOR=1
source "$PROJECT/lib/common.sh"
source "$PROJECT/lib/service.sh"
source "$PROJECT/lib/core.sh"
mkdir -p "$SBM_CACHE" "$SBM_CORE_DIR"
REAL_SING_BOX=$(core_download_version "$VERSION")
REAL_CLOUDFLARED=$(cloudflared_download_latest)
"$REAL_SING_BOX" version | grep -q "$VERSION"
"$REAL_CLOUDFLARED" version | grep -qi cloudflared
getcap "$REAL_SING_BOX" | grep -q cap_net_bind_service

# Exercise installation output and lifecycle with an isolated OpenRC backend.
export SBM_TEST_MODE=1 SBM_TEST_SING_BOX="$REAL_SING_BOX"
export SBM_PREFIX="$ROOT/install/usr/local"
export SBM_LIB="$ROOT/install/usr/local/lib/sb-manager"
export SBM_BIN_DIR="$ROOT/install/usr/local/bin"
export SBM_ETC="$ROOT/install/etc/sb-manager"
export SBM_VAR="$ROOT/install/var/lib/sb-manager"
export SBM_RUN="$ROOT/install/run/sb-manager"
export SBM_SYSTEMD_DIR="$ROOT/install/etc/systemd/system"
export SBM_OPENRC_DIR="$ROOT/install/etc/init.d"
export SBM_PERIODIC_DIR="$ROOT/install/etc/periodic"
export SBM_LOG_DIR="$ROOT/install/var/log/sb-manager"
export SBM_STATE="$SBM_ETC/state.json"
export SBM_GENERATED_DIR="$SBM_ETC/generated"
export SBM_CONFIG="$SBM_GENERATED_DIR/config.json"
export SBM_SECRETS="$SBM_ETC/secrets"
export SBM_CERTS="$SBM_ETC/certs"
export SBM_BACKUPS="$SBM_VAR/backups"
export SBM_EXPORTS="$SBM_VAR/exports"
export SBM_CACHE="$SBM_VAR/cache"
export SBM_CORE_DIR="$SBM_LIB/cores"
export SBM_LOCK="$SBM_RUN/manager.lock"
export SBM_SING_BOX_BIN="$SBM_BIN_DIR/sing-box"
export SBM_CLOUDFLARED_BIN="$SBM_BIN_DIR/cloudflared"
export SBM_SERVICE_USER=root
export SBM_FAKE_RC_LOG="$ROOT/rc.log"
export SBM_FAKE_RC_STATE="$ROOT/rc-state"
mkdir -p "$ROOT/bin" "$SBM_FAKE_RC_STATE"
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
    for f in "$SBM_FAKE_RC_STATE"/enabled-*; do [[ -e "$f" ]] || continue; printf '%s | default\n' "${f##*/enabled-}"; done
    ;;
esac
EOF_RC_UPDATE
cat >"$ROOT/bin/openrc-run" <<'EOF_OPENRC_RUN'
#!/usr/bin/env sh
exit 0
EOF_OPENRC_RUN
chmod +x "$ROOT/bin/rc-service" "$ROOT/bin/rc-update" "$ROOT/bin/openrc-run"
export PATH="$ROOT/bin:$PATH"

bash "$PROJECT/setup.sh" --no-menu --no-start
[[ -x "$SBM_OPENRC_DIR/sb-sing-box" ]]
[[ -x "$SBM_PERIODIC_DIR/daily/sb-core-update" ]]
[[ -x "$SBM_PERIODIC_DIR/daily/sb-acme-renew" ]]
[[ -x "$SBM_OPENRC_DIR/sb-traffic" ]]
[[ -x "$SBM_PERIODIC_DIR/15min/sb-traffic-sync" ]]
grep -Fq 'traffic reconcile' "$SBM_OPENRC_DIR/sb-traffic"
grep -q 'supervisor=supervise-daemon' "$SBM_OPENRC_DIR/sb-sing-box"
grep -q 'command_user="root:root"' "$SBM_OPENRC_DIR/sb-sing-box"
getcap "$(readlink -f "$SBM_SING_BOX_BIN")" | grep -q cap_net_bind_service

"$SBM_BIN_DIR/sb" node add vmess --id alpine-vm --port 29121 --domain cdn.example.com --address cdn.example.com
grep -q 'rc-update add sb-sing-box default' "$SBM_FAKE_RC_LOG"
grep -q 'rc-service sb-sing-box start' "$SBM_FAKE_RC_LOG"
"$SBM_BIN_DIR/sb" tunnel fixed alpine-vm cdn.example.com test-token cdn.example.com
grep -q -- '--token-file' "$SBM_OPENRC_DIR/sb-cloudflared"
! grep -q 'test-token' "$SBM_OPENRC_DIR/sb-cloudflared"
"$SBM_BIN_DIR/sb" tunnel stop
"$SBM_BIN_DIR/sb" node disable alpine-vm
! service_active "$SBM_SERVICE"

printf '{broken-json\n' >"$SBM_STATE"
"$SBM_BIN_DIR/sb" uninstall --purge --yes
[[ ! -e "$SBM_BIN_DIR/sb" && ! -e "$SBM_LIB" && ! -e "$SBM_ETC" && ! -e "$SBM_VAR" ]]
printf 'ALPINE SMOKE PASSED (%s)\n' "$(cat /etc/alpine-release)"
