# 可选运维功能（0.1.0-alpha.32）

参考 vps-tcp-tune 的测速、端口计费、代理入口、Tunnel 与 Sub-Store 管理思路，
按 sb-manager 的状态、凭据和事务模型实现。全部按需启用；默认安装不增加
Node.js、Python、iperf3 或 tc 依赖。兼容 Debian/systemd 和 Alpine/OpenRC。

## 吞吐测速与对比

目标需要运行自己的 iperf3 服务。管理器只启动客户端，默认测试 10 秒、单连接，
最多 30 秒、16 个连接；测速会实际传输数据。

```bash
sb deps install benchmark
sb network speed 192.0.2.10 --port 5201 --seconds 10 --streams 1 --direction down --json
sb network speed 192.0.2.10 --port 5201 --seconds 10 --streams 4 --direction up
sb network history
sb network compare BEFORE_ID AFTER_ID --json
```

记录保存在 `/var/lib/sb-manager/network-tests/`（目录 0700，文件 0600），包含
iperf3 JSON、接收吞吐、重传统计和 TCP 调优快照。只比较相同目标、端口、时长、
连接数和方向的结果。线路和对端负载会影响结果，建议多次测试。写入默认历史
目录需要 root；原有 `network ping` 仍可由普通用户运行。

面板：“诊断与修复 → 吞吐测速与前后对比”。

## SOCKS5、HTTP 和 mixed 入口

```bash
sb node add socks --id socks-local --port 1080
sb node add http --id http-local --port 8080
sb node add mixed --id mixed-main --listen 0.0.0.0 --address 192.0.2.20 --port 1081
sb share mixed-main
sb user add mixed-main second-user
```

默认监听 `127.0.0.1`，也可选 `::1`、`0.0.0.0`、`::`。每个用户自动生成
独立用户名/密码，复用节点启停、凭据轮换、模板、导出和流量策略。mixed 同时
接受 HTTP 和 SOCKS5，默认分享为 SOCKS5 链接。普通 SOCKS5/HTTP 不加密，
跨公网访问应结合受信任的加密通道。

SOCKS5/mixed 的 UDP relay 使用动态端口，不能由当前端口账本完整计费；启用
节点或共享流量策略时，管理器拒绝这些节点的 UDP 转发，并导出 TCP-only
outbound，避免绕过配额。未启用流量策略时保留核心原有 UDP 能力。

面板：“添加协议节点 → SOCKS5 / HTTP / mixed 认证代理”。

## 节点到期与续期

```bash
sb node expiry mixed-main --days 30
sb node expiry mixed-main --at 2027-01-01T00:00:00Z
sb node expiry mixed-main
sb node expiry mixed-main --clear
```

`--days` 从原到期日与当前时间中较晚的时刻延长；`--at` 使用 UTC。到期任务
停用节点并保留配置、凭据与流量记录。续期或清除期限会恢复因到期而停用的
节点，原本手动停用的节点保持停用；普通“启用”不能绕过到期策略。

复用流量维护任务：systemd 每 5 分钟、OpenRC periodic 每 15 分钟检查，停用
可能有一个检查周期的延迟；OpenRC 需要运行 cron。配置通知后，在到期前 3 天
和停用后分别发送去重通知。`sb traffic tick` 可主动执行检查。

面板：“管理现有节点 → 设置/延长节点有效期”。

## 多节点共享配额

```bash
sb traffic group set family --nodes snell-main,hy2-main,mixed-main --quota 500G \
  --reset-day 1 --quota-mode total
sb traffic group status --json
sb traffic group reset family
sb traffic group remove family
```

使用共享 nftables quota 和独立组用量账本，支持双向合计或仅下行；与单节点
配额可同时生效。每个节点只能属于一个组。创建组启用成员流量统计，修改成员
不清空组累计用量。删除节点或取消其流量统计前需要先移出组。移除组保留用量
记录；清零使用显式 `group reset`。组账期独立于节点账期，关机或漏跑后按当前
账期补偿重置。组用量随完整备份保存，达到配额由内核规则阻断；通知沿用现有
阈值和渠道。

面板：“流量统计、配额与限速 → 多节点共享配额”。

## Cloudflare Tunnel 多域名与路径

