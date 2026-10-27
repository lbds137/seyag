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
mktx_file() { # $1=out $2=tool_name $3=file_path $4=text [$5=new_string/content [$6=old_string]]
  local body="${5-$'## Handoff\nnext steps'}" old="${6-}"
  : > "$1"
  echo '{"type":"user","isMeta":null,"message":{"content":"go"}}' >> "$1"
  if [ "$2" = "Write" ]; then
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"%s","input":{"file_path":%s,"content":%s}}]}}\n' \
      "$2" "$(jsonstr "$3")" "$(jsonstr "$body")" >> "$1"
  else
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"%s","input":{"file_path":%s,"old_string":%s,"new_string":%s}}]}}\n' \
      "$2" "$(jsonstr "$3")" "$(jsonstr "$old")" "$(jsonstr "$body")" >> "$1"
  fi
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":%s}]}}\n' "$(jsonstr "$4")" >> "$1"
}

mkfile() { mkdir -p "$(dirname "$1")" && printf '%s' "$2" > "$1"; }

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
unset SYG_HANDOFF_PATHS SYG_HANDOFF_CMDS SYG_HANDOFF_SECTIONS
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
  'SYG_HANDOFF_CMDS' \
  'HANDOFF\\\.md\|handoff\\\.md'

mktx_file "$TMP/unwired-lower-nopick.jsonl" "Write" "/tmp/fixture/proj/handoff.md" \
  "Wrote handoff.md for the next session."
check 2 "unwired env: default lowercase handoff.md write + no pick blocks with banner + setup hint" \
  "$TMP/unwired-lower-nopick.jsonl" "" \
  'HANDOFF PICK' \
  'SYG_HANDOFF_PATHS' \
  'SYG_HANDOFF_CMDS' \
  'HANDOFF\\\.md\|handoff\\\.md'

mktx_file "$TMP/unwired-role-nopick.jsonl" "Edit" "/tmp/fixture/notes/roles/widget.md" \
  "Updated the role handoff for the next session."
check 0 "unwired env: roles/*.md write stays silent unless SYG_HANDOFF_PATHS wires it" \
  "$TMP/unwired-role-nopick.jsonl" "" '!.'

mktx_file "$TMP/unwired-handoff-pick.jsonl" "Write" "/tmp/fixture/proj/HANDOFF.md" \
  "Wrote HANDOFF.md for the next session. Pick: /clear."
check 0 "unwired env: default HANDOFF.md write + pick token passes" \
  "$TMP/unwired-handoff-pick.jsonl" "" '!.'

# Setting EITHER env var replaces (does not extend) the built-in path defaults:
# with only SYG_HANDOFF_CMDS set, a write to HANDOFF.md does not trip DEFAULT_HANDOFF_PATHS.
export SYG_HANDOFF_CMDS='myrole --set'
mktx_file "$TMP/cmds-only-handoff-nopick.jsonl" "Write" "/tmp/fixture/proj/HANDOFF.md" \
  "Wrote HANDOFF.md for the next session."
check 0 "replace semantics: only SYG_HANDOFF_CMDS set drops the HANDOFF.md path default" \
  "$TMP/cmds-only-handoff-nopick.jsonl" "" '!.'
unset SYG_HANDOFF_CMDS

# --- 13. Stop envelope last_assistant_message (transcript lag) ----------------
export SYG_HANDOFF_CMDS='myrole --set'
{
  echo '{"type":"user","isMeta":null,"message":{"content":"go"}}'
  echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"myrole --set widget --handoff '\''unit 3 done'\''"}}]}}'
} > "$TMP/lag-pick.jsonl"
echo "{\"stop_hook_active\":false,\"transcript_path\":\"$TMP/lag-pick.jsonl\",\"last_assistant_message\":\"Handoff on disk. Pick: keep.\"}" \
  | bash "$HOOK" >/dev/null 2>"$TMP/stderr.out"
got=$?
if [ "$got" != 0 ] || grep -q Traceback "$TMP/stderr.out"; then echo "FAIL [$got≠0]: last_assistant_message pick passes when transcript lacks closing text"; fail=1
else echo "ok   [0]: last_assistant_message pick passes when transcript lacks closing text"; fi

{
  echo '{"type":"user","isMeta":null,"message":{"content":"go"}}'
  echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"myrole --set widget --handoff '\''unit 3 done'\''"}}]}}'
} > "$TMP/lag-nopick.jsonl"
echo "{\"stop_hook_active\":false,\"transcript_path\":\"$TMP/lag-nopick.jsonl\",\"last_assistant_message\":\"Unit 3 is landed and the handoff is written to disk.\"}" \
  | bash "$HOOK" >/dev/null 2>"$TMP/stderr.out"
