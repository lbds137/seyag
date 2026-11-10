#!/bin/bash
# Fixture check for plugins/seyag/bin/pr-ci-wait — run after ANY edit to it.
#
# Never touches GitHub: a fake `gh` is put first on PATH. It ignores the real
# `--jq`/`--json` filters and returns fixtures already in POST-filter shape
# (same limitation Tzurot's own pr-monitor-reminder.probe.sh documents for its
# gh shim) — this probe pins pr-ci-wait's parsing of that shape, not whether
# real `gh` still produces it.
#
# HERMETIC BY CONSTRUCTION — no dependency on the checkout this probe runs
# from, or on anything in the calling shell's ambient environment:
#   - `git` runs against a disposable FIXTURE_REPO (`git init` + a commit +
#     its own `.github/workflows/claude-code-review.yml`) built fresh under
#     this probe's own mktemp dir, never this repo's real HEAD or real
#     workflow files. Every `pr-ci-wait` invocation runs with that repo as
#     its cwd.
#   - Every invocation goes through `env -i` (a CLEARED environment, not
#     `env VAR=val ... cmd`, which only ADDS to/overrides the inherited one):
#     an ambient `SYG_CI_ANCHOR` (this project's own `.claude/settings.json`
#     sets one, and Claude Code injects a project's settings `env` block into
#     every Bash tool call) previously leaked straight through every case that
#     didn't explicitly override it, silently switching a "no anchor
#     configured" case into anchor mode. MEASURED 2026-09-27: with
#     SYG_CI_ANCHOR=Probes actually exported (as it was live at the time),
#     the quiet-window case's fixture never named a "Probes" run, so
#     `anchor_complete` was never true and the gate burned the entire
#     PR_CI_WAIT_MAX_S before giving up — CI_GATE_TIMEOUT instead of
#     CI_COMPLETE. At the ~600s several cases used for that ceiling (meant as
#     "large enough never to be hit", not as a real wait), that is the
#     multi-minute hang a later run-probes.sh call reproduced from the main
#     checkout, on a DIFFERENT (post-merge) HEAD — the specific SHA on that
#     HEAD was never the mechanism; the leaked ambient env var was.
#   - No case's ceiling exceeds a few seconds (see PR_CI_WAIT_MAX_S below);
#     `run()` additionally wraps every invocation in `timeout` so a
#     regression that DOES hang fails loudly, naming the case, rather than
#     wedging the whole `run-probes.sh` gate silently.
#
# Usage: tests/pr-ci-wait.probe.sh   (from anywhere — this file and the `..`
# relative BIN path below are the only two paths that matter; copying both
# to a directory outside any git repo and running from there is exactly how
# hermeticity was verified, see the unit's report)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN="$SCRIPT_DIR/../plugins/seyag/bin/pr-ci-wait"
[ -f "$BIN" ] || BIN="$SCRIPT_DIR/pr-ci-wait"  # scratch-copy layout (probe + bin side by side)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAKE_BIN="$WORK/fakebin"
mkdir -p "$FAKE_BIN"

# --- the fixture repo --------------------------------------------------------
# Disposable, built fresh every run. Its own workflow file (not this repo's)
# is what the review-auto-detect case (12) actually detects.
FIXTURE_REPO="$WORK/fixture-repo"
mkdir -p "$FIXTURE_REPO/.github/workflows"
git -C "$FIXTURE_REPO" init -q
cat > "$FIXTURE_REPO/.github/workflows/claude-code-review.yml" <<'YML'
name: Claude Code Review
on: pull_request
jobs:
  review:
    runs-on: ubuntu-latest
    steps:
      - run: echo fixture
YML
git -C "$FIXTURE_REPO" add -A
git -C "$FIXTURE_REPO" -c user.email=t@t -c user.name=t commit -q -m "fixture"
FIXTURE_HEAD_SHA=$(git -C "$FIXTURE_REPO" rev-parse HEAD)

