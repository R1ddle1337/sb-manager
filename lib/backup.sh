#!/usr/bin/env bash
# shellcheck shell=bash

_backup_create() {
  local output=${1:-$SBM_BACKUPS/sb-manager-$(now_stamp).tar.gz} recipient=${2:-} stage plain output_tmp
  mkdir -p "$(dirname "$output")"
  stage=$(mktemp -d "$SBM_RUN/backup.XXXXXX")
  plain=$(mktemp "$SBM_RUN/backup-archive.XXXXXX")
  output_tmp=$(mktemp "$(dirname "$output")/.sb-manager-backup.XXXXXX")
  rm -f "$output_tmp"
  mkdir -p "$stage/etc" "$stage/meta" "$stage/var"
  cp -a "$SBM_STATE" "$stage/etc/state.json"
  [[ -d "$SBM_SECRETS" ]] && cp -a "$SBM_SECRETS" "$stage/etc/secrets"
  [[ -d "$SBM_CERTS" ]] && cp -a "$SBM_CERTS" "$stage/etc/certs"
  [[ -f "$SBM_CONFIG" ]] && cp -a "$SBM_CONFIG" "$stage/etc/config.json"
  [[ -d "$SBM_SUBSCRIPTIONS" ]] && cp -a "$SBM_SUBSCRIPTIONS" "$stage/var/subscriptions"
  {
    printf 'manager_version=%s\n' "$SBM_VERSION"
    printf 'created_at=%s\n' "$(now_iso)"
    printf 'hostname=%s\n' "$(hostname 2>/dev/null || true)"
    printf 'sing_box_version=%s\n' "$(core_current_version || true)"
  } >"$stage/meta/manifest.txt"
  tar -C "$stage" -czf "$plain" .
  if [[ -n "$recipient" ]]; then
    require_command age
    age --encrypt --recipient "$recipient" --output "$output_tmp" "$plain"
  else
    mv -f "$plain" "$output_tmp"
  fi
  chmod 0600 "$output_tmp"
  mv -f "$output_tmp" "$output"
  rm -rf "$stage"; rm -f "$plain"
  log_ok "备份已创建：$output"
  log_warn "备份包含节点密码、Tunnel Token 和 DNS API Token，请妥善保管。"
}
backup_create() { with_lock _backup_create "$@"; }

backup_is_age() {
  local archive=$1
  [[ "$archive" == *.age ]] || head -c 22 "$archive" 2>/dev/null | grep -q '^age-encryption.org/v1'
}

