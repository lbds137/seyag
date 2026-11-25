#!/usr/bin/env bash
# Hermetic probe for plugins/seyag/bin/load-gate: fixture loadavg and PSI files
# (SYG_LOAD_GATE_LOADAVG, SYG_LOAD_GATE_PSI, SYG_LOAD_GATE_NPROC), one run per case,
# each bounded by timeout.
# Usage: tests/load-gate.probe.sh   (from anywhere)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LG="$REPO/plugins/seyag/bin/load-gate"
[ -x "$LG" ] || { echo "FAIL  $LG is not executable (chmod +x it)"; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/load-gate-probe.XXXXXX")
bgpids=()
cleanup() {
  local p
  for p in "${bgpids[@]+"${bgpids[@]}"}"; do kill "$p" 2>/dev/null; done
  rm -rf "$tmp"
}
trap cleanup EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; }

mkload() {
  echo "$2 $3 19.21 5/1728 1746270" > "$1"
}

mkload "$tmp/ok-load" 8.35 13.35
mkload "$tmp/over1" 17 10
mkload "$tmp/over5" 10 21
mkload "$tmp/both-over" 17 21
mkload "$tmp/eq-load" 16.00 20.00
mkload "$tmp/load-5-1" 5 1
mkload "$tmp/load-124-1" 12.4 1
echo "garbled not-a-load" > "$tmp/garbled"
echo "some avg10=17.96 avg60=17.30 avg300=28.86 total=30095684746" > "$tmp/psi"
echo "some avg10=1.00 total=5" > "$tmp/psi-no-300"

# Baseline hermetic environment: every run inherits LOADAVG, PSI, and NPROC seams.
unset SYG_LOAD_GATE_1M SYG_LOAD_GATE_5M
export SYG_LOAD_GATE_LOADAVG="$tmp/ok-load"
export SYG_LOAD_GATE_PSI="$tmp/psi"
export SYG_LOAD_GATE_NPROC=8

# run SECONDS CMD...: stdout to $tmp/out, stderr to $tmp/err, exit code in $rc (124 = hung).
run() {
  local t=$1; shift
  timeout "$t" "$@" > "$tmp/out" 2> "$tmp/err"
  rc=$?
}
out() { cat "$tmp/out"; }
err() { cat "$tmp/err"; }

# 1 & 20a. pass under defaults (NPROC=8, load 8.35 13.35): exit 0, exact ok line pinned.
run 5 "$LG" --ok
want_ok="load-gate: ok: load 1m 8.35 <= 16, 5m 13.35 <= 20 on 8 cpus; cpu pressure avg300 28.86%"
[ "$rc" = 0 ] && [ "$(out)" = "$want_ok" ] \
  && ok "1. pass under defaults (NPROC=8, load 8.35 13.35) prints exact ok line" \
  || bad "1. pass defaults rc=$rc out=$(out) err=$(err)"

# 2 & 20b. 1m over (load 17 10, NPROC 8): exit 1, exact prefix up to '; top 3 CPU:'.
run 5 env SYG_LOAD_GATE_LOADAVG="$tmp/over1" "$LG" --ok
want_high_1m="load-gate: high: load 1m 17 > 16, 5m 10 <= 20 on 8 cpus; cpu pressure avg300 28.86%; top 3 CPU: "
[ "$rc" = 1 ] && [[ $(out) == "$want_high_1m"* ]] \
  && ok "2. 1m over (load 17 10) exits 1 with pinned high line and top 3 CPU" \
  || bad "2. 1m over rc=$rc out=$(out) err=$(err)"

# 3. 5m over only (load 10 21, NPROC 8): exit 1, 5m > 20 while 1m <= 16.
run 5 env SYG_LOAD_GATE_LOADAVG="$tmp/over5" "$LG" --ok
want_high_5m="load-gate: high: load 1m 10 <= 16, 5m 21 > 20 on 8 cpus; cpu pressure avg300 28.86%; top 3 CPU: "
[ "$rc" = 1 ] && [[ $(out) == "$want_high_5m"* ]] \
  && ok "3. 5m over only (load 10 21) exits 1 with 5m > 20 and 1m <= 16" \
  || bad "3. 5m over rc=$rc out=$(out) err=$(err)"