# --- the gh shim -------------------------------------------------------------
# Driven entirely by env vars the cases set:
#   FAKE_GH_HEAD_SHA   stdout for `api repos/.../pulls/N --jq .head.sha`
#   FAKE_GH_HEAD_EXIT  its exit code (default 0)
#   FAKE_GH_SEQ_DIR    dir of step-NNN.json (or .err) fixtures for the runs
#                       poll; each call advances a counter, clamped to the
#                       last fixture (repeat-last), so a case that never
#                       "completes" naturally exercises the timeout path
#   FAKE_GH_CHECKS_EXIT exit code for `pr checks` report pass (default 0;
#                       ignored either way per the real command's contract)
#   FAKE_GH_WATCH_SLEEP seconds `pr checks --watch` hangs before returning
#                       (default: returns at once)
#   FAKE_GH_JOBS_LOG    file the per-run jobs endpoints are appended to, one
#                       line per call (unset: not logged)
#   FAKE_GH_JOBS_TOTAL  bare integer the jobs endpoint prints (default 1)
#   FAKE_GH_JOBS_ERR_ONCE a file path: while it exists, the next jobs call
#                       deletes it and fails with `gh: HTTP 502`
cat > "$FAKE_BIN/gh" <<'SHIM'
#!/bin/bash
set -uo pipefail
CMD="${1:-}"; shift || true
case "$CMD" in
  api)
    ENDPOINT="${1:-}"
    case "$ENDPOINT" in
      */pulls/*)
        echo "${FAKE_GH_HEAD_SHA:-}"
        exit "${FAKE_GH_HEAD_EXIT:-0}"
        ;;
      */actions/runs/*/jobs*)
        [ -n "${FAKE_GH_JOBS_LOG:-}" ] && echo "$ENDPOINT" >> "$FAKE_GH_JOBS_LOG"
        if [ -n "${FAKE_GH_JOBS_ERR_ONCE:-}" ] && [ -e "$FAKE_GH_JOBS_ERR_ONCE" ]; then
          rm -f "$FAKE_GH_JOBS_ERR_ONCE"
          echo "gh: HTTP 502" >&2
          exit 1
        fi
        echo "${FAKE_GH_JOBS_TOTAL:-1}"
        exit 0
        ;;
      */actions/runs\?*)
        SEQ_DIR="${FAKE_GH_SEQ_DIR:?FAKE_GH_SEQ_DIR unset}"
        CNT_FILE="$SEQ_DIR/.count"
        N=$(( $(cat "$CNT_FILE" 2>/dev/null || echo 0) + 1 ))
        echo "$N" > "$CNT_FILE"
        LAST=$(find "$SEQ_DIR" -maxdepth 1 -name 'step-*.json' | wc -l)
        USE=$N
        [ "$USE" -gt "$LAST" ] && USE=$LAST
        [ "$USE" -lt 1 ] && { echo "fake-gh: no step fixtures in $SEQ_DIR" >&2; exit 1; }
        STEP=$(printf 'step-%03d' "$USE")
        if [ -f "$SEQ_DIR/$STEP.err" ]; then
          cat "$SEQ_DIR/$STEP.err" >&2
          exit 1
        fi
        cat "$SEQ_DIR/$STEP.json"
        exit 0
        ;;
      *)
        echo "fake-gh: unhandled api endpoint: $ENDPOINT" >&2
        exit 1
        ;;
    esac
    ;;
  pr)
    SUB="${1:-}"; shift || true
    case "$SUB" in
      checks)
        case " $* " in
          *" --watch "*) [ -n "${FAKE_GH_WATCH_SLEEP:-}" ] && exec sleep "$FAKE_GH_WATCH_SLEEP" ;;
        esac
        echo "fake-checks-report pr=${1:-?}"
        exit "${FAKE_GH_CHECKS_EXIT:-0}"
        ;;
      *) echo "fake-gh: unhandled pr subcommand: $SUB" >&2; exit 1 ;;
    esac
    ;;
  *)
    echo "fake-gh: unhandled command: $CMD" >&2
    exit 1
    ;;
esac
SHIM
chmod +x "$FAKE_BIN/gh"

FAILURES=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# CASE_TIMEOUT bounds each invocation from the OUTSIDE, independent of
# whatever PR_CI_WAIT_MAX_S the case itself sets: a regression that makes the
# gate ignore its own ceiling (or reintroduces an ambient-env leak this
# rewrite just closed) fails LOUDLY, naming the case, in a few seconds —
# never a silent multi-minute wedge of the whole run-probes.sh gate.
CASE_TIMEOUT=15

