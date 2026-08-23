import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { afterEach, test } from "node:test";
import { deflateRawSync } from "node:zlib";

import {
  cleanupIntake,
  downloadAttachments,
  notifyUser,
  uploadDocx,
} from "./discord-files.mjs";

const originalEnvironment = { ...process.env };
const servers = [];
const temporaryDirectories = [];

afterEach(async () => {
  process.env = { ...originalEnvironment };
  await Promise.all(
    servers.splice(0).map(
      (server) =>
        new Promise((resolve) => {
          server.close(resolve);
        }),
    ),
  );
  await Promise.all(
    temporaryDirectories.splice(0).map((directory) =>
      fs.rm(directory, { recursive: true, force: true }),
    ),
  );
});

async function temporaryDirectory() {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "credit-report-discord-"));
  temporaryDirectories.push(directory);
  return directory;
}

async function listen(handler) {
  const server = http.createServer(handler);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  servers.push(server);
  const address = server.address();
  return `http://127.0.0.1:${address.port}`;
}

function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function testZip(entries) {
  const localParts = [];
  const centralParts = [];
  let localOffset = 0;
  for (const [name, rawContent] of Object.entries(entries)) {
    const encodedName = Buffer.from(name, "utf8");
    const content = Buffer.from(rawContent, "utf8");
    const compressed = deflateRawSync(content);
    const checksum = crc32(content);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(8, 8);
    local.writeUInt32LE(checksum, 14);
    local.writeUInt32LE(compressed.length, 18);
    local.writeUInt32LE(content.length, 22);
    local.writeUInt16LE(encodedName.length, 26);
    localParts.push(local, encodedName, compressed);

    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(8, 10);
    central.writeUInt32LE(checksum, 16);
    central.writeUInt32LE(compressed.length, 20);
    central.writeUInt32LE(content.length, 24);
    central.writeUInt16LE(encodedName.length, 28);
    central.writeUInt32LE(localOffset, 42);
    centralParts.push(central, encodedName);
    localOffset += local.length + encodedName.length + compressed.length;
  }
  const centralBytes = Buffer.concat(centralParts);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(Object.keys(entries).length, 8);
  end.writeUInt16LE(Object.keys(entries).length, 10);
  end.writeUInt32LE(centralBytes.length, 12);
  end.writeUInt32LE(localOffset, 16);
  return Buffer.concat([...localParts, centralBytes, end]);
}

function minimalDocx() {
  return testZip({
    "[Content_Types].xml":
      '<?xml version="1.0"?><Types><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>',
    "_rels/.rels":
      '<?xml version="1.0"?><Relationships><Relationship Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>',
    "word/document.xml":
      '<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body/></w:document>',
  });
}

test("downloads an approved PDF into a message-scoped directory", async () => {
  const pdf = Buffer.from("%PDF-1.7\noffline-test\n");
  let baseUrl = "";
  baseUrl = await listen((request, response) => {
    if (request.url === "/api/channels/12345678901234567/messages/22345678901234567") {
      response.setHeader("content-type", "application/json");
      response.end(
        JSON.stringify({
          attachments: [
            {
              id: "1",
              filename: "../report.pdf",
              content_type: "application/pdf",
              size: pdf.length,
              url: `${baseUrl}/cdn/report.pdf`,
            },
          ],
        }),
      );
      return;
    }
    if (request.url === "/cdn/report.pdf") {
      response.setHeader("content-type", "application/pdf");
      response.end(pdf);
      return;
    }
    response.statusCode = 404;
    response.end();
  });

  process.env.DISCORD_TOKEN_CREDIT_REPORT = "offline-test-token";
  process.env.DISCORD_API_BASE = `${baseUrl}/api`;
  process.env.DISCORD_ALLOW_INSECURE_TEST_URLS = "1";
  const workspace = await temporaryDirectory();
  const destination = path.join(workspace, "tmp", "docs", "intake");
  process.env.CREDIT_REPORT_WORKSPACE = workspace;
  process.env.CREDIT_REPORT_CHANNEL_ID = "12345678901234567";
  const manifest = await downloadAttachments({
    channelId: "12345678901234567",
    messageId: "22345678901234567",
    destination,
  });

  assert.equal(manifest.files.length, 1);
  assert.equal(manifest.files[0].stored_name, "01-report.pdf");
  assert.deepEqual(await fs.readFile(manifest.files[0].path), pdf);
  assert.equal(
    JSON.parse(
      await fs.readFile(
        path.join(destination, "22345678901234567", "manifest.json"),
        "utf8",
      ),
    ).schema,
    "credit-report.discord-intake.v1",
  );
});

