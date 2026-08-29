# sb-manager

`sb-manager` 是一个面向 systemd/OpenRC Linux 的、状态驱动的 sing-box 多协议管理脚本。安装后输入 `sb` 即可打开中文交互面板，也可以使用完整的非交互 CLI。

> 当前版本：`0.1.0-alpha.27`。请先在测试 VPS 验证，不要直接覆盖仍在使用的生产节点。

## 功能

- VMess + WebSocket + Cloudflare Tunnel（固定 Tunnel 或 Quick Tunnel）
- Shadowsocks 2022（默认 TCP + multiplex）
- AnyTLS（TCP/TLS）
- Hysteria2（UDP/QUIC，可选 salamander）
- Trojan（TLS）、TUIC（QUIC）、VLESS（TLS/Reality）
- NaiveProxy（HTTPS/QUIC）、ShadowTLS v3 与 Snell v5
- 可选 Nginx Stream SNI 透传，让多个 TLS/TCP 协议共享一个公网端口
- acme.sh + Cloudflare DNS-01 证书申请、部署与续期
- sing-box 核心检查、自动更新策略、版本切换与回滚
- cloudflared 独立更新
- 节点添加、编辑、启停、删除和凭据轮换
- 节点级双向流量统计、月配额与独立上/下行速率控制
- 分享 URI 与 sing-box outbound JSON 导出
- 客户端导出支持 IPv4 优先、IPv6 优先或仅 IPv4 的出站解析策略
- Naive 分享链接使用与服务端一致的用户账号；ShadowTLS 需使用支持该协议的 sing-box/NekoBox 客户端
- 原子配置写入、`sing-box check`、快照和失败回滚
- 备份、恢复、日志、`sb doctor` 诊断与 `sb repair` 自动修复
- 低权限 systemd/OpenRC 服务；不会关闭或清空系统防火墙
- 防火墙面板可查看启用协议端口、显式执行 UFW allow，并在备份后清理 INPUT 链全局拦截
- 统一状态面板与 `sb status --json`，可供监控脚本直接读取
- 流量配额阈值通知（Telegram、企业微信和通用 Webhook）与可选定时健康检查
- UFW 安全安装向导会探测实际 SSH 端口并在启用前展示规则预览
- 节点备注、地区、用途、线路和标签，可按标签/地区筛选
- 节点模板、按标签/地区批量启停，以及配置差异和 dry-run 预览
- 磁盘、内存、负载、文件描述符、Fail2ban 封禁数和服务重启次数监控
- sing-box 1.14 特性覆盖矩阵见 [`docs/SINGBOX_1.14_FEATURE_MATRIX.md`](docs/SINGBOX_1.14_FEATURE_MATRIX.md)

### 节点流量控制

流量控制按节点的实际 sing-box 监听端口识别 TCP/UDP 流量，同时覆盖 IPv4、IPv6、Cloudflare Tunnel 回源和 Nginx Stream loopback 后端。配置保存在 `state.json`；累计用量保存在权限为 `0600` 的 `/var/lib/sb-manager/traffic-usage.json`，不会从生成的 `config.json` 反推。

```bash
# 双向合计 100 GiB/月，每月 1 日 UTC 重置；上行 20 Mbit/s、下行 100 Mbit/s
sb traffic set ss-main --quota 100G --reset-day 1 \
  --upload-rate 20M --download-rate 100M --quota-mode total

# 只把下行计入配额；同一速率应用到两个方向
sb traffic set ss-main --quota 2T --quota-mode download --rate 50M

sb traffic status
sb traffic status ss-main --json
sb traffic disable ss-main       # 保留配置与累计用量
sb traffic set ss-main           # 按原配置重新启用
sb traffic reset ss-main         # 交互确认后清零本周期
sb traffic remove ss-main        # 删除配置与累计用量
```

配额单位 `K/M/G/T/P` 按 1024 进制换算；速率单位 `K/M/G` 按 bit/s 的 1000 进制换算。`unlimited` 可单独取消配额或某一方向的限速。每月重置日限制为 1–28，避免短月歧义。

实现使用项目独占的 `inet sb_manager_traffic` nftables 表，不写入 `/etc/nftables.conf`、不开放端口，也不接管网卡根 qdisc。速率上限是 nftables policer：超出瞬时上限的数据包会被丢弃，TCP 会通过拥塞控制回落；它不是 `tc` 的平滑排队整形。计数每 5 分钟（OpenRC 为 15 分钟）落盘并在正常关机时再同步；突然断电最多可能丢失一个同步周期的未落盘用量。

