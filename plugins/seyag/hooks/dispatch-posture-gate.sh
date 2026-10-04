#!/bin/bash
# PreToolUse hook (matcher: Edit|Write|MultiEdit) — OPT-IN. Nudges the main
# loop toward dispatching implementation (the seyag `delegation` skill)
# instead of editing project source inline. Every main-loop tool call re-bills
# the full context, so an inline source edit is the shape worth catching once
# per commit-anchored editing burst (see Ack semantics below).
#
# Opt-in: the hook is a NO-OP (exit 0, no output) unless the project sets
#
#   SYG_DISPATCH_SRC_RE='^(src|lib)/.*\.(ts|js)$'
#
# in its own `.claude/settings.json` `env` block. The value is a POSIX
# extended regex (bash `[[ =~ ]]`) matched against the edited path RELATIVE
# to `$CLAUDE_PROJECT_DIR` (no leading slash, e.g. `src/a.ts`). It is NOT
# anchored for you: write `^`/`$` yourself. A path that does not resolve under
# the project dir never matches. Unset or empty → exit 0 before anything else.
#
# ABSOLUTE MODE: when the regex itself starts with `/` or `^/`, it is matched
# against the edited file's ABSOLUTE resolved path instead, and a path outside
# the project dir is no longer exempt — this is how a project scopes the gate
# to a path that lives outside its own tree.
# Known limitation: the ack key is built from the PROJECT dir's branch and
# HEAD, so in absolute mode the once-per-commit ack re-arms on the project's
# commits, not the target tree's. (The ack key itself stays unchanged in this
# unit.)
#
# Exemptions (checked after the scope match):
#   - Subagent edits. Claude Code's hook input carries `agent_id` when the hook
#     fires inside a subagent (Agent tool): in the 2.1.282 bundle the common
#     hook-input field list is ["hook_event_name","session_id","transcript_path",
#     "cwd","scratchpad_dir","prompt_id","permission_mode","agent_id",
#     "agent_type","served_call","caller_session_id","effort"], `agent_type` is
#     described as "Present when the hook fires from within a subagent
#     (alongside agent_id), or on the main thread of a session started with
#     --agent (without agent_id)", and Claude Code's own built-in hooks skip on
#     `agent_id !== undefined`. So a non-empty `.agent_id` exempts the call
#     (`agent_type` alone would also exempt an `--agent` main thread, which is
#     the main loop). Evidence is bundle-read, not runtime-captured: no hook on
#     this machine logs its input. A worker that reaches this gate without the
#     field still has the worktree exemption below.
#   - Anything under a `.claude/worktrees/` path (a worker's own scratch tree),
#     including when that worktree IS `$CLAUDE_PROJECT_DIR`.
#
# Size measurement (ported from Tzurot's copy unchanged): the inline exemption
# in the delegation skill is "≤ ~5 lines of mechanical edit", and this gate
# MEASURES that five from the tool input itself — for an Edit,
# max(lines(old_string), lines(new_string)); for a Write, lines(content); for a
# MultiEdit, the sum of those maxima over `edits[]`. Over five touched lines is
# a HARD block: no ack is recorded and retrying does not pass. Five or fewer
# falls through to the ack path below. The metric is LINE COUNT, not
# characters, so one very long line passes under it (accepted: a character
# metric would misclassify ordinary edits). A Write is sized on the WHOLE
# `content` on purpose: a Write of an existing file's full body is meant to
# hard-block.
#
# Ack semantics: the FIRST blocked edit at a given (UTC date, project dir,
# branch, HEAD) records an ack key and blocks (exit 2); retrying the SAME call
# finds the key recorded and passes (exit 0). HEAD is part of the key so the
# reminder RE-ARMS after every commit: a review-round fix is by construction a
# post-commit edit. The ack is branch-wide, not caller-scoped: any same-tree
# process shares one ack per key (a minor fail-open loss). The ack file is
# `/tmp/claude-<uid>/dispatch-posture-ack` (override: SYG_DISPATCH_ACK_FILE);
# the SessionStart prune may delete it after SYG_STATE_MAX_DAYS, which only
# re-arms a day-keyed ack.
#
# Fail-open on any internal error (missing jq, unwritable ack file, etc.) —
# a broken nudge must never block real work. run.sh also skips this hook when
# the project ships its own `.claude/hooks/dispatch-posture-gate.sh`.
#
# Fixture check: run hooks/dispatch-posture-gate.probe.sh after ANY edit to
# this hook.

set -uo pipefail

SRC_RE="${SYG_DISPATCH_SRC_RE:-}"
[ -z "$SRC_RE" ] && exit 0

