# 规则变更事件

> 本模板只接受已脱敏的通用信息。不要粘贴聊天原文、内部日志、截图、凭据或可识别来源项目的细节。

## 事件元数据

- 事件 ID：`<EVENT_ID>`
- 状态：`proposed | accepted | in_progress | blocked | verified | delivered | rejected`
- 创建时间：`<ISO_8601_TIMESTAMP>`
- 适用范围：`<SCOPE>`

## 规则增量

- 变更前：`<GENERIC_PREVIOUS_RULE>`
- 变更后：`<GENERIC_NEW_RULE>`
- 变更原因：`<RATIONALE>`

## 已确认事实

- `<FACT_1>`

## 合理假设与待确认事项

- 合理假设：`<ASSUMPTION_OR_NONE>`
- 待确认事项：`<QUESTION_OR_NONE>`

## 影响与约束

- 影响文件或模块：`<AFFECTED_SCOPE>`
- 兼容性影响：`<COMPATIBILITY_IMPACT>`
- 隐私与安全约束：`<SECURITY_CONSTRAINTS>`
- 排除项：`<OUT_OF_SCOPE>`

## 验收与验证

- 验收标准：`<ACCEPTANCE_CRITERIA>`
- 验证方式：`<VERIFICATION_METHOD>`
- 回滚或降级方式：`<ROLLBACK_OR_NOT_APPLICABLE>`

## 稳定回传

- 修改摘要：`<CHANGE_SUMMARY>`
- 验证命令与结果：`<VERIFICATION_RESULT>`
- 未验证项：`<UNVERIFIED_ITEMS_OR_NONE>`
- 隐私与 Secret 检查：`<PRIVACY_AND_SECRET_CHECK_RESULT>`
- 本地 Commit SHA：`<COMMIT_SHA_OR_NONE>`
- 待裁决事项：`<DECISION_REQUIRED_OR_NONE>`
- 远端授权请求：`<REMOTE_AUTHORIZATION_REQUEST_OR_NONE>`
