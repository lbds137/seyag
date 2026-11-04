#!/bin/bash
# Fixture check for plugins/seyag/bin/week-burn-window, the reference helper for
# CLAUDE_USAGE_WEEK_RESERVE_CMD: it prints 99 once the time to the weekly reset fits inside the
# burn window (rate from the readings log's slope, floored for a flat or falling week, plus a
# margin), and the hold reserve — CLAUDE_USAGE_WEEK_RESERVE when that is an integer 1-99, else
# 75 — on every other decided path (far reset, no log, unparsable or stale readings with no
# fresh .last fetch record, a future-dated latest row, out-of-range floats like 1e999 or a NaN
# weekly_pct, no usable rate, past or missing reset, week >= 100), quietly and with exit 0. A
# set-but-invalid SYG_WEEK_BURN_* override — including one too long to do arithmetic on — is
# crash-class: exit 1, nothing on stdout. Fixture readings live under a probe-local
# XDG_STATE_HOME and the clock is pinned with SYG_WEEK_BURN_NOW, so the real state log and the
# real time are never touched (the .last fixtures are content writes carrying the fetch epoch,
# the same way).
# Usage: tests/week-burn-window.probe.sh   (from anywhere)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WW=${WW_BIN:-"$REPO/plugins/seyag/bin/week-burn-window"}
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state/claude-usage"
log="$tmp/state/claude-usage/readings.jsonl"
T=1790400000 # fixture clock; every row's epoch and reset are written relative to it

rd() { printf '{"epoch":%s,"five_hour_pct":0,"weekly_pct":%s,"weekly_resets_at":%s,"ts":"fixture"}\n' "$1" "$2" "$3"; }

# ww <stdout want> <label> [VAR=v ...]: run the helper against the fixture state at the test
# clock; every decided path must print exactly one integer and exit 0.
ww() {
    local want=$1 label=$2; shift 2
    out=$(env XDG_STATE_HOME="$tmp/state" SYG_WEEK_BURN_NOW="$T" "$@" "$WW"); rc=$?
    [ "$rc" = 0 ] && [ "$out" = "$want" ] && ok "$label (got $out)" || bad "$label: rc=$rc out=[$out] want=[$want]"
}

# burn fixture: week 80->90 over 2 h (slope 5 %/h), reset inside the burn window
# (100-90)/5 h + 30 min = 9000 s for the default margin.
{ rd $((T - 7200)) 80 $((T + 5400)); rd $((T - 3600)) 85 $((T + 5400)); rd "$T" 90 $((T + 5400)); } > "$log"
ww 99 "burn-on: converging week near the reset prints 99"

{ rd $((T - 7200)) 80 $((T + 20000)); rd $((T - 3600)) 85 $((T + 20000)); rd "$T" 90 $((T + 20000)); } > "$log"
ww 75 "hold-when-far: reset 20000s out sits beyond the 9000s window"

rm -f "$log"
ww 75 "no log: holds at the default 75"

: > "$log"
ww 75 "empty log: no parsable rows holds"

{ echo 'not json at all'; echo '{"epoch":"x"}'; echo '[]'; rd $((T - 3600)) 85 $((T + 20000)); echo '{"epoch":1}'; rd "$T" 90 $((T + 20000)); } > "$log"
ww 75 "mixed parsable/unparsable: garbage skipped, parsable rows hold (far reset)"

{ echo 'garbage first'; rd $((T - 7200)) 80 $((T + 5400)); echo '{"weekly_pct":90}'; rd $((T - 3600)) 85 $((T + 5400)); rd "$T" 90 $((T + 5400)); } > "$log"
ww 99 "mixed parsable/unparsable: garbage skipped, parsable rows still burn"

