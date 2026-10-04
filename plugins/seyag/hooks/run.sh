#!/bin/bash
# Seyag hook dispatcher: run.sh <hook-name>
#
# If the project ships its own copy (.claude/hooks/<name>.sh under
# CLAUDE_PROJECT_DIR, else the cwd), exit 0 silently: the project's copy wins
# and is wired by the project's own settings, so running both would double-fire.
# Otherwise exec the plugin's copy with stdin passed through; its exit code,
# stdout and stderr reach Claude Code unchanged.

NAME="${1:-}"
case "$NAME" in
  '' | */* | .*) echo "run.sh: invalid hook name '$NAME'" >&2; exit 0 ;;
esac

if [ -f "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/hooks/$NAME.sh" ]; then
  exit 0
fi

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$DIR/$NAME.sh"
[ -f "$HOOK" ] || { echo "run.sh: no such seyag hook '$NAME'" >&2; exit 0; }

# Turn-shape hooks (Stop, UserPromptSubmit) are about talking to a person. Headless
# runs have nobody attending, and a Stop hook there can replace the script's real
# output, so skip them: CLAUDE_CODE_ENTRYPOINT starting `sdk-` (`claude -p` reports
# sdk-cli, SDK scripts sdk-*). CLAUDE_CODE_SESSION_ATTENDED is not consulted: a
# background session a person drives live carries 0 too. The shell guards still run.
if [[ "${CLAUDE_CODE_ENTRYPOINT:-}" == sdk-* ]]; then
  case "$NAME" in
    blocking-question-channel-check | turn-end-shape-gate | queued-message-receipt | \
      bare-token-binding-reminder | context-size-reminder | promise-ledger-check) exit 0 ;;
  esac
fi

# A hook with a syntax error would exit 2, and for PreToolUse that blocks the tool:
# one half-saved edit would stop every Bash call in every session. Fail open instead.
if ! bash -n "$HOOK" 2>/dev/null; then
  echo "run.sh: seyag hook '$NAME' has a syntax error; skipped" >&2
  exit 0
fi

export PYTHONDONTWRITEBYTECODE=1
exec bash "$HOOK"
