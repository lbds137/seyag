#!/bin/bash
# Fixture check for turn-end-shape-gate.sh — run after ANY edit to the hook.
#
# The fixtures are built from the REAL transcript shape, read off the live
# corpus rather than assumed: each assistant entry carries a `.message.content`
# ARRAY holding exactly ONE block (Claude Code splits one API response into one
# JSONL entry per block — the `apiBlockIndex` field indexes it), block types are
# `thinking` / `text` / `tool_use`, a tool call is followed by a `user` entry
# carrying the tool_result, and non-conversation sidecar entries (`attachment`,
# `mode`, `last-prompt`, …) are interleaved throughout. Case (e) additionally
# pins the multi-block reading, so the hook stays correct if Claude Code ever
# stops splitting.
#
# Usage: hooks/turn-end-shape-gate.probe.sh   (from anywhere)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$SCRIPT_DIR/turn-end-shape-gate.sh"

TMPDIR_PROBE=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR_PROBE"; }
trap cleanup EXIT

FAILURES=0

# assistant_block <type> <json-of-extra-fields> — one real-shaped entry.
assistant_block() {
  jq -cn --argjson b "$2" \
    '{type:"assistant",isSidechain:false,apiBlockIndex:0,uuid:"u",timestamp:"t",
      message:{role:"assistant",type:"message",model:"m",content:[$b]}}'
}

user_text() {
  jq -cn --arg t "$1" '{type:"user",isSidechain:false,uuid:"u",timestamp:"t",
    message:{role:"user",content:[{type:"text",text:$t}]}}'
}

user_tool_result() {
  jq -cn '{type:"user",isSidechain:false,uuid:"u",timestamp:"t",
    message:{role:"user",content:[{type:"tool_result",tool_use_id:"tu",content:"ok"}]}}'
}

sidecar() { jq -cn --arg t "$1" '{type:$t,uuid:"u",timestamp:"t"}'; }

THINK='{"type":"thinking","thinking":"weighing it"}'
TEXT='{"type":"text","text":"Done — the report, then the confirmation."}'
TOOLUSE='{"type":"tool_use","id":"tu","name":"Edit","input":{"file_path":"a.ts"}}'

# --- fixture A: turn ends on a text block ------------------------------------
FIX_A="$TMPDIR_PROBE/ends-with-text.jsonl"
{
  user_text "do the unit"
  assistant_block thinking "$THINK"
  assistant_block tool_use "$TOOLUSE"
  user_tool_result
  sidecar attachment
  assistant_block text "$TEXT"
} >"$FIX_A"

# --- fixture B: turn ends on a tool_use block (real shape: tool_result after) -
FIX_B="$TMPDIR_PROBE/ends-with-tool.jsonl"
{
  user_text "do the unit"
  assistant_block text "$TEXT"
  assistant_block thinking "$THINK"
  assistant_block tool_use "$TOOLUSE"
  user_tool_result
} >"$FIX_B"

# --- fixture E: ONE assistant entry, text THEN tool_use in the same array -----
FIX_E="$TMPDIR_PROBE/multiblock-tool-last.jsonl"
{
  user_text "do the unit"
  jq -cn --argjson t "$TEXT" --argjson u "$TOOLUSE" \
    '{type:"assistant",isSidechain:false,uuid:"u",timestamp:"t",
      message:{role:"assistant",content:[$t,$u]}}'
} >"$FIX_E"

# --- fixture F: multi-block entry ending on TEXT (the mirror of E) ------------
FIX_F="$TMPDIR_PROBE/multiblock-text-last.jsonl"
{
  user_text "do the unit"
  jq -cn --argjson t "$TEXT" --argjson u "$TOOLUSE" \
    '{type:"assistant",isSidechain:false,uuid:"u",timestamp:"t",
      message:{role:"assistant",content:[$u,$t]}}'
} >"$FIX_F"

# --- fixture G: last assistant entry ends on a thinking block ----------------
FIX_G="$TMPDIR_PROBE/ends-with-thinking.jsonl"
{
  user_text "do the unit"
  assistant_block thinking "$THINK"
} >"$FIX_G"

# --- fixture H: a SIDECHAIN (subagent) tool_use after the main loop's text ---
# Sidechain entries must not decide the main loop's turn shape.
FIX_H="$TMPDIR_PROBE/sidechain-tool-last.jsonl"
{
  user_text "do the unit"
  assistant_block text "$TEXT"
  jq -cn --argjson u "$TOOLUSE" \
    '{type:"assistant",isSidechain:true,uuid:"u",timestamp:"t",
      message:{role:"assistant",content:[$u]}}'
} >"$FIX_H"

