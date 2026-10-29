#!/bin/bash
# Fixture check for tests/run-probes.sh against a synthetic repo of fake probes:
# suite-order output under -j 1 and -j 3, non-zero exit status, self-SIGKILL (137),
# process-group cleanup of a leaked background child, SIGTERM propagation, and
# -j / --jobs option parsing.
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
out1=$(bash "$RUNNER" -j 1)
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
out3=$(bash "$RUNNER" -j 3)
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

want_usage="Usage: tests/run-probes.sh [-j N | --jobs N]"
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
