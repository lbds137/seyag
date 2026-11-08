#!/bin/bash
# Fixture check for live-checkout-guard.sh — run after ANY edit to the hook.
# Builds throwaway repos under a temp dir (an origin bare repo with HEAD on
# `main`, a "plugin" checkout cloned from it with CLAUDE_PLUGIN_ROOT pointing at
# a subdirectory inside it, a linked worktree of that plugin repo, a nested
# linked worktree under <plugin>/.claude/worktrees/, and a second standalone
# repo for SYG_LIVE_CHECKOUTS), then asserts exit codes and block stderr lines.
#
# Usage: hooks/live-checkout-guard.probe.sh   (from anywhere)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$SCRIPT_DIR/live-checkout-guard.sh"

TMP=$(mktemp -d) || { echo "FAIL [setup]: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# Hermetic: git must not climb out of $TMP on non-repo cases.
export GIT_CEILING_DIRECTORIES="$TMP"

ORIGIN="$TMP/origin.git"
LIVE="$TMP/plugin-checkout"
PLUGIN_SUB="$LIVE/plugins/demo"
WT="$TMP/linked-wt"
NESTED_WT="$LIVE/.claude/worktrees/unit-wt"
SECOND="$TMP/second-repo"
NOREPO="$TMP/norepo"

mkdir -p "$NOREPO"

git init -q --bare -b main "$ORIGIN" >/dev/null 2>&1 || {
  git init -q --bare "$ORIGIN" >/dev/null 2>&1
  git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1
}

git init -q -b main "$LIVE" >/dev/null 2>&1 || {
  git init -q "$LIVE" >/dev/null 2>&1
  git -C "$LIVE" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1
}
mkdir -p "$PLUGIN_SUB" "$LIVE/.claude-plugin" "$LIVE/.claude/dispatch"
printf '*.log\n.claude/dispatch/\nbuild/\n' >"$LIVE/.gitignore"
printf '{"name":"demo","plugins":[{"name":"demo","source":"./plugins/demo"}]}\n' >"$LIVE/.claude-plugin/marketplace.json"
echo "tracked" >"$LIVE/tracked.txt"
echo "plugin" >"$PLUGIN_SUB/hook.sh"
git -C "$LIVE" add .gitignore .claude-plugin/marketplace.json tracked.txt plugins/demo/hook.sh >/dev/null 2>&1
git -C "$LIVE" -c user.email=probe@example.invalid -c user.name=probe \
  commit -q -m "initial" >/dev/null 2>&1
INIT_SHA=$(git -C "$LIVE" rev-parse --short HEAD)
git -C "$LIVE" tag v1.0 >/dev/null 2>&1
git -C "$LIVE" branch other >/dev/null 2>&1
git -C "$LIVE" remote add origin "$ORIGIN" >/dev/null 2>&1
git -C "$LIVE" push -q -u origin main >/dev/null 2>&1
git -C "$LIVE" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main >/dev/null 2>&1
git -C "$LIVE" update-ref refs/remotes/origin/remote-only "$INIT_SHA" >/dev/null 2>&1

git -C "$LIVE" worktree add -q -b feat-wt "$WT" main >/dev/null 2>&1
mkdir -p "$LIVE/.claude/worktrees"
git -C "$LIVE" worktree add -q -b feat-nested "$NESTED_WT" main >/dev/null 2>&1

# Second repo for SYG_LIVE_CHECKOUTS and no-marketplace auto check (with origin/HEAD -> origin/trunk).
git init -q -b trunk "$SECOND" >/dev/null 2>&1 || {
  git init -q "$SECOND" >/dev/null 2>&1
  git -C "$SECOND" symbolic-ref HEAD refs/heads/trunk >/dev/null 2>&1
}
mkdir -p "$SECOND/plugins/sub"
echo "second" >"$SECOND/app.txt"
echo "sub" >"$SECOND/plugins/sub/hook.sh"
git -C "$SECOND" add app.txt plugins/sub/hook.sh >/dev/null 2>&1
git -C "$SECOND" -c user.email=probe@example.invalid -c user.name=probe \
  commit -q -m "init second" >/dev/null 2>&1
git -C "$SECOND" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk >/dev/null 2>&1

if [ ! -e "$WT/.git" ] || [ ! -e "$NESTED_WT/.git" ] || [ ! -d "$SECOND/.git" ]; then
  echo "FAIL [setup]: could not build fixture repos and worktrees"
  exit 1
fi
if ! git -C "$LIVE" rev-parse --verify -q refs/heads/other >/dev/null 2>&1 \
  || ! git -C "$LIVE" rev-parse --verify -q refs/tags/v1.0 >/dev/null 2>&1 \
  || ! git -C "$LIVE" rev-parse --verify -q refs/remotes/origin/remote-only >/dev/null 2>&1 \
  || ! git -C "$LIVE" symbolic-ref -q refs/remotes/origin/HEAD >/dev/null 2>&1 \
  || ! git -C "$SECOND" symbolic-ref -q refs/remotes/origin/HEAD >/dev/null 2>&1; then
  echo "FAIL [setup]: missing other branch, v1.0 tag, remote-only ref, or origin/HEAD in fixture repos"
  exit 1
fi

LIVE_REAL=$(realpath "$LIVE")
SECOND_REAL=$(realpath "$SECOND")

fail=0
count=0
LAST_ERR=""
LAST_OUT=""

# run_hook <expected-exit> <label> <payload-json> [ENV=val ...]
run_hook() {
  local expected="$1" label="$2" payload="$3" got first_line
  shift 3
  LAST_OUT=$(printf '%s' "$payload" | env \
    -u CLAUDE_PLUGIN_ROOT \
    -u SYG_LIVE_CHECKOUT_AUTO \
    -u SYG_LIVE_CHECKOUTS \
    -u SYG_ALLOW_LIVE_CHECKOUT \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_SUB" \
    "$@" \
    bash "$HOOK" 2>"$TMP/hook.err")
  got=$?
  LAST_ERR=$(cat "$TMP/hook.err")
  count=$((count + 1))

  if [ "$got" != "$expected" ]; then
    echo "FAIL [$got≠$expected]: $label (stderr: $LAST_ERR)"
    fail=1
    return
  fi
  if [ -n "$LAST_OUT" ]; then
    echo "FAIL [stdout non-empty]: $label (stdout: $LAST_OUT)"
    fail=1
    return
  fi
  if [ "$expected" = 2 ]; then
    first_line=$(printf '%s\n' "$LAST_ERR" | sed -n '1p')
    case "$first_line" in
      "LIVE-CHECKOUT GUARD — blocked: "?*)
        echo "ok   [2]: $label"
        ;;
      *)
        echo "FAIL [bad first stderr line '$first_line']: $label"
        fail=1
        ;;
    esac
  else
    echo "ok   [$got]: $label"
  fi
}