# run <label> <expected-exit> <extra-env...> -- runs pr-ci-wait under
# `timeout`, capturing combined stdout+stderr into $OUT and exit code into
# $RC. A `timeout`-caused kill (rc 124) is reported as its own distinct
# failure shape, never silently treated as a wrong-exit-code case.
run() {
  local label="$1" expected_rc="$2"; shift 2
  # `env -i` (a CLEARED environment) rather than `env VAR=val ... cmd`, which
  # only ADDS to/overrides whatever the calling shell already exports: see
  # the file header for the ambient SYG_CI_ANCHOR leak this closes.
  # PATH and HOME are the only ambient-adjacent values let through — git
  # needs HOME to find a global config (harmless here; identity is always
  # passed with -c on every fixture commit) and PATH to find `git`/`gh`/
  # `python3`. Every PR_CI_WAIT_* default below IS the case's env, in full;
  # nothing is inherited around it.
  #
  # `"$@"` supplies extra per-case assignments as arguments — themselves the
  # RESULT of an earlier expansion — which `env` recognizes regardless (bash
  # only treats a LITERAL, parse-time NAME=value token as an inline
  # assignment prefix; env inspects each argv string at runtime instead).
  #
  # The MAX_S and GRACE_S defaults are give-up ceilings that only a case
  # asserting a give-up reaches, and every such case sets its own short value;
  # a sub-second default let a loaded machine end a releasing case early
  # (CI_GATE_TIMEOUT/review-missing after 2 of 3 polls).
  OUT=$(cd "$FIXTURE_REPO" && timeout "$CASE_TIMEOUT" env -i \
    PATH="$FAKE_BIN:$PATH" HOME="$HOME" PYTHONDONTWRITEBYTECODE=1 \
    PR_CI_WAIT_POLL_S="${PR_CI_WAIT_POLL_S:-0.05}" \
    PR_CI_WAIT_MAX_S="${PR_CI_WAIT_MAX_S:-5}" \
    PR_CI_WAIT_GRACE_S="${PR_CI_WAIT_GRACE_S:-5}" \
    PR_CI_WAIT_HEARTBEAT_S="${PR_CI_WAIT_HEARTBEAT_S:-600}" \
    PR_CI_WAIT_SETTLE_S="${PR_CI_WAIT_SETTLE_S:-0}" \
    PR_CI_WAIT_QUIET_S="${PR_CI_WAIT_QUIET_S:-0.3}" \
    "$@" "$BIN" 8 --sha "$SHA_ARG" 2>&1)
  RC=$?
  if [ "$RC" -eq 124 ]; then
    fail "$label (TIMED OUT after ${CASE_TIMEOUT}s — this case hung; see output)"
    printf '%s\n' "$OUT" | sed 's/^/      /'
  elif [ "$RC" -eq "$expected_rc" ]; then
    pass "$label (exit $RC)"
  else
    fail "$label (exit $RC, expected $expected_rc)"
    printf '%s\n' "$OUT" | sed 's/^/      /'
  fi
}

# seq_dir <name> <json...> — writes one step-NNN.json fixture per argument.
seq_dir() {
  local dir="$WORK/$1"; shift
  mkdir -p "$dir"
  local i=1
  for payload in "$@"; do
    printf '%s' "$payload" > "$dir/$(printf 'step-%03d' "$i").json"
    i=$((i + 1))
  done
  printf '%s' "$dir"
}

DONE_CI='{"id":1,"name":"CI","status":"completed","conclusion":"success"}'
DONE_REVIEW='{"id":2,"name":"Claude Code Review","status":"completed","conclusion":"success"}'
PENDING_CI='{"id":1,"name":"CI","status":"in_progress","conclusion":null}'
INFLIGHT_REVIEW='{"id":2,"name":"Claude Code Review","status":"in_progress","conclusion":null}'
STARTUP_FAIL='{"id":9,"name":"Deploy","status":"completed","conclusion":"startup_failure"}'

SHA_ARG="$FIXTURE_HEAD_SHA"

# --- 1. abbreviated sha rejected, exit 2, no network ------------------------
SHA_ARG="abc123" run "abbreviated sha rejected" 2
[[ "$OUT" == *"40-character SHA"* ]] && pass "abbreviated sha: message names the requirement" \
  || fail "abbreviated sha: message names the requirement"
SHA_ARG="$FIXTURE_HEAD_SHA"

# --- 2. head mismatch -> exit 2 (real ~3s recheck) --------------------------
run "head mismatch after recheck -> exit 2" 2 \
  FAKE_GH_HEAD_SHA="$(printf 'b%.0s' {1..40})"
[[ "$OUT" == *"is not the head of PR #8"* ]] && pass "head mismatch: names the PR" \
  || fail "head mismatch: names the PR"

# --- 3. head unreadable -> warns and continues ------------------------------
D=$(seq_dir unreadable "[$DONE_CI]")
run "head unreadable -> warns, continues, releases" 0 \
  FAKE_GH_HEAD_EXIT=1 FAKE_GH_SEQ_DIR="$D" SYG_CI_REVIEW= SYG_CI_ANCHOR=CI
[[ "$OUT" == *"Could not read the PR head"* && "$OUT" == *"CI_COMPLETE"* ]] \
  && pass "head unreadable: warns and still releases" \
  || fail "head unreadable: warns and still releases"

# --- 4. anchor mode: releases only when anchor complete AND nothing pending
#         AND review complete (review left to auto-detect, matching
#         DONE_REVIEW's name and the fixture repo's own workflow file) ------
mkdir -p "$WORK/anchor-release"
printf '[%s]' "$PENDING_CI" > "$WORK/anchor-release/step-001.json"
printf '[%s,%s]' "$DONE_CI" "$DONE_REVIEW" > "$WORK/anchor-release/step-002.json"
run "anchor+pending+review all required" 0 \
  FAKE_GH_SEQ_DIR="$WORK/anchor-release" SYG_CI_ANCHOR=CI
[[ "$OUT" == *"CI_COMPLETE"* ]] && pass "anchor mode releases once all three hold" \
  || fail "anchor mode releases once all three hold"
[ "$(cat "$WORK/anchor-release/.count" 2>/dev/null)" = "2" ] \
  && pass "anchor mode: did not release at step 1 (still pending)" \
  || fail "anchor mode: did not release at step 1 (still pending) (count=$(cat "$WORK/anchor-release/.count" 2>/dev/null))"