# 4. env limits win: SYG_LOAD_GATE_1M=4 with load 5 1 -> exit 1; SYG_LOAD_GATE_1M=12.5 with load 12.4 1 -> exit 0.
run 5 env SYG_LOAD_GATE_1M=4 SYG_LOAD_GATE_LOADAVG="$tmp/load-5-1" "$LG" --ok
[ "$rc" = 1 ] && [[ $(out) == *"load 1m 5 > 4, 5m 1 <= 20"* ]] \
  && ok "4a. SYG_LOAD_GATE_1M=4 with load 5 1 exits 1" \
  || bad "4a. env limit 4 rc=$rc out=$(out) err=$(err)"

run 5 env SYG_LOAD_GATE_1M=12.5 SYG_LOAD_GATE_LOADAVG="$tmp/load-124-1" "$LG" --ok
[ "$rc" = 0 ] && [[ $(out) == *"load 1m 12.4 <= 12.5, 5m 1 <= 20"* ]] \
  && ok "4b. SYG_LOAD_GATE_1M=12.5 with load 12.4 1 exits 0 (decimal compare)" \
  || bad "4b. env limit 12.5 rc=$rc out=$(out) err=$(err)"

# 5. bad env (SYG_LOAD_GATE_5M=abc and SYG_LOAD_GATE_1M=abc) -> exit 2, stderr names the var.
run 5 env SYG_LOAD_GATE_5M=abc "$LG" --ok
[ "$rc" = 2 ] && grep -q "SYG_LOAD_GATE_5M needs a number, got 'abc'" "$tmp/err" \
  && ok "5a. SYG_LOAD_GATE_5M=abc exits 2 naming SYG_LOAD_GATE_5M" \
  || bad "5a. bad 5M env rc=$rc err=$(err)"

run 5 env SYG_LOAD_GATE_1M=abc "$LG" --ok
[ "$rc" = 2 ] && grep -q "SYG_LOAD_GATE_1M needs a number, got 'abc'" "$tmp/err" \
  && ok "5b. SYG_LOAD_GATE_1M=abc exits 2 naming SYG_LOAD_GATE_1M" \
  || bad "5b. bad 1M env rc=$rc err=$(err)"

# 6. bad NPROC seam (0 and x) -> exit 2.
run 5 env SYG_LOAD_GATE_NPROC=0 "$LG" --ok
[ "$rc" = 2 ] && grep -q "SYG_LOAD_GATE_NPROC" "$tmp/err" \
  && ok "6a. SYG_LOAD_GATE_NPROC=0 exits 2" \
  || bad "6a. NPROC=0 rc=$rc err=$(err)"

run 5 env SYG_LOAD_GATE_NPROC=x "$LG" --ok
[ "$rc" = 2 ] && grep -q "SYG_LOAD_GATE_NPROC" "$tmp/err" \
  && ok "6b. SYG_LOAD_GATE_NPROC=x exits 2" \
  || bad "6b. NPROC=x rc=$rc err=$(err)"

# 7. unreadable/garbled loadavg -> exit 2 'cannot read load'.
run 5 env SYG_LOAD_GATE_LOADAVG="$tmp/no-such-file" "$LG" --ok
[ "$rc" = 2 ] && grep -q "cannot read load from $tmp/no-such-file" "$tmp/err" \
  && ok "7a. missing loadavg exits 2 with 'cannot read load'" \
  || bad "7a. missing loadavg rc=$rc err=$(err)"

run 5 env SYG_LOAD_GATE_LOADAVG="$tmp/garbled" "$LG" --ok
[ "$rc" = 2 ] && grep -q "cannot read load from $tmp/garbled" "$tmp/err" \
  && ok "7b. garbled loadavg exits 2 with 'cannot read load'" \
  || bad "7b. garbled loadavg rc=$rc err=$(err)"

# 8. PSI missing file -> ok line ends 'cpu pressure n/a', exit 0.
run 5 env SYG_LOAD_GATE_PSI="$tmp/no-such-psi" "$LG" --ok
[ "$rc" = 0 ] && [[ $(out) == *"cpu pressure n/a" ]] \
  && ok "8. missing PSI file exits 0 ending with 'cpu pressure n/a'" \
  || bad "8. missing PSI rc=$rc out=$(out) err=$(err)"

