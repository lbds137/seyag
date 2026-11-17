#!/usr/bin/env bash
# Hermetic probe for plugins/seyag/bin/mem-gate: fixture meminfo files (SYG_MEM_GATE_MEMINFO), one
# run per case, each bounded by timeout. Pins the ok/low/waiting status lines against the fixture
# values, the SYG_MEM_GATE_MIN_MB knob (an explicit MB wins and skips its check, a bad value exits
# 2), the missing-MemAvailable exit (at start and mid-wait), a lib that cannot be loaded (exit 2),
# leading-zero numbers read as decimal, the --wait timeout and recovery paths, owner tracking
# (owner gone and dead owner exit 3), and the usage errors (exit 2).
# Usage: tests/mem-gate.probe.sh   (from anywhere)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MG="$REPO/plugins/seyag/bin/mem-gate"
[ -x "$MG" ] || { echo "FAIL  $MG is not executable (chmod +x it)"; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/mem-gate-probe.XXXXXX")
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

# mkmem FILE AVAIL_MB: a meminfo fixture with fixed swap (8388604 kB total, 7340032 kB free).
mkmem() {
  local avail_kb=$(($2 * 1024))
  {
    echo "MemTotal:        16305768 kB"
    echo "MemFree:          2345678 kB"
    echo "MemAvailable:    $avail_kb kB"
    echo "SwapTotal:        8388604 kB"
    echo "SwapFree:         7340032 kB"
  } > "$1"
}
swap_used=$(((8388604 - 7340032) / 1024))   # the swap-used MB the fixtures imply (1023)

mkmem "$tmp/high" 4096
mkmem "$tmp/low" 1024
cat > "$tmp/no-avail" <<'EOF'
MemTotal:        16305768 kB
MemFree:          2345678 kB
SwapTotal:        8388604 kB
SwapFree:         7340032 kB
EOF

# Baseline environment: the high fixture, no knob.
unset SYG_MEM_GATE_MIN_MB
export SYG_MEM_GATE_MEMINFO="$tmp/high"

# run SECONDS CMD...: stdout to $tmp/out, stderr to $tmp/err, exit code in $rc (124 = hung).
run() {
  local t=$1; shift
  timeout "$t" "$@" > "$tmp/out" 2> "$tmp/err"
  rc=$?
}
out() { cat "$tmp/out"; }
err() { cat "$tmp/err"; }

# --help: usage on stdout, exit 0.
run 5 "$MG" --help
[ "$rc" = 0 ] && grep -q "mem-gate \[--ok" "$tmp/out" \
  && ok "--help exits 0 with usage on stdout" || bad "--help rc=$rc out=$(head -c 200 "$tmp/out")"

# --ok above the default floor.
run 5 "$MG" --ok
want="mem-gate: ok: MemAvailable 4096 MB >= 2048 MB, swap used $swap_used MB"
[ "$rc" = 0 ] && [ "$(out)" = "$want" ] \
  && ok "--ok at 4096 MB exits 0 with the ok line" || bad "--ok high rc=$rc out=$(out)"

# --ok below the default floor.
run 5 env SYG_MEM_GATE_MEMINFO="$tmp/low" "$MG" --ok
[ "$rc" = 1 ] && [[ $(out) == "mem-gate: low: MemAvailable 1024 MB < 2048 MB"* ]] \
  && ok "--ok at 1024 MB exits 1 with the low line" || bad "--ok low rc=$rc out=$(out)"

# The knob moves the default floor.
run 5 env SYG_MEM_GATE_MIN_MB=8192 "$MG" --ok
[ "$rc" = 1 ] && [[ $(out) == "mem-gate: low: MemAvailable 4096 MB < 8192 MB"* ]] \
  && ok "SYG_MEM_GATE_MIN_MB=8192 fails a 4096 MB fixture" || bad "knob 8192 rc=$rc out=$(out)"

# An explicit MB argument wins over the knob.
run 5 env SYG_MEM_GATE_MIN_MB=8192 "$MG" --ok 1000
[ "$rc" = 0 ] && [[ $(out) == "mem-gate: ok: MemAvailable 4096 MB >= 1000 MB"* ]] \
  && ok "explicit --ok 1000 wins over SYG_MEM_GATE_MIN_MB=8192" || bad "arg wins rc=$rc out=$(out)"

# A bad knob value is a usage error naming the knob.
run 5 env SYG_MEM_GATE_MIN_MB=abc "$MG" --ok
[ "$rc" = 2 ] && grep -q "SYG_MEM_GATE_MIN_MB" "$tmp/err" \
  && ok "SYG_MEM_GATE_MIN_MB=abc exits 2 naming the knob" || bad "knob abc rc=$rc err=$(err)"

# A bad knob is not checked when an explicit MB is given.
run 5 env SYG_MEM_GATE_MIN_MB=abc "$MG" --ok 1000
[ "$rc" = 0 ] && [[ $(out) == "mem-gate: ok: MemAvailable 4096 MB >= 1000 MB"* ]] \
  && ok "SYG_MEM_GATE_MIN_MB=abc is not checked when --ok 1000 is explicit" || bad "bad knob + arg rc=$rc out=$(out) err=$(err)"

# Leading-zero numbers are decimal.
run 5 "$MG" --ok 0100
[ "$rc" = 0 ] && [[ $(out) == "mem-gate: ok: MemAvailable 4096 MB >= 100 MB"* ]] \
  && ok "--ok 0100 reads as 100, not octal" || bad "--ok 0100 rc=$rc out=$(out) err=$(err)"
run 15 env SYG_MEM_GATE_MEMINFO="$tmp/low" "$MG" --wait --interval 1 --timeout 02
[ "$rc" = 1 ] && grep -q "timed out" "$tmp/out" \
  && ok "--wait --interval 1 --timeout 02 times out (no arithmetic error)" || bad "--timeout 02 rc=$rc out=$(out) err=$(err)"
# 08 is not valid octal: it must still be waiting (cut off by the outer 3 s) with nothing on stderr.
run 3 env SYG_MEM_GATE_MEMINFO="$tmp/low" "$MG" --wait --interval 1 --timeout 08
[ "$rc" = 124 ] && [ ! -s "$tmp/err" ] \
  && ok "--timeout 08 keeps waiting: no usage or arithmetic failure" || bad "--timeout 08 rc=$rc err=$(err)"

# A lib that cannot be loaded: the bin copied alone, nothing beside it.
mkdir -p "$tmp/solo/bin"
cp "$MG" "$tmp/solo/bin/mem-gate"
run 5 "$tmp/solo/bin/mem-gate" --ok
[ "$rc" = 2 ] && grep -q "cannot load" "$tmp/err" \
  && ok "mem-gate without lib/owner.sh exits 2 with 'cannot load'" || bad "solo rc=$rc err=$(err)"

# A fixture without MemAvailable.
run 5 env SYG_MEM_GATE_MEMINFO="$tmp/no-avail" "$MG" --ok
[ "$rc" = 2 ] && grep -q "no MemAvailable line" "$tmp/err" \
  && ok "meminfo without MemAvailable exits 2" || bad "no MemAvailable rc=$rc err=$(err)"

# --wait times out on a low fixture.
run 15 env SYG_MEM_GATE_MEMINFO="$tmp/low" "$MG" --wait --interval 1 --timeout 2
[ "$rc" = 1 ] && grep -q "timed out" "$tmp/out" \
  && ok "--wait --timeout 2 on a low fixture exits 1 with 'timed out'" || bad "wait timeout rc=$rc out=$(out)"

# swap_when_waiting FILE AVAIL_MB|none: in the background, wait (up to ~10 s) for the tool's
# "mem-gate: waiting:" line in $tmp/out, pause 1 s, then replace FILE atomically with an AVAIL_MB
# fixture, or with the no-MemAvailable one for "none". The countdown starts with the tool, not before.
swap_when_waiting() {
  : > "$tmp/out"   # a previous case's startup line must not release the writer early
  (
    for _ in $(seq 50); do grep -q "mem-gate: waiting:" "$tmp/out" 2>/dev/null && break; sleep 0.2; done
    sleep 1
    if [ "$2" = none ]; then cp "$tmp/no-avail" "$1.new"; else mkmem "$1.new" "$2"; fi
    mv "$1.new" "$1"
  ) &
  bg=$!; bgpids+=("$bg")
}

# --wait returns once the fixture goes high (rewritten atomically after the tool is waiting).
mkmem "$tmp/recover" 1024
swap_when_waiting "$tmp/recover" 4096
run 20 env SYG_MEM_GATE_MEMINFO="$tmp/recover" "$MG" --wait --interval 1 --timeout 10
wait "$bg" 2>/dev/null
[ "$rc" = 0 ] && grep -q "ok after" "$tmp/out" \
  && ok "--wait exits 0 with 'ok after' once MemAvailable recovers" || bad "wait recover rc=$rc out=$(out)"

# MemAvailable disappears mid-wait: exit 2, not a stale or empty comparison.
mkmem "$tmp/vanish" 1024
swap_when_waiting "$tmp/vanish" none
run 20 env SYG_MEM_GATE_MEMINFO="$tmp/vanish" "$MG" --wait --interval 1 --timeout 10
wait "$bg" 2>/dev/null
[ "$rc" = 2 ] && grep -q "no MemAvailable line" "$tmp/err" \
  && ok "MemAvailable vanishing mid-wait exits 2" || bad "mid-wait no MemAvailable rc=$rc out=$(out) err=$(err)"

# Owner gone while waiting.
sleep 2 & own=$!; bgpids+=("$own")
run 25 env SYG_MEM_GATE_MEMINFO="$tmp/low" "$MG" --wait --interval 1 --timeout 20 --owner "$own"
[ "$rc" = 3 ] && grep -q "owner $own is gone" "$tmp/err" \
  && ok "owner exits mid-wait: exit 3 and 'owner $own is gone'" || bad "owner gone rc=$rc err=$(err)"

# An owner pid that is already reaped.
sleep 0.1 & dead=$!; wait "$dead" 2>/dev/null
run 25 env SYG_MEM_GATE_MEMINFO="$tmp/low" "$MG" --wait --interval 1 --timeout 20 --owner "$dead"
[ "$rc" = 3 ] && grep -q "owner $dead is gone" "$tmp/err" \
  && ok "dead owner exits 3" || bad "dead owner rc=$rc err=$(err)"

# Usage errors exit 2.
run 5 "$MG" --owner abc
[ "$rc" = 2 ] && grep -q "needs a PID" "$tmp/err" \
  && ok "--owner abc exits 2" || bad "--owner abc rc=$rc err=$(err)"
for args in "--interval 0" "--timeout abc" "--ok abc" "--bogus" "--owner"; do
  # shellcheck disable=SC2086 # the case labels are word lists on purpose
  run 5 "$MG" $args
  [ "$rc" = 2 ] && ok "'$args' exits 2" || bad "'$args' exits 2 (got rc $rc, 124 = hung)"
done

# owner_default, when it finds a session above this probe: its pid's exe is a claude binary.
o=$(bash -c ". '$REPO/plugins/seyag/lib/owner.sh'; owner_default")
if [ -n "$o" ]; then
  case "$(readlink "/proc/$o/exe")" in
    */claude/*|*/claude) ok "owner_default $o is a claude binary" ;;
    *) bad "owner_default $o is not a claude binary" ;;
  esac
fi

echo "mem-gate probe: $pass passed, $fail failed"
[ "$fail" = 0 ]
