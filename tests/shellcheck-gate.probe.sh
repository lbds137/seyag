#!/usr/bin/env bash
# Probe for plugins/seyag/bin/shellcheck-gate: usage and exit codes, missing binary error,
# sequential chunking via xargs over tests/shell-files.sh (with ROOT passthrough), flag
# passthrough, exit-code mapping (123 -> 1), gate-lock serialization, empty file list,
# and clean env -i execution.
# Usage: tests/shellcheck-gate.probe.sh   (from anywhere)
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO/plugins/seyag/bin"
SG="$BIN/shellcheck-gate"
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

t=$(mktemp -d); bg=()
cleanup() {
  for p in "${bg[@]}"; do kill "$p" 2>/dev/null; done
  rm -rf "$t"
}
trap cleanup EXIT
export SYG_GATE_LOCK_FILE=$t/gate.lock

# wait_for COND...: poll a command up to ~5 s (never a bare sleep as the synchronization)
wait_for() {
  for _ in $(seq 50); do "$@" && return 0; sleep 0.1; done
  return 1
}
wait_for_1s() {
  for _ in $(seq 10); do "$@" && return 0; sleep 0.1; done
  return 1
}
exists() { [ -e "$1" ]; }

mkdir -p "$t/minbin"
for cmd in bash dirname readlink mktemp xargs flock cat seq sleep grep rm kill; do
  if p=$(command -v "$cmd" 2>/dev/null) && [ -n "$p" ]; then
    ln -s "$p" "$t/minbin/$cmd"
  fi
done

STUB="$t/stub-shellcheck"
cat >"$STUB" <<'EOF'
#!/usr/bin/env bash
n=0
rc=0
skip=0
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case $a in
    -S) skip=1 ;;
    -*) ;;
    *)
      n=$((n + 1))
      if [ -n "${STUB_FAIL_ON:-}" ] && [[ $a == *"$STUB_FAIL_ON"* ]]; then
        rc=1
      fi
      ;;
  esac
done
if [ -n "${STUB_LOG:-}" ]; then
  printf 'nargs=%d args=%s\n' "$n" "$*" >>"$STUB_LOG"
fi
exit "$rc"
EOF
chmod +x "$STUB"

mkdir -p "$t/fx/tests" "$t/fx-empty/tests" "$t/fx/plugins/seyag/bin"
printf "printf '%%s\\n' '%s'/plugins/seyag/bin/tool0{1..7}\n" "$t/fx" >"$t/fx/tests/shell-files.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$t/fx-empty/tests/shell-files.sh"
for i in 1 2 3 4 5 6 7; do printf '#!/usr/bin/env bash\n' >"$t/fx/plugins/seyag/bin/tool0$i"; done

# (1) -h / --help exit 0 and print a usage line; no args exits 125; bad SYG_SHELLCHECK_CHUNK exits 125
out=$("$SG" -h 2>&1 >/dev/null); rc=$?
[ "$rc" = 0 ] && [[ $out == usage:* ]] \
  && ok "-h: exit 0 and usage on stderr" \
  || bad "-h (rc $rc: $out)"
out=$("$SG" --help 2>&1 >/dev/null); rc=$?
[ "$rc" = 0 ] && [[ $out == usage:* ]] \
  && ok "--help: exit 0 and usage on stderr" \
  || bad "--help (rc $rc: $out)"
out=$("$SG" 2>&1 >/dev/null); rc=$?
[ "$rc" = 125 ] && [[ $out == usage:* ]] \
  && ok "no args: exit 125 and usage on stderr" \
  || bad "no args (rc $rc: $out)"
out=$(SYG_SHELLCHECK_CHUNK=0 SYG_SHELLCHECK_BIN="$STUB" "$SG" -S warning 2>&1 >/dev/null); rc=$?
[ "$rc" = 125 ] && [[ $out == *SYG_SHELLCHECK_CHUNK* ]] \
  && ok "invalid SYG_SHELLCHECK_CHUNK=0: exit 125 with message on stderr" \
  || bad "invalid SYG_SHELLCHECK_CHUNK (rc $rc: $out)"

