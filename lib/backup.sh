#!/usr/bin/env bash
# shellcheck shell=bash

backup_create() {
  local output=${1:-$SBM_BACKUPS/sb-manager-$(now_stamp).tar.gz} stage
  mkdir -p "$(dirname "$output")"
  stage=$(mktemp -d "$SBM_RUN/backup.XXXXXX")
  mkdir -p "$stage/etc" "$stage/meta"
  cp -a "$SBM_STATE" "$stage/etc/state.json"
  [[ -d "$SBM_SECRETS" ]] && cp -a "$SBM_SECRETS" "$stage/etc/secrets"
  [[ -d "$SBM_CERTS" ]] && cp -a "$SBM_CERTS" "$stage/etc/certs"
  [[ -f "$SBM_CONFIG" ]] && cp -a "$SBM_CONFIG" "$stage/etc/config.json"
  {
    printf 'manager_version=%s\n' "$SBM_VERSION"
    printf 'created_at=%s\n' "$(now_iso)"
    printf 'hostname=%s\n' "$(hostname 2>/dev/null || true)"
    printf 'sing_box_version=%s\n' "$(core_current_version || true)"
  } >"$stage/meta/manifest.txt"
  tar -C "$stage" -czf "$output" .
  chmod 0600 "$output"; rm -rf "$stage"
  log_ok "备份已创建：$output"
  log_warn "备份包含节点密码、Tunnel Token 和 DNS API Token，请妥善保管。"
}

_restore_backup() {
  local archive=$1 stage safety candidate
  [[ -f "$archive" ]] || die "备份文件不存在：$archive"
  stage=$(mktemp -d "$SBM_RUN/restore.XXXXXX")
  tar -tzf "$archive" | grep -Eq '(^|/)\.\./|^/' && { rm -rf "$stage"; die "备份包包含不安全路径。"; }
  tar -xzf "$archive" -C "$stage"
  [[ -s "$stage/etc/state.json" ]] || { rm -rf "$stage"; die "备份中缺少 state.json。"; }
  state_validate "$stage/etc/state.json"
  safety="$SBM_BACKUPS/pre-restore-$(now_stamp).tar.gz"; backup_create "$safety" >/dev/null

  rm -rf "$SBM_SECRETS.restore" "$SBM_CERTS.restore"
  [[ -d "$stage/etc/secrets" ]] && cp -a "$stage/etc/secrets" "$SBM_SECRETS.restore" || mkdir -p "$SBM_SECRETS.restore/nodes"
  [[ -d "$stage/etc/certs" ]] && cp -a "$stage/etc/certs" "$SBM_CERTS.restore" || mkdir -p "$SBM_CERTS.restore"
  mv "$SBM_SECRETS" "$SBM_SECRETS.old.$$"; mv "$SBM_SECRETS.restore" "$SBM_SECRETS"
  mv "$SBM_CERTS" "$SBM_CERTS.old.$$"; mv "$SBM_CERTS.restore" "$SBM_CERTS"
  chmod 0700 "$SBM_SECRETS" "$SBM_SECRETS/nodes" 2>/dev/null || true
  candidate=$(state_candidate); cp "$stage/etc/state.json" "$candidate"
  if ! apply_candidate_state "$candidate" restore; then
    rm -rf "$SBM_SECRETS" "$SBM_CERTS"
    mv "$SBM_SECRETS.old.$$" "$SBM_SECRETS"; mv "$SBM_CERTS.old.$$" "$SBM_CERTS"
    rm -f "$candidate"; rm -rf "$stage"
    die "恢复失败；原配置已还原。安全备份：$safety"
  fi
  rm -rf "$SBM_SECRETS.old.$$" "$SBM_CERTS.old.$$" "$stage"; rm -f "$candidate"
  local d
  while IFS= read -r d; do cert_hook "$d" || true; done < <(jq -r '.certificates[].domain' "$SBM_STATE")
  tunnel_reconcile 1 || log_warn '配置已恢复，但 Tunnel 需要手动检查。'
  log_ok "恢复完成。恢复前备份：$safety"
}
backup_restore() {
  local archive=$1 confirmed=${2:-0}
  if [[ "$confirmed" != 1 ]]; then confirm "恢复会覆盖当前状态、密钥和证书，继续？" N || return 0; fi
  with_lock _restore_backup "$archive"
}
