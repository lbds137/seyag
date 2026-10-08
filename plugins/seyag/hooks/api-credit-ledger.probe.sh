#!/bin/bash
# Fixture check for api-credit-ledger.sh: inert (no python spawned, silent, exit 0)
# without SYG_CREDIT_LEDGER or when the bash route pre-filter cannot match; with
# the ledger and a matching route, a fixture transcript
# lands in the ledger and stdout stays empty, directly, through run.sh in a
# headless (sdk-cli) run, and through run.sh --event SessionEnd.
# Hermetic: every case runs under `env -i`; temp HOME, project dir, transcript,
# ledger and a stub price table (SYG_CREDIT_PRICE_TABLE_CMD).
#
# Usage: hooks/api-credit-ledger.probe.sh   (from anywhere)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$SCRIPT_DIR/api-credit-ledger.sh"
RUNSH="$SCRIPT_DIR/run.sh"
BASH_BIN=$(command -v bash)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/proj" "$TMP/tx" "$TMP/stub"

fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

printf '{"table":{"m-a":{"input":1,"output":2,"cacheRead":0.5,"cacheWrite":1.25}}}\n' > "$TMP/prices.json"
printf '#!/bin/bash\ncat %q\n' "$TMP/prices.json" > "$TMP/pt.sh"
# A python3 that only records it was spawned: proves the cheap bash exit.
printf '#!/bin/bash\ntouch %q\n' "$TMP/python-spawned" > "$TMP/stub/python3"
chmod +x "$TMP/pt.sh" "$TMP/stub/python3"
printf '{"type":"assistant","timestamp":"2026-10-10T10:00:00Z","requestId":"req-1","message":{"model":"m-a","id":"msg-1","usage":{"input_tokens":1000000,"output_tokens":0}}}\n' > "$TMP/tx/S.jsonl"
payload='{"session_id":"S","transcript_path":"'"$TMP/tx/S.jsonl"'","hook_event_name":"Stop"}'

# run CMD... with a clean env plus the case's variables (VARS array).
run() {
  OUT=$(printf '%s' "$payload" | env -i PATH="${RPATH:-$PATH}" HOME="$TMP/home" PYTHONDONTWRITEBYTECODE=1 \
    CLAUDE_PROJECT_DIR="$TMP/proj" "${VARS[@]}" "$@" 2>"$TMP/err")
  RC=$?
}

# 1. Ledger unset: exit 0, no output, python never spawned.
VARS=(SYG_CREDIT_WHEN=MY_ROUTE=metered MY_ROUTE=metered)
RPATH="$TMP/stub:$PATH" run "$BASH_BIN" "$HOOK"
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ ! -s "$TMP/err" ] && [ ! -e "$TMP/python-spawned" ] \
  && ok "ledger unset: exit 0, silent, no python spawned" || bad "ledger unset: rc=$RC out='$OUT' err='$(cat "$TMP/err")'"
# Bash route pre-filter: ledger set but the route cannot match -> python never spawned.
# spawned VARS...: did the stub python3 run under these variables (ledger set)?
spawned() {
  rm -f "$TMP/python-spawned"
  VARS=(SYG_CREDIT_LEDGER="$TMP/ctl/l.jsonl" "$@")
  RPATH="$TMP/stub:$PATH" run "$BASH_BIN" "$HOOK"
  [ "$RC" = 0 ] && [ -z "$OUT" ] || return 2
  [ -e "$TMP/python-spawned" ]
}
spawned SYG_CREDIT_WHEN=MY_ROUTE=metered MY_ROUTE=other ANTHROPIC_API_KEY=sk-probe; r=$?
[ "$r" = 1 ] && ok "pre-filter: ledger set + SYG_CREDIT_WHEN mismatch -> python not spawned" || bad "pre-filter WHEN mismatch: $r"
spawned SYG_CREDIT_WHEN=MY_ROUTE MY_ROUTE=MY_ROUTE; r=$?
[ "$r" = 1 ] && ok "pre-filter: ledger set + malformed SYG_CREDIT_WHEN -> python not spawned" || bad "pre-filter WHEN malformed: $r"
spawned ANTHROPIC_API_KEY=; r=$?
[ "$r" = 1 ] && ok "pre-filter: ledger set + no SYG_CREDIT_WHEN + empty key -> python not spawned" || bad "pre-filter empty key: $r"
spawned SYG_CREDIT_WHEN=MY_ROUTE=metered MY_ROUTE=metered; r=$?
[ "$r" = 0 ] && ok "pre-filter: ledger set + SYG_CREDIT_WHEN match -> python spawned" || bad "pre-filter WHEN match: $r"
spawned ANTHROPIC_API_KEY=sk-probe; r=$?
[ "$r" = 0 ] && ok "pre-filter: ledger set + no SYG_CREDIT_WHEN + key set -> python spawned" || bad "pre-filter key set: $r"
spawned SYG_CREDIT_FORCE=1; r=$?
[ "$r" = 0 ] && ok "pre-filter: SYG_CREDIT_FORCE=1 -> python spawned" || bad "pre-filter force: $r"