# (2) missing binary: SYG_SHELLCHECK_BIN=$t/definitely-missing and PATH without shellcheck/uvx -> 125
out=$(PATH="$t/minbin" SYG_SHELLCHECK_BIN="$t/definitely-missing" "$SG" -S warning 2>&1 >/dev/null); rc=$?
[ "$rc" = 125 ] && [[ $out == *"shellcheck-gate: no shellcheck found (install shellcheck or set SYG_SHELLCHECK_BIN)"* ]] \
  && ok "missing binary: exit 125 with 'no shellcheck found' message" \
  || bad "missing binary (rc $rc: $out)"

# (3) chunking: 7 fixture files, SYG_SHELLCHECK_CHUNK=3 -> 3 invocations with arg counts 3, 3, 1
log3="$t/case3.log"
ROOT="$t/fx" SYG_SHELLCHECK_BIN="$STUB" SYG_SHELLCHECK_CHUNK=3 STUB_LOG="$log3" \
  "$SG" -S warning --fstub-marker
rc=$?
mapfile -t lines3 <"$log3" 2>/dev/null
if [ "$rc" = 0 ] && [ "${#lines3[@]}" = 3 ] \
  && [[ ${lines3[0]} == "nargs=3 args="* ]] \
  && [[ ${lines3[1]} == "nargs=3 args="* ]] \
  && [[ ${lines3[2]} == "nargs=1 args="* ]]; then
  ok "chunking: 7 fixture files with SYG_SHELLCHECK_CHUNK=3 invoked stub 3 times with counts 3, 3, 1"
else
  bad "chunking (rc=$rc lines=${#lines3[@]}: $(cat "$log3" 2>/dev/null))"
fi

# (4) passthrough: -S warning and --fstub-marker reach every stub invocation
if [ "${#lines3[@]}" = 3 ] \
  && [[ ${lines3[0]} == *"args=-S warning --fstub-marker "* ]] \
  && [[ ${lines3[1]} == *"args=-S warning --fstub-marker "* ]] \
  && [[ ${lines3[2]} == *"args=-S warning --fstub-marker "* ]]; then
  ok "passthrough: -S warning and --fstub-marker reached every stub invocation"
else
  bad "passthrough ($(cat "$log3" 2>/dev/null))"
fi

# (5) exit propagation: stub exits 1 on marked file -> runner exits 1 (123->1 mapping); clean stub -> 0
log5a="$t/case5a.log"
ROOT="$t/fx" SYG_SHELLCHECK_BIN="$STUB" SYG_SHELLCHECK_CHUNK=3 STUB_LOG="$log5a" STUB_FAIL_ON=tool05 \
  "$SG" -S warning
rc_fail=$?
log5b="$t/case5b.log"
ROOT="$t/fx" SYG_SHELLCHECK_BIN="$STUB" SYG_SHELLCHECK_CHUNK=3 STUB_LOG="$log5b" \
  "$SG" -S warning
rc_clean=$?
if [ "$rc_fail" = 1 ] && [ "$rc_clean" = 0 ]; then
  ok "exit propagation: marked file exits 1 (xargs 123 mapped to 1); all-clean stub exits 0"
else
  bad "exit propagation (rc_fail=$rc_fail rc_clean=$rc_clean)"
fi

# (6) lock: busy SYG_GATE_LOCK_FILE blocks stub execution until released, then runs and returns stub code
lock6="$t/case6.lock"
log6="$t/case6.log"
mkfifo "$t/release"
( exec 8>>"$lock6"; flock 8; : >"$t/held"; read -r _ <"$t/release" ) &
holder=$!; bg+=("$holder")
if wait_for exists "$t/held"; then
  SYG_GATE_LOCK_FILE="$lock6" ROOT="$t/fx" SYG_SHELLCHECK_BIN="$STUB" SYG_SHELLCHECK_CHUNK=3 \
    STUB_LOG="$log6" STUB_FAIL_ON=tool02 "$SG" -S warning 2>"$t/lock6.err" &
  sg_pid=$!; bg+=("$sg_pid")
  waited=0
  wait_for grep -q "waiting for" "$t/lock6.err" && waited=1
  early=0
  wait_for_1s exists "$log6" && early=1
  echo go >"$t/release"
  wait "$holder" 2>/dev/null
  wait "$sg_pid"; rc6=$?
  if [ "$waited" = 1 ] && [ "$early" = 0 ] && [ -s "$log6" ] && [ "$rc6" = 1 ]; then
    ok "lock: runner waited while lock held (no stub run within ~1 s), then ran and exited with stub code 1"
  else
    bad "lock (waited=$waited early=$early rc=$rc6 log=$(cat "$log6" 2>/dev/null) err=$(cat "$t/lock6.err" 2>/dev/null))"
  fi
