#!/bin/bash
# Fixture check for tests/run-probes.sh against a synthetic repo of fake probes:
# suite-order output under -j 1 and -j 3, non-zero exit status, self-SIGKILL (137),
# process-group cleanup of a leaked background child, SIGTERM propagation, and
# -j / --jobs option parsing, --shard partitioning and balance, longest-first launch
# order, and --durations-out.
# Usage: tests/run-probes-runner.probe.sh   (from anywhere; never recurses into real probes)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

gone() {
  local pid=$1 i
  [ -n "$pid" ] || return 1
  for ((i = 0; i < 40; i++)); do
    if ! kill -0 "$pid" 2>/dev/null || grep -q '^State:[[:space:]]*Z' "/proc/$pid/status" 2>/dev/null; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

T=$(mktemp -d)
R="$T/repo"
PIDFILE="$R/leaked.pid"
RS="$T/sigrepo"
SIG_LEAK_PIDFILE="$RS/leaked.pid"
SIG_FG_PIDFILE="$RS/fg.pid"
leaked_pids=()
cleanup() {
  local f
  for f in "$PIDFILE" "$SIG_LEAK_PIDFILE" "$SIG_FG_PIDFILE"; do
    [ -s "$f" ] && leaked_pids+=("$(<"$f")")
  done
  # A recorded PID may be long dead and reused: kill it only while it is still
  # one of this probe's own sleep/bash fixtures.
  local p comm
  for p in ${leaked_pids[@]+"${leaked_pids[@]}"}; do
    comm=$(cat "/proc/$p/comm" 2>/dev/null) || continue
    case "$comm" in sleep | bash) kill -9 "$p" 2>/dev/null || true ;; esac
  done
  rm -rf "$T"
}
trap cleanup EXIT

mkdir -p "$R/tests" "$R/plugins/seyag/hooks"
cp "$REPO/tests/run-probes.sh" "$R/tests/run-probes.sh"
chmod +x "$R/tests/run-probes.sh"
RUNNER="$R/tests/run-probes.sh"

cat >"$R/tests/a.probe.sh" <<'EOF'
#!/bin/bash
sleep 0.3
exit 0
EOF

cat >"$R/tests/b.probe.sh" <<'EOF'
#!/bin/bash
echo bad
exit 3
EOF

cat >"$R/tests/c.probe.sh" <<'EOF'
#!/bin/bash
exit 0
EOF

cat >"$R/tests/d.probe.sh" <<'EOF'
#!/bin/bash
kill -9 $$
EOF

cat >"$R/tests/e.probe.sh" <<'EOF'
#!/bin/bash
sleep 300 &
echo "$!" >"$(dirname "${BASH_SOURCE[0]}")/../leaked.pid"
exit 0
EOF

want_lines='PASS  a
FAIL  b (exit 3)
      bad
PASS  c
FAIL  d (exit 137)
      (SIGTERM/SIGKILL after the 600s per-probe ceiling — usually the timeout, but an external cancel looks the same; the probe'\''s own output follows)
PASS  e
---
3 passed, 2 failed (of 5)'

rm -f "$PIDFILE"
out1=$(env -u SYG_PROBE_TIMEOUT bash "$RUNNER" -j 1)
rc1=$?
[ -s "$PIDFILE" ] && leaked_pids+=("$(<"$PIDFILE")")
if [ "$rc1" -eq 1 ] && [ "$(grep -v '^ *$' <<<"$out1")" = "$want_lines" ]; then
  ok "-j 1: suite-order PASS/FAIL lines, indented failure output, summary 3 passed, 2 failed (of 5), exit 1"
else
  bad "-j 1 (rc=$rc1): [$out1]"
fi
if [ -s "$PIDFILE" ] && gone "$(<"$PIDFILE")"; then
  ok "-j 1: leaked sleep 300 PID ($(<"$PIDFILE")) is no longer alive"
