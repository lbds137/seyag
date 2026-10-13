#!/bin/bash
# Fixture check for bin/usage-sweep against a throwaway projects dir.
# Usage: tests/usage-sweep.probe.sh   (from anywhere)

set -uo pipefail
US="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/plugins/seyag/bin/usage-sweep"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

line() { # id ts in out cache_read [block] [model]
  printf '{"type":"assistant","timestamp":"%s","requestId":"r-%s","message":{"id":"%s","model":"%s","content":[{"type":"%s"}],"usage":{"input_tokens":%s,"output_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":0}}}\n' \
    "$2" "$1" "$1" "${7:-m}" "${6:-text}" "$3" "$4" "$5"
}
P="$T/projects"; mkdir -p "$P/slugA/s1/subagents" "$P/slugA/mined-corpus" "$P/slugB"
{ line m0 2026-01-01T00:00:00Z 999 0 0     # before the window
  line m1 2026-09-24T02:00:00Z 10 2 100 thinking   # output_tokens grows as the reply streams:
  line m1 2026-09-24T02:00:00Z 10 2 100 text       # the reply counts once, at its largest (6)
  line m1 2026-09-24T02:00:00Z 10 6 100 tool_use
  printf '{"type":"assistant","timestamp":"2026-09-24T03:00:00Z","message":{"usage"\n'  # half-written tail
} > "$P/slugA/s1.jsonl"
line m2 2026-09-24T02:05:00Z 0 1 0 > "$P/slugA/s1/subagents/agent-x.jsonl"
mkdir -p "$P/slugA/s0/subagents"   # the same agent file carried into a second session: counted once
line m2 2026-09-24T02:05:00Z 0 1 0 > "$P/slugA/s0/subagents/agent-x.jsonl"
mkdir -p "$P/-dash-slug"; line m5 2026-09-24T04:00:00Z 7 0 0 > "$P/-dash-slug/s.jsonl"
line m3 2026-09-24T02:05:00Z 5000 0 0 > "$P/slugA/mined-corpus/copy.jsonl"
line m4 2026-09-24T04:00:00Z 100 0 0 > "$P/slugB/s2.jsonl"

run() { env -i HOME="$T" PATH=/usr/bin:/bin CLAUDE_PROJECTS_DIR="$P" "$US" "$@"; }
j=$(run --since 2026-09-24T01:15Z --json)
total=$(jq .total_weighted <<<"$j")
# 162 = m1 at its largest output (50) + m2 once across both files (5) + m4 (100) + m5 (7).
# First-seen usage would give 142; per-file dedupe 167.
[ "$total" = 162 ] && ok "one count per reply at its largest output, across files; skips mined-corpus and pre-window (162)" || bad "total $total, want 162"
[ "$(jq '[.main_weighted,.subagent_weighted]|join(",")' -r <<<"$j")" = "157,5" ] && ok "splits main vs subagent" || bad "split $(jq -c '[.main_weighted,.subagent_weighted]' <<<"$j")"
[ "$(jq .unparseable_lines <<<"$j")" = 1 ] && ok "counts the half-written line" || bad "unparseable"
[ "$(jq .meter <<<"$j")" = null ] && ok "runs without claude-usage on PATH" || bad "meter"
n=$(run --since 2026-09-24T01:15Z --json --no-dedupe | jq .total_weighted)
[ "$n" = 227 ] && ok "--no-dedupe counts every line (227)" || bad "no-dedupe $n"
b=$(run --since 2026-09-24T01:15Z --json --slug slugB | jq .total_weighted)
[ "$b" = 100 ] && ok "--slug scopes to one folder" || bad "slug $b"
d=$(run --since 2026-09-24T01:15Z --json --slug -dash-slug | jq .total_weighted)
[ "$d" = 7 ] && ok "--slug takes a dash-leading slug as a separate argument" || bad "dash slug $d"
run --since 2026-09-24T01:15Z --slug nope >/dev/null 2>&1; [ $? != 0 ] && ok "rejects an unknown slug" || bad "unknown slug"
run >/dev/null 2>&1; [ $? != 0 ] && ok "refuses to guess a window with no meter and no --since" || bad "no-window"
run --since 2026-09-24T01:15Z | grep -q "TOTAL weighted 0.0M" && ok "text output renders" || bad "text output"