# check_bash <expected-exit> <label> <command> <cwd> [ENV=val ...]
check_bash() {
  local expected="$1" label="$2" cmd="$3" cwd="$4" payload
  shift 4
  if [ "$cwd" = "__NONE__" ]; then
    payload=$(printf '%s' "$cmd" | jq -Rs '{tool_name:"Bash",tool_input:{command:.}}')
  else
    payload=$(printf '%s' "$cmd" | jq -Rs --arg d "$cwd" '{tool_name:"Bash",tool_input:{command:.},cwd:$d}')
  fi
  run_hook "$expected" "$label" "$payload" "$@"
}

# check_file <expected-exit> <label> <tool_name> <file_path> <cwd> [ENV=val ...]
check_file() {
  local expected="$1" label="$2" tool="$3" fpath="$4" cwd="$5" payload
  shift 5
  if [ "$tool" = "NotebookEdit" ]; then
    if [ "$cwd" = "__NONE__" ]; then
      payload=$(jq -nc --arg t "$tool" --arg p "$fpath" '{tool_name:$t,tool_input:{notebook_path:$p}}')
    else
      payload=$(jq -nc --arg t "$tool" --arg p "$fpath" --arg d "$cwd" '{tool_name:$t,tool_input:{notebook_path:$p},cwd:$d}')
    fi
  elif [ "$cwd" = "__NONE__" ]; then
    payload=$(jq -nc --arg t "$tool" --arg p "$fpath" '{tool_name:$t,tool_input:{file_path:$p}}')
  else
    payload=$(jq -nc --arg t "$tool" --arg p "$fpath" --arg d "$cwd" '{tool_name:$t,tool_input:{file_path:$p},cwd:$d}')
  fi
  run_hook "$expected" "$label" "$payload" "$@"
}

# --- 1. Branch switching & checkout in live root ------------------------------
check_bash 2 "switch to a feature branch blocks" "git switch other" "$LIVE"
check_bash 2 "switch - blocks" "git switch -" "$LIVE"
check_bash 2 "switch @{-1} blocks" "git switch @{-1}" "$LIVE"
check_bash 2 "switch --track origin/x blocks" "git switch --track origin/x" "$LIVE"
count=$((count + 1))
if grep -qF "origin/x" <<<"$LAST_ERR"; then
  echo "ok   [switch-track]: git switch --track origin/x block message names origin/x"