got=$?
if [ "$got" != 2 ] || grep -q Traceback "$TMP/stderr.out"; then echo "FAIL [$got≠2]: last_assistant_message without pick still blocks when transcript lacks closing text"; fail=1
else echo "ok   [2]: last_assistant_message without pick still blocks when transcript lacks closing text"; fi

# Empty LAM (older payloads) falls back to the transcript closing.
{
  echo '{"type":"user","isMeta":null,"message":{"content":"go"}}'
  echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"myrole --set widget --handoff '\''unit 3 done'\''"}}]}}'
  echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Handoff on disk. Pick: /clear for the next unit."}]}}'
} > "$TMP/empick.jsonl"
echo "{\"stop_hook_active\":false,\"transcript_path\":\"$TMP/empick.jsonl\",\"last_assistant_message\":\"\"}" \
  | bash "$HOOK" >/dev/null 2>"$TMP/stderr.out"
got=$?
if [ "$got" != 0 ] || grep -q Traceback "$TMP/stderr.out"; then echo "FAIL [$got≠0]: empty last_assistant_message falls back to the transcript closing"; fail=1
else echo "ok   [0]: empty last_assistant_message falls back to the transcript closing"; fi

# A truncated LAM (the harness's "… [+N chars]" suffix) with the pick cut
# still blocks: the accepted fail-closed residual (header note). Fresh
# transcript: a reused one is already accounted for by the fire-once offset.
{
  echo '{"type":"user","isMeta":null,"message":{"content":"go"}}'
  echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"myrole --set widget --handoff '\''unit 3 done'\''"}}]}}'
} > "$TMP/lag-trunc.jsonl"
echo "{\"stop_hook_active\":false,\"transcript_path\":\"$TMP/lag-trunc.jsonl\",\"last_assistant_message\":\"Handoff on disk. Pick: k… [+40 chars]\"}" \
  | bash "$HOOK" >/dev/null 2>"$TMP/stderr.out"
got=$?
if [ "$got" != 2 ] || grep -q Traceback "$TMP/stderr.out"; then echo "FAIL [$got≠2]: truncated last_assistant_message with the pick cut still blocks"; fail=1
else echo "ok   [2]: truncated last_assistant_message with the pick cut still blocks"; fi
unset SYG_HANDOFF_CMDS

# --- 14. Section narrowing (SYG_HANDOFF_SECTIONS) -----------------------------
export SYG_HANDOFF_PATHS='team-roles/.*\.md$'
mkfile "$TMP/team-roles/widget.md" $'# Widget\n\n## Needs Owner\n- first bullet\n\n## Next\n- ship unit 4\n'
mktx_file "$TMP/sec-fp-nonhandoff.jsonl" "Edit" "$TMP/team-roles/widget.md" \
  "Added one bullet to the non-handoff section." \
  $'## Needs Owner\n- first bullet\n- added bullet' \
  $'## Needs Owner\n- first bullet'
check 0 "FP-class: wired Edit to non-handoff section (## Needs Owner bullet) + no pick passes" \
  "$TMP/sec-fp-nonhandoff.jsonl"

mktx_file "$TMP/sec-edit-new-handoff.jsonl" "Edit" "/tmp/fixture/team-roles/widget.md" \
  "Updated the handoff section." \
  $'## Handoff\n- ship unit 4' "old bullet"
check 2 "wired Edit with ## Handoff in new_string + no pick blocks" \
  "$TMP/sec-edit-new-handoff.jsonl"

mktx_file "$TMP/sec-edit-old-next.jsonl" "Edit" "/tmp/fixture/team-roles/widget.md" \
  "Cleared the next steps section." \
  "- done" $'## Next\n- ship unit 4'
check 2 "wired Edit with ## Next in old_string (section rewrite) + no pick blocks" \
  "$TMP/sec-edit-old-next.jsonl"

mktx_file "$TMP/sec-write-next.jsonl" "Write" "/tmp/fixture/team-roles/widget.md" \
  "Wrote the role file." \
  $'# Widget\n\n## Next\n- ship unit 4'
check 2 "wired Write with ## Next in content + no pick blocks" \
  "$TMP/sec-write-next.jsonl"

mktx_file "$TMP/sec-write-nohead.jsonl" "Write" "/tmp/fixture/team-roles/widget.md" \
  "Wrote plain notes." \
  "plain body without any matching section heading"
check 0 "wired Write with heading-free content + no pick passes" \
  "$TMP/sec-write-nohead.jsonl"

