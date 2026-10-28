#!/bin/bash
# Fixture check for plugins/seyag/bin/worktree-transfer — run after ANY
# edit to the script. 23 cases assert the fixed check order, refusal shapes,
# branch-regex gating, and byte-identical staged transfer over hermetic
# throwaway git repos under $(mktemp -d):
#   1. cwd inside the linked worktree -> STOP: main-tree-identity
#   2. untracked file in the main tree -> STOP: main-tree-clean, worktree untouched
#   3. plain directory not registered as a worktree -> STOP: worktree-registered
#   4. worktree on branch feature/other (default regex) -> STOP: worktree-registered,
#      branch still exists and tree is intact afterward
#   5. detached worktree (git worktree add --detach) -> STOP: worktree-registered
#   6. --base <old-sha> after main moved, and --base does-not-exist -> STOP: base-unchanged
#   7. clean worktree with no edits -> STOP: empty-patch
#   8. commit made inside the worker worktree -> STOP: no-unpushed-base (HEAD differs)
#   9. pushed worker commit -> STOP: no-unpushed-base
#  10. first-failure-wins: dirty main tree + empty worktree -> STOP: main-tree-clean
#  11. SYG_WORKTREE_BRANCH_RE='^agent/' with branch agent/t2 -> full transfer and branch deletion
#  12. SYG_WORKTREE_BRANCH_RE='^agent/' with branch worktree-agent-x -> refusal, branch kept
#  13. SYG_WORKTREE_BRANCH_RE='(' -> refusal saying the regex is unusable, nothing deleted
#  14. SYG_WORKTREE_BRANCH_RE='' (set but empty) -> falls back to default ^worktree-agent-
#  15. dirty tracked file inside a submodule -> sanity-checked ` M <path>` porcelain line,
#      then STOP: nothing-outside-patch
#  16. happy path: exit 0, expected stdout lines, changes staged in main tree, modified/new/deleted
#      files verified, binary file byte-identical via cmp, gitignored dist/out.bin not transferred,
#      worktree directory and branch removed
#  17. no remote-tracking refs (origin removed) -> transfer succeeds with no remote-tracking refs
#  18. detached main working tree -> STOP: main-tree-identity naming detached
#  19. --base=OLD via the = form after main moved -> STOP: base-unchanged
#  20. usage errors: no positional, two positionals, unknown flag -> exit 2 + usage text
#  21. diff.noprefix=true in the fixture repo -> transfer still succeeds with the new
#      file at its real nested path (a/-b/ prefixes pinned on both diff calls)
#  22. worktree cut from an older commit than main HEAD -> STOP: no-unpushed-base
#      naming the differing HEADs (behind is as wrong as ahead)
#  23. a locked worktree -> transfer still succeeds (unlock then remove --force)
#
# Stated non-goal: the two removal-failure wordings (`git worktree remove --force`
# vs `git branch -D` in check 10) are not constructible without root tricks; the
# safety-critical piece — `branch -D` gated on the regex re-check — is pinned by
# cases 4, 11 and 12.
#
# Usage: tests/worktree-transfer.probe.sh   (from anywhere)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/plugins/seyag/bin/worktree-transfer"

while read -r v; do unset "$v"; done < <(compgen -v SYG_)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

T=$(mktemp -d)
cleanup() { rm -rf "$T"; }
trap cleanup EXIT

pass=0
fail=0

record_case() { # $1=case_fail(0|1) $2=label [$3=detail]
  if [ "$1" -eq 0 ]; then
    echo "ok   $2"
    pass=$((pass + 1))
  else
    echo "FAIL $2${3:+ ($3)}"
    fail=1
  fi
}