## 网络模型

```text
Cloudflare Edge → cloudflared → 127.0.0.1:<VMess-WS 回源端口>
Internet        → TCP/TLS      → AnyTLS
Internet        → UDP/QUIC     → Hysteria2
Internet        → TCP          → Shadowsocks 2022
```

AnyTLS 的 `443/TCP` 与 Hysteria2 的 `443/UDP` 可以同时使用。VMess-WS 的回源端口只监听 `127.0.0.1`，无需向公网开放。

### 端口规划

sing-box 官方不会为这些协议强制规定唯一端口，文档示例常用 `443`（TLS/QUIC）、`8388`（Shadowsocks）和 `8443`（TLS/QUIC 备用）。同一 IP 上的多个 TCP/TLS 入站不能同时绑定 `443/TCP`；要统一走 443，需要显式启用下面的 Nginx Stream SNI 透传功能。面板会按传输类型检查端口冲突：TCP 与 UDP 可以使用同一个数字端口，但两个 TCP 入站不能重复占用；推荐端口被占用时会依次建议 `8443`、`9443`、`10443`，也可以手工输入其他端口。API `9090`、订阅服务 `9080` 和 mixed 客户端 `2080` 默认只监听 loopback。

证书按域名保存，AnyTLS、Trojan、VLESS TLS、NaiveProxy 等节点可以复用同一域名证书，不需要按协议重复申请。证书复用不等于端口复用：同一证书的多个 TCP 节点仍需使用不同端口；如果要让它们共同使用公网 `443/TCP`，请为每个节点配置唯一 SNI 并启用 Nginx Stream 复用。`443/TCP` 与 `443/UDP` 可以并存，但 Hysteria2、TUIC 等 UDP 入站之间仍不能直接共用同一端口。

### 可选 Nginx Stream 端口复用

systemd 或 Alpine/OpenRC 均可选择启用独立的 Nginx Stream SNI 透传服务。它不终止 TLS，只读取 ClientHello 的 SNI，把公网 `443/TCP` 转发到 sing-box 的不同 loopback 后端。支持 AnyTLS、Trojan、VLESS TLS/Reality、Naive TCP 和 ShadowTLS v3；每个路由必须使用唯一且与协议 `server_name` 一致的域名。Shadowsocks、VMess Tunnel、Hysteria2、TUIC 和 Naive QUIC 不属于该 TCP/SNI 复用范围。

```bash
sb mux route add trojan-main trojan.example.com
sb mux route add vless-main vless.example.com
sb mux enable 443
sb mux status
```

启用时按需安装 Debian 的 `nginx-core`/`libnginx-mod-stream` 或 Alpine 的 `nginx`/`nginx-mod-stream`，将已登记节点改为 `127.0.0.1:<自动后端端口>`，分享链接和客户端导出使用公网复用端口。未知 SNI 会被拒绝。执行 `sb mux disable` 后恢复节点原来的独立监听端口；路由定义保留，便于再次启用。系统已有 Nginx 配置不会被改写，目标端口冲突会触发事务回滚。OpenRC 使用独立的前台 supervise-daemon 服务，并把 Nginx 复制到持久化数据目录后仅授予 `cap_net_bind_service`，避免升级覆盖能力设置。

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
- 启用流量控制时需要 `nftables`（安装器会自动补齐）
- `x86_64/amd64`、`aarch64/arm64`、ARMv7 或 x86 32 位
- 服务器可访问 GitHub Releases、Cloudflare 和 ACME 服务

当前不支持 OpenWrt/procd、macOS、Windows、FreeBSD，以及没有真正运行 systemd/OpenRC 的普通精简容器。Alpine 的 Docker 基础镜像默认没有以 OpenRC 作为 PID 1，不能当作常驻服务器直接安装。

## 一键安装

### Alpine Linux

Alpine 默认可能没有 Bash 和 curl，先安装最小引导依赖：

```bash
apk add --no-cache bash curl ca-certificates
bash <(curl -fsSL https://github.com/R1ddle1337/sb-manager/raw/refs/heads/main/install.sh)
```

安装器会继续补齐 OpenRC、dcron、libcap、gcompat、shadow、jq、openssl、iproute2、nftables 等依赖。OpenRC 服务日志位于：

```text
/var/log/sb-manager/sing-box.log
/var/log/sb-manager/sing-box.err.log
/var/log/sb-manager/cloudflared.log
/var/log/sb-manager/cloudflared.err.log
/var/log/sb-manager/nginx-stream.log
/var/log/sb-manager/nginx-stream.err.log
```

