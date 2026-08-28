#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')" == systemd ]] || {
  echo 'SUBSCRIPTION SYSTEMD SMOKE SKIPPED: systemd is not PID 1'
  exit 0
}

ROOT=$(mktemp -d /opt/sbmanager-subscription-systemd.XXXXXX)
UNIT="sb-subscription-smoke-$RANDOM.service"
PORT=$((30000 + RANDOM % 20000))
cleanup() {
  systemctl stop "$UNIT" >/dev/null 2>&1 || true
  systemctl disable "$UNIT" >/dev/null 2>&1 || true
  rm -f "/run/systemd/system/$UNIT"
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -rf "$ROOT"
}
trap cleanup EXIT

PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export SBM_PREFIX="$ROOT/usr/local" SBM_LIB="$ROOT/usr/local/lib/sb-manager" SBM_BIN_DIR="$ROOT/usr/local/bin"
export SBM_ETC="$ROOT/etc/sb-manager" SBM_VAR="$ROOT/var/lib/sb-manager" SBM_RUN="$ROOT/run/sb-manager"
export SBM_STATE="$SBM_ETC/state.json" SBM_GENERATED_DIR="$SBM_ETC/generated"
export SBM_CONFIG="$SBM_GENERATED_DIR/config.json" SBM_SECRETS="$SBM_ETC/secrets" SBM_CERTS="$SBM_ETC/certs"
export SBM_BACKUPS="$SBM_VAR/backups" SBM_EXPORTS="$SBM_VAR/exports" SBM_CACHE="$SBM_VAR/cache"
export SBM_CORE_DIR="$ROOT/cores" SBM_LOCK="$SBM_RUN/manager.lock" SBM_SUBSCRIPTIONS="$SBM_VAR/subscriptions"
export SBM_SYSTEMD_DIR=/run/systemd/system SBM_SERVICE=sb-sing-box-subscription-smoke.service
export SBM_SUBSCRIPTION_SERVICE="$UNIT" SBM_SUBSCRIPTION_PORT="$PORT"
export SBM_SERVICE_USER=daemon SBM_INIT_SYSTEM=systemd SBM_INIT_SYSTEM_RESOLVED=systemd SBM_SKIP_INIT=0 NO_COLOR=1
export SBM_SING_BOX_BIN="${SBM_TEST_SING_BOX:?Set SBM_TEST_SING_BOX}"

mkdir -p "$SBM_LIB/libexec"
chmod 0755 "$ROOT" "$ROOT/usr" "$ROOT/usr/local" "$ROOT/usr/local/lib" "$SBM_LIB" "$SBM_LIB/libexec"
install -m 0755 "$PROJECT/libexec/subscription_server.py" "$SBM_LIB/libexec/subscription_server.py"

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
source "$PROJECT/lib/runtime-security.sh"
source "$PROJECT/lib/core.sh"
source "$PROJECT/lib/node.sh"
source "$PROJECT/lib/export.sh"
source "$PROJECT/lib/subscription.sh"

state_init
chown root:daemon "$SBM_VAR"
node_add ss --id subscription-systemd --port 28388 --address 192.0.2.1 >/dev/null
created=$(subscription_create 24h mixed)
token=$(sed -n "s#.*127\\.0\\.0\\.1:$PORT/sub/##p" <<<"$created")
[[ "$token" =~ ^[A-Za-z0-9_-]{32,128}$ ]]
systemctl is-active --quiet "$UNIT"
systemctl show "$UNIT" -p User | grep -Fx 'User=daemon'
systemctl show "$UNIT" -p NoNewPrivileges | grep -Fx 'NoNewPrivileges=yes'
systemctl show "$UNIT" -p ProtectSystem | grep -Fx 'ProtectSystem=strict'
ss -H -ltn | awk '{print $4}' | grep -Fxq "127.0.0.1:$PORT"
! ss -H -ltn | awk '{print $4}' | grep -Fxq "0.0.0.0:$PORT"

for _ in {1..30}; do
  if curl -fsS "http://127.0.0.1:$PORT/sub/$token" -o "$ROOT/fetched.json"; then break; fi
  sleep 0.2
done
digest=$(printf '%s' "$token" | sha256sum | awk '{print $1}')
cmp "$ROOT/fetched.json" "$SBM_SUBSCRIPTIONS/$digest.profile.json"
"$SBM_SING_BOX_BIN" check -c "$ROOT/fetched.json"
subscription_revoke "$token" >/dev/null
[[ $(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/sub/$token") == 404 ]]
subscription_reconcile 1
! systemctl is-active --quiet "$UNIT"
[[ ! -e "/run/systemd/system/$UNIT" ]]
printf 'SUBSCRIPTION SYSTEMD SMOKE PASSED\n'
