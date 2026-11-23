#!/bin/bash
# Fixture check for handback-live-task-gate.sh — run after ANY edit to the hook or lib/handback_tasks.py.
# Builds a hermetic parent transcript dir with agent transcripts under
# <sid>/subagents/agent-<aid>.jsonl, feeds PreToolUse SubagentHandback payloads
# on stdin, and pins: a refusal (exit 2, the live task named, the refusal count
# shown), a pass (exit 0, empty stderr) for each way a task ends or is not the
# agent's own, the cap, the threshold knob, fail-open paths, and the
# SYG_DISABLE=handback-tasks bypass through run.sh.
# Record shapes follow the live captures in TASK-118 (findings §4-6). Ids are invented.
# The gate's state lives at <state>/seyag/handback-live-task-gate/<session>/<agent>.
#
# Usage: hooks/handback-live-task-gate.probe.sh   (from anywhere)

set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
unset SYG_DISABLE SYG_ENABLE SYG_PROFILE SYG_HANDBACK_GATE_MAX_DENIES

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$SCRIPT_DIR/handback-live-task-gate.sh"
RUN="$SCRIPT_DIR/run.sh"

TMP=$(mktemp -d) || { echo "FAIL [setup]: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"
PROJ="$TMP/proj"
PARENT="$PROJ/main.jsonl"
mkdir -p "$PROJ" "$STATE"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"start"}}' >"$PARENT"

fail=0
count=0
RC=0
ERR=""
EXTRA_ENV=()

# ---- record builders (one JSON object per line) ----
bash_launch() { # <tool_use id> <task id> <description>
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"%s","name":"Bash","input":{"command":"sleep 600; cat build.log","description":"%s","run_in_background":true}}]}}\n' "$1" "$3"
  printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","content":"Command running in background with ID: %s"}]},"toolUseResult":{"backgroundTaskId":"%s"}}\n' "$1" "$2" "$2"
}
text_turn() { # <text>
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"%s"}]}}\n' "$1"
}
notify_str() { # <task id>: a task-notification with string content
  printf '{"type":"user","origin":{"kind":"task-notification"},"message":{"role":"user","content":"<task-notification><task-id>%s</task-id><status>completed</status></task-notification>"}}\n' "$1"
}
notify_list() { # <task id>: a task-notification with list-of-text-blocks content
  printf '{"type":"user","origin":{"kind":"task-notification"},"message":{"role":"user","content":[{"type":"text","text":"<task-notification><task-id>%s</task-id><status>completed</status></task-notification>"}]}}\n' "$1"
}
stop_call() { # <tool_use id> <task id>
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"%s","name":"TaskStop","input":{"task_id":"%s"}}]}}\n' "$1" "$2"
}
stop_ok() { # <tool_use id> <task id>
  printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","content":"Successfully stopped task: %s (sleep 600; cat build.log)"}]},"toolUseResult":{"message":"Successfully stopped task: %s (sleep 600; cat build.log)","task_id":"%s","task_type":"local_bash"}}\n' "$1" "$2" "$2" "$2"
}
stop_gone() { # <tool_use id> <task id>: a repeat stop, reported as an error result
  printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","is_error":true,"content":"Task %s is not running (status: killed)"}]}}\n' "$1" "$2"
}

# agent_t <sid> <aid> <lines...>: write the agent transcript (lines come from the builders).
agent_t() {
  local sid=$1 aid=$2 dir
  shift 2
  dir="$PROJ/$sid/subagents"
  mkdir -p "$dir"
  printf '%s\n' "$@" >"$dir/agent-$aid.jsonl"
}

# payload <sid> <aid> <tool>: empty sid or aid omits the field.
payload() {
  jq -cn --arg s "$1" --arg a "$2" --arg t "$PARENT" --arg n "$3" \
    '{tool_name: $n, transcript_path: $t, tool_input: {message: "done"}, tool_use_id: "tu-probe"}
     + (if $s == "" then {} else {session_id: $s} end)
     + (if $a == "" then {} else {agent_id: $a} end)'
}

