#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export SBM_PREFIX="$ROOT/usr/local" SBM_LIB="$PROJECT" SBM_BIN_DIR="$ROOT/usr/local/bin"
export SBM_ETC="$ROOT/etc/sb-manager" SBM_VAR="$ROOT/var/lib/sb-manager" SBM_RUN="$ROOT/run/sb-manager"
export SBM_STATE="$SBM_ETC/state.json" SBM_GENERATED_DIR="$SBM_ETC/generated"
export SBM_CONFIG="$SBM_GENERATED_DIR/config.json"
export SBM_SECRETS="$SBM_ETC/secrets" SBM_CERTS="$SBM_ETC/certs" SBM_BACKUPS="$SBM_VAR/backups" SBM_EXPORTS="$SBM_VAR/exports" SBM_CACHE="$SBM_VAR/cache" SBM_CORE_DIR="$ROOT/cores"
export SBM_LOCK="$SBM_RUN/manager.lock" SBM_SKIP_INIT=1 SBM_SKIP_SYSTEMD=1 SBM_SERVICE_USER=sbmanager NO_COLOR=1
export SBM_SING_BOX_BIN="${SBM_TEST_SING_BOX:?Set SBM_TEST_SING_BOX}"

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
source "$PROJECT/lib/export.sh"

state_init
mkdir -p "$SBM_CERTS/edge.example.com"
openssl req -x509 -newkey rsa:2048 -nodes -days 3 -subj '/CN=edge.example.com' \
  -keyout "$SBM_CERTS/edge.example.com/key.pem" -out "$SBM_CERTS/edge.example.com/fullchain.pem" >/dev/null 2>&1

node_add trojan --id trojan-test --port 24444 --domain edge.example.com --address 192.0.2.1
node_add tuic --id tuic-test --port 24444 --domain edge.example.com --address 192.0.2.1
node_add vless --id vless-test --port 24445 --domain edge.example.com --address 192.0.2.1 --security tls
jq '.settings.public_ipv4="198.51.100.20"' "$SBM_STATE" >"$ROOT/state.new"; mv "$ROOT/state.new" "$SBM_STATE"
node_add vless --id reality-test --port 24446 --domain www.microsoft.com --security reality --handshake-server www.microsoft.com
node_add naive --id naive-test --port 24447 --domain edge.example.com --address 192.0.2.1 --network tcp
node_add shadowtls --id shadowtls-test --port 24448 --handshake-server www.microsoft.com

[[ $(jq '.nodes|length' "$SBM_STATE") == 6 ]]
[[ $(jq -r '.nodes[]|select(.id=="reality-test")|.server_address' "$SBM_STATE") == 198.51.100.20 ]]
[[ $(jq -r '.nodes[]|select(.id=="shadowtls-test")|.server_address' "$SBM_STATE") == 198.51.100.20 ]]
[[ $(jq '.inbounds|length' "$SBM_CONFIG") == 6 ]]
"$SBM_SING_BOX_BIN" check -c "$SBM_CONFIG"

"$SBM_SING_BOX_BIN" run -c "$SBM_CONFIG" >"$ROOT/runtime.log" 2>&1 &
runtime_pid=$!
for _ in {1..30}; do kill -0 "$runtime_pid" 2>/dev/null || { cat "$ROOT/runtime.log" >&2; exit 1; }; sleep 0.1; done
for port in 24444 24445 24446 24447 24448; do ss -H -ltn | grep -Eq ":${port}\\b"; done
ss -H -lun | grep -Eq ':24444\b'
kill "$runtime_pid"; wait "$runtime_pid" 2>/dev/null || true

for id in trojan-test tuic-test vless-test reality-test naive-test shadowtls-test; do
  node_share_uri "$id" | grep -Eq '^(trojan|tuic|vless|naive\+https|shadowtls)://'
  node_client_outbound "$id" | jq -e --arg id "$id" '.tag == ("proxy-" + $id + "-default")' >/dev/null
done

for id in trojan-test tuic-test vless-test reality-test naive-test shadowtls-test; do
  ob=$(node_client_outbound "$id")
  cfg="$ROOT/client-$id.json"
  jq -n --argjson ob "$ob" --argjson port "$((20800 + RANDOM % 1000))" \
    '{log:{level:"error"},inbounds:[{type:"mixed",tag:"mixed-in",listen:"127.0.0.1",listen_port:$port}],outbounds:[$ob],route:{final:$ob.tag}}' >"$cfg"
  "$SBM_SING_BOX_BIN" check -c "$cfg"
done

[[ $(jq -r '.inbounds[]|select(.tag=="in-tuic-test")|.zero_rtt_handshake' "$SBM_CONFIG") == false ]]
[[ $(jq -r '.inbounds[]|select(.tag=="in-reality-test")|.tls.reality.enabled' "$SBM_CONFIG") == true ]]
export_client_config "$ROOT/client-mixed.json" mixed
export_client_config "$ROOT/client-tun.json" tun
jq -e '.inbounds[0].type=="mixed" and .route.default_domain_resolver=="dns-local"' "$ROOT/client-mixed.json" >/dev/null
jq -e '.inbounds[0].type=="tun" and (.route.rules[]|select(.action=="hijack-dns"))' "$ROOT/client-tun.json" >/dev/null
printf 'PROTOCOL SUITE SMOKE PASSED\n'
