# sb-manager

`sb-manager` 是一个面向 systemd/OpenRC Linux 的、状态驱动的 sing-box 多协议管理脚本。安装后输入 `sb` 即可打开中文交互面板，也可以使用完整的非交互 CLI。

> 当前版本：`0.1.0-alpha.5`。请先在测试 VPS 验证，不要直接覆盖仍在使用的生产节点。

## 功能

- VMess + WebSocket + Cloudflare Tunnel（固定 Tunnel 或 Quick Tunnel）
- Shadowsocks 2022（默认 TCP + multiplex）
- AnyTLS（TCP/TLS）
- Hysteria2（UDP/QUIC，可选 salamander）
- acme.sh + Cloudflare DNS-01 证书申请、部署与续期
- sing-box 核心检查、自动更新策略、版本切换与回滚
- cloudflared 独立更新
- 节点添加、编辑、启停、删除和凭据轮换
- 分享 URI 与 sing-box outbound JSON 导出
- 原子配置写入、`sing-box check`、快照和失败回滚
- 备份、恢复、日志、`sb doctor` 诊断与 `sb repair` 自动修复
- 低权限 systemd/OpenRC 服务；不会关闭或清空系统防火墙

## 网络模型

```text
Cloudflare Edge → cloudflared → 127.0.0.1:<VMess-WS 回源端口>
Internet        → TCP/TLS      → AnyTLS
Internet        → UDP/QUIC     → Hysteria2
Internet        → TCP          → Shadowsocks 2022
```

AnyTLS 的 `443/TCP` 与 Hysteria2 的 `443/UDP` 可以同时使用。VMess-WS 的回源端口只监听 `127.0.0.1`，无需向公网开放。

## 支持环境

推荐：

- Debian 11/12/13（systemd）
- Ubuntu 20.04/22.04/24.04（systemd）
- Alpine Linux 3.21/3.22/3.23/3.24（OpenRC）
- Rocky Linux 8/9、AlmaLinux 8/9、Fedora（systemd）
- Arch Linux、openSUSE（systemd）

要求：

- systemd 或 OpenRC 作为实际服务管理器
- Bash 4+
- root 权限
- `x86_64/amd64`、`aarch64/arm64`、ARMv7 或 x86 32 位
- 服务器可访问 GitHub Releases、Cloudflare 和 ACME 服务

当前不支持 OpenWrt/procd、macOS、Windows、FreeBSD，以及没有真正运行 systemd/OpenRC 的普通精简容器。Alpine 的 Docker 基础镜像默认没有以 OpenRC 作为 PID 1，不能当作常驻服务器直接安装。

## 一键安装

### Alpine Linux

Alpine 默认可能没有 Bash 和 curl，先安装最小引导依赖：

```bash
apk add --no-cache bash curl ca-certificates
bash <(curl -fsSL https://raw.githubusercontent.com/R1ddle1337/sb-manager/main/install.sh)
```

安装器会继续补齐 OpenRC、dcron、libcap、gcompat、shadow、jq、openssl、iproute2 等依赖。OpenRC 服务日志位于：

```text
/var/log/sb-manager/sing-box.log
/var/log/sb-manager/sing-box.err.log
/var/log/sb-manager/cloudflared.log
/var/log/sb-manager/cloudflared.err.log
```

官方 sing-box Linux 核心使用 glibc ABI，Alpine 由 `gcompat` 提供运行时兼容。AnyTLS/Hysteria2 使用 443 等低位端口时，安装器会为 sing-box 核心设置最小的 `cap_net_bind_service` 文件能力，服务本身仍以 `sbmanager` 低权限用户运行。自动更新和 ACME 续期使用 Alpine `dcron` 的 `/etc/periodic` 任务。

### systemd 发行版

建议先查看安装脚本，再执行：

```bash
curl -fsSL https://raw.githubusercontent.com/R1ddle1337/sb-manager/main/install.sh -o install.sh
less install.sh
sudo bash install.sh
```

