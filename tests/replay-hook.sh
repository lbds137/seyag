#!/bin/bash
# tests/replay-hook.sh — replay one Bash-matching seyag hook against the
# Bash commands recorded in local Claude Code session JSONLs, and report what
# it would have blocked.
#
# SECRETS WARNING: the commands this prints are pulled verbatim from real
# recorded sessions and can contain tokens, paths, or other secrets. This
# output is local working material only — never paste it into a commit, PR,
# or tracked doc (same boundary as the session-mining corpus).
#
# Usage: tests/replay-hook.sh <hook-name> [--since N] [--slug SLUG] [--projects-dir DIR] [--tool NAME] [--event PreToolUse|PostToolUse]
#   <hook-name>          a hook under plugins/seyag/hooks/ (e.g. lossy-pipe-guard);
#                        an unknown name is refused with a one-line error, exit 2.
#   --since N            only JSONLs modified in the last N days (default 7).
#   --slug SLUG          only ~/.claude/projects/SLUG/*.jsonl and
#                        SLUG/*/subagents/*.jsonl (default: every slug).
#   --projects-dir DIR   the projects root (default $HOME/.claude/projects); lets
#                        a probe point this at a fixture instead of real logs.
#   --tool NAME          tool_use name to replay (default Bash; e.g. AskUserQuestion).
#   --event EVENT        PreToolUse or PostToolUse (default PreToolUse).
#
# Mechanism: with the default --tool Bash, pulls every Bash tool_use command from
# .message.content[] entries (.type=="tool_use", .name=="Bash", .input.command)
# and builds the hook JSON Claude Code sends ({"tool_name":"Bash",
# "tool_input":{"command":...},"cwd":<entry's cwd, else $HOME>,
# "hook_event_name":<event>,"session_id":<derived per file, see below>}) in the
# SAME jq pass, so a huge command never round-trips through a shell argv.
# With --tool AskUserQuestion (or any non-Bash tool), every main-lane tool_use
# of that name is replayed with {tool_name, tool_input:.input, tool_use_id:.id,
# cwd, hook_event_name:<event>, session_id, transcript_path:<prefix file>},
# plus tool_response:null for PostToolUse, where the prefix file in the
# per-file scratch state dir is cut before the FIRST line whose record carries
# the ask's message.id for PreToolUse, and up to and including the line holding
# the ask's tool_use for PostToolUse. Fed to the hook script DIRECTLY
# (`bash plugins/seyag/hooks/<hook-name>.sh`, not via run.sh — a project
# shipping its own `.claude/hooks/<name>.sh` override makes run.sh exit 0 for
# every command, reading as "nothing blocked").
#
# Subagent transcripts (<slug>/<session>/subagents/*.jsonl) are replayed too
# and labelled "(subagent)"; other nested JSONLs (mined-corpus reports) are
# not. session_id is the filename stem, or the parent dir for a subagent.
#
# Hooks run with a fresh per-JSONL-file XDG_STATE_HOME, XDG_RUNTIME_DIR and
# SYG_STATE_DIR (all in a scratch dir removed on exit), and with
# SYG_PR_MONITOR_SEEN_FILE and SYG_PR_BODY_ACK_FILE unset, so a replay never
# reads or writes the caller's state through those paths. The state and
# runtime dirs are wiped and recreated before EACH file's commands, so two
# sessions in one replay start equal — one session's ack never masks a later
# session's identical block. Within one file the state persists across that
# file's commands, as it did live; the next file starts empty. NOT isolated:
# hooks that write a hardcoded /tmp/claude-$(id -u) path
# (dispatch-posture-gate) still use the caller's /tmp state;
# queued-message-receipt, context-size-reminder and context-block-gate honor
# SYG_STATE_DIR and are isolated by the wipe above.
# Also unset (they name files outside those dirs): SYG_LAUNCH_RECORD_DIR,
# SYG_CREDIT_LEDGER, SYG_CLASSIFIER_LEDGER, SYG_DISPATCH_ACK_FILE.
#
# A hit ("block") is a non-zero exit from the hook script, OR, for PostToolUse,
# a non-empty stdout. Output: one section per hit (`command: <first 200 chars>`
# for Bash, `ask: <first question text, 200 chars, one line>` otherwise; slug;
# the hook's stderr/stdout, first 3 lines), then a summary line:
#   replay-hook: <hook-name>: <blocked>/<total> commands|asks blocked across <files> files
# A hook that exits 0 unless a switch is set blocks nothing in a run without
# it, so its header may carry `# REPLAY-ARMED-BY: VAR [VAR...]`. The field
# names only the variables, not every condition: a gate may also need its
# target marked (private-term-guard needs the repo public), so an armed replay
# that blocks nothing is not proof by itself. Before the replay, each named VAR
# that is unset or empty in this environment gets a stderr line
# (`replay-hook: warning: <hook-name> is inert without <VAR> (unset or empty
# here); export it for this run`), and the summary line gains
# ` (INERT: <VAR> unset or empty)` for each one; tokens that are not shell
# identifiers are skipped. The field is
# for gates only: a hook with side effects (one that writes files or state)
# must not carry it, or a replay would run it for real. Nothing else is
# printed. Exit 0 even with blocks — a report, not a gate.
#
# Streams each file through one jq pass (malformed lines skipped, not fatal);
# 10+ MB session logs are normal. ~20ms/command observed (one hook spawn per
# command) — a 7-day all-slug run is ~10-12 min (subagent logs roughly double
# the commands; ~17 ms/command measured), not the ~14 min a
# three-jq-spawns-per-command version cost.

