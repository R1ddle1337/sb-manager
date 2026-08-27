#!/usr/bin/env bash
# shellcheck shell=bash

sb_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    armv7l|armv7|armhf) printf 'armv7\n' ;;
    i386|i486|i586|i686) printf '386\n' ;;
    *) die "暂不支持的 CPU 架构：$(uname -m)" ;;
  esac
}
cloudflared_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    armv7l|armv7|armhf) printf 'arm\n' ;;
    i386|i486|i586|i686) printf '386\n' ;;
    *) die "暂不支持的 CPU 架构：$(uname -m)" ;;
  esac
}

github_api() {
  local url=$1
  curl -fsSL --retry 3 --connect-timeout 15 -H 'Accept: application/vnd.github+json' -H 'User-Agent: sb-manager' "$url"
}

core_release_json() {
  local version=${1:-latest}
  if [[ "$version" == latest ]]; then github_api 'https://api.github.com/repos/SagerNet/sing-box/releases/latest';
  else github_api "https://api.github.com/repos/SagerNet/sing-box/releases/tags/v${version#v}"; fi
}

core_latest_version() { core_release_json latest | jq -r '.tag_name' | sed 's/^v//'; }
core_current_version() {
  local output
  [[ -x "$SBM_SING_BOX_BIN" ]] || return 0
  output=$("$SBM_SING_BOX_BIN" version 2>/dev/null) || return 1
  extract_semver "$output"
}

