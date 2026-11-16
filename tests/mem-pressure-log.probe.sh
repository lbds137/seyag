#!/usr/bin/env bash
# Hermetic probe for plugins/seyag/bin/mem-pressure-log: fixture meminfo/PSI files and a temp state dir, one
# run per case. Pins the JSON line's fields against the fixture values, the null-PSI fallback
# (missing pressure file still exits 0), --help's no-side-effects, the arg contract (exit 2),
# the MemAvailable requirement (unreadable or absent: exit 1, nothing written), and rotation at
# SYG_MEM_PRESSURE_MAX_BYTES (old content to log.jsonl.1, one new line in log.jsonl).
# Usage: tests/mem-pressure-log.probe.sh   (from anywhere)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MP="$REPO/plugins/seyag/bin/mem-pressure-log"
[ -x "$MP" ] || { echo "FAIL  $MP is not executable (chmod +x it)"; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/mem-pressure-log-probe.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; }

mkdir -p "$tmp/fix"
# 12345678/1024=12056, 2345678/1024=2290, 8388604/1024=8191, 7340032/1024=7168 (truncated).
cat > "$tmp/fix/meminfo" <<'EOF'
MemTotal:        16305768 kB
MemFree:          2345678 kB
MemAvailable:    12345678 kB
SwapTotal:        8388604 kB
SwapFree:         7340032 kB
EOF
cat > "$tmp/fix/psi" <<'EOF'
some avg10=1.25 avg60=0.42 avg300=0.10 total=123456
full avg10=0.00 avg60=0.01 avg300=0.00 total=789
EOF
cat > "$tmp/fix/meminfo-no-avail" <<'EOF'
MemTotal:        16305768 kB
MemFree:          2345678 kB
SwapTotal:        8388604 kB
SwapFree:         7340032 kB
EOF

# 1. One run: exit 0, exactly one line, every field matching the fixtures.
state="$tmp/one"
line="$state/log.jsonl"
before=$(date +%s)
SYG_MEM_PRESSURE_MEMINFO="$tmp/fix/meminfo" SYG_MEM_PRESSURE_PSI="$tmp/fix/psi" \
  SYG_MEM_PRESSURE_STATE_DIR="$state" "$MP"
rc=$?
after=$(date +%s)
[ "$rc" = 0 ] && ok "one run exits 0" || bad "one run rc=$rc"
[ "$(wc -l < "$line" 2>/dev/null || echo 0)" = 1 ] \
  && ok "exactly one line in log.jsonl" || bad "lines in log.jsonl: $(wc -l < "$line" 2>/dev/null || echo missing)"
for check in \
  '.avail_mb == 12056' \
  '.free_mb == 2290' \
  '.swap_total_mb == 8191' \
  '.swap_free_mb == 7168' \
  '.psi_some_avg10 == 1.25' \
  '.psi_some_avg60 == 0.42' \
  '.psi_full_avg10 == 0' \
  '.psi_full_avg60 == 0.01'
do
  jq -e "$check" "$line" >/dev/null 2>&1 \
    && ok "field $check" || bad "field $check -> $(jq -c "$check" "$line" 2>&1)"
done
epoch=$(jq -r '.epoch' "$line" 2>/dev/null)
jq -e --argjson b "$before" --argjson a "$after" '.epoch >= $b and .epoch <= $a and .epoch == (.epoch|floor)' \
  "$line" >/dev/null 2>&1 \
  && ok "epoch is an integer within the run's seconds" || bad "epoch: $epoch (run $before..$after)"
ts=$(jq -r '.ts' "$line" 2>/dev/null)
ts_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
[[ $ts =~ $ts_re ]] && [ "$(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" = "$ts" ] \
  && ok "ts is UTC ISO8601 Z and matches epoch" || bad "ts=$ts epoch=$epoch"

# 1b. A second run appends (no rotation below the default 5 MiB threshold).
SYG_MEM_PRESSURE_MEMINFO="$tmp/fix/meminfo" SYG_MEM_PRESSURE_PSI="$tmp/fix/psi" \
  SYG_MEM_PRESSURE_STATE_DIR="$state" "$MP"
[ "$?" = 0 ] && [ "$(wc -l < "$line")" = 2 ] \
  && ok "second run appends (2 lines)" || bad "second run: $(wc -l < "$line" 2>/dev/null || echo missing) lines"
[ ! -e "$state/log.jsonl.1" ] && ok "no rotation below the threshold" || bad "log.jsonl.1 exists"

# 2. Missing pressure file: psi fields null, exit 0.
state="$tmp/nopsi"
SYG_MEM_PRESSURE_MEMINFO="$tmp/fix/meminfo" SYG_MEM_PRESSURE_PSI="$tmp/fix/no-such-psi" \
  SYG_MEM_PRESSURE_STATE_DIR="$state" "$MP"