_restore_backup() {
  local archive=$1 identity=${2:-} stage safety candidate extracted_kib source_archive
  [[ -f "$archive" ]] || die "备份文件不存在：$archive"
  stage=$(mktemp -d "$SBM_RUN/restore.XXXXXX")
  trap "rm -rf -- $(printf '%q' "$stage")" EXIT
  source_archive="$stage/backup.tar.gz"
  if backup_is_age "$archive"; then
    require_command age
    [[ -n "$identity" ]] || die "加密备份需要 --identity AGE_PRIVATE_KEY。"
    [[ -f "$identity" ]] || die "age 身份文件不存在：$identity"
    age --decrypt --identity "$identity" --output "$source_archive" "$archive"
  else
    cp -f -- "$archive" "$source_archive"
  fi
  backup_validate_archive "$source_archive" || die "备份包包含不安全路径、链接或特殊文件。"
  if tar --version 2>/dev/null | head -n1 | grep -q 'GNU tar'; then
    tar --no-same-owner --no-same-permissions -xzf "$source_archive" -C "$stage"
  else
    tar -xzf "$source_archive" -C "$stage"
  fi
  if find "$stage" \( -type l -o -type b -o -type c -o -type p -o -type s \) -print -quit | grep -q .; then
    rm -rf "$stage"; die "备份解压后包含链接或特殊文件。"
  fi
  extracted_kib=$(du -sk "$stage" | awk '{print $1}')
  (( extracted_kib <= 524288 )) || { rm -rf "$stage"; die "备份解压后超过 512 MiB 限制。"; }
  chown -R root:root "$stage" 2>/dev/null || true
  [[ -s "$stage/etc/state.json" ]] || { rm -rf "$stage"; die "备份中缺少 state.json。"; }
  state_validate "$stage/etc/state.json"
  safety="$SBM_BACKUPS/pre-restore-$(now_stamp).tar.gz"; _backup_create "$safety" >/dev/null

  rm -rf "$SBM_SECRETS.restore" "$SBM_CERTS.restore"
  [[ -d "$stage/etc/secrets" ]] && cp -a "$stage/etc/secrets" "$SBM_SECRETS.restore" || mkdir -p "$SBM_SECRETS.restore/nodes"
  [[ -d "$stage/etc/certs" ]] && cp -a "$stage/etc/certs" "$SBM_CERTS.restore" || mkdir -p "$SBM_CERTS.restore"
  rm -rf "$SBM_SECRETS" "$SBM_CERTS"
  mv "$SBM_SECRETS.restore" "$SBM_SECRETS"
  mv "$SBM_CERTS.restore" "$SBM_CERTS"
  if [[ -d "$stage/var/subscriptions" ]]; then
    rm -rf "$SBM_SUBSCRIPTIONS.restore"
    cp -a "$stage/var/subscriptions" "$SBM_SUBSCRIPTIONS.restore"
    rm -rf "$SBM_SUBSCRIPTIONS"
    mv "$SBM_SUBSCRIPTIONS.restore" "$SBM_SUBSCRIPTIONS"
  fi
  state_init_dirs
  find "$SBM_SECRETS" -type f -exec chmod 0600 {} + 2>/dev/null || true
  chmod 0700 "$SBM_SECRETS/nodes" 2>/dev/null || true
  if [[ -f ${SBM_TUNNEL_TOKEN_FILE:-$SBM_SECRETS/cloudflared.token} ]]; then
    chmod 0640 "${SBM_TUNNEL_TOKEN_FILE:-$SBM_SECRETS/cloudflared.token}"
    set_group_if_exists "$SBM_SERVICE_USER" "${SBM_TUNNEL_TOKEN_FILE:-$SBM_SECRETS/cloudflared.token}"
  fi
  candidate=$(state_candidate); cp "$stage/etc/state.json" "$candidate"
  apply_candidate_state "$candidate" restore || { rm -f "$candidate"; return 1; }
  rm -f "$candidate"
  local d
  while IFS= read -r d; do cert_hook "$d" || return 1; done < <(jq -r '.certificates[].domain' "$SBM_STATE")
  tunnel_reconcile 1 || return 1
  if declare -F subscription_reconcile >/dev/null 2>&1; then subscription_reconcile 1 || return 1; fi
  log_ok "恢复完成。恢复前备份：$safety"
}

backup_validate_archive() {
  local archive=$1 entry path part members=0 max_members=10000 compressed_bytes expanded_bytes
  local -a entries=()
  compressed_bytes=$(wc -c <"$archive") || return 1
  (( compressed_bytes <= 134217728 )) || return 1
  mapfile -t entries < <(tar -tzf "$archive") || return 1
  ((${#entries[@]} > 0 && ${#entries[@]} <= max_members)) || return 1
  while IFS= read -r entry; do
    members=$((members + 1))
    [[ "$members" -le "$max_members" ]] || return 1
    [[ "$entry" == . || "$entry" == ./ ]] && continue
    path=${entry#./}
    path=${path%/}
    [[ -n "$path" && "$path" != /* && "$path" != *$'\n'* ]] || return 1
    case "$path" in
      etc|etc/state.json|etc/config.json|etc/secrets|etc/secrets/*|etc/certs|etc/certs/*|meta|meta/manifest.txt|var|var/subscriptions|var/subscriptions/*) ;;
      *) return 1 ;;
    esac
    IFS=/ read -r -a parts <<<"$path"
    for part in "${parts[@]}"; do [[ "$part" != .. && "$part" != . ]] || return 1; done
  done < <(printf '%s\n' "${entries[@]}")
  tar -tvzf "$archive" | awk '
    $1 !~ /^[-d]/ {bad=1}
    $1 ~ /^-/ && $3 ~ /^[0-9]+$/ {total += $3}
    END {if (bad || total > 536870912) exit 1}
  ' || return 1
  expanded_bytes=$(tar -tvzf "$archive" | awk '$1 ~ /^-/ && $3 ~ /^[0-9]+$/ {total += $3} END {print total+0}')
  (( expanded_bytes <= 536870912 ))
}
backup_restore() {
  local archive=$1 confirmed=${2:-0} identity=${3:-}
  if [[ "$confirmed" != 1 ]]; then confirm "恢复会覆盖当前状态、密钥和证书，继续？" N || return 0; fi
  with_state_transaction restore _restore_backup "$archive" "$identity"
}
