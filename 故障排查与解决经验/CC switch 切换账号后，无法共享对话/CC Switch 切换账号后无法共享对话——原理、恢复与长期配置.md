# CC Switch 切换账号后无法共享对话：原理、恢复与长期配置

> 整理日期：2026-08-16
> 核对环境：Windows、Codex Desktop `26.803.10989.0`、CC Switch `3.19.2`
> 本文不记录或展示任何 API Key、Access Token、`auth.json` 内容。

## 一、先说结论

这次“对话消失”并不是对话被删除，而是同一批本地会话被分进了不同的历史列表。

Codex 的登录身份、会话列表和模型请求链路是三件不同的事：

1. **登录身份**：由 ChatGPT 登录或 API Key 决定，凭据缓存在 `~/.codex/auth.json` 或系统凭据库。
2. **会话列表**：Codex 根据 `model_provider` 标签过滤历史记录；标签不同，就像放在不同抽屉。
3. **请求链路**：请求可以直连官方/中转站，也可以先经过 CC Switch 本地路由，再转发到上游。

因此，“Codex 里显示哪个账号”“左侧能看到哪些对话”“模型请求实际由谁处理”不能互相等同。

## 二、脱敏案例中的已确认事实

只读检查得到：

- CC Switch 的“切换第三方时保留官方登录”已开启。
- “统一 Codex 会话历史”已开启，并勾选过迁入旧官方会话。
- CC Switch 总路由及 Codex 接管处于开启状态。
- 目标对话唯一匹配：
  - 标题：`<TASK_TITLE>`
  - Thread ID：`<TASK_ID>`
  - 会话文件：`<CODEX_HOME>\sessions\<DATE>\rollout-<TIMESTAMP>-<TASK_ID>.jsonl`
  - JSONL 与 `state_5.sqlite` 中的 `model_provider` 都是 `cc-switch-official`。
- CC Switch 的代理接管前备份显示，关闭总路由后原配置的 `model_provider` 是 `custom`。

所以这条对话的正确恢复方向是：

```text
cc-switch-official  →  custom
```

不是改成 `openai`。`custom` 才是当前“关闭总路由、但继续启用统一会话历史”时使用的共享列表。

## 三、为什么会出现三个标签

### 1. `openai`

Codex 的内建官方标签。未启用统一会话历史时，官方登录产生的对话通常归到这里。

### 2. `custom`

CC Switch 用于第三方供应商的共享标签。开启“统一 Codex 会话历史”后，直接连接官方渠道的会话也会使用 `custom`，从而与第三方会话显示在同一个列表。

### 3. `cc-switch-official`

这是 CC Switch 在“官方账号也被本地总路由接管”时使用的临时专用标签。源码说明它是代理接管的所有权标记，便于安全识别和清理代理配置。

问题正发生在这里：

```text
总路由关闭 + 统一历史开启
    当前列表标签 = custom

总路由开启 + 官方供应商经代理接管
    当前列表标签 = cc-switch-official
```

两边标签不同，Codex 左侧历史列表就互相看不见。

### 4. 示例验证矩阵（实际使用前需在本机复核）

案例验证表明：是否支持原生 Responses API，只能说明请求协议是否需要转换，不能单独决定历史列表是否共享。以下矩阵仅记录脱敏案例结果，不应直接视为其他机器的现状：

| 登录/供应商方式 | 总路由 | 脱敏案例结果 |
|---|---:|---|
| OpenAI Official 正式账号 | 关闭 | 进入当前 `custom` 共享列表，可看到并续接共享对话 |
| API 中转站令牌 | 开启 | 进入当前 `custom` 共享列表，可看到并续接共享对话 |
| OpenAI Official 正式账号 | 开启 | 进入 `cc-switch-official`，与 `custom` 列表分裂 |
| API 中转站令牌 | 关闭 | 无法稳定复现当前共享列表；实际标签尚未逐个供应商核验 |

因此，短期操作规则不能简单写成“原生 Responses 就永久关闭路由”。**协议原生与历史分桶是两个独立变量**，应以本机实测矩阵和 `model_provider` 事实为准。

## 四、安全恢复特定任务的方案

### 首选：已知 Thread ID 时直接打开（已验证）

如果已经从 `state_5.sqlite` 或目标 JSONL 中确认了唯一 Thread ID，应先让 Codex 按 ID 直接导航到原任务，不要把修改数据库当作第一步。

脱敏案例验证表明：

- 当前全局配置：`model_provider = "custom"`。
- 目标会话元数据：`model_provider = "cc-switch-official"`。
- 即使目标会话未出现在最近的可见任务列表中，Codex 仍能按 Thread ID 读取并直接打开原任务。
- 导航结果：`navigated = true`；标题、首条任务内容、项目路径和最近消息均与目标会话一致。
- 本次恢复窗口没有修改 JSONL、SQLite、登录凭据或 CC Switch 配置。

该方法恢复的是“原任务窗口”，不会自动修复不同 `model_provider` 造成的左侧列表过滤。若关闭窗口后仍需长期从左侧列表找到它，再评估下面的定向迁移。不要为了测试可写性，向仍承担项目调度职责的旧任务随意发送测试消息。

