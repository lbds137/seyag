#!/usr/bin/env bash
# Probe for clock-stamp-guard.sh (PreToolUse Edit|Write|MultiEdit).
# Every row runs with TZ, SYG_CLOCK_STAMP_NOW, SYG_CLOCK_STAMP_PATHS_FILE and an
# invented HOME, under env -i, so the real config and clock are never read.
# The hook sits next to this file; a copy of this probe beside a stub hook
# exercises the purpose canary.

set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/clock-stamp-guard.sh"
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

BANNER_READ='Read the time with `date`, or use a tool that stamps it.'

# Fixed instants (epoch seconds, UTC wall time in the labels).
NOW_A=1793658120   # 11-02 22:22:00
NOW_B=1793659380   # 11-02 22:43:00
NOW_C=1793660400   # 11-02 23:00:00
NOW_D=1793679967   # 11-03 04:26:07
NOW_E=1767225900   # 01-01 00:05:00 (year 2026)
NOW_F=1798761480   # 12-31 23:58:00 (year 2026)

pass=0
fail=0
OUT=""
RC=0

ok() { pass=$((pass + 1)); }
bad() {
  fail=$((fail + 1))
  echo "FAIL [$1]: $2" >&2
}

# run_hook NOW CFG PAYLOAD [VAR=VALUE ...]: sets OUT and RC.
run_hook() {
  local now=$1 cfg=$2 payload=$3
  shift 3
  OUT=$(printf '%s' "$payload" | env -i PATH="$PATH" HOME="$TMP/home" TZ=UTC \
    SYG_CLOCK_STAMP_NOW="$now" SYG_CLOCK_STAMP_PATHS_FILE="$cfg" "$@" \
    bash "$HOOK" 2>&1)
  RC=$?
}

# block_has LABEL PHRASE NOW CFG PAYLOAD [VAR=VALUE ...]: expects exit 2 with PHRASE in the message.
block_has() {
  local label=$1 phrase=$2
  shift 2
  run_hook "$@"
  if [ "$RC" = 2 ] && printf '%s' "$OUT" | grep -qF -- "$BANNER_READ" \
    && printf '%s' "$OUT" | grep -qF -- "$phrase"; then
    ok
  else
    bad "$label" "expected block (exit 2) with '$phrase', got rc=$RC out=$OUT"
  fi
}

# block_case LABEL NOW CFG PAYLOAD [VAR=VALUE ...]: expects exit 2.
block_case() {
  local label=$1
  shift
  run_hook "$@"
  if [ "$RC" = 2 ] && printf '%s' "$OUT" | grep -qF -- "$BANNER_READ"; then
    ok
  else
    bad "$label" "expected block (exit 2), got rc=$RC out=$OUT"
  fi
}

# pass_case LABEL NOW CFG PAYLOAD [VAR=VALUE ...]: expects exit 0 and no output.
pass_case() {
  local label=$1
  shift
  run_hook "$@"
  if [ "$RC" = 0 ] && [ -z "$OUT" ]; then
    ok
  else
    bad "$label" "expected pass (exit 0, silent), got rc=$RC out=$OUT"
  fi
}

jq_edit() { # FILE OLD NEW
  jq -cn --arg f "$1" --arg o "$2" --arg n "$3" --arg c "$TMP" \
    '{tool_name: "Edit", cwd: $c, tool_input: {file_path: $f, old_string: $o, new_string: $n, replace_all: false}}'
}

jq_write() { # FILE CONTENT
  jq -cn --arg f "$1" --arg n "$2" --arg c "$TMP" \
    '{tool_name: "Write", cwd: $c, tool_input: {file_path: $f, content: $n}}'
}

jq_multi() { # FILE OLD1 NEW1 OLD2 NEW2
  jq -cn --arg f "$1" --arg o1 "$2" --arg n1 "$3" --arg o2 "$4" --arg n2 "$5" --arg c "$TMP" \
    '{tool_name: "MultiEdit", cwd: $c, tool_input: {file_path: $f, edits: [{old_string: $o1, new_string: $n1}, {old_string: $o2, new_string: $n2}]}}'
}

