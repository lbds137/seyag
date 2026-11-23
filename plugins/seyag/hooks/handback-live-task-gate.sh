#!/bin/bash
# PreToolUse hook (matcher: SubagentHandback): refuse a subagent's hand-back
# while background tasks it started still run. Component `handback-tasks`;
# `SYG_DISABLE=handback-tasks` turns it off. At most SYG_HANDBACK_GATE_MAX_DENIES
# refusals per agent (default 3), then the hand-back passes.
#
# WHY:
#   A subagent that starts a background shell task (Bash run_in_background) and
#   hands back while it runs gets parked by the harness. When the task finishes
#   the agent resumes, and its second SubagentHandback is refused ("one report
#   per result"), so the final report is lost. SubagentStop is too late: the
#   report is already delivered through the SubagentHandback call by then. A
#   PreToolUse deny on SubagentHandback holds the report (live captures on
#   Claude Code 2.1.330, TASK-118).
#
# THE RULE (judged by `hooks/lib/handback_tasks.py` on the agent's own
# transcript, `<dir of transcript_path>/<session_id>/subagents/agent-<agent_id>.jsonl`):
#   - A task is owned when a user entry's toolUseResult carries a
#     backgroundTaskId. It is ended when a task-notification names it (unless
#     that text's status is running or pending), or when a TaskStop or KillShell
#     call on it has a result whose text says "Successfully stopped task" or
#     "is not running". Any other result leaves it live. Owned and not ended = live.
#   - Any live task refuses the hand-back (exit 2, the ids and labels on stderr),
#     up to the cap. The harness's PreToolUse payload has no background_tasks
#     field, so the agent's own transcript is the only source.
#   - Other agents' tasks never block: only the agent's own transcript is read.
#
# KNOWN BOUNDS:
#   - Only Bash run_in_background ownership is recognised. Nested Agent or Monitor
#     launches were not observed in captures.
#   - Notification statuses other than completed (failed, killed) are unobserved;
#     any status except running or pending is taken as terminal.
#   - The cap is per (session, agent) and counted in a state file at
#     <state>/seyag/handback-live-task-gate/<session>/<agent>: a denied
#     hand-back that is never re-sent leaves the count where it is.
#   - The hook reads transcripts, not live process state, so a task that died
#     without a notification or a TaskStop stays live until the cap.
#
# FAIL-OPEN:
#   Not SubagentHandback, a missing or invalid session or agent id, a missing or
#   unreadable agent transcript, unreadable or unwritable state, malformed JSON,
#   missing jq/python3, or any internal error -> exit 0 with nothing on stdout
#   or stderr. The state is written before the refusal is shown, so a write
#   failure passes rather than blocking without a count.
#
# Fixture check: run hooks/handback-live-task-gate.probe.sh after ANY edit.

set -uo pipefail

syg_drain_stdin() { IFS= read -r -d '' _ || true; }

type -P jq python3 >/dev/null 2>&1 || { syg_drain_stdin; exit 0; }

INPUT=$(cat 2>/dev/null) || exit 0
[ -n "$INPUT" ] || exit 0

TOOL_NAME='' SESSION_ID='' AGENT_ID='' TRANSCRIPT=''
{
  IFS= read -r -d '' TOOL_NAME \
    && IFS= read -r -d '' SESSION_ID \
    && IFS= read -r -d '' AGENT_ID \
    && IFS= read -r -d '' TRANSCRIPT
} < <(jq -j '
  def s: if . == null then "" elif type == "string" then . else tostring end
    | split(([0]|implode)) | join("")
    | ([10]|implode) as $nl | until((endswith($nl)|not); .[:-1]);
  "\(.tool_name | s)\u0000\(.session_id | s)\u0000\(.agent_id | s)\u0000\(.transcript_path | s)\u0000"
' <<<"$INPUT" 2>/dev/null) || exit 0
[ "$TOOL_NAME" = "SubagentHandback" ] || exit 0
[ -n "$SESSION_ID" ] && [ -n "$AGENT_ID" ] && [ -n "$TRANSCRIPT" ] || exit 0

# Ids are validated the way push-tree-guard validates its own (no state and no
# block when either id is invalid).
[[ "$SESSION_ID" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$SESSION_ID" != "." ] && [ "$SESSION_ID" != ".." ] || exit 0
[[ "$AGENT_ID" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$AGENT_ID" != "." ] && [ "$AGENT_ID" != ".." ] || exit 0

AGENT_T="$(dirname "$TRANSCRIPT")/$SESSION_ID/subagents/agent-$AGENT_ID.jsonl"
[ -r "$AGENT_T" ] || exit 0

HOOKS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK_LIB="$HOOKS_DIR/lib"

LIVE=$(HT_TRANSCRIPT="$AGENT_T" python3 -I "${SYG_PY_CACHE_ARG:--B}" -c 'import sys; sys.path.insert(0, sys.argv[1]); import handback_tasks' "$HOOK_LIB" 2>/dev/null) || exit 0
[ -n "$LIVE" ] || exit 0

STATE_DIR="${XDG_STATE_HOME:-${HOME:-}/.local/state}/seyag/handback-live-task-gate"
STATE_FILE="$STATE_DIR/$SESSION_ID/$AGENT_ID"

COUNT=0
if [ -r "$STATE_FILE" ]; then
  read -r RAW <"$STATE_FILE" 2>/dev/null || RAW=''
  [[ "$RAW" =~ ^[0-9]{1,9}$ ]] && COUNT=$((10#$RAW))
fi

MAX=3
MAX_RAW="${SYG_HANDBACK_GATE_MAX_DENIES:-}"
if [[ "$MAX_RAW" =~ ^[1-9][0-9]{0,8}$ ]]; then
  MAX=$((10#$MAX_RAW))
fi

[ "$COUNT" -ge "$MAX" ] && exit 0

NEW=$((COUNT + 1))
mkdir -p "$STATE_DIR/$SESSION_ID" 2>/dev/null || exit 0
{ printf '%s\n' "$NEW" >"$STATE_FILE"; } 2>/dev/null || exit 0

{
  echo "HANDBACK GATE — hand-back refused: background task(s) you started are still running:"
  while IFS=$'\t' read -r id label; do
    [ -n "$id" ] && printf '    %s  %s\n' "$id" "$label"
  done <<<"$LIVE"
  echo "Your report would reach the caller while they run, and a second hand-back after they finish is refused by the harness, so your final result would be lost."
  echo "Stop each one now: load TaskStop (ToolSearch \"select:TaskStop\"), then TaskStop with task_id <id>. If you need its output, read its output file first, then stop it. Then hand back."
  echo "Refusal $NEW of $MAX; after that the hand-back passes. Off switch: SYG_DISABLE=handback-tasks."
} >&2
exit 2
