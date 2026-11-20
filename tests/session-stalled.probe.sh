#!/usr/bin/env bash
# Hermetic probe for plugins/seyag/bin/session-stalled: synthetic transcripts only, no live sessions.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STALLED="$SCRIPT_DIR/../plugins/seyag/bin/session-stalled"
[ -x "$STALLED" ] || { echo "FAIL: $STALLED is not executable (chmod +x it)"; exit 1; }
export SYG_CONFIG=0
unset CLAUDE_PROJECTS_DIR CLAUDE_CONFIG_DIR
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }
NOW="2026-10-14T18:00:00Z"
export SYG_STALLED_NOW="$NOW"
ts="2026-10-14T17:30:00.000Z"
hm_iso() { date -d "$1" +%H:%M; }
ymd_hm_iso() { date -d "$1" '+%F %H:%M'; }

# error is the last real entry; trailing system/last-prompt metadata must not hide it
cat > "$tmp/err.jsonl" <<J
{"type":"user","timestamp":"$ts","message":{"role":"user","content":"go"}}
{"type":"assistant","timestamp":"$ts","isApiErrorMessage":true,"error":"rate_limit","message":{"role":"assistant","content":[{"type":"text","text":"API Error 429"}]}}
{"type":"system","subtype":"turn_duration","timestamp":"$ts"}
{"type":"last-prompt","lastPrompt":"go"}
J
out=$("$STALLED" --file "$tmp/err.jsonl" T); rc=$?
[ "$rc" = 1 ] && [ "$out" = "T stalled 30m rate_limit" ] && ok || bad "error-last should exit 1 (rc=$rc out=$out)"

# activity after the error clears it
cat "$tmp/err.jsonl" > "$tmp/ok.jsonl"
echo "{\"type\":\"user\",\"timestamp\":\"$ts\",\"message\":{\"role\":\"user\",\"content\":\"poke\"}}" >> "$tmp/ok.jsonl"
out=$("$STALLED" --file "$tmp/ok.jsonl" T); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "recovered should be silent rc 0 (rc=$rc out=$out)"

# reset parsing: one error entry with the given text, 30 minutes old (or custom timestamp $3)
err_with() { # file text [timestamp]
  printf '%s\n' "{\"type\":\"assistant\",\"timestamp\":\"${3:-$ts}\",\"isApiErrorMessage\":true,\"error\":\"rate_limit\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"$2\"}]}}" > "$1"
}

# z.ai stamps its reset in UTC+8: 2026-10-15 02:20:00+08:00 is 20m after NOW (2026-10-14T18:00:00Z)
zfut="2026-10-15 02:20:00"
zfut_hm=$(hm_iso "2026-10-15T02:20:00+08:00")
err_with "$tmp/zai.jsonl" "API Error: Request rejected (429) · [1308][Usage limit reached for 5 hour. Your limit will reset at $zfut][x]"
out=$("$STALLED" --file "$tmp/zai.jsonl" Z); rc=$?
[ "$rc" = 1 ] && [ "$out" = "Z stalled 30m rate_limit reset $zfut_hm (in 20m)" ] && ok || bad "zai future: rc=$rc $out"
out=$("$STALLED" --due --file "$tmp/zai.jsonl" Z); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "--due hides a future reset (rc=$rc out=$out)"
# the zone is configurable: the same stamp read in UTC+14 is 6h earlier (340m before NOW), so already passed
zkir_hm=$(hm_iso "2026-10-15T02:20:00+14:00")
out=$(SYG_STALLED_ZAI_TZ=Pacific/Kiritimati "$STALLED" --due --file "$tmp/zai.jsonl" Z); rc=$?
[ "$rc" = 1 ] && [ "$out" = "Z stalled 30m rate_limit reset $zkir_hm (passed 340m ago)" ] && ok || bad "zone override: rc=$rc $out"

zpast="2026-10-15 01:56:00"
zpast_hm=$(hm_iso "2026-10-15T01:56:00+08:00")
err_with "$tmp/zai2.jsonl" "Usage limit reached for 5 hour. Your limit will reset at $zpast"
out=$("$STALLED" --due --file "$tmp/zai2.jsonl" Z); rc=$?
[ "$rc" = 1 ] && [ "$out" = "Z stalled 30m rate_limit reset $zpast_hm (passed 4m ago)" ] && ok || bad "--due shows a passed reset: rc=$rc $out"

# a future reset under 60s away must round up to 1m, never 'in 0m'
zsoon="2026-10-15 02:00:30"
zsoon_hm=$(hm_iso "2026-10-15T02:00:30+08:00")
err_with "$tmp/zsoon.jsonl" "Usage limit reached for 5 hour. Your limit will reset at $zsoon"
out=$("$STALLED" --file "$tmp/zsoon.jsonl" Z); rc=$?
[ "$rc" = 1 ] && [ "$out" = "Z stalled 30m rate_limit reset $zsoon_hm (in 1m)" ] && ok || bad "under-60s future reset: rc=$rc $out"

# Anthropic names a wall-clock time and its zone; minutes are optional (ts is 13:30 EDT, NOW is 14:00 EDT)
afut_hm=$(hm_iso "2026-10-14T14:40:00-04:00")
err_with "$tmp/ant.jsonl" "You've hit your session limit · resets 2:40pm (America/New_York)"
out=$("$STALLED" --file "$tmp/ant.jsonl" A); rc=$?
[ "$rc" = 1 ] && [ "$out" = "A stalled 30m rate_limit reset $afut_hm (in 40m)" ] && ok || bad "anthropic future: rc=$rc $out"

