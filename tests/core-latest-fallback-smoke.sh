#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ARCHIVE="$ROOT/fallback.tar.gz"
mkdir -p "$ROOT/archive/sing-box-1.14.0-rc.4-linux-amd64"
cat >"$ROOT/archive/sing-box-1.14.0-rc.4-linux-amd64/sing-box" <<'EOF_CORE'
#!/usr/bin/env bash
if [[ ${1:-} == version ]]; then printf 'sing-box version 1.14.0-rc.4\n'; fi
EOF_CORE
chmod 0755 "$ROOT/archive/sing-box-1.14.0-rc.4-linux-amd64/sing-box"
tar -C "$ROOT/archive" -czf "$ARCHIVE" sing-box-1.14.0-rc.4-linux-amd64

export SBM_LIB="$PROJECT" SBM_PREFIX="$ROOT/usr/local" SBM_BIN_DIR="$ROOT/usr/local/bin"
export SBM_ETC="$ROOT/etc/sb-manager" SBM_VAR="$ROOT/var/lib/sb-manager" SBM_RUN="$ROOT/run/sb-manager"
export SBM_STATE="$SBM_ETC/state.json" SBM_GENERATED_DIR="$SBM_ETC/generated"
export SBM_CONFIG="$SBM_GENERATED_DIR/config.json"
export SBM_SECRETS="$SBM_ETC/secrets" SBM_CERTS="$SBM_ETC/certs" SBM_BACKUPS="$SBM_VAR/backups"
export SBM_EXPORTS="$SBM_VAR/exports" SBM_CACHE="$SBM_VAR/cache" SBM_CORE_DIR="$ROOT/cores" SBM_LOCK="$SBM_RUN/lock"
export SBM_SING_BOX_BIN="$SBM_BIN_DIR/sing-box" SBM_CLOUDFLARED_BIN="$SBM_BIN_DIR/cloudflared"
export SBM_SKIP_INIT=1 SBM_SKIP_SYSTEMD=1 NO_COLOR=1

mkdir -p "$ROOT/bin"
cat >"$ROOT/bin/curl" <<'EOF_CURL'
#!/usr/bin/env bash
set -Eeuo pipefail
out=''
for ((i=1; i<=$#; i++)); do
  if [[ ${!i} == -o ]]; then
    j=$((i + 1)); out=${!j}
  fi
done
[[ -n "$out" ]] || { echo 'fallback smoke expected -o' >&2; exit 1; }
cp "$SBM_FALLBACK_ARCHIVE" "$out"
EOF_CURL
chmod 0755 "$ROOT/bin/curl"
export SBM_FALLBACK_ARCHIVE="$ARCHIVE" PATH="$ROOT/bin:$PATH"

source "$PROJECT/lib/common.sh"
source "$PROJECT/lib/service.sh"
source "$PROJECT/lib/core.sh"

version_ge 1.14.0 1.14.0-rc.4
if version_ge 1.14.0-rc.4 1.14.0; then
  echo 'semver prerelease comparison is reversed' >&2
  exit 1
fi
github_api() { printf '%s\n' '[{"draft":true,"tag_name":"v99.0.0"},{"draft":false,"tag_name":"v9.9.9"}]'; }
[[ $(core_latest_version) == 9.9.9 ]]
github_api() { return 1; }
# The production fallback digest is checked separately below.  Override the
# digest only for this tiny local archive so the test does not need to carry a
# 32MB release asset in the repository.
core_fallback_asset_digest() { printf 'sha256:%s\n' "$(sha256sum "$SBM_FALLBACK_ARCHIVE" | awk '{print $1}')"; }
export SBM_FALLBACK_ARCHIVE="$ARCHIVE"
latest=$(core_latest_version 2>"$ROOT/fallback.log")
[[ "$latest" == 1.14.0-rc.4 ]]
grep -Fq '回退到 1.14.0-rc.4' "$ROOT/fallback.log"
if core_latest_version_strict >/dev/null 2>&1; then
  echo 'strict latest lookup unexpectedly succeeded' >&2
  exit 1
fi

target=$(core_download_version latest 2>"$ROOT/download.log")
[[ -x "$target" ]]
"$target" version | grep -Fq '1.14.0-rc.4'
grep -Fq '内置且已校验的资产信息' "$ROOT/download.log"

(source "$PROJECT/lib/core.sh"; [[ $(core_fallback_asset_digest 1.14.0-rc.4 amd64) == sha256:3d745827f1e7e2b6caf5788e2f94b7957ecea0b7a68f27e52ef90fdb9be6b4f8 ]])

mkdir -p "$SBM_CORE_DIR/sing-box/1.14.0"
cat >"$SBM_CORE_DIR/sing-box/1.14.0/sing-box" <<'EOF_STABLE'
#!/usr/bin/env bash
[[ ${1:-} == version ]] && printf 'sing-box version 1.14.0\n'
EOF_STABLE
chmod 0755 "$SBM_CORE_DIR/sing-box/1.14.0/sing-box"
mkdir -p "$SBM_BIN_DIR"
ln -sfn "$SBM_CORE_DIR/sing-box/1.14.0/sing-box" "$SBM_SING_BOX_BIN"
_core_update latest >"$ROOT/no-downgrade.log" 2>&1
grep -Fq '跳过可能的降级' "$ROOT/no-downgrade.log"
[[ $(readlink -f "$SBM_SING_BOX_BIN") == "$SBM_CORE_DIR/sing-box/1.14.0/sing-box" ]]

printf 'CORE LATEST FALLBACK SMOKE PASSED\n'