# 2. Ledger set, route matches: the transcript lands; stdout empty.
VARS=(SYG_CREDIT_LEDGER="$TMP/l1/l.jsonl" SYG_CREDIT_PRICE_TABLE_CMD="$TMP/pt.sh" SYG_CREDIT_WHEN=MY_ROUTE=metered MY_ROUTE=metered)
run "$BASH_BIN" "$HOOK"
[ "$RC" = 0 ] && [ -z "$OUT" ] && jq -e '.session_id=="S" and .cost_usd==1 and .request_ids==["req-1"]' "$TMP/l1/l.jsonl" >/dev/null 2>&1 \
  && ok "ledger set + route match: entry written (cost 1.00), stdout empty" || bad "direct: rc=$RC out='$OUT' err='$(cat "$TMP/err")'"
# Route mismatch: nothing written.
VARS=(SYG_CREDIT_LEDGER="$TMP/l2/l.jsonl" SYG_CREDIT_PRICE_TABLE_CMD="$TMP/pt.sh" SYG_CREDIT_WHEN=MY_ROUTE=metered MY_ROUTE=other)
run "$BASH_BIN" "$HOOK"
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ ! -e "$TMP/l2/l.jsonl" ] && ok "route mismatch: nothing written" || bad "mismatch: rc=$RC out='$OUT'"

# 3. Headless: run.sh keeps the api-credit component under CLAUDE_CODE_ENTRYPOINT=sdk-cli.
VARS=(SYG_CREDIT_LEDGER="$TMP/l3/l.jsonl" SYG_CREDIT_PRICE_TABLE_CMD="$TMP/pt.sh" SYG_CREDIT_WHEN=MY_ROUTE=metered MY_ROUTE=metered CLAUDE_CODE_ENTRYPOINT=sdk-cli)
run "$BASH_BIN" "$RUNSH" api-credit-ledger
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ -s "$TMP/l3/l.jsonl" ] \
  && ok "run.sh api-credit-ledger under sdk-cli: ledger written, stdout empty" || bad "headless run.sh: rc=$RC out='$OUT' err='$(cat "$TMP/err")'"
VARS=(SYG_CREDIT_LEDGER="$TMP/l4/l.jsonl" SYG_CREDIT_PRICE_TABLE_CMD="$TMP/pt.sh" SYG_CREDIT_WHEN=MY_ROUTE=metered MY_ROUTE=metered CLAUDE_CODE_ENTRYPOINT=sdk-cli)
run "$BASH_BIN" "$RUNSH" --event SessionEnd
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ -s "$TMP/l4/l.jsonl" ] \
  && ok "run.sh --event SessionEnd under sdk-cli: ledger written, stdout empty" || bad "SessionEnd event: rc=$RC out='$OUT' err='$(cat "$TMP/err")'"
# The component switches off like any other.
VARS=(SYG_CREDIT_LEDGER="$TMP/l5/l.jsonl" SYG_CREDIT_PRICE_TABLE_CMD="$TMP/pt.sh" SYG_CREDIT_WHEN=MY_ROUTE=metered MY_ROUTE=metered SYG_DISABLE=api-credit)
run "$BASH_BIN" "$RUNSH" api-credit-ledger
[ "$RC" = 0 ] && [ ! -e "$TMP/l5/l.jsonl" ] && ok "SYG_DISABLE=api-credit: nothing written" || bad "disable: rc=$RC"
# Every profile keeps it: SYG_PROFILE=none and guards still record.
for prof in none guards; do
  VARS=(SYG_CREDIT_LEDGER="$TMP/p-$prof/l.jsonl" SYG_CREDIT_PRICE_TABLE_CMD="$TMP/pt.sh" SYG_CREDIT_WHEN=MY_ROUTE=metered MY_ROUTE=metered "SYG_PROFILE=$prof")
  run "$BASH_BIN" "$RUNSH" api-credit-ledger
  [ "$RC" = 0 ] && [ -z "$OUT" ] && [ -s "$TMP/p-$prof/l.jsonl" ] \
    && ok "SYG_PROFILE=$prof + route match: ledger written" || bad "profile $prof: rc=$RC err='$(cat "$TMP/err")'"
done

exit $fail