set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HOOKS_DIR="$REPO/plugins/seyag/hooks"

HOOK_NAME="${1:-}"
if [ -z "$HOOK_NAME" ] || [[ "$HOOK_NAME" == --* ]]; then
  echo "replay-hook: usage: replay-hook.sh <hook-name> [--since N] [--slug SLUG] [--projects-dir DIR] [--tool NAME] [--event PreToolUse|PostToolUse]" >&2
  exit 2
fi
shift

if [ ! -f "$HOOKS_DIR/$HOOK_NAME.sh" ]; then
  echo "replay-hook: unknown hook '$HOOK_NAME'" >&2
  exit 2
fi

SINCE=7
SLUG=""
PROJECTS_DIR="$HOME/.claude/projects"
TOOL="Bash"
EVENT="PreToolUse"

need_value() { [ $# -ge 2 ] || { echo "replay-hook: $1 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --since) need_value "$@"; SINCE="$2"; shift 2 ;;
    --slug) need_value "$@"; SLUG="$2"; shift 2 ;;
    --projects-dir) need_value "$@"; PROJECTS_DIR="$2"; shift 2 ;;
    --tool) need_value "$@"; TOOL="$2"; shift 2 ;;
    --event) need_value "$@"; EVENT="$2"; shift 2 ;;
    *) echo "replay-hook: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[[ "$SINCE" =~ ^[0-9]+$ ]] || { echo "replay-hook: --since needs a whole number of days" >&2; exit 2; }
[ -n "$TOOL" ] || { echo "replay-hook: --tool needs a tool name" >&2; exit 2; }
case "$EVENT" in
  PreToolUse | PostToolUse) ;;
  *) echo "replay-hook: --event must be PreToolUse or PostToolUse" >&2; exit 2 ;;
esac

# Strip a trailing slash: otherwise ${f#"$PROJECTS_DIR"/} below fails to
# strip (double slash mismatch) and slug_name comes out empty.
PROJECTS_DIR=${PROJECTS_DIR%/}

if [ -n "$SLUG" ]; then
  SEARCH_ROOT="$PROJECTS_DIR/$SLUG"
  MAXDEPTH=1
else
  SEARCH_ROOT="$PROJECTS_DIR"
  MAXDEPTH=2
fi
[ -d "$SEARCH_ROOT" ] || { echo "replay-hook: no such directory: $SEARCH_ROOT" >&2; exit 2; }

