#!/bin/sh
set -eu

# OpenAB needs the Discord token, but the model-facing process must not inherit
# it. PID 1 invokes this wrapper as root; setpriv drops all credentials before
# starting codex-acp as the unprivileged node account.
unset DISCORD_TOKEN_CREDIT_REPORT

if [ "$#" -eq 0 ]; then
  set -- codex-acp
fi

case "$(basename "$1"):${2:-}" in
  codex:login|codex:logout)
    # Authentication commands do not start a model session and do not accept
    # the model-facing developer override. They still benefit from token
    # removal and the same UID/capability drop below.
    ;;
  codex:*|codex-acp:*)
    # Codex discovers the inner CreditReportSpace/AGENTS.md from its working
    # directory, but it does not traverse above that working root. Inject the
    # transport contract as developer instructions so both layers are present
    # without writing an override file into the host-mounted B worktree.
    developer_override="$(
      python -c 'import json, pathlib; print("developer_instructions=" + json.dumps(pathlib.Path("/workspace/AGENTS.md").read_text(encoding="utf-8"), ensure_ascii=False))'
    )"
    set -- "$@" -c "$developer_override"
    ;;
esac

exec setpriv \
  --reuid=1000 \
  --regid=1000 \
  --init-groups \
  --inh-caps=-all \
  --ambient-caps=-all \
  --bounding-set=-all \
  "$@"