{
  echo '{"type":"user","isMeta":null,"message":{"content":"go"}}'
  echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"MultiEdit","input":{"file_path":"/tmp/fixture/team-roles/widget.md","edits":[{"old_string":"- a","new_string":"- b"},{"old_string":"old","new_string":"## Next\n- ship unit 4"}]}}]}}'
  echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Applied multi-edit."}]}}'
} > "$TMP/sec-multiedit-hit.jsonl"
check 2 "wired MultiEdit with one edits[] item carrying ## Next + no pick blocks" \
  "$TMP/sec-multiedit-hit.jsonl"

mkfile "$TMP/team-roles/widget.md" $'# Widget\n\n## Needs Owner\n- a\n- b\n- c\n- d\n'
{
  echo '{"type":"user","isMeta":null,"message":{"content":"go"}}'
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"MultiEdit","input":{"file_path":%s,"edits":[{"old_string":"- a","new_string":"- b"},{"old_string":"- c","new_string":"- d"}]}}]}}\n' \
    "$(jsonstr "$TMP/team-roles/widget.md")"
  echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Applied multi-edit to bullets."}]}}'
} > "$TMP/sec-multiedit-miss.jsonl"
check 0 "wired MultiEdit with no edits[] item carrying a section + no pick passes" \
  "$TMP/sec-multiedit-miss.jsonl"

{
  echo '{"type":"user","isMeta":null,"message":{"content":"go"}}'
  echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"NotebookEdit","input":{"notebook_path":"/tmp/fixture/team-roles/widget.md","new_source":"## Handoff\n- notebook state"}}]}}'
  echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Updated notebook cell."}]}}'
} > "$TMP/sec-notebook-hit.jsonl"
check 2 "wired NotebookEdit with new_source carrying ## Handoff + no pick blocks" \
  "$TMP/sec-notebook-hit.jsonl"

{
  echo '{"type":"user","isMeta":null,"message":{"content":"go"}}'
  echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"NotebookEdit","input":{"notebook_path":"/tmp/fixture/team-roles/widget.md","new_source":"print(42)"}}]}}'
  echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Updated notebook code cell."}]}}'
} > "$TMP/sec-notebook-miss.jsonl"
check 0 "wired NotebookEdit without handoff section + no pick passes" \
  "$TMP/sec-notebook-miss.jsonl"

export SYG_HANDOFF_SECTIONS='^## Status\b'
mktx_file "$TMP/sec-custom-hit.jsonl" "Edit" "/tmp/fixture/team-roles/widget.md" \
  "Updated status section." \
  $'## Status\n- green' "old"
check 2 "custom SYG_HANDOFF_SECTIONS: Edit touching ## Status blocks" \
  "$TMP/sec-custom-hit.jsonl"

mkfile "$TMP/team-roles/widget.md" $'# Widget\n\n## Needs Owner\n- first bullet\n\n## Next\n- item\n- ship unit 4\n'
mktx_file "$TMP/sec-custom-replaces-default.jsonl" "Edit" "$TMP/team-roles/widget.md" \
  "Updated next section." \
  $'## Next\n- item' "old"
check 0 "custom SYG_HANDOFF_SECTIONS replaces default: Edit touching only ## Next passes" \
  "$TMP/sec-custom-replaces-default.jsonl"
unset SYG_HANDOFF_SECTIONS

export SYG_HANDOFF_SECTIONS=""
mktx_file "$TMP/sec-empty-disables.jsonl" "Edit" "/tmp/fixture/team-roles/widget.md" \
  "Added one bullet to the non-handoff section." \
  $'## Needs Owner\n- first bullet\n- added bullet' \
  $'## Needs Owner\n- first bullet'
check 2 "empty SYG_HANDOFF_SECTIONS disables narrowing: non-handoff Edit blocks" \
  "$TMP/sec-empty-disables.jsonl"
unset SYG_HANDOFF_SECTIONS

export SYG_HANDOFF_SECTIONS='['
mktx_file "$TMP/sec-broken-regex.jsonl" "Edit" "/tmp/fixture/team-roles/widget.md" \
  "Updated handoff section." \
  $'## Handoff\n- ship unit 4' "old"
check 0 "broken SYG_HANDOFF_SECTIONS regex fails open" \
  "$TMP/sec-broken-regex.jsonl" "" '!Traceback'
unset SYG_HANDOFF_SECTIONS SYG_HANDOFF_PATHS

export SYG_HANDOFF_PATHS='team-roles/.*\.md$'
export SYG_HANDOFF_CMDS='myrole --set'
mktx_bash "$TMP/sec-bash-untouched.jsonl" "myrole --set widget --handoff 'unit 5 done'" \
  "Handoff recorded via CLI."
