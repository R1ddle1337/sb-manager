#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export SBM_PREFIX="$ROOT/usr/local" SBM_LIB="$PROJECT" SBM_VAR="$ROOT/var/lib/sb-manager" SBM_RUN="$ROOT/run/sb-manager"
export SBM_LOCK="$SBM_RUN/manager.lock" SBM_BBR_SYSCTL_CONFIG="$ROOT/etc/sysctl.d/99-sb-manager-bbr.conf"
export SBM_BBR_BACKUP_DIR="$ROOT/var/lib/sb-manager/bbr" SBM_BBR_SYSCTL_CMD="$ROOT/bin/fake-sysctl" SBM_BBR_MODPROBE_CMD="$ROOT/bin/fake-modprobe"
mkdir -p "$ROOT/bin" "$ROOT/state"
printf '%s\n' 'fq_codel' >"$ROOT/state/qdisc"
printf '%s\n' 'cubic' >"$ROOT/state/cc"
printf '%s\n' 'cubic reno' >"$ROOT/state/available"
cat >"$ROOT/bin/fake-sysctl" <<'EOF_SYSCTL'
#!/usr/bin/env bash
set -u
root=${FAKE_SYSCTL_ROOT:?}
if [[ ${1:-} == -n ]]; then
  case "$2" in
    net.core.default_qdisc) cat "$root/state/qdisc";;
    net.ipv4.tcp_congestion_control) cat "$root/state/cc";;
    net.ipv4.tcp_available_congestion_control) cat "$root/state/available";;
  esac
elif [[ ${1:-} == -p ]]; then
  if [[ ${FAKE_SYSCTL_FAIL_BBR:-0} == 1 ]] && grep -Fq 'tcp_congestion_control=bbr' "$2"; then
    exit 1
  fi
  while IFS='=' read -r key value; do
    case "$key" in
      net.core.default_qdisc) printf '%s\n' "$value" >"$root/state/qdisc";;
      net.ipv4.tcp_congestion_control) printf '%s\n' "$value" >"$root/state/cc";;
    esac
  done <"$2"
elif [[ ${1:-} == -w ]]; then
  key=${2%%=*}; value=${2#*=}
  case "$key" in
    net.core.default_qdisc) printf '%s\n' "$value" >"$root/state/qdisc";;
    net.ipv4.tcp_congestion_control) printf '%s\n' "$value" >"$root/state/cc";;
  esac
fi
EOF_SYSCTL
cat >"$ROOT/bin/fake-modprobe" <<'EOF_MODPROBE'
#!/usr/bin/env bash
printf '%s\n' 'cubic reno bbr' >"${FAKE_SYSCTL_ROOT:?}/state/available"
EOF_MODPROBE
chmod +x "$ROOT/bin/fake-sysctl" "$ROOT/bin/fake-modprobe"
export FAKE_SYSCTL_ROOT="$ROOT"

source "$PROJECT/lib/common.sh"
source "$PROJECT/lib/bbr.sh"

# A file at the managed path without the manager marker is user-owned.
mkdir -p "$(dirname "$SBM_BBR_SYSCTL_CONFIG")"
printf '%s\n' 'net.ipv4.tcp_congestion_control=reno' >"$SBM_BBR_SYSCTL_CONFIG"
bbr_disable
grep -Fxq 'net.ipv4.tcp_congestion_control=reno' "$SBM_BBR_SYSCTL_CONFIG"
rm -f "$SBM_BBR_SYSCTL_CONFIG"

printf '%s\n' "$SBM_BBR_MARKER" >"$SBM_BBR_SYSCTL_CONFIG"
if (bbr_disable); then
  echo 'BBR disable unexpectedly removed a managed file without backup metadata' >&2
  exit 1
fi
[[ -e "$SBM_BBR_SYSCTL_CONFIG" ]]
rm -f "$SBM_BBR_SYSCTL_CONFIG"

bbr_enable
[[ $(cat "$ROOT/state/qdisc") == fq && $(cat "$ROOT/state/cc") == bbr ]]
grep -Fq 'net.core.default_qdisc=fq' "$SBM_BBR_SYSCTL_CONFIG"
[[ $(stat -c '%a' "$SBM_BBR_SYSCTL_CONFIG") == 644 ]]
[[ $(stat -c '%a' "$SBM_BBR_BACKUP_DIR") == 700 ]]
[[ $(stat -c '%a' "$SBM_BBR_BACKUP_META") == 600 ]]
bbr_status 1 | jq -e '.enabled==true and .congestion_control=="bbr"' >/dev/null
bbr_disable
[[ $(cat "$ROOT/state/qdisc") == fq_codel && $(cat "$ROOT/state/cc") == cubic ]]
[[ ! -e "$SBM_BBR_SYSCTL_CONFIG" ]]

# Restore both a pre-existing managed path and the exact live values, even if
# the old file did not define qdisc or congestion control.
printf '%s\n' 'cake' >"$ROOT/state/qdisc"
printf '%s\n' 'reno' >"$ROOT/state/cc"
mkdir -p "$(dirname "$SBM_BBR_SYSCTL_CONFIG")"
printf '%s\n' 'vm.swappiness=10' >"$SBM_BBR_SYSCTL_CONFIG"
bbr_enable
bbr_disable
grep -Fxq 'vm.swappiness=10' "$SBM_BBR_SYSCTL_CONFIG"
[[ $(cat "$ROOT/state/qdisc") == cake && $(cat "$ROOT/state/cc") == reno ]]

# An apply failure must remove the candidate config and restore live values.
rm -f "$SBM_BBR_SYSCTL_CONFIG"
printf '%s\n' 'fq_codel' >"$ROOT/state/qdisc"
printf '%s\n' 'cubic' >"$ROOT/state/cc"
if (export FAKE_SYSCTL_FAIL_BBR=1; bbr_enable); then
  echo 'BBR enable unexpectedly succeeded during injected sysctl failure' >&2
  exit 1
fi
[[ $(cat "$ROOT/state/qdisc") == fq_codel && $(cat "$ROOT/state/cc") == cubic ]]
[[ ! -e "$SBM_BBR_SYSCTL_CONFIG" && ! -e "$SBM_BBR_BACKUP_META" ]]
printf 'BBR SMOKE PASSED\n'