else
  bad "-j 1: leaked sleep 300 PID (${PIDFILE}: $(cat "$PIDFILE" 2>/dev/null)) still alive or missing"
fi

rm -f "$PIDFILE"
out3=$(env -u SYG_PROBE_TIMEOUT bash "$RUNNER" -j 3)
rc3=$?
[ -s "$PIDFILE" ] && leaked_pids+=("$(<"$PIDFILE")")
if [ "$rc3" -eq 1 ] && [ "$(grep -v '^ *$' <<<"$out3")" = "$want_lines" ]; then
  ok "-j 3: suite-order PASS/FAIL lines, indented failure output, summary 3 passed, 2 failed (of 5), exit 1"
else
  bad "-j 3 (rc=$rc3): [$out3]"
fi
if [ -s "$PIDFILE" ] && gone "$(<"$PIDFILE")"; then
  ok "-j 3: leaked sleep 300 PID ($(<"$PIDFILE")) is no longer alive"
else
  bad "-j 3: leaked sleep 300 PID (${PIDFILE}: $(cat "$PIDFILE" 2>/dev/null)) still alive or missing"
fi

if [ "$out1" = "$out3" ]; then
  ok "-j 1 and -j 3 outputs are identical"
else
  bad "-j 1 and -j 3 outputs differ: [-j 1: $out1] vs [-j 3: $out3]"
fi

want_usage="Usage: tests/run-probes.sh [-j N | --jobs N] [--shard I/N] [--durations-out FILE]"
for bad_args in "-j x" "-j -1" "--bogus"; do
  # shellcheck disable=SC2086 # intentional word splitting of flag + arg pair
  out=$(bash "$RUNNER" $bad_args 2>"$T/err")
  rc=$?
  err=$(<"$T/err")
  if [ "$rc" -eq 2 ] && [ -z "$out" ] && [ "$err" = "$want_usage" ]; then
    ok "invalid option '$bad_args': exit 2 with usage line on stderr"
  else
    bad "invalid option '$bad_args': rc=$rc out=[$out] err=[$err]"
  fi
done

for ok_args in "-j0" "--jobs=2" "-j 2"; do
  rm -f "$PIDFILE"
  # shellcheck disable=SC2086 # intentional word splitting of flag + arg pair
  out=$(bash "$RUNNER" $ok_args)
  rc=$?
  [ -s "$PIDFILE" ] && leaked_pids+=("$(<"$PIDFILE")")
  if [ "$rc" -eq 1 ] && [ "$(tail -n 1 <<<"$out")" = "3 passed, 2 failed (of 5)" ] \
    && [ -s "$PIDFILE" ] && gone "$(<"$PIDFILE")"; then
    ok "valid option '$ok_args': exit 1 with summary '3 passed, 2 failed (of 5)' and leaked child stopped"
  else
    bad "valid option '$ok_args': rc=$rc out=[$out]"
  fi
done

# --- --shard, longest-first launch order, --durations-out ---
# Six fake probes a..f that log their start and pass. Table seconds: a 5, b 9,
# c 1, d 7, e 3, f 2. Longest first: b d a e f c. Greedy over 3 shards (smallest
# running total, ties to the lowest shard): b->1 (9), d->2 (7), a->3 (5),
# e->3 (8), f->2 (9), c->3 (9). So shard 1 = {b}, 2 = {d f}, 3 = {a c e}.
RP="$T/shardrepo"
mkdir -p "$RP/tests" "$RP/plugins/seyag/hooks"
cp "$REPO/tests/run-probes.sh" "$RP/tests/run-probes.sh"
for n in a b c d e f; do
  cat >"$RP/tests/$n.probe.sh" <<EOF
