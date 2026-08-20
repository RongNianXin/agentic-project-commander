import assert from "node:assert/strict";
import { access, mkdtemp, readFile, rm, rmdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  countEncryptedFields,
  sha256File,
  transformFile,
  validateCandidate,
} from "./codex_session_sanitizer.mjs";

const testDir = await mkdtemp(join(tmpdir(), "codex-session-safety-"));
const source = join(testDir, "source.jsonl");
const candidate = join(testDir, "candidate.jsonl");
const unknownSource = join(testDir, "unknown.jsonl");
const unknownCandidate = join(testDir, "unknown-candidate.jsonl");

const preservedRecords = [
  {
    type: "response_item",
    payload: {
      type: "message",
      role: "user",
      content: [
        { type: "input_text", text: "你好，请阅读附件" },
        { type: "input_file", file_id: "file_test_123", filename: "资料.pdf" },
      ],
    },
  },
  {
    type: "response_item",
    payload: {
      type: "message",
      role: "assistant",
      content: [{ type: "output_text", text: "附件内容已收到" }],
    },
  },
  {
    type: "event_msg",
    payload: { type: "agent_message", message: "encrypted_content 只是普通可见文本" },
  },
];

const encryptedReasoning = {
  type: "response_item",
  payload: {
    type: "reasoning",
    summary: [],
    encrypted_content: "synthetic-ciphertext",
  },
};

try {
  const originalRecords = [preservedRecords[0], encryptedReasoning, ...preservedRecords.slice(1)];
  await writeFile(source, `${originalRecords.map(JSON.stringify).join("\n")}\n`, "utf8");
  const sourceHash = await sha256File(source);

  const result = await transformFile(source, candidate);
  await validateCandidate(candidate, result);
  assert.equal(result.encryptedFieldsBefore, 1);
  assert.equal(result.encryptedFieldsAfter, 0);
  assert.equal(await sha256File(source), sourceHash, "source file must remain unchanged");

  const sanitizedRecords = (await readFile(candidate, "utf8"))
    .trimEnd()
    .split("\n")
    .map(JSON.parse);
  assert.deepEqual(sanitizedRecords, preservedRecords, "visible records and attachment metadata changed");
  assert.equal(
    sanitizedRecords.reduce((total, record) => total + countEncryptedFields(record), 0),
    0,
  );

  const unknownRecord = {
    type: "response_item",
    payload: {
      type: "message",
      role: "assistant",
      encrypted_content: "unsupported-location",
      content: [{ type: "output_text", text: "不能被静默删除" }],
    },
  };
  await writeFile(unknownSource, `${JSON.stringify(unknownRecord)}\n`, "utf8");
  const unknownHash = await sha256File(unknownSource);
  await assert.rejects(
    transformFile(unknownSource, unknownCandidate),
    /Unclassified encrypted fields|Candidate retains/,
  );
  assert.equal(await sha256File(unknownSource), unknownHash, "unsupported source file changed");
  await assert.rejects(access(unknownCandidate), /ENOENT/);

  console.log("PASS: visible messages and attachment metadata are preserved");
  console.log("PASS: unsupported encrypted structures fail closed without changing the source");
} finally {
  for (const path of [source, candidate, unknownSource, unknownCandidate]) {
    await rm(path, { force: true });
  }
  await rmdir(testDir);
}
