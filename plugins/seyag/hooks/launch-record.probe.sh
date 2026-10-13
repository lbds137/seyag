#!/bin/bash
# Fixture check for launch-record.sh: records session launch metadata, flags
# hybrid provider configurations, sanitizes URLs, and prunes stale records.
# Hermetic: temp dirs, every case runs under clean environment with `env -i`,
# no network.
#
# Usage: hooks/launch-record.probe.sh   (from anywhere)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$SCRIPT_DIR/launch-record.sh"
BASH_BIN=$(command -v bash)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; [ -n "${2:-}" ] && printf '      got: %s\n' "$2"; fail=1; }

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || python3 -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$1" 2>/dev/null
}

run() {
  local sid="${SID-probe-session}"
  local src="${SRC:-startup}"
  local cwd="${CWD_ARG:-$TMP}"
  OUT=$(printf '{"session_id":"%s","source":"%s","cwd":"%s"}' "$sid" "$src" "$cwd" \
    | env -i PATH="$PATH" HOME="$TMP" "$@" "$BASH_BIN" "$HOOK" 2>"$TMP/err")
  RC=$?
}

# 1. unset dir -> no output, no file
RDIR="$TMP/records1"
run
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ ! -e "$RDIR" ] \
  && ok "1. unset dir -> no output, no file" || bad "1. unset dir" "$OUT"

# 2. homogeneous anthropic slots, empty base -> file with v=1, right fields, hybrid false, no output, mode 600
RDIR="$TMP/records2"
run SYG_LAUNCH_RECORD_DIR="$RDIR" ANTHROPIC_MODEL="claude-3-5-sonnet-20241022" ANTHROPIC_DEFAULT_OPUS_MODEL="claude-3-opus-20240229"
FILE="$RDIR/probe-session.json"
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ -f "$FILE" ] \
  && [ "$(file_mode "$FILE")" = "600" ] \
  && jq -e '.v == 1 and .session_id == "probe-session" and .source == "startup" and .hybrid == false and .hybrid_why == [] and .base_host == ""' "$FILE" >/dev/null 2>&1 \
  && jq -e '.slots == {"model": "claude-3-5-sonnet-20241022", "opus": "claude-3-opus-20240229"} and .families == {"model": "anthropic", "opus": "anthropic"}' "$FILE" >/dev/null 2>&1 \
  && ok "2. homogeneous anthropic slots, empty base -> file with v=1, right fields, hybrid false, no output, mode 600" \
  || bad "2. homogeneous anthropic slots" "$OUT"

# 3. base URL with userinfo/path/query -> base_host is host[:port] only and the token text appears nowhere in the file
RDIR="$TMP/records3"
TOKEN="secret-token-xyz-98765"
run SYG_LAUNCH_RECORD_DIR="$RDIR" ANTHROPIC_MODEL="claude-3-5-sonnet-20241022" \
  ANTHROPIC_BASE_URL="https://user:${TOKEN}@api.example.test:8443/v1/messages?key=${TOKEN}#frag"
FILE="$RDIR/probe-session.json"
[ "$RC" = 0 ] && [ -f "$FILE" ] \
  && [ "$(jq -r '.base_host' "$FILE" 2>/dev/null)" = "api.example.test:8443" ] \
  && ! grep -qF "$TOKEN" "$FILE" \
  && ok "3. base URL with userinfo/path/query -> base_host is host[:port] only and token text appears nowhere in file" \
  || bad "3. base URL with userinfo/path/query" "$OUT"

# 4. mixed families -> hybrid true, hybrid_why correct, output has systemMessage and additionalContext
RDIR="$TMP/records4"
run SYG_LAUNCH_RECORD_DIR="$RDIR" ANTHROPIC_BASE_URL="https://api.example.test" \
  ANTHROPIC_MODEL="claude-3-5-sonnet-20241022" ANTHROPIC_DEFAULT_HAIKU_MODEL="vendor-a/model-x"
FILE="$RDIR/probe-session.json"
[ "$RC" = 0 ] && [ -f "$FILE" ] \
  && jq -e '.hybrid == true and .hybrid_why == ["haiku"]' "$FILE" >/dev/null 2>&1 \
  && jq -e '.systemMessage != null and .hookSpecificOutput.hookEventName == "SessionStart" and .hookSpecificOutput.additionalContext != null' <<<"$OUT" >/dev/null 2>&1 \
  && grep -q "haiku" <<<"$OUT" && grep -q "vendor-a" <<<"$OUT" && grep -q "SYG_LAUNCH_RECORD_HYBRID_OK=1" <<<"$OUT" \
  && ok "4. mixed families -> hybrid true, hybrid_why correct, output has systemMessage and additionalContext" \
  || bad "4. mixed families" "$OUT"

