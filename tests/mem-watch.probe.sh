#!/usr/bin/env bash
# Hermetic probe for plugins/seyag/bin/mem-watch: fixture meminfo files (SYG_MEM_WATCH_MEMINFO) and
# a fixture cgroup tree (SYG_MEM_WATCH_CGROUP_ROOT), one run per case, each bounded by timeout.
# Pins --once against the fixture, the loop's below-threshold trigger and its top-3 text, the
# oom_kill trigger, the no-counter startup line, the missing-MemAvailable exit (once and loop),
# owner gone (exit 3) and the usage errors (exit 2, including --interval 0).
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
cg="$tmp/cg/user-1000.slice/user@1000.service/app.slice"
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

# A fixture without MemAvailable: exit 2, not a false below-threshold trigger.
run 5 env SYG_MEM_WATCH_MEMINFO="$tmp/no-avail" "$MW" --once
[ "$rc" = 2 ] && grep -q "no MemAvailable line in $tmp/no-avail" "$tmp/err" \
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