官方 sing-box Linux 核心使用 glibc ABI，Alpine 由 `gcompat` 提供运行时兼容。AnyTLS/Hysteria2 使用 443 等低位端口时，安装器会为 sing-box 核心设置最小的 `cap_net_bind_service` 文件能力，服务本身仍以 `sbmanager` 低权限用户运行。自动更新和 ACME 续期使用 Alpine `dcron` 的 `/etc/periodic` 任务。

### systemd 发行版

建议先查看安装脚本，再执行：

```bash
curl -fsSL https://github.com/R1ddle1337/sb-manager/raw/refs/heads/main/install.sh -o install.sh
less install.sh
sudo bash install.sh
```

直接执行（生产环境必须固定不可变 commit/tag，并提供源码摘要）：

```bash
bash <(curl -fsSL https://github.com/R1ddle1337/sb-manager/raw/refs/heads/main/install.sh)
```

`install.sh` 默认先解析 `main` 的最新 commit SHA，再按该不可变 commit 下载源码；也可设置 `SBM_INSTALL_REF=v0.1.0-alpha.27` 固定版本。显式指定 `main` 等可变分支仍需 `SBM_ALLOW_MUTABLE_REF=1`。离线发布包可使用 `build-release.sh` 生成，并核验 `SHA256SUMS`、`PROVENANCE-SHA256SUMS` 及可选的 GPG 签名文件。

安装完成后：

```bash
sb
```

安装参数：

```bash
# 安装后不自动打开菜单
bash <(curl -fsSL https://github.com/R1ddle1337/sb-manager/raw/refs/heads/main/install.sh) --no-menu

# 安装指定 sing-box 稳定版本
bash <(curl -fsSL https://github.com/R1ddle1337/sb-manager/raw/refs/heads/main/install.sh) --core-version 1.14.0-rc.2
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
sb doctor --network
sb probe NODE_ID
sb status --json                 # 机器可读的统一状态
sb health check --json           # 单次健康检查
sb health enable 21              # 启用定时健康检查，证书提前 21 天预警
sb config validate --json        # 校验 state、渲染结果和 sing-box 配置
sb config diff --json             # 查看脱敏后的已安装配置差异
```

出站 IP 策略可在“全局设置 → 出站 IP 优先级”中选择，也可使用 CLI：

```bash
sb settings outbound-ip prefer_ipv4   # IPv4 优先
sb settings outbound-ip prefer_ipv6   # IPv6 优先
sb settings outbound-ip ipv4_only     # 仅 IPv4
```

### 添加 Shadowsocks 2022

面板和 CLI 默认使用 `2022-blake3-aes-256-gcm`；如需兼容旧客户端，可显式指定其他受支持的方法。

```bash
sb node add ss --id ss-main --port 8388 --address YOUR_SERVER_IP
sb share ss-main
```

需要在云厂商安全组及本机防火墙开放对应的 `TCP 8388`。

### 节点元数据与筛选

节点元数据只保存在 `state.json`，不会进入 sing-box 生成配置：

```bash
sb node add ss --id hk-01 --port 8388 --address edge.example.com \
  --region hk --purpose relay --line cn2 --tags backup,fast --remark '备用线路'
sb node set hk-01 --region jp --tags production,ipv6
sb node list --tag backup
sb node list --region hk --json
sb node template save ss-standard hk-01
sb node template add ss-standard hk-02 --address edge.example.com --port 8389
sb node enable-all --tag production
sb node disable-all --region hk
```

节点和流量修改支持 `--dry-run`，只显示 state/config 差异，不会写入状态、重启服务或改变流量账本：

```bash
sb node set hk-01 --name '预览名称' --dry-run
sb traffic set hk-01 --quota 100G --dry-run
```

### Snell v5/v6

Snell 需要 sing-box `1.14.0-rc.1` 或更高版本核心。新建节点默认使用 Snell v6（traffic shaping），可选 `default`、`unshaped` 或 `unsafe-raw`；v6 需要 `1.14.0-rc.2` 或更高版本。Snell v5 仍可用于兼容旧客户端，服务端使用 v5、客户端 outbound 使用兼容的 v4，并可按需设置 `--obfs http --obfs-host example.com`。v6 不支持 HTTP obfs。

```bash
sb core update 1.14.0-rc.2
sb node add snell --id snell-main --address YOUR_SERVER_IP --port 6160 --snell-version 6 --snell-mode default
sb share snell-main
```

### Hysteria2（sing-box 1.14）