# --- Fixtures ---------------------------------------------------------------
mkdir -p "$TMP/proj" "$TMP/other" "$TMP/home/notes" "$TMP/cfg"
F="$TMP/proj/log.md"
O="$TMP/other/log.md"
printf '%s\n' '# Log' '' '## Handoff' '' '- **11-02 22:10:** earlier entry' \
  '- **11-02 23:3x:** carried placeholder' '' '## Next' '' '- old next line' > "$F"
DISK=$(cat "$F")

CFG_GLOB="$TMP/cfg/glob.txt"
printf '# clock-stamp paths\n\n%s\n' "$TMP/proj/*.md" > "$CFG_GLOB"
CFG_SECTION="$TMP/cfg/section.txt"
printf '%s\nsection: Handoff\n' "$TMP/proj/*.md" > "$CFG_SECTION"
CFG_COMMENTS="$TMP/cfg/comments.txt"
printf '# nothing to match here\n\n   # indented comment\n' > "$CFG_COMMENTS"
CFG_TILDE="$TMP/cfg/tilde.txt"
printf '%s\n' \~/notes/'*.md' > "$CFG_TILDE"
CFG_MISSING="$TMP/cfg/absent.txt"

# --- 1. Real misses (each blocks) -------------------------------------------
block_has "real miss: future line-leading at 22:22 (22:50 read)" "future" \
  "$NOW_A" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n- **11-02 22:50:** x')"
block_has "real miss: future line-leading at 22:43 (23:20 read)" "future" \
  "$NOW_B" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n**11-02 23:20:** y')"
block_has "real miss: placeholder 23:3x" "placeholder" \
  "$NOW_A" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n- **11-02 23:3x:** z')"
block_has "real miss: future line-leading at 23:00 (23:05 read)" "future" \
  "$NOW_C" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n**11-02 23:05:** w')"

# --- 2. Passes ---------------------------------------------------------------
pass_case "past leading stamp" \
  "$NOW_A" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n- **11-02 22:10:** past')"
pass_case "stamp at the current minute" \
  "$NOW_A" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n- **11-02 22:22:** now')"
pass_case "59 s ahead (23:01:04 at 23:00:05)" \
  "$((NOW_C + 5))" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n- **11-02 23:01:04:** ahead')"
pass_case "mid-line future text" \
  "$NOW_A" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n- resets Wed 11-04 11:25 for the review')"
pass_case "carried-over placeholder in old and new" \
  "$NOW_A" "$CFG_GLOB" "$(jq_edit "$F" '- **11-02 23:3x:** carried placeholder' '- **11-02 23:3x:** carried placeholder (reworded)')"
pass_case "modified frontmatter in UTC on a Write" \
  "$NOW_D" "$CFG_GLOB" "$(jq_write "$F" $'---\nmodified: 2026-11-03T04:26:07.173Z\n---\n# Log\n')"
pass_case "path outside the globs" \
  "$NOW_A" "$CFG_GLOB" "$(jq_edit "$O" '- old' $'- **11-02 23:3x:** outside')"
pass_case "no config file" \
  "$NOW_A" "$CFG_MISSING" "$(jq_edit "$F" '- old next line' $'- old next line\n- **11-02 23:3x:** z')"
pass_case "config with only comments" \
  "$NOW_A" "$CFG_COMMENTS" "$(jq_edit "$F" '- old next line' $'- old next line\n- **11-02 23:3x:** z')"

# --- 3. Year --------------------------------------------------------------------
pass_case "year: 12-31 23:58 read at 01-01 00:05 is past" \
  "$NOW_E" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n- **12-31 23:58:** x')"