### 后备：需要长期恢复左侧列表可见性时再定向迁移

以下修改不是恢复窗口的必经步骤。仅在直接导航失败，或用户明确需要把目标任务长期迁入当前 `custom` 列表时执行。

### 修改前提

- 完全退出 Codex Desktop、Codex 后台进程和 CC Switch。
- 确认 `state_5.sqlite-wal` 不再增长，目标 JSONL 不再被占用。
- 不直接编辑 `auth.json`。
- 不批量替换所有 `cc-switch-official` 会话，只处理已核准的 Thread ID。

### 必须备份的内容

1. 目标 JSONL 原文件。
2. `<CODEX_HOME>\state_5.sqlite` 的一致性副本。
3. 若关闭程序后仍存在 `state_5.sqlite-wal` / `state_5.sqlite-shm`，先停止操作，确认数据库已正确检查点，不要单独丢弃 WAL。

### 定向迁移

只修改两处，并保持 Thread ID 一致：

1. JSONL 第一条 `session_meta` 记录：

```json
"model_provider": "cc-switch-official"
```

改为：

```json
"model_provider": "custom"
```

2. `state_5.sqlite` 的 `threads` 表中，仅更新该 ID：

```sql
UPDATE threads
SET model_provider = 'custom'
WHERE id = '<TASK_ID>'
  AND model_provider = 'cc-switch-official';
```

### 验收

1. 保持“统一 Codex 会话历史”开启。
2. 关闭总路由，恢复代理接管前配置。
3. 重新启动 Codex。
4. 确认左侧出现 `<TASK_TITLE>`。
5. 打开后核对首尾消息、附件引用和标题。
6. 查询数据库，确认只更新了一行。

### 回滚

如出现标题缺失、正文打不开或列表异常：

1. 立即退出 Codex 与 CC Switch。
2. 恢复备份的 JSONL 和 `state_5.sqlite`。
3. 不在异常状态下继续批量修改其他会话。

> 案例状态：原任务窗口已通过 Thread ID 直接恢复；定向迁移并非恢复窗口的必经步骤。

## 五、能不能一劳永逸

需要把三个目标分开判断。

### 目标 A：无论官方还是第三方，都显示同一个对话列表

**基本可以做到。**

长期保持：

- `切换第三方时保留官方登录`：开启。
- `统一 Codex 会话历史`：开启。
- 开启时选择“同时迁入现有官方会话历史”。

但还要避免“官方账号经总路由接管”，否则会产生 `cc-switch-official` 这一额外列表。

### 目标 B：所有供应商都能任意接续同一个旧对话

**无法保证。**

会话中的 `encrypted_content` 推理内容可能只能由最初生成它的后端解密。即使左侧能够看到同一条对话，换另一个供应商续聊时仍可能失败。

可靠规则：

- 原供应商继续原对话，成功率最高。
- 更换后端时，使用“交接摘要/便携快照”创建新对话，比强行续接旧会话可靠。
- “列表共享”只解决可见性，不等于“上下文跨后端兼容”。

### 目标 C：永远不出现 502、503、504

**任何配置都无法保证。**

常见含义（最终仍需结合错误正文和路由日志判断）：

- `502`：代理或网关访问上游失败、上游返回无效响应、协议转换失败。
- `503`：上游暂时不可用、过载、熔断或无健康供应商。
- `504`：等待首字节或后续流式数据超时。

关闭本地路由只能减少“CC Switch 本地代理这一层”导致的错误，不能消除中转站、上游 OpenAI、网络或限流产生的错误。

## 六、当前可执行的短期方案

在 CC Switch `3.19.2` 不安装未合并补丁、不开发自定义守护程序的前提下，当前最稳妥的工作流是：

```text
切换第三方时保留官方登录 = 永久开启
统一 Codex 会话历史       = 永久开启

使用 OpenAI Official      = 关闭总路由
使用 API 中转站令牌       = 开启总路由并接管 Codex
```

每次切换令牌前执行：

1. 等待当前回复完全结束，不在请求进行中切换。
2. 先选择目标供应商，再按上表设置总路由。
3. 完全重启 Codex Desktop，让配置和历史筛选条件重新加载。
4. 先确认共享列表中能看到目标旧对话，再继续发送任务。
5. 若列表异常，不创建新长任务；先查看 `config.toml` 与数据库中的实际 `model_provider`。

为了降低遗忘风险，建议重命名供应商：

```text
【必须关路由】OpenAI Official
【必须开路由】Rong_UGF
【必须开路由】OZ_minapi
```

这不是唯一的理论方案，但它是当前版本中唯一不依赖未合并代码、又符合本机实测结果的稳妥方案。

## 七、为什么暂时不能永久开启总路由

CC Switch `3.19.2` 存在已公开确认的问题：开启统一历史并让 OpenAI Official 经本地路由接管时，活动标签仍被写成 `cc-switch-official`，而不是共享的 `custom`。因此永久开启总路由会持续产生新的独立会话。

相关公开进展：

