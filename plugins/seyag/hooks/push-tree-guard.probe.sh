#!/bin/bash
# Fixture check for push-tree-guard.sh — run after ANY edit to the hook or lib/push_tree.py.
# Builds a hermetic throwaway repo R with linked worktrees A and B, plus an
# unrelated repo O, feeds PreToolUse JSON payloads on stdin, and pins: a block
# (exit 2, PUSH-TREE GUARD on stderr, both paths named), a pass (exit 0, empty
# stderr), and the SYG_DISABLE=push-tree bypass through run.sh.
#
# Usage: hooks/push-tree-guard.probe.sh   (from anywhere)

set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
unset SYG_DISABLE SYG_ENABLE SYG_PROFILE

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$SCRIPT_DIR/push-tree-guard.sh"
RUN="$SCRIPT_DIR/run.sh"

TMP=$(mktemp -d) || { echo "FAIL [setup]: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"

GIT=(git -c user.name=t -c user.email=t@example.invalid)
REPO="$TMP/repo"
WT_A="$TMP/wt-a"
WT_B="$TMP/wt-b"
WT_C="$TMP/wt-c"
OTHER="$TMP/other"

mkdir -p "$REPO" "$OTHER"
git -C "$REPO" init -q -b main >/dev/null 2>&1 || { git -C "$REPO" init -q; git -C "$REPO" symbolic-ref HEAD refs/heads/main; }
"${GIT[@]}" -C "$REPO" commit -q --allow-empty -m init
"${GIT[@]}" -C "$REPO" worktree add -q -b wt-a "$WT_A" >/dev/null 2>&1
"${GIT[@]}" -C "$REPO" worktree add -q -b wt-b "$WT_B" >/dev/null 2>&1
"${GIT[@]}" -C "$REPO" worktree add -q -b wt-c "$WT_C" >/dev/null 2>&1
"${GIT[@]}" -C "$REPO" worktree add -q -b wt-x "$REPO/.claude/worktrees/x" >/dev/null 2>&1
git -C "$OTHER" init -q -b main >/dev/null 2>&1 || { git -C "$OTHER" init -q; git -C "$OTHER" symbolic-ref HEAD refs/heads/main; }
"${GIT[@]}" -C "$OTHER" commit -q --allow-empty -m init

fail=0
count=0
LAST_ERR=""

# payload <cwd> <command> <session> <agent>: empty session/agent omits the field.
payload() {
  jq -cn --arg c "$2" --arg d "$1" --arg s "$3" --arg a "$4" \
    '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}
     + (if $s == "" then {} else {session_id: $s} end)
     + (if $a == "" then {} else {agent_id: $a} end)'
}

# hook <want-rc> <label> <cwd> <command> <session> [agent] [runner]
# Runner defaults to the hook itself; "run" goes through run.sh with env passed
# as RUN_ENV (for the SYG_DISABLE case). HOOK_STATE overrides the state base.
hook() {
  local want=$1 label=$2 cwd=$3 cmd=$4 sid=$5 ag=${6:-} runner=${7:-hook} rc=0 err got
  if [ "$runner" = run ]; then
    err=$(payload "$cwd" "$cmd" "$sid" "$ag" \
      | env -u SYG_PROFILE -u SYG_ENABLE SYG_DISABLE="${RUN_DISABLE:-}" XDG_STATE_HOME="${HOOK_STATE:-$STATE}" \
        bash "$RUN" push-tree-guard 2>&1 >/dev/null) || rc=$?
  else
    err=$(payload "$cwd" "$cmd" "$sid" "$ag" \
      | XDG_STATE_HOME="${HOOK_STATE:-$STATE}" bash "$HOOK" 2>&1 >/dev/null) || rc=$?
  fi
  LAST_ERR=$err
  count=$((count + 1))
  got=$rc
  if [ "$got" = "$want" ]; then
    if [ "$want" = 2 ] && ! grep -qF 'PUSH-TREE GUARD' <<<"$err"; then
      echo "FAIL [$label]: exit 2 without PUSH-TREE GUARD on stderr: $err"
      fail=1
    elif [ "$want" = 0 ] && [ -n "$err" ]; then
      echo "FAIL [$label]: exit 0 with stderr: $err"
      fail=1
    else
      echo "ok   [$label]: exit $got"
    fi
  else
    echo "FAIL [$label]: exit $got (want $want) stderr: $err"
    fail=1
  fi
}

# expect_paths <label> <path>...: the last block names every path.
expect_paths() {
  local label=$1 p
  shift
  for p in "$@"; do
    if ! grep -qF "$p" <<<"$LAST_ERR"; then
      echo "FAIL [$label]: stderr does not name $p"
      fail=1
      return
    fi
  done
  echo "ok   [$label]: stderr names both trees"
}

# 1. commit in A, push in B blocks once; the identical re-run passes.
hook 0 "1a commit A" "$WT_A" "git commit -m x" c1
hook 2 "1b push B blocks" "$WT_B" "git push" c1
expect_paths "1b paths" "$WT_A" "$WT_B"
hook 0 "1c identical re-run passes" "$WT_B" "git push" c1

# 2. commit A, push A passes.
hook 0 "2a commit A" "$WT_A" "git commit -m x" c2
hook 0 "2b push A" "$WT_A" "git push" c2

# 3. no prior commit, push B passes.
hook 0 "3 push B with no prior commit" "$WT_B" "git push" c3

# 4. gh pr create blocks in B; --head (or --head=, -H) passes.
hook 0 "4a commit A" "$WT_A" "git commit -m x" c4
hook 2 "4a gh pr create --fill in B blocks" "$WT_B" "gh pr create --fill" c4
hook 0 "4b commit A (fresh session)" "$WT_A" "git commit -m x" c5
hook 0 "4b gh pr create --head foo in B passes" "$WT_B" "gh pr create --head foo" c5
hook 0 "4c gh pr create --head=foo in B passes" "$WT_B" "gh pr create --head=foo --fill" c5

# 5. a push naming a branch passes; a push of HEAD blocks.
hook 0 "5a commit A" "$WT_A" "git commit -m x" c6
hook 0 "5a git push origin some-branch in B passes" "$WT_B" "git push origin some-branch" c6
hook 2 "5b git push origin HEAD in B blocks" "$WT_B" "git push origin HEAD" c6

# 6. --dry-run is never judged.
hook 0 "6a commit A" "$WT_A" "git commit -m x" c7
hook 0 "6b git push --dry-run in B passes" "$WT_B" "git push --dry-run" c7

# 7. one command from the main checkout, cd-ing through A and then B.
hook 2 "7 cd A && commit && cd B && push blocks" "$REPO" \
  "cd ../wt-a && git commit -m x && cd ../wt-b && git push" c8

# 8. git -C A commit from cwd B records A; a later push in B blocks.
hook 0 "8a git -C A commit in cwd B" "$WT_B" "git -C $WT_A commit -m x" c9
hook 2 "8b push in B blocks" "$WT_B" "git push" c9

# 9. a push in an unrelated repo never blocks.
hook 0 "9a commit A" "$WT_A" "git commit -m x" c10
hook 0 "9b push in unrelated repo O passes" "$OTHER" "git push" c10

# 10. a different agent's commit does not reach the main session's push.
hook 0 "10a commit A as agent ag1" "$WT_A" "git commit -m x" c11 ag1
hook 0 "10b push B with no agent id passes" "$WT_B" "git push" c11

# 11. commit in the main checkout, push in B blocks.
hook 0 "11a commit in main checkout" "$REPO" "git commit -m x" c12
hook 2 "11b push in B blocks" "$WT_B" "git push" c12

# 12. no session id: no state, nothing blocked.
hook 0 "12a commit A, no session id" "$WT_A" "git commit -m x" ""
hook 0 "12b push B, no session id" "$WT_B" "git push" ""

# 13. one session: the first push blocks, the second passes.
hook 0 "13a git -C A commit (cwd B), commit only" "$WT_B" "git -C $WT_A commit -m x" c13
hook 2 "13b same command, first run blocks" "$WT_B" "git -C $WT_A commit -m x && git push" c13
hook 0 "13c same command, second run passes" "$WT_B" "git -C $WT_A commit -m x && git push" c13

# 14. SYG_DISABLE=push-tree through run.sh passes; with it unset the same push blocks.
hook 0 "14a commit A" "$WT_A" "git commit -m x" c14
RUN_DISABLE=push-tree hook 0 "14b SYG_DISABLE=push-tree via run.sh passes" "$WT_B" "git push" c14 "" run
hook 0 "14c commit A" "$WT_A" "git commit -m x" c15
RUN_DISABLE="" hook 2 "14d no disable via run.sh blocks" "$WT_B" "git push" c15 "" run

# fo. Fail-open: fo1 is a would-be hit whose ack cannot be written (read-only
# state dir); fo2's state path is a file, so nothing records and both calls pass silently.
hook 0 "fo1 commit A" "$WT_A" "git commit -m x" fo1
if [ -f "$STATE/seyag/push-tree-guard/fo1" ]; then
  chmod 555 "$STATE/seyag/push-tree-guard"
  hook 0 "fo1 push B with read-only state dir fails open" "$WT_B" "git push" fo1
  chmod 755 "$STATE/seyag/push-tree-guard"
else
  echo "FAIL [fo1 setup]: no state file for fo1, so the push is not a would-be hit"
  fail=1
fi
mkdir -p "$TMP/state-file-base" && : > "$TMP/state-file-base/seyag"
HOOK_STATE="$TMP/state-file-base" hook 0 "fo2 commit A, state path is a file" "$WT_A" "git commit -m x" fo2
HOOK_STATE="$TMP/state-file-base" hook 0 "fo2 push B, state path is a file passes silently (no record possible)" "$WT_B" "git push" fo2

# pf. Prefilter positive control: gh pr create still reaches the judge after the prefilter narrowed to pr create.
hook 0 "pf1 commit A" "$WT_A" "git commit -m x" pf1
hook 2 "pf1 gh pr create in B still judged" "$WT_B" "gh pr create --title t --body b" pf1

# Extra: refspec and flag shapes.
hook 0 "x1 commit A" "$WT_A" "git commit -m x" c16
hook 2 "x1b git push origin HEAD:main in B blocks" "$WT_B" "git push origin HEAD:main" c16
hook 0 "x2 commit A" "$WT_A" "git commit -m x" c17
hook 2 "x2b git push -u origin in B blocks" "$WT_B" "git push -u origin" c17
hook 0 "x3 commit A" "$WT_A" "git commit -m x" c18
hook 0 "x3b git push --tags in B passes" "$WT_B" "git push --tags" c18

# r1. One command pushing two other trees from A blocks once; the re-run passes.
hook 0 "r1a commit A" "$WT_A" "git commit -m x" r1
hook 2 "r1b git -C B push; git -C C push from cwd A blocks" "$WT_A" "git -C $WT_B push; git -C $WT_C push" r1
hook 0 "r1c identical re-run passes" "$WT_A" "git -C $WT_B push; git -C $WT_C push" r1

# r2. A denied commit in B is not recorded: the next push in C blocks naming A.
hook 0 "r2a commit A" "$WT_A" "git commit -m x" r2
hook 2 "r2b git -C B push; git -C B commit from cwd A blocks" "$WT_A" "git -C $WT_B push; git -C $WT_B commit -m x" r2
hook 2 "r2c git -C C push from cwd A blocks" "$WT_A" "git -C $WT_C push" r2
expect_paths "r2c names A as last-commit tree" "$WT_A"

# r3. A command ending its commit record in A leaves A as the record.
hook 0 "r3a commits A, B, A in one command passes" "$WT_A" "git -C $WT_A commit -m x; git -C $WT_B commit -m x; git -C $WT_A commit -m x" r3
hook 0 "r3b git push in A passes" "$WT_A" "git push" r3

# r4. An old-format state file (line 2 a bare path) reads as commit A with no acks.
mkdir -p "$STATE/seyag/push-tree-guard"
printf '%s\n%s\n' "$WT_A" "$WT_B" > "$STATE/seyag/push-tree-guard/r4"
hook 2 "r4 old-format state: git push in B blocks" "$WT_B" "git push" r4

# r5. The replay's shape: a conditional cd, a heredoc, then a new-line list that runs in two worlds.
R5_CMD=$(printf '%s\n' "cd \"$REPO\" && git worktree add -q -b wt-x .claude/worktrees/x HEAD && cd .claude/worktrees/x && cat > f <<'EOF'" "body" "EOF" "git add f && git commit -q -m m && gh pr create --draft --title t")
hook 0 "r5 replay shape with a new-line list passes" "$REPO" "$R5_CMD" r5

# Extra: a non-Bash tool, an invalid session id, and a non-commit command pass.
hook 0 "y1 Bash push with no prior commit passes" "$WT_B" "git push" c19 "" hook
bad=$(payload "$WT_A" "git commit -m x" "" "")
count=$((count + 1))
if printf '%s' "$bad" | jq '.tool_name="Read"' | XDG_STATE_HOME="$STATE" bash "$HOOK" >/dev/null 2>&1; then
  echo "ok   [y1b]: non-Bash tool exits 0"
else
  echo "FAIL [y1b]: non-Bash tool did not exit 0"
  fail=1
fi
hook 0 "y2 commit A, session '..' (invalid)" "$WT_A" "git commit -m x" ".."
hook 0 "y2b push B, session '..' (invalid)" "$WT_B" "git push" ".."
hook 0 "y3 push B in a session with no prior commit, on a non-commit command" "$WT_B" "ls" c20

echo "---"
echo "$count cases"
[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