apast_hm=$(hm_iso "2026-10-14T13:50:00-04:00")
err_with "$tmp/ant2.jsonl" "You've hit your session limit · resets 1:50pm (America/New_York)"
out=$("$STALLED" --due --file "$tmp/ant2.jsonl" A); rc=$?
[ "$rc" = 1 ] && [ "$out" = "A stalled 30m rate_limit reset $apast_hm (passed 10m ago)" ] && ok || bad "anthropic passed: rc=$rc $out"

a9_hm=$(hm_iso "2026-10-14T21:00:00-04:00")
err_with "$tmp/ant3.jsonl" "You've hit your session limit · resets 9pm (America/New_York)"
out=$("$STALLED" --file "$tmp/ant3.jsonl" A); rc=$?
[ "$rc" = 1 ] && [ "$out" = "A stalled 30m rate_limit reset $a9_hm (in 420m)" ] && ok || bad "hour-only form: rc=$rc $out"

# same-minute comparison (at minute precision, not jumping +24h when ts has seconds) and +1 day rollover
roll_ts="2026-10-14T17:30:00.050Z"
same_hm=$(hm_iso "2026-10-14T13:30:00-04:00")
err_with "$tmp/same.jsonl" "You've hit your session limit · resets 1:30pm (America/New_York)" "$roll_ts"
out=$("$STALLED" --due --file "$tmp/same.jsonl" A); rc=$?
[ "$rc" = 1 ] && [ "$out" = "A stalled 29m rate_limit reset $same_hm (passed 30m ago)" ] \
  && ok || bad "same-minute reset must not jump +24h: rc=$rc $out"

roll_hm=$(hm_iso "2026-10-15T13:29:00-04:00")
roll_ymd_hm=$(ymd_hm_iso "2026-10-15T13:29:00-04:00")
err_with "$tmp/roll.jsonl" "You've hit your session limit · resets 1:29pm (America/New_York)" "$roll_ts"
out=$("$STALLED" --file "$tmp/roll.jsonl" A); rc=$?
[ "$rc" = 1 ] && [ "$out" = "A stalled 29m rate_limit reset $roll_hm (in 1409m)" ] \
  && ok || bad "day rollover (+1 day): rc=$rc $out"
out=$("$STALLED" --due --file "$tmp/roll.jsonl" A); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "day rollover hidden under --due: rc=$rc $out"
out=$(SYG_STALLED_NOW="2026-10-16T18:00:00Z" "$STALLED" --due --file "$tmp/roll.jsonl" A); rc=$?
[ "$rc" = 1 ] && [ "$out" = "A stalled 2909m rate_limit reset $roll_ymd_hm (passed 1471m ago)" ] \
  && ok || bad "day rollover rolled date: rc=$rc $out"

# DST in America/New_York:
# 1) fall-back 2026-11-01: error at 01:30 EDT (-04:00) with 'resets 1:15am' -> 01:15 EST (-05:00), 45m later
fb_hm=$(hm_iso "2026-11-01T01:15:00-05:00")
fb_ymd_hm=$(ymd_hm_iso "2026-11-01T01:15:00-05:00")
err_with "$tmp/dst_fb.jsonl" "You've hit your session limit · resets 1:15am (America/New_York)" "2026-11-01T01:30:00-04:00"
out=$(SYG_STALLED_NOW="2026-11-01T01:45:00-04:00" "$STALLED" --file "$tmp/dst_fb.jsonl" A); rc=$?
[ "$rc" = 1 ] && [ "$out" = "A stalled 15m rate_limit reset $fb_hm (in 30m)" ] \
  && ok || bad "DST fall-back 01:30 EDT resets 1:15am (in 30m): rc=$rc $out"
out=$(SYG_STALLED_NOW="2026-11-01T01:45:00-04:00" "$STALLED" --due --file "$tmp/dst_fb.jsonl" A); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "DST fall-back future fold hidden under --due: rc=$rc $out"
out=$(SYG_STALLED_NOW="2026-11-01T01:30:00-05:00" "$STALLED" --due --file "$tmp/dst_fb.jsonl" A); rc=$?
[ "$rc" = 1 ] && [ "$out" = "A stalled 60m rate_limit reset $fb_hm (passed 15m ago)" ] \
  && ok || bad "DST fall-back passed second fold: rc=$rc $out"
out=$(SYG_STALLED_NOW="2026-11-02T02:15:00-05:00" "$STALLED" --due --file "$tmp/dst_fb.jsonl" A); rc=$?
[ "$rc" = 1 ] && [ "$out" = "A stalled 1545m rate_limit reset $fb_ymd_hm (passed 1500m ago)" ] \
  && ok || bad "DST fall-back date stays 2026-11-01: rc=$rc $out"
# the dated form takes the same fold as the hour-only form
err_with "$tmp/dst_fb_dated.jsonl" "You've hit your session limit · resets Nov 1, 1:15am (America/New_York)" "2026-11-01T01:30:00-04:00"
out=$(SYG_STALLED_NOW="2026-11-01T01:45:00-04:00" "$STALLED" --file "$tmp/dst_fb_dated.jsonl" A); rc=$?
[ "$rc" = 1 ] && [ "$out" = "A stalled 15m rate_limit reset $fb_hm (in 30m)" ] \
  && ok || bad "DST fall-back dated form picks the later fold: rc=$rc $out"

# 2) spring-forward 2026-03-08: 'resets 2:30am' in gap normalises via UTC round trip to 03:30 EDT (-04:00)
sf_hm=$(hm_iso "2026-03-08T03:30:00-04:00")
sf_ymd_hm=$(ymd_hm_iso "2026-03-08T03:30:00-04:00")
err_with "$tmp/dst_sf.jsonl" "You've hit your session limit · resets 2:30am (America/New_York)" "2026-03-08T01:30:00-05:00"
out=$(SYG_STALLED_NOW="2026-03-08T01:45:00-05:00" "$STALLED" --file "$tmp/dst_sf.jsonl" A); rc=$?
[ "$rc" = 1 ] && [ "$out" = "A stalled 15m rate_limit reset $sf_hm (in 45m)" ] \
  && ok || bad "DST spring-forward 2:30am gap normalised: rc=$rc $out"
