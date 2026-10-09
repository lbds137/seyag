#!/bin/bash
# Fixture check for bin/safe-worktree-clean against throwaway repos (a bare origin, a clone, and
# agent worktrees under its .claude/worktrees). Every HOLD reason fires alone: each tree breaks
# exactly one criterion. The tool always runs with --repo into the fixture, never the real repo.
# Usage: tests/safe-worktree-clean.probe.sh   (from anywhere)

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/plugins/seyag/bin/safe-worktree-clean"
HOOKS="$ROOT/plugins/seyag/hooks"
T=$(mktemp -d)
PIDS=()
cleanup() { [ ${#PIDS[@]} -eq 0 ] || kill "${PIDS[@]}" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

# Hermetic: no ambient SYG_* knob, no user or system git config.
while read -r v; do unset "$v"; done < <(compgen -v SYG_)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
cd "$T" || exit 1

# A repo with origin/main = c2; c1 is its parent. c1: a.txt=v1. c2: a.txt=v2, b.txt=b.
mk_repo() { # $1 name
  local r="$T/$1"
  git init -q --bare -b main "$T/$1-origin.git"
  git clone -q "$T/$1-origin.git" "$r" 2>/dev/null
  printf '*.log\n__pycache__/\n' > "$r/.gitignore"
  echo v1 > "$r/a.txt"
  git -C "$r" add . && git -C "$r" commit -qm first
  echo v2 > "$r/a.txt"; echo b > "$r/b.txt"
  git -C "$r" add . && git -C "$r" commit -qm second
  git -C "$r" push -q origin main 2>/dev/null
  git -C "$r" remote set-head origin main
  echo .claude/ >> "$r/.git/info/exclude"
  C1=$(git -C "$r" rev-parse HEAD~1)
}
add_tree() { # $1 repo, $2 tree name, $3 start point (default origin/main), $4 branch (default worktree-agent-<name>)
  git -C "$T/$1" worktree add -q -b "${4:-worktree-agent-$2}" "$T/$1/.claude/worktrees/$2" "${3:-origin/main}" 2>/dev/null
}
dead_pid() { sleep 0 & local p=$!; wait "$p"; echo "$p"; }
verdict() { # $1 json, $2 tree name -> "SAFE" or "HOLD:code,code"
  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
for t in d["worktrees"]:
    if t["path"].endswith("/" + sys.argv[2]):
        print(t["verdict"] if t["verdict"] == "SAFE" else
              "HOLD:" + ",".join(r["code"] for r in t["reasons"]))
' "$1" "$2"
}
expect() { # $1 json, $2 tree, $3 want, $4 label
  local got; got=$(verdict "$1" "$2")
  if [ "$got" = "$3" ]; then ok "$2: $3 ($4)"; else bad "$2: got '$got', want '$3' ($4)"; fi
}

# --- One repo, one tree per case; the dry run judges them all in one pass. ---
mk_repo judge
R="$T/judge"
add_tree judge safe
add_tree judge dirtysame "$C1"; echo v2 > "$R/.claude/worktrees/dirtysame/a.txt"
add_tree judge untrackedsame "$C1"; echo b > "$R/.claude/worktrees/untrackedsame/b.txt"
add_tree judge ignoredcache; mkdir -p "$R/.claude/worktrees/ignoredcache/pkg/__pycache__"
echo x > "$R/.claude/worktrees/ignoredcache/pkg/__pycache__/m.pyc"
add_tree judge subjmatch "$C1"; echo v2-pre > "$R/.claude/worktrees/subjmatch/a.txt"
git -C "$R/.claude/worktrees/subjmatch" commit -qam second       # a pre-rebase copy of c2
add_tree judge lockdead; git -C "$R" worktree lock --reason "claude agent agent-x (pid $(dead_pid))" "$R/.claude/worktrees/lockdead"
add_tree judge detachedok; git -C "$R/.claude/worktrees/detachedok" checkout -q --detach
git -C "$R" branch -q -D worktree-agent-detachedok
# HOLD cases, one criterion each.
sleep 300 & LIVE=$!; PIDS+=("$LIVE")
add_tree judge locklive; git -C "$R" worktree lock --reason "claude agent agent-y (pid $LIVE)" "$R/.claude/worktrees/locklive"
add_tree judge locknopid; git -C "$R" worktree lock "$R/.claude/worktrees/locknopid"
add_tree judge livecwd; (cd "$R/.claude/worktrees/livecwd" && exec sleep 300) & PIDS+=("$!")
add_tree judge unmerged; echo new > "$R/.claude/worktrees/unmerged/c.txt"
git -C "$R/.claude/worktrees/unmerged" add c.txt && git -C "$R/.claude/worktrees/unmerged" commit -qm "unique work"
add_tree judge dirty; echo mine > "$R/.claude/worktrees/dirty/a.txt"
add_tree judge stagedonly; echo staged > "$R/.claude/worktrees/stagedonly/a.txt"
git -C "$R/.claude/worktrees/stagedonly" add a.txt; echo v2 > "$R/.claude/worktrees/stagedonly/a.txt"
add_tree judge untrackednew; echo n > "$R/.claude/worktrees/untrackednew/notes.md"
add_tree judge untrackeddiff "$C1"; echo other > "$R/.claude/worktrees/untrackeddiff/b.txt"
add_tree judge ignored; echo log > "$R/.claude/worktrees/ignored/run.log"
add_tree judge oddbranch origin/main feature-x
add_tree judge detachedunref; git -C "$R/.claude/worktrees/detachedunref" checkout -q --detach
git -C "$R" branch -q -D worktree-agent-detachedunref
echo z > "$R/.claude/worktrees/detachedunref/z.txt"
git -C "$R/.claude/worktrees/detachedunref" add z.txt && git -C "$R/.claude/worktrees/detachedunref" commit -qm z
sleep 0.3   # let the live-cwd subshell finish its cd before the /proc walk

# Positive control: git's porcelain reports the lock the fixture set.
grep -qx locked <<<"$(git -C "$R" worktree list --porcelain | sed -n '/locknopid$/,/^$/p')" \
  && ok "porcelain shows 'locked' for a reasonless lock (positive control)" || bad "porcelain lock positive control"

J=$("$TOOL" --repo "$R" --json); rc=$?
[ $rc = 0 ] && ok "dry run exits 0 with holds present" || bad "dry run exit $rc"
expect "$J" safe SAFE "clean tree at base"
expect "$J" dirtysame SAFE "dirty file equal to base (criterion 4 positive)"
expect "$J" untrackedsame SAFE "untracked file equal to base's blob"
expect "$J" ignoredcache SAFE "ignored __pycache__ is a safe-clean cache name"
expect "$J" subjmatch SAFE "cherry + whose subject is on base"
expect "$J" lockdead SAFE "lock pid dead"
expect "$J" detachedok SAFE "detached HEAD reachable from base"
expect "$J" locklive HOLD:locked-live "criterion 1"
expect "$J" locknopid HOLD:lock-unparsable "criterion 1, fails closed"
expect "$J" livecwd HOLD:live-cwd "criterion 2"
expect "$J" unmerged HOLD:unmerged "criterion 3"
expect "$J" dirty HOLD:dirty "criterion 4, worktree content"
expect "$J" stagedonly HOLD:dirty "criterion 4, index content"
expect "$J" untrackednew HOLD:untracked-new "criterion 4, new untracked file"
expect "$J" untrackeddiff HOLD:untracked-differs "criterion 4, untracked differs from base"
expect "$J" ignored HOLD:ignored "criterion 5"
expect "$J" oddbranch HOLD:branch-name "criterion 6"
expect "$J" detachedunref HOLD:detached-unreferenced "criterion 7"
J=$(SYG_WORKTREE_BRANCH_RE='^feature-' "$TOOL" --repo "$R" --json)
expect "$J" oddbranch SAFE "SYG_WORKTREE_BRANCH_RE override"
expect "$J" safe HOLD:branch-name "the override replaces the default pattern"
expect "$(SYG_WORKTREE_BRANCH_RE='([' "$TOOL" --repo "$R" --json 2>/dev/null)" safe HOLD:branch-name "an invalid regex fails closed"

out=$("$TOOL" --repo "$R"); rc=$?
grep -q '^SAFE  .claude/worktrees/safe  \[worktree-agent-safe\]$' <<<"$out" \
  && grep -q '^HOLD report: 11 tree(s) left in place$' <<<"$out" \
  && grep -q '^    HOLD:untracked-new  notes.md is untracked and not on origin/main$' <<<"$out" \
  && [ -d "$R/.claude/worktrees/safe" ] && ok "text dry run: SAFE lines, one batched HOLD report, nothing removed" \
  || { bad "text dry run"; printf '%s\n' "$out"; }

# --- No base ref: every tree is HOLD:no-base. ---
NB="$T/nobase"; git init -q -b main "$NB"; echo x > "$NB/x"; git -C "$NB" add x; git -C "$NB" commit -qm x
git -C "$NB" worktree add -q -b worktree-agent-n "$NB/.claude/worktrees/n" 2>/dev/null
expect "$("$TOOL" --repo "$NB" --json)" n HOLD:no-base "no origin: fails closed"

# --- --apply: SAFE trees go, HOLD trees stay. ---
mk_repo apply
A="$T/apply"
add_tree apply gone
add_tree apply gonelocked; git -C "$A" worktree lock --reason "claude agent agent-z (pid $(dead_pid))" "$A/.claude/worktrees/gonelocked"
add_tree apply keep; echo n > "$A/.claude/worktrees/keep/new.txt"
out=$("$TOOL" --repo "$A" --apply); rc=$?
common=$(git -C "$A" rev-parse --path-format=absolute --git-common-dir)
if [ $rc = 0 ] && [ ! -e "$A/.claude/worktrees/gone" ] && [ ! -e "$A/.claude/worktrees/gonelocked" ] \
  && ! git -C "$A" rev-parse -q --verify refs/heads/worktree-agent-gone >/dev/null \
  && ! git -C "$A" rev-parse -q --verify refs/heads/worktree-agent-gonelocked >/dev/null \
  && [ ! -e "$common/worktrees/gone" ] && [ ! -e "$common/worktrees/gonelocked" ] \
  && ! git -C "$A" worktree list --porcelain | grep -q prunable \
  && [ -f "$A/.claude/worktrees/keep/new.txt" ] && git -C "$A" rev-parse -q --verify refs/heads/worktree-agent-keep >/dev/null \
  && grep -q 'removed, branch worktree-agent-gone deleted' <<<"$out"; then
  ok "--apply removes SAFE trees (locked one unlocked), deletes branches, prunes; the HOLD tree stays"
else
  bad "--apply (rc $rc)"; printf '%s\n' "$out"
fi
out=$("$TOOL" --repo "$A" --apply); rc=$?
[ $rc = 1 ] && [ -f "$A/.claude/worktrees/keep/new.txt" ] && grep -q '^HOLD report: 1 tree(s)' <<<"$out" \
  && grep -q '^nothing removed: no SAFE tree$' <<<"$out" \
  && ok "--apply with zero SAFE trees removes nothing, exits 1, prints the HOLD report" || { bad "--apply zero SAFE (rc $rc)"; printf '%s\n' "$out"; }

# --- --locks / --locks-apply ---
mk_repo locks
L="$T/locks"; add_tree locks w1; add_tree locks w2
lc=$(git -C "$L" rev-parse --path-format=absolute --git-common-dir)
: > "$lc/index.lock"; touch -d '20 minutes ago' "$lc/index.lock"                        # stale
: > "$lc/worktrees/w1/index.lock"                                                       # fresh
echo busy > "$lc/worktrees/w2/index.lock"; touch -d '20 minutes ago' "$lc/worktrees/w2/index.lock"  # non-empty
out=$("$TOOL" --repo "$L" --locks); rc=$?
[ $rc = 0 ] && grep -q "STALE  $lc/index.lock" <<<"$out" && grep -q "HOLD:fresh  $lc/worktrees/w1/index.lock" <<<"$out" \
  && grep -q "HOLD:nonempty  $lc/worktrees/w2/index.lock" <<<"$out" && [ -e "$lc/index.lock" ] \
  && ok "--locks lists stale, fresh and non-empty locks, deletes nothing" || { bad "--locks (rc $rc)"; printf '%s\n' "$out"; }
out=$("$TOOL" --repo "$L" --locks-apply); rc=$?
[ $rc = 0 ] && [ ! -e "$lc/index.lock" ] && [ -e "$lc/worktrees/w1/index.lock" ] && [ -e "$lc/worktrees/w2/index.lock" ] \
  && grep -q "STALE  $lc/index.lock .*deleted" <<<"$out" \
  && ok "--locks-apply deletes only the stale lock" || { bad "--locks-apply (rc $rc)"; printf '%s\n' "$out"; }
: > "$lc/worktrees/w1/index.lock"; touch -d '20 minutes ago' "$lc/worktrees/w1/index.lock"
out=$(SYG_WORKTREE_LOCK_AGE_MIN=30 "$TOOL" --repo "$L" --locks)
grep -q "HOLD:fresh  $lc/worktrees/w1/index.lock" <<<"$out" && ok "SYG_WORKTREE_LOCK_AGE_MIN raises the age floor" || bad "lock age override"
out=$(SYG_WORKTREE_LOCK_AGE_MIN=soon "$TOOL" --repo "$L" --locks)
grep -q "STALE  $lc/worktrees/w1/index.lock" <<<"$out" && ok "a non-numeric SYG_WORKTREE_LOCK_AGE_MIN falls back to 10" || bad "lock age fallback"
(cd "$L" && exec -a git sleep 300) & PIDS+=("$!"); sleep 0.3
out=$("$TOOL" --repo "$L" --locks-apply); rc=$?
[ -e "$lc/worktrees/w1/index.lock" ] && grep -q "HOLD:git-live  $lc/worktrees/w1/index.lock" <<<"$out" \
  && ok "a live git process in the repo holds an otherwise stale lock" || { bad "live git lock (rc $rc)"; printf '%s\n' "$out"; }

# --- The rm guards pass the tool's own invocation untouched (exit 0, no output). ---
for cmd in 'safe-worktree-clean --repo /srv/team/myrepo --apply' \
  'safe-worktree-clean --repo ~/src/node_modules-demo --apply' \
  'safe-worktree-clean --repo /srv/myrepo --locks-apply --apply' \
  'cd /srv/myrepo && safe-worktree-clean --apply --repo .'; do
  for hook in recursive-rm-guard cache-rm-redirect; do
    out=$(jq -nc --arg c "$cmd" '{tool_input: {command: $c}}' | CLAUDE_JOB_DIR="" bash "$HOOKS/$hook.sh" 2>&1); rc=$?
    [ $rc = 0 ] && [ -z "$out" ] && ok "$hook passes: $cmd" || bad "$hook (rc $rc, output '$out'): $cmd"
  done
done

# --- Usage and JSON shape. ---
"$TOOL" --help | grep -q 'safe-worktree-clean \[--apply\] \[--repo DIR\]' && ok "--help prints usage" || bad "--help"
"$TOOL" --bogus >/dev/null 2>&1; [ $? = 2 ] && ok "unknown argument exits 2" || bad "unknown argument"
"$TOOL" --repo "$T" >/dev/null 2>&1; [ $? = 2 ] && ok "a non-repo --repo exits 2" || bad "non-repo"
python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["base"]=="origin/main" and "locks" in d' \
  < <("$TOOL" --repo "$L" --json --locks) && ok "--json carries base and locks" || bad "--json shape"
exit $fail
