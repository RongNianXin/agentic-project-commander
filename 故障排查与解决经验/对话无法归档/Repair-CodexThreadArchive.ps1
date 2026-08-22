[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [Alias('Id')]
    [string]$TaskId,

    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),

    [string]$CodexExe,

    [string]$NodeExe = 'node',

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($TaskId)) {
    $TaskId = Read-Host '请输入无法归档的 Codex 任务 ID'
}

$TaskId = $TaskId.Trim()
if ($TaskId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
    throw "任务 ID 格式无效：$TaskId"
}

function Resolve-ExecutablePath {
    param([Parameter(Mandatory)][string]$Command)

    $resolved = Get-Command $Command -ErrorAction Stop
    return $resolved.Source
}

function Resolve-CodexExecutable {
    param([string]$RequestedPath)

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        if (-not (Test-Path -LiteralPath $RequestedPath -PathType Leaf)) {
            throw "指定的 Codex 可执行文件不存在：$RequestedPath"
        }
        return (Resolve-Path -LiteralPath $RequestedPath).Path
    }

    $runningCandidates = @(
        Get-CimInstance Win32_Process -Filter "Name='codex.exe'" -ErrorAction SilentlyContinue |
            ForEach-Object ExecutablePath |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_) -and
                $_ -notlike '*\WindowsApps\*'
            } |
            Select-Object -Unique
    )

    foreach ($candidate in $runningCandidates) {
        try {
            $versionOutput = & $candidate --version 2>&1
            if ($LASTEXITCODE -eq 0 -and "$versionOutput" -match '^codex-cli\s+') {
                return $candidate
            }
        }
        catch {
            continue
        }
    }

    return Resolve-ExecutablePath 'codex.exe'
}

function Invoke-SqliteHelper {
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$DatabasePath,
        [Parameter(Mandatory)][string]$Id,
        [string]$Argument1,
        [string]$Argument2
    )

    $arguments = @($script:SqliteHelperPath, $Action, $DatabasePath, $Id)
    if ($PSBoundParameters.ContainsKey('Argument1')) { $arguments += $Argument1 }
    if ($PSBoundParameters.ContainsKey('Argument2')) { $arguments += $Argument2 }

    $json = & $script:ResolvedNodeExe @arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "SQLite 辅助程序失败：$json"
    }

    return ($json | Out-String | ConvertFrom-Json)
}

$resolvedCodexHome = (Resolve-Path -LiteralPath $CodexHome).Path
$stateDatabase = Join-Path $resolvedCodexHome 'state_5.sqlite'
if (-not (Test-Path -LiteralPath $stateDatabase -PathType Leaf)) {
    throw "找不到 Codex 状态数据库：$stateDatabase"
}

$script:ResolvedNodeExe = Resolve-ExecutablePath $NodeExe
$nodeVersion = & $script:ResolvedNodeExe --version
if ($LASTEXITCODE -ne 0) {
    throw 'Node.js 无法运行。'
}

$nodeMajor = [int](($nodeVersion -replace '^v', '').Split('.')[0])
if ($nodeMajor -lt 22) {
    throw "需要 Node.js 22 或更高版本，当前为 $nodeVersion。"
}

$timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$backupRoot = Join-Path $resolvedCodexHome 'backups'
$backupDirectory = Join-Path $backupRoot "archive-repair-$timestamp"
$script:SqliteHelperPath = Join-Path ([IO.Path]::GetTempPath()) "codex-archive-repair-$PID-$timestamp.cjs"
$sqliteHelper = @'
const fs = require('node:fs');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');

const [action, databasePath, taskId, argument1, argument2] = process.argv.slice(2);
const db = new DatabaseSync(databasePath);
db.exec('PRAGMA busy_timeout=10000');

function getRow() {
  return db.prepare(`
    SELECT id, rollout_path, archived, archived_at, cli_version
    FROM threads
    WHERE id = ?
  `).get(taskId);
}