verify_asset_digest() {
  local file=$1 digest=${2:-}
  [[ -n "$digest" && "$digest" == sha256:* ]] || return 2
  local expected=${digest#sha256:} actual
  actual=$(sha256sum "$file" | awk '{print $1}')
  [[ "$actual" == "$expected" ]]
}

core_download_version() {
  local version=$1 arch json asset_name asset_url digest checksum_url tmpdir archive target expected
  arch=$(sb_arch); json=$(core_release_json "$version"); version=$(jq -r '.tag_name' <<<"$json" | sed 's/^v//')
  asset_name="sing-box-${version}-linux-${arch}.tar.gz"
  asset_url=$(jq -r --arg n "$asset_name" 'first(.assets[] | select(.name==$n) | .browser_download_url) // empty' <<<"$json")
  digest=$(jq -r --arg n "$asset_name" 'first(.assets[] | select(.name==$n) | (.digest // "")) // empty' <<<"$json")
  [[ -n "$asset_url" ]] || die "官方 Release 中未找到：$asset_name"
  target="$SBM_CORE_DIR/sing-box/$version/sing-box"
  if [[ -x "$target" ]]; then
    ensure_program_permissions
    printf '%s\n' "$target"
    return 0
  fi
  tmpdir=$(mktemp -d "$SBM_CACHE/sing-box.XXXXXX"); archive="$tmpdir/$asset_name"
  log_info "下载 sing-box $version ($arch)…"
  curl -fL --retry 3 --connect-timeout 15 "$asset_url" -o "$archive"
  if ! verify_asset_digest "$archive" "$digest"; then
    checksum_url=$(jq -r 'first(.assets[] | select(.name|test("checksums.*\\.txt$|checksum.*\\.txt$";"i")) | .browser_download_url) // empty' <<<"$json")
    [[ -n "$checksum_url" ]] || { rm -rf "$tmpdir"; die "Release 未提供可用 SHA-256 摘要，已拒绝安装。"; }
    curl -fL --retry 3 "$checksum_url" -o "$tmpdir/checksums.txt"
    expected=$(awk -v n="$asset_name" '$NF==n {print $1; exit}' "$tmpdir/checksums.txt")
    [[ -n "$expected" && "$expected" == "$(sha256sum "$archive" | awk '{print $1}')" ]] || { rm -rf "$tmpdir"; die "sing-box 下载文件校验失败。"; }
  fi
  mkdir -p "$SBM_CORE_DIR/sing-box/$version"
  chmod 0755 "$SBM_CORE_DIR" "$SBM_CORE_DIR/sing-box" "$SBM_CORE_DIR/sing-box/$version"
  tar -xzf "$archive" -C "$tmpdir"
  local found
  found=$(find "$tmpdir" -type f -name sing-box -perm -u+x -print -quit)
  [[ -n "$found" ]] || { rm -rf "$tmpdir"; die "压缩包中未找到 sing-box。"; }
  install -m 0755 "$found" "$target"
  ensure_program_permissions
  if ! "$target" version >/dev/null 2>&1; then
    rm -rf "$tmpdir"
    if [[ -f /etc/alpine-release ]]; then
      die "sing-box 官方核心无法在当前 Alpine 运行；请确认已安装 gcompat。"
    fi
    die "下载的 sing-box 核心无法执行。"
  fi
  if [[ $(init_system 2>/dev/null || true) == openrc ]]; then ensure_singbox_bind_capability "$target"; fi
  rm -rf "$tmpdir"
  printf '%s\n' "$target"
}

core_switch_to() {
  local version=$1 binary current_target previous
  binary="$SBM_CORE_DIR/sing-box/${version#v}/sing-box"
  [[ -x "$binary" ]] || binary=$(core_download_version "$version")
  validate_runtime_binary_path sing-box "$binary"
  ensure_program_permissions
  if [[ -s "$SBM_CONFIG" ]]; then core_validate_config_with "$binary" "$SBM_CONFIG" "$SBM_RUN/core-candidate-check.log" || return 1; fi
  if [[ $(init_system 2>/dev/null || true) == openrc ]]; then ensure_singbox_bind_capability "$binary"; fi
  current_target=$(readlink -f "$SBM_SING_BOX_BIN" 2>/dev/null || true)
  previous=${current_target:-none}
  mkdir -p "$SBM_BIN_DIR" "$SBM_VAR/core-history"
  ln -sfn "$binary" "$SBM_SING_BOX_BIN.new"
  mv -Tf "$SBM_SING_BOX_BIN.new" "$SBM_SING_BOX_BIN"
  printf '%s\t%s\t%s\n' "$(now_iso)" "$previous" "$binary" >>"$SBM_VAR/core-history/sing-box.tsv"
  ensure_program_permissions
  if [[ "$SBM_SKIP_INIT" != "1" ]] && service_exists "$SBM_SERVICE"; then
    if ! singbox_service_reconcile; then
      log_error "新核心启动失败，恢复旧核心。"
      if [[ -n "$current_target" && -x "$current_target" ]]; then
        ln -sfn "$current_target" "$SBM_SING_BOX_BIN"
        singbox_service_reconcile || true
      fi
      return 1
    fi
  fi
  log_ok "sing-box 已切换到 $(core_current_version)。"
}

_core_update() {
  local version=${1:-latest} latest current
  [[ "$version" == latest ]] && latest=$(core_latest_version) || latest=${version#v}
  current=$(core_current_version || true)
  if [[ "$current" == "$latest" ]]; then log_ok "sing-box 已是目标版本 $latest。"; return 0; fi
  core_download_version "$latest" >/dev/null
  core_switch_to "$latest"
}
core_update() { with_lock _core_update "${1:-latest}"; }

core_check_update() {
  local current latest
  current=$(core_current_version || true); latest=$(core_latest_version)
  printf '当前版本：%s\n最新稳定：%s\n' "${current:-未安装}" "$latest"
  [[ "$current" == "$latest" ]] || return 10
}

core_set_policy() {
  local policy=$1 candidate
  case "$policy" in manual|notify|patch|stable) ;; *) die "策略必须是 manual、notify、patch 或 stable。";; esac
  candidate=$(state_candidate)
  jq --arg p "$policy" '.settings.core_update_policy=$p' "$SBM_STATE" >"$candidate"
  with_lock apply_candidate_state "$candidate" core-policy
  rm -f "$candidate"
  log_ok "自动更新策略：$policy"
}

core_auto_update() {
  local policy current latest cmj cmi lmj lmi
  policy=$(jq -r '.settings.core_update_policy // "notify"' "$SBM_STATE")
  [[ "$policy" != manual ]] || return 0
  current=$(core_current_version || true); latest=$(core_latest_version)
  [[ "$current" != "$latest" ]] || return 0
  mkdir -p "$SBM_VAR/updates"
  jq -n --arg now "$(now_iso)" --arg current "$current" --arg latest "$latest" --arg policy "$policy" '{checked_at:$now,current:$current,latest:$latest,policy:$policy}' >"$SBM_VAR/updates/sing-box.json"
  case "$policy" in
    notify) log_warn "发现 sing-box 稳定版更新：$current → $latest。运行 sb core update。" ;;
    patch)
      IFS=. read -r cmj cmi _ <<<"$current"; IFS=. read -r lmj lmi _ <<<"$latest"
      if [[ "$cmj.$cmi" == "$lmj.$lmi" ]]; then _core_update "$latest"; else log_warn "发现跨 minor 更新 $latest；patch 策略不自动安装。"; fi
      ;;
    stable) _core_update "$latest" ;;
  esac
}