# --- 5. review run appearing in flight holds release until complete --------
mkdir -p "$WORK/review-inflight"
printf '[%s]' "$DONE_CI" > "$WORK/review-inflight/step-001.json"
printf '[%s,%s]' "$DONE_CI" "$INFLIGHT_REVIEW" > "$WORK/review-inflight/step-002.json"
printf '[%s,%s]' "$DONE_CI" "$DONE_REVIEW" > "$WORK/review-inflight/step-003.json"
run "in-flight review holds release until complete" 0 \
  FAKE_GH_SEQ_DIR="$WORK/review-inflight" SYG_CI_ANCHOR=CI
[[ "$OUT" == *"CI_COMPLETE"* ]] && pass "in-flight review eventually releases" \
  || fail "in-flight review eventually releases"
[ "$(cat "$WORK/review-inflight/.count" 2>/dev/null)" = "3" ] \
  && pass "in-flight review: held through steps 1-2, released only at step 3" \
  || fail "in-flight review: held through steps 1-2, released only at step 3 (count=$(cat "$WORK/review-inflight/.count" 2>/dev/null))"

# --- 6. review missing after grace -> CI_GATE_REVIEW_MISSING, exit 1 -------
# PR_CI_WAIT_MAX_S=5, not 600: the case must resolve via the (short) grace
# window well before that ceiling — 5s is still generous headroom, not the
# "hope it never matters" 600s the pre-fix version relied on.
D=$(seq_dir review-missing "[$DONE_CI]")
run "review missing after grace -> CI_GATE_REVIEW_MISSING" 1 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=CI PR_CI_WAIT_GRACE_S=0.2 PR_CI_WAIT_MAX_S=5
[[ "$OUT" == *"CI_GATE_REVIEW_MISSING"* && "$OUT" != *"CI_COMPLETE"* ]] \
  && pass "review-missing sentinel, never CI_COMPLETE" \
  || fail "review-missing sentinel, never CI_COMPLETE"

# --- 7. startup_failure on a non-anchor workflow -> immediate exit ---------
D=$(seq_dir startup "[$STARTUP_FAIL]")
run "startup_failure -> CI_GATE_STARTUP_FAILURE with rerun cmd" 1 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=CI SYG_CI_REVIEW= PR_CI_WAIT_MAX_S=5
[[ "$OUT" == *"CI_GATE_STARTUP_FAILURE"* && "$OUT" == *"gh run rerun 9"* ]] \
  && pass "startup_failure names the rerun command" \
  || fail "startup_failure names the rerun command"

# --- 7b. positive control: a failed run WITH jobs releases, and the job-count
#          lookup is cached across polls and pins the attempt. Step 1 holds a
#          second run in flight so the failed run is seen on two polls. ------
FAIL_WITH_JOBS='{"id":5,"name":"CI","status":"completed","conclusion":"failure","run_attempt":1}'
LINT_PENDING='{"id":6,"name":"Lint","status":"in_progress","conclusion":null,"run_attempt":1}'
JOBS_LOG_7B="$WORK/jobs-7b.log"
D=$(seq_dir failed-with-jobs "[$FAIL_WITH_JOBS,$LINT_PENDING]" "[$FAIL_WITH_JOBS]")
run "failed run with jobs releases" 0 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=CI SYG_CI_REVIEW= PR_CI_WAIT_MAX_S=5 \
  FAKE_GH_JOBS_LOG="$JOBS_LOG_7B" FAKE_GH_JOBS_TOTAL=3
[[ "$OUT" == *"CI_COMPLETE"* && "$OUT" != *"CI_GATE_STARTUP_FAILURE"* ]] \
  && pass "failed run with jobs: CI_COMPLETE, no startup sentinel" \
  || fail "failed run with jobs: CI_COMPLETE, no startup sentinel"
[ "$(cat "$D/.count" 2>/dev/null)" = "2" ] \
  && pass "failed run with jobs: two polls, so the cache was exercised" \
  || fail "failed run with jobs: two polls, so the cache was exercised (count=$(cat "$D/.count" 2>/dev/null))"
JOBS_LINES_7B=$(wc -l < "$JOBS_LOG_7B" 2>/dev/null || echo 0)
[ "$JOBS_LINES_7B" -eq 1 ] && grep -q 'runs/5/attempts/1/jobs' "$JOBS_LOG_7B" \
  && pass "failed run with jobs: one lookup across all polls, on the pinned attempt" \
  || fail "failed run with jobs: one lookup across all polls, on the pinned attempt (lines=$JOBS_LINES_7B)"

# --- 7c. a failed run that created zero jobs -> startup-failure sentinel ----
FAIL_ZERO='{"id":7,"name":"CI","status":"completed","conclusion":"failure","run_attempt":1}'
D=$(seq_dir zero-job "[$FAIL_ZERO]")
run "zero-job failure -> CI_GATE_STARTUP_FAILURE" 1 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=CI SYG_CI_REVIEW= PR_CI_WAIT_MAX_S=5 \
  FAKE_GH_JOBS_TOTAL=0
