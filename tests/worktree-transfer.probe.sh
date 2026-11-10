#!/bin/bash
# Fixture check for plugins/seyag/bin/worktree-transfer — run after ANY
# edit to the script. 56 cases assert the fixed check order, refusal shapes,
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
#  24. status.showUntrackedFiles=no in the fixture repo -> an untracked file in
#      the main tree still refuses STOP: main-tree-clean
#  25. a worker that committed everything and left a clean tree -> STOP:
#      no-unpushed-base (the HEAD diagnosis fires before the empty-patch check)
#  26. a gitignored non-build file in the worktree -> transfer succeeds and the
#      output lists the file as deleted-with-the-tree
#  27. skip-worktree edit in the worktree -> STOP: nothing-outside-patch, tree kept and main untouched
#  28. assume-unchanged edit in the worktree -> STOP: nothing-outside-patch, tree kept and main untouched
#  29. untracked nested repo in the worktree -> STOP: worktree-gitfile, tree kept
#  30. apply.whitespace=fix with trailing whitespace in patch -> STOP: byte-identical, tree kept
#  31. apply.whitespace=error with trailing whitespace in patch -> STOP: apply, tree kept
#  32. sparse worker tree with in-cone edit -> transfer succeeds
#  33. sparse worker tree with on-disk skip-worktree edit -> STOP: nothing-outside-patch
#  34. gitlink at a path with a space, commit in main's module store -> transfer succeeds
#  35. gitlink at a path with a quote, commit in main's module store -> transfer succeeds
#  36. repointed .git with core.fsmonitor -> STOP: worktree-gitfile without firing fsmonitor
#  37. untracked nested repo with core.fsmonitor -> STOP: worktree-gitfile without firing fsmonitor
#  38. planted repo at sub/ (no .git name) -> STOP: worktree-gitfile without firing fsmonitor
#  39. --rebase-base fast-forward: main advanced on README.md only -> transfer succeeds with rebase-proof line
#  40. --rebase-base conflict: touched src/app.js changed on main -> STOP: rebase-proof naming changed on main: src/app.js
#  41. --rebase-base squash merge with identical trees -> transfer succeeds with 'whole trees identical'
#  42. --rebase-base stacked branch commit not on main -> STOP: rebase-proof naming changed only on the worktree's branch: feat.txt
#  43. --rebase-base file/directory boundary conflict -> STOP: rebase-proof naming src/data.bin/inner.txt
#  44. --rebase-base literal special-char filenames (src/*.js, :odd.txt) with sibling src/other.js changed on main -> transfer succeeds
#  45. --rebase-base --base mismatch vs match -> STOP: base-unchanged on main HEAD, exit 0 on worktree HEAD
#  46. behind-main refusal without --rebase-base -> stderr suggests 'rerun with --rebase-base'
#  47. --rebase-base literal glob conflict: main and patch both edit src/*.js -> STOP: rebase-proof naming src/*.js
#  48. --rebase-base reverse file/directory boundary: patch adds src/newdir/x.txt, main commits file src/newdir -> STOP: rebase-proof naming src/newdir
#  49. --rebase-base scale: main adds 5000 files under bulk/ -> transfer succeeds with rebase-proof line
#  50. --rebase-base worker commit (main is ancestor of worktree HEAD, no upstream or upstream lacking commit) -> STOP: rebase-proof with land-on-main hint and README.md
#  51. unpulled main (origin/main ahead of local main) -> git pull --ff-only hint across --rebase-base, default, and --base
#  52. --rebase-base criss-cross merge bases -> second merge-base exposes conflict path alongside first
#  53. --rebase-base patch delete vs main edit on src/old.js -> STOP: rebase-proof naming changed on main: src/old.js
#  54. --rebase-base patch rename vs main edit on README.md -> STOP: rebase-proof naming changed on main: README.md
#  55. orphan worktree (unborn HEAD) -> STOP: base-unchanged naming rev-parse HEAD failed in worktree
#  56. --rebase-base empty worker commit -> transfer succeeds with rebase-proof line
#  57. worker commit changing README.md, no upstream -> default STOP: no-unpushed-base and --base STOP: base-unchanged, both with land-on-main hint
#  58. --allow-empty worker commit -> default and --base STOP name rerun with --rebase-base; --rebase-base then transfers
#
# Stated non-goal: the two removal-failure wordings (`git worktree remove --force`
# vs `git branch -D` in check 11) are not constructible without root tricks; the
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
elif ! grep -qF 'checks passed: main-tree-identity, main-tree-clean, worktree-registered, worktree-gitfile, base-unchanged (skipped: no --base), no-unpushed-base, empty-patch, nothing-outside-patch, rebase-proof (skipped: no --rebase-base), apply, byte-identical, removal' <<<"$out"; then
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
  && grep -qF 'rerun with --rebase-base' <<<"$err" \
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

# Case 24: status.showUntrackedFiles=no in the fixture repo -> an untracked
# file in the main tree STILL refuses STOP: main-tree-clean.
mk_fixture r24
R24="$T/r24"
git -C "$R24" config status.showUntrackedFiles no >/dev/null 2>&1
printf 'hidden untracked content\n' >"$R24/stray-hidden.txt"
err=$(cd "$R24" && bash "$TOOL" .wt 2>&1 >/dev/null)
rc=$?
if [ "$rc" -eq 1 ] && [[ $err == "STOP: main-tree-clean:"* ]]; then
  record_case 0 "case 24: status.showUntrackedFiles=no does not hide an untracked main-tree file"
else
  record_case 1 "case 24: untracked-hidden config" "rc=$rc err=$err"
fi

# Case 25: A worker that committed everything and left a clean tree -> STOP:
# no-unpushed-base (the HEAD diagnosis fires BEFORE the empty-patch check).
mk_fixture r25
R25="$T/r25"
printf 'committed change\n' >"$R25/.wt/committed.txt"
git -C "$R25/.wt" add committed.txt >/dev/null 2>&1
git -C "$R25/.wt" commit -q --no-verify -m 'worker commit' >/dev/null 2>&1
err=$(cd "$R25" && bash "$TOOL" .wt 2>&1 >/dev/null)
rc=$?
if [ "$rc" -eq 1 ] && [[ $err == "STOP: no-unpushed-base:"* ]] \
  && [[ $err != *"empty-patch"* ]]; then
  record_case 0 "case 25: committed-everything worker is diagnosed by HEAD, not by an empty patch"
else
  record_case 1 "case 25: committed-everything worker" "rc=$rc err=$err"
fi

# Case 26: A gitignored NON-build file in the worktree -> transfer succeeds
# and the output lists the file as deleted with the tree.
mk_fixture r26
R26="$T/r26"
printf 'notes/\n' >>"$R26/.wt/.gitignore"
mkdir -p "$R26/.wt/notes"
printf 'worker wanted this\n' >"$R26/.wt/notes/local.md"
out=$(cd "$R26" && bash "$TOOL" .wt 2>&1)
rc=$?
if [ "$rc" -eq 0 ] \
  && grep -q 'ignored file(s) in the worktree will be deleted' <<<"$out" \
  && grep -qF 'notes/local.md' <<<"$out" \
  && grep -q '^branch worktree-agent-t1 deleted$' <<<"$out" \
  && [ ! -e "$R26/.wt" ]; then
  record_case 0 "case 26: ignored files are listed on the output before the tree is removed"
else
  record_case 1 "case 26: ignored-file listing" "rc=$rc out=$out"
fi

# Case 27: skip-worktree edit refuses with the tree kept and main untouched.
mk_fixture r27
R27="$T/r27"
printf 'skip-worktree edit\n' >>"$R27/.wt/README.md"
git -C "$R27/.wt" update-index --skip-worktree README.md
err=$(cd "$R27" && bash "$TOOL" .wt 2>&1 >/dev/null)
rc=$?
if [ "$rc" -eq 1 ] && [[ $err == "STOP: nothing-outside-patch:"* ]] \
  && grep -qF 'README.md' <<<"$err" \
  && grep -qF 'assume-unchanged or skip-worktree edits would be lost' <<<"$err" \
  && [ -d "$R27/.wt" ] \
  && grep -qF 'skip-worktree edit' "$R27/.wt/README.md" \
  && [ -z "$(git -C "$R27" status --porcelain)" ]; then
  record_case 0 "case 27: skip-worktree edit refuses STOP: nothing-outside-patch with tree kept and main untouched"
else
  record_case 1 "case 27: skip-worktree edit" "rc=$rc err=$err"
fi

