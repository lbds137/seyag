#!/bin/bash
# Fixture check for plugins/seyag/bin/suite-time: exit-code passthrough, stdout passthrough, the TSV log,
# budget and regression warnings, an unwritable log, the slowest and log verbs, usage errors, a non-UTF-8
# argv byte, non-finite logged walls, duplicate headers, and a log that fails both to read and to write.
# Every case writes to its own mktemp directory (--log or SYG_SUITE_TIME_LOG, XDG_STATE_HOME pointed there).
# Not tested by design: the >= 10 s "used N s of CPU ... it was mostly waiting" line, because pinning it
# needs a 10 s sleep. Case 6 pins that the line does NOT fire for a sub-10 s sleep.
# Usage: tests/suite-time.probe.sh   (from anywhere)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ST="$REPO/plugins/seyag/bin/suite-time"
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
export XDG_STATE_HOME="$t/state"
unset SYG_SUITE_BUDGET_S SYG_SUITE_TIME_LOG SYG_SUITE_TIME_TOLERANCE

# seed FILE WALL EXIT COUNT: a log with a header and COUNT rows named and commanded "sleep 0.3".
seed() {
  printf 'ts\tname\texit\twall_s\tcpu_s\tload1\tcpus\tmem_avail_mb\tcmd\tnote\n' >"$1"
  for _ in $(seq "$4"); do
    printf '2026-11-01T00:00:00+00:00\tsleep 0.3\t%s\t%s\t0.0\t1.00\t8\t-\tsleep 0.3\t\n' "$3" "$2" >>"$1"
  done
}

# 1. Exit passthrough: 0, the child's own code, 128+signum for a signal, 127 with the not-found line
"$ST" run --log "$t/c1.tsv" -- true >/dev/null 2>&1; rc1=$?
"$ST" run --log "$t/c1.tsv" -- bash -c 'exit 3' >/dev/null 2>&1; rc2=$?
"$ST" run --log "$t/c1.tsv" -- bash -c 'kill -TERM $$' >/dev/null 2>&1; rc3=$?
err=$("$ST" run --log "$t/c1.tsv" -- no-such-cmd-xyz 2>&1 >/dev/null); rc4=$?
[ "$rc1" = 0 ] && [ "$rc2" = 3 ] && [ "$rc3" = 143 ] && [ "$rc4" = 127 ] \
  && grep -qx "suite-time: command not found: no-such-cmd-xyz" <<<"$err" \
  && ok "exit passthrough: 0, 3, 143 for SIGTERM, 127 with the not-found line" \
  || bad "exit passthrough (rc $rc1 $rc2 $rc3 $rc4: $err)"

# 2. CMD stdout is unchanged; the summary goes to stderr only
"$ST" run --log "$t/c2.tsv" -- printf 'a\tb\n' >"$t/c2.out" 2>"$t/c2.err"; rc=$?
printf 'a\tb\n' >"$t/c2.exp"
[ "$rc" = 0 ] && cmp -s "$t/c2.exp" "$t/c2.out" \
  && grep -q '^suite-time: printf .* wall .* exit 0$' "$t/c2.err" \
  && ! grep -q 'suite-time' "$t/c2.out" \
  && ok "stdout passthrough is byte-exact; summary line on stderr only" \
  || bad "stdout passthrough (rc $rc)"

# 3. Log: header once across two runs, two data rows of 10 columns, a tab in --note stored as a space
"$ST" run --log "$t/c3.tsv" --note $'x\ty' -- true >/dev/null 2>&1
"$ST" run --log "$t/c3.tsv" -- true >/dev/null 2>&1
stats=$(awk -F'\t' '$1=="ts"{h++} NF==10{c++} END{print h+0, c+0, NR}' "$t/c3.tsv")
note=$(awk -F'\t' 'NR==2{print $10}' "$t/c3.tsv")
[ "$stats" = "1 3 3" ] && [ "$note" = "x y" ] \
  && ok "log: one header, two 10-column rows, tab in note stored as a space" \
  || bad "log shape (stats '$stats', note '$note')"