# Out-of-range floats parse as JSON (1e999 -> inf) but crash int() with OverflowError outside
# the skip/keep tuples: they must degrade like any other untrusted row — hold quietly, exit 0,
# nothing on stderr, never a traceback.
{ printf '{"epoch":1e999,"five_hour_pct":0,"weekly_pct":90,"weekly_resets_at":%s,"ts":"fixture"}\n' "$((T + 5400))"; } > "$log"
out=$(env XDG_STATE_HOME="$tmp/state" SYG_WEEK_BURN_NOW="$T" "$WW" 2>"$tmp/err"); rc=$?
[ $rc = 0 ] && [ "$out" = 75 ] && [ ! -s "$tmp/err" ] \
    && ok "epoch 1e999 (inf): the row is skipped, no parsable rows holds quietly" \
    || bad "epoch 1e999: rc=$rc out=[$out] err=[$(cat "$tmp/err")]"
{ printf '{"epoch":%s,"five_hour_pct":0,"weekly_pct":90,"weekly_resets_at":1e999,"ts":"fixture"}\n' "$T"; } > "$log"
out=$(env XDG_STATE_HOME="$tmp/state" SYG_WEEK_BURN_NOW="$T" "$WW" 2>"$tmp/err"); rc=$?
[ $rc = 0 ] && [ "$out" = 75 ] && [ ! -s "$tmp/err" ] \
    && ok "weekly_resets_at 1e999 (inf): the row is kept with the reset unknown, holds quietly" \
    || bad "weekly_resets_at 1e999: rc=$rc out=[$out] err=[$(cat "$tmp/err")]"
{ printf '{"epoch":%s,"five_hour_pct":0,"weekly_pct":NaN,"weekly_resets_at":%s,"ts":"fixture"}\n' "$T" "$((T + 5400))"; } > "$log"
out=$(env XDG_STATE_HOME="$tmp/state" SYG_WEEK_BURN_NOW="$T" "$WW" 2>"$tmp/err"); rc=$?
[ $rc = 0 ] && [ "$out" = 75 ] && [ ! -s "$tmp/err" ] \
    && ok "weekly_pct NaN on the latest row: non-finite drops the row, holds quietly" \
    || bad "weekly_pct NaN: rc=$rc out=[$out] err=[$(cat "$tmp/err")]"

{ rd $((T - 25200)) 90 $((T + 5400)); } > "$log"
ww 75 "stale latest row (7 h old): holds"
# A latest row dated ahead of the clock is untrusted skew: never burn on it. Both rows sit in
# the slope window (span 13200 s, rate 2.73 %/h, window 15000 s), so absent the future guard
# the reset at 14900 s would burn — the row pins the guard, not the arithmetic.
{ rd $((T - 7200)) 80 $((T + 14900)); rd $((T + 6000)) 90 $((T + 14900)); } > "$log"
ww 75 "future-dated latest row (now + 100 min): untrusted clock skew holds despite the reset inside the slope window"

{ rd $((T - 7200)) 80 $((T + 33000)); rd "$T" 90 $((T + 33000)); } > "$log"
ww 75 "SYG_WEEK_BURN_RATE unset: slope 5 %/h window (9000s) < 33000s to reset, holds"
ww 99 "SYG_WEEK_BURN_RATE=0.1 slows the window past the reset and flips to burn" SYG_WEEK_BURN_RATE=0.1

# The slope needs its window: fewer than 2 rows in it, or fewer than 30 min between the window's
# first and last row, is no usable rate — hold, even with a valid reset already inside where a
# guessed window would fall. (Rows (a)-(c) pin this guard: bypassed, (a)/(c) divide by zero and
# (b) burns on a 600 s span.)
{ rd "$T" 90 $((T + 5400)); } > "$log"
ww 75 "(a) one fresh row, no other row in the 6 h slope window: holds"

{ rd $((T - 600)) 80 $((T + 2000)); rd "$T" 90 $((T + 2000)); } > "$log"
ww 75 "(b) two fresh rows spanning 600 s < 1800 s: holds despite the reset inside a guessed window"