- Issue `#5974`：记录了官方代理接管导致 `custom` / `cc-switch-official` 历史分裂。
- PR `#5735`：拟在统一历史开启时，让官方代理仍以 `custom` 作为活动标签，并把 `cc-switch-official` 仅保留为非活动的接管标记。
- 截至 2026-08-16，PR 仍未合并，状态为存在冲突、需要 Review，不能当作已发布能力。
- Issue `#6340`：普通直连模式如果官方供应商配置显式写了 `model_provider = "openai"`，统一历史也可能静默失效；升级后仍需用实际标签验收，不能只看 UI 开关。

在等效修复正式发布并验证前，不应把全部历史迁入 `cc-switch-official`，也不应为了总路由常开而修改 CC Switch 的所有权标记逻辑。

## 八、中长期选择

### 选择 A：等待官方修复（推荐）

等待 CC Switch 发布包含 PR `#5735` 或等效实现的正式版本。升级后先用测试对话验证官方代理、第三方切换和关闭接管都始终使用 `custom`，再考虑一次性清理其他历史桶。

### 选择 B：自行构建未合并 PR（不推荐日常使用）

技术上可以从 PR 分支构建自定义 CC Switch，但会引入代码冲突、Windows 签名、升级维护和回滚责任。必须在隔离的 `CC_SWITCH_TEST_HOME` 与复制的 Codex 数据上验证，不能直接覆盖当前正式环境。

### 选择 C：开发按供应商自动切换路由的守护程序（可行但需单独立项）

可以检测当前供应商，自动执行“官方关路由、API 开路由、重启 Codex”。但这是自定义自动化，受 CC Switch 数据库结构、进程状态和版本更新影响；必须提供幂等、锁、失败回滚和日志，不能靠简单监控后直接改 `config.toml`。

## 九、快速决策表

| 最重视的目标 | 当前建议 | 主要代价 |
|---|---|---|
| 当前立即稳定共享列表 | 官方关路由；API 开路由；统一历史常开 | 每次切换需人工确认 |
| 未来总路由永久开启 | 等待 PR `#5735` 或等效正式修复 | 发布时间待确认 |
| 使用非原生供应商 | 开启路由和 Codex 接管 | 增加代理与转换故障点 |
| 自动重试、熔断、备用供应商 | 总路由开启 + 故障转移队列 | 仍不能保证零错误或跨后端续聊 |
| 所有供应商任意接续同一长对话 | 当前无法可靠保证 | 用交接摘要 + 新对话兜底 |

## 十、排障检查顺序

遇到“对话消失”时：

1. 不要注销账号、删除缓存或重装 Codex。
2. 记录 CC Switch 的总路由、Codex 接管、统一会话历史三个开关。
3. 查看 `~/.codex/config.toml` 当前 `model_provider`。
4. 在 `~/.codex/state_5.sqlite` 的 `threads` 表按标题定位 Thread ID 和标签。
5. 核对对应 JSONL 第一条 `session_meta` 的 ID 与标签。
6. 先尝试按已核准的 Thread ID 直接打开原任务，并核对标题、首条消息、项目路径和最近消息。
7. 仅当直接打开失败，或确实需要长期恢复左侧列表可见性时，才先备份，再同时修正 JSONL 和数据库；不要只改一边。

遇到 502/503/504 时：

1. 读取完整错误，区分 `CC Switch local proxy failed` 与上游直接错误。
2. 在 CC Switch 请求日志确认实际供应商、上游状态和超时阶段。
3. 检查本地 `127.0.0.1:15721` 服务、端口占用和 Codex 接管状态。
4. 检查供应商余额、限流、模型名、Responses/Chat Completions 协议兼容性。
5. 若启用故障转移，检查备用队列、熔断状态和重试上限。

## 十一、参考资料

- [OpenAI Authentication](https://learn.chatgpt.com/docs/auth)
- [CC Switch：统一 Codex 会话历史](https://github.com/farion1231/cc-switch/blob/main/docs/guides/codex-unified-session-history-guide-zh.md)
- [CC Switch：使用第三方 API 时保留 Codex 官方登录](https://github.com/farion1231/cc-switch/blob/main/docs/guides/codex-official-auth-preservation-guide-zh.md)
- [CC Switch：代理服务](https://github.com/farion1231/cc-switch/blob/main/docs/user-manual/zh/4-proxy/4.1-service.md)
- [CC Switch：应用路由](https://github.com/farion1231/cc-switch/blob/main/docs/user-manual/zh/4-proxy/4.2-routing.md)
- [CC Switch：故障转移](https://github.com/farion1231/cc-switch/blob/main/docs/user-manual/zh/4-proxy/4.3-failover.md)
- [CC Switch Issue #5974：官方路由使统一历史失效](https://github.com/farion1231/cc-switch/issues/5974)
- [CC Switch PR #5735：代理接管期间保持统一历史](https://github.com/farion1231/cc-switch/pull/5735)
- [CC Switch Issue #6340：直连官方显式标签导致统一历史静默失效](https://github.com/farion1231/cc-switch/issues/6340)
