import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import { test } from "node:test";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { assertRenderedRouting, renderConfigText } from "./runtime-config.mjs";

const channelId = "12345678901234567";
const here = path.dirname(fileURLToPath(import.meta.url));
const template = `
[discord]
bot_token = "\${DISCORD_TOKEN_CREDIT_REPORT}"
allowed_channels = [
  "\${CREDIT_REPORT_CHANNEL_ID}",
]
allow_dm = false
[agent]
env = { CREDIT_REPORT_CHANNEL_ID = "\${CREDIT_REPORT_CHANNEL_ID}" }
`;

test("renders the configured channel into the effective allowlist", () => {
  const rendered = renderConfigText(template, {
    token: "offline-test-token",
    channelId,
  });
  assert.match(rendered, /allowed_channels\s*=\s*\[\s*"12345678901234567"/m);
  assert.doesNotMatch(rendered, /\$\{/);
  assertRenderedRouting(rendered, channelId);
});

test("rejects missing, malformed, or silently mismatched channel routing", () => {
  assert.throws(
    () => renderConfigText(template, { token: "offline-test-token", channelId: "" }),
    /17-20 digit/,
  );
  assert.throws(
    () =>
      renderConfigText(template.replace(/\$\{CREDIT_REPORT_CHANNEL_ID\}/, "99999999999999999"), {
        token: "offline-test-token",
        channelId,
      }),
    /placeholder count/,
  );
  assert.throws(
    () =>
      assertRenderedRouting(
        template
          .replaceAll("\${DISCORD_TOKEN_CREDIT_REPORT}", "offline-test-token")
          .replaceAll("\${CREDIT_REPORT_CHANNEL_ID}", "99999999999999999"),
        channelId,
      ),
    /does not match/,
  );
});

test("rejects missing token without including it in an error", () => {
  assert.throws(
    () => renderConfigText(template, { token: "", channelId }),
    /missing or invalid/,
  );
});

test("renders the production template and keeps the agent token-free", async () => {
  const productionTemplate = await fs.readFile(
    path.join(here, "..", "config-credit-report.toml"),
    "utf8",
  );
  const rendered = renderConfigText(productionTemplate, {
    token: "offline-test-token",
    channelId,
  });
  assertRenderedRouting(rendered, channelId);
  const agentBlock = productionTemplate.match(
    /\[agent\]([\s\S]*?)(?=\n\[[^\]]+\]|\s*$)/,
  )?.[1];
  assert.ok(agentBlock, "production config must contain an agent section");
  assert.doesNotMatch(agentBlock, /DISCORD_TOKEN_CREDIT_REPORT/);
  assert.match(agentBlock, /agent-entrypoint\.sh/);
  assert.match(agentBlock, /CREDIT_REPORT_BROKER_SOCKET/);
});