block_has "year: 01-01 00:05 read at 12-31 23:58 is next year, future" "future" \
  "$NOW_F" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n- **01-01 00:05:** x')"

# --- 4. Zone --------------------------------------------------------------------
pass_case "zone: 2026-11-03T04:26:07.173Z at that instant" \
  "$NOW_D" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n- **2026-11-03T04:26:07.173Z** x')"
block_has "zone: same wall time with no zone under New York blocks" "future" \
  "$NOW_D" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n- **2026-11-03T04:26:07** x')" "TZ=America/New_York"

# --- 5. Sections ----------------------------------------------------------------
pass_case "section: future stamp under ## Next passes (Write)" \
  "$NOW_A" "$CFG_SECTION" "$(jq_write "$F" $'# Log\n\n## Handoff\n\n## Next\n\n- **11-02 23:30:** x\n')"
block_has "section: same future stamp under ## Handoff blocks (Write)" "future" \
  "$NOW_A" "$CFG_SECTION" "$(jq_write "$F" $'# Log\n\n## Next\n\n## Handoff\n\n- **11-02 23:30:** x\n')"
pass_case "section: Edit under ## Next on disk passes" \
  "$NOW_A" "$CFG_SECTION" "$(jq_edit "$F" '- old next line' $'- old next line\n- **11-02 23:30:** x')"
block_has "section: Edit under ## Handoff on disk blocks" "future" \
  "$NOW_A" "$CFG_SECTION" "$(jq_edit "$F" '- **11-02 22:10:** earlier entry' $'- **11-02 22:10:** earlier entry\n- **11-02 23:30:** x')"
block_has "section: placeholder under ## Next still blocks" "placeholder" \
  "$NOW_A" "$CFG_SECTION" "$(jq_edit "$F" '- old next line' $'- old next line\n- **11-02 23:3x:** y')"

# --- 6. Code exemption -----------------------------------------------------------
pass_case "code span quoting a placeholder passes" \
  "$NOW_A" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n- Stamp shape `11-02 23:3x` is a placeholder.')"
block_has "control: the same placeholder unquoted blocks" "placeholder" \
  "$NOW_A" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n- Stamp shape 11-02 23:3x is a placeholder.')"
pass_case "future leading stamp inside a fenced block passes" \
  "$NOW_A" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n```\n- **11-02 23:50:** x\n```')"

# --- 7. Write over an existing file -----------------------------------------------
pass_case "Write keeping the old placeholder line passes" \
  "$NOW_A" "$CFG_GLOB" "$(jq_write "$F" "$DISK")"
block_has "Write adding a second, new placeholder line blocks" "placeholder" \
  "$NOW_A" "$CFG_GLOB" "$(jq_write "$F" "$DISK"$'\n- **11-03 0x:15:** new')"

# --- 8. MultiEdit ----------------------------------------------------------------
block_has "MultiEdit: clean first edit, placeholder second blocks" "placeholder" \
  "$NOW_A" "$CFG_GLOB" "$(jq_multi "$F" '- old next line' $'- old next line\n- **11-02 22:10:** ok' '- **11-02 22:10:** earlier entry' $'- **11-02 22:10:** earlier entry\n- **11-02 23:3x:** y')"
pass_case "MultiEdit: two clean edits pass" \
  "$NOW_A" "$CFG_GLOB" "$(jq_multi "$F" '- old next line' $'- old next line (a)' '- **11-02 22:10:** earlier entry' $'- **11-02 22:10:** earlier entry (b)')"

# --- 9. Tilde glob ----------------------------------------------------------------
block_has "tilde glob matches under the invented HOME" "placeholder" \
  "$NOW_A" "$CFG_TILDE" "$(jq_edit "$TMP/home/notes/x.md" '' '- **11-02 23:3x:** t')"
pass_case "tilde glob leaves a path outside HOME alone" \
  "$NOW_A" "$CFG_TILDE" "$(jq_edit "$O" '' '- **11-02 23:3x:** t')"