{ rd $((T - 25000)) 80 $((T + 20000)); rd "$T" 90 $((T + 5400)); } > "$log"
ww 75 "(c) latest row fresh but every other row older than 6 h: the slope window holds one row"

{ rd $((T - 7200)) 80 $((T + 7260)); rd $((T - 3600)) 85 $((T + 7260)); rd "$T" 90 $((T + 7260)); } > "$log"
ww 75 "SYG_WEEK_BURN_MARGIN_MIN=0 shrinks the window to 7200s: reset 7260s out holds" SYG_WEEK_BURN_MARGIN_MIN=0
ww 99 "SYG_WEEK_BURN_MARGIN_MIN=30 (default) covers the same reset" SYG_WEEK_BURN_MARGIN_MIN=30

# Boundary: reset exactly at the window (9000 s at week 90, slope 5 %/h, margin 30 min): <= burns.
{ rd $((T - 7200)) 80 $((T + 9000)); rd $((T - 3600)) 85 $((T + 9000)); rd "$T" 90 $((T + 9000)); } > "$log"
ww 99 "boundary: time-to-reset exactly the window burns (<="

# A raw slope above 100 %/h clamps to 100 before the window arithmetic; the >100 branch must
# still decide, never hold. This fixture's raw slope is 110 %/h (week 40->95 over 30 min):
# clamped the window is 1980 s, unclamped it would be ~1964 s — the reset at 1800 s burns under
# BOTH, so the verdict is invariant to the clamp's exact value and the row pins the clamp path
# (a >100 rate decides), not the burn arithmetic.
{ rd $((T - 1800)) 40 $((T + 1800)); rd "$T" 95 $((T + 1800)); } > "$log"
ww 99 "raw slope 110 %/h clamps to 100: reset 1800 s out sits inside both windows, burns"

# A flat or falling rate is not spending the tail, so the window is computed at RATE_FLOOR —
# a cap, so the parked tail still burns once the reset is close enough. This row's slope is
# -2.5 %/h over 2 h; floored, the window is 109800 s ((100-85)/0.5 h + 30 min).
{ rd $((T - 7200)) 90 $((T + 1000)); rd "$T" 85 $((T + 1000)); } > "$log"
ww 99 "rate <= 0 (falling week): the floored window covers the reset 1000s out, burns"

# The genuinely parked meter: log_reading dedupes identical readings, so an unmoved meter
# writes NO new rows and the fetch record ($log.last) is what keeps moving. The log then holds
# a single old row — fewer than 2 in the 6 h slope window — while the fresh fetch proves the
# meters were just read: a flat reading, and the window is computed at the floor. Week 90
# floors to a 73800 s window ((100-90)/0.5 h + 30 min); the paired rows sit 800 s inside and
# 800 s outside it. Both rows need the .last fetch epoch to pass the stale check (the row
# itself is 7 h old) AND the < 2-rows floor path to burn — drop either fix and both hold 75.
rm -f "$log.last"
{ rd $((T - 25200)) 90 $((T + 73000)); } > "$log"
printf '%s\n' "$T" > "$log.last"
ww 99 "parked meter: one 7 h-old row, .last fetched now, reset 73000s out inside the 73800s floored window, burns"
{ rd $((T - 25200)) 90 $((T + 74600)); } > "$log"
printf '%s\n' "$T" > "$log.last"
ww 75 "parked meter: same shape, reset 74600s out sits beyond the 73800s floored window, holds"
rm -f "$log.last"

