#!/usr/bin/env bash
# shellcheck shell=bash

if ! declare -F prepare_singbox_binary_for_backend >/dev/null 2>&1; then
  # shellcheck source=lib/runtime-security.sh
  source "$SBM_LIB/lib/runtime-security.sh"
fi

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

download_file_with_retries() {
  local url=$1 output=$2 label=${3:-文件} attempts=${4:-5} attempt delay
  rm -f "$output"
  for ((attempt=1; attempt<=attempts; attempt++)); do
    if curl --fail --location --silent --show-error \
      --connect-timeout 15 --max-time 600 \
      "$url" -o "$output"; then
      if [[ -s "$output" ]]; then
        return 0
      fi
      log_warn "$label 下载结果为空（第 $attempt/$attempts 次）。"
    else
      log_warn "$label 下载失败（第 $attempt/$attempts 次）。"
    fi
    rm -f "$output"
    (( attempt < attempts )) || break
    delay=$((attempt * 2))
    sleep "$delay"
  done
  die "$label 下载失败，已重试 $attempts 次。"
}

github_api() {
  local url=$1 attempt output delay attempts=5
  for ((attempt=1; attempt<=attempts; attempt++)); do
    if output=$(curl --fail --silent --show-error --location \
      --connect-timeout 15 --max-time 120 \
      -H 'Accept: application/vnd.github+json' \
      -H 'User-Agent: sb-manager' "$url"); then
      if [[ -n "$output" ]]; then
        printf '%s\n' "$output"
        return 0
      fi
    fi
    log_warn "GitHub API 请求失败（第 $attempt/$attempts 次）。"
    (( attempt < attempts )) || break
    delay=$((attempt * 2))
    sleep "$delay"
  done
  return 1
}

core_release_json() {
  local version=${1:-latest}
  if [[ "$version" == latest ]]; then github_api 'https://api.github.com/repos/SagerNet/sing-box/releases/latest';
  else github_api "https://api.github.com/repos/SagerNet/sing-box/releases/tags/v${version#v}"; fi
}

core_latest_version() {
  local json tag
  json=$(github_api 'https://api.github.com/repos/SagerNet/sing-box/releases?per_page=20') || return 1
  tag=$(jq -r 'map(select(.draft == false)) | first.tag_name // empty' <<<"$json")
  [[ -n "$tag" ]] || return 1
  printf '%s\n' "${tag#v}"
}
core_current_version() {
  local output
  [[ -x "$SBM_SING_BOX_BIN" ]] || return 0
  output=$("$SBM_SING_BOX_BIN" version 2>/dev/null) || return 1
  extract_semver "$output"
}