out=$(SYG_STALLED_NOW="2026-03-08T01:45:00-05:00" "$STALLED" --due --file "$tmp/dst_sf.jsonl" A); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "DST spring-forward future hidden under --due: rc=$rc $out"
out=$(SYG_STALLED_NOW="2026-03-09T04:30:00-04:00" "$STALLED" --due --file "$tmp/dst_sf.jsonl" A); rc=$?
[ "$rc" = 1 ] && [ "$out" = "A stalled 1560m rate_limit reset $sf_ymd_hm (passed 1500m ago)" ] \
  && ok || bad "DST spring-forward date: rc=$rc $out"

sf2_hm=$(hm_iso "2026-03-09T02:30:00-04:00")
sf2_ymd_hm=$(ymd_hm_iso "2026-03-09T02:30:00-04:00")
err_with "$tmp/dst_sf2.jsonl" "You've hit your session limit · resets 2:30am (America/New_York)" "2026-03-08T04:00:00-04:00"
out=$(SYG_STALLED_NOW="2026-03-08T04:30:00-04:00" "$STALLED" --file "$tmp/dst_sf2.jsonl" A); rc=$?
[ "$rc" = 1 ] && [ "$out" = "A stalled 30m rate_limit reset $sf2_hm (in 1320m)" ] \
  && ok || bad "DST spring-forward post-gap rolls to 2026-03-09 02:30 EDT: rc=$rc $out"
out=$(SYG_STALLED_NOW="2026-03-10T03:30:00-04:00" "$STALLED" --due --file "$tmp/dst_sf2.jsonl" A); rc=$?
[ "$rc" = 1 ] && [ "$out" = "A stalled 2850m rate_limit reset $sf2_ymd_hm (passed 1500m ago)" ] \
  && ok || bad "DST spring-forward post-gap rolled date: rc=$rc $out"

# Anthropic date forms ('resets Mon DD, ...' and 'resets Mon DD at ...'), >24h date output, 12am/12pm, uppercase AM/PM
d3_9pm=$(ymd_hm_iso "2026-10-17T21:00:00-04:00")
err_with "$tmp/ant_date1.jsonl" "You've hit your limit · resets Oct 17, 9pm (America/New_York)"
out=$("$STALLED" --file "$tmp/ant_date1.jsonl" A); rc=$?
[ "$rc" = 1 ] && [ "$out" = "A stalled 30m rate_limit reset $d3_9pm (in 4740m)" ] \
  && ok || bad "anthropic date comma form >24h: rc=$rc $out"
out=$("$STALLED" --due --file "$tmp/ant_date1.jsonl" A); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "anthropic future date hidden under --due: rc=$rc $out"

d3_12am=$(ymd_hm_iso "2026-10-17T00:00:00-04:00")
err_with "$tmp/ant_12am.jsonl" "You've hit your limit · resets Oct 17 at 12am (America/New_York)"
out=$("$STALLED" --file "$tmp/ant_12am.jsonl" A); rc=$?
[ "$rc" = 1 ] && [ "$out" = "A stalled 30m rate_limit reset $d3_12am (in 3480m)" ] \
  && ok || bad "anthropic date 'at' + 12am: rc=$rc $out"

d3_12pm=$(ymd_hm_iso "2026-10-17T12:00:00-04:00")
err_with "$tmp/ant_12pm.jsonl" "You've hit your limit · resets Oct 17 at 12PM (America/New_York)"
out=$("$STALLED" --file "$tmp/ant_12pm.jsonl" A); rc=$?
[ "$rc" = 1 ] && [ "$out" = "A stalled 30m rate_limit reset $d3_12pm (in 4200m)" ] \
  && ok || bad "anthropic date 'at' + uppercase 12PM: rc=$rc $out"

d3_915am=$(ymd_hm_iso "2026-10-17T09:15:00-04:00")
err_with "$tmp/ant_am.jsonl" "You've hit your limit · resets Oct 17, 9:15AM (America/New_York)"
out=$("$STALLED" --file "$tmp/ant_am.jsonl" A); rc=$?
[ "$rc" = 1 ] && [ "$out" = "A stalled 30m rate_limit reset $d3_915am (in 4035m)" ] \
  && ok || bad "anthropic uppercase AM: rc=$rc $out"

# Dated form across DST transition (error in EDT -04:00, target date Nov 5 in EST -05:00)
nov5_9pm=$(ymd_hm_iso "2026-11-05T21:00:00-05:00")
err_with "$tmp/ant_dst_date.jsonl" "You've hit your limit · resets Nov 5, 9pm (America/New_York)"
out=$("$STALLED" --file "$tmp/ant_dst_date.jsonl" A); rc=$?
[ "$rc" = 1 ] && [ "$out" = "A stalled 30m rate_limit reset $nov5_9pm (in 32160m)" ] \
  && ok || bad "dated form across DST gets EST offset: rc=$rc $out"

# Dated form with Feb 29 across a year boundary (error in non-leap 2027-12-15 -> 2028-02-29)
feb29_ymd_hm=$(ymd_hm_iso "2028-02-29T21:00:00-05:00")
err_with "$tmp/feb29_next.jsonl" "You've hit your limit · resets Feb 29, 9pm (America/New_York)" "2027-12-15T17:30:00Z"
out=$(SYG_STALLED_NOW="2027-12-15T18:00:00Z" "$STALLED" --file "$tmp/feb29_next.jsonl" A); rc=$?
[ "$rc" = 1 ] && [ "$out" = "A stalled 30m rate_limit reset $feb29_ymd_hm (in 109920m)" ] \
  && ok || bad "Feb 29 across year boundary (2027 -> 2028): rc=$rc $out"