else
  echo "FAIL [switch-track]: git switch --track origin/x block message missing origin/x: $LAST_ERR"
  fail=1
fi
check_bash 2 "switch -c new branch blocks" "git switch -c feat-x" "$LIVE"
check_bash 2 "switch -C existing branch blocks" "git switch -C main" "$LIVE"
check_bash 2 "switch --create blocks" "git switch --create feat-x" "$LIVE"
check_bash 2 "switch --detach blocks" "git switch --detach main" "$LIVE"
check_bash 2 "switch -d blocks" "git switch -d" "$LIVE"
check_bash 0 "switch main (default branch) allows" "git switch main" "$LIVE"
check_bash 0 "switch -q main allows" "git switch -q main" "$LIVE"

check_bash 2 "checkout feature branch blocks" "git checkout other" "$LIVE"
check_bash 2 "checkout - blocks" "git checkout -" "$LIVE"
check_bash 2 "checkout @{-1} blocks" "git checkout @{-1}" "$LIVE"
check_bash 2 "checkout @{-2} blocks" "git checkout @{-2}" "$LIVE"
check_bash 2 "checkout remote-only branch (DWIM) blocks" "git checkout remote-only" "$LIVE"
check_bash 0 "checkout --no-guess remote-only branch allows" "git checkout --no-guess remote-only" "$LIVE"
check_bash 0 "checkout non-existent non-remote name allows" "git checkout no-such-branch-or-file" "$LIVE"
check_bash 2 "checkout --conflict=diff3 other blocks" "git checkout --conflict=diff3 other" "$LIVE"
check_bash 2 "checkout -b new branch blocks" "git checkout -b feat-x" "$LIVE"
check_bash 2 "checkout -B branch blocks" "git checkout -B main" "$LIVE"
check_bash 2 "checkout --detach blocks" "git checkout --detach" "$LIVE"
check_bash 2 "checkout sha blocks" "git checkout $INIT_SHA" "$LIVE"
check_bash 2 "checkout tag blocks" "git checkout v1.0" "$LIVE"
check_bash 0 "checkout main (default branch) allows" "git checkout main" "$LIVE"
check_bash 0 "checkout -- <path> allows" "git checkout -- tracked.txt" "$LIVE"
check_bash 0 "checkout <file> without -- allows" "git checkout tracked.txt" "$LIVE"
check_bash 0 "checkout <subdir/file> without -- allows" "git checkout plugins/demo/hook.sh" "$LIVE"
check_bash 0 "checkout . without -- allows" "git checkout ." "$LIVE"
check_bash 0 "checkout main <file> without -- allows" "git checkout main tracked.txt" "$LIVE"
check_bash 0 "checkout HEAD <file> without -- allows" "git checkout HEAD tracked.txt" "$LIVE"
check_bash 2 "checkout other <file> without -- blocks" "git checkout other tracked.txt" "$LIVE"
check_bash 0 "checkout HEAD -- file allows" "git checkout HEAD -- tracked.txt" "$LIVE"
check_bash 0 "checkout main -- file allows" "git checkout main -- tracked.txt" "$LIVE"
check_bash 0 "restore tracked file allows" "git restore tracked.txt" "$LIVE"
check_bash 0 "restore -s main allows" "git restore -s main tracked.txt" "$LIVE"
check_bash 0 "restore -smain allows" "git restore -smain tracked.txt" "$LIVE"
check_bash 0 "restore --source=main allows" "git restore --source=main tracked.txt" "$LIVE"
check_bash 0 "restore --source HEAD allows" "git restore --source HEAD tracked.txt" "$LIVE"
check_bash 2 "restore -s other blocks" "git restore -s other tracked.txt" "$LIVE"
check_bash 2 "restore -sother blocks" "git restore -sother tracked.txt" "$LIVE"
check_bash 2 "restore --source=other blocks" "git restore --source=other tracked.txt" "$LIVE"
check_bash 2 "restore --source other blocks" "git restore --source other tracked.txt" "$LIVE"
check_bash 2 "checkout other -- file blocks" "git checkout other -- tracked.txt" "$LIVE"
check_bash 2 "checkout sha -- file blocks" "git checkout $INIT_SHA -- tracked.txt" "$LIVE"

