#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export SBM_PREFIX="$ROOT/usr/local" SBM_LIB="$PROJECT" SBM_BIN_DIR="$ROOT/usr/local/bin"
export SBM_ETC="$ROOT/etc/sb-manager" SBM_VAR="$ROOT/var/lib/sb-manager" SBM_RUN="$ROOT/run/sb-manager"
export SBM_STATE="$SBM_ETC/state.json" SBM_GENERATED_DIR="$SBM_ETC/generated"
export SBM_CONFIG="$SBM_GENERATED_DIR/config.json"
export SBM_SECRETS="$SBM_ETC/secrets" SBM_CERTS="$SBM_ETC/certs" SBM_BACKUPS="$SBM_VAR/backups" SBM_EXPORTS="$SBM_VAR/exports" SBM_CACHE="$SBM_VAR/cache" SBM_CORE_DIR="$ROOT/cores"
export SBM_LOCK="$SBM_RUN/manager.lock" SBM_SKIP_INIT=1 SBM_SKIP_SYSTEMD=1 SBM_SERVICE_USER=sbmanager NO_COLOR=1
export SBM_SING_BOX_BIN=/bin/true

mkdir -p "$ROOT/bin"
cat >"$ROOT/bin/firewall-fake" <<'EOF_FAKE'
#!/usr/bin/env bash
set -u
log=${FAKE_FIREWALL_LOG:?}
base=$(basename "$0")
if [[ "$base" == *-save ]]; then
  printf '%s\n' "# saved $base"
  exit 0
fi
case "${1:-}" in
  -S) printf '%s\n' '-P INPUT DROP' '-A INPUT -j DROP' '-A INPUT -p tcp -j DROP' ;;
  -D|-P|allow) printf '%s %s\n' "$base" "$*" >>"$log" ;;
  *) exit 0 ;;
esac
EOF_FAKE
chmod 0755 "$ROOT/bin/firewall-fake"
for name in iptables ip6tables iptables-save ip6tables-save ufw; do ln -s "$ROOT/bin/firewall-fake" "$ROOT/bin/$name"; done
export PATH="$ROOT/bin:$PATH" FAKE_FIREWALL_LOG="$ROOT/firewall.log"

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
source "$PROJECT/protocols/snell.sh"
source "$PROJECT/lib/render.sh"
source "$PROJECT/lib/node.sh"
source "$PROJECT/lib/firewall.sh"

state_init
node_add ss --id ss-firewall --port 28388 --address 192.0.2.1 >/dev/null
ports=$(firewall_list_protocol_ports)
grep -q 'ss-firewall.*TCP.*28388' <<<"$ports"
firewall_ufw_allow_protocol_ports 1
grep -q 'ufw allow 28388/tcp' "$FAKE_FIREWALL_LOG"

firewall_clear_iptables_input_deny 1
grep -q 'iptables -D INPUT -j DROP' "$FAKE_FIREWALL_LOG"
grep -q 'iptables -P INPUT ACCEPT' "$FAKE_FIREWALL_LOG"
grep -q 'ip6tables -P INPUT ACCEPT' "$FAKE_FIREWALL_LOG"
find "$SBM_VAR/firewall" -type f -name '*-iptables.rules' -size +0c | grep -q .
printf 'FIREWALL SMOKE PASSED\n'