# hook <sid> <aid> [tool]: run the hook directly, setting RC and ERR.
hook() {
  local sid=$1 aid=$2 tool=${3:-SubagentHandback}
  ERR=$(payload "$sid" "$aid" "$tool" \
    | env "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}" XDG_STATE_HOME="$STATE" bash "$HOOK" 2>&1 >/dev/null)
  RC=$?
}

# expect <label> <want-rc> [text...]: RC must equal want; a block must name each text; a pass must be silent.
expect() {
  local label=$1 want=$2 t ok=1
  shift 2
  count=$((count + 1))
  if [ "$RC" != "$want" ]; then
    ok=0
  elif [ "$want" = 2 ]; then
    for t in "$@"; do
      grep -qF -- "$t" <<<"$ERR" || { ok=0; break; }
    done
  elif [ -n "$ERR" ]; then
    ok=0
  fi
  if [ "$ok" = 1 ]; then
    echo "PASS [$label]: exit $RC"
  else
    echo "FAIL [$label]: exit $RC (want $want) stderr: $ERR"
    fail=1
  fi
}

# expect_absent <label> <text>: the block must not name the text.
expect_absent() {
  count=$((count + 1))
  if grep -qF -- "$2" <<<"$ERR"; then
    echo "FAIL [$1]: stderr names $2: $ERR"
    fail=1
  else
    echo "PASS [$1]: stderr does not name $2"
  fi
}

# 1. one owned live task blocks, names its id and label, and counts the refusal.
agent_t s1 a1 "$(bash_launch tu1 bfake0001 'Watch build log')"
hook s1 a1
expect "1 one owned live task blocks" 2 "bfake0001  Watch build log" "Refusal 1 of 3"

# 2. only text: nothing owned, nothing blocks.
agent_t s2 a1 "$(text_turn 'Report ready.')"
hook s2 a1
expect "2 no owned tasks passes" 0

# 3. a task id only in the parent transcript never blocks this agent.
printf '%s\n' "$(bash_launch tu3 bfake0003 'Parent job')" >"$PARENT"
agent_t s3 a1 "$(text_turn 'Report ready.')"
hook s3 a1
expect "3 parent-only task passes" 0
printf '%s\n' '{"type":"user","message":{"role":"user","content":"start"}}' >"$PARENT"

# 3b. a record whose tool_result tool_use_id is a list is skipped; the owned live task after it still blocks.
agent_t s3b a1 '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":["x"],"content":"y"}]}}' "$(bash_launch tu3b bfake3001 'After bad record')"
hook s3b a1
expect "3b list-typed tool_use_id does not stop the scan" 2 "bfake3001  After bad record"

# 4. owned task + task-notification with string content passes.
agent_t s4 a1 "$(bash_launch tu4 bfake0004 'Long build')" "$(notify_str bfake0004)"
hook s4 a1
expect "4 owned task with string notification passes" 0

# 4b. a task-notification whose status is running does not end its task: blocks.
notify_status() { # <task id> <status>: a string-content task-notification with that status
  printf '{"type":"user","origin":{"kind":"task-notification"},"message":{"role":"user","content":"<task-notification><task-id>%s</task-id><status>%s</status></task-notification>"}}\n' "$1" "$2"
}
agent_t s4b a1 "$(bash_launch tu4b bfake0040 'Still running')" "$(notify_status bfake0040 running)"
hook s4b a1
expect "4b running notification does not end the task" 2 "bfake0040  Still running"

# 4c. a task-notification with a failed status ends its task.
agent_t s4c a1 "$(bash_launch tu4c bfake0041 'Failed job')" "$(notify_status bfake0041 failed)"
hook s4c a1
expect "4c failed notification ends the task" 0