# Create a hermetic fixture repo at $T/$1 with a bare remote at $T/$1-origin.git,
# a base commit pushed to origin/main with (a) src/app.js, (b) src/old.js, (c) README.md,
# and a registered agent worktree at $T/$1/.wt on branch worktree-agent-t1 populated
# with uncommitted edits (modify a, add new file, delete b, add binary file, add
# gitignored dist/out.bin).
mk_fixture() { # $1=name
  local r="$T/$1" origin="$T/$1-origin.git"
  git init -q --bare -b main "$origin" >/dev/null 2>&1
  git init -q -b main "$r" >/dev/null 2>&1
  git -C "$r" config user.email probe@example.invalid
  git -C "$r" config user.name 'Probe Harness'
  git -C "$r" config commit.gpgsign false
  git -C "$r" remote add origin "$origin"

  mkdir -p "$r/src"
  printf 'dist/\n.wt*\n.claude/\n' >"$r/.gitignore"
  printf 'export const value = 1;\n' >"$r/src/app.js"
  printf 'export const obsolete = true;\n' >"$r/src/old.js"
  printf '# Fixture Repo\n' >"$r/README.md"

  git -C "$r" add -A >/dev/null 2>&1
  git -C "$r" commit -q --no-verify -m 'base commit' >/dev/null 2>&1
  git -C "$r" push -q origin main >/dev/null 2>&1

  (cd "$r" && git worktree add -q -b worktree-agent-t1 .wt >/dev/null 2>&1)
  populate_wt "$r/.wt"
}

populate_wt() { # $1=worktree-dir
  local wt=$1
  mkdir -p "$wt/src" "$wt/dist"
  printf 'export const value = 2;\n' >"$wt/src/app.js"
  printf 'export const added = "new";\n' >"$wt/src/new.js"
  rm -f "$wt/src/old.js"
  printf 'x\001\002\000y' >"$wt/src/data.bin"
  printf 'ignored-build-artifact\n' >"$wt/dist/out.bin"
}

# Build primary fixture repo R1 (reused across pre-apply refusal cases, then
# consumed by case 16 happy path).
mk_fixture r1
R1="$T/r1"

# Case 1: Run with cwd INSIDE the worktree -> STOP: main-tree-identity.
err=$(cd "$R1/.wt" && bash "$TOOL" "$R1/.wt" 2>&1 >/dev/null)
rc=$?
if [ "$rc" -eq 1 ] && [[ $err == "STOP: main-tree-identity:"* ]] \
  && [ -d "$R1/.wt" ] && [ -z "$(git -C "$R1" status --porcelain)" ]; then
  record_case 0 "case 1: cwd inside the worktree refuses STOP: main-tree-identity"
else
  record_case 1 "case 1: cwd inside the worktree" "rc=$rc err=$err"
fi

# Case 2: Untracked file in the main tree -> STOP: main-tree-clean, worktree untouched.
mk_fixture r2
R2="$T/r2"
printf 'stray untracked content\n' >"$R2/stray.txt"
err=$(cd "$R2" && bash "$TOOL" .wt 2>&1 >/dev/null)
rc=$?
if [ "$rc" -eq 1 ] && [[ $err == "STOP: main-tree-clean:"* ]] \
  && [ -d "$R2/.wt" ] && [ -f "$R2/.wt/src/new.js" ] \
  && git -C "$R2" diff --cached --quiet; then
  record_case 0 "case 2: untracked file in main tree refuses STOP: main-tree-clean, worktree untouched"
else
  record_case 1 "case 2: untracked file in main tree" "rc=$rc err=$err"
fi

# Case 3: A plain directory that is not a registered worktree -> STOP: worktree-registered.
mkdir -p "$R1/.wt-plain"
err=$(cd "$R1" && bash "$TOOL" .wt-plain 2>&1 >/dev/null)
rc=$?
if [ "$rc" -eq 1 ] && [[ $err == "STOP: worktree-registered:"* ]] \
  && [ -d "$R1/.wt" ] && [ -z "$(git -C "$R1" status --porcelain)" ]; then
  record_case 0 "case 3: unregistered plain directory refuses STOP: worktree-registered"
else
  record_case 1 "case 3: unregistered plain directory" "rc=$rc err=$err"
fi

