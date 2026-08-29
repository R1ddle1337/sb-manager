#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || { echo 'install smoke test requires root or sudo' >&2; exit 1; }
  exec sudo env SBM_TEST_SING_BOX="${SBM_TEST_SING_BOX:?Set SBM_TEST_SING_BOX}" NO_COLOR=1 bash "$0" "$@"
fi
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
REAL=${SBM_TEST_SING_BOX:?Set SBM_TEST_SING_BOX}
export SBM_TEST_MODE=1 SBM_SKIP_INIT=1 SBM_SKIP_SYSTEMD=1 SBM_TEST_SING_BOX="$REAL" NO_COLOR=1
export SBM_PREFIX="$ROOT/usr/local"
export SBM_LIB="$ROOT/usr/local/lib/sb-manager"
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
export SBM_CORE_DIR="$SBM_LIB/cores"
export SBM_LOCK="$SBM_RUN/manager.lock"
export SBM_SING_BOX_BIN="$SBM_BIN_DIR/sing-box"
export SBM_CLOUDFLARED_BIN="$SBM_BIN_DIR/cloudflared"
# Use an existing unprivileged account with a matching group so the isolated
# install can verify real directory traversal and read permissions.
export SBM_SERVICE_USER=daemon

bash "$PROJECT/setup.sh" --no-menu --no-start
[[ -x "$SBM_BIN_DIR/sb" && -x "$SBM_SING_BOX_BIN" && -x "$SBM_CLOUDFLARED_BIN" ]]
[[ "$(readlink "$SBM_SING_BOX_BIN")" != *$'\n'* ]]
[[ "$(readlink "$SBM_CLOUDFLARED_BIN")" != *$'\n'* ]]
env -u SBM_LIB "$SBM_BIN_DIR/sb" version | grep -q "$(tr -d '[:space:]' <"$PROJECT/VERSION")"
[[ -z $(find "$SBM_LIB" -maxdepth 0 ! -perm -0001 -print -quit) ]]
[[ -z $(find "$SBM_CORE_DIR" -type d ! -perm -0001 -print -quit) ]]
chmod 0755 "$ROOT" "$ROOT/usr" "$ROOT/usr/local" "$ROOT/etc" "$ROOT/var" "$ROOT/var/lib"
runuser -u "$SBM_SERVICE_USER" -- "$SBM_SING_BOX_BIN" version >/dev/null
if [[ -f "$(dirname "$REAL")/libcronet.so" ]]; then
  [[ -x "$(dirname "$(readlink -f "$SBM_SING_BOX_BIN")")/libcronet.so" ]]
fi
runuser -u "$SBM_SERVICE_USER" -- "$SBM_CLOUDFLARED_BIN" version >/dev/null
runuser -u "$SBM_SERVICE_USER" -- test -r "$SBM_CONFIG"
runuser -u "$SBM_SERVICE_USER" -- test -x "$SBM_VAR"
runuser -u "$SBM_SERVICE_USER" -- test -w "$SBM_VAR/cloudflared-home"
[[ -f "$SBM_SYSTEMD_DIR/sb-sing-box.service" && -f "$SBM_SYSTEMD_DIR/sb-core-update.timer" ]]
[[ -f "$SBM_SYSTEMD_DIR/sb-traffic.service" && -f "$SBM_SYSTEMD_DIR/sb-traffic-sync.timer" ]]
[[ -f "$SBM_SYSTEMD_DIR/sb-health-check.service" && -f "$SBM_SYSTEMD_DIR/sb-health-check.timer" ]]
grep -Fq 'traffic reconcile' "$SBM_SYSTEMD_DIR/sb-traffic.service"
grep -Fq 'traffic tick' "$SBM_SYSTEMD_DIR/sb-traffic-sync.service"
grep -Fq 'health tick' "$SBM_SYSTEMD_DIR/sb-health-check.service"
if command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze verify \
    "$SBM_SYSTEMD_DIR/sb-sing-box.service" \
    "$SBM_SYSTEMD_DIR/sb-traffic.service" \
    "$SBM_SYSTEMD_DIR/sb-traffic-sync.service" \
    "$SBM_SYSTEMD_DIR/sb-traffic-sync.timer" >/dev/null
  systemd-analyze verify \
    "$SBM_SYSTEMD_DIR/sb-health-check.service" \
    "$SBM_SYSTEMD_DIR/sb-health-check.timer" >/dev/null
fi
"$SBM_BIN_DIR/sb" node add vmess --id persist-test --port 29111 --domain cdn.example.com --address cdn.example.com
[[ $(jq '.nodes|length' "$SBM_STATE") == 1 ]]

# Reinstall/upgrade must preserve state and installed cores.
bash "$PROJECT/setup.sh" --no-menu --no-start
[[ $(jq '.nodes|length' "$SBM_STATE") == 1 ]]
"$SBM_SING_BOX_BIN" check -c "$SBM_CONFIG"

# A failed program upgrade must restore the previous program and service files.
printf 'preserve-on-failure\n' >"$SBM_LIB/rollback-marker"
if SBM_TEST_FAIL_STEP=6 bash "$PROJECT/setup.sh" --no-menu --no-start >/dev/null 2>&1; then
  echo 'injected setup failure unexpectedly succeeded' >&2; exit 1
fi
[[ $(cat "$SBM_LIB/rollback-marker") == preserve-on-failure ]]
[[ $(jq '.nodes|length' "$SBM_STATE") == 1 ]]

# Exercise core switch and rollback without systemd.
mkdir -p "$SBM_CORE_DIR/sing-box/9.9.9"
cat >"$SBM_CORE_DIR/sing-box/9.9.9/sing-box" <<EOF_WRAPPER
#!/usr/bin/env bash
if [[ \${1:-} == version ]]; then echo 'sing-box version 9.9.9'; exit 0; fi
exec "$REAL" "\$@"
EOF_WRAPPER
chmod +x "$SBM_CORE_DIR/sing-box/9.9.9/sing-box"
# Source installed libraries so we can select local version without network.
source "$SBM_LIB/lib/common.sh"
source "$SBM_LIB/lib/service.sh"
source "$SBM_LIB/lib/state.sh"
source "$SBM_LIB/lib/nginx_stream.sh"
source "$SBM_LIB/protocols/vmess_ws_cf.sh"
source "$SBM_LIB/protocols/shadowsocks.sh"
source "$SBM_LIB/protocols/anytls.sh"
source "$SBM_LIB/protocols/hysteria2.sh"
source "$SBM_LIB/lib/render.sh"
source "$SBM_LIB/lib/core.sh"
old=$(core_current_version)
core_switch_to 9.9.9
[[ $(core_current_version) == 9.9.9 ]]
sleep 1
core_rollback
[[ $(core_current_version) == "$old" ]]

# Non-interactive full uninstall must remain available even if the state file
# is damaged, and must remove program and data from the isolated root.
printf '{broken-json\n' >"$SBM_STATE"
"$SBM_BIN_DIR/sb" uninstall --purge --yes
[[ ! -e "$SBM_BIN_DIR/sb" && ! -e "$SBM_LIB" && ! -e "$SBM_ETC" && ! -e "$SBM_VAR" ]]

printf 'INSTALL SMOKE PASSED\n'
