#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/feature-fixture.sh"

node_add socks --id group-a --port 28581 >/dev/null
node_add http --id group-b --port 28582 >/dev/null
traffic_group_cli set shared --nodes group-a,group-b --quota 500G --reset-day 7
with_lock _traffic_group_status | jq -e '.[0].remaining_bytes==536870912000 and .[0].used_bytes==0' >/dev/null
traffic_render_nft_script 0 >"$ROOT/rules"
prefix=$(traffic_group_prefix shared)
[[ $(grep -c "add quota inet .* ${prefix}_quota " "$ROOT/rules") == 1 ]]
[[ $(grep -c "quota name ${prefix}_quota drop" "$ROOT/rules") -ge 4 ]]
cp "$SBM_STATE" "$ROOT/before.json"
expect_failure traffic_group_cli set second --nodes group-a --quota 10G
expect_failure traffic_group_cli set missing --nodes unknown --quota 10G
expect_failure traffic_group_cli set repeated --nodes group-a,group-a --quota 10G
expect_failure traffic_disable group-a
expect_failure node_delete group-a
cmp "$ROOT/before.json" "$SBM_STATE"
# Removing a member does not erase already billed group usage.
traffic_group_usage_put "$SBM_TRAFFIC_USAGE" shared "$(traffic_cycle_id 7)" 100 200
traffic_group_cli set shared --nodes group-b --quota 1G --reset-day 7 --quota-mode download
with_lock _traffic_group_status | jq -e '.[0].used_bytes==200 and .[0].nodes==["group-b"]' >/dev/null
traffic_group_usage_put "$SBM_TRAFFIC_USAGE" shared "$(( $(traffic_cycle_id 7) - 1 ))" 100 200
traffic_reset_due_unlocked
[[ "$TRAFFIC_RESET_CHANGED" == 1 ]]
jq -e '.groups.shared.upload_bytes==0 and .groups.shared.download_bytes==0' "$SBM_TRAFFIC_USAGE" >/dev/null
traffic_group_cli remove shared
traffic_group_usage_put "$SBM_TRAFFIC_USAGE" shared "$(( $(traffic_cycle_id 7) - 1 ))" 100 200
traffic_group_cli set shared --nodes group-b --quota 1G --reset-day 7
with_lock _traffic_group_status | jq -e '.[0].used_bytes==0' >/dev/null
traffic_group_cli remove shared
traffic_disable group-b >/dev/null
printf 'TRAFFIC GROUPS SMOKE PASSED\n'