# Case 4: A worktree on branch feature/other (default regex) -> STOP: worktree-registered,
# and the branch STILL EXISTS and the tree is intact afterward.
(cd "$R1" && git worktree add -q -b feature/other .wt-other >/dev/null 2>&1)
populate_wt "$R1/.wt-other"
err=$(cd "$R1" && bash "$TOOL" .wt-other 2>&1 >/dev/null)
rc=$?
if [ "$rc" -eq 1 ] && [[ $err == "STOP: worktree-registered:"* ]] \
  && git -C "$R1" rev-parse --verify -q refs/heads/feature/other >/dev/null \
  && [ -d "$R1/.wt-other" ] && [ -f "$R1/.wt-other/src/new.js" ] \
  && [ -z "$(git -C "$R1" status --porcelain)" ]; then
  record_case 0 "case 4: unmatched branch feature/other refuses STOP: worktree-registered, branch and tree intact"
else
  record_case 1 "case 4: unmatched branch feature/other" "rc=$rc err=$err"
fi

# Case 5: A detached worktree (git worktree add --detach) -> STOP: worktree-registered.
(cd "$R1" && git worktree add -q --detach .wt-detached >/dev/null 2>&1)
populate_wt "$R1/.wt-detached"
err=$(cd "$R1" && bash "$TOOL" .wt-detached 2>&1 >/dev/null)
rc=$?
if [ "$rc" -eq 1 ] && [[ $err == "STOP: worktree-registered:"* ]] \
  && [ -d "$R1/.wt-detached" ] && [ -z "$(git -C "$R1" status --porcelain)" ]; then
  record_case 0 "case 5: detached worktree refuses STOP: worktree-registered"
else
  record_case 1 "case 5: detached worktree" "rc=$rc err=$err"
fi

# Case 6: --base <old-sha> after main moved -> STOP: base-unchanged;
# separately --base does-not-exist -> STOP: base-unchanged.
mk_fixture r6
R6="$T/r6"
OLD_SHA=$(git -C "$R6" rev-parse HEAD)
err_bad=$(cd "$R6" && bash "$TOOL" --base does-not-exist .wt 2>&1 >/dev/null)
rc_bad=$?
printf 'More docs.\n' >>"$R6/README.md"
git -C "$R6" add README.md >/dev/null 2>&1
git -C "$R6" commit -q --no-verify -m 'advance main' >/dev/null 2>&1
git -C "$R6" push -q origin main >/dev/null 2>&1
err_old=$(cd "$R6" && bash "$TOOL" --base "$OLD_SHA" .wt 2>&1 >/dev/null)
rc_old=$?
if [ "$rc_bad" -eq 1 ] && [[ $err_bad == "STOP: base-unchanged:"* ]] \
  && [ "$rc_old" -eq 1 ] && [[ $err_old == "STOP: base-unchanged:"* ]] \
  && [ -d "$R6/.wt" ] && [ -z "$(git -C "$R6" status --porcelain)" ]; then
  record_case 0 "case 6: --base <old-sha> after main moved and --base does-not-exist both refuse STOP: base-unchanged"
else
  record_case 1 "case 6: --base checks" "rc_bad=$rc_bad err_bad=$err_bad rc_old=$rc_old err_old=$err_old"
fi

# Case 7: A clean worktree with no edits -> STOP: empty-patch.
(cd "$R1" && git worktree add -q -b worktree-agent-clean .wt-clean >/dev/null 2>&1)
err=$(cd "$R1" && bash "$TOOL" .wt-clean 2>&1 >/dev/null)
rc=$?
if [ "$rc" -eq 1 ] && [[ $err == "STOP: empty-patch:"* ]] \
  && [ -d "$R1/.wt-clean" ] \
  && git -C "$R1" rev-parse --verify -q refs/heads/worktree-agent-clean >/dev/null \
  && [ -z "$(git -C "$R1" status --porcelain)" ]; then
  record_case 0 "case 7: clean worktree with no edits refuses STOP: empty-patch"
else
  record_case 1 "case 7: clean worktree with no edits" "rc=$rc err=$err"
fi

