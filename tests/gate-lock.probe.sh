#!/usr/bin/env bash
# Probe for plugins/seyag/bin/gate-lock: usage and exit codes, a busy lock waits (and the command
# does not run until it frees), the command never inherits the lock fd, TERM, INT and HUP are
# forwarded (as TERM) and waited out so the lock outlives the signal until the command is gone, the
# command reads gate-lock's own stdin, the old unprefixed GATE_LOCK_FILE does not override
# SYG_GATE_LOCK_FILE, holder record write/clear (R1, R2), waiter holder report with unverified
# pidns and stale record fallbacks (R3), control-char stripping in forged labels (R4), no-record
# open-fd fallback without cap suffix or walker stderr leak (R5), hold-cap warning suffix without
# signalling the holder (R6), reporter exit on SIGKILL of waiting gate-lock without holding the
# lock fd (R7), record sanitize shape at write for cmd/dir (R8), and light lock class
# (--light-path, L1-L8, including SYG_GATE_LOCK_PEAK_MB floor+peak bar, heavy fallback, and signal
# during the light memory wait).
# Usage: tests/gate-lock.probe.sh   (from anywhere)
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO/plugins/seyag/bin"
GL="$BIN/gate-lock"
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
exists() { [ -e "$1" ]; }

# (a) no args: 125 plus usage on stderr; -h: 0
out=$("$GL" 2>&1 >/dev/null); rc=$?
[ "$rc" = 125 ] && [[ $out == usage:* ]] \
  && ok "no args: exit 125 and usage on stderr" \
  || bad "no args (rc $rc: $out)"
"$GL" -h >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "-h: exit 0" || bad "-h (rc $rc)"

# (b) the command's exit code passes through
"$GL" sh -c 'exit 7'; rc=$?
[ "$rc" = 7 ] && ok "exit code 7 passes through" || bad "exit code 7 (rc $rc)"
"$GL" true; rc=$?
[ "$rc" = 0 ] && ok "exit code 0 passes through" || bad "exit code 0 (rc $rc)"

# (c) an unopenable lock path (a directory) -> 125
mkdir "$t/lockdir"
out=$(SYG_GATE_LOCK_FILE=$t/lockdir "$GL" true 2>&1); rc=$?
[ "$rc" = 125 ] && [[ $out == *"can't open"* ]] \
  && ok "unopenable lock path: exit 125 with a message" \
  || bad "unopenable lock path (rc $rc: $out)"

# (d) a busy lock waits and the command does not run until it frees
mkfifo "$t/release"
( exec 8>>"$SYG_GATE_LOCK_FILE"; flock 8; : >"$t/held"; read -r _ <"$t/release" ) &
holder=$!; bg+=("$holder")
if wait_for exists "$t/held"; then
  "$GL" sh -c ': >"$1"' _ "$t/ran" 2>"$t/d.err" &
  gl=$!; bg+=("$gl")
  waited=0
  wait_for grep -q "waiting for" "$t/d.err" && waited=1
  # dwell ~0.5 s with the lock still held: a gate-lock that ran the command anyway would show it here
  early=0; for _ in 1 2 3 4 5; do [ -e "$t/ran" ] && { early=1; break; }; sleep 0.1; done
  echo go >"$t/release"
  wait "$holder" 2>/dev/null
  wait "$gl"; rc=$?
  [ "$waited" = 1 ] && [ "$early" = 0 ] && [ "$rc" = 0 ] && [ -e "$t/ran" ] \
    && ok "busy lock: waits (message on stderr), command runs only after release" \
    || bad "busy lock (waited=$waited early=$early rc=$rc err: $(cat "$t/d.err"))"
else
  bad "busy lock: the holder never took the lock"
  echo go >"$t/release" 2>/dev/null
fi

# (e) the command does not inherit fd 9
out=$("$GL" sh -c '[ -e /proc/self/fd/9 ] && echo inherited || echo clean' 2>&1)
[ "$out" = clean ] && ok "the command does not inherit the lock fd" || bad "fd 9 inherited ([$out])"

# (f) TERM is forwarded; gate-lock exits with the child's code and holds the lock until it is gone
cat >"$t/child.sh" <<'EOF'
#!/usr/bin/env bash
trap ': >"$1/term-seen"' TERM
: >"$1/child-up"
until [ -e "$1/finish" ]; do sleep 0.1; done
exit 0
EOF
chmod +x "$t/child.sh"
"$GL" "$t/child.sh" "$t" &
gl=$!; bg+=("$gl")
if wait_for exists "$t/child-up"; then
  kill -TERM "$gl"
  wait_for exists "$t/term-seen" && seen=1 || seen=0
  flock -n "$SYG_GATE_LOCK_FILE" true && free_early=1 || free_early=0
  : >"$t/finish"
  wait "$gl"; rc=$?
  flock -n "$SYG_GATE_LOCK_FILE" true && free_late=1 || free_late=0
  [ "$seen" = 1 ] && [ "$free_early" = 0 ] && [ "$rc" = 0 ] && [ "$free_late" = 1 ] \
    && ok "TERM forwarded to the command; lock held until it is gone; exit is the command's" \
    || bad "TERM forwarding (seen=$seen free_early=$free_early rc=$rc free_late=$free_late)"
