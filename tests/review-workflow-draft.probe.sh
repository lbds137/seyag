#!/bin/bash
# Fixture check for .github/workflows/claude-code-review.yml: the automerge job gates on the
# PR's live draft state read from the API, never on the event payload's draft flag. A run
# whose payload predates a draft-to-ready flip (a push and "ready for review" seconds apart,
# the ready run cancelled by the concurrency group) carries a stale draft=true; gating the
# job's `if` on it skipped the merge of a green, ready PR. The probe pins:
#  - the automerge job's `if` never reads github.event.pull_request.draft;
#  - a first step reads isDraft from the API: false -> ready=true, true -> held (exit 0,
#    no ready output), an unreadable state -> red;
#  - the wait and merge steps run only on ready=true, and the merge step re-reads isDraft
#    right before `gh pr merge` (a PR flipped back to draft during the wait is not merged);
#  - branch delete and post-merge run only when the merge step reports merged=true.
# The step scripts are cut from the workflow and run under `bash -e` with a stub gh.
# Usage: tests/review-workflow-draft.probe.sh   (writes only in a temp dir)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF="$REPO/.github/workflows/claude-code-review.yml"
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# job_block JOB: the lines of top-level job JOB (2-space key under jobs:).
job_block() {
  awk -v job="  $1:" '
    $0 == job { on = 1; print; next }
    on && /^  [A-Za-z0-9_-]+:/ { exit }
    on { print }' "$WF"
}
# job_if JOB: the job-level `if:` value (folded or inline), joined into one line.
job_if() {
  job_block "$1" | awk '
    /^    if:/ { on = 1; sub(/^    if:[[:space:]]*/, ""); print; next }
    on && /^    [A-Za-z0-9_-]+:/ { exit }
    on && /^      / { print; next }
    on { exit }' | tr '\n' ' '
}
# step_field JOB STEP FIELD: the step's FIELD line value (one line, e.g. `if`, `id`).
step_field() {
  job_block "$1" | awk -v step="      - name: $2" -v field="$3" '
    $0 == step { on = 1; next }
    on && /^      - / { exit }
    on && $0 ~ "^        " field ":" { sub("^        " field ":[[:space:]]*", ""); print; exit }'
}
# step_run JOB STEP: the step's `run: |` script, de-indented.
step_run() {
  job_block "$1" | awk -v step="      - name: $2" '
    $0 == step { on = 1; next }
    on && /^      - / { exit }
    on && /^        run: \|/ { body = 1; next }
    body && /^        [A-Za-z0-9_-]+:/ { exit }
    body { sub(/^          /, ""); print }'
}

# --- A1. the job-level gate never reads the payload's draft flag ------------
am_if=$(job_if automerge)
if [ -z "$am_if" ]; then
  bad "A1: automerge job has an if: expression"
elif grep -q 'pull_request\.draft' <<<"$am_if"; then
  bad "A1: automerge if: reads github.event.pull_request.draft (stale on a draft-to-ready race): $am_if"
else
  ok "A1: automerge if: does not read the payload's draft flag"
fi

# Stub gh: `pr view ... --json isDraft` prints $STUB_DRAFT (or fails when STUB_FAIL=1);
# every call is logged.
cat >"$tmp/gh" <<EOF
#!/bin/bash
echo "\$*" >>"$tmp/calls"
case "\$1 \$2" in
  "pr view")
    [ "\${STUB_FAIL:-}" = 1 ] && { echo "HTTP 502" >&2; exit 1; }
    echo "\$STUB_DRAFT" ;;
  "pr merge") exit 0 ;;
  *) echo "unexpected gh call: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/gh"

# run_step SCRIPT DRAFT [FAIL]: runs SCRIPT like Actions does (bash -e), stub gh first on PATH.
run_step() {
  : >"$tmp/calls"; : >"$tmp/out"
  PATH="$tmp:$PATH" STUB_DRAFT="$2" STUB_FAIL="${3:-}" GITHUB_OUTPUT="$tmp/out" \
    PR=7 REPO=octo/widget SHA=0123456789abcdef0123456789abcdef01234567 \
    bash -e "$1" >"$tmp/log" 2>&1
}

