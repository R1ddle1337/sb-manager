# sb-manager-web 完整开发文档

## 文档状态

- 项目状态：架构设计阶段
- 目标仓库：`github.com/R1ddle1337/sb-manager-web`
- 实现语言：Go
- 第一版目标：单服务器 WebUI
- 第二版目标：多服务器主动连接 Agent
- 当前仓库关系：新项目已创建为 [`sb-manager-web`](https://github.com/R1ddle1337/sb-manager-web)；本文件仍是完整设计基线，新项目稳定后同步维护其 `docs/` 目录。

## 1. 项目定位

`sb-manager-web` 是 `sb-manager` 的 Web 控制层，不是新的 sing-box 管理器，也不是对现有 Bash 项目的重写。

现有 `sb-manager` 继续负责所有实际变更：

- `state.json` 和状态迁移
- 节点、用户和凭据管理
- sing-box 配置渲染
- `sing-box check`
- systemd/OpenRC 服务管理
- 证书、备份、恢复和回滚
- 防火墙、流量控制、BBR 和 Hysteria2 UDP 缓冲区优化

新项目负责：

- Web 登录和会话
- 状态展示
- 表单和操作确认
- 本机/远程服务器列表
- Agent 注册和心跳
- 批量任务编排
- 审计日志

核心原则：WebUI 只能通过稳定的 `sb` CLI 或受限的本地执行接口操作，不能直接编辑生成的 `config.json`，也不能复制一份配置渲染器。

## 2. 目标和非目标

### 2.1 目标

第一版必须做到：

1. 服务器只需安装一个静态 Go 二进制即可启动 WebUI。
2. 不要求目标服务器安装 Python、Node.js、npm 或运行时依赖。
3. 默认只监听 loopback，不因为安装 WebUI 自动开放公网端口。
4. 单服务器用户不需要理解 Agent、SSH、mTLS 或任务队列。
5. CLI 和 WebUI 使用同一份本地状态和同一套事务逻辑。
6. 远程服务器可以通过一条加入命令注册，不需要手工配置 SSH 密钥。
7. 所有修改操作都具备超时、结果反馈和本地回滚能力。
8. Alpine/OpenRC 和 Debian/systemd 都有正式支持路径。

### 2.2 非目标

第一版不实现：

- 网页终端或任意 Shell 执行
- 直接修改 sing-box 生成配置
- 中央端保存节点密码和证书私钥
- Kubernetes、Redis、RabbitMQ 或微服务拆分
- 跨服务器的伪原子事务
- 自动关闭或清空系统防火墙
- 重新实现协议渲染器
- 复杂的企业级 RBAC、计费和多租户体系

## 3. 用户体验设计

### 3.1 单服务器安装

前提是服务器已经安装 `sb-manager`：

```bash
curl -fsSL https://github.com/R1ddle1337/sb-manager-web/raw/main/install.sh | sudo bash
sb-web enable
```

安装器需要完成：

1. 检测本机 `/usr/local/bin/sb`。
2. 检查 `sb-manager` 最低兼容版本。
3. 下载对应架构的 `sb-web` 二进制并验证 SHA256。
4. 创建 WebUI 服务用户、配置目录和数据目录。
5. 生成管理员初始凭据。
6. 安装 systemd 或 OpenRC 服务定义。
7. 默认只监听 `127.0.0.1`。
8. 输出访问地址、初始密码和重置命令。

如果服务器已有可用证书，WebUI 可以启用 HTTPS；没有证书时仍可使用 loopback HTTP，并提示通过 SSH 转发或已有 Cloudflare Tunnel 访问。

### 3.2 首次访问

用户执行：

```bash
sb-web status
sb-web reset-admin-password
```

Web 页面首页展示：

- sing-box 版本和 build tags
- 服务状态
- 节点数量和启用数量
- CPU、内存、磁盘和负载
- 流量用量和配额
- 证书有效期
- BBR 状态
- Hysteria2 UDP 缓冲区状态
- 最近失败任务和健康告警

### 3.3 添加服务器

中央 WebUI 生成一次性加入命令：

```bash
sb-web join https://panel.example.com <一次性令牌>
```

用户只需在新服务器执行一次。加入令牌默认：

- 只能使用一次
- 有效期 10 分钟
- 绑定控制端 URL 和证书指纹
- 注册成功后立即失效

新服务器注册后自动生成自己的 Ed25519 密钥，并主动连接控制端。用户不需要填写 SSH 密码、远程端口或手工 mTLS 参数。

### 3.4 批量操作

批量操作界面固定为：

```text
筛选服务器 → 选择操作 → 查看预览 → 确认 → 查看结果
```

结果按服务器显示：

```text
服务器 A：成功
服务器 B：失败（核心 build tag 不满足）
服务器 C：离线，未执行
```

不把多台服务器包装成一个不可回滚的全局事务。每台服务器仍然独立执行本地事务。

## 4. 总体架构

```text
┌────────────────────────────────────────────┐
│ 浏览器                                     │
│ 页面、表单、操作确认、日志和状态           │
└──────────────────┬─────────────────────────┘
                   │ HTTPS / WebSocket
                   ▼
┌────────────────────────────────────────────┐
│ sb-web controller（Go）                    │
│ auth / API / UI / inventory / tasks / audit │
└──────────────┬──────────────────┬──────────┘
               │本机               │远程 Agent
               ▼                   ▼
       sb CLI runner       mTLS Agent channel
               │                   │
               ▼                   ▼
       本机 sb-manager      远程 sb-web agent
                                   │
                                   ▼
                           远程 sb CLI runner
```

### 4.1 运行模式

同一个二进制支持三种模式：

```text
sb-web server    启动 Web 控制端
sb-web agent     启动远程 Agent
sb-web join      使用一次性令牌注册 Agent
```

单服务器只使用 `server`。多服务器时，主控服务器运行 `server`，其他机器运行 `agent`。

### 4.2 数据所有权

| 数据 | 所有者 | WebUI 是否直接写入 |
|---|---|---|
| `state.json` | sb-manager | 否 |
| 生成的 `config.json` | sb-manager | 否 |
| 节点密码、PSK、token | 目标服务器 | 否，临时读取 |
| 证书私钥 | 目标服务器 | 否 |
| WebUI 账号 | sb-manager-web | 是 |
| 服务器清单 | 控制端 sb-manager-web | 是 |
| Agent 私钥 | 对应服务器 | 是，仅本机 |
| 审计日志 | 控制端 sb-manager-web | 是 |
| 加密备份密文 | 可选控制端 | 是，密文形式 |

## 5. 仓库和代码组织

### 5.1 仓库边界

```text
sb-manager/       现有 Bash 项目，独立发布
sb-manager-web/   新 Go 项目，独立发布
```

不建议把整个 `sb-manager` 作为 Git 子模块复制进 WebUI。WebUI 只依赖安装后的 `sb` CLI，并用固定版本的测试夹具进行兼容性测试。

### 5.2 推荐目录

```text
sb-manager-web/
├── cmd/
│   └── sb-web/
│       └── main.go
├── internal/
│   ├── agent/              # Agent 注册、心跳、任务通道
│   ├── api/                # HTTP API、路由、错误处理
│   ├── audit/              # 审计事件
│   ├── auth/               # 密码、会话、CSRF、限速
│   ├── config/             # 配置文件和默认值
│   ├── inventory/          # 服务器清单
│   ├── runner/             # 固定参数调用 sb CLI
│   ├── storage/            # SQLite 数据访问
│   ├── task/               # 任务状态、幂等、超时
│   ├── tlsutil/            # 证书、指纹、mTLS
│   └── web/                # HTML 模板和静态资源
├── web/
│   ├── templates/
│   └── static/
├── deploy/
│   ├── systemd/
│   └── openrc/
├── docs/
├── tests/
├── go.mod
├── go.sum
├── Makefile
├── install.sh
├── LICENSE
└── README.md
```

### 5.3 Go 依赖原则

目标服务器只安装编译后的二进制。建议：

- `CGO_ENABLED=0`
- 使用标准库 `net/http`、`html/template`、`crypto/*`
- 使用纯 Go SQLite 驱动保存控制端元数据并启用 WAL
- 不在运行时依赖 Node、Python 或外部前端服务
- 前端使用 Go 模板和少量原生 JavaScript

## 6. 与 sb-manager 的集成契约

### 6.1 CLI 调用规则

Go 代码必须使用 `exec.CommandContext`，禁止通过 Shell 拼接：

```go
cmd := exec.CommandContext(ctx, sbPath,
    "--json", "status")
```

禁止：

```go
exec.Command("sh", "-c", userInput)
```

参数必须由 Go 的固定 API 映射产生，用户输入只能作为独立参数传递。

### 6.2 启动兼容性检查

WebUI 启动或添加服务器时执行：

```bash
sb version
sb status --json
sb core capabilities --json
```

检查内容：

- sb-manager 版本
- state schema 版本
- sing-box 版本
- CPU 架构
- systemd/OpenRC
- build tags
- BBR 和 Hysteria2 UDP 缓冲区状态

### 6.3 命令分层

只允许调用以下几类命令：

```text
读取：status、node list/show、user list、cert list、logs、doctor
修改：node add/set/enable/disable/delete、user add/set/rotate
系统：core update/rollback、bbr、hy2 buffer、backup、restore
诊断：doctor、probe、health check
```

未来如需新功能，先在 `sb-manager` 增加机器可读输出，再在 WebUI 中接入。不要在 WebUI 解析普通中文输出作为长期协议。

### 6.4 兼容性策略

WebUI 配置声明：

```text
minimum_sb_manager_version
supported_state_schema
required_commands
```

功能不可用时应隐藏或标记为“不支持”，而不是发送未知命令。

远程服务器升级失败不影响其他服务器，任务结果必须保留具体错误和服务器端日志引用。

## 7. 本地执行和权限模型

### 7.1 第一版

第一版允许 `sb-web server` 以 root 运行，但必须满足：

- 默认绑定 `127.0.0.1`
- 所有 API 需要登录
- 不提供任意命令接口
- 只执行固定命令白名单
- 所有命令带 context 超时
- 日志脱敏

这是为了降低跨发行版权限配置复杂度，适合第一版快速落地。

### 7.2 后续拆分

Web 服务稳定后拆为：

```text
sb-web（普通用户，HTTP/API/UI）
    │ 受限 Unix Socket JSON RPC
    ▼
sb-web-helper（root，固定动作）
    │
    ▼
sb-manager CLI
```

Helper 只接受动作名和结构化参数，例如：

```json
{"action":"bbr.enable"}
```

拒绝任何包含 Shell 语法、路径覆盖或未知参数的请求。

## 8. Web API 设计

### 8.1 通用约定

- 前缀：`/api/v1`
- 请求和响应：`application/json`
- 时间：UTC RFC3339
- ID：小写、短横线或 UUID
- 所有修改请求支持 `Idempotency-Key`
- 所有修改请求返回任务 ID
- 所有错误使用统一 JSON 结构

错误格式：

```json
{
  "error": {
    "code": "CORE_INCOMPATIBLE",
    "message": "当前核心不满足 Snell v6 要求",
    "details": {"current":"1.13.19","required":"1.14.0-rc.2"},
    "request_id": "req_01..."
  }
}
```

建议错误码：

```text
AUTH_REQUIRED
AUTH_FAILED
CSRF_FAILED
NOT_FOUND
VALIDATION_FAILED
CONFLICT
STATE_DRIFT
CORE_INCOMPATIBLE
COMMAND_TIMEOUT
COMMAND_FAILED
AGENT_OFFLINE
ROLLBACK_FAILED
BACKUP_REQUIRED
INTERNAL_ERROR
```

### 8.2 服务器 API

```text
GET    /api/v1/servers
POST   /api/v1/servers/enrollment
GET    /api/v1/servers/{id}
DELETE /api/v1/servers/{id}
GET    /api/v1/servers/{id}/status
GET    /api/v1/servers/{id}/capabilities
GET    /api/v1/servers/{id}/health
GET    /api/v1/servers/{id}/logs
```

### 8.3 节点 API

```text
GET    /api/v1/servers/{id}/nodes
POST   /api/v1/servers/{id}/nodes
GET    /api/v1/servers/{id}/nodes/{node_id}
PATCH  /api/v1/servers/{id}/nodes/{node_id}
POST   /api/v1/servers/{id}/nodes/{node_id}/enable
POST   /api/v1/servers/{id}/nodes/{node_id}/disable
DELETE /api/v1/servers/{id}/nodes/{node_id}
GET    /api/v1/servers/{id}/nodes/{node_id}/share
```

### 8.4 系统操作 API

```text
POST /api/v1/servers/{id}/core/check
POST /api/v1/servers/{id}/core/update
POST /api/v1/servers/{id}/core/rollback
POST /api/v1/servers/{id}/bbr/enable
POST /api/v1/servers/{id}/bbr/disable
GET  /api/v1/servers/{id}/bbr/status
POST /api/v1/servers/{id}/hy2-buffer/enable
POST /api/v1/servers/{id}/hy2-buffer/disable
GET  /api/v1/servers/{id}/hy2-buffer/status
POST /api/v1/servers/{id}/backup
POST /api/v1/servers/{id}/doctor
```

### 8.5 任务 API

```text
GET  /api/v1/tasks
GET  /api/v1/tasks/{id}
POST /api/v1/tasks/{id}/cancel
GET  /api/v1/tasks/{id}/events
```

## 9. Agent 设计

### 9.1 连接模型

Agent 主动向控制端建立 HTTPS/WebSocket 长连接：

```text
Agent → TLS ClientHello → 控制端
Agent ← mTLS 验证 ← 控制端
Agent ↔ 心跳、任务、事件、结果
```

控制端不需要连接服务器的 SSH，也不需要开放新的公网入站端口。

### 9.2 注册流程

```text
1. 控制端创建一次性 enrollment token
2. 用户在目标服务器执行 sb-web join
3. Agent 生成 Ed25519 私钥
4. Agent 使用 token 提交公钥和服务器信息
5. 控制端验证 token、URL 和证书指纹
6. 控制端登记 server_id、公钥和能力
7. token 立即失效
8. Agent 启动正式 mTLS/HTTPS 通道
```

令牌不能直接作为长期凭据。注册完成后，长期身份只由 Agent 私钥证明。

### 9.3 心跳内容

心跳只发送非秘密元数据：

```json
{
  "server_id":"srv_hk_01",
  "agent_version":"0.1.0",
  "sb_manager_version":"0.1.0-alpha.27",
  "core_version":"1.14.0-rc.2",
  "arch":"amd64",
  "backend":"systemd",
  "nodes":3,
  "enabled_nodes":2,
  "bbr":true,
  "hy2_udp_buffer":true,
  "sent_at":"2026-08-29T00:00:00Z"
}
```

节点密码、证书私钥和分享 URI 默认不放在心跳中。

### 9.4 任务传递

每个任务包含：

```json
{
  "task_id":"task_01...",
  "idempotency_key":"batch-20260829-01-srv_hk_01",
  "action":"hy2-buffer.enable",
  "args":{},
  "expected_manager_version":">=0.1.0-alpha.27",
  "expected_state_revision":37,
  "deadline":"2026-08-29T00:05:00Z"
}
```

Agent 必须：

1. 校验任务签名和目标 server_id。
2. 校验版本、状态修订号和参数。
3. 拒绝重复执行同一个幂等键。
4. 调用本机 `sb`。
5. 返回退出码、脱敏输出和结果摘要。
6. 保留本地任务 ID，断线重连后可继续上报。

## 10. 状态漂移和版本控制

每台服务器状态需要提供：

```json
{
  "server_id":"srv_hk_01",
  "state_revision":37,
  "state_digest":"sha256:..."
}
```

中央端下发任务时携带期望修订号。如果用户刚刚在服务器本地执行了 `sb node set`，修订号变为 38，则中央任务拒绝执行并显示：

```text
配置已在本地发生变化，请刷新后重新预览。
```

这比直接覆盖本地文件更安全，也保留了 CLI 的独立使用能力。

## 11. 存储设计

### 11.1 SQLite 表

控制端使用单个 SQLite 数据库：

```text
users
sessions
servers
tasks
enrollments
audit
```

每条记录包含 `schema_version` 和 `updated_at`，数据库升级必须可回滚或可备份。

### 11.2 文件位置

建议：

```text
/etc/sb-manager-web/config.json
/var/lib/sb-manager-web/web.db
/var/lib/sb-manager-web/agent-identity/
/var/lib/sb-manager-web/backups/
/var/log/sb-manager-web/
/run/sb-manager-web/
```

WebUI 数据库备份不能替代 sb-manager 的配置备份。两者需要分别备份。

### 11.3 密码和密钥

- 管理员密码只保存 Argon2id 哈希。
- Session token 使用随机不可预测值，只保存哈希或短期签名值。
- Agent 私钥只保存在 Agent 服务器。
- 控制端保存 Agent 公钥。
- enrollment token 只保存哈希、过期时间和使用状态。
- 日志中禁止输出密码、PSK、私钥和完整分享 URI。

## 12. 鉴权和 Web 安全

### 12.1 登录

- 管理员密码使用 Argon2id。
- 登录失败限速和指数退避。
- 登录成功后轮换 Session ID。
- Cookie 设置 `HttpOnly`、`SameSite=Strict`，HTTPS 时设置 `Secure`。
- 支持手动注销和全部会话失效。

### 12.2 CSRF 和请求安全

- 所有修改请求需要 CSRF token。
- 使用严格的 `Origin`/`Referer` 检查。
- 请求体限制大小。
- 路由参数和节点 ID 做白名单校验。
- 页面使用 Content Security Policy。
- 不允许 iframe 嵌入。

### 12.3 监听和 TLS

默认：

```text
127.0.0.1:9091
```

公网访问必须由用户主动选择。支持：

- 已有反向代理
- Cloudflare Tunnel
- 用户提供的证书
- 自动生成的本地自签证书（只适合内网）

WebUI 不应在用户未确认时自动绑定 `0.0.0.0` 或修改防火墙。

## 13. 任务和事务模型

### 13.1 单服务器任务

每个修改任务执行：

```text
接收请求
  → 校验参数
  → 读取当前状态
  → 生成预览
  → 调用 sb
  → 读取结果状态
  → 返回成功或错误
```

实际的候选配置、sing-box 校验、服务切换和回滚由 sb-manager 完成。

### 13.2 多服务器任务

```text
创建批量任务
  → 固定目标核心版本和摘要
  → 获取每台服务器预检查
  → 按顺序或并发上限执行
  → 单机成功/失败分别记录
  → 失败率达到阈值后停止剩余服务器
```

第一版默认并发数为 1，确认稳定后允许配置为 3 或 5。

### 13.3 “latest”处理

中央端批量升级时只解析一次最新 Release：

```text
latest → 具体版本 → SHA256 → 任务
```

所有服务器使用同一个具体版本和摘要，不能让每台 Agent 独立解析 `latest`。

## 14. 前端设计

### 14.1 页面

```text
/login
/
/servers
/servers/:id
/servers/:id/nodes
/servers/:id/certificates
/servers/:id/tasks
/tasks
/audit
/settings
```

### 14.2 页面原则

- 默认先显示状态，再显示操作。
- 危险操作必须二次确认。
- 批量操作先展示目标数量和能力差异。
- 失败结果显示可执行的下一步，而不是只显示退出码。
- 分享链接默认一次性显示，避免写入浏览器长期缓存。
- 秘密字段默认遮蔽，复制按钮需要明确用户操作。

### 14.3 技术选择

第一版使用：

- Go `html/template`
- 原生 JavaScript
- 内嵌 CSS
- `go:embed` 嵌入静态资源

不引入 Node 构建链。若未来页面复杂度明显增加，可以在开发机引入前端构建工具，但发布包仍只包含编译后的静态资源。

## 15. 配置文件

示例：

```json
{
  "listen": "127.0.0.1:9091",
  "sb_path": "/usr/local/bin/sb",
  "data_dir": "/var/lib/sb-manager-web",
  "database": "/var/lib/sb-manager-web/web.db",
  "log_dir": "/var/log/sb-manager-web",
  "tls": {
    "enabled": false,
    "cert_file": "",
    "key_file": ""
  },
  "agent": {
    "enabled": false,
    "controller_url": "",
    "heartbeat_interval": "30s"
  },
  "tasks": {
    "default_timeout": "10m",
    "batch_concurrency": 1,
    "failure_stop_percent": 25
  }
}
```

配置文件只保存监听、路径和策略，不保存节点秘密。

## 16. systemd 和 OpenRC 部署

### 16.1 systemd

服务名称：

```text
sb-manager-web.service
```

要求：

- `NoNewPrivileges=true`
- `PrivateTmp=true`
- `ProtectSystem=full`
- 仅开放必要的 `ReadWritePaths`
- 日志输出到项目日志目录或 journald
- Agent 模式支持自动重启和网络依赖

第一版如果服务需要 root 调用 sb，必须在单元文件中明确说明，并保持监听 loopback。

### 16.2 OpenRC

服务名称：

```text
sb-manager-web
```

要求：

- 使用 `supervise-daemon`
- 支持 `respawn`
- 日志写入 `/var/log/sb-manager-web/`
- Agent 网络断开时自动重连
- 不依赖容器中的伪 OpenRC PID 1

### 16.3 安装、升级和卸载

安装器必须：

1. 检测架构和 init 系统。
2. 下载并验证二进制。
3. 备份旧 WebUI 程序和服务文件。
4. 原子替换程序。
5. 启动后执行健康检查。
6. 启动失败自动恢复上一版。

卸载 WebUI 时：

- 不删除 `sb-manager`。
- 默认保留 WebUI 数据库和审计日志。
- `--purge` 才删除 WebUI 数据。
- 撤销本机 Agent 身份或提示用户在控制端撤销。
- 不删除 sb-manager 的配置、证书和节点数据。

## 17. 日志、监控和审计

### 17.1 运行日志

日志字段：

```text
timestamp
level
request_id
task_id
server_id
action
duration_ms
result
```

禁止记录：

- 密码
- 私钥
- token
- 完整分享 URI
- Authorization header
- Cookie

### 17.2 审计日志

审计事件示例：

```json
{
  "event_id":"evt_01...",
  "actor":"admin",
  "action":"hy2-buffer.enable",
  "targets":["srv_hk_01","srv_jp_01"],
  "started_at":"2026-08-29T00:00:00Z",
  "result":"partial_success",
  "task_id":"task_01..."
}
```

审计日志记录谁、何时、对哪些服务器做了什么，不记录节点秘密。

### 17.3 健康状态

Agent 离线判定：

```text
正常：最近心跳 ≤ 90 秒
警告：90 秒 < 最近心跳 ≤ 5 分钟
离线：最近心跳 > 5 分钟
```

控制端不因短暂离线自动删除服务器，也不自动执行危险恢复动作。

## 18. 备份和恢复

### 18.1 本机备份

WebUI 调用：

```bash
sb backup ...
```

备份密文由 sb-manager 负责生成。WebUI 只负责触发、下载和记录备份索引。

### 18.2 控制端备份

如果用户选择集中保存：

- 只上传 age 加密后的备份文件。
- 控制端不保存解密私钥，除非用户明确配置。
- 下载和删除操作写入审计日志。
- 控制端数据库备份与 sb-manager 备份分开处理。

### 18.3 恢复前确认

恢复是高风险操作，WebUI 必须显示：

- 目标服务器
- 备份时间
- 备份来源
- 预计覆盖的状态范围
- 是否包含证书和密钥
- 当前状态摘要

## 19. 测试计划

### 19.1 Go 单元测试

覆盖：

- 配置解析和默认值
- 参数白名单
- CLI 参数构造
- JSON 响应解析
- 错误映射
- enrollment token 过期和单次使用
- Session、CSRF 和密码哈希
- SQLite 读写、WAL 和迁移
- 任务幂等和超时
- Agent 心跳状态

### 19.2 API 测试

使用假的 `sb` 可执行文件，验证：

- Web 请求不会经过 Shell
- 参数被正确分割
- CLI 失败能返回稳定错误码
- 超时会杀死子进程
- 敏感输出被脱敏
- 未登录请求被拒绝
- CSRF 失败不会触发命令

### 19.3 集成测试

使用真实 sb-manager 和测试 sing-box 核心：

- 节点新增和删除
- 节点启停
- 分享链接导出
- 核心检查、更新、回滚
- BBR 开启和恢复
- Hysteria2 UDP 缓冲区开启和恢复
- 配置失败自动回滚
- 备份和恢复

### 19.4 Agent 测试

使用本地测试 CA 和临时端口验证：

- 首次注册
- 令牌重复使用被拒绝
- 错误证书指纹被拒绝
- 公钥撤销
- Agent 断线重连
- 任务重复投递只执行一次
- 控制端重启后任务状态不丢失

### 19.5 发行版测试

至少覆盖：

- Debian 12/13 + systemd
- Ubuntu 22.04/24.04 + systemd
- Alpine 3.21/3.24 + OpenRC
- amd64
- arm64

## 20. CI 和发布

### 20.1 CI 检查

```bash
gofmt -w .
go vet ./...
go test ./...
go test -race ./...
go build -trimpath -ldflags '-s -w' ./cmd/sb-web
```

同时运行：

- 静态检查
- API 集成测试
- Agent mTLS 测试
- 安装器 Bash 语法检查
- systemd 单元验证
- Alpine smoke test

### 20.2 发布资产

```text
sb-web-linux-amd64
sb-web-linux-arm64
sb-web-linux-armv7
SHA256SUMS
PROVENANCE-SHA256SUMS
```

发布版本必须记录：

- Git commit
- Go 版本
- 构建参数
- 支持的最低 sb-manager 版本
- API 版本
- SHA256

### 20.3 版本兼容

WebUI 使用独立版本号，但发布说明必须明确：

```text
sb-manager-web 0.1.0
最低 sb-manager 0.1.0-alpha.27
支持 state schema v2
```

## 21. 威胁模型

### 21.1 需要防御的风险

- WebUI 账号被暴力破解
- Web 请求注入任意 Shell
- 被盗 enrollment token 注册恶意服务器
- Agent 私钥泄露
- 控制端数据库泄露
- 审计日志泄露凭据
- 重放旧任务
- 用户本地修改被中央端覆盖
- Agent 被降级到不兼容版本

### 21.2 防御措施

- 默认 loopback
- HTTPS/mTLS
- enrollment token 短期、单次、哈希存储
- Agent 独立 Ed25519 身份
- 固定命令白名单
- `exec.CommandContext`，不经过 Shell
- 幂等键和任务过期时间
- 状态修订号和漂移保护
- 日志脱敏
- 最低版本和 build tag 检查
- 备份和本地回滚

### 21.3 不承诺的安全边界

如果用户明确把 WebUI 以 root 身份暴露到公网，且没有 HTTPS、强密码或反向代理，任何应用层设计都不能弥补该部署风险。安装器必须持续提醒这一点。

## 22. 分阶段开发路线

### Phase 0：基础契约

- 创建 `sb-manager-web` 仓库。
- 初始化 Go 模块和目录。
- 实现配置加载、日志、版本输出。
- 实现 `sb` 路径检测。
- 实现安全 CLI runner。
- 建立真实 sb-manager 兼容性测试夹具。

完成标准：可以安全调用 `sb status --json` 并返回结构化结果。

### Phase 1：单服务器 WebUI

- 登录、会话和 CSRF。
- 状态首页。
- 节点列表和节点 CRUD。
- 分享链接。
- 核心检查、更新和回滚。
- BBR 和 Hysteria2 UDP 缓冲区。
- 日志、备份和诊断。
- systemd/OpenRC 服务。

完成标准：单服务器用户不打开交互式 `sb` 菜单也能完成常用管理操作。

### Phase 2：Agent 注册

- 控制端服务器清单。
- 一次性 enrollment token。
- Agent 身份生成。
- mTLS/HTTPS 长连接。
- 心跳和远程状态。
- 远程单服务器操作。

完成标准：新服务器只执行一条加入命令即可出现在 WebUI。

### Phase 3：批量任务

- 标签和地区筛选。
- 批量核心更新。
- 批量 BBR/HY2 优化。
- 并发上限。
- 失败停止阈值。
- 任务事件和审计。
- 单服务器重试和回滚。

完成标准：批量操作结果可逐台追踪，不覆盖本地变更。

### Phase 4：权限和可靠性增强

- root helper 拆分。
- 更细的操作权限。
- Agent 证书轮换。
- 任务断点续传。
- 受控灰度发布。
- 控制端高可用或数据库迁移评估。

## 23. 第一版验收标准

### 安装

- 在 Debian 和 Alpine 上可完成安装。
- 不需要 Python、Node 或 npm。
- 安装失败可以恢复旧版本。
- 默认不开放公网端口。

### 功能

- 可以查看 `sb status --json`。
- 可以新增、编辑、启停和删除节点。
- 可以查看分享链接。
- 可以执行核心升级和回滚。
- 可以开启/恢复 BBR。
- 可以开启/恢复 Hysteria2 UDP 缓冲区。
- 可以查看日志和执行诊断。

### 安全

- 未登录无法执行 CLI。
- 不存在任意命令 API。
- 用户输入不会经过 Shell。
- 密码、私钥和 token 不出现在日志。
- enrollment token 只能使用一次。

### 可靠性

- CLI 超时可控。
- 子进程失败能返回明确错误。
- WebUI 重启不破坏 sb-manager 状态。
- Agent 断线后能恢复心跳。
- 单台远程服务器失败不影响其他服务器。

## 24. 关键设计决策总结

1. Go 只负责 Web、Agent 和编排，不重写 Bash 管理逻辑。
2. `sb-manager` 仍然是状态和配置的唯一真相源。
3. 单服务器优先，多服务器通过主动 Agent 扩展。
4. 默认 loopback，公网暴露必须由用户主动选择。
5. 不使用 SSH 作为用户必须理解的配置项。
6. 远程 Agent 使用一次性令牌注册和独立密钥。
7. 多服务器采用逐台任务，不伪造跨服务器原子事务。
8. `latest` 在控制端解析为具体版本后再批量下发。
9. WebUI 不记录或集中保存节点秘密。
10. 先保证易用和可回滚，再增加 root helper、灰度和复杂权限。

## 25. 开发约定

- 所有 Go 代码提交前运行 `gofmt`、`go vet` 和 `go test`。
- 所有外部输入先校验，再转换为固定 CLI 参数。
- 任何新增 Web API 都必须补 API 测试和审计事件。
- 任何新增 sb-manager CLI 依赖都必须更新兼容性矩阵。
- 不在 WebUI 中复制协议字段默认值；默认值由 sb-manager 决定。
- 不提交真实凭据、证书、Agent 私钥或生产数据库。
- 变更涉及安装、服务和权限时，必须补 Debian/OpenRC 测试。
- 发布前生成 SHA256 和 provenance 文件。

## 26. 当前下一步

新项目正式开始时，建议按以下顺序创建首个迭代：

```text
1. 已创建 sb-manager-web 仓库
2. 已搭建 Go module 和 cmd/internal/web 目录
3. 已实现 sb CLI runner、status 页面和 SQLite 存储
4. 已加入登录、CSRF、session 和节点/系统操作
5. 已加入 Agent 注册、心跳、任务和批量服务器操作
6. 已加入 systemd/OpenRC 安装器和 root helper
7. 继续完善远程 mTLS、备份下载和更完整的页面交互
```

在此之前，不修改现有 `sb-manager` 的协议和状态逻辑，避免 WebUI 项目尚未稳定时影响当前服务器脚本。
