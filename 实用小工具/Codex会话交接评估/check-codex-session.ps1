[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [Alias('Id')]
    [string]$TaskId,

    [switch]$ShowTurnPreview
)

# 支持三种用法：
#   .\check-codex-session.ps1 -TaskId '任务 ID'
#   .\check-codex-session.ps1 '任务 ID'
#   .\check-codex-session.ps1 -TaskId '任务 ID' -ShowTurnPreview
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

        [int]$ValueColumn = 24
    )

    $displayWidth = 0
    foreach ($character in $Label.ToCharArray()) {
        # 当前标签中的中文和全角标点占两列，ASCII 字符占一列。
        $displayWidth += if ([int]$character -le 0x7F) { 1 } else { 2 }
    }

    $paddingWidth = [Math]::Max(1, $ValueColumn - $displayWidth)
    return $Label + (' ' * $paddingWidth) + $Value
}

function Format-MiB {
    param([long]$Bytes)

    return ($Bytes / 1MB).ToString(
        'F2',
        [Globalization.CultureInfo]::InvariantCulture
    ) + ' MiB'
}

function Format-ByteSize {
    param([long]$Bytes)

    if ($Bytes -ge 1GB) {
        return ($Bytes / 1GB).ToString(
            'F2',
            [Globalization.CultureInfo]::InvariantCulture
        ) + ' GiB'
    }

    if ($Bytes -ge 1MB) {
        return Format-MiB $Bytes
    }

    if ($Bytes -ge 1KB) {
        return ($Bytes / 1KB).ToString(
            'F2',
            [Globalization.CultureInfo]::InvariantCulture
        ) + ' KiB'
    }

    return "$Bytes B"
}

function Format-Integer {
    param([long]$Value)

    return $Value.ToString(
        'N0',
        [Globalization.CultureInfo]::InvariantCulture
    )
}

function Format-TokenValue {
    param([long]$Value)

    if ($Value -ge 1000000) {
        return ($Value / 1000000).ToString(
            'F3',
            [Globalization.CultureInfo]::InvariantCulture
        ) + ' M'
    }

    return Format-Integer $Value
}

