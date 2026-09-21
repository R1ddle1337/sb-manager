#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export SBM_LIB="$PROJECT" SBM_ETC="$ROOT/etc/sb-manager" SBM_VAR="$ROOT/var" SBM_RUN="$ROOT/run"
export SBM_LOCK="$SBM_RUN/manager.lock" SBM_TCP_SYSCTL_CONFIG="$ROOT/etc/sysctl.d/99-sb-manager-tcp.conf"
export SBM_TCP_BACKUP_DIR="$ROOT/backups" SBM_TCP_SYSCTL_CMD="$ROOT/bin/sysctl" SBM_TCP_MEMINFO="$ROOT/meminfo"
export SBM_TCP_CGROUP_MEMORY_FILES="$ROOT/memory.max:$ROOT/memory.limit_in_bytes"
export SBM_TCP_SYSCTL_DIRS="$ROOT/etc/sysctl.d" SBM_TCP_SYSCTL_MAIN="$ROOT/etc/sysctl.conf"
export FAKE_TCP_ROOT="$ROOT" SBM_TEST_MODE=1
mkdir -p "$ROOT/bin" "$ROOT/etc/sysctl.d"
printf 'MemTotal: 1048576 kB\n' >"$SBM_TCP_MEMINFO"
cat >"$ROOT/original.json" <<'EOF_VALUES'
{"net.ipv4.tcp_rmem":"4096 131072 6291456","net.ipv4.tcp_wmem":"4096 16384 4194304","net.ipv4.tcp_moderate_rcvbuf":"0","net.ipv4.tcp_mtu_probing":"0"}
EOF_VALUES
cp "$ROOT/original.json" "$ROOT/values.json"
cat >"$SBM_TCP_SYSCTL_CMD" <<'EOF_SYSCTL'
#!/usr/bin/env bash
set -Eeuo pipefail
root=${FAKE_TCP_ROOT:?}
write_value() {
  local key=$1 value=$2
  jq -e --arg key "$key" 'has($key)' "$root/values.json" >/dev/null
  jq --arg key "$key" --arg value "$value" '.[$key]=$value' "$root/values.json" >"$root/new.json"
  mv "$root/new.json" "$root/values.json"
}
case "$1" in
  -n) jq -er --arg key "$2" '.[$key] // empty' "$root/values.json";;
  -p)
    printf 'apply\n' >>"$root/writes"
    while IFS='=' read -r key value; do
      [[ "$key" == net.* ]] || continue
      [[ ${FAKE_TCP_VERIFY_FAIL:-0} != 1 || "$key" != net.ipv4.tcp_mtu_probing ]] || continue
      write_value "$key" "$value"
      [[ ${FAKE_TCP_APPLY_FAIL:-0} != 1 ]] || exit 1
    done <"$2"
    ;;
  -w)
    printf 'restore\n' >>"$root/writes"
    [[ ${FAKE_TCP_RESTORE_FAIL:-0} != 1 ]] || exit 1
    write_value "${2%%=*}" "${2#*=}"
    ;;
  *) exit 2;;
esac
EOF_SYSCTL
chmod +x "$SBM_TCP_SYSCTL_CMD"
source "$PROJECT/lib/common.sh"
source "$PROJECT/lib/tcp_tuning.sh"
same_values() { jq -en --slurpfile a "$1" --slurpfile b "$2" '$a==$b' >/dev/null; }
expect_failure() {
  if ("$@"); then printf 'Unexpected success: %s\n' "$*" >&2; exit 1; fi
}

