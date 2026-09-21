#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export SBM_LIB="$PROJECT" SBM_ETC="$ROOT/etc" SBM_VAR="$ROOT/var" SBM_RUN="$ROOT/run"
export SBM_NETWORK_PING_CMD="$ROOT/ping" SBM_NETWORK_TIMEOUT_CMD=timeout
export FAKE_PING_ROOT="$ROOT"
cat >"$ROOT/ping" <<'EOF_PING'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$@" >"$FAKE_PING_ROOT/args"
cat "$FAKE_PING_ROOT/output"
exit "${FAKE_PING_EXIT:-0}"
EOF_PING
chmod +x "$ROOT/ping"
cat >"$ROOT/output" <<'EOF_IPUTILS'
PING example.com (192.0.2.1) 56(84) bytes of data.
64 bytes from 192.0.2.1: icmp_seq=1 ttl=64 time=10.0 ms
64 bytes from 192.0.2.1: icmp_seq=2 ttl=64 time=30.0 ms
64 bytes from 192.0.2.1: icmp_seq=4 ttl=64 time=20.0 ms
--- example.com ping statistics ---
4 packets transmitted, 3 received, 25% packet loss, time 3000ms
rtt min/avg/max/mdev = 10.000/20.000/30.000/8.165 ms
EOF_IPUTILS
bash "$PROJECT/sb" network ping example.com --count 4 --ipv4 --json >"$ROOT/result"
jq -e '.target=="example.com" and .sent==4 and .received==3 and .loss_percent==25 and .rtt_ms.avg==20 and .jitter_ms==15 and .reachable' "$ROOT/result" >/dev/null
grep -Fxq -- '-4' "$ROOT/args"
[[ ! -e "$SBM_ETC" && ! -e "$SBM_VAR" && ! -e "$SBM_RUN" ]]
cat >"$ROOT/output" <<'EOF_BUSYBOX'
PING ::1 (::1): 56 data bytes
64 bytes from ::1: seq=0 ttl=64 time=0.040 ms
64 bytes from ::1: seq=1 ttl=64 time=0.060 ms
--- ::1 ping statistics ---
2 packets transmitted, 2 packets received, 0% packet loss
round-trip min/avg/max = 0.040/0.050/0.060 ms
EOF_BUSYBOX
bash "$PROJECT/sb" --json network ping ::1 --count 2 --ipv6 >"$ROOT/result"
jq -e '.received==2 and .loss_percent==0 and .rtt_ms.avg==0.05 and .jitter_ms==0.02 and .ip_family=="6"' "$ROOT/result" >/dev/null
grep -Fxq -- '-6' "$ROOT/args"
printf '2 packets transmitted, 0 received, 100%% packet loss, time 1000ms\n' >"$ROOT/output"
if FAKE_PING_EXIT=1 bash "$PROJECT/sb" network ping example.com --count 2 --json >"$ROOT/result"; then exit 1; fi
jq -e '.loss_percent==100 and .rtt_ms==null and .jitter_ms==null and (.reachable|not)' "$ROOT/result" >/dev/null
printf 'ping: bad address\n' >"$ROOT/output"
if FAKE_PING_EXIT=2 bash "$PROJECT/sb" network ping example.com --json >"$ROOT/result" 2>"$ROOT/error"; then exit 1; fi
[[ ! -s "$ROOT/result" ]]
grep -Fq 'bad address' "$ROOT/error"
for target in '-f' 'bad host' '$(id)' 'https://example.com'; do
  if bash "$PROJECT/sb" network ping "$target" --json >/dev/null 2>&1; then exit 1; fi
done
for count in 0 31 -1 01 100000000000000000; do
  if bash "$PROJECT/sb" network ping example.com --count "$count" >/dev/null 2>&1; then exit 1; fi
done
if bash "$PROJECT/sb" network ping example.com --ipv4 --ipv6 >/dev/null 2>&1; then exit 1; fi
if bash "$PROJECT/sb" network ping example.com --count >/dev/null 2>&1; then exit 1; fi

# Opt-in real probes use only loopback, including BusyBox on Alpine containers.
if [[ ${SBM_TEST_NETWORK_LOOPBACK:-0} == 1 ]]; then
  SBM_NETWORK_PING_CMD=ping bash "$PROJECT/sb" network ping 127.0.0.1 --count 2 --json | jq -e '.received==2 and .reachable' >/dev/null
  SBM_NETWORK_PING_CMD=ping bash "$PROJECT/sb" network ping ::1 --count 2 --ipv6 --json | jq -e '.received==2 and .reachable' >/dev/null
fi
printf 'NETWORK SMOKE PASSED\n'