out=$(SYG_STALLED_NOW="2027-12-15T18:00:00Z" "$STALLED" --due --file "$tmp/feb29_next.jsonl" A); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "Feb 29 next year hidden under --due: rc=$rc $out"

# Feb 29 within 180 days in the past in a leap year (2028-03-01 -> 2028-02-29)
feb29_hm=$(hm_iso "2028-02-29T21:00:00-05:00")
err_with "$tmp/feb29_same.jsonl" "You've hit your limit · resets Feb 29, 9pm (America/New_York)" "2028-03-01T17:30:00Z"
out=$(SYG_STALLED_NOW="2028-03-01T18:00:00Z" "$STALLED" --due --file "$tmp/feb29_same.jsonl" A); rc=$?
[ "$rc" = 1 ] && [ "$out" = "A stalled 30m rate_limit reset $feb29_hm (passed 960m ago)" ] \
  && ok || bad "Feb 29 recent past in leap year: rc=$rc $out"

# Feb 29 more than 180 days in the past in a leap year (2028-12-15 -> 2029 has no Feb 29 -> unparsed)
err_with "$tmp/feb29_old.jsonl" "You've hit your limit · resets Feb 29, 9pm (America/New_York)" "2028-12-15T17:30:00Z"
out=$(SYG_STALLED_NOW="2028-12-15T18:00:00Z" "$STALLED" --file "$tmp/feb29_old.jsonl" A); rc=$?
[ "$rc" = 1 ] && [ "$out" = "A stalled 30m rate_limit" ] && ok || bad "Feb 29 >180d past in 2028 unparsed: rc=$rc $out"
out=$(SYG_STALLED_NOW="2028-12-15T18:00:00Z" "$STALLED" --due --file "$tmp/feb29_old.jsonl" A); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "Feb 29 >180d past in 2028 under --due fails closed: rc=$rc $out"

