#!/usr/bin/env bash
# Probe for plugins/seyag/bin/gate-lock: usage and exit codes, a busy lock waits (and the command
# does not run until it frees), the command never inherits the lock fd, TERM, INT and HUP are
# forwarded (as TERM) and waited out so the lock outlives the signal until the command is gone, the
# command reads gate-lock's own stdin, and the old unprefixed GATE_LOCK_FILE does not override
# SYG_GATE_LOCK_FILE.
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

exit "$fail"
