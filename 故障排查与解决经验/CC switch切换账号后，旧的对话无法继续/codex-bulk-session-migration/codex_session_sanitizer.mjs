import { createHash } from "node:crypto";
import { createReadStream, createWriteStream } from "node:fs";
import { open, readFile, rm, stat } from "node:fs/promises";
import { once } from "node:events";

export const FORMAT_VERSION = 1;

export function hasEncryptedContent(value) {
  if (Array.isArray(value)) return value.some(hasEncryptedContent);
  if (value !== null && typeof value === "object") {
    return Object.entries(value).some(
      ([key, nested]) => key === "encrypted_content" || hasEncryptedContent(nested),
    );
  }
  return false;
}

export function isLegacyEncryptedBlock(value) {
  return (
    value !== null &&
    typeof value === "object" &&
    value.type === "encrypted_content" &&
    Object.hasOwn(value, "encrypted_content")
  );
}

export function isEncryptedReasoningOrCompaction(value) {
  return (
    value !== null &&
    typeof value === "object" &&
    (value.type === "reasoning" || value.type === "compaction") &&
    hasEncryptedContent(value)
  );
}

export function isRemovableTopLevelRecord(record) {
  return (
    record?.type === "response_item" &&
    isEncryptedReasoningOrCompaction(record.payload)
  );
}

function classifyRemoval(value, counters) {
  if (isLegacyEncryptedBlock(value)) {
    counters.legacyEncryptedBlocks += 1;
    return "legacy-encrypted-block";
  }
  if (isEncryptedReasoningOrCompaction(value)) {
    if (value.type === "reasoning") counters.nestedReasoningItems += 1;
    if (value.type === "compaction") counters.compactionItems += 1;
    return value.type;
  }
  return null;
}

function sanitizeNested(value, counters) {
  if (Array.isArray(value)) {
    const output = [];
    for (const item of value) {
      if (classifyRemoval(item, counters)) continue;
      output.push(sanitizeNested(item, counters));
    }
    return output;
  }
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([key, nested]) => [key, sanitizeNested(nested, counters)]),
    );
  }
  return value;
}

export function sanitizeRecord(record, counters) {
  if (isRemovableTopLevelRecord(record)) {
    counters.topLevelReasoningRecords += 1;
    return null;
  }
  return sanitizeNested(record, counters);
}

function updateLeafDigest(value, hash, counter, skipRemovable) {
  if (skipRemovable && (isLegacyEncryptedBlock(value) || isEncryptedReasoningOrCompaction(value))) {
    return;
  }
  if (Array.isArray(value)) {
    hash.update("A[");
    for (const item of value) updateLeafDigest(item, hash, counter, skipRemovable);
    hash.update("]");
    return;
  }
  if (value !== null && typeof value === "object") {
    hash.update("O{");
    for (const [key, nested] of Object.entries(value)) {
      hash.update(`K${Buffer.byteLength(key)}:${key}`);
      updateLeafDigest(nested, hash, counter, skipRemovable);
    }
    hash.update("}");
    return;
  }
  const serialized = JSON.stringify(value);
  hash.update(`V${Buffer.byteLength(serialized)}:${serialized}`);
  counter.count += 1;
}

export function addPreservedRecordToDigest(record, hash, counter, original) {
  if (original && isRemovableTopLevelRecord(record)) return;
  updateLeafDigest(record, hash, counter, original);
}

export function countEncryptedFields(value) {
  if (Array.isArray(value)) {
    return value.reduce((total, item) => total + countEncryptedFields(item), 0);
  }
  if (value !== null && typeof value === "object") {
    return Object.entries(value).reduce(
      (total, [key, nested]) =>
        total + (key === "encrypted_content" ? 1 : countEncryptedFields(nested)),
      0,
    );
  }
  return 0;
}

export async function* readJsonl(path) {
  const stream = createReadStream(path);
  let pendingChunks = [];
  let pendingLength = 0;
  let lineNumber = 0;
  for await (const chunk of stream) {
    let start = 0;
    let newline;
    while ((newline = chunk.indexOf(0x0a, start)) !== -1) {
      const segment = chunk.subarray(start, newline);
      let line;
      if (pendingChunks.length === 0) {
        line = segment;
      } else {
        pendingChunks.push(segment);
        pendingLength += segment.length;
        line = Buffer.concat(pendingChunks, pendingLength);
        pendingChunks = [];
        pendingLength = 0;
      }
      if (line.at(-1) === 0x0d) line = line.subarray(0, -1);
      lineNumber += 1;
      if (line.length === 0) throw new Error(`Blank JSONL line at ${lineNumber}`);
      let record;
      try {
        record = JSON.parse(line.toString("utf8"));
      } catch (error) {
        throw new Error(`Invalid JSON at line ${lineNumber}: ${error.message}`);
      }
      yield { lineNumber, record };
      start = newline + 1;
    }
    if (start < chunk.length) {
      const remainder = chunk.subarray(start);
      pendingChunks.push(remainder);
      pendingLength += remainder.length;
    }
  }
  if (pendingLength > 0) {
    let pending = Buffer.concat(pendingChunks, pendingLength);
    if (pending.at(-1) === 0x0d) pending = pending.subarray(0, -1);
    lineNumber += 1;
    let record;
    try {
      record = JSON.parse(pending.toString("utf8"));
    } catch (error) {
      throw new Error(`Invalid JSON at line ${lineNumber}: ${error.message}`);
    }
    yield { lineNumber, record };
  }
}

