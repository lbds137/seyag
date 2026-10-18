#!/bin/bash
# Fixture check for blocking-question-channel-check.sh — run after ANY edit to
# the hook. Asserts the exit-code table over synthetic transcripts: a turn that
# ends on a question fires unless AskUserQuestion or PushNotification was used
# in the same turn; a closing text matching a pending marker (SYG_BQ_PENDING_MARKERS,
# with its built-in default) fires the same way. Statements, the stop_hook_active
# re-stop, and a missing transcript all stay silent. Also pins the banner: a firing
# quotes the tripped closing line on stderr, and on lanes matched by
# SYG_BQ_NO_RC_LANES (a broken regex fails open) the advice routes through
# SendMessage instead.
#
# Colocated with the hook — the transcript-parsing python is the fragile part;
# this probe pins its behavior on hook edits.
#
# Usage: hooks/blocking-question-channel-check.probe.sh   (from repo root)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$SCRIPT_DIR/blocking-question-channel-check.sh"
CLAUDE_PROJECT_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
export CLAUDE_PROJECT_DIR
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

jsonstr() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }

# Build a transcript: one user turn + an optional tool_use + a final text block.
mktx() { # $1=out $2=text $3=tool_name(optional)
  : > "$1"
  echo '{"type":"user","isMeta":null,"message":{"content":"go"}}' >> "$1"
  [ -n "${3:-}" ] && printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"%s","input":{}}]}}\n' "$3" >> "$1"
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":%s}]}}\n' "$(jsonstr "$2")" >> "$1"
}

