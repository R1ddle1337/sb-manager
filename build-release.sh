#!/usr/bin/env bash
set -Eeuo pipefail
SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
VERSION=$(tr -d '[:space:]' <"$SOURCE_DIR/VERSION")
OUTPUT_DIR=${1:-"$SOURCE_DIR/dist"}
SOURCE_COMMIT=$(git -C "$SOURCE_DIR" rev-parse HEAD 2>/dev/null || printf 'unavailable')
mkdir -p "$OUTPUT_DIR"

"$SOURCE_DIR/build-standalone.sh" "$OUTPUT_DIR/sb-manager-install.sh" >/dev/null
bash -n "$OUTPUT_DIR/sb-manager-install.sh"
(
  cd "$OUTPUT_DIR"
  sha256sum sb-manager-install.sh >SHA256SUMS
)
jq -n --arg version "$VERSION" --arg built_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --arg source_commit "$SOURCE_COMMIT" \
  --arg core "$(tr -d '[:space:]' <"$SOURCE_DIR/TESTED_CORE_VERSION")" \
  --arg acme_version 3.1.4 --arg acme_commit 3661fd86b6304115e42f43910e6dd452ab9866d6 \
  '{schema_version:1,manager_version:$version,built_at:$built_at,source_commit:$source_commit,tested_sing_box:$core,
    acme:{version:$acme_version,commit:$acme_commit}}' >"$OUTPUT_DIR/RELEASE-MANIFEST.json"
(
  cd "$OUTPUT_DIR"
  sha256sum RELEASE-MANIFEST.json SHA256SUMS >PROVENANCE-SHA256SUMS
)
if [[ -n ${SBM_RELEASE_SIGNING_KEY:-} ]]; then
  command -v gpg >/dev/null 2>&1 || { echo 'SBM_RELEASE_SIGNING_KEY 已设置但未找到 gpg。' >&2; exit 1; }
  gpg --batch --yes --armor --local-user "$SBM_RELEASE_SIGNING_KEY" \
    --detach-sign --output "$OUTPUT_DIR/RELEASE-MANIFEST.json.asc" "$OUTPUT_DIR/RELEASE-MANIFEST.json"
  gpg --batch --yes --armor --local-user "$SBM_RELEASE_SIGNING_KEY" \
    --detach-sign --output "$OUTPUT_DIR/SHA256SUMS.asc" "$OUTPUT_DIR/SHA256SUMS"
  printf 'Signed provenance: %s and %s\n' "$OUTPUT_DIR/RELEASE-MANIFEST.json.asc" "$OUTPUT_DIR/SHA256SUMS.asc"
else
  printf '%s\n' 'WARNING: 未设置 SBM_RELEASE_SIGNING_KEY；发布前请使用 GPG 签名 RELEASE-MANIFEST.json 和 SHA256SUMS。' >&2
fi
printf 'Release bundle created in %s\n' "$OUTPUT_DIR"