# Preview and CLI dry-run must not initialize manager state, logs, or backups.
bash "$PROJECT/sb" tcp plan --bandwidth 500 --rtt 200 --json >"$ROOT/plan.json"
jq -e '.buffer_bytes==25165824 and .memory_cap_bytes==33554432 and .capped==false and .proposed["net.ipv4.tcp_rmem"]=="4096 131072 25165824"' "$ROOT/plan.json" >/dev/null
bash "$PROJECT/sb" --dry-run --json tcp enable --bandwidth 1000 --rtt 200 | jq -e '.buffer_bytes==33554432 and .capped' >/dev/null
[[ ! -e "$SBM_TCP_BACKUP_DIR" && ! -e "$SBM_RUN" && ! -e "$SBM_ETC" && ! -e "$ROOT/writes" ]]
printf '134217728\n' >"$ROOT/memory.max"
tcp_tuning_plan 1000 200 | jq -e '.buffer_bytes==4194304 and .memory_kib==131072 and .capped' >/dev/null
printf 'max\n' >"$ROOT/memory.max"
printf '67108864\n' >"$ROOT/memory.limit_in_bytes"
tcp_tuning_plan 1000 200 | jq -e '.buffer_bytes==2097152 and .memory_kib==65536' >/dev/null
rm "$ROOT/memory.limit_in_bytes"
for bad in 0 01 -1 1.5 100001 999999999999999999999 'x[$(touch never)]'; do expect_failure tcp_tuning_plan "$bad" 100; done
expect_failure tcp_tuning_plan 100 2001
expect_failure bash "$PROJECT/sb" tcp enable --bandwidth
expect_failure bash "$PROJECT/sb" tcp status --unknown
expect_failure bash "$PROJECT/sb" --dry-run tcp disable

# Conflicts are reported and left untouched, including slash-style sysctl keys.
printf 'net/ipv4/tcp_rmem = 4096 131072 9999999\n' >"$ROOT/etc/sysctl.d/99-other.conf"
tcp_tuning_plan 500 200 | jq -e '.conflicts|length==1' >/dev/null
printf 'vm.swappiness=10\n' >"$SBM_TCP_SYSCTL_CONFIG"
chmod 0600 "$SBM_TCP_SYSCTL_CONFIG"
tcp_tuning_disable
grep -Fxq 'vm.swappiness=10' "$SBM_TCP_SYSCTL_CONFIG"
bash "$PROJECT/sb" tcp enable --bandwidth 500 --rtt 200 --json | jq -e '.enabled and .managed and (.recovery_pending|not)' >/dev/null
[[ $(stat -c '%a' "$SBM_TCP_BACKUP_DIR") == 700 ]]
[[ $(stat -c '%a' "$SBM_TCP_BACKUP_DIR/original/values.json") == 600 ]]
[[ $(stat -c '%a' "$SBM_TCP_SYSCTL_CONFIG") == 644 ]]
cp "$ROOT/values.json" "$ROOT/active.json"
cp "$SBM_TCP_SYSCTL_CONFIG" "$ROOT/active.conf"
# Failed retuning restores the previous active profile, not the first baseline.
expect_failure env FAKE_TCP_APPLY_FAIL=1 bash "$PROJECT/sb" tcp enable --bandwidth 100 --rtt 50
same_values "$ROOT/active.json" "$ROOT/values.json"
cmp "$ROOT/active.conf" "$SBM_TCP_SYSCTL_CONFIG"
tcp_tuning_enable 100 50 >/dev/null
tcp_tuning_disable
same_values "$ROOT/original.json" "$ROOT/values.json"
grep -Fxq 'vm.swappiness=10' "$SBM_TCP_SYSCTL_CONFIG"
[[ $(stat -c '%a' "$SBM_TCP_SYSCTL_CONFIG") == 600 ]]
grep -Fxq 'net/ipv4/tcp_rmem = 4096 131072 9999999' "$ROOT/etc/sysctl.d/99-other.conf"