# swap_when_waiting FILE L1 L5|garbled: wait for "load-gate: waiting:" in $tmp/out, pause 1 s,
# then atomically replace FILE with a new loadavg fixture (or the garbled fixture when $2 = garbled).
swap_when_waiting() {
  : > "$tmp/out"
  (
    for _ in $(seq 50); do grep -q "load-gate: waiting:" "$tmp/out" 2>/dev/null && break; sleep 0.2; done
    sleep 1
    if [ "$2" = garbled ]; then cp "$tmp/garbled" "$1.new"; else mkload "$1.new" "$2" "$3"; fi
    mv "$1.new" "$1"
  ) &
  bg=$!; bgpids+=("$bg")
}

# 9. --wait recovery: start high, rewrite the fixture low after ~1 s, --interval 1 --timeout 10 -> exit 0, 'ok after'.
mkload "$tmp/recover" 17 10
swap_when_waiting "$tmp/recover" 8.35 13.35
run 20 env SYG_LOAD_GATE_LOADAVG="$tmp/recover" "$LG" --wait --interval 1 --timeout 10 --owner ''
wait "$bg" 2>/dev/null
[ "$rc" = 0 ] && grep -q "load-gate: ok after [0-9]* s: load 1m 8.35 <= 16, 5m 13.35 <= 20 on 8 cpus; cpu pressure avg300 28.86%" "$tmp/out" \
  && ok "9. --wait recovery exits 0 with 'ok after'" \
  || bad "9. --wait recovery rc=$rc out=$(out) err=$(err)"

# 10. --wait timeout default proceed: always high, --interval 1 --timeout 2 -> exit 0, 'timed out after' and 'proceeding'.
run 15 env SYG_LOAD_GATE_LOADAVG="$tmp/over1" "$LG" --wait --interval 1 --timeout 2 --owner ''
[ "$rc" = 0 ] && grep -q "load-gate: timed out after [0-9]* s, proceeding: load 1m 17 > 16, 5m 10 <= 20 on 8 cpus; cpu pressure avg300 28.86%" "$tmp/out" \
  && ok "10. --wait timeout default proceed exits 0 with 'timed out after' and 'proceeding'" \
  || bad "10. --wait timeout proceed rc=$rc out=$(out) err=$(err)"

# 11. --wait timeout --on-timeout fail -> exit 1.
run 15 env SYG_LOAD_GATE_LOADAVG="$tmp/over1" "$LG" --wait --interval 1 --timeout 2 --on-timeout fail --owner ''
[ "$rc" = 1 ] && grep -q "load-gate: timed out after [0-9]* s: load 1m 17 > 16, 5m 10 <= 20 on 8 cpus; cpu pressure avg300 28.86%; top 3 CPU:" "$tmp/out" \
  && ok "11. --wait timeout --on-timeout fail exits 1 with top 3 CPU" \
  || bad "11. --wait timeout fail rc=$rc out=$(out) err=$(err)"

# 12. --on-timeout bogus -> exit 2.
run 5 "$LG" --on-timeout bogus
[ "$rc" = 2 ] && grep -q -- "--on-timeout" "$tmp/err" \
  && ok "12. --on-timeout bogus exits 2" \
  || bad "12. --on-timeout bogus rc=$rc err=$(err)"

# 13. owner gone: --owner a PID of a short-lived background sleep 2, high load, --interval 1 --timeout 20 -> exit 3.
sleep 2 & own=$!; bgpids+=("$own")
run 25 env SYG_LOAD_GATE_LOADAVG="$tmp/over1" "$LG" --wait --interval 1 --timeout 20 --owner "$own"
[ "$rc" = 3 ] && grep -q "owner $own is gone" "$tmp/err" \
  && ok "13. owner exits mid-wait: exit 3 and 'owner $own is gone'" \
  || bad "13. owner gone rc=$rc out=$(out) err=$(err)"

