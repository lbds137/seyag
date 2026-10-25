#!/bin/bash
# Fixture check for handoff-pick-check.sh — run after ANY edit to the hook.
# Asserts the exit-code table over synthetic transcripts: a turn that writes a
# handoff (via a Bash command matching SYG_HANDOFF_CMDS, an Edit/Write whose
# file_path matches SYG_HANDOFF_PATHS, or when unwired the narrow built-in
# default HANDOFF.md / handoff.md) blocks unless the closing message names
# one of the pick tokens (/clear, /compact, or the standalone word keep).
# Unmatched tool calls, an earlier turn's write, unwired non-default paths
# (including docs/roles/admin.md), stop_hook_active re-stops, and
# missing/broken inputs all stay silent. Fire-once memory: a fired (or
# pick-accompanied) write never re-arms the poll turn-ends absorbed after it,
# a NEW write past the stored offset re-arms, isMeta cron prompts do not bound
# the turn, and state failures (corrupt content, unwritable dir) fail open.
#
# Usage: plugins/seyag/hooks/handoff-pick-check.probe.sh   (from repo root)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$SCRIPT_DIR/handoff-pick-check.sh"
CLAUDE_PROJECT_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
export CLAUDE_PROJECT_DIR
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

jsonstr() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }

# Build a transcript: one user turn + a Bash tool_use + a final text block.
mktx_bash() { # $1=out $2=command $3=text
  : > "$1"
  echo '{"type":"user","isMeta":null,"message":{"content":"go"}}' >> "$1"
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":%s}}]}}\n' "$(jsonstr "$2")" >> "$1"
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":%s}]}}\n' "$(jsonstr "$3")" >> "$1"
}

# Build a transcript: one user turn + an Edit/Write tool_use + a final text block.
mktx_file() { # $1=out $2=tool_name $3=file_path $4=text
  : > "$1"
  echo '{"type":"user","isMeta":null,"message":{"content":"go"}}' >> "$1"
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"%s","input":{"file_path":%s}}]}}\n' "$2" "$(jsonstr "$3")" >> "$1"
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":%s}]}}\n' "$(jsonstr "$4")" >> "$1"
}

fail=0
check() { # $1=expected_exit $2=label $3=transcript $4=stop_active $5+=stderr regexes
  # Each regex must match the captured stderr; a regex prefixed with "!" must NOT.
  echo "{\"stop_hook_active\":${4:-false},\"transcript_path\":\"$3\"}" | bash "$HOOK" >/dev/null 2>"$TMP/stderr.out"
  local got=$? pat
  if [ "$got" != "$1" ]; then echo "FAIL [$got≠$1]: $2"; fail=1; return; fi
  for pat in "${@:5}"; do
    if [ "${pat#!}" != "$pat" ]; then
      if grep -qE "${pat#!}" "$TMP/stderr.out"; then
        echo "FAIL [stderr matches /${pat#!}/ but must not]: $2"; fail=1; return
      fi
    elif ! grep -qE "$pat" "$TMP/stderr.out"; then
      echo "FAIL [stderr misses /$pat/]: $2"; fail=1; return
    fi
  done
  echo "ok   [$got]: $2"
}

# Hermetic: ambient machine config must not leak into the probe, and the
# fire-once memory's state lives under the fixture tmp, never ~/.local/state.
unset SYG_HANDOFF_PATHS SYG_HANDOFF_CMDS
export XDG_STATE_HOME="$TMP/state"

# --- 1. Handoff via Bash matching SYG_HANDOFF_CMDS + no pick → exit 2 ---------
mktx_bash "$TMP/bash-nopick.jsonl" "myrole --set widget --handoff 'unit 3 done'" \
  "Unit 3 is landed and the handoff is written to disk."