function normalizeExtendedPath(value) {
  if (/^\\\\\?\\[A-Za-z]:\\/.test(value)) return value.slice(4);
  return null;
}

function emit(value) {
  process.stdout.write(JSON.stringify(value));
}

if (action === 'inspect') {
  const row = getRow();
  if (!row) {
    emit({ ok: false, reason: 'thread-not-found' });
  } else {
    const normalized = normalizeExtendedPath(row.rollout_path);
    emit({
      ok: true,
      archived: Number(row.archived),
      archivedAt: row.archived_at,
      cliVersion: row.cli_version,
      hasExtendedPrefix: normalized !== null,
      sourceExists: fs.existsSync(row.rollout_path),
      normalizedExists: normalized ? fs.existsSync(normalized) : false,
      sourcePath: row.rollout_path,
      normalizedPath: normalized
    });
  }
} else if (action === 'backup') {
  const target = argument1;
  if (fs.existsSync(target)) throw new Error('backup-already-exists');
  const quoted = target.replaceAll("'", "''");
  db.exec(`VACUUM INTO '${quoted}'`);
  emit({ ok: fs.existsSync(target) });
} else if (action === 'normalize') {
  db.exec('BEGIN IMMEDIATE');
  try {
    const row = getRow();
    if (!row) throw new Error('thread-not-found');
    if (Number(row.archived) !== 0) throw new Error('thread-already-archived');
    if (row.rollout_path !== argument1) throw new Error('rollout-path-changed');
    const result = db.prepare(`
      UPDATE threads
      SET rollout_path = ?
      WHERE id = ? AND rollout_path = ? AND archived = 0
    `).run(argument2, taskId, argument1);
    if (Number(result.changes) !== 1) throw new Error('conditional-update-failed');
    db.exec('COMMIT');
    emit({ ok: true, changes: Number(result.changes) });
  } catch (error) {
    db.exec('ROLLBACK');
    throw error;
  }
} else if (action === 'rollback') {
  db.exec('BEGIN IMMEDIATE');
  try {
    const result = db.prepare(`
      UPDATE threads
      SET rollout_path = ?
      WHERE id = ? AND rollout_path = ? AND archived = 0
    `).run(argument1, taskId, argument2);
    db.exec('COMMIT');
    emit({ ok: Number(result.changes) === 1, changes: Number(result.changes) });
  } catch (error) {
    db.exec('ROLLBACK');
    throw error;
  }
} else if (action === 'verify') {
  const row = getRow();
  emit({
    ok: Boolean(row),
    archived: row ? Number(row.archived) : null,
    archivedAt: row ? row.archived_at : null,
    rolloutExists: row ? fs.existsSync(row.rollout_path) : false,
    sourceStillExists: argument1 ? fs.existsSync(argument1) : null,
    isArchivedDirectory: row
      ? path.basename(path.dirname(row.rollout_path)).toLowerCase() === 'archived_sessions'
      : false
  });
} else {
  throw new Error(`unknown-action:${action}`);
}
'@
Set-Content -LiteralPath $script:SqliteHelperPath -Value $sqliteHelper -Encoding utf8NoBOM