# --- meter points (--points, --until, --by-session) ---
# Fixture extension (after every assertion above has run: m7 shifts the totals).
line m7 2026-09-24T02:06:00Z 0 1 0 > "$P/slugA/s1/subagents/agent-y.jsonl"
# claude-usage's readings log, at the XDG_STATE_HOME default that run()'s env -i leaves unset.
# Key order differs from the real log's lines on purpose; epochs are UTC unix seconds.
RLOG="$T/.local/state/claude-usage/readings.jsonl"; mkdir -p "$(dirname "$RLOG")"
rd() { printf '{"weekly_pct":%s,"epoch":%s,"five_hour_pct":%s,"ts":"2026-09-24"}\n' "$1" "$2" "$3"; }
{ rd 40.0 1790208000 30.0   # 00:00 — last reading at/before the window start (01:15)
  rd 40.0 1790215200 55.0   # 02:00
  rd  5.0 1790218800 80.0   # 03:00 — a weekly reset happened between 02:00 and 03:00
  rd 65.0 1790226000 40.0   # 05:00 — a five-hour reset happened before this
  rd 65.0 1790229600 70.0   # 06:00 — first reading at/after the window end (05:30)
} > "$RLOG"

j=$(run --since 2026-09-24T01:15Z --until 2026-09-24T05:30Z --points --json)
[ "$(jq '.points.weekly_delta == 60' <<<"$j")" = true ] && ok "weekly delta segment-sums to 60, reset segments contribute 0" || bad "weekly delta $(jq .points.weekly_delta <<<"$j")"
[ "$(jq .points.resets_inside.weekly <<<"$j")" = 1 ] && ok "counts the weekly reset inside the window" || bad "weekly resets $(jq -c .points.resets_inside <<<"$j")"
[ "$(jq '.points.five_hour_delta == 80' <<<"$j")" = true ] && ok "five-hour delta 80, its reset segment contributing 0" || bad "5h delta"
[ "$(jq .points.five_hour_usable <<<"$j")" = false ] && ok "marks the 5h figure unusable with a reset inside" || bad "5h usable"
[ "$(jq .points.readings_used <<<"$j")" = 5 ] && [ "$(jq .points.readings_skipped <<<"$j")" = 0 ] && ok "uses all 5 readings, skips none" || bad "readings used/skipped"
printf '{"epoch":"not-a-number","weekly_pct":40.0,"five_hour_pct":1.0}\n' >> "$RLOG"   # JSON-valid, wrong-typed
j2=$(run --since 2026-09-24T01:15Z --until 2026-09-24T05:30Z --points --json)
[ "$?" = 0 ] && [ "$(jq .points.readings_skipped <<<"$j2")" = 1 ] \
  && [ "$(jq '.points.weekly_delta == 60' <<<"$j2")" = true ] \
  && ok "a wrong-typed reading is skipped and the good ones still price" || bad "wrong-typed reading: $(jq -c '.points | {readings_skipped, weekly_delta}' <<<"$j2")"
[ "$(jq -r '.points.edge_left | [.epoch, .distance_s, .extrapolated] | @tsv' <<<"$j")" = "$(printf '1790208000\t4500\tfalse')" ] && ok "edge_left: last reading at/before the start, 4500s away" || bad "edge_left $(jq -c .points.edge_left <<<"$j")"
[ "$(jq -r '.points.edge_right | [.epoch, .distance_s, .extrapolated] | @tsv' <<<"$j")" = "$(printf '1790229600\t1800\tfalse')" ] && ok "edge_right: first reading at/after the end, 1800s away" || bad "edge_right $(jq -c .points.edge_right <<<"$j")"
# With m7 (weight 5) the swept total is 167: slugA 60, slugB 100, -dash-slug 7.
read -r sa sb ds sum <<<"$(jq -r '[.points.by_slug["slugA"], .points.by_slug["slugB"], .points.by_slug["-dash-slug"], ([.points.by_slug[]] | add)] | join(" ")' <<<"$j")"
awk -v a="$sa" -v b="$sb" -v d="$ds" -v s="$sum" 'BEGIN { exit !(a == 21.56 && b == 35.93 && d == 2.51 && s > 59.95 && s < 60.05) }' \
  && ok "per-slug points = share x weekly delta (21.56 / 35.93 / 2.51, sum ~ 60)" || bad "points split $sa $sb $ds $sum"
b=$(run --since 2026-09-24T01:15Z --until 2026-09-24T05:30Z --points --slug slugB --json | jq '.points.by_slug.slugB == 60')
[ "$b" = true ] && ok "--slug shares are of the swept set: the one swept folder takes the full delta" || bad "swept share $b"
[ "$(jq -e '([.points.by_model[]] | add) - .points.weekly_delta | if . < 0 then -. else . end < 0.05' <<<"$j")" = true ] \
  && ok "--points JSON has by_model summing to weekly_delta" || bad "--points by_model $(jq -c .points.by_model <<<"$j")"
run --since 2026-09-24T01:15Z --json | jq -e 'has("points") | not' >/dev/null && ok "without --points no points key (the log is never read)" || bad "points key without --points"
jq -e '.points | has("by_session") | not' <<<"$j" >/dev/null && ok "by_session appears only with --by-session" || bad "by_session without the flag"
j=$(run --since 2026-09-23T00:00Z --until 2026-09-24T02:30Z --points --json)
[ "$(jq -r '.points.edge_left | [.epoch, .distance_s, .extrapolated] | @tsv' <<<"$j")" = "$(printf '1790208000\t86400\ttrue')" ] \
  && ok "no reading at/before the start: first reading stands in, extrapolated, 86400s away" || bad "edge fallback $(jq -c .points.edge_left <<<"$j")"