# run <expected-exit> <expect-message-substring|-> <label> <transcript> <active> [<lam-json>|-]
# The optional last arg is the payload's `last_assistant_message` as a JSON
# string literal (e.g. '"text"'); `-` or omitted leaves the field absent.
run() {
  local expected="$1" needle="$2" label="$3" path="$4" active="$5" lam="${6:--}"
  local out actual
  out=$(
    jq -n --arg p "$path" --argjson a "$active" --arg l "$lam" \
      '{transcript_path:$p,stop_hook_active:$a}
       + (if $l == "-" then {} else {last_assistant_message:($l | fromjson)} end)' \
      | ${PROBE_TIMEOUT:+timeout "$PROBE_TIMEOUT"} "$HOOK" 2>&1
  )
  actual=$?
  if [ "$actual" -ne "$expected" ]; then
    printf 'FAIL  (exit %d, expected %d)  %s\n' "$actual" "$expected" "$label"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if [ "$needle" != "-" ] && ! grep -qF "$needle" <<<"$out"; then
    printf 'FAIL  (exit %d ok, message missing %q)  %s\n' "$actual" "$needle" "$label"
    FAILURES=$((FAILURES + 1))
    return
  fi
  printf 'PASS  (exit %d)  %s\n' "$actual" "$label"
}

run 0 - "(a) last assistant block is text → passes" "$FIX_A" false
run 2 "Edit" "(b) last assistant block is tool_use → blocks, names the tool" "$FIX_B" false
run 2 "rules/core.md" "(b) block message cites the rule" "$FIX_B" false
run 0 - "(c) stop_hook_active=true on (b)'s transcript → passes (block-once)" "$FIX_B" true
run 0 - "(d) transcript path missing → passes (fail-open)" "$TMPDIR_PROBE/nope.jsonl" false
run 2 "Edit" "(e) multi-block entry, tool_use last → blocks" "$FIX_E" false
run 0 - "(f) multi-block entry, text last → passes" "$FIX_F" false
run 0 - "(g) last assistant block is thinking → passes" "$FIX_G" false
run 0 - "(h) a sidechain tool_use does not decide the turn" "$FIX_H" false

# --- (i) empty transcript_path in the payload → passes ------------------------
jq -n '{stop_hook_active:false}' | "$HOOK" >/dev/null 2>&1
ACTUAL_I=$?
if [ "$ACTUAL_I" -eq 0 ]; then
  printf 'PASS  (exit %d)  %s\n' "$ACTUAL_I" "(i) no transcript_path key → passes"
else
  printf 'FAIL  (exit %d, expected 0)  %s\n' "$ACTUAL_I" "(i) no transcript_path key → passes"
  FAILURES=$((FAILURES + 1))
fi

# --- (j) a transcript with no assistant entry at all → passes ----------------
FIX_J="$TMPDIR_PROBE/no-assistant.jsonl"
{
  user_text "hello"
  sidecar mode
} >"$FIX_J"
run 0 - "(j) no assistant entry in the tail → passes (fail-open)" "$FIX_J" false

# --- (k) the block path survives the flush-race re-read ----------------------
# The hook re-reads the transcript several times before blocking, so a turn
# whose final text entry has not been flushed yet is not judged on one read.
# A static fixture never changes between reads, so this case exercises the
# whole poll window and must still reach the block — it is the assertion that
# the retry loop did not turn into an unconditional pass. It is the slowest
# case in the probe by design; the added latency is the hook working.
run 2 "Edit" "(k) tool_use-ending transcript still blocks after the re-reads" "$FIX_B" false

# --- (l) a non-JSON line before the tool_use-ending entry must not blind ----
# jq's default stream parser halts at the first parse error and everything
# after it in the stream goes unseen; a bad line inside the 2000-line tail
# would otherwise silently hide a real tool_use-ending turn.
FIX_L="$TMPDIR_PROBE/malformed-line-then-tool.jsonl"
{
  echo "this line is not JSON at all"
  user_text "do the unit"
  assistant_block text "$TEXT"
  assistant_block thinking "$THINK"
  assistant_block tool_use "$TOOLUSE"
  user_tool_result
} >"$FIX_L"
run 2 "Edit" "(l) a non-JSON line before the tool_use entry still blocks" "$FIX_L" false

# --- payload field `last_assistant_message` (Claude Code 2.1.289+) -----------
# The Stop payload carries the turn's final assistant text, which can exist
# before the transcript flushes it. Labels are prefixed "payload" because (l)
# above is already taken by the malformed-line case.

# split shape: two entries sharing one message.id (text, then tool_use)
msg_block() {
  jq -cn --arg id "$1" --argjson b "$2" \
    '{type:"assistant",isSidechain:false,uuid:"u",timestamp:"t",
      message:{id:$id,role:"assistant",content:[$b]}}'
}
CHECKING='{"type":"text","text":"Checking."}'
LONGTEXT_STR="A long closing paragraph that precedes the tool call."
LONGTEXT=$(jq -cn --arg t "$LONGTEXT_STR" '{type:"text",text:$t}')
LAM_MARKER="… [+99 chars]"

FIX_N="$TMPDIR_PROBE/split-same-id.jsonl"
{
  user_text "do the unit"
  msg_block m1 "$CHECKING"
  msg_block m1 "$TOOLUSE"
  user_tool_result
} >"$FIX_N"

FIX_E2="$TMPDIR_PROBE/multiblock-checking-tool-last.jsonl"
{
  user_text "do the unit"
  jq -cn --argjson t "$CHECKING" --argjson u "$TOOLUSE" \
    '{type:"assistant",isSidechain:false,uuid:"u",timestamp:"t",
      message:{role:"assistant",content:[$t,$u]}}'
} >"$FIX_E2"

