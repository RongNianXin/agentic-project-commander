# 故障排查与解决经验

这里保存已经复现、确认并完成脱敏的 Codex 与相关工具故障记录。每份资料应尽量说明现象、适用环境、可能原因、检查步骤、预期结果、回滚方式和仍待确认的风险。

## 当前内容

- [CC Switch 长任务断联与 401、502、503、504 快速处理](<CC Switch 长任务断联与 401 502 503 504 快速处理.md>)
- [CC Switch 切换账号后无法共享对话](<CC switch 切换账号后，无法共享对话/CC Switch 切换账号后无法共享对话——原理、恢复与长期配置.md>)
- [CC Switch 切换账号后旧对话无法继续](<CC switch切换账号后，旧的对话无法继续/Codex 切换账号后旧对话无法继续.md>)
- [历史任务批量迁移工具](<CC switch切换账号后，旧的对话无法继续/codex-bulk-session-migration/README.md>)
- [相关项目、许可证与差异说明](<相关项目、许可证与差异说明.md>)

## 先判断是哪一类问题

| 现象 | 优先判断 | 对应资料 |
| --- | --- | --- |
| 切换 Provider 后任务从列表消失，但 JSONL 仍在 | `model_provider`、状态库或索引的可见性/分桶不一致 | [切换账号后无法共享对话](<CC switch 切换账号后，无法共享对话/CC Switch 切换账号后无法共享对话——原理、恢复与长期配置.md>) |
| 任务仍能看到，但继续时出现 `invalid_encrypted_content`、`could not be verified` 或组织不匹配 | 旧账号、模型或上游绑定的加密推理/压缩状态无法重放 | [切换账号后旧对话无法继续](<CC switch切换账号后，旧的对话无法继续/Codex 切换账号后旧对话无法继续.md>) |
| 长任务打开、恢复或输入明显变慢 | 先区分本地会话体积/压缩累积、网络代理、进程资源和具体版本回归 | [只读会话检查工具](<../实用小工具/查看当前任务本地对话的文件大小/README.md>) |
| CC Switch 切换时希望长期避免跨供应商续接失败 | 需要切换前进程门禁、备份、候选转换、验证、原子提交和回滚事务 | [历史任务批量迁移工具](<CC switch切换账号后，旧的对话无法继续/codex-bulk-session-migration/README.md>) |

“历史列表能看见”和“旧任务能够跨供应商继续”不是同一问题。统一 `model_provider` 可以修复可见性，但不能转换其他账号、组织或上游生成的密文。

## 使用边界

- 公开资料不是 OpenAI 或 CC Switch 的官方修复，当前版本是否仍使用相同会话结构属于「待确认」。
- 密文迁移是最后手段：优先恢复原账号/原 Provider；必须迁移时，先在副本验证，再离线备份、安装并保留回滚清单。
- 不得使用按文本行删除 `encrypted_content` 的做法；未知结构必须失败关闭，不能猜测删除。
- 会话文件大小、压缩次数和上下文比例只能提供诊断线索，不能单独证明卡顿、费用或模型退化的根因。
- 分享排查结果时只提供版本、错误码、数量、大小、时间和脱敏哈希，不上传原始 JSONL、数据库、提示词、工具输出、绝对路径或凭据。
- 引用第三方项目时同时说明许可证、实现差异和是否复制源码，不把独立项目描述成官方合作或本仓库原创。

## 相关公开问题

- [CC Switch #4464：统一会话历史迁移后 encrypted_content 解密失败](https://github.com/farion1231/cc-switch/issues/4464)
- [CC Switch #3866：迁移改写 JSONL mtime，导致 resume 排序异常](https://github.com/farion1231/cc-switch/issues/3866)
- [OpenAI Codex #17541：模型/Provider 切换后密文无法解密](https://github.com/openai/codex/issues/17541)
- [OpenAI Codex #25290：持久化推理/压缩密文导致会话重放失败](https://github.com/openai/codex/issues/25290)
- [OpenAI Codex #25390：Windows 上大型本地任务打开后严重卡顿](https://github.com/openai/codex/issues/25390)

故障资料不得包含真实账号、任务 ID、绝对用户路径、凭据、聊天原文或生成态扫描报告。历史案例中的版本与第三方行为只代表当时环境，使用前需要重新验证。