export async function sha256File(path) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest("hex");
}

async function writeLine(stream, serialized) {
  if (!stream.write(`${serialized}\n`, "utf8")) await once(stream, "drain");
}

export async function transformFile(source, candidate) {
  const sourceInfo = await stat(source);
  const sourceHashBefore = await sha256File(source);
  const beforeDigest = createHash("sha256");
  const afterDigest = createHash("sha256");
  const beforeLeaves = { count: 0 };
  const afterLeaves = { count: 0 };
  const counters = {
    inputLines: 0,
    outputLines: 0,
    encryptedFieldsBefore: 0,
    encryptedFieldsAfter: 0,
    topLevelReasoningRecords: 0,
    nestedReasoningItems: 0,
    compactionItems: 0,
    legacyEncryptedBlocks: 0,
  };
  await rm(candidate, { force: true });
  const output = createWriteStream(candidate, { flags: "wx" });
  try {
    for await (const { lineNumber, record } of readJsonl(source)) {
      counters.inputLines = lineNumber;
      counters.encryptedFieldsBefore += countEncryptedFields(record);
      addPreservedRecordToDigest(record, beforeDigest, beforeLeaves, true);
      const sanitized = sanitizeRecord(record, counters);
      if (sanitized === null) continue;
      counters.encryptedFieldsAfter += countEncryptedFields(sanitized);
      addPreservedRecordToDigest(sanitized, afterDigest, afterLeaves, false);
      await writeLine(output, JSON.stringify(sanitized));
      counters.outputLines += 1;
    }
    output.end();
    await once(output, "finish");
  } catch (error) {
    output.destroy();
    await rm(candidate, { force: true });
    throw error;
  }

  const sourceHashAfter = await sha256File(source);
  if (sourceHashBefore !== sourceHashAfter || sourceInfo.size !== (await stat(source)).size) {
    await rm(candidate, { force: true });
    throw new Error("Source changed during transformation");
  }
  const expectedRemovedFields =
    counters.topLevelReasoningRecords +
    counters.nestedReasoningItems +
    counters.compactionItems +
    counters.legacyEncryptedBlocks;
  if (counters.encryptedFieldsBefore !== expectedRemovedFields) {
    await rm(candidate, { force: true });
    throw new Error(
      `Unclassified encrypted fields: before=${counters.encryptedFieldsBefore}, classified=${expectedRemovedFields}`,
    );
  }
  if (counters.encryptedFieldsAfter !== 0) {
    await rm(candidate, { force: true });
    throw new Error(`Candidate retains ${counters.encryptedFieldsAfter} encrypted fields`);
  }
  const beforeLeafHash = beforeDigest.digest("hex");
  const afterLeafHash = afterDigest.digest("hex");
  if (beforeLeafHash !== afterLeafHash || beforeLeaves.count !== afterLeaves.count) {
    await rm(candidate, { force: true });
    throw new Error("Preserved content changed during transformation");
  }

  return {
    sourceSizeBytes: sourceInfo.size,
    sourceSha256: sourceHashBefore,
    candidateSizeBytes: (await stat(candidate)).size,
    candidateSha256: await sha256File(candidate),
    preservedLeafCount: beforeLeaves.count,
    preservedLeafSha256: beforeLeafHash,
    ...counters,
  };
}

export async function validateCandidate(candidate, expected) {
  const digest = createHash("sha256");
  const leaves = { count: 0 };
  let lines = 0;
  let encryptedFields = 0;
  for await (const { lineNumber, record } of readJsonl(candidate)) {
    lines = lineNumber;
    encryptedFields += countEncryptedFields(record);
    addPreservedRecordToDigest(record, digest, leaves, false);
  }
  const result = {
    lines,
    encryptedFields,
    preservedLeafCount: leaves.count,
    preservedLeafSha256: digest.digest("hex"),
    sha256: await sha256File(candidate),
  };
  if (
    result.lines !== expected.outputLines ||
    result.encryptedFields !== 0 ||
    result.preservedLeafCount !== expected.preservedLeafCount ||
    result.preservedLeafSha256 !== expected.preservedLeafSha256 ||
    result.sha256 !== expected.candidateSha256
  ) {
    throw new Error(`Candidate validation mismatch: ${JSON.stringify(result)}`);
  }
  return result;
}
