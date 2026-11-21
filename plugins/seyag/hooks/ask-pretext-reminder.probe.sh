#!/bin/bash
# Fixture check for ask-pretext-reminder.sh — run after ANY edit to the hook.
# Pins same-message pre-ask text character count threshold (default 200 and
# SYG_ASK_PRETEXT_MIN_CHARS override + non-integer fallback), `!` command and
# fenced code block `<extras>` triggers below the character threshold, silence
# when text is only in an earlier message (different message.id) or after the
# tool_use, silence when tool_use_id is missing from the transcript, and
# headless / SYG_DISABLE=ask-pretext-reminder skips via run.sh.
#
# Usage: plugins/seyag/hooks/ask-pretext-reminder.probe.sh   (from anywhere)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="${HOOK:-$SCRIPT_DIR/ask-pretext-reminder.sh}"
RUN_SH="$SCRIPT_DIR/run.sh"
CLAUDE_PROJECT_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
export CLAUDE_PROJECT_DIR
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export XDG_STATE_HOME="$TMP/state"
export XDG_CACHE_HOME="$TMP/cache"
unset SYG_ASK_PRETEXT_MIN_CHARS

TICK=$(printf '\140')
FENCE="${TICK}${TICK}${TICK}"

# Build a PostToolUse transcript:
# genuine user line, optional earlier-message assistant text (msg_earlier),
# optional same-message assistant text before the ask (msg_ask), then the
# AskUserQuestion tool_use record (msg_ask, id=ASKID), then optional post-ask
# same-message text.
# $1=out $2=same_msg_pre_text $3=earlier_msg_text (optional) $4=post_ask_text (optional)
mktx() {
  OUT="$1" SAME="${2:-}" EARLIER="${3:-}" POST="${4:-}" ASKID="${ASKID:-tu-1}" MID="${MID:-msg_ask}" python3 -I -B - << 'PY'
import json, os
rows = [
    {"type": "user", "isMeta": None, "message": {"content": "go"}},
]
if os.environ["EARLIER"]:
    rows.append({
        "type": "assistant",
        "message": {"id": "msg_earlier", "content": [{"type": "text", "text": os.environ["EARLIER"]}]},
    })
if os.environ["SAME"]:
    rows.append({
        "type": "assistant",
        "message": {"id": os.environ["MID"], "content": [{"type": "text", "text": os.environ["SAME"]}]},
    })
rows.append({
    "type": "assistant",
    "message": {
        "id": os.environ["MID"],
        "content": [{
            "type": "tool_use",
            "id": os.environ["ASKID"],
            "name": "AskUserQuestion",
            "input": {"questions": [{"question": "Which option?", "options": []}]},
        }],
    },
})
if os.environ["POST"]:
    rows.append({
        "type": "assistant",
        "message": {"id": os.environ["MID"], "content": [{"type": "text", "text": os.environ["POST"]}]},
    })
with open(os.environ["OUT"], "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
PY
}

fail=0

run_reminder() { # $1=transcript $2=tool_use_id [env overrides...]
  local tx="$1" tuid="${2:-tu-1}"
  shift 2
  local payload
  payload=$(jq -nc --arg tx "$tx" --arg id "$tuid" '{
    tool_name: "AskUserQuestion",
    tool_input: {questions: [{question: "Which option?", options: []}]},
    tool_use_id: $id,
    hook_event_name: "PostToolUse",
    session_id: "sess-rem",
    transcript_path: $tx,
    tool_response: {answers: {}}
  }')
  printf '%s' "$payload" | env "$@" "$HOOK" 2>"$TMP/stderr.out"
}

check_fires() { # $1=label $2=out $3=expected_substring...
  local label="$1" out="$2" rc="$3"
  shift 3
  if [ "$rc" != 0 ]; then
    echo "FAIL [rc $rc≠0]: $label"
    fail=1
    return
  fi
  local ev ctx pat
  ev=$(jq -r '.hookSpecificOutput.hookEventName // empty' <<<"$out" 2>/dev/null)
  ctx=$(jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$out" 2>/dev/null)
  if [ "$ev" != "PostToolUse" ] || [ -z "$ctx" ]; then
    echo "FAIL [missing PostToolUse additionalContext]: $label (out: $out)"
    fail=1
    return
  fi
  for pat in "$@"; do
    if [ "${pat#!}" != "$pat" ]; then
      if [[ "$ctx" == *"${pat#!}"* ]]; then
        echo "FAIL [ctx contains '${pat#!}' but must not]: $label (ctx: $ctx)"
        fail=1
        return
      fi
    elif [[ "$ctx" != *"$pat"* ]]; then
      echo "FAIL [ctx misses '$pat']: $label (ctx: $ctx)"
      fail=1
      return
    fi
  done
  echo "ok   [fires]: $label"
}

check_silent() { # $1=label $2=out $3=rc
  if [ "$3" = 0 ] && [ -z "$2" ]; then
    echo "ok   [silent]: $1"
  else
    echo "FAIL [want silent exit 0, got rc=$3 out='$2']: $1"
    fail=1
  fi
}

TEXT_250=$(python3 -I -B -c 'print("a" * 250, end="")')
TEXT_300=$(python3 -I -B -c 'print("c" * 300, end="")')
TEXT_50=$(python3 -I -B -c 'print("b" * 50, end="")')

# 1. same-message text of 250 chars -> fires, and N is right
mktx "$TMP/250.jsonl" "$TEXT_250"
OUT=$(run_reminder "$TMP/250.jsonl" "tu-1")
check_fires "same-message text of 250 chars fires with exact N" "$OUT" "$?" \
  "ask-pretext-reminder: you wrote 250 characters in the same message before this AskUserQuestion. Some clients hide that text behind the ask dialog" \
  "!including"

# 2. 50 chars without code -> silent
mktx "$TMP/50.jsonl" "$TEXT_50"
OUT=$(run_reminder "$TMP/50.jsonl" "tu-1")
check_silent "50 chars without code is silent" "$OUT" "$?"

# 3. 50 chars with a `!` line -> fires with the command extra
CMD_TEXT="Run this first: ! gh pr merge 9 --rebase"
CMD_LEN=${#CMD_TEXT}
mktx "$TMP/50cmd.jsonl" "$CMD_TEXT"
OUT=$(run_reminder "$TMP/50cmd.jsonl" "tu-1")
check_fires "short text with a ! command fires with command extra" "$OUT" "$?" \
  "ask-pretext-reminder: you wrote ${CMD_LEN} characters in the same message before this AskUserQuestion, including a \`!\` command. Some clients hide"

# 3b. short text with a fenced code block -> fires with the fenced block extra
FENCE_TEXT="Code:
${FENCE}
echo hi
${FENCE}"
FENCE_LEN=${#FENCE_TEXT}
mktx "$TMP/50fence.jsonl" "$FENCE_TEXT"
OUT=$(run_reminder "$TMP/50fence.jsonl" "tu-1")
check_fires "short text with a fenced block fires with fenced code block extra" "$OUT" "$?" \
  "ask-pretext-reminder: you wrote ${FENCE_LEN} characters in the same message before this AskUserQuestion, including a fenced code block. Some clients hide"

# 3c. short text with BOTH a `!` command and a fenced block -> fires with both extras
BOTH_TEXT="Run ! echo one or:
${FENCE}
echo two
${FENCE}"
BOTH_LEN=${#BOTH_TEXT}
mktx "$TMP/50both.jsonl" "$BOTH_TEXT"
OUT=$(run_reminder "$TMP/50both.jsonl" "tu-1")
check_fires "short text with both ! command and fenced block includes both extras" "$OUT" "$?" \
  "ask-pretext-reminder: you wrote ${BOTH_LEN} characters in the same message before this AskUserQuestion, including a \`!\` command, including a fenced code block. Some clients hide"

# 4. text in an EARLIER message only -> silent
mktx "$TMP/earlier.jsonl" "" "$TEXT_250"
OUT=$(run_reminder "$TMP/earlier.jsonl" "tu-1")
check_silent "text in an earlier message only (different message.id) is silent" "$OUT" "$?"

# 4b. text in the same message AFTER the tool_use record is not counted
mktx "$TMP/post.jsonl" "" "" "$TEXT_250"
OUT=$(run_reminder "$TMP/post.jsonl" "tu-1")
check_silent "text after the tool_use record is not counted" "$OUT" "$?"

# 4c. one assistant record with [50-char text, tool_use, 300-char text] -> silent
T50="$TEXT_50" T300="$TEXT_300" OUT_PATH="$TMP/same-rec-post.jsonl" python3 -I -B - << 'PY'
import json, os
rows = [
    {"type": "user", "isMeta": None, "message": {"content": "go"}},
    {
        "type": "assistant",
        "message": {
            "id": "msg_ask",
            "content": [
                {"type": "text", "text": os.environ["T50"]},
                {
                    "type": "tool_use",
                    "id": "tu-1",
                    "name": "AskUserQuestion",
                    "input": {"questions": [{"question": "Which option?", "options": []}]},
                },
                {"type": "text", "text": os.environ["T300"]},
            ],
        },
    },
]
with open(os.environ["OUT_PATH"], "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
PY
OUT=$(run_reminder "$TMP/same-rec-post.jsonl" "tu-1")
check_silent "single assistant record with [50-char text, tool_use, 300-char text] is silent" "$OUT" "$?"

# 4d. 300-char sidechain record with the same message.id before the ask + 50 chars main-lane -> silent
T50="$TEXT_50" T300="$TEXT_300" OUT_PATH="$TMP/sidechain-same-mid.jsonl" python3 -I -B - << 'PY'
import json, os
rows = [
    {"type": "user", "isMeta": None, "message": {"content": "go"}},
    {
        "type": "assistant",
        "isSidechain": True,
        "message": {"id": "msg_ask", "content": [{"type": "text", "text": os.environ["T300"]}]},
    },
    {
        "type": "assistant",
        "message": {"id": "msg_ask", "content": [{"type": "text", "text": os.environ["T50"]}]},
    },
    {
        "type": "assistant",
        "message": {
            "id": "msg_ask",
            "content": [{
                "type": "tool_use",
                "id": "tu-1",
                "name": "AskUserQuestion",
                "input": {"questions": [{"question": "Which option?", "options": []}]},
            }],
        },
    },
]
with open(os.environ["OUT_PATH"], "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
PY
OUT=$(run_reminder "$TMP/sidechain-same-mid.jsonl" "tu-1")
check_silent "300-char sidechain record with same message.id + 50-char main-lane is silent" "$OUT" "$?"

# 5. tool_use id not in the transcript -> silent
OUT=$(run_reminder "$TMP/250.jsonl" "no-such-tool-use-id")
check_silent "tool_use_id not in transcript is silent" "$OUT" "$?"

# 6. SYG_ASK_PRETEXT_MIN_CHARS=40 with 50 chars -> fires
OUT=$(run_reminder "$TMP/50.jsonl" "tu-1" SYG_ASK_PRETEXT_MIN_CHARS=40)
check_fires "SYG_ASK_PRETEXT_MIN_CHARS=40 with 50 chars fires" "$OUT" "$?" \
  "ask-pretext-reminder: you wrote 50 characters in the same message before this AskUserQuestion."

# 7. a non-integer knob -> default (200): 50 chars stays silent, 250 chars fires
OUT=$(run_reminder "$TMP/50.jsonl" "tu-1" SYG_ASK_PRETEXT_MIN_CHARS=not-an-int)
check_silent "non-integer SYG_ASK_PRETEXT_MIN_CHARS falls back to 200 (50 chars silent)" "$OUT" "$?"
OUT=$(run_reminder "$TMP/250.jsonl" "tu-1" SYG_ASK_PRETEXT_MIN_CHARS=not-an-int)
check_fires "non-integer SYG_ASK_PRETEXT_MIN_CHARS falls back to 200 (250 chars fires)" "$OUT" "$?" \
  "you wrote 250 characters"

# 8. the disable switch (and headless) via run.sh -> silent
PAYLOAD_250=$(jq -nc --arg tx "$TMP/250.jsonl" '{
  tool_name: "AskUserQuestion",
  tool_input: {questions: [{question: "Which option?", options: []}]},
  tool_use_id: "tu-1",
  hook_event_name: "PostToolUse",
  session_id: "sess-rem",
  transcript_path: $tx
}')
OUT=$(printf '%s' "$PAYLOAD_250" | env -u SYG_PROFILE -u SYG_ENABLE -u CLAUDE_CODE_ENTRYPOINT \
  SYG_DISABLE=ask-pretext-reminder bash "$RUN_SH" ask-pretext-reminder 2>"$TMP/stderr.out")
check_silent "SYG_DISABLE=ask-pretext-reminder via run.sh is silent" "$OUT" "$?"

OUT=$(printf '%s' "$PAYLOAD_250" | env -u SYG_PROFILE -u SYG_ENABLE -u SYG_DISABLE \
  CLAUDE_CODE_ENTRYPOINT=sdk-cli bash "$RUN_SH" ask-pretext-reminder 2>"$TMP/stderr.out")
check_silent "headless (CLAUDE_CODE_ENTRYPOINT=sdk-cli) via run.sh is silent" "$OUT" "$?"

# 9. missing / unparseable transcript or input -> silent exit 0
OUT=$(run_reminder "$TMP/does-not-exist.jsonl" "tu-1")
check_silent "missing transcript is silent" "$OUT" "$?"
printf 'not json\n' | "$HOOK" >"$TMP/out.bad" 2>"$TMP/stderr.out"
check_silent "unparseable input is silent" "$(cat "$TMP/out.bad")" "$?"

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
