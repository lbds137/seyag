#!/usr/bin/env bash
# Probe for classifier-ledger.sh.
# Exercises JSONL append with 500-char error (300-char truncation) and
# 400-char command (200-char truncation), non-Bash payload without command,
# env-unset inertness, malformed-JSON fail-open, unwritable-path fail-open,
# and run.sh --event PostToolUseFailure wrapper integration.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HOOK_DIR/classifier-ledger.sh"
RUNNER="$HOOK_DIR/run.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

ok() {
  echo "ok:   $1"
  pass=$((pass + 1))
}

bad() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}

# --- 1. Write with 500-char error and 400-char command ---
ERR_500=$(printf 'E%.0s' $(seq 1 500))
CMD_400=$(printf 'C%.0s' $(seq 1 400))
LEDGER="$TMP/sub/ledger.jsonl"

PAYLOAD=$(jq -nc \
  --arg err "$ERR_500" \
  --arg cmd "$CMD_400" \
  '{
    session_id: "sess-alpha-01",
    tool_name: "Bash",
    tool_input: {command: $cmd},
    error: $err,
    is_interrupt: false,
    duration_ms: 42
  }')

OUT=$( (umask 022; printf '%s' "$PAYLOAD" | env -i PATH="$PATH" HOME="$HOME" SYG_CLASSIFIER_LEDGER="$LEDGER" bash "$HOOK") 2>&1 )
RC=$?

[ "$RC" -eq 0 ] && ok "write exit 0" || bad "write exit 0"
[ -z "$OUT" ] && ok "write stdout empty" || bad "write stdout empty"
[ -f "$LEDGER" ] && ok "ledger file created" || bad "ledger file created"
[ "$(stat -c %a "$(dirname "$LEDGER")")" = "700" ] && ok "ledger dir mode is 700" || bad "ledger dir mode is 700"
[ "$(stat -c %a "$LEDGER")" = "600" ] && ok "ledger file mode is 600" || bad "ledger file mode is 600"
[ "$(wc -l < "$LEDGER")" -eq 1 ] && ok "ledger line count is 1" || bad "ledger line count is 1"

LINE=$(cat "$LEDGER")
ERR_LEN=$(printf '%s' "$LINE" | jq -r '.error | length')
CMD_LEN=$(printf '%s' "$LINE" | jq -r '.command | length')
SESS_VAL=$(printf '%s' "$LINE" | jq -r '.session_id')
TOOL_VAL=$(printf '%s' "$LINE" | jq -r '.tool_name')
INTR_VAL=$(printf '%s' "$LINE" | jq -r '.is_interrupt')
TS_VAL=$(printf '%s' "$LINE" | jq -r '.ts')

[ "$ERR_LEN" -eq 300 ] && ok "error truncated to 300 chars" || bad "error truncated to 300 chars"
[ "$CMD_LEN" -eq 200 ] && ok "command truncated to 200 chars" || bad "command truncated to 200 chars"
[ "$SESS_VAL" = "sess-alpha-01" ] && ok "session_id preserved" || bad "session_id preserved"
[ "$TOOL_VAL" = "Bash" ] && ok "tool_name preserved" || bad "tool_name preserved"
[ "$INTR_VAL" = "false" ] && ok "is_interrupt preserved" || bad "is_interrupt preserved"
[ -n "$TS_VAL" ] && ok "ts populated" || bad "ts populated"

# --- 2. Non-Bash tool without .tool_input.command ---
PAYLOAD_READ='{"session_id":"sess-alpha-02","tool_name":"Read","tool_input":{"file_path":"/tmp/missing"},"error":"File not found","is_interrupt":true}'
OUT=$(printf '%s' "$PAYLOAD_READ" | env -i PATH="$PATH" HOME="$HOME" SYG_CLASSIFIER_LEDGER="$LEDGER" bash "$HOOK" 2>&1)
RC=$?
LINE2=$(tail -n 1 "$LEDGER")
HAS_CMD=$(printf '%s' "$LINE2" | jq -r 'has("command")')
INTR2=$(printf '%s' "$LINE2" | jq -r '.is_interrupt')

[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "non-bash write exit 0" || bad "non-bash write exit 0"
[ "$HAS_CMD" = "false" ] && ok "non-bash omits command field" || bad "non-bash omits command field"
[ "$INTR2" = "true" ] && ok "non-bash preserves is_interrupt=true" || bad "non-bash preserves is_interrupt=true"

# --- 3. Env unset is inert ---
UNSET_LEDGER="$TMP/should-not-exist.jsonl"
OUT=$(printf '%s' "$PAYLOAD" | env -i PATH="$PATH" HOME="$HOME" bash "$HOOK" 2>&1)
RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "env unset exit 0 + silent" || bad "env unset exit 0 + silent"
[ ! -e "$UNSET_LEDGER" ] && ok "env unset creates no file" || bad "env unset creates no file"

# --- 4. Malformed JSON fails open ---
BEFORE_LINES=$(wc -l < "$LEDGER")
OUT=$(printf 'not valid json {' | env -i PATH="$PATH" HOME="$HOME" SYG_CLASSIFIER_LEDGER="$LEDGER" bash "$HOOK" 2>&1)
RC=$?
AFTER_LINES=$(wc -l < "$LEDGER")
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "malformed JSON exit 0 + silent" || bad "malformed JSON exit 0 + silent"
[ "$BEFORE_LINES" -eq "$AFTER_LINES" ] && ok "malformed JSON appends nothing" || bad "malformed JSON appends nothing"

# --- 5. Unwritable path fails open ---
OUT=$(printf '%s' "$PAYLOAD" | env -i PATH="$PATH" HOME="$HOME" SYG_CLASSIFIER_LEDGER="/dev/null/impossible/ledger.jsonl" bash "$HOOK" 2>&1)
RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "unwritable path exit 0 + silent" || bad "unwritable path exit 0 + silent"

# --- 6. Dispatch via run.sh --event PostToolUseFailure ---
WRAP_LEDGER="$TMP/wrapped/ledger.jsonl"
OUT=$(printf '%s' "$PAYLOAD" | env -i PATH="$PATH" HOME="$HOME" CLAUDE_PROJECT_DIR="$TMP/proj" SYG_CLASSIFIER_LEDGER="$WRAP_LEDGER" bash "$RUNNER" --event PostToolUseFailure 2>&1)
RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "run.sh PostToolUseFailure exit 0 + silent" || bad "run.sh PostToolUseFailure exit 0 + silent"
[ -f "$WRAP_LEDGER" ] && [ "$(wc -l < "$WRAP_LEDGER")" -eq 1 ] && ok "run.sh PostToolUseFailure wrote 1 line" || bad "run.sh PostToolUseFailure wrote 1 line"

# --- 7. Pre-existing loose-permission ledger tightened to 600 on write ---
LOOSE_LEDGER="$TMP/loose-ledger.jsonl"
(umask 022; touch "$LOOSE_LEDGER")
OUT=$( (umask 022; printf '%s' "$PAYLOAD" | env -i PATH="$PATH" HOME="$HOME" SYG_CLASSIFIER_LEDGER="$LOOSE_LEDGER" bash "$HOOK") 2>&1 )
RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ "$(stat -c %a "$LOOSE_LEDGER")" = "600" ] && ok "pre-existing loose ledger tightened to 600" || bad "pre-existing loose ledger tightened to 600"

[ "$fail" -eq 0 ] || exit 1
echo "PASS: classifier-ledger ($pass cases)"
