import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { constants as fsConstants } from "node:fs";
import { homedir } from "node:os";
import {
  access,
  copyFile,
  mkdir,
  open,
  readdir,
  readFile,
  realpath,
  rename,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { basename, dirname, isAbsolute, join, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";
import {
  FORMAT_VERSION,
  sha256File,
  transformFile,
  validateCandidate,
} from "./codex_session_sanitizer.mjs";

const USER_HOME = homedir();
const CODEX_HOME = join(USER_HOME, ".codex");
const CC_SWITCH_HOME = join(USER_HOME, ".cc-switch");
// Codex moves archived tasks into archived_sessions. Only sessions remains visible
// in the normal task list, so archived history must stay outside this migration.
const SESSION_ROOT = join(CODEX_HOME, "sessions");
const SESSION_SCOPE = "unarchived-only";
const BACKUP_ROOT = join(USER_HOME, "Documents", "Codex", "CodexSessionBackups");
const PACKAGE_DIR = dirname(fileURLToPath(import.meta.url));
const STAGE_A_REPORT = join(PACKAGE_DIR, "stage-a-report.json");
const SESSION_FILE_PATTERN = /^rollout-.*-[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\.jsonl$/i;
const BLOCKING_PROCESSES = new Set([
  "cc-switch.exe",
  "cc_switch.exe",
  "chatgpt.exe",
  "codex.exe",
  "codex-code-mode-host.exe",
  "codex-command-runner.exe",
]);

function fail(message) {
  throw new Error(message);
}

async function exists(path) {
  try {
    await access(path, fsConstants.F_OK);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}

function timestamp() {
  return new Date().toISOString().replaceAll(":", "-").replace(/\.\d{3}Z$/, "Z");
}

function parseTaskListCsv(line) {
  const fields = [];
  let current = "";
  let quoted = false;
  for (let index = 0; index < line.length; index += 1) {
    const character = line[index];
    if (character === '"') {
      if (quoted && line[index + 1] === '"') {
        current += '"';
        index += 1;
      } else quoted = !quoted;
    } else if (character === "," && !quoted) {
      fields.push(current);
      current = "";
    } else current += character;
  }
  fields.push(current);
  return fields;
}

function findBlockingProcesses(output) {
  return output
    .split(/\r?\n/)
    .filter(Boolean)
    .map((line) => parseTaskListCsv(line)[0]?.toLowerCase())
    .filter(
      (name) =>
        BLOCKING_PROCESSES.has(name) ||
        name?.startsWith("codex-command-runner-") ||
        name?.startsWith("codex-code-mode-host-"),
    );
}

function assertApplicationsClosed() {
  let output;
  try {
    output = execFileSync("tasklist.exe", ["/fo", "csv", "/nh"], {
      encoding: "utf8",
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
    });
  } catch {
    fail("无法读取系统进程列表，已拒绝执行。请勿绕过此检查");
  }
  const running = [...new Set(findBlockingProcesses(output))];
  if (running.length > 0) {
    fail(`请先完全退出 Codex 和 CC-Switch。仍在运行：${running.join(", ")}`);
  }
}

async function* walk(root) {
  let entries;
  try {
    entries = await readdir(root, { withFileTypes: true });
  } catch (error) {
    if (error?.code === "ENOENT") return;
    throw error;
  }
  for (const entry of entries) {
    const path = join(root, entry.name);
    // Do not follow directory links or junctions that could escape SESSION_ROOT.
    if (entry.isSymbolicLink()) continue;
    if (entry.isDirectory()) yield* walk(path);
    else if (entry.isFile() && SESSION_FILE_PATTERN.test(entry.name)) yield path;
  }
}

async function discoverSessions() {
  const paths = [];
  for await (const path of walk(SESSION_ROOT)) paths.push(path);
  return paths.sort();
}

async function assertSessionPathsInScope(paths) {
  const canonicalRoot = await realpath(SESSION_ROOT);
  for (const source of paths) {
    const canonicalSource = await realpath(source);
    const scopedPath = relative(canonicalRoot, canonicalSource);
    const escapedRoot =
      scopedPath === "" ||
      scopedPath === ".." ||
      scopedPath.startsWith(`..${sep}`) ||
      isAbsolute(scopedPath);
    if (escapedRoot || !SESSION_FILE_PATTERN.test(basename(canonicalSource))) {
      fail(`检测到扫描范围外的任务文件，已拒绝执行：${source}`);
    }
  }
}

async function fsyncFile(path) {
  const handle = await open(path, "r+");
  try {
    await handle.sync();
  } finally {
    await handle.close();
  }
}

async function copyAndVerify(source, destination, expectedHash) {
  await mkdir(dirname(destination), { recursive: true });
  await copyFile(source, destination, fsConstants.COPYFILE_EXCL);
  await fsyncFile(destination);
  if ((await sha256File(destination)) !== expectedHash) {
    await rm(destination, { force: true });
    fail(`备份哈希验证失败：${destination}`);
  }
}

async function writeManifest(path, manifest) {
  const temporary = `${path}.${process.pid}.tmp`;
  const previous = `${path}.${process.pid}.previous`;
  await writeFile(temporary, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  await fsyncFile(temporary);
  if (!(await exists(path))) {
    await rename(temporary, path);
    return;
  }
  await rename(path, previous);
  try {
    await rename(temporary, path);
    await rm(previous, { force: true });
  } catch (error) {
    if (!(await exists(path)) && (await exists(previous))) await rename(previous, path);
    await rm(temporary, { force: true });
    throw error;
  }
}

async function backupAuxiliaryFiles(backupDir) {
  const paths = [
    join(CODEX_HOME, "config.toml"),
    join(CODEX_HOME, "state_5.sqlite"),
    join(CODEX_HOME, "state_5.sqlite-wal"),
    join(CODEX_HOME, "state_5.sqlite-shm"),
    join(CC_SWITCH_HOME, "cc-switch.db"),
    join(CC_SWITCH_HOME, "cc-switch.db-wal"),
    join(CC_SWITCH_HOME, "cc-switch.db-shm"),
  ];
  const result = [];
  for (const source of paths) {
    if (!(await exists(source))) continue;
    const hash = await sha256File(source);
    const group = source.startsWith(CC_SWITCH_HOME) ? "cc-switch" : "codex";
    const backup = join(backupDir, "auxiliary", group, basename(source));
    await copyAndVerify(source, backup, hash);
    result.push({ source, backup, sha256: hash });
  }
  return result;
}

async function prepareCandidates(runId, paths, manifest, manifestPath) {
  for (let index = 0; index < paths.length; index += 1) {
    const source = paths[index];
    const candidate = `${source}.${runId}.candidate`;
    const rollback = `${source}.${runId}.original`;
    if ((await exists(candidate)) || (await exists(rollback))) {
      fail(`检测到旧迁移残留文件，拒绝覆盖：${source}`);
    }
    const result = await transformFile(source, candidate);
    if (result.encryptedFieldsBefore === 0) {
      await rm(candidate, { force: true });
    } else {
      await validateCandidate(candidate, result);
      manifest.files.push({
        source,
        relativePath: relative(CODEX_HOME, source),
        candidate,
        rollback,
        backup: null,
        status: "candidate-validated",
        ...result,
      });
    }
    manifest.progress.scanned = index + 1;
    manifest.progress.affected = manifest.files.length;
    if ((index + 1) % 10 === 0 || result.encryptedFieldsBefore > 0) {
      console.log(`[准备 ${index + 1}/${paths.length}] encrypted=${result.encryptedFieldsBefore}`);
    }
    if ((index + 1) % 25 === 0) await writeManifest(manifestPath, manifest);
  }
}

async function backupSources(backupDir, manifest, manifestPath) {
  for (let index = 0; index < manifest.files.length; index += 1) {
    const file = manifest.files[index];
    const backup = join(backupDir, "sessions", file.relativePath);
    await copyAndVerify(file.source, backup, file.sourceSha256);
    file.backup = backup;
    file.status = "backup-verified";
    manifest.progress.backedUp = index + 1;
    if ((index + 1) % 10 === 0) {
      console.log(`[备份 ${index + 1}/${manifest.files.length}]`);
      await writeManifest(manifestPath, manifest);
    }
  }
}

async function restoreCommittedFiles(manifest) {
  for (const file of [...manifest.files].reverse()) {
    if (await exists(file.rollback)) {
      await rm(file.source, { force: true });
      await rename(file.rollback, file.source);
      file.status = "restored-after-failure";
    }
    await rm(file.candidate, { force: true });
  }
}

async function commitCandidates(manifest, manifestPath) {
  manifest.status = "committing";
  await writeManifest(manifestPath, manifest);
  try {
    for (let index = 0; index < manifest.files.length; index += 1) {
      const file = manifest.files[index];
      if ((await sha256File(file.source)) !== file.sourceSha256) {
        fail(`源文件在备份后发生变化：${file.source}`);
      }
      if ((await sha256File(file.candidate)) !== file.candidateSha256) {
        fail(`候选文件在提交前发生变化：${file.candidate}`);
      }
      await rename(file.source, file.rollback);
      try {
        await rename(file.candidate, file.source);
      } catch (error) {
        await rename(file.rollback, file.source);
        throw error;
      }
      if ((await sha256File(file.source)) !== file.candidateSha256) {
        fail(`提交后哈希不匹配：${file.source}`);
      }
      file.status = "committed";
      manifest.progress.committed = index + 1;
      await writeManifest(manifestPath, manifest);
      if ((index + 1) % 10 === 0) console.log(`[提交 ${index + 1}/${manifest.files.length}]`);
    }

    // Keep same-directory originals until the final installed manifest is durable.
    // If the manifest write fails, the catch block can still restore every source.
    for (const file of manifest.files) file.status = "installed";
    manifest.status = "installed";
    manifest.installedAt = new Date().toISOString();
    await writeManifest(manifestPath, manifest);
  } catch (error) {
    manifest.status = "rolling-back-after-failure";
    await writeManifest(manifestPath, manifest).catch(() => {});
    await restoreCommittedFiles(manifest);
    manifest.status = "rolled-back-after-failure";
    manifest.failure = error.message;
    await writeManifest(manifestPath, manifest).catch(() => {});
    throw error;
  }

  const cleanupWarnings = [];
  for (const file of manifest.files) {
    try {
      await rm(file.rollback, { force: true });
    } catch (error) {
      cleanupWarnings.push({ path: file.rollback, error: error.message });
    }
  }
  if (cleanupWarnings.length > 0) {
    manifest.cleanupWarnings = cleanupWarnings;
    console.warn(`迁移已完成，但 ${cleanupWarnings.length} 个临时原件未能删除；正式备份仍然有效。`);
    await writeManifest(manifestPath, manifest).catch(() => {});
  }
}

async function applyMigration() {
  assertApplicationsClosed();
  const stageA = JSON.parse(await readFile(STAGE_A_REPORT, "utf8"));
  if (stageA?.success !== true || stageA?.sanitizerFormatVersion !== FORMAT_VERSION) {
    fail("阶段 A 报告无效或转换器版本不匹配");
  }

  const runId = `bulk-${timestamp()}`;
  const backupDir = join(BACKUP_ROOT, runId);
  await mkdir(BACKUP_ROOT, { recursive: true });
  await mkdir(backupDir, { recursive: false });
  const manifestPath = join(backupDir, "manifest.json");
  const paths = await discoverSessions();
  await assertSessionPathsInScope(paths);
  console.log(`仅扫描当前未归档任务：${paths.length} 个；已归档任务不会扫描或修改。`);
  const manifest = {
    schemaVersion: 1,
    sanitizerFormatVersion: FORMAT_VERSION,
    sessionScope: SESSION_SCOPE,
    sessionRoot: SESSION_ROOT,
    runId,
    status: "preparing",
    createdAt: new Date().toISOString(),
    codexHome: CODEX_HOME,
    files: [],
    auxiliary: [],
    progress: { scanned: 0, affected: 0, backedUp: 0, committed: 0 },
  };
  await writeManifest(manifestPath, manifest);

  try {
    await prepareCandidates(runId, paths, manifest, manifestPath);
    manifest.status = "candidates-validated";
    await writeManifest(manifestPath, manifest);
    manifest.auxiliary = await backupAuxiliaryFiles(backupDir);
    await backupSources(backupDir, manifest, manifestPath);
    manifest.status = "backups-verified";
    await writeManifest(manifestPath, manifest);
    assertApplicationsClosed();
    await commitCandidates(manifest, manifestPath);
  } catch (error) {
    for (const file of manifest.files) await rm(file.candidate, { force: true }).catch(() => {});
    manifest.failure ??= error.message;
    if (!manifest.status.startsWith("rolled-back")) manifest.status = "failed-before-commit";
    await writeManifest(manifestPath, manifest).catch(() => {});
    throw error;
  }
  console.log(`批量迁移已安装。迁移文件：${manifest.files.length}；备份目录：${backupDir}`);
}

async function latestRestorableManifest() {
  const entries = await readdir(BACKUP_ROOT, { withFileTypes: true });
  const paths = entries
    .filter((entry) => entry.isDirectory() && entry.name.startsWith("bulk-"))
    .map((entry) => join(BACKUP_ROOT, entry.name, "manifest.json"))
    .sort()
    .reverse();
  for (const path of paths) {
    if (!(await exists(path))) continue;
    const manifest = JSON.parse(await readFile(path, "utf8"));
    if (["installed", "committing", "backups-verified"].includes(manifest.status)) {
      return { path, manifest };
    }
  }
  fail("没有找到可回滚的批量迁移备份");
}

async function rollbackLatest() {
  assertApplicationsClosed();
  const { path: manifestPath, manifest } = await latestRestorableManifest();
  const rollbackSnapshot = join(dirname(manifestPath), `before-rollback-${timestamp()}`);
  await mkdir(rollbackSnapshot, { recursive: false });

  for (let index = 0; index < manifest.files.length; index += 1) {
    const file = manifest.files[index];
    if (!(await exists(file.source)) || !(await exists(file.backup))) {
      fail(`回滚所需文件缺失：${file.source}`);
    }
    if ((await sha256File(file.backup)) !== file.sourceSha256) {
      fail(`原始备份哈希不匹配：${file.backup}`);
    }
    const currentHash = await sha256File(file.source);
    const currentBackup = join(rollbackSnapshot, file.relativePath);
    await copyAndVerify(file.source, currentBackup, currentHash);
  }

  const restored = [];
  try {
    for (const file of manifest.files) {
      const temporary = `${file.source}.${process.pid}.restoring`;
      await copyAndVerify(file.backup, temporary, file.sourceSha256);
      const current = `${file.source}.${process.pid}.pre-restore`;
      await rename(file.source, current);
      restored.push({ file, current });
      try {
        await rename(temporary, file.source);
      } catch (error) {
        await rename(current, file.source);
        restored.pop();
        throw error;
      }
    }
  } catch (error) {
    for (const { file, current } of restored.reverse()) {
      await rm(file.source, { force: true });
      await rename(current, file.source);
    }
    throw error;
  }
  for (const { current } of restored) await rm(current, { force: true });
  manifest.status = "rolled-back";
  manifest.rolledBackAt = new Date().toISOString();
  manifest.beforeRollback = rollbackSnapshot;
  await writeManifest(manifestPath, manifest);
  console.log(`批量迁移已回滚。迁移后现场备份：${rollbackSnapshot}`);
}

async function selfTest() {
  const sample = [
    '"ChatGPT.exe","100","Console","1","100 K"',
    '"cc-switch.exe","101","Console","1","100 K"',
    '"codex-command-runner-x86_64-pc-windows-msvc.exe","103","Console","1","100 K"',
    '"notepad.exe","102","Console","1","100 K"',
  ].join("\r\n");
  const detected = [...new Set(findBlockingProcesses(sample))].sort();
  if (
    JSON.stringify(detected) !==
    JSON.stringify([
      "cc-switch.exe",
      "chatgpt.exe",
      "codex-command-runner-x86_64-pc-windows-msvc.exe",
    ])
  ) {
    fail("进程门禁自测失败");
  }
  if (
    !SESSION_FILE_PATTERN.test("rollout-2026-08-13T00-00-00-00000000-0000-0000-0000-000000000000.jsonl") ||
    SESSION_FILE_PATTERN.test("00000000-0000-0000-0000-000000000000.backup.jsonl")
  ) {
    fail("正式会话文件识别自测失败");
  }
  if (
    SESSION_SCOPE !== "unarchived-only" ||
    SESSION_ROOT !== join(CODEX_HOME, "sessions") ||
    SESSION_ROOT.includes("archived_sessions")
  ) {
    fail("未归档任务扫描范围自测失败");
  }
  const paths = await discoverSessions();
  await assertSessionPathsInScope(paths);
  console.log("PASS: bulk installer process guard");
  console.log(`PASS: ${paths.length} unarchived sessions are in scope; archived sessions are excluded`);
}

const mode = process.argv[2];
if (mode === "--apply") await applyMigration();
else if (mode === "--rollback-latest") await rollbackLatest();
else if (mode === "--self-test") await selfTest();
else console.log("未修改任何文件。参数：--apply、--rollback-latest、--self-test");
