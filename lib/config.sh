#!/usr/bin/env bash
# shellcheck shell=bash

config_redact() {
  jq '
    walk(if type=="object" then with_entries(
      if (.key | test("password|passwd|token|secret|uuid|private|psk|userkey|api_key";"i"))
      then .value="***REDACTED***" else . end
    ) else . end)
  '
}

config_render_validated() {
  local state=$1 output=$2 log_file=${3:-$SBM_RUN/config-validate.log}
  state_validate "$state"
  render_config_from_state "$state" "$output"
  core_validate_config_with "$SBM_SING_BOX_BIN" "$output" "$log_file"
}

config_validate() {
  local json=${1:-0} tmp rc=0 message='配置有效'
  tmp=$(mktemp "$SBM_RUN/config-validate.XXXXXX")
  if ! (config_render_validated "$SBM_STATE" "$tmp"); then rc=1; message='状态、渲染或 sing-box 校验失败'; fi
  if [[ "$json" == 1 ]]; then
    jq -n --argjson valid "$([[ "$rc" == 0 ]] && echo true || echo false)" --arg message "$message" \
      --arg checked_at "$(now_iso)" --arg log "$SBM_RUN/config-validate.log" \
      '{valid:$valid,checked_at:$checked_at,message:$message,log:(if $valid then null else $log end)}'
  elif [[ "$rc" == 0 ]]; then
    log_ok "$message"
  else
    log_error "$message；详见 $SBM_RUN/config-validate.log"
  fi
  rm -f "$tmp"
  return "$rc"
}

config_diff_files() {
  local before=$1 after=$2 output=$3 before_redacted after_redacted
  before_redacted=$(mktemp "$SBM_RUN/config-before.XXXXXX")
  after_redacted=$(mktemp "$SBM_RUN/config-after.XXXXXX")
  config_redact <"$before" >"$before_redacted"
  config_redact <"$after" >"$after_redacted"
  diff -u --label installed-config --label candidate-config "$before_redacted" "$after_redacted" >"$output" || true
  rm -f "$before_redacted" "$after_redacted"
}

config_state_diff_files() {
  local before=$1 after=$2 output=$3
  diff -u --label current-state --label candidate-state <(jq -S . "$before") <(jq -S . "$after") >"$output" || true
}

config_preview_candidate() {
  local candidate=$1 json=${2:-${SBM_OUTPUT_JSON:-0}} rendered installed state_diff config_diff changed
  rendered=$(mktemp "$SBM_RUN/config-preview.XXXXXX")
  installed=$(mktemp "$SBM_RUN/config-installed.XXXXXX")
  state_diff=$(mktemp "$SBM_RUN/state-diff.XXXXXX")
  config_diff=$(mktemp "$SBM_RUN/config-diff.XXXXXX")
  config_render_validated "$candidate" "$rendered" "$SBM_RUN/config-preview-check.log"
  if [[ -s "$SBM_CONFIG" ]]; then cp -f "$SBM_CONFIG" "$installed"; else printf '{}\n' >"$installed"; fi
  config_state_diff_files "$SBM_STATE" "$candidate" "$state_diff"
  config_diff_files "$installed" "$rendered" "$config_diff"
  changed=false
  [[ -s "$state_diff" || -s "$config_diff" ]] && changed=true
  if [[ "$json" == 1 ]]; then
    jq -n --argjson changed "$changed" --rawfile state_diff "$state_diff" --rawfile config_diff "$config_diff" \
      '{valid:true,changed:$changed,state_diff:$state_diff,config_diff:$config_diff,secrets_redacted:true}'
  else
    printf '%s\n' '---- state.json 预览 ----'
    if [[ -s "$state_diff" ]]; then cat "$state_diff"; else printf '无变化\n'; fi
    printf '%s\n' '---- 生成配置预览（敏感字段已遮蔽）----'
    if [[ -s "$config_diff" ]]; then cat "$config_diff"; else printf '无变化\n'; fi
  fi
  rm -f "$rendered" "$installed" "$state_diff" "$config_diff"
}

config_diff() {
  local json=${1:-0} rendered installed output changed=false
  rendered=$(mktemp "$SBM_RUN/config-diff-current.XXXXXX")
  installed=$(mktemp "$SBM_RUN/config-diff-installed.XXXXXX")
  output=$(mktemp "$SBM_RUN/config-diff-output.XXXXXX")
  config_render_validated "$SBM_STATE" "$rendered" "$SBM_RUN/config-diff-check.log"
  if [[ -s "$SBM_CONFIG" ]]; then cp -f "$SBM_CONFIG" "$installed"; else printf '{}\n' >"$installed"; fi
  config_diff_files "$installed" "$rendered" "$output"
  [[ -s "$output" ]] && changed=true
  if [[ "$json" == 1 ]]; then
    jq -n --argjson changed "$changed" --rawfile diff "$output" '{valid:true,changed:$changed,diff:$diff,secrets_redacted:true}'
  elif [[ -s "$output" ]]; then
    cat "$output"
  else
    log_ok '已安装配置与当前状态渲染结果一致。'
  fi
  rm -f "$rendered" "$installed" "$output"
}