else
  bad "TERM forwarding: the child never started"
  : >"$t/finish"
fi

# (g) INT and HUP are forwarded the same way, as TERM (the child's trap is on TERM)
# A job started with & from a non-interactive shell has SIGINT ignored on entry, and bash cannot trap
# a signal that was ignored on entry: `env --default-signal=INT` restores it for the background child.
for sig in INT HUP; do
  d=$t/sig-$sig; mkdir "$d"
  env --default-signal=INT "$GL" "$t/child.sh" "$d" &
  gl=$!; bg+=("$gl")
  if wait_for exists "$d/child-up"; then
    kill -"$sig" "$gl"
    wait_for exists "$d/term-seen" && seen=1 || seen=0
    flock -n "$SYG_GATE_LOCK_FILE" true && free_early=1 || free_early=0
    : >"$d/finish"
    wait "$gl"; rc=$?
    flock -n "$SYG_GATE_LOCK_FILE" true && free_late=1 || free_late=0
    [ "$seen" = 1 ] && [ "$free_early" = 0 ] && [ "$rc" = 0 ] && [ "$free_late" = 1 ] \
      && ok "$sig forwarded to the command as TERM; lock held until it is gone; exit is the command's" \
      || bad "$sig forwarding (seen=$seen free_early=$free_early rc=$rc free_late=$free_late)"
  else
    bad "$sig forwarding: the child never started"
    : >"$d/finish"
  fi
done

# (h) the command reads gate-lock's stdin (a background job would otherwise get /dev/null)
out=$(printf 'hello\n' | "$GL" cat)
[ "$out" = hello ] && ok "the command reads gate-lock's stdin" || bad "stdin passthrough ([$out])"

# (i) the old unprefixed GATE_LOCK_FILE doesn't override SYG_GATE_LOCK_FILE (hermetic: both under
# $t, so no row ever falls back to the real /tmp/gate.lock and queues behind live gates)
SYG_GATE_LOCK_FILE=$t/new.lock GATE_LOCK_FILE=$t/old.lock "$GL" true
[ -e "$t/new.lock" ] && [ ! -e "$t/old.lock" ] \
  && ok "the old GATE_LOCK_FILE name doesn't override SYG_GATE_LOCK_FILE" \
  || bad "old lock name (new=$([ -e "$t/new.lock" ] && echo yes || echo no) old=$([ -e "$t/old.lock" ] && echo yes || echo no))"

# (R1) held gate-lock (real gate-lock running a FIFO-blocked command, label fixture-holder):
# waiter's stderr names fixture-holder, holder's pid, and a held age; first waiting line is byte-identical
r1_lock=$t/r1.lock
mkfifo "$t/r1-fifo"
SYG_GATE_LOCK_FILE=$r1_lock SYG_GATE_LOCK_LABEL=fixture-holder \
  "$GL" sh -c ': >"$1"; read -r _ <"$2"' _ "$t/r1-held" "$t/r1-fifo" &
r1_holder=$!; bg+=("$r1_holder")
if wait_for exists "$t/r1-held"; then
  SYG_GATE_LOCK_FILE=$r1_lock SYG_GATE_LOCK_REPORT_S=1 \
    "$GL" sh -c ': >"$1"' _ "$t/r1-ran" 2>"$t/r1.err" &
  r1_waiter=$!; bg+=("$r1_waiter")
  wait_for grep -q "still waiting" "$t/r1.err"
  echo go >"$t/r1-fifo"
  wait "$r1_holder" 2>/dev/null
  wait "$r1_waiter"; r1_rc=$?
  r1_first=$(head -n 1 "$t/r1.err" 2>/dev/null)
  r1_err=$(cat "$t/r1.err" 2>/dev/null)
  if [ "$r1_rc" = 0 ] && [ -e "$t/r1-ran" ] \
    && [ "$r1_first" = "gate-lock: waiting for $r1_lock (another gate run holds it)" ] \
    && [[ $r1_err == *"gate-lock: holder: pid $r1_holder, fixture-holder, in "* ]] \
    && [[ $r1_err == *", held "* ]] \
    && [[ $r1_err == *"gate-lock: still waiting ("*"); holder: pid $r1_holder, fixture-holder, "* ]]; then
    ok "R1: waiter reports fixture-holder, holder pid and held age; first waiting line is byte-identical"
  else
    bad "R1 holder report (rc=$r1_rc first=[$r1_first] err=[$r1_err])"
  fi
else
  bad "R1: fixture-holder never started"
  echo go >"$t/r1-fifo" 2>/dev/null
fi

# (R2) the holder record is cleared after release
if [ -e "$r1_lock" ] && [ ! -s "$r1_lock" ] && [ ! -s "$SYG_GATE_LOCK_FILE" ]; then
  ok "R2: holder record is cleared after release"
else
  bad "R2 record not cleared (r1_lock=[$(cat "$r1_lock" 2>/dev/null)] main=[$(cat "$SYG_GATE_LOCK_FILE" 2>/dev/null)])"
fi