# Case 8: A commit made inside the worker worktree -> STOP: no-unpushed-base (HEAD differs).
(cd "$R1" && git worktree add -q -b worktree-agent-committed .wt-committed >/dev/null 2>&1)
printf 'committed change\n' >"$R1/.wt-committed/committed.txt"
git -C "$R1/.wt-committed" add committed.txt >/dev/null 2>&1
git -C "$R1/.wt-committed" commit -q --no-verify -m 'worker commit' >/dev/null 2>&1
populate_wt "$R1/.wt-committed"
err=$(cd "$R1" && bash "$TOOL" .wt-committed 2>&1 >/dev/null)
rc=$?
if [ "$rc" -eq 1 ] && [[ $err == "STOP: no-unpushed-base:"* ]] \
  && [ -d "$R1/.wt-committed" ] \
  && git -C "$R1" rev-parse --verify -q refs/heads/worktree-agent-committed >/dev/null \
  && [ -z "$(git -C "$R1" status --porcelain)" ]; then
  record_case 0 "case 8: commit inside worker worktree refuses STOP: no-unpushed-base (HEAD differs)"
else
  record_case 1 "case 8: commit inside worker worktree" "rc=$rc err=$err"
fi

# Case 9: Pushed worker commit: a worktree whose branch carries one commit
# pushed to origin -> STOP: no-unpushed-base fires.
(cd "$R1" && git worktree add -q -b worktree-agent-pushed .wt-pushed >/dev/null 2>&1)
printf 'pushed worker commit\n' >"$R1/.wt-pushed/pushed.txt"
git -C "$R1/.wt-pushed" add pushed.txt >/dev/null 2>&1
git -C "$R1/.wt-pushed" commit -q --no-verify -m 'worker pushed commit' >/dev/null 2>&1
git -C "$R1/.wt-pushed" push -q origin worktree-agent-pushed >/dev/null 2>&1
populate_wt "$R1/.wt-pushed"
err=$(cd "$R1" && bash "$TOOL" .wt-pushed 2>&1 >/dev/null)
rc=$?
if [ "$rc" -eq 1 ] && [[ $err == "STOP: no-unpushed-base:"* ]] \
  && [ -d "$R1/.wt-pushed" ] \
  && git -C "$R1" rev-parse --verify -q refs/heads/worktree-agent-pushed >/dev/null \
  && [ -z "$(git -C "$R1" status --porcelain)" ]; then
  record_case 0 "case 9: pushed worker commit refuses STOP: no-unpushed-base"
else
  record_case 1 "case 9: no-unpushed-base" "rc=$rc err=$err"
fi

# Case 10: First-failure-wins: dirty main tree AND an empty worktree together ->
# the refusal names main-tree-clean.
(cd "$R2" && git worktree add -q -b worktree-agent-empty .wt-empty >/dev/null 2>&1)
err=$(cd "$R2" && bash "$TOOL" .wt-empty 2>&1 >/dev/null)
rc=$?
if [ "$rc" -eq 1 ] && [[ $err == "STOP: main-tree-clean:"* ]] \
  && [[ $err != *"empty-patch"* ]] && [ -d "$R2/.wt-empty" ]; then
  record_case 0 "case 10: dirty main tree + empty worktree refuses STOP: main-tree-clean (first failure wins)"
else
  record_case 1 "case 10: first-failure-wins" "rc=$rc err=$err"
fi

# Case 11: SYG_WORKTREE_BRANCH_RE='^agent/' with a worktree on branch agent/t2 ->
# full success including branch deletion.
mk_fixture r11
R11="$T/r11"
(cd "$R11" && git worktree add -q -b agent/t2 .wt-agent2 >/dev/null 2>&1)
populate_wt "$R11/.wt-agent2"
out=$(cd "$R11" && SYG_WORKTREE_BRANCH_RE='^agent/' bash "$TOOL" .wt-agent2 2>&1)
rc=$?
if [ "$rc" -eq 0 ] \
  && grep -q '^worktree removed$' <<<"$out" \
  && grep -q '^branch agent/t2 deleted$' <<<"$out" \
  && [ ! -e "$R11/.wt-agent2" ] \
  && ! git -C "$R11" rev-parse --verify -q refs/heads/agent/t2 >/dev/null \
  && [ -f "$R11/src/new.js" ]; then
  record_case 0 "case 11: SYG_WORKTREE_BRANCH_RE='^agent/' transfers and deletes branch agent/t2"