直接执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/R1ddle1337/sb-manager/main/install.sh)
```

安装完成后：

```bash
sb
```

安装参数：

```bash
# 安装后不自动打开菜单
bash <(curl -fsSL https://raw.githubusercontent.com/R1ddle1337/sb-manager/main/install.sh) --no-menu

# 安装指定 sing-box 稳定版本
bash <(curl -fsSL https://raw.githubusercontent.com/R1ddle1337/sb-manager/main/install.sh) --core-version 1.13.19
```

也可以克隆源码后安装：

```bash
git clone https://github.com/R1ddle1337/sb-manager.git
cd sb-manager
sudo ./setup.sh
```

## 快速开始

### 查看状态与诊断

```bash
sb status
sb doctor
```

### 添加 Shadowsocks 2022

```bash
sb node add ss --id ss-main --port 8388 --address YOUR_SERVER_IP
sb share ss-main
```

需要在云厂商安全组及本机防火墙开放对应的 `TCP 8388`。

### AnyTLS 与 Hysteria2

先准备一个直接解析到 VPS 的域名，例如 `edge.example.com`。使用 Cloudflare DNS 时，该记录应为 **DNS Only**，不要开启橙云代理。

配置 Cloudflare DNS API Token 并签发证书：

```bash
sb cert setup-cloudflare
sb cert issue edge.example.com your-email@example.com
```

添加节点：

```bash
sb node add anytls --id any-main --domain edge.example.com --address edge.example.com --port 443
sb node add hy2    --id hy2-main --domain edge.example.com --address edge.example.com --port 443
```

开放：

```text
TCP 443  AnyTLS
UDP 443  Hysteria2
```

### VMess-WS + Cloudflare Tunnel

先添加本机回源节点：

```bash
sb node add vmess --id vm-cf-main --port 29001
```

固定 Tunnel：

```bash
sb tunnel fixed vm-cf-main cdn.example.com
```

命令会隐藏输入 Tunnel Token，并提示你在 Cloudflare 控制台配置：

```text
Hostname    : cdn.example.com
Service URL : http://127.0.0.1:29001
```

临时 Quick Tunnel：

```bash
sb tunnel quick vm-cf-main
```

显示分享链接：

```bash
sb share vm-cf-main
```

## 常用命令

```bash
sb node list
sb node show NODE_ID
sb node enable NODE_ID
sb node disable NODE_ID
sb node delete NODE_ID
sb node rotate NODE_ID
sb node set NODE_ID --port 8443

sb share NODE_ID
sb share all
sb export outbounds

sb cert list
sb cert inspect example.com
sb cert renew

sb tunnel status
sb tunnel refresh
sb tunnel set-token
sb tunnel stop

sb core check
sb core update
sb core rollback
sb core policy manual
sb core policy notify
sb core policy patch
sb core policy stable

sb cloudflared update
sb acme update
sb backup
sb restore /path/to/backup.tar.gz
sb logs follow
sb doctor
```

完整帮助：

```bash
sb --help
```

## 数据与权限

```text
/usr/local/bin/sb
/usr/local/lib/sb-manager/
/etc/sb-manager/state.json
/etc/sb-manager/generated/config.json
/etc/sb-manager/secrets/
/etc/sb-manager/certs/
/var/lib/sb-manager/backups/
/var/lib/sb-manager/exports/
```

- 状态、Token、节点密码、私钥及导出文件不会提交到仓库。
- Tunnel Token 使用受限文件保存，不直接写入 systemd `ExecStart` 或 OpenRC 脚本。
- sing-box 以独立的 `sbmanager` 低权限用户运行。
- systemd 通过 unit 的 ambient capability 提供低端口绑定能力；OpenRC 才在核心文件上设置 `cap_net_bind_service`。
- 脚本不会关闭 UFW/firewalld，也不会清空 iptables/nftables。
- 直连协议的安全组和防火墙端口由管理员明确开放。

## 卸载

交互面板中选择“卸载与彻底清理”，或使用命令行：

```bash
sb uninstall                 # 卸载程序，保留节点和数据
sb uninstall --purge         # 完全卸载并删除节点、证书、密钥和备份
sb uninstall --purge --yes   # 非交互完全卸载
```

## Debian/systemd 路由监听说明

sing-box 在 Linux 启动时会通过 Netlink 订阅路由变化。systemd 服务必须在 `RestrictAddressFamilies` 中允许 `AF_NETLINK`；缺失时日志会出现：

```text
start service: subscribe route updates: address family not supported by protocol
```

`0.1.0-alpha.5` 起，安装器、实际启动预检和 `sb doctor` 都会检查这一项。

## 诊断与修复

```bash
sb doctor                    # 只检查，不修改系统
sb repair                    # 修复核心权限/能力、重建配置并协调服务
sb doctor --repair           # 与 sb repair 等价
```

没有启用节点时，systemd 的 `sb-sing-box.service` 或 OpenRC 的 `sb-sing-box` 保持停止属于正常待命状态；添加第一个启用节点后会自动启动。

### systemd 报 `203/EXEC` 或 `Permission denied`

典型日志：

```text
Failed to execute /usr/local/bin/sing-box: Permission denied
Failed at step EXEC spawning /usr/local/bin/sing-box
status=203/EXEC
```

先运行自动修复：

```bash
sb repair
sb doctor
```

`sb repair` 会停止重启循环、修复目录遍历权限、清除 systemd 后端不需要的旧 file capabilities，并在与正式服务相同的 systemd 沙箱中预检核心执行；不会删除节点、证书或密钥。

尚未更新到 `0.1.0-alpha.5` 时，可手动执行：

```bash
systemctl stop sb-sing-box.service
target="$(readlink -f /usr/local/bin/sing-box)"
setcap -r "$target" 2>/dev/null || true
chmod 755 /usr/local /usr/local/bin /usr/local/lib \
  /usr/local/lib/sb-manager /usr/local/lib/sb-manager/cores \
  /usr/local/lib/sb-manager/cores/sing-box \
  "$(dirname "$target")" "$target"
systemctl daemon-reload
systemctl reset-failed sb-sing-box.service
systemctl start sb-sing-box.service
journalctl -u sb-sing-box.service -n 50 --no-pager -l
```

进一步诊断：

```bash
getcap "$(readlink -f /usr/local/bin/sing-box)"
namei -l /usr/local/bin/sing-box
findmnt -T "$(readlink -f /usr/local/bin/sing-box)" -o TARGET,SOURCE,FSTYPE,OPTIONS
systemctl show sb-sing-box.service -p Result -p ExecMainStatus
```

## 开发与测试

语法检查：

```bash
find . -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
```

使用真实 sing-box 核心运行测试：

```bash
SBM_TEST_SING_BOX=/path/to/sing-box bash tests/run.sh
SBM_TEST_SING_BOX=/path/to/sing-box bash tests/install-smoke.sh
bash tests/systemd-exec-smoke.sh
bash tests/openrc-lifecycle.sh
```

生成离线单文件安装器：

```bash
./build-standalone.sh /tmp/sb-manager-install.sh
sha256sum /tmp/sb-manager-install.sh
```

架构和状态模型见：

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- [`docs/STATE_SCHEMA.md`](docs/STATE_SCHEMA.md)

## 重要说明

- 这是 alpha 版本，接口和状态 schema 仍可能调整。
- Cloudflare Tunnel 的公共 HTTP hostname 适用于 VMess-WebSocket 回源；AnyTLS、Hysteria2 和普通 Shadowsocks 节点应使用直连入口。
- 分享链接和备份含访问凭据，请按密钥文件处理。
- 使用本项目时应遵守服务器所在地、服务提供商及使用者所在地的法律和服务条款。

## License

当前仓库尚未指定开源许可证。在许可证明确前，代码版权默认保留。