# (R3) a holder record with a forged pidns prints unverified; a dead pid with matching ns prints stale record
r3a_lock=$t/r3a.lock
mkfifo "$t/r3a-fifo"
(
  exec 8>>"$r3a_lock"
  flock 8
  printf 'pid=99999\nstart=1\npidns=pid:[9999999999]\nsince=%s\nlabel=forged-ns\ncmd=sh\ndir=box\n' "$(date +%s)" >"$r3a_lock"
  : >"$t/r3a-held"
  read -r _ <"$t/r3a-fifo"
) &
r3a_h=$!; bg+=("$r3a_h")
r3a_ok=0
if wait_for exists "$t/r3a-held"; then
  SYG_GATE_LOCK_FILE=$r3a_lock SYG_GATE_LOCK_REPORT_S=1 "$GL" true 2>"$t/r3a.err" &
  r3a_w=$!; bg+=("$r3a_w")
  wait_for grep -q "holder:" "$t/r3a.err"
  echo go >"$t/r3a-fifo"
  wait "$r3a_h" 2>/dev/null
  wait "$r3a_w" 2>/dev/null
  grep -q "unverified" "$t/r3a.err" && r3a_ok=1
else
  echo go >"$t/r3a-fifo" 2>/dev/null
fi

r3b_lock=$t/r3b.lock
mkfifo "$t/r3b-fifo"
sh -c 'exit 0' &
dead_p=$!
wait "$dead_p" 2>/dev/null
my_ns=$(readlink /proc/self/ns/pid)
(
  exec 8>>"$r3b_lock"
  flock 8
  printf 'pid=%s\nstart=1\npidns=%s\nsince=%s\nlabel=dead-holder\ncmd=sh\ndir=box\n' "$dead_p" "$my_ns" "$(date +%s)" >"$r3b_lock"
  : >"$t/r3b-held"
  read -r _ <"$t/r3b-fifo"
) &
r3b_h=$!; bg+=("$r3b_h")
r3b_ok=0
if wait_for exists "$t/r3b-held"; then
  SYG_GATE_LOCK_FILE=$r3b_lock SYG_GATE_LOCK_REPORT_S=1 "$GL" true 2>"$t/r3b.err" &
  r3b_w=$!; bg+=("$r3b_w")
  wait_for grep -q "holder:" "$t/r3b.err"
  echo go >"$t/r3b-fifo"
  wait "$r3b_h" 2>/dev/null
  wait "$r3b_w" 2>/dev/null
  grep -q "stale record (pid $dead_p gone)" "$t/r3b.err" && r3b_ok=1
else
  echo go >"$t/r3b-fifo" 2>/dev/null
fi
if [ "$r3a_ok" = 1 ] && [ "$r3b_ok" = 1 ]; then
  ok "R3: forged pidns prints unverified; dead pid with matching ns prints stale record"
else
  bad "R3 (unverified=$r3a_ok err_a=[$(cat "$t/r3a.err" 2>/dev/null)] stale=$r3b_ok err_b=[$(cat "$t/r3b.err" 2>/dev/null)])"
fi

# (R4) control characters in a forged label are stripped
r4_lock=$t/r4.lock
mkfifo "$t/r4-fifo"
(
  exec 8>>"$r4_lock"
  flock 8
  printf 'pid=99999\nstart=1\npidns=pid:[9999999999]\nsince=%s\nlabel=clean\033\007\rname\ncmd=sh\ndir=box\n' "$(date +%s)" >"$r4_lock"
  : >"$t/r4-held"
  read -r _ <"$t/r4-fifo"
) &
r4_h=$!; bg+=("$r4_h")
if wait_for exists "$t/r4-held"; then
  SYG_GATE_LOCK_FILE=$r4_lock SYG_GATE_LOCK_REPORT_S=1 "$GL" true 2>"$t/r4.err" &
  r4_w=$!; bg+=("$r4_w")
  wait_for grep -q "holder:" "$t/r4.err"
  echo go >"$t/r4-fifo"
  wait "$r4_h" 2>/dev/null
  wait "$r4_w" 2>/dev/null
  r4_err=$(cat "$t/r4.err" 2>/dev/null)
  if [[ $r4_err == *"cleanname"* ]] && [[ $r4_err != *$'\033'* ]] && [[ $r4_err != *$'\007'* ]] && [[ $r4_err != *$'\r'* ]]; then
    ok "R4: control characters in a forged label are stripped"
  else
    bad "R4 control chars not stripped (err=[$r4_err])"
  fi
else
  bad "R4: holder never took lock"
  echo go >"$t/r4-fifo" 2>/dev/null
fi

# (R5) no record (plain flock holder): waiter prints no holder record fallback with age includes queue time,
# and no cap suffix even with SYG_GATE_LOCK_HOLD_CAP_S=1
r5_lock=$t/r5.lock
mkfifo "$t/r5-fifo"
( exec 8>"$r5_lock"; flock 8; : >"$t/r5-held"; read -r _ <"$t/r5-fifo" ) &
r5_h=$!; bg+=("$r5_h")
if wait_for exists "$t/r5-held"; then
  SYG_GATE_LOCK_FILE=$r5_lock SYG_GATE_LOCK_HOLD_CAP_S=1 SYG_GATE_LOCK_REPORT_S=1 \
    "$GL" true 2>"$t/r5.err" &
  r5_w=$!; bg+=("$r5_w")
  wait_for grep -q "still waiting" "$t/r5.err"
  echo go >"$t/r5-fifo"
  wait "$r5_h" 2>/dev/null
  wait "$r5_w" 2>/dev/null
  r5_err=$(cat "$t/r5.err" 2>/dev/null)
  if [[ $r5_err == *"no holder record (an older gate-lock?)"* ]] \
    && [[ $r5_err == *"holder or waiter; age includes queue time"* ]] \
    && [[ $r5_err == *"$r5_h "* ]] \
    && [[ $r5_err != *"past the hold cap"* ]]; then
    ok "R5: no holder record prints fallback with age includes queue time and no cap suffix"
  else
    bad "R5 fallback (h=$r5_h err=[$r5_err])"
  fi
  # The transient race itself is load-dependent and not deterministically probeable; this pins that walker errors stay suppressed when a race does fire, and the field verification is the deck-platform probe re-run without its filter.
  if [[ $r5_err != *"No such file or directory"* ]]; then
    ok "R5: open-fd fallback stderr contains no 'No such file or directory' walker error"
  else
    bad "R5 walker stderr leak (err=[$r5_err])"
  fi