[ "$(jq .points.readings_used <<<"$j")" = 3 ] && ok "the points window clips to the readings inside it (3)" || bad "clipped readings"
run --since 2026-09-23T00:00Z --until 2026-09-24T02:30Z --points | grep -q "points are approximate" && ok "warns when the nearest reading sits far from the window edge" || bad "approximate warning"
j=$(run --since 2026-09-24T01:15Z --until 2026-09-24T05:30Z --points --by-session --json)
# m1 (s1.jsonl, 50) and every slugA subagent file (5 or 10 with m2) land on a parent
# session key, never their own. m2 exists identically in s0/ and s1/ subagents and the
# dedupe is first-wins, so which of slugA/s0 or slugA/s1 gets it follows scan order —
# only the slugA total (60 of 167 weighted = 21.56 of the delta) is pinned, plus every
# slugA key being a parent session.
[ "$(jq '([.points.by_session | to_entries[] | select(.key | startswith("slugA/")) | .value] | add) - 21.56 | if . < 0 then -. else . end < 0.01' <<<"$j")" = true ] \
  && [ "$(jq '[.points.by_session | to_entries[] | select(.key | startswith("slugA/")) | .key] | all(test("^slugA/s[01]$"))' <<<"$j")" = true ] \
  && ok "--by-session: subagent files attach to their parent session's key, never their own" || bad "by-session $(jq -c .points.by_session <<<"$j")"
u=$(run --since 2026-09-24T01:15Z --until 2026-09-24T02:03Z --json | jq .total_weighted)
[ "$u" = 50 ] && ok "--until bounds the sweep without --points: usage after the cutoff excluded (50)" || bad "until $u"
run --since 2026-09-24T01:15Z --until 2026-09-24T05:30Z --points | grep -q "meter points: weekly +60.0 pts" && ok "text output renders the meter-points block" || bad "text points"
mv "$RLOG" "$T/readings.saved"
run --since 2026-09-24T01:15Z --points >/dev/null 2>"$T/err"
[ $? != 0 ] && grep -q "no usable readings in $RLOG" "$T/err" \
  && ok "missing readings log + --points: exits non-zero, names the path" || bad "missing log: $(cat "$T/err")"

# --- --fit, --probe, per-model points ---
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
PF="$T/fit-projects"
RLOG_FIT="$T/fit-state/claude-usage/readings.jsonl"
mkdir -p "$PF/slugA" "$PF/slugB" "$(dirname "$RLOG_FIT")"
run_fit() { env -i HOME="$T" PATH=/usr/bin:/bin CLAUDE_PROJECTS_DIR="$PF" XDG_STATE_HOME="$T/fit-state" "$US" "$@"; }

# Synthetic truth: opus rate 0.5 pts/M, haiku rate 0.1 pts/M.
# 8 intervals with integer point deltas:
# iv1: opus 2M + glm-x 1M (unbilled) -> 1 pt
# iv2: haiku 10M -> 1 pt
# iv3: opus 1M + haiku 5M -> 1 pt
# iv4: opus 4M + haiku 10M -> 3 pts
# iv5: opus 2M + haiku 10M -> 2 pts
# iv6: opus 6M -> 3 pts
# iv7: haiku 20M -> 2 pts
# iv8: opus 3M + haiku 5M -> 2 pts
# Total: 15 pts over 8 intervals.
rd_fit() {
  printf '{"epoch":%s,"five_hour_pct":%s,"weekly_pct":%s%s%s%s,"ts":"%s"}\n' \
    "$2" "$1" "$3" \
    "${4:+,\"prev_epoch\":$4}" \
    "${5:+,\"five_hour_resets_at\":$5}" \
    "${6:+,\"weekly_resets_at\":$6}" \
    "$(iso "$2")"
}

{ rd_fit 10.0 1790300000 10.0
  rd_fit 11.0 1790300300 11.0 1790300240
  rd_fit 12.0 1790300600 12.0 1790300540
  rd_fit 13.0 1790300900 13.0 1790300840
  rd_fit 14.0 1790301200 14.0 1790301140
  rd_fit 17.0 1790301500 17.0 1790301440
  rd_fit 19.0 1790301800 19.0 1790301740
  rd_fit 22.0 1790302100 22.0 1790302040
  rd_fit 24.0 1790302400 24.0 1790302340
  rd_fit 26.0 1790302700 26.0 1790302640
} > "$RLOG_FIT"