else
  bad "lock: background holder never acquired lock"
  echo go >"$t/release" 2>/dev/null
fi

# (7) empty file list: fixture enumerator prints nothing -> exit 0, stub never invoked
log7="$t/case7.log"
ROOT="$t/fx-empty" SYG_SHELLCHECK_BIN="$STUB" SYG_SHELLCHECK_CHUNK=3 STUB_LOG="$log7" \
  "$SG" -S warning
rc7=$?
if [ "$rc7" = 0 ] && [ ! -e "$log7" ]; then
  ok "empty file list: exit 0 and stub never invoked"
else
  bad "empty file list (rc=$rc7 log_exists=$([ -e "$log7" ] && echo yes || echo no))"
fi

# (8) env -i with minimal PATH: bin defaults do not depend on inherited env beyond PATH/HOME
log8="$t/case8.log"
env -i PATH="$t/minbin" HOME="$t" ROOT="$t/fx" SYG_GATE_LOCK_FILE="$t/envi.lock" \
  SYG_SHELLCHECK_BIN="$STUB" STUB_LOG="$log8" "$SG" -S warning
rc8=$?
mapfile -t lines8 <"$log8" 2>/dev/null
if [ "$rc8" = 0 ] && [ "${#lines8[@]}" = 1 ] && [[ ${lines8[0]} == "nargs=7 args=-S warning "* ]]; then
  ok "env -i with minimal PATH: default chunk=20 ran 7 fixture files in 1 invocation, exit 0"
else
  bad "env -i (rc=$rc8 lines=${#lines8[@]}: $(cat "$log8" 2>/dev/null))"
fi

# (9) failing enumerator: fixture prints two paths then exits 1 -> 125, stub never invoked
mkdir -p "$t/fxfail/tests"
cat >"$t/fxfail/tests/shell-files.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' '$t/fx/plugins/seyag/bin/tool01' '$t/fx/plugins/seyag/bin/tool02'
exit 1
EOF
log9="$t/case9.log"
out=$(ROOT="$t/fxfail" SYG_SHELLCHECK_BIN="$STUB" STUB_LOG="$log9" "$SG" -S warning 2>&1 >/dev/null); rc=$?
if [ "$rc" = 125 ] && [[ $out == *"file enumeration failed (exit 1)"* ]] && [ ! -e "$log9" ]; then
  ok "failing enumerator: exit 125 with 'file enumeration failed' message, stub never invoked"
else
  bad "failing enumerator (rc=$rc out=$out log=$([ -e "$log9" ] && echo present || echo absent))"
fi

# (10) ROOT set but no enumerator under it: no silent repo-enumerator fallback
mkdir -p "$t/fx2"
log10="$t/case10.log"
out=$(ROOT="$t/fx2" SYG_SHELLCHECK_BIN="$STUB" STUB_LOG="$log10" "$SG" -S warning 2>&1 >/dev/null); rc=$?
if [ "$rc" = 125 ] && [[ $out == *"ROOT is set but"* ]] && [ ! -e "$log10" ]; then
  ok "ROOT without tests/shell-files.sh: exit 125, no repo-enumerator fallback, stub never invoked"
else
  bad "ROOT without enumerator (rc=$rc out=$out log=$([ -e "$log10" ] && echo present || echo absent))"
fi

# (11) bare name: a stub named shellcheck on PATH (no SYG_SHELLCHECK_BIN) is resolved via command -v
log11="$t/case11.log"
lines11=()
cp "$STUB" "$t/minbin/shellcheck"
PATH="$t/minbin" ROOT="$t/fx" STUB_LOG="$log11" "$SG" -S warning >/dev/null 2>&1; rc=$?
mapfile -t lines11 <"$log11" 2>/dev/null
if [ "$rc" = 0 ] && [ "${#lines11[@]}" = 1 ] && [[ ${lines11[0]} == "nargs=7 args=-S warning "* ]]; then
  ok "bare name: shellcheck on PATH resolved via command -v and ran (7 files, exit 0)"
else
  bad "bare name (rc=$rc lines=${#lines11[@]}: $(cat "$log11" 2>/dev/null))"