[[ "$OUT" == *"CI_GATE_STARTUP_FAILURE"* && "$OUT" == *"gh run rerun 7"* \
   && "$OUT" == *"zero jobs"* && "$OUT" == *"failed with zero jobs"* && "$OUT" != *"CI_COMPLETE"* ]] \
  && pass "zero-job failure: sentinel, rerun command, never CI_COMPLETE" \
  || fail "zero-job failure: sentinel, rerun command, never CI_COMPLETE"

# --- 7d. no lookup for a run that is not a failure ---------------------------
JOBS_LOG_7D="$WORK/jobs-7d.log"
D=$(seq_dir success-only "[$DONE_CI]")
run "success run releases without a job lookup" 0 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=CI SYG_CI_REVIEW= PR_CI_WAIT_MAX_S=5 \
  FAKE_GH_JOBS_LOG="$JOBS_LOG_7D" FAKE_GH_JOBS_TOTAL=0
[ ! -e "$JOBS_LOG_7D" ] \
  && pass "success run: the jobs endpoint was never called" \
  || fail "success run: the jobs endpoint was never called"

# --- 7e. startup_failure AND a zero-job failure: both reported, one exit ----
D=$(seq_dir startup-and-zero "[$STARTUP_FAIL,$FAIL_ZERO]")
run "startup_failure plus zero-job failure" 1 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=CI SYG_CI_REVIEW= PR_CI_WAIT_MAX_S=5 \
  FAKE_GH_JOBS_TOTAL=0
[[ "$OUT" == *"CI_GATE_STARTUP_FAILURE"* && "$OUT" == *"died before dispatch"* \
   && "$OUT" == *"zero jobs"* && "$OUT" == *"failed with zero jobs"* \
   && "$OUT" == *"Rerun all with: gh run rerun 9 && gh run rerun 7"* ]] \
  && pass "both kinds: the startup line is kept and the zero-job line names both reruns" \
  || fail "both kinds: the startup line is kept and the zero-job line names both reruns"

# --- 7f. a failed job-count lookup is a failed poll, retried, never cached --
ERR_ONCE_7F="$WORK/jobs-err-once"
: > "$ERR_ONCE_7F"
D=$(seq_dir lookup-error "[$FAIL_ZERO]")
run "failed jobs lookup is retried, then flags the zero-job run" 1 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=CI SYG_CI_REVIEW= PR_CI_WAIT_MAX_S=5 \
  FAKE_GH_JOBS_TOTAL=0 FAKE_GH_JOBS_ERR_ONCE="$ERR_ONCE_7F"
[[ "$OUT" == *"gh api failed (1x)"* && "$OUT" == *"CI_GATE_STARTUP_FAILURE"* ]] \
  && pass "jobs lookup error: counted as a failed poll, retried, then flagged" \
  || fail "jobs lookup error: counted as a failed poll, retried, then flagged"

# --- 7g. run_attempt >= 2: the lookup pins that attempt ----------------------
JOBS_LOG_7G="$WORK/jobs-7g.log"
D=$(seq_dir attempt-two '[{"id":12,"name":"CI","status":"completed","conclusion":"failure","run_attempt":2}]')
run "zero-job failure on attempt 2 -> CI_GATE_STARTUP_FAILURE" 1 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=CI SYG_CI_REVIEW= PR_CI_WAIT_MAX_S=5 \
  FAKE_GH_JOBS_LOG="$JOBS_LOG_7G" FAKE_GH_JOBS_TOTAL=0
[[ "$OUT" == *"CI_GATE_STARTUP_FAILURE"* ]] && grep -q 'runs/12/attempts/2/jobs' "$JOBS_LOG_7G" \
  && pass "attempt 2: sentinel, and the lookup hit runs/12/attempts/2/jobs" \
  || fail "attempt 2: sentinel, and the lookup hit runs/12/attempts/2/jobs"

# --- 7h. no run_attempt on the run object: the plain jobs endpoint -----------
JOBS_LOG_7H="$WORK/jobs-7h.log"
D=$(seq_dir attempt-missing '[{"id":13,"name":"CI","status":"completed","conclusion":"failure"}]')
run "zero-job failure without run_attempt -> CI_GATE_STARTUP_FAILURE" 1 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=CI SYG_CI_REVIEW= PR_CI_WAIT_MAX_S=5 \
  FAKE_GH_JOBS_LOG="$JOBS_LOG_7H" FAKE_GH_JOBS_TOTAL=0
[[ "$OUT" == *"CI_GATE_STARTUP_FAILURE"* ]] && grep -q 'runs/13/jobs' "$JOBS_LOG_7H" \
  && ! grep -q 'attempts' "$JOBS_LOG_7H" \
  && pass "no run_attempt: sentinel, and the lookup hit runs/13/jobs without attempts" \
  || fail "no run_attempt: sentinel, and the lookup hit runs/13/jobs without attempts"

