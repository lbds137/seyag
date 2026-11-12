#!/bin/bash
# Fixture check for plugins/seyag/bin/pr-closeout against a throwaway repo and
# a fake `gh`. Never touches GitHub or any real branch/worktree: the fixture
# repo, its bare origin, its two worktrees and the gh shim all live under this
# probe's own mktemp dir; every pr-closeout run has the fixture repo as cwd.
# The shim returns POST-filter shapes (as if `gh` had applied --json/-q itself)
# and logs issue calls, so write-shaped calls are asserted off the log.
#
# Usage: tests/pr-closeout.probe.sh   (from anywhere)

set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN="$SCRIPT_DIR/../plugins/seyag/bin/pr-closeout"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAKE_BIN="$WORK/fakebin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/gh" <<'SHIM'
#!/bin/bash
set -uo pipefail
CMD=${1:-}; shift || true
case $CMD in
  pr)
    cat "${FAKE_PR_JSON:?FAKE_PR_JSON unset}"
    exit 0
    ;;
  issue)
    SUB=${1:-}; URL=${2:-}
    [ -n "${FAKE_GH_LOG:-}" ] && echo "$SUB $URL $*" >> "$FAKE_GH_LOG"
    if [ "$SUB" = view ]; then
      st=$(awk -F'\t' -v u="$URL" '$1==u{print $2; exit}' "${FAKE_ISSUE_STATES:?unset}")
      if [ -z "$st" ]; then echo "gh: Not found ($URL)" >&2; exit 1; fi
      [ -n "${FAKE_ISSUE_WARN:-}" ] && echo "gh: note: API deprecation for $URL" >&2
      echo "$st"
    fi
    exit 0
    ;;
esac
echo "gh shim: unexpected call: $CMD" >&2
exit 64
SHIM
chmod +x "$FAKE_BIN/gh"

# --- fixture repo: main, feat-x (squash-merged), wip-z (unmerged), and two
# agent worktrees: worktree-agent-wt-a clean at origin/main (SAFE), worktree-agent-wt-b
# with an untracked file (HOLD). A bare repo stands in for origin.
FIX="$WORK/fixture"
git init -q -b main "$FIX"
git -C "$FIX" config user.email t@t
git -C "$FIX" config user.name t
echo base > "$FIX/f.txt" && git -C "$FIX" add f.txt
git -C "$FIX" commit -qm base
git -C "$FIX" checkout -qb feat-x
echo feat > "$FIX/f.txt" && git -C "$FIX" commit -qam "feat-x change"
git -C "$FIX" checkout -q main
git -C "$FIX" merge --squash -q feat-x >/dev/null 2>&1
git -C "$FIX" commit -qm "feat-x change"
git -C "$FIX" checkout -qb wip-z
echo wip > "$FIX/g.txt" && git -C "$FIX" add g.txt
git -C "$FIX" commit -qm "wip work"
git -C "$FIX" checkout -q main
git -C "$FIX" worktree add -q "$FIX/.claude/worktrees/wt-a" -b worktree-agent-wt-a
git -C "$FIX" worktree add -q "$FIX/.claude/worktrees/wt-b" -b worktree-agent-wt-b
echo loose > "$FIX/.claude/worktrees/wt-b/d.txt"
git init -q --bare "$WORK/origin.git"
git -C "$FIX" remote add origin "$WORK/origin.git"
git -C "$FIX" push -q origin main
git -C "$FIX" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
PR_SHA=$(git -C "$FIX" rev-parse origin/main)
WTA="$FIX/.claude/worktrees/wt-a"
WTB="$FIX/.claude/worktrees/wt-b"
U1="https://github.example/acme/widget/issues/11"
U2="https://github.example/acme/widget/issues/12"
U3="https://github.example/acme/widget/issues/13"
export FAKE_GH_LOG="$WORK/gh.log"
export FAKE_ISSUE_STATES="$WORK/issues.tsv"
export FAKE_PR_JSON="$WORK/pr.json"

fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }
set_pr() { # state headbranch [url]... — POST-filter shape
  local state=$1 branch=$2; shift 2
  local items="" u
  for u in "$@"; do items+="${items:+,}{\"url\":\"$u\"}"; done
  printf '{"state":"%s","mergeCommit":{"oid":"%s"},"closingIssuesReferences":[%s],"headRefName":"%s"}\n' \
    "$state" "$PR_SHA" "$items" "$branch" > "$FAKE_PR_JSON"
}
set_issue() { printf '%s\t%s\n' "$1" "$2" >> "$FAKE_ISSUE_STATES"; }
reset() { : > "$FAKE_ISSUE_STATES"; : > "$FAKE_GH_LOG"; }
run() { (cd "$FIX" && env PATH="$FAKE_BIN:$PATH" bash "$BIN" "$@"); }