# 14. unknown option -> exit 2; --help -> exit 0 and mentions --on-timeout.
run 5 "$LG" --bogus
[ "$rc" = 2 ] && grep -q "unknown option" "$tmp/err" \
  && ok "14a. unknown option exits 2" \
  || bad "14a. unknown option rc=$rc err=$(err)"

run 5 "$LG" --help
[ "$rc" = 0 ] && grep -q -- "--on-timeout" "$tmp/out" \
  && ok "14b. --help exits 0 and mentions --on-timeout" \
  || bad "14b. --help rc=$rc out=$(head -c 200 "$tmp/out")"

# 15. leading-zero flags (--interval 08 --timeout 08) read as decimal in wait loop (rc 124, empty stderr).
run 3 env SYG_LOAD_GATE_LOADAVG="$tmp/over1" "$LG" --wait --interval 08 --timeout 08 --owner ''
[ "$rc" = 124 ] && [ ! -s "$tmp/err" ] && grep -qF "checking every 8 s, timeout 8 s" "$tmp/out" \
  && ok "15. leading-zero flags (--interval 08 --timeout 08) keep waiting as 8 s (rc 124)" \
  || bad "15. --interval 08 rc=$rc out=$(out) err=$(err)"

# 16. equality passes: NPROC=8, load 16.00 20.00 -> exit 0, line contains '1m 16.00 <= 16, 5m 20.00 <= 20'.
run 5 env SYG_LOAD_GATE_LOADAVG="$tmp/eq-load" "$LG" --ok
[ "$rc" = 0 ] && grep -qF "1m 16.00 <= 16, 5m 20.00 <= 20" "$tmp/out" \
  && ok "16. equality passes: load 16.00 20.00 on 8 cpus exits 0" \
  || bad "16. equality rc=$rc out=$(out) err=$(err)"

# 17. both over: load 17 21 (NPROC 8) -> exit 1, line contains '1m 17 > 16, 5m 21 > 20'.
run 5 env SYG_LOAD_GATE_LOADAVG="$tmp/both-over" "$LG" --ok
[ "$rc" = 1 ] && grep -qF "1m 17 > 16, 5m 21 > 20" "$tmp/out" \
  && ok "17. both over (load 17 21) exits 1 with '1m 17 > 16, 5m 21 > 20'" \
  || bad "17. both over rc=$rc out=$(out) err=$(err)"

# 18. PSI file present but no avg300 ('some avg10=1.00 total=5') -> exit 0, line ends 'cpu pressure n/a'.
run 5 env SYG_LOAD_GATE_PSI="$tmp/psi-no-300" "$LG" --ok
[ "$rc" = 0 ] && [[ $(out) == *"cpu pressure n/a" ]] \
  && ok "18. PSI file without avg300 exits 0 ending with 'cpu pressure n/a'" \
  || bad "18. PSI no avg300 rc=$rc out=$(out) err=$(err)"

# 19. decimal env with exact format: SYG_LOAD_GATE_5M=12.50 -> limit printed 12.5.
run 5 env SYG_LOAD_GATE_5M=12.50 "$LG" --ok
[ "$rc" = 1 ] && grep -qF "5m 13.35 > 12.5 on 8 cpus" "$tmp/out" \
  && ok "19. SYG_LOAD_GATE_5M=12.50 formats limit as 12.5" \
  || bad "19. decimal env format rc=$rc out=$(out) err=$(err)"

# 20. pass-case and fail-case exact line pins verified explicitly.
run 5 "$LG"
[ "$rc" = 0 ] && [ "$(out)" = "$want_ok" ] \
  && ok "20a. default bare invocation matches exact pass line" \
  || bad "20a. bare pass pin rc=$rc out=$(out)"

run 5 env SYG_LOAD_GATE_LOADAVG="$tmp/over1" "$LG" --ok
high_prefix=$(out | sed 's/; top 3 CPU: .*/; top 3 CPU:/')
want_high_exact="load-gate: high: load 1m 17 > 16, 5m 10 <= 20 on 8 cpus; cpu pressure avg300 28.86%; top 3 CPU:"
[ "$rc" = 1 ] && [ "$high_prefix" = "$want_high_exact" ] \
  && ok "20b. fail-case line pinned exactly up to '; top 3 CPU:'" \
  || bad "20b. fail pin rc=$rc got='$high_prefix' want='$want_high_exact'"

