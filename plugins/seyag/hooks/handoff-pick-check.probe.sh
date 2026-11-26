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
# Emitter mode (SYG_PICK_CMD, section 17): when the machine names a pick
# command, the pick counts only when the turn ran it (`<cmd> clear|compact|keep`)
# after the handoff write; pick words in the closing text do not count, and a
# mention (grep, echo, --help), an earlier call, an errored call or a call to
# another command does not either. Empty or multi-line values keep the text match.
# Section 18 covers the stale-pick trigger: a turn that a task-notification started,
# with an earlier clear or compact pick and no pick of its own, blocks once per turn
# start (the .stale state file).
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
check() { # $1=expected_exit $2=label $3=transcript $4=stop_active $5+=stderr regexes (CHECK_LAM optional)
  # Each regex must match the captured stderr; a regex prefixed with "!" must NOT.
  local lam_field=""
  [ -n "${CHECK_LAM+x}" ] && lam_field=",\"last_assistant_message\":$(jsonstr "$CHECK_LAM")"
  echo "{\"stop_hook_active\":${4:-false},\"transcript_path\":\"$3\"$lam_field}" | bash "$HOOK" >/dev/null 2>"$TMP/stderr.out"
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
unset SYG_HANDOFF_PATHS SYG_HANDOFF_CMDS SYG_HANDOFF_SECTIONS SYG_PICK_CMD
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

# --- 17. SYG_PICK_CMD emitter mode --------------------------------------------
# The pick counts only when the turn ran the named command after the handoff
# write (same record or later). Tool calls are paired with their results by id.
export SYG_HANDOFF_CMDS='myrole --set' SYG_PICK_CMD='pick-note'
tx_user() { printf '%s\n' '{"type":"user","isMeta":null,"message":{"content":"go"}}' >> "$1"; }
tx_bash() { # $1=out $2=tool_use id $3=command
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":%s,"name":"Bash","input":{"command":%s}}]}}\n' \
    "$(jsonstr "$2")" "$(jsonstr "$3")" >> "$1"
}
tx_result() { # $1=out $2=tool_use id [$3=true marks is_error]
  local err=""
  [ "${3:-}" = true ] && err=',"is_error":true'
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":%s,"content":"done"%s}]}}\n' \
    "$(jsonstr "$2")" "$err" >> "$1"
}
tx_text() { # $1=out $2=text
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":%s}]}}\n' "$(jsonstr "$2")" >> "$1"
}
HANDOFF_CALL="myrole --set widget --handoff 'unit 3 done'"

f="$TMP/pick-run-later.jsonl"; : > "$f"; tx_user "$f"
tx_bash "$f" t1 "$HANDOFF_CALL"; tx_result "$f" t1
tx_bash "$f" t2 "pick-note clear"; tx_result "$f" t2
tx_text "$f" "Unit 3 is landed and the handoff is on disk."
check 0 "emitter: handoff write, then 'pick-note clear' run, closing without pick words passes" "$f"

f="$TMP/pick-text-only.jsonl"; : > "$f"; tx_user "$f"
tx_bash "$f" t1 "$HANDOFF_CALL"; tx_result "$f" t1
tx_text "$f" "Handoff on disk. Pick: /clear."
check 2 "emitter: closing 'Pick: /clear' with no emitter call blocks, naming pick-note" "$f" "" \
  'handoff written without running the pick command' \
  'pick-note clear\|compact\|keep' \
  '!without a next-session pick'

f="$TMP/pick-same-record.jsonl"; : > "$f"; tx_user "$f"
tx_bash "$f" t1 "$HANDOFF_CALL && pick-note keep"; tx_result "$f" t1
tx_text "$f" "Handoff on disk."
check 0 "emitter: same record '<handoff> && pick-note keep' passes" "$f"

f="$TMP/pick-cd-later.jsonl"; : > "$f"; tx_user "$f"
tx_bash "$f" t1 "$HANDOFF_CALL"; tx_result "$f" t1
tx_bash "$f" t2 "cd /x && pick-note compact"; tx_result "$f" t2
tx_text "$f" "Handoff on disk."
check 0 "emitter: later record 'cd /x && pick-note compact' passes" "$f"

# Mentions are not calls: argv[0] must be the command.
pick_mention_tx() { # $1=out $2=command
  : > "$1"; tx_user "$1"
  tx_bash "$1" t1 "$HANDOFF_CALL"; tx_result "$1" t1
  tx_bash "$1" t2 "$2"; tx_result "$1" t2
  tx_text "$1" "Handoff on disk."
}
pick_mention_tx "$TMP/pick-mention-grep.jsonl" "grep pick-note file"
check 2 "emitter: 'grep pick-note file' is a mention, not a call" "$TMP/pick-mention-grep.jsonl"
pick_mention_tx "$TMP/pick-mention-echo.jsonl" "echo pick-note clear"
check 2 "emitter: 'echo pick-note clear' is a mention, not a call" "$TMP/pick-mention-echo.jsonl"
pick_mention_tx "$TMP/pick-mention-help.jsonl" "pick-note --help"
check 2 "emitter: 'pick-note --help' is not a call" "$TMP/pick-mention-help.jsonl"

f="$TMP/pick-before-write.jsonl"; : > "$f"; tx_user "$f"
tx_bash "$f" t0 "pick-note keep"; tx_result "$f" t0
tx_bash "$f" t1 "$HANDOFF_CALL"; tx_result "$f" t1
tx_text "$f" "Handoff on disk."
check 2 "emitter: call before the handoff write does not count" "$f"

f="$TMP/pick-errored.jsonl"; : > "$f"; tx_user "$f"
tx_bash "$f" t1 "$HANDOFF_CALL"; tx_result "$f" t1
tx_bash "$f" t2 "pick-note clear"; tx_result "$f" t2 true
tx_text "$f" "Handoff on disk."
check 2 "emitter: call whose tool_result carries is_error does not count" "$f"

export SYG_PICK_CMD='pick-note --fleet'
f="$TMP/pick-fleet-ok.jsonl"; : > "$f"; tx_user "$f"
tx_bash "$f" t1 "$HANDOFF_CALL"; tx_result "$f" t1
tx_bash "$f" t2 "pick-note --fleet clear"; tx_result "$f" t2
tx_text "$f" "Handoff on disk."
check 0 "multi-word SYG_PICK_CMD: 'pick-note --fleet clear' passes" "$f"

f="$TMP/pick-fleet-short.jsonl"; : > "$f"; tx_user "$f"
tx_bash "$f" t1 "$HANDOFF_CALL"; tx_result "$f" t1
tx_bash "$f" t2 "pick-note clear"; tx_result "$f" t2
tx_text "$f" "Handoff on disk."
check 2 "multi-word SYG_PICK_CMD: bare 'pick-note clear' (missing --fleet) does not count" "$f"
export SYG_PICK_CMD='pick-note'

f="$TMP/pick-path-form.jsonl"; : > "$f"; tx_user "$f"
tx_bash "$f" t1 "$HANDOFF_CALL"; tx_result "$f" t1
tx_bash "$f" t2 "/opt/bin/pick-note keep"; tx_result "$f" t2
tx_text "$f" "Handoff on disk."
check 0 "path-form emitter: '/opt/bin/pick-note keep' matches on basename" "$f"

export SYG_PICK_CMD=''
mktx_bash "$TMP/pick-empty-text.jsonl" "$HANDOFF_CALL" "Handoff on disk. Pick: /clear."
check 0 "empty SYG_PICK_CMD: text pick '/clear' still passes" "$TMP/pick-empty-text.jsonl"
mktx_bash "$TMP/pick-empty-none.jsonl" "$HANDOFF_CALL" "Unit 3 is landed."
check 2 "empty SYG_PICK_CMD: no pick still blocks with the old title" "$TMP/pick-empty-none.jsonl" "" \
  'handoff written without a next-session pick' '!pick-note'

export SYG_PICK_CMD=$'pick-note\nevil'
mktx_bash "$TMP/pick-nl-text.jsonl" "$HANDOFF_CALL" "Handoff on disk. Pick: /clear."
check 0 "multi-line SYG_PICK_CMD: text pick '/clear' still passes" "$TMP/pick-nl-text.jsonl"
mktx_bash "$TMP/pick-nl-none.jsonl" "$HANDOFF_CALL" "Unit 3 is landed."
check 2 "multi-line SYG_PICK_CMD: no pick still blocks with the old title" "$TMP/pick-nl-none.jsonl" "" \
  'handoff written without a next-session pick' '!handoff written without running the pick command'

# Order within one record is not checked (accepted, see the hook header). The
# multi-line value above is still exported, so restore the single-word command.
export SYG_PICK_CMD='pick-note'
f="$TMP/pick-before-handoff-same-record.jsonl"; : > "$f"; tx_user "$f"
tx_bash "$f" t1 "pick-note keep && $HANDOFF_CALL"; tx_result "$f" t1
tx_text "$f" "Handoff on disk."
check 0 "emitter: pick before the handoff inside one record counts (order within a record unchecked, accepted)" "$f"

# Mode agreement with session-start.sh: whitespace-only is unset in both; any
# other single-line value is emitter mode, even one shlex cannot split.
export SYG_PICK_CMD='   '
mktx_bash "$TMP/pick-blank-text.jsonl" "$HANDOFF_CALL" "Handoff on disk. Pick: /clear."
check 0 "whitespace-only SYG_PICK_CMD: text mode (text pick passes)" "$TMP/pick-blank-text.jsonl"
export SYG_PICK_CMD='pick-note "x'
mktx_bash "$TMP/pick-unbal.jsonl" "$HANDOFF_CALL" "Handoff on disk. Pick: /clear."
check 2 "unbalanced-quote SYG_PICK_CMD: still emitter mode (text pick does not count)" "$TMP/pick-unbal.jsonl" "" \
  'handoff written without running the pick command'
export SYG_PICK_CMD="''"
f="$TMP/pick-emptyword.jsonl"; : > "$f"; tx_user "$f"
tx_bash "$f" t1 "$HANDOFF_CALL"; tx_result "$f" t1
tx_bash "$f" t2 "pick-note clear"; tx_result "$f" t2
tx_text "$f" "Handoff on disk."
check 2 "quoted-empty SYG_PICK_CMD: matches no call, blocks in emitter mode" "$f" "" \
  'handoff written without running the pick command'
unset SYG_PICK_CMD SYG_HANDOFF_CMDS

# --- 18. Stale-pick trigger: a notification-started turn that ends without a pick ---
# Section 18 runs with SYG_PICK_CMD=pick-note, and each case that can fire gets its
# own XDG_STATE_HOME (the fire-once .stale file lives there); cases 1 and 3 share one
# state dir on purpose, and cases 3 and 4 reuse case 1's transcript.
tx_notif() { # $1=out $2=task id: a task-notification turn start (origin kind)
  local body
  body=$(printf '<task-notification>\n<task-id>%s</task-id>\n<status>completed</status>\n</task-notification>' "$2")
  printf '{"type":"user","isMeta":null,"origin":{"kind":"task-notification"},"message":{"content":%s}}\n' \
    "$(jsonstr "$body")" >> "$1"
}
tx_human() { printf '%s\n' '{"type":"user","isMeta":null,"origin":{"kind":"human"},"message":{"content":"go"}}' >> "$1"; }
export SYG_PICK_CMD='pick-note'
unset SYG_HANDOFF_CMDS SYG_HANDOFF_PATHS

# Base: a human turn, a clear pick, a closing text, then a notification turn that ends.
S18="$TMP/s18-base.jsonl"; : > "$S18"; tx_human "$S18"
tx_bash "$S18" t1 "pick-note clear"; tx_result "$S18" t1
tx_text "$S18" "Done."
tx_notif "$S18" b1
tx_text "$S18" "b1 finished; nothing else to do."

XDG_STATE_HOME="$TMP/state18-1" check 2 "stale-pick: base notification turn blocks once" "$S18" "" \
  'the pick went stale on a notification turn' 'pick-note clear\|compact\|keep' 'SYG_DISABLE=stale-pick'

# Case 2: the notification turn re-runs the pick before its text.
f="$TMP/s18-2.jsonl"; : > "$f"; tx_human "$f"
tx_bash "$f" t1 "pick-note clear"; tx_result "$f" t1
tx_text "$f" "Done."
tx_notif "$f" b1
tx_bash "$f" t2 "pick-note clear"; tx_result "$f" t2
tx_text "$f" "b1 finished; nothing else to do."
XDG_STATE_HOME="$TMP/state18-2" check 0 "stale-pick: the notification turn re-runs the pick, passes" "$f"

# Case 3: the base transcript, checked a second time unchanged, is fire-once silent.
XDG_STATE_HOME="$TMP/state18-1" check 0 "stale-pick: fire-once, same transcript checked again passes" "$S18"

# Case 4: a second notification turn appended re-arms the gate.
tx_notif "$S18" b2
tx_text "$S18" "b2 finished too."
XDG_STATE_HOME="$TMP/state18-1" check 2 "stale-pick: a new notification turn re-arms and blocks" "$S18" "" \
  'the pick went stale on a notification turn'

# Case 5: an earlier keep pick is not a clear or compact pick.
f="$TMP/s18-5.jsonl"; : > "$f"; tx_human "$f"
tx_bash "$f" t1 "pick-note keep"; tx_result "$f" t1
tx_text "$f" "Done."
tx_notif "$f" b1; tx_text "$f" "b1 finished."
XDG_STATE_HOME="$TMP/state18-5" check 0 "stale-pick: earlier pick is keep, passes" "$f"

# Case 6: an owner turn between the pick and the notification ends the walk.
f="$TMP/s18-6.jsonl"; : > "$f"; tx_human "$f"
tx_bash "$f" t1 "pick-note clear"; tx_result "$f" t1
tx_text "$f" "Done."
tx_human "$f"; tx_text "$f" "Thanks, next question."
tx_notif "$f" b1; tx_text "$f" "b1 finished."
XDG_STATE_HOME="$TMP/state18-6" check 0 "stale-pick: owner turn between pick and notification, passes" "$f"

# Case 7: a compaction between the pick and the notification ends the walk.
f="$TMP/s18-7.jsonl"; : > "$f"; tx_human "$f"
tx_bash "$f" t1 "pick-note clear"; tx_result "$f" t1
tx_text "$f" "Done."
printf '%s\n' '{"type":"system","subtype":"compact_boundary","content":"Conversation compacted"}' >> "$f"
tx_notif "$f" b1; tx_text "$f" "b1 finished."
XDG_STATE_HOME="$TMP/state18-7" check 0 "stale-pick: compact boundary between pick and notification, passes" "$f"

# Case 8: a slash-command entry with no origin is skipped over, so the clear still counts.
f="$TMP/s18-8.jsonl"; : > "$f"; tx_human "$f"
tx_bash "$f" t1 "pick-note clear"; tx_result "$f" t1
tx_text "$f" "Done."
printf '%s\n' '{"type":"user","isMeta":null,"message":{"content":"<command-name>/reload-plugins</command-name>"}}' >> "$f"
tx_notif "$f" b1; tx_text "$f" "b1 finished."
XDG_STATE_HOME="$TMP/state18-8" check 2 "stale-pick: command-name entry between pick and notification is skipped, blocks" "$f" "" \
  'the pick went stale on a notification turn'

# Case 9: a plain typed message with no origin ends the walk.
f="$TMP/s18-9.jsonl"; : > "$f"; tx_human "$f"
tx_bash "$f" t1 "pick-note clear"; tx_result "$f" t1
tx_text "$f" "Done."
printf '%s\n' '{"type":"user","isMeta":null,"message":{"content":"hello"}}' >> "$f"
tx_notif "$f" b1; tx_text "$f" "b1 finished."
XDG_STATE_HOME="$TMP/state18-9" check 0 "stale-pick: plain typed message between pick and notification, passes" "$f"

# Case 10: the turn starts with a plain user entry (no origin), so there is no notification turn.
f="$TMP/s18-10.jsonl"; : > "$f"; tx_human "$f"
tx_bash "$f" t1 "pick-note clear"; tx_result "$f" t1
tx_text "$f" "Done."
tx_user "$f"; tx_text "$f" "b1 finished; nothing else to do."
XDG_STATE_HOME="$TMP/state18-10" check 0 "stale-pick: turn starts with a plain user entry, passes" "$f"

# Case 11: an errored earlier pick does not count.
f="$TMP/s18-11.jsonl"; : > "$f"; tx_human "$f"
tx_bash "$f" t1 "pick-note clear"; tx_result "$f" t1 true
tx_text "$f" "Done."
tx_notif "$f" b1; tx_text "$f" "b1 finished."
XDG_STATE_HOME="$TMP/state18-11" check 0 "stale-pick: earlier pick errored, passes" "$f"

# Case 12: a background task launched this session and not yet ended keeps the turn silent.
f="$TMP/s18-12.jsonl"; : > "$f"; tx_human "$f"
tx_bash "$f" t1 "pick-note clear"; tx_result "$f" t1
tx_text "$f" "Done."
tx_bash "$f" t9 "sleep 999"
printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t9","content":"started"}]},"toolUseResult":{"backgroundTaskId":"b9"}}' >> "$f"
tx_notif "$f" b1; tx_text "$f" "b1 finished."
XDG_STATE_HOME="$TMP/state18-12" check 0 "stale-pick: live background task b9 (notification names b1) passes" "$f"

# Case 13: the same transcript, the notification names b9, which ends the live task.
f="$TMP/s18-13.jsonl"; : > "$f"; tx_human "$f"
tx_bash "$f" t1 "pick-note clear"; tx_result "$f" t1
tx_text "$f" "Done."
tx_bash "$f" t9 "sleep 999"
printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t9","content":"started"}]},"toolUseResult":{"backgroundTaskId":"b9"}}' >> "$f"
tx_notif "$f" b9; tx_text "$f" "b9 finished."
XDG_STATE_HOME="$TMP/state18-13" check 2 "stale-pick: notification ends the live task b9, blocks" "$f" "" \
  'the pick went stale on a notification turn'

# Case 13b: b9 is launched, a task-notification for it is queued mid-turn (a queued_command
# attachment, not a user entry), then the notification turn starts and ends. The queued
# attachment ends b9, so nothing is live and the turn blocks.
f="$TMP/s18-13b.jsonl"; : > "$f"; tx_human "$f"
tx_bash "$f" t1 "pick-note clear"; tx_result "$f" t1
tx_text "$f" "Done."
tx_bash "$f" t9 "sleep 999"
printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t9","content":"started"}]},"toolUseResult":{"backgroundTaskId":"b9"}}' >> "$f"
printf '%s\n' '{"type":"attachment","attachment":{"type":"queued_command","commandMode":"task-notification","origin":{"kind":"task-notification"},"prompt":"<task-notification>\n<task-id>b9</task-id>\n<status>completed</status>\n</task-notification>"}}' >> "$f"
tx_notif "$f" b1; tx_text "$f" "b1 finished."
XDG_STATE_HOME="$TMP/state18-13b" check 2 "stale-pick: b9 ended by a queued mid-turn notification, blocks" "$f" "" \
  'the pick went stale on a notification turn'

# Case 14: the component switched off by SYG_DISABLE passes the base fixture.
XDG_STATE_HOME="$TMP/state18-14" SYG_DISABLE=stale-pick check 0 "stale-pick: SYG_DISABLE=stale-pick passes base" "$S18"
unset SYG_DISABLE

# Case 15: no SYG_PICK_CMD (text mode) passes the base fixture.
unset SYG_PICK_CMD
XDG_STATE_HOME="$TMP/state18-15" check 0 "stale-pick: SYG_PICK_CMD unset (text mode) passes base" "$S18"
export SYG_PICK_CMD='pick-note'

# Case 16: a stop-hook re-stop passes the base fixture.
XDG_STATE_HOME="$TMP/state18-16" check 0 "stale-pick: stop_hook_active true passes base" "$S18" true

unset SYG_PICK_CMD

# --- 19. Prose-pick trigger: a no-handoff turn that names a pick in prose -----
export SYG_PICK_CMD='pick-note'
unset SYG_HANDOFF_CMDS SYG_HANDOFF_PATHS SYG_HANDOFF_SECTIONS SYG_PROSE_PICK_RE CHECK_LAM
PROSE_S1="The handoff is on disk, so **/clear** is still my pick here."
mktx_prose() { # $1=out $2=text
  : > "$1"; tx_human "$1"; tx_text "$1" "$2"
}

# Case 1: human turn naming /clear as present pick blocks once.
S19_1="$TMP/s19-1.jsonl"; mktx_prose "$S19_1" "$PROSE_S1"
XDG_STATE_HOME="$TMP/state19-1" check 2 "prose-pick: case 1 human turn naming /clear in prose blocks once" "$S19_1" "" \
  'pick named in prose, not run' 'pick-note clear\|compact\|keep' 'SYG_DISABLE=prose-pick'

# Case 2: '/compact is queued' blocks.
f="$TMP/s19-2.jsonl"; mktx_prose "$f" '`/compact` is queued for when this session goes idle.'
XDG_STATE_HOME="$TMP/state19-2" check 2 "prose-pick: case 2 '/compact is queued' blocks" "$f" "" \
  'pick named in prose, not run'

# Case 3: 'Pick: **/compact**.' blocks.
f="$TMP/s19-3.jsonl"; mktx_prose "$f" 'Pick: **/compact**.'
XDG_STATE_HOME="$TMP/state19-3" check 2 "prose-pick: case 3 'Pick: **/compact**.' blocks" "$f" "" \
  'pick named in prose, not run'

# Case 4: 'My pick is `/clear` now' blocks.
f="$TMP/s19-4.jsonl"; mktx_prose "$f" 'My pick is `/clear` now: the next unit is unrelated.'
XDG_STATE_HOME="$TMP/state19-4" check 2 "prose-pick: case 4 'My pick is /clear now' blocks" "$f" "" \
  'pick named in prose, not run'

# Case 4b: a sentence-initial 'Now' reaches the pick across six words; a
# mid-sentence 'now' that far from it (a mention) does not.
f="$TMP/s19-4b.jsonl"; mktx_prose "$f" 'Now is a good time to /compact, since the thread continues.'
XDG_STATE_HOME="$TMP/state19-4b" check 2 "prose-pick: case 4b 'Now is a good time to /compact' blocks" "$f" "" \
  'pick named in prose, not run'
f="$TMP/s19-4c.jsonl"; mktx_prose "$f" 'All of this is in my role file now, so it carries across a /compact.'
XDG_STATE_HOME="$TMP/state19-4c" check 0 "prose-pick: case 4c mid-sentence 'now' far from the pick passes" "$f"

# Case 5: forecast with future markers passes.
f="$TMP/s19-5.jsonl"; mktx_prose "$f" 'Once the PR merges, my pick will be `/clear`.'
XDG_STATE_HOME="$TMP/state19-5" check 0 "prose-pick: case 5 forecast with future markers passes" "$f"

# Case 6: mention without a pick claim passes.
f="$TMP/s19-6.jsonl"; mktx_prose "$f" '`/clear` still doesn'\''t reset the counter.'
XDG_STATE_HOME="$TMP/state19-6" check 0 "prose-pick: case 6 mention without pick word passes" "$f"

# Case 7: case 1's text with a pick-note clear call in the same turn passes.
f="$TMP/s19-7.jsonl"; : > "$f"; tx_human "$f"
tx_bash "$f" t1 "pick-note clear"; tx_result "$f" t1
tx_text "$f" "$PROSE_S1"
XDG_STATE_HOME="$TMP/state19-7" check 0 "prose-pick: case 7 emitter call in same turn passes" "$f"

# Case 8: case 1 with SYG_PICK_CMD unset passes.
unset SYG_PICK_CMD
XDG_STATE_HOME="$TMP/state19-8" check 0 "prose-pick: case 8 SYG_PICK_CMD unset passes" "$S19_1"
export SYG_PICK_CMD='pick-note'

# Case 9: case 1 with SYG_DISABLE=prose-pick passes.
XDG_STATE_HOME="$TMP/state19-9" SYG_DISABLE=prose-pick check 0 "prose-pick: case 9 SYG_DISABLE=prose-pick passes" "$S19_1"

# Case 10: fire-once — case 1's transcript and state dir again passes.
XDG_STATE_HOME="$TMP/state19-1" check 0 "prose-pick: case 10 fire-once same transcript and state dir passes" "$S19_1"

# Case 11: case 1 with stop_hook_active true passes.
XDG_STATE_HOME="$TMP/state19-11" check 0 "prose-pick: case 11 stop_hook_active true passes" "$S19_1" true

# Case 12: LAM vs transcript last text — both scanned.
f="$TMP/s19-12a.jsonl"; mktx_prose "$f" "Done."
XDG_STATE_HOME="$TMP/state19-12a" CHECK_LAM="$PROSE_S1" check 2 "prose-pick: case 12a LAM has prose pick while transcript has Done. -> blocks" "$f" "" \
  'pick named in prose, not run'
XDG_STATE_HOME="$TMP/state19-12b" CHECK_LAM="Done." check 2 "prose-pick: case 12b transcript has prose pick while LAM has Done. -> blocks" "$S19_1" "" \
  'pick named in prose, not run'

# Case 13: carry-forward across live background work.
f="$TMP/s19-13ab.jsonl"; : > "$f"; tx_human "$f"
tx_bash "$f" t9 "sleep 999"
printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t9","content":"started"}]},"toolUseResult":{"backgroundTaskId":"b9"}}' >> "$f"
tx_text "$f" "$PROSE_S1"
XDG_STATE_HOME="$TMP/state19-13ab" check 0 "prose-pick: case 13a live background task b9 defers prose pick" "$f"

tx_notif "$f" b9
tx_text "$f" "b9 finished."
XDG_STATE_HOME="$TMP/state19-13ab" check 2 "prose-pick: case 13b b9 notification ends live work and blocks with owed message" "$f" "" \
  'a prose pick is still owed' 'pick-note clear\|compact\|keep' 'SYG_DISABLE=prose-pick'

f="$TMP/s19-13c.jsonl"; : > "$f"; tx_human "$f"
tx_bash "$f" t9 "sleep 999"
printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t9","content":"started"}]},"toolUseResult":{"backgroundTaskId":"b9"}}' >> "$f"
tx_text "$f" "$PROSE_S1"
XDG_STATE_HOME="$TMP/state19-13c" check 0 "prose-pick: case 13c setup (records .prose-owed)" "$f"
tx_notif "$f" b9
tx_bash "$f" t10 "pick-note clear"; tx_result "$f" t10
tx_text "$f" "b9 finished."
XDG_STATE_HOME="$TMP/state19-13c" check 0 "prose-pick: case 13c notification turn runs pick-note clear -> passes" "$f"

f="$TMP/s19-13d.jsonl"; : > "$f"; tx_human "$f"
tx_bash "$f" t9 "sleep 999"
printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t9","content":"started"}]},"toolUseResult":{"backgroundTaskId":"b9"}}' >> "$f"
tx_text "$f" "$PROSE_S1"
XDG_STATE_HOME="$TMP/state19-13d" check 0 "prose-pick: case 13d setup (records .prose-owed)" "$f"
tx_human "$f"; tx_text "$f" "ok."
tx_notif "$f" b9; tx_text "$f" "b9 finished."
XDG_STATE_HOME="$TMP/state19-13d" check 0 "prose-pick: case 13d intervening human turn cancels .prose-owed -> passes" "$f"

# Case 14: stale-pick takes precedence over prose-pick on a notification turn after an earlier pick.
f="$TMP/s19-14.jsonl"; : > "$f"; tx_human "$f"
tx_bash "$f" t1 "pick-note clear"; tx_result "$f" t1
tx_text "$f" "Done."
tx_notif "$f" b1
tx_text "$f" "$PROSE_S1"
XDG_STATE_HOME="$TMP/state19-14" check 2 "prose-pick: case 14 stale-pick takes precedence over prose-pick" "$f" "" \
  'the pick went stale on a notification turn' '!pick named in prose'

# Case 15: SYG_PROSE_PICK_RE override and invalid-regex fallback.
XDG_STATE_HOME="$TMP/state19-15a" SYG_PROSE_PICK_RE='zzz-never' check 0 "prose-pick: case 15a SYG_PROSE_PICK_RE override replaces default" "$S19_1"
XDG_STATE_HOME="$TMP/state19-15b" SYG_PROSE_PICK_RE='(' check 2 "prose-pick: case 15b invalid SYG_PROSE_PICK_RE falls back to default" "$S19_1" "" \
  'pick named in prose, not run'

# Case 16: a handoff turn whose closing names a prose pick uses missing:emitter, not prose.
f="$TMP/s19-16.jsonl"; : > "$f"; tx_human "$f"
tx_bash "$f" t1 "$HANDOFF_CALL"; tx_result "$f" t1
tx_text "$f" "$PROSE_S1"
XDG_STATE_HOME="$TMP/state19-16" SYG_HANDOFF_CMDS='myrole --set' check 2 "prose-pick: case 16 handoff turn uses missing:emitter message, not prose" "$f" "" \
  'handoff written without running the pick command' '!pick named in prose'

unset SYG_PICK_CMD

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