check 2 "Bash branch untouched by default section narrowing: SYG_HANDOFF_CMDS still blocks" \
  "$TMP/sec-bash-untouched.jsonl"
unset SYG_HANDOFF_CMDS SYG_HANDOFF_PATHS

unset SYG_HANDOFF_PATHS SYG_HANDOFF_CMDS SYG_HANDOFF_SECTIONS
mktx_file "$TMP/sec-unwired-headingfree.jsonl" "Write" "/tmp/fixture/proj/HANDOFF.md" \
  "Wrote HANDOFF.md for the next session." \
  "Plain handoff notes with no markdown section headings at all."
check 2 "unwired built-in HANDOFF.md Write with heading-free content still blocks with setup hint" \
  "$TMP/sec-unwired-headingfree.jsonl" "" \
  'HANDOFF PICK' \
  'SYG_HANDOFF_PATHS' \
  'SYG_HANDOFF_CMDS'

# --- 15. Round-1 refinements: broken SECTIONS vs CMDS, built-in path exemption ---
export SYG_HANDOFF_PATHS='team-roles/.*\.md$' SYG_HANDOFF_CMDS='myrole --set' SYG_HANDOFF_SECTIONS='['
mktx_bash "$TMP/r1-broken-cmds.jsonl" "myrole --set widget --handoff 'unit 5 done'" \
  "Handoff recorded via CLI."
check 2 "broken SYG_HANDOFF_SECTIONS disables file branch only; SYG_HANDOFF_CMDS still blocks" \
  "$TMP/r1-broken-cmds.jsonl"
unset SYG_HANDOFF_CMDS

mktx_file "$TMP/r1-broken-file.jsonl" "Edit" "/tmp/fixture/team-roles/widget.md" \
  "Updated handoff section." \
  $'## Handoff\n- ship unit 5' "old"
check 0 "broken SYG_HANDOFF_SECTIONS with CMDS unset leaves file branch inert" \
  "$TMP/r1-broken-file.jsonl" "" '!Traceback'
unset SYG_HANDOFF_PATHS SYG_HANDOFF_SECTIONS

export SYG_HANDOFF_PATHS='(^|/)(?:HANDOFF\.md|handoff\.md)$'
mktx_file "$TMP/r2-built-in-wired.jsonl" "Write" "/tmp/fixture/proj/HANDOFF.md" \
  "Wrote HANDOFF.md for the next session." \
  "Plain handoff notes with no markdown section headings at all."
check 2 "wired built-in HANDOFF.md path stays path-only (heading-free Write blocks)" \
  "$TMP/r2-built-in-wired.jsonl"

mktx_file "$TMP/r2-built-in-still-fp.jsonl" "Edit" "/tmp/fixture/team-roles/widget.md" \
  "Updated role file." \
  $'## Handoff\n- ship unit 5' "old"
check 0 "wired built-in pattern does not match non-default role path (control)" \
  "$TMP/r2-built-in-still-fp.jsonl"
unset SYG_HANDOFF_PATHS

export SYG_HANDOFF_PATHS='team-roles/.*\.md$'
mkfile "$TMP/team-roles/widget.md" $'# Widget\n\n## Needs Owner\n- b1\n\n## Next\n- ship unit 4\n'
mktx_file "$TMP/r3-insection.jsonl" "Edit" "$TMP/team-roles/widget.md" \
  "Updated handoff bullet." \
  "- unit 4 shipped; next: unit 5" "- ship unit 4"
check 2 "r3-insection: deliberate old_string-fallback pin (pre-edit file: old_string present, new_string absent)" \
  "$TMP/r3-insection.jsonl"
unset SYG_HANDOFF_PATHS

# --- 16. Disk-based section resolution (locator) ------------------------------
export SYG_HANDOFF_PATHS='r4-roles/.*\.md$'
mkfile "$TMP/r4-roles/widget.md" $'# Widget\n\n## Needs Owner\n- b1\n\n## Next\n- unit 4 shipped; next: unit 5\n'
mktx_file "$TMP/r4-locator-fire.jsonl" "Edit" "$TMP/r4-roles/widget.md" \
  "Updated handoff bullet." \
  "- unit 4 shipped; next: unit 5" "- ship unit 4"
check 2 "r4-locator-fire: in-section Edit under ## Next on disk + no pick blocks" \
  "$TMP/r4-locator-fire.jsonl"