else
  record_case 1 "case 11: SYG_WORKTREE_BRANCH_RE='^agent/' with agent/t2" "rc=$rc out=$out"
fi

# Case 12: Same regex ('^agent/') against a worktree-agent-x branch -> refusal, branch not deleted.
(cd "$R1" && git worktree add -q -b worktree-agent-x .wt-x >/dev/null 2>&1)
populate_wt "$R1/.wt-x"
err=$(cd "$R1" && SYG_WORKTREE_BRANCH_RE='^agent/' bash "$TOOL" .wt-x 2>&1 >/dev/null)
rc=$?
if [ "$rc" -eq 1 ] && [[ $err == "STOP: worktree-registered:"* ]] \
  && [ -d "$R1/.wt-x" ] \
  && git -C "$R1" rev-parse --verify -q refs/heads/worktree-agent-x >/dev/null \
  && [ -z "$(git -C "$R1" status --porcelain)" ]; then
  record_case 0 "case 12: SYG_WORKTREE_BRANCH_RE='^agent/' refuses worktree-agent-x and keeps branch"
else
  record_case 1 "case 12: SYG_WORKTREE_BRANCH_RE='^agent/' with worktree-agent-x" "rc=$rc err=$err"
fi

# Case 13: SYG_WORKTREE_BRANCH_RE='(' -> refusal saying the regex is unusable, nothing deleted.
err=$(cd "$R1" && SYG_WORKTREE_BRANCH_RE='(' bash "$TOOL" .wt-x 2>&1 >/dev/null)
rc=$?
if [ "$rc" -eq 1 ] && [[ $err == "STOP: worktree-registered:"* ]] \
  && grep -q 'not a valid extended regex' <<<"$err" \
  && grep -q 'unusable' <<<"$err" \
  && [ -d "$R1/.wt-x" ] \
  && git -C "$R1" rev-parse --verify -q refs/heads/worktree-agent-x >/dev/null \
  && [ -z "$(git -C "$R1" status --porcelain)" ]; then
  record_case 0 "case 13: SYG_WORKTREE_BRANCH_RE='(' refuses as unusable extended regex, nothing deleted"
else
  record_case 1 "case 13: invalid SYG_WORKTREE_BRANCH_RE='('" "rc=$rc err=$err"
fi

# Case 14: SYG_WORKTREE_BRANCH_RE='' (set but empty) -> behaves as the default:
# against an unmatched branch it refuses like case 4, against a matching
# worktree-agent-x branch it transfers.
mk_fixture r14
R14="$T/r14"
(cd "$R14" && git worktree add -q -b feature/other .wt-other >/dev/null 2>&1)
populate_wt "$R14/.wt-other"
(cd "$R14" && git worktree add -q -b worktree-agent-x .wt-x >/dev/null 2>&1)
populate_wt "$R14/.wt-x"
err_unmatched=$(cd "$R14" && SYG_WORKTREE_BRANCH_RE='' bash "$TOOL" .wt-other 2>&1 >/dev/null)
rc_unmatched=$?
out_matched=$(cd "$R14" && SYG_WORKTREE_BRANCH_RE='' bash "$TOOL" .wt-x 2>&1)
rc_matched=$?
if [ "$rc_unmatched" -eq 1 ] && [[ $err_unmatched == "STOP: worktree-registered:"* ]] \
  && [ -d "$R14/.wt-other" ] \
  && git -C "$R14" rev-parse --verify -q refs/heads/feature/other >/dev/null \
  && [ "$rc_matched" -eq 0 ] \
  && grep -q '^branch worktree-agent-x deleted$' <<<"$out_matched" \
  && [ ! -e "$R14/.wt-x" ] \
  && ! git -C "$R14" rev-parse --verify -q refs/heads/worktree-agent-x >/dev/null; then
  record_case 0 "case 14: SYG_WORKTREE_BRANCH_RE='' (set but empty) falls back to default ^worktree-agent-"