core_version_series() {
  local version=${1#v}
  [[ "$version" =~ ^([0-9]+)\.([0-9]+)\. ]] || return 1
  printf '%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

core_validate_build_tags() {
  local binary=$1 state=${2:-$SBM_STATE} output
  [[ -s "$state" ]] || return 0
  output=$("$binary" version 2>/dev/null) || return 1
  if jq -e '.nodes[]? | select(.enabled==true and (.protocol=="hysteria2" or .protocol=="tuic"))' "$state" >/dev/null; then
    grep -Eq '(^|[,[:space:]])with_quic([,[:space:]]|$)' <<<"$output" || { log_error '当前配置需要 with_quic 构建标签。'; return 1; }
  fi
  if jq -e '.nodes[]? | select(.enabled==true and .protocol=="vless" and .security=="reality")' "$state" >/dev/null; then
    grep -Eq '(^|[,[:space:]])with_utls([,[:space:]]|$)' <<<"$output" || { log_error '当前 Reality 配置需要 with_utls 构建标签。'; return 1; }
  fi
  if jq -e '.nodes[]? | select(.enabled==true and .protocol=="snell")' "$state" >/dev/null; then
    version_ge "$(extract_semver "$output")" 1.14.0-rc.1 || { log_error '当前 Snell 配置需要 sing-box 1.14.0-rc.1 或更高版本核心。'; return 1; }
  fi
}

verify_asset_digest() {
  local file=$1 digest=${2:-}
  [[ -n "$digest" && "$digest" == sha256:* ]] || return 2
  local expected=${digest#sha256:} actual
  actual=$(sha256sum "$file" | awk '{print $1}')
  [[ "$actual" == "$expected" ]]
}

artifact_record() {
  local name=$1 version=$2 url=$3 digest=$4 binary=${5:-} manifest tmp details='' binary_digest=''
  manifest="$SBM_VAR/install-manifest.json"
  mkdir -p "$SBM_VAR"
  if [[ -n "$binary" && -x "$binary" ]]; then
    details=$("$binary" version 2>/dev/null | head -n 20 || true)
    binary_digest="sha256:$(sha256sum "$binary" | awk '{print $1}')"
  fi
  tmp=$(mktemp "$SBM_VAR/.install-manifest.XXXXXX")
  if [[ -s "$manifest" ]] && jq -e 'type=="object" and (.artifacts|type=="array")' "$manifest" >/dev/null 2>&1; then
    jq --arg name "$name" --arg version "$version" --arg url "$url" --arg digest "$digest" \
      --arg installed_at "$(now_iso)" --arg details "$details" --arg binary_digest "$binary_digest" '
        .artifacts |= (map(select(.name != $name)) + [{
          name:$name, version:$version, source_url:$url, digest:$digest,
          installed_at:$installed_at, binary_digest:$binary_digest, version_output:$details
        }])
      ' "$manifest" >"$tmp"
  else
    jq -n --arg name "$name" --arg version "$version" --arg url "$url" --arg digest "$digest" \
      --arg installed_at "$(now_iso)" --arg details "$details" --arg binary_digest "$binary_digest" '{schema_version:1,artifacts:[{
        name:$name,version:$version,source_url:$url,digest:$digest,
        installed_at:$installed_at,binary_digest:$binary_digest,version_output:$details
      }]}' >"$tmp"
  fi
  chmod 0640 "$tmp"
  mv -f "$tmp" "$manifest"
}

core_download_version() {
  local version=$1 arch json asset_name asset_url digest checksum_url tmpdir archive target expected found found_dir
  arch=$(sb_arch)
  json=$(core_release_json "$version") || die "无法获取 sing-box Release 信息。"
  version=$(jq -r '.tag_name // empty' <<<"$json" | sed 's/^v//')
  [[ -n "$version" ]] || die "sing-box Release 信息缺少版本号。"
  asset_name="sing-box-${version}-linux-${arch}.tar.gz"
  asset_url=$(jq -r --arg n "$asset_name" 'first(.assets[] | select(.name==$n) | .browser_download_url) // empty' <<<"$json")
  digest=$(jq -r --arg n "$asset_name" 'first(.assets[] | select(.name==$n) | (.digest // "")) // empty' <<<"$json")
  [[ -n "$asset_url" ]] || die "官方 Release 中未找到：$asset_name"
  target="$SBM_CORE_DIR/sing-box/$version/sing-box"
  if [[ -x "$target" ]]; then
    "$target" version 2>/dev/null | grep -Fq "$version" || die "已缓存的 sing-box $version 无法通过版本校验。"
    ensure_program_permissions
    prepare_singbox_binary_for_backend "$target"
    artifact_record sing-box "$version" "$asset_url" "${digest:-previously-verified}" "$target"
    printf '%s\n' "$target"
    return 0
  fi
  tmpdir=$(mktemp -d "$SBM_CACHE/sing-box.XXXXXX"); archive="$tmpdir/$asset_name"
  log_info "下载 sing-box $version ($arch)…"
  download_file_with_retries "$asset_url" "$archive" "sing-box $version" 5
  if ! verify_asset_digest "$archive" "$digest"; then
    checksum_url=$(jq -r 'first(.assets[] | select(.name|test("checksums.*\\.txt$|checksum.*\\.txt$";"i")) | .browser_download_url) // empty' <<<"$json")
    [[ -n "$checksum_url" ]] || { rm -rf "$tmpdir"; die "Release 未提供可用 SHA-256 摘要，已拒绝安装。"; }
    download_file_with_retries "$checksum_url" "$tmpdir/checksums.txt" "sing-box checksum" 5
    expected=$(awk -v n="$asset_name" '$NF==n {print $1; exit}' "$tmpdir/checksums.txt")
    [[ -n "$expected" && "$expected" == "$(sha256sum "$archive" | awk '{print $1}')" ]] || { rm -rf "$tmpdir"; die "sing-box 下载文件校验失败。"; }
    digest="sha256:$expected"
  fi
  mkdir -p "$SBM_CORE_DIR/sing-box/$version"
  chmod 0755 "$SBM_CORE_DIR" "$SBM_CORE_DIR/sing-box" "$SBM_CORE_DIR/sing-box/$version"
  if ! tar -xzf "$archive" -C "$tmpdir"; then
    rm -rf "$tmpdir"
    die "sing-box 下载文件无法解压，可能已损坏。"
  fi
  local found
  found=$(find "$tmpdir" -type f -name sing-box -perm -u+x -print -quit)
  [[ -n "$found" ]] || { rm -rf "$tmpdir"; die "压缩包中未找到 sing-box。"; }
  install -m 0755 "$found" "$target"
  found_dir=$(dirname "$found")
  if [[ -f "$found_dir/libcronet.so" ]]; then
    install -m 0755 "$found_dir/libcronet.so" "$(dirname "$target")/libcronet.so"
  fi
  ensure_program_permissions
  if ! "$target" version >/dev/null 2>&1; then
    rm -rf "$tmpdir"
    if [[ -f /etc/alpine-release ]]; then
      die "sing-box 官方核心无法在当前 Alpine 运行；请确认已安装 gcompat。"
    fi
    die "下载的 sing-box 核心无法执行。"
  fi
  prepare_singbox_binary_for_backend "$target"
  artifact_record sing-box "$version" "$asset_url" "$digest" "$target"
  rm -rf "$tmpdir"
  printf '%s\n' "$target"
}