# --- 2. Banner / message structure assertions ---------------------------------
count=$((count + 1))
LAST_LINE=$(printf '%s\n' "$LAST_ERR" | tail -n 1)
if grep -qF "$LIVE_REAL" <<<"$LAST_ERR" \
  && grep -qF "default branch: main" <<<"$LAST_ERR" \
  && grep -qF "this checkout's files are the code every session loads" <<<"$LAST_ERR" \
  && grep -qF "git worktree add -b <branch> $LIVE_REAL/.claude/worktrees/<name> main" <<<"$LAST_ERR" \
  && grep -qF "edit the same path inside that worktree" <<<"$LAST_ERR" \
  && [[ "$LAST_LINE" == *SYG_ALLOW_LIVE_CHECKOUT=1* ]]; then
  echo "ok   [banner]: block message names live root, default branch, why, worktree fix, and bypass on last line"
else
  echo "FAIL [banner]: block message missing required elements: $LAST_ERR"
  fail=1
fi

# --- 3. Stash, commit, history/tree mutations, pull, apply, bisect ------------
check_bash 2 "stash (bare) blocks" "git stash" "$LIVE"
check_bash 2 "stash push blocks" "git stash push -m wip" "$LIVE"
check_bash 2 "stash pop blocks" "git stash pop" "$LIVE"
check_bash 2 "stash drop blocks" "git stash drop" "$LIVE"
check_bash 0 "stash list allows" "git stash list" "$LIVE"
check_bash 0 "stash show allows" "git stash show" "$LIVE"

check_bash 2 "commit blocks" "git commit -m wip" "$LIVE"
check_bash 2 "merge blocks" "git merge other" "$LIVE"
check_bash 2 "rebase blocks" "git rebase other" "$LIVE"
check_bash 2 "cherry-pick blocks" "git cherry-pick $INIT_SHA" "$LIVE"
check_bash 2 "revert blocks" "git revert HEAD" "$LIVE"
check_bash 2 "am blocks" "git am patch.mbox" "$LIVE"
check_bash 2 "reset --hard blocks" "git reset --hard HEAD" "$LIVE"
check_bash 2 "reset (mixed) blocks" "git reset HEAD~1" "$LIVE"
check_bash 0 "merge --abort allows" "git merge --abort" "$LIVE"
check_bash 0 "merge --quit allows" "git merge --quit" "$LIVE"
check_bash 0 "rebase --abort allows" "git rebase --abort" "$LIVE"
check_bash 0 "rebase --quit allows" "git rebase --quit" "$LIVE"
check_bash 0 "cherry-pick --abort allows" "git cherry-pick --abort" "$LIVE"
check_bash 0 "revert --quit allows" "git revert --quit" "$LIVE"
check_bash 0 "am --abort allows" "git am --abort" "$LIVE"

check_bash 2 "rm blocks" "git rm tracked.txt" "$LIVE"
check_bash 2 "mv blocks" "git mv tracked.txt renamed.txt" "$LIVE"
check_bash 2 "read-tree -u blocks" "git read-tree -u HEAD" "$LIVE"
check_bash 2 "read-tree -m blocks" "git read-tree -m HEAD" "$LIVE"
check_bash 2 "read-tree -um blocks" "git read-tree -um HEAD" "$LIVE"
check_bash 0 "read-tree without -u/-m allows" "git read-tree HEAD" "$LIVE"

check_bash 2 "update-ref HEAD blocks" "git update-ref HEAD $INIT_SHA" "$LIVE"
check_bash 2 "update-ref refs/heads/main blocks" "git update-ref refs/heads/main $INIT_SHA" "$LIVE"
check_bash 2 "update-ref -d refs/heads/other blocks" "git update-ref -d refs/heads/other" "$LIVE"
check_bash 2 "update-ref -m reason refs/heads/main blocks" "git update-ref -m reason refs/heads/main $INIT_SHA" "$LIVE"
check_bash 2 "update-ref --stdin blocks" "git update-ref --stdin" "$LIVE"
check_bash 0 "update-ref refs/remotes/origin/main allows" "git update-ref refs/remotes/origin/main $INIT_SHA" "$LIVE"
check_bash 0 "update-ref refs/tags/v1.0 allows" "git update-ref refs/tags/v1.0 $INIT_SHA" "$LIVE"
check_bash 2 "symbolic-ref HEAD <ref> blocks" "git symbolic-ref HEAD refs/heads/other" "$LIVE"
check_bash 2 "symbolic-ref -m reason HEAD <ref> blocks" "git symbolic-ref -m reason HEAD refs/heads/other" "$LIVE"
check_bash 0 "symbolic-ref HEAD (read, one operand) allows" "git symbolic-ref HEAD" "$LIVE"
check_bash 0 "symbolic-ref --short -q HEAD (read) allows" "git symbolic-ref --short -q HEAD" "$LIVE"
check_bash 2 "symbolic-ref -d HEAD blocks" "git symbolic-ref -d HEAD" "$LIVE"
check_bash 2 "symbolic-ref --delete HEAD blocks" "git symbolic-ref --delete HEAD" "$LIVE"
check_bash 0 "symbolic-ref -d refs/remotes/origin/HEAD allows" "git symbolic-ref -d refs/remotes/origin/HEAD" "$LIVE"
check_bash 0 "pull --ff-only origin main allows" "git pull --ff-only origin main" "$LIVE"
check_bash 0 "SYG_ALLOW_LIVE_CHECKOUT=1 prefix on git allows" "SYG_ALLOW_LIVE_CHECKOUT=1 git commit -m x" "$LIVE"
check_bash 0 "symbolic-ref refs/remotes/origin/HEAD <ref> allows" \
  "git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main" "$LIVE"