# 5. owned task + task-notification with list-of-text-blocks content passes.
agent_t s5 a1 "$(bash_launch tu5 bfake0005 'Long build')" "$(notify_list bfake0005)"
hook s5 a1
expect "5 owned task with list notification passes" 0

# 6. owned task + TaskStop (successful) passes; 6b, a repeat stop reading "is not running", passes too.
agent_t s6 a1 "$(bash_launch tu6 bfake0006 'Watch build log')" "$(stop_call tu6s bfake0006)" "$(stop_ok tu6s bfake0006)"
hook s6 a1
expect "6 owned task stopped with TaskStop passes" 0
agent_t s6b a1 "$(bash_launch tu6b bfake0066 'Watch build log')" "$(stop_call tu6b2 bfake0066)" "$(stop_gone tu6b2 bfake0066)"
hook s6b a1
expect "6b owned task whose stop reads not running passes" 0

# 6c. a TaskStop whose result is another error (neither accepted phrase) does not end the task: blocks.
agent_t s6c a1 "$(bash_launch tu6c bfake0067 'Denied stop')" "$(stop_call tu6c2 bfake0067)" '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu6c2","is_error":true,"content":"Permission denied"}]}}'
hook s6c a1
expect "6c TaskStop with another error leaves the task live" 2 "bfake0067  Denied stop"

# 7. two owned, one stopped: only the live one is named.
agent_t s7 a1 "$(bash_launch tu7a bfake0701 'First job')" "$(bash_launch tu7b bfake0702 'Second job')" "$(stop_call tu7s bfake0701)" "$(stop_ok tu7s bfake0701)"
hook s7 a1
expect "7 one of two stopped blocks naming the live one" 2 "bfake0702  Second job" "Refusal 1 of 3"
expect_absent "7 stopped task not named" bfake0701

# 8. cap: three refusals, the fourth passes; another agent in the same session starts at 1.
agent_t s8 a1 "$(bash_launch tu8 bfake0801 'Capped job')"
agent_t s8 a2 "$(bash_launch tu8b bfake0802 'Other agent job')"
hook s8 a1
expect "8a refusal 1 of 3" 2 "Refusal 1 of 3"
hook s8 a1
expect "8b refusal 2 of 3" 2 "Refusal 2 of 3"
hook s8 a1
expect "8c refusal 3 of 3" 2 "Refusal 3 of 3"
hook s8 a1
expect "8d fourth hand-back passes (cap reached)" 0
hook s8 a2
expect "8e other agent starts at 1" 2 "Refusal 1 of 3"

# 8b. sessions "s8c.x"+agent "y" and "s8c"+agent "x.y" keep separate counters.
agent_t s8c.x y "$(bash_launch tu8c bfake0811 'Collide A')"
agent_t s8c x.y "$(bash_launch tu8d bfake0812 'Collide B')"
hook s8c.x y
expect "8b-1 first collision side refusal 1 of 3" 2 "Refusal 1 of 3"
hook s8c x.y
expect "8b-2 other collision side also starts at 1" 2 "Refusal 1 of 3"

# 16a. a clean pass (the transcript now shows the task stopped) clears the agent's count: the next episode starts at 1.
agent_t s16 a1 "$(bash_launch tu16 bfake1601 'Episode one')"
hook s16 a1
expect "16a-1 episode one refusal 1 of 3" 2 "Refusal 1 of 3"
hook s16 a1
expect "16a-2 episode one refusal 2 of 3" 2 "Refusal 2 of 3"
agent_t s16 a1 "$(bash_launch tu16 bfake1601 'Episode one')" "$(stop_call tu16s bfake1601)" "$(stop_ok tu16s bfake1601)"
hook s16 a1
expect "16a-3 stopped task passes with count 2 in state" 0
count=$((count + 1))
if [ ! -e "$STATE/seyag/handback-live-task-gate/s16/a1" ]; then
  echo "PASS [16a-4 clean pass removes the state file]"