core_switch_to() {
  local version=$1 binary current_target previous transition_snapshot
  binary="$SBM_CORE_DIR/sing-box/${version#v}/sing-box"
  [[ -x "$binary" ]] || binary=$(core_download_version "$version")
  validate_runtime_binary_path sing-box "$binary"
  ensure_program_permissions
  prepare_singbox_binary_for_backend "$binary"
  if [[ -s "$SBM_CONFIG" ]]; then core_validate_config_with "$binary" "$SBM_CONFIG" "$SBM_RUN/core-candidate-check.log" || return 1; fi
  core_validate_build_tags "$binary" "$SBM_STATE" || return 1
  current_target=$(readlink -f "$SBM_SING_BOX_BIN" 2>/dev/null || true)
  previous=${current_target:-none}
  transition_snapshot=$(snapshot_create "core-before-${version#v}")
  mkdir -p "$SBM_BIN_DIR" "$SBM_VAR/core-history"
  ln -sfn "$binary" "$SBM_SING_BOX_BIN.new"
  mv -Tf "$SBM_SING_BOX_BIN.new" "$SBM_SING_BOX_BIN"
  ensure_program_permissions
  if [[ "$SBM_SKIP_INIT" != "1" ]] && service_exists "$SBM_SERVICE"; then
    if ! singbox_service_reconcile; then
      log_error "新核心启动失败，恢复旧核心。"
      if [[ -n "$current_target" && -x "$current_target" ]]; then
        prepare_singbox_binary_for_backend "$current_target"
        ln -sfn "$current_target" "$SBM_SING_BOX_BIN"
        singbox_service_reconcile || true
      fi
      return 1
    fi
  fi
  printf '%s\t%s\t%s\t%s\n' "$(now_iso)" "$previous" "$binary" "$transition_snapshot" >>"$SBM_VAR/core-history/sing-box.tsv"
  log_ok "sing-box 已切换到 $(core_current_version)。"
}