# 1. not-MERGED: exit 1, nothing done (shim log empty of any issue call).
reset
set_pr OPEN feat-x
out=$(run 7 2>&1); rc=$?
[ $rc = 1 ] && ok "OPEN PR: exit 1" || bad "OPEN PR exit $rc (out: $out)"
grep -qF "pr-closeout: PR 7 is OPEN, not MERGED — nothing done" <<<"$out" \
  && ok "OPEN PR: nothing-done line" || bad "OPEN PR line (out: $out)"
[ -s "$FAKE_GH_LOG" ] && bad "OPEN PR: shim log has calls: $(cat "$FAKE_GH_LOG")" \
  || ok "OPEN PR: shim log has no calls"

# 2. ELIGIBLE, dry run: verdict + plan line, branch kept, exit 0.
reset
set_pr MERGED feat-x
out=$(run 7 2>&1); rc=$?
[ $rc = 0 ] && ok "ELIGIBLE dry: exit 0" || bad "ELIGIBLE dry exit $rc (out: $out)"
grep -qF "ELIGIBLE feat-x (tree identical to $PR_SHA)" <<<"$out" \
  && ok "ELIGIBLE dry: verdict line verbatim" || bad "ELIGIBLE verdict (out: $out)"
grep -qF "plan: branch-sweep --only feat-x --apply" <<<"$out" \
  && ok "ELIGIBLE dry: plan line" || bad "ELIGIBLE plan (out: $out)"
git -C "$FIX" rev-parse --verify -q refs/heads/feat-x >/dev/null \
  && ok "ELIGIBLE dry: feat-x kept" || bad "ELIGIBLE dry deleted feat-x"
! grep -q '^deleted ' <<<"$out" && ok "ELIGIBLE dry: nothing deleted" || bad "ELIGIBLE dry deleted"

# 3. ELIGIBLE, --apply: branch deleted, exit 0.
out=$(run 7 --apply 2>&1); rc=$?
[ $rc = 0 ] && ok "ELIGIBLE apply: exit 0" || bad "ELIGIBLE apply exit $rc (out: $out)"
grep -qF "done: branch-sweep --only feat-x --apply" <<<"$out" \
  && ok "ELIGIBLE apply: done line" || bad "ELIGIBLE done (out: $out)"
grep -qF "deleted feat-x (matching SHA $PR_SHA)" <<<"$out" \
  && ok "ELIGIBLE apply: deletion line passes through" || bad "ELIGIBLE deletion (out: $out)"
git -C "$FIX" rev-parse --verify -q refs/heads/feat-x >/dev/null \
  && bad "ELIGIBLE apply: feat-x still exists" || ok "ELIGIBLE apply: feat-x deleted"
grep -qF "pr-closeout: PR 7 closed out" <<<"$out" \
  && ok "ELIGIBLE apply: closed-out line" || bad "ELIGIBLE closed-out (out: $out)"

# 4. SKIP (checked out in a worktree) → SAFE: dry plan line.
reset
set_pr MERGED worktree-agent-wt-a
out=$(run 8 2>&1); rc=$?
[ $rc = 0 ] && ok "SAFE dry: exit 0" || bad "SAFE dry exit $rc (out: $out)"
grep -qF "SKIP worktree-agent-wt-a (checked out in a worktree)" <<<"$out" \
  && ok "SAFE dry: SKIP verdict verbatim" || bad "SAFE SKIP verdict (out: $out)"
grep -qF "plan: safe-worktree-clean --only $WTA --apply" <<<"$out" \
  && ok "SAFE dry: plan line" || bad "SAFE plan (out: $out)"
wtl=$(git -C "$FIX" worktree list --porcelain)
grep -qF "$WTA" <<<"$wtl" \
  && ok "SAFE dry: worktree kept" || bad "SAFE dry removed worktree"

# 5. SAFE, --apply: worktree removed (gone from git worktree list), exit 0.
out=$(run 8 --apply 2>&1); rc=$?
[ $rc = 0 ] && ok "SAFE apply: exit 0" || bad "SAFE apply exit $rc (out: $out)"
grep -qF "done: safe-worktree-clean --only $WTA --apply" <<<"$out" \
  && ok "SAFE apply: done line" || bad "SAFE done (out: $out)"
wtl=$(git -C "$FIX" worktree list --porcelain)
grep -qF "$WTA" <<<"$wtl" \
  && bad "SAFE apply: worktree still listed" || ok "SAFE apply: worktree removed"
git -C "$FIX" rev-parse --verify -q refs/heads/worktree-agent-wt-a >/dev/null \
  && bad "SAFE apply: branch still exists" || ok "SAFE apply: branch removed too"

# 6. HOLD: dirty tree held, HOLD lines + hold plan id reported, exit 1.
reset
set_pr MERGED worktree-agent-wt-b
out=$(run 8 2>&1); rc=$?
[ $rc = 1 ] && ok "HOLD: exit 1" || bad "HOLD exit $rc (out: $out)"
grep -q 'HOLD:' <<<"$out" && ok "HOLD: HOLD lines reported" || bad "HOLD lines (out: $out)"
grep -q '^hold plan: ' <<<"$out" && ok "HOLD: hold plan id reported" || bad "hold plan (out: $out)"
wtl=$(git -C "$FIX" worktree list --porcelain)
grep -qF "$WTB" <<<"$wtl" \
  && ok "HOLD: tree left in place" || bad "HOLD: tree removed"