#!/bin/bash
echo $n >>"\$(dirname "\${BASH_SOURCE[0]}")/../start.log"
exit 0
EOF
done
printf '%s\n' \
  '# fixture durations' \
  '' \
  $'tests/a.probe.sh\t5.0' \
  $'tests/b.probe.sh\t9' \
  $'tests/c.probe.sh\t1.0' \
  $'tests/d.probe.sh\t7.0' \
  $'tests/e.probe.sh\t3.0' \
  $'tests/f.probe.sh\t2.0' \
  $'tests/ghost.probe.sh\t99.0' >"$RP/tests/probe-durations.tsv"
RPRUN="$RP/tests/run-probes.sh"

shard_names() { # prints the PASS names of one --shard run, space separated
  bash "$RPRUN" -j 2 "$@" 2>/dev/null | awk '/^PASS/ { printf "%s ", $2 }'
}

s1=$(shard_names --shard 1/3)
s2=$(shard_names --shard 2/3)
s3=$(shard_names --shard 3/3)
union=$(printf '%s\n' $s1 $s2 $s3 | sort | tr '\n' ' ')
if [ "$union" = "a b c d e f " ]; then
  ok "--shard 1/3, 2/3, 3/3 together run every probe exactly once"
else
  bad "--shard partition: 1/3=[$s1] 2/3=[$s2] 3/3=[$s3] union=[$union]"
fi

if [ "$s1" = "b " ] && [ "$s2" = "d f " ] && [ "$s3" = "a c e " ]; then
  ok "--shard split matches the hand-computed greedy balance (1={b} 2={d f} 3={a c e})"
else
  bad "--shard balance: 1/3=[$s1] 2/3=[$s2] 3/3=[$s3]"
fi

out=$(bash "$RPRUN" -j 2 --shard=3/3 2>"$T/err")
rc=$?
err=$(<"$T/err")
want_s3=$'PASS  a\nPASS  c\nPASS  e\n---\n3 passed, 0 failed (of 3)'
if [ "$rc" -eq 0 ] && [ "$out" = "$want_s3" ] \
  && [ "$(grep -cF 'run-probes: shard 3/3: 3 of 6 probes' <<<"$err")" -eq 1 ]; then
  ok "--shard=3/3: suite-order PASS lines, summary over the selected probes, shard line on stderr"
else
  bad "--shard=3/3: rc=$rc out=[$out] err=[$err]"
fi

rm -f "$RP/start.log"
out=$(bash "$RPRUN" -j 1)
rc=$?
order=$(tr '\n' ' ' <"$RP/start.log")
want_all=$'PASS  a\nPASS  b\nPASS  c\nPASS  d\nPASS  e\nPASS  f\n---\n6 passed, 0 failed (of 6)'
if [ "$rc" -eq 0 ] && [ "$order" = "b d a e f c " ] && [ "$out" = "$want_all" ]; then
  ok "-j 1: probes start longest-first (b d a e f c) while PASS lines stay in suite order"
else
  bad "longest-first: rc=$rc start order=[$order] out=[$out]"
fi

# No table: every probe counts as 10 s, so the split is by path: 1={a c e} 2={b d f}.
mv "$RP/tests/probe-durations.tsv" "$RP/probe-durations.saved"
n1=$(shard_names --shard 1/2)
n2=$(shard_names --shard 2/2)
union=$(printf '%s\n' $n1 $n2 | sort | tr '\n' ' ')
if [ "$union" = "a b c d e f " ] && [ "$n1" = "a c e " ] && [ "$n2" = "b d f " ]; then
  ok "no probe-durations.tsv: --shard 1/2 and 2/2 still partition the set (all probes count 10 s)"
else
  bad "no table: 1/2=[$n1] 2/2=[$n2] union=[$union]"
fi
mv "$RP/probe-durations.saved" "$RP/tests/probe-durations.tsv"

for bad_spec in "0/3" "4/3" "1/0" "x" "1/3/2"; do
  out=$(bash "$RPRUN" --shard "$bad_spec" 2>"$T/err")
  rc=$?
  err=$(<"$T/err")
  if [ "$rc" -eq 2 ] && [ -z "$out" ] && [ "$err" = "$want_usage" ]; then
    ok "invalid --shard '$bad_spec': exit 2 with usage line on stderr"
  else
    bad "invalid --shard '$bad_spec': rc=$rc out=[$out] err=[$err]"
  fi