export SYG_HANDOFF_CMDS='myrole --set'
check 2 "Bash handoff write + no pick token blocks" "$TMP/bash-nopick.jsonl" "" \
  'HANDOFF PICK' \
  '/clear \(unrelated next unit\)' \
  '/compact \(same thread\)' \
  'keep \(reply due within the hour; warm cache\)' \
  'never schedule wakeups to keep the cache warm' \
  'and is every owner directive from this session on disk\?' \
  'once per turn' \
  '!SYG_HANDOFF_PATHS' \
  '!SYG_HANDOFF_CMDS'

# --- 2. Same Bash handoff write + each pick token → exit 0 --------------------
mktx_bash "$TMP/bash-keep.jsonl" "myrole --set widget --handoff 'unit 3 done'" \
  "Handoff on disk. Pick: keep (reply due within the hour)."
check 0 "Bash handoff write + 'keep' passes" "$TMP/bash-keep.jsonl"

mktx_bash "$TMP/bash-compact.jsonl" "myrole --set widget --handoff 'unit 3 done'" \
  "Handoff on disk. Next-session pick: /compact (same thread)."
check 0 "Bash handoff write + '/compact' passes" "$TMP/bash-compact.jsonl"

mktx_bash "$TMP/bash-clear.jsonl" "myrole --set widget --handoff 'unit 3 done'" \
  "Handoff on disk. Recommended pick: /clear (unrelated next unit)."
check 0 "Bash handoff write + '/clear' passes" "$TMP/bash-clear.jsonl"

mktx_bash "$TMP/bash-case.jsonl" "myrole --set widget --handoff 'unit 3 done'" \
  "Handoff on disk. Keep the session warm for the follow-up."
check 0 "Bash handoff write + capitalized 'Keep' passes (case-insensitive)" "$TMP/bash-case.jsonl"

# --- 3. Word-boundary negative: 'keep' inside 'keeper' is not a pick ----------
mktx_bash "$TMP/bash-keeper.jsonl" "myrole --set widget --handoff 'unit 3 done'" \
  "Handoff on disk. That helper is a keeper for the next batch."
check 2 "'keep' inside 'keeper' is not a pick token" "$TMP/bash-keeper.jsonl"

mktx_bash "$TMP/bash-pathclear.jsonl" "myrole --set widget --handoff 'unit 3 done'" \
  "Handoff on disk. Updated src/clear/handler.ts too."
check 2 "'/clear' inside a file path is not a pick token" "$TMP/bash-pathclear.jsonl"
unset SYG_HANDOFF_CMDS

# --- 4. Handoff via Edit/Write matching SYG_HANDOFF_PATHS ---------------------
export SYG_HANDOFF_PATHS='team-roles/.*\.md$|(^|/)HANDOFF\.md$'
mktx_file "$TMP/edit-nopick.jsonl" "Edit" "/tmp/fixture/team-roles/widget.md" \
  "Updated the role file with the handoff and next steps."
check 2 "Edit matching SYG_HANDOFF_PATHS + no pick blocks" "$TMP/edit-nopick.jsonl"

mktx_file "$TMP/write-nopick.jsonl" "Write" "/tmp/fixture/proj/HANDOFF.md" \
  "Wrote HANDOFF.md for the next session."
check 2 "Write matching SYG_HANDOFF_PATHS + no pick blocks" "$TMP/write-nopick.jsonl"

mktx_file "$TMP/edit-withpick.jsonl" "Edit" "/tmp/fixture/team-roles/widget.md" \
  "Updated the role file. Pick: /clear."
check 0 "Edit matching SYG_HANDOFF_PATHS + '/clear' passes" "$TMP/edit-withpick.jsonl"

# --- 5. No handoff written this turn (tool calls exist but don't match) -------
export SYG_HANDOFF_CMDS='myrole --set'
mktx_file "$TMP/edit-other.jsonl" "Edit" "/tmp/fixture/proj/src/index.ts" \
  "Landed the parser fix; all checks pass."
check 0 "Edit to a non-matching path + no pick passes" "$TMP/edit-other.jsonl"

mktx_bash "$TMP/bash-other.jsonl" "git status --short" \
  "Working tree is clean."
check 0 "Bash command not matching SYG_HANDOFF_CMDS + no pick passes" "$TMP/bash-other.jsonl"