else
  record_case 1 "case 14: SYG_WORKTREE_BRANCH_RE='' empty fallback" \
    "rc_unmatched=$rc_unmatched err=$err_unmatched rc_matched=$rc_matched out=$out_matched"
fi

# Case 15: nothing-outside-patch: submodule with modified tracked file inside
# the worker worktree produces a leading-space porcelain line (` M <path>`) and
# refuses STOP: nothing-outside-patch.
INNER="$T/inner-sub"
git init -q -b main "$INNER" >/dev/null 2>&1
git -C "$INNER" config user.email probe@example.invalid
git -C "$INNER" config user.name 'Probe Harness'
git -C "$INNER" config commit.gpgsign false
printf 'tracked submodule line\n' >"$INNER/inner.txt"
git -C "$INNER" add inner.txt >/dev/null 2>&1
git -C "$INNER" commit -q --no-verify -m 'inner init' >/dev/null 2>&1

mk_fixture r15
R15="$T/r15"
(
  cd "$R15" \
    && git -c protocol.file.allow=always submodule add -q "$INNER" sub >/dev/null 2>&1 \
    && git commit -q --no-verify -m 'add submodule' >/dev/null 2>&1 \
    && git push -q origin main >/dev/null 2>&1 \
    && git worktree add -q -b worktree-agent-sub .wt-sub >/dev/null 2>&1
)
(cd "$R15/.wt-sub" && git -c protocol.file.allow=always submodule update --init -q >/dev/null 2>&1)
populate_wt "$R15/.wt-sub"
printf 'modified uncommitted line in submodule\n' >>"$R15/.wt-sub/sub/inner.txt"

sub_porcelain=$(git -C "$R15/.wt-sub" status --porcelain)
if ! grep -q '^ M sub' <<<"$sub_porcelain"; then
  record_case 1 "case 15: submodule fixture failed to produce the ' M sub' porcelain line" "got: $sub_porcelain"
else
  err=$(cd "$R15" && bash "$TOOL" .wt-sub 2>&1 >/dev/null)
  rc=$?
  if [ "$rc" -eq 1 ] && [[ $err == "STOP: nothing-outside-patch:"* ]] \
    && [ -d "$R15/.wt-sub" ] && [ -z "$(git -C "$R15" status --porcelain)" ]; then
    record_case 0 "case 15: dirty tracked file in submodule produces ' M sub' and refuses STOP: nothing-outside-patch"
  else
    record_case 1 "case 15: nothing-outside-patch" "rc=$rc err=$err porcelain=$sub_porcelain"
  fi
fi

# Case 16: Happy path on R1/.wt (branch worktree-agent-t1).
cp "$R1/.wt/src/data.bin" "$T/expected-data.bin"
out=$(cd "$R1" && bash "$TOOL" .wt 2>&1)
rc=$?
main_porcelain=$(git -C "$R1" status --porcelain)
wt_list=$(git -C "$R1" worktree list --porcelain)

c16_fail=0
c16_reason=""
if [ "$rc" -ne 0 ]; then
  c16_fail=1; c16_reason="rc=$rc out=$out"
elif ! grep -qF 'checks passed: main-tree-identity, main-tree-clean, worktree-registered, base-unchanged (skipped: no --base), empty-patch, nothing-outside-patch, no-unpushed-base, apply, byte-identical, removal' <<<"$out"; then
  c16_fail=1; c16_reason="missing checks passed line in: $out"
elif ! grep -qxF 'worktree removed' <<<"$out"; then
  c16_fail=1; c16_reason="missing 'worktree removed' in: $out"
elif ! grep -qxF 'branch worktree-agent-t1 deleted' <<<"$out"; then
  c16_fail=1; c16_reason="missing 'branch worktree-agent-t1 deleted' in: $out"
elif ! grep -qxF 'next step: run the gates, then commit' <<<"$out"; then
  c16_fail=1; c16_reason="missing 'next step:' line in: $out"
