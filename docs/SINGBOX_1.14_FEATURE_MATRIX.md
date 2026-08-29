# sing-box 1.14 特性与 sb-manager 覆盖矩阵

本项目管理的是 Linux 上的 sing-box 代理节点、客户端导出和受保护的控制面。sing-box 1.14 同时包含桌面客户端、端点和外部服务功能，不能把所有字段都安全地塞进现有 `nodes[]` 模型。

## 已在面板和 CLI 中支持

| 特性 | 面板入口 | CLI | 兼容性 |
| --- | --- | --- | --- |
| Snell v5/v6（v5 HTTP obfs、v6 traffic shaping） | 添加节点 → Snell v5/v6 | `sb node add snell --snell-version 5|6` | v5 需要 1.14+，v6 需要 rc.2+ |
| Hysteria2 Gecko obfs | 添加节点 → Hysteria2 | `--obfs gecko --obfs-min-packet-size N --obfs-max-packet-size N` | 需要 1.14+ |
| Hysteria2 Chrome QUIC 指纹开关 | 添加节点 → Hysteria2 | `--disable-chrome-parrot` | 需要 1.14+ |
| Hysteria2 BBR profile / Brutal debug | 添加节点 → Hysteria2 | `--bbr-profile`、`--brutal-debug` | 需要 1.14+ |
| Optimistic DNS、DNS timeout | 全局设置 → sing-box 1.14 DNS 优化 | `sb settings dns ...` | 需要 1.14+，1.13 自动省略字段 |
| TUN DNS mode/address | 完整客户端配置导出 | `sb export config --mode tun --tun-dns-mode ...` | 需要 1.14+，1.13 保持旧格式 |
| Hysteria Realm rendezvous service | Hysteria Realm 菜单 | `sb realm enable|disable|status|show-token`；Hysteria2 使用 `--realm-id` | 需要 1.14+ |
| API Service / Dashboard | sing-box API/Dashboard | `sb api ...` | loopback-only |
| API CLI | sing-box API/Dashboard | `sb api cli status|outbounds|...` | 需要 1.14+ |
| JSON Schema | 核心与组件更新 → 导出 Schema | `sb core schema [FILE]` | 需要 1.14 beta2+ |
| 核心 build tags 检查 | 核心与组件更新 → 查看核心能力 | `sb core capabilities [--json]` | 按实际二进制能力显示 |

## 已存在但由核心自动提供

- AnyTLS 客户端元数据在 1.14 中默认不再发送；项目导出没有设置该字段，因此使用核心默认行为。
- Hysteria2 客户端 Chrome QUIC parrot 默认开启；只有明确使用 `--disable-chrome-parrot` 时才写入关闭字段。
- 1.14 的统一 HTTP client 已用于 API/Dashboard 的 `http-direct` 配置。

## 需要独立数据模型，暂未接入节点面板

- OpenVPN Server endpoint：需要地址池、TLS/静态密钥、推送路由/DNS、UDP NAT 和客户端用户体系，属于完整 VPN 服务而不是普通代理入站。
- OpenConnect Client、OpenVPN Client：是出站端点，应该进入单独的出站/链路模型，而不是服务端节点列表。
- Network namespace、Bridge、L3 forwarding、UDP NAT 参数：需要主机网络命名空间和权限编排，必须单独设计安全策略。
- TLS spoof：客户端功能，需要 `CAP_NET_RAW`/`CAP_NET_ADMIN` 或管理员权限；项目不会在服务器安装时默认授予这些能力。

## 主要属于桌面客户端或外部服务

Taildrop、Tailscale SSH、USB/IP、Apple/Windows TLS/HTTP engine、桌面客户端远程控制等由 sing-box 图形客户端或 Tailscale 端点管理，不在 sb-manager 的 Linux 代理节点面板范围内。核心是否编译这些功能可用 `sb core capabilities --json` 查看。

所有 1.14 专属字段均经过核心版本门控；状态、配置、凭据和服务操作仍遵循现有候选校验、原子安装和失败回滚流程。
