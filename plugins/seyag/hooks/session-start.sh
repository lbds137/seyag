#!/bin/bash
# SessionStart hook (seyag plugin).
#
# The core rules (rules/core.md) are NOT injected here: Claude Code shows hook
# output over ~10 KB only as a 2 KB preview, and core.md is larger. They load as
# a user-level rule instead (~/.claude/rules/seyag-core.md -> rules/core.md;
# see the README). This hook only:
# - startup / clear: prints "seyag plugin <version>" (deck-sessions
#   greps it from session logs),
#   then warns in one line if that rules link is missing (component `rules`).
# - compact: adds the post-compaction recovery checklist (the failure class
#   where re-suggested settings, dropped promises and lost work-stack pointers
#   keep recurring; component `rules`). Adapted from Tzurot's session-start.sh.
# - resume: outputs nothing.
# - every source: deletes prompt-hook state files older than 7 days (below).
#
# Output is built with jq (never hand-escaped). Fail-open: no jq, or nothing to
# say, means a silent exit 0. A project's own .claude/hooks/session-start.sh
# takes precedence via run.sh.

set -uo pipefail

# Age out the per-session state files the prompt hooks leave in the shared state
# dir (queued-message-receipt, context-size-reminder; Tzurot's copies use the same
# names): nothing removes them when a session ends. A live session rewrites its
# receipt state on every prompt; a context-reminder stamp older than the cutoff is
# far past its cooldown anyway. Only this user's own, non-symlinked dir, only its
# top level, only regular files with these prefixes. Runs before the jq check,
# which it doesn't need.
STATE_DIR="${SYG_STATE_DIR:-/tmp/claude-$(id -u)}"
while [ "${STATE_DIR%/}" != "$STATE_DIR" ] && [ "$STATE_DIR" != / ]; do STATE_DIR=${STATE_DIR%/}; done
MAX_DAYS="${SYG_STATE_MAX_DAYS:-7}"
case "$MAX_DAYS" in '' | *[!0-9]*) MAX_DAYS=7 ;; esac
if [ -d "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ] && [ -O "$STATE_DIR" ]; then
  find "$STATE_DIR" -maxdepth 1 -type f \
    \( -name 'queued-receipt-state-*' -o -name 'context-reminder-*' \) \
    -mmin +$((MAX_DAYS * 1440)) -delete 2>/dev/null
fi

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
SOURCE=$(jq -r '.source // empty' <<<"$INPUT" 2>/dev/null || echo "")

# Components: the rules-link warning and the compact checklist belong to the
# `rules` component (SYG_PROFILE / SYG_DISABLE); the version line never does. A
# resolver that will not load leaves everything on.
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/components.sh
if [ -r "$HOOK_DIR/lib/components.sh" ] && source "$HOOK_DIR/lib/components.sh" 2>/dev/null \
  && declare -F syg_enabled >/dev/null; then
  :
else
  syg_enabled() { return 0; }
fi

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RULES_DIR="${SYG_USER_RULES_DIR:-$HOME/.claude/rules}"

TEXT=""
case "$SOURCE" in
  startup | clear)
    # Printed on every startup/clear as the first line; deck-sessions
    # greps this exact "seyag plugin " prefix from session JSONLs.
    VERSION=$(jq -r '.version // empty' "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null)
    TEXT="seyag plugin ${VERSION:-unknown}"

    # Compare contents, not paths: the plugin may run from a versioned cache copy
    # while the rules link points into the source repo.
    linked=""
    for f in "$RULES_DIR"/*.md; do
      [ -e "$f" ] && cmp -s "$f" "$PLUGIN_ROOT/rules/core.md" && linked=1 && break
    done
    [ -n "$linked" ] || ! syg_enabled rules || TEXT="${TEXT:+$TEXT
}The seyag plugin's core rules are not loaded (no file in $RULES_DIR matches its rules/core.md). Tell the owner; the fix is in the seyag README under Install, and it takes effect in the next session."
    ;;
  compact)
    syg_enabled rules || exit 0
    TEXT=$(cat <<'EOF'
POST-COMPACTION RECOVERY (structural checklist — act before new work):
0. Undelivered reports FIRST: if the compaction summary names a user-facing
   report, answer, or completion message that was never delivered, deliver it
   in the FIRST reply — before any tool calls.
1. Session settings: recover effort level / permission mode from pre-compaction
   state; do NOT re-suggest settings that were already active. The env block's
   MODEL line may be stale after an in-session /model switch — verify the
   driver model via the session JSONL's per-message `.message.model` field
   before asserting it, and never flag a mismatch from the env block alone.
2. Open promises and asks: grep the session JSONL under
   ~/.claude/projects/<project-slug>/ for "I'll" and unanswered user questions
   before re-deriving or guessing at lost state.
3. Work-stack pointer: resume the interrupted task at its resume point; a
   side-quest does not clear the main line.
4. Re-read the project's rules and your role file / handoff notes.
   Auto-loaded content never counts as Read for editing — Edit/Write requires
   a fresh Read of any file first.
EOF
)
    ;;
esac

[ -n "$TEXT" ] || exit 0

jq -n --arg ctx "$TEXT" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