elif [ -z "$main_porcelain" ] || grep -vqE '^[MADRCT]  ' <<<"$main_porcelain"; then
  c16_fail=1; c16_reason="main status --porcelain not cleanly staged: $main_porcelain"
elif [ "$(cat "$R1/src/app.js" 2>/dev/null)" != "export const value = 2;" ]; then
  c16_fail=1; c16_reason="modified file src/app.js content mismatch"
elif [ ! -f "$R1/src/new.js" ]; then
  c16_fail=1; c16_reason="new file src/new.js missing in main tree"
elif [ -e "$R1/src/old.js" ]; then
  c16_fail=1; c16_reason="deleted file src/old.js still exists in main tree"
elif ! cmp -s "$R1/src/data.bin" "$T/expected-data.bin"; then
  c16_fail=1; c16_reason="binary file src/data.bin not byte-identical"
elif [ -e "$R1/dist/out.bin" ]; then
  c16_fail=1; c16_reason="gitignored dist/out.bin unexpectedly transferred"
elif [ -e "$R1/.wt" ]; then
  c16_fail=1; c16_reason="worktree directory .wt still exists"
elif git -C "$R1" rev-parse --verify -q refs/heads/worktree-agent-t1 >/dev/null; then
  c16_fail=1; c16_reason="branch worktree-agent-t1 still exists"
elif grep -qxF "worktree $R1/.wt" <<<"$wt_list"; then
  c16_fail=1; c16_reason="worktree list still contains .wt"
fi
record_case "$c16_fail" "case 16: happy path transfers staged patch (text + binary, no ignored), removes worktree and branch" "$c16_reason"

# Case 17: No remote-tracking refs (origin removed) -> transfer succeeds in a
# never-fetched repo.
mk_fixture r17
R17="$T/r17"
git -C "$R17" remote remove origin >/dev/null 2>&1
out=$(cd "$R17" && bash "$TOOL" .wt 2>&1)
rc=$?
if [ "$rc" -eq 0 ] \
  && grep -q '^branch worktree-agent-t1 deleted$' <<<"$out" \
  && [ ! -e "$R17/.wt" ] \
  && [ -f "$R17/src/new.js" ]; then
  record_case 0 "case 17: transfer succeeds with no remote-tracking refs"
else
  record_case 1 "case 17: no remote-tracking refs" "rc=$rc out=$out"
fi

# Case 18: Detached main working tree -> STOP: main-tree-identity naming detached.
mk_fixture r18
R18="$T/r18"
git -C "$R18" checkout -q --detach HEAD >/dev/null 2>&1
err=$(cd "$R18" && bash "$TOOL" .wt 2>&1 >/dev/null)
rc=$?
if [ "$rc" -eq 1 ] && [[ $err == "STOP: main-tree-identity:"* ]] \
  && grep -q 'detached' <<<"$err" \
  && [ -d "$R18/.wt" ] \
  && git -C "$R18" rev-parse --verify -q refs/heads/worktree-agent-t1 >/dev/null; then
  record_case 0 "case 18: detached main refuses STOP: main-tree-identity naming detached"
else
  record_case 1 "case 18: detached main" "rc=$rc err=$err"
fi

# Case 19: --base=OLD via the = form after main moved -> STOP: base-unchanged.
mk_fixture r19
R19="$T/r19"
OLD_SHA19=$(git -C "$R19" rev-parse HEAD)
printf 'More docs.\n' >>"$R19/README.md"
git -C "$R19" add README.md >/dev/null 2>&1
git -C "$R19" commit -q --no-verify -m 'advance main' >/dev/null 2>&1
err=$(cd "$R19" && bash "$TOOL" "--base=$OLD_SHA19" .wt 2>&1 >/dev/null)
rc=$?
if [ "$rc" -eq 1 ] && [[ $err == "STOP: base-unchanged:"* ]]; then
  record_case 0 "case 19: --base=OLD (the = form) after main moved refuses STOP: base-unchanged"
else
  record_case 1 "case 19: --base= form" "rc=$rc err=$err"