# --- 7i. a cancelled zero-job run is not checked ----------------------------
JOBS_LOG_7I="$WORK/jobs-7i.log"
D=$(seq_dir cancelled-zero '[{"id":14,"name":"CI","status":"completed","conclusion":"cancelled","run_attempt":1}]')
run "cancelled zero-job run releases" 0 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=CI SYG_CI_REVIEW= PR_CI_WAIT_MAX_S=5 \
  FAKE_GH_JOBS_LOG="$JOBS_LOG_7I" FAKE_GH_JOBS_TOTAL=0
[[ "$OUT" == *"CI_COMPLETE"* ]] && [ ! -e "$JOBS_LOG_7I" ] \
  && pass "cancelled run: CI_COMPLETE, the jobs endpoint was never called" \
  || fail "cancelled run: CI_COMPLETE, the jobs endpoint was never called"

# --- 7j. quiet-window mode (no anchor) still flags a zero-job failure --------
D=$(seq_dir quiet-zero "[$FAIL_ZERO]")
run "quiet-window mode: zero-job failure -> CI_GATE_STARTUP_FAILURE" 1 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_REVIEW= PR_CI_WAIT_MAX_S=5 FAKE_GH_JOBS_TOTAL=0
[[ "$OUT" == *"CI_GATE_STARTUP_FAILURE"* && "$OUT" == *"quiet-window rule"* ]] \
  && pass "quiet-window mode: the zero-job failure takes the startup sentinel" \
  || fail "quiet-window mode: the zero-job failure takes the startup sentinel"

# --- 7k. a lookup error on one run does not hide a startup_failure run -------
JOBS_LOG_7K="$WORK/jobs-7k.log"
ERR_ONCE_7K="$WORK/jobs-err-once-7k"
: > "$ERR_ONCE_7K"
D=$(seq_dir lookup-error-startup "[$STARTUP_FAIL,$FAIL_ZERO]")
run "lookup error beside a startup_failure run" 1 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=CI SYG_CI_REVIEW= PR_CI_WAIT_MAX_S=5 \
  FAKE_GH_JOBS_TOTAL=0 FAKE_GH_JOBS_ERR_ONCE="$ERR_ONCE_7K" FAKE_GH_JOBS_LOG="$JOBS_LOG_7K"
JOBS_LINES_7K=$(wc -l < "$JOBS_LOG_7K" 2>/dev/null || echo 0)
[[ "$OUT" == *"CI_GATE_STARTUP_FAILURE"* && "$OUT" == *"died before dispatch"* \
   && "$OUT" == *"gh run rerun 9"* && "$OUT" == *"gh api failed (1x)"* \
   && "$OUT" == *"job count for CI (run 7)"* ]] \
  && pass "lookup error: the startup run is reported and the error names the run" \
  || fail "lookup error: the startup run is reported and the error names the run"
[ "$JOBS_LINES_7K" -eq 1 ] \
  && pass "lookup error: the gate exited on the first poll (one lookup)" \
  || fail "lookup error: the gate exited on the first poll (lines=$JOBS_LINES_7K)"

# --- 7l. a lookup error holds release until the lookup succeeds --------------
JOBS_LOG_7L="$WORK/jobs-7l.log"
ERR_ONCE_7L="$WORK/jobs-err-once-7l"
: > "$ERR_ONCE_7L"
D=$(seq_dir lookup-error-holds '[{"id":5,"name":"CI","status":"completed","conclusion":"failure","run_attempt":1}]')
run "lookup error holds release, then releases once it succeeds" 0 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=CI SYG_CI_REVIEW= PR_CI_WAIT_MAX_S=5 \
  FAKE_GH_JOBS_TOTAL=3 FAKE_GH_JOBS_ERR_ONCE="$ERR_ONCE_7L" FAKE_GH_JOBS_LOG="$JOBS_LOG_7L"
JOBS_LINES_7L=$(wc -l < "$JOBS_LOG_7L" 2>/dev/null || echo 0)
POLLS_7L=$(cat "$D/.count" 2>/dev/null || echo 0)
[[ "$OUT" == *"CI_COMPLETE"* && "$OUT" == *"gh api failed (1x)"* && "$OUT" == *"recovered after 1"* ]] \
  && pass "lookup error hold: error logged, recovery logged, CI_COMPLETE" \
  || fail "lookup error hold: error logged, recovery logged, CI_COMPLETE"
[ "$POLLS_7L" -ge 2 ] && [ "$JOBS_LINES_7L" -eq 2 ] \
  && pass "lookup error hold: not released on the errored poll (polls=$POLLS_7L, lookups=$JOBS_LINES_7L)" \
  || fail "lookup error hold: not released on the errored poll (polls=$POLLS_7L, lookups=$JOBS_LINES_7L)"

# --- 8. gh api errors reported after threshold, recovery logged ------------
mkdir -p "$WORK/errors"
for i in $(seq 1 10); do
  printf 'gh: HTTP 500\n' > "$WORK/errors/$(printf 'step-%03d' "$i").err"
  printf '[]' > "$WORK/errors/$(printf 'step-%03d' "$i").json"  # unused (err wins)