# Handoff written in an EARLIER turn does not trigger on the current turn.
{
  echo '{"type":"user","isMeta":null,"message":{"content":"wrap up"}}'
  echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"myrole --set widget"}}]}}'
  echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Handoff written. Pick: keep."}]}}'
  echo '{"type":"user","isMeta":null,"message":{"content":"one quick check"}}'
  echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git status"}}]}}'
  echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Working tree is clean."}]}}'
} > "$TMP/earlier-turn.jsonl"
check 0 "handoff write in an earlier turn does not trigger this turn" "$TMP/earlier-turn.jsonl"

# --- 6. stop_hook_active re-stop always allows --------------------------------
check 0 "stop_hook_active true allows the re-stop" "$TMP/bash-nopick.jsonl" true
unset SYG_HANDOFF_PATHS SYG_HANDOFF_CMDS

# --- 7. Unwired non-default paths and Bash calls stay silent → exit 0 ---------
check 0 "unwired env: Bash call with no SYG_HANDOFF_CMDS stays silent" "$TMP/bash-nopick.jsonl" "" '!.'
check 0 "unwired env: non-default path Edit stays silent" "$TMP/edit-nopick.jsonl" "" '!.'

mktx_file "$TMP/unwired-docs-role.jsonl" "Edit" "/tmp/fixture/proj/docs/roles/admin.md" \
  "Documented the admin RBAC role permissions."
check 0 "unwired env: docs/roles/admin.md write stays silent (narrowed default)" "$TMP/unwired-docs-role.jsonl" "" '!.'

export SYG_HANDOFF_PATHS="" SYG_HANDOFF_CMDS=""
check 0 "both env vars empty: non-default Bash call stays silent" "$TMP/bash-nopick.jsonl" "" '!.'
unset SYG_HANDOFF_PATHS SYG_HANDOFF_CMDS

# --- 8. Fail-open on broken ERE or missing/empty transcript -------------------
export SYG_HANDOFF_CMDS='['
check 0 "broken SYG_HANDOFF_CMDS regex fails open" "$TMP/bash-nopick.jsonl"
unset SYG_HANDOFF_CMDS

export SYG_HANDOFF_PATHS='team-roles/'
check 0 "missing transcript file fails open" "$TMP/does-not-exist.jsonl"
: > "$TMP/empty.jsonl"
check 0 "empty transcript file fails open" "$TMP/empty.jsonl"
unset SYG_HANDOFF_PATHS

# --- 9. Fire-once memory: an accounted write never re-arms ---------------------
export SYG_HANDOFF_CMDS='myrole --set'
# §1 fired on bash-nopick.jsonl and recorded the write; a poll turn-end that
# writes nothing (the today-bug: isMeta polls never bound the window) stays
# silent on re-evaluation.
check 0 "re-evaluation with no new handoff write stays silent" "$TMP/bash-nopick.jsonl" "" '!.'

# A NEW matching write past the stored offset re-arms the gate.
mktx_bash "$TMP/mem-chain.jsonl" "myrole --set widget --handoff 'unit 3 done'" \
  "Unit 3 is landed and the handoff is written to disk."
check 2 "memory chain: fresh write, first fire" "$TMP/mem-chain.jsonl"
{
  echo '{"type":"user","isMeta":true,"message":{"content":"[Cron] poll the worker"}}'
  echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"myrole --set widget --handoff unit-4-done"}}]}}'
  echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Polled; handoff updated for unit 4."}]}}'
} >> "$TMP/mem-chain.jsonl"
check 2 "a NEW handoff write past the stored offset fires again" "$TMP/mem-chain.jsonl"
check 0 "and the advanced state absorbs the next poll turn-end" "$TMP/mem-chain.jsonl" "" '!.'

# A pick-accompanied write is accounted too (not only fires): the poll
# turn-ends absorbed after it must not re-arm the gate.
mktx_bash "$TMP/pick-then-poll.jsonl" "myrole --set widget --handoff 'unit 3 done'" \
  "Handoff on disk. Pick: keep."