# hours outside 1..12 (0, 13..99) must be treated as unparsed, and fail closed under --due
for bad_hr in "0am" "13pm" "99pm"; do
  err_with "$tmp/badhr.jsonl" "You've hit your session limit · resets $bad_hr (America/New_York)"
  out=$("$STALLED" --file "$tmp/badhr.jsonl" A); rc=$?
  [ "$rc" = 1 ] && [ "$out" = "A stalled 30m rate_limit" ] && ok || bad "hour $bad_hr should be unparsed (rc=$rc out=$out)"
  out=$("$STALLED" --due --file "$tmp/badhr.jsonl" A); rc=$?
  [ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "hour $bad_hr under --due must fail closed (rc=$rc out=$out)"
done

# broadened has_reset (\breset case-insensitive) and bare string items in content list
for phrase in "will reset in 3 hours" "reset on Friday" "reset 9pm" "RESET soon"; do
  err_with "$tmp/hasreset.jsonl" "$phrase"
  out=$("$STALLED" --file "$tmp/hasreset.jsonl" A); rc=$?
  [ "$rc" = 1 ] && [ "$out" = "A stalled 30m rate_limit" ] && ok || bad "has_reset phrase '$phrase' without --due (rc=$rc out=$out)"
  out=$("$STALLED" --due --file "$tmp/hasreset.jsonl" A); rc=$?
  [ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "has_reset phrase '$phrase' under --due fails closed (rc=$rc out=$out)"
done
# a dropped connection names no quota reset: still due
for phrase in "API Error: Connection reset by peer" "socket hang up: ECONNRESET" "connection RESET" \
  "The connection was reset" "reset by peer"; do
  err_with "$tmp/netreset.jsonl" "$phrase"
  out=$("$STALLED" --due --file "$tmp/netreset.jsonl" A); rc=$?
  [ "$rc" = 1 ] && [ "$out" = "A stalled 30m rate_limit" ] && ok || bad "network reset '$phrase' is due (rc=$rc out=$out)"
done

printf '%s\n' "{\"type\":\"assistant\",\"timestamp\":\"$ts\",\"isApiErrorMessage\":true,\"error\":\"rate_limit\",\"message\":{\"role\":\"assistant\",\"content\":[\"will reset in 3 hours\"]}}" > "$tmp/strlist.jsonl"
out=$("$STALLED" --due --file "$tmp/strlist.jsonl" A); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "bare string item in content list has_reset under --due (rc=$rc out=$out)"
printf '%s\n' "{\"type\":\"assistant\",\"timestamp\":\"$ts\",\"isApiErrorMessage\":true,\"error\":\"rate_limit\",\"message\":{\"role\":\"assistant\",\"content\":[\"limit hit · \",\"resets 9pm (America/New_York)\"]}}" > "$tmp/strlist2.jsonl"
out=$("$STALLED" --file "$tmp/strlist2.jsonl" A); rc=$?
[ "$rc" = 1 ] && [ "$out" = "A stalled 30m rate_limit reset $a9_hm (in 420m)" ] && ok || bad "bare string item parsed reset (rc=$rc out=$out)"

# 7-day bound on unparsed reset under --due: <7 days fails closed, >=7 days is reported as due
err_with "$tmp/unparsed_6d.jsonl" "will reset in 3 hours" "2026-10-07T19:00:00Z"
out=$("$STALLED" --due --file "$tmp/unparsed_6d.jsonl" A); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "unparsed reset <7d old fails closed under --due (rc=$rc out=$out)"
err_with "$tmp/unparsed_7d.jsonl" "will reset in 3 hours" "2026-10-07T18:00:00Z"
out=$("$STALLED" --due --file "$tmp/unparsed_7d.jsonl" A); rc=$?
[ "$rc" = 1 ] && [ "$out" = "A stalled 10080m rate_limit" ] && ok || bad "unparsed reset 7d old reported as due (rc=$rc out=$out)"
err_with "$tmp/unparsed_8d.jsonl" "will reset in 3 hours" "2026-10-06T18:00:00Z"
out=$("$STALLED" --due --file "$tmp/unparsed_8d.jsonl" A); rc=$?
[ "$rc" = 1 ] && [ "$out" = "A stalled 11520m rate_limit" ] && ok || bad "unparsed reset 8d old reported as due (rc=$rc out=$out)"

# no reset text (an overload or 5xx stall): resumable now, so --due shows it, line unchanged
out=$("$STALLED" --due --file "$tmp/err.jsonl" T); rc=$?
[ "$rc" = 1 ] && [ "$out" = "T stalled 30m rate_limit" ] && ok || bad "--due without a reset shows it (rc=$rc out=$out)"
# a named reset that cannot be parsed (unknown zone or malformed reset text) fails closed under --due,
# while still reporting without reset when --due is not set
out=$(SYG_STALLED_ZAI_TZ=Bad/Zone "$STALLED" --file "$tmp/zai.jsonl" Z); rc=$?
[ "$rc" = 1 ] && [ "$out" = "Z stalled 30m rate_limit" ] && ok || bad "unknown zone without --due shows stall (rc=$rc out=$out)"
out=$(SYG_STALLED_ZAI_TZ=Bad/Zone "$STALLED" --due --file "$tmp/zai.jsonl" Z); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "unknown zone under --due fails closed (rc=$rc out=$out)"
err_with "$tmp/bad_zai.jsonl" "Usage limit reached. Your limit will reset at not-a-timestamp"
out=$("$STALLED" --due --file "$tmp/bad_zai.jsonl" Z); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "unparseable 'reset at' under --due fails closed (rc=$rc out=$out)"

# OverflowError inputs in reset_time must be caught and treated as unparsed (not crash)
err_with "$tmp/ovf_ant.jsonl" "You've hit your session limit · resets 9pm (America/New_York)" "0001-01-01T00:00:00+00:00"
out=$("$STALLED" --file "$tmp/ovf_ant.jsonl" A 2>&1); rc=$?
[ "$rc" = 1 ] && [ "$out" = "A stalled 1065459960m rate_limit" ] && ok || bad "OverflowError on 0001-01-01 NY reset (rc=$rc out=$out)"
out=$("$STALLED" --due --file "$tmp/ovf_ant.jsonl" A 2>&1); rc=$?
[ "$rc" = 1 ] && [ "$out" = "A stalled 1065459960m rate_limit" ] && ok || bad "OverflowError on 0001-01-01 NY reset under --due (>=7d old) (rc=$rc out=$out)"

err_with "$tmp/ovf_zai.jsonl" "Usage limit reached. Your limit will reset at 0001-01-01 00:00:00"
out=$("$STALLED" --file "$tmp/ovf_zai.jsonl" Z 2>&1); rc=$?
[ "$rc" = 1 ] && [ "$out" = "Z stalled 30m rate_limit" ] && ok || bad "OverflowError on z.ai 0001-01-01 reset (rc=$rc out=$out)"
out=$("$STALLED" --due --file "$tmp/ovf_zai.jsonl" Z 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "OverflowError on z.ai 0001-01-01 under --due fails closed (rc=$rc out=$out)"

# unexpected exception in check_file (e.g. invalid SYG_STALLED_NOW) prints 'session-stalled: ...' to stderr and exits 2
out=$(SYG_STALLED_NOW="not-a-timestamp" "$STALLED" --file "$tmp/err.jsonl" T 2>&1 >/dev/null); rc=$?
[ "$rc" = 2 ] && case "$out" in "session-stalled: "*) true ;; *) false ;; esac \
  && ok || bad "unexpected exception in check_file must exit 2 with session-stalled: message (rc=$rc out=$out)"

# crash inputs: non-object JSON lines, missing/null/naive/malformed timestamp, text null, message not a dict, error null
cat > "$tmp/nonobj.jsonl" <<'J'
123
"str"
[1, 2]
null
J
out=$("$STALLED" --file "$tmp/nonobj.jsonl" T 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "non-object JSON lines (rc=$rc out=$out)"

for bad_ts_line in \
  '{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","message":{"content":"err"}}' \
  '{"type":"assistant","timestamp":null,"isApiErrorMessage":true,"error":"rate_limit","message":{"content":"err"}}' \
  '{"type":"assistant","timestamp":"2026-10-14T12:00:00","isApiErrorMessage":true,"error":"rate_limit","message":{"content":"err"}}' \
  '{"type":"assistant","timestamp":"not-a-timestamp","isApiErrorMessage":true,"error":"rate_limit","message":{"content":"err"}}' \
  '{"type":"assistant","timestamp":"0001-01-01T00:00:00+08:00","isApiErrorMessage":true,"error":"rate_limit","message":{"content":"err"}}'
do
  printf '%s\n' "$bad_ts_line" > "$tmp/badts.jsonl"
  out=$("$STALLED" --file "$tmp/badts.jsonl" T 2>&1); rc=$?
  [ "$rc" = 1 ] && [ "$out" = "T stalled ?m rate_limit" ] && ok || bad "bad timestamp still reports the stall, age unknown (rc=$rc out=$out)"
done
# hour-only reset needs the error's date: with no readable stamp it is unparsed, so --due fails closed
printf '%s\n' '{"type":"assistant","timestamp":"not-a-timestamp","isApiErrorMessage":true,"error":"rate_limit","message":{"content":"resets 9pm (America/New_York)"}}' > "$tmp/badts.jsonl"
out=$("$STALLED" --due --file "$tmp/badts.jsonl" T 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "bad timestamp + hour-only reset under --due (rc=$rc out=$out)"

printf '%s\n' "{\"type\":\"assistant\",\"timestamp\":\"$ts\",\"isApiErrorMessage\":true,\"error\":\"rate_limit\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":null}]}}" > "$tmp/nulltext.jsonl"
out=$("$STALLED" --file "$tmp/nulltext.jsonl" T 2>&1); rc=$?
[ "$rc" = 1 ] && [ "$out" = "T stalled 30m rate_limit" ] && ok || bad "text null in content block (rc=$rc out=$out)"

