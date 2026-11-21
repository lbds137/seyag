#!/bin/bash
# Fixture check for ask-command-echo-check.sh — run after ANY edit to the hook.
# Asserts the exit-code table over synthetic transcripts: an AskUserQuestion in the
# current turn carrying a `!` command or a URL (question text or any option label,
# description or preview) blocks the stop once unless the closing message repeats
# it in a fenced code block (a URL may instead stand alone on its own line). Prose
# "! line", placeholder and example URLs, inline-backtick-only echoes, earlier-turn
# asks, block-once-per-ask (including under stop_hook_active), a "Stop hook
# feedback:" entry not ending the turn, and missing or garbage transcripts are
# pinned too.
#
# Usage: hooks/ask-command-echo-check.probe.sh   (from repo root)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="${HOOK:-$SCRIPT_DIR/ask-command-echo-check.sh}"
CLAUDE_PROJECT_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
export CLAUDE_PROJECT_DIR
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Hermetic state: the hook remembers the ask it blocked on under XDG_STATE_HOME.
export XDG_STATE_HOME="$TMP/state"

TICK=$(printf '\140')
FENCE="${TICK}${TICK}${TICK}"

# Build a transcript: genuine user line, an assistant AskUserQuestion tool_use,
# the answer as a tool_result, then the closing text.
# $1=out $2=question $3=closing text $4=options JSON (optional, default [])
# Env: ASKID = the ask's tool_use id (default t1; empty = omit the field),
#      FEEDBACK = text of a user entry inserted before the closing text.
mktx() {
  OUT="$1" Q="$2" CLOSE="${3:-Done.}" OPTS="${4:-[]}" ASKID="${ASKID-t1}" FEEDBACK="${FEEDBACK:-}" python3 -I -B - << 'PY'
import json, os
inp = {"questions": [{"question": os.environ["Q"], "options": json.loads(os.environ["OPTS"])}]}
ask = {"type": "tool_use", "name": "AskUserQuestion", "input": inp}
if os.environ["ASKID"]:
    ask["id"] = os.environ["ASKID"]
rows = [
    {"type": "user", "isMeta": None, "message": {"content": "go"}},
    {"type": "assistant", "message": {"content": [ask]}},
    {"type": "user", "message": {"content": [{"type": "tool_result", "content": "answered"}]}},
]
if os.environ["FEEDBACK"]:
    rows.append({"type": "user", "message": {"content": os.environ["FEEDBACK"]}})
rows.append({"type": "assistant", "message": {"content": [{"type": "text", "text": os.environ["CLOSE"]}]}})
with open(os.environ["OUT"], "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
PY
}

fail=0
NCASE=0
# SID overrides the per-call session id (default: a fresh one, so state never leaks between cases).
check() { # $1=expected_exit $2=label $3=transcript $4=stop_active $5+=stderr regexes ("!" prefix = must not match)
  NCASE=$((NCASE + 1))
  echo "{\"session_id\":\"${SID:-case-$NCASE}\",\"stop_hook_active\":${4:-false},\"transcript_path\":\"$3\"}" | "$HOOK" >/dev/null 2>"$TMP/stderr.out"
  local got=$? pat
  if [ "$got" != "$1" ]; then echo "FAIL [$got≠$1]: $2"; fail=1; return; fi
  for pat in "${@:5}"; do
    if [ "${pat#!}" != "$pat" ]; then
      if grep -qE -e "${pat#!}" "$TMP/stderr.out"; then
        echo "FAIL [stderr matches /${pat#!}/ but must not]: $2"; fail=1; return
      fi
    elif ! grep -qE -e "$pat" "$TMP/stderr.out"; then
      echo "FAIL [stderr misses /$pat/]: $2"; fail=1; return
    fi
  done
  echo "ok   [$got]: $2"
}

CMD='gh pr merge 1 --rebase'
Q1="Merge it? Run: ! $CMD"

# 1. command only in the question → fires, banner names it
mktx "$TMP/1.jsonl" "$Q1" "Done. Run the line when ready."
check 2 "command only in the question fires" "$TMP/1.jsonl" "" 'ASK-DIALOG COMMAND' "$CMD"

# 2. fenced in the closing → silent
mktx "$TMP/2.jsonl" "$Q1" "Run this:
${FENCE}
! $CMD
${FENCE}"
check 0 "command in a fenced block passes" "$TMP/2.jsonl"

# 3. inline backticks only → fires
mktx "$TMP/3.jsonl" "$Q1" "Run ${TICK}! $CMD${TICK} when ready."
check 2 "inline backticks do not satisfy" "$TMP/3.jsonl"

# 4. no command or URL
mktx "$TMP/4.jsonl" "Which option do you want?"
check 0 "ask without a command or URL passes" "$TMP/4.jsonl"

# 5. prose "! line"
mktx "$TMP/5.jsonl" "I'll hand you the one ! line after this. OK?" "Done."
check 0 "prose '! line' is not a command" "$TMP/5.jsonl"

# 6. backticked command followed by prose
mktx "$TMP/6.jsonl" "Run ${TICK}! cd x && git push origin b${TICK} and then tell me." "${FENCE}
! cd x && git push origin b
${FENCE}"
check 0 "backtick-bounded command satisfied by the fenced line" "$TMP/6.jsonl"

# 7. command runs on into prose; prefix rule
mktx "$TMP/7.jsonl" "type this: ! foo --bar then pick Done" "${FENCE}
foo --bar
${FENCE}"
check 0 "fenced line that is a prefix of the key satisfies it" "$TMP/7.jsonl"

# 8. option description / preview only
mktx "$TMP/8a.jsonl" "Pick one" "Done." '[{"label":"A","description":"run ! make deploy-all now"}]'
check 2 "command in an option description fires" "$TMP/8a.jsonl" "" 'make deploy-all'
mktx "$TMP/8b.jsonl" "Pick one" "Done." '[{"label":"A","preview":"! make deploy-all"}]'
check 2 "command in an option preview fires" "$TMP/8b.jsonl" "" 'make deploy-all'

# 9. URL
URL='https://github.com/o/r/security'
mktx "$TMP/9a.jsonl" "Open $URL and tell me." "Link:

$URL"
check 0 "URL alone on its own line passes" "$TMP/9a.jsonl"
mktx "$TMP/9b.jsonl" "Open $URL and tell me." "Open $URL when ready."
check 2 "URL only inside a sentence fires" "$TMP/9b.jsonl" "" "$URL"

# 10. illustrative URLs
mktx "$TMP/10.jsonl" "Examples: https://evil.example/x, https://sbar.fyi/i/<code> and http://127.0.0.1:3000 ok?" "Done."
check 0 "example, placeholder and loopback URLs are skipped" "$TMP/10.jsonl"

# 11. two commands, one echoed
mktx "$TMP/11.jsonl" "Run ${TICK}! echo alpha-one${TICK} then ${TICK}! echo beta-two${TICK}" "${FENCE}
echo alpha-one
${FENCE}"
check 2 "two commands, one fenced: names only the missing one" "$TMP/11.jsonl" "" 'beta-two' '!alpha-one'

# 12. stop_hook_active no longer exempts (deliberate change: the ask often happens in a
# retry another Stop hook triggered); block-once is per ask, via the state file.
SID=sess-ask check 2 "A: stop_hook_active true, first sight of ask t1 → fires (was 0 before per-ask state)" "$TMP/1.jsonl" true
SID=sess-ask check 0 "B: same ask t1 again → already reminded, allows" "$TMP/1.jsonl" true
ASKID=t2 mktx "$TMP/12c.jsonl" "$Q1" "Done. Run the line when ready."
SID=sess-ask check 2 "C: a new last ask t2 in the same session → fires again" "$TMP/12c.jsonl" true
ASKID='' mktx "$TMP/12d.jsonl" "$Q1" "Done. Run the line when ready."
SID=sess-hash check 2 "D: ask without an id blocks (hash identity)" "$TMP/12d.jsonl"
SID=sess-hash check 0 "D: identical rerun of the id-less ask allows" "$TMP/12d.jsonl"
FEEDBACK='Stop hook feedback: [x] some other hook blocked' mktx "$TMP/12e.jsonl" "$Q1" "Done. Run the line when ready."
check 2 "E: a 'Stop hook feedback:' user entry is not a turn boundary" "$TMP/12e.jsonl"
touch "$TMP/not-a-dir"
XDG_STATE_HOME="$TMP/not-a-dir" check 2 "F: state dir unwritable, stop_hook_active false → still blocks" "$TMP/1.jsonl" false
XDG_STATE_HOME="$TMP/not-a-dir" check 0 "F: state dir unwritable, stop_hook_active true → allows" "$TMP/1.jsonl" true

# 13. ask in a previous turn
{
  echo '{"type":"user","isMeta":null,"message":{"content":"go"}}'
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion","input":{"questions":[{"question":"Run ! %s ?","options":[]}]}}]}}\n' "$CMD"
  echo '{"type":"user","isMeta":null,"message":{"content":"yes"}}'
  echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Merged."}]}}'
} > "$TMP/13.jsonl"
check 0 "ask in an earlier turn is not judged" "$TMP/13.jsonl"

# 14. fail-open
check 0 "missing transcript path" "$TMP/does-not-exist.jsonl"
printf 'not json\n{broken\n\n' > "$TMP/14.jsonl"
check 0 "garbage transcript" "$TMP/14.jsonl"

# 15. last_assistant_message wins over the transcript
echo "{\"stop_hook_active\":false,\"transcript_path\":\"$TMP/1.jsonl\",\"last_assistant_message\":\"Run:\\n${FENCE}\\n! $CMD\\n${FENCE}\"}" \
  | "$HOOK" >/dev/null 2>"$TMP/stderr.out"
got=$?
if [ "$got" != 0 ] || grep -q Traceback "$TMP/stderr.out"; then echo "FAIL [$got≠0]: last_assistant_message fence wins over the transcript's last text"; fail=1
else echo "ok   [0]: last_assistant_message fence wins over the transcript's last text"; fi

# 16. tilde fence
mktx "$TMP/16.jsonl" "$Q1" "Run:
~~~
$CMD
~~~"
check 0 "~~~ fence satisfies" "$TMP/16.jsonl"

# A command closing the question keeps no trailing "?" in its key.
QEND="Will you merge it with: ! gh pr merge 7 --rebase --admin?"
mktx "$TMP/17a.jsonl" "$QEND" "Run this:
\`\`\`
! gh pr merge 7 --rebase --admin
\`\`\`"
check 0 "command ending the question, fenced without the ?, passes" "$TMP/17a.jsonl"
mktx "$TMP/17b.jsonl" "$QEND" "Run the line when ready."
check 2 "command ending the question, not echoed, fires without the ?" "$TMP/17b.jsonl" "" 'gh pr merge 7 --rebase --admin$'

# Code negation with no space after the bang is not a command.
mktx "$TMP/18.jsonl" "Suggested shape: refuse !guild_id unless recipient. OK?" "Done."
check 0 "bang with no following space (code negation) is not a command" "$TMP/18.jsonl"

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
