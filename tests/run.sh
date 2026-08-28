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
export SBM_SYSTEMD_DIR="$ROOT/etc/systemd/system"
export SBM_STATE="$SBM_ETC/state.json"
export SBM_GENERATED_DIR="$SBM_ETC/generated"
export SBM_CONFIG="$SBM_GENERATED_DIR/config.json"
export SBM_SECRETS="$SBM_ETC/secrets"
export SBM_CERTS="$SBM_ETC/certs"
export SBM_BACKUPS="$SBM_VAR/backups"
export SBM_EXPORTS="$SBM_VAR/exports"
export SBM_CACHE="$SBM_VAR/cache"
export SBM_CORE_DIR="$ROOT/cores"
export SBM_SING_BOX_BIN="${SBM_TEST_SING_BOX:?Set SBM_TEST_SING_BOX}"
export SBM_CLOUDFLARED_BIN="$ROOT/bin/cloudflared"
export SBM_LOCK="$SBM_RUN/manager.lock"
export SBM_SKIP_INIT=1 SBM_SKIP_SYSTEMD=1
export NO_COLOR=1

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
source "$PROJECT/lib/render.sh"
source "$PROJECT/lib/core.sh"
source "$PROJECT/lib/node.sh"
source "$PROJECT/lib/export.sh"
source "$PROJECT/lib/cert.sh"
source "$PROJECT/lib/tunnel.sh"
source "$PROJECT/lib/backup.sh"

state_init
mkdir -p "$SBM_CERTS/edge.example.com"
openssl req -x509 -newkey rsa:2048 -nodes -days 3 -subj '/CN=edge.example.com' \
  -keyout "$SBM_CERTS/edge.example.com/key.pem" -out "$SBM_CERTS/edge.example.com/fullchain.pem" >/dev/null 2>&1

node_add vmess --id vm-test --name 'VM test' --port 29001 --domain cdn.example.com --address cdn.example.com
node_add ss --id ss-test --name 'SS test' --port 28388 --address 192.0.2.1
node_add anytls --id any-test --name 'Any test' --port 24443 --domain edge.example.com
node_add hy2 --id hy2-test --name 'HY2 test' --port 24443 --domain edge.example.com --address 192.0.2.1 --obfs salamander --masquerade https://example.com
node_user_add ss-test alice 'Alice SS'
node_user_add any-test alice 'Alice AnyTLS'

[[ $(jq '.nodes|length' "$SBM_STATE") == 4 ]]
[[ $(jq -r '.nodes[]|select(.id=="ss-test")|.method' "$SBM_STATE") == 2022-blake3-aes-256-gcm ]]
[[ $(jq '.inbounds|length' "$SBM_CONFIG") == 4 ]]
[[ $(jq '.nodes[]|select(.id=="ss-test")|.users|length' "$SBM_STATE") == 2 ]]
[[ $(jq -r '.nodes[]|select(.id=="any-test")|.server_address' "$SBM_STATE") == edge.example.com ]]
jq -e '.inbounds[]|select(.tag=="in-ss-test")|(.users|length)==2' "$SBM_CONFIG" >/dev/null
jq -e '.inbounds[]|select(.tag=="in-any-test")|(.users|length)==2' "$SBM_CONFIG" >/dev/null
"$SBM_SING_BOX_BIN" check -c "$SBM_CONFIG"
jq -e '.dns.strategy=="prefer_ipv4" and .route.default_domain_resolver=="dns-local"' "$SBM_CONFIG" >/dev/null

# Global client DNS/outbound address selection follows the configured strategy.
settings_set_outbound_ip_strategy prefer_ipv6 >/dev/null
jq -e '.dns.strategy=="prefer_ipv6"' "$SBM_CONFIG" >/dev/null
export_client_config "$ROOT/client-prefer-ipv6.json" mixed >/dev/null
jq -e '.dns.strategy=="prefer_ipv6"' "$ROOT/client-prefer-ipv6.json" >/dev/null
settings_set_outbound_ip_strategy ipv4_only >/dev/null
jq -e '.dns.strategy=="ipv4_only"' "$SBM_CONFIG" >/dev/null
export_client_config "$ROOT/client-ipv4-only.json" mixed >/dev/null
jq -e '.dns.strategy=="ipv4_only"' "$ROOT/client-ipv4-only.json" >/dev/null
settings_set_outbound_ip_strategy prefer_ipv4 >/dev/null