# Hook state (see the header): one state and one runtime dir, wiped and
# recreated before each JSONL file's commands.
REPLAY_STATE=$(mktemp -d) || { echo "replay-hook: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$REPLAY_STATE"' EXIT
mkdir -p "$REPLAY_STATE/state" "$REPLAY_STATE/runtime"
chmod 700 "$REPLAY_STATE/runtime"

# REPLAY-ARMED-BY (see the header): a switch the hook needs to act, unset or empty here.
INERT_SUFFIX=""
ARMED_LINE=$(grep -m1 '^# REPLAY-ARMED-BY:' "$HOOKS_DIR/$HOOK_NAME.sh" 2>/dev/null || true)
if [ -n "$ARMED_LINE" ]; then
  read -r -a ARMED_VARS <<<"${ARMED_LINE#*REPLAY-ARMED-BY:}"
  for armed_var in ${ARMED_VARS[@]+"${ARMED_VARS[@]}"}; do
    [[ "$armed_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if [ -z "${!armed_var:-}" ]; then
      echo "replay-hook: warning: $HOOK_NAME is inert without $armed_var (unset or empty here); export it for this run" >&2
      INERT_SUFFIX="$INERT_SUFFIX (INERT: $armed_var unset or empty)"
    fi
  done
fi

TOTAL=0
BLOCKED=0
FILES=0

# Epoch cutoff, not `find -mtime`: -mtime's day-bucket semantics differ across
# find implementations (bfs matches -mtime -0; GNU find's docs say it
# shouldn't). --since 0 means "modified after right now" — no existing file
# can satisfy that, so it deterministically yields 0 files.
CUTOFF=$(( $(date +%s) - SINCE * 86400 ))
FILE_LIST=$( {
  find "$SEARCH_ROOT" -maxdepth "$MAXDEPTH" -type f -name '*.jsonl' 2>/dev/null
  find "$SEARCH_ROOT" -mindepth $((MAXDEPTH + 2)) -maxdepth $((MAXDEPTH + 2)) -type f -regex '.*/subagents/[^/]*\.jsonl' 2>/dev/null
} )

while IFS= read -r f; do
  [ -z "$f" ] && continue
  mtime=$(stat -c %Y "$f" 2>/dev/null) || continue
  [ "$mtime" -gt "$CUTOFF" ] || continue
  FILES=$((FILES + 1))
  rel=${f#"$PROJECTS_DIR"/}
  case "$rel" in
    */*) slug_name=${rel%%/*} ;;
    *) slug_name="(root)" ;;
  esac
  slug_label="slug: $slug_name"
  case "$rel" in
    */subagents/*) slug_label="$slug_label (subagent)" ;;
  esac
  case "$rel" in
    */subagents/*) sess_id=$(basename "$(dirname "$(dirname "$f")")") ;;
    *) sess_id=$(basename "$f" .jsonl) ;;
  esac

  # Fresh state for this file (see the header): one session's ack must never
  # mask a later session's identical block.
  rm -rf "$REPLAY_STATE/state" "$REPLAY_STATE/runtime"
  mkdir -p "$REPLAY_STATE/state" "$REPLAY_STATE/runtime"
  chmod 700 "$REPLAY_STATE/runtime"

  if [ "$TOOL" = "Bash" ]; then
    while IFS= read -r payload; do
      [ -z "$payload" ] && continue
      TOTAL=$((TOTAL + 1))

      if [ "$EVENT" = "PostToolUse" ]; then
        hout=$(printf '%s' "$payload" | env -u CLAUDE_PROJECT_DIR -u SYG_PR_MONITOR_SEEN_FILE -u SYG_PR_BODY_ACK_FILE -u SYG_LAUNCH_RECORD_DIR -u SYG_CREDIT_LEDGER -u SYG_CLASSIFIER_LEDGER -u SYG_DISPATCH_ACK_FILE SYG_STATE_DIR="$REPLAY_STATE/state" XDG_STATE_HOME="$REPLAY_STATE/state" XDG_RUNTIME_DIR="$REPLAY_STATE/runtime" PYTHONDONTWRITEBYTECODE=1 bash "$HOOKS_DIR/$HOOK_NAME.sh" 2>"$REPLAY_STATE/hook.err")
        rc=$?
        herr=$(cat "$REPLAY_STATE/hook.err" 2>/dev/null || true)
        out="${herr}${herr:+${hout:+$'\n'}}${hout}"
        hit=0
        if [ "$rc" -ne 0 ] || [ -n "$hout" ]; then hit=1; fi
      else
        out=$(printf '%s' "$payload" | env -u CLAUDE_PROJECT_DIR -u SYG_PR_MONITOR_SEEN_FILE -u SYG_PR_BODY_ACK_FILE -u SYG_LAUNCH_RECORD_DIR -u SYG_CREDIT_LEDGER -u SYG_CLASSIFIER_LEDGER -u SYG_DISPATCH_ACK_FILE SYG_STATE_DIR="$REPLAY_STATE/state" XDG_STATE_HOME="$REPLAY_STATE/state" XDG_RUNTIME_DIR="$REPLAY_STATE/runtime" PYTHONDONTWRITEBYTECODE=1 bash "$HOOKS_DIR/$HOOK_NAME.sh" 2>&1)
        rc=$?
        hit=0
        [ "$rc" -ne 0 ] && hit=1
      fi

      if [ "$hit" -eq 1 ]; then
        BLOCKED=$((BLOCKED + 1))
        cmd=$(jq -r '.tool_input.command' <<<"$payload")
        cmd="${cmd//$'\n'/ }"; cmd="${cmd//$'\r'/ }"; cmd="${cmd//$'\t'/ }"
        echo "--- blocked ---"
        echo "command: ${cmd:0:200}"
        echo "$slug_label"
        printf '%s\n' "$out" | head -3
        echo
      fi
    done < <(jq -Rc --arg home "$HOME" --arg sid "$sess_id" --arg ev "$EVENT" '
        (fromjson? // empty) |
        (.cwd // $home) as $cwd |
        (.message.content // [])[]? | select(.type=="tool_use" and .name=="Bash" and .input.command != null) |
        ({tool_name:"Bash", tool_input:{command:.input.command}, cwd:$cwd, hook_event_name:$ev, session_id:$sid}
         + (if $ev == "PostToolUse" then {tool_response:null} else {} end))
      ' "$f")
  else
    PREFIX_FILE="$REPLAY_STATE/state/prefix.jsonl"
    while IFS=$'\t' read -r cut payload; do
      [ -z "$payload" ] && continue
      TOTAL=$((TOTAL + 1))

      if [ "${cut:-0}" -gt 0 ]; then
        head -n "$cut" "$f" > "$PREFIX_FILE"
      else
        : > "$PREFIX_FILE"
      fi

      if [ "$EVENT" = "PostToolUse" ]; then
        hout=$(printf '%s' "$payload" | env -u CLAUDE_PROJECT_DIR -u SYG_PR_MONITOR_SEEN_FILE -u SYG_PR_BODY_ACK_FILE -u SYG_LAUNCH_RECORD_DIR -u SYG_CREDIT_LEDGER -u SYG_CLASSIFIER_LEDGER -u SYG_DISPATCH_ACK_FILE SYG_STATE_DIR="$REPLAY_STATE/state" XDG_STATE_HOME="$REPLAY_STATE/state" XDG_RUNTIME_DIR="$REPLAY_STATE/runtime" PYTHONDONTWRITEBYTECODE=1 bash "$HOOKS_DIR/$HOOK_NAME.sh" 2>"$REPLAY_STATE/hook.err")
        rc=$?
        herr=$(cat "$REPLAY_STATE/hook.err" 2>/dev/null || true)
        out="${herr}${herr:+${hout:+$'\n'}}${hout}"
        hit=0
        if [ "$rc" -ne 0 ] || [ -n "$hout" ]; then hit=1; fi
      else
        out=$(printf '%s' "$payload" | env -u CLAUDE_PROJECT_DIR -u SYG_PR_MONITOR_SEEN_FILE -u SYG_PR_BODY_ACK_FILE -u SYG_LAUNCH_RECORD_DIR -u SYG_CREDIT_LEDGER -u SYG_CLASSIFIER_LEDGER -u SYG_DISPATCH_ACK_FILE SYG_STATE_DIR="$REPLAY_STATE/state" XDG_STATE_HOME="$REPLAY_STATE/state" XDG_RUNTIME_DIR="$REPLAY_STATE/runtime" PYTHONDONTWRITEBYTECODE=1 bash "$HOOKS_DIR/$HOOK_NAME.sh" 2>&1)
        rc=$?
        hit=0
        [ "$rc" -ne 0 ] && hit=1
      fi

      if [ "$hit" -eq 1 ]; then
        BLOCKED=$((BLOCKED + 1))
        ask_q=$(jq -r '.tool_input.questions[0].question // ""' <<<"$payload")
        ask_q="${ask_q//$'\n'/ }"; ask_q="${ask_q//$'\r'/ }"; ask_q="${ask_q//$'\t'/ }"
        echo "--- blocked ---"
        echo "ask: ${ask_q:0:200}"
        echo "$slug_label"
        printf '%s\n' "$out" | head -3
        echo
      fi
    done < <(jq -Rnr --arg home "$HOME" --arg sid "$sess_id" --arg tool "$TOOL" --arg ev "$EVENT" --arg pfx "$PREFIX_FILE" '
        [inputs | {line: input_line_number, rec: (fromjson? // null)} | select(.rec != null and (.rec | type) == "object")] as $rows
        | (reduce $rows[] as $r ({};
            (($r.rec.message.id? // "") | tostring) as $mid
            | if $mid != "" and (has($mid) | not) then .[$mid] = $r.line else . end)) as $first_line
        | $rows[]
        | .line as $ln
        | .rec
        | select((.isSidechain // false) | not)
        | (.cwd // $home) as $cwd
        | ((.message.id? // "") | tostring) as $mid
        | (if $ev == "PreToolUse" then ((if $mid != "" then $first_line[$mid] else $ln end) - 1) else $ln end) as $cut
        | (.message.content // [])[]?
        | select((type == "object") and .type == "tool_use" and .name == $tool and (.input != null))
        | ({tool_name: $tool, tool_input: .input, tool_use_id: (.id // ""), cwd: $cwd, hook_event_name: $ev, session_id: $sid, transcript_path: $pfx}
           + (if $ev == "PostToolUse" then {tool_response: null} else {} end)) as $p
        | "\($cut)\t\($p | tojson)"
      ' "$f")
  fi
done <<<"$FILE_LIST"

UNIT_LABEL="commands"
[ "$TOOL" != "Bash" ] && UNIT_LABEL="asks"
echo "replay-hook: $HOOK_NAME: $BLOCKED/$TOTAL $UNIT_LABEL blocked across $FILES files$INERT_SUFFIX"
exit 0