# --- 10. Invalid stamps are not stamps ----------------------------------------------
pass_case "impossible date 02-30 is not a stamp" \
  "$NOW_A" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n- **02-30 23:3x:** x')"
pass_case "hour 24 is not a stamp" \
  "$NOW_A" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n- **11-02 24:15:** x')"

# --- 11. Fail open -------------------------------------------------------------------
pass_case "malformed JSON fails open" "$NOW_A" "$CFG_GLOB" 'not json {'
pass_case "tool Bash fails open" "$NOW_A" "$CFG_GLOB" \
  '{"tool_name":"Bash","tool_input":{"command":"echo 11-02 23:3x"}}'
pass_case "Edit without file_path fails open" "$NOW_A" "$CFG_GLOB" \
  '{"tool_name":"Edit","tool_input":{"old_string":"a","new_string":"11-02 23:3x"}}'

# --- 12. Hint ------------------------------------------------------------------------
block_has "hint appears in the message" "use-the-stamper" \
  "$NOW_A" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n- **11-02 23:3x:** z')" \
  "SYG_CLOCK_STAMP_HINT=use-the-stamper"
block_has "message names the current local time" "2026-11-02 22:22:00 UTC" \
  "$NOW_A" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n- **11-02 23:3x:** z')"

# --- 13. Review round 1 ----------------------------------------------------------
# Fixtures for these rows.
G="$TMP/proj/split.md"
printf '%s\n' '# Log' '' '## Next' '' '- **11-02 23:30:** a' > "$G"
CRLF="$TMP/proj/crlf.md"
printf '## Next\r\n\r\nold line\r\n' > "$CRLF"
ln -s "$TMP/proj" "$TMP/link"

# Fix 1: an inline code span is one word, so a stamp after it is line-leading.
pass_case "code span as the leading word, then mid-line future text" \
  "$NOW_A" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n- `z.ai` resets 11-04 11:25')"
block_has "code span as the leading word, then a future stamp blocks" "future" \
  "$NOW_A" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n- `tool` 11-04 11:25 x')"

# Fix 2: a time range is not a zone; an offset counts only after a T separator.
pass_case "range 22:10-22:40 is not a zone" \
  "$NOW_A" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n- **11-02 22:10-22:40:** worked')"
pass_case "range 09:00-12:00 is not a zone" \
  "$NOW_A" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n- **11-02 09:00-12:00:** x')"
pass_case "T separator with -05:00 passes when the wall time is 23:26:07 on the day before" \
  "$NOW_D" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n- **2026-11-02T23:26:07-05:00** x')"
block_has "T separator with -05:00 at 04:26:07 wall time is 5 h ahead and blocks" "future" \
  "$NOW_D" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n- **2026-11-03T04:26:07-05:00** x')"

# Fix 3: every line in the new text that carries a surviving key is judged.
block_has "carried-over line under Next plus a new copy under Handoff blocks" "future" \
  "$NOW_A" "$CFG_SECTION" "$(jq_write "$G" $'# Log\n\n## Next\n\n- **11-02 23:30:** a\n\n## Handoff\n\n- **11-02 23:30:** a\n')"

# Fix 5: a stamp whose instant cannot be computed is skipped; the others still judge.
block_has "unconvertible stamp does not hide a placeholder" "placeholder" \
  "$NOW_A" "$CFG_GLOB" "$(jq_write "$F" $'- **0001-01-01 00:00:** x\n- **11-03 0x:15:** y\n')" "TZ=America/New_York"

# Fix 6: CRLF survives in old_string lookup.
pass_case "CRLF old_string under ## Next passes" \
  "$NOW_A" "$CFG_SECTION" "$(jq_edit "$CRLF" $'old line\r' $'old line\r\n- **11-02 23:30:** x')"

# Fix 8: a one-line triple-backtick span is not a fence opener.
block_has "one-line triple-backtick span is not a fence; following placeholder blocks" "placeholder" \
  "$NOW_A" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n```code```\n- **11-02 23:3x:** z')"

