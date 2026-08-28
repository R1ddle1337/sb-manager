#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export SBM_PREFIX="$ROOT/usr/local" SBM_LIB="$PROJECT" SBM_BIN_DIR="$ROOT/usr/local/bin"
export SBM_ETC="$ROOT/etc/sb-manager" SBM_VAR="$ROOT/var/lib/sb-manager" SBM_RUN="$ROOT/run/sb-manager"
export SBM_GENERATED_DIR="$SBM_ETC/generated" SBM_STATE="$SBM_ETC/state.json" SBM_CONFIG="$SBM_ETC/generated/config.json"
export SBM_SECRETS="$SBM_ETC/secrets" SBM_CERTS="$SBM_ETC/certs" SBM_BACKUPS="$SBM_VAR/backups" SBM_EXPORTS="$SBM_VAR/exports" SBM_CACHE="$SBM_VAR/cache"
export SBM_CORE_DIR="$ROOT/cores" SBM_LOCK="$SBM_RUN/manager.lock" SBM_SKIP_INIT=1 SBM_SKIP_SYSTEMD=1 SBM_SERVICE_USER=sbmanager NO_COLOR=1
export SBM_SING_BOX_BIN="${SBM_TEST_SING_BOX:?Set SBM_TEST_SING_BOX}"
export SBM_NGINX_STREAM_BIN=${SBM_NGINX_STREAM_BIN:-/usr/sbin/nginx}
export SBM_NGINX_STREAM_MODULE=${SBM_NGINX_STREAM_MODULE:-/usr/lib/nginx/modules/ngx_stream_module.so}
export SBM_NGINX_STREAM_RUNTIME_DIR="$ROOT/run/nginx-stream" SBM_NGINX_STREAM_PID="$ROOT/run/nginx-stream/nginx.pid"
export SBM_NGINX_STREAM_CONFIG="$ROOT/etc/sb-manager/nginx-stream.conf"

source "$PROJECT/lib/common.sh"
source "$PROJECT/lib/service.sh"
source "$PROJECT/lib/state.sh"
source "$PROJECT/lib/nginx_stream.sh"
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
source "$PROJECT/lib/export.sh"

[[ -x "$SBM_NGINX_STREAM_BIN" ]]
[[ -f "$SBM_NGINX_STREAM_MODULE" ]]
state_init
for domain in trojan.example.com vless.example.com anytls.example.com naive.example.com; do
  mkdir -p "$SBM_CERTS/$domain"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3 -subj "/CN=$domain" \
    -addext "subjectAltName=DNS:$domain" -keyout "$SBM_CERTS/$domain/key.pem" \
    -out "$SBM_CERTS/$domain/fullchain.pem" >/dev/null 2>&1
done

node_add trojan --id trojan-mux --port 24451 --domain trojan.example.com --address 127.0.0.1
node_add vless --id vless-mux --port 24452 --domain vless.example.com --address 127.0.0.1 --security tls
node_add anytls --id anytls-mux --port 24453 --domain anytls.example.com --address 127.0.0.1
node_add naive --id naive-mux --port 24454 --domain naive.example.com --address 127.0.0.1 --network tcp
node_add vless --id reality-mux --port 24455 --domain www.microsoft.com --address 127.0.0.1 --security reality --handshake-server www.microsoft.com
node_add shadowtls --id shadowtls-mux --port 24456 --address 127.0.0.1 --handshake-server www.apple.com
nginx_stream_route_add trojan-mux trojan.example.com 25451
nginx_stream_route_add vless-mux vless.example.com 25452
nginx_stream_route_add anytls-mux anytls.example.com 25453
nginx_stream_route_add naive-mux naive.example.com 25454
nginx_stream_route_add reality-mux www.microsoft.com 25455
nginx_stream_route_add shadowtls-mux www.apple.com 25456
nginx_stream_enable 18443