core_rollback() {
  local current candidate version
  current=$(readlink -f "$SBM_SING_BOX_BIN" 2>/dev/null || true)
  candidate=$(find "$SBM_CORE_DIR/sing-box" -mindepth 2 -maxdepth 2 -type f -name sing-box -perm -u+x -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk -v cur="$current" '$2!=cur {print $2; exit}')
  [[ -n "$candidate" ]] || die "没有可回滚的旧核心。"
  version=$(basename "$(dirname "$candidate")")
  core_switch_to "$version"
}

cloudflared_release_json() { github_api 'https://api.github.com/repos/cloudflare/cloudflared/releases/latest'; }
cloudflared_latest_version() { cloudflared_release_json | jq -r '.tag_name' | sed 's/^v//'; }
cloudflared_current_version() {
  local output
  [[ -x "$SBM_CLOUDFLARED_BIN" ]] || return 0
  output=$("$SBM_CLOUDFLARED_BIN" version 2>/dev/null) || return 1
  if [[ $output =~ ([0-9]{4}\.[0-9]+\.[0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    return 1
  fi
}

cloudflared_download_latest() {
  local arch json version asset_name url digest tmp target
  arch=$(cloudflared_arch); json=$(cloudflared_release_json); version=$(jq -r '.tag_name' <<<"$json" | sed 's/^v//')
  asset_name="cloudflared-linux-${arch}"
  url=$(jq -r --arg n "$asset_name" 'first(.assets[] | select(.name==$n) | .browser_download_url) // empty' <<<"$json")
  digest=$(jq -r --arg n "$asset_name" 'first(.assets[] | select(.name==$n) | (.digest // "")) // empty' <<<"$json")
  [[ -n "$url" ]] || die "未找到 cloudflared 资产：$asset_name"
  target="$SBM_CORE_DIR/cloudflared/$version/cloudflared"
  if [[ -x "$target" ]]; then
    ensure_program_permissions
    printf '%s\n' "$target"
    return 0
  fi
  mkdir -p "$(dirname "$target")"
  chmod 0755 "$SBM_CORE_DIR" "$SBM_CORE_DIR/cloudflared" "$(dirname "$target")"
  tmp=$(mktemp "$SBM_CACHE/cloudflared.XXXXXX")
  log_info "下载 cloudflared $version ($arch)…"
  curl -fL --retry 3 --connect-timeout 15 "$url" -o "$tmp"
  if [[ -n "$digest" && "$digest" == sha256:* ]]; then verify_asset_digest "$tmp" "$digest" || { rm -f "$tmp"; die "cloudflared 校验失败。"; }
  else log_warn "该 Release API 未返回 cloudflared 摘要；仅完成 TLS 下载校验。"; fi
  install -m 0755 "$tmp" "$target"; rm -f "$tmp"; ensure_program_permissions
  "$target" version >/dev/null 2>&1 || die "下载的 cloudflared 核心无法执行。"
  printf '%s\n' "$target"
}

_cloudflared_update() {
  local binary old
  binary=$(cloudflared_download_latest); old=$(readlink -f "$SBM_CLOUDFLARED_BIN" 2>/dev/null || true)
  validate_runtime_binary_path cloudflared "$binary"
  ensure_program_permissions
  if [[ "$old" == "$binary" ]]; then log_ok "cloudflared 已是最新版。"; return; fi
  ln -sfn "$binary" "$SBM_CLOUDFLARED_BIN.new"; mv -Tf "$SBM_CLOUDFLARED_BIN.new" "$SBM_CLOUDFLARED_BIN"
  if [[ "$SBM_SKIP_INIT" != "1" ]] && service_exists "$SBM_TUNNEL_SERVICE" && service_enabled "$SBM_TUNNEL_SERVICE"; then
    if ! service_restart "$SBM_TUNNEL_SERVICE"; then [[ -n "$old" ]] && ln -sfn "$old" "$SBM_CLOUDFLARED_BIN"; service_try_restart "$SBM_TUNNEL_SERVICE" || true; return 1; fi
  fi
  log_ok "cloudflared 已更新至 $(cloudflared_current_version)。"
}
cloudflared_update() { with_lock _cloudflared_update; }