fi

# Case 20: Usage errors -> exit 2 with usage text on stderr.
err_nopos=$(bash "$TOOL" 2>&1 >/dev/null); rc_nopos=$?
err_twopos=$(bash "$TOOL" a b 2>&1 >/dev/null); rc_twopos=$?
err_badflag=$(bash "$TOOL" --nope x 2>&1 >/dev/null); rc_badflag=$?
if [ "$rc_nopos" -eq 2 ] && [ -n "$err_nopos" ] \
  && [ "$rc_twopos" -eq 2 ] && [ -n "$err_twopos" ] \
  && [ "$rc_badflag" -eq 2 ] && [ -n "$err_badflag" ]; then
  record_case 0 "case 20: no positional, two positionals, unknown flag all exit 2 with usage"
else
  record_case 1 "case 20: usage errors" \
    "rc_nopos=$rc_nopos rc_twopos=$rc_twopos rc_badflag=$rc_badflag"
fi

# Case 21: diff.noprefix=true in the fixture repo -> transfer still succeeds
# with the new file at its real nested path (the flag set pins the prefixes).
mk_fixture r21
R21="$T/r21"
git -C "$R21" config diff.noprefix true >/dev/null 2>&1
out=$(cd "$R21" && bash "$TOOL" .wt 2>&1)
rc=$?
if [ "$rc" -eq 0 ] \
  && [ -f "$R21/src/new.js" ] \
  && [ ! -e "$R21/new.js" ] \
  && [ ! -e "$R21/.wt" ] \
  && ! git -C "$R21" rev-parse --verify -q refs/heads/worktree-agent-t1 >/dev/null; then
  record_case 0 "case 21: diff.noprefix=true still transfers with the file at its nested path"
else
  record_case 1 "case 21: diff.noprefix=true" "rc=$rc out=$out"
fi

# Case 22: Worktree cut from an OLDER commit than main HEAD -> STOP:
# no-unpushed-base naming the differing HEADs.
mk_fixture r22
R22="$T/r22"
MAIN_HEAD22=$(git -C "$R22" rev-parse HEAD)
printf 'Later docs.\n' >>"$R22/README.md"
git -C "$R22" add README.md >/dev/null 2>&1
git -C "$R22" commit -q --no-verify -m 'advance main' >/dev/null 2>&1
(cd "$R22" && git worktree add -q -b worktree-agent-old .wt-old "$MAIN_HEAD22" >/dev/null 2>&1)
populate_wt "$R22/.wt-old"
err=$(cd "$R22" && bash "$TOOL" .wt-old 2>&1 >/dev/null)
rc=$?
if [ "$rc" -eq 1 ] && [[ $err == "STOP: no-unpushed-base:"* ]] \
  && grep -q 'differs from the main tree HEAD' <<<"$err" \
  && [ -d "$R22/.wt-old" ] \
  && git -C "$R22" rev-parse --verify -q refs/heads/worktree-agent-old >/dev/null; then
  record_case 0 "case 22: worktree behind main HEAD refuses STOP: no-unpushed-base (differing HEADs named)"
else
  record_case 1 "case 22: worktree behind main" "rc=$rc err=$err"
fi

# Case 23: A LOCKED worktree -> transfer still succeeds (unlock then remove --force).
mk_fixture r23
R23="$T/r23"
git -C "$R23" worktree lock --reason 'probe lock' "$R23/.wt" >/dev/null 2>&1
out=$(cd "$R23" && bash "$TOOL" .wt 2>&1)
rc=$?
if [ "$rc" -eq 0 ] \
  && grep -q '^worktree removed$' <<<"$out" \
  && grep -q '^branch worktree-agent-t1 deleted$' <<<"$out" \
  && [ ! -e "$R23/.wt" ]; then
  record_case 0 "case 23: locked worktree unlocks and transfers"
else
  record_case 1 "case 23: locked worktree" "rc=$rc out=$out"
fi

[ "$fail" -eq 0 ] || exit 1
echo "PASS: worktree-transfer ($pass cases)"