fail=0
check() { # $1=expected_exit $2=label $3=transcript $4=stop_active $5+=stderr regexes
  # Each regex must match the captured stderr; a regex prefixed with "!" must NOT.
  echo "{\"stop_hook_active\":${4:-false},\"transcript_path\":\"$3\"}" | "$HOOK" >/dev/null 2>"$TMP/stderr.out"
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

# Hermetic: ambient lane vars must not flip the legacy cases' advice.
unset SYG_BQ_NO_RC_LANES ANTHROPIC_BASE_URL SYG_BQ_PENDING_MARKERS

# --- 1. the core fire case ---------------------------------------------------
mktx "$TMP/a.jsonl" "Both approaches work here. Should I use X or Y?"
check 2 "closing question, no formal channel this turn" "$TMP/a.jsonl"

# --- 2/3. the formal channels clear it ---------------------------------------
mktx "$TMP/b.jsonl" "Both approaches work here. Should I use X or Y?" "AskUserQuestion"
check 0 "same question + AskUserQuestion in the turn" "$TMP/b.jsonl"

mktx "$TMP/c.jsonl" "Both approaches work here. Should I use X or Y?" "PushNotification"
check 0 "same question + PushNotification in the turn" "$TMP/c.jsonl"

# An unrelated tool does NOT clear it — only the two formal channels do.
mktx "$TMP/c2.jsonl" "Both approaches work here. Should I use X or Y?" "Bash"
check 2 "an ordinary tool_use is not a formal channel" "$TMP/c2.jsonl"

# --- 4. a statement close ----------------------------------------------------
mktx "$TMP/d.jsonl" "Done — the fix is in and every gate is green."
check 0 "closing statement, no question" "$TMP/d.jsonl"

# --- 5. block-once ------------------------------------------------------------
check 0 "stop_hook_active re-stop always allows" "$TMP/a.jsonl" true

# --- 6. fail-open on a missing/empty transcript ------------------------------
check 0 "missing transcript path (fail-open)" "$TMP/does-not-exist.jsonl"
check 0 "empty transcript path (fail-open)" ""

: > "$TMP/empty.jsonl"
check 0 "empty transcript file (no text block)" "$TMP/empty.jsonl"

# --- 7. trailing markdown must not hide the mark -----------------------------
mktx "$TMP/e.jsonl" "That leaves one call to make. **Ship it as-is, right?**"
check 2 "trailing bold after the question mark still fires" "$TMP/e.jsonl"

TICK=$(printf '\140')
mktx "$TMP/e2.jsonl" "One thing left: do we keep ${TICK}--strict${TICK}?${TICK}"
check 2 "trailing backtick after the question mark still fires" "$TMP/e2.jsonl"

mktx "$TMP/e3.jsonl" "So: which one, A or B?   "
check 2 "trailing whitespace after the question mark still fires" "$TMP/e3.jsonl"

# --- 8. a mid-text question mark is not a closing ask ------------------------
mktx "$TMP/f.jsonl" "The obvious question is: why did it retry?

Because the busy path throws before the usage row is written. Fixed and green."
check 0 "question mid-message, statement close — does not fire" "$TMP/f.jsonl"

mktx "$TMP/f2.jsonl" "Should we cache this? I checked, and the answer is no.
Landed the direct read instead."
check 0 "question in an earlier line, statement close — does not fire" "$TMP/f2.jsonl"

# Trailing blank lines must not mask the question — the LAST NON-EMPTY line decides.
mktx "$TMP/f3.jsonl" "Ready to push. Want me to open the PR?

"
check 2 "trailing blank lines do not mask the closing question" "$TMP/f3.jsonl"

# The final TEXT block is what counts, even when a tool_use follows earlier text.
mktx "$TMP/g.jsonl" "Gates are green. Merge now or wait for the release cut?" "Read"
check 2 "question after an unrelated tool_use in the same turn" "$TMP/g.jsonl"

# A formal channel from a PREVIOUS turn does not clear the current one.
{
  echo '{"type":"user","isMeta":null,"message":{"content":"go"}}'
  echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion","input":{}}]}}'
  echo '{"type":"user","isMeta":null,"message":{"content":"option 1"}}'
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":%s}]}}\n' \
    "$(jsonstr "Applied option 1. Should I also bump the baseline?")"
} > "$TMP/h.jsonl"
check 2 "formal channel in an EARLIER turn does not clear this one" "$TMP/h.jsonl"

# --- 9. the lenient no-boundary fallback (the one deliberate deviation from ---
# --- promise-ledger-check: turn_start is None => scan the WHOLE transcript ---
# A boundary-less transcript (no genuine user message) WITH a formal channel:
# the lenient scan credits it — silent. Strict-fail would fire here.
{
  echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion","input":{}}]}}'
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":%s}]}}\n' \
    "$(jsonstr "Truncated transcript. Which option did you want?")"
} > "$TMP/i.jsonl"
check 0 "no turn boundary + formal channel anywhere — lenient scan credits it" "$TMP/i.jsonl"

# Same boundary-less shape WITHOUT a formal channel: the fallback still fires.
{
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":%s}]}}\n' \
    "$(jsonstr "Truncated transcript. Which option did you want?")"
} > "$TMP/i2.jsonl"
check 2 "no turn boundary + no formal channel — still fires" "$TMP/i2.jsonl"

# --- 10. the banner quotes the tripped closing line ---------------------------
check 2 "fire banner quotes the tripped line" "$TMP/a.jsonl" "" \
  'Your closing message ends with:' 'Should I use X or Y\?'

# --- 11. lane routing: no-RC lanes get SendMessage advice ---------------------
export SYG_BQ_NO_RC_LANES='z\.ai' ANTHROPIC_BASE_URL='https://api.z.ai/api/anthropic'
check 2 "no-RC lane routes the ask through SendMessage" "$TMP/a.jsonl" "" \
  'no Remote Control' 'SendMessage'
unset SYG_BQ_NO_RC_LANES ANTHROPIC_BASE_URL

check 2 "lane vars unset keeps the default advice" "$TMP/a.jsonl" "" \
  'AskUserQuestion' 'the ask fits structured options' '!SendMessage'

export SYG_BQ_NO_RC_LANES='[' ANTHROPIC_BASE_URL='https://api.z.ai/api/anthropic'
check 2 "broken lane regex fails open to the default advice" "$TMP/a.jsonl" "" \
  '!no Remote Control' 'broken ERE'
unset SYG_BQ_NO_RC_LANES ANTHROPIC_BASE_URL

export SYG_BQ_NO_RC_LANES='z\.ai' ANTHROPIC_BASE_URL='https://api.z.ai/api/anthropic'
check 0 "statement close with lane vars set — silent stays silent" "$TMP/d.jsonl" "" '!.'
unset SYG_BQ_NO_RC_LANES ANTHROPIC_BASE_URL

# --- 12. pending-marker pass (no closing "?") ---------------------------------
mktx "$TMP/m1.jsonl" "Everything is staged — say the word and I'll start 3c"
check 2 "pending marker: 'say the word'" "$TMP/m1.jsonl" "" \
  'Your closing message leaves an ask pending:' \
  '!Your closing message ends with:' \
  "say the word and I'll start 3c"

mktx "$TMP/m2.jsonl" "The branch is pushed; still waiting on you for that"
check 2 "pending marker: 'waiting on you'" "$TMP/m2.jsonl"

mktx "$TMP/m3.jsonl" "Diff is clean, this needs your yes before it ships"
check 2 "pending marker: 'needs your yes'" "$TMP/m3.jsonl"

mktx "$TMP/m3b.jsonl" "Ready to cut; this needs your go before I tag"
check 2 "pending marker: 'needs your go'" "$TMP/m3b.jsonl"

mktx "$TMP/m4.jsonl" "Left the two defaults in place; needs your call on the preset"
check 2 "pending marker: 'needs your call'" "$TMP/m4.jsonl"

mktx "$TMP/m4b.jsonl" "The migration plan need your input on the retention window"
check 2 "pending marker: 'need your input'" "$TMP/m4b.jsonl"

mktx "$TMP/m5.jsonl" "Two layouts are ready, for you to decide the ordering"
check 2 "pending marker: 'for you to decide'" "$TMP/m5.jsonl"

mktx "$TMP/m6.jsonl" "Build is deployed to staging, for you to test on the phone"
check 2 "pending marker: 'for you to test'" "$TMP/m6.jsonl"

mktx "$TMP/m7.jsonl" "Logs are rotated and archived, for you to check in the morning"
check 2 "pending marker: 'for you to check'" "$TMP/m7.jsonl"

mktx "$TMP/m8.jsonl" "Waiting on you."
check 2 "pending marker: case-insensitive ('Waiting on you.')" "$TMP/m8.jsonl"

mktx "$TMP/m9.jsonl" "The hook docs quote ${TICK}say the word${TICK} as an example phrase."
check 0 "pending marker inside inline code span does not fire" "$TMP/m9.jsonl"

mktx "$TMP/m9b.jsonl" "Earlier I was waiting on you for the token; that is resolved now.

Shipped and verified."
check 0 "pending marker in an earlier paragraph, clean final paragraph — does not fire" "$TMP/m9b.jsonl"

FENCE="${TICK}${TICK}${TICK}"
mktx "$TMP/m9c.jsonl" "Example:
${FENCE}
waiting on you
${FENCE}
All set."
check 0 "pending marker inside fenced code block does not fire" "$TMP/m9c.jsonl"

mktx "$TMP/m10a.jsonl" "There's nothing waiting on you either."
check 0 "negated pending marker: 'nothing waiting on you' does not fire" "$TMP/m10a.jsonl"

mktx "$TMP/m10b.jsonl" "Otherwise I'm idle, with nothing waiting on you."
check 0 "negated pending marker: 'with nothing waiting on you' does not fire" "$TMP/m10b.jsonl"

mktx "$TMP/m10c.jsonl" "I'm idle again, and nothing is waiting on you."
check 0 "negated pending marker: 'nothing is waiting on you' does not fire" "$TMP/m10c.jsonl"

mktx "$TMP/m10d.jsonl" "Nobody is waiting on you right now."
check 0 "negated pending marker: 'Nobody is waiting on you' does not fire" "$TMP/m10d.jsonl"

mktx "$TMP/m10e.jsonl" "It isn't waiting on you anymore."
check 0 "negated pending marker: \"isn't waiting on you\" does not fire" "$TMP/m10e.jsonl"

mktx "$TMP/m10f.jsonl" "It isn’t waiting on you anymore."
check 0 "negated pending marker: curly apostrophe (isn’t) does not fire" "$TMP/m10f.jsonl"

mktx "$TMP/m10f.jsonl" "No rush, but this is waiting on you"
check 2 "negator before comma boundary does not suppress pending marker" "$TMP/m10f.jsonl"

mktx "$TMP/m10g.jsonl" "I can't ship it until it is waiting on you for the final check"
check 2 "negator more than three words back does not suppress pending marker" "$TMP/m10g.jsonl"

mktx "$TMP/m10h.jsonl" "Nothing else to do; say the word and I'll start"
check 2 "negator before semicolon boundary does not suppress pending marker" "$TMP/m10h.jsonl"

mktx "$TMP/m10i.jsonl" "No changes pushed - waiting on you"
check 2 "negator before spaced-hyphen boundary does not suppress pending marker" "$TMP/m10i.jsonl"

mktx "$TMP/m10j.jsonl" "If not say the word"
check 2 "conditional 'If not' before pending marker still fires" "$TMP/m10j.jsonl"

mktx "$TMP/m10k.jsonl" "Not sure if it's waiting on you"
check 2 "non-governing negator ('Not sure if it's') does not suppress pending marker" "$TMP/m10k.jsonl"

mktx "$TMP/m10l.jsonl" "There is nothing left but waiting on you"
check 2 "negator separated by 'left but' does not suppress pending marker" "$TMP/m10l.jsonl"

mktx "$TMP/m10m.jsonl" "Don't forget for you to test"
check 2 "negator before non-filler verb ('Don't forget') does not suppress pending marker" "$TMP/m10m.jsonl"

export SYG_BQ_PENDING_MARKERS='green light'
mktx "$TMP/m10.jsonl" "Once the build finishes, consider it a green light from me"
check 2 "custom SYG_BQ_PENDING_MARKERS trips on its own pattern" "$TMP/m10.jsonl" "" \
  'consider it a green light from me'
check 0 "custom SYG_BQ_PENDING_MARKERS replaces the default ('say the word' passes)" "$TMP/m1.jsonl"
unset SYG_BQ_PENDING_MARKERS

export SYG_BQ_PENDING_MARKERS=""
check 0 "empty SYG_BQ_PENDING_MARKERS disables the marker pass" "$TMP/m1.jsonl"
check 2 "empty SYG_BQ_PENDING_MARKERS keeps the closing-'?' check active" "$TMP/a.jsonl"
unset SYG_BQ_PENDING_MARKERS

export SYG_BQ_PENDING_MARKERS='['
check 0 "broken SYG_BQ_PENDING_MARKERS regex fails open" "$TMP/m1.jsonl"
unset SYG_BQ_PENDING_MARKERS

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
