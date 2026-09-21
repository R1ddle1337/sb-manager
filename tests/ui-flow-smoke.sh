#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/feature-fixture.sh"

# CLI values keep literal q; closed input must fail without replacing a value.
(
  unset SBM_UI_WORKER
  value=existing
  prompt_value value 'CLI value' '' <<<q
  [[ "$value" == q ]]
  if prompt_value value 'CLI value' default </dev/null; then exit 1; fi
  [[ "$value" == q ]]
  prompt_secret value 'CLI secret' <<<q
  [[ "$value" == q ]]
) >"$ROOT/cli-input"

# Unit coverage for selections and edit defaults, without executing mutations.
jq '.settings.public_ipv4="198.51.100.8" |
  .nodes=[{id:"alpha",name:"Alpha"},{id:"beta",name:"Beta"},{id:"gamma",name:"Gamma"}] |
  .traffic_groups=[{id:"family",nodes:["alpha","beta"],quota_bytes:123456789,reset_day:7,quota_mode:"download"}] |
  .substore={enabled:true,port:9311,version:"2.39.9",frontend_version:"2.32.2"}' "$SBM_STATE" >"$ROOT/state.new"
mv "$ROOT/state.new" "$SBM_STATE"
responses=(); response_index=0
prompt_value() {
  printf '%s\t%s\n' "$2" "${3:-}" >>"$ROOT/prompts"
  local answer=${responses[$response_index]:-${3:-}}
  response_index=$((response_index+1))
  printf -v "$1" '%s' "$answer"
}
confirm() { return 0; }
traffic_group_cli() { printf '%s\n' "$@" >"$ROOT/group-args"; }
substore_cli() { printf '%s\n' "$@" >"$ROOT/substore-args"; }
tunnel_routes_cli() { printf '%s\n' "$@" >"$ROOT/route-args"; }

responses=(2 1 '' '' '' ''); response_index=0
ui_traffic_group_menu >"$ROOT/group-ui"
grep -Fxq '123456789B' "$ROOT/group-args"
grep -Fxq 'alpha,beta' "$ROOT/group-args"
grep -Fxq '7' "$ROOT/group-args"
grep -Fxq 'download' "$ROOT/group-args"
responses=(2 '' '' ''); response_index=0
ui_substore_menu >"$ROOT/substore-ui"
grep -Fxq '9311' "$ROOT/substore-args"

responses=('1,3,1'); response_index=0
members=''
ui_select_members members '' >"$ROOT/members-ui"
[[ "$members" == alpha,gamma ]]
responses=('99999999999999999999999999' 2); response_index=0
selected=''
ui_select_json selected '示例' '[{"id":"a"},{"id":"b"}]' >"$ROOT/selector-ui"
[[ "$selected" == b ]]

export SBM_UI_NET_DIR="$ROOT/interfaces"
mkdir -p "$SBM_UI_NET_DIR/lo" "$SBM_UI_NET_DIR/eth0" "$SBM_UI_NET_DIR/eth1"
printf 'up\n' >"$SBM_UI_NET_DIR/eth0/operstate"
printf 'down\n' >"$SBM_UI_NET_DIR/eth1/operstate"
ui_interfaces_json | jq -e 'map(.id)==["eth0","eth1"]' >/dev/null
responses=(''); response_index=0
selected=''
ui_select_interface selected eth1 >"$ROOT/interfaces-ui"
[[ "$selected" == eth1 ]]

history='[{"id":"before","target":"test","port":5201,"seconds":10,"streams":1,"direction":"down","bits_per_second":100000000},
 {"id":"match","target":"test","port":5201,"seconds":10,"streams":1,"direction":"down","bits_per_second":110000000},
 {"id":"mismatch","target":"test","port":5201,"seconds":10,"streams":4,"direction":"down","bits_per_second":110000000}]'
responses=(1); response_index=0
selected=''
ui_select_benchmark selected "$history" before >"$ROOT/history-ui"
[[ "$selected" == match ]]
! grep -q mismatch "$ROOT/history-ui"
[[ $(ui_proxy_address_default 127.0.0.1) == 127.0.0.1 ]]
[[ $(ui_proxy_address_default ::1) == ::1 ]]
[[ $(ui_proxy_address_default 0.0.0.0) == 198.51.100.8 ]]
responses=(-); response_index=0
value='^/api/'
ui_prompt_optional value '路径' "$value"
[[ -z "$value" ]]
jq '.tunnel.mode="managed" | .tunnel.routes=[{id:"api",hostname:"app.example.com",service:"http://127.0.0.1:9088",path:"^/api/"}]' "$SBM_STATE" >"$ROOT/state.new"
mv "$ROOT/state.new" "$SBM_STATE"
responses=(3 1 '' '' ''); response_index=0
ui_tunnel_routes_menu >"$ROOT/routes-ui"
grep -Fxq 'app.example.com' "$ROOT/route-args"
grep -Fxq 'http://127.0.0.1:9088' "$ROOT/route-args"
grep -Fxq '^/api/' "$ROOT/route-args"

# Build a private copy: worker functions are loaded by a fresh Bash process.
# Only mock backend actions in that copy; all menu/input code remains real.
mkdir -p "$ROOT/program"
cp -a "$PROJECT/sb" "$PROJECT/VERSION" "$PROJECT/lib" "$PROJECT/libexec" "$PROJECT/protocols" "$ROOT/program/"
cat >>"$ROOT/program/lib/substore.sh" <<'EOF_STUB'
substore_cli() {
  case "$1" in
    enable) die 'INJECTED_ACTION_FAILURE';;
    disable) false; printf 'unsafe continuation\n' >"$SBM_RUN/after-failure";;
    restore) printf 'unexpected restore\n' >"$SBM_RUN/after-cancel";;
    *) printf '%s|%s|%s|%s|%s\n' "$SBM_DRY_RUN" "$SBM_ASSUME_YES" "$SBM_QUIET" "${NO_COLOR:-}" "$C_RED" >"$SBM_RUN/ui-flags"; printf 'SUBSTORE_ACTION_OK\n';;
  esac
}
EOF_STUB
cat >>"$ROOT/program/lib/manager.sh" <<'EOF_UPDATE'
manager_update() { printf 'ui-reloaded\n' >"$SBM_LIB/VERSION"; }
EOF_UPDATE
cat >>"$ROOT/program/lib/uninstall.sh" <<'EOF_UNINSTALL'
uninstall_manager() {
  confirm 'TEST_UNINSTALL_CONFIRM' N || return 0
  SBM_UNINSTALLED=1
  printf 'TEST_UNINSTALL_COMPLETE\n'
}
EOF_UNINSTALL
# Start the PTY worker from a valid state. Every runtime path remains isolated.
state_default_json >"$SBM_STATE"
node_add http --id panel-node --port 19081 --name Panel --address 127.0.0.1 >/dev/null
python3 "$PROJECT/tests/ui-pty.py" "$ROOT/program" "$ROOT"
[[ ! -e "$SBM_RUN/after-failure" && ! -e "$SBM_RUN/after-cancel" ]]
[[ $(cat "$SBM_RUN/ui-flags") == '1|1|1|1|' ]]
jq -e '.nodes[]|select(.id=="panel-node")|.name=="Renamed"' "$SBM_STATE" >/dev/null
printf 'UI FLOW SMOKE PASSED\n'
