#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

# Local checkout: install directly from the checked-out source tree.
SCRIPT_PATH=${BASH_SOURCE[0]}
if [[ -f "$SCRIPT_PATH" ]]; then
  SCRIPT_DIR=$(cd -- "$(dirname -- "$SCRIPT_PATH")" 2>/dev/null && pwd || true)
  if [[ -n ${SCRIPT_DIR:-} && -f "$SCRIPT_DIR/setup.sh" ]]; then
    exec bash "$SCRIPT_DIR/setup.sh" "$@"
  fi
fi

# Remote source bootstrap. The default "latest" mode resolves main to its
# current immutable commit before downloading; explicit refs may pin a tag or
# commit. Mutable branch refs require an explicit development opt-in.
REPOSITORY=${SBM_INSTALL_REPOSITORY:-R1ddle1337/sb-manager}
DEFAULT_INSTALL_REF=latest
REF=${SBM_INSTALL_REF:-$DEFAULT_INSTALL_REF}
command -v curl >/dev/null 2>&1 || { echo '缺少 curl，无法下载安装包。' >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo '缺少 tar，无法解压安装包。' >&2; exit 1; }
if [[ "$REF" == latest ]]; then
  printf '正在解析 GitHub main 的最新 commit…\n' >&2
  latest_json=$(curl --fail --location --silent --show-error \
    --connect-timeout 15 --max-time 60 -H 'Accept: application/vnd.github+json' \
    -H 'User-Agent: sb-manager' "https://api.github.com/repos/${REPOSITORY}/commits/main") \
    || { echo '无法解析仓库最新 commit。' >&2; exit 1; }
  REF=$(printf '%s\n' "$latest_json" \
    | grep -oE '"sha"[[:space:]]*:[[:space:]]*"[0-9a-fA-F]{40}"' \
    | head -n1 | sed -E 's/.*"([0-9a-fA-F]{40})".*/\1/')
  [[ "$REF" =~ ^[0-9a-fA-F]{40}$ ]] || { echo 'GitHub API 未返回有效 commit SHA。' >&2; exit 1; }
  printf '使用最新不可变 commit：%s\n' "$REF" >&2
elif [[ ${SBM_ALLOW_MUTABLE_REF:-0} != 1 && "$REF" =~ ^(main|master|develop|development|trunk)$ ]]; then
  echo '拒绝使用可变分支；请设置不可变的 SBM_INSTALL_REF（tag 或 commit SHA），或省略它以自动解析最新 commit。' >&2
  exit 1
fi
ARCHIVE_URL=${SBM_INSTALL_ARCHIVE_URL:-https://github.com/${REPOSITORY}/archive/${REF}.tar.gz}
ARCHIVE_SHA256=${SBM_INSTALL_SHA256:-}

TMPDIR_INSTALL=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR_INSTALL"; }
trap cleanup EXIT INT TERM

ARCHIVE="$TMPDIR_INSTALL/source.tar.gz"
printf '正在下载 sb-manager（%s@%s）…\n' "$REPOSITORY" "$REF"
curl --fail --location --silent --show-error \
  --retry 3 --retry-delay 2 --connect-timeout 15 \
  --proto '=https' --tlsv1.2 \
  "$ARCHIVE_URL" -o "$ARCHIVE"

if [[ -n "$ARCHIVE_SHA256" ]]; then
  command -v sha256sum >/dev/null 2>&1 || { echo '缺少 sha256sum，无法校验安装包。' >&2; exit 1; }
  [[ "$ARCHIVE_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || { echo 'SBM_INSTALL_SHA256 不是有效的 SHA-256。' >&2; exit 1; }
  ACTUAL=$(sha256sum "$ARCHIVE" | awk '{print $1}')
  [[ "$ACTUAL" == "$ARCHIVE_SHA256" ]] || { echo '源码归档 SHA-256 校验失败，已拒绝执行。' >&2; exit 1; }
  printf '源码归档 SHA-256 校验通过：%s\n' "$ACTUAL"
else
  printf '%s\n' '警告：未设置 SBM_INSTALL_SHA256；生产环境请固定 commit/ref 并提供摘要。' >&2
fi

tar -xzf "$ARCHIVE" -C "$TMPDIR_INSTALL"
SETUP=$(find "$TMPDIR_INSTALL" -mindepth 2 -maxdepth 2 -type f -name setup.sh -print -quit)
[[ -n "$SETUP" ]] || { echo '下载的源码包中没有找到 setup.sh。' >&2; exit 1; }
bash "$SETUP" "$@"
