#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="/opt/sbmanager-nginx-systemd-smoke.$$"
mkdir -p "$ROOT"
chmod 0755 "$ROOT"
DUMMY_UNIT="sb-nginx-stream-smoke-$$.service"
MUX_UNIT="sb-nginx-stream-smoke-mux-$$.service"
cleanup() {
  set +e
  systemctl disable --now "$MUX_UNIT" >/dev/null 2>&1 || true
  systemctl disable --now "$DUMMY_UNIT" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/$MUX_UNIT" "/etc/systemd/system/$DUMMY_UNIT"
  systemctl daemon-reload >/dev/null 2>&1 || true
  kill "${nginx_pid:-}" "${sb_pid:-}" 2>/dev/null || true
  wait "${nginx_pid:-}" "${sb_pid:-}" 2>/dev/null || true
  rm -rf "$ROOT"
}
trap cleanup EXIT

PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export SBM_PREFIX="$ROOT/usr/local" SBM_LIB=/usr/local/lib/sb-manager SBM_BIN_DIR="$ROOT/usr/local/bin"
export SBM_ETC="$ROOT/etc/sb-manager" SBM_VAR="$ROOT/var/lib/sb-manager" SBM_RUN="$ROOT/run/sb-manager"
export SBM_GENERATED_DIR="$SBM_ETC/generated" SBM_STATE="$SBM_ETC/state.json" SBM_CONFIG="$SBM_ETC/generated/config.json"
export SBM_SECRETS="$SBM_ETC/secrets" SBM_CERTS="$SBM_ETC/certs" SBM_BACKUPS="$SBM_VAR/backups" SBM_EXPORTS="$SBM_VAR/exports" SBM_CACHE="$SBM_VAR/cache"
export SBM_LOCK="$SBM_RUN/manager.lock" SBM_SERVICE_USER=sbmanager SBM_SERVICE="$DUMMY_UNIT" SBM_NGINX_STREAM_SERVICE="$MUX_UNIT"
export SBM_SYSTEMD_DIR=/etc/systemd/system SBM_NGINX_STREAM_CONFIG="$SBM_ETC/nginx-stream.conf"
export SBM_NGINX_STREAM_RUNTIME_DIR=/run/sb-manager-nginx SBM_NGINX_STREAM_PID=/run/sb-manager-nginx/nginx.pid
export SBM_NGINX_STREAM_BIN=${SBM_NGINX_STREAM_BIN:-/usr/sbin/nginx}
export SBM_NGINX_STREAM_MODULE=${SBM_NGINX_STREAM_MODULE:-/usr/lib/nginx/modules/ngx_stream_module.so}
export SBM_SING_BOX_BIN="${SBM_TEST_SING_BOX:?Set SBM_TEST_SING_BOX}"
export SBM_SKIP_INIT=0 SBM_SKIP_SYSTEMD=0 SBM_INIT_SYSTEM=systemd NO_COLOR=1

cat >"/etc/systemd/system/$DUMMY_UNIT" <<EOF_UNIT
[Unit]
Description=sb-manager Nginx Stream smoke dependency

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true

[Install]
WantedBy=multi-user.target
EOF_UNIT
systemctl daemon-reload
systemctl start "$DUMMY_UNIT"

source "$PROJECT/lib/common.sh"
source "$PROJECT/lib/service.sh"
source "$PROJECT/lib/state.sh"
source "$PROJECT/lib/nginx_stream.sh"
source "$PROJECT/protocols/trojan.sh"
source "$PROJECT/protocols/vless.sh"
source "$PROJECT/lib/render.sh"
source "$PROJECT/lib/core.sh"
source "$PROJECT/lib/node.sh"
source "$PROJECT/lib/export.sh"

state_init
chown root:sbmanager "$SBM_ETC" "$SBM_GENERATED_DIR" "$SBM_CERTS" "$SBM_VAR"
chmod 0750 "$SBM_ETC" "$SBM_GENERATED_DIR" "$SBM_CERTS" "$SBM_VAR"
for domain in trojan-smoke.example.com vless-smoke.example.com; do
  mkdir -p "$SBM_CERTS/$domain"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3 -subj "/CN=$domain" \
    -addext "subjectAltName=DNS:$domain" -keyout "$SBM_CERTS/$domain/key.pem" \
    -out "$SBM_CERTS/$domain/fullchain.pem" >/dev/null 2>&1
done
node_add trojan --id trojan-smoke --port 24461 --domain trojan-smoke.example.com --address 127.0.0.1
node_add vless --id vless-smoke --port 24462 --domain vless-smoke.example.com --address 127.0.0.1 --security tls
nginx_stream_route_add trojan-smoke trojan-smoke.example.com 25461
nginx_stream_route_add vless-smoke vless-smoke.example.com 25462
real_nginx=$SBM_NGINX_STREAM_BIN
SBM_NGINX_STREAM_BIN=/bin/false
if nginx_stream_enable 18461 >/dev/null 2>&1; then
  echo 'expected Nginx activation failure' >&2
  exit 1
fi
SBM_NGINX_STREAM_BIN=$real_nginx
jq -e '.nginx_stream.enabled==false' "$SBM_STATE" >/dev/null
jq -e '.inbounds[]|select(.tag=="in-trojan-smoke")|.listen=="::" and .listen_port==24461' "$SBM_CONFIG" >/dev/null
nginx_stream_enable 18461

"$SBM_SING_BOX_BIN" run -c "$SBM_CONFIG" >"$ROOT/sing-box.log" 2>&1 &
sb_pid=$!
for _ in {1..50}; do kill -0 "$sb_pid" 2>/dev/null || { cat "$ROOT/sing-box.log" >&2; exit 1; }; ss -H -ltn | grep -Eq ':25461\b' && break; sleep 0.1; done
nginx_stream_reconcile
systemctl is-active --quiet "$MUX_UNIT"
systemctl is-enabled --quiet "$MUX_UNIT"
for domain in trojan-smoke.example.com vless-smoke.example.com; do
  cert=$(timeout 5 openssl s_client -connect 127.0.0.1:18461 -servername "$domain" -showcerts </dev/null 2>/dev/null | openssl x509 -noout -subject)
  grep -Eq "CN[[:space:]]*=[[:space:]]*$domain" <<<"$cert"
done
systemctl restart "$MUX_UNIT"
systemctl is-active --quiet "$MUX_UNIT"
nginx_stream_disable
! systemctl is-active --quiet "$MUX_UNIT"
printf 'NGINX STREAM SYSTEMD SMOKE PASSED\n'