else
  echo "FAIL [16a-4 clean pass removes the state file]: state file still present"
  fail=1
fi
agent_t s16 a1 "$(bash_launch tu16b bfake1602 'Episode two')"
hook s16 a1
expect "16a-5 next episode reads refusal 1 of 3" 2 "Refusal 1 of 3"

# 16b. a description with a tab and a newline prints as one line: "    <id>  <label>".
agent_t s16b a1 '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu16e","name":"Bash","input":{"command":"sleep 600","description":"Watch\tbuild\nlog here","run_in_background":true}}]}}' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu16e","content":"Command running in background with ID: bfake1631"}]},"toolUseResult":{"backgroundTaskId":"bfake1631"}}'
hook s16b a1
count=$((count + 1))
if [ "$RC" = 2 ] && [ "$(grep -c '^    bfake1631  Watch build log here$' <<<"$ERR")" = 1 ] && [ "$(grep -c 'bfake1631' <<<"$ERR")" = 1 ]; then
  echo "PASS [16b tab and newline in description give one label line]"
else
  echo "FAIL [16b tab and newline in description give one label line]: exit $RC stderr: $ERR"
  fail=1
fi

# 16c. a transcript over 32 MiB passes silently, even with an owned live task appended.
agent_t s16c a1 "$(bash_launch tu16c bfake1640 'Big transcript')"
BIG="$PROJ/s16c/subagents/agent-a1.jsonl"
truncate -s 33M "$BIG"
printf '%s\n' "$(bash_launch tu16d bfake1641 'Appended after size')" >>"$BIG"
count=$((count + 1))
if [ "$(stat -c %s "$BIG")" -gt 33554432 ]; then
  echo "PASS [16c fixture is over 32 MiB]"
else
  echo "FAIL [16c fixture is over 32 MiB]: size $(stat -c %s "$BIG")"
  fail=1
fi
hook s16c a1
expect "16c over 32 MiB transcript passes silently" 0

# 9. SYG_HANDBACK_GATE_MAX_DENIES: 1 caps at one refusal; a non-number falls back to 3.
agent_t s9 a1 "$(bash_launch tu9 bfake0901 'Knob job')"
EXTRA_ENV=(SYG_HANDBACK_GATE_MAX_DENIES=1)
hook s9 a1
expect "9a max 1: first refusal" 2 "Refusal 1 of 1"
hook s9 a1
expect "9b max 1: second hand-back passes" 0
EXTRA_ENV=(SYG_HANDBACK_GATE_MAX_DENIES=abc)
agent_t s9b a1 "$(bash_launch tu9b bfake0902 'Knob job')"
hook s9b a1
expect "9c max abc falls back to 3" 2 "Refusal 1 of 3"
EXTRA_ENV=()

# 10. unwritable state (XDG_STATE_HOME is a file): passes silently, never blocks without a count.
agent_t s10 a1 "$(bash_launch tu10 bfake1001 'State job')"
printf 'not a dir' >"$TMP/state-as-file"
ERR=$(payload s10 a1 SubagentHandback \
  | XDG_STATE_HOME="$TMP/state-as-file" bash "$HOOK" 2>&1 >/dev/null); RC=$?
expect "10 unwritable state passes" 0

# 11. fail-open paths.
agent_t s11 a1 "$(bash_launch tu11 bfake1101 'Open job')"
hook s11 a1 Bash
expect "11a tool_name Bash passes" 0
hook s11 "" SubagentHandback
expect "11b missing agent_id passes" 0
hook s13nofile a1
expect "11c agent transcript missing passes" 0
ERR=$(printf 'not json at all' | XDG_STATE_HOME="$STATE" bash "$HOOK" 2>&1 >/dev/null); RC=$?
expect "11d garbage stdin passes" 0
hook "../x" a1
expect "11e invalid session id passes" 0

