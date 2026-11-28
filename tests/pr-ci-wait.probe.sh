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
#   FAKE_GH_PR_STATE   stdout for `api repos/.../pulls/N` when not querying
#                       `--jq .head.sha` (default
#                       `{"state":"open","draft":false,"merged":false,"head":"<FIXTURE_HEAD_SHA>","author":"me"}`)
#   FAKE_GH_PR_STATE_EXIT its exit code (default 0; non-zero also prints
#                       `gh: HTTP 502` to stderr)
#   FAKE_GH_USER       stdout for `api user` (default `me`)
#   FAKE_GH_USER_EXIT  its exit code (default 0; non-zero also prints
#                       `gh: HTTP 502` to stderr)
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
#   FAKE_GH_JOBS_EXIT   non-empty: every jobs call fails with `gh: HTTP 502` and
#                       this exit code (the lookup error never clears)
#   FAKE_GH_JOBLIST     JSON array the jobs endpoint prints when not querying
#                       `total_count` (default `[]`)
#   FAKE_GH_JOBLIST_LOG file the per-run job-list endpoints are appended to,
#                       one line per call (unset: not logged)
#   FAKE_GH_JOBLIST_EXIT non-empty: every job-list call fails with
#                       `gh: HTTP 502` and this exit code
cat > "$FAKE_BIN/gh" <<'SHIM'
#!/bin/bash
set -uo pipefail
CMD="${1:-}"; shift || true
case "$CMD" in
  api)
    ENDPOINT="${1:-}"
    case "$ENDPOINT" in
      */pulls/*)
        case "$*" in
          *"--jq .head.sha")
            echo "${FAKE_GH_HEAD_SHA:-}"
            exit "${FAKE_GH_HEAD_EXIT:-0}"
            ;;
        esac
        DEFAULT_PR_STATE="{\"state\":\"open\",\"draft\":false,\"merged\":false,\"head\":\"$FIXTURE_HEAD_SHA\",\"author\":\"me\"}"
        echo "${FAKE_GH_PR_STATE:-$DEFAULT_PR_STATE}"
        if [ "${FAKE_GH_PR_STATE_EXIT:-0}" -ne 0 ]; then
          echo "gh: HTTP 502" >&2
        fi
        exit "${FAKE_GH_PR_STATE_EXIT:-0}"
        ;;
      user)
        echo "${FAKE_GH_USER:-me}"
        if [ "${FAKE_GH_USER_EXIT:-0}" -ne 0 ]; then
          echo "gh: HTTP 502" >&2
        fi
        exit "${FAKE_GH_USER_EXIT:-0}"
        ;;
      */actions/runs/*/jobs*)
        case "$*" in
          *total_count*)
            [ -n "${FAKE_GH_JOBS_LOG:-}" ] && echo "$ENDPOINT" >> "$FAKE_GH_JOBS_LOG"
            if [ -n "${FAKE_GH_JOBS_ERR_ONCE:-}" ] && [ -e "$FAKE_GH_JOBS_ERR_ONCE" ]; then
              rm -f "$FAKE_GH_JOBS_ERR_ONCE"
              echo "gh: HTTP 502" >&2
              exit 1
            fi
            if [ -n "${FAKE_GH_JOBS_EXIT:-}" ]; then
              echo "gh: HTTP 502" >&2
              exit "$FAKE_GH_JOBS_EXIT"
            fi
            echo "${FAKE_GH_JOBS_TOTAL:-1}"
            exit 0
            ;;
        esac
        [ -n "${FAKE_GH_JOBLIST_LOG:-}" ] && echo "$ENDPOINT" >> "$FAKE_GH_JOBLIST_LOG"
        if [ -n "${FAKE_GH_JOBLIST_EXIT:-}" ]; then
          echo "gh: HTTP 502" >&2
          exit "$FAKE_GH_JOBLIST_EXIT"
        fi
        echo "${FAKE_GH_JOBLIST:-[]}"
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
  # SYG_CI_WAIT_PRIME_REVIEW defaults to 0 here so a CI_COMPLETE case never runs
  # the real merge-review hook against this machine's ack state; the priming
  # cases (P1..P8 below) pass their own value after it, which wins.
  # The MAX_S and GRACE_S defaults are give-up ceilings that only a case
  # asserting a give-up reaches, and every such case sets its own short value;
  # a sub-second default let a loaded machine end a releasing case early
  # (CI_GATE_TIMEOUT/review-missing after 2 of 3 polls).
  OUT=$(cd "$FIXTURE_REPO" && timeout "$CASE_TIMEOUT" env -i \
    PATH="$FAKE_BIN:$PATH" HOME="$HOME" PYTHONDONTWRITEBYTECODE=1 \
    FIXTURE_HEAD_SHA="$FIXTURE_HEAD_SHA" \
    PR_CI_WAIT_POLL_S="${PR_CI_WAIT_POLL_S:-0.05}" \
    PR_CI_WAIT_MAX_S="${PR_CI_WAIT_MAX_S:-5}" \
    PR_CI_WAIT_GRACE_S="${PR_CI_WAIT_GRACE_S:-5}" \
    PR_CI_WAIT_HEARTBEAT_S="${PR_CI_WAIT_HEARTBEAT_S:-600}" \
    PR_CI_WAIT_SETTLE_S="${PR_CI_WAIT_SETTLE_S:-0}" \
    PR_CI_WAIT_QUIET_S="${PR_CI_WAIT_QUIET_S:-0.3}" \
    SYG_CI_WAIT_PRIME_REVIEW="${SYG_CI_WAIT_PRIME_REVIEW:-0}" \
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
JOBS_LINES_7B=$({ wc -l < "$JOBS_LOG_7B"; } 2>/dev/null || echo 0)
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
JOBS_LINES_7K=$({ wc -l < "$JOBS_LOG_7K"; } 2>/dev/null || echo 0)
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
JOBS_LINES_7L=$({ wc -l < "$JOBS_LOG_7L"; } 2>/dev/null || echo 0)
POLLS_7L=$(cat "$D/.count" 2>/dev/null || echo 0)
[[ "$OUT" == *"CI_COMPLETE"* && "$OUT" == *"gh api failed (1x)"* && "$OUT" == *"recovered after 1"* ]] \
  && pass "lookup error hold: error logged, recovery logged, CI_COMPLETE" \
  || fail "lookup error hold: error logged, recovery logged, CI_COMPLETE"
[ "$POLLS_7L" -ge 2 ] && [ "$JOBS_LINES_7L" -eq 2 ] \
  && pass "lookup error hold: not released on the errored poll (polls=$POLLS_7L, lookups=$JOBS_LINES_7L)" \
  || fail "lookup error hold: not released on the errored poll (polls=$POLLS_7L, lookups=$JOBS_LINES_7L)"

# --- 7m. a lookup error that never clears: the heartbeat names the held release
JOBS_LOG_7M="$WORK/jobs-7m.log"
D=$(seq_dir lookup-error-persistent '[{"id":5,"name":"CI","status":"completed","conclusion":"failure","run_attempt":1}]')
run "persistent lookup error holds release until the gate gives up" 1 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=CI SYG_CI_REVIEW= PR_CI_WAIT_MAX_S=2 PR_CI_WAIT_HEARTBEAT_S=0 \
  FAKE_GH_JOBS_TOTAL=3 FAKE_GH_JOBS_EXIT=1 FAKE_GH_JOBS_LOG="$JOBS_LOG_7M"
JOBS_LINES_7M=$({ wc -l < "$JOBS_LOG_7M"; } 2>/dev/null || echo 0)
[[ "$OUT" == *"CI_GATE_TIMEOUT"* && "$OUT" == *"release held: job-count lookup failing"* && "$OUT" != *"CI_COMPLETE"* ]] \
  && pass "persistent lookup error: CI_GATE_TIMEOUT, heartbeat says release is held, never CI_COMPLETE" \
  || fail "persistent lookup error: CI_GATE_TIMEOUT, heartbeat says release is held, never CI_COMPLETE"
[ "$JOBS_LINES_7M" -ge 2 ] \
  && pass "persistent lookup error: the lookup was retried, nothing cached (lookups=$JOBS_LINES_7M)" \
  || fail "persistent lookup error: the lookup was retried, nothing cached (lookups=$JOBS_LINES_7M)"

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

# --- AS1..AS14. automerge-skipped check (SYG_CI_AUTOMERGE_JOB) --------------
AS_RUNS_GREEN='[{"id":1,"name":"Probes","status":"completed","conclusion":"success"},{"id":10,"name":"Claude Code Review","status":"completed","conclusion":"success"},{"id":21,"name":"Claude Code Review","status":"completed","conclusion":"success","run_attempt":1},{"id":30,"name":"Claude Code Review","status":"completed","conclusion":"cancelled"}]'
AS_RUNS_RED='[{"id":1,"name":"Probes","status":"completed","conclusion":"failure","run_attempt":1},{"id":10,"name":"Claude Code Review","status":"completed","conclusion":"success"},{"id":21,"name":"Claude Code Review","status":"completed","conclusion":"success","run_attempt":1},{"id":30,"name":"Claude Code Review","status":"completed","conclusion":"cancelled"}]'
AS_JOBS_SKIPPED='[{"name":"claude-review","conclusion":"success"},{"name":"automerge","conclusion":"skipped"}]'
AS_JOBS_RAN='[{"name":"claude-review","conclusion":"success"},{"name":"automerge","conclusion":"success"}]'
AS_JOBS_NO_AUTOMERGE='[{"name":"claude-review","conclusion":"success"}]'

# --- AS1. race shape: automerge skipped on green open non-draft PR -----------
JOBLIST_LOG_AS1="$WORK/joblist-as1.log"
D=$(seq_dir as1-race "$AS_RUNS_GREEN")
run "AS1: automerge skipped on green open non-draft PR -> CI_GATE_AUTOMERGE_SKIPPED" 1 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=Probes SYG_CI_REVIEW="Claude Code Review" \
  SYG_CI_AUTOMERGE_JOB=automerge FAKE_GH_JOBLIST="$AS_JOBS_SKIPPED" \
  FAKE_GH_JOBLIST_LOG="$JOBLIST_LOG_AS1"
[[ "$OUT" == *"CI_GATE_AUTOMERGE_SKIPPED"* && "$OUT" != *"CI_COMPLETE"* && "$OUT" == *"gh pr close"* ]] \
  && pass "AS1: CI_GATE_AUTOMERGE_SKIPPED sentinel and gh pr close instruction" \
  || { fail "AS1: CI_GATE_AUTOMERGE_SKIPPED sentinel and gh pr close instruction"; printf '%s\n' "$OUT" | sed 's/^/      /'; }
JOBLIST_LINES_AS1=$({ wc -l < "$JOBLIST_LOG_AS1"; } 2>/dev/null || echo 0)
[ "$JOBLIST_LINES_AS1" -eq 1 ] && grep -q 'runs/21/attempts/1/jobs' "$JOBLIST_LOG_AS1" \
  && pass "AS1: one joblist lookup on latest non-cancelled review run (runs/21/attempts/1/jobs)" \
  || fail "AS1: one joblist lookup on latest non-cancelled review run (lines=$JOBLIST_LINES_AS1, log=$(cat "$JOBLIST_LOG_AS1" 2>/dev/null))"

# --- AS2. draft PR: automerge skipped is held by design -> CI_COMPLETE -------
D=$(seq_dir as2-draft "$AS_RUNS_GREEN")
run "AS2: automerge skipped on draft PR -> CI_COMPLETE" 0 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=Probes SYG_CI_REVIEW="Claude Code Review" \
  SYG_CI_AUTOMERGE_JOB=automerge FAKE_GH_JOBLIST="$AS_JOBS_SKIPPED" \
  FAKE_GH_PR_STATE="{\"state\":\"open\",\"draft\":true,\"merged\":false,\"head\":\"$FIXTURE_HEAD_SHA\",\"author\":\"me\"}"
[[ "$OUT" == *"CI_COMPLETE"* && "$OUT" != *"CI_GATE_AUTOMERGE_SKIPPED"* && "$OUT" == *"held by design"* ]] \
  && pass "AS2: draft PR reports CI_COMPLETE and held by design" \
  || { fail "AS2: draft PR reports CI_COMPLETE and held by design"; printf '%s\n' "$OUT" | sed 's/^/      /'; }

# --- AS3. automerge ran (success) -> CI_COMPLETE -----------------------------
D=$(seq_dir as3-ran "$AS_RUNS_GREEN")
run "AS3: automerge ran -> CI_COMPLETE" 0 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=Probes SYG_CI_REVIEW="Claude Code Review" \
  SYG_CI_AUTOMERGE_JOB=automerge FAKE_GH_JOBLIST="$AS_JOBS_RAN"
[[ "$OUT" == *"CI_COMPLETE"* && "$OUT" != *"CI_GATE_AUTOMERGE_SKIPPED"* ]] \
  && pass "AS3: automerge success reports CI_COMPLETE" \
  || { fail "AS3: automerge success reports CI_COMPLETE"; printf '%s\n' "$OUT" | sed 's/^/      /'; }

# --- AS4. knob unset -> CI_COMPLETE, no joblist lookup -----------------------
JOBLIST_LOG_AS4="$WORK/joblist-as4.log"
D=$(seq_dir as4-unset "$AS_RUNS_GREEN")
run "AS4: SYG_CI_AUTOMERGE_JOB unset -> CI_COMPLETE" 0 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=Probes SYG_CI_REVIEW="Claude Code Review" \
  FAKE_GH_JOBLIST="$AS_JOBS_SKIPPED" FAKE_GH_JOBLIST_LOG="$JOBLIST_LOG_AS4"
[[ "$OUT" == *"CI_COMPLETE"* ]] && [ ! -e "$JOBLIST_LOG_AS4" ] \
  && pass "AS4: knob unset reports CI_COMPLETE and joblist log not created" \
  || { fail "AS4: knob unset reports CI_COMPLETE and joblist log not created"; printf '%s\n' "$OUT" | sed 's/^/      /'; }

# --- AS5. lookup failure -> degrades to CI_COMPLETE --------------------------
D=$(seq_dir as5-err "$AS_RUNS_GREEN")
run "AS5: joblist lookup failure -> CI_COMPLETE" 0 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=Probes SYG_CI_REVIEW="Claude Code Review" \
  SYG_CI_AUTOMERGE_JOB=automerge FAKE_GH_JOBLIST_EXIT=1
[[ "$OUT" == *"CI_COMPLETE"* && "$OUT" != *"CI_GATE_AUTOMERGE_SKIPPED"* && "$OUT" == *"automerge check could not run"* ]] \
  && pass "AS5: lookup failure warns and reports CI_COMPLETE" \
  || { fail "AS5: lookup failure warns and reports CI_COMPLETE"; printf '%s\n' "$OUT" | sed 's/^/      /'; }

# --- AS6. red CI: anchor run conclusion failure -> CI_COMPLETE ---------------
D=$(seq_dir as6-red "$AS_RUNS_RED")
run "AS6: red CI with automerge skipped -> CI_COMPLETE" 0 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=Probes SYG_CI_REVIEW="Claude Code Review" \
  SYG_CI_AUTOMERGE_JOB=automerge FAKE_GH_JOBLIST="$AS_JOBS_SKIPPED"
[[ "$OUT" == *"CI_COMPLETE"* && "$OUT" != *"CI_GATE_AUTOMERGE_SKIPPED"* ]] \
  && pass "AS6: red CI reports CI_COMPLETE" \
  || { fail "AS6: red CI reports CI_COMPLETE"; printf '%s\n' "$OUT" | sed 's/^/      /'; }

# --- AS7. merged PR -> CI_COMPLETE -------------------------------------------
D=$(seq_dir as7-merged "$AS_RUNS_GREEN")
run "AS7: merged PR with automerge skipped -> CI_COMPLETE" 0 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=Probes SYG_CI_REVIEW="Claude Code Review" \
  SYG_CI_AUTOMERGE_JOB=automerge FAKE_GH_JOBLIST="$AS_JOBS_SKIPPED" \
  FAKE_GH_PR_STATE="{\"state\":\"closed\",\"draft\":false,\"merged\":true,\"head\":\"$FIXTURE_HEAD_SHA\",\"author\":\"me\"}"
[[ "$OUT" == *"CI_COMPLETE"* && "$OUT" != *"CI_GATE_AUTOMERGE_SKIPPED"* && "$OUT" != *"automerge check could not run"* ]] \
  && pass "AS7: merged PR reports CI_COMPLETE" \
  || { fail "AS7: merged PR reports CI_COMPLETE"; printf '%s\n' "$OUT" | sed 's/^/      /'; }

# --- AS8. knob set but no such job -> CI_COMPLETE ----------------------------
D=$(seq_dir as8-nojob "$AS_RUNS_GREEN")
run "AS8: SYG_CI_AUTOMERGE_JOB set but job absent -> CI_COMPLETE" 0 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=Probes SYG_CI_REVIEW="Claude Code Review" \
  SYG_CI_AUTOMERGE_JOB=automerge FAKE_GH_JOBLIST="$AS_JOBS_NO_AUTOMERGE"
[[ "$OUT" == *"CI_COMPLETE"* && "$OUT" != *"CI_GATE_AUTOMERGE_SKIPPED"* ]] \
  && pass "AS8: missing job reports CI_COMPLETE" \
  || { fail "AS8: missing job reports CI_COMPLETE"; printf '%s\n' "$OUT" | sed 's/^/      /'; }

# --- AS9. PR-state lookup failure -> degrades to CI_COMPLETE -----------------
D=$(seq_dir as9-pr-err "$AS_RUNS_GREEN")
run "AS9: PR-state lookup failure -> CI_COMPLETE" 0 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=Probes SYG_CI_REVIEW="Claude Code Review" \
  SYG_CI_AUTOMERGE_JOB=automerge FAKE_GH_JOBLIST="$AS_JOBS_SKIPPED" \
  FAKE_GH_PR_STATE_EXIT=1
[[ "$OUT" == *"CI_COMPLETE"* && "$OUT" != *"CI_GATE_AUTOMERGE_SKIPPED"* && "$OUT" == *"automerge check could not run"* ]] \
  && pass "AS9: PR-state failure warns and reports CI_COMPLETE" \
  || { fail "AS9: PR-state failure warns and reports CI_COMPLETE"; printf '%s\n' "$OUT" | sed 's/^/      /'; }

# --- AS10. closed, not merged PR -> CI_COMPLETE ------------------------------
D=$(seq_dir as10-closed "$AS_RUNS_GREEN")
run "AS10: closed unmerged PR with automerge skipped -> CI_COMPLETE" 0 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=Probes SYG_CI_REVIEW="Claude Code Review" \
  SYG_CI_AUTOMERGE_JOB=automerge FAKE_GH_JOBLIST="$AS_JOBS_SKIPPED" \
  FAKE_GH_PR_STATE="{\"state\":\"closed\",\"draft\":false,\"merged\":false,\"head\":\"$FIXTURE_HEAD_SHA\",\"author\":\"me\"}"
[[ "$OUT" == *"CI_COMPLETE"* && "$OUT" != *"CI_GATE_AUTOMERGE_SKIPPED"* && "$OUT" != *"automerge check could not run"* ]] \
  && pass "AS10: closed unmerged PR reports CI_COMPLETE" \
  || { fail "AS10: closed unmerged PR reports CI_COMPLETE"; printf '%s\n' "$OUT" | sed 's/^/      /'; }

# --- AS11. PR author differs from authenticated gh user -> CI_COMPLETE -------
D=$(seq_dir as11-author "$AS_RUNS_GREEN")
run "AS11: automerge skipped on PR by another author -> CI_COMPLETE" 0 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=Probes SYG_CI_REVIEW="Claude Code Review" \
  SYG_CI_AUTOMERGE_JOB=automerge FAKE_GH_JOBLIST="$AS_JOBS_SKIPPED" \
  FAKE_GH_PR_STATE="{\"state\":\"open\",\"draft\":false,\"merged\":false,\"head\":\"$FIXTURE_HEAD_SHA\",\"author\":\"someone-else\"}"
[[ "$OUT" == *"CI_COMPLETE"* && "$OUT" != *"CI_GATE_AUTOMERGE_SKIPPED"* && "$OUT" == *"not the authenticated gh user"* ]] \
  && pass "AS11: non-viewer author reports CI_COMPLETE and explains author skip" \
  || { fail "AS11: non-viewer author reports CI_COMPLETE and explains author skip"; printf '%s\n' "$OUT" | sed 's/^/      /'; }

# --- AS12. PR head moved since watched SHA -> CI_COMPLETE --------------------
MOVED_HEAD_SHA=$(printf 'c%.0s' {1..40})
D=$(seq_dir as12-head-moved "$AS_RUNS_GREEN")
run "AS12: automerge skipped after PR head moved -> CI_COMPLETE" 0 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=Probes SYG_CI_REVIEW="Claude Code Review" \
  SYG_CI_AUTOMERGE_JOB=automerge FAKE_GH_JOBLIST="$AS_JOBS_SKIPPED" \
  FAKE_GH_PR_STATE="{\"state\":\"open\",\"draft\":false,\"merged\":false,\"head\":\"$MOVED_HEAD_SHA\",\"author\":\"me\"}"
[[ "$OUT" == *"CI_COMPLETE"* && "$OUT" != *"CI_GATE_AUTOMERGE_SKIPPED"* && "$OUT" == *"head moved"* ]] \
  && pass "AS12: moved PR head reports CI_COMPLETE and notes head moved" \
  || { fail "AS12: moved PR head reports CI_COMPLETE and notes head moved"; printf '%s\n' "$OUT" | sed 's/^/      /'; }

# --- AS13. SYG_CI_AUTOMERGE_JOB set with SYG_CI_REVIEW= (empty) -> CI_COMPLETE
JOBLIST_LOG_AS13="$WORK/joblist-as13.log"
D=$(seq_dir as13-noreview "$AS_RUNS_GREEN")
run "AS13: SYG_CI_AUTOMERGE_JOB set with SYG_CI_REVIEW= -> CI_COMPLETE" 0 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=Probes SYG_CI_REVIEW= \
  SYG_CI_AUTOMERGE_JOB=automerge FAKE_GH_JOBLIST="$AS_JOBS_SKIPPED" \
  FAKE_GH_JOBLIST_LOG="$JOBLIST_LOG_AS13"
[[ "$OUT" == *"CI_COMPLETE"* && "$OUT" != *"CI_GATE_AUTOMERGE_SKIPPED"* && "$OUT" == *"review workflow is off"* ]] \
  && [ ! -e "$JOBLIST_LOG_AS13" ] \
  && pass "AS13: empty SYG_CI_REVIEW disables automerge check and skips joblist lookup" \
  || { fail "AS13: empty SYG_CI_REVIEW disables automerge check and skips joblist lookup"; printf '%s\n' "$OUT" | sed 's/^/      /'; }

# --- AS14. gh api user failure -> degrades to CI_COMPLETE --------------------
D=$(seq_dir as14-user-err "$AS_RUNS_GREEN")
run "AS14: gh api user failure -> CI_COMPLETE" 0 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=Probes SYG_CI_REVIEW="Claude Code Review" \
  SYG_CI_AUTOMERGE_JOB=automerge FAKE_GH_JOBLIST="$AS_JOBS_SKIPPED" \
  FAKE_GH_USER_EXIT=1
[[ "$OUT" == *"CI_COMPLETE"* && "$OUT" != *"CI_GATE_AUTOMERGE_SKIPPED"* && "$OUT" == *"automerge check could not run"* ]] \
  && pass "AS14: gh api user failure warns and reports CI_COMPLETE" \
  || { fail "AS14: gh api user failure warns and reports CI_COMPLETE"; printf '%s\n' "$OUT" | sed 's/^/      /'; }

# --- P1..P8. merge-gate priming on CI_COMPLETE --------------------------------
# run() defaults SYG_CI_WAIT_PRIME_REVIEW=0; each case below passes its own.
# before_in_out A B: both strings are in $OUT and A's first occurrence is first.
before_in_out() {
  [[ "$OUT" == *"$1"* && "$OUT" == *"$2"* ]] || return 1
  local head_a="${OUT%%"$1"*}" head_b="${OUT%%"$2"*}"
  [ "${#head_a}" -lt "${#head_b}" ]
}

PRIME_STUB="$WORK/prime-stub.sh"
cat > "$PRIME_STUB" <<'STUB'
#!/bin/bash
# Test double for the merge-review hook: records stdin and call count, then
# prints a recognisable block on stdout (default) or stderr (STUB_STREAM=err).
cat > "$STUB_STDIN"
echo x >> "$STUB_CALLS"
if [ "${STUB_STREAM:-out}" = err ]; then echo STUB-REVIEW-BLOCK >&2; else echo STUB-REVIEW-BLOCK; fi
exit 2
STUB
chmod +x "$PRIME_STUB"
PRIME_PAYLOAD='{"tool_name": "Bash", "tool_input": {"command": "gh pr merge 8"}}'
PRIME_LINE="priming the merge gate for PR #8"
D_REL=$(seq_dir prime-release "[$DONE_CI]")

# P1. stub called once with the exact payload; order priming line < block < sentinel < checks report.
rm -f "$WORK/p1.stdin" "$WORK/p1.calls"
run "P1: CI_COMPLETE primes the merge gate" 0 \
  FAKE_GH_SEQ_DIR="$D_REL" SYG_CI_REVIEW= SYG_CI_ANCHOR=CI \
  SYG_CI_WAIT_PRIME_REVIEW=1 SYG_CI_WAIT_PRIME_CMD="$PRIME_STUB" \
  STUB_STDIN="$WORK/p1.stdin" STUB_CALLS="$WORK/p1.calls"
[ "$(wc -l < "$WORK/p1.calls" 2>/dev/null)" = "1" ] && [ "$(cat "$WORK/p1.stdin" 2>/dev/null)" = "$PRIME_PAYLOAD" ] \
  && pass "P1: stub called once with the exact synthetic payload" \
  || { fail "P1: stub called once with the exact synthetic payload (stdin=$(cat "$WORK/p1.stdin" 2>/dev/null))"; }
before_in_out "$PRIME_LINE" "STUB-REVIEW-BLOCK" && before_in_out "STUB-REVIEW-BLOCK" "CI_COMPLETE" \
  && before_in_out "CI_COMPLETE" "fake-checks-report" \
  && pass "P1: order is priming line, stub block, sentinel, checks report" \
  || { fail "P1: order is priming line, stub block, sentinel, checks report"; printf '%s\n' "$OUT" | sed 's/^/      /'; }

# P1b. a block written to STDERR still reaches pr-ci-wait's stdout, in order.
rm -f "$WORK/p1b.stdin" "$WORK/p1b.calls"
OUT_ONLY=$(cd "$FIXTURE_REPO" && timeout "$CASE_TIMEOUT" env -i \
  PATH="$FAKE_BIN:$PATH" HOME="$HOME" PYTHONDONTWRITEBYTECODE=1 FIXTURE_HEAD_SHA="$FIXTURE_HEAD_SHA" \
  PR_CI_WAIT_POLL_S=0.05 PR_CI_WAIT_MAX_S=5 PR_CI_WAIT_GRACE_S=5 PR_CI_WAIT_SETTLE_S=0 PR_CI_WAIT_QUIET_S=0.3 \
  FAKE_GH_SEQ_DIR="$D_REL" SYG_CI_REVIEW= SYG_CI_ANCHOR=CI \
  SYG_CI_WAIT_PRIME_REVIEW=1 SYG_CI_WAIT_PRIME_CMD="$PRIME_STUB" STUB_STREAM=err \
  STUB_STDIN="$WORK/p1b.stdin" STUB_CALLS="$WORK/p1b.calls" \
  "$BIN" 8 --sha "$SHA_ARG" 2>/dev/null)
OUT="$OUT_ONLY"
before_in_out "$PRIME_LINE" "STUB-REVIEW-BLOCK" && before_in_out "STUB-REVIEW-BLOCK" "fake-checks-report" \
  && pass "P1b: stderr block surfaces on pr-ci-wait's stdout, in order" \
  || { fail "P1b: stderr block surfaces on pr-ci-wait's stdout, in order"; printf '%s\n' "$OUT" | sed 's/^/      /'; }

# P2. a non-CI_COMPLETE outcome (zero-job failure) never primes.
rm -f "$WORK/p2.stdin" "$WORK/p2.calls"
D=$(seq_dir prime-nonrelease "[$FAIL_ZERO]")
run "P2: non-CI_COMPLETE outcome -> exit 1" 1 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=CI SYG_CI_REVIEW= FAKE_GH_JOBS_TOTAL=0 \
  SYG_CI_WAIT_PRIME_REVIEW=1 SYG_CI_WAIT_PRIME_CMD="$PRIME_STUB" \
  STUB_STDIN="$WORK/p2.stdin" STUB_CALLS="$WORK/p2.calls"
[ ! -e "$WORK/p2.calls" ] && [[ "$OUT" != *"$PRIME_LINE"* ]] \
  && pass "P2: stub not called, no priming line" \
  || { fail "P2: stub not called, no priming line"; printf '%s\n' "$OUT" | sed 's/^/      /'; }

# P3. SYG_CI_WAIT_PRIME_REVIEW=0 skips silently.
rm -f "$WORK/p3.stdin" "$WORK/p3.calls"
run "P3: SYG_CI_WAIT_PRIME_REVIEW=0 on CI_COMPLETE" 0 \
  FAKE_GH_SEQ_DIR="$D_REL" SYG_CI_REVIEW= SYG_CI_ANCHOR=CI \
  SYG_CI_WAIT_PRIME_REVIEW=0 SYG_CI_WAIT_PRIME_CMD="$PRIME_STUB" \
  STUB_STDIN="$WORK/p3.stdin" STUB_CALLS="$WORK/p3.calls"
[ ! -e "$WORK/p3.calls" ] && [[ "$OUT" == *"CI_COMPLETE"* && "$OUT" != *"$PRIME_LINE"* ]] \
  && pass "P3: stub not called, no priming line" \
  || { fail "P3: stub not called, no priming line"; printf '%s\n' "$OUT" | sed 's/^/      /'; }

# P4. an automerge job configured (job ran, so CI_COMPLETE) skips priming.
rm -f "$WORK/p4.stdin" "$WORK/p4.calls"
D=$(seq_dir prime-automerge "$AS_RUNS_GREEN")
run "P4: automerge job configured, CI_COMPLETE" 0 \
  FAKE_GH_SEQ_DIR="$D" SYG_CI_ANCHOR=Probes SYG_CI_REVIEW="Claude Code Review" \
  SYG_CI_AUTOMERGE_JOB=automerge FAKE_GH_JOBLIST="$AS_JOBS_RAN" \
  SYG_CI_WAIT_PRIME_REVIEW=1 SYG_CI_WAIT_PRIME_CMD="$PRIME_STUB" \
  STUB_STDIN="$WORK/p4.stdin" STUB_CALLS="$WORK/p4.calls"
[ ! -e "$WORK/p4.calls" ] && [[ "$OUT" == *"CI_COMPLETE"* && "$OUT" != *"$PRIME_LINE"* ]] \
  && pass "P4: stub not called, no priming line" \
  || { fail "P4: stub not called, no priming line"; printf '%s\n' "$OUT" | sed 's/^/      /'; }

# P5. seam path not executable (OSError): warns, exit code and sentinel unchanged.
: > "$WORK/not-executable"
run "P5: unrunnable priming command still exits 0" 0 \
  FAKE_GH_SEQ_DIR="$D_REL" SYG_CI_REVIEW= SYG_CI_ANCHOR=CI \
  SYG_CI_WAIT_PRIME_REVIEW=1 SYG_CI_WAIT_PRIME_CMD="$WORK/not-executable"
[[ "$OUT" == *"merge gate not primed:"* && "$OUT" == *"will block once as usual"* ]] && before_in_out "merge gate not primed" "fake-checks-report" \
  && pass "P5: 'not primed' warning printed before the checks report" \
  || { fail "P5: 'not primed' warning printed before the checks report"; printf '%s\n' "$OUT" | sed 's/^/      /'; }

# P8. a priming command exiting neither 0 nor 2: warns the ack state is unknown,
# exit code and sentinel unchanged.
EXIT3_STUB="$WORK/exit3-stub.sh"
printf '#!/bin/bash\ncat >/dev/null\nexit 3\n' > "$EXIT3_STUB"
chmod +x "$EXIT3_STUB"
run "P8: priming command exiting 3 still exits 0" 0 \
  FAKE_GH_SEQ_DIR="$D_REL" SYG_CI_REVIEW= SYG_CI_ANCHOR=CI \
  SYG_CI_WAIT_PRIME_REVIEW=1 SYG_CI_WAIT_PRIME_CMD="$EXIT3_STUB"
[[ "$OUT" == *"CI_COMPLETE"* && "$OUT" == *"hook exited 3; ack state unknown"* ]] \
  && pass "P8: CI_COMPLETE printed and 'hook exited 3; ack state unknown' warned" \
  || { fail "P8: CI_COMPLETE printed and 'hook exited 3; ack state unknown' warned"; printf '%s\n' "$OUT" | sed 's/^/      /'; }

# P6. INTEGRATION (no seam): the real run.sh + the real hook, a temp state dir and a
# gh shim that answers the hook's calls for the fixture PR and defers everything else to the
# pr-ci-wait shim. FAKE_INT_REVIEW_JSON is one raw comment; empty = no comments.
INT_BIN="$WORK/intbin"
mkdir -p "$INT_BIN"
cat > "$INT_BIN/gh" <<'SHIM'
#!/bin/bash
case "$*" in
  "pr view "*"--json "*)
    case "$*" in
      *baseRefName*) printf '%s\n%s\n' "${FAKE_INT_BASE:-develop}" "feat/x" ;;
      *author,files*) printf '%s\n%s\n' "octo-user" "false" ;;
      *) exit 64 ;;
    esac ;;
  "repo view "*"--json "*) printf '%s\n%s\n' "acme-widgets/cli" "main" ;;
  *"/issues/"*"/comments"*)
    if [ -n "${FAKE_INT_REVIEW_JSON:-}" ]; then printf '[[%s]]' "$FAKE_INT_REVIEW_JSON"; else printf '[[]]'; fi ;;
  "pr diff "*) printf '' ;;
  *) exec "$FAKE_BIN_REAL/gh" "$@" ;;
esac
SHIM
chmod +x "$INT_BIN/gh"
INT_UPDATED="2026-08-08T12:00:00Z"
INT_REVIEW=$(jq -nc --arg u "$INT_UPDATED" \
  '{id:4242,user:{login:"claude[bot]"},created_at:$u,updated_at:$u,body:"INT-REVIEW-BODY: add a test for the empty case"}')
XDG_P6="$WORK/xdg-p6"
INT_ACK="$XDG_P6/seyag/pr-merge-review-check/ack"
run "P6: integration, real hook through run.sh" 0 \
  PATH="$INT_BIN:$FAKE_BIN:$PATH" FAKE_BIN_REAL="$FAKE_BIN" FAKE_INT_BASE=develop \
  FAKE_INT_REVIEW_JSON="$INT_REVIEW" FAKE_GH_SEQ_DIR="$D_REL" SYG_CI_REVIEW= SYG_CI_ANCHOR=CI \
  SYG_CONFIG=0 XDG_STATE_HOME="$XDG_P6" SYG_CI_WAIT_PRIME_REVIEW=1
[[ "$OUT" == *"PR MERGE GATE"* && "$OUT" == *"INT-REVIEW-BODY"* ]] && before_in_out "$PRIME_LINE" "PR MERGE GATE" \
  && before_in_out "INT-REVIEW-BODY" "CI_COMPLETE" \
  && pass "P6: the real hook's block and the review body print after the priming line and before CI_COMPLETE" \
  || { fail "P6: the real hook's block and the review body print after the priming line and before CI_COMPLETE"; printf '%s\n' "$OUT" | sed 's/^/      /'; }
grep -qxF "8:4242:$INT_UPDATED" "$INT_ACK" 2>/dev/null \
  && pass "P6: ack file holds 8:<id>:<updated_at>" \
  || { fail "P6: ack file holds 8:<id>:<updated_at> (file: $(cat "$INT_ACK" 2>/dev/null))"; }
printf '%s' "$PRIME_PAYLOAD" | (cd "$FIXTURE_REPO" && env -i \
  PATH="$INT_BIN:$FAKE_BIN:$PATH" HOME="$HOME" FAKE_BIN_REAL="$FAKE_BIN" FAKE_INT_BASE=develop \
  FAKE_INT_REVIEW_JSON="$INT_REVIEW" SYG_CONFIG=0 XDG_STATE_HOME="$XDG_P6" \
  bash "$SCRIPT_DIR/../plugins/seyag/hooks/run.sh" pr-merge-review-check >"$WORK/p6.second.out" 2>&1)
P6_RC=$?
[ "$P6_RC" -eq 0 ] && [ ! -s "$WORK/p6.second.out" ] \
  && pass "P6: the session's own first merge call then proceeds (rc 0, no output)" \
  || { fail "P6: the session's own first merge call then proceeds (rc $P6_RC)"; sed 's/^/      /' "$WORK/p6.second.out"; }

# P7. INTEGRATION, non-acking path: no claude[bot] comment on a non-default-base PR
# writes no review ack line.
XDG_P7="$WORK/xdg-p7"
run "P7: integration, no review comment" 0 \
  PATH="$INT_BIN:$FAKE_BIN:$PATH" FAKE_BIN_REAL="$FAKE_BIN" FAKE_INT_BASE=develop \
  FAKE_INT_REVIEW_JSON= FAKE_GH_SEQ_DIR="$D_REL" SYG_CI_REVIEW= SYG_CI_ANCHOR=CI \
  SYG_CONFIG=0 XDG_STATE_HOME="$XDG_P7" SYG_CI_WAIT_PRIME_REVIEW=1
{ [ ! -e "$XDG_P7/seyag/pr-merge-review-check/ack" ] || ! grep -q '^8:' "$XDG_P7/seyag/pr-merge-review-check/ack"; } \
  && [[ "$OUT" == *"$PRIME_LINE"* && "$OUT" == *"CI_COMPLETE"* ]] \
  && pass "P7: no review ack line written when there was no review" \
  || { fail "P7: no review ack line written when there was no review"; printf '%s\n' "$OUT" | sed 's/^/      /'; }

echo "---"
echo "$FAILURES failed"
[ "$FAILURES" -eq 0 ]
