#!/usr/bin/env bash
set -Eeuo pipefail

# Run this script on the designated Debian 13 host. Keep the official cores
# outside the checkout so install-smoke cannot copy large test assets.
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
STABLE=${SBM_TEST_SING_BOX_STABLE:?Set SBM_TEST_SING_BOX_STABLE to official 1.13.19}
PREVIEW=${SBM_TEST_SING_BOX_PREVIEW:?Set SBM_TEST_SING_BOX_PREVIEW to official 1.14.0-rc.1}

run_stable() {
  local test=$1
  printf '\n===== %s (stable) =====\n' "$test"
  SBM_TEST_SING_BOX="$STABLE" bash "$PROJECT/$test"
}

for test in \
  tests/ui-menu-smoke.sh \
  tests/firewall-smoke.sh \
  tests/firewall-security-smoke.sh \
  tests/traffic-control-smoke.sh \
  tests/traffic-nft-real-smoke.sh \
  tests/nginx-stream-smoke.sh \
  tests/nginx-stream-systemd-smoke.sh \
  tests/cert-hook-lock-smoke.sh \
  tests/cert-reload-smoke.sh \
  tests/run.sh \
  tests/state-safety-smoke.sh \
  tests/state-migration-smoke.sh \
  tests/protocol-suite-smoke.sh \
  tests/probe-smoke.sh \
  tests/subscription-smoke.sh \
  tests/subscription-systemd-smoke.sh \
  tests/backup-age-smoke.sh \
  tests/core-paired-rollback-smoke.sh \
  tests/recovery-smoke.sh \
  tests/doctor-smoke.sh \
  tests/service-lifecycle.sh \
  tests/openrc-lifecycle.sh \
  tests/openrc-nginx-stream-smoke.sh \
  tests/systemd-exec-smoke.sh \
  tests/systemd-real-exec.sh \
  tests/install-smoke.sh \
  tests/bootstrap-latest-smoke.sh \
  tests/download-retry-smoke.sh \
  tests/acme-install-smoke.sh \
  tests/core-download-smoke.sh; do
  run_stable "$test"
done

printf '\n===== tests/api-preview-smoke.sh (preview) =====\n'
SBM_TEST_SING_BOX="$PREVIEW" bash "$PROJECT/tests/api-preview-smoke.sh"
printf '\n===== tests/snell-preview-smoke.sh (preview) =====\n'
SBM_TEST_SING_BOX="$PREVIEW" bash "$PROJECT/tests/snell-preview-smoke.sh"
printf '\nREMOTE DEBIAN 13 SUITE PASSED\n'
