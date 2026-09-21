# TCP 调优与网络诊断借鉴记录

参考项目：[Eric86777/vps-tcp-tune](https://github.com/Eric86777/vps-tcp-tune)，
审阅版本 `e5f3e8d262a442b3c3f3167885998a84fdd17136`（MIT）。本次借鉴功能
思路，代码按 sb-manager 的模块、锁、备份和 CLI 约定独立实现。

| 参考功能 | sb-manager 的处理 |
| --- | --- |
| 按带宽/地区选择 TCP 缓冲区 | 新增 `sb tcp`，用明确的带宽和 RTT 计算 2 倍 BDP，结合内存限额；先预览，再应用 |
| 网络延迟质量检测 | 新增 `sb network ping`，本地 ping/timeout，提供丢包、RTT、抖动和 JSON |
| Snell 多实例、多端口 | 已有统一节点管理与 Snell v5/v6 导出，继续复用 |
| 按端口流量配额与限速 | 已有节点流量控制和通知机制，继续复用 |
| BBR、UDP 缓冲区 | 已有独立开启/恢复功能；新 TCP 调优不改动其键 |
| Cloudflare Tunnel | 已有 Tunnel 生命周期管理，继续复用 |
| XanMod/BBRv3 内核安装 | 本次不引入内核替换、引导配置修改和自动重启 |
| DNS、IPv6、Swap、第三方脚本入口 | 与本次代理网络诊断的范围不同，未移植 |

上游的地区档位被改为用户提供的实际 RTT，避免把地域直接等同于链路延迟。
本项目不自动运行 Speedtest，也不宣称这些参数必然提升吞吐。现有 `sb bbr`
表示启用内核提供的 `bbr` 算法，并不意味着安装了 BBRv3。

## 参数与恢复

`lib/tcp_tuning.sh` 只管理四个键：`net.ipv4.tcp_rmem`、
`net.ipv4.tcp_wmem`、`net.ipv4.tcp_moderate_rcvbuf`、
`net.ipv4.tcp_mtu_probing`。不改 `net.core.rmem_max/wmem_max`、拥塞控制、
qdisc、防火墙、DNS 或 sing-box 配置。

带宽为 1–100000 Mbps 的整数，RTT 为 1–2000 ms 的整数。缓冲区上限按
`bandwidth_mbps × rtt_ms × 250` 字节计算，向上取整到 MiB，最低建议
4 MiB，再限制到内存的 1/32 与 64 MiB 中的较小值。内存取 `/proc/meminfo`
与可见的 cgroup v2 `memory.max` / v1 `memory.limit_in_bytes` 中的较小值。
非标准 cgroup 挂载可通过 `SBM_TCP_CGROUP_MEMORY_FILES` 指定限额文件。
这是每 socket、每方向的上限，高并发仍需监测实际内存占用。

例如 1 GiB 内存、500 Mbps、200 ms RTT 时：

```text
TCP 调优预览：500 Mbps / RTT 200 ms
每方向缓冲区上限：24 MiB（内存限制：32 MiB）
net.ipv4.tcp_rmem: 4096 131072 6291456 → 4096 131072 25165824
net.ipv4.tcp_wmem: 4096 16384 4194304 → 4096 16384 25165824
net.ipv4.tcp_moderate_rcvbuf: 0 → 1
net.ipv4.tcp_mtu_probing: 0 → 1
```

每次变更先在受保护的备份目录保存 `pending` 快照，保存成功后才安装候选
配置、调用 sysctl 并逐键读取校验。首次 `original` 快照保留到停用；后续
调整失败只恢复调整前的运行值和配置。恢复只写四个已验证的键，不执行旧
配置里可能包含的其他参数。备份损坏或恢复失败时保留恢复资料并返回失败，
不继续卸载。升级无需修改 `state.json` 或执行状态迁移。

系统原有的 sysctl 启动服务负责加载 `/etc/sysctl.d/99-sb-manager-tcp.conf`。
Alpine OpenRC 会在该目录之后加载 `/etc/sysctl.conf` 和 `/run/sysctl.d/`；
其他文件也可能设置相同键，因此预览列出冲突文件，启动后可用 `sb tcp status`
核对。预览不会编辑这些文件。

## 兼容与验证

网络诊断兼容 iputils 与 BusyBox，不使用 BusyBox 不支持的 `ping -n`。
以 `LC_ALL=C` 解析摘要，普通用户可运行；JSON 包含发送/接收数量、丢包率、
RTT、相邻收到的响应 RTT 差值绝对值的平均数和原始 ping 退出码。无响应时
输出结构化结果并返回非零；DNS/权限/命令错误也返回非零。测试只向回环地址
发送真实 ICMP。

```bash
bash tests/tcp-tuning-smoke.sh
SBM_TEST_NETWORK_LOOPBACK=1 bash tests/network-smoke.sh
bash tests/bbr-smoke.sh
bash tests/hy2-udp-buffer-smoke.sh
bash tests/service-lifecycle.sh
bash tests/openrc-lifecycle.sh
bash tests/ui-menu-smoke.sh

# 仅在一次性 Alpine 容器内安装测试依赖；源码只读挂载。
docker run --rm --memory 128m -v "$PWD:/project:ro" alpine:3.24 \
  sh -c 'apk add --no-cache bash >/dev/null && bash /project/tests/alpine-network-smoke.sh'
```

测试覆盖：参数校验、内存/cgroup 限制、只读预览、配置冲突、权限、重复调整、
部分应用失败、读回不一致、回滚失败后重试、损坏/丢失备份、符号链接拒绝、
卸载恢复、iputils/BusyBox 输出、IPv4/IPv6 回环以及 OpenRC 生命周期。
sysctl 写入使用隔离模拟器；Alpine 容器的真实 sysctl 只用于只读检查。

`0.1.0-alpha.31` 已通过本地隔离回归和 Alpine **3.21.7、3.22.5、3.23.5、
3.24.1** 的上述容器测试（内存限额 128 MiB）。本地最小安装测试使用
sing-box `1.14.0`，验证新模块随安装器正常加载；Bash 语法、ShellCheck
error 级检查和离线安装包语法也纳入发布检查。

本次无可用远程测试机，未执行远程 Debian 验收、真实 VPS sysctl 写入或重启
持久化测试，也未做实际线路吞吐对比。容器测试不能替代这些验收。