printf '%s\n' "{\"type\":\"assistant\",\"timestamp\":\"$ts\",\"isApiErrorMessage\":true,\"error\":\"rate_limit\",\"message\":\"not-a-dict\"}" > "$tmp/badmsg.jsonl"
out=$("$STALLED" --file "$tmp/badmsg.jsonl" T 2>&1); rc=$?
[ "$rc" = 1 ] && [ "$out" = "T stalled 30m rate_limit" ] && ok || bad "message not a dict (rc=$rc out=$out)"

printf '%s\n' "{\"type\":\"assistant\",\"timestamp\":\"$ts\",\"isApiErrorMessage\":true,\"error\":null,\"message\":{\"content\":\"err\"}}" > "$tmp/nullerr.jsonl"
out=$("$STALLED" --file "$tmp/nullerr.jsonl" T 2>&1); rc=$?
[ "$rc" = 1 ] && [ "$out" = "T stalled 30m api_error" ] && ok || bad "error null prints api_error (rc=$rc out=$out)"

"$STALLED" --file "$tmp/nonexistent.jsonl" T >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok || bad "unreadable file must not exit 1 (rc=$rc)"

# flags in any order; an unknown argument or bare/option-followed --file is refused with exit 2
out=$("$STALLED" --file "$tmp/zai.jsonl" Z --due); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "--due after the name (rc=$rc out=$out)"
"$STALLED" --file "$tmp/zai.jsonl" Z --bogus >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok || bad "unknown argument should exit 2 (rc=$rc)"
"$STALLED" --file >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok || bad "--file with no arg should exit 2 (rc=$rc)"
"$STALLED" --file --due >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok || bad "--file followed by --due should exit 2 (rc=$rc)"
"$STALLED" --file -x >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok || bad "--file followed by option should exit 2 (rc=$rc)"