check_bash 0 "pull --ff-only (no refspec) allows" "git pull --ff-only" "$LIVE"
check_bash 0 "pull --ff-only origin allows" "git pull --ff-only origin" "$LIVE"
check_bash 0 "pull --ff-only origin main allows" "git pull --ff-only origin main" "$LIVE"
check_bash 2 "pull --ff-only non-origin remote blocks" "git pull --ff-only upstream" "$LIVE"
check_bash 2 "pull --ff-only non-origin remote with default branch blocks" "git pull --ff-only upstream main" "$LIVE"
check_bash 2 "pull --ff-only origin feat blocks" "git pull --ff-only origin feat" "$LIVE"
check_bash 2 "pull --ff-only origin main feat blocks" "git pull --ff-only origin main feat" "$LIVE"
check_bash 2 "pull without --ff-only blocks" "git pull origin main" "$LIVE"
check_bash 2 "bare pull blocks" "git pull" "$LIVE"

check_bash 0 "apply --check allows" "git apply --check patch.diff" "$LIVE"
check_bash 0 "apply --stat allows" "git apply --stat patch.diff" "$LIVE"
check_bash 0 "apply --numstat allows" "git apply --numstat patch.diff" "$LIVE"
check_bash 0 "apply --summary allows" "git apply --summary patch.diff" "$LIVE"
check_bash 2 "apply --stat --apply blocks" "git apply --stat --apply patch.diff" "$LIVE"
check_bash 2 "apply --stat --index blocks" "git apply --stat --index patch.diff" "$LIVE"
check_bash 2 "apply without check/stat/numstat/summary blocks" "git apply patch.diff" "$LIVE"

check_bash 2 "bisect start blocks" "git bisect start" "$LIVE"
check_bash 0 "bisect log allows" "git bisect log" "$LIVE"

# --- 4. Allowed read-only, fetch, worktree, branch commands -------------------
check_bash 0 "fetch allows" "git fetch origin" "$LIVE"
check_bash 0 "status allows" "git status --short" "$LIVE"
check_bash 0 "log allows" "git log --oneline -5" "$LIVE"
check_bash 0 "diff allows" "git diff" "$LIVE"
check_bash 0 "worktree add allows" "git worktree add -b new-wt $LIVE/.claude/worktrees/new-wt main" "$LIVE"
check_bash 0 "worktree list allows" "git worktree list" "$LIVE"
check_bash 0 "worktree remove allows" "git worktree remove $LIVE/.claude/worktrees/new-wt" "$LIVE"
check_bash 0 "worktree prune allows" "git worktree prune" "$LIVE"
check_bash 0 "branch (creating ref) allows" "git branch new-ref main" "$LIVE"

# --- 5. Directory resolution: -C, cd, pushd, --git-dir, --work-tree, GIT_DIR -
check_bash 2 "git -C <live> commit from unrelated cwd blocks" "git -C $LIVE commit -m x" "$NOREPO"
check_bash 2 "git -C <live-subdir> commit from unrelated cwd blocks" "git -C $PLUGIN_SUB commit -m x" "$NOREPO"
check_bash 2 "cd <live> && git commit from unrelated cwd blocks" "cd $LIVE && git commit -m x" "$NOREPO"
check_bash 2 "pushd <live> && git commit from unrelated cwd blocks" "pushd $LIVE && git commit -m x" "$NOREPO"
check_bash 0 "commit inside linked worktree allows" "git commit -m x" "$WT"
check_bash 0 "switch -c inside linked worktree allows" "git switch -c another" "$WT"
check_bash 0 "git -C <linked-wt> commit from live cwd allows" "git -C $WT commit -m x" "$LIVE"
check_bash 0 "cd <linked-wt> && git commit from live cwd allows" "cd $WT && git commit -m x" "$LIVE"
check_bash 0 "commit inside nested .claude/worktrees linked worktree allows" "git commit -m x" "$NESTED_WT"
check_bash 2 "unexpanded git -C \"\$VAR\" commit with live payload cwd blocks (falls back to payload cwd)" \
  'git -C "$UNSET_VAR" commit -m x' "$LIVE"