# Partial application and a successful sysctl command that ignores a key both roll back.
rm "$SBM_TCP_SYSCTL_CONFIG"
for fault in FAKE_TCP_APPLY_FAIL FAKE_TCP_VERIFY_FAIL; do
  expect_failure env "$fault=1" bash "$PROJECT/sb" tcp enable --bandwidth 500 --rtt 200
  same_values "$ROOT/original.json" "$ROOT/values.json"
  [[ ! -e "$SBM_TCP_SYSCTL_CONFIG" && ! -e "$SBM_TCP_BACKUP_DIR/original" && ! -e "$SBM_TCP_BACKUP_DIR/pending" ]]
done
# A failed rollback remains recoverable on the next invocation.
expect_failure env FAKE_TCP_APPLY_FAIL=1 FAKE_TCP_RESTORE_FAIL=1 bash "$PROJECT/sb" tcp enable --bandwidth 500 --rtt 200
[[ -e "$SBM_TCP_BACKUP_DIR/pending/values.json" ]]
tcp_tuning_status 1 | jq -e '.recovery_pending' >/dev/null
tcp_tuning_disable
same_values "$ROOT/original.json" "$ROOT/values.json"
[[ ! -e "$SBM_TCP_BACKUP_DIR/pending" && ! -e "$SBM_TCP_SYSCTL_CONFIG" ]]

# Readback detects drift; damaged/missing backups never trigger blind changes.
tcp_tuning_enable 500 200 >/dev/null
"$SBM_TCP_SYSCTL_CMD" -w net.ipv4.tcp_mtu_probing=0
tcp_tuning_status 1 | jq -e '.managed and (.enabled|not)' >/dev/null
cp "$SBM_TCP_BACKUP_DIR/original/values.json" "$ROOT/good-backup.json"
printf '{}\n' >"$SBM_TCP_BACKUP_DIR/original/values.json"
cp "$ROOT/writes" "$ROOT/writes-before"
expect_failure tcp_tuning_enable 100 100
expect_failure tcp_tuning_disable
cmp "$ROOT/writes-before" "$ROOT/writes"
cp "$ROOT/good-backup.json" "$SBM_TCP_BACKUP_DIR/original/values.json"
tcp_tuning_disable
printf '%s\n' "$SBM_TCP_MARKER" >"$SBM_TCP_SYSCTL_CONFIG"
expect_failure tcp_tuning_disable
expect_failure tcp_tuning_enable 100 100
rm "$SBM_TCP_SYSCTL_CONFIG"
ln -s "$ROOT/original.json" "$SBM_TCP_SYSCTL_CONFIG"
expect_failure tcp_tuning_enable 100 100
[[ -L "$SBM_TCP_SYSCTL_CONFIG" ]]

# Uninstall restores tuning before removing its code/backups, in a copied tree.
rm "$SBM_TCP_SYSCTL_CONFIG"
tcp_tuning_enable 500 200 >/dev/null
mkdir -p "$ROOT/install"
cp -a "$PROJECT/lib" "$PROJECT/protocols" "$PROJECT/sb" "$PROJECT/VERSION" "$ROOT/install/"
env SBM_LIB="$ROOT/install" SBM_BIN_DIR="$ROOT/bin" SBM_SKIP_INIT=1 SBM_SKIP_SYSTEMD=1 \
  SBM_SYSTEMD_DIR="$ROOT/systemd" SBM_OPENRC_DIR="$ROOT/init.d" SBM_PERIODIC_DIR="$ROOT/periodic" \
  SBM_LOG_DIR="$ROOT/log" SBM_BBR_SYSCTL_CONFIG="$ROOT/bbr.conf" SBM_HY2_UDP_BUFFER_SYSCTL_CONFIG="$ROOT/hy2.conf" \
  bash "$ROOT/install/sb" uninstall --yes >/dev/null
same_values "$ROOT/original.json" "$ROOT/values.json"
[[ ! -e "$ROOT/install" && ! -e "$SBM_TCP_SYSCTL_CONFIG" && ! -e "$SBM_TCP_BACKUP_DIR/original" ]]
printf 'TCP TUNING SMOKE PASSED\n'