# Fix 9: headings with up to three leading spaces, and closing hash runs.
pass_case "indented (three spaces) ## Next heading" \
  "$NOW_A" "$CFG_SECTION" "$(jq_write "$F" $'   ## Next\n\n- **11-02 23:30:** x\n')"
block_has "closing hash run is stripped from a heading" "future" \
  "$NOW_A" "$CFG_SECTION" "$(jq_write "$F" $'## Handoff ##\n\n- **11-02 23:30:** x\n')"

# Fix 10: the rest of the list.
block_has "replace_all true Edit is judged" "placeholder" \
  "$NOW_A" "$CFG_GLOB" "$(jq -cn --arg f "$F" --arg c "$TMP" '{tool_name:"Edit",cwd:$c,tool_input:{file_path:$f,old_string:"- old next line",new_string:"- old next line\n- **11-02 23:3x:** z",replace_all:true}}')"
block_has "relative file_path resolves against cwd" "placeholder" \
  "$NOW_A" "$CFG_GLOB" "$(jq -cn --arg c "$TMP" '{tool_name:"Edit",cwd:$c,tool_input:{file_path:"proj/log.md",old_string:"- old next line",new_string:"- old next line\n- **11-02 23:3x:** z"}}')"
block_has "symlinked dir matches through realpath" "placeholder" \
  "$NOW_A" "$CFG_GLOB" "$(jq_edit "$TMP/link/log.md" '- old next line' $'- old next line\n- **11-02 23:3x:** z')"
pass_case "exactly 60 s ahead passes" \
  "$NOW_C" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n- **11-02 23:01:** x')"
block_has "61 s ahead blocks" "future" \
  "$NOW_C" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n- **11-02 23:01:01:** x')"
run_hook "$NOW_A" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n- **11-02 23:3x:** z')" "SYG_CLOCK_STAMP_HINT="
if [ "$RC" = 2 ] && [ "$(printf '%s' "$OUT" | tail -n 1)" = "$BANNER_READ" ]; then
  ok
else
  bad "empty hint adds no line" "expected the last line to be the read line, got rc=$RC out=$OUT"
fi
block_has "old_string at offset 0 with no heading is judged" "future" \
  "$NOW_A" "$CFG_SECTION" "$(jq_edit "$F" '# Log' $'# Log\n- **11-02 23:30:** x')"

# --- 14. Review round 2 ----------------------------------------------------------
# Fix 1: an early exit drains stdin, so a payload larger than a pipe buffer does not
# SIGPIPE the writer. The writer must exit 0 and the hook must exit 0.
BIG=$(head -c 70000 /dev/zero | tr '\0' a)
BIGPAYLOAD='{"tool_name":"Write","tool_input":{"file_path":"'"$TMP"'/proj/log.md","content":"'"$BIG"'"}}'
for big_cfg in "$CFG_MISSING" "$CFG_COMMENTS"; do
  big_ok=1
  for _ in 1 2 3; do
    printf '%s' "$BIGPAYLOAD" | env -i PATH="$PATH" HOME="$TMP/home" SYG_CLOCK_STAMP_PATHS_FILE="$big_cfg" \
      bash "$HOOK" >/dev/null 2>&1
    pst=("${PIPESTATUS[@]}")
    WRITER=${pst[0]}
    HRC=${pst[1]}
    if [ "$WRITER" = 141 ] || [ "$HRC" != 0 ]; then big_ok=0; fi
  done
  if [ "$big_ok" = 1 ]; then
    ok
  else
    bad "large payload, early exit drains stdin ($(basename "$big_cfg"))" "writer=$WRITER hook=$HRC (141 is SIGPIPE)"
  fi
done