{ line o1 "$(iso 1790300400)" 2000000 0 0 text claude-opus-4-6
  line h2 "$(iso 1790300700)" 10000000 0 0 text claude-haiku-4
  line o3 "$(iso 1790301000)" 1000000 0 0 text claude-opus-4-6
  line o4 "$(iso 1790301300)" 4000000 0 0 text claude-opus-4-6
  line h5 "$(iso 1790301600)" 10000000 0 0 text claude-haiku-4
  line o8 "$(iso 1790302500)" 3000000 0 0 text claude-opus-4-6
  line h8 "$(iso 1790302500)" 5000000 0 0 text claude-haiku-4
} > "$PF/slugA/s.jsonl"

{ line g1 "$(iso 1790300400)" 1000000 0 0 text glm-x
  line h3 "$(iso 1790301000)" 5000000 0 0 text claude-haiku-4
  line h4 "$(iso 1790301300)" 10000000 0 0 text claude-haiku-4
  line o5 "$(iso 1790301600)" 2000000 0 0 text claude-opus-4-6
  line o6 "$(iso 1790301900)" 6000000 0 0 text claude-opus-4-6
  line h7 "$(iso 1790302200)" 20000000 0 0 text claude-haiku-4
} > "$PF/slugB/s.jsonl"

START_WIN="$(iso 1790300000)"
END_WIN="$(iso 1790303000)"

jf=$(run_fit --since "$START_WIN" --until "$END_WIN" --fit --json)
opus_rate=$(jq -r '.fit.by_family.opus.pts_per_M' <<<"$jf")
haiku_rate=$(jq -r '.fit.by_family.haiku.pts_per_M' <<<"$jf")
intervals=$(jq -r '.fit.intervals' <<<"$jf")
unbilled=$(jq -r '.fit.unbilled_M' <<<"$jf")
r2=$(jq -r '.fit.r2' <<<"$jf")

awk -v o="$opus_rate" -v h="$haiku_rate" -v iv="$intervals" -v ub="$unbilled" -v r="$r2" \
  'BEGIN { exit !(o >= 0.45 && o <= 0.55 && h >= 0.09 && h <= 0.11 && iv == 8 && ub == 1.0 && r > 0.99) }' \
  && ok "--fit synthetic truth: opus ~0.5, haiku ~0.1, 8 intervals, unbilled_M 1.0, r2 > 0.99" \
  || bad "--fit synthetic truth failed (opus $opus_rate, haiku $haiku_rate, intervals $intervals, unbilled $unbilled, r2 $r2)"

# --slug X --fit prints note and gives same fit
out_slug=$(run_fit --since "$START_WIN" --until "$END_WIN" --slug slugA --fit)
grep -q "note: --fit uses all project folders (ignoring --slug for the fit)" <<<"$out_slug" \
  && ok "--slug with --fit prints the note" || bad "missing note in --slug --fit: $out_slug"

jf_slug=$(run_fit --since "$START_WIN" --until "$END_WIN" --slug slugA --fit --json)
[ "$(jq -S '.fit.by_family' <<<"$jf")" = "$(jq -S '.fit.by_family' <<<"$jf_slug")" ] \
  && ok "--slug with --fit gives the same fit as without --slug" || bad "--slug fit mismatch"

# --probe START END --slug S: observed equals ticks in span, run estimate ≈ slug spend × true rates
P_START="$(iso 1790300300)"
P_END="$(iso 1790301500)"
jp=$(run_fit --since "$START_WIN" --until "$END_WIN" --probe "$P_START" "$P_END" --slug slugA --json)
obs=$(jq -r '.probe.observed' <<<"$jp")
run_est=$(jq -r '.probe.run.estimate_total' <<<"$jp")
awk -v o="$obs" -v e="$run_est" 'BEGIN { exit !(o == 6 && e >= 4.05 && e <= 4.95) }' \
  && ok "--probe: observed equals 6 ticks, run estimate ~4.5 pts" || bad "--probe failed (obs $obs, run_est $run_est)"

# --probe with START before --since: replies in span counted (non-zero all.estimate_total), total_weighted unchanged
j_np=$(run_fit --since "$(iso 1790300600)" --until "$END_WIN" --fit --json)
tw_np=$(jq .total_weighted <<<"$j_np")
j_p=$(run_fit --since "$(iso 1790300600)" --until "$END_WIN" --probe "$(iso 1790300300)" "$(iso 1790301500)" --json)
tw_p=$(jq .total_weighted <<<"$j_p")
est_all=$(jq -r '.probe.all.estimate_total' <<<"$j_p")
[ "$tw_p" = "$tw_np" ] && awk -v e="$est_all" 'BEGIN { exit !(e > 0) }' \
  && ok "--probe with START before --since: probe counts replies (est > 0), total_weighted unchanged" \
  || bad "--probe START before --since failed: tw_p=$tw_p, tw_np=$tw_np, est_all=$est_all"