# 5. same with SYG_LAUNCH_RECORD_HYBRID_OK=1 -> record still hybrid true, no output
RDIR="$TMP/records5"
run SYG_LAUNCH_RECORD_DIR="$RDIR" ANTHROPIC_BASE_URL="https://api.example.test" \
  ANTHROPIC_MODEL="claude-3-5-sonnet-20241022" ANTHROPIC_DEFAULT_HAIKU_MODEL="vendor-a/model-x" \
  SYG_LAUNCH_RECORD_HYBRID_OK=1
FILE="$RDIR/probe-session.json"
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ -f "$FILE" ] \
  && jq -e '.hybrid == true and .hybrid_why == ["haiku"]' "$FILE" >/dev/null 2>&1 \
  && ok "5. same with SYG_LAUNCH_RECORD_HYBRID_OK=1 -> record still hybrid true, no output" \
  || bad "5. hybrid ok suppressed output" "$OUT"

# 6. default endpoint with a single non-anthropic family (~vendor-a/model-x in two slots) -> hybrid true, family vendor-a
RDIR="$TMP/records6"
run SYG_LAUNCH_RECORD_DIR="$RDIR" \
  ANTHROPIC_MODEL="~vendor-a/model-x" ANTHROPIC_DEFAULT_SONNET_MODEL="~vendor-a/model-x"
FILE="$RDIR/probe-session.json"
[ "$RC" = 0 ] && [ -f "$FILE" ] \
  && jq -e '.hybrid == true and .base_host == ""' "$FILE" >/dev/null 2>&1 \
  && jq -e '.families.model == "vendor-a" and .families.sonnet == "vendor-a"' "$FILE" >/dev/null 2>&1 \
  && jq -e '.hybrid_why == ["model", "sonnet"]' "$FILE" >/dev/null 2>&1 \
  && ok "6. default endpoint with a single non-anthropic family (~vendor-a/model-x in two slots) -> hybrid true, family vendor-a" \
  || bad "6. default endpoint with single non-anthropic family" "$OUT"

# 7. extra vars from SYG_LAUNCH_RECORD_ENV incl. an invalid name skipped
RDIR="$TMP/records7"
run SYG_LAUNCH_RECORD_DIR="$RDIR" SYG_LAUNCH_RECORD_ENV="MY_PRESET 123_INVALID VALID_VAR OTHER_VAR" \
  MY_PRESET="custom-preset" VALID_VAR="val-123"
FILE="$RDIR/probe-session.json"
[ "$RC" = 0 ] && [ -f "$FILE" ] \
  && jq -e '.extra.MY_PRESET == "custom-preset" and .extra.VALID_VAR == "val-123" and .extra.OTHER_VAR == ""' "$FILE" >/dev/null 2>&1 \
  && ! jq -e '.extra | has("123_INVALID")' "$FILE" >/dev/null 2>&1 \
  && ok "7. extra vars from SYG_LAUNCH_RECORD_ENV incl. an invalid name skipped" \
  || bad "7. extra vars from SYG_LAUNCH_RECORD_ENV" "$OUT"

# 8. bad session_id -> no file
RDIR="$TMP/records8"
bad_ids=("" "../escape" "bad/id" "id with spaces" "session*id")
bad_id_ok=1
for b in "${bad_ids[@]}"; do
  SID="$b" run SYG_LAUNCH_RECORD_DIR="$RDIR" ANTHROPIC_MODEL="claude-3-5-sonnet-20241022"
  if [ "$RC" != 0 ] || [ -n "$OUT" ]; then bad_id_ok=0; fi
done
n_files=0
if [ -d "$RDIR" ]; then
  n_files=$(find "$RDIR" -name "*.json" 2>/dev/null | wc -l)
fi
[ "$bad_id_ok" = 1 ] && [ "$n_files" -eq 0 ] \
  && ok "8. bad session_id -> no file" || bad "8. bad session_id -> created file or output" "$OUT"

# 9. a 15-day-old json in the dir is pruned, a 13-day-old one kept, a non-json file kept
RDIR="$TMP/records9"
mkdir -m 700 "$RDIR"
printf '{"old": 15}\n' > "$RDIR/old-15.json"
printf '{"old": 13}\n' > "$RDIR/old-13.json"
printf 'keep me\n' > "$RDIR/keep.txt"

python3 -c '
import os, sys, time
now = time.time()
os.utime(sys.argv[1], (now - 15 * 86400, now - 15 * 86400))
os.utime(sys.argv[2], (now - 13 * 86400, now - 13 * 86400))
os.utime(sys.argv[3], (now - 15 * 86400, now - 15 * 86400))
' "$RDIR/old-15.json" "$RDIR/old-13.json" "$RDIR/keep.txt"