check_bash 2 "unreadable cd target with live payload cwd blocks (falls back to payload cwd)" \
  'cd "$UNSET_VAR" && git commit -m x' "$LIVE"
check_bash 2 "git --git-dir=<live/.git> commit from unrelated cwd blocks" \
  "git --git-dir=$LIVE/.git commit -m x" "$NOREPO"
check_bash 2 "git --git-dir <live/.git> commit from unrelated cwd blocks" \
  "git --git-dir $LIVE/.git commit -m x" "$NOREPO"
check_bash 2 "git --work-tree=<live> commit from unrelated cwd blocks" \
  "git --work-tree=$LIVE commit -m x" "$NOREPO"
check_bash 2 "git --work-tree <live> commit from unrelated cwd blocks" \
  "git --work-tree $LIVE commit -m x" "$NOREPO"
check_bash 2 "git --git-dir=<live/.git> --work-tree=<live> commit from unrelated cwd blocks" \
  "git --git-dir=$LIVE/.git --work-tree=$LIVE commit -m x" "$NOREPO"
check_bash 0 "git --git-dir=<other/.git> commit from live cwd allows" \
  "git --git-dir=$SECOND/.git commit -m x" "$LIVE"
check_bash 0 "git --work-tree=<linked-wt> commit from live cwd allows" \
  "git --work-tree=$WT commit -m x" "$LIVE"
check_bash 0 "git --git-dir=<other/.git> --work-tree=<other> commit from live cwd allows" \
  "git --git-dir=$SECOND/.git --work-tree=$SECOND commit -m x" "$LIVE"
check_bash 2 "GIT_DIR=<live/.git> prefix git commit from unrelated cwd blocks" \
  "GIT_DIR=$LIVE/.git git commit -m x" "$NOREPO"
check_bash 2 "GIT_WORK_TREE=<live> prefix git commit from unrelated cwd blocks" \
  "GIT_WORK_TREE=$LIVE git commit -m x" "$NOREPO"
check_bash 0 "GIT_DIR=<other/.git> prefix git commit from live cwd allows" \
  "GIT_DIR=$SECOND/.git git commit -m x" "$LIVE"
check_bash 2 "export GIT_DIR=<live/.git> && git commit from unrelated cwd blocks" \
  "export GIT_DIR=$LIVE/.git && git commit -m x" "$NOREPO"
check_bash 2 "export GIT_WORK_TREE=<live> && git commit from unrelated cwd blocks" \
  "export GIT_WORK_TREE=$LIVE && git commit -m x" "$NOREPO"
check_bash 0 "export GIT_DIR=<other/.git> && git commit from live cwd allows" \
  "export GIT_DIR=$SECOND/.git && git commit -m x" "$LIVE"
check_bash 2 "unexpanded --git-dir=\"\$VAR\" with live payload cwd blocks" \
  'git --git-dir="$UNSET_VAR" commit -m x' "$LIVE"
check_bash 2 "unexpanded --work-tree=\"\$VAR\" with live payload cwd blocks" \
  'git --work-tree="$UNSET_VAR" commit -m x' "$LIVE"
check_bash 0 "git worktree add then git -C <new-wt> commit in same command allows" \
  "git worktree add -b n .claude/worktrees/new main && git -C .claude/worktrees/new commit -m x" "$LIVE"
check_bash 0 "git worktree add then cd <new-wt> && git commit in same command allows" \
  "git worktree add -b n .claude/worktrees/new main && cd .claude/worktrees/new && git commit -m x" "$LIVE"
check_bash 0 "git worktree add -q -b then git -C <new-wt> apply --index in same command allows" \
  "git worktree add -q -b audit-lows-b .claude/worktrees/lowsB-release $INIT_SHA && git -C .claude/worktrees/lowsB-release apply --index ../../dispatch/lowsB.patch" "$LIVE"
