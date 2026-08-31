#!/usr/bin/env bash
# shellcheck shell=bash

# Dependency policy
# -----------------
# The installer deliberately keeps the base set small.  Optional features
# call dependency_require_feature() immediately before they need a command,
# so a small Alpine VPS does not pay for Python, nftables, kmod, cron, etc.

dependency_distro() {
  if command_exists apk || [[ -f /etc/alpine-release ]]; then
    printf 'alpine\n'
  elif command_exists apt-get; then
    printf 'debian\n'
  elif command_exists dnf; then
    printf 'dnf\n'
  elif command_exists yum; then
    printf 'yum\n'
  elif command_exists pacman; then
    printf 'pacman\n'
  elif command_exists zypper; then
    printf 'zypper\n'
  else
    printf 'unknown\n'
  fi
}

dependency_package_hint() {
  local feature=${1:-base} distro
  distro=$(dependency_distro)
  case "$feature:$distro" in
    base:alpine) printf 'apk add --no-cache bash curl ca-certificates jq openssl coreutils findutils flock gcompat libcap-utils\n' ;;
    base:debian) printf 'apt-get install --no-install-recommends bash curl ca-certificates jq openssl coreutils findutils util-linux\n' ;;
    low-port:alpine) printf 'apk add --no-cache libcap-utils\n' ;;
    low-port:debian) printf 'apt-get install --no-install-recommends libcap2-bin\n' ;;
    traffic:alpine) printf 'apk add --no-cache nftables\n' ;;
    traffic:debian) printf 'apt-get install --no-install-recommends nftables\n' ;;
    subscription:alpine) printf 'apk add --no-cache python3\n' ;;
    subscription:debian) printf 'apt-get install --no-install-recommends python3\n' ;;
    bbr:alpine) printf 'apk add --no-cache kmod\n' ;;
    bbr:debian) printf 'apt-get install --no-install-recommends kmod\n' ;;
    probe:alpine) printf 'apk add --no-cache iproute2-ss\n' ;;
    probe:debian) printf 'apt-get install --no-install-recommends iproute2\n' ;;
    scheduler:alpine) printf 'apk add --no-cache dcron\n' ;;
    logrotate:alpine) printf 'apk add --no-cache logrotate\n' ;;
    logrotate:debian) printf 'apt-get install --no-install-recommends logrotate\n' ;;
    *) printf '%s\n' '请使用当前发行版的包管理器安装缺少的依赖。' ;;
  esac
}

dependency_install_packages() {
  local rc=0
  local -a packages=("$@")
  ((${#packages[@]} > 0)) || return 0

  if [[ -n ${SBM_DEPENDENCY_INSTALLER:-} ]]; then
    "$SBM_DEPENDENCY_INSTALLER" "${packages[@]}"
    return $?
  fi
  if [[ ${SBM_TEST_MODE:-0} == 1 ]]; then
    log_error "测试模式禁止安装系统依赖：${packages[*]}"
    return 1
  fi
  if [[ ${SBM_DRY_RUN:-0} == 1 ]]; then
    log_error "dry-run 模式不会安装系统依赖：${packages[*]}"
    return 1
  fi
  [[ ${SBM_AUTO_INSTALL_DEPENDENCIES:-1} == 1 ]] || {
    log_error "缺少可选依赖：${packages[*]}。可手工执行：$(dependency_package_hint "${SBM_DEPENDENCY_FEATURE:-base}")"
    return 1
  }

  case "$(dependency_distro)" in
    alpine)
      apk add --no-cache "${packages[@]}" || rc=$?
      ;;
    debian)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y || rc=$?
      if (( rc == 0 )); then
        apt-get install -y --no-install-recommends "${packages[@]}" || rc=$?
      fi
      ;;
    dnf)
      dnf install -y "${packages[@]}" || rc=$?
      ;;
    yum)
      yum install -y "${packages[@]}" || rc=$?
      ;;
    pacman)
      pacman -Sy --noconfirm --needed "${packages[@]}" || rc=$?
      ;;
    zypper)
      zypper --non-interactive install "${packages[@]}" || rc=$?
      ;;
    *)
      log_error "未找到支持的包管理器，无法安装：${packages[*]}"
      return 1
      ;;
  esac
  return "$rc"
}

