#!/usr/bin/env bash
# Hermetic probe for plugins/seyag/bin/long-job: usage errors, unreadable-memory exit 6, owner
# recording (CLAUDE_JOB_DIR or cwd basename), state-dir permissions, SYG_LONG_JOB_STATE_DIR,
# SYG_LONG_JOB_UNIT_PREFIX, SYG_LONG_JOB_PARENT_CMD and SYG_LONG_JOB_CMD chain refusals/warnings,
# --wait-mem gate forwarding, missing lib/owner.sh, and real transient user units when a user
# systemd manager is available (explicit SKIP count otherwise).
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

unset SYG_LONG_JOB_STATE_DIR SYG_LONG_JOB_UNIT_PREFIX SYG_LONG_JOB_PARENT_CMD SYG_LONG_JOB_CMD
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
run bad/name -- true|NAME may hold only letters
run x|run needs -- before the command
run x -- |run needs a command after --
run x --bogus -- true|unknown run option --bogus
run x --wait-mem 0 -- true|--wait-mem needs at least 1 second
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

# --- new cases (a)-(g)
# (a) SYG_LONG_JOB_STATE_DIR=$tmp/sd puts NAME.cmd and NAME.owner under $tmp/sd, and status NAME finds it there.
timeout 5 env SYG_LONG_JOB_STATE_DIR="$tmp/sd" PATH="$tmp/stub:$PATH" "$LJ" run sd-job --min-mb 0 -- true >/dev/null 2>&1; rc=$?
out=$(timeout 5 env SYG_LONG_JOB_STATE_DIR="$tmp/sd" "$LJ" status sd-job 2>&1); rc2=$?
[ "$rc" = 0 ] && [ -s "$tmp/sd/sd-job.cmd" ] && [ -s "$tmp/sd/sd-job.owner" ] \
  && [ "$rc2" = 0 ] && [[ $out == "sd-job:"* ]] \
  && ok "(a) SYG_LONG_JOB_STATE_DIR puts NAME.cmd and NAME.owner under custom dir and status finds it" \
  || bad "(a) SYG_LONG_JOB_STATE_DIR (rc=$rc/$rc2, out=$out)"

# (b) SYG_LONG_JOB_UNIT_PREFIX=pfx: stub systemd-run records --unit=pfx-NAME.service and stub systemctl calls name pfx-NAME.service.
rm -f "$tmp/argv" "$tmp/systemctl-argv"
out=$(timeout 5 env SYG_LONG_JOB_UNIT_PREFIX=pfx PATH="$tmp/stub-rec:$PATH" "$LJ" run pfx-job --min-mb 0 -- true 2>&1); rc=$?
[ "$rc" = 0 ] && grep -qxF -- "--unit=pfx-pfx-job.service" "$tmp/argv" \
  && grep -qxF -- "pfx-pfx-job.service" "$tmp/systemctl-argv" \
  && ok "(b) SYG_LONG_JOB_UNIT_PREFIX=pfx passes --unit=pfx-NAME.service to systemd-run and pfx-NAME.service to systemctl" \
  || bad "(b) SYG_LONG_JOB_UNIT_PREFIX=pfx (rc=$rc, argv=$(tr '\n' ' ' <"$tmp/argv" 2>/dev/null), sysctl=$(tr '\n' ' ' <"$tmp/systemctl-argv" 2>/dev/null))"

# (c) SYG_LONG_JOB_UNIT_PREFIX='a b' exits 2 naming the knob; leading '-' exits 2 saying it must start with a letter or digit.
out=$(timeout 5 env SYG_LONG_JOB_UNIT_PREFIX='a b' PATH="$tmp/stub:$PATH" "$LJ" run bad-pfx --min-mb 0 -- true 2>&1); rc=$?
[ "$rc" = 2 ] && grep -q "SYG_LONG_JOB_UNIT_PREFIX" <<<"$out" \
  && ok "(c) SYG_LONG_JOB_UNIT_PREFIX='a b' exits 2 naming the knob" \
  || bad "(c) SYG_LONG_JOB_UNIT_PREFIX='a b' (rc=$rc: $out)"
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

# (d) && refusal through SYG_LONG_JOB_PARENT_CMD with SYG_LONG_JOB_CMD='jobrun run' alias.
err=$(timeout 5 env SYG_LONG_JOB_CMD='jobrun run' SYG_LONG_JOB_PARENT_CMD='jobrun run x --min-mb 0 -- true && echo after' PATH="$tmp/stub:$PATH" "$LJ" run x --min-mb 0 -- true 2>&1 >/dev/null); rc=$?
[ "$rc" = 2 ] && grep -q "^jobrun: refusing:" <<<"$err" && [ ! -e "$XDG_STATE_HOME/long-job/x.cmd" ] \
  && ok "(d) SYG_LONG_JOB_CMD='jobrun run' refuses && tail via SYG_LONG_JOB_PARENT_CMD with exit 2 and nothing recorded" \
  || bad "(d) alias && refusal (rc=$rc: $err)"