$pathNormalized = $false
$inspection = $null
try {
    $inspection = Invoke-SqliteHelper -Action inspect -DatabasePath $stateDatabase -Id $TaskId
    if (-not $inspection.ok) {
        throw '状态数据库中找不到该任务。请确认任务 ID。'
    }

    if ($inspection.archived -eq 1) {
        Write-Host '任务已经归档，无需修复。'
        return
    }

    if (-not $inspection.hasExtendedPrefix) {
        throw '该任务的 rollout_path 不是已知的 Windows 扩展路径故障，本工具拒绝修改。'
    }

    if (-not $inspection.sourceExists -or -not $inspection.normalizedExists) {
        throw '扩展路径和规范化路径没有同时指向现存文件，本工具拒绝修改。'
    }

    Write-Host '诊断命中：rollout_path 带有 Windows 扩展路径前缀，且源文件实际存在。'
    Write-Host "任务创建时的 Codex 内核版本：$($inspection.cliVersion)"

    if ($DryRun) {
        Write-Host 'DryRun 完成：未修改数据库，也未执行归档。'
        return
    }

    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    $databaseBackup = Join-Path $backupDirectory 'state_5.sqlite'
    $sourceBackup = Join-Path $backupDirectory 'session.jsonl'
    $backupResult = Invoke-SqliteHelper -Action backup -DatabasePath $stateDatabase -Id $TaskId -Argument1 $databaseBackup
    if (-not $backupResult.ok) {
        throw 'SQLite 一致性备份失败。'
    }

    Copy-Item -LiteralPath $inspection.sourcePath -Destination $sourceBackup
    $manifest = [ordered]@{
        createdAtUtc = [DateTime]::UtcNow.ToString('o')
        taskId = $TaskId
        stateDatabaseSha256 = (Get-FileHash -LiteralPath $databaseBackup -Algorithm SHA256).Hash
        sessionSha256 = (Get-FileHash -LiteralPath $sourceBackup -Algorithm SHA256).Hash
        originalRolloutPath = $inspection.sourcePath
        normalizedRolloutPath = $inspection.normalizedPath
    }
    $manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupDirectory 'manifest.json') -Encoding utf8NoBOM

    $null = Invoke-SqliteHelper `
        -Action normalize `
        -DatabasePath $stateDatabase `
        -Id $TaskId `
        -Argument1 $inspection.sourcePath `
        -Argument2 $inspection.normalizedPath
    $pathNormalized = $true

    $resolvedCodexExe = Resolve-CodexExecutable $CodexExe
    $codexVersion = & $resolvedCodexExe --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Codex CLI 无法运行：$codexVersion"
    }
    Write-Host "使用 Codex CLI：$codexVersion"

    $archiveOutput = & $resolvedCodexExe archive $TaskId 2>&1
    $archiveExitCode = $LASTEXITCODE
    if ($archiveExitCode -ne 0) {
        throw "Codex 归档失败：$archiveOutput"
    }

    $verification = Invoke-SqliteHelper `
        -Action verify `
        -DatabasePath $stateDatabase `
        -Id $TaskId `
        -Argument1 $inspection.normalizedPath

    $verified = (
        $verification.ok -and
        $verification.archived -eq 1 -and
        -not [string]::IsNullOrWhiteSpace($verification.archivedAt) -and
        $verification.rolloutExists -and
        -not $verification.sourceStillExists -and
        $verification.isArchivedDirectory
    )

    if (-not $verified) {
        throw "Codex 命令已返回成功，但归档状态回读不完整。不要重复运行；请保留备份：$backupDirectory"
    }

    $pathNormalized = $false
    Write-Host '归档成功：数据库标记、归档时间、归档文件和源文件迁移均已验证。'
    Write-Host "备份目录：$backupDirectory"
}
catch {
    $originalError = $_
    if ($pathNormalized -and $null -ne $inspection) {
        try {
            $rollback = Invoke-SqliteHelper `
                -Action rollback `
                -DatabasePath $stateDatabase `
                -Id $TaskId `
                -Argument1 $inspection.sourcePath `
                -Argument2 $inspection.normalizedPath

            if ($rollback.ok) {
                throw "$($originalError.Exception.Message)`n路径记录已自动回滚。备份位于：$backupDirectory"
            }
        }
        catch {
            if ($_.Exception.Message -like '*路径记录已自动回滚*') {
                throw
            }

            throw "$($originalError.Exception.Message)`n自动回滚未完成，禁止重复运行。备份位于：$backupDirectory`n回滚错误：$($_.Exception.Message)"
        }

        throw "$($originalError.Exception.Message)`n任务状态已发生额外变化，未进行不安全的强制回滚。备份位于：$backupDirectory"
    }

    throw
}
finally {
    if (Test-Path -LiteralPath $script:SqliteHelperPath) {
        Remove-Item -LiteralPath $script:SqliteHelperPath -Force -ErrorAction SilentlyContinue
    }
}