dependency_install_base() {
  local profile=${1:-minimal} distro
  local -a packages=()
  distro=$(dependency_distro)
  case "$distro" in
    alpine)
      # Keep gcompat because official sing-box Linux archives use the glibc
      # ABI.  libcap-utils is small but required for OpenRC low-port binding.
      packages=(bash curl ca-certificates jq openssl coreutils findutils flock gcompat libcap-utils)
      [[ "$profile" == full ]] && packages+=(iproute2 nftables python3 kmod logrotate dcron)
      if ! command_exists tar; then packages+=(tar); fi
      if ! command_exists gzip; then packages+=(gzip); fi
      if ! command_exists rc-service || ! command_exists rc-update || ! command_exists openrc-run; then packages+=(openrc); fi
      if { ! command_exists adduser && ! command_exists useradd; } || { ! command_exists addgroup && ! command_exists groupadd; }; then packages+=(shadow); fi
      ;;
    debian)
      packages=(bash curl ca-certificates jq openssl coreutils findutils)
      command_exists flock || packages+=(util-linux)
      command_exists tar || packages+=(tar)
      command_exists gzip || packages+=(gzip)
      if { ! command_exists useradd && ! command_exists adduser; } || { ! command_exists groupadd && ! command_exists addgroup; }; then packages+=(passwd); fi
      if [[ ${SBM_INIT_SYSTEM:-auto} == openrc ]] || { command_exists rc-service && command_exists rc-update; }; then packages+=(libcap2-bin); fi
      [[ "$profile" == full ]] && packages+=(iproute2 nftables python3 kmod logrotate)
      ;;
    dnf|yum)
      packages=(bash curl ca-certificates jq openssl coreutils findutils util-linux)
      if [[ ${SBM_INIT_SYSTEM:-auto} == openrc ]] || { command_exists rc-service && command_exists rc-update; }; then packages+=(libcap); fi
      [[ "$profile" == full ]] && packages+=(iproute nftables python3 kmod logrotate)
      ;;
    pacman)
      packages=(bash curl ca-certificates jq openssl coreutils findutils util-linux)
      if [[ ${SBM_INIT_SYSTEM:-auto} == openrc ]] || { command_exists rc-service && command_exists rc-update; }; then packages+=(libcap); fi
      [[ "$profile" == full ]] && packages+=(iproute2 nftables python kmod logrotate)
      ;;
    zypper)
      packages=(bash curl ca-certificates jq openssl coreutils findutils util-linux)
      if [[ ${SBM_INIT_SYSTEM:-auto} == openrc ]] || { command_exists rc-service && command_exists rc-update; }; then packages+=(libcap-progs); fi
      [[ "$profile" == full ]] && packages+=(iproute2 nftables python3 kmod logrotate)
      ;;
    *)
      log_error '不支持的包管理器。当前支持 apk、apt、dnf、yum、pacman、zypper。'
      return 1
      ;;
  esac
  dependency_install_packages "${packages[@]}"
}

dependency_feature_packages() {
  local feature=$1 distro
  distro=$(dependency_distro)
  case "$feature:$distro" in
    low-port:alpine) printf '%s\n' libcap-utils ;;
    low-port:debian) printf '%s\n' libcap2-bin ;;
    low-port:dnf|low-port:yum) printf '%s\n' libcap ;;
    low-port:pacman) printf '%s\n' libcap ;;
    low-port:zypper) printf '%s\n' libcap-progs ;;
    traffic:alpine) printf '%s\n' nftables ;;
    traffic:debian) printf '%s\n' nftables ;;
    traffic:dnf|traffic:yum) printf '%s\n' nftables ;;
    traffic:pacman) printf '%s\n' nftables ;;
    traffic:zypper) printf '%s\n' nftables ;;
    subscription:alpine|subscription:debian|subscription:dnf|subscription:yum|subscription:zypper) printf '%s\n' python3 ;;
    subscription:pacman) printf '%s\n' python ;;
    bbr:alpine|bbr:debian|bbr:dnf|bbr:yum|bbr:zypper) printf '%s\n' kmod ;;
    bbr:pacman) printf '%s\n' kmod ;;
    probe:alpine) printf '%s\n' iproute2-ss ;;
    probe:debian) printf '%s\n' iproute2 ;;
    probe:dnf|probe:yum|probe:pacman|probe:zypper) printf '%s\n' iproute2 ;;
    scheduler:alpine) printf '%s\n' dcron ;;
    logrotate:alpine|logrotate:debian|logrotate:dnf|logrotate:yum|logrotate:pacman|logrotate:zypper) printf '%s\n' logrotate ;;
    *) return 1 ;;
  esac
}

dependency_feature_commands() {
  case "$1" in
    low-port) printf '%s\n' setcap getcap ;;
    traffic) printf '%s\n' nft ;;
    subscription)
      if [[ $(dependency_distro) == pacman ]]; then printf '%s\n' python; else printf '%s\n' python3; fi
      ;;
    bbr) printf '%s\n' modprobe ;;
    probe) printf '%s\n' ss ;;
    scheduler) printf '%s\n' crond ;;
    logrotate) printf '%s\n' logrotate ;;
    *) return 1 ;;
  esac
}

