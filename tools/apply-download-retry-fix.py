from pathlib import Path


def read(path: str) -> str:
    return Path(path).read_text()


def write(path: str, text: str) -> None:
    Path(path).write_text(text)


core = read("lib/core.sh")

anchor = '''cloudflared_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64\\n' ;;
    aarch64|arm64) printf 'arm64\\n' ;;
    armv7l|armv7|armhf) printf 'arm\\n' ;;
    i386|i486|i586|i686) printf '386\\n' ;;
    *) die "暂不支持的 CPU 架构：$(uname -m)" ;;
  esac
}

'''
helper = r'''download_file_with_retries() {
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

'''
if anchor not in core:
    raise SystemExit("cloudflared_arch anchor not found")
core = core.replace(anchor, anchor + helper, 1)

old = '''github_api() {
  local url=$1
  curl -fsSL --retry 3 --connect-timeout 15 -H 'Accept: application/vnd.github+json' -H 'User-Agent: sb-manager' "$url"
}
'''
new = r'''github_api() {
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
'''
if old not in core:
    raise SystemExit("github_api block not found")
core = core.replace(old, new, 1)

old = "core_latest_version() { core_release_json latest | jq -r '.tag_name' | sed 's/^v//'; }\n"
new = r'''core_latest_version() {
  local json tag
  json=$(core_release_json latest) || return 1
  tag=$(jq -r '.tag_name // empty' <<<"$json")
  [[ -n "$tag" ]] || return 1
  printf '%s\n' "${tag#v}"
}
'''
if old not in core:
    raise SystemExit("core_latest_version block not found")
core = core.replace(old, new, 1)

old = '''  arch=$(sb_arch); json=$(core_release_json "$version"); version=$(jq -r '.tag_name' <<<"$json" | sed 's/^v//')
'''
new = '''  arch=$(sb_arch)
  json=$(core_release_json "$version") || die "无法获取 sing-box Release 信息。"
  version=$(jq -r '.tag_name // empty' <<<"$json" | sed 's/^v//')
  [[ -n "$version" ]] || die "sing-box Release 信息缺少版本号。"
'''
if old not in core:
    raise SystemExit("core release assignment not found")
core = core.replace(old, new, 1)

old = '''  curl -fL --retry 3 --connect-timeout 15 "$asset_url" -o "$archive"
  if ! verify_asset_digest "$archive" "$digest"; then
'''
new = '''  download_file_with_retries "$asset_url" "$archive" "sing-box $version" 5
  if ! verify_asset_digest "$archive" "$digest"; then
'''
if old not in core:
    raise SystemExit("sing-box asset curl not found")
core = core.replace(old, new, 1)

old = '''    curl -fL --retry 3 "$checksum_url" -o "$tmpdir/checksums.txt"
    expected=$(awk -v n="$asset_name" '$NF==n {print $1; exit}' "$tmpdir/checksums.txt")
'''
new = '''    download_file_with_retries "$checksum_url" "$tmpdir/checksums.txt" "sing-box checksum" 5
    expected=$(awk -v n="$asset_name" '$NF==n {print $1; exit}' "$tmpdir/checksums.txt")
'''
if old not in core:
    raise SystemExit("checksum curl not found")
core = core.replace(old, new, 1)

old = '''  tar -xzf "$archive" -C "$tmpdir"
  local found
'''
new = '''  if ! tar -xzf "$archive" -C "$tmpdir"; then
    rm -rf "$tmpdir"
    die "sing-box 下载文件无法解压，可能已损坏。"
  fi
  local found
'''
if old not in core:
    raise SystemExit("tar extraction not found")
core = core.replace(old, new, 1)

old = '''_core_update() {
  local version=${1:-latest} latest current
  [[ "$version" == latest ]] && latest=$(core_latest_version) || latest=${version#v}
'''
new = '''_core_update() {
  local version=${1:-latest} latest current
  if [[ "$version" == latest ]]; then
    latest=$(core_latest_version) || die "无法查询 sing-box 最新稳定版本。"
  else
    latest=${version#v}
  fi
'''
if old not in core:
    raise SystemExit("_core_update header not found")