check 0 "pick-accompanied write passes (and is accounted)" "$TMP/pick-then-poll.jsonl"
{
  echo '{"type":"user","isMeta":true,"message":{"content":"[Cron] poll the worker"}}'
  echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Polled; nothing new to report."}]}}'
} >> "$TMP/pick-then-poll.jsonl"
check 0 "absorbed poll turn-end after a picked write stays silent" "$TMP/pick-then-poll.jsonl" "" '!.'

# --- 10. isMeta cron prompts do not bound the turn ------------------------------
# The write stays in the window across the isMeta entry, so the gate fires on
# the poll's pickless closing — pins the boundary rule itself (were isMeta a
# boundary, the poll turn alone has no write and would pass).
mktx_bash "$TMP/cron-boundary.jsonl" "myrole --set widget --handoff 'unit 3 done'" \
  "Unit 3 is landed and the handoff is written to disk."
{
  echo '{"type":"user","isMeta":true,"message":{"content":"[Cron] poll the worker"}}'
  echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Polled; nothing new to report."}]}}'
} >> "$TMP/cron-boundary.jsonl"
check 2 "isMeta cron prompt does not bound the turn (write stays in window)" "$TMP/cron-boundary.jsonl"

# --- 11. State failures fail open ----------------------------------------------
mkdir -p "$XDG_STATE_HOME/seyag/handoff-pick-check"
echo 'not-a-number' > "$XDG_STATE_HOME/seyag/handoff-pick-check/bash-nopick.jsonl.offset"
check 2 "corrupt state content fails open (fires)" "$TMP/bash-nopick.jsonl"

: > "$TMP/state-not-a-dir"  # a regular file where the state dir must go
XDG_STATE_HOME="$TMP/state-not-a-dir"
export XDG_STATE_HOME
check 2 "unwritable state dir still fires (fail-open)" "$TMP/bash-nopick.jsonl" "" \
  'HANDOFF PICK' '!Traceback'
export XDG_STATE_HOME="$TMP/state"
unset SYG_HANDOFF_CMDS

# --- 12. Unwired-state fallback: default handoff write + setup hint -----------
unset SYG_HANDOFF_PATHS SYG_HANDOFF_CMDS
mktx_file "$TMP/unwired-handoff-nopick.jsonl" "Write" "/tmp/fixture/proj/HANDOFF.md" \
  "Wrote HANDOFF.md for the next session."
check 2 "unwired env: default HANDOFF.md write + no pick blocks with banner + setup hint" \
  "$TMP/unwired-handoff-nopick.jsonl" "" \
  'HANDOFF PICK' \
  '/clear \(unrelated next unit\)' \
  'SYG_HANDOFF_PATHS' \
  'SYG_HANDOFF_CMDS'

mktx_file "$TMP/unwired-lower-nopick.jsonl" "Write" "/tmp/fixture/proj/handoff.md" \
  "Wrote handoff.md for the next session."
check 2 "unwired env: default lowercase handoff.md write + no pick blocks with banner + setup hint" \
  "$TMP/unwired-lower-nopick.jsonl" "" \
  'HANDOFF PICK' \
  'SYG_HANDOFF_PATHS' \
  'SYG_HANDOFF_CMDS'

mktx_file "$TMP/unwired-role-nopick.jsonl" "Edit" "/tmp/fixture/notes/roles/widget.md" \
  "Updated the role handoff for the next session."
check 0 "unwired env: roles/*.md write stays silent unless SYG_HANDOFF_PATHS wires it" \
  "$TMP/unwired-role-nopick.jsonl" "" '!.'

mktx_file "$TMP/unwired-handoff-pick.jsonl" "Write" "/tmp/fixture/proj/HANDOFF.md" \
  "Wrote HANDOFF.md for the next session. Pick: /clear."
check 0 "unwired env: default HANDOFF.md write + pick token passes" \
  "$TMP/unwired-handoff-pick.jsonl" "" '!.'

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
