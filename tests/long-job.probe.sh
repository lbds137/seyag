#!/usr/bin/env bash
# Hermetic probe for plugins/seyag/bin/long-job: usage errors (StandardInput* refused by prefix),
# unreadable-memory exit 6, owner recording (CLAUDE_JOB_DIR or cwd basename), state-dir
# permissions, SYG_LONG_JOB_STATE_DIR, SYG_LONG_JOB_UNIT_PREFIX, SYG_LONG_JOB_PARENT_CMD and
# SYG_LONG_JOB_CMD chain refusals/warnings, the SYG_LONG_JOB_AS marker display name (message
# prefix, hints, ended sentinel; empty, invalid or unset keeps long-job), --slice and
# -p/--property forwarding (CPUWeight/StartupCPUWeight/CPUQuota dropped under --heavy), --wait-mem
# gate forwarding, --heavy (gate lock, memory and load waits, nested lock), missing lib/owner.sh,
# and real transient user units when a user systemd manager is available (explicit SKIP count
# otherwise).
# Usage: tests/long-job.probe.sh   (from anywhere)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LJ="$REPO/plugins/seyag/bin/long-job"
MG="$REPO/plugins/seyag/bin/mem-gate"
[ -x "$LJ" ] || { echo "FAIL  $LJ is not executable (chmod +x it)"; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/long-job-probe.XXXXXX")
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; }

unset SYG_LONG_JOB_STATE_DIR SYG_LONG_JOB_UNIT_PREFIX SYG_LONG_JOB_PARENT_CMD SYG_LONG_JOB_CMD SYG_LONG_JOB_AS
unset SYG_LONG_JOB_LOAD_GATE SYG_GATE_LOCK_FILE SYG_LOAD_GATE_1M SYG_LOAD_GATE_5M
unset SYG_MEM_GATE_MIN_MB SYG_MEM_GATE_MEMINFO
export XDG_STATE_HOME="$tmp/state"
export XDG_CONFIG_HOME="$tmp/cfg"
export CLAUDE_PROJECT_DIR="$tmp/proj"

ORIG_PATH="$PATH"
mkdir -p "$tmp/stub" "$tmp/stub-rec" "$tmp/work/proj-y"
printf '#!/bin/sh\nexit 0\n' >"$tmp/stub/systemd-run"; chmod +x "$tmp/stub/systemd-run"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" >>"%s/systemctl-argv"\nexit 0\n' "$tmp" >"$tmp/stub/systemctl"; chmod +x "$tmp/stub/systemctl"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" >"%s/argv"\nexit 0\n' "$tmp" >"$tmp/stub-rec/systemd-run"; chmod +x "$tmp/stub-rec/systemd-run"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" >>"%s/systemctl-argv"\nexit 0\n' "$tmp" >"$tmp/stub-rec/systemctl"; chmod +x "$tmp/stub-rec/systemctl"
export PATH="$tmp/stub:$ORIG_PATH"

# --- long-job usage errors (no systemd needed)
while IFS='|' read -r args want_msg; do
  # shellcheck disable=SC2086 # word splitting is intentional for multi-word cases
  out=$(timeout 5 "$LJ" $args 2>&1); rc=$?
  [ "$rc" = 2 ] && grep -qF -- "$want_msg" <<<"$out" \
    && ok "long-job '$args' exits 2 with '$want_msg'" \
    || bad "long-job '$args' exits 2 with '$want_msg' (got $rc: $out)"
done <<'EOF'
|needs a subcommand
run|needs a job NAME
run bad/name -- true|NAME must start with a letter or digit and hold only letters
run -- make|NAME must start with a letter or digit and hold only letters, digits, '.', '_' and '-': '--'
status ..|NAME must start with a letter or digit and hold only letters, digits, '.', '_' and '-': '..'
run x|run needs -- before the command
run x -- |run needs a command after --
run x --bogus -- true|unknown run option --bogus
run x --wait-mem 0 -- true|--wait-mem needs at least 1 second
run x --min-mb 0 --wait-mem 5 -- true|--wait-mem needs the memory gate; drop --min-mb 0
run x --slice|--slice needs a value
run x --slice bad/s -- true|--slice needs a slice name
run x -p nokey -- true|-p needs KEY=VALUE
run x -p StandardOutput=null -- true|is set by long-job
run x --property StandardError=null -- true|is set by long-job
run x -p Slice=low.slice -- true|use --slice NAME
wat|unknown subcommand 'wat'
EOF
timeout 5 "$LJ" wait nosuch >/dev/null 2>&1; [ $? = 1 ] && ok "long-job wait on an unknown job exits 1" || bad "long-job wait unknown"

# A mem-gate that can't read memory exits 6, distinct from a usage error, and starts nothing.
printf 'MemTotal: 1 kB\n' >"$tmp/meminfo-bad"
out=$(timeout 5 env SYG_MEM_GATE_MEMINFO="$tmp/meminfo-bad" "$LJ" run nomem -- true 2>&1); rc=$?
[ "$rc" = 6 ] && grep -q "mem-gate could not read memory" <<<"$out" && [ ! -e "$XDG_STATE_HOME/long-job/nomem.cmd" ] \
  && ok "run exits 6 naming mem-gate when memory is unreadable, nothing recorded" || bad "run unreadable memory (rc $rc: $out)"

# --- long-job owner: CLAUDE_JOB_DIR's basename, else the cwd's, is recorded at run and shown by status.
# A stub systemd-run takes the start path without a user manager; the owner is written before it runs.
(cd "$tmp/work/proj-y" && timeout 5 env -u CLAUDE_JOB_DIR PATH="$tmp/stub:$PATH" "$LJ" run own-cwd --min-mb 0 -- true >/dev/null 2>&1)
out=$(timeout 5 "$LJ" status own-cwd)
case "$out" in *"[owner: proj-y]"*) ok "status shows the cwd basename as owner" ;; *) bad "status should show the cwd basename as owner: $out" ;; esac
# Job command lines can carry tokens: the state dir is owner-only and long-job's own files are 600,
# also when the dir already existed group/other-readable.
modes=$(stat -c %a "$XDG_STATE_HOME/long-job" "$XDG_STATE_HOME/long-job/own-cwd.cmd" "$XDG_STATE_HOME/long-job/own-cwd.owner" "$XDG_STATE_HOME/long-job/own-cwd.log" | tr '\n' ' ')
[ "$modes" = "700 600 600 600 " ] && ok "run creates an owner-only state dir and 600 cmd/owner/log files" || bad "state modes: $modes"
chmod 755 "$XDG_STATE_HOME/long-job"
(timeout 5 env PATH="$tmp/stub:$PATH" "$LJ" run own-mode --min-mb 0 -- true >/dev/null 2>&1)
modes=$(stat -c %a "$XDG_STATE_HOME/long-job" "$XDG_STATE_HOME/long-job/own-mode.cmd" | tr '\n' ' ')
[ "$modes" = "700 600 " ] && ok "run tightens an existing 755 state dir to 700" || bad "existing-dir modes: $modes"
(timeout 5 env CLAUDE_JOB_DIR="$tmp/jobs/abc123" PATH="$tmp/stub:$PATH" "$LJ" run own-job --min-mb 0 -- true >/dev/null 2>&1)
out=$(timeout 5 "$LJ" status own-job)
case "$out" in *"[owner: abc123]"*) ok "status shows the CLAUDE_JOB_DIR basename as owner" ;; *) bad "status should show the CLAUDE_JOB_DIR basename as owner: $out" ;; esac
out=$(timeout 5 env -u SYG_LONG_JOB_PARENT_CMD PATH="$tmp/stub:$PATH" "$LJ" run own-hint --min-mb 0 -- true 2>&1)
[ "$(tail -n 1 <<<"$out")" = 'long-job: to be woken when it ends, run "long-job wait own-hint" with Bash run_in_background; on the wake, a last line "long-job: ended: …" is the result, anything else means run "long-job wait own-hint --poll" and follow its last line (see --help)' ] \
  && ok "run's last line is the background-waiter recipe" || bad "run hint ($out)"
# systemctl itself failing (empty ActiveState) is not an end: --poll says unknown, a blocking wait keeps waiting.
mkdir -p "$tmp/stub-sysctl-fail"; printf '#!/bin/sh\nexit 1\n' >"$tmp/stub-sysctl-fail/systemctl"; chmod +x "$tmp/stub-sysctl-fail/systemctl"
out=$(timeout 5 env PATH="$tmp/stub-sysctl-fail:$PATH" "$LJ" wait own-cwd --poll --owner "" 2>&1); rc=$?
[ "$rc" = 4 ] && [ "$(tail -n 1 <<<"$out")" = "long-job: state unknown: systemctl show failed for own-cwd; check again shortly (not an end)" ] && ! grep -q "ended" <<<"$out" \
  && ok "wait --poll with systemctl failing says unknown, exit 4, no ended line" || bad "poll unknown state (rc $rc: $out)"
