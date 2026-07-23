import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { promises as fs } from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const helperPath = path.join(here, "discord-files.mjs");
const brokerPath = path.join(here, "discord-broker.mjs");
const channelId = "12345678901234567";
const messageId = "22345678901234567";
const siblingMessageId = "32345678901234567";

function minimalPdf() {
  const content = "BT /F1 12 Tf 72 720 Td (offline permission test) Tj ET";
  const objects = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
    `<< /Length ${Buffer.byteLength(content)} >>\nstream\n${content}\nendstream`,
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
  ];
  let body = "%PDF-1.4\n";
  const offsets = [];
  for (const [index, object] of objects.entries()) {
    offsets.push(Buffer.byteLength(body));
    body += `${index + 1} 0 obj\n${object}\nendobj\n`;
  }
  const xrefOffset = Buffer.byteLength(body);
  body += `xref\n0 ${objects.length + 1}\n`;
  body += "0000000000 65535 f \n";
  for (const offset of offsets) {
    body += `${String(offset).padStart(10, "0")} 00000 n \n`;
  }
  body += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n`;
  body += `startxref\n${xrefOffset}\n%%EOF\n`;
  return Buffer.from(body, "ascii");
}

async function waitForSocket(socketPath, child) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (child.exitCode !== null) {
      throw new Error(`broker exited before socket readiness (${child.exitCode})`);
    }
    try {
      const stat = await fs.lstat(socketPath);
      if (stat.isSocket()) return;
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error("broker socket did not become ready");
}

async function runAsAgent(command, args, environment) {
  const setprivArgs = [
    "--reuid=1000",
    "--regid=1000",
    "--init-groups",
    "--inh-caps=-all",
    "--ambient-caps=-all",
    "--bounding-set=-all",
    command,
    ...args,
  ];
  return await new Promise((resolve, reject) => {
    const child = spawn("setpriv", setprivArgs, {
      env: environment,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.once("error", reject);
    child.once("exit", (code, signal) => {
      if (code === 0) {
        resolve({ stdout, stderr });
      } else {
        reject(
          new Error(
            `agent command failed (code=${code}, signal=${signal}): ${stderr}`,
          ),
        );
      }
    });
  });
}

const canRun =
  process.platform === "linux" &&
  typeof process.getuid === "function" &&
  process.getuid() === 0;

test(
  "root broker grants only node-group traversal/read and performs message-scoped cleanup",
  { skip: !canRun, timeout: 30_000 },
  async (t) => {
    const workspace = await fs.mkdtemp(
      path.join(os.tmpdir(), "credit-report-broker-integration-"),
    );
    await fs.chown(workspace, 0, 1000);
    await fs.chmod(workspace, 0o750);
    const runtime = path.join(workspace, "runtime");
    await fs.mkdir(runtime, { mode: 0o750 });
    await fs.chown(runtime, 0, 1000);
    const socketPath = path.join(runtime, "discord.sock");
    const intake = path.join(workspace, "tmp", "docs", "intake");
    const pdf = minimalPdf();

    let apiBase = "";
    const server = http.createServer((request, response) => {
      if (
        request.url ===
        `/api/channels/${channelId}/messages/${messageId}`
      ) {
        assert.equal(request.headers.authorization, "Bot offline-test-token");
        response.setHeader("content-type", "application/json");
        response.end(
          JSON.stringify({
            attachments: [
              {
                id: "1",
                filename: "offline-test.pdf",
                content_type: "application/pdf",
                size: pdf.length,
                url: `${apiBase}/cdn/offline-test.pdf`,
              },
            ],
          }),
        );
        return;
      }
      if (request.url === "/cdn/offline-test.pdf") {
        response.setHeader("content-type", "application/pdf");
        response.end(pdf);
        return;
      }
      response.statusCode = 404;
      response.end();
    });
    await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
    apiBase = `http://127.0.0.1:${server.address().port}`;

    const environment = {
      ...process.env,
      DISCORD_TOKEN_CREDIT_REPORT: "offline-test-token",
      DISCORD_API_BASE: `${apiBase}/api`,
      DISCORD_ALLOW_INSECURE_TEST_URLS: "1",
      CREDIT_REPORT_CHANNEL_ID: channelId,
      CREDIT_REPORT_WORKSPACE: workspace,
      CREDIT_REPORT_INTAKE_ROOT: intake,
      CREDIT_REPORT_BROKER_SOCKET: socketPath,
    };
    const broker = spawn(process.execPath, [brokerPath], {
      env: environment,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let brokerStderr = "";
    broker.stderr.setEncoding("utf8");
    broker.stderr.on("data", (chunk) => {
      brokerStderr += chunk;
    });

    t.after(async () => {
      if (broker.exitCode === null) broker.kill("SIGTERM");
      await new Promise((resolve) => {
        if (broker.exitCode !== null) resolve();
        else broker.once("exit", resolve);
      });
      await new Promise((resolve) => server.close(resolve));
      await fs.rm(workspace, { recursive: true, force: true });
    });

    await waitForSocket(socketPath, broker);
    const downloadResult = await runAsAgent(
      process.execPath,
      [
        helperPath,
        "download",
        "--channel-id",
        channelId,
        "--message-id",
        messageId,
        "--dest",
        intake,
      ],
      environment,
    );
    assert.match(downloadResult.stdout, /credit-report\.discord-intake\.v1/);
    assert.equal(broker.exitCode, null, brokerStderr);

    const messageDirectory = path.join(intake, messageId);
    const pdfPath = path.join(messageDirectory, "01-offline-test.pdf");
    const manifestPath = path.join(messageDirectory, "manifest.json");
    for (const directory of [
      path.join(workspace, "tmp"),
      path.join(workspace, "tmp", "docs"),
      intake,
      messageDirectory,
    ]) {
      const stat = await fs.stat(directory);
      assert.equal(stat.gid, 1000);
      assert.equal(stat.mode & 0o007, 0, `${directory} grants access to other users`);
      assert.notEqual(stat.mode & 0o050, 0, `${directory} lacks node-group traversal`);
    }
    for (const file of [pdfPath, manifestPath]) {
      const stat = await fs.stat(file);
      assert.equal(stat.uid, 0);
      assert.equal(stat.gid, 1000);
      assert.equal(stat.mode & 0o777, 0o640);
    }

    const renderPrefix = path.join(os.tmpdir(), `credit-report-node-${process.pid}`);
    await runAsAgent(
      "sh",
      [
        "-c",
        `test -r "$1" && pdftoppm -f 1 -singlefile -png "$1" "$2" >/dev/null 2>&1 && test -s "$2.png"`,
        "sh",
        pdfPath,
        renderPrefix,
      ],
      environment,
    );
    await fs.rm(`${renderPrefix}.png`, { force: true });

    const siblingDirectory = path.join(intake, siblingMessageId);
    await fs.mkdir(siblingDirectory, { mode: 0o750 });
    await fs.chown(siblingDirectory, 0, 1000);
    await fs.writeFile(path.join(siblingDirectory, "keep.txt"), "keep", {
      mode: 0o640,
    });
    await fs.chown(path.join(siblingDirectory, "keep.txt"), 0, 1000);

    await runAsAgent(
      process.execPath,
      [
        helperPath,
        "clean",
        "--message-id",
        messageId,
        "--dest",
        intake,
      ],
      environment,
    );
    await assert.rejects(fs.access(messageDirectory));
    await fs.access(path.join(siblingDirectory, "keep.txt"));
  },
);