test("message-id latest resolves the newest human message with attachments", async () => {
  const pdf = Buffer.from("%PDF-1.7\nlatest-test\n");
  let baseUrl = "";
  baseUrl = await listen((request, response) => {
    if (request.url === "/api/channels/12345678901234567/messages?limit=20") {
      response.setHeader("content-type", "application/json");
      response.end(
        JSON.stringify([
          // 新到舊：最新是 bot 回傳的 DOCX（要跳過），再來才是真人附件訊息
          {
            id: "52345678901234567",
            author: { bot: true },
            attachments: [{ id: "9", filename: "report.docx" }],
          },
          { id: "42345678901234567", author: { bot: false }, attachments: [] },
          {
            id: "32345678901234567",
            author: { bot: false },
            attachments: [
              {
                id: "1",
                filename: "cred.pdf",
                content_type: "application/pdf",
                size: pdf.length,
                url: `${baseUrl}/cdn/cred.pdf`,
              },
            ],
          },
        ]),
      );
      return;
    }
    if (request.url === "/api/channels/12345678901234567/messages/32345678901234567") {
      response.setHeader("content-type", "application/json");
      response.end(
        JSON.stringify({
          attachments: [
            {
              id: "1",
              filename: "cred.pdf",
              content_type: "application/pdf",
              size: pdf.length,
              url: `${baseUrl}/cdn/cred.pdf`,
            },
          ],
        }),
      );
      return;
    }
    if (request.url === "/cdn/cred.pdf") {
      response.setHeader("content-type", "application/pdf");
      response.end(pdf);
      return;
    }
    response.statusCode = 404;
    response.end();
  });

  process.env.DISCORD_TOKEN_CREDIT_REPORT = "offline-test-token";
  process.env.DISCORD_API_BASE = `${baseUrl}/api`;
  process.env.DISCORD_ALLOW_INSECURE_TEST_URLS = "1";
  const workspace = await temporaryDirectory();
  const destination = path.join(workspace, "tmp", "docs", "intake");
  process.env.CREDIT_REPORT_WORKSPACE = workspace;
  process.env.CREDIT_REPORT_CHANNEL_ID = "12345678901234567";
  const manifest = await downloadAttachments({
    channelId: "12345678901234567",
    messageId: "latest",
    destination,
  });

  assert.equal(manifest.message_id, "32345678901234567");
  assert.equal(manifest.files.length, 1);
  assert.deepEqual(await fs.readFile(manifest.files[0].path), pdf);
});

test("uploads only a DOCX below the configured workspace", async () => {
  let observedAuthorization = "";
  let observedBody = "";
  const baseUrl = await listen((request, response) => {
    observedAuthorization = String(request.headers.authorization || "");
    const chunks = [];
    request.on("data", (chunk) => chunks.push(chunk));
    request.on("end", () => {
      observedBody = Buffer.concat(chunks).toString("utf8");
      response.setHeader("content-type", "application/json");
      response.end(JSON.stringify({ id: "32345678901234567" }));
    });
  });

  const workspace = await temporaryDirectory();
  const outputPath = path.join(workspace, "completed-report.docx");
  await fs.writeFile(outputPath, minimalDocx());
  process.env.DISCORD_TOKEN_CREDIT_REPORT = "offline-test-token";
  process.env.DISCORD_API_BASE = `${baseUrl}/api`;
  process.env.CREDIT_REPORT_WORKSPACE = workspace;
  process.env.CREDIT_REPORT_CHANNEL_ID = "12345678901234567";

  const result = await uploadDocx({
    channelId: "12345678901234567",
    filePath: outputPath,
    replyTo: "22345678901234567",
  });

  assert.equal(result.uploaded, true);
  assert.equal(observedAuthorization, "Bot offline-test-token");
  assert.match(observedBody, /completed-report\.docx/);
  assert.match(observedBody, /22345678901234567/);
});

