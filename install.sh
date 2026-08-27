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

# Remote bootstrap for:
#   bash <(curl -fsSL https://raw.githubusercontent.com/R1ddle1337/sb-manager/main/install.sh)
REPOSITORY=${SBM_INSTALL_REPOSITORY:-R1ddle1337/sb-manager}
REF=${SBM_INSTALL_REF:-main}
ARCHIVE_URL=${SBM_INSTALL_ARCHIVE_URL:-https://github.com/${REPOSITORY}/archive/refs/heads/${REF}.tar.gz}

command -v curl >/dev/null 2>&1 || { echo '缺少 curl，无法下载安装包。' >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo '缺少 tar，无法解压安装包。' >&2; exit 1; }

TMPDIR_INSTALL=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR_INSTALL"; }
trap cleanup EXIT INT TERM

ARCHIVE="$TMPDIR_INSTALL/source.tar.gz"
printf '正在下载 sb-manager（%s@%s）…\n' "$REPOSITORY" "$REF"
curl --fail --location --silent --show-error \
  --retry 3 --retry-delay 2 --connect-timeout 15 \
  --proto '=https' --tlsv1.2 \
  "$ARCHIVE_URL" -o "$ARCHIVE"

tar -xzf "$ARCHIVE" -C "$TMPDIR_INSTALL"
SETUP=$(find "$TMPDIR_INSTALL" -mindepth 2 -maxdepth 2 -type f -name setup.sh -print -quit)
[[ -n "$SETUP" ]] || { echo '下载的源码包中没有找到 setup.sh。' >&2; exit 1; }

bash "$SETUP" "$@"