check_bash 0 "git worktree add --lock --reason then git --work-tree=<new-wt> commit allows" \
  "git worktree add --lock --reason wip -B n .claude/worktrees/new/sub main && git --work-tree=.claude/worktrees/new/sub/inner commit -m x" "$LIVE"
check_bash 2 "git -C <non-existent-wt> commit with no worktree add still blocks" \
  "git -C .claude/worktrees/never-made commit -m x" "$LIVE"
check_bash 2 "cd <non-existent-wt> && git commit with no worktree add still blocks" \
  "cd .claude/worktrees/never-made && git commit -m x" "$LIVE"
check_bash 2 "git worktree add ../elsewhere && git commit in live root still blocks" \
  "git worktree add ../elsewhere && git commit -m x" "$LIVE"

# --- 6. Edit / Write / MultiEdit / NotebookEdit & check-ignore 128 ------------
check_file 2 "Edit of a tracked file in live root blocks" Edit "$LIVE/tracked.txt" "$LIVE"
check_file 2 "MultiEdit of a tracked file in live root blocks" MultiEdit "$LIVE/tracked.txt" "$LIVE"
check_file 2 "NotebookEdit of a tracked file in live root blocks" NotebookEdit "$LIVE/tracked.txt" "$LIVE"
check_file 0 "NotebookEdit of a gitignored file in live root allows" NotebookEdit "$LIVE/.claude/dispatch/nb.ipynb" "$LIVE"
check_file 0 "NotebookEdit inside linked worktree allows" NotebookEdit "$WT/tracked.txt" "$WT"
check_file 2 "relative file_path resolved against payload cwd blocks" Edit "tracked.txt" "$LIVE"
check_file 2 "relative file_path from subdir resolved against payload cwd blocks" Edit "../../tracked.txt" "$PLUGIN_SUB"
check_file 2 "Write of a new non-ignored file inside live root blocks" Write "$LIVE/new-source.sh" "$LIVE"
check_file 2 "Edit of a file under .git/ blocks" Edit "$LIVE/.git/config" "$LIVE"
check_file 2 "Write of a file under .git/hooks/ blocks" Write "$LIVE/.git/hooks/pre-commit" "$LIVE"

check_file 0 "Edit of an existing gitignored file allows" Edit "$LIVE/.claude/dispatch/unit.md" "$LIVE"
check_file 0 "Write of a new path matching .gitignore (*.log) allows" Write "$LIVE/debug.log" "$LIVE"
check_file 0 "Write of a new path inside a non-existent gitignored dir (build/) allows" Write "$LIVE/build/output.txt" "$LIVE"
check_file 0 "Edit inside external linked worktree allows" Edit "$WT/tracked.txt" "$WT"
check_file 0 "Edit inside nested .claude/worktrees linked worktree allows" Edit "$NESTED_WT/tracked.txt" "$LIVE"
check_file 0 "Write of a new file inside nested .claude/worktrees linked worktree allows" Write "$NESTED_WT/new.txt" "$LIVE"

SHIM_DIR="$TMP/git-shim"
mkdir -p "$SHIM_DIR"
REAL_GIT=$(command -v git)
cat >"$SHIM_DIR/git" <<EOF
#!/bin/bash
for a in "\$@"; do
  [ "\$a" = "check-ignore" ] && exit 128
done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$SHIM_DIR/git"
check_file 0 "check-ignore exit 128 on existing path fails open (allows)" \
  Edit "$LIVE/tracked.txt" "$LIVE" PATH="$SHIM_DIR:$PATH"
check_file 0 "check-ignore exit 128 on non-existent parent dir fails open (allows)" \
  Write "$LIVE/uncreated-dir/file.txt" "$LIVE" PATH="$SHIM_DIR:$PATH"

# --- 7. Configuration & Bypass env vars ---------------------------------------
check_bash 0 "CLAUDE_PLUGIN_ROOT pointing at a non-git dir allows git commit" \
  "git commit -m x" "$LIVE" CLAUDE_PLUGIN_ROOT="$NOREPO"
check_file 0 "CLAUDE_PLUGIN_ROOT pointing at a non-git dir allows Edit" \
  Edit "$LIVE/tracked.txt" "$LIVE" CLAUDE_PLUGIN_ROOT="$NOREPO"

check_bash 0 "CLAUDE_PLUGIN_ROOT inside repo without .claude-plugin/marketplace.json is inert (Bash)" \
  "git commit -m x" "$SECOND" CLAUDE_PLUGIN_ROOT="$SECOND/plugins/sub"