done

out=$(bash "$RPRUN" --shard 9/9 2>"$T/err")
rc=$?
err=$(<"$T/err")
if [ "$rc" -eq 0 ] && [ "$out" = $'---\n0 passed, 0 failed (of 0)' ] \
  && [ "$(grep -cF 'run-probes: shard 9/9: 0 of 6 probes' <<<"$err")" -eq 1 ]; then
  ok "--shard 9/9 over 6 probes: empty shard exits 0 with '0 passed, 0 failed (of 0)'"
else
  bad "empty shard: rc=$rc out=[$out] err=[$err]"
fi

# --durations-out: a run whose probes all pass writes one row per probe, suite
# order; a run with a failing probe writes nothing; with --shard it is a usage error.
RD="$T/durrepo"
mkdir -p "$RD/tests" "$RD/plugins/seyag/hooks"
cp "$REPO/tests/run-probes.sh" "$RD/tests/run-probes.sh"
printf '#!/bin/bash\nsleep 0.3\nexit 0\n' >"$RD/tests/x.probe.sh"
printf '#!/bin/bash\nexit 0\n' >"$RD/tests/z.probe.sh"
for dur_args in "--durations-out $T/dur1.tsv" "--durations-out=$T/dur1.tsv"; do
  rm -f "$T/dur1.tsv"
  # shellcheck disable=SC2086 # intentional word splitting of flag + arg pair
  out=$(bash "$RD/tests/run-probes.sh" -j 2 $dur_args 2>/dev/null)
  rc=$?
  rows=$(grep -v '^#' "$T/dur1.tsv" 2>/dev/null)
  comments=$(grep -c '^#' "$T/dur1.tsv" 2>/dev/null)
  paths=$(awk -F'\t' '{ printf "%s ", $1 }' <<<"$rows")
  numeric=$(awk -F'\t' '$2 !~ /^[0-9]+\.[0-9]$/ { n++ } END { print n + 0 }' <<<"$rows")
  slow=$(awk -F'\t' '$1 == "tests/x.probe.sh" && $2 >= 0.3 { print "yes" }' <<<"$rows")
  if [ "$rc" -eq 0 ] && [ "$comments" -eq 2 ] \
    && [ "$paths" = "tests/x.probe.sh tests/z.probe.sh " ] \
    && [ "$numeric" -eq 0 ] && [ "$slow" = "yes" ]; then
    ok "'${dur_args%%[ =]*}': all probes pass, so two comment lines, then a numeric row per probe in suite order"
  else
    bad "'$dur_args': rc=$rc comments=$comments paths=[$paths] non-numeric=$numeric slow=[$slow] out=[$out]"
  fi
done

# A failing probe: no file, a 'not writing' line on stderr, exit status still 1.
printf '#!/bin/bash\nexit 3\n' >"$RD/tests/y.probe.sh"
rm -f "$T/dur2.tsv"
out=$(bash "$RD/tests/run-probes.sh" -j 2 --durations-out "$T/dur2.tsv" 2>"$T/err")
rc=$?
err=$(<"$T/err")
if [ "$rc" -eq 1 ] && [ ! -e "$T/dur2.tsv" ] \
  && [ "$(grep -cxF "run-probes: not writing $T/dur2.tsv: 1 probe(s) failed" <<<"$err")" -eq 1 ] \
  && [ "$(tail -n 1 <<<"$out")" = "2 passed, 1 failed (of 3)" ]; then
  ok "--durations-out with a failing probe: no file, 'not writing' line on stderr, summary kept, exit 1"
else
  bad "--durations-out with a failing probe: rc=$rc file=$([ -e "$T/dur2.tsv" ] && echo present || echo absent) err=[$err] out=[$out]"