# ABSOLUTE MODE: a regex anchored (or not) at a leading slash matches the
# resolved absolute path instead of the project-relative one, and a path
# outside the project dir is in scope for it (see header, "ABSOLUTE MODE").
case "$SRC_RE" in
  ^/* | /*) ABS_MODE=1 ;;
  *) ABS_MODE=0 ;;
esac

INPUT=$(cat)

TOOL_NAME=$(jq -r '.tool_name // empty' <<<"$INPUT" 2>/dev/null || echo "")
case "$TOOL_NAME" in
  Edit | Write | MultiEdit) ;;
  *) exit 0 ;;
esac

FILE_PATH=$(jq -r '.tool_input.file_path // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ -z "$FILE_PATH" ] && exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"

# Canonicalize both sides (lexically, no existence required) so a trailing
# slash, a `docs/../services/x.ts` scope escape, a forged
# `.claude/worktrees/../../src/x.ts` exemption, or a symlinked project dir
# against a realpath file_path all compare as the same real paths. Fail open
# if realpath is missing.
PROJECT_DIR=$(realpath -m -- "${PROJECT_DIR%/}" 2>/dev/null) || exit 0

case "$FILE_PATH" in
  /*) RESOLVED="$FILE_PATH" ;;
  *) RESOLVED="$PROJECT_DIR/$FILE_PATH" ;;
esac
RESOLVED=$(realpath -m -- "$RESOLVED" 2>/dev/null) || exit 0

# Must resolve under the project root at all — skipped in absolute mode,
# where a path outside the project dir is exactly what the regex targets.
if [ "$ABS_MODE" -eq 0 ]; then
  case "$RESOLVED" in
    "$PROJECT_DIR"/*) ;;
    *) exit 0 ;;
  esac
fi

REL="${RESOLVED#"$PROJECT_DIR"/}"

# Absolute mode matches the resolved absolute path; relative mode matches the
# path relative to the project dir (unchanged behaviour).
if [ "$ABS_MODE" -eq 1 ]; then
  MATCH_TARGET="$RESOLVED"
else
  MATCH_TARGET="$REL"
fi

# Only paths the project opted in are in scope. An invalid regex makes `=~`
# return 2, which falls through to exit 0 (fail open).
if [[ ! "$MATCH_TARGET" =~ $SRC_RE ]]; then
  exit 0
fi

# A subagent's edit is exempt — the gate targets the main loop editing inline,
# not a dispatched worker doing its job (see the header for the field).
AGENT_ID=$(jq -r '.agent_id // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ -n "$AGENT_ID" ] && exit 0

# A worker's own worktree scratch tree is exempt for the same reason.
case "$RESOLVED" in
  */.claude/worktrees/*) exit 0 ;;
esac

# How many lines this single call touches. The empty/absent string counts 0 (a
# pure insertion has no old text, a pure deletion no new text); otherwise the
# count is `\n` count + 1, ignoring ONE trailing newline — a five-line block
# ending in a newline is five lines, not six. Fail-open: an unparseable input
# yields 0 and falls through to the ack path. Pinned by the trailing-newline
# fixtures in dispatch-posture-gate.probe.sh.
TOUCHED=$(jq -r '
  def nlines: (. // "") | if . == "" then 0 else (1 + (sub("\n$"; "") | [match("\n"; "g")] | length)) end;
  if .tool_name == "Edit" then
    [(.tool_input.old_string | nlines), (.tool_input.new_string | nlines)] | max
  elif .tool_name == "Write" then
    .tool_input.content | nlines
  elif .tool_name == "MultiEdit" then
    ([.tool_input.edits[]? | ([(.old_string | nlines), (.new_string | nlines)] | max)] | add) // 0
  else 0 end
' <<<"$INPUT" 2>/dev/null || echo 0)
case "$TOUCHED" in
  '' | *[!0-9]*) TOUCHED=0 ;;
esac

if [ "$TOUCHED" -gt 5 ]; then
  cat >&2 <<EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
DISPATCH POSTURE — inline source edit of $TOUCHED lines (limit 5)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
The inline exemption is a ≤5-line mechanical edit in a file already in
context (the seyag \`delegation\` skill, § When to dispatch). This call
touches $TOUCHED lines, so the exemption does not apply — and comment-only
bulk is not an exception, it is the same context re-bill.

Retrying will NOT pass: no ack is recorded for an over-size edit.

Do one of:
  - dispatch the unit per the \`delegation\` skill (driver specs, worker
    implements), or hand a review round's batch to the unit's worker; or
  - split this into edits that each stand alone at five lines or fewer.

If you are a dispatched worker editing the main tree, stop and report:
your dispatch was meant to be worktree-isolated.

This project opted in via SYG_DISPATCH_SRC_RE=$SRC_RE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
  exit 2
fi

STATE_DIR="/tmp/claude-$(id -u)"
ACK_FILE="${SYG_DISPATCH_ACK_FILE:-$STATE_DIR/dispatch-posture-ack}"
if [ -z "${SYG_DISPATCH_ACK_FILE:-}" ]; then
  # shellcheck disable=SC2174 # only the leaf holds state; parents take the default mode
  mkdir -p -m 700 "$STATE_DIR" 2>/dev/null || exit 0
  [ ! -L "$STATE_DIR" ] || exit 0
  [ -O "$STATE_DIR" ] || exit 0
fi
BRANCH=$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || echo detached)
HEAD_SHA=$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo nohead)
ACK_KEY="$(date -u +%F):$PROJECT_DIR:$BRANCH:$HEAD_SHA"

if [ -f "$ACK_FILE" ] && grep -qxF "$ACK_KEY" "$ACK_FILE" 2>/dev/null; then
  exit 0
fi

if ! printf '%s\n' "$ACK_KEY" >>"$ACK_FILE" 2>/dev/null; then
  echo "dispatch-posture-gate: could not write ack file $ACK_FILE — failing open" >&2
  exit 0
fi
chmod 600 "$ACK_FILE" 2>/dev/null || true

cat >&2 <<'EOF'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
DISPATCH POSTURE — first main-loop source edit since the last commit
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
The main loop dispatches implementation; it does not do it inline
(the seyag `delegation` skill). Every main-loop tool call re-bills
the full context. A post-commit edit is usually a REVIEW-ROUND fix —
those are dispatch work too (batch the round to the unit's worker).

If this edit is inline-exempt (a mechanical edit within the measured
5-line limit in a file already in context): retry — this gate passes
once acked at this commit. Over five touched lines there is no ack
and no retry; that block is hard.

Otherwise: dispatch the unit per the `delegation` skill, or hand the
review round's batch to the unit's worker.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
exit 2