SID="fresh-session" run SYG_LAUNCH_RECORD_DIR="$RDIR" ANTHROPIC_MODEL="claude-3-5-sonnet-20241022"
[ "$RC" = 0 ] && [ -f "$RDIR/fresh-session.json" ] \
  && [ ! -e "$RDIR/old-15.json" ] \
  && [ -f "$RDIR/old-13.json" ] \
  && [ -f "$RDIR/keep.txt" ] \
  && ok "9. a 15-day-old json in the dir is pruned, a 13-day-old one kept, a non-json file kept" \
  || bad "9. pruning 14-day files"

# 10. rewrite: second run with a different source overwrites the file
RDIR="$TMP/records10"
SID="session-rw" SRC="startup" run SYG_LAUNCH_RECORD_DIR="$RDIR" ANTHROPIC_MODEL="claude-3-5-sonnet-20241022"
FILE="$RDIR/session-rw.json"
first_ok=0
[ "$RC" = 0 ] && [ -f "$FILE" ] && [ "$(jq -r '.source' "$FILE" 2>/dev/null)" = "startup" ] && first_ok=1

SID="session-rw" SRC="resume" run SYG_LAUNCH_RECORD_DIR="$RDIR" ANTHROPIC_MODEL="claude-3-5-sonnet-20241022"
[ "$first_ok" = 1 ] && [ "$RC" = 0 ] && [ -f "$FILE" ] && [ "$(jq -r '.source' "$FILE" 2>/dev/null)" = "resume" ] \
  && ok "10. rewrite: second run with a different source overwrites the file" \
  || bad "10. rewrite" "$OUT"

# 11. opus[1m] alias with claude-x sonnet, no base URL -> hybrid false, families.model anthropic, slots.model opus[1m] verbatim, no output
RDIR="$TMP/records11"
run SYG_LAUNCH_RECORD_DIR="$RDIR" ANTHROPIC_MODEL="opus[1m]" ANTHROPIC_DEFAULT_SONNET_MODEL="claude-x"
FILE="$RDIR/probe-session.json"
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ -f "$FILE" ] \
  && jq -e '.hybrid == false and .hybrid_why == [] and .base_host == ""' "$FILE" >/dev/null 2>&1 \
  && jq -e '.families.model == "anthropic" and .slots.model == "opus[1m]"' "$FILE" >/dev/null 2>&1 \
  && ok "11. opus[1m] alias with claude-x sonnet, no base URL -> hybrid false, families.model anthropic, slots.model opus[1m] verbatim, no output" \
  || bad "11. opus[1m] alias with claude-x sonnet" "$OUT"

# 12. base URL with opus alias resolving to vendor-a slot -> families.model vendor-a, hybrid false, no output
RDIR="$TMP/records12"
run SYG_LAUNCH_RECORD_DIR="$RDIR" ANTHROPIC_BASE_URL="https://api.example.test" \
  ANTHROPIC_MODEL="opus" ANTHROPIC_DEFAULT_OPUS_MODEL="vendor-a/m1" ANTHROPIC_DEFAULT_SONNET_MODEL="vendor-a/m2"
FILE="$RDIR/probe-session.json"
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ -f "$FILE" ] \
  && jq -e '.hybrid == false and .hybrid_why == [] and .base_host == "api.example.test"' "$FILE" >/dev/null 2>&1 \
  && jq -e '.families.model == "vendor-a" and .families.opus == "vendor-a" and .families.sonnet == "vendor-a"' "$FILE" >/dev/null 2>&1 \
  && ok "12. base URL with opus alias resolving to vendor-a slot -> families.model vendor-a, hybrid false, no output" \
  || bad "12. base URL with opus alias resolving to vendor-a slot" "$OUT"

# 13. default endpoint, ANTHROPIC_MODEL=mystery-model -> family unknown, hybrid true
RDIR="$TMP/records13"
run SYG_LAUNCH_RECORD_DIR="$RDIR" ANTHROPIC_MODEL="mystery-model"
FILE="$RDIR/probe-session.json"
[ "$RC" = 0 ] && [ -f "$FILE" ] \
  && jq -e '.hybrid == true and .base_host == ""' "$FILE" >/dev/null 2>&1 \
  && jq -e '.families.model == "unknown"' "$FILE" >/dev/null 2>&1 \
  && ok "13. default endpoint, ANTHROPIC_MODEL=mystery-model -> family unknown, hybrid true" \
  || bad "13. default endpoint, ANTHROPIC_MODEL=mystery-model" "$OUT"

exit $fail
