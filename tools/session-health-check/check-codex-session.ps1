[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [Alias('Id')]
    [string]$TaskId
)

# 支持三种用法：
#   .\check-codex-session.ps1 -TaskId '任务 ID'
#   .\check-codex-session.ps1 '任务 ID'
#   .\check-codex-session.ps1                 # 根据提示输入任务 ID
if ([string]::IsNullOrWhiteSpace($TaskId)) {
    $TaskId = Read-Host '请输入 Codex 任务 ID'
}

$TaskId = $TaskId.Trim()
$taskIdPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

if ($TaskId -notmatch $taskIdPattern) {
    throw "任务 ID 格式无效：$TaskId`n正确示例：00000000-0000-0000-0000-000000000000"
}

function Format-StatusLine {
    param(
        [Parameter(Mandatory)]
        [string]$Label,

        [Parameter(Mandatory)]
        [string]$Value,

        [int]$ValueColumn = 20
    )

    $displayWidth = 0
    foreach ($character in $Label.ToCharArray()) {
        # 当前标签中的中文和全角标点占两列，ASCII 字符占一列。
        $displayWidth += if ([int]$character -le 0x7F) { 1 } else { 2 }
    }

    $paddingWidth = [Math]::Max(1, $ValueColumn - $displayWidth)
    return $Label + (' ' * $paddingWidth) + $Value
}

$roots = @(
    (Join-Path $env:USERPROFILE '.codex\sessions'),
    (Join-Path $env:USERPROFILE '.codex\archived_sessions')
) | Where-Object { Test-Path -LiteralPath $_ }

if (-not $roots) {
    throw '未找到 Codex 会话目录。'
}

$files = @(
    Get-ChildItem -LiteralPath $roots -Recurse -File `
        -Filter "*$taskId*.jsonl" -ErrorAction Stop
)

if ($files.Count -eq 0) {
    throw "未找到任务 $taskId 的本地会话文件。"
}

if ($files.Count -gt 1) {
    throw "同一任务 ID 匹配到多个文件，请人工确认：`n$($files.FullName -join "`n")"
}

$file = $files[0]
$compactCount = 0
$lastToken = $null
$parseWarnings = 0
$stream = $null
$reader = $null

try {
    $stream = [IO.File]::Open(
        $file.FullName,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite
    )
    $reader = [IO.StreamReader]::new($stream)

    while (($line = $reader.ReadLine()) -ne $null) {
        $head = $line.Substring(0, [Math]::Min(512, $line.Length))

        # 只统计顶层 compacted，避免与配对的 context_compacted 重复计数。
        if ($head -match '^\s*\{.*?"type"\s*:\s*"compacted"') {
            $compactCount++
            continue
        }

        if (-not $line.Contains('"type":"token_count"')) {
            continue
        }

        try {
            $record = $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            $parseWarnings++
            continue
        }

        if (
            $record.type -eq 'event_msg' -and
            $record.payload.type -eq 'token_count'
        ) {
            $lastToken = $record
        }
    }
}
catch {
    throw "读取会话文件失败：$($_.Exception.Message)"
}
finally {
    if ($reader) {
        $reader.Dispose()
    }
    elseif ($stream) {
        $stream.Dispose()
    }
}

$file.Refresh()
$sizeMiB = $file.Length / 1MB
$sizeText = $sizeMiB.ToString(
    'F2',
    [Globalization.CultureInfo]::InvariantCulture
)
$state = if ($file.FullName -like '*\archived_sessions\*') {
    '已归档'
}
else {
    '活动中'
}

$contextText = '无法取得'
$contextPercent = $null

if ($lastToken) {
    $inputTokens = $lastToken.payload.info.last_token_usage.input_tokens
    $windowTokens = $lastToken.payload.info.model_context_window

    if ($null -ne $inputTokens -and [double]$windowTokens -gt 0) {
        $contextPercent = [Math]::Round(
            100 * [double]$inputTokens / [double]$windowTokens,
            1
        )
        $percentText = $contextPercent.ToString(
            'F1',
            [Globalization.CultureInfo]::InvariantCulture
        )
        $contextText = "$percentText%"
    }
}

if ($sizeMiB -ge 200) {
    $sizeScore = 4
}
elseif ($sizeMiB -ge 100) {
    $sizeScore = 3
}
elseif ($sizeMiB -ge 50) {
    $sizeScore = 2
}
elseif ($sizeMiB -ge 30) {
    $sizeScore = 1
}
else {
    $sizeScore = 0
}

if ($compactCount -ge 10) {
    $compressionScore = 3
}
elseif ($compactCount -ge 7) {
    $compressionScore = 2
}
elseif ($compactCount -ge 4) {
    $compressionScore = 1
}
else {
    $compressionScore = 0
}

if ($null -eq $contextPercent) {
    $contextBasis = '未取得最近上下文占比；该指标不参与综合评分。'
}
elseif ($contextPercent -ge 85) {
    $contextBasis = "最近输入占窗口 $contextText，达到 85% 观察线；建议自动压缩后复查。"
}
else {
    $contextBasis = "最近输入占窗口 $contextText，尚未达到 85% 观察线。"
}

$totalScore = $sizeScore + $compressionScore
$sizeBasis = "文件为 $sizeText MiB，大小评分 $sizeScore 分；分级线为 30、50、100 和 200 MiB。"
$compressionBasis = "已自动压缩 $compactCount 次，压缩评分 $compressionScore 分；分级线为 4、7 和 10 次。"

if ($totalScore -ge 3) {
    $advice = '建议交接：当前技术指标已达到交接线。请确定当前阶段的任务已完成，或至少处在一个可交接的断点处。'
}
elseif ($totalScore -eq 2) {
    $advice = '建议准备交接：当前技术指标已进入观察区，但不必打断正在执行的复杂步骤。'
}
else {
    $advice = '暂不建议交接：可以继续当前任务。'
}

Format-StatusLine '任务 ID：' $taskId
Format-StatusLine '状态：' $state
Format-StatusLine '路径：' $file.FullName
Format-StatusLine '文件大小：' "$sizeText MiB"
Format-StatusLine '最后修改：' $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss zzz')
Format-StatusLine '上下文压缩：' "$compactCount 次"
Format-StatusLine '最近输入占窗口：' $contextText
''
"交接建议：$advice"
'参考依据：'
"  1. $sizeBasis"
"  2. $contextBasis"
"  3. $compressionBasis"
"  4. 综合评分为 $totalScore 分：0～1 分继续，2 分准备交接，3 分及以上建议交接。"
'  5. 上述分级和 85% 观察线都是本地经验规则，并非 OpenAI 官方限制。'
'人工判断提醒：请主动判断 AI 是否已出现明显理解不足，例如忘记约束、重复执行或前后矛盾；如已出现，应提高交接优先级。'

if ($parseWarnings -gt 0) {
    ''
    "解析警告：$parseWarnings 条 Token 记录未能解析；请在活动任务写入结束后重试。"
}

''