FIX_P="$TMPDIR_PROBE/split-same-id-long.jsonl"
{
  user_text "do the unit"
  msg_block m1 "$LONGTEXT"
  msg_block m1 "$TOOLUSE"
  user_tool_result
} >"$FIX_P"

# the real shape: SendMessage tool_use, its tool_result, final text not on disk
FIX_Q="$TMPDIR_PROBE/sendmessage-then-result.jsonl"
{
  user_text "do the unit"
  msg_block m1 '{"type":"tool_use","id":"tu","name":"SendMessage","input":{}}'
  user_tool_result
} >"$FIX_Q"

run 0 - "(payload-l) tool-ending transcript + LAM naming other text → passes" "$FIX_B" false '"Final report text."'
run 2 "Edit" "(payload-m) LAM equals the tool-ending message's own text → blocks" "$FIX_E2" false '"Checking."'
run 2 "Edit" "(payload-n) split same-id entries, LAM equals their text → blocks" "$FIX_N" false '"Checking."'
run 2 "Edit" "(payload-o) empty LAM keeps the old behavior → blocks" "$FIX_B" false '""'
run 2 "Edit" "(payload-p) truncated LAM that is a prefix of own text → blocks" "$FIX_P" false \
  "$(jq -cn --arg t "${LONGTEXT_STR:0:20}$LAM_MARKER" '$t')"
run 0 - "(payload-q) SendMessage-ending shape, final text unflushed → passes" "$FIX_Q" false '"Seyag 0.3.31 is merged."'
run 0 - "(payload-r) non-matching LAM with stop_hook_active=true → passes" "$FIX_B" true '"Final report text."'

# --- hardening cases: whitespace, multi-block joins, odd lines, locale, speed -
FIX_S="$TMPDIR_PROBE/whitespace-text.jsonl"
{
  user_text "do the unit"
  msg_block m1 '{"type":"text","text":"  \n Checking.\n"}'
  msg_block m1 "$TOOLUSE"
  user_tool_result
} >"$FIX_S"
run 2 "Edit" "(payload-s) own text trimmed of surrounding whitespace → blocks" "$FIX_S" false '"Checking."'

FIX_T="$TMPDIR_PROBE/two-text-blocks.jsonl"
{
  user_text "do the unit"
  jq -cn --argjson u "$TOOLUSE" \
    '{type:"assistant",isSidechain:false,uuid:"u",timestamp:"t",
      message:{id:"m1",role:"assistant",content:[{type:"text",text:"A"},{type:"text",text:"B"},$u]}}'
  user_tool_result
} >"$FIX_T"
run 2 "Edit" "(payload-t) two text blocks join with newline, LAM equals the join → blocks" "$FIX_T" false '"A\nB"'

FIX_U="$TMPDIR_PROBE/non-object-line.jsonl"
{
  user_text "do the unit"
  echo 5
  msg_block m1 "$CHECKING"
  msg_block m1 "$TOOLUSE"
  user_tool_result
} >"$FIX_U"
run 2 "Edit" "(payload-u) a bare-number line in the tail does not blind the own-text read → blocks" "$FIX_U" false '"Checking."'

FIX_V="$TMPDIR_PROBE/no-id-thinking-text-tool.jsonl"
{
  user_text "do the unit"
  jq -cn --argjson t "$THINK" --argjson x "$CHECKING" --argjson u "$TOOLUSE" \
    '{type:"assistant",isSidechain:false,uuid:"u",timestamp:"t",
      message:{role:"assistant",content:[$t,$x,$u]}}'
  user_tool_result
} >"$FIX_V"
run 2 "Edit" "(payload-v) an entry with no message.id uses its own text → blocks" "$FIX_V" false '"Checking."'

run 0 - "(payload-w) non-matching truncated LAM → passes" "$FIX_P" false '"Other text… [+9 chars]"'

LC_ALL=C run 2 "Edit" "(payload-x) truncated-prefix match under LC_ALL=C → blocks" "$FIX_P" false \
  "$(jq -cn --arg t "${LONGTEXT_STR:0:20}$LAM_MARKER" '$t')"

FIX_Y="$TMPDIR_PROBE/long-space-run.jsonl"
{
  user_text "do the unit"
  # --rawfile: a 200 KB --arg would exceed the argv limit and silently empty the fixture
  { printf 'a'; printf '%200000s' ''; printf 'b'; } >"$TMPDIR_PROBE/spaces.txt"
  jq -cn --rawfile s "$TMPDIR_PROBE/spaces.txt" --argjson u "$TOOLUSE" \
    '{type:"assistant",isSidechain:false,uuid:"u",timestamp:"t",
      message:{id:"m1",role:"assistant",content:[{type:"text",text:$s},$u]}}'
  user_tool_result
} >"$FIX_Y"
PROBE_TIMEOUT=5 run 0 - "(payload-y) a 200000-space text run finishes inside 5 s → passes" "$FIX_Y" false '"x"'

exit $FAILURES