mkfile "$TMP/r4-roles/widget.md" $'# Widget\n\n## Needs Owner\n- b1 confirmed\n\n## Next\n- ship unit 4\n'
mktx_file "$TMP/r4-locator-pass.jsonl" "Edit" "$TMP/r4-roles/widget.md" \
  "Confirmed bullet under non-handoff section." \
  "- b1 confirmed" "- b1"
check 0 "r4-locator-pass: in-section Edit under ## Needs Owner on disk + no pick passes" \
  "$TMP/r4-locator-pass.jsonl"

mktx_file "$TMP/r4-missing-file.jsonl" "Edit" "$TMP/r4-roles/missing.md" \
  "Edited a file no longer on disk." \
  "- new line" "- old line"
check 2 "r4-missing-file: wired Edit to missing file on disk fails closed (blocks)" \
  "$TMP/r4-missing-file.jsonl"

mkfile "$TMP/r4-roles/rewritten.md" $'# Widget\n\n## Needs Owner\n- completely rewritten section\n'
mktx_file "$TMP/r4-not-found.jsonl" "Edit" "$TMP/r4-roles/rewritten.md" \
  "Edited a region later rewritten." \
  "- gone new" "- gone old"
check 2 "r4-not-found: wired Edit whose old/new strings are absent from disk fails closed (blocks)" \
  "$TMP/r4-not-found.jsonl"

mktx_file "$TMP/r4-short-circuit.jsonl" "Edit" "$TMP/r4-roles/widget.md" \
  "Updated next section with heading." \
  $'## Next\n- ship unit 5' "- ship unit 4"
check 2 "r4-short-circuit: wired Edit carrying ## Next in new_string blocks via short-circuit" \
  "$TMP/r4-short-circuit.jsonl"

mkfile "$TMP/r4-roles/widget.md" $'# Widget\n\n## Needs Owner\n- b1 confirmed\n\n## Next\n- unit 4 shipped; next: unit 5\n'
{
  echo '{"type":"user","isMeta":null,"message":{"content":"go"}}'
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"MultiEdit","input":{"file_path":%s,"edits":[{"old_string":"- b1","new_string":"- b1 confirmed"},{"old_string":"- ship unit 4","new_string":"- unit 4 shipped; next: unit 5"}]}}]}}\n' \
    "$(jsonstr "$TMP/r4-roles/widget.md")"
  echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Applied multi-edit to role file."}]}}'
} > "$TMP/r4-multiedit.jsonl"
check 2 "r4-multiedit: wired MultiEdit with one in-section item under ## Next on disk + no pick blocks" \
  "$TMP/r4-multiedit.jsonl"

mkfile "$TMP/r4-roles/priority.md" $'# Widget\n\n## Needs Owner\n- ship unit 4\n\n## Next\n- unit 4 shipped\n'
mktx_file "$TMP/r4-priority.jsonl" "Edit" "$TMP/r4-roles/priority.md" \
  "Moved the bullet between sections." \
  "- unit 4 shipped" "- ship unit 4"
check 2 "r4-priority: both strings on disk under different sections resolve new_string first" \
  "$TMP/r4-priority.jsonl"

mkfile "$TMP/r4-roles/delete-pass.md" $'# Widget\n\n## Needs Owner\n'
mktx_file "$TMP/r4-delete-pass.jsonl" "Edit" "$TMP/r4-roles/delete-pass.md" \
  "Removed obsolete bullet." \
  "" "- b1"
check 0 "r4-delete-pass: unlocatable deletion (old_string absent post-edit) passes (deletion residual)" \
  "$TMP/r4-delete-pass.jsonl"

mkfile "$TMP/r4-roles/delete-fire.md" $'# Widget\n\n## Needs Owner\n- b1\n\n## Next\n- duplicated line\n'
mktx_file "$TMP/r4-delete-fire.jsonl" "Edit" "$TMP/r4-roles/delete-fire.md" \
  "Removed duplicate bullet." \
  "" "- duplicated line"
check 2 "r4-delete-fire: deletion whose old_string still appears under ## Next on disk blocks" \
  "$TMP/r4-delete-fire.jsonl"

mkfile "$TMP/r4-roles/newstring-pass.md" $'# Widget\n\n## Needs Owner\n- b1 confirmed\n\n## Next\n- ship unit 4\n'
mktx_file "$TMP/r4-newstring-pass.jsonl" "Edit" "$TMP/r4-roles/newstring-pass.md" \
  "Replaced bullet under non-handoff section." \
  "- b1 confirmed" "- gone"
check 0 "r4-newstring-pass: found new_string under ## Needs Owner dominates missing old_string and passes" \
  "$TMP/r4-newstring-pass.jsonl"
unset SYG_HANDOFF_PATHS

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