1.14 核心支持 Gecko QUIC 混淆（可调链路包长）和 Chrome QUIC 指纹伪装开关。面板添加 Hysteria2 时会让你选择无混淆、Salamander 或 Gecko；Gecko 默认包长为 512–1200 字节，也可以通过 CLI 调整：

```bash
sb node add hy2 --id hy2-gecko --domain edge.example.com --address 203.0.113.10 \
  --port 443 --obfs gecko --obfs-min-packet-size 600 --obfs-max-packet-size 1100
sb node add hy2 --id hy2-no-parrot --domain edge.example.com --address 203.0.113.10 \
  --port 8443 --disable-chrome-parrot
sb node add hy2 --id hy2-bbr --domain edge.example.com --address 203.0.113.10 \
  --port 9443 --bbr-profile aggressive --brutal-debug
```

Gecko、`--disable-chrome-parrot`、`--bbr-profile` 和 `--brutal-debug` 需要 sing-box `1.14.0-rc.1` 或更高版本；使用 1.13 核心时管理器会拒绝包含这些字段的启用配置。客户端导出会保留 Gecko 包长、BBR profile 和 Chrome 指纹设置。也可以通过 `sb core schema [文件]` 导出当前 1.14 核心生成的 JSON Schema。

DNS 1.14 优化可以在面板“设置 → sing-box 1.14 DNS 优化”中开启，也可以使用 CLI：

```bash
sb settings dns optimistic true
sb settings dns optimistic-timeout 3d
sb settings dns timeout 10s
sb settings dns show
```

这些字段仅在使用 1.14 核心时写入生成配置；继续使用 1.13 核心时会保持原有 DNS 配置格式。

客户端 TUN 导出也可使用 1.14 的 DNS 模式：`sb export config --mode tun --tun-dns-mode hijack|native|disabled [--tun-dns-address IP]`。留空地址时由核心根据 TUN 地址自动推导。

启用 API 后，面板的“sing-box API/Dashboard”菜单可查看服务状态、outbounds 和导出 Schema；脚本也可通过 `sb api cli status`、`sb api cli outbounds` 调用 1.14 API CLI。API 仍只监听 loopback，远程使用请通过 SSH 转发。

“核心与组件更新”菜单中的“查看核心 build tags 与能力”以及 `sb core capabilities --json` 可检查当前二进制是否编译了 `with_quic`、`with_utls`、`with_openvpn`、`with_openconnect`、`with_usbip`、`with_tailscale` 等标签。未编译的能力不会被管理器伪装成可用。

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
# 加密备份（age recipient）；恢复时使用 --identity 私钥文件
sb backup /var/lib/sb-manager/backups/nodes.age --recipient age1...
sb restore /var/lib/sb-manager/backups/nodes.age --identity /root/age-identity.txt --yes
sb logs follow
sb doctor
```

防火墙与端口管理（安装器不会自动执行，需在面板或 CLI 中显式选择）：

交互面板路径：`12. 防火墙与协议端口` → `5. 安装并启用 Fail2ban` 或 `6. 安装并启用 UFW`。

```bash
sb firewall ports                 # 查看所有节点的 TCP/UDP 端口
sb firewall ufw-allow --yes       # 为所有启用协议端口执行 ufw allow
sb firewall fail2ban --yes        # 安装并启用 Fail2ban：SSH 180 秒内 5 次失败，永久封禁
sb firewall ufw --yes              # 安装并启用 UFW，放行 22/80/443 及启用协议端口
sb firewall ufw --dry-run          # 只预览 SSH、Web 和协议端口放行计划
sb firewall status                 # 查看 UFW/Fail2ban 状态
sb firewall clear-iptables --yes  # 先备份，再清理 INPUT 全局 DROP/REJECT
```

`fail2ban` 只覆盖 SSH jail：`findtime=180`、`maxretry=5`、`bantime=-1`，不会替换其他 jail；SSH 端口会从 `sshd -T`/监听套接字自动探测，无法探测时安全回退到 22。`ufw` 向导会先保存 iptables/UFW 状态并展示预览，再幂等放行探测到的 SSH 端口、兼容性的 TCP 22、80、443 和当前启用的 sing-box 协议端口；UFW 未安装时会按当前发行版调用包管理器安装。备份和状态快照保存在 `/var/lib/sb-manager/firewall/`。

通知和健康检查：

```bash
sb notify configure telegram --token-file /root/telegram-token \
  --chat-id 123456 --thresholds 80,90,100