_core_update() {
  local version=${1:-latest} latest current
  if [[ "$version" == latest ]]; then
    latest=$(core_latest_version) || die "无法查询 sing-box 最新官方版本。"
  else
    latest=${version#v}
  fi
  current=$(core_current_version || true)
  if [[ "$current" == "$latest" ]]; then log_ok "sing-box 已是目标版本 $latest。"; return 0; fi
  core_download_version "$latest" >/dev/null
  core_switch_to "$latest"
}
core_update() { with_lock _core_update "${1:-latest}"; }

core_check_update() {
  local current latest
  current=$(core_current_version || true)
  latest=$(core_latest_version) || die "无法查询 sing-box 最新官方版本。"
  printf '当前版本：%s\n最新官方版本：%s\n' "${current:-未安装}" "$latest"
  [[ "$current" == "$latest" ]] || return 10
}

core_schema() {
  local output=${1:-} version
  version=$(core_current_version || true)
  version_ge "$version" 1.14.0-beta.2 || die 'sing-box schema 命令需要 1.14.0-beta.2 或更高版本核心。'
  [[ -x "$SBM_SING_BOX_BIN" ]] || die "sing-box 核心不存在：$SBM_SING_BOX_BIN"
  if [[ -n "$output" ]]; then
    mkdir -p "$(dirname "$output")"
    "$SBM_SING_BOX_BIN" schema >"$output"
    chmod 0644 "$output"
    jq -e . "$output" >/dev/null || die 'sing-box schema 输出不是有效 JSON。'
    log_ok "已导出 sing-box JSON Schema：$output"
  else
    "$SBM_SING_BOX_BIN" schema
  fi
}

_core_set_policy() {
  local policy=$1 candidate
  case "$policy" in manual|notify|patch|stable) ;; *) die "策略必须是 manual、notify、patch 或 stable。";; esac
  candidate=$(state_candidate)
  jq --arg p "$policy" '.settings.core_update_policy=$p' "$SBM_STATE" >"$candidate"
  if ! apply_candidate_state "$candidate" core-policy; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  log_ok "自动更新策略：$policy"
}
core_set_policy() { with_state_transaction core-policy _core_set_policy "$@"; }

core_auto_update() {
  local policy current latest cmj cmi lmj lmi
  policy=$(jq -r '.settings.core_update_policy // "notify"' "$SBM_STATE")
  [[ "$policy" != manual ]] || return 0
  current=$(core_current_version || true)
  latest=$(core_latest_version) || { log_warn "无法查询 sing-box 最新官方版本。"; return 1; }
  [[ "$current" != "$latest" ]] || return 0
  mkdir -p "$SBM_VAR/updates"
  jq -n --arg now "$(now_iso)" --arg current "$current" --arg latest "$latest" --arg policy "$policy" '{checked_at:$now,current:$current,latest:$latest,policy:$policy}' >"$SBM_VAR/updates/sing-box.json"
  case "$policy" in
    notify) log_warn "发现 sing-box 更新：$current → $latest。运行 sb core update。" ;;
    patch)
      IFS=. read -r cmj cmi _ <<<"$current"; IFS=. read -r lmj lmi _ <<<"$latest"
      if [[ "$cmj.$cmi" == "$lmj.$lmi" ]]; then _core_update "$latest"; else log_warn "发现跨 minor 更新 $latest；patch 策略不自动安装。"; fi
      ;;
    stable)
      if [[ $(core_version_series "$current" 2>/dev/null || true) == "$(core_version_series "$latest" 2>/dev/null || true)" ]]; then
        _core_update "$latest"
      else
        log_warn "发现跨 minor 版本 $latest；为避免配置迁移风险，仅通知并保留当前 $current。请手动运行 sb core update $latest。"
      fi
      ;;
  esac
}