# Freshness has a second source: the fetch record .last is rewritten on every refresh, dedupe
# or not, so a parked meter's readings can go quiet while the fetch stays recent. A climb that
# stopped 3 h ago (85->90, then nothing): the latest row is past STALE_MAX_S, so ONLY the .last
# fetch epoch gets it past the stale check, and with the older row 7 h back the slope window
# holds one row, so ONLY the < 2-rows floor path can burn it — drop either fix and this row
# holds.
{ rd $((T - 25200)) 85 $((T + 73000)); rd $((T - 10800)) 90 $((T + 73000)); } > "$log"
printf '%s\n' "$T" > "$log.last"
ww 99 "latest row 3 h old but .last fetched now: the fetch record keeps the reading fresh, floored window burns"
# The degraded side of the same shape: no fetch record at all (both freshness sources stale) —
# the stale hold, never a guess. Same log as the row above, .last removed: the only difference.
rm -f "$log.last"
ww 75 "latest row 3 h old and .last missing: stale row with no fetch record, holds"
rm -f "$log.last"

# The fresh-endpoint slope: a fresh fetch record substitutes now for the latest row's epoch.
# A climb 80->90 that stopped 30 min ago (rows 5.5 h and 5 h old): pre-fix the slope spanned
# the two rows (1800 s, 20 %/h, window 1 h < the 20000 s reset) and held; post-fix the span
# runs to now (19800 s, ~1.82 %/h, window ~6 h) and the reset fits — burns.
{ rd $((T - 19800)) 80 $((T + 20000)); rd $((T - 18000)) 90 $((T + 20000)); } > "$log"
printf '%s\n' "$T" > "$log.last"
ww 99 "parked-after-climb: fresh fetch makes the slope's endpoint now (span 5.5 h, rate ~1.82 %/h, window ~6 h), reset 20000s out burns"
rm -f "$log.last"

# The freshness read is the record's CONTENT (the fetch epoch), not its mtime:
# (a) content says fetched now, mtime a day old — the content leg decides: fresh, parked burn.
rm -f "$log.last"
{ rd $((T - 25200)) 90 $((T + 73000)); } > "$log"
printf '%s\n' "$T" > "$log.last"
touch -d "@$((T - 100000))" "$log.last"
ww 99 "content freshness: .last content fetched now but mtime a day old — content leg wins, parked meter burns"
# (b) content unparsable, mtime fresh — the epoch is unread, so the fetch counts stale and the
# stale row holds (a deliberate change from the mtime world, where fresh mtime burned).
printf 'garbage\n' > "$log.last"
touch -d "@$T" "$log.last"
ww 75 "unparsable .last content: fresh mtime does not save it — fetch unread, stale row holds"
rm -f "$log.last"

{ rd $((T - 3600)) 99 $((T + 1800)); rd "$T" 100 $((T + 1800)); } > "$log"
ww 75 "week 100: holds even with the reset inside the (empty-tail) window"

{ rd $((T - 7200)) 80 $((T - 100)); rd $((T - 3600)) 85 $((T - 100)); rd "$T" 90 $((T - 100)); } > "$log"
ww 75 "reset already past: holds"

{ printf '{"epoch":%s,"weekly_pct":90}\n' "$T"; } > "$log"
ww 75 "weekly_resets_at missing: holds"

# A null weekly_resets_at keeps the row (usage-sweep's reader convention) with the reset
# unknown. The row's presence matters: drop it and the two earlier rows (span exactly 1800 s,
# slope 30 %/h, window 600 s + 1800 s margin) would burn on the 2400 s reset instead.
{ rd $((T - 3600)) 80 $((T + 2400)); rd $((T - 1800)) 95 $((T + 2400)); \
  printf '{"epoch":%s,"five_hour_pct":0,"weekly_pct":90,"weekly_resets_at":null,"ts":"fixture"}\n' "$T"; } > "$log"
ww 75 "null weekly_resets_at on the latest row: row kept, reset unknown, holds"

{ rd $((T - 7200)) 80 $((T + 20000)); rd $((T - 3600)) 85 $((T + 20000)); rd "$T" 90 $((T + 20000)); } > "$log"
ww 82 "hold value follows CLAUDE_USAGE_WEEK_RESERVE=82" CLAUDE_USAGE_WEEK_RESERVE=82
ww 75 "hold value ignores a non-integer CLAUDE_USAGE_WEEK_RESERVE=abc" CLAUDE_USAGE_WEEK_RESERVE=abc