test("sends a bounded user-facing notification without allowed mentions", async () => {
  let observedAuthorization = "";
  let observedPayload = null;
  const baseUrl = await listen((request, response) => {
    observedAuthorization = String(request.headers.authorization || "");
    const chunks = [];
    request.on("data", (chunk) => chunks.push(chunk));
    request.on("end", () => {
      observedPayload = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      response.setHeader("content-type", "application/json");
      response.end(JSON.stringify({ id: "32345678901234567" }));
    });
  });

  process.env.DISCORD_TOKEN_CREDIT_REPORT = "offline-test-token";
  process.env.DISCORD_API_BASE = `${baseUrl}/api`;
  process.env.CREDIT_REPORT_CHANNEL_ID = "12345678901234567";

  const result = await notifyUser({
    channelId: "12345678901234567",
    replyTo: "22345678901234567",
    content: "⏳ 已收到補件｜正在確認檔案內容；你目前不需操作。",
  });

  assert.equal(result.notified, true);
  assert.equal(observedAuthorization, "Bot offline-test-token");
  assert.equal(observedPayload.content, "⏳ 已收到補件｜正在確認檔案內容；你目前不需操作。");
  assert.deepEqual(observedPayload.allowed_mentions, {
    parse: [],
    replied_user: false,
  });
  assert.equal(observedPayload.message_reference.message_id, "22345678901234567");
});

test("rejects empty or oversized user-facing notifications", async () => {
  process.env.CREDIT_REPORT_CHANNEL_ID = "12345678901234567";

  await assert.rejects(
    notifyUser({ channelId: "12345678901234567", content: "   " }),
    /must not be empty/,
  );
  await assert.rejects(
    notifyUser({ channelId: "12345678901234567", content: "x".repeat(1901) }),
    /exceeds 1900 characters/,
  );
});

test("rejects a DOCX path outside the configured workspace", async () => {
  const workspace = await temporaryDirectory();
  const outsideDirectory = await temporaryDirectory();
  const outsideFile = path.join(outsideDirectory, "outside.docx");
  await fs.writeFile(outsideFile, minimalDocx());
  process.env.CREDIT_REPORT_WORKSPACE = workspace;
  process.env.CREDIT_REPORT_CHANNEL_ID = "12345678901234567";

  await assert.rejects(
    uploadDocx({
      channelId: "12345678901234567",
      filePath: outsideFile,
    }),
    /below CREDIT_REPORT_WORKSPACE/,
  );
});

test("rejects an attachment URL outside the Discord CDN allowlist", async () => {
  const baseUrl = await listen((request, response) => {
    if (request.url?.includes("/messages/")) {
      response.setHeader("content-type", "application/json");
      response.end(
        JSON.stringify({
          attachments: [
            {
              id: "1",
              filename: "report.pdf",
              content_type: "application/pdf",
              size: 10,
              url: "https://example.invalid/report.pdf",
            },
          ],
        }),
      );
      return;
    }
    response.statusCode = 404;
    response.end();
  });
  const workspace = await temporaryDirectory();
  process.env.DISCORD_TOKEN_CREDIT_REPORT = "offline-test-token";
  process.env.DISCORD_API_BASE = `${baseUrl}/api`;
  delete process.env.DISCORD_ALLOW_INSECURE_TEST_URLS;
  process.env.CREDIT_REPORT_WORKSPACE = workspace;
  process.env.CREDIT_REPORT_CHANNEL_ID = "12345678901234567";

  await assert.rejects(
    downloadAttachments({
      channelId: "12345678901234567",
      messageId: "22345678901234567",
      destination: path.join(workspace, "tmp", "docs", "intake"),
    }),
    /not an approved Discord CDN URL/,
  );
});

