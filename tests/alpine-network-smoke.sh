#!/usr/bin/env bash
set -Eeuo pipefail

# Run only inside a disposable Alpine VM/container with Bash already installed.
[[ -f /etc/alpine-release ]] || { echo 'This test must run on Alpine.' >&2; exit 1; }
apk add --no-cache bash curl jq openssl flock openrc python3 coreutils findutils >/dev/null
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export SBM_INIT_SYSTEM=openrc

# Exercise the real BusyBox sysctl reader and TCP planner without any writes.
bash "$PROJECT/sb" tcp plan --bandwidth 500 --rtt 100 --json |
  jq -e '.buffer_bytes>0 and .proposed["net.ipv4.tcp_mtu_probing"]=="1"' >/dev/null
# Mutating/failure paths use fake sysctl and mktemp state on every platform.
bash "$PROJECT/tests/tcp-tuning-smoke.sh"
SBM_TEST_NETWORK_LOOPBACK=1 bash "$PROJECT/tests/network-smoke.sh"
bash "$PROJECT/tests/ui-menu-smoke.sh"
bash "$PROJECT/tests/ui-flow-smoke.sh"
bash "$PROJECT/tests/subscription-live-smoke.sh"
bash "$PROJECT/tests/openrc-lifecycle.sh"
printf 'ALPINE NETWORK SMOKE PASSED (%s)\n' "$(cat /etc/alpine-release)"