# 4. Budget: flag, env, precedence, invalid values
err=$("$ST" run --log "$t/c4.tsv" --budget 0.0001 -- sleep 0.05 2>&1 >/dev/null)
fired=$(grep -c 'over budget: .* > 0.0001s. Measure, then fix: see the testing-discipline skill.$' <<<"$err")
quiet=$("$ST" run --log "$t/c4.tsv" --budget 100 -- true 2>&1 >/dev/null | grep -c 'over budget')
env_fired=$(SYG_SUITE_BUDGET_S=0.0001 "$ST" run --log "$t/c4.tsv" -- sleep 0.05 2>&1 >/dev/null | grep -c 'over budget')
override=$(SYG_SUITE_BUDGET_S=0.0001 "$ST" run --log "$t/c4.tsv" --budget 100 -- sleep 0.05 2>&1 >/dev/null | grep -c 'over budget')
"$ST" run --log "$t/c4.tsv" --budget abc -- true >/dev/null 2>&1; rc_badflag=$?
envwarn_err=$(SYG_SUITE_BUDGET_S=abc "$ST" run --log "$t/c4.tsv" -- true 2>&1 >/dev/null); rc_envwarn=$?
if [ "$fired" = 1 ] && [ "$quiet" = 0 ] && [ "$env_fired" = 1 ] && [ "$override" = 0 ] \
  && [ "$rc_badflag" = 2 ] && [ "$rc_envwarn" = 0 ] && grep -q 'SYG_SUITE_BUDGET_S' <<<"$envwarn_err"; then
  ok "budget: --budget and env fire the over-budget line, --budget overrides env, bad values handled"
else
  bad "budget (fired $fired quiet $quiet env $env_fired override $override badflag $rc_badflag envwarn $rc_envwarn)"
fi

# 5. Regression: 3 clean matching runs at 0.01 s against a 0.3 s sleep
seed "$t/r1.tsv" 0.01 0 3
r1=$("$ST" run --log "$t/r1.tsv" -- sleep 0.3 2>&1 >/dev/null | grep -c 'slower than the median of its last 3 runs')
seed "$t/r2.tsv" 100 0 3
r2=$("$ST" run --log "$t/r2.tsv" -- sleep 0.3 2>&1 >/dev/null | grep -c 'slower than the median')
seed "$t/r3.tsv" 0.01 1 3
r3=$("$ST" run --log "$t/r3.tsv" -- sleep 0.3 2>&1 >/dev/null | grep -c 'slower than the median')
seed "$t/r4.tsv" 0.01 0 2
r4=$("$ST" run --log "$t/r4.tsv" -- sleep 0.3 2>&1 >/dev/null | grep -c 'slower than the median')
seed "$t/r5.tsv" 0.01 0 3
r5=$(SYG_SUITE_TIME_TOLERANCE=100000 "$ST" run --log "$t/r5.tsv" -- sleep 0.3 2>&1 >/dev/null | grep -c 'slower than the median')
if [ "$r1" = 1 ] && [ "$r2" = 0 ] && [ "$r3" = 0 ] && [ "$r4" = 0 ] && [ "$r5" = 0 ]; then
  ok "regression: fires on 3 clean fast seeds; silent for slow seeds, failed seeds, 2 seeds, and a large tolerance"
else
  bad "regression (fires $r1, slow $r2, failed $r3, two-seed $r4, tolerance $r5)"
fi

# 6. Waiting line: a sub-10 s sleep is not waiting time, so the line stays silent
err=$("$ST" run --log "$t/c6.tsv" -- sleep 0.3 2>&1 >/dev/null)
if grep -q 'mostly waiting' <<<"$err"; then bad "waiting line fired for a 0.3 s sleep"; else
  ok "waiting line silent below 10 s (the >= 10 s case is untested by design)"; fi

# 7. Unwritable log: a read warning and a write warning beside the summary, exit code 4 preserved
: >"$t/blocker"
err=$("$ST" run --log "$t/blocker/x.tsv" -- bash -c 'exit 4' 2>&1 >/dev/null); rc=$?
warns=$(grep -c '^suite-time:' <<<"$err")
if [ "$rc" = 4 ] && [ "$warns" = 3 ] && grep -qE '^suite-time: cannot read log ' <<<"$err" \
  && grep -qE '^suite-time: cannot write log ' <<<"$err"; then
  ok "unwritable log: read and write warnings beside the summary, exit code 4 preserved"