# 21. limit not rounded: SYG_LOAD_GATE_1M=8.346 with 8.35 13.35 -> exit 1, stdout contains '1m 8.35 > 8.346'.
run 5 env SYG_LOAD_GATE_1M=8.346 "$LG" --ok
[ "$rc" = 1 ] && grep -qF "1m 8.35 > 8.346" "$tmp/out" \
  && ok "21. SYG_LOAD_GATE_1M=8.346 is not rounded (1m 8.35 > 8.346)" \
  || bad "21. unrounded limit rc=$rc out=$(out) err=$(err)"

# 22. loadavg turns garbled mid-wait -> exit 2, stderr 'cannot read load from'.
mkload "$tmp/vanish" 17 10
swap_when_waiting "$tmp/vanish" garbled
run 20 env SYG_LOAD_GATE_LOADAVG="$tmp/vanish" "$LG" --wait --interval 1 --timeout 10 --owner ''
wait "$bg" 2>/dev/null
[ "$rc" = 2 ] && grep -qF "cannot read load from $tmp/vanish" "$tmp/err" \
  && ok "22. loadavg turning garbled mid-wait exits 2 with 'cannot read load from'" \
  || bad "22. mid-wait garbled rc=$rc out=$(out) err=$(err)"

# 23. --interval 0 -> exit 2, stderr names --interval.
run 5 "$LG" --interval 0
[ "$rc" = 2 ] && grep -q -- "--interval" "$tmp/err" \
  && ok "23. --interval 0 exits 2 naming --interval" \
  || bad "23. --interval 0 rc=$rc err=$(err)"

# 24. lib not loadable: the bin copied alone without lib/ -> exit 2, stderr 'cannot load'.
mkdir -p "$tmp/solo/bin"
cp "$LG" "$tmp/solo/bin/load-gate"
run 5 "$tmp/solo/bin/load-gate" --ok
[ "$rc" = 2 ] && grep -q "cannot load" "$tmp/err" \
  && ok "24. load-gate without lib/owner.sh exits 2 with 'cannot load'" \
  || bad "24. solo rc=$rc err=$(err)"

# 25. --ok ignores --on-timeout: fail on passing fixture -> exit 0; proceed on high fixture -> exit 1.
run 5 "$LG" --ok --on-timeout fail
[ "$rc" = 0 ] && [ "$(out)" = "$want_ok" ] \
  && ok "25a. --ok --on-timeout fail on passing fixture exits 0" \
  || bad "25a. --ok --on-timeout fail rc=$rc out=$(out) err=$(err)"

run 5 env SYG_LOAD_GATE_LOADAVG="$tmp/over1" "$LG" --ok --on-timeout proceed
[ "$rc" = 1 ] && [[ $(out) == "$want_high_1m"* ]] \
  && ok "25b. --ok --on-timeout proceed on high fixture exits 1" \
  || bad "25b. --ok --on-timeout proceed rc=$rc out=$(out) err=$(err)"

# 26. bad arguments loop: each exits 2 with non-empty stderr.
for args in "--timeout abc" "--interval abc" "--timeout" "--interval" "--owner" "--on-timeout"; do
  # shellcheck disable=SC2086 # the case labels are word lists on purpose
  run 5 "$LG" $args
  [ "$rc" = 2 ] && [ -s "$tmp/err" ] \
    && ok "26. '$args' exits 2 with non-empty stderr" \
    || bad "26. '$args' rc=$rc err=$(err)"
done

# 27. owner already dead -> exit 3 ('owner <pid> is gone, exiting'); non-numeric --owner -> exit 2 ('--owner needs a PID').
sleep 0 & dead=$!; wait "$dead" 2>/dev/null
run 15 env SYG_LOAD_GATE_LOADAVG="$tmp/over1" "$LG" --wait --interval 1 --timeout 10 --owner "$dead"
[ "$rc" = 3 ] && grep -qF "load-gate: owner $dead is gone, exiting" "$tmp/err" \
  && ok "27a. already-dead owner exits 3 with 'owner $dead is gone, exiting'" \
  || bad "27a. dead owner rc=$rc out=$(out) err=$(err)"