# (e) Old parent-cmd variable set to an && chain, with SYG_LONG_JOB_PARENT_CMD unset and run from a script (not bash -c), is ignored.
old_seam_var=OLD_JOB_PARENT_CMD
cat >"$tmp/run-from-script.sh" <<EOF
#!/usr/bin/env bash
exec "$LJ" run old-seam --min-mb 0 -- true
EOF
chmod +x "$tmp/run-from-script.sh"
out=$(timeout 5 env -u SYG_LONG_JOB_PARENT_CMD "${old_seam_var}=long-job run old-seam --min-mb 0 -- true && echo after" PATH="$tmp/stub:$PATH" bash "$tmp/run-from-script.sh" 2>&1); rc=$?
[ "$rc" = 0 ] && [ -s "$XDG_STATE_HOME/long-job/old-seam.cmd" ] \
  && ok "(e) old parent-cmd variable is ignored when SYG_LONG_JOB_PARENT_CMD is unset and run from a script" \
  || bad "(e) old parent-cmd variable not ignored (rc=$rc: $out)"

# (f) --wait-mem path: stub systemd-run records gate args carrying $REPO/plugins/seyag/bin/mem-gate,
# and mem-gate --wait 1 --timeout 1 --interval 1 --owner "" against a high fixture exits 0.
rm -f "$tmp/argv"
out=$(timeout 5 env PATH="$tmp/stub-rec:$PATH" "$LJ" run wm-job --min-mb 512 --wait-mem 10 -- true 2>&1); rc=$?
rec_mg=$(awk '/^--gate$/{getline; getline; getline; getline; print; exit}' "$tmp/argv")
printf 'MemTotal: 15000000 kB\nMemAvailable: 5242880 kB\nSwapTotal: 2097152 kB\nSwapFree: 1048576 kB\n' >"$tmp/meminfo-high"
timeout 5 env SYG_MEM_GATE_MEMINFO="$tmp/meminfo-high" "$MG" --wait 1 --timeout 1 --interval 1 --owner "" >/dev/null 2>&1; mg_rc=$?
[ "$rc" = 0 ] && grep -qxF -- "--gate" "$tmp/argv" && [ -n "$rec_mg" ] \
  && [ "$(readlink -f "$rec_mg")" = "$(readlink -f "$MG")" ] && [ "$mg_rc" = 0 ] \
  && ok "(f) --wait-mem passes $MG in gate args and mem-gate --wait with empty --owner exits 0" \
  || bad "(f) --wait-mem / mem-gate empty owner (rc=$rc, mg_rc=$mg_rc, rec_mg=$rec_mg, argv=$(tr '\n' ' ' <"$tmp/argv" 2>/dev/null))"

# (g) Copied bin/long-job without ../lib/owner.sh exits 2 with 'cannot load'.
mkdir -p "$tmp/solo/bin"
cp "$LJ" "$tmp/solo/bin/long-job"
out=$(timeout 5 "$tmp/solo/bin/long-job" status 2>&1); rc=$?
[ "$rc" = 2 ] && grep -q "cannot load" <<<"$out" \
  && ok "(g) long-job without lib/owner.sh exits 2 with 'cannot load'" \
  || bad "(g) solo without owner.sh (rc=$rc: $out)"

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
cleanup_units() { for s in ok bad stop gate race wq wr dollar; do systemctl --user stop "long-job-$p-$s.service" 2>/dev/null; systemctl --user reset-failed "long-job-$p-$s.service" 2>/dev/null; done; rm -rf "$tmp"; }
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
s=$SECONDS; out=$(timeout 5 "$LJ" wait "$p-stop" --poll --owner ""); rc=$?
[ "$rc" = 4 ] && [ $((SECONDS - s)) -le 2 ] && grep -q "$p-stop: running" <<<"$out" && ok "wait --poll on a running job exits 4 at once" || bad "wait --poll running (rc $rc: $out)"
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
unset SYG_MEM_GATE_MEMINFO

n=$(timeout 5 "$LJ" status | grep -c "^$p-")
[ "$n" = 7 ] && ok "status lists every recorded job" || bad "status lists $n jobs, want 7"

echo "long-job probe: $pass passed, $fail failed"
[ "$fail" = 0 ]