done
printf '[%s]' "$DONE_CI" > "$WORK/errors/step-011.json"
run "gh api failures: first + 10th reported, recovery logged" 0 \
  FAKE_GH_SEQ_DIR="$WORK/errors" SYG_CI_ANCHOR=CI SYG_CI_REVIEW= PR_CI_WAIT_MAX_S=5
[[ "$OUT" == *"gh api failed (1x)"* && "$OUT" == *"gh api failed (10x)"* \
   && "$OUT" == *"recovered after 10"* ]] \
  && pass "error throttling: 1st and 10th reported, recovery logged" \
  || fail "error throttling: 1st and 10th reported, recovery logged"

# --- 9. timeout -> CI_GATE_TIMEOUT, exit 1 ----------------------------------
D=$(seq_dir never-settles "[$PENDING_CI]")
run "gate gives up -> CI_GATE_TIMEOUT" 1 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=CI SYG_CI_REVIEW= PR_CI_WAIT_MAX_S=0.15
[[ "$OUT" == *"CI_GATE_TIMEOUT"* && "$OUT" == *"gave up"* ]] \
  && pass "timeout sentinel and message" \
  || fail "timeout sentinel and message"

# --- 10. final `gh pr checks` printed on every outcome ----------------------
[[ "$OUT" == *"fake-checks-report pr=8"* ]] && pass "final checks report printed (timeout case)" \
  || fail "final checks report printed (timeout case)"

# --- 11. quiet-window mode: releases only after the window, unchanged ------
#          set; a run appearing inside the window restarts it --------------
# Deterministic via PR_CI_WAIT_FAKE_TICK_S: the quiet-window clock advances
# by a fixed amount (FAKE_TICK_S) per poll instead of wall time, so the poll
# count at release is exact — no wall-clock jitter under load to drift it.
# With ids stay UNCHANGED for six settled polls (steps 2-7) before a NEW run
# id appears at step 8 (then clamped/repeated), and FAKE_TICK_S=1,
# QUIET_S=10, POLL_S=0.01:
#   - restart WORKS (the shipped `self.ids != state["run_ids"]` check): the
#     clock resets at step 8 (poll 8, tick=7, since=7); release needs
#     (since=7) + QUIET_S(10) = tick 17, i.e. poll 18. QUIET_COUNT == 18.
#   - restart is DROPPED (mutated to `self.ids is None`, so a changed id set
#     no longer resets the clock): the clock is set once at step 2 (poll 2,
#     tick=1, since=1) and never resets, so release needs tick 11, i.e.
#     poll 12. QUIET_COUNT == 12 on the broken path — confirmed by the
#     mutation check below.
mkdir -p "$WORK/quiet"
printf '[%s]' "$PENDING_CI" > "$WORK/quiet/step-001.json"           # still pending
for n in 2 3 4 5 6 7; do
  printf '[%s]' "$DONE_CI" > "$WORK/quiet/step-00$n.json"           # same id; clock ticking since step 2
done
printf '[%s,%s]' "$DONE_CI" '{"id":3,"name":"Extra","status":"completed","conclusion":"success"}' \
  > "$WORK/quiet/step-008.json"                                     # NEW run id at step 8 -> restarts clock
run "quiet-window mode settles after the window, restarted by a new run" 0 \
  FAKE_GH_SEQ_DIR="$WORK/quiet" SYG_CI_REVIEW= PR_CI_WAIT_FAKE_TICK_S=1 \
  PR_CI_WAIT_QUIET_S=10 PR_CI_WAIT_POLL_S=0.01 PR_CI_WAIT_MAX_S=5
[[ "$OUT" == *"CI_COMPLETE"* && "$OUT" == *"quiet-window rule"* ]] \
  && pass "quiet-window mode releases and names the rule" \
  || fail "quiet-window mode releases and names the rule"
QUIET_COUNT=$(cat "$WORK/quiet/.count" 2>/dev/null || echo 0)
# 18 is the exact poll count the restarting (correct) path settles at; the
# broken (non-restarting) path would settle at exactly 12 (see mutation
# check below) — deterministic under the fake clock, no band needed.
[ "$QUIET_COUNT" -eq 18 ] \
  && pass "quiet-window mode: waited a full window AFTER the restart, not just from the first settle (count=$QUIET_COUNT)" \
  || fail "quiet-window mode: waited a full window after the restart (count=$QUIET_COUNT, want 18)"

# --- 12. review auto-detect from the FIXTURE repo's own workflow file ------
D=$(seq_dir autodetect-review "[$PENDING_CI]")
run "review auto-detected from the fixture repo's own workflow file" 1 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=CI PR_CI_WAIT_MAX_S=0.1
[[ "$OUT" == *'auto-detected from a workflow file'* && "$OUT" == *'"Claude Code Review"'* ]] \
  && pass "review auto-detect fires and names the workflow" \
  || fail "review auto-detect fires and names the workflow"