使用本地管理的命名 Tunnel UUID 和 credentials JSON。凭据可通过 Cloudflared
官方 `tunnel login` / `tunnel create NAME` 流程取得。

```bash
sb cloudflared install
sb tunnel managed 11111111-2222-3333-4444-555555555555 /root/tunnel-credentials.json
sb tunnel route add web app.example.com http://127.0.0.1:3001
sb tunnel route add api app.example.com http://127.0.0.1:9080 '^/api/'
sb tunnel route list
sb tunnel route remove api
```

在 Cloudflare 将域名 CNAME 指向 `<UUID>.cfargotunnel.com`，或自行使用
`cloudflared tunnel route dns UUID DOMAIN`；管理器不自动修改云端 DNS。
回源限定本机 HTTP(S)，路径规则优先于整个域名，同类规则按列表顺序匹配，
末尾添加 404。调用 Cloudflared 校验 ingress，失败时恢复状态和原服务。
既有 fixed/quick 模式保留，同一时间运行一个模式。

面板：“Cloudflare Tunnel 管理 → 多域名/路径路由管理”。

## Sub-Store 生命周期与节点同步

```bash
sb substore install --port 3001
sb substore update --version 2.39.9 --frontend-version 2.32.2
sb substore status --json
sb substore access
sb substore sync sb-manager
sb substore backup /root/substore-backup.tar.gz
sb substore restore /root/substore-backup.tar.gz
sb substore disable
sb substore enable
```

按需安装发行版 Node.js 和 Python，下载官方后端 bundle 与前端 Release，并
通过 Release API 的 SHA-256 校验。只监听 `127.0.0.1`，后端使用随机访问路径；
`access` 显示前后端地址。可用 SSH 转发，或显式配置 Tunnel 路由访问。

`sync` 将启用节点导入同名 Sub-Store 本地订阅，再次执行则更新内容；修改节点
或凭据后需要重新同步。凭据保存在 secrets 目录，程序和数据位于
`/var/lib/sb-manager/substore/`。服务使用现有服务账号，支持 systemd/OpenRC。
更新或恢复失败会回退程序、数据和设置。

独立备份和完整 `sb backup` 都包含 Sub-Store 数据；备份期间短暂停止正在运行
的 Sub-Store 以取得一致副本，再恢复服务。备份含访问路径和订阅凭据，权限为
0600。普通卸载停止组件并保留数据，彻底卸载才删除。完整恢复沿用 128 MiB
压缩 / 512 MiB 解压上限；独立恢复为 128 MiB 压缩 / 256 MiB 解压上限。

面板主菜单：“Sub-Store 组件与订阅同步”。

## tc 下行平滑限速

```bash
sb deps install shaping
sb traffic set mixed-main --download-rate 50M --upload-rate 20M
sb traffic shaping plan eth0 --capacity 1G
sb traffic shaping enable eth0 --capacity 1G
sb traffic shaping status --json
sb traffic shaping disable
```

对所选网卡上直连节点的**下行**执行 HTB + fq_codel 排队整形。容量参数是
该网卡总整形上限，也涵盖同一网卡的其他流量，应填写实际链路容量。上行、
Tunnel/Nginx loopback 回源和其他网卡的流量继续使用 nftables 限速；预览列出
适用和排除节点。

只接管内核默认 noqueue/mq/fq/fq_codel，或管理器之前恢复的相同队列。自定义
队列、过滤器或无法还原的参数会被拒绝。原队列记录保存在
`/var/lib/sb-manager/shaping/`。调整失败尝试回滚，停用或卸载时恢复；恢复失败
保留记录并中止卸载。默认安装不启用整形。

面板：“流量统计、配额与限速 → tc 下行平滑限速”。

## 验证范围

隔离测试覆盖成功、校验失败、回滚、权限、备份恢复、账期、到期续期及
systemd/OpenRC 服务定义。Alpine 3.21–3.24 容器覆盖新增功能。真实测试覆盖
sing-box 认证与转发、Sub-Store 前端和同步、Cloudflared ingress、iperf3 双向
测速，以及独立网络命名空间内的 tc/nftables 安装与恢复。

当前没有远程测试机，未做远程 Debian/VPS 验收、真实公网 Tunnel、实机重启
或实际业务线路的吞吐提升验收。