# Case 28: assume-unchanged edit refuses with the tree kept and main untouched.
mk_fixture r28
R28="$T/r28"
printf 'assume-unchanged edit\n' >>"$R28/.wt/README.md"
git -C "$R28/.wt" update-index --assume-unchanged README.md
err=$(cd "$R28" && bash "$TOOL" .wt 2>&1 >/dev/null)
rc=$?
if [ "$rc" -eq 1 ] && [[ $err == "STOP: nothing-outside-patch:"* ]] \
  && grep -qF 'README.md' <<<"$err" \
  && grep -qF 'assume-unchanged or skip-worktree edits would be lost' <<<"$err" \
  && [ -d "$R28/.wt" ] \
  && grep -qF 'assume-unchanged edit' "$R28/.wt/README.md" \
  && [ -z "$(git -C "$R28" status --porcelain)" ]; then
  record_case 0 "case 28: assume-unchanged edit refuses STOP: nothing-outside-patch with tree kept and main untouched"
else
  record_case 1 "case 28: assume-unchanged edit" "rc=$rc err=$err"
fi

# Case 29: untracked nested repo refuses with the tree kept.
mk_fixture r29
R29="$T/r29"
git init -q -b main "$R29/.wt/nested-repo" >/dev/null 2>&1
git -C "$R29/.wt/nested-repo" config user.email probe@example.invalid
git -C "$R29/.wt/nested-repo" config user.name 'Probe Harness'
git -C "$R29/.wt/nested-repo" config commit.gpgsign false
printf 'unique nested repo payload\n' >"$R29/.wt/nested-repo/nested.txt"
git -C "$R29/.wt/nested-repo" add nested.txt >/dev/null 2>&1
git -C "$R29/.wt/nested-repo" commit -q --no-verify -m 'nested repo commit' >/dev/null 2>&1
err=$(cd "$R29" && bash "$TOOL" .wt 2>&1 >/dev/null)
rc=$?
if [ "$rc" -eq 1 ] && [[ $err == "STOP: worktree-gitfile:"* ]] \
  && grep -qF 'nested-repo' <<<"$err" \
  && [ -d "$R29/.wt/nested-repo/.git" ] \
  && [ -f "$R29/.wt/nested-repo/nested.txt" ] \
  && [ -z "$(git -C "$R29" status --porcelain)" ]; then
  record_case 0 "case 29: untracked nested repo refuses STOP: worktree-gitfile with tree kept"
else
  record_case 1 "case 29: untracked nested repo" "rc=$rc err=$err"
fi