# Ticks outside the window are not counted in ticks_total
j_win=$(run_fit --since "$(iso 1790300800)" --until "$(iso 1790302000)" --fit --json)
[ "$(jq -r '.fit.ticks_total' <<<"$j_win")" = 4 ] \
  && ok "ticks outside window not counted in ticks_total (4 in window vs 9 in log)" \
  || bad "ticks_total window filter failed: $(jq -c '.fit | {ticks_total, ticks_precise}' <<<"$j_win")"

# --slug A --fit vs --slug A: identical report fields with cross-folder deduped reply
mkdir -p "$T/cross-dedupe-state/claude-usage" "$T/cross-dedupe-projects/slugA" "$T/cross-dedupe-projects/slugB"
{ rd_fit 10.0 1000 10.0
  rd_fit 11.0 1300 11.0 1240
  rd_fit 12.0 1600 12.0 1540
  rd_fit 13.0 1900 13.0 1840
  rd_fit 14.0 2200 14.0 2140
} > "$T/cross-dedupe-state/claude-usage/readings.jsonl"
{ line shared "$(iso 1100)" 10 10 0 text claude-opus-4-6
  line onlyA "$(iso 1400)" 20 0 0 text claude-haiku-4
  line onlyA2 "$(iso 2000)" 20 0 0 text claude-haiku-4
} > "$T/cross-dedupe-projects/slugA/s.jsonl"
{ line shared "$(iso 1100)" 10 100 0 text claude-opus-4-6
  line onlyB "$(iso 1700)" 30 0 0 text claude-haiku-4
} > "$T/cross-dedupe-projects/slugB/s.jsonl"

run_cross() { env -i HOME="$T" PATH=/usr/bin:/bin CLAUDE_PROJECTS_DIR="$T/cross-dedupe-projects" \
                   XDG_STATE_HOME="$T/cross-dedupe-state" "$US" "$@"; }
j_cross_slug=$(run_cross --since "$(iso 900)" --until "$(iso 2300)" --slug slugA --json)
j_cross_fit=$(run_cross --since "$(iso 900)" --until "$(iso 2300)" --slug slugA --fit --json)

[ "$(jq -S '.total_weighted' <<<"$j_cross_slug")" = "$(jq -S '.total_weighted' <<<"$j_cross_fit")" ] \
  && [ "$(jq -S '.by_slug' <<<"$j_cross_slug")" = "$(jq -S '.by_slug' <<<"$j_cross_fit")" ] \
  && [ "$(jq -S '.by_model' <<<"$j_cross_slug")" = "$(jq -S '.by_model' <<<"$j_cross_fit")" ] \
  && [ "$(jq -S '.files' <<<"$j_cross_slug")" = "$(jq -S '.files' <<<"$j_cross_fit")" ] \
  && [ "$(jq -S '.usage_lines' <<<"$j_cross_slug")" = "$(jq -S '.usage_lines' <<<"$j_cross_fit")" ] \
  && ok "--slug A --fit vs --slug A: report fields (.total_weighted, .by_slug, .by_model, .files, .usage_lines) identical" \
  || bad "--slug A --fit vs --slug A mismatch: $(jq -c '{slug: {tw: .total_weighted, lines: .usage_lines}}' <<<"$j_cross_slug") vs $(jq -c '{fit: {tw: .total_weighted, lines: .usage_lines}}' <<<"$j_cross_fit")"

# An imprecise tick (prev_epoch missing, 1-hour gap) is merged over; ticks_precise < ticks_total, fit succeeds
mkdir -p "$T/imprecise-state/claude-usage" "$T/imprecise-projects/slugA" "$T/imprecise-projects/slugB"
{ line o1 "$(iso 1790300400)" 2000000 0 0 text claude-opus-4-6
  line h2 "$(iso 1790300700)" 10000000 0 0 text claude-haiku-4
  line o3 "$(iso 1790301000)" 1000000 0 0 text claude-opus-4-6
  line o4 "$(iso 1790301300)" 4000000 0 0 text claude-opus-4-6
  line h5 "$(iso 1790301600)" 10000000 0 0 text claude-haiku-4
  line o8 "$(iso 1790306100)" 3000000 0 0 text claude-opus-4-6
  line h8 "$(iso 1790306100)" 5000000 0 0 text claude-haiku-4
} > "$T/imprecise-projects/slugA/s.jsonl"
cp "$PF/slugB/s.jsonl" "$T/imprecise-projects/slugB/"
head -n 9 "$RLOG_FIT" > "$T/imprecise-state/claude-usage/readings.jsonl"
# Insert reading with 1h gap (3600s) and no prev_epoch
rd_fit 25.0 1790306000 25.0 >> "$T/imprecise-state/claude-usage/readings.jsonl"
# Followed by reading 9 at 1790306300 with prev_epoch
rd_fit 26.0 1790306300 26.0 1790306240 >> "$T/imprecise-state/claude-usage/readings.jsonl"
ji=$(env -i HOME="$T" PATH=/usr/bin:/bin CLAUDE_PROJECTS_DIR="$T/imprecise-projects" \
     XDG_STATE_HOME="$T/imprecise-state" "$US" --since "$START_WIN" --until "$(iso 1790307000)" --fit --json)
