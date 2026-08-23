#!/usr/bin/env node
import { promises as fs } from "node:fs";
import net from "node:net";
import path from "node:path";
import process from "node:process";

import {
  cleanupIntake,
  downloadAttachments,
  notifyUser,
  uploadDocx,
} from "./discord-files.mjs";

const socketPath =
  process.env.CREDIT_REPORT_BROKER_SOCKET ||
  "/run/credit-report/discord.sock";
const token = process.env.DISCORD_TOKEN_CREDIT_REPORT;

if (!token || /\s/.test(token)) {
  throw new Error("Discord broker requires DISCORD_TOKEN_CREDIT_REPORT");
}

async function grantAgentReadAccess(options, manifest) {
  const workspace = await fs.realpath(
    process.env.CREDIT_REPORT_WORKSPACE || "/workspace/CreditReportSpace",
  );
  const destination = path.resolve(
    options.destination ||
      process.env.CREDIT_REPORT_INTAKE_ROOT ||
      path.join(workspace, "tmp", "docs", "intake"),
  );
  const messageDirectory = path.join(destination, manifest.message_id);
  const relativeDestination = path.relative(workspace, destination);
  if (
    !relativeDestination ||
    relativeDestination.startsWith("..") ||
    path.isAbsolute(relativeDestination)
  ) {
    throw new Error("broker intake destination must be below the workspace");
  }

  // downloadAttachments may have created tmp/docs/intake while running as
  // root. Make every newly root-only component traversable by the node group;
  // otherwise the model cannot reach a correctly permissioned message leaf.
  let current = workspace;
  for (const segment of [
    ...relativeDestination.split(path.sep),
    manifest.message_id,
  ]) {
    current = path.join(current, segment);
    const stat = await fs.lstat(current);
    if (stat.isSymbolicLink() || !stat.isDirectory()) {
      throw new Error("broker intake path contains a non-directory component");
    }
    const agentCanTraverse =
      (stat.uid === 1000 && (stat.mode & 0o100) !== 0) ||
      (stat.gid === 1000 && (stat.mode & 0o010) !== 0) ||
      (stat.mode & 0o001) !== 0;
    if (!agentCanTraverse) {
      await fs.chown(current, 0, 1000);
      await fs.chmod(current, (stat.mode & 0o777) | 0o050);
    }
  }
  for (const file of [
    ...manifest.files.map((entry) => entry.path),
    path.join(messageDirectory, "manifest.json"),
  ]) {
    await fs.chown(file, 0, 1000);
    await fs.chmod(file, 0o640);
  }
}

async function dispatch(request) {
  if (!request || typeof request !== "object") {
    throw new Error("broker request must be an object");
  }
  if (request.command === "download") {
    const options = request.options || {};
    const manifest = await downloadAttachments(options);
    await grantAgentReadAccess(options, manifest);
    return manifest;
  }
  if (request.command === "upload") {
    return await uploadDocx(request.options || {});
  }
  if (request.command === "notify") {
    return await notifyUser(request.options || {});
  }
  if (request.command === "clean") {
    return await cleanupIntake(request.options || {});
  }
  throw new Error("unsupported Discord broker command");
}

await fs.mkdir(path.dirname(socketPath), { recursive: true, mode: 0o750 });
try {
  const existing = await fs.lstat(socketPath);
  if (!existing.isSocket()) {
    throw new Error("refusing to replace non-socket broker path");
  }
  await fs.unlink(socketPath);
} catch (error) {
  if (error.code !== "ENOENT") throw error;
}

// The client half-closes after sending one newline-delimited request. Keep the
// server's writable half open until the async Discord/filesystem operation has
// produced its response.
const server = net.createServer({ allowHalfOpen: true }, (socket) => {
  let input = "";
  socket.setEncoding("utf8");
  socket.on("data", (chunk) => {
    input += chunk;
    if (input.length > 128 * 1024) {
      socket.destroy(new Error("broker request is too large"));
    }
  });
  socket.on("end", async () => {
    try {
      const request = JSON.parse(input);
      const result = await dispatch(request);
      socket.end(JSON.stringify({ ok: true, result }));
    } catch (error) {
      socket.end(
        JSON.stringify({
          ok: false,
          error: String(error?.message || "Discord broker request failed").slice(0, 1000),
        }),
      );
    }
  });
});

await new Promise((resolve, reject) => {
  server.once("error", reject);
  server.listen(socketPath, resolve);
});
await fs.chmod(socketPath, 0o660);
await fs.chown(socketPath, 0, 1000);

function shutdown() {
  server.close(() => process.exit(0));
}
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