run 5 "$LG" --owner abc
[ "$rc" = 2 ] && grep -qF "load-gate: --owner needs a PID, got 'abc'" "$tmp/err" \
  && ok "27b. --owner abc exits 2 with '--owner needs a PID'" \
  || bad "27b. --owner abc rc=$rc err=$(err)"

# 28a. NPROC=3 defaults: 1m limit 2 x 3 = 6, 5m limit 2.5 x 3 = 7.50 printed as 7.5; load 5 1 is under both.
run 5 env SYG_LOAD_GATE_NPROC=3 SYG_LOAD_GATE_LOADAVG="$tmp/load-5-1" "$LG" --ok
[ "$rc" = 0 ] && grep -qF "load 1m 5 <= 6, 5m 1 <= 7.5 on 3 cpus" "$tmp/out" \
  && ok "28a. NPROC=3 defaults print limits 1m 6 and 5m 7.5" \
  || bad "28a. NPROC=3 defaults rc=$rc out=$(out) err=$(err)"

# 28b. leading zeros in limits: SYG_LOAD_GATE_1M=08 prints 8, SYG_LOAD_GATE_5M=08.50 prints 8.5.
run 5 env SYG_LOAD_GATE_1M=08 SYG_LOAD_GATE_5M=08.50 SYG_LOAD_GATE_LOADAVG="$tmp/load-5-1" "$LG" --ok
[ "$rc" = 0 ] && grep -qF "load 1m 5 <= 8, 5m 1 <= 8.5 on 8 cpus" "$tmp/out" \
  && ok "28b. SYG_LOAD_GATE_1M=08 and 5M=08.50 print limits 8 and 8.5" \
  || bad "28b. leading-zero limits rc=$rc out=$(out) err=$(err)"

# 28c. --ok never checks the owner: a PID that cannot exist changes nothing (under load 0, over load 1, never 3).
run 5 "$LG" --ok --owner 999999999; rc_under=$rc
run 5 env SYG_LOAD_GATE_LOADAVG="$tmp/over1" "$LG" --ok --owner 999999999; rc_over=$rc
[ "$rc_under" = 0 ] && [ "$rc_over" = 1 ] \
  && ok "28c. --ok --owner 999999999 exits 0 under load and 1 over load" \
  || bad "28c. --ok owner ignored under=$rc_under over=$rc_over err=$(err)"

# 28d. pins current behaviour: --wait checks load once before its loop, so a dead owner with low
# load exits 0 (the pre-loop check passes first), not 3.
run 5 "$LG" --wait --owner 999999999 --interval 1 --timeout 5
[ "$rc" = 0 ] \
  && ok "28d. --wait with a dead owner and low load exits 0 (pre-loop check passes first)" \
  || bad "28d. --wait dead owner low load rc=$rc out=$(out) err=$(err)"

# 28e. a comm with a space ('Web Content') must not shift the top-3 columns: fake ps prints pid,pcpu,comm.
mkdir -p "$tmp/psbin"
cat > "$tmp/psbin/ps" <<'EOF'
#!/bin/bash
# Pins the bin's exact call: any other column order or sort fails the case.
[ "$*" = "-eo pid,pcpu,comm --sort=-pcpu" ] || { echo "fake ps: unexpected args: $*" >&2; exit 99; }
echo "  PID %CPU COMMAND"
echo "123 45.6 Web Content"
echo "7 3.0 bash"
echo "9 1.0 sleep"
EOF
chmod +x "$tmp/psbin/ps"
run 5 env PATH="$tmp/psbin:$PATH" SYG_LOAD_GATE_LOADAVG="$tmp/over1" "$LG" --ok
[ "$rc" = 1 ] && [[ $(out) == *"; top 3 CPU: 123 Web Content 45.6%, 7 bash 3.0%, 9 sleep 1.0%" ]] \
  && ok "28e. spaced comm keeps top 3 CPU columns intact" \
  || bad "28e. spaced comm rc=$rc out=$(out) err=$(err)"

echo "load-gate probe: $pass passed, $fail failed"
[ "$fail" = 0 ]