core_rollback() {
  local current candidate version history_line previous paired_snapshot safety
  current=$(readlink -f "$SBM_SING_BOX_BIN" 2>/dev/null || true)
  if [[ -s "$SBM_VAR/core-history/sing-box.tsv" ]]; then
    history_line=$(awk -F '\t' -v cur="$current" '$3==cur && $2!="none" {line=$0} END {print line}' "$SBM_VAR/core-history/sing-box.tsv")
    if [[ -n "$history_line" ]]; then
      IFS=$'\t' read -r _ previous _ paired_snapshot <<<"$history_line"
      [[ -x "$previous" ]] && candidate=$previous
    fi
  fi
  if [[ -z ${candidate:-} ]]; then
    candidate=$(find "$SBM_CORE_DIR/sing-box" -mindepth 2 -maxdepth 2 -type f -name sing-box -perm -u+x -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk -v cur="$current" '$2!=cur {print $2; exit}')
  fi
  [[ -n "$candidate" ]] || die "没有可回滚的旧核心。"
  safety=$(snapshot_create core-rollback-safety)
  if [[ -s "$SBM_CONFIG" ]] && ! core_validate_config_with "$candidate" "$SBM_CONFIG" "$SBM_RUN/core-rollback-check.log"; then
    [[ -n ${paired_snapshot:-} && -d "$paired_snapshot" ]] || die "旧核心不兼容当前配置，且没有已知可用的配对快照。"
    cp -a "$paired_snapshot/state.json" "$SBM_STATE"
    cp -a "$paired_snapshot/config.json" "$SBM_CONFIG"
    snapshot_restore_payload "$paired_snapshot"
    if ! core_validate_config_with "$candidate" "$SBM_CONFIG" "$SBM_RUN/core-rollback-paired-check.log"; then
      snapshot_restore "$safety" || true
      die "旧核心与配对快照仍不兼容，已恢复回滚前状态。"
    fi
    log_warn "当前配置与旧核心不兼容，已恢复升级前配对快照：$paired_snapshot"
  fi
  version=$(basename "$(dirname "$candidate")")
  core_switch_to "$version" || { snapshot_restore "$safety" || true; return 1; }
}

cloudflared_release_json() { github_api 'https://api.github.com/repos/cloudflare/cloudflared/releases/latest'; }
cloudflared_latest_version() {
  local json tag
  json=$(cloudflared_release_json) || return 1
  tag=$(jq -r '.tag_name // empty' <<<"$json")
  [[ -n "$tag" ]] || return 1
  printf '%s\n' "${tag#v}"
}
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
  arch=$(cloudflared_arch)
  json=$(cloudflared_release_json) || die "无法获取 cloudflared Release 信息。"
  version=$(jq -r '.tag_name // empty' <<<"$json" | sed 's/^v//')
  [[ -n "$version" ]] || die "cloudflared Release 信息缺少版本号。"
  asset_name="cloudflared-linux-${arch}"
  url=$(jq -r --arg n "$asset_name" 'first(.assets[] | select(.name==$n) | .browser_download_url) // empty' <<<"$json")
  digest=$(jq -r --arg n "$asset_name" 'first(.assets[] | select(.name==$n) | (.digest // "")) // empty' <<<"$json")
  [[ -n "$url" ]] || die "未找到 cloudflared 资产：$asset_name"
  target="$SBM_CORE_DIR/cloudflared/$version/cloudflared"
  if [[ -x "$target" ]]; then
    "$target" version 2>/dev/null | grep -Fq "$version" || die "已缓存的 cloudflared $version 无法通过版本校验。"
    ensure_program_permissions
    artifact_record cloudflared "$version" "$url" "${digest:-previously-verified}" "$target"
    printf '%s\n' "$target"
    return 0
  fi
  mkdir -p "$(dirname "$target")"
  chmod 0755 "$SBM_CORE_DIR" "$SBM_CORE_DIR/cloudflared" "$(dirname "$target")"
  tmp=$(mktemp "$SBM_CACHE/cloudflared.XXXXXX")
  log_info "下载 cloudflared $version ($arch)…"
  download_file_with_retries "$url" "$tmp" "cloudflared $version" 5
  [[ -n "$digest" && "$digest" == sha256:* ]] || { rm -f "$tmp"; die "Release API 未提供 cloudflared SHA-256 摘要，已拒绝安装。"; }
  verify_asset_digest "$tmp" "$digest" || { rm -f "$tmp"; die "cloudflared 校验失败。"; }
  install -m 0755 "$tmp" "$target"; rm -f "$tmp"; ensure_program_permissions
  "$target" version >/dev/null 2>&1 || die "下载的 cloudflared 核心无法执行。"
  artifact_record cloudflared "$version" "$url" "$digest" "$target"
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