[ "$(jq -r '.fit.ticks_precise < .fit.ticks_total and .fit.intervals == 8' <<<"$ji")" = true ] \
  && ok "imprecise tick: ticks_precise < ticks_total, intervals merged over it, fit succeeds" \
  || bad "imprecise tick failed: $(jq -c '.fit | {ticks_total, ticks_precise, intervals}' <<<"$ji")"

# Reset detection: reset to higher value 13 with different five_hour_resets_at (> 600 s apart).
# Assert no interval spans the reset (spend placed across reset is outside intervals),
# right interval count with --fit, and spend_M vs window_spend_M.
mkdir -p "$T/reset-state/claude-usage" "$T/reset-projects/slugA"
{ rd_fit  9.0  700  9.0 ""   18000
  rd_fit 10.0 1000 10.0 940  18000
  rd_fit 11.0 1300 11.0 1240 18000
  rd_fit 12.0 1600 12.0 1540 18000
  rd_fit 13.0 1900 13.0 1840 36000
  rd_fit 14.0 2200 14.0 2140 36000
  rd_fit 15.0 2500 15.0 2440 36000
} > "$T/reset-state/claude-usage/readings.jsonl"
{ line o1 "$(iso 1100)" 2000000 0 0 text claude-opus-4-6
  line o2 "$(iso 1400)" 2000000 0 0 text claude-opus-4-6
  line o3 "$(iso 1800)" 2000000 0 0 text claude-opus-4-6
  line o4 "$(iso 2300)" 2000000 0 0 text claude-opus-4-6
} > "$T/reset-projects/slugA/s.jsonl"
j_reset=$(env -i HOME="$T" PATH=/usr/bin:/bin CLAUDE_PROJECTS_DIR="$T/reset-projects" \
               XDG_STATE_HOME="$T/reset-state" "$US" --since "$(iso 600)" --until "$(iso 2700)" --fit --json)
[ "$(jq -r '.fit.intervals' <<<"$j_reset")" = 3 ] \
  && [ "$(jq -r '.fit.by_family.opus.pts_per_M' <<<"$j_reset")" = "0.5" ] \
  && [ "$(jq -r '.fit.by_family.opus.spend_M' <<<"$j_reset")" = "6.0" ] \
  && [ "$(jq -r '.fit.by_family.opus.window_spend_M' <<<"$j_reset")" = "8.0" ] \
  && ok "reset detection: reset to higher value 13 splits chain (3 intervals, rate 0.5, no straddling interval)" \
  || bad "reset detection failed: $(jq -c '.fit' <<<"$j_reset")"

[ "$(jq -r '.fit.by_family.opus.window_spend_M > .fit.by_family.opus.spend_M' <<<"$j_reset")" = true ] \
  && ok "spend_M vs window_spend_M: family spend outside intervals gives window_spend_M > spend_M (8.0 > 6.0)" \
  || bad "spend_M vs window_spend_M failed: $(jq -c '.fit.by_family.opus' <<<"$j_reset")"

# Positive control: the same fixture WITHOUT the resets_at change yields a straddling interval (4 intervals)
mkdir -p "$T/pos-state/claude-usage"
{ rd_fit  9.0  700  9.0 ""   18000
  rd_fit 10.0 1000 10.0 940  18000
  rd_fit 11.0 1300 11.0 1240 18000
  rd_fit 12.0 1600 12.0 1540 18000
  rd_fit 13.0 1900 13.0 1840 18000
  rd_fit 14.0 2200 14.0 2140 18000
  rd_fit 15.0 2500 15.0 2440 18000
} > "$T/pos-state/claude-usage/readings.jsonl"
j_pos=$(env -i HOME="$T" PATH=/usr/bin:/bin CLAUDE_PROJECTS_DIR="$T/reset-projects" \
             XDG_STATE_HOME="$T/pos-state" "$US" --since "$(iso 600)" --until "$(iso 2700)" --fit --json)
[ "$(jq -r '.fit.intervals' <<<"$j_pos")" = 4 ] \
  && ok "positive control: without resets_at change, straddling interval is formed (4 intervals vs 3)" \
  || bad "positive control failed (intervals $(jq -r '.fit.intervals' <<<"$j_pos"))"

