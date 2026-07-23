#!/usr/bin/env node
/**
 * Narrow Discord attachment bridge for the credit-report Codex agent.
 *
 * OpenAB supplies sender_context (channel/thread/message IDs), while this helper
 * uses the bot token to fetch the original message and persist only approved
 * report inputs. It also uploads the final DOCX back to the originating channel.
 */
import { createHash, randomUUID } from "node:crypto";
import { promises as fs } from "node:fs";
import net from "node:net";
import path from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";
import { inflateRawSync } from "node:zlib";

const DEFAULT_API_BASE = "https://discord.com/api/v10";
const DEFAULT_WORKSPACE = "/workspace/CreditReportSpace";
const DEFAULT_MAX_FILE_BYTES = 25 * 1024 * 1024;
const DEFAULT_MAX_TOTAL_BYTES = 100 * 1024 * 1024;
const DEFAULT_MAX_FILES = 20;

const ALLOWED_EXTENSIONS = new Set([
  ".pdf",
  ".png",
  ".jpg",
  ".jpeg",
  ".webp",
  ".gif",
  ".tif",
  ".tiff",
  ".heic",
  ".heif",
]);

const ALLOWED_MIME_TYPES = new Set([
  "application/pdf",
  "image/png",
  "image/jpeg",
  "image/webp",
  "image/gif",
  "image/tiff",
  "image/heic",
  "image/heif",
]);

function fail(message) {
  throw new Error(message);
}

function positiveIntFromEnv(name, fallback) {
  const raw = process.env[name];
  if (!raw) return fallback;
  const parsed = Number(raw);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) {
    fail(`${name} must be a positive integer`);
  }
  return parsed;
}

function requireToken() {
  const token = process.env.DISCORD_TOKEN_CREDIT_REPORT;
  if (!token || /\s/.test(token)) {
    fail("DISCORD_TOKEN_CREDIT_REPORT is missing or invalid");
  }
  return token;
}

function validateSnowflake(value, label) {
  if (!/^\d{17,20}$/.test(value ?? "")) {
    fail(`${label} must be a 17-20 digit Discord snowflake`);
  }
  return value;
}

function apiBase() {
  return (process.env.DISCORD_API_BASE || DEFAULT_API_BASE).replace(/\/+$/, "");
}

function isDiscordCdnUrl(rawUrl) {
  const parsed = new URL(rawUrl);
  if (parsed.protocol !== "https:") return false;
  return (
    parsed.hostname === "cdn.discordapp.com" ||
    parsed.hostname === "media.discordapp.net"
  );
}

function assertAttachmentUrl(rawUrl) {
  if (process.env.DISCORD_ALLOW_INSECURE_TEST_URLS === "1") {
    const parsed = new URL(rawUrl);
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
      fail("attachment URL must use HTTP(S)");
    }
    return;
  }
  if (!isDiscordCdnUrl(rawUrl)) {
    fail("attachment URL is not an approved Discord CDN URL");
  }
}

