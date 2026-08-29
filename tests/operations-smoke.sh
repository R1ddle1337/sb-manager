#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

export SBM_PREFIX="$ROOT/usr/local" SBM_LIB="$PROJECT" SBM_BIN_DIR="$ROOT/usr/local/bin"
export SBM_ETC="$ROOT/etc/sb-manager" SBM_VAR="$ROOT/var/lib/sb-manager" SBM_RUN="$ROOT/run/sb-manager"
export SBM_STATE="$ROOT/etc/sb-manager/state.json" SBM_GENERATED_DIR="$ROOT/etc/sb-manager/generated"
export SBM_CONFIG="$ROOT/etc/sb-manager/generated/config.json" SBM_SECRETS="$ROOT/etc/sb-manager/secrets"
export SBM_CERTS="$ROOT/etc/sb-manager/certs" SBM_BACKUPS="$ROOT/var/lib/sb-manager/backups"
export SBM_EXPORTS="$ROOT/var/lib/sb-manager/exports" SBM_CACHE="$ROOT/var/lib/sb-manager/cache" SBM_CORE_DIR="$ROOT/cores"
export SBM_LOCK="$ROOT/run/sb-manager/manager.lock" SBM_SING_BOX_BIN=/bin/true SBM_CLOUDFLARED_BIN=/bin/false
export SBM_SKIP_INIT=1 SBM_TEST_MODE=1 NO_COLOR=1 SBM_SERVICE_USER
SBM_SERVICE_USER=$(id -un)

mkdir -p "$ROOT/bin"
cat >"$ROOT/bin/notification-sender" <<'EOF_SENDER'
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$SBM_TEST_NOTIFICATION_LOG"
EOF_SENDER
chmod 0755 "$ROOT/bin/notification-sender"
export SBM_NOTIFICATION_SENDER="$ROOT/bin/notification-sender"
export SBM_TEST_NOTIFICATION_LOG="$ROOT/notifications.log"

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
source "$PROJECT/protocols/snell.sh"
source "$PROJECT/lib/render.sh"
source "$PROJECT/lib/core.sh"
source "$PROJECT/lib/node.sh"
source "$PROJECT/lib/traffic.sh"
source "$PROJECT/lib/firewall.sh"
source "$PROJECT/lib/notification.sh"
source "$PROJECT/lib/health.sh"
source "$PROJECT/lib/status.sh"
source "$PROJECT/lib/config.sh"
source "$PROJECT/lib/template.sh"
export SBM_ASSUME_YES=1

state_init
jq -e '.notifications=={enabled:false,provider:"none",traffic_thresholds:[80,90,100]}
  and .health.enabled==false and .health.certificate_warn_days==21
  and .health.resources.disk_min_free_percent==10 and .node_templates==[]' "$SBM_STATE" >/dev/null

node_add ss --id metadata-test --port 28388 --address 192.0.2.1 --region hk --purpose relay \
  --line cn2 --tags backup,fast --remark 'secondary' >/dev/null
jq -e '.nodes[0].metadata.region=="hk" and (.nodes[0].metadata.tags|index("backup"))!=null' "$SBM_STATE" >/dev/null
[[ $(node_list_json backup '' | jq 'length') == 1 ]]
[[ $(node_list_json '' jp | jq 'length') == 0 ]]
node_set metadata-test --region jp --tags production,ipv6 --remark 'primary' >/dev/null
jq -e '.nodes[0].metadata.region=="jp" and .nodes[0].metadata.remark=="primary" and (.nodes[0].metadata.tags|length)==2' "$SBM_STATE" >/dev/null

node_template_save ss-base metadata-test >/dev/null
[[ $(node_template_list 1 | jq 'length') == 1 ]]
node_template_add ss-base metadata-clone --port 28389 --address 192.0.2.2 >/dev/null
node_batch_disable production '' >/dev/null
jq -e '[.nodes[]|select(.metadata.tags|index("production"))|.enabled] | all(.==false)' "$SBM_STATE" >/dev/null
node_batch_enable production '' >/dev/null
export SBM_DRY_RUN=1
node_set metadata-clone --name preview-only >/dev/null
jq -e '.nodes[]|select(.id=="metadata-clone")|.name!="preview-only"' "$SBM_STATE" >/dev/null
export SBM_DRY_RUN=0
config_validate 1 | jq -e '.valid==true' >/dev/null
config_diff 1 | jq -e '.valid==true and (.secrets_redacted==true)' >/dev/null
health_configure_resources --disk-free 12 --memory-max 88 --load-per-core 3 >/dev/null
jq -e '.health.resources.disk_min_free_percent==12 and .health.resources.memory_max_percent==88 and .health.resources.cpu_load_per_core_max==3' "$SBM_STATE" >/dev/null

notification_configure telegram '123456:test-token' 10001 '80,90,100' >/dev/null
[[ $(stat -c '%a' "$SBM_NOTIFICATION_SECRET") == 600 ]]
notification_test >/dev/null
grep -Fq $'telegram\ttest\t' "$SBM_TEST_NOTIFICATION_LOG"

traffic_set metadata-test --quota 1000B >/dev/null
traffic_usage_init_unlocked
tmp=$(mktemp "$ROOT/usage.XXXXXX")
jq '.nodes["metadata-test"].upload_bytes=850 | .nodes["metadata-test"].download_bytes=0' "$SBM_TRAFFIC_USAGE" >"$tmp"
mv -f "$tmp" "$SBM_TRAFFIC_USAGE"
notification_traffic_check_unlocked
notification_traffic_check_unlocked
[[ $(grep -Fc $'telegram\ttraffic_threshold\t' "$SBM_TEST_NOTIFICATION_LOG") == 1 ]]
grep -Fq '80% 阈值' "$SBM_TEST_NOTIFICATION_LOG"

health_enable 30 >/dev/null
health_tick
jq -e '.monitoring_enabled==true and .healthy==false and (.issues|map(.code)|index("traffic_rules_missing"))!=null' "$SBM_HEALTH_REPORT" >/dev/null
health_status 1 | jq -e '.enabled==true and .certificate_warn_days==30' >/dev/null

data=$(status_collect_json_unlocked)
jq -e '.manager.version and .summary.nodes==2 and .nodes[0].metadata.region=="jp"
  and .nodes[0].traffic.percent_used==85 and .components.notifications.credentials_ready==true' <<<"$data" >/dev/null

export SBM_SSH_PORTS='2222,2200'
[[ $(firewall_detect_ssh_ports | paste -sd, -) == 2200,2222 ]]
preview=$(firewall_setup_ufw 0 1)
grep -Fq '2200,2222/TCP' <<<"$preview"
grep -Fq '22/TCP' <<<"$preview"

printf 'OPERATIONS SMOKE PASSED\n'