# 7. DIFFERS: verdict verbatim, branch left, exit 1.
reset
set_pr MERGED wip-z
out=$(run 7 2>&1); rc=$?
[ $rc = 1 ] && ok "DIFFERS: exit 1" || bad "DIFFERS exit $rc (out: $out)"
grep -q '^DIFFERS wip-z$' <<<"$out" \
  && ok "DIFFERS: verdict line verbatim" || bad "DIFFERS verdict (out: $out)"
git -C "$FIX" rev-parse --verify -q refs/heads/wip-z >/dev/null \
  && ok "DIFFERS: wip-z kept" || bad "DIFFERS deleted wip-z"

# 8. Issues OPEN + CLOSED, ABSENT branch: dry plans only the OPEN issue with
# the exact Fixed-by text; --apply runs it (asserted on the shim log); exit 0.
reset
set_issue "$U1" OPEN
set_issue "$U2" CLOSED
set_pr MERGED gone-branch "$U1" "$U2"
out=$(run 9 2>&1); rc=$?
[ $rc = 0 ] && ok "issues dry: exit 0" || bad "issues dry exit $rc (out: $out)"
[ "$(grep -c '^plan: ' <<<"$out")" = 1 ] \
  && ok "issues dry: exactly one plan line" || bad "issues dry plans (out: $out)"
grep -qF "plan: gh issue close $U1 --comment \"Fixed by $PR_SHA (#9).\"" <<<"$out" \
  && ok "issues dry: exact Fixed-by plan text" || bad "issues dry plan (out: $out)"
grep -qF "issue $U2: already closed" <<<"$out" \
  && ok "issues dry: CLOSED reported" || bad "issues dry CLOSED (out: $out)"
grep -qF "ABSENT gone-branch (no such local branch)" <<<"$out" \
  && ok "ABSENT: verdict line verbatim, no leftover" || bad "ABSENT verdict (out: $out)"
grep -qF "pr-closeout: PR 9 closed out" <<<"$out" \
  && ok "issues+ABSENT dry: closed-out line" || bad "issues dry closed-out (out: $out)"
out=$(run 9 --apply 2>&1); rc=$?
[ $rc = 0 ] && ok "issues apply: exit 0" || bad "issues apply exit $rc (out: $out)"
grep -qF "close $U1 --comment Fixed by $PR_SHA (#9)." <<<"$(cat "$FAKE_GH_LOG")" \
  && ok "issues apply: shim ran the close with the Fixed-by text" \
  || bad "issues apply shim log: $(cat "$FAKE_GH_LOG")"
grep -qF "issue $U1: closed" <<<"$out" && ok "issues apply: closed line" || bad "issues apply closed (out: $out)"
! grep -qF "close $U2" <<<"$(cat "$FAKE_GH_LOG")" \
  && ok "issues apply: CLOSED issue not re-closed" || bad "issues apply re-closed U2"
grep -qF "done: gh issue close $U1 --comment \"Fixed by $PR_SHA (#9).\"" <<<"$out" \
  && ok "issues apply: done-line shape" || bad "issues apply done line (out: $out)"

# 9. Issue view failure: reported FAILED, never treated as closed, exit 1.

# 9. Issue view failure: reported FAILED, never treated as closed, exit 1.
reset
set_issue "$U1" OPEN
set_pr MERGED gone-branch "$U1" "$U3"
out=$(run 9 2>"$WORK/err"); rc=$?
[ $rc = 1 ] && ok "view failure: exit 1" || bad "view failure exit $rc (out: $out)"
grep -qF "issue $U3: FAILED:" <<<"$out" \
  && ok "view failure: FAILED line" || bad "view failure line (out: $out)"
grep -qF "pr-closeout: cannot read issue $U3:" <"$WORK/err" \
  && ok "view failure: cannot-read line on stderr" || bad "view failure stderr: $(cat "$WORK/err")"

# 10. A warning on stderr of a SUCCESSFUL view must not corrupt the state
# read: OPEN stays a plan (the merged-capture version once read it as
# "already closed" and planned nothing).
FAKE_ISSUE_WARN=1
export FAKE_ISSUE_WARN
reset
set_issue "$U1" OPEN
set_pr MERGED gone-branch "$U1"
out=$(run 9 2>&1); rc=$?
unset FAKE_ISSUE_WARN
[ $rc = 0 ] && ok "stderr warning: exit 0" || bad "stderr warning exit $rc (out: $out)"
grep -qF "plan: gh issue close $U1" <<<"$out" \
  && ok "stderr warning: OPEN still planned" || bad "stderr warning planned (out: $out)"
! grep -qF "already closed" <<<"$out" \
  && ok "stderr warning: not misread as closed" || bad "stderr warning misread: $out"

exit $fail
