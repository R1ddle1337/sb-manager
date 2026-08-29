#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export SBM_PREFIX="$ROOT/usr/local" SBM_LIB="$PROJECT" SBM_BIN_DIR="$ROOT/usr/local/bin"
export SBM_ETC="$ROOT/etc/sb-manager" SBM_VAR="$ROOT/var/lib/sb-manager" SBM_RUN="$ROOT/run/sb-manager"
export SBM_SECRETS="$SBM_ETC/secrets" SBM_CERTS="$SBM_ETC/certs" SBM_CORE_DIR="$ROOT/cores"
export SBM_STATE="$SBM_ETC/state.json" SBM_GENERATED_DIR="$SBM_ETC/generated" SBM_CONFIG="$SBM_ETC/generated/config.json"
export SBM_BACKUPS="$SBM_VAR/backups" SBM_EXPORTS="$SBM_VAR/exports" SBM_CACHE="$SBM_VAR/cache" SBM_LOCK="$SBM_RUN/manager.lock"
export SBM_SKIP_INIT=1 SBM_SKIP_SYSTEMD=1 SBM_SERVICE_USER=sbmanager NO_COLOR=1
export SBM_SING_BOX_BIN="${SBM_TEST_SING_BOX:?Set SBM_TEST_SING_BOX to official sing-box 1.14+}"

source "$PROJECT/lib/common.sh"
source "$PROJECT/lib/service.sh"
source "$PROJECT/lib/state.sh"
source "$PROJECT/protocols/hysteria2.sh"
source "$PROJECT/lib/render.sh"
source "$PROJECT/lib/core.sh"
source "$PROJECT/lib/node.sh"
source "$PROJECT/lib/export.sh"

version_ge "$(core_current_version)" 1.14.0-rc.1
state_init
mkdir -p "$SBM_CERTS/edge.example.com"
openssl req -x509 -newkey rsa:2048 -nodes -days 3 -subj '/CN=edge.example.com' \
  -keyout "$SBM_CERTS/edge.example.com/key.pem" -out "$SBM_CERTS/edge.example.com/fullchain.pem" >/dev/null 2>&1

node_add hy2 --id gecko-test --name 'Gecko test' --port 24543 --domain edge.example.com --address 192.0.2.1 \
  --obfs gecko --obfs-min-packet-size 600 --obfs-max-packet-size 1100 --disable-chrome-parrot \
  --bbr-profile aggressive --brutal-debug

jq -e '.nodes[0].obfs.type=="gecko" and .nodes[0].obfs.min_packet_size==600 and .nodes[0].obfs.max_packet_size==1100 and .nodes[0].disable_chrome_parrot==true and .nodes[0].bbr_profile=="aggressive" and .nodes[0].brutal_debug==true' "$SBM_STATE" >/dev/null
jq -e '.inbounds[0].obfs.type=="gecko" and .inbounds[0].obfs.min_packet_size==600 and .inbounds[0].obfs.max_packet_size==1100 and .inbounds[0].bbr_profile=="aggressive" and .inbounds[0].brutal_debug==true' "$SBM_CONFIG" >/dev/null
node_client_outbound gecko-test | jq -e '.obfs.type=="gecko" and .obfs.min_packet_size==600 and .obfs.max_packet_size==1100 and .disable_chrome_parrot==true and .bbr_profile=="aggressive" and .brutal_debug==true' >/dev/null
"$SBM_SING_BOX_BIN" check -c "$SBM_CONFIG"

settings_set_dns optimistic true
settings_set_dns optimistic-timeout 2d
settings_set_dns timeout 5s
jq -e '.dns.optimistic.enabled==true and .dns.optimistic.timeout=="2d" and .dns.timeout=="5s"' "$SBM_CONFIG" >/dev/null
"$SBM_SING_BOX_BIN" check -c "$SBM_CONFIG"

client_ob=$(node_client_outbound gecko-test)
jq -n --argjson ob "$client_ob" \
  '{log:{level:"error"},inbounds:[{type:"mixed",listen:"127.0.0.1",listen_port:20880}],outbounds:[$ob],route:{final:$ob.tag}}' >"$ROOT/client.json"
"$SBM_SING_BOX_BIN" check -c "$ROOT/client.json"

core_schema "$ROOT/schema.json"
jq -e '.properties.inbounds and .properties.outbounds' "$ROOT/schema.json" >/dev/null
core_capabilities 1 >"$ROOT/capabilities.json"
jq -e '.version=="1.14.0-rc.2" and .features.quic==true and .features.openvpn==true and .features.openconnect==true' "$ROOT/capabilities.json" >/dev/null
export_client_config "$ROOT/tun-dns.json" tun hijack 192.0.2.53
jq -e '.inbounds[0].dns_mode=="hijack" and .inbounds[0].dns_address==["192.0.2.53"]' "$ROOT/tun-dns.json" >/dev/null
printf 'HYSTERIA 1.14 PREVIEW SMOKE PASSED\n'
