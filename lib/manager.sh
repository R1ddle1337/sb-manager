#!/usr/bin/env bash
# shellcheck shell=bash

manager_update() (
  set -Eeuo pipefail
  local check_only=0 repository current='' latest response stage
  case "${1:-}" in
    --check) check_only=1; shift ;;
    '') ;;
    *) usage_die '用法：sb update [--check]' ;;
  esac
  (($# == 0)) || usage_die '用法：sb update [--check]'
  [[ ${SBM_DRY_RUN:-0} != 1 ]] || check_only=1
  if (( ! check_only )); then
    [[ ${SBM_TEST_MODE:-0} == 1 ]] || require_root
  fi
  require_command curl
  require_command jq
  repository=${SBM_INSTALL_REPOSITORY:-}
  if [[ -z "$repository" && -r "$SBM_LIB/INSTALL_REPOSITORY" ]]; then
    repository=$(cat "$SBM_LIB/INSTALL_REPOSITORY")
  fi
  repository=${repository:-R1ddle1337/sb-manager}
  [[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die '无效的 GitHub 仓库名。'
  [[ ! -r "$SBM_LIB/INSTALL_COMMIT" ]] || current=$(cat "$SBM_LIB/INSTALL_COMMIT")
  printf '当前脚本：%s（commit：%s）\n' "$SBM_VERSION" "${current:-未记录}"
  response=$(curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
    --connect-timeout 15 --max-time 60 -H 'Accept: application/vnd.github+json' \
    -H 'User-Agent: sb-manager' "https://api.github.com/repos/$repository/commits/main") \
    || die '检查脚本更新失败，请检查 GitHub 网络连接后重试。'
  latest=$(jq -er '.sha | select(type=="string" and test("^[0-9a-fA-F]{40}$"))' <<<"$response") \
    || die 'GitHub 未返回有效的脚本 commit。'
  if [[ "$current" == "$latest" ]]; then
    printf '脚本已经是最新版本。\n'
    exit 0
  fi
  printf '可更新至 commit：%s\n' "$latest"
  (( ! check_only )) || { printf '执行 sb update 更新脚本；当前核心和节点将保留。\n'; exit 0; }
  [[ -x "$SBM_SING_BOX_BIN" ]] || die '未找到已安装核心；请重新运行安装器。'
  stage=$(mktemp -d)
  trap 'rm -rf -- "$stage"' EXIT
  # Run a private copy: setup replaces the installed scripts during upgrade.
  cp "$SBM_LIB/install.sh" "$stage/install.sh"
  printf '正在更新脚本，保留当前核心、节点、密钥和证书；服务可能短暂重启。\n'
  SBM_INSTALL_REPOSITORY="$repository" SBM_INSTALL_REF="$latest" \
    bash "$stage/install.sh" --no-menu --keep-core
  printf '脚本更新完成：%s。\n' "$(cat "$SBM_LIB/VERSION")"
)