# Separate small case for <3 intervals exit message
mkdir -p "$T/small-state/claude-usage" "$T/small-projects/slugA"
{ rd_fit 10.0 1000 10.0
  rd_fit 11.0 1300 11.0 1240
  rd_fit 12.0 1600 12.0 1540
  rd_fit  5.0 1900  5.0
  rd_fit  6.0 2200  6.0 2140
  rd_fit  7.0 2500  7.0 2440
} > "$T/small-state/claude-usage/readings.jsonl"
{ line o1 "$(iso 1400)" 2000000 0 0 text claude-opus-4-6
  line o2 "$(iso 2300)" 2000000 0 0 text claude-opus-4-6
} > "$T/small-projects/slugA/s.jsonl"
err_out=$(env -i HOME="$T" PATH=/usr/bin:/bin CLAUDE_PROJECTS_DIR="$T/small-projects" \
          XDG_STATE_HOME="$T/small-state" "$US" --since "$(iso 900)" --until "$(iso 3000)" --fit 2>&1); rc=$?
[ $rc = 1 ] && grep -q "usage-sweep: --fit needs at least 3 tick intervals, found 2" <<<"$err_out" \
  && ok "<3 intervals exits 1 with message" \
  || bad "<3 intervals exit message failed (rc $rc): $err_out"

# --- --meter week fixture: precise weekly ticks, flat 5h meter, reset splits chain without spanning interval ---
mkdir -p "$T/week-state/claude-usage" "$T/week-projects/slugA" "$T/week-pos-state/claude-usage"
{ rd_fit 10.0  700  9.0 ""   "" 100000
  rd_fit 10.0 1000 10.0  940 "" 100000
  rd_fit 10.0 1300 11.0 1240 "" 100000
  rd_fit 10.0 1600 12.0 1540 "" 100000
  rd_fit 10.0 1900 13.0 1840 "" 200000
  rd_fit 10.0 2200 14.0 2140 "" 200000
  rd_fit 10.0 2500 15.0 2440 "" 200000
} > "$T/week-state/claude-usage/readings.jsonl"
{ line o1 "$(iso 1100)" 2000000 0 0 text claude-opus-4-6
  line o2 "$(iso 1400)" 2000000 0 0 text claude-opus-4-6
  line o3 "$(iso 1800)" 2000000 0 0 text claude-opus-4-6
  line o4 "$(iso 2300)" 2000000 0 0 text claude-opus-4-6
} > "$T/week-projects/slugA/s.jsonl"

j_week=$(env -i HOME="$T" PATH=/usr/bin:/bin CLAUDE_PROJECTS_DIR="$T/week-projects" \
              XDG_STATE_HOME="$T/week-state" "$US" --since "$(iso 600)" --until "$(iso 2700)" --meter week --fit --json)
opus_wk=$(jq -r '.fit.by_family.opus.pts_per_M' <<<"$j_week")
iv_wk=$(jq -r '.fit.intervals' <<<"$j_week")
sp_wk=$(jq -r '.fit.by_family.opus.spend_M' <<<"$j_week")
wsp_wk=$(jq -r '.fit.by_family.opus.window_spend_M' <<<"$j_week")

awk -v o="$opus_wk" -v iv="$iv_wk" -v sp="$sp_wk" -v wsp="$wsp_wk" \
  'BEGIN { exit !(o >= 0.45 && o <= 0.55 && iv == 3 && sp == 6.0 && wsp == 8.0) }' \
  && ok "--meter week: recovers known rate ~0.5, 3 intervals, reset splits chain without spanning interval" \
  || bad "--meter week failed (opus $opus_wk, intervals $iv_wk, spend $sp_wk, window $wsp_wk)"

# 5h fit of the same fixture finds < 3 intervals (five_hour_pct is flat)
err_5h=$(env -i HOME="$T" PATH=/usr/bin:/bin CLAUDE_PROJECTS_DIR="$T/week-projects" \
              XDG_STATE_HOME="$T/week-state" "$US" --since "$(iso 600)" --until "$(iso 2700)" --fit 2>&1); rc=$?
[ $rc = 1 ] && grep -q "usage-sweep: --fit needs at least 3 tick intervals, found 0" <<<"$err_5h" \
  && ok "--meter week fixture: flat 5h meter finds < 3 intervals (exits 1)" \
  || bad "flat 5h meter check failed (rc $rc): $err_5h"

# Positive control: same fixture without weekly_resets_at change gives one more interval (4 intervals vs 3)
{ rd_fit 10.0  700  9.0 ""   "" 100000
  rd_fit 10.0 1000 10.0  940 "" 100000
  rd_fit 10.0 1300 11.0 1240 "" 100000
  rd_fit 10.0 1600 12.0 1540 "" 100000
  rd_fit 10.0 1900 13.0 1840 "" 100000
  rd_fit 10.0 2200 14.0 2140 "" 100000
  rd_fit 10.0 2500 15.0 2440 "" 100000
} > "$T/week-pos-state/claude-usage/readings.jsonl"
j_week_pos=$(env -i HOME="$T" PATH=/usr/bin:/bin CLAUDE_PROJECTS_DIR="$T/week-projects" \
                  XDG_STATE_HOME="$T/week-pos-state" "$US" --since "$(iso 600)" --until "$(iso 2700)" --meter week --fit --json)
