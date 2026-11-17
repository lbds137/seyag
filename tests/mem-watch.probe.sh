#!/usr/bin/env bash
# Hermetic probe for plugins/seyag/bin/mem-watch: fixture meminfo files (SYG_MEM_WATCH_MEMINFO) and
# a fixture cgroup tree (SYG_MEM_WATCH_CGROUP_ROOT), one run per case, each bounded by timeout.
# Pins --once against the fixture, the loop's below-threshold trigger and its top-3 text, the
# oom_kill trigger, the no-counter startup line, the missing-MemAvailable exit (once and loop),
# owner gone (exit 3) and the usage errors (exit 2, including --interval 0). Also pins the
# unrounded threshold compare (1.955 GB shown as 2.0 still trips --threshold-gb 2), a vanished
# or reset counter not counting as a kill, and the counter search taking only this user's app
# slice (own uid preferred, other uids and child scopes ignored, a root below the user slice ok).
# Usage: tests/mem-watch.probe.sh   (from anywhere)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MW="$REPO/plugins/seyag/bin/mem-watch"
[ -x "$MW" ] || { echo "FAIL  $MW is not executable (chmod +x it)"; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/mem-watch-probe.XXXXXX")
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

# mkmem FILE AVAIL_MB: a meminfo fixture.
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
# mkoom FILE N: a cgroup memory.events fixture with an oom_kill counter of N.
mkoom() {
  printf 'low 0\nhigh 0\nmax 0\noom 0\noom_kill %s\n' "$2" > "$1"
}

mkmem "$tmp/high" 4096
cat > "$tmp/no-avail" <<'EOF'
MemTotal:        16305768 kB
MemFree:          2345678 kB
SwapTotal:        8388604 kB
SwapFree:         7340032 kB
EOF
mkdir "$tmp/cg-empty"

# Baseline environment: the high fixture and a cgroup root with no counter in it.
export SYG_MEM_WATCH_MEMINFO="$tmp/high"
export SYG_MEM_WATCH_CGROUP_ROOT="$tmp/cg-empty"

# run SECONDS CMD...: stdout to $tmp/out, stderr to $tmp/err, exit code in $rc (124 = hung).
run() {
  local t=$1; shift
  timeout "$t" "$@" > "$tmp/out" 2> "$tmp/err"
  rc=$?
}
out() { cat "$tmp/out"; }
err() { cat "$tmp/err"; }

# --help: usage on stdout, exit 0.
run 5 "$MW" --help
[ "$rc" = 0 ] && grep -q "mem-watch \[--threshold-gb" "$tmp/out" \
  && ok "--help exits 0 with usage on stdout" || bad "--help rc=$rc out=$(head -c 200 "$tmp/out")"

# --once above and below the threshold.
run 5 "$MW" --once --threshold-gb 1
[ "$rc" = 0 ] && grep -q "MemAvailable 4.0 GB" "$tmp/out" \
  && ok "--once --threshold-gb 1 at 4 GB exits 0 and names MemAvailable 4.0 GB" || bad "--once 1 rc=$rc out=$(out)"
run 5 "$MW" --once --threshold-gb 8
[ "$rc" = 1 ] && grep -q "MemAvailable 4.0 GB" "$tmp/out" \
  && ok "--once --threshold-gb 8 at 4 GB exits 1" || bad "--once 8 rc=$rc out=$(out)"

# Loop mode triggers at once when below the threshold, with the top-3 text in MB.
run 10 "$MW" --threshold-gb 8 --interval 1
[ "$rc" = 0 ] && grep -q "below threshold" "$tmp/out" && grep -q "top 3 RSS: .* MB" "$tmp/out" \
  && ok "loop below threshold exits 0 with 'below threshold' and a top-3 text in MB" || bad "loop threshold rc=$rc out=$(out)"

# No counter under the cgroup root: the startup line says so.
run 10 "$MW" --threshold-gb 8 --interval 1
grep -q "none (watching MemAvailable only)" "$tmp/out" \
  && ok "empty cgroup root: startup line says 'none (watching MemAvailable only)'" || bad "no-counter startup line: $(out)"
run 5 "$MW" --once --threshold-gb 1
grep -q "oom counter none" "$tmp/out" \
  && ok "empty cgroup root: --once line says 'oom counter none'" || bad "no-counter --once line: $(out)"

# oom_kill trigger: the counter is found four levels down and rewritten once the tool is running
# (the writer waits for its startup line, so its countdown never starts before the tool does).
uid=$(id -u)
decoy=99999; [ "$uid" = "$decoy" ] && decoy=99998
cg="$tmp/cg/user-$uid.slice/user@$uid.service/app.slice"
mkdir -p "$cg"
mkoom "$cg/memory.events" 0
: > "$tmp/out"   # a previous case's startup line must not release the writer early
( for _ in $(seq 50); do grep -q "mem-watch: pid" "$tmp/out" 2>/dev/null && break; sleep 0.2; done
  sleep 1; mkoom "$cg/memory.events.new" 1; mv "$cg/memory.events.new" "$cg/memory.events" ) &
bg=$!; bgpids+=("$bg")
run 20 env SYG_MEM_WATCH_CGROUP_ROOT="$tmp/cg" "$MW" --threshold-gb 1 --interval 1
wait "$bg" 2>/dev/null
[ "$rc" = 0 ] && grep -q "oom_kill incremented" "$tmp/out" && grep -q "oom_kill 1 (was 0)" "$tmp/out" \
  && ok "oom_kill 0 -> 1 exits 0 with 'oom_kill incremented'" || bad "oom trigger rc=$rc out=$(out)"

# Threshold edge: 2050000 kB is 1.955 GB, which displays as 2.0 but is below 2 GB.
{
  echo "MemTotal:        16305768 kB"
  echo "MemAvailable:    2050000 kB"
} > "$tmp/just-under"
run 5 env SYG_MEM_WATCH_MEMINFO="$tmp/just-under" "$MW" --once --threshold-gb 2
[ "$rc" = 1 ] && grep -q "MemAvailable 2.0 GB" "$tmp/out" \
  && ok "--once at 1.955 GB (shows 2.0) with --threshold-gb 2 exits 1" || bad "just-under --once rc=$rc out=$(out)"
run 10 env SYG_MEM_WATCH_MEMINFO="$tmp/just-under" "$MW" --threshold-gb 2 --interval 1
[ "$rc" = 0 ] && grep -q "below threshold" "$tmp/out" \
  && ok "loop at 1.955 GB (shows 2.0) with --threshold-gb 2 exits 0 with 'below threshold'" || bad "just-under loop rc=$rc out=$(out)"

# A counter that vanishes mid-watch, then returns at the same value, is not a kill: keep
# watching. (Reading the gap as 0 would rebaseline to 0 and fire on the return to 3.)
cgv="$tmp/cg-vanish/user-$uid.slice/user@$uid.service/app.slice"
mkdir -p "$cgv"
mkoom "$cgv/memory.events" 3
: > "$tmp/out"
( for _ in $(seq 50); do grep -q "mem-watch: pid" "$tmp/out" 2>/dev/null && break; sleep 0.2; done
  sleep 1; rm -f "$cgv/memory.events"
  sleep 4; mkoom "$cgv/memory.events.new" 3; mv "$cgv/memory.events.new" "$cgv/memory.events" ) &
bg=$!; bgpids+=("$bg")
run 10 env SYG_MEM_WATCH_CGROUP_ROOT="$tmp/cg-vanish" "$MW" --threshold-gb 1 --interval 1
wait "$bg" 2>/dev/null
[ "$rc" = 124 ] && ! grep -q "oom_kill incremented" "$tmp/out" \
  && ok "counter vanishing mid-watch keeps watching (no trigger)" || bad "vanished counter rc=$rc out=$(out)"

# A non-numeric counter value counts as no value: keep watching, nothing on stderr.
cgn="$tmp/cg-nan/user-$uid.slice/user@$uid.service/app.slice"
mkdir -p "$cgn"
printf 'low 0\noom_kill abc\n' > "$cgn/memory.events"
run 4 env SYG_MEM_WATCH_CGROUP_ROOT="$tmp/cg-nan" "$MW" --threshold-gb 1 --interval 1
[ "$rc" = 124 ] && [ ! -s "$tmp/err" ] && ! grep -q "incremented" "$tmp/out" \
  && ok "non-numeric oom_kill keeps watching with empty stderr" || bad "non-numeric counter rc=$rc out=$(out) err=$(err)"

# A counter that resets (slice restarted) rebaselines; the next real increment triggers.
cgr="$tmp/cg-reset/user-$uid.slice/user@$uid.service/app.slice"
mkdir -p "$cgr"
mkoom "$cgr/memory.events" 5
: > "$tmp/out"
( for _ in $(seq 50); do grep -q "mem-watch: pid" "$tmp/out" 2>/dev/null && break; sleep 0.2; done
  sleep 1; mkoom "$cgr/memory.events.new" 0; mv "$cgr/memory.events.new" "$cgr/memory.events"
  sleep 4; mkoom "$cgr/memory.events.new" 1; mv "$cgr/memory.events.new" "$cgr/memory.events" ) &
bg=$!; bgpids+=("$bg")
run 25 env SYG_MEM_WATCH_CGROUP_ROOT="$tmp/cg-reset" "$MW" --threshold-gb 1 --interval 1
wait "$bg" 2>/dev/null
[ "$rc" = 0 ] && grep -q "oom_kill 1 (was 0)" "$tmp/out" && ! grep -q "(was 5)" "$tmp/out" \
  && ok "counter reset 5 -> 0 rebaselines, then 0 -> 1 triggers" || bad "reset counter rc=$rc out=$(out)"

# Counter search: this user's app slice only.
cgo="$tmp/cg-own"
# Own slice created first, the decoy last: directory order often lists the newest entry first,
# so a plain "first candidate" search would pick the decoy.
mkdir -p "$cgo/user-$uid.slice/user@$uid.service/app.slice"
mkoom "$cgo/user-$uid.slice/user@$uid.service/app.slice/memory.events" 2
mkdir -p "$cgo/user-$decoy.slice/user@$decoy.service/app.slice"
mkoom "$cgo/user-$decoy.slice/user@$decoy.service/app.slice/memory.events" 7
run 5 env SYG_MEM_WATCH_CGROUP_ROOT="$cgo" "$MW" --once --threshold-gb 1
grep -qF "oom counter $cgo/user-$uid.slice/user@$uid.service/app.slice/memory.events" "$tmp/out" && grep -q "oom_kill 2," "$tmp/out" \
  && ok "own uid's app slice preferred over another uid's" || bad "own uid preferred: $(out)"
mkdir -p "$tmp/cg-other/user-$decoy.slice/user@$decoy.service/app.slice"
mkoom "$tmp/cg-other/user-$decoy.slice/user@$decoy.service/app.slice/memory.events" 7
run 5 env SYG_MEM_WATCH_CGROUP_ROOT="$tmp/cg-other" "$MW" --once --threshold-gb 1
grep -q "oom counter none" "$tmp/out" \
  && ok "another uid's app slice alone is not used" || bad "other uid only: $(out)"
mkdir -p "$tmp/cg-scope/app.slice/x.scope"
mkoom "$tmp/cg-scope/app.slice/x.scope/memory.events" 4
run 5 env SYG_MEM_WATCH_CGROUP_ROOT="$tmp/cg-scope" "$MW" --once --threshold-gb 1
grep -q "oom counter none" "$tmp/out" \
  && ok "a child scope under app.slice is not matched" || bad "scope not matched: $(out)"
mkdir -p "$tmp/cgsvc/app.slice"
mkoom "$tmp/cgsvc/app.slice/memory.events" 6
run 5 env SYG_MEM_WATCH_CGROUP_ROOT="$tmp/cgsvc" "$MW" --once --threshold-gb 1
grep -qF "oom counter $tmp/cgsvc/app.slice/memory.events" "$tmp/out" && grep -q "oom_kill 6," "$tmp/out" \
  && ok "a root below the user slice finds app.slice/memory.events directly" || bad "root below user slice: $(out)"

# A fixture without MemAvailable: exit 2, not a false below-threshold trigger.
run 5 env SYG_MEM_WATCH_MEMINFO="$tmp/no-avail" "$MW" --once
[ "$rc" = 2 ] && grep -qF "no MemAvailable line in $tmp/no-avail" "$tmp/err" \
  && ok "--once with no MemAvailable line exits 2" || bad "--once no MemAvailable rc=$rc err=$(err)"
run 5 env SYG_MEM_WATCH_MEMINFO="$tmp/no-avail" "$MW" --threshold-gb 8 --interval 1
[ "$rc" = 2 ] && grep -q "no MemAvailable line in" "$tmp/err" && ! grep -q "below threshold" "$tmp/out" \
  && ok "loop with no MemAvailable line exits 2" || bad "loop no MemAvailable rc=$rc out=$(out) err=$(err)"

# A lib that cannot be loaded: the bin copied alone, nothing beside it.
mkdir -p "$tmp/solo/bin"
cp "$MW" "$tmp/solo/bin/mem-watch"
run 5 "$tmp/solo/bin/mem-watch" --once
[ "$rc" = 2 ] && grep -q "cannot load" "$tmp/err" \
  && ok "mem-watch without lib/owner.sh exits 2 with 'cannot load'" || bad "solo rc=$rc err=$(err)"

# Owner gone while watching.
sleep 2 & own=$!; bgpids+=("$own")
run 25 "$MW" --threshold-gb 0 --interval 1 --owner "$own"
[ "$rc" = 3 ] && grep -q "owner $own is gone" "$tmp/err" \
  && ok "owner exits mid-watch: exit 3 and 'owner $own is gone'" || bad "owner gone rc=$rc err=$(err)"

# Usage errors exit 2.
run 5 "$MW" --interval 0
[ "$rc" = 2 ] && grep -q "mem-watch: --interval must be at least 1" "$tmp/err" \
  && ok "--interval 0 exits 2 with 'must be at least 1'" || bad "--interval 0 rc=$rc err=$(err)"
for args in "--interval abc" "--interval" "--threshold-gb" "--threshold-gb abc" "--bogus"; do
  # shellcheck disable=SC2086 # the case labels are word lists on purpose
  run 5 "$MW" $args
  [ "$rc" = 2 ] && ok "'$args' exits 2" || bad "'$args' exits 2 (got rc $rc, 124 = hung)"
done

echo "mem-watch probe: $pass passed, $fail failed"
[ "$fail" = 0 ]
