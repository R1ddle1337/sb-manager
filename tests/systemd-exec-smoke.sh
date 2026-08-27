#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

export SBM_PREFIX="$ROOT/usr/local"
export SBM_LIB="$PROJECT"
export SBM_BIN_DIR="$ROOT/usr/local/bin"
export SBM_ETC="$ROOT/etc/sb-manager"
export SBM_VAR="$ROOT/var/lib/sb-manager"
export SBM_RUN="$ROOT/run/sb-manager"
export SBM_CORE_DIR="$ROOT/usr/local/lib/sb-manager/cores"
export SBM_SING_BOX_BIN="$SBM_BIN_DIR/sing-box"
export SBM_SERVICE_USER=sbmanager
export SBM_INIT_SYSTEM=systemd
export SBM_INIT_SYSTEM_RESOLVED=systemd
export SBM_SKIP_INIT=0
export SBM_FAKE_CAP_MARKER="$ROOT/capability.marker"
export SBM_FAKE_SYSTEMD_RUN_LOG="$ROOT/systemd-run.log"
export NO_COLOR=1

mkdir -p "$ROOT/fake-bin" "$SBM_BIN_DIR" "$SBM_CORE_DIR/sing-box/1.13.19" "$SBM_RUN" "$SBM_ETC"
cat >"$SBM_CORE_DIR/sing-box/1.13.19/sing-box" <<'EOF_CORE'
#!/usr/bin/env bash
printf 'sing-box version 1.13.19\n'
EOF_CORE
chmod 0755 "$SBM_CORE_DIR/sing-box/1.13.19/sing-box"
ln -s "$SBM_CORE_DIR/sing-box/1.13.19/sing-box" "$SBM_SING_BOX_BIN"

cat >"$ROOT/fake-bin/getcap" <<'EOF_GETCAP'
#!/usr/bin/env bash
if [[ -f "$SBM_FAKE_CAP_MARKER" ]]; then
  printf '%s cap_net_bind_service=ep\n' "$1"
fi
EOF_GETCAP
cat >"$ROOT/fake-bin/setcap" <<'EOF_SETCAP'
#!/usr/bin/env bash
if [[ ${1:-} == -r ]]; then
  rm -f "$SBM_FAKE_CAP_MARKER"
else
  : >"$SBM_FAKE_CAP_MARKER"
fi
EOF_SETCAP
cat >"$ROOT/fake-bin/systemctl" <<'EOF_SYSTEMCTL'
#!/usr/bin/env bash
[[ ${1:-} == show-environment ]] && exit 0
exit 0
EOF_SYSTEMCTL
cat >"$ROOT/fake-bin/systemd-run" <<'EOF_SYSTEMD_RUN'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$SBM_FAKE_SYSTEMD_RUN_LOG"
exit 0
EOF_SYSTEMD_RUN
chmod 0755 "$ROOT/fake-bin/"*
export PATH="$ROOT/fake-bin:$PATH"

# shellcheck source=lib/common.sh
source "$PROJECT/lib/common.sh"
source "$PROJECT/lib/service.sh"
source "$PROJECT/lib/runtime-security.sh"

# A stale OpenRC file capability must be removed before a systemd unit with
# NoNewPrivileges starts the binary.
: >"$SBM_FAKE_CAP_MARKER"
prepare_singbox_binary_for_backend "$SBM_SING_BOX_BIN" systemd
[[ ! -e "$SBM_FAKE_CAP_MARKER" ]]
[[ -z $(singbox_file_capabilities "$SBM_SING_BOX_BIN") ]]

# OpenRC still receives the one narrowly-scoped capability it needs.
prepare_singbox_binary_for_backend "$SBM_SING_BOX_BIN" openrc
[[ -e "$SBM_FAKE_CAP_MARKER" ]]

# Switching back to systemd removes it again and the transient preflight uses
# the same critical execution restrictions as the permanent unit.
prepare_singbox_binary_for_backend "$SBM_SING_BOX_BIN" systemd
systemd_exec_preflight "$SBM_SING_BOX_BIN"
grep -Fxq -- '--property=NoNewPrivileges=yes' "$SBM_FAKE_SYSTEMD_RUN_LOG"
grep -Fxq -- '--property=AmbientCapabilities=CAP_NET_BIND_SERVICE' "$SBM_FAKE_SYSTEMD_RUN_LOG"
grep -Fxq -- '--property=CapabilityBoundingSet=CAP_NET_BIND_SERVICE' "$SBM_FAKE_SYSTEMD_RUN_LOG"
grep -Fxq -- '--property=User=sbmanager' "$SBM_FAKE_SYSTEMD_RUN_LOG"
grep -Fxq "$SBM_SING_BOX_BIN" "$SBM_FAKE_SYSTEMD_RUN_LOG"

printf 'SYSTEMD EXEC SMOKE PASSED\n'