sb notify configure webhook --url-file /root/monitor-webhook
sb notify status --json
sb notify test
sb notify disable
```

通知 Token、Webhook URL 和 Chat ID 保存在权限为 `0600` 的 `secrets/notifications.json`；定时任务只在达到新阈值或健康状态发生变化时发送，避免重复告警。`sb traffic tick` 会执行流量阈值检查，systemd/OpenRC 安装会额外创建 `sb-health-check.timer` 或 15 分钟 periodic 任务。

所有命令也支持在命令前使用统一选项，例如 `sb --json status`、`sb --quiet health check`、`sb --yes firewall ufw`。参数/用法错误返回退出码 `2`，健康检查或状态发现错误返回 `1`，便于脚本编排。

资源监控阈值可调整：

```bash
sb health configure --disk-free 10 --memory-max 90 --load-per-core 2
```

低风险修复只处理权限、配置渲染、流量规则和已确认失败的服务，不会修改 SSH、防火墙默认策略、内核参数或路由：

```bash
sb doctor --repair-safe
sb repair --safe
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
/var/lib/sb-manager/nginx-stream/nginx  # 仅在 OpenRC 启用 Nginx Stream 时
```

- 状态、Token、节点密码、私钥及导出文件不会提交到仓库。
- Tunnel Token 使用受限文件保存，不直接写入 systemd `ExecStart` 或 OpenRC 脚本。
- sing-box 以独立的 `sbmanager` 低权限用户运行。
- systemd 通过 unit 的 ambient capability 提供低端口绑定能力；OpenRC 只在托管的 sing-box/Nginx 可执行文件上设置 `cap_net_bind_service`。
- 脚本安装时不会自动启用 UFW 或 Fail2ban；防火墙变更只能通过显式的 `sb firewall` 操作执行。`sb firewall ufw --yes` 会启用 UFW 并放行 22/80/443 及启用协议端口，`sb firewall fail2ban --yes` 会启用永久 SSH 封禁策略。
- 直连协议的安全组和防火墙端口由管理员明确开放。

## 卸载

交互面板中选择“卸载与彻底清理”，或使用命令行：

```bash
sb uninstall                 # 卸载程序，保留节点和数据
sb uninstall --purge         # 完全卸载并删除节点、证书、密钥和备份
sb uninstall --purge --yes   # 非交互完全卸载
```

## Linux 路由监听说明

sing-box 在 Linux 启动时会通过 Netlink 订阅路由变化。systemd 服务必须在 `RestrictAddressFamilies` 中允许 `AF_NETLINK`；缺失时日志会出现：

```text
start service: subscribe route updates: address family not supported by protocol
```

`0.1.0-alpha.5` 起，安装器、实际启动预检和 `sb doctor` 都会检查这一项。OpenRC/Alpine 不使用 systemd 沙箱，服务脚本通过同一配置直接运行并由 `supervise-daemon` 监控。

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

`sb repair` 会停止重启循环、修复目录遍历权限、按后端校正低端口能力，并在 systemd 上使用与正式服务相同的沙箱预检核心执行；不会删除节点、证书或密钥。

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
bash tests/openrc-nginx-stream-smoke.sh
# 在 Alpine 3.21-3.24 的一次性 VM/容器中以 root 运行：
bash tests/alpine-nginx-stream-smoke.sh
```

在指定 Debian 13 测试机上运行完整验收（官方核心目录放在仓库外）：

```bash
SBM_TEST_SING_BOX_STABLE=/opt/sing-box-1.13.19/sing-box \
SBM_TEST_SING_BOX_PREVIEW=/opt/sing-box-1.14.0-rc.1/sing-box \
bash tests/remote-debian13-suite.sh
```

生成离线单文件安装器：

```bash
./build-standalone.sh /tmp/sb-manager-install.sh
sha256sum /tmp/sb-manager-install.sh
```

架构和状态模型见：

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- [`docs/STATE_SCHEMA.md`](docs/STATE_SCHEMA.md)
- [`docs/REMOTE_ACCEPTANCE_2026-08-28.md`](docs/REMOTE_ACCEPTANCE_2026-08-28.md)

## 重要说明

- 这是 alpha 版本，接口和状态 schema 仍可能调整。
- Cloudflare Tunnel 的公共 HTTP hostname 适用于 VMess-WebSocket 回源；AnyTLS、Hysteria2 和普通 Shadowsocks 节点应使用直连入口。
- 分享链接和备份含访问凭据，请按密钥文件处理。
- 使用本项目时应遵守服务器所在地、服务提供商及使用者所在地的法律和服务条款。

## License

当前仓库尚未指定开源许可证。在许可证明确前，代码版权默认保留。
