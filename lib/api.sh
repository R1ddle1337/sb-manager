#!/usr/bin/env bash
# shellcheck shell=bash

_api_enable() {
  local port=${1:-9090} dashboard=${2:-false} candidate secret
  validate_port "$port" || die "无效 API 端口：$port"
  case "$dashboard" in true|false) ;; *) die 'Dashboard 参数必须是 true 或 false。';; esac
  version_ge "$(core_current_version)" 1.14.0-rc.1 || die 'API/Dashboard 是 1.14+ 功能；当前核心不支持。'
  secret=$(random_password 36)
  state_write_secret api "$(jq -n --arg secret "$secret" '{secret:$secret}')"
  mkdir -p "$SBM_VAR/dashboard"
  chown "$SBM_SERVICE_USER":"$SBM_SERVICE_USER" "$SBM_VAR/dashboard" 2>/dev/null || true
  chmod 0750 "$SBM_VAR/dashboard"
  candidate=$(state_candidate)
  jq --argjson port "$port" --argjson dashboard "$dashboard" '.api={enabled:true,listen:"127.0.0.1",port:$port,dashboard:$dashboard}' "$SBM_STATE" >"$candidate"
  if ! apply_candidate_state "$candidate" api-enable; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  log_ok "API 已启用，仅监听 127.0.0.1:$port。"
  log_warn '使用 sb api show-token 查看令牌；远程访问请使用 SSH 转发，不要直接暴露公网。'
}
api_enable() { with_state_transaction api-enable _api_enable "$@"; }

_api_disable() {
  local candidate
  candidate=$(state_candidate)
  jq '.api.enabled=false | .api.dashboard=false' "$SBM_STATE" >"$candidate"
  if ! apply_candidate_state "$candidate" api-disable; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate" "$(state_secret_path api)"
  log_ok 'API/Dashboard 已禁用。'
}
api_disable() { with_state_transaction api-disable _api_disable; }

api_status() {
  jq '.api' "$SBM_STATE"
  if [[ $(jq -r '.api.enabled' "$SBM_STATE") == true ]]; then
    printf 'SSH 转发示例：ssh -L %s:127.0.0.1:%s root@SERVER\n' "$(jq -r '.api.port' "$SBM_STATE")" "$(jq -r '.api.port' "$SBM_STATE")"
  fi
}

api_show_token() {
  [[ $(jq -r '.api.enabled' "$SBM_STATE") == true ]] || die 'API 未启用。'
  state_get_secret api | jq -r '.secret'
}