fi

# (12) path-shaped knob that exists but is not an executable file -> 125, no uvx fallback
out=$(PATH="$t/minbin" SYG_SHELLCHECK_BIN="$t" "$SG" -S warning 2>&1 >/dev/null); rc=$?
if [ "$rc" = 125 ] && [[ $out == *"SYG_SHELLCHECK_BIN"*"is not an executable file"* ]]; then
  ok "unusable SYG_SHELLCHECK_BIN (directory): exit 125 with knob-naming message, no uvx attempt"
else
  bad "unusable SYG_SHELLCHECK_BIN (rc=$rc out=$out)"
fi

# (13) signal forwarding: TERM to the runner kills the pipeline; the lock outlives it
mkdir -p "$t/sigfx/tests" "$t/sigfx/files"
for i in 1 2 3 4; do printf '#!/usr/bin/env bash\n' >"$t/sigfx/files/f$i"; done
paths13=""
for i in 1 2 3 4; do paths13+=" '$t/sigfx/files/f$i'"; done
cat >"$t/sigfx/tests/shell-files.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n'$paths13
EOF
SSTUB="$t/stub-slow"
cat >"$SSTUB" <<'EOF'
#!/usr/bin/env bash
sleep 1
printf 'done %s\n' "$*" >>"$SLOW_LOG"
exit 0
EOF
chmod +x "$SSTUB"
mark="$t/case13.marks"
lock13="$t/case13.lock"
rm -f "$mark"
SLOW_LOG="$mark" ROOT="$t/sigfx" SYG_SHELLCHECK_BIN="$SSTUB" SYG_SHELLCHECK_CHUNK=1 \
  SYG_GATE_LOCK_FILE="$lock13" "$SG" -S warning >/dev/null 2>"$t/case13.err" &
sg13=$!; bg+=("$sg13")
dead() { local s; s=$(ps -o stat= -p "$1" 2>/dev/null); [ -z "$s" ] || [[ $s == Z* ]]; }
lockfree13() { ( exec 8>>"$lock13" && flock -n 8 ); }
if wait_for test -s "$mark"; then
  kill -TERM "$sg13" 2>/dev/null
  a_gone=0; wait_for dead "$sg13" && a_gone=1
  a_lock=0; wait_for lockfree13 && a_lock=1
  wait "$sg13" 2>/dev/null; rc13=$?
  n13a=0; [ -s "$mark" ] && n13a=$(wc -l <"$mark")
  sleep 1
  n13b=0; [ -s "$mark" ] && n13b=$(wc -l <"$mark")
  if [ "$a_gone" = 1 ] && [ "$a_lock" = 1 ] && [ "$n13a" = "$n13b" ]; then
    ok "signal forwarding: TERM reached runner -> runner gone (rc=$rc13), lock freed, no stub completed after the signal"
  else
    bad "signal forwarding (gone=$a_gone lockfree=$a_lock markers=$n13a->$n13b rc=$rc13 err=$(cat "$t/case13.err" 2>/dev/null))"
  fi
else
  bad "signal forwarding: no stub marker appeared within ~5 s (err=$(cat "$t/case13.err" 2>/dev/null))"
fi

# (14) an invocation killed by a signal: stub TERMs itself on a marked file -> xargs 125 -> exit 1
KSTUB="$t/stub-selfkill"
cat >"$KSTUB" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case $a in *killed*) kill -TERM $$ ;; esac
done
exit 0
EOF
chmod +x "$KSTUB"
mkdir -p "$t/kfx/tests" "$t/kfx/files"
for f in ok1 killed; do printf '#!/usr/bin/env bash\n' >"$t/kfx/files/$f"; done
cat >"$t/kfx/tests/shell-files.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' '$t/kfx/files/ok1' '$t/kfx/files/killed'
EOF
ROOT="$t/kfx" SYG_SHELLCHECK_BIN="$KSTUB" SYG_SHELLCHECK_CHUNK=1 SYG_GATE_LOCK_FILE="$t/case14.lock" \
  "$SG" -S warning >/dev/null 2>&1
rc14=$?
if [ "$rc14" = 1 ]; then
  ok "invocation killed by signal: stub self-TERM -> xargs 125 mapped to exit 1"
else
  bad "invocation killed by signal (rc=$rc14)"
fi

exit "$fail"