# --- A2. a first step reads the live draft state -----------------------------
first_step=$(job_block automerge | awk '/^    steps:/ { s = 1; next } s && /^      - name: / { sub(/^      - name: /, ""); print; exit }')
live_id=$(step_field automerge "$first_step" id)
step_run automerge "$first_step" >"$tmp/live.sh"
if [ "$live_id" != live ] || ! grep -q 'isDraft' "$tmp/live.sh"; then
  bad "A2: automerge's first step (id: live) reads isDraft from the API (first step: '$first_step', id: '$live_id')"
else
  ok "A2: automerge's first step (id: live) reads isDraft from the API"
  run_step "$tmp/live.sh" false; rc=$?
  if [ "$rc" = 0 ] && grep -qx 'ready=true' "$tmp/out"; then
    ok "A2a: live draft=false -> ready=true"
  else
    bad "A2a: live draft=false -> ready=true (rc=$rc, out: $(cat "$tmp/out"))"
  fi
  run_step "$tmp/live.sh" true; rc=$?
  if [ "$rc" = 0 ] && ! grep -q '^ready=true' "$tmp/out"; then
    ok "A2b: live draft=true -> held, exit 0, no ready output"
  else
    bad "A2b: live draft=true -> held, exit 0, no ready output (rc=$rc, out: $(cat "$tmp/out"))"
  fi
  run_step "$tmp/live.sh" "" 1; rc=$?
  if [ "$rc" != 0 ] && ! grep -q '^ready=true' "$tmp/out"; then
    ok "A2c: unreadable draft state -> red, no ready output"
  else
    bad "A2c: unreadable draft state -> red, no ready output (rc=$rc)"
  fi
fi

# --- A3. wait and merge run only on a live ready ----------------------------
for s in "Wait for the other checks" "Merge"; do
  v=$(step_field automerge "$s" if)
  if [ "$v" = "steps.live.outputs.ready == 'true'" ]; then
    ok "A3: step '$s' runs only on steps.live.outputs.ready"
  else
    bad "A3: step '$s' runs only on steps.live.outputs.ready (if: '$v')"
  fi
done

# --- A4. the merge step re-reads draft right before merging ------------------
step_run automerge Merge >"$tmp/merge.sh"
[ "$(step_field automerge Merge id)" = merge ] && ok "A4: Merge step has id: merge" || bad "A4: Merge step has id: merge"
run_step "$tmp/merge.sh" true; rc=$?
if [ "$rc" != 0 ] && ! grep -q '^pr merge' "$tmp/calls" && ! grep -q '^merged=true' "$tmp/out"; then
  ok "A4a: flipped back to draft during the wait -> no merge, red"
else
  bad "A4a: flipped back to draft during the wait -> no merge, red (rc=$rc, calls: $(tr '\n' ';' <"$tmp/calls"))"
fi
run_step "$tmp/merge.sh" false; rc=$?
order=$(grep -oE '^pr (view|merge)' "$tmp/calls" | tr '\n' ';')
if [ "$rc" = 0 ] && [ "$order" = "pr view;pr merge;" ] && grep -qx 'merged=true' "$tmp/out" \
  && grep -q -- '--match-head-commit 0123456789abcdef0123456789abcdef01234567' "$tmp/calls"; then
  ok "A4b: live ready -> isDraft read, then merge --match-head-commit, merged=true"
else
  bad "A4b: live ready -> isDraft read, then merge --match-head-commit, merged=true (rc=$rc, calls: $order)"
fi

# --- A5. branch delete and post-merge follow a real merge only --------------
del_if=$(step_field automerge "Delete the merged branch" if)
grep -q "steps.merge.outputs.merged == 'true'" <<<"$del_if" \
  && ok "A5: branch delete runs only after merged=true" \
  || bad "A5: branch delete runs only after merged=true (if: '$del_if')"
grep -q "merged: \${{ steps.merge.outputs.merged }}" <(job_block automerge) \
  && ok "A5: automerge exports outputs.merged" \
  || bad "A5: automerge exports outputs.merged"
grep -q "needs.automerge.outputs.merged == 'true'" <<<"$(job_if post-merge)" \
  && ok "A5: post-merge runs only after merged=true" \
  || bad "A5: post-merge runs only after merged=true"

[ "$fail" = 0 ] && echo "review-workflow-draft: all checks passed"
exit "$fail"
