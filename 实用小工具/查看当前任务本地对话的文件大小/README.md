# Codex 本地会话检查工具

本目录提供一个只读 PowerShell 脚本，用于查看指定 Codex 任务的本地会话文件状态。传统 Windows PowerShell 可以直接执行；Windows Terminal 只是可选的显示界面。

脚本不会修改会话，也不会输出对话正文。文件较大或压缩次数较多只是一项诊断信号；网络代理、具体版本回归、图片/工具输出、后台进程和存储性能仍需分别排查。

## 文件

1. `check-codex-session.ps1`：输出会话文件路径、MiB 大小、最后修改时间、自动压缩次数、最近输入占窗口比例和交接建议。
2. `查看当前任务本地对话文件大小-公开版.docx`：适合下载后离线查看的脱敏使用说明。

## 使用步骤

1. 在目标 Codex 对话中取得任务 ID。可以发送：

   ```text
   请只回复当前任务的本地会话文件绝对路径、任务 ID、文件大小和最后修改时间。
   ```

2. 打开 Windows PowerShell 或 Windows Terminal，进入本目录：

   ```powershell
   Set-Location "<TOOL_DIRECTORY>"
   ```

3. 另起一条命令，传入实际任务 ID：

   ```powershell
   .\check-codex-session.ps1 "00000000-0000-0000-0000-000000000000"
   ```

   也可以不传参数，由脚本提示输入：

   ```powershell
   .\check-codex-session.ps1
   ```

4. 如果执行策略阻止脚本，可使用一次性调用：

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\check-codex-session.ps1" -TaskId "00000000-0000-0000-0000-000000000000"
   ```

## 如何理解结果

1. 脚本根据会话文件大小和历史压缩次数形成综合评分；最近输入占窗口比例作为观察信息。
2. 容量分级、压缩次数分级和 85% 观察线都是本地经验规则，并非 OpenAI 官方限制。
3. 不要只因达到单一阈值就打断复杂任务。交接前应确认当前阶段已完成，或至少处于可交接断点。
4. 如果 AI 已出现忘记约束、重复执行或前后矛盾，应提高交接优先级。

需要 AI 辅助判断时，可以发送：

```text
请独立判断当前任务是否适合交接到新对话。重点检查：当前阶段是否已完成或处于可交接断点，以及你是否出现忘记约束、重复执行、前后矛盾等理解不足。请明确回答“继续当前对话”或“建议交接”，并简述依据。
```

## 可选显示设置

Windows Terminal 可以单独调整终端文字显示。若希望行距稍宽，可在其 `settings.json` 对应配置中使用：

```json
"font": {
  "cellHeight": "1.25"
}
```

该设置只影响 Windows Terminal 的显示，不改变 PowerShell 脚本输出，也不适用于 TXT 文件本身。