[ "$(jq -r '.fit.intervals' <<<"$j_week_pos")" = 4 ] \
  && ok "--meter week positive control: without resets_at change, straddling interval forms (4 intervals vs 3)" \
  || bad "--meter week positive control failed: $(jq -r '.fit.intervals' <<<"$j_week_pos")"

# --- --boot 0 exits non-zero with error message on stderr ---
err_boot0=$(run --since 2026-09-24T01:15Z --boot 0 2>&1); rc=$?
[ $rc != 0 ] && grep -q "usage-sweep: --boot must be at least 1" <<<"$err_boot0" \
  && ok "--boot 0 exits non-zero with 'usage-sweep: --boot must be at least 1'" \
  || bad "--boot 0 failed (rc $rc): $err_boot0"

# --- --max-gap override ---
mkdir -p "$T/gap-state/claude-usage" "$T/gap-projects/slugA"
{ rd_fit 10.0 1000 10.0
  rd_fit 11.0 1300 11.0 1180
  rd_fit 12.0 1600 12.0 1480
  rd_fit 13.0 1900 13.0 1780
  rd_fit 14.0 2200 14.0 2080
} > "$T/gap-state/claude-usage/readings.jsonl"
{ line o1 "$(iso 1400)" 2000000 0 0 text claude-opus-4-6
  line o2 "$(iso 1700)" 2000000 0 0 text claude-opus-4-6
  line o3 "$(iso 2000)" 2000000 0 0 text claude-opus-4-6
} > "$T/gap-projects/slugA/s.jsonl"

j_gap_def=$(env -i HOME="$T" PATH=/usr/bin:/bin CLAUDE_PROJECTS_DIR="$T/gap-projects" \
                 XDG_STATE_HOME="$T/gap-state" "$US" --since "$(iso 900)" --until "$(iso 2300)" --fit --json)
[ "$(jq -r '.fit.ticks_precise == 4 and .fit.intervals == 3' <<<"$j_gap_def")" = true ] \
  && ok "--max-gap default (180): 120s brackets counted precise (4 ticks, 3 intervals)" \
  || bad "--max-gap default failed: $(jq -c '.fit | {ticks_precise, intervals}' <<<"$j_gap_def")"

err_gap60=$(env -i HOME="$T" PATH=/usr/bin:/bin CLAUDE_PROJECTS_DIR="$T/gap-projects" \
                 XDG_STATE_HOME="$T/gap-state" "$US" --since "$(iso 900)" --until "$(iso 2300)" --max-gap 60 --fit 2>&1); rc=$?
[ $rc = 1 ] && grep -q "usage-sweep: --fit needs at least 3 tick intervals, found 0" <<<"$err_gap60" \
  && ok "--max-gap 60: 120s brackets not precise, 0 intervals, exits 1" \
  || bad "--max-gap 60 failed (rc $rc): $err_gap60"

# --- --max-span override ---
mkdir -p "$T/span-state/claude-usage" "$T/span-projects/slugA"
{ rd_fit 10.0 10000 10.0
  rd_fit 11.0 17200 11.0 17140
  rd_fit 12.0 24400 12.0 24340
  rd_fit 13.0 31600 13.0 31540
  rd_fit 14.0 38800 14.0 38740
} > "$T/span-state/claude-usage/readings.jsonl"
{ line o1 "$(iso 20000)" 2000000 0 0 text claude-opus-4-6
  line o2 "$(iso 28000)" 2000000 0 0 text claude-opus-4-6
  line o3 "$(iso 35000)" 2000000 0 0 text claude-opus-4-6
} > "$T/span-projects/slugA/s.jsonl"

j_span_def=$(env -i HOME="$T" PATH=/usr/bin:/bin CLAUDE_PROJECTS_DIR="$T/span-projects" \
                  XDG_STATE_HOME="$T/span-state" "$US" --since "$(iso 9000)" --until "$(iso 40000)" --fit --json)
[ "$(jq -r '.fit.intervals == 3' <<<"$j_span_def")" = true ] \
  && ok "--max-span default (18000): ~2h intervals fitted (3 intervals)" \
  || bad "--max-span default failed: $(jq -c '.fit | {intervals}' <<<"$j_span_def")"

err_span3600=$(env -i HOME="$T" PATH=/usr/bin:/bin CLAUDE_PROJECTS_DIR="$T/span-projects" \
                   XDG_STATE_HOME="$T/span-state" "$US" --since "$(iso 9000)" --until "$(iso 40000)" --max-span 3600 --fit 2>&1); rc=$?
[ $rc = 1 ] && grep -q "usage-sweep: --fit needs at least 3 tick intervals, found 0" <<<"$err_span3600" \
  && ok "--max-span 3600: drops ~2h intervals, exits 1 for <3 intervals" \
  || bad "--max-span 3600 failed (rc $rc): $err_span3600"

exit $fail