dependency_require_feature() {
  local feature=$1 command missing=0 package
  local -a missing_packages=()
  local old_feature=${SBM_DEPENDENCY_FEATURE:-}
  dependency_feature_commands "$feature" >/dev/null 2>&1 || {
    log_error "未知可选功能：$feature"
    return 1
  }
  if [[ "$feature" == scheduler ]] && declare -F effective_init_system >/dev/null 2>&1; then
    if [[ $(effective_init_system 2>/dev/null || true) == systemd ]]; then
      log_info 'systemd 使用内置 timer，无需额外安装 cron。'
      return 0
    fi
  fi
  if [[ "$feature" == low-port ]] && declare -F effective_init_system >/dev/null 2>&1; then
    if [[ $(effective_init_system 2>/dev/null || true) == systemd ]]; then
      log_info 'systemd 通过 unit capability 提供低端口权限，无需安装 setcap。'
      return 0
    fi
  fi
  SBM_DEPENDENCY_FEATURE=$feature
  while IFS= read -r command; do
    [[ -n "$command" ]] || continue
    if ! command_exists "$command"; then missing=1; fi
  done < <(dependency_feature_commands "$feature" 2>/dev/null || true)
  if (( missing == 0 )); then
    SBM_DEPENDENCY_FEATURE=$old_feature
    return 0
  fi
  while IFS= read -r package; do
    [[ -n "$package" ]] && missing_packages+=("$package")
  done < <(dependency_feature_packages "$feature" 2>/dev/null || true)
  if ((${#missing_packages[@]} == 0)); then
    log_error "无法为功能 $feature 映射当前发行版依赖。"
    SBM_DEPENDENCY_FEATURE=$old_feature
    return 1
  fi
  if ! dependency_install_packages "${missing_packages[@]}"; then
    SBM_DEPENDENCY_FEATURE=$old_feature
    return 1
  fi
  while IFS= read -r command; do
    [[ -n "$command" ]] || continue
    if ! command_exists "$command"; then
      log_error "依赖安装后仍缺少命令：$command（功能：$feature）"
      SBM_DEPENDENCY_FEATURE=$old_feature
      return 1
    fi
  done < <(dependency_feature_commands "$feature" 2>/dev/null || true)
  if [[ "$feature" == scheduler ]] && declare -F effective_init_system >/dev/null 2>&1 && [[ $(effective_init_system 2>/dev/null || true) == openrc ]] && declare -F service_enable >/dev/null 2>&1; then
    service_enable crond || true
    service_active crond || service_start crond || log_warn 'dcron 已安装，但 crond 未能启动；请手动运行 rc-service crond start。'
  fi
  SBM_DEPENDENCY_FEATURE=$old_feature
}

dependency_status() {
  local json=${1:-0} feature command available
  local -a features=(low-port traffic subscription bbr probe scheduler logrotate)
  if [[ "$json" == 1 ]]; then
    {
      for feature in "${features[@]}"; do
        if [[ "$feature" == scheduler ]] && declare -F effective_init_system >/dev/null 2>&1 && [[ $(effective_init_system 2>/dev/null || true) == systemd ]]; then
          jq -cn --arg feature "$feature" '{feature:$feature,command:"systemd timer",available:true}'
          continue
        fi
        if [[ "$feature" == low-port ]] && declare -F effective_init_system >/dev/null 2>&1 && [[ $(effective_init_system 2>/dev/null || true) == systemd ]]; then
          jq -cn --arg feature "$feature" '{feature:$feature,command:"systemd unit capability",available:true}'
          continue
        fi
        while IFS= read -r command; do
          [[ -n "$command" ]] || continue
          if command_exists "$command"; then available=true; else available=false; fi
          jq -cn --arg feature "$feature" --arg command "$command" --argjson available "$available" \
            '{feature:$feature,command:$command,available:$available}'
        done < <(dependency_feature_commands "$feature" 2>/dev/null || true)
      done
    } | jq -s .
    return 0
  fi
  printf '%-14s %-12s %s\n' '功能' '状态' '命令'
  for feature in "${features[@]}"; do
    if [[ "$feature" == scheduler ]] && declare -F effective_init_system >/dev/null 2>&1 && [[ $(effective_init_system 2>/dev/null || true) == systemd ]]; then
      printf '%-14s %-12s %s\n' "$feature" 'systemd timer' '无需 crond'
      continue
    fi
    if [[ "$feature" == low-port ]] && declare -F effective_init_system >/dev/null 2>&1 && [[ $(effective_init_system 2>/dev/null || true) == systemd ]]; then
      printf '%-14s %-12s %s\n' "$feature" 'systemd capability' '无需 setcap'
      continue
    fi
    local -a commands=()
    while IFS= read -r command; do [[ -n "$command" ]] && commands+=("$command"); done < <(dependency_feature_commands "$feature" 2>/dev/null || true)
    available=1
    for command in "${commands[@]}"; do command_exists "$command" || available=0; done
    if (( available )); then printf '%-14s %-12s %s\n' "$feature" '已就绪' "${commands[*]}"; else printf '%-14s %-12s %s\n' "$feature" '按需安装' "${commands[*]}"; fi
  done
}