jq -e '.nginx_stream.enabled and (.nginx_stream.routes|length)==6' "$SBM_STATE" >/dev/null
jq -e '.inbounds[]|select(.tag=="in-trojan-mux")|.listen=="127.0.0.1" and .listen_port==25451' "$SBM_CONFIG" >/dev/null
jq -e '.inbounds[]|select(.tag=="in-vless-mux")|.listen=="127.0.0.1" and .listen_port==25452' "$SBM_CONFIG" >/dev/null
[[ $(node_share_uri trojan-mux) == *'@127.0.0.1:18443?'* ]]
[[ $(node_share_uri vless-mux) == *'@127.0.0.1:18443?'* ]]

nginx_stream_render_config "$SBM_STATE" "$SBM_NGINX_STREAM_CONFIG"
nginx_stream_test_config "$SBM_NGINX_STREAM_CONFIG"
grep -q 'trojan.example.com sbm_stream_trojan_mux;' "$SBM_NGINX_STREAM_CONFIG"
grep -q 'vless.example.com sbm_stream_vless_mux;' "$SBM_NGINX_STREAM_CONFIG"
grep -q 'anytls.example.com sbm_stream_anytls_mux;' "$SBM_NGINX_STREAM_CONFIG"
grep -q 'naive.example.com sbm_stream_naive_mux;' "$SBM_NGINX_STREAM_CONFIG"
grep -q 'www.microsoft.com sbm_stream_reality_mux;' "$SBM_NGINX_STREAM_CONFIG"
grep -q 'www.apple.com sbm_stream_shadowtls_mux;' "$SBM_NGINX_STREAM_CONFIG"

"$SBM_SING_BOX_BIN" run -c "$SBM_CONFIG" >"$ROOT/sing-box.log" 2>&1 &
sb_pid=$!
"$SBM_NGINX_STREAM_BIN" -c "$SBM_NGINX_STREAM_CONFIG" -g 'daemon off;' >"$ROOT/nginx.log" 2>&1 &
nginx_pid=$!
cleanup_processes() { kill "$nginx_pid" "$sb_pid" 2>/dev/null || true; wait "$nginx_pid" "$sb_pid" 2>/dev/null || true; }
trap 'cleanup_processes; rm -rf "$ROOT"' EXIT
for _ in {1..50}; do
  kill -0 "$sb_pid" 2>/dev/null && kill -0 "$nginx_pid" 2>/dev/null || { cat "$ROOT/sing-box.log" "$ROOT/nginx.log" >&2; exit 1; }
  ss -H -ltn | grep -Eq ':18443\b' && break
  sleep 0.1
done
for domain in trojan.example.com vless.example.com anytls.example.com naive.example.com; do
  cert=$(timeout 5 openssl s_client -connect 127.0.0.1:18443 -servername "$domain" -showcerts </dev/null 2>/dev/null | openssl x509 -noout -subject)
  grep -Eq "CN[[:space:]]*=[[:space:]]*$domain" <<<"$cert"
done
for domain in www.microsoft.com www.apple.com; do
  cert=$(timeout 8 openssl s_client -connect 127.0.0.1:18443 -servername "$domain" -showcerts </dev/null 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || true)
  [[ -n "$cert" ]]
done
unknown_cert=$(timeout 4 openssl s_client -connect 127.0.0.1:18443 -servername unknown.example.com -showcerts </dev/null 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || true)
if [[ -n "$unknown_cert" ]]; then
  echo 'unknown SNI unexpectedly reached a backend' >&2
  exit 1
fi
cleanup_processes
trap 'rm -rf "$ROOT"' EXIT

nginx_stream_disable
jq -e '.nginx_stream.enabled==false' "$SBM_STATE" >/dev/null
jq -e '.inbounds[]|select(.tag=="in-trojan-mux")|.listen=="::" and .listen_port==24451' "$SBM_CONFIG" >/dev/null
printf 'NGINX STREAM SMOKE PASSED\n'