core = core.replace(old, new, 1)

old = '''  current=$(core_current_version || true); latest=$(core_latest_version)
  printf '当前版本：%s\\n最新稳定：%s\\n' "${current:-未安装}" "$latest"
'''
new = '''  current=$(core_current_version || true)
  latest=$(core_latest_version) || die "无法查询 sing-box 最新稳定版本。"
  printf '当前版本：%s\\n最新稳定：%s\\n' "${current:-未安装}" "$latest"
'''
if old not in core:
    raise SystemExit("core_check_update assignment not found")
core = core.replace(old, new, 1)

old = '''  current=$(core_current_version || true); latest=$(core_latest_version)
  [[ "$current" != "$latest" ]] || return 0
'''
new = '''  current=$(core_current_version || true)
  latest=$(core_latest_version) || { log_warn "无法查询 sing-box 最新稳定版本。"; return 1; }
  [[ "$current" != "$latest" ]] || return 0
'''
if old not in core:
    raise SystemExit("core_auto_update assignment not found")
core = core.replace(old, new, 1)

old = "cloudflared_latest_version() { cloudflared_release_json | jq -r '.tag_name' | sed 's/^v//'; }\n"
new = r'''cloudflared_latest_version() {
  local json tag
  json=$(cloudflared_release_json) || return 1
  tag=$(jq -r '.tag_name // empty' <<<"$json")
  [[ -n "$tag" ]] || return 1
  printf '%s\n' "${tag#v}"
}
'''
if old not in core:
    raise SystemExit("cloudflared_latest_version block not found")
core = core.replace(old, new, 1)

old = '''  arch=$(cloudflared_arch); json=$(cloudflared_release_json); version=$(jq -r '.tag_name' <<<"$json" | sed 's/^v//')
'''
new = '''  arch=$(cloudflared_arch)
  json=$(cloudflared_release_json) || die "无法获取 cloudflared Release 信息。"
  version=$(jq -r '.tag_name // empty' <<<"$json" | sed 's/^v//')
  [[ -n "$version" ]] || die "cloudflared Release 信息缺少版本号。"
'''
if old not in core:
    raise SystemExit("cloudflared release assignment not found")
core = core.replace(old, new, 1)

old = '''  curl -fL --retry 3 --connect-timeout 15 "$url" -o "$tmp"
  if [[ -n "$digest" && "$digest" == sha256:* ]]; then verify_asset_digest "$tmp" "$digest" || { rm -f "$tmp"; die "cloudflared 校验失败。"; }
'''
new = '''  download_file_with_retries "$url" "$tmp" "cloudflared $version" 5
  if [[ -n "$digest" && "$digest" == sha256:* ]]; then verify_asset_digest "$tmp" "$digest" || { rm -f "$tmp"; die "cloudflared 校验失败。"; }
'''
if old not in core:
    raise SystemExit("cloudflared asset curl not found")
core = core.replace(old, new, 1)

write("lib/core.sh", core)