# 12. through run.sh: SYG_DISABLE=handback-tasks passes; unset blocks.
agent_t s12 a1 "$(bash_launch tu12 bfake1201 'Run job')"
ERR=$(payload s12 a1 SubagentHandback \
  | env -u SYG_PROFILE -u SYG_ENABLE SYG_DISABLE=handback-tasks XDG_STATE_HOME="$STATE" bash "$RUN" handback-live-task-gate 2>&1 >/dev/null); RC=$?
expect "12a SYG_DISABLE=handback-tasks via run.sh passes" 0
agent_t s12b a1 "$(bash_launch tu12b bfake1202 'Run job')"
ERR=$(payload s12b a1 SubagentHandback \
  | env -u SYG_PROFILE -u SYG_ENABLE -u SYG_DISABLE XDG_STATE_HOME="$STATE" bash "$RUN" handback-live-task-gate 2>&1 >/dev/null); RC=$?
expect "12b no disable via run.sh blocks" 2 "bfake1202" "Refusal 1 of 3"

# live_task_ids over parsed entries: handoff-pick-check imports it with HT_TRANSCRIPT unset.
LT_LIB="$SCRIPT_DIR/lib"
LT_LAUNCH='{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu1","content":"started"}]},"toolUseResult":{"backgroundTaskId":"b1"}}'
LT_NOTE='{"type":"user","origin":{"kind":"task-notification"},"message":{"content":"<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n</task-notification>"}}'
LT_PY='import sys, json; sys.path.insert(0, sys.argv[1]); import handback_tasks; print(json.dumps(handback_tasks.live_task_ids(json.loads(l) for l in sys.stdin)))'
count=$((count + 1))
got=$(printf '%s\n%s\n' "$LT_LAUNCH" "$LT_NOTE" | env -u HT_TRANSCRIPT python3 -I -c "$LT_PY" "$LT_LIB" 2>&1)
if [ "$got" = "[]" ]; then echo "PASS [live_task_ids: launch then notification ends b1]: $got"; else echo "FAIL [live_task_ids: launch then notification ends b1] want [] got: $got"; fail=1; fi
count=$((count + 1))
got=$(printf '%s\n' "$LT_LAUNCH" | env -u HT_TRANSCRIPT python3 -I -c "$LT_PY" "$LT_LIB" 2>&1)
if [ "$got" = '["b1"]' ]; then echo "PASS [live_task_ids: launch alone leaves b1 live]: $got"; else echo "FAIL [live_task_ids: launch alone] want [\"b1\"] got: $got"; fail=1; fi
LT_QUEUED='{"type":"attachment","attachment":{"type":"queued_command","commandMode":"task-notification","origin":{"kind":"task-notification"},"prompt":"<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n</task-notification>"}}'
LT_QUEUED_HUMAN='{"type":"attachment","attachment":{"type":"queued_command","commandMode":"task-notification","origin":{"kind":"human"},"prompt":"<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n</task-notification>"}}'
count=$((count + 1))
got=$(printf '%s\n%s\n' "$LT_LAUNCH" "$LT_QUEUED" | env -u HT_TRANSCRIPT python3 -I -c "$LT_PY" "$LT_LIB" 2>&1)
if [ "$got" = "[]" ]; then echo "PASS [live_task_ids: launch then queued mid-turn notification ends b1]: $got"; else echo "FAIL [live_task_ids: launch then queued mid-turn notification ends b1] want [] got: $got"; fail=1; fi
count=$((count + 1))
got=$(printf '%s\n%s\n' "$LT_LAUNCH" "$LT_QUEUED_HUMAN" | env -u HT_TRANSCRIPT python3 -I -c "$LT_PY" "$LT_LIB" 2>&1)
if [ "$got" = '["b1"]' ]; then echo "PASS [live_task_ids: queued attachment with human origin leaves b1 live]: $got"; else echo "FAIL [live_task_ids: queued attachment with human origin] want [\"b1\"] got: $got"; fail=1; fi

echo "---"
echo "$count cases"
[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
