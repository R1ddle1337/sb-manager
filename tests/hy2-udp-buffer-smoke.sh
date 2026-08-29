#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export SBM_PREFIX="$ROOT/usr/local" SBM_LIB="$PROJECT" SBM_VAR="$ROOT/var/lib/sb-manager" SBM_RUN="$ROOT/run/sb-manager"
export SBM_LOCK="$SBM_RUN/manager.lock"
export SBM_BIN_DIR="$ROOT/usr/local/bin" SBM_ETC="$ROOT/etc/sb-manager" SBM_STATE="$ROOT/etc/sb-manager/state.json"
export SBM_GENERATED_DIR="$ROOT/etc/sb-manager/generated" SBM_CONFIG="$ROOT/etc/sb-manager/generated/config.json"
export SBM_SECRETS="$ROOT/etc/sb-manager/secrets" SBM_CERTS="$ROOT/etc/sb-manager/certs"
export SBM_SKIP_INIT=1 SBM_TEST_MODE=1 SBM_SERVICE_USER=root NO_COLOR=1
export SBM_HY2_UDP_BUFFER_SYSCTL_CONFIG="$ROOT/etc/sysctl.d/99-hysteria.conf"
export SBM_HY2_UDP_BUFFER_BACKUP_DIR="$ROOT/var/lib/sb-manager/hysteria2-udp-buffer"
export SBM_HY2_UDP_BUFFER_SYSCTL_CMD="$ROOT/bin/fake-sysctl"
mkdir -p "$ROOT/bin" "$ROOT/state"
printf '%s\n' '212992' >"$ROOT/state/rmem"
printf '%s\n' '212992' >"$ROOT/state/wmem"

cat >"$ROOT/bin/fake-sysctl" <<'EOF_SYSCTL'
#!/usr/bin/env bash
set -u
root=${FAKE_SYSCTL_ROOT:?}
if [[ ${1:-} == -n ]]; then
  case "$2" in
    net.core.rmem_max) cat "$root/state/rmem";;
    net.core.wmem_max) cat "$root/state/wmem";;
  esac
elif [[ ${1:-} == -p ]]; then
  if [[ ${FAKE_SYSCTL_FAIL_HY2:-0} == 1 ]] && grep -Fq 'net.core.rmem_max=16777216' "$2"; then
    exit 1
  fi
  while IFS='=' read -r key value; do
    case "$key" in
      net.core.rmem_max) printf '%s\n' "$value" >"$root/state/rmem";;
      net.core.wmem_max) printf '%s\n' "$value" >"$root/state/wmem";;
    esac
  done <"$2"
elif [[ ${1:-} == -w ]]; then
  key=${2%%=*}; value=${2#*=}
  case "$key" in
    net.core.rmem_max) printf '%s\n' "$value" >"$root/state/rmem";;
    net.core.wmem_max) printf '%s\n' "$value" >"$root/state/wmem";;
  esac
fi
EOF_SYSCTL
chmod +x "$ROOT/bin/fake-sysctl"
export FAKE_SYSCTL_ROOT="$ROOT"

source "$PROJECT/lib/common.sh"
source "$PROJECT/lib/hysteria2_tuning.sh"

# A user-created official file is not manager-owned and must survive disable.
mkdir -p "$(dirname "$SBM_HY2_UDP_BUFFER_SYSCTL_CONFIG")"
printf '%s\n' 'net.core.rmem_max=8388608' >"$SBM_HY2_UDP_BUFFER_SYSCTL_CONFIG"
chmod 0640 "$SBM_HY2_UDP_BUFFER_SYSCTL_CONFIG"
hy2_udp_buffer_disable
grep -Fxq 'net.core.rmem_max=8388608' "$SBM_HY2_UDP_BUFFER_SYSCTL_CONFIG"

# Enabling applies 16 MiB and protects both the old file and live values.
hy2_udp_buffer_enable
[[ $(cat "$ROOT/state/rmem") == 16777216 && $(cat "$ROOT/state/wmem") == 16777216 ]]
grep -Fqx 'net.core.rmem_max=16777216' "$SBM_HY2_UDP_BUFFER_SYSCTL_CONFIG"
grep -Fqx 'net.core.wmem_max=16777216' "$SBM_HY2_UDP_BUFFER_SYSCTL_CONFIG"
[[ $(stat -c '%a' "$SBM_HY2_UDP_BUFFER_SYSCTL_CONFIG") == 644 ]]
[[ $(stat -c '%a' "$SBM_HY2_UDP_BUFFER_BACKUP_DIR") == 700 ]]
[[ $(stat -c '%a' "$SBM_HY2_UDP_BUFFER_BACKUP_META") == 600 ]]
hy2_udp_buffer_status 1 | jq -e '.enabled==true and .managed==true and .recommended_size=="16777216"' >/dev/null
bash "$PROJECT/sb" hy2 buffer status --json | jq -e '.enabled==true and .managed==true' >/dev/null
hy2_udp_buffer_disable
grep -Fxq 'net.core.rmem_max=8388608' "$SBM_HY2_UDP_BUFFER_SYSCTL_CONFIG"
[[ $(stat -c '%a' "$SBM_HY2_UDP_BUFFER_SYSCTL_CONFIG") == 640 ]]
[[ $(cat "$ROOT/state/rmem") == 212992 && $(cat "$ROOT/state/wmem") == 212992 ]]

# An apply failure must remove the candidate and restore exact live values.
rm -f "$SBM_HY2_UDP_BUFFER_SYSCTL_CONFIG"
printf '%s\n' '425984' >"$ROOT/state/rmem"
printf '%s\n' '425984' >"$ROOT/state/wmem"
if (export FAKE_SYSCTL_FAIL_HY2=1; hy2_udp_buffer_enable); then
  echo 'Hysteria2 UDP buffer enable unexpectedly succeeded during injected sysctl failure' >&2
  exit 1
fi
[[ $(cat "$ROOT/state/rmem") == 425984 && $(cat "$ROOT/state/wmem") == 425984 ]]
[[ ! -e "$SBM_HY2_UDP_BUFFER_SYSCTL_CONFIG" && ! -e "$SBM_HY2_UDP_BUFFER_BACKUP_META" ]]

# Corrupt backup metadata must never cause the managed file to be discarded.
mkdir -p "$SBM_HY2_UDP_BUFFER_BACKUP_DIR"
printf '%s\n' '{broken' >"$SBM_HY2_UDP_BUFFER_BACKUP_META"
printf '%s\n' "$SBM_HY2_UDP_BUFFER_MARKER" >"$SBM_HY2_UDP_BUFFER_SYSCTL_CONFIG"
if (hy2_udp_buffer_disable); then
  echo 'Hysteria2 UDP buffer disable unexpectedly accepted corrupt backup metadata' >&2
  exit 1
fi
[[ -e "$SBM_HY2_UDP_BUFFER_SYSCTL_CONFIG" && -e "$SBM_HY2_UDP_BUFFER_BACKUP_META" ]]
printf 'HYSTERIA2 UDP BUFFER SMOKE PASSED\n'