else
  bad "unwritable log (rc $rc, $warns stderr lines: $err)"
fi

# 8. slowest: top-N ordering, summary counts, missing time, malformed and empty XML
cat >"$t/a.xml" <<'EOF'
<testsuite name="a">
  <testcase classname="a.B" name="fast" time="0.5"/>
  <testcase classname="a.B" name="slow" time="2.0"/>
</testsuite>
EOF
cat >"$t/b.xml" <<'EOF'
<testsuites><testsuite name="b">
  <testcase name="mid" time="1.25"/>
  <testcase classname="c" name="missing"/>
</testsuite></testsuites>
EOF
top=$("$ST" slowest "$t/a.xml" "$t/b.xml" 2>/dev/null | sed -n 1p)
rows2=$("$ST" slowest -n 2 "$t/a.xml" "$t/b.xml" 2>/dev/null | grep -c '^  [0-9]')
summary=$("$ST" slowest "$t/a.xml" "$t/b.xml" 2>/dev/null | tail -n 1)
missing_warn=$("$ST" slowest "$t/a.xml" "$t/b.xml" 2>&1 >/dev/null)
printf '<testsuite><testcase name="x" time="1"' >"$t/bad.xml"
"$ST" slowest "$t/bad.xml" >/dev/null 2>&1; rc_bad=$?
printf '<root/>\n' >"$t/none.xml"
"$ST" slowest "$t/none.xml" >/dev/null 2>&1; rc_none=$?
if [ "$top" = "  2.000s  a.B::slow" ] && [ "$rows2" = 2 ] \
  && [ "$summary" = "suite-time: 4 testcases, 3.8s summed across 2 files" ] \
  && grep -qx 'suite-time: 1 testcases had a missing or invalid time attribute (counted as 0)' <<<"$missing_warn" \
  && [ "$rc_bad" = 1 ] && [ "$rc_none" = 1 ]; then
  ok "slowest: top line, -n 2, summary counts, missing-time warning, malformed and empty XML exit 1"
else
  bad "slowest (top '$top', rows $rows2, summary '$summary', rc $rc_bad $rc_none)"
fi

# 9. log verb: --name filter, -n 1 with header, missing log exit 1
"$ST" run --log "$t/c9.tsv" --name alpha -- true >/dev/null 2>&1
"$ST" run --log "$t/c9.tsv" --name beta -- true >/dev/null 2>&1
filtered=$("$ST" log --log "$t/c9.tsv" --name alpha)
f_stats=$(awk -F'\t' '$1=="ts"{h++} $2=="alpha"{a++} $2=="beta"{b++} END{print h+0, a+0, b+0}' <<<"$filtered")
one=$("$ST" log --log "$t/c9.tsv" -n 1)
"$ST" log --log "$t/none.tsv" >/dev/null 2>&1; rc_missing=$?
if [ "$f_stats" = "1 1 0" ] && [ "$(wc -l <<<"$one")" = 2 ] && [ "$rc_missing" = 1 ]; then
  ok "log verb: --name filters, -n 1 prints header plus one row, missing log exits 1"
else
  bad "log verb (filter '$f_stats', n1 lines $(wc -l <<<"$one"), missing rc $rc_missing)"
fi

# 10. Usage: no -- after run, and no arguments, both exit 2; run -h prints usage and exits 0
"$ST" run true >/dev/null 2>&1; rc_nodash=$?
"$ST" >/dev/null 2>&1; rc_noargs=$?
help_out=$("$ST" run -h 2>/dev/null); rc_help=$?
if [ "$rc_nodash" = 2 ] && [ "$rc_noargs" = 2 ] && [ "$rc_help" = 0 ] && grep -q '^usage:' <<<"$help_out"; then
  ok "usage: run without -- and no arguments exit 2; run -h prints usage, exit 0"