# Add a deterministic regression: two reset-like failures must be retried;
# permanent failure must remove the partial output and stop immediately.
test = r'''#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

export SBM_LIB="$PROJECT"
export SBM_PREFIX="$ROOT/usr/local"
export SBM_BIN_DIR="$ROOT/usr/local/bin"
export SBM_ETC="$ROOT/etc/sb-manager"
export SBM_VAR="$ROOT/var/lib/sb-manager"
export SBM_RUN="$ROOT/run/sb-manager"
export SBM_CACHE="$SBM_VAR/cache"
export SBM_BACKUPS="$SBM_VAR/backups"
export SBM_EXPORTS="$SBM_VAR/exports"
export SBM_CORE_DIR="$ROOT/cores"
export SBM_SKIP_INIT=1 SBM_SKIP_SYSTEMD=1 NO_COLOR=1
export FAKE_CURL_COUNT="$ROOT/curl.count"

mkdir -p "$ROOT/fake-bin" "$SBM_CACHE" "$SBM_CORE_DIR"
cat >"$ROOT/fake-bin/curl" <<'EOF_CURL'
#!/usr/bin/env bash
set -u
out=''
while (($#)); do
  case "$1" in
    -o) out=$2; shift 2 ;;
    --connect-timeout|--max-time) shift 2 ;;
    --fail|--location|--silent|--show-error) shift ;;
    *) shift ;;
  esac
done
count=0
[[ ! -f "$FAKE_CURL_COUNT" ]] || count=$(cat "$FAKE_CURL_COUNT")
count=$((count + 1))
printf '%s\n' "$count" >"$FAKE_CURL_COUNT"
printf 'partial' >"$out"
if [[ ${FAKE_CURL_ALWAYS_FAIL:-0} == 1 || $count -lt ${FAKE_CURL_SUCCEED_ON:-3} ]]; then
  exit 35
fi
printf 'complete' >"$out"
EOF_CURL
chmod 0755 "$ROOT/fake-bin/curl"
export PATH="$ROOT/fake-bin:$PATH"

# shellcheck source=lib/common.sh
source "$PROJECT/lib/common.sh"
source "$PROJECT/lib/service.sh"
source "$PROJECT/lib/core.sh"

sleep() { :; }

out="$ROOT/success.bin"
export FAKE_CURL_SUCCEED_ON=3 FAKE_CURL_ALWAYS_FAIL=0
download_file_with_retries 'https://example.invalid/core' "$out" test-core 5
[[ $(cat "$out") == complete ]]
[[ $(cat "$FAKE_CURL_COUNT") == 3 ]]

rm -f "$FAKE_CURL_COUNT"
out_fail="$ROOT/failure.bin"
export FAKE_CURL_ALWAYS_FAIL=1
if (download_file_with_retries 'https://example.invalid/core' "$out_fail" test-core 3 >/dev/null 2>&1); then
  echo 'permanent download failure was unexpectedly accepted' >&2
  exit 1
fi
[[ ! -e "$out_fail" ]]
[[ $(cat "$FAKE_CURL_COUNT") == 3 ]]

printf 'DOWNLOAD RETRY SMOKE PASSED\n'
'''
write("tests/download-retry-smoke.sh", test)

ci = read(".github/workflows/ci.yml")
anchor = '''      - name: First-download path regression
        run: bash tests/core-download-smoke.sh

'''
addition = anchor + '''      - name: Download retry and fail-fast regression
        run: bash tests/download-retry-smoke.sh

'''
if anchor not in ci:
    raise SystemExit("CI first-download anchor missing")
write(".github/workflows/ci.yml", ci.replace(anchor, addition, 1))

# Version and release notes.
write("VERSION", "0.1.0-alpha.6\n")
common = read("lib/common.sh")
if "0.1.0-alpha.5" not in common:
    raise SystemExit("common version marker missing")
write("lib/common.sh", common.replace("0.1.0-alpha.5", "0.1.0-alpha.6", 1))

install_test = read("tests/install-smoke.sh")
if "0.1.0-alpha.5" not in install_test:
    raise SystemExit("install smoke version marker missing")
write("tests/install-smoke.sh", install_test.replace("0.1.0-alpha.5", "0.1.0-alpha.6", 1))

readme = read("README.md")
current = "> 当前版本：`0.1.0-alpha.5`。"
if current not in readme:
    raise SystemExit("README current version marker missing")
write("README.md", readme.replace(current, "> 当前版本：`0.1.0-alpha.6`。", 1))

changelog = read("CHANGELOG.md")
entry = '''# Changelog

## 0.1.0-alpha.6

- Retry all core download failures with bounded backoff instead of relying on curl's limited default retry classes.
- Stop immediately after a failed or empty download and remove partial files before checksum or extraction steps.
- Validate GitHub Release API responses and propagate lookup failures without silently converting `latest` into an invalid version.
- Add deterministic retry/fail-fast coverage while retaining the real first-download smoke test.

'''
if not changelog.startswith("# Changelog\n\n"):
    raise SystemExit("unexpected changelog header")
write("CHANGELOG.md", entry + changelog[len("# Changelog\n\n"):])