out=$(timeout 10 env PATH="$tmp/stub-sysctl-fail:$PATH" "$LJ" wait own-cwd --interval 1 --timeout 2 --owner "" 2>&1); rc=$?
[ "$rc" = 4 ] && ! grep -q "^long-job: ended" <<<"$out" \
  && ok "a blocking wait with systemctl failing keeps waiting to its timeout, no ended line" || bad "blocking wait unknown state (rc $rc: $out)"
out=$(timeout 5 "$LJ" cmd own-cwd); rc=$?
[ "$rc" = 0 ] && [ "$out" = "$(cat "$XDG_STATE_HOME/long-job/own-cwd.cmd")" ] && [ "$out" = "true " ] \
  && ok "long-job cmd prints the recorded command line verbatim" || bad "long-job cmd own-cwd (rc $rc: [$out])"
out=$(timeout 5 "$LJ" cmd nosuch 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q "no job named nosuch" <<<"$out" && ok "long-job cmd on an unknown job exits 1" || bad "long-job cmd unknown (rc $rc: $out)"
# rc: the recorded exit code alone; no exit record (the stub systemd-run never ran the job) is exit 4, no output.
out=$(timeout 5 "$LJ" rc own-cwd 2>&1); rc=$?
[ "$rc" = 4 ] && [ -z "$out" ] && ok "long-job rc with no exit record exits 4 and prints nothing" || bad "long-job rc no record (rc $rc: [$out])"
echo "5 $(date +%s)" >"$XDG_STATE_HOME/long-job/own-cwd.exit"  # the producer's shape: RC EPOCH
out=$(timeout 5 "$LJ" rc own-cwd 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$out" = 5 ] && ok "long-job rc prints the recorded exit code alone" || bad "long-job rc recorded (rc $rc: [$out])"
rm -f -- "$XDG_STATE_HOME/long-job/own-cwd.exit"
out=$(timeout 5 "$LJ" rc nosuch 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q "no job named nosuch" <<<"$out" && ok "long-job rc on an unknown job exits 1" || bad "long-job rc unknown (rc $rc: $out)"

# --- long-job chain and env check
out=$(timeout 5 env SYG_LONG_JOB_PARENT_CMD='long-job run chain-refuse --min-mb 0 -- true && echo after' PATH="$tmp/stub:$PATH" "$LJ" run chain-refuse --min-mb 0 -- true 2>&1); rc=$?
[ "$rc" = 2 ] && grep -q "long-job: refusing:" <<<"$out" && [ ! -e "$XDG_STATE_HOME/long-job/chain-refuse.cmd" ] \
  && ok "run refuses && tail via SYG_LONG_JOB_PARENT_CMD with exit 2 and records nothing" || bad "run chain-refuse (rc $rc: $out)"
err=$(timeout 5 env SYG_LONG_JOB_PARENT_CMD='CLAUDE_X=1 long-job run chain-warn --min-mb 0 -- true || echo fallback' PATH="$tmp/stub:$PATH" "$LJ" run chain-warn --min-mb 0 -- true 2>&1 >/dev/null); rc=$?
[ "$rc" = 0 ] && grep -q "long-job: warning: '|| …'" <<<"$err" && grep -q "long-job: warning: CLAUDE_X" <<<"$err" && [ -e "$XDG_STATE_HOME/long-job/chain-warn.cmd" ] \
  && ok "run warns on stderr for || and CLAUDE_ prefix and still starts" || bad "run chain-warn (rc $rc: $err)"
out=$(timeout 5 env -u SYG_LONG_JOB_PARENT_CMD PATH="$tmp/stub:$PATH" bash -c "\"$LJ\" run chain-real --min-mb 0 -- true && echo TAIL" 2>&1); rc=$?
[ "$rc" = 2 ] && grep -q "long-job: refusing:" <<<"$out" && ! grep -q "TAIL" <<<"$out" && [ ! -e "$XDG_STATE_HOME/long-job/chain-real.cmd" ] \
  && ok "real bash -c with && tail exits 2 from /proc/PPID/cmdline and skips TAIL" || bad "run chain-real (rc $rc: $out)"
out=$(timeout 5 env -u SYG_LONG_JOB_PARENT_CMD PATH="$tmp/stub:$PATH" bash -c -l "\"$LJ\" run chain-real-l --min-mb 0 -- true && echo TAIL" 2>&1); rc=$?
[ "$rc" = 2 ] && grep -q "long-job: refusing:" <<<"$out" && ! grep -q "TAIL" <<<"$out" && [ ! -e "$XDG_STATE_HOME/long-job/chain-real-l.cmd" ] \
  && ok "real bash -c -l with && tail skips -l in /proc/PPID/cmdline, exits 2 and skips TAIL" || bad "run chain-real-l (rc $rc: $out)"

# --- long-job state dir, unit prefix, recorded unit, config, owner.sh
# SYG_LONG_JOB_STATE_DIR=$tmp/sd puts NAME.cmd and NAME.owner under $tmp/sd, and status NAME finds it there.
timeout 5 env SYG_LONG_JOB_STATE_DIR="$tmp/sd" PATH="$tmp/stub:$PATH" "$LJ" run sd-job --min-mb 0 -- true >/dev/null 2>&1; rc=$?
out=$(timeout 5 env SYG_LONG_JOB_STATE_DIR="$tmp/sd" "$LJ" status sd-job 2>&1); rc2=$?
[ "$rc" = 0 ] && [ -s "$tmp/sd/sd-job.cmd" ] && [ -s "$tmp/sd/sd-job.owner" ] \
  && [ "$rc2" = 0 ] && [[ $out == "sd-job:"* ]] \
  && ok "SYG_LONG_JOB_STATE_DIR puts NAME.cmd and NAME.owner under custom dir and status finds it" \
  || bad "SYG_LONG_JOB_STATE_DIR (rc=$rc/$rc2, out=$out)"

# Existing SYG_LONG_JOB_STATE_DIR keeps its mode (755); a new state dir under it is created 700; files inside are 600.
mkdir -p "$tmp/sd-keep"
chmod 755 "$tmp/sd-keep"
timeout 5 env SYG_LONG_JOB_STATE_DIR="$tmp/sd-keep" PATH="$tmp/stub:$PATH" "$LJ" run keep-job --min-mb 0 -- true >/dev/null 2>&1; rc=$?
timeout 5 env SYG_LONG_JOB_STATE_DIR="$tmp/sd-keep/new-sub" PATH="$tmp/stub:$PATH" "$LJ" run sub-job --min-mb 0 -- true >/dev/null 2>&1; rc2=$?
modes=$(stat -c %a "$tmp/sd-keep" "$tmp/sd-keep/keep-job.cmd" "$tmp/sd-keep/new-sub" "$tmp/sd-keep/new-sub/sub-job.cmd" 2>/dev/null | tr '\n' ' ')
[ "$rc" = 0 ] && [ "$rc2" = 0 ] && [ "$modes" = "755 600 700 600 " ] \
  && ok "existing SYG_LONG_JOB_STATE_DIR keeps 755 while a new dir under it is created 700 (files 600)" \
  || bad "SYG_LONG_JOB_STATE_DIR chmod ownership (rc=$rc/$rc2, modes=[$modes])"

# Per-NAME start lock: holding flock on $sd/x.lock makes run x exit 2 with the lock message and write no NAME.cmd.
sd="$tmp/sd-lock"
mkdir -p "$sd"
( flock 9; sleep 3 ) 9>"$sd/x.lock" &
lpid=$!
for _ in $(seq 20); do flock -n "$sd/x.lock" true 2>/dev/null || break; sleep 0.05; done
out=$(timeout 5 env SYG_LONG_JOB_STATE_DIR="$sd" PATH="$tmp/stub:$PATH" "$LJ" run x --min-mb 0 -- true 2>&1); rc=$?
wait "$lpid" 2>/dev/null
[ "$rc" = 2 ] && grep -qF "long-job: x is being started by another long-job run" <<<"$out" && [ ! -e "$sd/x.cmd" ] \
  && ok "run exits 2 when NAME.lock is held by another start and writes no NAME.cmd" \
  || bad "same-NAME start lock (rc=$rc: $out)"

# SYG_LONG_JOB_UNIT_PREFIX=pfx: stub systemd-run records --unit=pfx-NAME.service and stub systemctl calls name pfx-NAME.service.
rm -f "$tmp/argv" "$tmp/systemctl-argv"
out=$(timeout 5 env SYG_LONG_JOB_UNIT_PREFIX=pfx PATH="$tmp/stub-rec:$PATH" "$LJ" run pfx-job --min-mb 0 -- true 2>&1); rc=$?
[ "$rc" = 0 ] && grep -qxF -- "--unit=pfx-pfx-job.service" "$tmp/argv" \
  && grep -qxF -- "pfx-pfx-job.service" "$tmp/systemctl-argv" \
  && ok "SYG_LONG_JOB_UNIT_PREFIX=pfx passes --unit=pfx-NAME.service to systemd-run and pfx-NAME.service to systemctl" \
  || bad "SYG_LONG_JOB_UNIT_PREFIX=pfx (rc=$rc, argv=$(tr '\n' ' ' <"$tmp/argv" 2>/dev/null), sysctl=$(tr '\n' ' ' <"$tmp/systemctl-argv" 2>/dev/null))"

# --- long-job run --heavy: argv shape against the recording stub (no unit starts)
cat >"$tmp/load-gate-stub" <<EOF
#!/bin/bash
echo "load-gate-stub: \$* 1m=\${SYG_LOAD_GATE_1M-unset}"
exit \$(cat "$tmp/load-rc" 2>/dev/null || echo 0)
EOF
chmod +x "$tmp/load-gate-stub"
printf 'MemTotal: 15000000 kB\nMemAvailable: 1048576 kB\nSwapTotal: 2097152 kB\nSwapFree: 1048576 kB\n' >"$tmp/meminfo-low"
GL="$REPO/plugins/seyag/bin/gate-lock"
av() { tr '\n' ' ' <"$tmp/argv" 2>/dev/null; }

# S1: --heavy defaults to a 900 s memory wait, takes the gate lock, and forwards the caller's seams.
rm -f "$tmp/argv"
out=$(timeout 5 env SYG_GATE_LOCK_FILE="$tmp/gl" SYG_LONG_JOB_LOAD_GATE="$tmp/load-gate-stub" SYG_LOAD_GATE_1M=7 SYG_MEM_GATE_MEMINFO="$tmp/meminfo-low" PATH="$tmp/stub-rec:$PATH" "$LJ" run hv-job --heavy -- true 2>/dev/null); rc=$?
[ "$rc" = 0 ] && grep -qxF -- "--setenv=SYG_GATE_LOCK_FILE=$tmp/gl" "$tmp/argv" \
  && grep -qxF -- "--setenv=SYG_LOAD_GATE_1M=7" "$tmp/argv" \
  && grep -qxF -- "--lock" "$tmp/argv" && grep -qxF -- "$GL" "$tmp/argv" \
  && grep -qxF -- "$XDG_STATE_HOME/long-job/hv-job@gate.lock" "$tmp/argv" \
  && grep -qxF -- "--gate" "$tmp/argv" && grep -qxF -- "900" "$tmp/argv" \
  && grep -qxF -- "--load" "$tmp/argv" && grep -qxF -- "$tmp/load-gate-stub" "$tmp/argv" \
  && grep -qF "queues for the gate lock, then waits for 2048 MB of memory (up to 900 s), then for the CPU load (load-gate)" <<<"$out" \
  && ok "run --heavy locks, defaults --wait-mem to 900, loads the load-gate and forwards the lock file and load limits" \
  || bad "run --heavy defaults (rc=$rc, out=[$out], argv=$(av))"

# S2: --heavy --min-mb 0 skips the memory wait but keeps the lock.
rm -f "$tmp/argv"
out=$(timeout 5 env SYG_GATE_LOCK_FILE="$tmp/gl" SYG_LONG_JOB_LOAD_GATE="$tmp/load-gate-stub" PATH="$tmp/stub-rec:$PATH" "$LJ" run hv-job0 --heavy --min-mb 0 -- true 2>&1); rc=$?
[ "$rc" = 0 ] && grep -qxF -- "--no-gate" "$tmp/argv" && ! grep -qxF -- "900" "$tmp/argv" && grep -qxF -- "--lock" "$tmp/argv" \
  && ok "run --heavy --min-mb 0 skips the memory wait but still takes the gate lock" \
  || bad "run --heavy --min-mb 0 (rc=$rc, out=[$out], argv=$(av))"

# S3: an empty load-gate seam skips the load wait with a warning.
rm -f "$tmp/argv"
err=$(timeout 5 env SYG_GATE_LOCK_FILE="$tmp/gl" SYG_LONG_JOB_LOAD_GATE='' PATH="$tmp/stub-rec:$PATH" "$LJ" run hv-noload --heavy --min-mb 0 -- true 2>&1 >/dev/null); rc=$?
[ "$rc" = 0 ] && grep -qF "skips the CPU load wait" <<<"$err" && grep -qxF -- "--no-load" "$tmp/argv" && ! grep -qxF -- "--load" "$tmp/argv" \
  && ok "run --heavy with no load-gate warns and passes --no-load" \
  || bad "run --heavy no load-gate (rc=$rc, err=[$err], argv=$(av))"

# S4: a plain run neither locks nor forwards the lock file or the load limits.
rm -f "$tmp/argv"
out=$(timeout 5 env SYG_GATE_LOCK_FILE="$tmp/gl" SYG_LOAD_GATE_1M=7 SYG_LONG_JOB_LOAD_GATE="$tmp/load-gate-stub" PATH="$tmp/stub-rec:$PATH" "$LJ" run plain-job --min-mb 0 -- true 2>&1); rc=$?
[ "$rc" = 0 ] && grep -qxF -- "--no-load" "$tmp/argv" && ! grep -qxF -- "--lock" "$tmp/argv" \
  && ! grep -qF -- "--setenv=SYG_GATE_LOCK_FILE=" "$tmp/argv" && ! grep -qF -- "--setenv=SYG_LOAD_GATE_1M=" "$tmp/argv" \
  && ok "a plain run passes --no-load, no --lock and forwards neither the lock file nor the load limits" \
  || bad "plain run (rc=$rc, out=[$out], argv=$(av))"

# S5: an explicit --wait-mem survives --heavy.
rm -f "$tmp/argv"
out=$(timeout 5 env SYG_GATE_LOCK_FILE="$tmp/gl" SYG_LONG_JOB_LOAD_GATE="$tmp/load-gate-stub" PATH="$tmp/stub-rec:$PATH" "$LJ" run hv-w30 --heavy --wait-mem 30 -- true 2>&1); rc=$?
w=$(awk '/^--gate$/{getline; getline; print; exit}' "$tmp/argv")
[ "$rc" = 0 ] && [ "$w" = 30 ] && ! grep -qxF -- "900" "$tmp/argv" \
  && ok "run --heavy --wait-mem 30 keeps 30" \
  || bad "run --heavy --wait-mem 30 (rc=$rc, w=[$w], out=[$out], argv=$(av))"

# S6: --help documents --heavy.
out=$(timeout 5 "$LJ" --help 2>&1)
grep -qF -- "--heavy" <<<"$out" && ok "--help documents --heavy" || bad "--help lacks --heavy"

# S7: --slice and -p/--property reach systemd-run as --slice=NAME and -p KEY=VALUE pairs.
rm -f "$tmp/argv"
out=$(timeout 5 env PATH="$tmp/stub-rec:$PATH" "$LJ" run prop-job --min-mb 0 --no-inhibit --slice jobs.slice -p CPUWeight=20 --property MemoryHigh=1G -- true 2>&1); rc=$?
p_n=$(awk 'prev=="-p" && ($0=="CPUWeight=20" || $0=="MemoryHigh=1G") {n++} {prev=$0} END{print n+0}' "$tmp/argv")
[ "$rc" = 0 ] && grep -qxF -- "--slice=jobs.slice" "$tmp/argv" && [ "$p_n" = 2 ] \
  && ok "run --slice and -p/--property reach systemd-run (--slice=jobs.slice; each KEY=VALUE after a -p line)" \
  || bad "run --slice/-p (rc=$rc, p_n=$p_n, argv=$(av))"

# S8: --heavy drops --slice with a note but keeps -p properties.
rm -f "$tmp/argv"
err=$(timeout 5 env SYG_LONG_JOB_LOAD_GATE='' SYG_GATE_LOCK_FILE="$tmp/gl.lock" PATH="$tmp/stub-rec:$PATH" "$LJ" run hv-slice --heavy --min-mb 0 --no-inhibit --slice jobs.slice -p MemoryHigh=1G -- true 2>&1 >/dev/null); rc=$?
[ "$rc" = 0 ] && ! grep -qF -- "--slice=" "$tmp/argv" && grep -qxF -- "MemoryHigh=1G" "$tmp/argv" \
  && grep -qF -- "--slice jobs.slice is ignored for a --heavy job" <<<"$err" \
  && ok "run --heavy drops --slice with a note while -p MemoryHigh=1G stays" \
  || bad "run --heavy --slice (rc=$rc, err=[$err], argv=$(av))"

# S9: SYG_LONG_JOB_AS='/opt/x/myrun' names messages and the wrapper argv myrun, hints the whole value.
rm -f "$tmp/argv"
out=$(timeout 5 env SYG_LONG_JOB_AS='/opt/x/myrun' PATH="$tmp/stub-rec:$PATH" "$LJ" run dn-job --min-mb 0 --no-inhibit -- true 2>&1); rc=$?
after_exit=$(awk 'prev ~ /\.exit$/ {print; exit} {prev=$0}' "$tmp/argv")
[ "$rc" = 0 ] && grep -q "^myrun: started dn-job as " <<<"$out" \
  && grep -qF 'run "/opt/x/myrun wait dn-job" with Bash run_in_background' <<<"$out" \
  && grep -qF '"/opt/x/myrun wait dn-job --poll"' <<<"$out" \
  && ! grep -q "long-job:" <<<"$out" && [ "$after_exit" = "myrun" ] \
  && ok "SYG_LONG_JOB_AS='/opt/x/myrun' renames messages to myrun, hints carry the whole value (no long-job: line; wrapper argv carries myrun after the .exit path)" \
  || bad "display name myrun (rc=$rc, after_exit=[$after_exit], out=[$out], argv=$(av))"
out=$(timeout 5 env SYG_LONG_JOB_AS=myrun "$LJ" status nosuch 2>&1); rc=$?
[ "$rc" = 1 ] && grep -qF "myrun: no job named nosuch" <<<"$out" \
  && ok "an unknown NAME under the marker dies as myrun: no job named nosuch" \
  || bad "display name unknown NAME (rc=$rc: $out)"

# S9b (the TASK-177 regression): SYG_LONG_JOB_CMD alone — a runner with its own job store —
# must not rename long-job.
rm -f "$tmp/argv"
out=$(timeout 5 env SYG_LONG_JOB_CMD='myrun run' PATH="$tmp/stub-rec:$PATH" "$LJ" run dn-job2 --min-mb 0 --no-inhibit -- true 2>&1); rc=$?
after_exit=$(awk 'prev ~ /\.exit$/ {print; exit} {prev=$0}' "$tmp/argv")
[ "$rc" = 0 ] && grep -q "^long-job: started dn-job2 as " <<<"$out" \
  && grep -qF 'run "long-job wait dn-job2"' <<<"$out" \
  && ! grep -q "myrun" <<<"$out" && [ "$after_exit" = "long-job" ] \
  && ok "SYG_LONG_JOB_CMD='myrun run' without the marker keeps long-job's name and hints (no myrun anywhere; wrapper argv carries long-job)" \
  || bad "SYG_LONG_JOB_CMD does not rename (rc=$rc, after_exit=[$after_exit], out=[$out], argv=$(av))"

# S10: an empty or invalid SYG_LONG_JOB_AS keeps the long-job name.
for v in '' 'bad$name' 'rel/myrun' 'myrun run' '/opt/x/'; do
  out=$(timeout 5 env SYG_LONG_JOB_AS="$v" "$LJ" status nosuch 2>&1); rc=$?
  [ "$rc" = 1 ] && grep -qF "long-job: no job named nosuch" <<<"$out" \
    && ok "SYG_LONG_JOB_AS='$v' keeps the long-job: prefix" \
    || bad "SYG_LONG_JOB_AS='$v' (rc=$rc: $out)"
done

# S11: -p StandardInputText/StandardInputData are refused by the StandardInput* prefix (the job's
# log owns stdin); nothing starts.
for pv in StandardInputText=hi StandardInputData=aGk=; do
  rm -f "$tmp/argv"
  out=$(timeout 5 env PATH="$tmp/stub-rec:$PATH" "$LJ" run sin-job -p "$pv" -- true 2>&1); rc=$?
  [ "$rc" = 2 ] && grep -qF "is set by long-job (the job's log); not allowed" <<<"$out" && [ ! -e "$tmp/argv" ] \
    && ok "-p $pv exits 2 with the stdio refusal, nothing started" \
    || bad "-p $pv (rc=$rc, out=[$out], argv=$(av))"
done

# S12: --heavy drops -p CPUWeight/CPUQuota/StartupCPUWeight with a note; other props stay.
# The -p options come before --heavy, so the drop must happen after the option loop.
rm -f "$tmp/argv"
err=$(timeout 5 env SYG_LONG_JOB_LOAD_GATE='' SYG_GATE_LOCK_FILE="$tmp/gl.lock" PATH="$tmp/stub-rec:$PATH" "$LJ" run hv-cpu -p CPUWeight=20 -p CPUQuota=50% --property StartupCPUWeight=5 -p CPUShares=64 -p MemoryHigh=1G --heavy --min-mb 0 --no-inhibit -- true 2>&1 >/dev/null); rc=$?
[ "$rc" = 0 ] && grep -qxF -- "MemoryHigh=1G" "$tmp/argv" \
  && ! grep -qF -- "CPUWeight=20" "$tmp/argv" && ! grep -qF -- "CPUQuota=50%" "$tmp/argv" && ! grep -qF -- "StartupCPUWeight=5" "$tmp/argv" \
  && grep -qF -- "-p CPUWeight=20 is ignored for a --heavy job" <<<"$err" \
  && grep -qF -- "-p CPUQuota=50% is ignored for a --heavy job" <<<"$err" \
  && grep -qF -- "-p StartupCPUWeight=5 is ignored for a --heavy job" <<<"$err" \
  && ! grep -qF -- "CPUShares=64" "$tmp/argv" && grep -qF -- "-p CPUShares=64 is ignored for a --heavy job" <<<"$err" \
  && ok "run --heavy drops -p CPUWeight/CPUQuota/StartupCPUWeight/CPUShares with a note while -p MemoryHigh=1G stays" \
  || bad "run --heavy CPU props (rc=$rc, err=[$err], argv=$(av))"

# SYG_LONG_JOB_UNIT_PREFIX='a b' exits 2 naming the knob; leading '-' exits 2 saying it must start with a letter or digit.
out=$(timeout 5 env SYG_LONG_JOB_UNIT_PREFIX='a b' PATH="$tmp/stub:$PATH" "$LJ" run bad-pfx --min-mb 0 -- true 2>&1); rc=$?
[ "$rc" = 2 ] && grep -q "SYG_LONG_JOB_UNIT_PREFIX" <<<"$out" \
  && ok "SYG_LONG_JOB_UNIT_PREFIX='a b' exits 2 naming the knob" \
  || bad "SYG_LONG_JOB_UNIT_PREFIX='a b' (rc=$rc: $out)"
out=$(timeout 5 env SYG_LONG_JOB_UNIT_PREFIX=-x "$LJ" status x 2>&1); rc=$?
[ "$rc" = 2 ] && grep -q "SYG_LONG_JOB_UNIT_PREFIX must start with a letter or digit" <<<"$out" \
  && ok "SYG_LONG_JOB_UNIT_PREFIX=-x exits 2 saying the prefix must start with a letter or digit" \
  || bad "SYG_LONG_JOB_UNIT_PREFIX=-x (rc=$rc: $out)"

# SYG_LONG_JOB_STATE_DIR=rel exits 2 requiring an absolute path.
out=$(timeout 5 env SYG_LONG_JOB_STATE_DIR=rel "$LJ" status x 2>&1); rc=$?
[ "$rc" = 2 ] && grep -qF "SYG_LONG_JOB_STATE_DIR must be an absolute path: 'rel'" <<<"$out" \
  && ok "SYG_LONG_JOB_STATE_DIR=rel exits 2 requiring an absolute path" \
  || bad "SYG_LONG_JOB_STATE_DIR=rel (rc=$rc: $out)"

# Recorded NAME.unit: run NAME with prefix A, then status and wait --poll with prefix B query A-NAME.service.
rm -f "$tmp/argv" "$tmp/systemctl-argv"
out=$(timeout 5 env SYG_LONG_JOB_UNIT_PREFIX=A PATH="$tmp/stub-rec:$PATH" "$LJ" run unit-rec --min-mb 0 -- true 2>&1); rc=$?
rm -f "$tmp/systemctl-argv"
timeout 5 env SYG_LONG_JOB_UNIT_PREFIX=B PATH="$tmp/stub-rec:$PATH" "$LJ" status unit-rec >/dev/null 2>&1; rc_st=$?
st_argv=$(tr '\n' ' ' <"$tmp/systemctl-argv" 2>/dev/null)
rm -f "$tmp/systemctl-argv"
timeout 5 env SYG_LONG_JOB_UNIT_PREFIX=B PATH="$tmp/stub-rec:$PATH" "$LJ" wait unit-rec --poll --owner "" >/dev/null 2>&1; rc_wt=$?
wt_argv=$(tr '\n' ' ' <"$tmp/systemctl-argv" 2>/dev/null)
[ "$rc" = 0 ] && [ "$rc_st" = 0 ] && [ "$rc_wt" = 4 ] \
  && [ "$(cat "$XDG_STATE_HOME/long-job/unit-rec.unit" 2>/dev/null)" = "A-unit-rec.service" ] \
  && [ "$(stat -c %a "$XDG_STATE_HOME/long-job/unit-rec.unit" 2>/dev/null)" = "600" ] \
  && grep -qF -- "-- A-unit-rec.service" <<<"$st_argv" && ! grep -qF -- "B-unit-rec.service" <<<"$st_argv" \
  && grep -qF -- "-- A-unit-rec.service" <<<"$wt_argv" && ! grep -qF -- "B-unit-rec.service" <<<"$wt_argv" \
  && ok "run records NAME.unit (600) and status/wait --poll query A-NAME.service even under prefix B" \
  || bad "recorded NAME.unit under prefix B (rc=$rc/$rc_st/$rc_wt, st=[$st_argv], wt=[$wt_argv])"

# Config loading: user seyag/config.toml sets syg_long_job_unit_prefix = "cfg" when env is unset; env overrides it.
mkdir -p "$tmp/cfg-lj/seyag"
printf 'syg_long_job_unit_prefix = "cfg"\n' >"$tmp/cfg-lj/seyag/config.toml"
rm -f "$tmp/argv"
out=$(timeout 5 env -u SYG_LONG_JOB_UNIT_PREFIX XDG_CONFIG_HOME="$tmp/cfg-lj" PATH="$tmp/stub-rec:$PATH" "$LJ" run cfg-job --min-mb 0 -- true 2>&1); rc=$?
[ "$rc" = 0 ] && grep -qxF -- "--unit=cfg-cfg-job.service" "$tmp/argv" \
  && ok "config.toml syg_long_job_unit_prefix=cfg sets unit prefix when SYG_LONG_JOB_UNIT_PREFIX is unset" \
  || bad "config.toml unit prefix (rc=$rc, argv=$(tr '\n' ' ' <"$tmp/argv" 2>/dev/null))"
rm -f "$tmp/argv"
out=$(timeout 5 env SYG_LONG_JOB_UNIT_PREFIX=envp XDG_CONFIG_HOME="$tmp/cfg-lj" PATH="$tmp/stub-rec:$PATH" "$LJ" run envp-job --min-mb 0 -- true 2>&1); rc=$?
[ "$rc" = 0 ] && grep -qxF -- "--unit=envp-envp-job.service" "$tmp/argv" \
  && ok "env SYG_LONG_JOB_UNIT_PREFIX=envp overrides config.toml syg_long_job_unit_prefix" \
  || bad "env overrides config.toml unit prefix (rc=$rc, argv=$(tr '\n' ' ' <"$tmp/argv" 2>/dev/null))"

# && refusal through SYG_LONG_JOB_PARENT_CMD with SYG_LONG_JOB_CMD='jobrun run' alias.
err=$(timeout 5 env SYG_LONG_JOB_CMD='jobrun run' SYG_LONG_JOB_PARENT_CMD='jobrun run x --min-mb 0 -- true && echo after' PATH="$tmp/stub:$PATH" "$LJ" run x --min-mb 0 -- true 2>&1 >/dev/null); rc=$?
[ "$rc" = 2 ] && grep -q "^jobrun: refusing:" <<<"$err" && [ ! -e "$XDG_STATE_HOME/long-job/x.cmd" ] \
  && ok "SYG_LONG_JOB_CMD='jobrun run' refuses && tail via SYG_LONG_JOB_PARENT_CMD with exit 2 and nothing recorded" \
  || bad "alias && refusal (rc=$rc: $err)"

# Old parent-cmd variable set to an && chain, with SYG_LONG_JOB_PARENT_CMD unset and run from a script (not bash -c), is ignored.
old_seam_var=OLD_JOB_PARENT_CMD
cat >"$tmp/run-from-script.sh" <<EOF
#!/usr/bin/env bash
exec "$LJ" run old-seam --min-mb 0 -- true
EOF
chmod +x "$tmp/run-from-script.sh"
out=$(timeout 5 env -u SYG_LONG_JOB_PARENT_CMD "${old_seam_var}=long-job run old-seam --min-mb 0 -- true && echo after" PATH="$tmp/stub:$PATH" bash "$tmp/run-from-script.sh" 2>&1); rc=$?
[ "$rc" = 0 ] && [ -s "$XDG_STATE_HOME/long-job/old-seam.cmd" ] \
  && ok "old parent-cmd variable is ignored when SYG_LONG_JOB_PARENT_CMD is unset and run from a script" \
  || bad "old parent-cmd variable not ignored (rc=$rc: $out)"

# --wait-mem path: stub systemd-run records gate args carrying $REPO/plugins/seyag/bin/mem-gate,
# and mem-gate --wait 1 --timeout 1 --interval 1 --owner "" against a high fixture exits 0.
rm -f "$tmp/argv"
out=$(timeout 5 env PATH="$tmp/stub-rec:$PATH" "$LJ" run wm-job --min-mb 512 --wait-mem 10 -- true 2>&1); rc=$?
rec_mg=$(awk '/^--gate$/{getline; getline; getline; getline; print; exit}' "$tmp/argv")
printf 'MemTotal: 15000000 kB\nMemAvailable: 5242880 kB\nSwapTotal: 2097152 kB\nSwapFree: 1048576 kB\n' >"$tmp/meminfo-high"
timeout 5 env SYG_MEM_GATE_MEMINFO="$tmp/meminfo-high" "$MG" --wait 1 --timeout 1 --interval 1 --owner "" >/dev/null 2>&1; mg_rc=$?
[ "$rc" = 0 ] && grep -qxF -- "--gate" "$tmp/argv" && [ -n "$rec_mg" ] \
  && [ "$(readlink -f "$rec_mg")" = "$(readlink -f "$MG")" ] && [ "$mg_rc" = 0 ] \
  && ok "--wait-mem passes $MG in gate args and mem-gate --wait with empty --owner exits 0" \
  || bad "--wait-mem / mem-gate empty owner (rc=$rc, mg_rc=$mg_rc, rec_mg=$rec_mg, argv=$(tr '\n' ' ' <"$tmp/argv" 2>/dev/null))"

# Copied bin/long-job without ../lib/owner.sh exits 2 with 'cannot load'.
mkdir -p "$tmp/solo/bin"
cp "$LJ" "$tmp/solo/bin/long-job"
out=$(timeout 5 "$tmp/solo/bin/long-job" status 2>&1); rc=$?
[ "$rc" = 2 ] && grep -q "cannot load" <<<"$out" \
  && ok "long-job without lib/owner.sh exits 2 with 'cannot load'" \
  || bad "solo without owner.sh (rc=$rc: $out)"

# Inhibitor fallback: when systemd-inhibit exits 1, run logs and prints the unavailable note and omits systemd-inhibit from systemd-run argv.
mkdir -p "$tmp/stub-noinh"
cp "$tmp/stub-rec/systemd-run" "$tmp/stub-rec/systemctl" "$tmp/stub-noinh/"
printf '#!/bin/sh\nexit 1\n' >"$tmp/stub-noinh/systemd-inhibit"; chmod +x "$tmp/stub-noinh/systemd-inhibit"
rm -f "$tmp/argv"
out=$(timeout 5 env PATH="$tmp/stub-noinh:$PATH" "$LJ" run noinh-job --min-mb 0 -- true 2>&1); rc=$?
[ "$rc" = 0 ] \
  && grep -qxF "long-job: sleep/idle inhibitor unavailable here (systemd-inhibit refused); running without it" <<<"$out" \
  && grep -qxF "long-job: sleep/idle inhibitor unavailable here (systemd-inhibit refused); running without it" "$XDG_STATE_HOME/long-job/noinh-job.log" \
  && [ -s "$tmp/argv" ] && ! grep -q "systemd-inhibit" "$tmp/argv" \
  && ok "run falls back when systemd-inhibit is refused, notes it on stderr and in log, and omits systemd-inhibit from systemd-run argv" \
  || bad "inhibitor fallback (rc=$rc, out=[$out], argv=$(tr '\n' ' ' <"$tmp/argv" 2>/dev/null))"

export PATH="$ORIG_PATH"
# --- long-job against the real user manager
if ! systemctl --user show-environment >/dev/null 2>&1; then
  skip_n=$(sed -n '/^# --- long-job against the real user manager/,$p' "${BASH_SOURCE[0]}" | grep -v '^[[:space:]]*#' | grep -cE '(^|[;&|[:space:]])ok "')
  echo "long-job probe: $pass passed, $fail failed"
  echo "SKIP  $skip_n real-unit cases (no user systemd manager)"
  [ "$fail" = 0 ]
  exit $?
fi
p=probe-$$
cleanup_units() { for s in ok bad stop gate race wq wr dollar heavy heavyq heavymem heavyld heavylf heavyln plainld disp heavydisp; do systemctl --user stop "long-job-$p-$s.service" 2>/dev/null; systemctl --user reset-failed "long-job-$p-$s.service" 2>/dev/null; done; rm -rf "$tmp"; }
trap cleanup_units EXIT

timeout 10 "$LJ" run "$p-gate" --min-mb 99999999 -- true >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ ! -e "$XDG_STATE_HOME/long-job/$p-gate.cmd" ] && ok "run refuses below the memory gate and records nothing" || bad "run memory gate (rc $rc)"

mkdir -p "$tmp/cwd"
out=$(cd "$tmp/cwd" && timeout 10 env FOO_PROBE=bar "$LJ" run "$p-ok" --min-mb 0 --no-inhibit --env FOO_PROBE -- bash -c 'pwd; echo "foo=$FOO_PROBE"; read -t 1 x && echo "stdin:$x"; echo err >&2' <<<probe-input); rc=$?
[ "$rc" = 0 ] && grep -q "started $p-ok" <<<"$out" && ok "run starts a unit" || bad "run start (rc $rc: $out)"
out=$(timeout 25 "$LJ" wait "$p-ok" --interval 1 --timeout 20 --owner ""); rc=$?
[ "$rc" = 0 ] && grep -q "done, exit 0" <<<"$out" && ok "wait reports exit 0" || bad "wait exit 0 (rc $rc: $out)"
! grep -q "CronDelete" <<<"$out" && ok "a blocking wait doesn't print the cron-tick line" || bad "blocking wait printed the cron line ($out)"
[ "$(tail -n 1 <<<"$out")" = "long-job: ended: act on the result above" ] && ok "a blocking wait that saw the end ends with the ended line" || bad "blocking wait last line ($out)"
out=$(timeout 5 "$LJ" wait "$p-ok" --poll --owner ""); rc=$?
[ "$rc" = 0 ] && grep -q "done, exit 0" <<<"$out" && grep -q "^--- last lines" <<<"$out" && ok "wait --poll on a finished job reports its result" || bad "wait --poll done (rc $rc: $out)"
[ "$(tail -n 1 <<<"$out")" = "long-job: ended: act on the result above; if a cron tick ran this check, CronDelete it now (CronList shows its id)" ] && ok "wait --poll on a finished job ends with the ended + CronDelete line" || bad "wait --poll done last line ($out)"
out=$(timeout 5 "$LJ" wait "no-such-job-$p" --poll --owner "" 2>&1); rc=$?
[ "$rc" = 1 ] && ! grep -q "CronDelete" <<<"$out" && ok "wait --poll on an unknown job exits 1 without the CronDelete line" || bad "wait --poll unknown (rc $rc: $out)"
log=$(timeout 5 "$LJ" log "$p-ok")
grep -qx "$tmp/cwd" <<<"$log" && ok "job runs in the caller's directory" || bad "job cwd ($log)"
grep -qx "foo=bar" <<<"$log" && ok "--env passes the caller's variable" || bad "--env ($log)"
grep -qx "err" <<<"$log" && ok "stderr lands in the log" || bad "stderr in log"
! grep -q "^stdin:" <<<"$log" && ok "the caller's stdin doesn't reach the job" || bad "stdin not empty"
# The job's arguments reach it byte-exact. systemd-run's default expansion turns
# ${label} into "", ${HOME} into its value and $$ into $; long-job turns it off.
# The lone '$HOME' argument covers systemd's other rule: a whole-argument $VAR is expanded too.
dollar='Error(`${label}: no answer within ${ms} ms`) [ "${BASH_VERSINFO[0]}" -ge 5 ] ${HOME} $$ $HOME ${x:-f} $${x} end$'
if ! timeout 10 "$LJ" run "$p-dollar" --min-mb 0 --no-inhibit -- printf 'arg=%s\n' "$dollar" '$HOME' >/dev/null; then
  bad "dollar job did not start"
elif ! timeout 25 "$LJ" wait "$p-dollar" --interval 1 --timeout 20 --owner "" >/dev/null; then
  bad "dollar job did not end with exit 0"
elif ! log=$(timeout 5 "$LJ" log "$p-dollar"); then
  bad "dollar job log unreadable"
elif grep -qxF "arg=$dollar" <<<"$log" && grep -qxF 'arg=$HOME' <<<"$log"; then
  ok "job arguments keep \${...}, \$\$ and a lone \$VAR byte-exact"
else
  bad "job argument rewritten: $(grep '^arg=' <<<"$log")"
fi

timeout 10 "$LJ" run "$p-bad" --min-mb 0 -- bash -c 'exit 7' -h >/dev/null
out=$(timeout 25 "$LJ" wait "$p-bad" --interval 1 --timeout 20 --owner ""); rc=$?
[ "$rc" = 1 ] && grep -q "failed, exit 7" <<<"$out" && ok "wait reports a failing exit and exits 1 (inhibitor on, -h after -- reaches the job)" || bad "wait failure (rc $rc: $out)"
[ "$(tail -n 1 <<<"$out")" = "long-job: ended: act on the result above" ] && ok "a blocking wait on a failed job still ends with the ended line" || bad "blocking wait failed last line ($out)"
out=$(timeout 5 "$LJ" wait "$p-bad" --poll --owner ""); rc=$?
[ "$rc" = 1 ] && grep -q "failed, exit 7" <<<"$out" && grep -qxF "long-job: ended: act on the result above; if a cron tick ran this check, CronDelete it now (CronList shows its id)" <<<"$out" && ok "wait --poll on a failed job exits 1 and still prints the ended + CronDelete line" || bad "wait --poll failed (rc $rc: $out)"

timeout 10 "$LJ" run "$p-stop" --min-mb 0 --no-inhibit -- sleep 60 >/dev/null
timeout 5 "$LJ" run "$p-stop" --min-mb 0 -- true >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "run refuses a name that is already running" || bad "duplicate run (rc $rc)"
out=$(timeout 5 "$LJ" status "$p-stop"); grep -q "running" <<<"$out" && ok "status shows running" || bad "status running ($out)"
out=$(timeout 10 "$LJ" wait "$p-stop" --interval 1 --timeout 2 --owner ""); rc=$?
[ "$rc" = 4 ] && ok "wait times out with exit 4" || bad "wait timeout (rc $rc)"
! grep -q "^long-job: ended" <<<"$out" && ok "a timed-out wait prints no ended line (the wake rule then polls)" || bad "timed-out wait printed an ended line ($out)"
sleep 0 & dead=$!; wait "$dead"
out=$(timeout 15 "$LJ" wait "$p-stop" --interval 1 --timeout 10 --owner "$dead" 2>&1); rc=$?
[ "$rc" = 3 ] && ! grep -q "^long-job: ended" <<<"$out" && ok "a wait whose owner is gone exits 3 with no ended line" || bad "owner-gone wait (rc $rc: $out)"
# Not timed: a --poll that blocked would sleep the 15 s default interval and die at timeout 5 (rc 124), never rc 4.
out=$(timeout 5 "$LJ" wait "$p-stop" --poll --owner ""); rc=$?
[ "$rc" = 4 ] && grep -q "$p-stop: running" <<<"$out" && ok "wait --poll on a running job exits 4 without blocking" || bad "wait --poll running (rc $rc: $out)"
[ "$(tail -n 1 <<<"$out")" = "long-job: still running: with no live waiter for $p-stop, start \"long-job wait $p-stop\" in the background; otherwise, and on a cron tick, say nothing" ] && ! grep -q "CronDelete" <<<"$out" && ok "wait --poll on a running job ends with the still-running line" || bad "wait --poll running last line ($out)"
timeout 5 systemctl --user stop "long-job-$p-stop.service"
out=$(timeout 15 "$LJ" wait "$p-stop" --interval 1 --timeout 10 --owner ""); rc=$?
[ "$rc" = 1 ] && grep -q "without an exit record" <<<"$out" && ok "a stopped job reports no exit record, exit 1" || bad "stopped job (rc $rc: $out)"
out=$(timeout 5 "$LJ" wait "$p-stop" --poll --owner ""); rc=$?
[ "$rc" = 1 ] && grep -q "without an exit record" <<<"$out" && grep -qxF "long-job: ended: act on the result above; if a cron tick ran this check, CronDelete it now (CronList shows its id)" <<<"$out" && ok "wait --poll on a stopped job exits 1 with the ended + CronDelete line" || bad "wait --poll stopped (rc $rc: $out)"

timeout 10 "$LJ" run "$p-race" --min-mb 0 --no-inhibit -- sleep 2 >/dev/null
out=$(timeout 10 "$LJ" wait "$p-race" --interval 4 --timeout 1 --owner ""); rc=$?
[ "$rc" = 0 ] && grep -q "done, exit 0" <<<"$out" && [ "$(tail -n 1 <<<"$out")" = "long-job: ended: act on the result above" ] && ok "a job that ends during the last sleep is reported done with the ended line, not timed out" || bad "wait race (rc $rc: $out)"

# --- long-job --wait-mem gate inside the unit
printf 'MemTotal: 15000000 kB\nMemAvailable: 1048576 kB\nSwapTotal: 2097152 kB\nSwapFree: 1048576 kB\n' >"$tmp/meminfo-wait"
export SYG_MEM_GATE_MEMINFO="$tmp/meminfo-wait"

# A: fixture MemAvailable low (1 GB), --wait-mem 6 times out inside unit, CMD not run
s=$SECONDS
timeout 10 "$LJ" run "$p-wq" --min-mb 4000 --wait-mem 6 --no-inhibit -- touch "$tmp/ran-wq" >/dev/null; rc=$?
elapsed=$((SECONDS - s))
[ "$rc" = 0 ] && [ "$elapsed" -le 3 ] && ok "run --wait-mem returns 0 at once" || bad "run --wait-mem start (rc $rc in ${elapsed}s)"
out=$(timeout 5 "$LJ" status "$p-wq")
grep -q "running" <<<"$out" && ok "status wq right after shows running" || bad "status wq right after ($out)"
out=$(timeout 25 "$LJ" wait "$p-wq" --interval 1 --timeout 20 --owner ""); rc=$?
[ "$rc" = 1 ] && grep -q "failed, exit 1" <<<"$out" && ok "wait exits 1 on gate timeout" || bad "wait wq timeout (rc $rc: $out)"
[ ! -e "$tmp/ran-wq" ] && ok "command did not run when gate timed out" || bad "ran-wq exists"
log=$(timeout 5 "$LJ" log "$p-wq")
grep -q "timed out" <<<"$log" && ok "job log contains timed out" || bad "timed out not in log ($log)"

# B: fixture low, --wait-mem 30, then raise MemAvailable > 4000 MB, CMD runs
printf 'MemTotal: 15000000 kB\nMemAvailable: 1048576 kB\nSwapTotal: 2097152 kB\nSwapFree: 1048576 kB\n' >"$tmp/meminfo-wait"
timeout 10 "$LJ" run "$p-wr" --min-mb 4000 --wait-mem 30 --no-inhibit -- touch "$tmp/ran-wr" >/dev/null; rc=$?
[ "$rc" = 0 ] && ok "run wr starts at once" || bad "run wr start (rc $rc)"
# Raise memory only once the unit is waiting, and atomically, so its first read sees the low fixture.
for _ in $(seq 20); do grep -q "mem-gate: waiting" "$XDG_STATE_HOME/long-job/$p-wr.log" 2>/dev/null && break; sleep 0.5; done
printf 'MemTotal: 15000000 kB\nMemAvailable: 5242880 kB\nSwapTotal: 2097152 kB\nSwapFree: 1048576 kB\n' >"$tmp/meminfo-wait.new"
mv "$tmp/meminfo-wait.new" "$tmp/meminfo-wait"
out=$(timeout 45 "$LJ" wait "$p-wr" --interval 1 --timeout 40 --owner ""); rc=$?
[ "$rc" = 0 ] && grep -q "done, exit 0" <<<"$out" && ok "wait wr exits 0 once memory frees" || bad "wait wr (rc $rc: $out)"
[ -e "$tmp/ran-wr" ] && ok "ran-wr exists" || bad "ran-wr does not exist"
log=$(timeout 5 "$LJ" log "$p-wr")
grep -q "ok after" <<<"$log" && ok "log contains ok after" || bad "ok after not in log ($log)"

# --- long-job run --heavy inside real units (every heavy case uses a lock file under $tmp, never /tmp/gate.lock)
export SYG_GATE_LOCK_FILE="$tmp/gate.lock"
export SYG_LONG_JOB_LOAD_GATE="$tmp/load-gate-stub"
LJS="$XDG_STATE_HOME/long-job"
# logwait FILE PATTERN SECONDS: poll the log for a fixed string.
logwait() { local i; for ((i = 0; i < $3 * 2; i++)); do grep -qF -- "$2" "$1" 2>/dev/null && return 0; sleep 0.5; done; return 1; }
# lineno FILE REGEX: the first matching line number, or empty.
lineno() { grep -n -m1 -- "$2" "$1" 2>/dev/null | cut -d: -f1; }

# C: low memory, --heavy does not refuse at start; the memory wait starts only after the lock is held.
export SYG_MEM_GATE_MEMINFO="$tmp/meminfo-low"
timeout 10 "$LJ" run "$p-heavymem" --heavy --min-mb 4000 --no-inhibit -- true >/dev/null 2>&1; rc=$?
logwait "$LJS/$p-heavymem.log" "mem-gate: waiting" 10; wrc=$?
l_lock=$(lineno "$LJS/$p-heavymem.log" "holding the gate lock"); l_mem=$(lineno "$LJS/$p-heavymem.log" "mem-gate: waiting")
[ "$rc" = 0 ] && [ "$wrc" = 0 ] && [ -n "$l_lock" ] && [ -n "$l_mem" ] && [ "$l_lock" -lt "$l_mem" ] \
  && ok "run --heavy on low memory starts, and its memory wait begins after the gate lock is held" \
  || bad "heavy memory wait (rc=$rc, wait=$wrc, lock line=[$l_lock], mem line=[$l_mem], log=$(cat "$LJS/$p-heavymem.log" 2>/dev/null | tr '\n' '|'))"
timeout 10 systemctl --user stop "long-job-$p-heavymem.service" 2>/dev/null
unset SYG_MEM_GATE_MEMINFO

# D: a gate-lock call inside the job takes the per-job lock instead of waiting on the job's own.
timeout 10 "$LJ" run "$p-heavy" --heavy --min-mb 0 --no-inhibit -- bash -c 'exec "$1" echo nested-ran' _ "$REPO/plugins/seyag/bin/gate-lock" >/dev/null 2>&1; rc=$?
out=$(timeout 25 "$LJ" wait "$p-heavy" --interval 1 --timeout 20 --owner ""); wrc=$?
grep -qx "nested-ran" "$LJS/$p-heavy.log" 2>/dev/null \
  && [ "$rc" = 0 ] && [ "$wrc" = 0 ] \
  && ok "a gate-lock call inside a --heavy job does not deadlock on the job's own lock" \
  || bad "heavy nested gate-lock (rc=$rc, wait=$wrc, out=$out, log=$(tr '\n' '|' <"$LJS/$p-heavy.log" 2>/dev/null))"
# A deadlocked job would hold the gate lock for the cases below: release it.
timeout 10 systemctl --user stop "long-job-$p-heavy.service" 2>/dev/null

# E: a held gate lock queues the job; it runs once the lock is released.
exec 8>>"$SYG_GATE_LOCK_FILE"; flock 8
timeout 10 "$LJ" run "$p-heavyq" --heavy --min-mb 0 --no-inhibit -- touch "$tmp/ran-heavyq" >/dev/null 2>&1; rc=$?
logwait "$LJS/$p-heavyq.log" "gate-lock: waiting" 10; wrc=$?
sleep 1
timeout 5 "$LJ" wait "$p-heavyq" --poll --owner "" >/dev/null 2>&1; prc=$?
[ -e "$tmp/ran-heavyq" ] && ran1=1 || ran1=0
exec 8>&-
out=$(timeout 25 "$LJ" wait "$p-heavyq" --interval 1 --timeout 20 --owner ""); wrc2=$?
[ "$rc" = 0 ] && [ "$wrc" = 0 ] && [ "$prc" = 4 ] && [ "$ran1" = 0 ] && [ "$wrc2" = 0 ] && [ -e "$tmp/ran-heavyq" ] \
  && ok "run --heavy queues behind a held gate lock (still running, CMD not run) and runs after release" \
  || bad "heavy queue (rc=$rc, logwait=$wrc, poll=$prc, ran-before=$ran1, wait=$wrc2, out=$out)"

# F: the load wait runs after the lock, before CMD, with the forwarded load limit.
SYG_LOAD_GATE_1M=7 timeout 10 "$LJ" run "$p-heavyld" --heavy --min-mb 0 --no-inhibit -- echo cmd-ran >"$tmp/heavyld.out" 2>&1; rc=$?
out=$(timeout 25 "$LJ" wait "$p-heavyld" --interval 1 --timeout 20 --owner ""); wrc=$?
f1=$(lineno "$LJS/$p-heavyld.log" "holding the gate lock"); f2=$(lineno "$LJS/$p-heavyld.log" '^load-gate-stub: --wait --owner  1m=7$'); f3=$(lineno "$LJS/$p-heavyld.log" '^cmd-ran$')
[ "$rc" = 0 ] && [ "$wrc" = 0 ] && [ -n "$f1" ] && [ -n "$f2" ] && [ -n "$f3" ] && [ "$f1" -lt "$f2" ] && [ "$f2" -lt "$f3" ] \
  && grep -qF "then for the CPU load (load-gate)" "$tmp/heavyld.out" \
  && ok "run --heavy: lock, then the load wait with the forwarded limit, then CMD" \
  || bad "heavy load wait (rc=$rc, wait=$wrc, lines=[$f1/$f2/$f3], start=$(cat "$tmp/heavyld.out"), log=$(tr '\n' '|' <"$LJS/$p-heavyld.log" 2>/dev/null))"

# G: a failing load-gate runs CMD anyway and says so.
echo 2 >"$tmp/load-rc"
timeout 10 "$LJ" run "$p-heavylf" --heavy --min-mb 0 --no-inhibit -- echo cmd-ran >/dev/null 2>&1; rc=$?
out=$(timeout 25 "$LJ" wait "$p-heavylf" --interval 1 --timeout 20 --owner ""); wrc=$?
rm -f "$tmp/load-rc"
grep -qF "load-gate exited 2; running anyway" "$LJS/$p-heavylf.log" 2>/dev/null && grep -qx "cmd-ran" "$LJS/$p-heavylf.log" 2>/dev/null \
  && [ "$rc" = 0 ] && [ "$wrc" = 0 ] \
  && ok "run --heavy runs CMD anyway when load-gate exits non-zero, and logs it" \
  || bad "heavy load-gate failure (rc=$rc, wait=$wrc, log=$(tr '\n' '|' <"$LJS/$p-heavylf.log" 2>/dev/null))"

# H: no load-gate: warn at start, skip the load wait.
err=$(SYG_LONG_JOB_LOAD_GATE='' timeout 10 "$LJ" run "$p-heavyln" --heavy --min-mb 0 --no-inhibit -- echo cmd-ran 2>&1 >/dev/null); rc=$?
out=$(timeout 25 "$LJ" wait "$p-heavyln" --interval 1 --timeout 20 --owner ""); wrc=$?
[ "$rc" = 0 ] && [ "$wrc" = 0 ] && grep -qF "skips the CPU load wait" <<<"$err" \
  && grep -qx "cmd-ran" "$LJS/$p-heavyln.log" 2>/dev/null && ! grep -q "load-gate-stub" "$LJS/$p-heavyln.log" \
  && ok "run --heavy without a load-gate warns and runs CMD without the load wait" \
  || bad "heavy no load-gate (rc=$rc, wait=$wrc, err=$err, log=$(tr '\n' '|' <"$LJS/$p-heavyln.log" 2>/dev/null))"

# I: a plain run never calls the load-gate.
timeout 10 "$LJ" run "$p-plainld" --min-mb 0 --no-inhibit -- echo cmd-ran >/dev/null 2>&1; rc=$?
out=$(timeout 25 "$LJ" wait "$p-plainld" --interval 1 --timeout 20 --owner ""); wrc=$?
[ "$rc" = 0 ] && [ "$wrc" = 0 ] && grep -qx "cmd-ran" "$LJS/$p-plainld.log" 2>/dev/null && ! grep -q "load-gate-stub" "$LJS/$p-plainld.log" \
  && ok "a plain run does not call the load-gate" \
  || bad "plain run load-gate (rc=$rc, wait=$wrc, log=$(tr '\n' '|' <"$LJS/$p-plainld.log" 2>/dev/null))"

# J: the marker SYG_LONG_JOB_AS reaches run's output, the log header and wait's ended sentinel.
out=$(timeout 10 env SYG_LONG_JOB_AS=myrun "$LJ" run "$p-disp" --min-mb 0 --no-inhibit -- echo cmd-ran 2>&1); rc=$?
wout=$(timeout 25 env SYG_LONG_JOB_AS=myrun "$LJ" wait "$p-disp" --interval 1 --timeout 20 --owner ""); wrc=$?
[ "$rc" = 0 ] && [ "$wrc" = 0 ] && grep -q "^myrun: started $p-disp as " <<<"$out" \
  && grep -qF "=== myrun $p-disp started" "$LJS/$p-disp.log" 2>/dev/null && grep -qx "cmd-ran" "$LJS/$p-disp.log" 2>/dev/null \
  && [ "$(tail -n 1 <<<"$wout")" = "myrun: ended: act on the result above" ] && ! grep -q "^long-job: " <<<"$wout" \
  && ok "SYG_LONG_JOB_AS=myrun names run's lines, the log header and the ended sentinel myrun" \
  || bad "display-name real unit (rc=$rc, wrc=$wrc, out=[$out], wout=[$wout], log=$(tr '\n' '|' <"$LJS/$p-disp.log" 2>/dev/null))"

# J2: the marker survives --heavy's --lock re-exec: the wrapper's gate-lock line, the job's output
# and wait's ended sentinel all say myrun.
out=$(timeout 10 env SYG_LONG_JOB_AS=myrun SYG_LONG_JOB_LOAD_GATE='' "$LJ" run "$p-heavydisp" --heavy --min-mb 0 --no-inhibit -- echo heavy-ran 2>&1); rc=$?
wout=$(timeout 25 env SYG_LONG_JOB_AS=myrun "$LJ" wait "$p-heavydisp" --interval 1 --timeout 20 --owner ""); wrc=$?
grep -q "^myrun: .* holding the gate lock" "$LJS/$p-heavydisp.log" 2>/dev/null && grep -qx "heavy-ran" "$LJS/$p-heavydisp.log" 2>/dev/null \
  && [ "$rc" = 0 ] && [ "$wrc" = 0 ] \
  && [ "$(tail -n 1 <<<"$wout")" = "myrun: ended: act on the result above" ] \
  && ok "SYG_LONG_JOB_AS=myrun survives --heavy's --lock re-exec (gate-lock line, CMD output, ended sentinel all myrun)" \
  || bad "display-name heavy real unit (rc=$rc, wrc=$wrc, out=[$out], wout=[$wout], log=$(tr '\n' '|' <"$LJS/$p-heavydisp.log" 2>/dev/null))"
timeout 10 systemctl --user stop "long-job-$p-heavydisp.service" 2>/dev/null
unset SYG_GATE_LOCK_FILE SYG_LONG_JOB_LOAD_GATE

# status queries systemd once per recorded job; 5 s ran out under heavy load (0 listed, 11-25).
n=$(timeout 60 "$LJ" status | grep -c "^$p-")
[ "$n" = 16 ] && ok "status lists every recorded job" || bad "status lists $n jobs, want 16"

echo "long-job probe: $pass passed, $fail failed"
[ "$fail" = 0 ]