out=$(env XDG_STATE_HOME="$tmp/state" SYG_WEEK_BURN_NOW=abc "$WW" 2>"$tmp/err"); rc=$?
[ $rc = 1 ] && [ -z "$out" ] && grep -q "SYG_WEEK_BURN_NOW='abc' is not an epoch" "$tmp/err" \
    && ok "set-but-invalid SYG_WEEK_BURN_NOW: crash-class exit 1, nothing on stdout" \
    || bad "SYG_WEEK_BURN_NOW=abc: rc=$rc out=[$out] err=[$(cat "$tmp/err")]"
out=$(env XDG_STATE_HOME="$tmp/state" SYG_WEEK_BURN_RATE=lots "$WW" 2>"$tmp/err"); rc=$?
[ $rc = 1 ] && [ -z "$out" ] && grep -q "SYG_WEEK_BURN_RATE='lots' is not a number" "$tmp/err" \
    && ok "set-but-invalid SYG_WEEK_BURN_RATE: crash-class exit 1, nothing on stdout" \
    || bad "SYG_WEEK_BURN_RATE=lots: rc=$rc out=[$out] err=[$(cat "$tmp/err")]"
out=$(env XDG_STATE_HOME="$tmp/state" SYG_WEEK_BURN_RATE=0 "$WW" 2>"$tmp/err"); rc=$?
[ $rc = 1 ] && [ -z "$out" ] && grep -q "SYG_WEEK_BURN_RATE='0' is not > 0" "$tmp/err" \
    && ok "SYG_WEEK_BURN_RATE=0 (numeric, not > 0): crash-class exit 1" \
    || bad "SYG_WEEK_BURN_RATE=0: rc=$rc out=[$out] err=[$(cat "$tmp/err")]"
out=$(env XDG_STATE_HOME="$tmp/state" SYG_WEEK_BURN_MARGIN_MIN=-5 "$WW" 2>"$tmp/err"); rc=$?
[ $rc = 1 ] && [ -z "$out" ] && grep -q "SYG_WEEK_BURN_MARGIN_MIN='-5' is not an integer >= 0" "$tmp/err" \
    && ok "set-but-invalid SYG_WEEK_BURN_MARGIN_MIN: crash-class exit 1" \
    || bad "SYG_WEEK_BURN_MARGIN_MIN=-5: rc=$rc out=[$out] err=[$(cat "$tmp/err")]"

out=$(env XDG_STATE_HOME="$tmp/state" SYG_WEEK_BURN_NOW=123456789012345678901234567890 "$WW" 2>"$tmp/err"); rc=$?
[ $rc = 1 ] && [ -z "$out" ] && grep -q "SYG_WEEK_BURN_NOW='123456789012345678901234567890' is not an epoch" "$tmp/err" \
    && ok "30-digit SYG_WEEK_BURN_NOW (past bash arithmetic): crash-class exit 1, nothing on stdout" \
    || bad "30-digit NOW: rc=$rc out=[$out] err=[$(cat "$tmp/err")]"
out=$(env XDG_STATE_HOME="$tmp/state" SYG_WEEK_BURN_MARGIN_MIN=123456789012345678901234567890 "$WW" 2>"$tmp/err"); rc=$?
[ $rc = 1 ] && [ -z "$out" ] && grep -q "SYG_WEEK_BURN_MARGIN_MIN='123456789012345678901234567890' is not an integer >= 0" "$tmp/err" \
    && ok "30-digit SYG_WEEK_BURN_MARGIN_MIN (past bash arithmetic): crash-class exit 1" \
    || bad "30-digit MARGIN: rc=$rc out=[$out] err=[$(cat "$tmp/err")]"

exit $fail