test("rejects a channel outside the configured channel and its threads", async () => {
  const baseUrl = await listen((request, response) => {
    if (request.url === "/api/channels/32345678901234567") {
      response.setHeader("content-type", "application/json");
      response.end(JSON.stringify({ parent_id: "42345678901234567" }));
      return;
    }
    response.statusCode = 404;
    response.end();
  });
  const workspace = await temporaryDirectory();
  process.env.DISCORD_TOKEN_CREDIT_REPORT = "offline-test-token";
  process.env.DISCORD_API_BASE = `${baseUrl}/api`;
  process.env.CREDIT_REPORT_WORKSPACE = workspace;
  process.env.CREDIT_REPORT_CHANNEL_ID = "12345678901234567";

  await assert.rejects(
    downloadAttachments({
      channelId: "32345678901234567",
      messageId: "22345678901234567",
      destination: path.join(workspace, "tmp", "docs", "intake"),
    }),
    /not #聯徵報告製作 or one of its threads/,
  );
});

test("rejects unsupported attachment types before download", async () => {
  const baseUrl = await listen((request, response) => {
    if (request.url?.includes("/messages/")) {
      response.setHeader("content-type", "application/json");
      response.end(
        JSON.stringify({
          attachments: [
            {
              id: "1",
              filename: "payload.zip",
              content_type: "application/zip",
              size: 4,
              url: `${baseUrl}/cdn/payload.zip`,
            },
          ],
        }),
      );
      return;
    }
    response.statusCode = 404;
    response.end();
  });
  const workspace = await temporaryDirectory();
  process.env.DISCORD_TOKEN_CREDIT_REPORT = "offline-test-token";
  process.env.DISCORD_API_BASE = `${baseUrl}/api`;
  process.env.DISCORD_ALLOW_INSECURE_TEST_URLS = "1";
  process.env.CREDIT_REPORT_WORKSPACE = workspace;
  process.env.CREDIT_REPORT_CHANNEL_ID = "12345678901234567";

  await assert.rejects(
    downloadAttachments({
      channelId: "12345678901234567",
      messageId: "22345678901234567",
      destination: path.join(workspace, "tmp", "docs", "intake"),
    }),
    /unsupported attachment types/,
  );
});

test("rejects an attachment over the configured size limit", async () => {
  const baseUrl = await listen((request, response) => {
    if (request.url?.includes("/messages/")) {
      response.setHeader("content-type", "application/json");
      response.end(
        JSON.stringify({
          attachments: [
            {
              id: "1",
              filename: "report.pdf",
              content_type: "application/pdf",
              size: 9,
              url: `${baseUrl}/cdn/report.pdf`,
            },
          ],
        }),
      );
      return;
    }
    response.statusCode = 404;
    response.end();
  });
  const workspace = await temporaryDirectory();
  process.env.DISCORD_TOKEN_CREDIT_REPORT = "offline-test-token";
  process.env.DISCORD_API_BASE = `${baseUrl}/api`;
  process.env.DISCORD_ALLOW_INSECURE_TEST_URLS = "1";
  process.env.CREDIT_REPORT_WORKSPACE = workspace;
  process.env.CREDIT_REPORT_CHANNEL_ID = "12345678901234567";
  process.env.CREDIT_REPORT_MAX_ATTACHMENT_BYTES = "8";

  await assert.rejects(
    downloadAttachments({
      channelId: "12345678901234567",
      messageId: "22345678901234567",
      destination: path.join(workspace, "tmp", "docs", "intake"),
    }),
    /exceeds the per-file limit/,
  );
});