fi

# --durations-out with --shard is a usage error: exit 2, usage line, no file.
rm -f "$T/dur3.tsv"
out=$(bash "$RD/tests/run-probes.sh" --shard 1/2 --durations-out "$T/dur3.tsv" 2>"$T/err")
rc=$?
err=$(<"$T/err")
if [ "$rc" -eq 2 ] && [ -z "$out" ] && [ "$err" = "$want_usage" ] && [ ! -e "$T/dur3.tsv" ]; then
  ok "--shard 1/2 with --durations-out: exit 2 with usage line on stderr, no file"
else
  bad "--shard with --durations-out: rc=$rc out=[$out] err=[$err] file=$([ -e "$T/dur3.tsv" ] && echo present || echo absent)"
fi

mkdir -p "$RS/tests" "$RS/plugins/seyag/hooks"
cp "$REPO/tests/run-probes.sh" "$RS/tests/run-probes.sh"
chmod +x "$RS/tests/run-probes.sh"

cat >"$RS/tests/s.probe.sh" <<'EOF'
#!/bin/bash
dir="$(dirname "${BASH_SOURCE[0]}")/.."
sleep 300 &
echo "$!" >"$dir/leaked.pid"
sleep 30 &
echo "$!" >"$dir/fg.pid"
wait
EOF

bash "$RS/tests/run-probes.sh" -j 2 >"$T/sig.out" 2>&1 &
runner_pid=$!
leaked_pids+=("$runner_pid")

for ((i = 0; i < 100; i++)); do
  [ -s "$SIG_LEAK_PIDFILE" ] && [ -s "$SIG_FG_PIDFILE" ] && break
  sleep 0.05
done
[ -s "$SIG_LEAK_PIDFILE" ] && leaked_pids+=("$(<"$SIG_LEAK_PIDFILE")")
[ -s "$SIG_FG_PIDFILE" ] && leaked_pids+=("$(<"$SIG_FG_PIDFILE")")

kill -TERM "$runner_pid" 2>/dev/null || true

runner_exited=0
for ((i = 0; i < 100; i++)); do
  if ! kill -0 "$runner_pid" 2>/dev/null || grep -q '^State:[[:space:]]*Z' "/proc/$runner_pid/status" 2>/dev/null; then
    runner_exited=1
    break
  fi
  sleep 0.05
done
if [ "$runner_exited" -eq 1 ]; then
  wait "$runner_pid" 2>/dev/null
  sig_rc=$?
else
  kill -9 "$runner_pid" 2>/dev/null || true
  wait "$runner_pid" 2>/dev/null
  sig_rc=-1
fi

if [ "$runner_exited" -eq 1 ] && [ "$sig_rc" -eq 143 ]; then
  ok "SIGTERM to runner: exits within 5s with status 143"
else
  bad "SIGTERM to runner: runner_exited=$runner_exited rc=$sig_rc"
fi
if [ -s "$SIG_LEAK_PIDFILE" ] && gone "$(<"$SIG_LEAK_PIDFILE")"; then
  ok "SIGTERM to runner: leaked sleep 300 PID ($(<"$SIG_LEAK_PIDFILE")) is gone"
else
  bad "SIGTERM to runner: leaked sleep 300 PID (${SIG_LEAK_PIDFILE}: $(cat "$SIG_LEAK_PIDFILE" 2>/dev/null)) still alive or missing"
fi
if [ -s "$SIG_FG_PIDFILE" ] && gone "$(<"$SIG_FG_PIDFILE")"; then
  ok "SIGTERM to runner: probe sleep 30 PID ($(<"$SIG_FG_PIDFILE")) is gone"
else
  bad "SIGTERM to runner: probe sleep 30 PID (${SIG_FG_PIDFILE}: $(cat "$SIG_FG_PIDFILE" 2>/dev/null)) still alive or missing"
fi

exit "$fail"