else
  bad "R5: holder never took lock"
  echo go >"$t/r5-fifo" 2>/dev/null
fi

# (R6) verified holder past SYG_GATE_LOCK_HOLD_CAP_S=1 gets the cap suffix; with cap 0 there is none;
# holder is never signalled and is still running after the waiter's report
r6_lock=$t/r6.lock
mkfifo "$t/r6-fifo"
SYG_GATE_LOCK_FILE=$r6_lock SYG_GATE_LOCK_LABEL=cap-holder \
  "$GL" sh -c ': >"$1"; read -r _ <"$2"; : >"$3"' _ "$t/r6-held" "$t/r6-fifo" "$t/r6-clean-exit" &
r6_h=$!; bg+=("$r6_h")
if wait_for exists "$t/r6-held"; then
  SYG_GATE_LOCK_FILE=$r6_lock SYG_GATE_LOCK_HOLD_CAP_S=1 SYG_GATE_LOCK_REPORT_S=1 \
    "$GL" true 2>"$t/r6a.err" &
  r6_w1=$!; bg+=("$r6_w1")
  wait_for grep -q "past the hold cap (1s)" "$t/r6a.err"
  kill -0 "$r6_h" 2>/dev/null && r6_alive=1 || r6_alive=0
  SYG_GATE_LOCK_FILE=$r6_lock SYG_GATE_LOCK_HOLD_CAP_S=0 SYG_GATE_LOCK_REPORT_S=1 \
    "$GL" true 2>"$t/r6b.err" &
  r6_w2=$!; bg+=("$r6_w2")
  wait_for grep -q "still waiting" "$t/r6b.err"
  echo go >"$t/r6-fifo"
  wait "$r6_h" 2>/dev/null
  wait "$r6_w1" 2>/dev/null
  wait "$r6_w2" 2>/dev/null
  r6a_err=$(cat "$t/r6a.err" 2>/dev/null)
  r6b_err=$(cat "$t/r6b.err" 2>/dev/null)
  if [[ $r6a_err == *"; past the hold cap (1s)"* ]] \
    && [ "$r6_alive" = 1 ] && [ -e "$t/r6-clean-exit" ] \
    && [[ $r6b_err != *"past the hold cap"* ]]; then
    ok "R6: verified holder past SYG_GATE_LOCK_HOLD_CAP_S=1 gets cap suffix; cap 0 has none; holder never signalled"
  else
    bad "R6 hold cap (alive=$r6_alive clean=$([ -e "$t/r6-clean-exit" ] && echo 1 || echo 0) a=[$r6a_err] b=[$r6b_err])"
  fi
else
  bad "R6: holder never started"
  echo go >"$t/r6-fifo" 2>/dev/null
fi