# --- 13. SYG_CI_REVIEW= disables the assertion -------------------------------
D=$(seq_dir review-disabled "[$DONE_CI]")
run "SYG_CI_REVIEW= disables the review assertion" 0 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=CI SYG_CI_REVIEW=
[[ "$OUT" == *"disabled (SYG_CI_REVIEW="* && "$OUT" == *"CI_COMPLETE"* ]] \
  && pass "explicit empty SYG_CI_REVIEW disables the assertion" \
  || fail "explicit empty SYG_CI_REVIEW disables the assertion"

# --- 13d. SYG_CI_REVIEW set-but-EMPTY disables even though auto-detection ----
#          names a workflow. Presence, not truthiness: an empty SYG_CI_REVIEW
#          must disable the assertion rather than fall through to the
#          auto-detection (case 12 proves it finds the fixture's "Claude Code
#          Review" workflow, whose run the fixture never produces — a
#          fall-through would end CI_GATE_REVIEW_MISSING, exit 1).
D=$(seq_dir syg-review-empty "[$DONE_CI]")
run "SYG_CI_REVIEW= disables even though auto-detection names a workflow" 0 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=CI SYG_CI_REVIEW=
[[ "$OUT" == *"disabled (SYG_CI_REVIEW="* && "$OUT" == *"CI_COMPLETE"* ]] \
  && pass "SYG_CI_REVIEW set-but-empty disables the assertion (presence, not truthiness)" \
  || fail "SYG_CI_REVIEW set-but-empty disables the assertion (presence, not truthiness)"

# --- 14. --help prints the docstring, exit 0 --------------------------------
HELP_OUT=$(timeout "$CASE_TIMEOUT" env -i PATH="$PATH" HOME="$HOME" PYTHONDONTWRITEBYTECODE=1 "$BIN" --help 2>&1)
HELP_RC=$?
[[ "$HELP_RC" -eq 0 && "$HELP_OUT" == *"pr-ci-wait N [--sha FULL40]"* ]] \
  && pass "--help prints usage (exit 0)" \
  || fail "--help prints usage (exit 0)"

# --- 15. ambient-env leak stays closed: SYG_CI_ANCHOR set in the CALLING
#          shell (simulating this project's own settings.json env block, or
#          any other project that happens to export it) must NOT leak into a
#          case that never asked for an anchor -------------------------------
export SYG_CI_ANCHOR=Probes  # exported in THIS probe's own shell on purpose
D=$(seq_dir ambient-leak-check "[$DONE_CI]")
# PR_CI_WAIT_MAX_S must comfortably exceed PR_CI_WAIT_QUIET_S (5s vs 0.3s,
# matching run()'s defaults) — under load equal values race, timing out just
# short of the quiet window and reading as a false regression rather than a real one.
run "ambient SYG_CI_ANCHOR in the CALLING shell does not leak in" 0 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_REVIEW= PR_CI_WAIT_QUIET_S=0.3 PR_CI_WAIT_POLL_S=0.1 PR_CI_WAIT_MAX_S=5
unset SYG_CI_ANCHOR
[[ "$OUT" == *"CI_COMPLETE"* && "$OUT" == *"quiet-window rule"* ]] \
  && pass "ambient leak check: quiet-window rule used, not the leaked anchor" \
  || { fail "ambient leak check: quiet-window rule used, not the leaked anchor"; printf '%s\n' "$OUT" | sed 's/^/      /'; }

# --- 16. a `gh pr checks --watch` that outlives the budget is stopped (the
#          floor is 5s), warned about, and the decided sentinel still prints --
D=$(seq_dir watch-hangs "[$DONE_CI]")
START16=$(date +%s)
run "a hung --watch is bounded by the remaining budget" 0 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=CI SYG_CI_REVIEW= PR_CI_WAIT_MAX_S=0.5 FAKE_GH_WATCH_SLEEP=60
ELAPSED16=$(( $(date +%s) - START16 ))
[[ "$OUT" == *"--watch\` still running after 5s"* && "$OUT" == *"CI_COMPLETE"* \
   && "$OUT" == *"fake-checks-report pr=8"* ]] \
  && pass "hung --watch: warning, CI_COMPLETE and the final report (${ELAPSED16}s)" \
  || { fail "hung --watch: warning, CI_COMPLETE and the final report"; printf '%s\n' "$OUT" | sed 's/^/      /'; }
# The 0.5s budget was spent, so the 5s bound is the floor, not "what was left" of the budget.
[[ "$OUT" == *"(the 5s floor; PR_CI_WAIT_MAX_S was spent)"* && "$OUT" != *"what was left"* ]] \
  && pass "hung --watch: the warning names the floor, not the leftover budget" \
  || { fail "hung --watch: the warning names the floor, not the leftover budget"; printf '%s\n' "$OUT" | sed 's/^/      /'; }

echo "---"
echo "$FAILURES failed"
[ "$FAILURES" -eq 0 ]
