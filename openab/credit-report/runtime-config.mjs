#!/usr/bin/env node
import { promises as fs } from "node:fs";
import path from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";

const TOKEN_PLACEHOLDER = '"${DISCORD_TOKEN_CREDIT_REPORT}"';
const CHANNEL_PLACEHOLDER = '"${CREDIT_REPORT_CHANNEL_ID}"';

function fail(message) {
  throw new Error(message);
}

function replaceAllCounted(text, needle, replacement, expectedCount, label) {
  const count = text.split(needle).length - 1;
  if (count !== expectedCount) {
    fail(`${label} placeholder count must be ${expectedCount}, found ${count}`);
  }
  return text.split(needle).join(replacement);
}

export function assertRenderedRouting(text, expectedChannelId) {
  const match = text.match(
    /allowed_channels\s*=\s*\[\s*"(\d{17,20})"\s*,?\s*\]/m,
  );
  if (!match) fail("rendered config must contain exactly one numeric allowed channel");
  if (match[1] !== expectedChannelId) {
    fail("rendered allowed channel does not match CREDIT_REPORT_CHANNEL_ID");
  }
  if (!/allow_dm\s*=\s*false\b/m.test(text)) {
    fail("credit-report config must keep Discord DMs disabled");
  }
}

export function renderConfigText(template, { token, channelId }) {
  if (!token || /\s/.test(token)) {
    fail("DISCORD_TOKEN_CREDIT_REPORT is missing or invalid");
  }
  if (!/^\d{17,20}$/.test(channelId || "")) {
    fail("CREDIT_REPORT_CHANNEL_ID must be a 17-20 digit Discord snowflake");
  }

  let rendered = replaceAllCounted(
    template,
    TOKEN_PLACEHOLDER,
    JSON.stringify(token),
    1,
    "Discord token",
  );
  rendered = replaceAllCounted(
    rendered,
    CHANNEL_PLACEHOLDER,
    JSON.stringify(channelId),
    2,
    "credit-report channel",
  );
  if (/\$\{[A-Z0-9_]+\}/.test(rendered)) {
    fail("rendered config contains an unresolved environment placeholder");
  }
  assertRenderedRouting(rendered, channelId);
  return rendered;
}

async function main() {
  const [templatePath, outputPath] = process.argv.slice(2);
  if (!templatePath || !outputPath) {
    fail("usage: runtime-config.mjs TEMPLATE OUTPUT");
  }
  const template = await fs.readFile(templatePath, "utf8");
  const rendered = renderConfigText(template, {
    token: process.env.DISCORD_TOKEN_CREDIT_REPORT,
    channelId: process.env.CREDIT_REPORT_CHANNEL_ID,
  });
  await fs.mkdir(path.dirname(outputPath), { recursive: true, mode: 0o750 });
  const temporary = `${outputPath}.${process.pid}.tmp`;
  await fs.writeFile(temporary, rendered, { encoding: "utf8", mode: 0o600, flag: "wx" });
  await fs.rename(temporary, outputPath);
  await fs.chmod(outputPath, 0o600);
}

const invokedPath = process.argv[1] ? pathToFileURL(path.resolve(process.argv[1])).href : "";
if (import.meta.url === invokedPath) {
  main().catch((error) => {
    process.stderr.write(`credit-report config: ${error.message}\n`);
    process.exitCode = 1;
  });
}