test("rejects intake outside the workspace and through a symlink", async () => {
  const pdf = Buffer.from("%PDF-1.7\n");
  const baseUrl = await listen((request, response) => {
    if (request.url?.includes("/messages/")) {
      response.setHeader("content-type", "application/json");
      response.end(
        JSON.stringify({
          attachments: [
            {
              id: "1",
              filename: "report.pdf",
              content_type: "application/pdf",
              size: pdf.length,
              url: `${baseUrl}/cdn/report.pdf`,
            },
          ],
        }),
      );
      return;
    }
    response.statusCode = 404;
    response.end();
  });
  const workspace = await temporaryDirectory();
  const outside = await temporaryDirectory();
  process.env.DISCORD_TOKEN_CREDIT_REPORT = "offline-test-token";
  process.env.DISCORD_API_BASE = `${baseUrl}/api`;
  process.env.DISCORD_ALLOW_INSECURE_TEST_URLS = "1";
  process.env.CREDIT_REPORT_WORKSPACE = workspace;
  process.env.CREDIT_REPORT_CHANNEL_ID = "12345678901234567";

  await assert.rejects(
    downloadAttachments({
      channelId: "12345678901234567",
      messageId: "22345678901234567",
      destination: outside,
    }),
    /must be below CREDIT_REPORT_WORKSPACE/,
  );

  const link = path.join(workspace, "tmp-link");
  await fs.symlink(outside, link, process.platform === "win32" ? "junction" : "dir");
  await assert.rejects(
    downloadAttachments({
      channelId: "12345678901234567",
      messageId: "22345678901234567",
      destination: path.join(link, "intake"),
    }),
    /unsafe intake directory component/,
  );
});

test("rejects a generic ZIP renamed as DOCX", async () => {
  const workspace = await temporaryDirectory();
  const fakeDocx = path.join(workspace, "not-word.docx");
  await fs.writeFile(fakeDocx, testZip({ "payload.txt": "not OOXML" }));
  process.env.CREDIT_REPORT_WORKSPACE = workspace;
  process.env.CREDIT_REPORT_CHANNEL_ID = "12345678901234567";

  await assert.rejects(
    uploadDocx({
      channelId: "12345678901234567",
      filePath: fakeDocx,
    }),
    /not a valid WordprocessingML OOXML package/,
  );
});

test("rejects a ZIP with OOXML filenames but invalid XML parts", async () => {
  const workspace = await temporaryDirectory();
  const fakeDocx = path.join(workspace, "names-only.docx");
  await fs.writeFile(
    fakeDocx,
    testZip({
      "[Content_Types].xml": "",
      "_rels/.rels": "",
      "word/document.xml": "",
    }),
  );
  process.env.CREDIT_REPORT_WORKSPACE = workspace;
  process.env.CREDIT_REPORT_CHANNEL_ID = "12345678901234567";

  await assert.rejects(
    uploadDocx({
      channelId: "12345678901234567",
      filePath: fakeDocx,
    }),
    /not a valid WordprocessingML OOXML package/,
  );
});

test("cleans only the validated message directory and rejects symlinks", async () => {
  const workspace = await temporaryDirectory();
  const outside = await temporaryDirectory();
  const intake = path.join(workspace, "tmp", "docs", "intake");
  const messageId = "22345678901234567";
  const messageDirectory = path.join(intake, messageId);
  await fs.mkdir(messageDirectory, { recursive: true });
  await fs.writeFile(path.join(messageDirectory, "manifest.json"), "{}");
  process.env.CREDIT_REPORT_WORKSPACE = workspace;

  const cleaned = await cleanupIntake({ messageId, destination: intake });
  assert.equal(cleaned.cleaned, true);
  await assert.rejects(fs.access(messageDirectory));

  await fs.symlink(
    outside,
    messageDirectory,
    process.platform === "win32" ? "junction" : "dir",
  );
  await assert.rejects(
    cleanupIntake({ messageId, destination: intake }),
    /regular directory, not a symlink/,
  );
});
