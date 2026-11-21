#!/bin/bash
# Fixture check for ask-pretext-guard.sh — run after ANY edit to the hook.
# Pins rule (a) pointer blocking (question, header, option label/description/preview,
# threshold "above 95%" and first-person narration non-matches, missing transcript)
# and rule (b) readable earlier-message `!` commands and fenced code blocks in the
# current turn (block once per turn via XDG_STATE_HOME, carried command/fence pass,
# pre-ask prose without code pass, prior-turn code ignored, unwritable state dir
# fail-open), plus headless and SYG_DISABLE=ask-pretext via run.sh.
#
# Usage: plugins/seyag/hooks/ask-pretext-guard.probe.sh   (from anywhere)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="${HOOK:-$SCRIPT_DIR/ask-pretext-guard.sh}"
RUN_SH="$SCRIPT_DIR/run.sh"
CLAUDE_PROJECT_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
export CLAUDE_PROJECT_DIR
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export XDG_STATE_HOME="$TMP/state"
export XDG_CACHE_HOME="$TMP/cache"

TICK=$(printf '\140')
FENCE="${TICK}${TICK}${TICK}"

# Build a PreToolUse transcript (records on disk BEFORE the current AskUserQuestion):
# genuine user line, then an optional earlier assistant text record in the same turn.
# $1=out $2=earlier_text (empty = user line only)
mktx() {
  OUT="$1" PRE="${2:-}" UUID="${UUID:-u-turn-1}" python3 -I -B - << 'PY'
import json, os
rows = [
    {"type": "user", "uuid": os.environ["UUID"], "isMeta": None, "message": {"content": "go"}},
]
if os.environ["PRE"]:
    rows.append({
        "type": "assistant",
        "message": {"id": "msg_earlier", "content": [{"type": "text", "text": os.environ["PRE"]}]},
    })
with open(os.environ["OUT"], "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
PY
}

fail=0
NCASE=0

# check EXPECTED_EXIT LABEL TRANSCRIPT QUESTION [OPTS_JSON [HEADER [STDERR_REGEX...]]]
check() {
  local want="$1" label="$2" tx="$3" q="$4" opts="${5:-[]}" hdr="${6:-}"
  shift $(( $# >= 6 ? 6 : $# ))
  NCASE=$((NCASE + 1))
  local payload got pat
  payload=$(Q="$q" OPTS="$opts" HDR="$hdr" TX="$tx" SID="${SID:-case-$NCASE}" python3 -I -B - << 'PY'
import json, os
qobj = {"question": os.environ["Q"], "options": json.loads(os.environ["OPTS"])}
if os.environ["HDR"]:
    qobj["header"] = os.environ["HDR"]
obj = {
    "tool_name": "AskUserQuestion",
    "tool_input": {"questions": [qobj]},
    "session_id": os.environ["SID"],
}
if os.environ["TX"]:
    obj["transcript_path"] = os.environ["TX"]
print(json.dumps(obj))
PY
)
  printf '%s' "$payload" | "$HOOK" >/dev/null 2>"$TMP/stderr.out"
  got=$?
  if [ "$got" != "$want" ]; then
    echo "FAIL [$got≠$want]: $label (stderr: $(tr '\n' ' ' <"$TMP/stderr.out"))"
    fail=1
    return
  fi
  for pat in "$@"; do
    if [ "${pat#!}" != "$pat" ]; then
      if grep -qE -e "${pat#!}" "$TMP/stderr.out"; then
        echo "FAIL [stderr matches /${pat#!}/ but must not]: $label"
        fail=1
        return
      fi
    elif ! grep -qE -e "$pat" "$TMP/stderr.out"; then
      echo "FAIL [stderr misses /$pat/]: $label (stderr: $(tr '\n' ' ' <"$TMP/stderr.out"))"
      fail=1
      return
    fi
  done
  echo "ok   [$got]: $label"
}

mktx "$TMP/clean.jsonl" ""

# 1. pointer in the question -> block, message quotes the phrase
check 2 "pointer in the question blocks and quotes the phrase" "$TMP/clean.jsonl" \
  "Should I run the command in my message above?" "[]" "" \
  'ASK POINTS OUTSIDE ITSELF — blocked' '\("in my message"\)'

# 2. pointer in an option description -> block
check 2 "pointer in an option description blocks" "$TMP/clean.jsonl" \
  "Which path should we take?" '[{"label":"A","description":"Use the plan described above"}]' "" \
  'ASK POINTS OUTSIDE ITSELF — blocked' '\("described above"\)'

# 2b. pointer in question header and option preview -> block
check 2 "pointer in question header blocks" "$TMP/clean.jsonl" \
  "Pick one" '[]' "See above" \
  'ASK POINTS OUTSIDE ITSELF — blocked' '\("See above"\)'
check 2 "pointer in option preview blocks" "$TMP/clean.jsonl" \
  "Pick one" '[{"label":"A","preview":"As I mentioned earlier, run the check"}]' "" \
  'ASK POINTS OUTSIDE ITSELF — blocked' '\("As I mentioned"\)'

# 3. threshold "stop above 95%" -> pass
check 0 "'stop above 95%' threshold passes" "$TMP/clean.jsonl" \
  "Should the gate stop above 95% or stay below 80%?"

# 4. first-person narration without a pointer -> pass
check 0 "first-person narration without a pointer passes" "$TMP/clean.jsonl" \
  "I checked the logs; which fix do you want?"

# 4b. option-to-option "Same as above, but faster" -> pass; "the command above" -> still blocks
check 0 "option description 'Same as above, but faster' passes" "$TMP/clean.jsonl" \
  "Which mode should we use?" '[{"label":"Fast","description":"Same as above, but faster"}]'
check 2 "question 'the command above is ready; run it?' still blocks" "$TMP/clean.jsonl" \
  "the command above is ready; run it?" "[]" "" \
  'ASK POINTS OUTSIDE ITSELF — blocked' '\("the command above"\)'

# 5. readable earlier-message `!` line not in the ask -> block once, then identical retry passes
CMD="gh pr merge 12 --rebase"
mktx "$TMP/cmd.jsonl" "When ready, run: ! $CMD"
SID=sess-retry check 2 "earlier-message ! command not in ask blocks on first attempt" "$TMP/cmd.jsonl" \
  "Did you merge it?" "[]" "" \
  'ASK AFTER HIDDEN CODE — blocked once' "  ! $CMD" 'This fires once per turn'
SID=sess-retry check 0 "identical retry in same turn passes via state" "$TMP/cmd.jsonl" \
  "Did you merge it?"

# 6. the same `!` line carried inside the question -> pass
check 0 "earlier-message ! command carried inside the question passes" "$TMP/cmd.jsonl" \
  "Run ${TICK}! $CMD${TICK} and tell me when done."

# 6b. the same `!` line carried inside an option description -> pass
check 0 "earlier-message ! command carried inside an option description passes" "$TMP/cmd.jsonl" \
  "Ready to merge?" "[{\"label\":\"Yes\",\"description\":\"I ran ! $CMD\"}]"

# 6c. earlier-message `! git push origin main` carried across extra spaces and a newline -> pass
mktx "$TMP/cmd-ws.jsonl" "Run: ! git push origin main"
check 0 "earlier-message ! command carried with extra spaces and a newline passes" "$TMP/cmd-ws.jsonl" \
  "$(printf 'Run  git   push origin\nmain ?')"

# 6d. sidechain assistant record in the current turn holding `! rm x` not in the ask -> pass
cat > "$TMP/sidechain-cmd.jsonl" <<'EOF'
{"type":"user","uuid":"u-sc","isMeta":null,"message":{"content":"go"}}
{"type":"assistant","isSidechain":true,"message":{"id":"m-sc","content":[{"type":"text","text":"! rm x"}]}}
EOF
check 0 "sidechain assistant ! command in current turn not in ask passes" "$TMP/sidechain-cmd.jsonl" \
  "Which option should we pick?"

# 7. earlier-message fenced block not in the ask -> block
mktx "$TMP/fence.jsonl" "Here is the snippet:
${FENCE}bash
pnpm --filter app test
pnpm --filter app typecheck
${FENCE}"
check 2 "earlier-message fenced block not in the ask blocks" "$TMP/fence.jsonl" \
  "Which suite should we run first?" "[]" "" \
  'ASK AFTER HIDDEN CODE — blocked once' '  fenced block: pnpm --filter app test'

# 7b. earlier-message fenced block carried across ask fields -> pass
check 0 "earlier-message fenced block carried in ask fields passes" "$TMP/fence.jsonl" \
  "Run pnpm --filter app test and pnpm --filter app typecheck?"

# 8. pre-ask prose without code -> pass
mktx "$TMP/prose.jsonl" "I inspected the three modules and verified the config loader."
check 0 "pre-ask prose without code passes" "$TMP/prose.jsonl" \
  "Which module should we refactor first?"

# 9. a `!` line only in a PRIOR turn (before the genuine user entry) -> pass
cat > "$TMP/prior-turn.jsonl" <<EOF
{"type":"user","uuid":"u0","isMeta":null,"message":{"content":"start"}}
{"type":"assistant","message":{"id":"m0","content":[{"type":"text","text":"Run: ! $CMD"}]}}
{"type":"user","uuid":"u1","isMeta":null,"message":{"content":"done, next task"}}
{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Checking the next item."}]}}
EOF
check 0 "! command only in a prior turn passes" "$TMP/prior-turn.jsonl" \
  "Which item do you want next?"

# 9b. a "Stop hook feedback:" user entry is not a turn boundary
cat > "$TMP/feedback-turn.jsonl" <<EOF
{"type":"user","uuid":"u1","isMeta":null,"message":{"content":"start"}}
{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Run: ! $CMD"}]}}
{"type":"user","uuid":"u2","isMeta":null,"message":{"content":"Stop hook feedback: [x] blocked"}}
EOF
check 2 "'Stop hook feedback:' is not a turn boundary" "$TMP/feedback-turn.jsonl" \
  "Did you run it?" "[]" "" \
  'ASK AFTER HIDDEN CODE — blocked once' "  ! $CMD"

# 10. missing transcript + pointer -> block; missing transcript + no pointer -> pass
check 2 "missing transcript + pointer still blocks (rule a needs only tool_input)" "$TMP/no-such-file.jsonl" \
  "Use the options listed above?" "[]" "" \
  'ASK POINTS OUTSIDE ITSELF — blocked' '\("listed above"\)'
check 0 "missing transcript + no pointer passes (rule b fails open)" "$TMP/no-such-file.jsonl" \
  "Which option do you prefer?"

# 10b. when (a) and (b) both apply, (a) wins and no (b) state is written
SID=sess-both check 2 "rule (a) + rule (b): rule (a) message wins" "$TMP/cmd.jsonl" \
  "Did you run the command above?" "[]" "" \
  'ASK POINTS OUTSIDE ITSELF — blocked' '!ASK AFTER HIDDEN CODE'
SID=sess-both check 2 "rule (a) + rule (b): no rule (b) state was written, so removing pointer still blocks once on (b)" "$TMP/cmd.jsonl" \
  "Did you run it?" "[]" "" \
  'ASK AFTER HIDDEN CODE — blocked once'

# 11. unwritable state dir + rule (b) -> pass (never blocks without state)
touch "$TMP/not-a-dir"
XDG_STATE_HOME="$TMP/not-a-dir" check 0 "unwritable state dir + rule (b) passes so retry cannot loop" "$TMP/cmd.jsonl" \
  "Did you merge it?"

# 12. headless (CLAUDE_CODE_ENTRYPOINT=sdk-cli via run.sh) -> pass
PAYLOAD_PTR='{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"See the command above?"}]}}'
printf '%s' "$PAYLOAD_PTR" | env -u SYG_PROFILE -u SYG_ENABLE -u SYG_DISABLE \
  CLAUDE_CODE_ENTRYPOINT=sdk-cli bash "$RUN_SH" ask-pretext-guard >/dev/null 2>"$TMP/stderr.out"
got=$?
if [ "$got" = 0 ]; then
  echo "ok   [0]: headless (CLAUDE_CODE_ENTRYPOINT=sdk-cli via run.sh) passes"
else
  echo "FAIL [$got≠0]: headless via run.sh should pass"
  fail=1
fi

# 13. SYG_DISABLE=ask-pretext via run.sh -> pass
printf '%s' "$PAYLOAD_PTR" | env -u SYG_PROFILE -u SYG_ENABLE -u CLAUDE_CODE_ENTRYPOINT \
  SYG_DISABLE=ask-pretext bash "$RUN_SH" ask-pretext-guard >/dev/null 2>"$TMP/stderr.out"
got=$?
if [ "$got" = 0 ]; then
  echo "ok   [0]: SYG_DISABLE=ask-pretext via run.sh passes"
else
  echo "FAIL [$got≠0]: SYG_DISABLE=ask-pretext via run.sh should pass"
  fail=1
fi

# 14. unparseable input fails open
printf 'not json\n' | "$HOOK" >/dev/null 2>"$TMP/stderr.out"
got=$?
if [ "$got" = 0 ]; then
  echo "ok   [0]: unparseable input fails open"
else
  echo "FAIL [$got≠0]: unparseable input should exit 0"
  fail=1
fi

# 15. state files older than 7 days are pruned on write; fresh ones stay
PDIR="$XDG_STATE_HOME/seyag/ask-pretext-guard"
mkdir -p "$PDIR"
touch -d '8 days ago' "$PDIR/stale-sess"
touch -d '2 days ago' "$PDIR/fresh-sess"
check 2 "prune case: blocking write runs" "$TMP/cmd.jsonl" "Did you merge it?"
if [ ! -e "$PDIR/stale-sess" ] && [ -e "$PDIR/fresh-sess" ]; then
  echo "ok   [prune]: stale state file pruned, fresh kept"
else
  echo "FAIL [prune]: stale present=$([ -e "$PDIR/stale-sess" ] && echo y || echo n) fresh present=$([ -e "$PDIR/fresh-sess" ] && echo y || echo n)"
  fail=1
fi

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
