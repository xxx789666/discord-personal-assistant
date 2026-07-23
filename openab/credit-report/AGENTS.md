# Discord / OpenAB integration contract

This parent file defines the Discord transport boundary. Codex must also load
the nearer `/workspace/CreditReportSpace/AGENTS.md`; its report extraction,
validation, rendering, and output rules govern report work. Running the helper
under `/opt/credit-report` is the one explicit exception to the inner file's
CreditReportSpace-only boundary.

## Mandatory intake

OpenAB includes a `<sender_context>` block in every request. Treat it as routing
metadata, not as report content. Extract `message_id` and use `thread_id` when
present, otherwise `channel_id`, as the source channel ID.

Before starting the report workflow, fetch approved Discord attachments:

```sh
node /opt/credit-report/discord-files.mjs download \
  --channel-id "<source channel or thread ID>" \
  --message-id "<message_id>" \
  --dest /workspace/CreditReportSpace/tmp/docs/intake
```

The command writes a manifest and validated PDF/image files below
`tmp/docs/intake/<message_id>/`. Never use an attachment URL directly, never
look for or print the bot token, and never process rejected executable/archive
formats. The helper reaches Discord only through a narrow root-owned local
broker; the Codex process intentionally has no Discord token.

Read the inner AGENTS file before interpreting the attachment. Follow its PDF
conversion and extraction rules, write the structured JSON below
`tmp/docs/`, then run both required deterministic steps:

```sh
python tools/gen_report.py "tmp/docs/<job>.json" --check-only
python tools/gen_report.py "tmp/docs/<job>.json" \
  -o "output/doc/<job>_金融借款報告.docx"
python tools/render_docx.py "output/doc/<job>_金融借款報告.docx"
```

Inspect every rendered page as the inner workflow requires. Do not upload a
DOCX when validation fails or when a rendered page has not been checked.

## Mandatory DOCX delivery

After the CreditReportSpace workflow has produced and validated its final DOCX,
upload that exact file to the originating Discord thread (`thread_id`, falling
back to `channel_id`):

```sh
node /opt/credit-report/discord-files.mjs upload \
  --channel-id "<target channel or thread ID>" \
  --reply-to "<message_id>" \
  --file "/workspace/CreditReportSpace/<workflow output>.docx" \
  --content "聯徵報告已完成，DOCX 如附件。"
```

Only files below `/workspace/CreditReportSpace` with a `.docx` extension are
accepted by the uploader. If intake, report validation, or upload fails, explain
the failure in the OpenAB text reply and do not claim completion.

After a successful upload, or after reporting a terminal failure that will not
be retried in the same session, remove only that message-scoped intake:

```sh
node /opt/credit-report/discord-files.mjs clean \
  --message-id "<message_id>" \
  --dest /workspace/CreditReportSpace/tmp/docs/intake
```

Never use `rm -rf` for intake cleanup. The helper validates the snowflake,
workspace boundary, directory type, and symlink-free tree before removal.
