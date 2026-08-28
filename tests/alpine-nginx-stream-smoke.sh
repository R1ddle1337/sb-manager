#!/usr/bin/env bash
set -Eeuo pipefail

[[ -f /etc/alpine-release ]] || { echo 'This test must run on Alpine.' >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'This test must run as root.' >&2; exit 1; }
apk add --no-cache bash jq openrc libcap coreutils >/dev/null

ROOT=$(mktemp -d)
cleanup() {
  kill "${nginx_pid:-}" 2>/dev/null || true
  wait "${nginx_pid:-}" 2>/dev/null || true
  rm -rf "$ROOT"
}
trap cleanup EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

export SBM_PREFIX="$ROOT/usr/local" SBM_LIB="$PROJECT" SBM_BIN_DIR="$ROOT/usr/local/bin"
export SBM_ETC="$ROOT/etc/sb-manager" SBM_VAR="$ROOT/var/lib/sb-manager" SBM_RUN="$ROOT/run/sb-manager"
export SBM_OPENRC_DIR="$ROOT/etc/init.d" SBM_LOG_DIR="$ROOT/var/log/sb-manager"
export SBM_STATE="$SBM_ETC/state.json" SBM_GENERATED_DIR="$SBM_ETC/generated"
export SBM_CONFIG="$SBM_GENERATED_DIR/config.json" SBM_SECRETS="$SBM_ETC/secrets"
export SBM_CERTS="$SBM_ETC/certs" SBM_BACKUPS="$SBM_VAR/backups"
export SBM_EXPORTS="$SBM_VAR/exports" SBM_CACHE="$SBM_VAR/cache"
export SBM_LOCK="$SBM_RUN/manager.lock" SBM_SERVICE_USER=root
export SBM_INIT_SYSTEM=openrc SBM_SKIP_INIT=0 SBM_SKIP_SYSTEMD=0 NO_COLOR=1
export SBM_NGINX_STREAM_BIN=/usr/sbin/nginx
export SBM_NGINX_STREAM_MODULE=/usr/lib/nginx/modules/ngx_stream_module.so
export SBM_NGINX_STREAM_OPENRC_BIN="$SBM_VAR/nginx-stream/nginx"
export SBM_NGINX_STREAM_CONFIG="$SBM_ETC/nginx-stream.conf"
export SBM_NGINX_STREAM_RUNTIME_DIR="$ROOT/run/nginx-stream"
export SBM_NGINX_STREAM_PID="$SBM_NGINX_STREAM_RUNTIME_DIR/nginx.pid"

source "$PROJECT/lib/common.sh"
source "$PROJECT/lib/service.sh"
source "$PROJECT/lib/state.sh"
source "$PROJECT/lib/nginx_stream.sh"

nginx_stream_install_dependencies
nginx_stream_runtime_ready
state_init
jq --arg now "$(now_iso)" '
  .nodes=[{
    id:"alpine-trojan",name:"Alpine Trojan",protocol:"trojan",enabled:true,
    listen:"::",port:24443,domain:"trojan.alpine.example.com",
    server_address:"127.0.0.1",created_at:$now,
    users:[{id:"default",name:"Alpine Trojan",enabled:true,created_at:$now}]
  }]
  | .nginx_stream={
      enabled:true,listen:"::",port:18443,
      routes:[{node_id:"alpine-trojan",sni:"trojan.alpine.example.com",backend_port:25443}]
    }
' "$SBM_STATE" >"$SBM_STATE.new"
mv -f "$SBM_STATE.new" "$SBM_STATE"

nginx_stream_render_config "$SBM_STATE" "$SBM_NGINX_STREAM_CONFIG"
nginx_stream_test_config "$SBM_NGINX_STREAM_CONFIG"
nginx_stream_write_service openrc
[[ -x "$SBM_OPENRC_DIR/sb-nginx-stream" ]]
grep -Fq "command=\"$SBM_NGINX_STREAM_OPENRC_BIN\"" "$SBM_OPENRC_DIR/sb-nginx-stream"
grep -Fq "$SBM_NGINX_STREAM_RUNTIME_DIR" "$SBM_OPENRC_DIR/sb-nginx-stream"
getcap "$SBM_NGINX_STREAM_OPENRC_BIN" | grep -q cap_net_bind_service

mkdir -p "$SBM_NGINX_STREAM_RUNTIME_DIR"
"$SBM_NGINX_STREAM_OPENRC_BIN" -c "$SBM_NGINX_STREAM_CONFIG" -g 'daemon off;' >"$ROOT/nginx.log" 2>&1 &
nginx_pid=$!
for _ in 1 2 3 4 5; do
  kill -0 "$nginx_pid" 2>/dev/null || { cat "$ROOT/nginx.log" >&2; exit 1; }
  sleep 0.2
done

printf 'ALPINE NGINX STREAM PASSED (%s)\n' "$(cat /etc/alpine-release)"
