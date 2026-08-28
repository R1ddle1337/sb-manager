#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

export SBM_PREFIX="$ROOT/usr/local" SBM_LIB="$PROJECT" SBM_BIN_DIR="$ROOT/usr/local/bin"
export SBM_ETC="$ROOT/etc/sb-manager" SBM_VAR="$ROOT/var/lib/sb-manager" SBM_RUN="$ROOT/run/sb-manager"
export SBM_OPENRC_DIR="$ROOT/etc/init.d" SBM_LOG_DIR="$ROOT/var/log/sb-manager"
export SBM_NGINX_STREAM_BIN="$ROOT/bin/nginx"
export SBM_NGINX_STREAM_OPENRC_BIN="$ROOT/var/lib/sb-manager/nginx-stream/nginx"
export SBM_NGINX_STREAM_CONFIG="$SBM_ETC/nginx-stream.conf"
export SBM_NGINX_STREAM_RUNTIME_DIR="$ROOT/run/nginx-stream"
export SBM_NGINX_STREAM_PID="$SBM_NGINX_STREAM_RUNTIME_DIR/nginx.pid"
export SBM_SERVICE_USER=root SBM_SERVICE=sb-sing-box.service
export SBM_INIT_SYSTEM=openrc SBM_SKIP_INIT=0 SBM_SKIP_SYSTEMD=0
export SBM_FAKE_SETCAP_LOG="$ROOT/setcap.log" NO_COLOR=1

mkdir -p "$ROOT/bin"
cat >"$SBM_NGINX_STREAM_BIN" <<'EOF_NGINX'
#!/bin/sh
exit 0
EOF_NGINX
cat >"$ROOT/bin/setcap" <<'EOF_SETCAP'
#!/bin/sh
printf '%s\n' "$*" >>"$SBM_FAKE_SETCAP_LOG"
EOF_SETCAP
chmod 0755 "$SBM_NGINX_STREAM_BIN" "$ROOT/bin/setcap"
export PATH="$ROOT/bin:$PATH"

source "$PROJECT/lib/common.sh"
source "$PROJECT/lib/service.sh"
source "$PROJECT/lib/nginx_stream.sh"

nginx_stream_write_service openrc
service_file="$SBM_OPENRC_DIR/sb-nginx-stream"
[[ -x "$service_file" ]]
grep -q '^#!/sbin/openrc-run' "$service_file"
grep -Fq "command=\"$SBM_NGINX_STREAM_OPENRC_BIN\"" "$service_file"
grep -Fq "command_args=\"-c $SBM_NGINX_STREAM_CONFIG\"" "$service_file"
grep -Fq "command_args_foreground=\"-g 'daemon off;'\"" "$service_file"
grep -Fq 'need sb-sing-box' "$service_file"
grep -Fq "$SBM_NGINX_STREAM_RUNTIME_DIR" "$service_file"
[[ -x "$SBM_NGINX_STREAM_OPENRC_BIN" ]]
grep -Fq "cap_net_bind_service=+ep $SBM_NGINX_STREAM_OPENRC_BIN" "$SBM_FAKE_SETCAP_LOG"
mapfile -t logs < <(service_log_files "$SBM_NGINX_STREAM_SERVICE")
[[ "${logs[0]}" == "$SBM_NGINX_STREAM_LOG" && "${logs[1]}" == "$SBM_NGINX_STREAM_ERROR_LOG" ]]

printf 'OPENRC NGINX STREAM PASSED\n'
