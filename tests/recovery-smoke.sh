#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
REAL=${SBM_TEST_SING_BOX:?Set SBM_TEST_SING_BOX}

run_low_disk_diagnostics() {
  local root=$1
  mkdir -p "$root/bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "Filesystem 1024-blocks Used Available Capacity Mounted on\\n"' 'printf "fake 1000000 950000 50000 95%% /\\n"' >"$root/bin/df"
  chmod 0755 "$root/bin/df"
  export PATH="$root/bin:$PATH"
  export SBM_PREFIX="$root/usr/local" SBM_LIB="$PROJECT" SBM_BIN_DIR="$root/usr/local/bin"
  export SBM_ETC="$root/etc/sb-manager" SBM_VAR="$root/var/lib/sb-manager" SBM_RUN="$root/run/sb-manager"
  export SBM_STATE="$SBM_ETC/state.json" SBM_GENERATED_DIR="$SBM_ETC/generated"
  export SBM_CONFIG="$SBM_GENERATED_DIR/config.json"
  export SBM_SECRETS="$SBM_ETC/secrets" SBM_CERTS="$SBM_ETC/certs" SBM_BACKUPS="$SBM_VAR/backups" SBM_EXPORTS="$SBM_VAR/exports" SBM_CACHE="$SBM_VAR/cache"
  export SBM_CORE_DIR="$root/cores" SBM_LOCK="$SBM_RUN/manager.lock" SBM_SING_BOX_BIN="$root/bin/sing-box"
  export SBM_SKIP_INIT=1 SBM_SKIP_SYSTEMD=1 NO_COLOR=1
  export SBM_SERVICE_USER=$(id -un)
  mkdir -p "$SBM_CORE_DIR/sing-box/test"
  install -m 0755 "$REAL" "$SBM_CORE_DIR/sing-box/test/sing-box"
  ln -s "$SBM_CORE_DIR/sing-box/test/sing-box" "$SBM_SING_BOX_BIN"
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
  source "$PROJECT/lib/render.sh"
  source "$PROJECT/lib/core.sh"
  source "$PROJECT/lib/node.sh"
  source "$PROJECT/lib/doctor.sh"
  state_init
  output=$(doctor_run 2>&1 || true)
  grep -q '可用空间不足 100 MiB' <<<"$output"
  grep -q 'inode 使用率 95%' <<<"$output"
}

run_service_rollback() {
  local root=$1
  mkdir -p "$root/bin" "$root/systemd"
  printf '%s\n' '#!/usr/bin/env bash' 'set -u' 'printf "%s fail=%s\\n" "$*" "${FAKE_FAIL:-unset}" >>"$FAKE_LOG"' 'case ${1:-} in' 'daemon-reload|enable|disable|reset-failed|status) exit 0 ;;' 'restart)' '  [[ -f "$FAKE_FAIL" ]] && exit 1' '  : >"$FAKE_ACTIVE"' '  exit 0 ;;' 'start) : >"$FAKE_ACTIVE"; exit 0 ;;' 'stop) rm -f "$FAKE_ACTIVE"; exit 0 ;;' 'is-active)' '  [[ -f "$FAKE_ACTIVE" ]] && exit 0' '  exit 3 ;;' 'is-enabled) exit 0 ;;' '*) exit 0 ;;' 'esac' >"$root/bin/systemctl"
  chmod 0755 "$root/bin/systemctl"
  export PATH="$root/bin:$PATH"
  export SBM_PREFIX="$root/usr/local" SBM_LIB="$PROJECT" SBM_BIN_DIR="$root/usr/local/bin"
  export SBM_ETC="$root/etc/sb-manager" SBM_VAR="$root/var/lib/sb-manager" SBM_RUN="$root/run/sb-manager"
  export SBM_SYSTEMD_DIR="$root/systemd" SBM_SERVICE=sb-recovery.service SBM_INIT_SYSTEM=systemd SBM_INIT_SYSTEM_RESOLVED=systemd SBM_SKIP_INIT=0
  export SBM_STATE="$SBM_ETC/state.json" SBM_GENERATED_DIR="$SBM_ETC/generated"
  export SBM_CONFIG="$SBM_GENERATED_DIR/config.json"
  export SBM_SECRETS="$SBM_ETC/secrets" SBM_CERTS="$SBM_ETC/certs" SBM_BACKUPS="$SBM_VAR/backups" SBM_EXPORTS="$SBM_VAR/exports" SBM_CACHE="$SBM_VAR/cache"
  export SBM_CORE_DIR="$root/cores" SBM_LOCK="$SBM_RUN/manager.lock" SBM_SING_BOX_BIN="$REAL" SBM_CLOUDFLARED_BIN="$root/bin/cloudflared" FAKE_ACTIVE="$root/active" FAKE_FAIL="$root/fail" FAKE_LOG="$root/systemctl.log" NO_COLOR=1
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
  source "$PROJECT/lib/render.sh"
  source "$PROJECT/lib/core.sh"
  source "$PROJECT/lib/node.sh"
  printf '%s\n' '[Unit]' '[Service]' >"$SBM_SYSTEMD_DIR/$SBM_SERVICE"
  state_init
  node_add ss --id crash-test --port 37891 --address 127.0.0.1 >/dev/null
  before=$(jq -r '.nodes[]|select(.id=="crash-test")|.name' "$SBM_STATE")
  : >"$FAKE_FAIL"
  if node_set crash-test --name 'must-rollback' >/dev/null 2>&1; then
    cat "$FAKE_LOG" >&2
    echo 'service crash unexpectedly accepted' >&2
    return 1
  fi
  [[ $(jq -r '.nodes[]|select(.id=="crash-test")|.name' "$SBM_STATE") == "$before" ]]
  ! grep -q 'must-rollback' "$SBM_CONFIG"
}

low_root=$(mktemp -d)
service_root=$(mktemp -d)
trap 'rm -rf "$low_root" "$service_root"' EXIT
run_low_disk_diagnostics "$low_root"
run_service_rollback "$service_root"
printf 'RECOVERY SMOKE PASSED\n'
