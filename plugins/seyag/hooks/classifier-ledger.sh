#!/usr/bin/env bash
# classifier-ledger.sh — PostToolUseFailure opt-in JSONL ledger.
#
# Inert unless SYG_CLASSIFIER_LEDGER names a file path (same opt-in pattern as
# api-credit-ledger / launch-record). When set, appends one JSON line per
# PostToolUseFailure event with:
#   ts, session_id, tool_name, error (truncated to 300 chars),
#   command (.tool_input.command truncated to 200 chars when present),
#   is_interrupt.
#
# Evidence: PostToolUseFailure payload
# verified by a driver-side live probe of the harness events.
#
# Trigger: second-consecutive injection + z.ai rate-limit canary defer until
# the ledger holds real classifier-shaped entries.
#
# Privacy: the ledger stores unfiltered command and error text (which can
# contain inline tokens), so SYG_CLASSIFIER_LEDGER must not be pointed at a
# synced or shared path.
#
# Non-blocking: stdout stays empty and exits 0 on every path (unset env,
# missing jq, malformed JSON, or unwritable path).

set -uo pipefail

LEDGER="${SYG_CLASSIFIER_LEDGER:-}"
[ -n "$LEDGER" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null) || exit 0
[ -n "$INPUT" ] || exit 0

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")

ENTRY=$(printf '%s' "$INPUT" | jq -c --arg ts "$TS" '
  select(type == "object") |
  if (.tool_input | type == "object") and (.tool_input.command | type == "string") then
    {
      ts: $ts,
      session_id: (.session_id // ""),
      tool_name: (.tool_name // ""),
      error: ((.error // "") | tostring | .[:300]),
      command: (.tool_input.command[:200]),
      is_interrupt: (.is_interrupt // false)
    }
  else
    {
      ts: $ts,
      session_id: (.session_id // ""),
      tool_name: (.tool_name // ""),
      error: ((.error // "") | tostring | .[:300]),
      is_interrupt: (.is_interrupt // false)
    }
  end
' 2>/dev/null) || exit 0

[ -n "$ENTRY" ] || exit 0

umask 077
mkdir -p "$(dirname "$LEDGER")" 2>/dev/null || exit 0

if command -v flock >/dev/null 2>&1; then
  (
    flock -w 2 9 2>/dev/null || true
    printf '%s\n' "$ENTRY" >> "$LEDGER"
  ) 9>>"$LEDGER" 2>/dev/null || true
else
  printf '%s\n' "$ENTRY" >> "$LEDGER" 2>/dev/null || true
fi
chmod 600 "$LEDGER" 2>/dev/null || true

exit 0