# (R7) reporter exits when waiting gate-lock is killed with SIGKILL, and does not keep the lock:
# a third locker acquires once the holder releases
r7_lock=$t/r7.lock
mkfifo "$t/r7-fifo"
SYG_GATE_LOCK_FILE=$r7_lock "$GL" sh -c ': >"$1"; read -r _ <"$2"' _ "$t/r7-held" "$t/r7-fifo" &
r7_h=$!; bg+=("$r7_h")
if wait_for exists "$t/r7-held"; then
  SYG_GATE_LOCK_FILE=$r7_lock SYG_GATE_LOCK_REPORT_S=1 "$GL" true 2>"$t/r7.err" &
  r7_w=$!; bg+=("$r7_w")
  wait_for grep -q "still waiting" "$t/r7.err"
  r7_rep=''
  for pdir in /proc/[0-9]*; do
    cpid=${pdir#/proc/}
    IFS= read -r cstat 2>/dev/null <"$pdir/stat" || continue
    read -r -a cf <<<"${cstat##*\) }"
    if [ "${cf[1]:-}" = "$r7_w" ]; then
      IFS= read -r ccomm 2>/dev/null <"$pdir/comm" || ccomm=''
      [ "$ccomm" = flock ] || r7_rep=$cpid
    fi
  done
  kill -KILL "$r7_w" 2>/dev/null
  wait "$r7_w" 2>/dev/null
  rep_gone=0
  if [ -n "$r7_rep" ]; then
    wait_for sh -c '! kill -0 "$1" 2>/dev/null' _ "$r7_rep" && rep_gone=1
  fi
  echo go >"$t/r7-fifo"
  wait "$r7_h" 2>/dev/null
  timeout 20 env SYG_GATE_LOCK_FILE=$r7_lock "$GL" sh -c ': >"$1"' _ "$t/r7-third" 2>"$t/r7-third.err"
  r7_rc=$?
  if [ "$rep_gone" = 1 ] && [ "$r7_rc" = 0 ] && [ -e "$t/r7-third" ]; then
    ok "R7: reporter exits when waiting gate-lock is killed with SIGKILL; third locker acquires after release"
  else
    bad "R7 reporter SIGKILL (rep=$r7_rep rep_gone=$rep_gone third_rc=$r7_rc err=[$(cat "$t/r7-third.err" 2>/dev/null)])"
  fi
else
  bad "R7: holder never started"
  echo go >"$t/r7-fifo" 2>/dev/null
fi

# (R8) write_record sanitizes cmd= and dir= at write: running from a directory whose basename
# contains a newline produces exactly 7 key= lines and cmd/dir values with no control characters
r8_lock=$t/r8.lock
r8_dir=$t/$'dir\nforged=1\r\007box'
r8_cmd=$'cmd\ninj=1\r\033run'
mkdir -p "$r8_dir"
mkfifo "$t/r8-fifo"
cat >"$r8_dir/$r8_cmd" <<'EOF'
#!/usr/bin/env bash
: >"$1"
read -r _ <"$2"
EOF
chmod +x "$r8_dir/$r8_cmd"
(
  cd "$r8_dir" && SYG_GATE_LOCK_FILE=$r8_lock SYG_GATE_LOCK_LABEL=r8-holder \
    "$GL" "./$r8_cmd" "$t/r8-held" "$t/r8-fifo"
) &
r8_h=$!; bg+=("$r8_h")
if wait_for exists "$t/r8-held"; then
  cp "$r8_lock" "$t/r8.rec"
  echo go >"$t/r8-fifo"
  wait "$r8_h"; r8_rc=$?
  mapfile -t r8_lines <"$t/r8.rec"
  r8_keys=$(printf '%s\n' "${r8_lines[@]}" | sed 's/=.*//')
  r8_cmd_v=$(sed -n 's/^cmd=//p' "$t/r8.rec")
  r8_dir_v=$(sed -n 's/^dir=//p' "$t/r8.rec")
  if [ "$r8_rc" = 0 ] && [ "${#r8_lines[@]}" = 7 ] \
    && [ "$r8_keys" = $'pid\nstart\npidns\nsince\nlabel\ncmd\ndir' ] \
    && [ "$r8_cmd_v" = "cmdinj=1run" ] && [ "$r8_dir_v" = "dirforged=1box" ] \
    && [[ $r8_cmd_v != *[[:cntrl:]]* ]] && [[ $r8_dir_v != *[[:cntrl:]]* ]]; then
    ok "R8: write_record sanitizes cmd= and dir= at write (7 key= lines, no control characters)"
  else
    bad "R8 sanitize write (rc=$r8_rc n=${#r8_lines[@]} keys=[$r8_keys] cmd=[$r8_cmd_v] dir=[$r8_dir_v] rec=[$(cat "$t/r8.rec" 2>/dev/null)])"
  fi
else
  bad "R8: holder never started"
  echo go >"$t/r8-fifo" 2>/dev/null
fi

# (L1) --light-path follows the suffix rule for .lock and non-.lock names and takes no lock
lp1=$(SYG_GATE_LOCK_FILE=$t/a.lock "$GL" --light-path); lp1_rc=$?
lp2=$(SYG_GATE_LOCK_FILE=$t/b.gate "$GL" --light-path); lp2_rc=$?
if [ "$lp1_rc" = 0 ] && [ "$lp1" = "$t/a.light.lock" ] && [ ! -e "$t/a.lock" ] && [ ! -e "$t/a.light.lock" ] \
  && [ "$lp2_rc" = 0 ] && [ "$lp2" = "$t/b.gate.light" ]; then
  ok "L1: --light-path follows the suffix rule (.lock -> .light.lock, else .light) without touching lock files"
else
  bad "L1 --light-path (lp1=$lp1/$lp1_rc lp2=$lp2/$lp2_rc)"
fi

# (L2) a light gate and a held HEAVY lock: the light gate runs without waiting
l2_lock=$t/l2.lock
printf 'MemTotal: 8388608 kB\nMemAvailable: 2621440 kB\n' >"$t/meminfo-l2"
mkfifo "$t/l2-fifo"
SYG_GATE_LOCK_FILE=$l2_lock "$GL" sh -c ': >"$1"; read -r _ <"$2"' _ "$t/l2-held" "$t/l2-fifo" &
l2_h=$!; bg+=("$l2_h")
if wait_for exists "$t/l2-held"; then
  SYG_GATE_LOCK_FILE=$l2_lock SYG_GATE_LOCK_CLASS=light SYG_GATE_LOCK_PEAK_MB=256 \
    SYG_MEM_GATE_MEMINFO=$t/meminfo-l2 SYG_MEM_GATE_MIN_MB=0 \
    "$GL" sh -c ': >"$1"' _ "$t/l2-ran" 2>"$t/l2.err" &
  l2_p=$!; bg+=("$l2_p")
  l2_ok=0
  wait_for exists "$t/l2-ran" && l2_ok=1
  echo go >"$t/l2-fifo"
  wait "$l2_h" 2>/dev/null
  wait "$l2_p"; l2_rc=$?
  if [ "$l2_ok" = 1 ] && [ "$l2_rc" = 0 ] && [ ! -s "$t/l2.err" ]; then
    ok "L2: light gate runs without waiting while the heavy lock is held"
  else
    bad "L2 light vs heavy (ok=$l2_ok rc=$l2_rc err=[$(cat "$t/l2.err" 2>/dev/null)])"
  fi
else
  bad "L2: heavy holder never started"
  echo go >"$t/l2-fifo" 2>/dev/null
fi

# (L3) two light gates serialize
l3_lock=$t/l3.lock
printf 'MemTotal: 8388608 kB\nMemAvailable: 2621440 kB\n' >"$t/meminfo-l3"
mkfifo "$t/l3-fifo"
SYG_GATE_LOCK_FILE=$l3_lock SYG_GATE_LOCK_CLASS=light SYG_GATE_LOCK_PEAK_MB=256 SYG_GATE_LOCK_LABEL=light-one \
  SYG_MEM_GATE_MEMINFO=$t/meminfo-l3 SYG_MEM_GATE_MIN_MB=0 \
  "$GL" sh -c ': >"$1"; read -r _ <"$2"' _ "$t/l3-held" "$t/l3-fifo" &
l3_h=$!; bg+=("$l3_h")
if wait_for exists "$t/l3-held"; then
  SYG_GATE_LOCK_FILE=$l3_lock SYG_GATE_LOCK_CLASS=light SYG_GATE_LOCK_PEAK_MB=256 \
    SYG_MEM_GATE_MEMINFO=$t/meminfo-l3 SYG_MEM_GATE_MIN_MB=0 \
    "$GL" sh -c ': >"$1"' _ "$t/l3-ran" 2>"$t/l3.err" &
  l3_w=$!; bg+=("$l3_w")
  l3_waited=0
  wait_for grep -q "waiting for $t/l3.light.lock" "$t/l3.err" && l3_waited=1
  [ -e "$t/l3-ran" ] && l3_early=1 || l3_early=0
  echo go >"$t/l3-fifo"
  wait "$l3_h" 2>/dev/null
  wait "$l3_w"; l3_rc=$?
  if [ "$l3_waited" = 1 ] && [ "$l3_early" = 0 ] && [ "$l3_rc" = 0 ] && [ -e "$t/l3-ran" ]; then
    ok "L3: two light gates serialize on the derived light lock"
  else
    bad "L3 light serialization (waited=$l3_waited early=$l3_early rc=$l3_rc err=[$(cat "$t/l3.err" 2>/dev/null)])"
  fi
else
  bad "L3: first light gate never started"
  echo go >"$t/l3-fifo" 2>/dev/null
fi

# (L4) light gate uses the floor + peak bar: a fixture at floor+peak-1 (2559 MB = 2048 + 512 - 1)
# waits and prints "need 2560 MB (floor 2048 + peak 512)", and floor+peak (2560 MB) runs;
# with SYG_GATE_LOCK_MEM_WAIT_S=1 and low memory it exits 125 (and unreadable meminfo exits 125)
l4_lock=$t/l4.lock
printf 'MemTotal: 8388608 kB\nMemAvailable: 2620416 kB\n' >"$t/meminfo-l4"
timeout 20 env SYG_GATE_LOCK_FILE=$l4_lock SYG_GATE_LOCK_CLASS=light SYG_GATE_LOCK_PEAK_MB=512 \
  SYG_MEM_GATE_MEMINFO=$t/meminfo-l4 SYG_MEM_GATE_MIN_MB=2048 SYG_GATE_LOCK_MEM_POLL_S=1 \
  "$GL" sh -c ': >"$1"' _ "$t/l4-ran" 2>"$t/l4.err" &
l4_p=$!; bg+=("$l4_p")
l4_waited=0
wait_for grep -qF "gate-lock: waiting for memory (2559 MB available, need 2560 MB (floor 2048 + peak 512))" "$t/l4.err" && l4_waited=1
[ -e "$t/l4-ran" ] && l4_early=1 || l4_early=0
printf 'MemTotal: 8388608 kB\nMemAvailable: 2621440 kB\n' >"$t/meminfo-l4.high"
mv "$t/meminfo-l4.high" "$t/meminfo-l4"
wait "$l4_p"; l4_rc=$?

printf 'MemTotal: 8388608 kB\nMemAvailable: 2620416 kB\n' >"$t/meminfo-l4-low"
l4_to_out=$(timeout 20 env SYG_GATE_LOCK_FILE=$l4_lock SYG_GATE_LOCK_CLASS=light SYG_GATE_LOCK_PEAK_MB=512 \
  SYG_MEM_GATE_MEMINFO=$t/meminfo-l4-low SYG_MEM_GATE_MIN_MB=2048 SYG_GATE_LOCK_MEM_WAIT_S=1 SYG_GATE_LOCK_MEM_POLL_S=1 \
  "$GL" sh -c ': >"$1"' _ "$t/l4-to-ran" 2>&1)
l4_to_rc=$?

l4_bad_out=$(timeout 20 env SYG_GATE_LOCK_FILE=$l4_lock SYG_GATE_LOCK_CLASS=light SYG_GATE_LOCK_PEAK_MB=512 \
  SYG_MEM_GATE_MEMINFO=$t/no-such-meminfo \
  "$GL" sh -c ': >"$1"' _ "$t/l4-bad-ran" 2>&1)
l4_bad_rc=$?

if [ "$l4_waited" = 1 ] && [ "$l4_early" = 0 ] && [ "$l4_rc" = 0 ] && [ -e "$t/l4-ran" ] \
  && [ "$l4_to_rc" = 125 ] && [[ $l4_to_out == *"gate-lock: memory stayed below 2560 MB for 1 s; not running"* ]] && [ ! -e "$t/l4-to-ran" ] \
  && [ "$l4_bad_rc" = 125 ] && [ ! -e "$t/l4-bad-ran" ]; then
  ok "L4: light gate waits at floor+peak-1 (need 2560 MB (floor 2048 + peak 512)) and runs at floor+peak; exits 125 on timeout or unreadable meminfo"
else
  bad "L4 memory wait (waited=$l4_waited early=$l4_early rc=$l4_rc err=[$(cat "$t/l4.err" 2>/dev/null)] to_rc=$l4_to_rc to_out=[$l4_to_out] bad_rc=$l4_bad_rc bad_out=[$l4_bad_out])"
fi

# (L5) bad SYG_GATE_LOCK_CLASS exits 125; bad SYG_GATE_LOCK_MEM_WAIT_S on light class exits 125 before opening/taking the lock
l5_out=$(SYG_GATE_LOCK_CLASS=bogus "$GL" true 2>&1); l5_rc=$?
l5_lock=$t/l5.lock
l5_light=$t/l5.light.lock
mkfifo "$t/l5-fifo"
( exec 8>>"$l5_light"; flock 8; : >"$t/l5-held"; read -r _ <"$t/l5-fifo" ) &
l5_h=$!; bg+=("$l5_h")
l5_mw_rc=0 l5_mw_out=''
if wait_for exists "$t/l5-held"; then
  l5_mw_out=$(timeout 5 env SYG_GATE_LOCK_FILE=$l5_lock SYG_GATE_LOCK_CLASS=light SYG_GATE_LOCK_PEAK_MB=256 \
    SYG_GATE_LOCK_MEM_WAIT_S=bad "$GL" true 2>&1)
  l5_mw_rc=$?
fi
echo go >"$t/l5-fifo" 2>/dev/null
wait "$l5_h" 2>/dev/null
if [ "$l5_rc" = 125 ] && [[ $l5_out == *SYG_GATE_LOCK_CLASS* ]] \
  && [ "$l5_mw_rc" = 125 ] && [[ $l5_mw_out == *SYG_GATE_LOCK_MEM_WAIT_S* ]] && [[ $l5_mw_out != *"waiting for"* ]]; then
  ok "L5: invalid SYG_GATE_LOCK_CLASS and bad SYG_GATE_LOCK_MEM_WAIT_S exit 125 at once without waiting on a held light lock"
else
  bad "L5 invalid class/mem_wait (rc=$l5_rc out=[$l5_out] mw_rc=$l5_mw_rc mw_out=[$l5_mw_out])"
fi

# (L6) child does not see SYG_GATE_LOCK_CLASS, SYG_GATE_LOCK_LABEL or SYG_GATE_LOCK_PEAK_MB
printf 'MemTotal: 8388608 kB\nMemAvailable: 2621440 kB\n' >"$t/meminfo-l6"
l6_out=$(SYG_GATE_LOCK_CLASS=light SYG_GATE_LOCK_LABEL=my-label SYG_GATE_LOCK_PEAK_MB=512 \
  SYG_MEM_GATE_MEMINFO=$t/meminfo-l6 SYG_MEM_GATE_MIN_MB=0 \
  "$GL" sh -c 'printf "class=%s label=%s peak=%s\n" "${SYG_GATE_LOCK_CLASS-unset}" "${SYG_GATE_LOCK_LABEL-unset}" "${SYG_GATE_LOCK_PEAK_MB-unset}"')
if [ "$l6_out" = "class=unset label=unset peak=unset" ]; then
  ok "L6: child does not inherit SYG_GATE_LOCK_CLASS, SYG_GATE_LOCK_LABEL or SYG_GATE_LOCK_PEAK_MB"
else
  bad "L6 child env ([$l6_out])"
fi

# (L7) light without a peak (unset, empty or non-integer) runs on the heavy lock: waits behind a held heavy lock and prints the note
l7_lock=$t/l7.lock
mkfifo "$t/l7-fifo"
SYG_GATE_LOCK_FILE=$l7_lock "$GL" sh -c ': >"$1"; read -r _ <"$2"' _ "$t/l7-held" "$t/l7-fifo" &
l7_h=$!; bg+=("$l7_h")
if wait_for exists "$t/l7-held"; then
  env -u SYG_GATE_LOCK_PEAK_MB SYG_GATE_LOCK_FILE=$l7_lock SYG_GATE_LOCK_CLASS=light \
    "$GL" sh -c ': >"$1"' _ "$t/l7-ran" 2>"$t/l7.err" &
  l7_w=$!; bg+=("$l7_w")
  l7_waited=0
  wait_for grep -q "waiting for $l7_lock" "$t/l7.err" && l7_waited=1
  [ -e "$t/l7-ran" ] && l7_early=1 || l7_early=0
  echo go >"$t/l7-fifo"
  wait "$l7_h" 2>/dev/null
  wait "$l7_w"; l7_rc=$?
  l7_bad_err=$(SYG_GATE_LOCK_FILE=$l7_lock SYG_GATE_LOCK_CLASS=light SYG_GATE_LOCK_PEAK_MB=notanint "$GL" true 2>&1)
  l7_err=$(cat "$t/l7.err" 2>/dev/null)
  if [ "$l7_waited" = 1 ] && [ "$l7_early" = 0 ] && [ "$l7_rc" = 0 ] && [ -e "$t/l7-ran" ] \
    && [[ $l7_err == *"gate-lock: light needs a recorded peak (SYG_GATE_LOCK_PEAK_MB); running as heavy"* ]] \
    && [[ $l7_bad_err == *"gate-lock: light needs a recorded peak (SYG_GATE_LOCK_PEAK_MB); running as heavy"* ]]; then
    ok "L7: light without a recorded peak prints note and runs as heavy (waits behind held heavy lock)"
  else
    bad "L7 light without peak (waited=$l7_waited early=$l7_early rc=$l7_rc err=[$l7_err] bad_err=[$l7_bad_err])"
  fi
else
  bad "L7: heavy holder never started"
  echo go >"$t/l7-fifo" 2>/dev/null
fi

# (L8) signal during the light memory wait (forced with min 0 + peak 512 on a low-MemAvailable fixture):
# TERM exits 143 and INT exits 130, clearing the lock record and never running the command.
# HUP shares the same on_sig / got code path (exits 129).
l8_lock=$t/l8.lock
l8_light=$t/l8.light.lock
printf 'MemTotal: 8388608 kB\nMemAvailable: 102400 kB\n' >"$t/meminfo-l8"
SYG_GATE_LOCK_FILE=$l8_lock SYG_GATE_LOCK_CLASS=light SYG_GATE_LOCK_PEAK_MB=512 \
  SYG_MEM_GATE_MEMINFO=$t/meminfo-l8 SYG_MEM_GATE_MIN_MB=0 \
  SYG_GATE_LOCK_MEM_WAIT_S=20 SYG_GATE_LOCK_MEM_POLL_S=1 \
  "$GL" sh -c ': >"$1"' _ "$t/l8-term-ran" 2>"$t/l8-term.err" &
l8_term_p=$!; bg+=("$l8_term_p")
l8_term_waited=0
if wait_for grep -q "waiting for memory" "$t/l8-term.err"; then
  l8_term_waited=1
  kill -TERM "$l8_term_p" 2>/dev/null
else
  kill -KILL "$l8_term_p" 2>/dev/null
fi
wait "$l8_term_p" 2>/dev/null; l8_term_rc=$?
l8_term_empty=0
[ -e "$l8_light" ] && [ ! -s "$l8_light" ] && l8_term_empty=1

env --default-signal=INT SYG_GATE_LOCK_FILE=$l8_lock SYG_GATE_LOCK_CLASS=light SYG_GATE_LOCK_PEAK_MB=512 \
  SYG_MEM_GATE_MEMINFO=$t/meminfo-l8 SYG_MEM_GATE_MIN_MB=0 \
  SYG_GATE_LOCK_MEM_WAIT_S=20 SYG_GATE_LOCK_MEM_POLL_S=1 \
  "$GL" sh -c ': >"$1"' _ "$t/l8-int-ran" 2>"$t/l8-int.err" &
l8_int_p=$!; bg+=("$l8_int_p")
l8_int_waited=0
if wait_for grep -q "waiting for memory" "$t/l8-int.err"; then
  l8_int_waited=1
  kill -INT "$l8_int_p" 2>/dev/null
else
  kill -KILL "$l8_int_p" 2>/dev/null
fi
wait "$l8_int_p" 2>/dev/null; l8_int_rc=$?
l8_int_empty=0
[ -e "$l8_light" ] && [ ! -s "$l8_light" ] && l8_int_empty=1

if [ "$l8_term_waited" = 1 ] && [ "$l8_term_rc" = 143 ] && [ "$l8_term_empty" = 1 ] && [ ! -e "$t/l8-term-ran" ] \
  && [ "$l8_int_waited" = 1 ] && [ "$l8_int_rc" = 130 ] && [ "$l8_int_empty" = 1 ] && [ ! -e "$t/l8-int-ran" ]; then
  ok "L8: TERM (143) and INT (130) during light memory wait clear the lock record and do not run the command"
else
  bad "L8 signal in mem wait (term: waited=$l8_term_waited rc=$l8_term_rc empty=$l8_term_empty ran=$([ -e "$t/l8-term-ran" ] && echo 1 || echo 0) err=[$(cat "$t/l8-term.err" 2>/dev/null)]; int: waited=$l8_int_waited rc=$l8_int_rc empty=$l8_int_empty ran=$([ -e "$t/l8-int-ran" ] && echo 1 || echo 0) err=[$(cat "$t/l8-int.err" 2>/dev/null)])"
fi

exit "$fail"