# Case 30: STOP: byte-identical via apply.whitespace=fix reached with the tree kept.
mk_fixture r30
R30="$T/r30"
git -C "$R30" config apply.whitespace fix
printf 'export const value = 2;   \n' >"$R30/.wt/src/app.js"
err=$(cd "$R30" && bash "$TOOL" .wt 2>&1 >/dev/null)
rc=$?
kept_patch=${err#*kept at }
kept_patch=${kept_patch%% *}
[ -n "$kept_patch" ] && [ -f "$kept_patch" ] && rm -rf -- "$(dirname "$kept_patch")"
if [ "$rc" -eq 1 ] && [[ $err == "STOP: byte-identical:"* ]] \
  && [ -d "$R30/.wt" ] \
  && git -C "$R30" rev-parse --verify -q refs/heads/worktree-agent-t1 >/dev/null; then
  record_case 0 "case 30: apply.whitespace=fix reaches STOP: byte-identical with the tree kept"
else
  record_case 1 "case 30: STOP: byte-identical via apply.whitespace=fix" "rc=$rc err=$err"
fi

# Case 31: STOP: apply reached with the tree kept.
mk_fixture r31
R31="$T/r31"
git -C "$R31" config apply.whitespace error
printf 'export const value = 2;   \n' >"$R31/.wt/src/app.js"
err=$(cd "$R31" && bash "$TOOL" .wt 2>&1 >/dev/null)
rc=$?
if [ "$rc" -eq 1 ] && [[ $err == "STOP: apply:"* ]] \
  && [ -d "$R31/.wt" ] \
  && git -C "$R31" rev-parse --verify -q refs/heads/worktree-agent-t1 >/dev/null \
  && [ -z "$(git -C "$R31" status --porcelain)" ]; then
  record_case 0 "case 31: apply failure reaches STOP: apply with the tree kept"
else
  record_case 1 "case 31: STOP: apply" "rc=$rc err=$err"
fi

# Case 32: A sparse worker tree with an in-cone edit transfers (out-of-cone S
# entries absent from disk do not refuse).
mk_fixture r32
R32="$T/r32"
mkdir -p "$R32/docs"
printf 'guide v1\n' >"$R32/docs/guide.md"
git -C "$R32" add docs/guide.md >/dev/null 2>&1
git -C "$R32" commit -q --no-verify -m 'add docs/guide.md' >/dev/null 2>&1
git -C "$R32" push -q origin main >/dev/null 2>&1
(cd "$R32" && git worktree add -q -b worktree-agent-sparse .wt-sparse >/dev/null 2>&1)
git -C "$R32/.wt-sparse" sparse-checkout set src >/dev/null 2>&1
sparse_tag=$(git -C "$R32/.wt-sparse" ls-files -v -- docs/guide.md)
printf 'export const value = 3;\n' >"$R32/.wt-sparse/src/app.js"
out=$(cd "$R32" && bash "$TOOL" .wt-sparse 2>&1)
rc=$?
if [ "$rc" -eq 0 ] \
  && [ "$sparse_tag" = "S docs/guide.md" ] \
  && [ "$(cat "$R32/src/app.js" 2>/dev/null)" = "export const value = 3;" ] \
  && [ -f "$R32/docs/guide.md" ] \
  && [ ! -e "$R32/.wt-sparse" ] \
  && ! git -C "$R32" rev-parse --verify -q refs/heads/worktree-agent-sparse >/dev/null; then
  record_case 0 "case 32: sparse worker tree with an in-cone edit transfers"
else
  record_case 1 "case 32: sparse worker tree with in-cone edit" "rc=$rc sparse_tag='$sparse_tag' out=$out"
fi

# Case 33: In a sparse worker tree, a skip-worktree (S) file present on disk
# with an edit still refuses.
mk_fixture r33
R33="$T/r33"
mkdir -p "$R33/docs"
printf 'guide v1\n' >"$R33/docs/guide.md"
git -C "$R33" add docs/guide.md >/dev/null 2>&1
git -C "$R33" commit -q --no-verify -m 'add docs/guide.md' >/dev/null 2>&1
git -C "$R33" push -q origin main >/dev/null 2>&1
(cd "$R33" && git worktree add -q -b worktree-agent-sparse-disk .wt-sparse-disk >/dev/null 2>&1)
git -C "$R33/.wt-sparse-disk" sparse-checkout set src >/dev/null 2>&1
printf 'export const value = 4;\n' >"$R33/.wt-sparse-disk/src/app.js"
mkdir -p "$R33/.wt-sparse-disk/docs"
printf 'on-disk skip-worktree edit\n' >"$R33/.wt-sparse-disk/docs/guide.md"
err=$(cd "$R33" && bash "$TOOL" .wt-sparse-disk 2>&1 >/dev/null)
rc=$?
if [ "$rc" -eq 1 ] && [[ $err == "STOP: nothing-outside-patch:"* ]] \
  && grep -qF 'docs/guide.md' <<<"$err" \
  && [ -d "$R33/.wt-sparse-disk" ] \
  && [ -z "$(git -C "$R33" status --porcelain)" ]; then
  record_case 0 "case 33: skip-worktree file present on disk with an edit still refuses"
else
  record_case 1 "case 33: skip-worktree file on disk in sparse tree" "rc=$rc err=$err"
fi

# Case 34: A gitlink at a path containing a space, with its commit in main's
# module store, transfers.
SUB_SPACE="$T/sub-space-origin"
git init -q -b main "$SUB_SPACE" >/dev/null 2>&1
git -C "$SUB_SPACE" config user.email probe@example.invalid
git -C "$SUB_SPACE" config user.name 'Probe Harness'
git -C "$SUB_SPACE" config commit.gpgsign false
printf 'sub space v1\n' >"$SUB_SPACE/s.txt"
git -C "$SUB_SPACE" add s.txt >/dev/null 2>&1
git -C "$SUB_SPACE" commit -q --no-verify -m 'sub space v1' >/dev/null 2>&1
mk_fixture r34
R34="$T/r34"
(
  cd "$R34" \
    && git -c protocol.file.allow=always submodule add -q "$SUB_SPACE" "sub space" >/dev/null 2>&1 \
    && git commit -q --no-verify -m 'add sub space' >/dev/null 2>&1 \
    && git push -q origin main >/dev/null 2>&1 \
    && git worktree add -q -b worktree-agent-space .wt-space >/dev/null 2>&1
)
printf 'sub space v2\n' >"$SUB_SPACE/s.txt"
git -C "$SUB_SPACE" commit -qam 'sub space v2' >/dev/null 2>&1
SUB_SPACE_V2=$(git -C "$SUB_SPACE" rev-parse HEAD)
git -C "$R34/sub space" -c protocol.file.allow=always fetch -q origin main >/dev/null 2>&1
(cd "$R34/.wt-space" && git -c protocol.file.allow=always submodule update --init -q >/dev/null 2>&1)
git -C "$R34/.wt-space/sub space" checkout -q "$SUB_SPACE_V2"
out=$(cd "$R34" && bash "$TOOL" .wt-space 2>&1)
rc=$?
if [ "$rc" -eq 0 ] \
  && [ "$(git -C "$R34" ls-files -s -- "sub space" | awk '{print $2}')" = "$SUB_SPACE_V2" ] \
  && [ ! -e "$R34/.wt-space" ] \
  && ! git -C "$R34" rev-parse --verify -q refs/heads/worktree-agent-space >/dev/null; then
  record_case 0 "case 34: gitlink at path with a space, commit in main's module store, transfers"
else
  record_case 1 "case 34: gitlink at path with a space" "rc=$rc out=$out"
fi

# Case 35: A gitlink at a path with a quote, with its commit in main's module
# store, does not false-refuse.
SUB_QUOTE="$T/sub-quote-origin"
git init -q -b main "$SUB_QUOTE" >/dev/null 2>&1
git -C "$SUB_QUOTE" config user.email probe@example.invalid
git -C "$SUB_QUOTE" config user.name 'Probe Harness'
git -C "$SUB_QUOTE" config commit.gpgsign false
printf 'sub quote v1\n' >"$SUB_QUOTE/q.txt"
git -C "$SUB_QUOTE" add q.txt >/dev/null 2>&1
git -C "$SUB_QUOTE" commit -q --no-verify -m 'sub quote v1' >/dev/null 2>&1
mk_fixture r35
R35="$T/r35"
qpath='sub "quote"'
(
  cd "$R35" \
    && git -c protocol.file.allow=always submodule add -q "$SUB_QUOTE" "$qpath" >/dev/null 2>&1 \
    && git commit -q --no-verify -m 'add sub quote' >/dev/null 2>&1 \
    && git push -q origin main >/dev/null 2>&1 \
    && git worktree add -q -b worktree-agent-quote .wt-quote >/dev/null 2>&1
)
printf 'sub quote v2\n' >"$SUB_QUOTE/q.txt"
git -C "$SUB_QUOTE" commit -qam 'sub quote v2' >/dev/null 2>&1
SUB_QUOTE_V2=$(git -C "$SUB_QUOTE" rev-parse HEAD)
git -C "$R35/$qpath" -c protocol.file.allow=always fetch -q origin main >/dev/null 2>&1
(cd "$R35/.wt-quote" && git -c protocol.file.allow=always submodule update --init -q >/dev/null 2>&1)
git -C "$R35/.wt-quote/$qpath" checkout -q "$SUB_QUOTE_V2"
raw_z_sample=$(git -C "$R35/.wt-quote" diff --raw --no-renames --no-abbrev --ignore-submodules=none -z | tr '\0' '|')
out=$(cd "$R35" && bash "$TOOL" .wt-quote 2>&1)
rc=$?
if [ "$rc" -eq 0 ] \
  && [[ $raw_z_sample == :160000\ 160000\ *\ M\|"$qpath"\| ]] \
  && [ "$(git -C "$R35" ls-files -s -- "$qpath" | awk '{print $2}')" = "$SUB_QUOTE_V2" ] \
  && [ ! -e "$R35/.wt-quote" ] \
  && ! git -C "$R35" rev-parse --verify -q refs/heads/worktree-agent-quote >/dev/null; then
  record_case 0 "case 35: gitlink at path with a quote does not false-refuse and transfers"
else
  record_case 1 "case 35: gitlink at path with a quote" "rc=$rc raw_z=$raw_z_sample out=$out"
fi

# Case 36: A worktree whose .git is repointed at a crafted gitdir with
# core.fsmonitor set to a script that touches a marker file refuses
# STOP: worktree-gitfile without firing the marker; direct git -C status fires it.
mk_fixture r36
R36="$T/r36"
FSM36_CRAFTED="$T/r36-crafted.git"
FSM36_MARKER="$T/r36-fsmonitor.marker"
FSM36_HOOK="$T/r36-fsmonitor-hook.sh"
printf '#!/bin/sh\n: > "%s"\n' "$FSM36_MARKER" >"$FSM36_HOOK"
chmod +x "$FSM36_HOOK"
cp -R "$R36/.git" "$FSM36_CRAFTED"
git --git-dir="$FSM36_CRAFTED" config core.fsmonitor "$FSM36_HOOK"
printf 'gitdir: %s\n' "$FSM36_CRAFTED" >"$R36/.wt/.git"
rm -f "$FSM36_MARKER"
err=$(cd "$R36" && bash "$TOOL" .wt 2>&1 >/dev/null)
rc=$?
marker_before=absent
[ -e "$FSM36_MARKER" ] && marker_before=present
git -C "$R36/.wt" status >/dev/null 2>&1
marker_after=absent
[ -e "$FSM36_MARKER" ] && marker_after=present
if [ "$rc" -eq 1 ] && [[ $err == "STOP: worktree-gitfile:"* ]] \
  && [ "$marker_before" = absent ] && [ "$marker_after" = present ] \
  && [ -d "$R36/.wt" ] && [ -z "$(git -C "$R36" status --porcelain)" ]; then
  record_case 0 "case 36: repointed .git with core.fsmonitor refuses STOP: worktree-gitfile without firing marker (direct git -C status fires it)"
else
  record_case 1 "case 36: repointed .git with core.fsmonitor" \
    "rc=$rc marker_before=$marker_before marker_after=$marker_after err=$err"
fi

# Case 37: An untracked nested repo whose .git directory has core.fsmonitor set
# to a marker-touching script refuses STOP: worktree-gitfile with the tree kept,
# main tree clean, and marker absent; git add sub + git status fires the marker.
mk_fixture r37
R37="$T/r37"
FSM37_WT="$R37/.wt"
FSM37_MARKER="$T/r37-fsmonitor.marker"
FSM37_HOOK="$T/r37-fsmonitor-hook.sh"
printf '#!/bin/sh\n: > "%s"\n' "$FSM37_MARKER" >"$FSM37_HOOK"
chmod +x "$FSM37_HOOK"
mkdir "$FSM37_WT/sub"
cp -R "$R37/.git" "$FSM37_WT/sub/.git"
rm -rf "$FSM37_WT/sub/.git/worktrees"
git -C "$FSM37_WT/sub" reset -q --hard main
git -C "$FSM37_WT/sub" config core.fsmonitor "$FSM37_HOOK"
rm -f "$FSM37_MARKER"
err=$(cd "$R37" && bash "$TOOL" .wt 2>&1 >/dev/null)
rc=$?
marker37_before=absent
[ -e "$FSM37_MARKER" ] && marker37_before=present
git -C "$FSM37_WT" add sub 2>/dev/null
git -C "$FSM37_WT" status >/dev/null 2>&1
marker37_after=absent
[ -e "$FSM37_MARKER" ] && marker37_after=present
if [ "$rc" -eq 1 ] && [[ $err == "STOP: worktree-gitfile:"* ]] \
  && [ "$marker37_before" = absent ] && [ "$marker37_after" = present ] \
  && [ -d "$FSM37_WT" ] && [ -z "$(git -C "$R37" status --porcelain)" ]; then
  record_case 0 "case 37: untracked nested repo with core.fsmonitor refuses STOP: worktree-gitfile without firing marker (add + status fires it)"
else
  record_case 1 "case 37: untracked nested repo with core.fsmonitor" \
    "rc=$rc marker_before=$marker37_before marker_after=$marker37_after err=$err"
fi

# Case 38: A planted repo (no .git name) at sub/ beside a normal edit refuses
# STOP: worktree-gitfile: with the tree kept, main tree clean, sub absent from
# the main tree, and marker absent; git -C "$WT/sub" status then fires the marker.
plant_repo() { # $1=dir $2=hook
  mkdir -p "$1/objects" "$1/refs/heads"
  printf 'ref: refs/heads/main\n' >"$1/HEAD"
  : >"$1/objects/.keep"
  : >"$1/refs/heads/.keep"
  printf '[core]\n\trepositoryformatversion = 0\n\tbare = false\n\tworktree = ..\n\tfsmonitor = %s\n' "$2" >"$1/config"
}
mk_fixture r38
R38="$T/r38"
FSM38_WT="$R38/.wt"
FSM38_MARKER="$T/r38-fsmonitor.marker"
FSM38_HOOK="$T/r38-fsmonitor-hook.sh"
printf '#!/bin/sh\n: > "%s"\n' "$FSM38_MARKER" >"$FSM38_HOOK"
chmod +x "$FSM38_HOOK"
plant_repo "$FSM38_WT/sub" "$FSM38_HOOK"
rm -f "$FSM38_MARKER"
err=$(cd "$R38" && bash "$TOOL" .wt 2>&1 >/dev/null)
rc=$?
marker38_before=absent
[ -e "$FSM38_MARKER" ] && marker38_before=present
git -C "$FSM38_WT/sub" status >/dev/null 2>&1
marker38_after=absent
[ -e "$FSM38_MARKER" ] && marker38_after=present
if [ "$rc" -eq 1 ] && [[ $err == "STOP: worktree-gitfile:"* ]] \
  && grep -qF 'sub' <<<"$err" \
  && [ "$marker38_before" = absent ] && [ "$marker38_after" = present ] \
  && [ -d "$FSM38_WT" ] && [ ! -e "$R38/sub" ] \
  && [ -z "$(git -C "$R38" status --porcelain)" ]; then
  record_case 0 "case 38: planted repo at sub/ (no .git) refuses STOP: worktree-gitfile with tree kept, main clean, sub absent from main, marker absent (git -C sub status fires it)"
else
  record_case 1 "case 38: planted repo at sub/ (no .git)" \
    "rc=$rc marker_before=$marker38_before marker_after=$marker38_after sub_in_main=$([ -e "$R38/sub" ] && echo present || echo absent) err=$err"
fi

# Case 39: --rebase-base fast-forward: worktree cut at the old base, main
# advanced with a commit touching only README.md -> exit 0, staged in main,
# rebase-proof line, worktree and branch removed.
mk_fixture r39
R39="$T/r39"
printf 'Later docs on main.\n' >>"$R39/README.md"
git -C "$R39" add README.md >/dev/null 2>&1
git -C "$R39" commit -q --no-verify -m 'advance main on README' >/dev/null 2>&1
out=$(cd "$R39" && bash "$TOOL" --rebase-base .wt 2>&1)
rc=$?
main_porcelain39=$(git -C "$R39" status --porcelain)
if [ "$rc" -eq 0 ] \
  && [ "$(cat "$R39/src/app.js" 2>/dev/null)" = "export const value = 2;" ] \
  && [ -f "$R39/src/new.js" ] \
  && [ ! -e "$R39/src/old.js" ] \
  && [ -n "$main_porcelain39" ] && ! grep -vqE '^[MADRCT]  ' <<<"$main_porcelain39" \
  && grep -q '^rebase-proof: .*identical at worktree HEAD ' <<<"$out" \
  && grep -qF 'no-unpushed-base (deferred to rebase-proof)' <<<"$out" \
  && grep -qF ', rebase-proof, apply' <<<"$out" \
  && [ ! -e "$R39/.wt" ] \
  && ! git -C "$R39" rev-parse --verify -q refs/heads/worktree-agent-t1 >/dev/null; then
  record_case 0 "case 39: --rebase-base fast-forward transfers onto advanced main with rebase-proof"
else
  record_case 1 "case 39: --rebase-base fast-forward" "rc=$rc out=$out porcelain=$main_porcelain39"
fi

# Case 40: --rebase-base when a touched file (src/app.js) changed on main ->
# exit 1, STOP: rebase-proof: naming changed on main: src/app.js, worktree and branch kept, main clean.
mk_fixture r40
R40="$T/r40"
if ! printf 'export const value = 99;\n' >"$R40/src/app.js" \
  || ! git -C "$R40" add src/app.js >/dev/null 2>&1 \
  || ! git -C "$R40" commit -q --no-verify -m 'advance main on src/app.js' >/dev/null 2>&1; then
  record_case 1 "case 40: --rebase-base conflict on src/app.js" "setup: advance main on src/app.js failed"
else
  err=$(cd "$R40" && bash "$TOOL" --rebase-base .wt 2>&1 >/dev/null)
  rc=$?
  if [ "$rc" -eq 1 ] && [[ $err == "STOP: rebase-proof:"* ]] \
    && grep -qF 'src/app.js' <<<"$err" \
    && grep -qF 'changed on main: src/app.js' <<<"$err" \
    && [ -d "$R40/.wt" ] \
    && git -C "$R40" rev-parse --verify -q refs/heads/worktree-agent-t1 >/dev/null \
    && [ -z "$(git -C "$R40" status --porcelain)" ]; then
    record_case 0 "case 40: --rebase-base refuses STOP: rebase-proof when main changed touched src/app.js"
  else
    record_case 1 "case 40: --rebase-base conflict on src/app.js" "rc=$rc err=$err"
  fi
fi

# Case 41: --rebase-base squash merge with identical trees -> exit 0, proof line
# contains 'whole trees identical'.
mk_fixture r41
R41="$T/r41"
git -C "$R41" checkout -q -b feat >/dev/null 2>&1
printf 'feature content\n' >"$R41/feat.txt"
git -C "$R41" add feat.txt >/dev/null 2>&1
git -C "$R41" commit -q --no-verify -m 'feat commit' >/dev/null 2>&1
(cd "$R41" && git worktree add -q -b worktree-agent-sq .wt-sq feat >/dev/null 2>&1)
populate_wt "$R41/.wt-sq"
git -C "$R41" checkout -q main >/dev/null 2>&1
git -C "$R41" merge -q --squash feat >/dev/null 2>&1
git -C "$R41" commit -q --no-verify -m 'squash feat' >/dev/null 2>&1
out=$(cd "$R41" && bash "$TOOL" --rebase-base .wt-sq 2>&1)
rc=$?
if [ "$rc" -eq 0 ] \
  && grep -q '^rebase-proof: .*whole trees identical$' <<<"$out" \
  && [ -f "$R41/src/new.js" ] \
  && [ -f "$R41/feat.txt" ] \
  && [ ! -e "$R41/.wt-sq" ] \
  && ! git -C "$R41" rev-parse --verify -q refs/heads/worktree-agent-sq >/dev/null; then
  record_case 0 "case 41: --rebase-base after squash-merge with identical trees transfers and notes whole trees identical"
else
  record_case 1 "case 41: --rebase-base squash identical trees" "rc=$rc out=$out"
fi

# Case 42: --rebase-base when worktree's branch commit is not on main ->
# exit 1, STOP: rebase-proof: naming feat.txt, nothing staged in main.
mk_fixture r42
R42="$T/r42"
if ! git -C "$R42" checkout -q -b feat >/dev/null 2>&1 \
  || ! printf 'feature content\n' >"$R42/feat.txt" \
  || ! git -C "$R42" add feat.txt >/dev/null 2>&1 \
  || ! git -C "$R42" commit -q --no-verify -m 'feat commit' >/dev/null 2>&1 \
  || ! (cd "$R42" && git worktree add -q -b worktree-agent-unmerged .wt-unmerged feat >/dev/null 2>&1) \
  || ! populate_wt "$R42/.wt-unmerged" \
  || ! git -C "$R42" checkout -q main >/dev/null 2>&1 \
  || ! printf 'Unrelated main docs.\n' >>"$R42/README.md" \
  || ! git -C "$R42" add README.md >/dev/null 2>&1 \
  || ! git -C "$R42" commit -q --no-verify -m 'advance main on README' >/dev/null 2>&1; then
  record_case 1 "case 42: --rebase-base unmerged branch commit" "setup: unmerged branch fixture failed"
else
  err=$(cd "$R42" && bash "$TOOL" --rebase-base .wt-unmerged 2>&1 >/dev/null)
  rc=$?
  if [ "$rc" -eq 1 ] && [[ $err == "STOP: rebase-proof:"* ]] \
    && grep -qF 'feat.txt' <<<"$err" \
    && grep -qF "changed only on the worktree's branch: feat.txt" <<<"$err" \
    && ! grep -qF 'changed on main' <<<"$err" \
    && [ -d "$R42/.wt-unmerged" ] \
    && git -C "$R42" rev-parse --verify -q refs/heads/worktree-agent-unmerged >/dev/null \
    && [ -z "$(git -C "$R42" status --porcelain)" ]; then
    record_case 0 "case 42: --rebase-base with unmerged branch commit refuses STOP: rebase-proof naming feat.txt"
  else
    record_case 1 "case 42: --rebase-base unmerged branch commit" "rc=$rc err=$err"
  fi
fi

# Case 43: --rebase-base file/directory boundary: worktree adds file src/data.bin,
# main commits src/data.bin/inner.txt -> exit 1, STOP: rebase-proof: naming src/data.bin/inner.txt.
mk_fixture r43
R43="$T/r43"
mkdir -p "$R43/src/data.bin"
printf 'inside dir\n' >"$R43/src/data.bin/inner.txt"
git -C "$R43" add src/data.bin/inner.txt >/dev/null 2>&1
git -C "$R43" commit -q --no-verify -m 'add directory at src/data.bin' >/dev/null 2>&1
err=$(cd "$R43" && bash "$TOOL" --rebase-base .wt 2>&1 >/dev/null)
rc=$?
if [ "$rc" -eq 1 ] && [[ $err == "STOP: rebase-proof:"* ]] \
  && grep -qF 'src/data.bin/inner.txt' <<<"$err" \
  && [ -d "$R43/.wt" ] \
  && [ -z "$(git -C "$R43" status --porcelain)" ]; then
  record_case 0 "case 43: --rebase-base file/directory boundary conflict refuses STOP: rebase-proof naming src/data.bin/inner.txt"
else
  record_case 1 "case 43: --rebase-base file/directory boundary" "rc=$rc err=$err"
fi

# Case 44: --rebase-base literal names: worktree adds src/*.js and :odd.txt,
# main advanced on README.md and sibling src/other.js -> exit 0, both files staged in main.
mk_fixture r44
R44="$T/r44"
printf 'export const other = 1;\n' >"$R44/src/other.js"
git -C "$R44" add src/other.js >/dev/null 2>&1
git -C "$R44" commit -q --no-verify -m 'add src/other.js in base' >/dev/null 2>&1
(cd "$R44" && git worktree add -q -b worktree-agent-lit .wt-lit >/dev/null 2>&1)
populate_wt "$R44/.wt-lit"
printf 'glob-named file\n' >"$R44/.wt-lit/src/*.js"
printf 'colon-named file\n' >"$R44/.wt-lit/:odd.txt"
printf 'Later docs.\n' >>"$R44/README.md"
printf 'export const other = 2;\n' >"$R44/src/other.js"
git -C "$R44" add README.md src/other.js >/dev/null 2>&1
git -C "$R44" commit -q --no-verify -m 'advance main on README and src/other.js' >/dev/null 2>&1
out=$(cd "$R44" && bash "$TOOL" --rebase-base .wt-lit 2>&1)
rc=$?
main_porcelain44=$(git -C "$R44" status --porcelain)
if [ "$rc" -eq 0 ] \
  && [ -f "$R44/src/*.js" ] \
  && [ -f "$R44/:odd.txt" ] \
  && grep -qF 'A  src/*.js' <<<"$main_porcelain44" \
  && grep -qF 'A  :odd.txt' <<<"$main_porcelain44" \
  && [ ! -e "$R44/.wt-lit" ]; then
  record_case 0 "case 44: --rebase-base with literal special-character filenames (src/*.js, :odd.txt) transfers and stages both"
else
  record_case 1 "case 44: --rebase-base literal names" "rc=$rc out=$out porcelain=$main_porcelain44"
fi

# Case 45: --rebase-base --base <wrong sha> (main's new HEAD) -> STOP: base-unchanged:
# containing 'is not --base'; --rebase-base --base <worktree HEAD> on the same fixture -> exit 0.
mk_fixture r45
R45="$T/r45"
WT_HEAD45=$(git -C "$R45/.wt" rev-parse HEAD)
printf 'Later docs.\n' >>"$R45/README.md"
git -C "$R45" add README.md >/dev/null 2>&1
git -C "$R45" commit -q --no-verify -m 'advance main on README' >/dev/null 2>&1
NEW_MAIN45=$(git -C "$R45" rev-parse HEAD)
err_wrong=$(cd "$R45" && bash "$TOOL" --rebase-base --base "$NEW_MAIN45" .wt 2>&1 >/dev/null)
rc_wrong=$?
out_right=$(cd "$R45" && bash "$TOOL" --rebase-base --base "$WT_HEAD45" .wt 2>&1)
rc_right=$?
if [ "$rc_wrong" -eq 1 ] && [[ $err_wrong == "STOP: base-unchanged:"* ]] \
  && grep -qF 'is not --base' <<<"$err_wrong" \
  && [ "$rc_right" -eq 0 ] \
  && [ -f "$R45/src/new.js" ] \
  && [ ! -e "$R45/.wt" ]; then
  record_case 0 "case 45: --rebase-base --base checks worktree HEAD (refuses main's new HEAD, accepts worktree HEAD)"
else
  record_case 1 "case 45: --rebase-base --base" "rc_wrong=$rc_wrong err_wrong=$err_wrong rc_right=$rc_right out_right=$out_right"
fi

# Case 46: Discoverability: case 22's setup without --rebase-base -> stderr
# contains 'rerun with --rebase-base'.
mk_fixture r46
R46="$T/r46"
MAIN_HEAD46=$(git -C "$R46" rev-parse HEAD)
printf 'Later docs.\n' >>"$R46/README.md"
git -C "$R46" add README.md >/dev/null 2>&1
git -C "$R46" commit -q --no-verify -m 'advance main' >/dev/null 2>&1
(cd "$R46" && git worktree add -q -b worktree-agent-old .wt-old "$MAIN_HEAD46" >/dev/null 2>&1)
populate_wt "$R46/.wt-old"
err46_nobase=$(cd "$R46" && bash "$TOOL" .wt-old 2>&1 >/dev/null)
rc46_nobase=$?
err46_base=$(cd "$R46" && bash "$TOOL" --base "$MAIN_HEAD46" .wt-old 2>&1 >/dev/null)
rc46_base=$?
if [ "$rc46_nobase" -eq 1 ] && [[ $err46_nobase == "STOP: no-unpushed-base:"* ]] \
  && grep -qF 'rerun with --rebase-base' <<<"$err46_nobase" \
  && [ "$rc46_base" -eq 1 ] && [[ $err46_base == "STOP: base-unchanged:"* ]] \
  && grep -qF 'rerun with --rebase-base' <<<"$err46_base"; then
  record_case 0 "case 46: behind-main refusals without --rebase-base suggest rerun with --rebase-base"
else
  record_case 1 "case 46: discoverability" "rc_nobase=$rc46_nobase err_nobase=$err46_nobase rc_base=$rc46_base err_base=$err46_base"
fi

# Case 47: --rebase-base literal glob conflict: main's commit changes a
# committed file literally named src/*.js that the patch also edits ->
# exit 1, STOP: rebase-proof: naming src/*.js.
mk_fixture r47
R47="$T/r47"
printf 'glob v1\n' >"$R47/src/*.js"
git -C "$R47" add -A >/dev/null 2>&1
git -C "$R47" commit -q --no-verify -m 'add literal src/*.js in base' >/dev/null 2>&1
(cd "$R47" && git worktree add -q -b worktree-agent-glob .wt-glob >/dev/null 2>&1)
populate_wt "$R47/.wt-glob"
printf 'glob wt edit\n' >"$R47/.wt-glob/src/*.js"
printf 'glob main edit\n' >"$R47/src/*.js"
git -C "$R47" add -A >/dev/null 2>&1
git -C "$R47" commit -q --no-verify -m 'advance main on literal src/*.js' >/dev/null 2>&1
err=$(cd "$R47" && bash "$TOOL" --rebase-base .wt-glob 2>&1 >/dev/null)
rc=$?
if [ "$rc" -eq 1 ] && [[ $err == "STOP: rebase-proof:"* ]] \
  && grep -qF 'src/*.js' <<<"$err" \
  && [ -d "$R47/.wt-glob" ] \
  && [ -z "$(git -C "$R47" status --porcelain)" ]; then
  record_case 0 "case 47: --rebase-base refuses STOP: rebase-proof naming literal src/*.js when both main and patch edit it"
else
  record_case 1 "case 47: --rebase-base literal glob conflict" "rc=$rc err=$err"
fi

# Case 48: --rebase-base reverse file/directory boundary: the patch adds
# src/newdir/x.txt; main commits a FILE src/newdir -> exit 1,
# STOP: rebase-proof: naming src/newdir.
mk_fixture r48
R48="$T/r48"
mkdir -p "$R48/.wt/src/newdir"
printf 'inside newdir\n' >"$R48/.wt/src/newdir/x.txt"
printf 'file at src/newdir\n' >"$R48/src/newdir"
git -C "$R48" add src/newdir >/dev/null 2>&1
git -C "$R48" commit -q --no-verify -m 'add file at src/newdir' >/dev/null 2>&1
err=$(cd "$R48" && bash "$TOOL" --rebase-base .wt 2>&1 >/dev/null)
rc=$?
if [ "$rc" -eq 1 ] && [[ $err == "STOP: rebase-proof:"* ]] \
  && grep -qF 'src/newdir' <<<"$err" \
  && [ -d "$R48/.wt" ] \
  && [ -z "$(git -C "$R48" status --porcelain)" ]; then
  record_case 0 "case 48: --rebase-base reverse file/directory boundary refuses STOP: rebase-proof naming src/newdir"
else
  record_case 1 "case 48: --rebase-base reverse file/directory boundary" "rc=$rc err=$err"
fi

# Case 49: --rebase-base scale: main's commit adds 5000 files under bulk/,
# patch is populate_wt's -> exit 0 and the proof line is printed.
mk_fixture r49
R49="$T/r49"
mkdir -p "$R49/bulk"
for i in $(seq 1 5000); do
  printf '%s\n' "$i" >"$R49/bulk/f-$i.txt"
done
git -C "$R49" add bulk >/dev/null 2>&1
git -C "$R49" commit -q --no-verify -m 'add 5000 bulk files' >/dev/null 2>&1
out=$(cd "$R49" && bash "$TOOL" --rebase-base .wt 2>&1)
rc=$?
if [ "$rc" -eq 0 ] \
  && grep -q '^rebase-proof: .*identical at worktree HEAD ' <<<"$out" \
  && [ -f "$R49/src/new.js" ] \
  && [ ! -e "$R49/.wt" ]; then
  record_case 0 "case 49: --rebase-base scale (5000 files under bulk/) transfers and prints rebase-proof line"
else
  record_case 1 "case 49: --rebase-base scale" "rc=$rc out=$out"
fi

# Case 50: --rebase-base when worktree has a commit ahead of main (no upstream on main,
# then with upstream origin/main lacking the worktree commit) ->
# exit 1, STOP: rebase-proof: naming ancestor relation, land-on-main hint, and README.md.
mk_fixture r50
R50="$T/r50"
if ! printf 'worker committed README line\n' >>"$R50/.wt/README.md" \
  || ! git -C "$R50/.wt" add README.md >/dev/null 2>&1 \
  || ! git -C "$R50/.wt" commit -q --no-verify -m 'worker commit on README' >/dev/null 2>&1 \
  || git -C "$R50" rev-parse --verify -q '@{upstream}^{commit}' >/dev/null 2>&1; then
  record_case 1 "case 50: worker commit ahead of main" "setup: failed to commit README.md in .wt with no main upstream"
else
  err=$(cd "$R50" && bash "$TOOL" --rebase-base .wt 2>&1 >/dev/null)
  rc=$?
  if ! git -C "$R50" branch -q --set-upstream-to=origin/main main >/dev/null 2>&1; then
    record_case 1 "case 50: worker commit ahead of main" "setup: failed to set upstream on main"
  else
    err2=$(cd "$R50" && bash "$TOOL" --rebase-base .wt 2>&1 >/dev/null)
    rc2=$?
    if [ "$rc" -eq 1 ] && [[ $err == "STOP: rebase-proof:"* ]] \
      && grep -qF 'is an ancestor of worktree HEAD' <<<"$err" \
      && grep -qF 'land them on main first' <<<"$err" \
      && grep -qF 'README.md' <<<"$err" \
      && [ "$rc2" -eq 1 ] && [[ $err2 == "STOP: rebase-proof:"* ]] \
      && grep -qF 'land them on main first' <<<"$err2" \
      && ! grep -qF 'git pull --ff-only' <<<"$err2" \
      && [ -d "$R50/.wt" ] \
      && git -C "$R50" rev-parse --verify -q refs/heads/worktree-agent-t1 >/dev/null \
      && [ -z "$(git -C "$R50" status --porcelain)" ]; then
      record_case 0 "case 50: --rebase-base with worker commit ahead of main refuses STOP: rebase-proof with land-on-main hint and README.md"
    else
      record_case 1 "case 50: worker commit ahead of main" "rc=$rc err=$err rc2=$rc2 err2=$err2"
    fi
  fi
fi

# Case 51: unpulled main (origin/main one commit ahead of local main, upstream set):
# (a) --rebase-base -> STOP: rebase-proof: with 'run git pull --ff-only in the main tree'
# (b) without flags -> STOP: no-unpushed-base: with 'git pull --ff-only' and no 'rerun with --rebase-base'
# (c) --base <origin/main sha> without --rebase-base -> STOP: base-unchanged: with 'git pull --ff-only' and no 'rerun with --rebase-base'
mk_fixture r51
R51="$T/r51"
R51_CLONE="$T/r51-clone"
if ! git clone -q "$T/r51-origin.git" "$R51_CLONE" >/dev/null 2>&1 \
  || ! git -C "$R51_CLONE" config user.email probe@example.invalid \
  || ! git -C "$R51_CLONE" config user.name 'Probe Harness' \
  || ! git -C "$R51_CLONE" config commit.gpgsign false \
  || ! printf 'Upstream advance.\n' >>"$R51_CLONE/README.md" \
  || ! git -C "$R51_CLONE" add README.md >/dev/null 2>&1 \
  || ! git -C "$R51_CLONE" commit -q --no-verify -m 'advance origin/main' >/dev/null 2>&1 \
  || ! git -C "$R51_CLONE" push -q origin main >/dev/null 2>&1 \
  || ! git -C "$R51" fetch -q origin >/dev/null 2>&1 \
  || ! git -C "$R51" branch -q --set-upstream-to=origin/main main >/dev/null 2>&1 \
  || ! (cd "$R51" && git worktree add -q -b worktree-agent-up .wt-up origin/main >/dev/null 2>&1) \
  || ! populate_wt "$R51/.wt-up"; then
  record_case 1 "case 51: unpulled main" "setup: failed to advance origin/main and create .wt-up"
else
  LOCAL51=$(git -C "$R51" rev-parse HEAD 2>/dev/null || true)
  ORIGIN51=$(git -C "$R51" rev-parse origin/main 2>/dev/null || true)
  if [ -z "$LOCAL51" ] || [ -z "$ORIGIN51" ] || [ "$LOCAL51" = "$ORIGIN51" ] \
    || ! git -C "$R51" merge-base --is-ancestor "$LOCAL51" "$ORIGIN51" 2>/dev/null; then
    record_case 1 "case 51: unpulled main" "setup: local main ($LOCAL51) is not a strict ancestor of origin/main ($ORIGIN51)"
  else
    err51a=$(cd "$R51" && bash "$TOOL" --rebase-base .wt-up 2>&1 >/dev/null)
    rc51a=$?
    err51b=$(cd "$R51" && bash "$TOOL" .wt-up 2>&1 >/dev/null)
    rc51b=$?
    err51c=$(cd "$R51" && bash "$TOOL" --base "$ORIGIN51" .wt-up 2>&1 >/dev/null)
    rc51c=$?
    if [ "$rc51a" -eq 1 ] && [[ $err51a == "STOP: rebase-proof:"* ]] \
      && grep -qF 'run git pull --ff-only in the main tree' <<<"$err51a" \
      && [ "$rc51b" -eq 1 ] && [[ $err51b == "STOP: no-unpushed-base:"* ]] \
      && grep -qF 'git pull --ff-only' <<<"$err51b" \
      && ! grep -qF 'rerun with --rebase-base' <<<"$err51b" \
      && [ "$rc51c" -eq 1 ] && [[ $err51c == "STOP: base-unchanged:"* ]] \
      && grep -qF 'git pull --ff-only' <<<"$err51c" \
      && ! grep -qF 'rerun with --rebase-base' <<<"$err51c" \
      && [ -d "$R51/.wt-up" ] \
      && git -C "$R51" rev-parse --verify -q refs/heads/worktree-agent-up >/dev/null \
      && [ -z "$(git -C "$R51" status --porcelain)" ]; then
      record_case 0 "case 51: unpulled main hints git pull --ff-only across --rebase-base, default, and --base"
    else
      record_case 1 "case 51: unpulled main" "rc_a=$rc51a err_a=$err51a rc_b=$rc51b err_b=$err51b rc_c=$rc51c err_c=$err51c"
    fi
  fi
fi

# Case 52: criss-cross merge bases (A1, B1) where the second merge-base exposes a
# conflict path p unchanged from the first merge-base to WT_HEAD -> STOP: rebase-proof:
# naming both p and q.
mk_fixture r52
R52="$T/r52"
if ! git -C "$R52" checkout -q -b side-a >/dev/null 2>&1 \
  || ! printf 'v1\n' >"$R52/cc-a.txt" \
  || ! git -C "$R52" add cc-a.txt >/dev/null 2>&1 \
  || ! git -C "$R52" commit -q --no-verify -m 'A1: add cc-a.txt' >/dev/null 2>&1 \
  || ! git -C "$R52" checkout -q main >/dev/null 2>&1 \
  || ! git -C "$R52" checkout -q -b side-b >/dev/null 2>&1 \
  || ! printf 'v1\n' >"$R52/cc-b.txt" \
  || ! git -C "$R52" add cc-b.txt >/dev/null 2>&1 \
  || ! git -C "$R52" commit -q --no-verify -m 'B1: add cc-b.txt' >/dev/null 2>&1 \
  || ! git -C "$R52" checkout -q side-a >/dev/null 2>&1 \
  || ! git -C "$R52" merge -q --no-edit --no-verify side-b >/dev/null 2>&1 \
  || ! git -C "$R52" checkout -q main >/dev/null 2>&1 \
  || ! git -C "$R52" merge -q --ff-only side-b >/dev/null 2>&1 \
  || ! git -C "$R52" merge -q --no-commit side-a~1 >/dev/null 2>&1 \
  || ! printf 'main-v2\n' >"$R52/cc-a.txt" \
  || ! printf 'main-v2\n' >"$R52/cc-b.txt" \
  || ! git -C "$R52" add cc-a.txt cc-b.txt >/dev/null 2>&1 \
  || ! git -C "$R52" commit -q --no-verify -m 'B2: merge A1 into B1 with main edits' >/dev/null 2>&1 \
  || ! (cd "$R52" && git worktree add -q -b worktree-agent-cc .wt-cc side-a >/dev/null 2>&1) \
  || ! printf 'export const value = 2;\n' >"$R52/.wt-cc/src/app.js"; then
  record_case 1 "case 52: criss-cross second merge-base" "setup: failed to construct criss-cross graph"
else
  WT_HEAD52=$(git -C "$R52/.wt-cc" rev-parse HEAD 2>/dev/null || true)
  MAIN_HEAD52=$(git -C "$R52" rev-parse HEAD 2>/dev/null || true)
  mapfile -t CC_MBS < <(git -C "$R52" merge-base --all "$WT_HEAD52" "$MAIN_HEAD52" 2>/dev/null)
  if [ "${#CC_MBS[@]}" -ne 2 ]; then
    record_case 1 "case 52: criss-cross second merge-base" "setup: expected 2 merge bases, got ${#CC_MBS[@]}"
  else
    MB0_DIFF=$(git -C "$R52" diff --name-only "${CC_MBS[0]}" "$WT_HEAD52" 2>/dev/null)
    MB1_DIFF=$(git -C "$R52" diff --name-only "${CC_MBS[1]}" "$WT_HEAD52" 2>/dev/null)
    if grep -qxF 'cc-a.txt' <<<"$MB1_DIFF" && ! grep -qxF 'cc-a.txt' <<<"$MB0_DIFF"; then
      cc_p="cc-a.txt"
      cc_q="cc-b.txt"
    else
      cc_p="cc-b.txt"
      cc_q="cc-a.txt"
    fi
    if grep -qxF "$cc_p" <<<"$MB0_DIFF" \
      || ! grep -qxF "$cc_p" <<<"$MB1_DIFF" \
      || ! grep -qxF "$cc_q" <<<"$MB0_DIFF" \
      || grep -qxF "$cc_q" <<<"$MB1_DIFF"; then
      record_case 1 "case 52: criss-cross second merge-base" "setup: per-base membership failed (mb0=$MB0_DIFF mb1=$MB1_DIFF p=$cc_p q=$cc_q)"
    else
      err=$(cd "$R52" && bash "$TOOL" --rebase-base .wt-cc 2>&1 >/dev/null)
      rc=$?
      if [ "$rc" -eq 1 ] && [[ $err == "STOP: rebase-proof:"* ]] \
        && grep -qF "$cc_p" <<<"$err" \
        && grep -qF "$cc_q" <<<"$err" \
        && grep -qF 'changed on main:' <<<"$err" \
        && ! grep -qF "changed only on the worktree's branch" <<<"$err" \
        && [ -d "$R52/.wt-cc" ] \
        && git -C "$R52" rev-parse --verify -q refs/heads/worktree-agent-cc >/dev/null \
        && [ -z "$(git -C "$R52" status --porcelain)" ]; then
        record_case 0 "case 52: criss-cross second merge-base exposes conflict path ($cc_p alongside $cc_q)"
      else
        record_case 1 "case 52: criss-cross second merge-base" "rc=$rc err=$err"
      fi
    fi
  fi
fi

# Case 53: --rebase-base patch delete vs main edit on src/old.js ->
# exit 1, STOP: rebase-proof: containing 'changed on main: src/old.js'.
mk_fixture r53
R53="$T/r53"
if ! printf 'export const obsolete = false;\n' >"$R53/src/old.js" \
  || ! git -C "$R53" add src/old.js >/dev/null 2>&1 \
  || ! git -C "$R53" commit -q --no-verify -m 'edit src/old.js on main' >/dev/null 2>&1; then
  record_case 1 "case 53: patch delete vs main edit" "setup: failed to commit src/old.js edit on main"
else
  err=$(cd "$R53" && bash "$TOOL" --rebase-base .wt 2>&1 >/dev/null)
  rc=$?
  if [ "$rc" -eq 1 ] && [[ $err == "STOP: rebase-proof:"* ]] \
    && grep -qF 'changed on main: src/old.js' <<<"$err" \
    && [ -d "$R53/.wt" ] \
    && git -C "$R53" rev-parse --verify -q refs/heads/worktree-agent-t1 >/dev/null \
    && [ -z "$(git -C "$R53" status --porcelain)" ]; then
    record_case 0 "case 53: --rebase-base refuses STOP: rebase-proof when patch deletes src/old.js and main edited it"
  else
    record_case 1 "case 53: patch delete vs main edit" "rc=$rc err=$err"
  fi
fi

# Case 54: --rebase-base patch rename (README.md -> docs/README.md) vs main edit on README.md ->
# exit 1, STOP: rebase-proof: containing 'changed on main: README.md'.
mk_fixture r54
R54="$T/r54"
if ! mkdir -p "$R54/.wt/docs" \
  || ! mv "$R54/.wt/README.md" "$R54/.wt/docs/README.md" \
  || ! printf 'Main edited README.\n' >>"$R54/README.md" \
  || ! git -C "$R54" add README.md >/dev/null 2>&1 \
  || ! git -C "$R54" commit -q --no-verify -m 'edit README.md on main' >/dev/null 2>&1; then
  record_case 1 "case 54: patch rename vs main edit" "setup: failed to rename README.md in .wt and edit on main"
else
  err=$(cd "$R54" && bash "$TOOL" --rebase-base .wt 2>&1 >/dev/null)
  rc=$?
  if [ "$rc" -eq 1 ] && [[ $err == "STOP: rebase-proof:"* ]] \
    && grep -qF 'changed on main: README.md' <<<"$err" \
    && [ -d "$R54/.wt" ] \
    && git -C "$R54" rev-parse --verify -q refs/heads/worktree-agent-t1 >/dev/null \
    && [ -z "$(git -C "$R54" status --porcelain)" ]; then
    record_case 0 "case 54: --rebase-base refuses STOP: rebase-proof naming old path README.md when patch renames it and main edited it"
  else
    record_case 1 "case 54: patch rename vs main edit" "rc=$rc err=$err"
  fi
fi

# Case 55: orphan worktree (git worktree add --orphan -b worktree-agent-orph .wt-orph) ->
# passes checks 1-4 and fails rev-parse HEAD at check 5 with STOP: base-unchanged:.
mk_fixture r55
R55="$T/r55"
if ! (cd "$R55" && git worktree add -q --orphan -b worktree-agent-orph .wt-orph >/dev/null 2>&1); then
  record_case 1 "case 55: orphan worktree rev-parse HEAD failure" "setup: git worktree add --orphan failed"
else
  err=$(cd "$R55" && bash "$TOOL" .wt-orph 2>&1 >/dev/null)
  rc=$?
  if [ "$rc" -eq 1 ] && [[ $err == "STOP: base-unchanged:"* ]] \
    && grep -qF 'rev-parse HEAD failed in worktree' <<<"$err" \
    && [ -d "$R55/.wt-orph" ] \
    && [ "$(git -C "$R55/.wt-orph" symbolic-ref -q HEAD 2>/dev/null)" = "refs/heads/worktree-agent-orph" ] \
    && [ -z "$(git -C "$R55" status --porcelain)" ]; then
    record_case 0 "case 55: orphan worktree refuses STOP: base-unchanged when rev-parse HEAD fails"
  else
    record_case 1 "case 55: orphan worktree rev-parse HEAD failure" "rc=$rc err=$err"
  fi
fi

# Case 56: --rebase-base when worker made only an empty commit ->
# AHEAD_PATHS is empty so ancestor check falls through and transfer succeeds.
mk_fixture r56
R56="$T/r56"
if ! git -C "$R56/.wt" commit -q --allow-empty --no-verify -m empty >/dev/null 2>&1; then
  record_case 1 "case 56: empty worker commit transfers" "setup: commit --allow-empty failed"
else
  MAIN56=$(git -C "$R56" rev-parse HEAD 2>/dev/null || true)
  WT56=$(git -C "$R56/.wt" rev-parse HEAD 2>/dev/null || true)
  if [ -z "$MAIN56" ] || [ -z "$WT56" ] || [ "$MAIN56" = "$WT56" ] \
    || ! git -C "$R56" merge-base --is-ancestor "$MAIN56" "$WT56" 2>/dev/null; then
    record_case 1 "case 56: empty worker commit transfers" "setup: main HEAD ($MAIN56) is not a strict ancestor of worktree HEAD ($WT56)"
  else
    out=$(cd "$R56" && bash "$TOOL" --rebase-base .wt 2>"$T/r56.err")
    rc=$?
    err56=$(cat "$T/r56.err" 2>/dev/null || true)
    if [ "$rc" -eq 0 ] \
      && grep -q '^rebase-proof: ' <<<"$out" \
      && [ -f "$R56/src/new.js" ] \
      && [ ! -e "$R56/.wt" ] \
      && ! git -C "$R56" rev-parse --verify -q refs/heads/worktree-agent-t1 >/dev/null; then
      record_case 0 "case 56: --rebase-base with empty worker commit transfers and prints rebase-proof line"
    else
      record_case 1 "case 56: empty worker commit transfers" "rc=$rc out=$out err=$err56"
    fi
  fi
fi

# Case 57: worker commit changing README.md, main has no upstream (main is a strict
# ancestor of worktree HEAD and the commit changes a path) ->
# (a) default -> exit 1, STOP: no-unpushed-base: with 'land them on main first' and
#     '(a worker commit?)', no 'rerun with --rebase-base'
# (b) --base <worktree HEAD> -> exit 1, STOP: base-unchanged: with 'main HEAD is behind
#     the --base commit' and 'land them on main first', no 'rerun with --rebase-base'
mk_fixture r57
R57="$T/r57"
if ! printf 'worker committed README line\n' >>"$R57/.wt/README.md" \
  || ! git -C "$R57/.wt" add README.md >/dev/null 2>&1 \
  || ! git -C "$R57/.wt" commit -q --no-verify -m 'worker commit on README' >/dev/null 2>&1 \
  || git -C "$R57" rev-parse --verify -q '@{upstream}^{commit}' >/dev/null 2>&1; then
  record_case 1 "case 57: worker commit ahead of main" "setup: failed to commit README.md in .wt with no main upstream"
else
  WT57=$(git -C "$R57/.wt" rev-parse HEAD 2>/dev/null || true)
  err_a=$(cd "$R57" && bash "$TOOL" .wt 2>&1 >/dev/null)
  rc_a=$?
  err_b=$(cd "$R57" && bash "$TOOL" --base "$WT57" .wt 2>&1 >/dev/null)
  rc_b=$?
  if [ "$rc_a" -eq 1 ] && [[ $err_a == "STOP: no-unpushed-base:"* ]] \
    && grep -qF 'land them on main first' <<<"$err_a" \
    && grep -qF '(a worker commit?)' <<<"$err_a" \
    && ! grep -qF 'rerun with --rebase-base' <<<"$err_a" \
    && [ "$rc_b" -eq 1 ] && [[ $err_b == "STOP: base-unchanged:"* ]] \
    && grep -qF 'main HEAD is behind the --base commit' <<<"$err_b" \
    && grep -qF 'land them on main first' <<<"$err_b" \
    && ! grep -qF 'rerun with --rebase-base' <<<"$err_b" \
    && [ -d "$R57/.wt" ] \
    && git -C "$R57" rev-parse --verify -q refs/heads/worktree-agent-t1 >/dev/null \
    && [ -z "$(git -C "$R57" status --porcelain)" ]; then
    record_case 0 "case 57: worker commit ahead of main refuses with land-on-main hint in default and --base modes"
  else
    record_case 1 "case 57: worker commit ahead of main" "rc_a=$rc_a err_a=$err_a rc_b=$rc_b err_b=$err_b"
  fi
fi

# Case 58: worker makes one --allow-empty commit (main is a strict ancestor, no path
# changed) -> (a) default and (b) --base refuse naming 'rerun with --rebase-base' and not
# the land-on-main hint; (c) --rebase-base then transfers and src/new.js lands in main.
mk_fixture r58
R58="$T/r58"
if ! git -C "$R58/.wt" commit -q --allow-empty --no-verify -m empty >/dev/null 2>&1; then
  record_case 1 "case 58: empty worker commit" "setup: commit --allow-empty failed"
else
  MAIN58=$(git -C "$R58" rev-parse HEAD 2>/dev/null || true)
  WT58=$(git -C "$R58/.wt" rev-parse HEAD 2>/dev/null || true)
  if [ -z "$MAIN58" ] || [ -z "$WT58" ] || [ "$MAIN58" = "$WT58" ] \
    || ! git -C "$R58" merge-base --is-ancestor "$MAIN58" "$WT58" 2>/dev/null; then
    record_case 1 "case 58: empty worker commit" "setup: main HEAD ($MAIN58) is not a strict ancestor of worktree HEAD ($WT58)"
  else
    err_a=$(cd "$R58" && bash "$TOOL" .wt 2>&1 >/dev/null)
    rc_a=$?
    err_b=$(cd "$R58" && bash "$TOOL" --base "$WT58" .wt 2>&1 >/dev/null)
    rc_b=$?
    err_c=$(cd "$R58" && bash "$TOOL" --rebase-base .wt 2>&1 >/dev/null)
    rc_c=$?
    if [ "$rc_a" -eq 1 ] && [[ $err_a == "STOP: no-unpushed-base:"* ]] \
      && grep -qF 'change no paths: rerun with --rebase-base' <<<"$err_a" \
      && ! grep -qF 'land them on main first' <<<"$err_a" \
      && [ "$rc_b" -eq 1 ] && [[ $err_b == "STOP: base-unchanged:"* ]] \
      && grep -qF 'main HEAD is behind the --base commit, whose commit(s) change no paths: rerun with --rebase-base' <<<"$err_b" \
      && ! grep -qF 'land them on main first' <<<"$err_b" \
      && grep -qF '(--base must be the worktree HEAD)' <<<"$err_b" \
      && ! grep -qF '(--base must be the worktree HEAD)' <<<"$err_a" \
      && [ "$rc_c" -eq 0 ] && [ -f "$R58/src/new.js" ] \
      && [ ! -e "$R58/.wt" ] \
      && ! git -C "$R58" rev-parse --verify -q refs/heads/worktree-agent-t1 >/dev/null; then
      record_case 0 "case 58: empty worker commit names rerun with --rebase-base, and --rebase-base transfers"
    else
      record_case 1 "case 58: empty worker commit hint" "rc_a=$rc_a err_a=$err_a rc_b=$rc_b err_b=$err_b rc_c=$rc_c err_c=$err_c"
    fi
  fi
fi

[ "$fail" -eq 0 ] || exit 1
echo "PASS: worktree-transfer ($pass cases)"