# Start the real core once and verify that all four listeners can coexist.
"$SBM_SING_BOX_BIN" run -c "$SBM_CONFIG" >"$ROOT/runtime.log" 2>&1 &
runtime_pid=$!
for _ in {1..30}; do kill -0 "$runtime_pid" 2>/dev/null || { cat "$ROOT/runtime.log" >&2; exit 1; }; sleep 0.1; done
ss -H -ltn | grep -Eq ':29001\b'
ss -H -ltn | grep -Eq ':28388\b'
ss -H -ltn | grep -Eq ':24443\b'
ss -H -lun | grep -Eq ':24443\b'
kill "$runtime_pid"; wait "$runtime_pid" 2>/dev/null || true

node_share_uri vm-test | grep -q '^vmess://'
node_share_uri ss-test | grep -q '^ss://'
node_share_uri any-test | grep -q '^anytls://.*fp=chrome'
node_share_uri hy2-test | grep -q '^hysteria2://'
node_client_outbound vm-test | jq -e '.type=="vmess"' >/dev/null
node_client_outbound ss-test | jq -e '.type=="shadowsocks"' >/dev/null
node_client_outbound any-test | jq -e '.type=="anytls" and .tls.utls.enabled==true and .tls.utls.fingerprint=="chrome"' >/dev/null
node_client_outbound hy2-test | jq -e '.type=="hysteria2"' >/dev/null

# Validate every generated client outbound with the real core.
for id in vm-test ss-test any-test hy2-test; do
  ob=$(node_client_outbound "$id")
  cfg="$ROOT/client-$id.json"
  jq -n --argjson ob "$ob" '{log:{level:"error"},inbounds:[{type:"mixed",tag:"mixed-in",listen:"127.0.0.1",listen_port:20800}],outbounds:[$ob],route:{final:$ob.tag}}' >"$cfg"
  "$SBM_SING_BOX_BIN" check -c "$cfg"
done
node_client_outbound ss-test alice | jq -e '.type=="shadowsocks" and (.password|contains(":"))' >/dev/null
node_client_outbound any-test alice | jq -e '.type=="anytls" and .tls.utls.enabled==true and .tls.utls.fingerprint=="chrome"' >/dev/null

# Fixed Tunnel token stays in a protected file and never appears in the unit.
tunnel_setup_fixed vm-test cdn.example.com test-tunnel-token cdn.example.com
grep -q -- "--token-file" "$SBM_SYSTEMD_DIR/$SBM_TUNNEL_SERVICE"
! grep -q "test-tunnel-token" "$SBM_SYSTEMD_DIR/$SBM_TUNNEL_SERVICE"
[[ $(stat -c %a "$SBM_TUNNEL_TOKEN_FILE") == 640 ]]
tunnel_stop

node_disable ss-test
[[ $(jq -r '.nodes[]|select(.id=="ss-test")|.enabled' "$SBM_STATE") == false ]]
node_enable ss-test
node_set ss-test --port 28389 --name 'SS edited'
[[ $(jq -r '.nodes[]|select(.id=="ss-test")|.port' "$SBM_STATE") == 28389 ]]

# Invalid candidate must be rejected without changing the installed state.
bad=$(state_candidate)
jq '(.nodes[]|select(.id=="ss-test")|.method)="invalid-method"' "$SBM_STATE" >"$bad"
if (apply_candidate_state "$bad" invalid-test >/dev/null 2>&1); then echo 'invalid config unexpectedly accepted' >&2; exit 1; fi
rm -f "$bad"
[[ $(jq -r '.nodes[]|select(.id=="ss-test")|.method' "$SBM_STATE") == 2022-blake3-aes-256-gcm ]]

# Backup and restore round-trip.
backup="$ROOT/test-backup.tar.gz"
backup_create "$backup" >/dev/null
node_set ss-test --name 'Temporary name'
backup_restore "$backup" 1 >/dev/null
[[ $(jq -r '.nodes[]|select(.id=="ss-test")|.name' "$SBM_STATE") == 'SS edited' ]]
old=$(jq -r '.password' "$(state_user_secret_path ss-test default)")
node_rotate ss-test
new=$(jq -r '.password' "$(state_user_secret_path ss-test default)")
[[ "$old" != "$new" ]]
node_delete ss-test
! state_node_exists ss-test

# All offered Shadowsocks 2022 methods must render with correctly sized keys.
node_add ss --id ss256-test --port 28390 --address 192.0.2.1 --method 2022-blake3-aes-256-gcm
node_delete ss256-test
node_add ss --id sschacha-test --port 28391 --address 192.0.2.1 --method 2022-blake3-chacha20-poly1305
node_delete sschacha-test

# TCP 443 + UDP 443 is legal; duplicate TCP is not.
node_add ss --id conflict-test --port 24443 --address 192.0.2.1 --disabled
if (node_enable conflict-test >/dev/null 2>&1); then echo 'expected TCP conflict rejection' >&2; exit 1; fi

jq -e '.schema_version==2' "$SBM_STATE" >/dev/null
printf 'ALL TESTS PASSED\n'
