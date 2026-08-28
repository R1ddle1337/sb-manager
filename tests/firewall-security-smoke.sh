#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

export SBM_PREFIX="$ROOT/usr/local" SBM_LIB="$PROJECT" SBM_BIN_DIR="$ROOT/usr/local/bin"
export SBM_ETC="$ROOT/etc/sb-manager" SBM_VAR="$ROOT/var/lib/sb-manager" SBM_RUN="$ROOT/run/sb-manager"
export SBM_STATE="$SBM_ETC/state.json" SBM_GENERATED_DIR="$SBM_ETC/generated"
export SBM_CONFIG="$SBM_GENERATED_DIR/config.json"
export SBM_SECRETS="$SBM_ETC/secrets" SBM_CERTS="$SBM_ETC/certs" SBM_BACKUPS="$SBM_VAR/backups"
export SBM_EXPORTS="$SBM_VAR/exports" SBM_CACHE="$SBM_VAR/cache" SBM_CORE_DIR="$ROOT/cores"
export SBM_LOCK="$SBM_RUN/manager.lock" SBM_SING_BOX_BIN=/bin/true SBM_SKIP_INIT=1 SBM_TEST_MODE=1
export SBM_SERVICE_USER=$(id -un) SBM_FAIL2BAN_CONFIG="$ROOT/etc/fail2ban/jail.d/sb-manager-sshd.local"
export SBM_FIREWALL_PACKAGE_INSTALLER="$ROOT/package-install"

mkdir -p "$ROOT/bin"
cat >"$ROOT/package-install" <<'EOF_INSTALLER'
#!/usr/bin/env bash
set -u
package=${1:?}
printf '%s\n' "$package" >>"$FAKE_PACKAGE_LOG"
case "$package" in
  fail2ban)
    cat >"$FAKE_BIN_DIR/fail2ban-client" <<'EOF_F2B'
#!/usr/bin/env bash
case "${1:-}" in -t) exit 0;; status) printf 'Status\n';; *) exit 0;; esac
EOF_F2B
    chmod 0755 "$FAKE_BIN_DIR/fail2ban-client"
    ;;
  ufw)
    cat >"$FAKE_BIN_DIR/ufw" <<'EOF_UFW'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$FAKE_UFW_LOG"
if [[ ${1:-} == status ]]; then
  [[ -f "$FAKE_UFW_ACTIVE" ]] && printf 'Status: active\n' || printf 'Status: inactive\n'
elif [[ ${1:-} == --force && ${2:-} == enable ]]; then
  : >"$FAKE_UFW_ACTIVE"
fi
EOF_UFW
    chmod 0755 "$FAKE_BIN_DIR/ufw"
    ;;
esac
EOF_INSTALLER
chmod 0755 "$ROOT/package-install"
export FAKE_BIN_DIR="$ROOT/bin" FAKE_PACKAGE_LOG="$ROOT/packages.log" FAKE_UFW_LOG="$ROOT/ufw.log" FAKE_UFW_ACTIVE="$ROOT/ufw.active"
export PATH="$FAKE_BIN_DIR:$PATH"

# Mask any host-installed UFW so this smoke test never changes the runner's
# firewall rules. The package callback is exercised separately below.
cat >"$FAKE_BIN_DIR/ufw" <<'EOF_UFW_EXISTING'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$FAKE_UFW_LOG"
if [[ ${1:-} == status ]]; then
  [[ -f "$FAKE_UFW_ACTIVE" ]] && printf 'Status: active\n' || printf 'Status: inactive\n'
elif [[ ${1:-} == --force && ${2:-} == enable ]]; then
  : >"$FAKE_UFW_ACTIVE"
fi
EOF_UFW_EXISTING
chmod 0755 "$FAKE_BIN_DIR/ufw"

source "$PROJECT/lib/common.sh"
source "$PROJECT/lib/service.sh"
source "$PROJECT/lib/state.sh"
source "$PROJECT/lib/nginx_stream.sh"
source "$PROJECT/protocols/vmess_ws_cf.sh"
source "$PROJECT/protocols/shadowsocks.sh"
source "$PROJECT/protocols/anytls.sh"
source "$PROJECT/protocols/hysteria2.sh"
source "$PROJECT/protocols/trojan.sh"
source "$PROJECT/protocols/tuic.sh"
source "$PROJECT/protocols/vless.sh"
source "$PROJECT/protocols/naive.sh"
source "$PROJECT/protocols/shadowtls.sh"
source "$PROJECT/protocols/snell.sh"
source "$PROJECT/lib/render.sh"
source "$PROJECT/lib/core.sh"
source "$PROJECT/lib/node.sh"
source "$PROJECT/lib/firewall.sh"

state_init
node_add ss --id security-test --port 28388 --address 192.0.2.1 >/dev/null

firewall_setup_fail2ban 1 >/dev/null
grep -Fxq fail2ban "$FAKE_PACKAGE_LOG"
grep -Fq '[sshd]' "$SBM_FAIL2BAN_CONFIG"
grep -Fq 'findtime = 180' "$SBM_FAIL2BAN_CONFIG"
grep -Fq 'maxretry = 5' "$SBM_FAIL2BAN_CONFIG"
grep -Fq 'bantime = -1' "$SBM_FAIL2BAN_CONFIG"
grep -Fq 'port = 22' "$SBM_FAIL2BAN_CONFIG"
[[ "$(stat -c '%a' "$SBM_FAIL2BAN_CONFIG")" == 644 ]]

firewall_setup_ufw 1 >/dev/null
grep -Fq 'allow 22/tcp' "$FAKE_UFW_LOG"
grep -Fq 'allow 80/tcp' "$FAKE_UFW_LOG"
grep -Fq 'allow 443/tcp' "$FAKE_UFW_LOG"
grep -Fq 'allow 28388/tcp' "$FAKE_UFW_LOG"
grep -Fq -- '--force enable' "$FAKE_UFW_LOG"

# Re-running is idempotent and does not invoke enable again once active.
before=$(wc -l <"$FAKE_UFW_LOG")
firewall_setup_ufw 1 >/dev/null
after=$(wc -l <"$FAKE_UFW_LOG")
(( after > before ))
[[ $(grep -Fc -- '--force enable' "$FAKE_UFW_LOG") == 1 ]]

firewall_package_install ufw
grep -Fxq ufw "$FAKE_PACKAGE_LOG"

status=$(firewall_status)
grep -Fq 'UFW' <<<"$status"
grep -Fq 'Fail2ban' <<<"$status"

printf 'FIREWALL SECURITY SMOKE PASSED\n'