else
  bad "usage (no -- rc $rc_nodash, no args rc $rc_noargs, run -h rc $rc_help)"
fi

# 11. Log path precedence: SYG_SUITE_TIME_LOG beats the XDG default; with neither, the row lands in
#     $XDG_STATE_HOME/seyag/suite-time.tsv
SYG_SUITE_TIME_LOG="$t/env.tsv" "$ST" run -- true >/dev/null 2>&1
"$ST" run -- true >/dev/null 2>&1
env_rows=$(grep -c $'\ttrue\t' "$t/env.tsv" 2>/dev/null)
xdg_rows=$(grep -c $'\ttrue\t' "$XDG_STATE_HOME/seyag/suite-time.tsv" 2>/dev/null)
if [ "$env_rows" = 1 ] && [ "$xdg_rows" = 1 ]; then
  ok "log path: SYG_SUITE_TIME_LOG used when set, XDG_STATE_HOME/seyag/suite-time.tsv otherwise"
else
  bad "log path (env rows '$env_rows', xdg rows '$xdg_rows')"
fi

# 12. A non-UTF-8 argv byte: the child's exit code survives and exactly one row is appended
"$ST" run --log "$t/c12.tsv" -- bash -c 'exit 5' "$(printf 'x\xff')" >/dev/null 2>&1; rc12=$?
rows12=$(grep -c -v $'^ts\t' "$t/c12.tsv" 2>/dev/null)
if [ "$rc12" = 5 ] && [ "$rows12" = 1 ]; then
  ok "non-UTF-8 argv: exit 5 preserved and one row appended"
else
  bad "non-UTF-8 argv (rc $rc12, rows '$rows12')"
fi

# 13. Non-finite logged walls are dropped before the median: 3 clean rows at 0.01 s, then 3 "inf" rows.
#     Kept, the last 5 walls' median is inf and the regression line can never fire; dropped, the median
#     is 0.01 and the 0.3 s run fires it.
seed "$t/n13.tsv" 0.01 0 3
for _ in 1 2 3; do
  printf '2026-11-01T00:00:00+00:00\tsleep 0.3\t0\tinf\t0.0\t1.00\t8\t-\tsleep 0.3\t\n' >>"$t/n13.tsv"
done
err13=$("$ST" run --log "$t/n13.tsv" -- sleep 0.3 2>&1 >/dev/null); rc13=$?
if [ "$rc13" = 0 ] && grep -q 'slower than the median of its last 3 runs' <<<"$err13"; then
  ok "non-finite walls: inf rows dropped, the median of the 3 finite rows drives the regression line"
else
  bad "non-finite walls (rc $rc13: $err13)"
fi

# 14. Duplicate headers: a log with HEADER, row, HEADER, row prints one header and two rows
seed "$t/d14.tsv" 0.3 0 1
seed "$t/d14b.tsv" 0.3 0 1
cat "$t/d14b.tsv" >>"$t/d14.tsv"
out14=$("$ST" log --log "$t/d14.tsv" -n 10)
if [ "$(wc -l <<<"$out14")" = 3 ] && [ "$(grep -c $'^ts\t' <<<"$out14")" = 1 ]; then
  ok "duplicate headers: log prints one header and two rows"
else
  bad "duplicate headers (lines $(wc -l <<<"$out14"), headers $(grep -c $'^ts\t' <<<"$out14"))"
fi

# 15. Read and write both fail (the log path is a directory): two warnings, the read error first
mkdir "$t/dirlog"
err15=$("$ST" run --log "$t/dirlog" -- true 2>&1 >/dev/null); rc15=$?
if [ "$rc15" = 0 ] && [ "$(grep -c '^suite-time:' <<<"$err15")" = 3 ] \
  && [ "$(grep -n 'cannot read log' <<<"$err15" | cut -d: -f1)" = 2 ] \
  && [ "$(grep -n 'cannot write log' <<<"$err15" | cut -d: -f1)" = 3 ]; then
  ok "read and write both fail: two warnings, read error first, exit 0"
else
  bad "read and write both fail (rc $rc15: $err15)"
fi

[ "$fail" = 0 ]