# Fix 2: an out-of-range T offset is trimmed like a space offset, so the stamp is still judged.
block_has "T with an out-of-range offset is trimmed; the placeholder still blocks" "placeholder" \
  "$NOW_A" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n- **11-02T2x:30+15:00** z')"
pass_case "T with an out-of-range offset is trimmed; 10:00 local is past" \
  "$NOW_A" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n- **11-02T10:00+15:00** z')"

# Fix 3: a backtick fence whose info string holds any backtick is not a fence opener.
block_has "fence line with a lone backtick in its info string is not a fence" "placeholder" \
  "$NOW_A" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n```a`b\n- **11-02 23:3x:** z')"

# --- 15. Review round 3 ----------------------------------------------------------
# Item 1: after a space, an offset is kept when the stamp has seconds (RFC 3339 style).
pass_case "RFC 3339 space form with seconds and +00:00 passes at its instant under New York" \
  "$NOW_D" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n- 2026-11-03 04:26:07+00:00 x')" "TZ=America/New_York"
block_has "RFC 3339 space form with seconds, 2 minutes ahead, blocks" "future" \
  "$((NOW_D - 120))" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n- 2026-11-03 04:26:07+00:00 x')" "TZ=America/New_York"
block_has "space form without seconds keeps trimming: 04:26 read as New York local is 5 h ahead" "future" \
  "$NOW_D" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n- **2026-11-03 04:26+00:00:** x')" "TZ=America/New_York"

# Item 2: an Edit whose old_string sits inside a fenced block on disk starts inside that fence.
FENCE="$TMP/proj/fence.md"
printf '%s\n' '# Log' '' '```' '- **11-02 22:10:** code' '```' '' '- old next line' > "$FENCE"
pass_case "edit inside a fenced block on disk: the added stamp is code" \
  "$NOW_A" "$CFG_GLOB" "$(jq_edit "$FENCE" '- **11-02 22:10:** code' $'- **11-02 22:10:** code\n- **11-04 11:25:** sample')"
block_has "edit outside any fence: the same added stamp blocks" "future" \
  "$NOW_A" "$CFG_GLOB" "$(jq_edit "$FENCE" '- old next line' $'- old next line\n- **11-04 11:25:** sample')"
block_has "edit inside a fence whose new text closes the fence: a placeholder after it blocks" "placeholder" \
  "$NOW_A" "$CFG_GLOB" "$(jq_edit "$FENCE" '- **11-02 22:10:** code' $'- **11-02 22:10:** code\n```\n- **11-02 23:3x:** z')"

# Item 3: placeholder seconds are a placeholder; real seconds must be digits 00-59.
block_has "placeholder seconds xx block as a placeholder" "placeholder" \
  "$NOW_A" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n- **11-02 23:30:xx** z')"
pass_case "real seconds 60 is not a stamp" \
  "$NOW_A" "$CFG_GLOB" "$(jq_edit "$F" '- old next line' $'- old next line\n- **11-02 22:10:60** z')"

# Item 6: a non-dict entry in edits does not stop a placeholder edit from blocking.
block_has "MultiEdit with a non-dict entry: the placeholder edit still blocks" "placeholder" \
  "$NOW_A" "$CFG_GLOB" "$(jq -cn --arg f "$F" --arg c "$TMP" '{tool_name:"MultiEdit",cwd:$c,tool_input:{file_path:$f,edits:["junk",{old_string:"- old next line",new_string:"- old next line\n- **11-02 23:3x:** z"}]}}')"
pass_case "MultiEdit whose edits are all non-dict entries passes without a crash" \
  "$NOW_A" "$CFG_GLOB" "$(jq -cn --arg f "$F" --arg c "$TMP" '{tool_name:"MultiEdit",cwd:$c,tool_input:{file_path:$f,edits:["junk",42,null]}}')"

[ "$fail" -eq 0 ] || { echo "FAIL: clock-stamp-guard ($fail failed, $pass passed)"; exit 1; }
echo "PASS: clock-stamp-guard ($pass cases)"