rc=$?
[ "$rc" = 0 ] && ok "missing pressure file still exits 0" || bad "missing pressure file rc=$rc"
jq -e '.psi_some_avg10 == null and .psi_some_avg60 == null and .psi_full_avg10 == null
       and .psi_full_avg60 == null and .avail_mb == 12056' \
  "$state/log.jsonl" >/dev/null 2>&1 \
  && ok "psi fields null, meminfo fields kept" || bad "line: $(cat "$state/log.jsonl" 2>/dev/null)"

# 3. --help: usage to stdout, exit 0, no state dir created.
state="$tmp/help"
out=$(SYG_MEM_PRESSURE_MEMINFO="$tmp/fix/meminfo" SYG_MEM_PRESSURE_PSI="$tmp/fix/psi" \
  SYG_MEM_PRESSURE_STATE_DIR="$state" "$MP" --help)
rc=$?
[ "$rc" = 0 ] && grep -q "Usage:" <<<"$out" \
  && ok "--help exits 0 with usage" || bad "--help rc=$rc"
[ ! -e "$state" ] && ok "--help creates no state dir" || bad "--help created $state"

# 4. Unknown argument: usage to stderr, exit 2, nothing created.
state="$tmp/badarg"
out=$(SYG_MEM_PRESSURE_MEMINFO="$tmp/fix/meminfo" SYG_MEM_PRESSURE_PSI="$tmp/fix/psi" \
  SYG_MEM_PRESSURE_STATE_DIR="$state" "$MP" --frobnicate 2>"$tmp/badarg.err")
rc=$?
[ "$rc" = 2 ] && ok "unknown arg exits 2" || bad "unknown arg rc=$rc"
[ -s "$tmp/badarg.err" ] && [ -z "$out" ] \
  && ok "unknown arg: usage to stderr, nothing on stdout" || bad "stderr: $(head -1 "$tmp/badarg.err")"
[ ! -e "$state" ] && ok "unknown arg creates nothing" || bad "unknown arg created $state"

# 5. Meminfo without MemAvailable: message to stderr, exit 1, nothing written.
state="$tmp/noavail"
out=$(SYG_MEM_PRESSURE_MEMINFO="$tmp/fix/meminfo-no-avail" SYG_MEM_PRESSURE_PSI="$tmp/fix/psi" \
  SYG_MEM_PRESSURE_STATE_DIR="$state" "$MP" 2>"$tmp/noavail.err")
rc=$?
[ "$rc" = 1 ] && ok "meminfo without MemAvailable exits 1" || bad "no-MemAvailable rc=$rc"
[ -s "$tmp/noavail.err" ] && ok "no-MemAvailable: message on stderr" || bad "stderr empty"
[ ! -e "$state" ] && ok "no-MemAvailable: writes nothing, creates no dir" || bad "created $state"
# Same for an unreadable meminfo.
state="$tmp/nomeminfo"
out=$(SYG_MEM_PRESSURE_MEMINFO="$tmp/fix/gone" SYG_MEM_PRESSURE_STATE_DIR="$state" "$MP" 2>"$tmp/nomeminfo.err")
rc=$?
[ "$rc" = 1 ] && [ -s "$tmp/nomeminfo.err" ] && [ ! -e "$state" ] \
  && ok "unreadable meminfo exits 1, creates nothing" || bad "unreadable meminfo rc=$rc"

# 6. Rotation: existing log over SYG_MEM_PRESSURE_MAX_BYTES moves to log.jsonl.1 (replacing a stale
# .1); the run leaves exactly one new line in log.jsonl.
state="$tmp/rotate"
mkdir -p "$state"
printf '{"old":1}\n{"old":2}\n' > "$state/log.jsonl"
printf 'stale\n' > "$state/log.jsonl.1"
SYG_MEM_PRESSURE_MEMINFO="$tmp/fix/meminfo" SYG_MEM_PRESSURE_PSI="$tmp/fix/psi" \
  SYG_MEM_PRESSURE_STATE_DIR="$state" SYG_MEM_PRESSURE_MAX_BYTES=10 "$MP"
rc=$?
printf '{"old":1}\n{"old":2}\n' > "$tmp/rotate.expected"
[ "$rc" = 0 ] && ok "rotating run exits 0" || bad "rotating run rc=$rc"
cmp -s "$tmp/rotate.expected" "$state/log.jsonl.1" \
  && ok "old content moved to log.jsonl.1 (stale .1 replaced)" || bad "log.jsonl.1: $(cat "$state/log.jsonl.1" 2>/dev/null)"
[ "$(wc -l < "$state/log.jsonl" 2>/dev/null || echo 0)" = 1 ] && jq -e '.avail_mb == 12056' "$state/log.jsonl" >/dev/null 2>&1 \
  && ok "log.jsonl holds exactly the one new line" || bad "log.jsonl: $(cat "$state/log.jsonl" 2>/dev/null)"

echo "---"
echo "mem-pressure-log probe: $pass passed, $fail failed"
[ "$fail" = 0 ]