check_file 0 "CLAUDE_PLUGIN_ROOT inside repo without .claude-plugin/marketplace.json is inert (Edit)" \
  Edit "$SECOND/app.txt" "$SECOND" CLAUDE_PLUGIN_ROOT="$SECOND/plugins/sub"

check_bash 0 "SYG_LIVE_CHECKOUT_AUTO=0 disables auto plugin root detection (Bash)" \
  "git commit -m x" "$LIVE" SYG_LIVE_CHECKOUT_AUTO=0
check_file 0 "SYG_LIVE_CHECKOUT_AUTO=0 disables auto plugin root detection (Edit)" \
  Edit "$LIVE/tracked.txt" "$LIVE" SYG_LIVE_CHECKOUT_AUTO=0

check_bash 2 "SYG_LIVE_CHECKOUTS naming a second repo blocks commit there" \
  "git commit -m x" "$SECOND" SYG_LIVE_CHECKOUT_AUTO=0 SYG_LIVE_CHECKOUTS="$SECOND:$NOREPO"
check_file 2 "SYG_LIVE_CHECKOUTS naming a second repo blocks Edit there" \
  Edit "$SECOND/app.txt" "$SECOND" SYG_LIVE_CHECKOUT_AUTO=0 SYG_LIVE_CHECKOUTS="$SECOND"
check_bash 0 "second repo with origin/HEAD=trunk allows switch trunk" \
  "git switch trunk" "$SECOND" SYG_LIVE_CHECKOUT_AUTO=0 SYG_LIVE_CHECKOUTS="$SECOND"
check_bash 2 "second repo with origin/HEAD=trunk blocks switch main" \
  "git switch main" "$SECOND" SYG_LIVE_CHECKOUT_AUTO=0 SYG_LIVE_CHECKOUTS="$SECOND"
count=$((count + 1))
if grep -qF "$SECOND_REAL" <<<"$LAST_ERR" && grep -qF "default branch: trunk" <<<"$LAST_ERR"; then
  echo "ok   [banner-second]: second repo block message names $SECOND_REAL and default branch trunk"
else
  echo "FAIL [banner-second]: second repo block message missing expected root/branch: $LAST_ERR"
  fail=1
fi

check_bash 0 "SYG_ALLOW_LIVE_CHECKOUT=1 as prefix word in command allows" \
  "SYG_ALLOW_LIVE_CHECKOUT=1 git commit -m x" "$LIVE"
check_bash 0 "SYG_ALLOW_LIVE_CHECKOUT=1 after env in command allows" \
  "env SYG_ALLOW_LIVE_CHECKOUT=1 git switch other" "$LIVE"
check_bash 0 "export SYG_ALLOW_LIVE_CHECKOUT=1 earlier in command allows" \
  "export SYG_ALLOW_LIVE_CHECKOUT=1 && git commit -m x" "$LIVE"
check_bash 2 "true SYG_ALLOW_LIVE_CHECKOUT=1; git commit still blocks" \
  "true SYG_ALLOW_LIVE_CHECKOUT=1; git commit -m x" "$LIVE"
check_bash 2 "SYG_ALLOW_LIVE_CHECKOUT=1 on earlier command only still blocks later git commit" \
  "SYG_ALLOW_LIVE_CHECKOUT=1 true && git commit -m x" "$LIVE"
check_bash 2 "SYG_ALLOW_LIVE_CHECKOUT=1 as git argument still blocks" \
  "git commit -m SYG_ALLOW_LIVE_CHECKOUT=1" "$LIVE"
check_bash 2 "SYG_ALLOW_LIVE_CHECKOUT=1 only inside quoted commit message still blocks" \
  'git commit -m "mention SYG_ALLOW_LIVE_CHECKOUT=1 in msg"' "$LIVE"
check_bash 0 "SYG_ALLOW_LIVE_CHECKOUT=1 in hook environment allows Bash" \
  "git commit -m x" "$LIVE" SYG_ALLOW_LIVE_CHECKOUT=1
check_file 0 "SYG_ALLOW_LIVE_CHECKOUT=1 in hook environment allows Edit" \
  Edit "$LIVE/tracked.txt" "$LIVE" SYG_ALLOW_LIVE_CHECKOUT=1

# --- 8. Fail-open edge cases --------------------------------------------------
run_hook 0 "malformed JSON fails open" "{not valid json"
run_hook 0 "empty JSON fails open" "{}"
run_hook 0 "non-guarded tool (Read) fails open" \
  "$(jq -nc --arg p "$LIVE/tracked.txt" '{tool_name:"Read",tool_input:{file_path:$p}}')"

echo "---"
echo "$count cases"
[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