function Format-EventTimestamp {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    try {
        $parsed = [DateTimeOffset]::Parse(
            $Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
        return $parsed.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz')
    }
    catch {
        return $Value
    }
}

function Format-TurnPreview {
    param(
        [string]$Value,
        [int]$MaximumLength = 48
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    $normalized = [regex]::Replace($Value, '\s+', ' ').Trim()
    if ($normalized.Length -le $MaximumLength) {
        return $normalized
    }

    return $normalized.Substring(0, $MaximumLength) + '…'
}

function Get-JsonlTextFormat {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $probe = $null
    try {
        $probe = [IO.File]::Open(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::ReadWrite
        )
        $buffer = New-Object byte[] 65536
        $count = $probe.Read($buffer, 0, $buffer.Length)
    }
    finally {
        if ($probe) {
            $probe.Dispose()
        }
    }

    $encoding = [Text.UTF8Encoding]::new($false)
    $bomBytes = 0
    $newLineBytes = 1
    $asciiByteWidth = 1
    $encodingKind = 'utf8'

    if (
        $count -ge 3 -and
        $buffer[0] -eq 0xEF -and
        $buffer[1] -eq 0xBB -and
        $buffer[2] -eq 0xBF
    ) {
        $encoding = [Text.UTF8Encoding]::new($true)
        $bomBytes = 3
    }
    elseif (
        $count -ge 2 -and
        $buffer[0] -eq 0xFF -and
        $buffer[1] -eq 0xFE
    ) {
        $encoding = [Text.Encoding]::Unicode
        $bomBytes = 2
        $newLineBytes = 2
        $asciiByteWidth = 2
        $encodingKind = 'utf16le'
    }
    elseif (
        $count -ge 2 -and
        $buffer[0] -eq 0xFE -and
        $buffer[1] -eq 0xFF
    ) {
        $encoding = [Text.Encoding]::BigEndianUnicode
        $bomBytes = 2
        $newLineBytes = 2
        $asciiByteWidth = 2
        $encodingKind = 'utf16be'
    }

    if ($encodingKind -eq 'utf8') {
        for ($index = $bomBytes; $index -lt $count; $index++) {
            if ($buffer[$index] -eq 0x0A) {
                $newLineBytes = if (
                    $index -gt $bomBytes -and
                    $buffer[$index - 1] -eq 0x0D
                ) { 2 } else { 1 }
                break
            }
        }
    }
    elseif ($encodingKind -eq 'utf16le') {
        for ($index = $bomBytes; $index -lt ($count - 1); $index += 2) {
            if ($buffer[$index] -eq 0x0A -and $buffer[$index + 1] -eq 0x00) {
                $newLineBytes = if (
                    $index -ge ($bomBytes + 2) -and
                    $buffer[$index - 2] -eq 0x0D -and
                    $buffer[$index - 1] -eq 0x00
                ) { 4 } else { 2 }
                break
            }
        }
    }
    else {
        for ($index = $bomBytes; $index -lt ($count - 1); $index += 2) {
            if ($buffer[$index] -eq 0x00 -and $buffer[$index + 1] -eq 0x0A) {
                $newLineBytes = if (
                    $index -ge ($bomBytes + 2) -and
                    $buffer[$index - 2] -eq 0x00 -and
                    $buffer[$index - 1] -eq 0x0D
                ) { 4 } else { 2 }
                break
            }
        }
    }

    return [pscustomobject]@{
        Encoding = $encoding
        BomBytes = $bomBytes
        NewLineBytes = $newLineBytes
        AsciiByteWidth = $asciiByteWidth
    }
}

function Get-RecordShape {
    param([string]$Head)

    $typeMatches = [regex]::Matches(
        $Head,
        '"type"\s*:\s*"([^"\\]+)"'
    )

    $topType = if ($typeMatches.Count -ge 1) {
        $typeMatches[0].Groups[1].Value
    }
    else {
        ''
    }

    $payloadType = if ($typeMatches.Count -ge 2) {
        $typeMatches[1].Groups[1].Value
    }
    else {
        ''
    }

    return [pscustomobject]@{
        TopType = $topType
        PayloadType = $payloadType
    }
}

function Get-HeadStringField {
    param(
        [string]$Head,
        [string]$Name
    )

    $match = [regex]::Match(
        $Head,
        '"' + [regex]::Escape($Name) + '"\s*:\s*"([^"\\]*)"'
    )
    if (-not $match.Success) {
        return ''
    }

    return $match.Groups[1].Value
}

function Get-RecordCategory {
    param(
        [string]$TopType,
        [string]$PayloadType
    )

    if ($TopType -eq 'compacted') {
        return '压缩历史快照（不含内联附件）'
    }

    if ($TopType -eq 'turn_context') {
        return '回合上下文与指令'
    }

    if ($TopType -eq 'session_meta') {
        return '会话元数据'
    }

    if ($TopType -eq 'response_item') {
        if ($PayloadType -match '(?i)(tool|function_call|command|web_search|computer|mcp|apply_patch)') {
            return '工具调用与输出'
        }

        if ($PayloadType -match '(?i)(message|reasoning|summary)') {
            return '用户、助手与推理文本'
        }

        return '其他响应记录'
    }

    if ($TopType -eq 'event_msg') {
        if ($PayloadType -eq 'token_count') {
            return 'Token 与速率元数据'
        }

        if ($PayloadType -match '(?i)(exec|tool|command|patch|web|computer|mcp)') {
            return '工具调用与输出'
        }

        if ($PayloadType -match '(?i)(user_message|agent_message|reasoning|summary)') {
            return '用户、助手与推理文本'
        }

        return '其他事件记录'
    }

    return '其他事件与结构'
}

function Get-InlineDataByteCount {
    param(
        [string]$Line,
        [int]$AsciiByteWidth = 1
    )

    $total = [long]0
    $searchFrom = 0
    $needle = 'data:'

    while ($searchFrom -lt $Line.Length) {
        $dataStart = $Line.IndexOf(
            $needle,
            $searchFrom,
            [StringComparison]::Ordinal
        )
        if ($dataStart -lt 0) {
            break
        }

        $quoteEnd = $Line.IndexOf(
            '"',
            $dataStart,
            [StringComparison]::Ordinal
        )
        if ($quoteEnd -lt 0) {
            $quoteEnd = $Line.Length
        }

        $base64Marker = $Line.IndexOf(
            ';base64,',
            $dataStart,
            [StringComparison]::Ordinal
        )
        if ($base64Marker -ge 0 -and $base64Marker -lt $quoteEnd) {
            # data URL 使用 ASCII 字符；UTF-16 文件中每个字符占两个字节。
            $total += [long](
                ($quoteEnd - $dataStart) * $AsciiByteWidth
            )
        }

        $searchFrom = [Math]::Max($dataStart + 5, $quoteEnd + 1)
    }

    return $total
}

function Add-CategoryStat {
    param(
        [hashtable]$ByteTable,
        [hashtable]$RecordTable,
        [string]$Category,
        [long]$Bytes,
        [bool]$CountRecord = $true
    )

    if ($Bytes -le 0) {
        return
    }

    if (-not $ByteTable.ContainsKey($Category)) {
        $ByteTable[$Category] = [long]0
        $RecordTable[$Category] = 0
    }

    $ByteTable[$Category] = [long]$ByteTable[$Category] + $Bytes
    if ($CountRecord) {
        $RecordTable[$Category] = [int]$RecordTable[$Category] + 1
    }
}

function Get-LongProperty {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return [long]0
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return [long]0
    }

    try {
        return [long]$property.Value
    }
    catch {
        return [long]0
    }
}

function Get-TokenSnapshot {
    param([object]$Info)

    if ($null -eq $Info -or $null -eq $Info.total_token_usage) {
        return $null
    }

    $usage = $Info.total_token_usage
    $inputTokens = Get-LongProperty $usage 'input_tokens'
    $cachedInputTokens = Get-LongProperty $usage 'cached_input_tokens'
    $outputTokens = Get-LongProperty $usage 'output_tokens'
    $reasoningTokens = Get-LongProperty $usage 'reasoning_output_tokens'
    $totalTokens = Get-LongProperty $usage 'total_tokens'

    if ($totalTokens -le 0 -and ($inputTokens -gt 0 -or $outputTokens -gt 0)) {
        $totalTokens = $inputTokens + $outputTokens
    }

    return [pscustomobject]@{
        InputTokens = $inputTokens
        CachedInputTokens = $cachedInputTokens
        OutputTokens = $outputTokens
        ReasoningTokens = $reasoningTokens
        TotalTokens = $totalTokens
    }
}

function Get-OrCreateTurnUsage {
    param(
        [hashtable]$Table,
        [int]$TurnIndex,
        [string]$TurnId = '',
        [long]$StartBytes = -1,
        [string]$StartTimestamp = ''
    )

    if (-not $Table.ContainsKey($TurnIndex)) {
        $Table[$TurnIndex] = [pscustomobject]@{
            TurnIndex = $TurnIndex
            TurnId = $TurnId
            Status = '未结束'
            HasTurnContext = $false
            StartBytes = $StartBytes
            EndBytes = [long]-1
            StartTimestamp = $StartTimestamp
            EndTimestamp = ''
            UserPreview = ''
            InputTokens = [long]0
            CachedInputTokens = [long]0
            OutputTokens = [long]0
            ReasoningTokens = [long]0
            TotalTokens = [long]0
        }
    }

    $item = $Table[$TurnIndex]
    if (
        [string]::IsNullOrWhiteSpace($item.TurnId) -and
        -not [string]::IsNullOrWhiteSpace($TurnId)
    ) {
        $item.TurnId = $TurnId
    }
    if ($item.StartBytes -lt 0 -and $StartBytes -ge 0) {
        $item.StartBytes = $StartBytes
    }
    if (
        [string]::IsNullOrWhiteSpace($item.StartTimestamp) -and
        -not [string]::IsNullOrWhiteSpace($StartTimestamp)
    ) {
        $item.StartTimestamp = $StartTimestamp
    }

    return $item
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
$file.Refresh()
$lengthBeforeScan = [long]$file.Length
$textFormat = Get-JsonlTextFormat $file.FullName

$compactCount = 0
$lastTokenInfo = $null
$parseWarnings = 0
$tokenResetWarnings = 0
$tokenBaselineWarnings = 0
$offsetWarnings = 0
$turnContextRecordCount = 0
$duplicateTurnContextCount = 0
$completedTurnCount = 0
$abortedTurnCount = 0
$currentTurnIndex = 0
$turnSequenceCount = 0
$tokenAdvanceCount = 0
$previousTokenSnapshot = $null
$turnUsages = @{}
$turnIdToIndex = @{}
$completedSizeByOrdinal = @{}
$terminalTurnIds = @{}
$categoryBytes = @{}
$categoryRecords = @{}
$cumulativeBytes = [long]$textFormat.BomBytes
$scanEndPosition = [long]0
$lastResidualCategory = '其他事件与结构'
$lastCompletionOrdinal = 0
$lastLineWasCompletion = $false
$lastLineHadNewline = $true
$stream = $null
$reader = $null

if ($textFormat.BomBytes -gt 0) {
    Add-CategoryStat `
        $categoryBytes `
        $categoryRecords `
        '其他事件与结构' `
        $textFormat.BomBytes `
        $false
}

try {
    $stream = [IO.File]::Open(
        $file.FullName,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite
    )
    $reader = [IO.StreamReader]::new(
        $stream,
        $textFormat.Encoding,
        $true,
        65536
    )

    while (($line = $reader.ReadLine()) -ne $null) {
        $recordStartBytes = $cumulativeBytes
        $lineByteCount = [long]$textFormat.Encoding.GetByteCount($line)
        $recordBytes = $lineByteCount + [long]$textFormat.NewLineBytes
        $cumulativeBytes += $recordBytes
        $lastLineWasCompletion = $false

        $head = $line.Substring(0, [Math]::Min(4096, $line.Length))
        $shape = Get-RecordShape $head
        $recordTurnId = Get-HeadStringField $head 'turn_id'
        $recordTimestamp = Get-HeadStringField $head 'timestamp'
        $category = Get-RecordCategory $shape.TopType $shape.PayloadType
        $lastResidualCategory = $category

        $inlineDataBytes = Get-InlineDataByteCount `
            $line `
            $textFormat.AsciiByteWidth
        $inlineDataBytes = [Math]::Min($inlineDataBytes, $recordBytes)
        if ($inlineDataBytes -gt 0) {
            Add-CategoryStat `
                $categoryBytes `
                $categoryRecords `
                '内联图片与附件数据' `
                $inlineDataBytes
        }

        $residualBytes = $recordBytes - $inlineDataBytes
        Add-CategoryStat `
            $categoryBytes `
            $categoryRecords `
            $category `
            $residualBytes

        if ($shape.TopType -eq 'compacted') {
            $compactCount++
        }

        $isTurnStartEvent = (
            $shape.TopType -eq 'event_msg' -and
            $shape.PayloadType -match '^(task_started|turn_started)$'
        )
        if ($isTurnStartEvent) {
            if (
                -not [string]::IsNullOrWhiteSpace($recordTurnId) -and
                $turnIdToIndex.ContainsKey($recordTurnId)
            ) {
                $currentTurnIndex = [int]$turnIdToIndex[$recordTurnId]
            }
            elseif (-not [string]::IsNullOrWhiteSpace($recordTurnId)) {
                if (
                    $currentTurnIndex -gt 0 -and
                    (Get-OrCreateTurnUsage $turnUsages $currentTurnIndex).Status -eq '未结束' -and
                    [string]::IsNullOrWhiteSpace((Get-OrCreateTurnUsage $turnUsages $currentTurnIndex).TurnId)
                ) {
                    # 兼容先出现无 ID 用户消息、稍后才补 turn_id 的旧记录。
                }
                else {
                    $turnSequenceCount++
                    $currentTurnIndex = $turnSequenceCount
                }
                $turnIdToIndex[$recordTurnId] = $currentTurnIndex
            }
            elseif (
                $currentTurnIndex -le 0 -or
                (Get-OrCreateTurnUsage $turnUsages $currentTurnIndex).Status -ne '未结束'
            ) {
                $turnSequenceCount++
                $currentTurnIndex = $turnSequenceCount
            }

            $null = Get-OrCreateTurnUsage `
                $turnUsages `
                $currentTurnIndex `
                $recordTurnId `
                $recordStartBytes `
                $recordTimestamp
        }

        if ($shape.TopType -eq 'turn_context') {
            $turnContextRecordCount++
            if (
                -not [string]::IsNullOrWhiteSpace($recordTurnId) -and
                $turnIdToIndex.ContainsKey($recordTurnId)
            ) {
                $currentTurnIndex = [int]$turnIdToIndex[$recordTurnId]
            }
            elseif (-not [string]::IsNullOrWhiteSpace($recordTurnId)) {
                if (
                    $currentTurnIndex -gt 0 -and
                    (Get-OrCreateTurnUsage $turnUsages $currentTurnIndex).Status -eq '未结束' -and
                    [string]::IsNullOrWhiteSpace((Get-OrCreateTurnUsage $turnUsages $currentTurnIndex).TurnId)
                ) {
                    # 兼容旧格式在 turn_context 才首次提供 turn_id。
                }
                else {
                    $turnSequenceCount++
                    $currentTurnIndex = $turnSequenceCount
                }
                $turnIdToIndex[$recordTurnId] = $currentTurnIndex
            }
            elseif (
                $currentTurnIndex -le 0 -or
                (Get-OrCreateTurnUsage $turnUsages $currentTurnIndex).Status -ne '未结束'
            ) {
                $turnSequenceCount++
                $currentTurnIndex = $turnSequenceCount
            }

            $turnUsage = Get-OrCreateTurnUsage `
                $turnUsages `
                $currentTurnIndex `
                $recordTurnId `
                $recordStartBytes `
                $recordTimestamp
            if ($turnUsage.HasTurnContext) {
                $duplicateTurnContextCount++
            }
            $turnUsage.HasTurnContext = $true
        }

        if (
            $shape.TopType -eq 'event_msg' -and
            $shape.PayloadType -eq 'user_message'
        ) {
            if (
                -not [string]::IsNullOrWhiteSpace($recordTurnId) -and
                $turnIdToIndex.ContainsKey($recordTurnId)
            ) {
                $currentTurnIndex = [int]$turnIdToIndex[$recordTurnId]
            }
            elseif (-not [string]::IsNullOrWhiteSpace($recordTurnId)) {
                if (
                    $currentTurnIndex -gt 0 -and
                    (Get-OrCreateTurnUsage $turnUsages $currentTurnIndex).Status -eq '未结束' -and
                    [string]::IsNullOrWhiteSpace((Get-OrCreateTurnUsage $turnUsages $currentTurnIndex).TurnId)
                ) {
                    # 当前匿名回合取得正式 ID，不创建重复回合。
                }
                else {
                    $turnSequenceCount++
                    $currentTurnIndex = $turnSequenceCount
                }
                $turnIdToIndex[$recordTurnId] = $currentTurnIndex
            }
            elseif (
                $currentTurnIndex -le 0 -or
                (Get-OrCreateTurnUsage $turnUsages $currentTurnIndex).Status -ne '未结束'
            ) {
                $turnSequenceCount++
                $currentTurnIndex = $turnSequenceCount
                if (-not [string]::IsNullOrWhiteSpace($recordTurnId)) {
                    $turnIdToIndex[$recordTurnId] = $currentTurnIndex
                }
            }

            $turnUsage = Get-OrCreateTurnUsage `
                $turnUsages `
                $currentTurnIndex `
                $recordTurnId `
                $recordStartBytes `
                $recordTimestamp
            if (
                -not [string]::IsNullOrWhiteSpace($recordTurnId) -and
                -not $turnIdToIndex.ContainsKey($recordTurnId)
            ) {
                $turnIdToIndex[$recordTurnId] = $currentTurnIndex
            }

            if ($ShowTurnPreview -and [string]::IsNullOrWhiteSpace($turnUsage.UserPreview)) {
                try {
                    $userRecord = $line | ConvertFrom-Json -ErrorAction Stop
                    $messageProperty = $userRecord.payload.PSObject.Properties['message']
                    if (
                        $null -ne $messageProperty -and
                        $messageProperty.Value -is [string]
                    ) {
                        $turnUsage.UserPreview = Format-TurnPreview ([string]$messageProperty.Value)
                    }
                }
                catch {
                    $parseWarnings++
                }
            }
        }

        if (
            $shape.TopType -eq 'event_msg' -and
            $shape.PayloadType -eq 'token_count'
        ) {
            try {
                $record = $line | ConvertFrom-Json -ErrorAction Stop
                $info = $record.payload.info
                if ($null -ne $info) {
                    $candidateLastUsage = $info.last_token_usage
                    $candidateWindow = Get-LongProperty `
                        $info `
                        'model_context_window'
                    $candidateInputProperty = if ($null -ne $candidateLastUsage) {
                        $candidateLastUsage.PSObject.Properties['input_tokens']
                    }
                    else {
                        $null
                    }
                    if (
                        $null -ne $candidateInputProperty -and
                        $null -ne $candidateInputProperty.Value -and
                        $candidateWindow -gt 0
                    ) {
                        $lastTokenInfo = $info
                    }
                }

                $snapshot = Get-TokenSnapshot $info
                if ($null -ne $snapshot -and $snapshot.TotalTokens -gt 0) {
                    if ($currentTurnIndex -le 0) {
                        $turnSequenceCount++
                        $currentTurnIndex = $turnSequenceCount
                    }
                    $turnUsage = Get-OrCreateTurnUsage `
                        $turnUsages `
                        $currentTurnIndex `
                        '' `
                        $recordStartBytes `
                        $recordTimestamp

                    if ($null -eq $previousTokenSnapshot) {
                        if (
                            $currentTurnIndex -le 1 -and
                            $completedTurnCount -eq 0 -and
                            $abortedTurnCount -eq 0
                        ) {
                            $deltaInput = $snapshot.InputTokens
                            $deltaCached = $snapshot.CachedInputTokens
                            $deltaOutput = $snapshot.OutputTokens
                            $deltaReasoning = $snapshot.ReasoningTokens
                            $deltaTotal = $snapshot.TotalTokens
                        }
                        else {
                            # 首个累计快照若出现在后续回合，可能包含缺失的历史记录。
                            $tokenBaselineWarnings++
                            $deltaInput = [long]0
                            $deltaCached = [long]0
                            $deltaOutput = [long]0
                            $deltaReasoning = [long]0
                            $deltaTotal = [long]0
                        }
                    }
                    elseif ($snapshot.TotalTokens -gt $previousTokenSnapshot.TotalTokens) {
                        $deltaInput = [Math]::Max(0, $snapshot.InputTokens - $previousTokenSnapshot.InputTokens)
                        $deltaCached = [Math]::Max(0, $snapshot.CachedInputTokens - $previousTokenSnapshot.CachedInputTokens)
                        $deltaOutput = [Math]::Max(0, $snapshot.OutputTokens - $previousTokenSnapshot.OutputTokens)
                        $deltaReasoning = [Math]::Max(0, $snapshot.ReasoningTokens - $previousTokenSnapshot.ReasoningTokens)
                        $deltaTotal = $snapshot.TotalTokens - $previousTokenSnapshot.TotalTokens
                    }
                    elseif ($snapshot.TotalTokens -lt $previousTokenSnapshot.TotalTokens) {
                        # 累计计数发生回退时重新建立基线，避免把旧累计量重复归入当前回合。
                        $tokenResetWarnings++
                        $deltaInput = [long]0
                        $deltaCached = [long]0
                        $deltaOutput = [long]0
                        $deltaReasoning = [long]0
                        $deltaTotal = [long]0
                    }
                    else {
                        # 相同累计快照可能只是速率限制更新，不能重复计算 last_token_usage。
                        $deltaInput = [long]0
                        $deltaCached = [long]0
                        $deltaOutput = [long]0
                        $deltaReasoning = [long]0
                        $deltaTotal = [long]0
                    }

                    if ($deltaTotal -gt 0) {
                        $turnUsage.InputTokens += [long]$deltaInput
                        $turnUsage.CachedInputTokens += [long]$deltaCached
                        $turnUsage.OutputTokens += [long]$deltaOutput
                        $turnUsage.ReasoningTokens += [long]$deltaReasoning
                        $turnUsage.TotalTokens += [long]$deltaTotal
                        $tokenAdvanceCount++
                    }

                    $previousTokenSnapshot = $snapshot
                }
            }
            catch {
                $parseWarnings++
            }
        }

        $isCompleteEvent = (
            $shape.TopType -eq 'event_msg' -and
            $shape.PayloadType -match '^(task_complete|turn_complete)$'
        )
        $isAbortEvent = (
            $shape.TopType -eq 'event_msg' -and
            $shape.PayloadType -match '^(turn_aborted|task_aborted)$'
        )

        if ($isCompleteEvent -or $isAbortEvent) {
            $turnId = $recordTurnId

            $isDuplicateTerminal = (
                -not [string]::IsNullOrWhiteSpace($turnId) -and
                $terminalTurnIds.ContainsKey($turnId)
            )

            if (-not $isDuplicateTerminal) {
                if (-not [string]::IsNullOrWhiteSpace($turnId)) {
                    $terminalTurnIds[$turnId] = $true
                }

                if (
                    -not [string]::IsNullOrWhiteSpace($turnId) -and
                    $turnIdToIndex.ContainsKey($turnId)
                ) {
                    $currentTurnIndex = [int]$turnIdToIndex[$turnId]
                }
                elseif (
                    -not [string]::IsNullOrWhiteSpace($turnId) -and
                    $currentTurnIndex -gt 0 -and
                    (Get-OrCreateTurnUsage $turnUsages $currentTurnIndex).Status -eq '未结束' -and
                    [string]::IsNullOrWhiteSpace((Get-OrCreateTurnUsage $turnUsages $currentTurnIndex).TurnId)
                ) {
                    $turnIdToIndex[$turnId] = $currentTurnIndex
                }
                elseif (
                    $currentTurnIndex -le 0 -or
                    (Get-OrCreateTurnUsage $turnUsages $currentTurnIndex).Status -ne '未结束' -or
                    (
                        -not [string]::IsNullOrWhiteSpace($turnId) -and
                        -not [string]::IsNullOrWhiteSpace((Get-OrCreateTurnUsage $turnUsages $currentTurnIndex).TurnId) -and
                        (Get-OrCreateTurnUsage $turnUsages $currentTurnIndex).TurnId -ne $turnId
                    )
                ) {
                    $turnSequenceCount++
                    $currentTurnIndex = $turnSequenceCount
                    if (-not [string]::IsNullOrWhiteSpace($turnId)) {
                        $turnIdToIndex[$turnId] = $currentTurnIndex
                    }
                }
                $turnUsage = Get-OrCreateTurnUsage `
                    $turnUsages `
                    $currentTurnIndex `
                    $turnId `
                    $recordStartBytes `
                    $recordTimestamp
                $turnUsage.EndBytes = $cumulativeBytes
                $turnUsage.EndTimestamp = $recordTimestamp

                if ($isCompleteEvent) {
                    $turnUsage.Status = '已完成'
                    $completedTurnCount++
                    $completedSizeByOrdinal[$completedTurnCount] = $cumulativeBytes
                    $lastCompletionOrdinal = $completedTurnCount
                    $lastLineWasCompletion = $true
                }
                else {
                    $turnUsage.Status = '已中止'
                    $abortedTurnCount++
                }

            }
        }
    }

    $scanEndPosition = [long]$stream.Position
    if ($scanEndPosition -gt 0) {
        $savedPosition = $stream.Position
        $null = $stream.Seek(-1, [IO.SeekOrigin]::End)
        $lastByte = $stream.ReadByte()
        $lastLineHadNewline = ($lastByte -eq 0x0A)
        $null = $stream.Seek($savedPosition, [IO.SeekOrigin]::Begin)
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

if (-not $lastLineHadNewline -and $cumulativeBytes -gt 0) {
    $cumulativeBytes -= [long]$textFormat.NewLineBytes
    if ($categoryBytes.ContainsKey($lastResidualCategory)) {
        $categoryBytes[$lastResidualCategory] = [Math]::Max(
            0,
            [long]$categoryBytes[$lastResidualCategory] - [long]$textFormat.NewLineBytes
        )
    }
    if ($lastLineWasCompletion -and $lastCompletionOrdinal -gt 0) {
        $completedSizeByOrdinal[$lastCompletionOrdinal] -= [long]$textFormat.NewLineBytes
        if (
            $currentTurnIndex -gt 0 -and
            $turnUsages.ContainsKey($currentTurnIndex) -and
            $turnUsages[$currentTurnIndex].EndBytes -ge 0
        ) {
            $turnUsages[$currentTurnIndex].EndBytes -= [long]$textFormat.NewLineBytes
        }
    }
}

if ($scanEndPosition -ne $cumulativeBytes) {
    # 极少数混合换行文件可能让按行估算与实际字节位置不一致。
    $offsetDifference = $scanEndPosition - $cumulativeBytes
    if (-not $categoryBytes.ContainsKey($lastResidualCategory)) {
        $categoryBytes[$lastResidualCategory] = [long]0
        $categoryRecords[$lastResidualCategory] = 0
    }
    $categoryBytes[$lastResidualCategory] = [Math]::Max(
        0,
        [long]$categoryBytes[$lastResidualCategory] + $offsetDifference
    )
    $cumulativeBytes = $scanEndPosition
    $offsetWarnings++
}

foreach ($turnUsage in $turnUsages.Values) {
    if ($turnUsage.StartBytes -lt 0) {
        $turnUsage.StartBytes = [long]0
    }
    if ($turnUsage.EndBytes -lt 0) {
        $turnUsage.EndBytes = $cumulativeBytes
    }
}

$completedTurnCount = @(
    $turnUsages.Values | Where-Object { $_.Status -eq '已完成' }
).Count
$abortedTurnCount = @(
    $turnUsages.Values | Where-Object { $_.Status -eq '已中止' }
).Count
$unfinishedTurnCount = @(
    $turnUsages.Values | Where-Object { $_.Status -eq '未结束' }
).Count

$file.Refresh()
$latestLength = [long]$file.Length
$fileChangedDuringScan = (
    $latestLength -ne $lengthBeforeScan -or
    $latestLength -ne $scanEndPosition
)
$sizeMiB = $latestLength / 1MB
$sizeText = Format-MiB $latestLength
$storageState = if ($file.FullName -like '*\archived_sessions\*') {
    '已归档'
}
else {
    '未归档（不代表应用正在运行）'
}

$contextText = '无法取得'
$contextPercent = $null

if ($null -ne $lastTokenInfo) {
    $lastUsage = $lastTokenInfo.last_token_usage
    $inputProperty = if ($null -ne $lastUsage) {
        $lastUsage.PSObject.Properties['input_tokens']
    }
    else {
        $null
    }
    $windowTokens = Get-LongProperty $lastTokenInfo 'model_context_window'

    if (
        $null -ne $inputProperty -and
        $null -ne $inputProperty.Value -and
        $windowTokens -gt 0
    ) {
        $inputTokens = [long]$inputProperty.Value
        $contextPercent = [Math]::Round(
            100 * [double]$inputTokens / [double]$windowTokens,
            1
        )
        $contextText = $contextPercent.ToString(
            'F1',
            [Globalization.CultureInfo]::InvariantCulture
        ) + '%'
    }
}

$maximumTurnIndex = if ($turnUsages.Count -gt 0) {
    [int]($turnUsages.Keys | Measure-Object -Maximum).Maximum
}
else {
    0
}
$startedTurnCount = $maximumTurnIndex

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
$sizeBasis = "文件为 $sizeText，大小评分 $sizeScore 分；分级线为 30、50、100 和 200 MiB。"
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

$tokenRankings = @(
    $turnUsages.Values |
        Where-Object { $_.TotalTokens -gt 0 } |
        Sort-Object -Property `
            @{ Expression = { $_.TotalTokens }; Descending = $true }, `
            @{ Expression = { $_.TurnIndex }; Descending = $false } |
        Select-Object -First 3
)

$fileRankings = @(
    $categoryBytes.GetEnumerator() |
        Where-Object { $_.Value -gt 0 } |
        Sort-Object -Property `
            @{ Expression = { $_.Value }; Descending = $true }, `
            @{ Expression = { $_.Key }; Descending = $false } |
        Select-Object -First 3
)

'一、基本信息'
Format-StatusLine '任务 ID：' $taskId
Format-StatusLine '会话存储状态：' $storageState
Format-StatusLine '路径：' $file.FullName
Format-StatusLine '最后修改：' $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss zzz')
Format-StatusLine '最近输入占窗口：' $contextText
''
'二、文件资源'
Format-StatusLine '上下文压缩：' "$compactCount 次"
Format-StatusLine '回合统计：' "已完成 $completedTurnCount 轮；已中止 $abortedTurnCount 轮；未结束 $unfinishedTurnCount 轮"
Format-StatusLine '回合识别：' "原始 turn_context $turnContextRecordCount 条；按 turn_id/终止边界合并重复 $duplicateTurnContextCount 条；识别 $startedTurnCount 轮"

foreach ($milestone in @(1, 5, 15, 20)) {
    $milestoneLabel = '{0:D2} 轮完成后文件大小：' -f $milestone
    if ($completedSizeByOrdinal.ContainsKey($milestone)) {
        $milestoneText = Format-MiB $completedSizeByOrdinal[$milestone]
    }
    else {
        $milestoneText = "尚未达到（当前已完成 $completedTurnCount 轮）"
    }
    Format-StatusLine $milestoneLabel $milestoneText
}

if ($startedTurnCount -gt 0) {
    $latestTurnStatus = if ($turnUsages.ContainsKey($startedTurnCount)) {
        $turnUsages[$startedTurnCount].Status
    }
    else {
        '状态待确认'
    }
    Format-StatusLine '最新回合与文件：' "第 $startedTurnCount 轮（$latestTurnStatus）；$sizeText"
}
else {
    Format-StatusLine '最新回合与文件：' "未识别到回合；$sizeText"
}

''
'三、主要消耗分析'
'单位说明：M tokens 表示百万 Token；MiB 表示本地文件字节（1 MiB = 1,048,576 B），二者不能固定换算。'
'Token 消耗最高回合（按本地累计 Token 快照增量）：'
if ($tokenRankings.Count -gt 0 -and $tokenAdvanceCount -gt 0) {
    $rankNames = @('第一', '第二', '第三')
    for ($index = 0; $index -lt $tokenRankings.Count; $index++) {
        $item = $tokenRankings[$index]
        $totalText = Format-TokenValue $item.TotalTokens
        $totalExactText = Format-Integer $item.TotalTokens
        $inputText = Format-TokenValue $item.InputTokens
        $cachedText = Format-TokenValue $item.CachedInputTokens
        $outputText = Format-TokenValue $item.OutputTokens
        $reasoningText = Format-TokenValue $item.ReasoningTokens
        "  $($rankNames[$index])：第 $($item.TurnIndex) 轮（$($item.Status)），$totalText tokens（精确值 $totalExactText）；输入 $inputText（其中缓存 $cachedText），输出 $outputText（其中推理 $reasoningText）。"

        $locatorParts = @()
        $timestamp = if (-not [string]::IsNullOrWhiteSpace($item.EndTimestamp)) {
            Format-EventTimestamp $item.EndTimestamp
        }
        else {
            Format-EventTimestamp $item.StartTimestamp
        }
        if (-not [string]::IsNullOrWhiteSpace($timestamp)) {
            $locatorParts += "事件时间 $timestamp（可对照界面显示的分钟）"
        }
        if (-not [string]::IsNullOrWhiteSpace($item.TurnId)) {
            $suffixStart = [Math]::Max(0, $item.TurnId.Length - 8)
            $locatorParts += "回合 ID 尾号 $($item.TurnId.Substring($suffixStart))"
        }
        $turnFileBytes = [Math]::Max(
            0,
            [long]$item.EndBytes - [long]$item.StartBytes
        )
        $locatorParts += "本轮 JSONL 增长 $(Format-MiB $turnFileBytes)"
        if ($ShowTurnPreview -and -not [string]::IsNullOrWhiteSpace($item.UserPreview)) {
            $locatorParts += "用户输入【$($item.UserPreview)】"
        }
        "    定位：$($locatorParts -join '；')。"
    }
}
else {
    '  无法可靠取得：当前文件没有可用的累计 Token 增量。'
}
if (-not $ShowTurnPreview) {
    '  快速定位：重新运行时加 -ShowTurnPreview，可在前三名下显示用户输入摘要；默认关闭以避免意外展示对话内容。'
}

'本地会话文件占用前三（不等同于 Token 消耗）：'
if ($fileRankings.Count -gt 0 -and $scanEndPosition -gt 0) {
    $rankNames = @('第一', '第二', '第三')
    for ($index = 0; $index -lt $fileRankings.Count; $index++) {
        $item = $fileRankings[$index]
        $percentage = [Math]::Round(
            100 * [double]$item.Value / [double]$scanEndPosition,
            1
        ).ToString('F1', [Globalization.CultureInfo]::InvariantCulture)
        $recordCount = if ($categoryRecords.ContainsKey($item.Key)) {
            $categoryRecords[$item.Key]
        }
        else {
            0
        }
        $byteText = Format-ByteSize $item.Value
        "  $($rankNames[$index])：$($item.Key)，$byteText，占 $percentage%，涉及 $recordCount 条记录。"
    }
}
else {
    '  无法取得：未扫描到完整的本地会话记录。'
}

''
'四、交接建议'
"交接建议：$advice"
'参考依据：'
"  1. $sizeBasis"
"  2. $contextBasis"
"  3. $compressionBasis"
"  4. 综合评分为 $totalScore 分：0～1 分继续，2 分准备交接，3 分及以上建议交接。"
'  5. 上述分级和 85% 观察线都是本地经验规则，并非 OpenAI 官方限制。'
'人工判断提醒：请主动判断 AI 是否已出现明显理解不足，例如忘记约束、重复执行或前后矛盾；如已出现，应提高交接优先级。'

if (
    $parseWarnings -gt 0 -or
    $tokenResetWarnings -gt 0 -or
    $tokenBaselineWarnings -gt 0 -or
    $offsetWarnings -gt 0 -or
    $duplicateTurnContextCount -gt 0 -or
    $fileChangedDuringScan
) {
    ''
    '扫描提醒：'
    if ($parseWarnings -gt 0) {
        "  - $parseWarnings 条关键记录未能解析；活动任务写入结束后可重试。"
    }
    if ($tokenResetWarnings -gt 0) {
        "  - 累计 Token 计数回退 $tokenResetWarnings 次；回退点已重新建立基线，排名可能少计但不会把旧累计量重复计算。"
    }
    if ($tokenBaselineWarnings -gt 0) {
        "  - 首个累计 Token 快照出现在后续回合 $tokenBaselineWarnings 次；该快照仅作为基线，排名可能少计但不会把历史累计量误算到单一回合。"
    }
    if ($offsetWarnings -gt 0) {
        "  - 检测到非统一编码或换行；最终文件占用已按实际扫描字节校正，历史里程碑大小可能有轻微偏差。"
    }
    if ($duplicateTurnContextCount -gt 0) {
        "  - 检测到 $duplicateTurnContextCount 条重复 turn_context；已按回合 ID 或相邻终止边界合并，避免把内部上下文记录误报为界面回合。"
    }
    if ($fileChangedDuringScan) {
        '  - 文件在扫描期间仍有写入；轮次、Token 和内容占比以本次已读取数据为准。'
    }
}

''
