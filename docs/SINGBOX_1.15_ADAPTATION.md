# sing-box 1.15 适配记录

当前仓库的配置生成只使用 1.13/1.14 已验证的协议字段，版本门控通过
`version_ge` 比较完整版本号，因此 sing-box 1.15 不需要额外的状态迁移。

已使用官方 `sing-box 1.15.0-alpha.2` 执行 `tests/run.sh`，覆盖节点添加、
多用户凭据、真实 TCP/UDP 监听、分享链接、客户端 outbound 和配置校验，结果为
`ALL TESTS PASSED`。

适配策略：

1. 稳定安装默认仍跟随 GitHub 最新非 prerelease Release；1.15 alpha 只通过
   `sb core channel preview` 选择，不会自动替换稳定核心。
2. 每次切换核心都继续执行配置 `check`、build tag 检查和配对回滚；失败时恢复
   原核心、配置和状态。
3. 只有确认 1.15 新字段的官方 schema、行为和客户端兼容性后，才新增状态字段和
   renderer 分支，并为 1.14/1.15 分别增加回归测试。

升级前建议：

```bash
sb backup /var/lib/sb-manager/backups/pre-1.15.tar.gz
sb core channel preview
sb core update 1.15.0-alpha.2
sb config validate
sb status --json
```

如果 1.15 正式版引入配置变更，应先导出新核心 schema，与
`docs/STATE_SCHEMA.md` 和生成配置逐项比较，再提交版本门控和迁移测试。