function sanitizeFilename(filename, index) {
  const base = path.basename(String(filename || `attachment-${index}`));
  const cleaned = base
    .normalize("NFKC")
    .replace(/[\u0000-\u001f\u007f]/g, "")
    .replace(/[<>:"/\\|?*]/g, "_")
    .replace(/^\.+/, "")
    .trim();
  const fallback = `attachment-${index}`;
  const selected = cleaned || fallback;
  const extension = path.extname(selected);
  const stem = path.basename(selected, extension).slice(0, 110);
  return `${stem || fallback}${extension.slice(0, 12)}`;
}

function isAllowedAttachment(attachment) {
  const mime = String(attachment.content_type || "")
    .split(";", 1)[0]
    .trim()
    .toLowerCase();
  const extension = path.extname(String(attachment.filename || "")).toLowerCase();
  return (
    ALLOWED_EXTENSIONS.has(extension) &&
    (!mime || ALLOWED_MIME_TYPES.has(mime))
  );
}

function hasExpectedMagic(bytes, extension, mime) {
  const ext = extension.toLowerCase();
  const type = mime.toLowerCase();
  if (ext === ".pdf" || type === "application/pdf") {
    return bytes.subarray(0, 5).toString("ascii") === "%PDF-";
  }
  if (ext === ".png" || type === "image/png") {
    return bytes.subarray(0, 8).equals(Buffer.from("89504e470d0a1a0a", "hex"));
  }
  if (ext === ".jpg" || ext === ".jpeg" || type === "image/jpeg") {
    return bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  }
  if (ext === ".gif" || type === "image/gif") {
    const header = bytes.subarray(0, 6).toString("ascii");
    return header === "GIF87a" || header === "GIF89a";
  }
  if (ext === ".webp" || type === "image/webp") {
    return (
      bytes.subarray(0, 4).toString("ascii") === "RIFF" &&
      bytes.subarray(8, 12).toString("ascii") === "WEBP"
    );
  }
  if (ext === ".tif" || ext === ".tiff" || type === "image/tiff") {
    const header = bytes.subarray(0, 4).toString("hex");
    return header === "49492a00" || header === "4d4d002a";
  }
  if (ext === ".heic" || ext === ".heif" || type === "image/heic" || type === "image/heif") {
    const brand = bytes.subarray(4, 16).toString("ascii");
    return brand.includes("ftyp");
  }
  return false;
}

async function discordFetch(url, options = {}) {
  const headers = new Headers(options.headers || {});
  headers.set("Authorization", `Bot ${requireToken()}`);
  const timeoutMs = positiveIntFromEnv("DISCORD_HTTP_TIMEOUT_MS", 60_000);
  const response = await fetch(url, {
    ...options,
    headers,
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!response.ok) {
    const body = (await response.text()).slice(0, 500);
    fail(`Discord API ${response.status}: ${body}`);
  }
  return response;
}

async function assertAllowedChannel(channelId) {
  const configuredChannel = validateSnowflake(
    process.env.CREDIT_REPORT_CHANNEL_ID,
    "CREDIT_REPORT_CHANNEL_ID",
  );
  if (channelId === configuredChannel) return;
  const response = await discordFetch(`${apiBase()}/channels/${channelId}`);
  const channel = await response.json();
  if (String(channel.parent_id || "") !== configuredChannel) {
    fail("channel is not #聯徵報告製作 or one of its threads");
  }
}

async function ensureDirectoryBelowWorkspace(directory) {
  const workspace = path.resolve(process.env.CREDIT_REPORT_WORKSPACE || DEFAULT_WORKSPACE);
  const workspaceReal = await fs.realpath(workspace);
  const resolved = path.resolve(directory);
  const relative = path.relative(workspace, resolved);
  if (!relative || relative.startsWith("..") || path.isAbsolute(relative)) {
    fail("intake destination must be below CREDIT_REPORT_WORKSPACE");
  }

  let current = workspaceReal;
  for (const segment of relative.split(path.sep)) {
    current = path.join(current, segment);
    try {
      const stat = await fs.lstat(current);
      if (stat.isSymbolicLink() || !stat.isDirectory()) {
        fail(`unsafe intake directory component: ${segment}`);
      }
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
      await fs.mkdir(current, { mode: 0o700 });
    }
  }
  return current;
}

async function atomicWrite(filePath, bytes) {
  const temporaryPath = `${filePath}.${randomUUID()}.tmp`;
  await fs.writeFile(temporaryPath, bytes, { mode: 0o600, flag: "wx" });
  await fs.rename(temporaryPath, filePath);
}

export async function downloadAttachments({ channelId, messageId, destination }) {
  validateSnowflake(channelId, "channel ID");
  validateSnowflake(messageId, "message ID");
  await assertAllowedChannel(channelId);
  const maxFileBytes = positiveIntFromEnv(
    "CREDIT_REPORT_MAX_ATTACHMENT_BYTES",
    DEFAULT_MAX_FILE_BYTES,
  );
  const maxTotalBytes = positiveIntFromEnv(
    "CREDIT_REPORT_MAX_TOTAL_BYTES",
    DEFAULT_MAX_TOTAL_BYTES,
  );
  const maxFiles = positiveIntFromEnv("CREDIT_REPORT_MAX_ATTACHMENTS", DEFAULT_MAX_FILES);

  const messageResponse = await discordFetch(
    `${apiBase()}/channels/${channelId}/messages/${messageId}`,
  );
  const message = await messageResponse.json();
  const attachments = Array.isArray(message.attachments) ? message.attachments : [];
  if (attachments.length === 0) {
    fail("message does not contain any attachments");
  }
  const approved = attachments.filter(isAllowedAttachment);
  if (approved.length !== attachments.length) {
    const rejected = attachments
      .filter((attachment) => !isAllowedAttachment(attachment))
      .map((attachment) => sanitizeFilename(attachment.filename, "rejected"))
      .join(", ");
    fail(`message contains unsupported attachment types: ${rejected}`);
  }
  if (approved.length > maxFiles) {
    fail(`message has ${approved.length} approved attachments; limit is ${maxFiles}`);
  }

  const destinationDirectory = await ensureDirectoryBelowWorkspace(destination);
  const messageDirectory = await ensureDirectoryBelowWorkspace(
    path.join(destinationDirectory, messageId),
  );
  const files = [];
  let totalBytes = 0;

  for (const [index, attachment] of approved.entries()) {
    const reportedSize = Number(attachment.size || 0);
    if (!Number.isSafeInteger(reportedSize) || reportedSize < 0) {
      fail(`attachment ${index + 1} has an invalid size`);
    }
    if (reportedSize > maxFileBytes) {
      fail(`attachment ${attachment.filename} exceeds the per-file limit`);
    }
    if (totalBytes + reportedSize > maxTotalBytes) {
      fail("attachments exceed the total size limit");
    }

    assertAttachmentUrl(attachment.url);
    const response = await fetch(attachment.url, {
      redirect: "follow",
      signal: AbortSignal.timeout(
        positiveIntFromEnv("DISCORD_HTTP_TIMEOUT_MS", 60_000),
      ),
    });
    if (!response.ok) {
      fail(`attachment download failed (${response.status})`);
    }
    assertAttachmentUrl(response.url || attachment.url);
    const bytes = Buffer.from(await response.arrayBuffer());
    if (bytes.length > maxFileBytes || totalBytes + bytes.length > maxTotalBytes) {
      fail(`attachment ${attachment.filename} exceeds configured limits`);
    }

    const storedName = `${String(index + 1).padStart(2, "0")}-${sanitizeFilename(
      attachment.filename,
      index + 1,
    )}`;
    const extension = path.extname(storedName);
    const mime = String(attachment.content_type || "")
      .split(";", 1)[0]
      .trim()
      .toLowerCase();
    if (!hasExpectedMagic(bytes, extension, mime)) {
      fail(`attachment ${attachment.filename} does not match its declared file type`);
    }

    const finalPath = path.join(messageDirectory, storedName);
    await atomicWrite(finalPath, bytes);
    totalBytes += bytes.length;
    files.push({
      attachment_id: String(attachment.id || ""),
      original_name: String(attachment.filename || ""),
      stored_name: storedName,
      content_type: mime || "application/octet-stream",
      size_bytes: bytes.length,
      sha256: createHash("sha256").update(bytes).digest("hex"),
      path: finalPath,
    });
  }

  const manifest = {
    schema: "credit-report.discord-intake.v1",
    channel_id: channelId,
    message_id: messageId,
    downloaded_at: new Date().toISOString(),
    files,
  };
  await atomicWrite(
    path.join(messageDirectory, "manifest.json"),
    Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`, "utf8"),
  );
  return manifest;
}

async function assertSymlinkFreeTree(directory) {
  const entries = await fs.readdir(directory, { withFileTypes: true });
  for (const entry of entries) {
    const entryPath = path.join(directory, entry.name);
    const stat = await fs.lstat(entryPath);
    if (stat.isSymbolicLink()) {
      fail("intake cleanup refuses a tree containing symlinks");
    }
    if (stat.isDirectory()) {
      await assertSymlinkFreeTree(entryPath);
    } else if (!stat.isFile()) {
      fail("intake cleanup refuses non-regular filesystem entries");
    }
  }
}

export async function cleanupIntake({ messageId, destination }) {
  validateSnowflake(messageId, "message ID");
  const destinationDirectory = await ensureDirectoryBelowWorkspace(
    destination ||
      process.env.CREDIT_REPORT_INTAKE_ROOT ||
      path.join(
        process.env.CREDIT_REPORT_WORKSPACE || DEFAULT_WORKSPACE,
        "tmp",
        "docs",
        "intake",
      ),
  );
  const messageDirectory = path.join(destinationDirectory, messageId);
  let stat;
  try {
    stat = await fs.lstat(messageDirectory);
  } catch (error) {
    if (error.code === "ENOENT") {
      return { cleaned: false, message_id: messageId };
    }
    throw error;
  }
  if (stat.isSymbolicLink() || !stat.isDirectory()) {
    fail("message intake path must be a regular directory, not a symlink");
  }

  const quarantine = path.join(
    destinationDirectory,
    `.cleanup-${messageId}-${randomUUID()}`,
  );
  await fs.rename(messageDirectory, quarantine);
  try {
    const movedStat = await fs.lstat(quarantine);
    if (movedStat.isSymbolicLink() || !movedStat.isDirectory()) {
      fail("quarantined intake path is not a regular directory");
    }
    await assertSymlinkFreeTree(quarantine);
    await fs.rm(quarantine, { recursive: true, force: false });
  } catch (error) {
    try {
      await fs.rename(quarantine, messageDirectory);
    } catch {
      // Preserve the original error; the quarantine name remains inside the
      // validated intake root for manual inspection.
    }
    throw error;
  }
  return { cleaned: true, message_id: messageId };
}

async function assertWorkspaceFile(filePath) {
  const workspace = path.resolve(process.env.CREDIT_REPORT_WORKSPACE || DEFAULT_WORKSPACE);
  const workspaceReal = await fs.realpath(workspace);
  const resolved = path.resolve(filePath);
  const stat = await fs.lstat(resolved);
  if (stat.isSymbolicLink() || !stat.isFile()) {
    fail("upload path must be a regular file, not a symlink");
  }
  const realFile = await fs.realpath(resolved);
  const relative = path.relative(workspaceReal, realFile);
  if (!relative || relative.startsWith("..") || path.isAbsolute(relative)) {
    fail("upload path must be a file below CREDIT_REPORT_WORKSPACE");
  }
  if (path.extname(realFile).toLowerCase() !== ".docx") {
    fail("only DOCX output may be uploaded by this helper");
  }
  return realFile;
}

function findZipEndOfCentralDirectory(bytes) {
  const lowerBound = Math.max(0, bytes.length - 65_557);
  for (let offset = bytes.length - 22; offset >= lowerBound; offset -= 1) {
    if (bytes.readUInt32LE(offset) !== 0x06054b50) continue;
    const commentLength = bytes.readUInt16LE(offset + 20);
    if (offset + 22 + commentLength === bytes.length) return offset;
  }
  fail("DOCX ZIP end-of-central-directory record is missing");
}

function readDocxZipEntries(bytes) {
  if (
    bytes.length < 22 ||
    !bytes.subarray(0, 4).equals(Buffer.from("504b0304", "hex"))
  ) {
    fail("DOCX output is not a ZIP package");
  }
  const endOffset = findZipEndOfCentralDirectory(bytes);
  const diskNumber = bytes.readUInt16LE(endOffset + 4);
  const centralDisk = bytes.readUInt16LE(endOffset + 6);
  const diskEntries = bytes.readUInt16LE(endOffset + 8);
  const totalEntries = bytes.readUInt16LE(endOffset + 10);
  const centralSize = bytes.readUInt32LE(endOffset + 12);
  const centralOffset = bytes.readUInt32LE(endOffset + 16);
  if (
    diskNumber !== 0 ||
    centralDisk !== 0 ||
    diskEntries !== totalEntries ||
    totalEntries === 0xffff ||
    centralSize === 0xffffffff ||
    centralOffset === 0xffffffff
  ) {
    fail("DOCX ZIP must be a non-Zip64 single-disk package");
  }
  const centralEnd = centralOffset + centralSize;
  if (centralEnd !== endOffset || centralEnd > bytes.length) {
    fail("DOCX ZIP central directory bounds are invalid");
  }

  const entries = new Map();
  let offset = centralOffset;
  for (let index = 0; index < totalEntries; index += 1) {
    if (offset + 46 > centralEnd || bytes.readUInt32LE(offset) !== 0x02014b50) {
      fail("DOCX ZIP central directory is malformed");
    }
    const flags = bytes.readUInt16LE(offset + 8);
    const compression = bytes.readUInt16LE(offset + 10);
    const compressedSize = bytes.readUInt32LE(offset + 20);
    const uncompressedSize = bytes.readUInt32LE(offset + 24);
    const nameLength = bytes.readUInt16LE(offset + 28);
    const extraLength = bytes.readUInt16LE(offset + 30);
    const commentLength = bytes.readUInt16LE(offset + 32);
    const localOffset = bytes.readUInt32LE(offset + 42);
    const nameStart = offset + 46;
    const nameEnd = nameStart + nameLength;
    const next = nameEnd + extraLength + commentLength;
    if (nameEnd > centralEnd || next > centralEnd) {
      fail("DOCX ZIP central directory is truncated");
    }
    const name = bytes.subarray(nameStart, nameEnd).toString("utf8");
    if (entries.has(name)) fail("DOCX ZIP contains duplicate entry names");
    if ((flags & 0x1) !== 0) fail("encrypted DOCX ZIP entries are not allowed");
    if (localOffset + 30 > centralOffset || bytes.readUInt32LE(localOffset) !== 0x04034b50) {
      fail("DOCX ZIP local file header is invalid");
    }
    const localNameLength = bytes.readUInt16LE(localOffset + 26);
    const localExtraLength = bytes.readUInt16LE(localOffset + 28);
    const dataStart = localOffset + 30 + localNameLength + localExtraLength;
    const dataEnd = dataStart + compressedSize;
    if (dataEnd > centralOffset) fail("DOCX ZIP entry data exceeds its bounds");

    entries.set(name, {
      compression,
      compressedSize,
      uncompressedSize,
      dataStart,
    });
    offset = next;
  }
  if (offset !== centralEnd) fail("DOCX ZIP central directory entry count is invalid");
  return entries;
}

function readZipPart(bytes, entry) {
  const maxPartBytes = 8 * 1024 * 1024;
  if (entry.uncompressedSize > maxPartBytes) {
    fail("DOCX required XML part exceeds the validation limit");
  }
  const compressed = bytes.subarray(
    entry.dataStart,
    entry.dataStart + entry.compressedSize,
  );
  let output;
  if (entry.compression === 0) {
    output = compressed;
  } else if (entry.compression === 8) {
    output = inflateRawSync(compressed, { maxOutputLength: maxPartBytes });
  } else {
    fail("DOCX required XML part uses an unsupported compression method");
  }
  if (output.length !== entry.uncompressedSize) {
    fail("DOCX required XML part has an invalid expanded size");
  }
  return output.toString("utf8");
}

export function hasExpectedDocxPackage(bytes) {
  try {
    const entries = readDocxZipEntries(bytes);
    const contentTypesEntry = entries.get("[Content_Types].xml");
    const relationshipsEntry = entries.get("_rels/.rels");
    const documentEntry = entries.get("word/document.xml");
    if (!contentTypesEntry || !relationshipsEntry || !documentEntry) return false;

    const contentTypes = readZipPart(bytes, contentTypesEntry);
    const relationships = readZipPart(bytes, relationshipsEntry);
    const document = readZipPart(bytes, documentEntry);
    return (
      contentTypes.includes('PartName="/word/document.xml"') &&
      contentTypes.includes(
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml",
      ) &&
      relationships.includes(
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument",
      ) &&
      /Target="\/?word\/document\.xml"/.test(relationships) &&
      document.includes(
        "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
      ) &&
      /<w:document(?:\s|>)/.test(document)
    );
  } catch {
    return false;
  }
}

export async function uploadDocx({
  channelId,
  filePath,
  content = "聯徵報告已完成，DOCX 如附件。",
  replyTo,
}) {
  validateSnowflake(channelId, "channel ID");
  if (replyTo) validateSnowflake(replyTo, "reply-to message ID");
  await assertAllowedChannel(channelId);
  const resolved = await assertWorkspaceFile(filePath);
  const bytes = await fs.readFile(resolved);
  const maxFileBytes = positiveIntFromEnv(
    "CREDIT_REPORT_MAX_OUTPUT_BYTES",
    DEFAULT_MAX_FILE_BYTES,
  );
  if (bytes.length > maxFileBytes) {
    fail(`DOCX output exceeds ${maxFileBytes} bytes`);
  }
  if (!hasExpectedDocxPackage(bytes)) {
    fail("DOCX output is not a valid WordprocessingML OOXML package");
  }

  const payload = { content: String(content).slice(0, 1900) };
  if (replyTo) {
    payload.message_reference = {
      message_id: replyTo,
      channel_id: channelId,
      fail_if_not_exists: false,
    };
  }
  const form = new FormData();
  form.append("payload_json", JSON.stringify(payload));
  form.append(
    "files[0]",
    new Blob([bytes], {
      type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    }),
    path.basename(resolved),
  );
  const response = await discordFetch(`${apiBase()}/channels/${channelId}/messages`, {
    method: "POST",
    body: form,
  });
  const result = await response.json();
  return {
    uploaded: true,
    channel_id: channelId,
    message_id: String(result.id || ""),
    filename: path.basename(resolved),
    size_bytes: bytes.length,
  };
}

export async function brokerRequest(command, options) {
  const socketPath = process.env.CREDIT_REPORT_BROKER_SOCKET;
  if (!socketPath) fail("CREDIT_REPORT_BROKER_SOCKET is not configured");
  const timeoutMs = positiveIntFromEnv("DISCORD_HTTP_TIMEOUT_MS", 60_000);
  return await new Promise((resolve, reject) => {
    const socket = net.createConnection(socketPath);
    let response = "";
    socket.setEncoding("utf8");
    socket.setTimeout(timeoutMs);
    socket.on("connect", () => {
      socket.end(`${JSON.stringify({ command, options })}\n`);
    });
    socket.on("data", (chunk) => {
      response += chunk;
      if (response.length > 2 * 1024 * 1024) {
        socket.destroy(new Error("Discord broker response is too large"));
      }
    });
    socket.on("timeout", () => {
      socket.destroy(new Error("Discord broker request timed out"));
    });
    socket.on("error", reject);
    socket.on("close", () => {
      if (!response) {
        reject(new Error("Discord broker closed without a response"));
        return;
      }
      try {
        const parsed = JSON.parse(response);
        if (!parsed.ok) {
          reject(new Error(parsed.error || "Discord broker request failed"));
          return;
        }
        resolve(parsed.result);
      } catch (error) {
        reject(new Error(`invalid Discord broker response: ${error.message}`));
      }
    });
  });
}

function parseArguments(argv) {
  const [command, ...rest] = argv;
  const options = {};
  for (let index = 0; index < rest.length; index += 1) {
    const key = rest[index];
    if (!key.startsWith("--")) fail(`unexpected argument: ${key}`);
    const value = rest[index + 1];
    if (value === undefined || value.startsWith("--")) fail(`missing value for ${key}`);
    options[key.slice(2)] = value;
    index += 1;
  }
  return { command, options };
}

function usage() {
  return `Usage:
  discord-files.mjs download --channel-id ID --message-id ID --dest DIR
  discord-files.mjs upload --channel-id ID --file PATH [--reply-to ID] [--content TEXT]
  discord-files.mjs clean --message-id ID [--dest DIR]

Production environment:
  CREDIT_REPORT_BROKER_SOCKET (the Codex child does not receive the bot token)

Optional environment:
  CREDIT_REPORT_WORKSPACE, CREDIT_REPORT_INTAKE_ROOT,
  CREDIT_REPORT_MAX_ATTACHMENT_BYTES,
  CREDIT_REPORT_MAX_TOTAL_BYTES, CREDIT_REPORT_MAX_ATTACHMENTS,
  CREDIT_REPORT_MAX_OUTPUT_BYTES, DISCORD_HTTP_TIMEOUT_MS`;
}

async function main() {
  const { command, options } = parseArguments(process.argv.slice(2));
  const useBroker = Boolean(process.env.CREDIT_REPORT_BROKER_SOCKET);
  if (command === "download") {
    const request = {
      channelId: options["channel-id"],
      messageId: options["message-id"],
      destination:
        options.dest ||
        process.env.CREDIT_REPORT_INTAKE_ROOT ||
        path.join(
          process.env.CREDIT_REPORT_WORKSPACE || DEFAULT_WORKSPACE,
          "tmp",
          "docs",
          "intake",
        ),
    };
    const result = useBroker
      ? await brokerRequest("download", request)
      : await downloadAttachments(request);
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    return;
  }
  if (command === "upload") {
    const request = {
      channelId: options["channel-id"],
      filePath: options.file,
      replyTo: options["reply-to"],
      content: options.content,
    };
    const result = useBroker
      ? await brokerRequest("upload", request)
      : await uploadDocx(request);
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    return;
  }
  if (command === "clean") {
    const request = {
      messageId: options["message-id"],
      destination: options.dest,
    };
    const result = useBroker
      ? await brokerRequest("clean", request)
      : await cleanupIntake(request);
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    return;
  }
  process.stdout.write(`${usage()}\n`);
  if (command && command !== "help" && command !== "--help") process.exitCode = 2;
}

const invokedPath = process.argv[1] ? pathToFileURL(path.resolve(process.argv[1])).href : "";
if (import.meta.url === invokedPath) {
  main().catch((error) => {
    process.stderr.write(`credit-report Discord helper: ${error.message}\n`);
    process.exitCode = 1;
  });
}