# the live path (no --file) under set -u: a stub `claude agents` with no sessions is silent rc 0
mkdir -p "$tmp/stub"; printf '#!/bin/sh\necho "[]"\n' > "$tmp/stub/claude"; chmod +x "$tmp/stub/claude"
out=$(PATH="$tmp/stub:$PATH" HOME="$tmp" "$STALLED" 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "live path with no sessions (rc=$rc out=$out)"

# live path: failing or non-JSON `claude agents --json` exits 2 with a message
printf '#!/bin/sh\nexit 1\n' > "$tmp/stub/claude"
out=$(PATH="$tmp/stub:$PATH" HOME="$tmp" "$STALLED" 2>&1); rc=$?
[ "$rc" = 2 ] && [ -n "$out" ] && ok || bad "live path failing claude exits 2 with message (rc=$rc out=$out)"

printf '#!/bin/sh\necho "not-json"\n' > "$tmp/stub/claude"
out=$(PATH="$tmp/stub:$PATH" HOME="$tmp" "$STALLED" 2>&1); rc=$?
[ "$rc" = 2 ] && [ -n "$out" ] && ok || bad "live path non-JSON claude exits 2 with message (rc=$rc out=$out)"

# live path: missing ~/.claude/projects exits 2 with a message when sessions exist
cat > "$tmp/stub/claude" <<'EOF'
#!/bin/sh
printf '[{"name":"a","sessionId":"sid-1"}]\n'
EOF
chmod +x "$tmp/stub/claude"
out=$(PATH="$tmp/stub:$PATH" HOME="$tmp" "$STALLED" 2>&1); rc=$?
[ "$rc" = 2 ] && [ -n "$out" ] && ok || bad "live path missing ~/.claude/projects exits 2 (rc=$rc out=$out)"

# live path: 'no transcript' in a readable ~/.claude/projects is silent rc 0
mkdir -p "$tmp/.claude/projects/proj"
out=$(PATH="$tmp/stub:$PATH" HOME="$tmp" "$STALLED" 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "live path no transcript is silent rc 0 (rc=$rc out=$out)"

# mode-000 cases mean nothing to root, who reads through them
if [ "$(id -u)" != 0 ]; then
# live path: unreadable ~/.claude/projects exits 2 with a message
chmod 000 "$tmp/.claude/projects"
out=$(PATH="$tmp/stub:$PATH" HOME="$tmp" "$STALLED" 2>&1); rc=$?
chmod 755 "$tmp/.claude/projects"
[ "$rc" = 2 ] && [ -n "$out" ] && ok || bad "live path unreadable ~/.claude/projects exits 2 (rc=$rc out=$out)"

# live path: find failing on an unreadable project folder is an error, not 'no transcript'
mkdir -p "$tmp/.claude/projects/locked"
chmod 000 "$tmp/.claude/projects/locked"
out=$(PATH="$tmp/stub:$PATH" HOME="$tmp" "$STALLED" 2>&1); rc=$?
chmod 755 "$tmp/.claude/projects/locked"
[ "$rc" = 2 ] && ok || bad "live path find failure exits 2 (rc=$rc out=$out)"
fi

# live path: \037 separator preserves tabs in session names
cp "$tmp/err.jsonl" "$tmp/.claude/projects/proj/sid-1.jsonl"
cat > "$tmp/stub/claude" <<'EOF'
#!/bin/sh
printf '[{"name":"tab\\tname","sessionId":"sid-1"}]\n'
EOF
chmod +x "$tmp/stub/claude"
out=$(PATH="$tmp/stub:$PATH" HOME="$tmp" "$STALLED" 2>&1); rc=$?
[ "$rc" = 1 ] && [ "$out" = $'tab\tname stalled 30m rate_limit' ] && ok || bad "live path with tab in name (rc=$rc out=$out)"

# live path: a find error elsewhere doesn't drop a transcript it found. The scan visits every
# folder (no -quit), so the find error always happens: rc 2, the error itself on stderr, and
# the found transcript still checked. (The old assertion accepted rc 1 too, which a run that
# never reached the error also gave.)
if [ "$(id -u)" != 0 ]; then
chmod 000 "$tmp/.claude/projects/locked"
out=$(PATH="$tmp/stub:$PATH" HOME="$tmp" "$STALLED" 2>"$tmp/f7.err"); rc=$?
chmod 755 "$tmp/.claude/projects/locked"
if [ "$rc" = 2 ] && [ "$out" = $'tab\tname stalled 30m rate_limit' ] && grep -q "find: .*locked" "$tmp/f7.err"; then
  ok
else
  bad "found transcript kept beside a find error (rc=$rc out=$out err=$(cat "$tmp/f7.err"))"
fi
fi

# agents entries that are not usable sessions are skipped with one warn naming the index;
# the rest of the list is still checked. A name that is null is not printed as None.
mkdir -p "$tmp/mal/.claude/projects/proj"
cp "$tmp/err.jsonl" "$tmp/mal/.claude/projects/proj/sid-1.jsonl"
mal_run() { # $1 agents JSON: sets rc, out (stdout) and err (stderr)
  printf '%s\n' "$1" >"$tmp/mal.json"
  printf '#!/bin/sh\ncat "%s"\n' "$tmp/mal.json" >"$tmp/stub/claude"
  chmod +x "$tmp/stub/claude"
  out=$(PATH="$tmp/stub:$PATH" HOME="$tmp/mal" "$STALLED" 2>"$tmp/mal.err"); rc=$?
  err=$(cat "$tmp/mal.err")
}
mal_run '[{"sessionId":null},{"name":"ok","sessionId":"sid-1"}]'
[ "$rc" = 1 ] && [ "$out" = "ok stalled 30m rate_limit" ] && [ "$err" = "session-stalled: skipping agents entry 0: not a dict, no string sessionId, or null pid" ] \
  && ok || bad "null sessionId skipped with a warn, rest checked (rc=$rc out=$out err=$err)"
mal_run '[{"name":"nosid"},{"name":"ok","sessionId":"sid-1"}]'
[ "$rc" = 1 ] && [ "$out" = "ok stalled 30m rate_limit" ] && [[ $err == *"skipping agents entry 0:"* ]] \
  && ok || bad "missing sessionId skipped with a warn (rc=$rc out=$out err=$err)"
mal_run '[null]'
[ "$rc" = 0 ] && [ -z "$out" ] && [[ $err == *"skipping agents entry 0:"* ]] \
  && ok || bad "[null] entry skipped, rc 0 (rc=$rc out=$out err=$err)"
mal_run '["x",{"name":"ok","sessionId":"sid-1"}]'
[ "$rc" = 1 ] && [ "$out" = "ok stalled 30m rate_limit" ] && [[ $err == *"skipping agents entry 0:"* ]] \
  && ok || bad "non-dict entry skipped with a warn (rc=$rc out=$out err=$err)"
mal_run '[{"name":"dead","pid":null,"sessionId":"sid-1"}]'
[ "$rc" = 0 ] && [ -z "$out" ] && [[ $err == *"skipping agents entry 0:"* ]] \
  && ok || bad "null pid skipped (a dead agent is not stalled) (rc=$rc out=$out err=$err)"
mal_run '[{"name":null,"sessionId":"sid-1"}]'
[ "$rc" = 1 ] && [ "$out" = "sid-1 stalled 30m rate_limit" ] && [ -z "$err" ] \
  && ok || bad "null name falls back to the session prefix, not None (rc=$rc out=$out err=$err)"
# a sessionId holding glob characters must match only its own transcript
mkdir -p "$tmp/glob/.claude/projects/proj"
cp "$tmp/err.jsonl" "$tmp/glob/.claude/projects/proj/sid-1.jsonl"
printf '[{"name":"g","sessionId":"*"}]\n' >"$tmp/glob.json"
printf '#!/bin/sh\ncat "%s"\n' "$tmp/glob.json" >"$tmp/stub/claude"
out=$(PATH="$tmp/stub:$PATH" HOME="$tmp/glob" "$STALLED" 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "glob sessionId matches no other transcript (rc=$rc out=$out)"


# live path: check_file exit 2 does not abort the scan; stalled lines are still printed and exit is 2
ln -s "$tmp/nonexistent.jsonl" "$tmp/.claude/projects/proj/sid-bad.jsonl"
cp "$tmp/err.jsonl" "$tmp/.claude/projects/proj/sid-2.jsonl"
cat > "$tmp/stub/claude" <<'EOF'
#!/bin/sh
printf '[{"name":"first","sessionId":"sid-1"},{"name":"broken","sessionId":"sid-bad"},{"name":"second","sessionId":"sid-2"}]\n'
EOF
chmod +x "$tmp/stub/claude"
out=$(PATH="$tmp/stub:$PATH" HOME="$tmp" "$STALLED" 2>"$tmp/live.err"); rc=$?
err_out=$(cat "$tmp/live.err")
[ "$rc" = 2 ] && [ "$out" = $'first stalled 30m rate_limit\nsecond stalled 30m rate_limit' ] && [ -n "$err_out" ] \
  && ok || bad "live path continues after check_file exit 2 (rc=$rc out=$out err=$err_out)"

# api-request-blob: trailing after an API error still leaves the session stalled; replaying an API error after recovery is not stalled
{ cat "$tmp/err.jsonl"
  printf '{"type":"api-request-blob","timestamp":null,"message":{"role":"user","content":"ok"}}\n'
} > "$tmp/err_blob.jsonl"
out=$("$STALLED" --file "$tmp/err_blob.jsonl" B); rc=$?
[ "$rc" = 1 ] && [ "$out" = "B stalled 30m rate_limit" ] && ok || bad "trailing api-request-blob keeps stall (rc=$rc out=$out)"
{ cat "$tmp/err.jsonl"
  printf '{"type":"assistant","timestamp":"2026-10-14T18:05:00Z","message":{"role":"assistant","content":"recovered"}}\n'
  printf '{"type":"api-request-blob","timestamp":null,"isApiErrorMessage":true,"error":"rate_limit","message":{"role":"assistant","content":"limit hit"}}\n'
} > "$tmp/rec_blob.jsonl"
out=$("$STALLED" --file "$tmp/rec_blob.jsonl" B); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "api-request-blob replaying error after recovery is not stalled (rc=$rc out=$out)"

# the live scan's transcript root: CLAUDE_PROJECTS_DIR, else CLAUDE_CONFIG_DIR/projects, else ~/.claude/projects
cat > "$tmp/stub/claude" <<'STUB'
#!/bin/sh
printf '[{"name":"cfg","sessionId":"sid-1"}]\n'
STUB
mkdir -p "$tmp/cfgdir/projects/proj" "$tmp/pd/proj" "$tmp/nohome"
cp "$tmp/err.jsonl" "$tmp/cfgdir/projects/proj/sid-1.jsonl"
out=$(PATH="$tmp/stub:$PATH" HOME="$tmp/nohome" CLAUDE_CONFIG_DIR="$tmp/cfgdir" "$STALLED" 2>&1); rc=$?
[ "$rc" = 1 ] && [ "$out" = "cfg stalled 30m rate_limit" ] && ok || bad "live scan reads CLAUDE_CONFIG_DIR/projects (rc=$rc out=$out)"
out=$(PATH="$tmp/stub:$PATH" HOME="$tmp/nohome" CLAUDE_CONFIG_DIR="$tmp/cfgdir" CLAUDE_PROJECTS_DIR="$tmp/pd" "$STALLED" 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "CLAUDE_PROJECTS_DIR wins over CLAUDE_CONFIG_DIR (rc=$rc out=$out)"
cp "$tmp/err.jsonl" "$tmp/pd/proj/sid-1.jsonl"
out=$(PATH="$tmp/stub:$PATH" HOME="$tmp/nohome" CLAUDE_CONFIG_DIR="$tmp/nope" CLAUDE_PROJECTS_DIR="$tmp/pd" "$STALLED" 2>&1); rc=$?
[ "$rc" = 1 ] && [ "$out" = "cfg stalled 30m rate_limit" ] && ok || bad "CLAUDE_PROJECTS_DIR is read (rc=$rc out=$out)"
out=$(PATH="$tmp/stub:$PATH" HOME="$tmp/nohome" CLAUDE_PROJECTS_DIR="$tmp/nope" "$STALLED" 2>&1); rc=$?
[ "$rc" = 2 ] && [ "$out" = "session-stalled: $tmp/nope is missing or unreadable" ] && ok || bad "missing root names the root dir (rc=$rc out=$out)"


# an agent entry without a name is listed under its 8-character session prefix; the scan carries on
mkdir -p "$tmp/unhome/.claude/projects/proj"
cp "$tmp/err.jsonl" "$tmp/unhome/.claude/projects/proj/abcdef123456.jsonl"
cp "$tmp/err.jsonl" "$tmp/unhome/.claude/projects/proj/sid-n.jsonl"
cat > "$tmp/stub/claude" <<'STUB'
#!/bin/sh
printf '[{"sessionId":"abcdef123456"},{"name":"","sessionId":"abcdef123456"},{"name":"named","sessionId":"sid-n"}]\n'
STUB
out=$(PATH="$tmp/stub:$PATH" HOME="$tmp/unhome" "$STALLED" 2>&1); rc=$?
[ "$rc" = 1 ] && [ "$out" = $'abcdef12 stalled 30m rate_limit\nabcdef12 stalled 30m rate_limit\nnamed stalled 30m rate_limit' ] \
  && ok || bad "unnamed agents listed by session prefix (rc=$rc out=$out)"

# --help starts with the tool's own name
out=$("$STALLED" --help); rc=$?
case "$out" in "session-stalled: "*) [ "$rc" = 0 ] && ok || bad "--help exit code (rc=$rc)" ;; *) bad "--help must start with session-stalled: (out=${out%%$'\n'*})" ;; esac

# an unknown argument names the tool
out=$("$STALLED" --bogus 2>&1); rc=$?
[ "$rc" = 2 ] && [ "$out" = "session-stalled: unknown argument: --bogus" ] && ok || bad "unknown-argument message names session-stalled (rc=$rc out=$out)"

[ "$fail" = 0 ] && echo "ok:   session-stalled: $pass cases passed"
echo "session-stalled probe: $pass passed, $fail failed"
[ "$fail" = 0 ]
