#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/feature-fixture.sh"
export SBM_NETWORK_IPERF_CMD="$ROOT/bin/iperf3"
cat >"$SBM_NETWORK_IPERF_CMD" <<'EOF_IPERF'
#!/usr/bin/env bash
[[ ${FAKE_IPERF_FAIL:-0} != 1 ]] || exit 1
jq -n --argjson speed "${FAKE_IPERF_SPEED:-100000000}" '{end:{sum_received:{bits_per_second:$speed,bytes:125000000},sum_sent:{retransmits:2}}}'
EOF_IPERF
chmod +x "$SBM_NETWORK_IPERF_CMD"
network_speed 127.0.0.1 5201 1 1 down 1 >"$ROOT/a.json"
FAKE_IPERF_SPEED=125000000 network_speed 127.0.0.1 5201 1 1 down 1 >"$ROOT/b.json"
network_compare "$(jq -r '.id' "$ROOT/a.json")" "$(jq -r '.id' "$ROOT/b.json")" 1 | jq -e '.change_percent==25' >/dev/null
[[ $(stat -c '%a' "$SBM_NETWORK_HISTORY") == 700 ]]
[[ $(stat -c '%a' "$SBM_NETWORK_HISTORY/$(jq -r '.id' "$ROOT/a.json").json") == 600 ]]
network_speed 127.0.0.1 5201 1 2 down 1 >"$ROOT/c.json"
expect_failure network_compare "$(jq -r '.id' "$ROOT/a.json")" "$(jq -r '.id' "$ROOT/c.json")"
expect_failure network_speed '-f' 5201 1 1 down 1
expect_failure network_speed example.com 5201 31 1 down 1
expect_failure env FAKE_IPERF_FAIL=1 bash "$PROJECT/sb" network speed example.com --seconds 1
network_history | jq -e 'length==3' >/dev/null
expect_failure network_compare ../state missing
printf 'BENCHMARK SMOKE PASSED\n'
