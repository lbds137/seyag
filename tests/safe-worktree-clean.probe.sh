#!/bin/bash
# Fixture check for bin/safe-worktree-clean against throwaway repos (a bare origin, a clone, and
# agent worktrees under its .claude/worktrees). Every HOLD reason fires alone: each tree breaks
# exactly one criterion. Also covers multi-repo sweeps (--repo repeatable, --repos-file) and
# --apply-hold plan verification, backup layout, and removal (P1-P14). The tool always runs with
# --repo into the fixture, never the real repo.
# Usage: tests/safe-worktree-clean.probe.sh   (from anywhere)

set -uo pipefail
# Hooks run here directly, not via run.sh: keep bytecode out of hooks/lib.
export PYTHONDONTWRITEBYTECODE=1
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
export SYG_WORKTREE_BACKUP_ALLOW_VOLATILE=1
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
add_tree judge squashed "$C1"; echo v2 > "$R/.claude/worktrees/squashed/a.txt"
git -C "$R/.claude/worktrees/squashed" commit -qam "wip one"
echo b > "$R/.claude/worktrees/squashed/b.txt"
git -C "$R/.claude/worktrees/squashed" add b.txt && git -C "$R/.claude/worktrees/squashed" commit -qm "wip two"
add_tree judge netempty; echo n > "$R/.claude/worktrees/netempty/n.txt"
git -C "$R/.claude/worktrees/netempty" add n.txt && git -C "$R/.claude/worktrees/netempty" commit -qm "add n"
git -C "$R/.claude/worktrees/netempty" rm -q n.txt && git -C "$R/.claude/worktrees/netempty" commit -qm "drop n"
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
add_tree judge subjdiff "$C1"; echo v2-pre > "$R/.claude/worktrees/subjdiff/a.txt"
git -C "$R/.claude/worktrees/subjdiff" commit -qam second        # subject on base, content differs
add_tree judge generic; echo p > "$R/.claude/worktrees/generic/p.txt"
git -C "$R/.claude/worktrees/generic" add p.txt && git -C "$R/.claude/worktrees/generic" commit -qm eco
git -C "$R" config merge.ours.driver true
echo 'a.txt merge=ours' > "$R/.gitattributes"
add_tree judge drvours "$C1"; echo v2-drv > "$R/.claude/worktrees/drvours/a.txt"
git -C "$R/.claude/worktrees/drvours" commit -qam drv
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
expect "$J" squashed SAFE "cherry + but base contains the branch's changes (squash merge)"
expect "$J" netempty SAFE "cherry + but net branch change is empty (added then removed)"
expect "$J" lockdead SAFE "lock pid dead"
expect "$J" detachedok SAFE "detached HEAD reachable from base"
expect "$J" locklive HOLD:locked-live "criterion 1"
expect "$J" locknopid HOLD:lock-unparsable "criterion 1, fails closed"
expect "$J" livecwd HOLD:live-cwd "criterion 2"
expect "$J" unmerged HOLD:unmerged "criterion 3"
expect "$J" subjdiff HOLD:unmerged "subject on base but content differs"
expect "$J" generic HOLD:unmerged "generic subject that is a substring of a base message"
expect "$J" drvours HOLD:unmerged "criterion 3, working-tree .gitattributes merge=ours driver ignored"
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
  && grep -q '^HOLD report: 14 tree(s) left in place$' <<<"$out" \
  && grep -q '^    HOLD:untracked-new  notes.md is untracked and not on origin/main$' <<<"$out" \
  && [ -d "$R/.claude/worktrees/safe" ] && ok "text dry run: SAFE lines, one batched HOLD report, nothing removed" \
  || { bad "text dry run"; printf '%s\n' "$out"; }

# --- Criterion 3: an info/attributes merge=ours driver cannot make a conflicting branch SAFE. ---
mk_repo infoattr
IA="$T/infoattr"
git -C "$IA" config merge.ours.driver true
echo 'a.txt merge=ours' > "$IA/$(git -C "$IA" rev-parse --git-path info/attributes)"
add_tree infoattr infoattr "$C1"; echo v2-drv > "$IA/.claude/worktrees/infoattr/a.txt"
git -C "$IA/.claude/worktrees/infoattr" commit -qam drv
expect "$("$TOOL" --repo "$IA" --json)" infoattr HOLD:unmerged "criterion 3, info/attributes merge=ours holds"

# --- Criterion 3: merge.default + merge.ours.driver in repo config (no attributes) holds unmerged. ---
mk_repo mergedefault
MD="$T/mergedefault"
git -C "$MD" config merge.ours.driver true
git -C "$MD" config merge.default ours
add_tree mergedefault mergedefault "$C1"; echo v2-drv > "$MD/.claude/worktrees/mergedefault/a.txt"
git -C "$MD/.claude/worktrees/mergedefault" commit -qam drv
expect "$("$TOOL" --repo "$MD" --json)" mergedefault HOLD:unmerged "criterion 3, merge.default ours driver holds"

# --- No base ref: every tree is HOLD:no-base. ---
NB="$T/nobase"; git init -q -b main "$NB"; echo x > "$NB/x"; git -C "$NB" add x; git -C "$NB" commit -qm x
git -C "$NB" worktree add -q -b worktree-agent-n "$NB/.claude/worktrees/n" 2>/dev/null
expect "$("$TOOL" --repo "$NB" --json)" n HOLD:no-base "no origin: fails closed"

# --- Configurable base ref (--base REF / SYG_WORKTREE_BASE) ---
reason_msg() { # $1 json, $2 tree name -> first reason detail
  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
for t in d["worktrees"]:
    if t["path"].endswith("/" + sys.argv[2]):
        print(t["reasons"][0]["detail"] if t["reasons"] else "")
' "$1" "$2"
}

mk_repo flow
F="$T/flow"
git -C "$F" switch -q -c develop
echo 'gen/' >> "$F/.gitignore"
echo d > "$F/d.txt"
git -C "$F" add .gitignore d.txt && git -C "$F" commit -qm "feature d"
FEAT_D=$(git -C "$F" rev-parse HEAD)
mkdir -p "$F/.claude"
echo 'gen/' > "$F/.claude/worktree-regenerable"   # gitignore's directory form: the / is dropped
git -C "$F" add -f .claude/worktree-regenerable && git -C "$F" commit -qm "regenerable"
git -C "$F" push -q origin develop 2>/dev/null
git -C "$F" switch -q main && git -C "$F" branch -q -D develop

add_tree flow merged
git -C "$F/.claude/worktrees/merged" cherry-pick "$FEAT_D" >/dev/null

add_tree flow dirtydev
echo d > "$F/.claude/worktrees/dirtydev/d.txt"

add_tree flow regen origin/develop~1   # at "feature d", so detdev's tip (develop) is on no local branch
mkdir -p "$F/.claude/worktrees/regen/gen"; echo x > "$F/.claude/worktrees/regen/gen/x"

git -C "$F" worktree add -q --detach "$F/.claude/worktrees/detdev" origin/develop 2>/dev/null

# 1. default (no knob)
J=$("$TOOL" --repo "$F" --json)
expect "$J" merged HOLD:unmerged "flow default: merged unmerged against origin/main"
expect "$J" dirtydev HOLD:untracked-new "flow default: dirtydev untracked-new against origin/main"
expect "$J" regen HOLD:unmerged,ignored "flow default: develop commits not on main, regenerable file only on develop"
expect "$J" detdev HOLD:detached-unreferenced "flow default: detdev detached-unreferenced against origin/main"

# 2. SYG_WORKTREE_BASE=origin/develop: all four SAFE
J=$(SYG_WORKTREE_BASE=origin/develop "$TOOL" --repo "$F" --json)
expect "$J" merged SAFE "flow SYG_WORKTREE_BASE: merged SAFE"
expect "$J" dirtydev SAFE "flow SYG_WORKTREE_BASE: dirtydev SAFE"
expect "$J" regen SAFE "flow SYG_WORKTREE_BASE: regen SAFE"
expect "$J" detdev SAFE "flow SYG_WORKTREE_BASE: detdev SAFE"

# 3. --base origin/develop: all four SAFE
J=$("$TOOL" --repo "$F" --base origin/develop --json)
expect "$J" merged SAFE "flow --base: merged SAFE"
expect "$J" dirtydev SAFE "flow --base: dirtydev SAFE"
expect "$J" regen SAFE "flow --base: regen SAFE"
expect "$J" detdev SAFE "flow --base: detdev SAFE"

# 4. --base=origin/develop with SYG_WORKTREE_BASE=origin/nope: merged SAFE (flag wins)
J=$(SYG_WORKTREE_BASE=origin/nope "$TOOL" --repo "$F" --base=origin/develop --json)
expect "$J" merged SAFE "flow --base= wins over SYG_WORKTREE_BASE"

# 5. SYG_WORKTREE_BASE= (empty): merged HOLD:unmerged (empty = unset)
J=$(SYG_WORKTREE_BASE='' "$TOOL" --repo "$F" --json)
expect "$J" merged HOLD:unmerged "flow SYG_WORKTREE_BASE empty counts as unset"

# 6. SYG_WORKTREE_BASE=origin/nope: merged HOLD:no-base with specific reason message
J=$(SYG_WORKTREE_BASE=origin/nope "$TOOL" --repo "$F" --json)
expect "$J" merged HOLD:no-base "SYG_WORKTREE_BASE unresolvable ref fails closed"
want="base ref origin/nope (from SYG_WORKTREE_BASE) does not resolve to a commit"
got=$(reason_msg "$J" merged)
[ "$got" = "$want" ] && ok "reason message: $want" || bad "reason message: got '$got', want '$want'"

# 7. --base origin/nope: HOLD:no-base with specific reason message
J=$("$TOOL" --repo "$F" --base origin/nope --json)
expect "$J" merged HOLD:no-base "--base unresolvable ref fails closed"
want="base ref origin/nope (from --base) does not resolve to a commit"
got=$(reason_msg "$J" merged)
[ "$got" = "$want" ] && ok "reason message: $want" || bad "reason message: got '$got', want '$want'"

# A ref git would read as an option is a usage error, whichever source gave it.
"$TOOL" --repo "$F" --base --apply >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "--base --apply exits 2 (the flag is not swallowed as the ref)" || bad "--base --apply exit $rc"
SYG_WORKTREE_BASE=-x "$TOOL" --repo "$F" --json >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "SYG_WORKTREE_BASE=-x exits 2" || bad "SYG_WORKTREE_BASE=-x exit $rc"

# 8. --base as the last argument: exit 2
"$TOOL" --repo "$F" --base >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "--base as the last argument exits 2" || bad "--base as last argument exit $rc"

# Empty --base / --base= is a usage error
err=$("$TOOL" --repo "$F" --base= 2>&1 >/dev/null); rc=$?
[ "$rc" = 2 ] && grep -q 'safe-worktree-clean: --base needs a ref' <<<"$err" \
  && ok "--base= exits 2 with '--base needs a ref'" || bad "--base= (rc $rc, err '$err')"
err=$("$TOOL" --repo "$F" --base '' 2>&1 >/dev/null); rc=$?
[ "$rc" = 2 ] && grep -q 'safe-worktree-clean: --base needs a ref' <<<"$err" \
  && ok "--base '' exits 2 with '--base needs a ref'" || bad "--base '' (rc $rc, err '$err')"

# 9. Text mode with --base origin/develop: first line contains base: origin/develop
out=$("$TOOL" --repo "$F" --base origin/develop)
first_line=$(head -n 1 <<<"$out")
grep -q 'base: origin/develop' <<<"$first_line" \
  && ok "text mode with --base: first line contains base: origin/develop" \
  || bad "text mode base line: got '$first_line'"

# --- --apply: SAFE trees go, HOLD trees stay. ---
mk_repo apply
A="$T/apply"
add_tree apply gone
add_tree apply gonelocked; git -C "$A" worktree lock --reason "claude agent agent-z (pid $(dead_pid))" "$A/.claude/worktrees/gonelocked"
add_tree apply keep; echo n > "$A/.claude/worktrees/keep/new.txt"
out=$("$TOOL" --repo "$A" --apply); rc=$?
common=$(git -C "$A" rev-parse --path-format=absolute --git-common-dir)
_pipe_out=$(git -C "$A" worktree list --porcelain 2>/dev/null) || bad "--apply setup: git worktree list failed"
if [ $rc = 0 ] && [ ! -e "$A/.claude/worktrees/gone" ] && [ ! -e "$A/.claude/worktrees/gonelocked" ] \
  && ! git -C "$A" rev-parse -q --verify refs/heads/worktree-agent-gone >/dev/null \
  && ! git -C "$A" rev-parse -q --verify refs/heads/worktree-agent-gonelocked >/dev/null \
  && [ ! -e "$common/worktrees/gone" ] && [ ! -e "$common/worktrees/gonelocked" ] \
  && ! grep -q prunable <<<"$_pipe_out" \
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

# --- Check 4 subsumption: the base already holds the tree's change plus later edits. ---
# Trees start at c3 (f.txt = lines 1-9, bin.dat binary); the base then moves to c4: line 2 -> X,
# line 9 -> driver, new u.txt, v.txt (no final newline) and w.bin (binary), bin.dat changed the
# same way as f.txt.
mk_repo sub
S="$T/sub"
seq 1 9 > "$S/f.txt"; printf '\0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n' > "$S/bin.dat"
git -C "$S" add . && git -C "$S" commit -qm third && git -C "$S" push -q origin main 2>/dev/null
for n in subset extrahunk conflict stagedsubset stagedextra untrackedsubset untrackedinterleaved \
  untrackedempty untrackedextra untrackedreorder untrackednlok untrackednl untrackedbinary \
  deletion binary modechmod modestaged modetype hiddenassume hiddenskip hiddenboth untrackedexec modecontrol; do add_tree sub "$n"; done
sed -i 's/^2$/X/; s/^9$/driver/' "$S/f.txt"; sed -i 's/^2$/X/; s/^9$/driver/' "$S/bin.dat"
printf 'u1\nu2\nu3\n' > "$S/u.txt"; printf 'v1\nv2' > "$S/v.txt"; printf '\0\nw1\nw2\n' > "$S/w.bin"
git -C "$S" add . && git -C "$S" commit -qm fourth && git -C "$S" push -q origin main 2>/dev/null
W="$S/.claude/worktrees"
sed -i 's/^2$/X/' "$W/subset/f.txt"                                 # base has X, plus line 9
sed -i 's/^2$/X/; s/^5$/W/' "$W/extrahunk/f.txt"                    # line 5 -> W: base lacks it
sed -i 's/^2$/Y/' "$W/conflict/f.txt"                               # base has X on the same line
sed -i 's/^2$/X/' "$W/stagedsubset/f.txt"; git -C "$W/stagedsubset" add f.txt
git -C "$W/stagedsubset" show HEAD:f.txt > "$W/stagedsubset/f.txt" # index only; worktree = HEAD
sed -i 's/^5$/W/' "$W/stagedextra/f.txt"; git -C "$W/stagedextra" add f.txt
git -C "$W/stagedextra" show HEAD:f.txt > "$W/stagedextra/f.txt"
printf 'u1\nu2\n' > "$W/untrackedsubset/u.txt"                      # base = this + u3
printf 'u1\nu3\n' > "$W/untrackedinterleaved/u.txt"                 # base adds u2 between
: > "$W/untrackedempty/u.txt"
printf 'u1\nzz\n' > "$W/untrackedextra/u.txt"
printf 'u2\nu1\n' > "$W/untrackedreorder/u.txt"                     # base has them as u1, u2
printf 'v1\n' > "$W/untrackednlok/v.txt"                            # base = this + v2 (no newline)
printf 'v1\nv2\n' > "$W/untrackednl/v.txt"                          # base's v2 lacks the newline
printf '\0\nw1\n' > "$W/untrackedbinary/w.bin"                      # base = this + w2, binary
rm -f "$W/deletion/f.txt"                                           # base still has f.txt
sed -i 's/^2$/X/' "$W/binary/bin.dat"                               # the subset change, binary
chmod +x "$W/modechmod/f.txt"                                       # mode only; base edited f.txt
git -C "$W/modestaged" update-index --chmod=+x f.txt                # staged mode only
git -C "$W/modetype" update-index --cacheinfo "120000,$(git -C "$W/modetype" rev-parse HEAD:f.txt),f.txt"
sed -i 's/^5$/W/' "$W/hiddenassume/f.txt"; git -C "$W/hiddenassume" update-index --assume-unchanged f.txt
sed -i 's/^5$/W/' "$W/hiddenskip/f.txt"; git -C "$W/hiddenskip" update-index --skip-worktree f.txt
sed -i 's/^5$/W/' "$W/hiddenboth/f.txt"; git -C "$W/hiddenboth" update-index --assume-unchanged f.txt; git -C "$W/hiddenboth" update-index --skip-worktree f.txt
cp "$S/u.txt" "$W/untrackedexec/u.txt"; chmod +x "$W/untrackedexec/u.txt"   # base's bytes, base 100644
# Trees at the base itself (c4): a mode change with the blob still equal to base's.
for n in modeonly modeonlystaged; do add_tree sub "$n"; done
chmod +x "$W/modeonly/a.txt"
git -C "$W/modeonlystaged" update-index --chmod=+x a.txt
cp "$S/f.txt" "$W/modecontrol/f.txt"; git -C "$W/modecontrol" add f.txt   # base's bytes and mode
J=$("$TOOL" --repo "$S" --json)
expect "$J" subset SAFE "4: base subsumes the worker's edit plus a later driver edit"
expect "$J" extrahunk HOLD:dirty "4: a worker hunk the base lacks"
expect "$J" conflict HOLD:dirty "4: worker and base edit the same line differently"
expect "$J" stagedsubset SAFE "4: staged-only subset of the base"
expect "$J" stagedextra HOLD:dirty "4: staged-only hunk the base lacks"
# Untracked: base must keep every tree line, in order (additions only).
expect "$J" untrackedsubset SAFE "4: untracked prefix of base's file"
expect "$J" untrackedinterleaved SAFE "4: untracked file, base adds a line between its lines"
expect "$J" untrackedempty SAFE "4: an empty untracked file is subsumed by base's file"
expect "$J" untrackedextra HOLD:untracked-differs "4: untracked file with a line base lacks"
expect "$J" untrackedreorder HOLD:untracked-differs "4: untracked file, base has the same lines reordered"
expect "$J" untrackednlok SAFE "4: untracked prefix of a base file without a final newline"
expect "$J" untrackednl HOLD:untracked-differs "4: base's last shared line lacks the tree's trailing newline"
expect "$J" untrackedbinary HOLD:untracked-differs "4: untracked binary prefix of base's file"
expect "$J" deletion HOLD:dirty "4: a deletion the base doesn't have"
expect "$J" binary HOLD:dirty "4: the subset change in a binary file"
expect "$J" modechmod HOLD:dirty "4: a worktree mode change the base lacks (content subsumed)"
expect "$J" modestaged HOLD:dirty "4: a staged mode change the base lacks (content subsumed)"
expect "$J" modetype HOLD:dirty "4: a staged file-to-symlink type change, blob unchanged"
expect "$J" hiddenassume HOLD:hidden "4: an edit hidden by assume-unchanged"
expect "$J" hiddenskip HOLD:hidden "4: an edit hidden by skip-worktree"
expect "$J" hiddenboth HOLD:hidden "4: an edit hidden by skip-worktree and assume-unchanged"
want="f.txt is marked skip-worktree and assume-unchanged; its edits are not visible"
got=$(reason_msg "$J" hiddenboth)
[ "$got" = "$want" ] && ok "reason message: $want" || bad "reason message: got '$got', want '$want'"
expect "$J" untrackedexec HOLD:untracked-differs "4: untracked file with base's bytes but the executable bit base lacks"
expect "$J" modeonly HOLD:dirty "4: chmod +x at base, blob equal to base's"
expect "$J" modeonlystaged HOLD:dirty "4: staged chmod +x at base, blob equal to base's"
expect "$J" modecontrol SAFE "4: dirty and staged file equal to base's blob and mode"

# --- Check 5: repo-declared regenerable ignored paths. ---
mk_repo regen
G="$T/regen"
printf 'dist/\nother/\n.husky/_/\nfiles/\n.env\nsecrets.txt\n' >> "$G/.gitignore"
git -C "$G" add . && git -C "$G" commit -qm ignores && git -C "$G" push -q origin main 2>/dev/null
GW="$G/.claude/worktrees"
add_tree regen nofile; mkdir -p "$GW/nofile/dist"; echo x > "$GW/nofile/dist/a.js"
expect "$("$TOOL" --repo "$G" --json)" nofile HOLD:ignored "5: no .claude/worktree-regenerable on base: dist/ holds"
mkdir -p "$G/.claude"
printf '# build output\ndist\nbad =\n\n.husky/_\n = also-bad\n.env = .env.example\nsecrets.txt = secrets.example\n' \
  > "$G/.claude/worktree-regenerable"
printf 'API_KEY=\n' > "$G/.env.example"
git -C "$G" add -f .claude/worktree-regenerable .env.example && git -C "$G" commit -qm regenerable \
  && git -C "$G" push -q origin main 2>/dev/null
echo other >> "$G/.claude/worktree-regenerable"                     # main's working copy widened: ignored
add_tree regen plain
add_tree regen regenok; mkdir -p "$GW/regenok/dist" "$GW/regenok/.husky/_"
echo x > "$GW/regenok/dist/a.js"; echo h > "$GW/regenok/.husky/_/h"
add_tree regen regenother; mkdir -p "$GW/regenother/other"; echo x > "$GW/regenother/other/a"
add_tree regen widened; echo other >> "$GW/widened/.claude/worktree-regenerable"
mkdir -p "$GW/widened/other"; echo x > "$GW/widened/other/a"
add_tree regen envfiles; mkdir -p "$GW/envfiles/files"; echo x > "$GW/envfiles/files/a"
add_tree regen envok; cp "$G/.env.example" "$GW/envok/.env"
add_tree regen envdiff; echo 'API_KEY=SECRET-MARKER-7f3a' > "$GW/envdiff/.env"
add_tree regen tmplmissing; echo s > "$GW/tmplmissing/secrets.txt"
J=$("$TOOL" --repo "$G" --json 2>"$T/regen.err")
expect "$J" nofile SAFE "5: the nofile twin once base lists dist"
expect "$J" regenok SAFE "5: base lists dist and .husky/_ (after a malformed line)"
expect "$J" regenother HOLD:ignored "5: other/ is not listed on base (main's working copy is not read)"
expect "$J" widened HOLD:dirty,ignored "5: the tree's own widened list is not honoured"
expect "$J" envfiles HOLD:ignored "5: files/ without the env"
expect "$J" envok SAFE "5: .env byte-equal to base's .env.example"
expect "$J" envdiff HOLD:ignored "5: .env differs from its template"
expect "$J" tmplmissing HOLD:ignored "5: the declared template is absent on base"
[ "$(grep -c 'line 3 of .claude/worktree-regenerable on origin/main is malformed' "$T/regen.err")" = 1 ] \
  && [ "$(grep -c 'line 6 of .claude/worktree-regenerable on origin/main is malformed' "$T/regen.err")" = 1 ] \
  && [ "$(grep -c . "$T/regen.err")" = 2 ] \
  && ok "5: each malformed line warns once on stderr" || { bad "5: malformed-line warnings"; cat "$T/regen.err"; }
expect "$(SYG_WORKTREE_REGENERABLE='files' "$TOOL" --repo "$G" --json 2>/dev/null)" envfiles SAFE "5: SYG_WORKTREE_REGENERABLE='files'"
expect "$(SYG_WORKTREE_REGENERABLE=$'other\n  files' "$TOOL" --repo "$G" --json 2>/dev/null)" envfiles SAFE \
  "5: SYG_WORKTREE_REGENERABLE entries after a newline are honoured"
out=$("$TOOL" --repo "$G" 2>/dev/null; "$TOOL" --repo "$G" --json 2>/dev/null)
grep -q '^    HOLD:ignored  ignored .env differs from its declared template .env.example$' <<<"$out" \
  && grep -q '^    HOLD:ignored  ignored secrets.txt differs from its declared template secrets.example$' <<<"$out" \
  && ! grep -q 'SECRET-MARKER' <<<"$out" \
  && ok "5: the template reason names paths only, never the file's content" || { bad "5: template reason"; printf '%s\n' "$out"; }
python3 -c '
import json, sys
d = {t["path"].rsplit("/", 1)[-1]: t for t in json.loads(sys.argv[1])["worktrees"]}
a, b = d["regenok"], d["plain"]
assert a["verdict"] == b["verdict"] == "SAFE" and sorted(a) == sorted(b)
assert a["reasons"] == b["reasons"] == [] and a["action"] is b["action"] is None
' "$J" && ok "5: --json for a regenerable-SAFE tree has the shape of a plain SAFE tree" || bad "5: --json shape"

# A glob that matches every path would wave .env secrets through: refused with a warning.
mk_repo broad
B="$T/broad"
printf '.env\n' >> "$B/.gitignore"; mkdir -p "$B/.claude"; printf '*\n.*\n**\n' > "$B/.claude/worktree-regenerable"
git -C "$B" add . && git -C "$B" add -f .claude/worktree-regenerable && git -C "$B" commit -qm broad \
  && git -C "$B" push -q origin main 2>/dev/null
add_tree broad secret; echo 'API_KEY=SECRET-MARKER-7f3a' > "$B/.claude/worktrees/secret/.env"
J=$("$TOOL" --repo "$B" --json 2>"$T/broad.err")
expect "$J" secret HOLD:ignored "5: base lists *, .* and **: an ignored .env still holds"
for g in '\*' '\.\*' '\*\*'; do
  grep -q "^safe-worktree-clean: warning: line [0-9] of .claude/worktree-regenerable on origin/main: '$g' matches every path; ignored$" "$T/broad.err" \
    || bad "5: no matches-every-path warning for $g"
done
[ "$(grep -c . "$T/broad.err")" = 3 ] && ok "5: each match-all glob warns once on stderr" || { bad "5: match-all warnings"; cat "$T/broad.err"; }
J=$(SYG_WORKTREE_REGENERABLE='**' "$TOOL" --repo "$B" --json 2>"$T/broad.err")
expect "$J" secret HOLD:ignored "5: SYG_WORKTREE_REGENERABLE='**' is refused too"
grep -q "^safe-worktree-clean: warning: SYG_WORKTREE_REGENERABLE: '\*\*' matches every path; ignored$" "$T/broad.err" \
  && ok "5: the env's match-all glob warns" || { bad "5: env match-all warning"; cat "$T/broad.err"; }
J=$(SYG_WORKTREE_REGENERABLE='*/' "$TOOL" --repo "$B" --json 2>"$T/broad.err")
expect "$J" secret HOLD:ignored "5: '*/' is still match-all once its trailing / is dropped"
grep -q "^safe-worktree-clean: warning: SYG_WORKTREE_REGENERABLE: '\*/' matches every path; ignored$" "$T/broad.err" \
  && ok "5: '*/' warns" || { bad "5: '*/' warning"; cat "$T/broad.err"; }

# --- --all: judge every linked worktree wherever it lives. ---
mk_repo allrepo
AR="$T/allrepo"
add_tree allrepo inside
mkdir -p "$T/elsewhere"
git -C "$AR" worktree add -q -b worktree-agent-x "$T/elsewhere/agent-x" origin/main 2>/dev/null
git -C "$AR" worktree add -q -b feature-y "$T/elsewhere/feature-y" origin/main 2>/dev/null
git -C "$AR" worktree add -q --detach "$T/elsewhere/det" origin/main
J=$("$TOOL" --repo "$AR" --json)
expect "$J" inside SAFE "without --all: inside agent tree judged SAFE"
expect "$J" agent-x "" "without --all: outside agent tree absent from JSON"
expect "$J" feature-y "" "without --all: outside non-agent tree absent from JSON"
expect "$J" det "" "without --all: outside detached tree absent from JSON"
J=$("$TOOL" --repo "$AR" --all --json)
expect "$J" inside SAFE "--all: inside agent tree SAFE"
expect "$J" agent-x SAFE "--all: outside agent tree SAFE"
expect "$J" feature-y HOLD:branch-name "--all: outside non-agent tree HOLD:branch-name"
expect "$J" det HOLD:detached-outside "--all: outside detached tree HOLD:detached-outside"
expect "$J" allrepo "" "--all: main checkout is never listed"
out=$("$TOOL" --repo "$AR" --all)
if grep -q 'worktrees judged: 4' <<<"$out" \
  && grep -q '^SAFE  \.claude/worktrees/inside  \[worktree-agent-inside\]$' <<<"$out" \
  && grep -q "^SAFE  $T/elsewhere/agent-x  \[worktree-agent-x\]$" <<<"$out" \
  && grep -q "^  $T/elsewhere/feature-y  \[feature-y\]$" <<<"$out" \
  && grep -q "^  $T/elsewhere/det  \[detached\]$" <<<"$out"; then
  ok "--all text: summary counts 4, inside relative, outside absolute"
else
  bad "--all text"; printf '%s\n' "$out"
fi
out=$("$TOOL" --repo "$AR" --all --apply); rc=$?
if [ $rc = 0 ] && [ ! -e "$AR/.claude/worktrees/inside" ] && [ ! -e "$T/elsewhere/agent-x" ] \
  && ! git -C "$AR" rev-parse -q --verify refs/heads/worktree-agent-inside >/dev/null \
  && ! git -C "$AR" rev-parse -q --verify refs/heads/worktree-agent-x >/dev/null \
  && [ -d "$T/elsewhere/feature-y" ] && git -C "$AR" rev-parse -q --verify refs/heads/feature-y >/dev/null \
  && [ -d "$T/elsewhere/det" ]; then
  ok "--all --apply removes outside SAFE agent tree and its branch; feature-y and det stay"
else
  bad "--all --apply (rc $rc)"; printf '%s\n' "$out"
fi

# --- Lock word boundary, cache leaf-only match, in-progress operations, and submodules. ---
mk_repo batch1
B1="$T/batch1"
B1W="$B1/.claude/worktrees"
add_tree batch1 lockrapid
git -C "$B1" worktree lock --reason "rapid 99999" "$B1W/lockrapid"
add_tree batch1 cachenotes
mkdir -p "$B1W/cachenotes/node_modules/mine"
echo x > "$B1W/cachenotes/node_modules/mine/notes.log"
add_tree batch1 cachehand
mkdir -p "$B1W/cachehand/data/node_modules"
echo x > "$B1W/cachehand/data/node_modules/hand-written.log"
git -C "$B1" checkout -q -b side "$C1"
echo side > "$B1/a.txt"
git -C "$B1" commit -qam "side change"
C_SIDE=$(git -C "$B1" rev-parse HEAD)
git -C "$B1" checkout -q main
git -C "$B1" branch -q -D side
add_tree batch1 midrebase
git -C "$B1W/midrebase" rebase --exec false HEAD~1 >/dev/null 2>&1
add_tree batch1 midmerge
git -C "$B1W/midmerge" merge "$C_SIDE" >/dev/null 2>&1
git -C "$B1W/midmerge" checkout HEAD -- a.txt
add_tree batch1 midcherry
git -C "$B1W/midcherry" cherry-pick "$C_SIDE" >/dev/null 2>&1
git -C "$B1W/midcherry" checkout HEAD -- a.txt
add_tree batch1 midseq
seq_dir=$(git -C "$B1W/midseq" rev-parse --git-path sequencer)
mkdir -p "$seq_dir"
echo "pick $C1" > "$seq_dir/todo"
add_tree batch1 pytestcache
mkdir -p "$B1W/pytestcache/.pytest_cache/v"
printf '*\n' > "$B1W/pytestcache/.pytest_cache/.gitignore"
printf 'pytest cache dir\n' > "$B1W/pytestcache/.pytest_cache/README.md"
printf '{}\n' > "$B1W/pytestcache/.pytest_cache/v/cache"
_pipe_out=$(git -C "$B1W/pytestcache" status --porcelain=v1 --ignored=matching --untracked-files=all) \
  && grep -qx '!! \.pytest_cache/README\.md' <<<"$_pipe_out" \
  && ok "pytestcache: git status --ignored=matching lists .pytest_cache/README.md individually" \
  || bad "pytestcache: .pytest_cache/README.md not listed individually"
add_tree batch1 cleanlinked
git -C "$B1" rebase --exec false HEAD~1 >/dev/null 2>&1
J=$("$TOOL" --repo "$B1" --json)
git -C "$B1" rebase --abort >/dev/null 2>&1
expect "$J" lockrapid HOLD:lock-unparsable "lock reason 'rapid 99999' does not parse as a dead pid"
expect "$J" cachenotes HOLD:ignored "node_modules/mine/notes.log holds (leaf is not cache name)"
expect "$J" cachehand HOLD:ignored "data/node_modules/hand-written.log holds (leaf is not cache name)"
expect "$J" midrebase HOLD:in-progress "mid-rebase worktree holds"
expect "$J" midmerge HOLD:in-progress "mid-merge worktree holds"
expect "$J" midcherry HOLD:in-progress "mid-cherry-pick worktree holds"
expect "$J" midseq HOLD:in-progress "sequencer with no CHERRY_PICK_HEAD holds"
expect "$J" pytestcache SAFE ".pytest_cache self-ignored stays SAFE"
expect "$J" cleanlinked SAFE "main-tree rebase does not hold a linked tree"

mk_repo submod
SM="$T/submod"
SMW="$SM/.claude/worktrees"
git init -q --bare -b main "$T/nested-origin.git"
git clone -q "$T/nested-origin.git" "$T/nested-seed" 2>/dev/null
echo "nested-initial-content" > "$T/nested-seed/n.txt"
git -C "$T/nested-seed" add n.txt && git -C "$T/nested-seed" commit -qm "nested init"
git -C "$T/nested-seed" push -q origin main 2>/dev/null
git init -q --bare -b main "$T/sub-origin.git"
git clone -q "$T/sub-origin.git" "$T/sub-seed" 2>/dev/null
echo "sub-initial-content" > "$T/sub-seed/s.txt"
git -C "$T/sub-seed" add s.txt && git -C "$T/sub-seed" commit -qm "sub init"
git -C "$T/sub-seed" -c protocol.file.allow=always submodule add -q "$T/nested-origin.git" nested 2>/dev/null
git -C "$T/sub-seed" commit -qm "add nested submodule"
git -C "$T/sub-seed" push -q origin main 2>/dev/null
git -C "$SM" -c protocol.file.allow=always submodule add -q "$T/sub-origin.git" sub 2>/dev/null
git -C "$SM" commit -qm "add submodule"
git -C "$SM" push -q origin main 2>/dev/null
add_tree submod subclean
git -C "$SMW/subclean" -c protocol.file.allow=always submodule update --init -q 2>/dev/null
add_tree submod subuntracked
git -C "$SMW/subuntracked" -c protocol.file.allow=always submodule update --init -q 2>/dev/null
echo "untracked-in-sub" > "$SMW/subuntracked/sub/untracked.txt"
add_tree submod subbranch
git -C "$SMW/subbranch" -c protocol.file.allow=always submodule update --init -q 2>/dev/null
sub_rec=$(git -C "$SMW/subbranch/sub" rev-parse HEAD)
git -C "$SMW/subbranch/sub" switch -q -c sub-wip
echo "sub-branch-only-content" > "$SMW/subbranch/sub/s.txt"
git -C "$SMW/subbranch/sub" commit -qam "sub branch commit"
git -C "$SMW/subbranch/sub" checkout -q --detach "$sub_rec"
add_tree submod substash
git -C "$SMW/substash" -c protocol.file.allow=always submodule update --init -q 2>/dev/null
echo "sub-stash-content" > "$SMW/substash/sub/s.txt"
git -C "$SMW/substash/sub" stash push -q -m "sub stash"
add_tree submod subcustomref
git -C "$SMW/subcustomref" -c protocol.file.allow=always submodule update --init -q 2>/dev/null
custom_tree=$(git -C "$SMW/subcustomref/sub" rev-parse "HEAD^{tree}")
custom_sha=$(echo "custom ref commit" | git -C "$SMW/subcustomref/sub" commit-tree "$custom_tree" -p HEAD)
git -C "$SMW/subcustomref/sub" update-ref refs/custom/saved "$custom_sha"
add_tree submod subreflog
git -C "$SMW/subreflog" -c protocol.file.allow=always submodule update --init -q 2>/dev/null
sub_rec_rl=$(git -C "$SMW/subreflog/sub" rev-parse HEAD)
git -C "$SMW/subreflog/sub" checkout -q --detach "$sub_rec_rl"
echo "sub-reflog-only-content" > "$SMW/subreflog/sub/s.txt"
git -C "$SMW/subreflog/sub" commit -qam "sub reflog commit"
git -C "$SMW/subreflog/sub" checkout -q --detach "$sub_rec_rl"
add_tree submod subnogit
echo "populated-without-git" > "$SMW/subnogit/sub/local.txt"
add_tree submod subnested
git -C "$SMW/subnested" -c protocol.file.allow=always submodule update --init --recursive -q 2>/dev/null
echo "nested-stash-content" > "$SMW/subnested/sub/nested/n.txt"
git -C "$SMW/subnested/sub/nested" stash push -q -m "nested stash"
J=$("$TOOL" --repo "$SM" --json)
expect "$J" subclean SAFE "clean initialised submodule at recorded commit with remote stays SAFE"
expect "$J" subuntracked HOLD:submodule "untracked file in initialised submodule holds"
expect "$J" subbranch HOLD:submodule "submodule branch commit with gitlink unchanged holds"
expect "$J" substash HOLD:submodule "stash in submodule holds"
expect "$J" subcustomref HOLD:submodule "custom ref commit in submodule holds"
expect "$J" subreflog HOLD:submodule "reflog-only commit in submodule holds"
expect "$J" subnogit HOLD:submodule "populated gitlink directory with no .git holds"
expect "$J" subnested HOLD:submodule "nested submodule stash holds"
GCFG="$T/global-untracked-no.gitconfig"
git config --file "$GCFG" status.showUntrackedFiles no
J_GCFG=$(GIT_CONFIG_GLOBAL="$GCFG" "$TOOL" --repo "$SM" --json)
expect "$J_GCFG" subuntracked HOLD:submodule "status.showUntrackedFiles=no in global config with untracked file in submodule still holds"
out=$("$TOOL" --repo "$SM" --apply); rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$SMW/subclean" ] && [ -d "$SMW/subbranch/sub" ] \
  && git -C "$SMW/subbranch/sub" rev-parse --verify -q refs/heads/sub-wip >/dev/null; then
  ok "subbranch: --apply keeps tree with submodule branch commit while removing clean sibling"
else
  bad "subbranch --apply (rc $rc)"; printf '%s\n' "$out"
fi

# --- Check 9 (gitfile): repointed .git with core.fsmonitor is held, never runs git in the tree, and --apply keeps it. ---
mk_repo fsm
FSM="$T/fsm"
add_tree fsm fsmbad
add_tree fsm fsmclean
FSM_WT="$FSM/.claude/worktrees/fsmbad"
FSM_CRAFTED="$T/fsm-crafted.git"
FSM_MARKER="$T/fsm-marker"
FSM_HOOK="$T/fsm-hook.sh"
printf '#!/bin/sh\n: > "%s"\n' "$FSM_MARKER" > "$FSM_HOOK"
chmod +x "$FSM_HOOK"
cp -R "$FSM/.git" "$FSM_CRAFTED"
git --git-dir="$FSM_CRAFTED" config core.fsmonitor "$FSM_HOOK"
printf 'gitdir: %s\n' "$FSM_CRAFTED" > "$FSM_WT/.git"
rm -f "$FSM_MARKER"
J_FSM=$("$TOOL" --repo "$FSM" --json)
expect "$J_FSM" fsmbad HOLD:gitfile "repointed .git with core.fsmonitor holds as gitfile"
expect "$J_FSM" fsmclean SAFE "clean sibling alongside repointed tree is still SAFE"
[ ! -e "$FSM_MARKER" ] && ok "safe-worktree-clean dry run did not fire core.fsmonitor marker" \
  || bad "safe-worktree-clean dry run fired core.fsmonitor marker"
out_fsm=$("$TOOL" --repo "$FSM" --apply); rc_fsm=$?
if [ "$rc_fsm" -eq 0 ] && [ ! -e "$FSM_MARKER" ] && [ -d "$FSM_WT" ] && [ ! -e "$FSM/.claude/worktrees/fsmclean" ]; then
  ok "safe-worktree-clean --apply keeps held gitfile tree without firing core.fsmonitor and removes SAFE sibling"
else
  bad "safe-worktree-clean --apply on repointed tree (rc=$rc_fsm, marker=$([ -e "$FSM_MARKER" ] && echo present || echo absent))"; printf '%s\n' "$out_fsm"
fi
git -C "$FSM_WT" status >/dev/null 2>&1
[ -e "$FSM_MARKER" ] && ok "positive control: direct git -C status on repointed tree fires core.fsmonitor marker" \
  || bad "positive control: direct git -C status did not fire core.fsmonitor marker"

# Nested real .git directory with core.fsmonitor staged as a gitlink: held as gitfile without firing the marker.
mk_repo fsmnest
FSMN="$T/fsmnest"
add_tree fsmnest fsmnestbad
add_tree fsmnest fsmnestclean
FSMN_WT="$FSMN/.claude/worktrees/fsmnestbad"
FSMN_MARKER="$T/fsmnest-marker"
FSMN_HOOK="$T/fsmnest-hook.sh"
printf '#!/bin/sh\n: > "%s"\n' "$FSMN_MARKER" > "$FSMN_HOOK"
chmod +x "$FSMN_HOOK"
mkdir "$FSMN_WT/sub"
cp -R "$FSMN/.git" "$FSMN_WT/sub/.git"
rm -rf "$FSMN_WT/sub/.git/worktrees"
git -C "$FSMN_WT/sub" reset -q --hard main
git -C "$FSMN_WT/sub" config core.fsmonitor "$FSMN_HOOK"
git -C "$FSMN_WT" add sub 2>/dev/null
rm -f "$FSMN_MARKER"
J_FSMN=$("$TOOL" --repo "$FSMN" --json)
expect "$J_FSMN" fsmnestbad HOLD:gitfile "nested real .git with core.fsmonitor holds as gitfile"
[ ! -e "$FSMN_MARKER" ] && ok "safe-worktree-clean dry run did not fire nested core.fsmonitor marker" \
  || bad "safe-worktree-clean dry run fired nested core.fsmonitor marker"
out_fsmn=$("$TOOL" --repo "$FSMN" --apply); rc_fsmn=$?
if [ "$rc_fsmn" -eq 0 ] && [ ! -e "$FSMN_MARKER" ] && [ -d "$FSMN_WT" ] && [ ! -e "$FSMN/.claude/worktrees/fsmnestclean" ]; then
  ok "safe-worktree-clean --apply keeps held nested-gitfile tree without firing core.fsmonitor"
else
  bad "safe-worktree-clean --apply on nested .git tree (rc=$rc_fsmn, marker=$([ -e "$FSMN_MARKER" ] && echo present || echo absent))"; printf '%s\n' "$out_fsmn"
fi
git -C "$FSMN_WT" status >/dev/null 2>&1
[ -e "$FSMN_MARKER" ] && ok "positive control: direct git -C status on staged nested repo fires core.fsmonitor marker" \
  || bad "positive control: direct git -C status on staged nested repo did not fire core.fsmonitor marker"

# Planted repo (no .git name) at sub/, untracked: dry run is HOLD:gitfile, --apply keeps the tree, marker absent; git -C "$WT/sub" status fires the marker.
plant_repo() { # $1=dir $2=hook
  mkdir -p "$1/objects" "$1/refs/heads"
  printf 'ref: refs/heads/main\n' > "$1/HEAD"
  : > "$1/objects/.keep"
  : > "$1/refs/heads/.keep"
  printf '[core]\n\trepositoryformatversion = 0\n\tbare = false\n\tworktree = ..\n\tfsmonitor = %s\n' "$2" > "$1/config"
}
mk_repo fsmplant
FSMP="$T/fsmplant"
add_tree fsmplant fsmplantbad
add_tree fsmplant fsmplantclean
FSMP_WT="$FSMP/.claude/worktrees/fsmplantbad"
FSMP_MARKER="$T/fsmplant-marker"
FSMP_HOOK="$T/fsmplant-hook.sh"
printf '#!/bin/sh\n: > "%s"\n' "$FSMP_MARKER" > "$FSMP_HOOK"
chmod +x "$FSMP_HOOK"
plant_repo "$FSMP_WT/sub" "$FSMP_HOOK"
rm -f "$FSMP_MARKER"
J_FSMP=$("$TOOL" --repo "$FSMP" --json)
expect "$J_FSMP" fsmplantbad HOLD:gitfile "planted repo at sub/ (no .git) holds as gitfile"
[ ! -e "$FSMP_MARKER" ] && ok "safe-worktree-clean dry run did not fire planted repo core.fsmonitor marker" \
  || bad "safe-worktree-clean dry run fired planted repo core.fsmonitor marker"
out_fsmp=$("$TOOL" --repo "$FSMP" --apply); rc_fsmp=$?
if [ "$rc_fsmp" -eq 0 ] && [ ! -e "$FSMP_MARKER" ] && [ -d "$FSMP_WT" ] && [ ! -e "$FSMP/.claude/worktrees/fsmplantclean" ]; then
  ok "safe-worktree-clean --apply keeps held planted-repo tree without firing core.fsmonitor"
else
  bad "safe-worktree-clean --apply on planted-repo tree (rc=$rc_fsmp, marker=$([ -e "$FSMP_MARKER" ] && echo present || echo absent))"; printf '%s\n' "$out_fsmp"
fi
git -C "$FSMP_WT/sub" status >/dev/null 2>&1
[ -e "$FSMP_MARKER" ] && ok "positive control: direct git -C sub status on planted repo fires core.fsmonitor marker" \
  || bad "positive control: direct git -C sub status on planted repo did not fire core.fsmonitor marker"

# Gitlink whose path is a symlink to a crafted repo outside the tree: judge_submodules must not run git -C through it.
mk_repo fsmsym
FSMS="$T/fsmsym"
add_tree fsmsym fsmsymbad
FSMS_WT="$FSMS/.claude/worktrees/fsmsymbad"
FSMS_CRAFTED="$T/fsmsym-crafted"
FSMS_MARKER="$T/fsmsym-marker"
FSMS_HOOK="$T/fsmsym-hook.sh"
git init -q "$FSMS_CRAFTED" && git -C "$FSMS_CRAFTED" commit -q --allow-empty -m crafted
FSMS_SHA=$(git -C "$FSMS_CRAFTED" rev-parse HEAD)
printf '#!/bin/sh\n: > "%s"\n' "$FSMS_MARKER" > "$FSMS_HOOK"
chmod +x "$FSMS_HOOK"
git -C "$FSMS_CRAFTED" config core.fsmonitor "$FSMS_HOOK"
ln -s "$FSMS_CRAFTED" "$FSMS_WT/sub"
git -C "$FSMS_WT" update-index --add --cacheinfo "160000,$FSMS_SHA,sub"
rm -f "$FSMS_MARKER"
J_FSMS=$("$TOOL" --repo "$FSMS" --json)
got_fsms=$(verdict "$J_FSMS" fsmsymbad)
case "$got_fsms" in *gitfile*) ok "fsmsymbad: gitlink at a symlink to a repo outside the tree holds as gitfile ('$got_fsms')" ;;
  *) bad "fsmsymbad: got '$got_fsms', want gitfile among its reasons" ;; esac
[ ! -e "$FSMS_MARKER" ] && ok "safe-worktree-clean dry run did not fire symlinked-gitlink core.fsmonitor marker" \
  || bad "safe-worktree-clean dry run fired symlinked-gitlink core.fsmonitor marker"
out_fsms=$("$TOOL" --repo "$FSMS" --apply); rc_fsms=$?
if [ ! -e "$FSMS_MARKER" ] && [ -d "$FSMS_WT" ] && [ -L "$FSMS_WT/sub" ]; then
  ok "safe-worktree-clean --apply keeps the held symlinked-gitlink tree without firing core.fsmonitor (rc=$rc_fsms)"
else
  bad "safe-worktree-clean --apply on symlinked-gitlink tree (rc=$rc_fsms, marker=$([ -e "$FSMS_MARKER" ] && echo present || echo absent))"; printf '%s\n' "$out_fsms"
fi
git -C "$FSMS_WT/sub" status >/dev/null 2>&1
[ -e "$FSMS_MARKER" ] && ok "positive control: direct git -C sub status through the symlink fires core.fsmonitor marker" \
  || bad "positive control: direct git -C sub status through the symlink did not fire core.fsmonitor marker"

# Gitlink at a/crafted where a is a symlink to the crafted repo's parent: the resolved path is outside the tree.
mk_repo fsmsymdir
FSMD="$T/fsmsymdir"
add_tree fsmsymdir fsmsymdirbad
FSMD_WT="$FSMD/.claude/worktrees/fsmsymdirbad"
FSMD_PARENT="$T/fsmsymdir-parent"
FSMD_CRAFTED="$FSMD_PARENT/crafted"
FSMD_MARKER="$T/fsmsymdir-marker"
FSMD_HOOK="$T/fsmsymdir-hook.sh"
mkdir -p "$FSMD_PARENT"
git init -q "$FSMD_CRAFTED" && git -C "$FSMD_CRAFTED" commit -q --allow-empty -m crafted
FSMD_SHA=$(git -C "$FSMD_CRAFTED" rev-parse HEAD)
printf '#!/bin/sh\n: > "%s"\n' "$FSMD_MARKER" > "$FSMD_HOOK"
chmod +x "$FSMD_HOOK"
git -C "$FSMD_CRAFTED" config core.fsmonitor "$FSMD_HOOK"
ln -s "$FSMD_PARENT" "$FSMD_WT/a"
git -C "$FSMD_WT" update-index --add --cacheinfo "160000,$FSMD_SHA,a/crafted"
rm -f "$FSMD_MARKER"
J_FSMD=$("$TOOL" --repo "$FSMD" --json)
got_fsmd=$(verdict "$J_FSMD" fsmsymdirbad)
case "$got_fsmd" in *gitfile*) ok "fsmsymdirbad: gitlink under a symlink that resolves outside the tree holds as gitfile ('$got_fsmd')" ;;
  *) bad "fsmsymdirbad: got '$got_fsmd', want gitfile among its reasons" ;; esac
[ ! -e "$FSMD_MARKER" ] && ok "safe-worktree-clean dry run did not fire symlinked-parent core.fsmonitor marker" \
  || bad "safe-worktree-clean dry run fired symlinked-parent core.fsmonitor marker"
out_fsmd=$("$TOOL" --repo "$FSMD" --apply); rc_fsmd=$?
if [ ! -e "$FSMD_MARKER" ] && [ -d "$FSMD_WT" ] && [ -L "$FSMD_WT/a" ]; then
  ok "safe-worktree-clean --apply keeps the held symlinked-parent tree without firing core.fsmonitor (rc=$rc_fsmd)"
else
  bad "safe-worktree-clean --apply on symlinked-parent tree (rc=$rc_fsmd, marker=$([ -e "$FSMD_MARKER" ] && echo present || echo absent))"; printf '%s\n' "$out_fsmd"
fi
git -C "$FSMD_WT/a/crafted" status >/dev/null 2>&1
[ -e "$FSMD_MARKER" ] && ok "positive control: direct git -C a/crafted status through the symlink fires core.fsmonitor marker" \
  || bad "positive control: direct git -C a/crafted status through the symlink did not fire core.fsmonitor marker"

# Gitlink at sub, a symlink (relative target) to a real directory inside the tree: the path resolves inside, so only the -L clause holds it.
mk_repo fsmsyminner
FSMI="$T/fsmsyminner"
add_tree fsmsyminner fsmsyminnerbad
FSMI_WT="$FSMI/.claude/worktrees/fsmsyminnerbad"
mkdir -p "$FSMI_WT/realdir" && echo inside > "$FSMI_WT/realdir/f.txt"
FSMI_CRAFTED="$T/fsmsyminner-crafted"
git init -q "$FSMI_CRAFTED" && git -C "$FSMI_CRAFTED" commit -q --allow-empty -m crafted
FSMI_SHA=$(git -C "$FSMI_CRAFTED" rev-parse HEAD)
ln -s realdir "$FSMI_WT/sub"
git -C "$FSMI_WT" update-index --add --cacheinfo "160000,$FSMI_SHA,sub"
J_FSMI=$("$TOOL" --repo "$FSMI" --json)
got_fsmi=$(verdict "$J_FSMI" fsmsyminnerbad)
case "$got_fsmi" in *gitfile*) ok "fsmsyminnerbad: gitlink at a symlink to an in-tree directory holds as gitfile ('$got_fsmi')" ;;
  *) bad "fsmsyminnerbad: got '$got_fsmi', want gitfile among its reasons" ;; esac

# --- --only: per-tree scope filter. ---
mk_repo onlyrepo
O="$T/onlyrepo"
add_tree onlyrepo tree1
add_tree onlyrepo tree2
out=$("$TOOL" --repo "$O" --only "$O/.claude/worktrees/tree1"); rc=$?
if [ "$rc" -eq 0 ] && grep -q '^SAFE  \.claude/worktrees/tree1  \[worktree-agent-tree1\]$' <<<"$out" \
  && ! grep -q 'tree2' <<<"$out"; then
  ok "--only <tree1> dry run lists only tree1"
else
  bad "--only <tree1> dry run (rc $rc)"; printf '%s\n' "$out"
fi
out=$(cd "$O" && "$TOOL" --only .claude/worktrees/tree1); rc=$?
if [ "$rc" -eq 0 ] && grep -q '^SAFE  \.claude/worktrees/tree1  \[worktree-agent-tree1\]$' <<<"$out" \
  && ! grep -q 'tree2' <<<"$out"; then
  ok "--only relative path from repo root works"
else
  bad "--only relative path (rc $rc)"; printf '%s\n' "$out"
fi
out=$("$TOOL" --repo "$O" --only="$O/.claude/worktrees/tree2"); rc=$?
if [ "$rc" -eq 0 ] && grep -q '^SAFE  \.claude/worktrees/tree2  \[worktree-agent-tree2\]$' <<<"$out" \
  && ! grep -q 'tree1' <<<"$out"; then
  ok "--only=<tree2> dry run lists only tree2"
else
  bad "--only=<tree2> dry run (rc $rc)"; printf '%s\n' "$out"
fi
err=$("$TOOL" --repo "$O" --only "$O/.claude/worktrees/nosuch" --apply 2>&1 >/dev/null); rc=$?
if [ "$rc" -eq 2 ] \
  && grep -qF "safe-worktree-clean: --only $O/.claude/worktrees/nosuch: not a worktree this run judges in $O (agent trees under .claude/worktrees/; --all widens)" <<<"$err" \
  && [ -d "$O/.claude/worktrees/tree1" ] && [ -d "$O/.claude/worktrees/tree2" ]; then
  ok "--only <nonexistent path> exits 2 with message and removes nothing"
else
  bad "--only <nonexistent path> (rc $rc, err '$err')"
fi
out=$("$TOOL" --repo "$O" --only "$O/.claude/worktrees/tree1" --apply); rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$O/.claude/worktrees/tree1" ] \
  && ! git -C "$O" rev-parse -q --verify refs/heads/worktree-agent-tree1 >/dev/null \
  && [ -d "$O/.claude/worktrees/tree2" ] \
  && git -C "$O" rev-parse -q --verify refs/heads/worktree-agent-tree2 >/dev/null; then
  ok "--only <tree1> --apply removes tree1 and its branch, tree2 and its branch still exist"
else
  bad "--only <tree1> --apply (rc $rc)"; printf '%s\n' "$out"
fi
add_tree onlyrepo tree3
git -C "$O" worktree lock --reason "no pid here" "$O/.claude/worktrees/tree3"
out=$("$TOOL" --repo "$O" --only "$O/.claude/worktrees/tree3" --apply); rc=$?
if [ "$rc" -eq 1 ] && [ -d "$O/.claude/worktrees/tree3" ] \
  && git -C "$O" rev-parse -q --verify refs/heads/worktree-agent-tree3 >/dev/null \
  && grep -q 'HOLD:lock-unparsable' <<<"$out"; then
  ok "--only <tree3> --apply on HOLD tree exits 1, keeps tree3 and branch, reports HOLD:lock-unparsable"
else
  bad "--only <tree3> --apply HOLD (rc $rc)"; printf '%s\n' "$out"
fi
git -C "$O" worktree unlock "$O/.claude/worktrees/tree3"
add_tree onlyrepo tree4 && [ -d "$O/.claude/worktrees/tree4" ] \
  || { bad "setup: add_tree onlyrepo tree4 failed"; git -C "$O" worktree list; }
out=$("$TOOL" --repo "$O" --only "$O/.claude/worktrees/tree2" --only "$O/.claude/worktrees/tree3"); rc=$?
if [ "$rc" -eq 0 ] \
  && grep -q '^SAFE  \.claude/worktrees/tree2  \[worktree-agent-tree2\]$' <<<"$out" \
  && grep -q '^SAFE  \.claude/worktrees/tree3  \[worktree-agent-tree3\]$' <<<"$out" \
  && ! grep -q 'tree4' <<<"$out"; then
  ok "two --only flags dry run lists both tree2 and tree3 as SAFE"
else
  bad "two --only flags dry run (rc $rc)"; printf '%s\n' "$out"
fi
out=$("$TOOL" --repo "$O" --json --only "$O/.claude/worktrees/tree2"); rc=$?
if [ "$rc" -eq 0 ] && python3 -c 'import json,sys; w=json.load(sys.stdin)["worktrees"]; assert len(w)==1 and w[0]["path"].endswith("/tree2") and w[0]["verdict"]=="SAFE"' <<<"$out"; then
  ok "--json --only <tree2> has one worktrees entry ending with /tree2 and verdict SAFE"
else
  bad "--json --only <tree2> (rc $rc)"; printf '%s\n' "$out"
fi
t3_lock="$(git -C "$O/.claude/worktrees/tree3" rev-parse --git-dir)/index.lock"
: > "$t3_lock"; touch -d '30 minutes ago' "$t3_lock"
out=$("$TOOL" --repo "$O" --only "$O/.claude/worktrees/tree2" --locks); rc=$?
if [ "$rc" -eq 0 ] && grep -qF "STALE  $t3_lock" <<<"$out"; then
  ok "--only <tree2> --locks still lists tree3's stale index.lock"
else
  bad "--only <tree2> --locks (rc $rc)"; printf '%s\n' "$out"
fi
pre=$("$TOOL" --repo "$O" --locks)
err=$("$TOOL" --repo "$O" --only "$O/.claude/worktrees/nosuch" --locks-apply 2>&1 >/dev/null); rc=$?
if grep -qF "STALE  $t3_lock" <<<"$pre" \
  && [ "$rc" -eq 2 ] \
  && grep -qF "safe-worktree-clean: --only $O/.claude/worktrees/nosuch: not a worktree this run judges in $O (agent trees under .claude/worktrees/; --all widens)" <<<"$err" \
  && [ -e "$t3_lock" ]; then
  ok "--only <nosuch> --locks-apply exits 2 before --locks runs and leaves the lock in place"
else
  bad "--only <nosuch> --locks-apply (rc $rc, err '$err')"; printf '%s\n' "$pre"
fi
rm -f "$t3_lock"
git -C "$O" worktree add -q -b worktree-agent-outside "$T/outside-tree"
err=$("$TOOL" --repo "$O" --only "$T/outside-tree" 2>&1 >/dev/null); rc=$?
if [ "$rc" -eq 2 ] \
  && grep -qF "safe-worktree-clean: --only $T/outside-tree: not a worktree this run judges in $O (agent trees under .claude/worktrees/; --all widens)" <<<"$err"; then
  ok "--only <outside-tree> without --all exits 2 with not-judged message"
else
  bad "--only <outside-tree> without --all (rc $rc, err '$err')"
fi
out=$("$TOOL" --repo "$O" --all --only "$T/outside-tree"); rc=$?
if { [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; } && grep -q 'outside-tree' <<<"$out" \
  && ! grep -qE 'tree1|tree2|tree3' <<<"$out"; then
  ok "--all --only <outside-tree> dry run names outside-tree and no other tree"
else
  bad "--all --only <outside-tree> dry run (rc $rc)"; printf '%s\n' "$out"
fi
git -C "$O" worktree remove --force "$T/outside-tree"
git -C "$O" branch -D worktree-agent-outside >/dev/null

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
_pipe_out=$("$TOOL" --help) && grep -q 'safe-worktree-clean \[--apply\] \[--repo DIR\]' <<<"$_pipe_out" && ok "--help prints usage" || bad "--help"
"$TOOL" --bogus >/dev/null 2>&1; [ $? = 2 ] && ok "unknown argument exits 2" || bad "unknown argument"
"$TOOL" --repo "$T" >/dev/null 2>&1; [ $? = 2 ] && ok "a non-repo --repo exits 2" || bad "non-repo"
python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["base"]=="origin/main" and "locks" in d' \
  < <("$TOOL" --repo "$L" --json --locks) && ok "--json carries base and locks" || bad "--json shape"

# --- Multi-repo sweep and --apply-hold backup/removal (P1-P8). ---
approvable_of() { # $1 json, $2 tree name -> "True" or "False"
  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
for t in d["worktrees"]:
    if t["path"].endswith("/" + sys.argv[2]):
        print(t["approvable"])
' "$1" "$2"
}

# P1 dry run: sweepone with fine (SAFE), held (commit + dirty + untracked + notes.log + __pycache__/x.pyc), busy (live cwd).
mk_repo sweepone && [ -d "$T/sweepone" ] || bad "P1 setup: mk_repo sweepone"
SW1="$T/sweepone"
SW1W="$SW1/.claude/worktrees"
add_tree sweepone fine && [ -d "$SW1W/fine" ] || bad "P1 setup: add_tree fine"
add_tree sweepone held && [ -d "$SW1W/held" ] || bad "P1 setup: add_tree held"
echo committed > "$SW1W/held/committed.txt" \
  && git -C "$SW1W/held" add committed.txt \
  && git -C "$SW1W/held" commit -qm "held work" \
  || bad "P1 setup: held commit"
HELD_SHA=$(git -C "$SW1W/held" rev-parse HEAD 2>/dev/null)
[ -n "$HELD_SHA" ] || bad "P1 setup: HELD_SHA"
echo dirty-edit > "$SW1W/held/a.txt" && [ -f "$SW1W/held/a.txt" ] || bad "P1 setup: dirty edit"
echo untracked-item > "$SW1W/held/extra.txt" && [ -f "$SW1W/held/extra.txt" ] || bad "P1 setup: untracked extra.txt"
echo keep-log > "$SW1W/held/notes.log" && [ -f "$SW1W/held/notes.log" ] || bad "P1 setup: ignored notes.log"
mkdir -p "$SW1W/held/__pycache__" && echo pyc > "$SW1W/held/__pycache__/x.pyc" && [ -f "$SW1W/held/__pycache__/x.pyc" ] \
  || bad "P1 setup: ignored __pycache__/x.pyc"
add_tree sweepone busy && [ -d "$SW1W/busy" ] || bad "P1 setup: add_tree busy"
(cd "$SW1W/busy" && exec sleep 300) &
BUSY_PID=$!
PIDS+=("$BUSY_PID")
sleep 0.3
kill -0 "$BUSY_PID" 2>/dev/null || bad "P1 setup: busy sleep process"

J_P1=$("$TOOL" --repo "$SW1" --json); rc_p1j=$?
out_p1=$("$TOOL" --repo "$SW1"); rc_p1t=$?
expect "$J_P1" fine SAFE "P1: fine is SAFE"
expect "$J_P1" held HOLD:unmerged,dirty,untracked-new,ignored "P1: held has expected HOLD reasons"
expect "$J_P1" busy HOLD:live-cwd "P1: busy has HOLD:live-cwd"
if [ "$(approvable_of "$J_P1" fine)" = "False" ] && [ "$(approvable_of "$J_P1" held)" = "True" ]; then
  ok "P1: held is approvable and fine is not"
else
  bad "P1: fine/held approvable flags (fine=$(approvable_of "$J_P1" fine), held=$(approvable_of "$J_P1" held))"
fi
if [ "$rc_p1t" -eq 0 ] && [ "$(approvable_of "$J_P1" busy)" = "False" ] && ! grep -q 'approvable with --apply-hold: .*busy' <<<"$out_p1"; then
  ok "P1: busy is not approvable"
else
  bad "P1: busy should not be approvable (got $(approvable_of "$J_P1" busy))"
fi
PLAN_P1_JSON=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["hold_plan"] or "")' "$J_P1")
PLAN_P1_TXT=$(sed -n 's/^hold plan: \([0-9a-f]\{12\}\)$/\1/p' <<<"$out_p1")
if [ "$rc_p1j" -eq 0 ] && [ "$rc_p1t" -eq 0 ] && [ -n "$PLAN_P1_TXT" ] && [ "$PLAN_P1_TXT" = "$PLAN_P1_JSON" ] \
  && grep -qx '  approvable with --apply-hold: \.claude/worktrees/held' <<<"$out_p1"; then
  ok "P1: dry run text hold plan ($PLAN_P1_TXT) matches JSON hold_plan and lists held"
else
  bad "P1: dry run plan id (rc_j=$rc_p1j, rc_t=$rc_p1t, txt='$PLAN_P1_TXT', json='$PLAN_P1_JSON')"; printf '%s\n' "$out_p1"
fi

# P2 wrong id: --apply-hold 000000000000 -> rc 2, stderr starts safe-worktree-clean: hold plan changed:, all three trees stay.
err_p2=$("$TOOL" --repo "$SW1" --apply-hold 000000000000 2>&1 >/dev/null); rc_p2=$?
if [ "$rc_p2" -eq 2 ] \
  && [[ $err_p2 == "safe-worktree-clean: hold plan changed: approved 000000000000, now $PLAN_P1_JSON; rerun the dry run and get a fresh yes"* ]] \
  && [ -d "$SW1W/fine" ] && [ -d "$SW1W/held" ] && [ -d "$SW1W/busy" ]; then
  ok "P2: wrong id exits 2 with hold plan changed message and leaves all three trees in place"
else
  bad "P2: wrong id (rc=$rc_p2, err='$err_p2', fine=$([ -d "$SW1W/fine" ] && echo ok || echo gone), held=$([ -d "$SW1W/held" ] && echo ok || echo gone))"
fi

# P3 stale id: add an untracked file in held, apply with old id -> rc 2, nothing removed; remove file again and re-read id.
echo drift > "$SW1W/held/drift.txt" && [ -f "$SW1W/held/drift.txt" ] || bad "P3 setup: create drift.txt"
err_p3=$("$TOOL" --repo "$SW1" --apply-hold "$PLAN_P1_JSON" 2>&1 >/dev/null); rc_p3=$?
if [ "$rc_p3" -eq 2 ] \
  && [[ $err_p3 == "safe-worktree-clean: hold plan changed: approved $PLAN_P1_JSON, now "* ]] \
  && [ -d "$SW1W/fine" ] && [ -d "$SW1W/held" ] && [ -d "$SW1W/busy" ]; then
  ok "P3: stale id after adding untracked file exits 2 and removes nothing"
else
  bad "P3: stale id (rc=$rc_p3, err='$err_p3')"
fi
rm "$SW1W/held/drift.txt" && [ ! -e "$SW1W/held/drift.txt" ] || bad "P3 setup: remove drift.txt"
PLAN_P3=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["hold_plan"] or "")' < <("$TOOL" --repo "$SW1" --json))
if [ "$PLAN_P3" = "$PLAN_P1_JSON" ]; then
  ok "P3: removing drift.txt restores the original hold plan id ($PLAN_P3)"
else
  bad "P3: restored plan id got '$PLAN_P3', want '$PLAN_P1_JSON'"
fi

# P4 apply: SYG_WORKTREE_BACKUP_DIR=$T/bk --apply-hold <id> -> rc 0; fine and held gone, branches deleted, busy present, backup verified.
out_p4=$(SYG_WORKTREE_BACKUP_DIR="$T/bk" "$TOOL" --repo "$SW1" --apply-hold="$PLAN_P3"); rc_p4=$?
if [ "$rc_p4" -eq 0 ] && [ ! -e "$SW1W/fine" ] && [ ! -e "$SW1W/held" ] && [ -d "$SW1W/busy" ] \
  && ! git -C "$SW1" rev-parse -q --verify refs/heads/worktree-agent-fine >/dev/null \
  && ! git -C "$SW1" rev-parse -q --verify refs/heads/worktree-agent-held >/dev/null \
  && git -C "$SW1" rev-parse -q --verify refs/heads/worktree-agent-busy >/dev/null \
  && grep -q "^backups: $T/bk/" <<<"$out_p4"; then
  ok "P4: --apply-hold removes fine and held and their branches, keeps busy, and prints backups dir"
else
  bad "P4: --apply-hold removal/branches (rc=$rc_p4, fine=$([ -e "$SW1W/fine" ] && echo present || echo gone), held=$([ -e "$SW1W/held" ] && echo present || echo gone), busy=$([ -d "$SW1W/busy" ] && echo present || echo gone))"; printf '%s\n' "$out_p4"
fi
shopt -s nullglob
bk_dirs=("$T/bk"/*/sweepone--held--[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
shopt -u nullglob
BK_HELD=${bk_dirs[0]:-}
if [ "${#bk_dirs[@]}" -eq 1 ] && [ -d "$BK_HELD" ] && [ "$(stat -c %a "$BK_HELD")" = 700 ]; then
  ok "P4: backup dir exists for held with mode 700"
else
  bad "P4: backup dir for held (count=${#bk_dirs[@]}, dir='$BK_HELD', mode=$(stat -c %a "$BK_HELD" 2>/dev/null))"
fi
modes_ok=true
for bf in tree.tgz branch.bundle uncommitted.patch changes.txt README.txt; do
  if [ ! -f "$BK_HELD/$bf" ] || [ "$(stat -c %a "$BK_HELD/$bf" 2>/dev/null)" != 600 ]; then
    modes_ok=false
    bad "P4: $bf missing or not mode 600 (got $(stat -c %a "$BK_HELD/$bf" 2>/dev/null))"
  fi
done
$modes_ok && ok "P4: tree.tgz, branch.bundle, uncommitted.patch, changes.txt, README.txt all mode 600"
tar_list=$(tar -tzf "$BK_HELD/tree.tgz" 2>/dev/null) || bad "P4: tar -tzf on the backup tree.tgz failed"
if grep -qx 'extra\.txt' <<<"$tar_list" && grep -qx 'notes\.log' <<<"$tar_list" && ! grep -qE '(^|/)\.git(/|$)' <<<"$tar_list"; then
  ok "P4: tree.tgz lists extra.txt and notes.log and omits .git"
else
  bad "P4: tree.tgz contents missing extra.txt or notes.log (list: $tar_list)"
fi
if ! grep -q '__pycache__' <<<"$tar_list"; then
  ok "P4: tree.tgz excludes __pycache__"
else
  bad "P4: tree.tgz includes __pycache__ (list: $tar_list)"
fi
git clone -q "$T/sweepone-origin.git" "$T/p4-scratch" 2>/dev/null && [ -d "$T/p4-scratch" ] || bad "P4 setup: clone scratch"
if git -C "$T/p4-scratch" fetch -q "$BK_HELD/branch.bundle" worktree-agent-held:worktree-agent-held 2>/dev/null \
  && [ "$(git -C "$T/p4-scratch" rev-parse worktree-agent-held 2>/dev/null)" = "$HELD_SHA" ]; then
  ok "P4: fetching branch.bundle into scratch repo yields worktree-agent-held at pre-removal HEAD"
else
  bad "P4: bundle fetch (got '$(git -C "$T/p4-scratch" rev-parse worktree-agent-held 2>/dev/null)', want '$HELD_SHA')"
fi
if grep -q 'a\.txt' "$BK_HELD/uncommitted.patch" && grep -q 'dirty-edit' "$BK_HELD/uncommitted.patch"; then
  ok "P4: uncommitted.patch names the dirty path a.txt"
else
  bad "P4: uncommitted.patch contents"
fi

# P5 no commits beyond base: a tree with only an untracked new file -> apply removes it, no branch.bundle, changes.txt says no commits beyond.
mk_repo sweepnoc && [ -d "$T/sweepnoc" ] || bad "P5 setup: mk_repo sweepnoc"
SW5="$T/sweepnoc"
SW5W="$SW5/.claude/worktrees"
add_tree sweepnoc onlynew && [ -d "$SW5W/onlynew" ] || bad "P5 setup: add_tree onlynew"
echo u > "$SW5W/onlynew/only.txt" && [ -f "$SW5W/onlynew/only.txt" ] || bad "P5 setup: only.txt"
PLAN_P5=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["hold_plan"] or "")' < <("$TOOL" --repo "$SW5" --json))
[ -n "$PLAN_P5" ] || bad "P5 setup: PLAN_P5"
SYG_WORKTREE_BACKUP_DIR="$T/bk5" "$TOOL" --repo "$SW5" --apply-hold "$PLAN_P5" >/dev/null; rc_p5=$?
shopt -s nullglob
bk5_dirs=("$T/bk5"/*/sweepnoc--onlynew--[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
shopt -u nullglob
BK5=${bk5_dirs[0]:-}
if [ "$rc_p5" -eq 0 ] && [ ! -e "$SW5W/onlynew" ] && [ -d "$BK5" ] && [ ! -e "$BK5/branch.bundle" ] \
  && grep -q 'no commits beyond origin/main' "$BK5/changes.txt" \
  && grep -q 'no branch.bundle: no commits beyond origin/main' "$BK5/README.txt"; then
  ok "P5: tree with no commits beyond base is removed without branch.bundle and changes.txt/README.txt note no commits beyond"
else
  bad "P5: no commits beyond base (rc=$rc_p5, dir='$BK5')"
fi

# P6 backup failure: SYG_WORKTREE_BACKUP_DIR set to a regular file -> rc 3, tree stays, action names failed: backup:.
mk_repo sweepfail && [ -d "$T/sweepfail" ] || bad "P6 setup: mk_repo sweepfail"
SW6="$T/sweepfail"
SW6W="$SW6/.claude/worktrees"
add_tree sweepfail stuck && [ -d "$SW6W/stuck" ] || bad "P6 setup: add_tree stuck"
echo u > "$SW6W/stuck/u.txt" && [ -f "$SW6W/stuck/u.txt" ] || bad "P6 setup: u.txt"
PLAN_P6=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["hold_plan"] or "")' < <("$TOOL" --repo "$SW6" --json))
[ -n "$PLAN_P6" ] || bad "P6 setup: PLAN_P6"
echo not-a-dir > "$T/bkfile" && [ -f "$T/bkfile" ] || bad "P6 setup: bkfile"
J_P6=$(SYG_WORKTREE_BACKUP_DIR="$T/bkfile" "$TOOL" --repo "$SW6" --apply-hold "$PLAN_P6" --json 2>/dev/null); rc_p6=$?
act_p6=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["worktrees"][0]["action"] or "")' "$J_P6")
if [ "$rc_p6" -eq 3 ] && [ -d "$SW6W/stuck" ] && [ -f "$SW6W/stuck/u.txt" ] && [[ $act_p6 == "failed: backup: "* ]]; then
  ok "P6: backup failure exits 3, leaves the tree in place, and records failed: backup: action"
else
  bad "P6: backup failure (rc=$rc_p6, action='$act_p6')"
fi

# P7 several repos: sweepa and sweepb, one approvable tree each.
mk_repo sweepa && [ -d "$T/sweepa" ] || bad "P7 setup: mk_repo sweepa"
mk_repo sweepb && [ -d "$T/sweepb" ] || bad "P7 setup: mk_repo sweepb"
SWA="$T/sweepa"
SWB="$T/sweepb"
add_tree sweepa ha && [ -d "$SWA/.claude/worktrees/ha" ] || bad "P7 setup: add_tree ha"
add_tree sweepb hb && [ -d "$SWB/.claude/worktrees/hb" ] || bad "P7 setup: add_tree hb"
echo a > "$SWA/.claude/worktrees/ha/new_a.txt" && [ -f "$SWA/.claude/worktrees/ha/new_a.txt" ] || bad "P7 setup: new_a.txt"
echo b > "$SWB/.claude/worktrees/hb/new_b.txt" && [ -f "$SWB/.claude/worktrees/hb/new_b.txt" ] || bad "P7 setup: new_b.txt"

out_p7=$("$TOOL" --repo "$SWA" --repo "$SWB"); rc_p7=$?
SWEEP_ID=$(sed -n 's/^sweep plan: \([0-9a-f]\{12\}\)$/\1/p' <<<"$out_p7")
if [ "$rc_p7" -eq 0 ] && grep -q "^repo: $SWA " <<<"$out_p7" && grep -q "^repo: $SWB " <<<"$out_p7" && [ -n "$SWEEP_ID" ]; then
  ok "P7: --repo A --repo B shows both repo: headers and sweep plan: $SWEEP_ID"
else
  bad "P7: multi-repo text dry run (rc=$rc_p7, sweep_id='$SWEEP_ID')"; printf '%s\n' "$out_p7"
fi

printf '# comment line\n\n%s/sweepa\n%s\n' '~' "$SWB" > "$T/repos.txt" && [ -f "$T/repos.txt" ] || bad "P7 setup: repos.txt"
out_p7f=$(HOME="$T" "$TOOL" --repos-file "$T/repos.txt"); rc_p7f=$?
SWEEP_ID_FILE=$(sed -n 's/^sweep plan: \([0-9a-f]\{12\}\)$/\1/p' <<<"$out_p7f")
if [ "$rc_p7f" -eq 0 ] && [ "$SWEEP_ID_FILE" = "$SWEEP_ID" ]; then
  ok "P7: --repos-file with comment, blank line, and ~/ gives the same sweep plan id"
else
  bad "P7: --repos-file (rc=$rc_p7f, got '$SWEEP_ID_FILE', want '$SWEEP_ID')"
fi

J_P7=$("$TOOL" --repo "$SWA" --repo "$SWB" --json); rc_p7j=$?
if [ "$rc_p7j" -eq 0 ] && python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert len(d["repos"]) == 2 and d["sweep_plan"] == sys.argv[2]
' "$J_P7" "$SWEEP_ID"; then
  ok "P7: --json has repos of length 2 and matching sweep_plan"
else
  bad "P7: --json multi-repo (rc=$rc_p7j)"; printf '%s\n' "$J_P7"
fi

err_p7w=$("$TOOL" --repo "$SWA" --repo "$SWB" --apply-hold 000000000000 2>&1 >/dev/null); rc_p7w=$?
if [ "$rc_p7w" -eq 2 ] && [ -d "$SWA/.claude/worktrees/ha" ] && [ -d "$SWB/.claude/worktrees/hb" ]; then
  ok "P7: wrong sweep id exits 2 and removes nothing in either repo"
else
  bad "P7: wrong sweep id (rc=$rc_p7w, err='$err_p7w')"
fi

out_p7a=$(SYG_WORKTREE_BACKUP_DIR="$T/bk7" "$TOOL" --repo "$SWA" --repo "$SWB" --apply-hold "$SWEEP_ID"); rc_p7a=$?
if [ "$rc_p7a" -eq 0 ] && [ ! -e "$SWA/.claude/worktrees/ha" ] && [ ! -e "$SWB/.claude/worktrees/hb" ] \
  && [ "$(grep -c '^backups: ' <<<"$out_p7a")" -eq 1 ]; then
  ok "P7: right sweep id backs up and removes both trees across repos"
else
  bad "P7: right sweep id apply (rc=$rc_p7a)"; printf '%s\n' "$out_p7a"
fi

# P8 refusals: --apply-hold X --all -> 2; --repo A --repo B --only P -> 2; --repos-file /nonexistent -> 2.
"$TOOL" --repo "$SWA" --apply-hold "$SWEEP_ID" --all >/dev/null 2>&1; rc_r1=$?
[ "$rc_r1" -eq 2 ] && ok "P8: --apply-hold with --all exits 2" || bad "P8: --apply-hold --all exit $rc_r1"
err_r2=$("$TOOL" --repo "$SWA" --repo "$SWB" --only "$SWA/.claude/worktrees/ha" 2>&1 >/dev/null); rc_r2=$?
[ "$rc_r2" -eq 2 ] && grep -qF -- '--only applies to one repo' <<<"$err_r2" \
  && ok "P8: --repo A --repo B --only P exits 2 (--only applies to one repo)" || bad "P8: multi-repo --only (rc=$rc_r2, err='$err_r2')"
"$TOOL" --repos-file "$T/no-such-repos-file" >/dev/null 2>&1; rc_r3=$?
[ "$rc_r3" -eq 2 ] && ok "P8: --repos-file /nonexistent exits 2" || bad "P8: --repos-file /nonexistent exit $rc_r3"

# P9 same basename + spaces: two repos $T/sp1/my proj and $T/sp2/my proj, each with tree w.
for sp in sp1 sp2; do
  mkdir -p "$T/$sp" && [ -d "$T/$sp" ] || bad "P9 setup: mkdir $sp"
  r_sp="$T/$sp/my proj"
  git init -q --bare -b main "$T/$sp/origin.git" && [ -d "$T/$sp/origin.git" ] || bad "P9 setup: bare $sp"
  git clone -q "$T/$sp/origin.git" "$r_sp" 2>/dev/null && [ -d "$r_sp" ] || bad "P9 setup: clone $sp"
  printf '*.log\n__pycache__/\n' > "$r_sp/.gitignore"
  echo v1 > "$r_sp/a.txt"
  git -C "$r_sp" add . && git -C "$r_sp" commit -qm first && git -C "$r_sp" push -q origin main 2>/dev/null \
    && git -C "$r_sp" remote set-head origin main \
    && echo .claude/ >> "$r_sp/.git/info/exclude" \
    || bad "P9 setup: init commits $sp"
  git -C "$r_sp" worktree add -q -b worktree-agent-w "$r_sp/.claude/worktrees/w" origin/main 2>/dev/null \
    && [ -d "$r_sp/.claude/worktrees/w" ] || bad "P9 setup: worktree w in $sp"
  echo "commit-$sp" > "$r_sp/.claude/worktrees/w/c.txt" \
    && git -C "$r_sp/.claude/worktrees/w" add c.txt \
    && git -C "$r_sp/.claude/worktrees/w" commit -qm "work $sp" \
    || bad "P9 setup: commit in $sp/w"
  echo "only-in-$sp" > "$r_sp/.claude/worktrees/w/u.txt" \
    && [ -f "$r_sp/.claude/worktrees/w/u.txt" ] || bad "P9 setup: u.txt in $sp/w"
done
SPA="$T/sp1/my proj"
SPB="$T/sp2/my proj"
SPA_W_SHA=$(git -C "$SPA" rev-parse refs/heads/worktree-agent-w 2>/dev/null)
[ -n "$SPA_W_SHA" ] || bad "P9 setup: SPA_W_SHA"
out_p9d=$("$TOOL" --repo "$SPA" --repo "$SPB"); rc_p9d=$?
SWEEP_P9=$(sed -n 's/^sweep plan: \([0-9a-f]\{12\}\)$/\1/p' <<<"$out_p9d")
[ "$rc_p9d" -eq 0 ] && [ -n "$SWEEP_P9" ] || bad "P9 setup: sweep plan id (rc=$rc_p9d, id='$SWEEP_P9')"
out_p9a=$(SYG_WORKTREE_BACKUP_DIR="$T/bk9" "$TOOL" --repo "$SPA" --repo "$SPB" --apply-hold "$SWEEP_P9"); rc_p9a=$?
sha_spa=$(printf '%s\0%s' "$SPA" "$SPA/.claude/worktrees/w" | sha256sum | cut -c1-8)
sha_spb=$(printf '%s\0%s' "$SPB" "$SPB/.claude/worktrees/w" | sha256sum | cut -c1-8)
shopt -s nullglob
bk9_dirs=("$T/bk9"/*/"my proj--w--"[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
bk9_a=("$T/bk9"/*/"my proj--w--$sha_spa")
bk9_b=("$T/bk9"/*/"my proj--w--$sha_spb")
shopt -u nullglob
BK9_A=${bk9_a[0]:-}
BK9_B=${bk9_b[0]:-}
if [ "$rc_p9a" -eq 0 ] && [ ! -e "$SPA/.claude/worktrees/w" ] && [ ! -e "$SPB/.claude/worktrees/w" ] \
  && [ "${#bk9_dirs[@]}" -eq 2 ] && [ -d "$BK9_A" ] && [ -d "$BK9_B" ] && [ "$BK9_A" != "$BK9_B" ] \
  && [ "$(tar -xzOf "$BK9_A/tree.tgz" u.txt 2>/dev/null)" = "only-in-sp1" ] \
  && [ "$(tar -xzOf "$BK9_B/tree.tgz" u.txt 2>/dev/null)" = "only-in-sp2" ]; then
  ok "P9: same basename repos get two distinct backup dirs my proj--w--<8hex> with their own tree.tgz content"
else
  bad "P9: same basename backups (rc=$rc_p9a, count=${#bk9_dirs[@]}, A='$BK9_A', B='$BK9_B')"; printf '%s\n' "$out_p9a"
fi
restore_cmd=$(grep '^  git -C .* fetch ' "$BK9_A/README.txt" 2>/dev/null)
if [ -n "$restore_cmd" ] && eval "$restore_cmd" 2>/dev/null \
  && [ "$(git -C "$SPA" rev-parse -q --verify refs/heads/worktree-agent-w 2>/dev/null)" = "$SPA_W_SHA" ]; then
  ok "P9: eval of quoted git -C restore line from README.txt restores refs/heads/worktree-agent-w in repo with space"
else
  bad "P9: README restore eval (cmd='$restore_cmd', sha='$(git -C "$SPA" rev-parse -q --verify refs/heads/worktree-agent-w 2>/dev/null)', want='$SPA_W_SHA')"
fi

# P10 content change: editing an untracked file's or ignored non-cache file's content invalidates the plan id.
mk_repo sweepcontent && [ -d "$T/sweepcontent" ] || bad "P10 setup: mk_repo sweepcontent"
SW10="$T/sweepcontent"
SW10W="$SW10/.claude/worktrees"
add_tree sweepcontent wc && [ -d "$SW10W/wc" ] || bad "P10 setup: add_tree wc"
echo v1 > "$SW10W/wc/u.txt" && [ -f "$SW10W/wc/u.txt" ] || bad "P10 setup: u.txt v1"
PLAN_P10_U=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["hold_plan"] or "")' < <("$TOOL" --repo "$SW10" --json))
[ -n "$PLAN_P10_U" ] || bad "P10 setup: PLAN_P10_U"
echo v2 > "$SW10W/wc/u.txt" && [ -f "$SW10W/wc/u.txt" ] || bad "P10 setup: u.txt v2"
err_p10u=$(SYG_WORKTREE_BACKUP_DIR="$T/bk10" "$TOOL" --repo "$SW10" --apply-hold "$PLAN_P10_U" 2>&1 >/dev/null); rc_p10u=$?
if [ "$rc_p10u" -eq 2 ] && [ -d "$SW10W/wc" ] && grep -q 'hold plan changed' <<<"$err_p10u"; then
  ok "P10: changing untracked file content (same name) invalidates plan id (rc 2, tree stays)"
else
  bad "P10: untracked content change (rc=$rc_p10u, err='$err_p10u')"
fi
mk_repo sweepcontentlog && [ -d "$T/sweepcontentlog" ] || bad "P10 setup: mk_repo sweepcontentlog"
SW10L="$T/sweepcontentlog"
SW10LW="$SW10L/.claude/worktrees"
add_tree sweepcontentlog wclog && [ -d "$SW10LW/wclog" ] || bad "P10 setup: add_tree wclog"
echo log1 > "$SW10LW/wclog/app.log" && [ -f "$SW10LW/wclog/app.log" ] || bad "P10 setup: app.log v1"
PLAN_P10_L=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["hold_plan"] or "")' < <("$TOOL" --repo "$SW10L" --json))
[ -n "$PLAN_P10_L" ] || bad "P10 setup: PLAN_P10_L"
echo log2 > "$SW10LW/wclog/app.log" && [ -f "$SW10LW/wclog/app.log" ] || bad "P10 setup: app.log v2"
err_p10l=$(SYG_WORKTREE_BACKUP_DIR="$T/bk10" "$TOOL" --repo "$SW10L" --apply-hold "$PLAN_P10_L" 2>&1 >/dev/null); rc_p10l=$?
if [ "$rc_p10l" -eq 2 ] && [ -d "$SW10LW/wclog" ] && grep -q 'hold plan changed' <<<"$err_p10l"; then
  ok "P10: changing ignored non-cache file content (*.log) invalidates plan id (rc 2, tree stays)"
else
  bad "P10: ignored content change (rc=$rc_p10l, err='$err_p10l')"
fi

# P11 changed during backup: tar shim writes late.txt into -C dir after -czf.
REAL_TAR=$(command -v tar)
mkdir -p "$T/shim" && [ -n "$REAL_TAR" ] || bad "P11 setup: shim dir"
cat > "$T/shim/tar" <<EOF
#!/bin/bash
"$REAL_TAR" "\$@"
rc=\$?
is_czf=false
c_dir=""
prev=""
for a in "\$@"; do
  [ "\$prev" = "-C" ] && c_dir=\$a
  [ "\$a" = "-czf" ] && is_czf=true
  prev=\$a
done
if \$is_czf && [ -n "\$c_dir" ]; then
  echo late > "\$c_dir/late.txt"
fi
exit \$rc
EOF
chmod +x "$T/shim/tar" && [ -x "$T/shim/tar" ] || bad "P11 setup: chmod tar shim"
mk_repo sweeprace && [ -d "$T/sweeprace" ] || bad "P11 setup: mk_repo sweeprace"
SW11="$T/sweeprace"
SW11W="$SW11/.claude/worktrees"
add_tree sweeprace wr && [ -d "$SW11W/wr" ] || bad "P11 setup: add_tree wr"
echo u > "$SW11W/wr/u.txt" && [ -f "$SW11W/wr/u.txt" ] || bad "P11 setup: u.txt"
PLAN_P11=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["hold_plan"] or "")' < <("$TOOL" --repo "$SW11" --json))
[ -n "$PLAN_P11" ] || bad "P11 setup: PLAN_P11"
J_P11=$(PATH="$T/shim:$PATH" SYG_WORKTREE_BACKUP_DIR="$T/bk11" "$TOOL" --repo "$SW11" --apply-hold "$PLAN_P11" --json); rc_p11=$?
act_p11=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["worktrees"][0]["action"] or "")' "$J_P11")
sha_sw11=$(printf '%s\0%s' "$SW11" "$SW11W/wr" | sha256sum | cut -c1-8)
shopt -s nullglob
bk11_dirs=("$T/bk11"/*/"sweeprace--wr--$sha_sw11")
shopt -u nullglob
if [ "$rc_p11" -eq 3 ] && [ -d "$SW11W/wr" ] && [ -f "$SW11W/wr/late.txt" ] \
  && [[ $act_p11 == *"kept: tree changed during backup"* ]] \
  && [ "${#bk11_dirs[@]}" -eq 1 ] && [ -d "${bk11_dirs[0]}" ]; then
  ok "P11: tree changed during backup exits 3, keeps tree with late.txt, keeps backup dir, and reports kept: tree changed during backup"
else
  bad "P11: changed during backup (rc=$rc_p11, action='$act_p11', dirs=${#bk11_dirs[@]})"
fi

# P12 pre-existing leaf: fixed SYG_WORKTREE_RUN_STAMP, pre-created leaf dir with sentinel.
mk_repo sweeppre && [ -d "$T/sweeppre" ] || bad "P12 setup: mk_repo sweeppre"
SW12="$T/sweeppre"
SW12W="$SW12/.claude/worktrees"
add_tree sweeppre wp && [ -d "$SW12W/wp" ] || bad "P12 setup: add_tree wp"
echo u > "$SW12W/wp/u.txt" && [ -f "$SW12W/wp/u.txt" ] || bad "P12 setup: u.txt"
PLAN_P12=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["hold_plan"] or "")' < <("$TOOL" --repo "$SW12" --json))
[ -n "$PLAN_P12" ] || bad "P12 setup: PLAN_P12"
STAMP_P12="2026-01-02T030405"
sha_sw12=$(printf '%s\0%s' "$SW12" "$SW12W/wp" | sha256sum | cut -c1-8)
PRE_LEAF="$T/bk12/$STAMP_P12/sweeppre--wp--$sha_sw12"
mkdir -p "$PRE_LEAF" && echo keep-sentinel > "$PRE_LEAF/sentinel.txt" && [ -f "$PRE_LEAF/sentinel.txt" ] \
  || bad "P12 setup: pre-create leaf dir"
J_P12=$(SYG_WORKTREE_BACKUP_DIR="$T/bk12" SYG_WORKTREE_RUN_STAMP="$STAMP_P12" "$TOOL" --repo "$SW12" --apply-hold "$PLAN_P12" --json); rc_p12=$?
act_p12=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["worktrees"][0]["action"] or "")' "$J_P12")
if [ "$rc_p12" -eq 3 ] && [ -d "$SW12W/wp" ] && [ -f "$SW12W/wp/u.txt" ] \
  && [[ $act_p12 == *"already exists"* ]] \
  && [ "$(cat "$PRE_LEAF/sentinel.txt" 2>/dev/null)" = "keep-sentinel" ] \
  && [ ! -e "$PRE_LEAF/tree.tgz" ]; then
  ok "P12: pre-existing backup leaf dir exits 3 with already exists, keeps tree, and leaves sentinel untouched"
else
  bad "P12: pre-existing leaf (rc=$rc_p12, action='$act_p12')"
fi

# P13 text after apply: P4 text output has HOLD removed after backup: 1 tree(s) and HOLD report: 1 tree(s) left in place.
if grep -qx 'HOLD removed after backup: 1 tree(s)' <<<"$out_p4" \
  && grep -q '^  \.claude/worktrees/held  \[worktree-agent-held\]  backed up to ' <<<"$out_p4" \
  && grep -qx 'HOLD report: 1 tree(s) left in place' <<<"$out_p4" \
  && grep -q '^  \.claude/worktrees/busy  \[worktree-agent-busy\]$' <<<"$out_p4"; then
  ok "P13: text after apply separates HOLD removed after backup: 1 tree(s) and HOLD report: 1 tree(s) left in place"
else
  bad "P13: text after apply"; printf '%s\n' "$out_p4"
fi

# P14 multi-repo failures: --repo <good> --repo $T/not-a-repo --apply-hold X and --json dry run.
mk_repo sweepgood && [ -d "$T/sweepgood" ] || bad "P14 setup: mk_repo sweepgood"
SW14="$T/sweepgood"
SW14W="$SW14/.claude/worktrees"
add_tree sweepgood wg && [ -d "$SW14W/wg" ] || bad "P14 setup: add_tree wg"
echo u > "$SW14W/wg/u.txt" && [ -f "$SW14W/wg/u.txt" ] || bad "P14 setup: u.txt"
mkdir -p "$T/not-a-repo" && [ -d "$T/not-a-repo" ] || bad "P14 setup: mkdir not-a-repo"
err_p14=$("$TOOL" --repo "$SW14" --repo "$T/not-a-repo" --apply-hold 000000000000 2>&1 >/dev/null); rc_p14=$?
if [ "$rc_p14" -eq 2 ] && grep -qF "safe-worktree-clean: $T/not-a-repo: dry run failed; nothing removed" <<<"$err_p14" \
  && [ -d "$SW14W/wg" ]; then
  ok "P14: multi-repo --apply-hold with a failing dry run exits 2 with dry run failed; nothing removed and keeps good repo's tree"
else
  bad "P14: multi-repo --apply-hold failure (rc=$rc_p14, err='$err_p14')"
fi
J_P14=$("$TOOL" --repo "$SW14" --repo "$T/not-a-repo" --json 2>/dev/null); rc_p14j=$?
out_p14t=$("$TOOL" --repo "$SW14" --repo "$T/not-a-repo" 2>/dev/null); rc_p14t=$?
if [ "$rc_p14j" -eq 2 ] && [ "$rc_p14t" -eq 2 ] && python3 -c '
import json, sys
d = json.loads(sys.argv[1])
repos = d["repos"]
assert len(repos) == 2
assert repos[0]["repo"] == sys.argv[2] and "worktrees" in repos[0]
assert repos[1] == {"repo": sys.argv[3], "error": "exit 2"}
assert d["sweep_plan"] is None
' "$J_P14" "$SW14" "$T/not-a-repo" \
  && grep -qxF "sweep plan: none (dry run failed for $T/not-a-repo; fix it or drop it from the list)" <<<"$out_p14t" \
  && ! grep -q '^sweep plan: [0-9a-f]\{12\}$' <<<"$out_p14t"; then
  ok "P14: multi-repo dry run with failed child has sweep_plan null in JSON and prints sweep plan: none in text"
else
  bad "P14: multi-repo dry run (rc_j=$rc_p14j, rc_t=$rc_p14t)"; printf '%s\n%s\n' "$J_P14" "$out_p14t"
fi

# P15 staged-reverted: tree with echo secret > a.txt; git add a.txt; echo hi > a.txt (status MM, checked).
mk_repo sweep15 && [ -d "$T/sweep15" ] || bad "P15 setup: mk_repo sweep15"
SW15="$T/sweep15"
SW15W="$SW15/.claude/worktrees"
add_tree sweep15 mm && [ -d "$SW15W/mm" ] || bad "P15 setup: add_tree mm"
echo secret > "$SW15W/mm/a.txt" \
  && git -C "$SW15W/mm" add a.txt \
  && echo hi > "$SW15W/mm/a.txt" \
  && _pipe_out=$(git -C "$SW15W/mm" status --porcelain=v1) && grep -qx 'MM a\.txt' <<<"$_pipe_out" \
  || bad "P15 setup: status MM a.txt"
PLAN_P15=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["hold_plan"] or "")' < <("$TOOL" --repo "$SW15" --json))
[ -n "$PLAN_P15" ] || bad "P15 setup: PLAN_P15"
SYG_WORKTREE_BACKUP_DIR="$T/bk15" "$TOOL" --repo "$SW15" --apply-hold "$PLAN_P15" >/dev/null; rc_p15=$?
sha_sw15=$(printf '%s\0%s' "$SW15" "$SW15W/mm" | sha256sum | cut -c1-8)
shopt -s nullglob
bk15_dirs=("$T/bk15"/*/"sweep15--mm--$sha_sw15")
shopt -u nullglob
BK15=${bk15_dirs[0]:-}
git clone -q "$T/sweep15-origin.git" "$T/p15-clone" 2>/dev/null && [ -d "$T/p15-clone" ] || bad "P15 setup: clone p15-clone"
if [ "$rc_p15" -eq 0 ] && [ ! -e "$SW15W/mm" ] && [ -f "$BK15/staged.patch" ] \
  && [ "$(stat -c %a "$BK15/staged.patch" 2>/dev/null)" = 600 ] \
  && grep -q 'secret' "$BK15/staged.patch" \
  && grep -q 'git -C <tree or new worktree> apply --index .*staged\.patch' "$BK15/README.txt" \
  && git -C "$T/p15-clone" apply --check "$BK15/staged.patch" 2>/dev/null; then
  ok "P15: staged-reverted (MM) tree removed, staged.patch (mode 600) has secret and applies cleanly to base clone"
else
  bad "P15: staged-reverted (rc=$rc_p15, dir='$BK15')"
fi

# P16 index-only change: staged edit, dry run id, change index only, old id -> rc 2, tree stays.
mk_repo sweep16 && [ -d "$T/sweep16" ] || bad "P16 setup: mk_repo sweep16"
SW16="$T/sweep16"
SW16W="$SW16/.claude/worktrees"
add_tree sweep16 idx && [ -d "$SW16W/idx" ] || bad "P16 setup: add_tree idx"
echo staged1 > "$SW16W/idx/a.txt" \
  && git -C "$SW16W/idx" add a.txt \
  && echo work > "$SW16W/idx/a.txt" \
  || bad "P16 setup: initial staged edit"
cached_p16_before=$(git -C "$SW16W/idx" diff --cached HEAD 2>/dev/null)
[ -n "$cached_p16_before" ] || bad "P16 setup: cached_p16_before"
PLAN_P16=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["hold_plan"] or "")' < <("$TOOL" --repo "$SW16" --json))
[ -n "$PLAN_P16" ] || bad "P16 setup: PLAN_P16"
echo staged2 > "$SW16W/idx/a.txt" \
  && git -C "$SW16W/idx" add a.txt \
  && echo work > "$SW16W/idx/a.txt" \
  || bad "P16 setup: second staged edit"
cached_p16_after=$(git -C "$SW16W/idx" diff --cached HEAD 2>/dev/null)
[ -n "$cached_p16_after" ] && [ "$cached_p16_after" != "$cached_p16_before" ] && [ "$(cat "$SW16W/idx/a.txt")" = "work" ] \
  || bad "P16 setup: git diff --cached changed while worktree file unchanged"
err_p16=$(SYG_WORKTREE_BACKUP_DIR="$T/bk16" "$TOOL" --repo "$SW16" --apply-hold "$PLAN_P16" 2>&1 >/dev/null); rc_p16=$?
if [ "$rc_p16" -eq 2 ] && [ -d "$SW16W/idx" ] && grep -q 'hold plan changed' <<<"$err_p16"; then
  ok "P16: index-only change invalidates plan id (rc 2, tree stays)"
else
  bad "P16: index-only change (rc=$rc_p16, err='$err_p16')"
fi

# P17 unmerged: unmerged index entry without MERGE_HEAD plus untracked file -> approvable false, no hold plan:.
mk_repo sweep17 && [ -d "$T/sweep17" ] || bad "P17 setup: mk_repo sweep17"
SW17="$T/sweep17"
SW17W="$SW17/.claude/worktrees"
add_tree sweep17 unm && [ -d "$SW17W/unm" ] || bad "P17 setup: add_tree unm"
b1_17=$(printf 'base\n' | git -C "$SW17W/unm" hash-object -w --stdin)
b2_17=$(printf 'ours\n' | git -C "$SW17W/unm" hash-object -w --stdin)
b3_17=$(printf 'theirs\n' | git -C "$SW17W/unm" hash-object -w --stdin)
[ -n "$b1_17" ] && [ -n "$b2_17" ] && [ -n "$b3_17" ] || bad "P17 setup: hash-object stage blobs"
printf '100644 %s 1\ta.txt\n100644 %s 2\ta.txt\n100644 %s 3\ta.txt\n' "$b1_17" "$b2_17" "$b3_17" \
  | git -C "$SW17W/unm" update-index --index-info || bad "P17 setup: update-index --index-info"
[ "$(git -C "$SW17W/unm" ls-files -u | wc -l)" -eq 3 ] \
  && [ ! -e "$(git -C "$SW17W/unm" rev-parse --git-path MERGE_HEAD)" ] \
  || bad "P17 setup: git ls-files -u has 3 entries and no MERGE_HEAD"
echo u > "$SW17W/unm/u.txt" && [ -f "$SW17W/unm/u.txt" ] || bad "P17 setup: u.txt"
J_P17=$("$TOOL" --repo "$SW17" --json); rc_p17j=$?
out_p17=$("$TOOL" --repo "$SW17"); rc_p17t=$?
if [ "$rc_p17j" -eq 0 ] && [ "$rc_p17t" -eq 0 ] \
  && [ "$(approvable_of "$J_P17" unm)" = "False" ] \
  && python3 -c 'import json,sys; assert json.loads(sys.argv[1])["hold_plan"] is None' "$J_P17" \
  && ! grep -q '^hold plan:' <<<"$out_p17"; then
  ok "P17: unmerged index entry without MERGE_HEAD makes tree non-approvable with no hold plan:"
else
  bad "P17: unmerged index entry (rc_j=$rc_p17j, rc_t=$rc_p17t, approvable=$(approvable_of "$J_P17" unm))"; printf '%s\n' "$out_p17"
fi

# P18 backup root inside a tree or repo root -> rc 2, stderr starts safe-worktree-clean: backup dir, tree stays.
mk_repo sweep18 && [ -d "$T/sweep18" ] || bad "P18 setup: mk_repo sweep18"
SW18="$T/sweep18"
SW18W="$SW18/.claude/worktrees"
add_tree sweep18 wt18 && [ -d "$SW18W/wt18" ] || bad "P18 setup: add_tree wt18"
echo u > "$SW18W/wt18/u.txt" && [ -f "$SW18W/wt18/u.txt" ] || bad "P18 setup: u.txt"
PLAN_P18=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["hold_plan"] or "")' < <("$TOOL" --repo "$SW18" --json))
[ -n "$PLAN_P18" ] || bad "P18 setup: PLAN_P18"
err_p18a=$(SYG_WORKTREE_BACKUP_DIR="$SW18W/wt18/bk" "$TOOL" --repo "$SW18" --apply-hold "$PLAN_P18" 2>&1 >/dev/null); rc_p18a=$?
err_p18b=$(SYG_WORKTREE_BACKUP_DIR="$SW18/bk" "$TOOL" --repo "$SW18" --apply-hold "$PLAN_P18" 2>&1 >/dev/null); rc_p18b=$?
if [ "$rc_p18a" -eq 2 ] && [ "$rc_p18b" -eq 2 ] \
  && [[ $err_p18a == "safe-worktree-clean: backup dir "*"; choose SYG_WORKTREE_BACKUP_DIR outside the repo and its worktrees" ]] \
  && [[ $err_p18b == "safe-worktree-clean: backup dir "*"; choose SYG_WORKTREE_BACKUP_DIR outside the repo and its worktrees" ]] \
  && [ -d "$SW18W/wt18" ] && [ ! -e "$SW18W/wt18/bk" ] && [ ! -e "$SW18/bk" ]; then
  ok "P18: backup root inside approvable tree or repo root exits 2 with backup dir error and leaves tree in place"
else
  bad "P18: backup root guard (rc_a=$rc_p18a, err_a='$err_p18a', rc_b=$rc_p18b, err_b='$err_p18b')"
fi

# P19 backslash name: untracked back\slash.txt -> apply rc 0, tree removed, tar --quoting-style=literal -tzf lists back\slash.txt.
mk_repo sweep19 && [ -d "$T/sweep19" ] || bad "P19 setup: mk_repo sweep19"
SW19="$T/sweep19"
SW19W="$SW19/.claude/worktrees"
add_tree sweep19 bs && [ -d "$SW19W/bs" ] || bad "P19 setup: add_tree bs"
echo bs > "$SW19W/bs/"'back\slash.txt' && [ -f "$SW19W/bs/"'back\slash.txt' ] || bad "P19 setup: back\\slash.txt"
PLAN_P19=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["hold_plan"] or "")' < <("$TOOL" --repo "$SW19" --json))
[ -n "$PLAN_P19" ] || bad "P19 setup: PLAN_P19"
SYG_WORKTREE_BACKUP_DIR="$T/bk19" "$TOOL" --repo "$SW19" --apply-hold "$PLAN_P19" >/dev/null; rc_p19=$?
sha_sw19=$(printf '%s\0%s' "$SW19" "$SW19W/bs" | sha256sum | cut -c1-8)
shopt -s nullglob
bk19_dirs=("$T/bk19"/*/"sweep19--bs--$sha_sw19")
shopt -u nullglob
BK19=${bk19_dirs[0]:-}
tar19_list=$(tar --quoting-style=literal -tzf "$BK19/tree.tgz" 2>/dev/null)
if [ "$rc_p19" -eq 0 ] && [ ! -e "$SW19W/bs" ] && [ -f "$BK19/tree.tgz" ] \
  && grep -qxF 'back\slash.txt' <<<"$tar19_list"; then
  ok "P19: untracked back\\slash.txt backs up, verifies with literal quoting, and removes tree"
else
  bad "P19: backslash name (rc=$rc_p19, dir='$BK19', list='$tar19_list')"
fi

# P20 cache record: P4's held backup changes.txt lists __pycache__ under the excluded section.
if [ -f "$BK_HELD/changes.txt" ] \
  && _pipe_out=$(sed -n '/^=== Excluded as cache\/regenerable (not in tree\.tgz) ===$/,$p' "$BK_HELD/changes.txt") && grep -qx '__pycache__' <<<"$_pipe_out" \
  && _pipe_out=$(sed -n '/^=== Excluded as cache\/regenerable (not in tree\.tgz) ===$/,$p' "$BK5/changes.txt") && grep -qx 'none' <<<"$_pipe_out"; then
  ok "P20: changes.txt lists __pycache__ under excluded section for P4 held and none when none excluded"
else
  bad "P20: changes.txt excluded section"; cat "$BK_HELD/changes.txt" 2>/dev/null
fi

# P21 locked during backup: tar shim locks the tree with live pid $$ -> rc 3, tree stays, action contains kept: tree locked during backup.
PROBE_PID=$$
kill -0 "$PROBE_PID" 2>/dev/null || bad "P21 setup: PROBE_PID alive"
mkdir -p "$T/shim21" && [ -n "$REAL_TAR" ] || bad "P21 setup: shim21 dir"
cat > "$T/shim21/tar" <<EOF
#!/bin/bash
"$REAL_TAR" "\$@"
rc=\$?
is_czf=false
c_dir=""
prev=""
for a in "\$@"; do
  [ "\$prev" = "-C" ] && c_dir=\$a
  [ "\$a" = "-czf" ] && is_czf=true
  prev=\$a
done
if \$is_czf && [ -n "\$c_dir" ]; then
  git -C "\$c_dir" worktree lock --reason "pid $PROBE_PID" "\$c_dir"
fi
exit \$rc
EOF
chmod +x "$T/shim21/tar" && [ -x "$T/shim21/tar" ] || bad "P21 setup: chmod tar shim21"
mk_repo sweeplockrace && [ -d "$T/sweeplockrace" ] || bad "P21 setup: mk_repo sweeplockrace"
SW21="$T/sweeplockrace"
SW21W="$SW21/.claude/worktrees"
add_tree sweeplockrace wlr && [ -d "$SW21W/wlr" ] || bad "P21 setup: add_tree wlr"
echo u > "$SW21W/wlr/u.txt" && [ -f "$SW21W/wlr/u.txt" ] || bad "P21 setup: u.txt"
PLAN_P21=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["hold_plan"] or "")' < <("$TOOL" --repo "$SW21" --json))
[ -n "$PLAN_P21" ] || bad "P21 setup: PLAN_P21"
J_P21=$(PATH="$T/shim21:$PATH" SYG_WORKTREE_BACKUP_DIR="$T/bk21" "$TOOL" --repo "$SW21" --apply-hold "$PLAN_P21" --json); rc_p21=$?
act_p21=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["worktrees"][0]["action"] or "")' "$J_P21")
if [ "$rc_p21" -eq 3 ] && [ -d "$SW21W/wlr" ] && [[ $act_p21 == *"kept: tree locked during backup"* ]]; then
  ok "P21: tree locked during backup exits 3, keeps tree, and reports kept: tree locked during backup"
else
  bad "P21: locked during backup (rc=$rc_p21, action='$act_p21')"
fi

# P22 volatile root: real-tmpfs branch when $T is tmpfs/ramfs, plus host-independent stat shim sub-cases (a) tmpfs and (b) ext2/ext3.
mk_repo sweep22 && [ -d "$T/sweep22" ] || bad "P22 setup: mk_repo sweep22"
SW22="$T/sweep22"
SW22W="$SW22/.claude/worktrees"
add_tree sweep22 wt22 && [ -d "$SW22W/wt22" ] || bad "P22 setup: add_tree wt22"
echo u > "$SW22W/wt22/u.txt" && [ -f "$SW22W/wt22/u.txt" ] || bad "P22 setup: u.txt"
PLAN_P22=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["hold_plan"] or "")' < <("$TOOL" --repo "$SW22" --json))
[ -n "$PLAN_P22" ] || bad "P22 setup: PLAN_P22"
t_fstype=$(stat -f -c %T "$T" 2>/dev/null) || t_fstype=""
case "$t_fstype" in
  tmpfs | ramfs)
    err_p22=$(env -u SYG_WORKTREE_BACKUP_ALLOW_VOLATILE SYG_WORKTREE_BACKUP_DIR="$T/bk22" "$TOOL" --repo "$SW22" --apply-hold "$PLAN_P22" 2>&1 >/dev/null); rc_p22=$?
    if [ "$rc_p22" -eq 2 ] \
      && [[ $err_p22 == "safe-worktree-clean: backup dir "* ]] \
      && [[ $err_p22 == *"lost on reboot"* ]] \
      && [ -d "$SW22W/wt22" ] && [ -f "$SW22W/wt22/u.txt" ] && [ ! -e "$T/bk22" ]; then
      ok "P22: volatile backup root ($t_fstype) without SYG_WORKTREE_BACKUP_ALLOW_VOLATILE=1 exits 2, keeps tree, and leaves $T/bk22 absent"
    else
      bad "P22: volatile backup root (rc=$rc_p22, err='$err_p22', tree=$([ -d "$SW22W/wt22" ] && echo present || echo gone), bk22=$([ -e "$T/bk22" ] && echo present || echo absent))"
    fi
    ;;
  *)
    echo "skip: P22 real tmpfs ($T is $t_fstype)"
    ;;
esac
REAL_STAT=$(command -v stat)
mkdir -p "$T/shim22" && [ -n "$REAL_STAT" ] || bad "P22 setup: shim22 dir"
cat > "$T/shim22/stat" <<EOF
#!/bin/bash
for a in "\$@"; do
  if [ "\$a" = "-f" ]; then
    printf '%s\n' "\${P22_FSTYPE:-}"
    exit 0
  fi
done
exec "$REAL_STAT" "\$@"
EOF
chmod +x "$T/shim22/stat" && [ -x "$T/shim22/stat" ] || bad "P22 setup: chmod stat shim22"
mk_repo sweep22a && [ -d "$T/sweep22a" ] || bad "P22a setup: mk_repo sweep22a"
SW22A="$T/sweep22a"
SW22AW="$SW22A/.claude/worktrees"
add_tree sweep22a wt22a && [ -d "$SW22AW/wt22a" ] || bad "P22a setup: add_tree wt22a"
echo u > "$SW22AW/wt22a/u.txt" && [ -f "$SW22AW/wt22a/u.txt" ] || bad "P22a setup: u.txt"
PLAN_P22A=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["hold_plan"] or "")' < <("$TOOL" --repo "$SW22A" --json))
[ -n "$PLAN_P22A" ] || bad "P22a setup: PLAN_P22A"
err_p22a=$(env -u SYG_WORKTREE_BACKUP_ALLOW_VOLATILE PATH="$T/shim22:$PATH" P22_FSTYPE=tmpfs SYG_WORKTREE_BACKUP_DIR="$T/bk22s" "$TOOL" --repo "$SW22A" --apply-hold "$PLAN_P22A" 2>&1 >/dev/null); rc_p22a=$?
if [ "$rc_p22a" -eq 2 ] \
  && [[ $err_p22a == "safe-worktree-clean: backup dir "* ]] \
  && [[ $err_p22a == *"lost on reboot"* ]] \
  && [ -d "$SW22AW/wt22a" ] && [ -f "$SW22AW/wt22a/u.txt" ] && [ ! -e "$T/bk22s" ]; then
  ok "P22(a): stat shim tmpfs without SYG_WORKTREE_BACKUP_ALLOW_VOLATILE=1 exits 2, keeps tree, and leaves $T/bk22s absent"
else
  bad "P22(a): stat shim tmpfs (rc=$rc_p22a, err='$err_p22a', tree=$([ -d "$SW22AW/wt22a" ] && echo present || echo gone), bk22s=$([ -e "$T/bk22s" ] && echo present || echo absent))"
fi
mk_repo sweep22b && [ -d "$T/sweep22b" ] || bad "P22b setup: mk_repo sweep22b"
SW22B="$T/sweep22b"
SW22BW="$SW22B/.claude/worktrees"
add_tree sweep22b wt22b && [ -d "$SW22BW/wt22b" ] || bad "P22b setup: add_tree wt22b"
echo u > "$SW22BW/wt22b/u.txt" && [ -f "$SW22BW/wt22b/u.txt" ] || bad "P22b setup: u.txt"
PLAN_P22B=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["hold_plan"] or "")' < <("$TOOL" --repo "$SW22B" --json))
[ -n "$PLAN_P22B" ] || bad "P22b setup: PLAN_P22B"
env -u SYG_WORKTREE_BACKUP_ALLOW_VOLATILE PATH="$T/shim22:$PATH" P22_FSTYPE=ext2/ext3 SYG_WORKTREE_BACKUP_DIR="$T/bk22p" "$TOOL" --repo "$SW22B" --apply-hold "$PLAN_P22B" >/dev/null 2>&1; rc_p22b=$?
sha_sw22b=$(printf '%s\0%s' "$SW22B" "$SW22BW/wt22b" | sha256sum | cut -c1-8)
shopt -s nullglob
bk22b_readmes=("$T/bk22p"/*/"sweep22b--wt22b--$sha_sw22b/README.txt")
shopt -u nullglob
if [ "$rc_p22b" -eq 0 ] && [ ! -e "$SW22BW/wt22b" ] && [ "${#bk22b_readmes[@]}" -eq 1 ] && [ -f "${bk22b_readmes[0]}" ]; then
  ok "P22(b): stat shim ext2/ext3 without SYG_WORKTREE_BACKUP_ALLOW_VOLATILE=1 exits 0, removes tree, and writes backup README.txt"
else
  bad "P22(b): stat shim ext2/ext3 (rc=$rc_p22b, tree=$([ -e "$SW22BW/wt22b" ] && echo present || echo gone), readmes=${#bk22b_readmes[@]})"
fi

# P23 duplicate repo: --repo <R> --repo <R/.>, --repo <R> --repo <linked worktree>, and with --apply-hold <id> -> rc 2, stderr contains are the same repo, approvable tree stays.
mk_repo sweep23 && [ -d "$T/sweep23" ] || bad "P23 setup: mk_repo sweep23"
SW23="$T/sweep23"
SW23W="$SW23/.claude/worktrees"
add_tree sweep23 wt23 && [ -d "$SW23W/wt23" ] || bad "P23 setup: add_tree wt23"
echo u > "$SW23W/wt23/u.txt" && [ -f "$SW23W/wt23/u.txt" ] || bad "P23 setup: u.txt"
PLAN_P23=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["hold_plan"] or "")' < <("$TOOL" --repo "$SW23" --json))
[ -n "$PLAN_P23" ] || bad "P23 setup: PLAN_P23"
err_p23a=$("$TOOL" --repo "$SW23" --repo "$SW23/." 2>&1 >/dev/null); rc_p23a=$?
err_p23b=$("$TOOL" --repo "$SW23" --repo "$SW23W/wt23" 2>&1 >/dev/null); rc_p23b=$?
err_p23c=$(SYG_WORKTREE_BACKUP_DIR="$T/bk23" "$TOOL" --repo "$SW23" --repo "$SW23/." --apply-hold "$PLAN_P23" 2>&1 >/dev/null); rc_p23c=$?
if [ "$rc_p23a" -eq 2 ] && [ "$rc_p23b" -eq 2 ] && [ "$rc_p23c" -eq 2 ] \
  && [[ $err_p23a == *"are the same repo"* ]] \
  && [[ $err_p23b == *"are the same repo"* ]] \
  && [[ $err_p23c == *"are the same repo"* ]] \
  && [ -d "$SW23W/wt23" ] && [ -f "$SW23W/wt23/u.txt" ]; then
  ok "P23: duplicate repo (different spelling or linked worktree) exits 2 with are the same repo in dry run and --apply-hold, keeping tree"
else
  bad "P23: duplicate repo (rc_a=$rc_p23a, err_a='$err_p23a', rc_b=$rc_p23b, err_b='$err_p23b', rc_c=$rc_p23c, err_c='$err_p23c')"
fi

# P24 reflog commit: commit c1 (lost.txt), git reset --hard HEAD~1, untracked file -> apply rc 0, reflog.pack + changes.txt + index-pack restore check.
mk_repo sweep24 && [ -d "$T/sweep24" ] || bad "P24 setup: mk_repo sweep24"
SW24="$T/sweep24"
SW24W="$SW24/.claude/worktrees"
add_tree sweep24 wt24 && [ -d "$SW24W/wt24" ] || bad "P24 setup: add_tree wt24"
echo lost-payload > "$SW24W/wt24/lost.txt" \
  && git -C "$SW24W/wt24" add lost.txt \
  && git -C "$SW24W/wt24" commit -qm "reflog only commit" \
  || bad "P24 setup: commit lost.txt"
C1_P24=$(git -C "$SW24W/wt24" rev-parse HEAD 2>/dev/null)
[ -n "$C1_P24" ] || bad "P24 setup: C1_P24"
git -C "$SW24W/wt24" reset -q --hard HEAD~1 || bad "P24 setup: reset --hard HEAD~1"
! git -C "$SW24W/wt24" merge-base --is-ancestor "$C1_P24" refs/heads/worktree-agent-wt24 2>/dev/null \
  && _pipe_out=$(git -C "$SW24W/wt24" rev-list --walk-reflogs HEAD 2>/dev/null) && grep -qx "$C1_P24" <<<"$_pipe_out" \
  || bad "P24 setup: C1_P24 unreachable from branch and present in HEAD reflog"
echo u > "$SW24W/wt24/u.txt" && [ -f "$SW24W/wt24/u.txt" ] || bad "P24 setup: u.txt"
PLAN_P24=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["hold_plan"] or "")' < <("$TOOL" --repo "$SW24" --json))
[ -n "$PLAN_P24" ] || bad "P24 setup: PLAN_P24"
SYG_WORKTREE_BACKUP_DIR="$T/bk24" "$TOOL" --repo "$SW24" --apply-hold "$PLAN_P24" >/dev/null; rc_p24=$?
sha_sw24=$(printf '%s\0%s' "$SW24" "$SW24W/wt24" | sha256sum | cut -c1-8)
shopt -s nullglob
bk24_dirs=("$T/bk24"/*/"sweep24--wt24--$sha_sw24")
shopt -u nullglob
BK24=${bk24_dirs[0]:-}
git clone -q "$T/sweep24-origin.git" "$T/p24-clone" 2>/dev/null && [ -d "$T/p24-clone" ] || bad "P24 setup: clone p24-clone"
if [ "$rc_p24" -eq 0 ] && [ ! -e "$SW24W/wt24" ] && [ -f "$BK24/reflog.pack" ] \
  && [ "$(stat -c %a "$BK24/reflog.pack" 2>/dev/null)" = 600 ] \
  && [ -f "$BK24/reflog.idx" ] \
  && [ "$(stat -c %a "$BK24/reflog.idx" 2>/dev/null)" = 600 ] \
  && { [ ! -e "$BK24/reflog.rev" ] || [ "$(stat -c %a "$BK24/reflog.rev" 2>/dev/null)" = 600 ]; } \
  && _pipe_out=$(sed -n '/^=== Commits only in reflogs or per-worktree refs (in reflog\.pack) ===$/,/^===/p' "$BK24/changes.txt") && grep -q "^$C1_P24 " <<<"$_pipe_out" \
  && grep -q 'index-pack --stdin --fix-thin < .*reflog\.pack' "$BK24/README.txt" \
  && git -C "$T/p24-clone" index-pack --stdin --fix-thin < "$BK24/reflog.pack" >/dev/null 2>&1 \
  && git -C "$T/p24-clone" cat-file -e "$C1_P24^{commit}" 2>/dev/null \
  && [ "$(git -C "$T/p24-clone" show "$C1_P24:lost.txt" 2>/dev/null)" = "lost-payload" ]; then
  ok "P24: reflog-only commit is packed in reflog.pack, listed in changes.txt, and restores into a fresh clone"
else
  bad "P24: reflog commit (rc=$rc_p24, dir='$BK24')"
fi

# P25 detached tree with commits: tree detached at a commit beyond BASE (approvable as detached-unreferenced), apply -> rc 0, README HEAD:restored-worktree fetch restores old HEAD.
mk_repo sweep25 && [ -d "$T/sweep25" ] || bad "P25 setup: mk_repo sweep25"
SW25="$T/sweep25"
SW25W="$SW25/.claude/worktrees"
git -C "$SW25" worktree add -q --detach "$SW25W/det25" origin/main 2>/dev/null \
  && [ -d "$SW25W/det25" ] || bad "P25 setup: worktree add --detach det25"
echo det-work > "$SW25W/det25/det.txt" \
  && git -C "$SW25W/det25" add det.txt \
  && git -C "$SW25W/det25" commit -qm "detached commit" \
  || bad "P25 setup: detached commit"
DET25_SHA=$(git -C "$SW25W/det25" rev-parse HEAD 2>/dev/null)
[ -n "$DET25_SHA" ] || bad "P25 setup: DET25_SHA"
J_P25=$("$TOOL" --repo "$SW25" --json)
expect "$J_P25" det25 HOLD:detached-unreferenced "P25: det25 held as detached-unreferenced"
PLAN_P25=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["hold_plan"] or "")' "$J_P25")
[ "$(approvable_of "$J_P25" det25)" = "True" ] && [ -n "$PLAN_P25" ] || bad "P25 setup: det25 approvable and PLAN_P25 non-empty"
SYG_WORKTREE_BACKUP_DIR="$T/bk25" "$TOOL" --repo "$SW25" --apply-hold "$PLAN_P25" >/dev/null; rc_p25=$?
sha_sw25=$(printf '%s\0%s' "$SW25" "$SW25W/det25" | sha256sum | cut -c1-8)
shopt -s nullglob
bk25_dirs=("$T/bk25"/*/"sweep25--det25--$sha_sw25")
shopt -u nullglob
BK25=${bk25_dirs[0]:-}
restore_p25=$(grep '^  git -C .* fetch .* HEAD:restored-worktree$' "$BK25/README.txt" 2>/dev/null)
if [ "$rc_p25" -eq 0 ] && [ ! -e "$SW25W/det25" ] && [ -n "$restore_p25" ] \
  && eval "$restore_p25" 2>/dev/null \
  && [ "$(git -C "$SW25" rev-parse -q --verify refs/heads/restored-worktree 2>/dev/null)" = "$DET25_SHA" ]; then
  ok "P25: detached tree with commits is approvable, removed on apply, and README fetch HEAD:restored-worktree restores old HEAD"
else
  bad "P25: detached tree with commits (rc=$rc_p25, cmd='$restore_p25')"
fi

# P26 dead-pid lock: approvable tree locked with --reason "pid <dead pid>" -> apply rc 0, tree removed.
mk_repo sweep26 && [ -d "$T/sweep26" ] || bad "P26 setup: mk_repo sweep26"
SW26="$T/sweep26"
SW26W="$SW26/.claude/worktrees"
add_tree sweep26 wt26 && [ -d "$SW26W/wt26" ] || bad "P26 setup: add_tree wt26"
echo u > "$SW26W/wt26/u.txt" && [ -f "$SW26W/wt26/u.txt" ] || bad "P26 setup: u.txt"
dp26=$(sh -c 'echo $$')
[ -n "$dp26" ] && [ ! -e "/proc/$dp26" ] || bad "P26 setup: dead pid $dp26"
git -C "$SW26" worktree lock --reason "pid $dp26" "$SW26W/wt26" || bad "P26 setup: worktree lock"
PLAN_P26=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["hold_plan"] or "")' < <("$TOOL" --repo "$SW26" --json))
[ -n "$PLAN_P26" ] || bad "P26 setup: PLAN_P26"
SYG_WORKTREE_BACKUP_DIR="$T/bk26" "$TOOL" --repo "$SW26" --apply-hold "$PLAN_P26" >/dev/null; rc_p26=$?
if [ "$rc_p26" -eq 0 ] && [ ! -e "$SW26W/wt26" ] \
  && ! git -C "$SW26" rev-parse -q --verify refs/heads/worktree-agent-wt26 >/dev/null; then
  ok "P26: approvable tree locked with dead pid unlocks, backs up, and removes on --apply-hold"
else
  bad "P26: dead-pid lock (rc=$rc_p26, tree=$([ -e "$SW26W/wt26" ] && echo present || echo gone))"
fi

# P27 cwd appears during backup: tar shim starts sleep 60 with cwd in tree on -czf, records pid to file -> apply rc 3, action contains has its cwd inside the tree, tree stays; kill recorded pid.
mkdir -p "$T/shim27" && [ -n "$REAL_TAR" ] || bad "P27 setup: shim27 dir"
PIDFILE_P27="$T/p27-sleep.pid"
cat > "$T/shim27/tar" <<EOF
#!/bin/bash
"$REAL_TAR" "\$@"
rc=\$?
is_czf=false
c_dir=""
prev=""
for a in "\$@"; do
  [ "\$prev" = "-C" ] && c_dir=\$a
  [ "\$a" = "-czf" ] && is_czf=true
  prev=\$a
done
if \$is_czf && [ -n "\$c_dir" ]; then
  (cd "\$c_dir" && exec sleep 60) >/dev/null 2>&1 </dev/null &
  echo \$! >> "$PIDFILE_P27"
  sleep 0.2
fi
exit \$rc
EOF
chmod +x "$T/shim27/tar" && [ -x "$T/shim27/tar" ] || bad "P27 setup: chmod tar shim27"
mk_repo sweepcwdrace && [ -d "$T/sweepcwdrace" ] || bad "P27 setup: mk_repo sweepcwdrace"
SW27="$T/sweepcwdrace"
SW27W="$SW27/.claude/worktrees"
add_tree sweepcwdrace wcr && [ -d "$SW27W/wcr" ] || bad "P27 setup: add_tree wcr"
echo u > "$SW27W/wcr/u.txt" && [ -f "$SW27W/wcr/u.txt" ] || bad "P27 setup: u.txt"
PLAN_P27=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["hold_plan"] or "")' < <("$TOOL" --repo "$SW27" --json))
[ -n "$PLAN_P27" ] || bad "P27 setup: PLAN_P27"
J_P27=$(PATH="$T/shim27:$PATH" SYG_WORKTREE_BACKUP_DIR="$T/bk27" "$TOOL" --repo "$SW27" --apply-hold "$PLAN_P27" --json); rc_p27=$?
pids_p27=()
if [ -s "$PIDFILE_P27" ]; then
  while IFS= read -r p27 || [ -n "$p27" ]; do
    [ -n "$p27" ] || continue
    PIDS+=("$p27")
    pids_p27+=("$p27")
  done < "$PIDFILE_P27"
fi
if [ "${#pids_p27[@]}" -gt 0 ]; then
  for p27 in "${pids_p27[@]}"; do
    kill "$p27" 2>/dev/null
    wait "$p27" 2>/dev/null
  done
else
  bad "P27 setup: recorded sleep pid missing"
fi
act_p27=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["worktrees"][0]["action"] or "")' "$J_P27")
if [ "$rc_p27" -eq 3 ] && [ -d "$SW27W/wcr" ] && [[ $act_p27 == *"has its cwd inside the tree"* ]]; then
  ok "P27: cwd appearing during backup exits 3, keeps tree, and reports has its cwd inside the tree"
else
  bad "P27: cwd during backup (rc=$rc_p27, action='$act_p27')"
fi

# P28 branch-name approvable: tree on branch feature/x (not matching ^worktree-agent-) with an untracked file -> approvable true; apply -> rc 0, tree removed, feature/x deleted, bundle/README name feature/x.
mk_repo sweep28 && [ -d "$T/sweep28" ] || bad "P28 setup: mk_repo sweep28"
SW28="$T/sweep28"
SW28W="$SW28/.claude/worktrees"
add_tree sweep28 wt28 origin/main feature/x && [ -d "$SW28W/wt28" ] || bad "P28 setup: add_tree wt28 feature/x"
echo u > "$SW28W/wt28/u.txt" && [ -f "$SW28W/wt28/u.txt" ] || bad "P28 setup: u.txt"
J_P28_PRE=$("$TOOL" --repo "$SW28" --json)
[ "$(approvable_of "$J_P28_PRE" wt28)" = "True" ] || bad "P28 setup: wt28 on feature/x with untracked file should be approvable"
echo feat > "$SW28W/wt28/feat.txt" \
  && git -C "$SW28W/wt28" add feat.txt \
  && git -C "$SW28W/wt28" commit -qm "feature x commit" \
  || bad "P28 setup: commit feat.txt"
J_P28=$("$TOOL" --repo "$SW28" --json)
PLAN_P28=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["hold_plan"] or "")' "$J_P28")
[ "$(approvable_of "$J_P28" wt28)" = "True" ] && [ -n "$PLAN_P28" ] || bad "P28 setup: PLAN_P28"
SYG_WORKTREE_BACKUP_DIR="$T/bk28" "$TOOL" --repo "$SW28" --apply-hold "$PLAN_P28" >/dev/null; rc_p28=$?
sha_sw28=$(printf '%s\0%s' "$SW28" "$SW28W/wt28" | sha256sum | cut -c1-8)
shopt -s nullglob
bk28_dirs=("$T/bk28"/*/"sweep28--wt28--$sha_sw28")
shopt -u nullglob
BK28=${bk28_dirs[0]:-}
if [ "$rc_p28" -eq 0 ] && [ ! -e "$SW28W/wt28" ] \
  && ! git -C "$SW28" rev-parse -q --verify refs/heads/feature/x >/dev/null \
  && [ -f "$BK28/branch.bundle" ] \
  && _pipe_out=$(git -C "$SW28" bundle list-heads "$BK28/branch.bundle" 2>/dev/null) && grep -q 'refs/heads/feature/x$' <<<"$_pipe_out" \
  && grep -qx 'branch: feature/x' "$BK28/README.txt" \
  && grep -q 'feature/x:feature/x$' "$BK28/README.txt"; then
  ok "P28: branch feature/x tree is approvable, removed on apply with branch deleted, and bundle/README name feature/x"
else
  bad "P28: branch-name approvable (rc=$rc_p28, dir='$BK28')"
fi

# P29 big reflog: HEAD reflog with >=60000 entries (appended directly to <common>/worktrees/wt29/logs/HEAD) plus untracked file -> apply rc 0, tree removed.
mk_repo sweep29 && [ -d "$T/sweep29" ] || bad "P29 setup: mk_repo sweep29"
SW29="$T/sweep29"
SW29W="$SW29/.claude/worktrees"
add_tree sweep29 wt29 && [ -d "$SW29W/wt29" ] || bad "P29 setup: add_tree wt29"
sha1_p29=$(git -C "$SW29W/wt29" rev-parse HEAD~1 2>/dev/null)
sha2_p29=$(git -C "$SW29W/wt29" rev-parse HEAD 2>/dev/null)
common_p29=$(git -C "$SW29" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
head_log_p29="$common_p29/worktrees/wt29/logs/HEAD"
[ -n "$sha1_p29" ] && [ -n "$sha2_p29" ] && [ -f "$head_log_p29" ] || bad "P29 setup: shas and HEAD reflog path"
awk -v a="$sha1_p29" -v b="$sha2_p29" 'BEGIN {
  for (i = 0; i < 30000; i++) {
    printf "%s %s t <t@example.invalid> 1700000000 +0000\tflip\n%s %s t <t@example.invalid> 1700000000 +0000\tflop\n", b, a, a, b
  }
}' >> "$head_log_p29"
n_rl_p29=$(git -C "$SW29W/wt29" rev-list --walk-reflogs HEAD 2>/dev/null | wc -l)
[ "$n_rl_p29" -ge 60000 ] || bad "P29 setup: walk-reflogs count ($n_rl_p29 < 60000)"
echo u > "$SW29W/wt29/u.txt" && [ -f "$SW29W/wt29/u.txt" ] || bad "P29 setup: u.txt"
PLAN_P29=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["hold_plan"] or "")' < <("$TOOL" --repo "$SW29" --json))
[ -n "$PLAN_P29" ] || bad "P29 setup: PLAN_P29"
SYG_WORKTREE_BACKUP_DIR="$T/bk29" "$TOOL" --repo "$SW29" --apply-hold "$PLAN_P29" >/dev/null; rc_p29=$?
if [ "$rc_p29" -eq 0 ] && [ ! -e "$SW29W/wt29" ]; then
  ok "P29: tree with >=60000 HEAD reflog entries backs up and removes on --apply-hold without hitting argv limit"
else
  bad "P29: big reflog (rc=$rc_p29, tree=$([ -e "$SW29W/wt29" ] && echo present || echo gone))"
fi

# P30 quoted restore refspec: branch worktree-agent-feat(x);y with commit beyond base + untracked file -> README fetch line run with bash -c recreates branch at backed-up HEAD sha.
mk_repo sweep30 && [ -d "$T/sweep30" ] || bad "P30 setup: mk_repo sweep30"
SW30="$T/sweep30"
SW30W="$SW30/.claude/worktrees"
BR30='worktree-agent-feat(x);y'
add_tree sweep30 wt30 origin/main "$BR30" && [ -d "$SW30W/wt30" ] || bad "P30 setup: add_tree wt30"
echo c30 > "$SW30W/wt30/c30.txt" \
  && git -C "$SW30W/wt30" add c30.txt \
  && git -C "$SW30W/wt30" commit -qm "p30 commit" \
  || bad "P30 setup: commit c30.txt"
SHA_P30=$(git -C "$SW30W/wt30" rev-parse HEAD 2>/dev/null)
echo u30 > "$SW30W/wt30/u30.txt" && [ -f "$SW30W/wt30/u30.txt" ] && [ -n "$SHA_P30" ] || bad "P30 setup: u30.txt and SHA_P30"
PLAN_P30=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["hold_plan"] or "")' < <("$TOOL" --repo "$SW30" --json))
[ -n "$PLAN_P30" ] || bad "P30 setup: PLAN_P30"
SYG_WORKTREE_BACKUP_DIR="$T/bk30" "$TOOL" --repo "$SW30" --apply-hold "$PLAN_P30" >/dev/null; rc_p30=$?
! git -C "$SW30" rev-parse -q --verify "refs/heads/$BR30" >/dev/null || bad "P30 setup: branch deleted by --apply-hold"
sha_sw30=$(printf '%s\0%s' "$SW30" "$SW30W/wt30" | sha256sum | cut -c1-8)
shopt -s nullglob
bk30_dirs=("$T/bk30"/*/"sweep30--wt30--$sha_sw30")
shopt -u nullglob
BK30=${bk30_dirs[0]:-}
restore_p30=$(grep '^  git -C .* fetch ' "$BK30/README.txt" 2>/dev/null)
if [ "$rc_p30" -eq 0 ] && [ ! -e "$SW30W/wt30" ] && [ -n "$restore_p30" ] \
  && bash -c "$restore_p30" >/dev/null 2>&1 \
  && [ "$(git -C "$SW30" rev-parse -q --verify "refs/heads/$BR30" 2>/dev/null)" = "$SHA_P30" ]; then
  ok "P30: README fetch line quotes special branch name worktree-agent-feat(x);y and bash -c recreates it at backed-up HEAD"
else
  bad "P30: quoted restore refspec (rc=$rc_p30, cmd='$restore_p30', got='$(git -C "$SW30" rev-parse -q --verify "refs/heads/$BR30" 2>/dev/null)', want='$SHA_P30')"
fi

# P31 per-worktree refs: (i) refs/worktree/keep at commit-tree commit holds as worktree-refs (approvable); (ii) --apply-hold packs it in reflog.pack and records it in changes.txt/README.txt; (iii) refs/worktree/x on base stays SAFE.
mk_repo sweep31 && [ -d "$T/sweep31" ] || bad "P31 setup: mk_repo sweep31"
SW31="$T/sweep31"
SW31W="$SW31/.claude/worktrees"
add_tree sweep31 wt31k && [ -d "$SW31W/wt31k" ] || bad "P31 setup: add_tree wt31k"
add_tree sweep31 wt31s && [ -d "$SW31W/wt31s" ] || bad "P31 setup: add_tree wt31s"
tree_31=$(git -C "$SW31W/wt31k" rev-parse 'HEAD^{tree}' 2>/dev/null)
C_P31=$(git -C "$SW31W/wt31k" commit-tree "$tree_31" -p HEAD -m keep 2>/dev/null)
[ -n "$C_P31" ] && git -C "$SW31W/wt31k" update-ref refs/worktree/keep "$C_P31" || bad "P31 setup: commit-tree + update-ref keep"
_pipe_out=$(git -C "$SW31W/wt31k" rev-list --walk-reflogs HEAD 2>/dev/null) || bad "P31 setup: walking the HEAD reflog"
! grep -qx "$C_P31" <<<"$_pipe_out" || bad "P31 setup: C_P31 is in the HEAD reflog"
_pipe_out=$(git -C "$SW31W/wt31k" rev-list --walk-reflogs refs/heads/worktree-agent-wt31k 2>/dev/null) || bad "P31 setup: walking the branch reflog"
! grep -qx "$C_P31" <<<"$_pipe_out" || bad "P31 setup: C_P31 is in the branch reflog"
git -C "$SW31W/wt31s" update-ref refs/worktree/x "$C1" || bad "P31 setup: update-ref refs/worktree/x on base"
J_P31=$("$TOOL" --repo "$SW31" --json); rc_p31d=$?
PLAN_P31=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["hold_plan"] or "")' "$J_P31")
if [ "$rc_p31d" -eq 0 ] && [ "$(verdict "$J_P31" wt31k)" = "HOLD:worktree-refs" ] \
  && [ "$(approvable_of "$J_P31" wt31k)" = "True" ] && [ -n "$PLAN_P31" ]; then
  ok "P31(i): tree with unreferenced refs/worktree/keep is HOLD:worktree-refs and approvable"
else
  bad "P31(i): worktree-refs verdict/approvable (rc=$rc_p31d, verdict='$(verdict "$J_P31" wt31k)', approvable='$(approvable_of "$J_P31" wt31k)', plan='$PLAN_P31')"
fi
if [ "$(verdict "$J_P31" wt31s)" = "SAFE" ]; then
  ok "P31(iii): tree whose refs/worktree/x points at a commit on base stays SAFE"
else
  bad "P31(iii): wt31s expected SAFE, got '$(verdict "$J_P31" wt31s)'"
fi
SYG_WORKTREE_BACKUP_DIR="$T/bk31" "$TOOL" --repo "$SW31" --apply-hold "${PLAN_P31:-none}" >/dev/null 2>&1; rc_p31a=$?
sha_sw31=$(printf '%s\0%s' "$SW31" "$SW31W/wt31k" | sha256sum | cut -c1-8)
shopt -s nullglob
bk31_dirs=("$T/bk31"/*/"sweep31--wt31k--$sha_sw31")
shopt -u nullglob
BK31=${bk31_dirs[0]:-}
git clone -q "$T/sweep31-origin.git" "$T/p31-clone" 2>/dev/null && [ -d "$T/p31-clone" ] || bad "P31 setup: clone p31-clone"
if [ "$rc_p31a" -eq 0 ] && [ ! -e "$SW31W/wt31k" ] && [ ! -e "$SW31W/wt31s" ] && [ -f "$BK31/reflog.pack" ] \
  && _pipe_out=$(sed -n '/^=== Commits only in reflogs or per-worktree refs (in reflog\.pack) ===$/,/^===/p' "$BK31/changes.txt") && grep -q "^$C_P31 " <<<"$_pipe_out" \
  && _pipe_out=$(sed -n '/^=== Per-worktree refs (refs\/worktree\/\*, refs\/bisect\/\*, refs\/rewritten\/\*) ===$/,/^===/p' "$BK31/changes.txt") && grep -qx "$C_P31 refs/worktree/keep" <<<"$_pipe_out" \
  && grep -q 'update-ref <refname> <sha from changes\.txt>' "$BK31/README.txt" \
  && git -C "$T/p31-clone" index-pack --stdin --fix-thin < "$BK31/reflog.pack" >/dev/null 2>&1 \
  && git -C "$T/p31-clone" cat-file -e "$C_P31^{commit}" 2>/dev/null; then
  ok "P31(ii): --apply-hold packs refs/worktree/keep commit in reflog.pack, lists it in changes.txt and README.txt, and restores into a scratch clone"
else
  bad "P31(ii): worktree-refs backup (rc=$rc_p31a, dir='$BK31')"
fi

# P31(iv)/(v) non-commit refs/worktree/* tips: a ref at a blob and a ref at an annotated tag object (on an otherwise-unreferenced commit-tree commit) HOLD as worktree-refs-object and are never approvable (the backup packs commits only).
mk_repo sweep31b && [ -d "$T/sweep31b" ] || bad "P31b setup: mk_repo sweep31b"
SW31B="$T/sweep31b"
SW31BW="$SW31B/.claude/worktrees"
add_tree sweep31b wt31blob && [ -d "$SW31BW/wt31blob" ] || bad "P31b setup: add_tree wt31blob"
add_tree sweep31b wt31tag && [ -d "$SW31BW/wt31tag" ] || bad "P31b setup: add_tree wt31tag"
blob_31=$(printf 'blob payload\n' | git -C "$SW31BW/wt31blob" hash-object -w --stdin 2>/dev/null)
[ -n "$blob_31" ] && git -C "$SW31BW/wt31blob" update-ref refs/worktree/blobref "$blob_31" || bad "P31(iv) setup: hash-object -w + update-ref blobref"
[ "$(git -C "$SW31BW/wt31blob" for-each-ref --format='%(objecttype)' refs/worktree/blobref 2>/dev/null)" = blob ] || bad "P31(iv) setup: blobref is not a blob"
tree_31t=$(git -C "$SW31BW/wt31tag" rev-parse 'HEAD^{tree}' 2>/dev/null)
C_P31T=$(git -C "$SW31BW/wt31tag" commit-tree "$tree_31t" -p HEAD -m tagged 2>/dev/null)
[ -n "$C_P31T" ] && git -C "$SW31BW/wt31tag" tag -a -m "p31 tag" p31tmptag "$C_P31T" 2>/dev/null || bad "P31(v) setup: commit-tree + tag -a"
tag_31=$(git -C "$SW31BW/wt31tag" rev-parse refs/tags/p31tmptag 2>/dev/null)
[ -n "$tag_31" ] && git -C "$SW31BW/wt31tag" update-ref refs/worktree/tagref "$tag_31" \
  && git -C "$SW31BW/wt31tag" tag -d p31tmptag >/dev/null 2>&1 || bad "P31(v) setup: update-ref tagref + delete tag"
[ "$(git -C "$SW31BW/wt31tag" for-each-ref --format='%(objecttype)' refs/worktree/tagref 2>/dev/null)" = tag ] \
  && [ -z "$(git -C "$SW31BW/wt31tag" for-each-ref refs/tags/p31tmptag 2>/dev/null)" ] || bad "P31(v) setup: tagref is not a tag object or the temporary tag remains"
J_P31B=$("$TOOL" --repo "$SW31B" --json); rc_p31b=$?
if [ "$rc_p31b" -eq 0 ] && [ "$(verdict "$J_P31B" wt31blob)" = "HOLD:worktree-refs-object" ] \
  && [ "$(approvable_of "$J_P31B" wt31blob)" = "False" ]; then
  ok "P31(iv): tree whose refs/worktree/blobref points at a blob is HOLD:worktree-refs-object and not approvable"
else
  bad "P31(iv): blob ref verdict/approvable (rc=$rc_p31b, verdict='$(verdict "$J_P31B" wt31blob)', approvable='$(approvable_of "$J_P31B" wt31blob)')"
fi
v_p31t=$(verdict "$J_P31B" wt31tag)
if [[ $v_p31t == HOLD:* ]] && [[ ",${v_p31t#HOLD:}," == *,worktree-refs-object,* ]] \
  && [ "$(approvable_of "$J_P31B" wt31tag)" = "False" ]; then
  ok "P31(v): tree whose refs/worktree/tagref points at an annotated tag object is HOLD with worktree-refs-object and not approvable"
else
  bad "P31(v): tag ref verdict/approvable (verdict='$v_p31t', approvable='$(approvable_of "$J_P31B" wt31tag)')"
fi

# P32 moving refs/worktree/* between dry run and --apply-hold invalidates plan id (exit 2, tree kept).
mk_repo sweep32 && [ -d "$T/sweep32" ] || bad "P32 setup: mk_repo sweep32"
SW32="$T/sweep32"
SW32W="$SW32/.claude/worktrees"
add_tree sweep32 wt32 && [ -d "$SW32W/wt32" ] || bad "P32 setup: add_tree wt32"
tree_32=$(git -C "$SW32W/wt32" rev-parse 'HEAD^{tree}' 2>/dev/null)
C1_P32=$(git -C "$SW32W/wt32" commit-tree "$tree_32" -p HEAD -m keep1 2>/dev/null)
C2_P32=$(git -C "$SW32W/wt32" commit-tree "$tree_32" -p HEAD -m keep2 2>/dev/null)
[ -n "$C1_P32" ] && [ -n "$C2_P32" ] && [ "$C1_P32" != "$C2_P32" ] \
  && git -C "$SW32W/wt32" update-ref refs/worktree/keep "$C1_P32" || bad "P32 setup: update-ref C1_P32"
PLAN_P32=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["hold_plan"] or "")' < <("$TOOL" --repo "$SW32" --json))
[ -n "$PLAN_P32" ] || bad "P32 setup: PLAN_P32"
git -C "$SW32W/wt32" update-ref refs/worktree/keep "$C2_P32" || bad "P32 setup: move refs/worktree/keep to C2_P32"
err_p32=$(SYG_WORKTREE_BACKUP_DIR="$T/bk32" "$TOOL" --repo "$SW32" --apply-hold "${PLAN_P32:-none}" 2>&1 >/dev/null); rc_p32=$?
if [ "$rc_p32" -eq 2 ] && [ -d "$SW32W/wt32" ] && grep -q 'hold plan changed' <<<"$err_p32"; then
  ok "P32: moving refs/worktree/keep between dry run and --apply-hold invalidates plan id (rc 2, tree kept)"
else
  bad "P32: moving refs/worktree/keep (rc=$rc_p32, err='$err_p32')"
fi

# P33 batch hash-object parity: 3 untracked files (1 regular, 1 symlink, 1 newline-named) + 1 ignored file match reference per-file formula.
mk_repo sweep33 && [ -d "$T/sweep33" ] || bad "P33 setup: mk_repo sweep33"
SW33="$T/sweep33"
SW33W="$SW33/.claude/worktrees"
WT33="$SW33W/wt33"
add_tree sweep33 wt33 && [ -d "$WT33" ] || bad "P33 setup: add_tree wt33"
echo one > "$WT33/u1.txt" \
  && ln -s a.txt "$WT33/ulink" \
  && echo two > "$WT33/"$'u\nnl.txt' \
  && echo three > "$WT33/extra.log" \
  && [ -f "$WT33/u1.txt" ] && [ -L "$WT33/ulink" ] && [ -f "$WT33/"$'u\nnl.txt' ] && [ -f "$WT33/extra.log" ] \
  || bad "P33 setup: create files"
# The reference mirrors tree_state_sha's stream exactly, rc sentinels included (all children
# succeed on a healthy tree, the batch covers u1.txt and extra.log: batch=0:0).
ref_state_p33=$(
  {
    printf '\001atrisk=%s\0' 0
    git -C "$WT33" status --porcelain=v1 -z --ignored --untracked-files=all; rc33=$?
    printf '\001status=%s\0' "$rc33"
    git -C "$WT33" diff --binary HEAD; rc33=$?
    printf '\001diff=%s\0' "$rc33"
    git -C "$WT33" diff --binary --cached HEAD; rc33=$?
    printf '\001diffcached=%s\0' "$rc33"
    printf '\001batch=%s\0' "0:0"
    for p33 in $'u\nnl.txt' u1.txt ulink extra.log; do
      rc33=0
      if [ -L "$WT33/$p33" ]; then
        h33=$(readlink -- "$WT33/$p33") || rc33=$?
      else
        h33=$(git -C "$WT33" hash-object --no-filters -- "$p33") || rc33=$?
      fi
      printf '%s\0%s\0' "$p33" "${h33:-}"
      printf '\001hash=%s\0' "$rc33"
    done
    git -C "$WT33" for-each-ref --format='%(objectname) %(refname)' refs/worktree/ refs/bisect/ refs/rewritten/; rc33=$?
    printf '\001foreachref=%s\0' "$rc33"
  } | sha256sum | cut -d' ' -f1
)
head_p33=$(git -C "$WT33" rev-parse HEAD)
reasons_p33=$(printf '%s\n' \
  $'untracked-new\tu\nnl.txt is untracked and not on origin/main' \
  $'untracked-new\tu1.txt is untracked and not on origin/main' \
  $'untracked-new\tulink is untracked and not on origin/main' \
  $'ignored\textra.log is ignored and not a safe-clean cache name or a declared regenerable path' \
  | LC_ALL=C sort)
ref_plan_p33=$(printf '%s\0%s\0%s\0%s\0%s\0' "$WT33" "worktree-agent-wt33" "$head_p33" "$reasons_p33" "$ref_state_p33" | sha256sum | cut -c1-12)
PLAN_P33=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["hold_plan"] or "")' < <("$TOOL" --repo "$SW33" --json))
if [ -n "$PLAN_P33" ] && [ "$PLAN_P33" = "$ref_plan_p33" ]; then
  ok "P33: batched hash-object hold_plan ($PLAN_P33) matches old per-file formula with regular, symlink, and newline-named files"
else
  bad "P33: batched hash-object parity (got '$PLAN_P33', want '$ref_plan_p33')"
fi

# P33b batch path hygiene: untracked `a` and `"a"` (literal quotes in the name) must not collide in the batch (git C-unquotes a stdin-paths line starting with a quote); hold_plan equals the old per-file formula and changes when `"a"` changes.
mk_repo sweep33b && [ -d "$T/sweep33b" ] || bad "P33b setup: mk_repo sweep33b"
SW33B="$T/sweep33b"
WT33B="$SW33B/.claude/worktrees/wt33b"
add_tree sweep33b wt33b && [ -d "$WT33B" ] || bad "P33b setup: add_tree wt33b"
printf 'one\n' > "$WT33B/a" \
  && printf 'two\n' > "$WT33B/"'"a"' \
  && [ -f "$WT33B/a" ] && [ -f "$WT33B/"'"a"' ] \
  || bad "P33b setup: create a and quoted-name files"
ref_plan_p33b() {
  local p h rc_b state head reasons
  state=$(
    {
      printf '\001atrisk=%s\0' 0
      git -C "$WT33B" status --porcelain=v1 -z --ignored --untracked-files=all; rc_b=$?
      printf '\001status=%s\0' "$rc_b"
      git -C "$WT33B" diff --binary HEAD; rc_b=$?
      printf '\001diff=%s\0' "$rc_b"
      git -C "$WT33B" diff --binary --cached HEAD; rc_b=$?
      printf '\001diffcached=%s\0' "$rc_b"
      printf '\001batch=%s\0' "0:0"   # the batch holds only `a`; the quoted name is hashed per file
      for p in '"a"' a; do
        rc_b=0
        h=$(git -C "$WT33B" hash-object --no-filters -- "$p") || rc_b=$?
        printf '%s\0%s\0' "$p" "${h:-}"
        printf '\001hash=%s\0' "$rc_b"
      done
      git -C "$WT33B" for-each-ref --format='%(objectname) %(refname)' refs/worktree/ refs/bisect/ refs/rewritten/; rc_b=$?
      printf '\001foreachref=%s\0' "$rc_b"
    } | sha256sum | cut -d' ' -f1
  )
  head=$(git -C "$WT33B" rev-parse HEAD)
  reasons=$(printf '%s\n' \
    $'untracked-new\t"a" is untracked and not on origin/main' \
    $'untracked-new\ta is untracked and not on origin/main' \
    | LC_ALL=C sort)
  printf '%s\0%s\0%s\0%s\0%s\0' "$WT33B" "worktree-agent-wt33b" "$head" "$reasons" "$state" | sha256sum | cut -c1-12
}
ref1_p33b=$(ref_plan_p33b)
PLAN1_P33B=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["hold_plan"] or "")' < <("$TOOL" --repo "$SW33B" --json))
printf 'three\n' > "$WT33B/"'"a"' || bad "P33b setup: rewrite quoted-name file"
ref2_p33b=$(ref_plan_p33b)
PLAN2_P33B=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["hold_plan"] or "")' < <("$TOOL" --repo "$SW33B" --json))
if [ -n "$PLAN1_P33B" ] && [ "$PLAN1_P33B" = "$ref1_p33b" ] \
  && [ -n "$PLAN2_P33B" ] && [ "$PLAN2_P33B" = "$ref2_p33b" ] && [ "$PLAN1_P33B" != "$PLAN2_P33B" ]; then
  ok "P33b: hold_plan matches the per-file formula for untracked a and \"a\", and changes when \"a\" changes"
else
  bad "P33b: quoted-name batch parity (plan1='$PLAN1_P33B' want '$ref1_p33b'; plan2='$PLAN2_P33B' want '$ref2_p33b')"
fi

# P34 SYG_WORKTREE_RUN_STAMP validation: ../x, a/b and a set-but-empty value exit 2 with message prefix; no dir created under backup root.
err_p34a=$(SYG_WORKTREE_BACKUP_DIR="$T/bk34" SYG_WORKTREE_RUN_STAMP="../x" "$TOOL" --repo "$SW33" 2>&1 >/dev/null); rc_p34a=$?
err_p34b=$(SYG_WORKTREE_BACKUP_DIR="$T/bk34" SYG_WORKTREE_RUN_STAMP="a/b" "$TOOL" --repo "$SW33" 2>&1 >/dev/null); rc_p34b=$?
err_p34c=$(SYG_WORKTREE_BACKUP_DIR="$T/bk34" SYG_WORKTREE_RUN_STAMP="" "$TOOL" --repo "$SW33" 2>&1 >/dev/null); rc_p34c=$?
if [ "$rc_p34a" -eq 2 ] && [ "$rc_p34b" -eq 2 ] && [ "$rc_p34c" -eq 2 ] \
  && [[ $err_p34a == "safe-worktree-clean: SYG_WORKTREE_RUN_STAMP is internal and must be a plain name: ../x"* ]] \
  && [[ $err_p34b == "safe-worktree-clean: SYG_WORKTREE_RUN_STAMP is internal and must be a plain name: a/b"* ]] \
  && [[ $err_p34c == "safe-worktree-clean: SYG_WORKTREE_RUN_STAMP is internal and must be a plain name: "* ]] \
  && [ ! -e "$T/bk34" ] && [ ! -e "$T/x" ]; then
  ok "P34: invalid SYG_WORKTREE_RUN_STAMP values ../x, a/b and set-but-empty exit 2 with plain-name error and create no backup dir"
else
  bad "P34: SYG_WORKTREE_RUN_STAMP validation (rc_a=$rc_p34a, err_a='$err_p34a', rc_b=$rc_p34b, err_b='$err_p34b', rc_c=$rc_p34c, err_c='$err_p34c')"
fi

# P35 same tree basename at different depths in one repo: .claude/worktrees/a/wt and .claude/worktrees/b/wt -> both backed up and removed, rc 0.
mk_repo sweep35 && [ -d "$T/sweep35" ] || bad "P35 setup: mk_repo sweep35"
SW35="$T/sweep35"
SW35W="$SW35/.claude/worktrees"
mkdir -p "$SW35W/a" "$SW35W/b" || bad "P35 setup: mkdir a b"
git -C "$SW35" worktree add -q -b worktree-agent-awt "$SW35W/a/wt" origin/main 2>/dev/null \
  && git -C "$SW35" worktree add -q -b worktree-agent-bwt "$SW35W/b/wt" origin/main 2>/dev/null \
  && [ -d "$SW35W/a/wt" ] && [ -d "$SW35W/b/wt" ] || bad "P35 setup: worktrees a/wt and b/wt"
echo ua > "$SW35W/a/wt/u.txt" && echo ub > "$SW35W/b/wt/u.txt" \
  && [ -f "$SW35W/a/wt/u.txt" ] && [ -f "$SW35W/b/wt/u.txt" ] || bad "P35 setup: u.txt in a/wt and b/wt"
PLAN_P35=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["hold_plan"] or "")' < <("$TOOL" --repo "$SW35" --json))
[ -n "$PLAN_P35" ] || bad "P35 setup: PLAN_P35"
SYG_WORKTREE_BACKUP_DIR="$T/bk35" "$TOOL" --repo "$SW35" --apply-hold "$PLAN_P35" >/dev/null; rc_p35=$?
shopt -s nullglob
bk35_readmes=("$T/bk35"/*/sweep35--wt--*/README.txt)
shopt -u nullglob
if [ "$rc_p35" -eq 0 ] && [ ! -e "$SW35W/a/wt" ] && [ ! -e "$SW35W/b/wt" ] && [ "${#bk35_readmes[@]}" -eq 2 ]; then
  ok "P35: two approvable trees with basename wt under .claude/worktrees/{a,b}/wt get distinct backup leaves and both are removed"
else
  bad "P35: duplicate tree basename in one repo (rc=$rc_p35, readmes=${#bk35_readmes[@]})"
fi

# P36 text and JSON sweep plan parity on a two-repo fixture.
mk_repo sweep36a && mk_repo sweep36b && [ -d "$T/sweep36a" ] && [ -d "$T/sweep36b" ] || bad "P36 setup: mk_repo sweep36a/b"
SW36A="$T/sweep36a"
SW36B="$T/sweep36b"
add_tree sweep36a wt36a && add_tree sweep36b wt36b \
  && [ -d "$SW36A/.claude/worktrees/wt36a" ] && [ -d "$SW36B/.claude/worktrees/wt36b" ] || bad "P36 setup: add_tree wt36a/b"
echo a36 > "$SW36A/.claude/worktrees/wt36a/u.txt" && echo b36 > "$SW36B/.claude/worktrees/wt36b/u.txt" \
  && [ -f "$SW36A/.claude/worktrees/wt36a/u.txt" ] && [ -f "$SW36B/.claude/worktrees/wt36b/u.txt" ] || bad "P36 setup: u.txt"
out_p36t=$("$TOOL" --repo "$SW36A" --repo "$SW36B"); rc_p36t=$?
J_P36=$("$TOOL" --repo "$SW36A" --repo "$SW36B" --json); rc_p36j=$?
SWEEP_P36_TXT=$(sed -n 's/^sweep plan: \([0-9a-f]\{12\}\)$/\1/p' <<<"$out_p36t")
SWEEP_P36_JSON=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["sweep_plan"] or "")' "$J_P36")
if [ "$rc_p36t" -eq 0 ] && [ "$rc_p36j" -eq 0 ] && [ -n "$SWEEP_P36_TXT" ] && [ "$SWEEP_P36_TXT" = "$SWEEP_P36_JSON" ]; then
  ok "P36: text and JSON dry runs produce identical non-empty sweep plan id ($SWEEP_P36_TXT)"
else
  bad "P36: text vs JSON sweep plan (rc_t=$rc_p36t, rc_j=$rc_p36j, txt='$SWEEP_P36_TXT', json='$SWEEP_P36_JSON')"
fi

# P37 per-worktree ref namespaces beyond refs/worktree/: refs/bisect/* (organic git bisect) and
# refs/rewritten/* (a --rebase-merges label stopped mid-rebase). wt37live keeps BISECT_LOG, so it
# also holds as in-progress and is never approvable; wt37done is back on its branch with BISECT_LOG
# gone, holds as bisect-refs only, and its --apply-hold backup lists the refs and restores the
# commit; wt37rew stops an authored todo (label + break) after the pick, so refs/rewritten/mid-rew
# points at a rebased commit on no branch.
mk_repo sweep37 && [ -d "$T/sweep37" ] || bad "P37 setup: mk_repo sweep37"
SW37="$T/sweep37"
SW37W="$SW37/.claude/worktrees"
add_tree sweep37 wt37live && [ -d "$SW37W/wt37live" ] || bad "P37 setup: add_tree wt37live"
echo live > "$SW37W/wt37live/live.txt" && git -C "$SW37W/wt37live" add live.txt \
  && git -C "$SW37W/wt37live" commit -qm "live era" || bad "P37 setup: wt37live commit"
LIVE37=$(git -C "$SW37W/wt37live" rev-parse HEAD)
git -C "$SW37W/wt37live" reset -q --hard origin/main || bad "P37 setup: wt37live reset"
git -C "$SW37W/wt37live" bisect start >/dev/null 2>&1 \
  && git -C "$SW37W/wt37live" bisect bad "$LIVE37" >/dev/null 2>&1 \
  && git -C "$SW37W/wt37live" bisect good origin/main >/dev/null 2>&1 || bad "P37 setup: wt37live bisect"
[ -n "$(git -C "$SW37W/wt37live" for-each-ref refs/bisect/ 2>/dev/null)" ] \
  && [ -e "$(git -C "$SW37W/wt37live" rev-parse --git-path BISECT_LOG)" ] || bad "P37 setup: wt37live refs/bisect + BISECT_LOG"
add_tree sweep37 wt37done && [ -d "$SW37W/wt37done" ] || bad "P37 setup: add_tree wt37done"
echo bisect-done > "$SW37W/wt37done/done.txt" && git -C "$SW37W/wt37done" add done.txt \
  && git -C "$SW37W/wt37done" commit -qm "done era" || bad "P37 setup: wt37done commit"
DONE37=$(git -C "$SW37W/wt37done" rev-parse HEAD)
git -C "$SW37W/wt37done" reset -q --hard origin/main || bad "P37 setup: wt37done reset"
git -C "$SW37W/wt37done" bisect start >/dev/null 2>&1 \
  && git -C "$SW37W/wt37done" bisect bad "$DONE37" >/dev/null 2>&1 \
  && git -C "$SW37W/wt37done" bisect good origin/main >/dev/null 2>&1 || bad "P37 setup: wt37done bisect"
git -C "$SW37W/wt37done" checkout -q worktree-agent-wt37done >/dev/null 2>&1 \
  && rm -f "$(git -C "$SW37W/wt37done" rev-parse --git-path BISECT_LOG)" \
  && [ -n "$(git -C "$SW37W/wt37done" for-each-ref refs/bisect/ 2>/dev/null)" ] \
  && [ ! -e "$(git -C "$SW37W/wt37done" rev-parse --git-path BISECT_LOG)" ] || bad "P37 setup: wt37done refs/bisect without BISECT_LOG"
add_tree sweep37 wt37rew && [ -d "$SW37W/wt37rew" ] || bad "P37 setup: add_tree wt37rew"
echo rew > "$SW37W/wt37rew/rew.txt" && git -C "$SW37W/wt37rew" add rew.txt \
  && git -C "$SW37W/wt37rew" commit -qm "rew one" || bad "P37 setup: wt37rew commit"
echo m37 > "$SW37/m37.txt" && git -C "$SW37" add m37.txt && git -C "$SW37" commit -qm "main ahead" \
  || bad "P37 setup: main ahead commit"
printf '#!/bin/sh\nawk \x27{print} /^pick /{print "label mid-rew"; print "break"; exit}\x27 "$1" > "$1.new" && mv "$1.new" "$1"\n' > "$T/seqed_p37.sh"
chmod +x "$T/seqed_p37.sh"
GIT_SEQUENCE_EDITOR="$T/seqed_p37.sh" git -C "$SW37W/wt37rew" rebase -i --rebase-merges main >/dev/null 2>&1 \
  && [ -n "$(git -C "$SW37W/wt37rew" for-each-ref refs/rewritten/ 2>/dev/null)" ] \
  || bad "P37 setup: wt37rew rebase stopped with refs/rewritten"
J_P37=$("$TOOL" --repo "$SW37" --json); rc_p37=$?
if [ "$rc_p37" -eq 0 ] && [ "$(verdict "$J_P37" wt37live)" = "HOLD:bisect-refs,in-progress" ] \
  && [ "$(approvable_of "$J_P37" wt37live)" = "False" ]; then
  ok "P37(i): a mid-bisect tree with refs/bisect/bad at an orphan commit is HOLD:bisect-refs,in-progress and not approvable"
else
  bad "P37(i): wt37live (rc=$rc_p37, verdict='$(verdict "$J_P37" wt37live)', approvable=$(approvable_of "$J_P37" wt37live))"
fi
if [ "$(verdict "$J_P37" wt37done)" = "HOLD:bisect-refs" ] && [ "$(approvable_of "$J_P37" wt37done)" = "True" ]; then
  ok "P37(ii): refs/bisect/* with no bisect in progress is HOLD:bisect-refs alone and approvable"
else
  bad "P37(ii): wt37done (verdict='$(verdict "$J_P37" wt37done)', approvable=$(approvable_of "$J_P37" wt37done))"
fi
want_p37d="refs/bisect/* holds commits on neither origin/main nor another branch (2 ref(s) in the namespace, first: refs/bisect/bad)"
got_p37d=$(reason_msg "$J_P37" wt37done)
[ "$got_p37d" = "$want_p37d" ] && ok "P37(ii): bisect-refs reason line: $want_p37d" \
  || bad "P37(ii): bisect-refs reason line: got '$got_p37d', want '$want_p37d'"
v_p37r=$(verdict "$J_P37" wt37rew)
if [ "$v_p37r" = "HOLD:detached-unreferenced,rewritten-refs,in-progress" ] \
  && [ "$(approvable_of "$J_P37" wt37rew)" = "False" ]; then
  ok "P37(iii): a --rebase-merges label at a rebased commit is HOLD with rewritten-refs (shared scan) and not approvable"
else
  bad "P37(iii): wt37rew (verdict='$v_p37r', approvable=$(approvable_of "$J_P37" wt37rew))"
fi
want_p37r="refs/rewritten/* holds commits on neither origin/main nor another branch (2 ref(s) in the namespace, first: refs/rewritten/mid-rew)"
got_p37r=$(python3 -c '
import json, sys
d = json.loads(sys.argv[1])
for t in d["worktrees"]:
    if t["path"].endswith("/" + sys.argv[2]):
        for r in t["reasons"]:
            if r["code"] == sys.argv[3]:
                print(r["detail"])
                break
' "$J_P37" wt37rew rewritten-refs)
[ "$got_p37r" = "$want_p37r" ] && ok "P37(iii): rewritten-refs reason line: $want_p37r" \
  || bad "P37(iii): rewritten-refs reason line: got '$got_p37r', want '$want_p37r'"
PLAN_P37=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["hold_plan"] or "")' <<<"$J_P37")
[ -n "$PLAN_P37" ] || bad "P37 setup: PLAN_P37"
SYG_WORKTREE_BACKUP_DIR="$T/bk37" "$TOOL" --repo "$SW37" --apply-hold "$PLAN_P37" >/dev/null 2>&1; rc_p37a=$?
sha_sw37=$(printf '%s\0%s' "$SW37" "$SW37W/wt37done" | sha256sum | cut -c1-8)
shopt -s nullglob
bk37_dirs=("$T/bk37"/*/"sweep37--wt37done--$sha_sw37")
shopt -u nullglob
BK37=${bk37_dirs[0]:-}
GOOD37=$(sed -n 's/^\([0-9a-f]*\) refs\/bisect\/good-.*$/\1/p' "$BK37/changes.txt" 2>/dev/null)
git clone -q "$T/sweep37-origin.git" "$T/p37-clone" 2>/dev/null && [ -d "$T/p37-clone" ] || bad "P37 setup: clone p37-clone"
if [ "$rc_p37a" -eq 0 ] && [ ! -e "$SW37W/wt37done" ] && [ -f "$BK37/reflog.pack" ] \
  && _pipe_out=$(sed -n '/^=== Per-worktree refs (refs\/worktree\/\*, refs\/bisect\/\*, refs\/rewritten\/\*) ===$/,/^===/p' "$BK37/changes.txt") \
  && grep -qx "$DONE37 refs/bisect/bad" <<<"$_pipe_out" \
  && grep -q "^$GOOD37 refs/bisect/good-" <<<"$_pipe_out" \
  && grep -q '^  # refs/worktree/\*, refs/bisect/\* and refs/rewritten/\* die with the tree; recreate each: git -C .* update-ref <refname> <sha from changes.txt>$' "$BK37/README.txt" \
  && git -C "$T/p37-clone" index-pack --stdin --fix-thin < "$BK37/reflog.pack" >/dev/null 2>&1 \
  && git -C "$T/p37-clone" cat-file -e "$DONE37^{commit}" 2>/dev/null; then
  ok "P37(iv): --apply-hold backs up wt37done, lists both refs/bisect refs in changes.txt, hints update-ref in README.txt, and the bad tip restores into a scratch clone"
else
  bad "P37(iv): bisect backup (rc=$rc_p37a, dir='$BK37', good='$GOOD37')"
fi

# P38 batch-fallback seam: SYG_WORKTREE_STATE_BATCH_FAIL=1 skips tree_state_sha's hash-object
# batch child (batch_ok=false, rc_batch=1), forcing each at-risk file to hash per file; the
# plan id must equal the per-file reference formula (true content, not a vacuous batch) with
# the batch sentinel flipped, and differ from the healthy-batch id of the same tree.
mk_repo sweep38 && [ -d "$T/sweep38" ] || bad "P38 setup: mk_repo sweep38"
SW38="$T/sweep38"
WT38="$SW38/.claude/worktrees/wt38"
add_tree sweep38 wt38 && [ -d "$WT38" ] || bad "P38 setup: add_tree wt38"
echo f1 > "$WT38/u1.txt" && echo f2 > "$WT38/u2.txt" \
  && [ -f "$WT38/u1.txt" ] && [ -f "$WT38/u2.txt" ] || bad "P38 setup: u1.txt u2.txt"
ref_plan_p38() { # $1 = the batch sentinel the tool must fold in ("0:0" healthy, "1:1" seam)
  local p h rc38 state head reasons
  state=$(
    {
      printf '\001atrisk=%s\0' 0
      git -C "$WT38" status --porcelain=v1 -z --ignored --untracked-files=all; rc38=$?
      printf '\001status=%s\0' "$rc38"
      git -C "$WT38" diff --binary HEAD; rc38=$?
      printf '\001diff=%s\0' "$rc38"
      git -C "$WT38" diff --binary --cached HEAD; rc38=$?
      printf '\001diffcached=%s\0' "$rc38"
      printf '\001batch=%s\0' "$1"
      for p in u1.txt u2.txt; do
        rc38=0
        h=$(git -C "$WT38" hash-object --no-filters -- "$p") || rc38=$?
        printf '%s\0%s\0' "$p" "${h:-}"
        printf '\001hash=%s\0' "$rc38"
      done
      git -C "$WT38" for-each-ref --format='%(objectname) %(refname)' refs/worktree/ refs/bisect/ refs/rewritten/; rc38=$?
      printf '\001foreachref=%s\0' "$rc38"
    } | sha256sum | cut -d' ' -f1
  )
  head=$(git -C "$WT38" rev-parse HEAD)
  reasons=$(printf '%s\n' \
    $'untracked-new\tu1.txt is untracked and not on origin/main' \
    $'untracked-new\tu2.txt is untracked and not on origin/main' \
    | LC_ALL=C sort)
  printf '%s\0%s\0%s\0%s\0%s\0' "$WT38" "worktree-agent-wt38" "$head" "$reasons" "$state" | sha256sum | cut -c1-12
}
PLAN_P38_SEAM=$(SYG_WORKTREE_STATE_BATCH_FAIL=1 "$TOOL" --repo "$SW38" --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["hold_plan"] or "")')
PLAN_P38_NORM=$("$TOOL" --repo "$SW38" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["hold_plan"] or "")')
if [ -n "$PLAN_P38_SEAM" ] && [ "$PLAN_P38_SEAM" = "$(ref_plan_p38 '1:1')" ] \
  && [ -n "$PLAN_P38_NORM" ] && [ "$PLAN_P38_NORM" = "$(ref_plan_p38 '0:0')" ] \
  && [ "$PLAN_P38_SEAM" != "$PLAN_P38_NORM" ]; then
  ok "P38: with the batch failed, the hold plan still matches the per-file formula (batch=1:1) and differs from the healthy-batch id ($PLAN_P38_NORM)"
else
  bad "P38: batch fallback (seam='$PLAN_P38_SEAM' want '$(ref_plan_p38 '1:1')', norm='$PLAN_P38_NORM' want '$(ref_plan_p38 '0:0')')"
fi

# P38b real-failure family: a fake git first on PATH proxies every call to real git, but for
# the one tree_state_sha call shape baked into SHIM38B_MATCH it emits the real output
# byte-for-byte and exits 42 — so the poisoned run's stream differs from the healthy one ONLY
# by the folded child rc (status / diff / diff --cached / for-each-ref / batch hash-object),
# or, for the per-file hash-object shape, by the rc plus the emptied hash that rc forces.
# Each variant's hold plan id must differ from the same tree's healthy id; the two hash-object
# variants exercise the real `else rc_batch=$?` / per-file failure branches (P38 above pins
# only the seam's skipping). Red-check: a tree_state_sha that dropped child rcs hashes the
# poisoned streams identically for the status/diff/diff --cached/for-each-ref variants, so
# their checks fail — the batch hash-object variant still differs on such a mutant, but via
# the batch_ok flip (a failed batch child zeroes the \001batch=<rc>:<0|1> ok bit and forces
# the per-file fallback), not via the rc in its own sentinel; the per-file variant is pinned
# by its rc-faithful formula below, which the mutant also misses.
mk_repo sweep38b && [ -d "$T/sweep38b" ] || bad "P38b setup: mk_repo sweep38b"
SW38B="$T/sweep38b"
WT38B="$SW38B/.claude/worktrees/wt38b"
add_tree sweep38b wt38b && [ -d "$WT38B" ] || bad "P38b setup: add_tree wt38b"
echo f1 > "$WT38B/u1.txt" && echo f2 > "$WT38B/u2.txt" \
  && echo nl > "$WT38B/"$'u\nnl.txt' \
  && [ -f "$WT38B/u1.txt" ] && [ -f "$WT38B/u2.txt" ] && [ -f "$WT38B/"$'u\nnl.txt' ] \
  || bad "P38b setup: untracked files (2 batchable, 1 newline-named)"
REAL_GIT=$(command -v git)
[ -n "$REAL_GIT" ] || bad "P38b setup: command -v git"
mkdir -p "$T/shim38b"
cat > "$T/shim38b/git" <<EOF
#!/bin/sh
# P38b: proxy to real git; for the one tree_state_sha call shape matched by
# SHIM38B_MATCH, emit the real output byte-for-byte and exit 42.
real='$REAL_GIT'
case " \$* " in
  *"\$SHIM38B_MATCH"*) ;;
  *) exec "\$real" "\$@" ;;
esac
tmp=\$(mktemp) || exit 1
"\$real" "\$@" >"\$tmp" 2>/dev/null
cat "\$tmp"
rm -f "\$tmp"
exit 42
EOF
chmod +x "$T/shim38b/git"
fail_plan() { # $1 = match fragment -> that poisoned run's hold plan id
  SHIM38B_MATCH=$1 PATH="$T/shim38b:$PATH" "$TOOL" --repo "$SW38B" --json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["hold_plan"] or "")'
}
PLAN_38B_OK=$("$TOOL" --repo "$SW38B" --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["hold_plan"] or "")')
[ -n "$PLAN_38B_OK" ] || bad "P38b setup: healthy hold plan id"
check38b() { # $1 label, $2 match fragment: the poisoned plan must differ from the healthy id
  local plan
  plan=$(fail_plan "$2")
  if [ -n "$plan" ] && [ "$plan" != "$PLAN_38B_OK" ]; then
    ok "P38b: $1 child failing (rc 42, real output intact) changes the hold plan id"
  else
    bad "P38b: $1 (plan='$plan', healthy='$PLAN_38B_OK')"
  fi
}
# the fragments match tree_state_sha's call shapes, never the judge's (status: --ignored
# bare vs the judge's --no-renames --ignored=matching; diff: --binary vs --name-only;
# for-each-ref: the two-field format vs the judge's three-field one). NOT unique by shape
# alone, though: regen_verdict's `hash-object --no-filters --` call and backup_tree's
# `diff --binary HEAD` / two-field for-each-ref are byte-identical to tree_state_sha's.
# Uniqueness today rests on --json never invoking backup_tree (an apply-path function) and
# sweep38b holding no regenerable or ignored entries (so regen_verdict never runs) — a
# fixture edit adding either must re-check every fragment here.
check38b 'git status'                     ' status --porcelain=v1 -z --ignored '
check38b 'git diff'                       ' diff --binary HEAD '
check38b 'git diff --cached'              ' diff --binary --cached HEAD '
check38b 'git for-each-ref'               'for-each-ref --format=%(objectname) %(refname) refs/worktree/'
check38b 'batch hash-object --stdin-paths' ' hash-object --no-filters --stdin-paths'

# the per-file shape empties the hash on its nonzero rc, so this variant also pins the exact
# rc-faithful stream: the newline-named file's hash is empty and its hash sentinel is 42
plan_38b_pf=$(fail_plan ' hash-object --no-filters -- ')
ref_state_38b_pf=$(
  {
    printf '\001atrisk=%s\0' 0
    git -C "$WT38B" status --porcelain=v1 -z --ignored --untracked-files=all; rc38b=$?
    printf '\001status=%s\0' "$rc38b"
    git -C "$WT38B" diff --binary HEAD; rc38b=$?
    printf '\001diff=%s\0' "$rc38b"
    git -C "$WT38B" diff --binary --cached HEAD; rc38b=$?
    printf '\001diffcached=%s\0' "$rc38b"
    printf '\001batch=%s\0' "0:0"  # u1.txt and u2.txt still batch healthy
    for p38b in $'u\nnl.txt' u1.txt u2.txt; do
      rc38b=0
      if [ "$p38b" = $'u\nnl.txt' ]; then
        h38b=""; rc38b=42
      else
        h38b=$(git -C "$WT38B" hash-object --no-filters -- "$p38b") || rc38b=$?
      fi
      printf '%s\0%s\0' "$p38b" "${h38b:-}"
      printf '\001hash=%s\0' "$rc38b"
    done
    git -C "$WT38B" for-each-ref --format='%(objectname) %(refname)' refs/worktree/ refs/bisect/ refs/rewritten/; rc38b=$?
    printf '\001foreachref=%s\0' "$rc38b"
  } | sha256sum | cut -d' ' -f1
)
head38b=$(git -C "$WT38B" rev-parse HEAD)
reasons38b=$(printf '%s\n' \
  $'untracked-new\tu\nnl.txt is untracked and not on origin/main' \
  $'untracked-new\tu1.txt is untracked and not on origin/main' \
  $'untracked-new\tu2.txt is untracked and not on origin/main' \
  | LC_ALL=C sort)
ref_plan_38b_pf=$(printf '%s\0%s\0%s\0%s\0%s\0' "$WT38B" "worktree-agent-wt38b" "$head38b" "$reasons38b" "$ref_state_38b_pf" | sha256sum | cut -c1-12)
if [ -n "$plan_38b_pf" ] && [ "$plan_38b_pf" != "$PLAN_38B_OK" ] && [ "$plan_38b_pf" = "$ref_plan_38b_pf" ]; then
  ok "P38b: per-file hash-object failing (rc 42, hash emptied) changes the plan id and matches the rc-faithful formula"
else
  bad "P38b: per-file hash-object (plan='$plan_38b_pf', formula='$ref_plan_38b_pf', healthy='$PLAN_38B_OK')"
fi

# P39 refs/bisect non-commit tip (shape follows P31(iv)/(v), for the bisect namespace): a ref
# at a blob under refs/bisect/ HOLDs as bisect-refs-object — pinning the $ns-refs-object
# interpolation — names the object type, and the tree is never approvable (the backup packs
# commits only).
mk_repo sweep39 && [ -d "$T/sweep39" ] || bad "P39 setup: mk_repo sweep39"
SW39="$T/sweep39"
WT39="$SW39/.claude/worktrees/wt39blob"
add_tree sweep39 wt39blob && [ -d "$WT39" ] || bad "P39 setup: add_tree wt39blob"
blob_39=$(printf 'bisect blob payload\n' | git -C "$WT39" hash-object -w --stdin 2>/dev/null)
[ -n "$blob_39" ] && git -C "$WT39" update-ref refs/bisect/blobref "$blob_39" || bad "P39 setup: hash-object -w + update-ref refs/bisect/blobref"
[ "$(git -C "$WT39" for-each-ref --format='%(objecttype)' refs/bisect/blobref 2>/dev/null)" = blob ] || bad "P39 setup: blobref is not a blob"
J_P39=$("$TOOL" --repo "$SW39" --json); rc_p39=$?
want_p39="refs/bisect/blobref points at a blob; back it up by hand before removing the tree"
if [ "$rc_p39" -eq 0 ] && [ "$(verdict "$J_P39" wt39blob)" = "HOLD:bisect-refs-object" ] \
  && [ "$(approvable_of "$J_P39" wt39blob)" = "False" ] \
  && [ "$(reason_msg "$J_P39" wt39blob)" = "$want_p39" ]; then
  ok "P39: refs/bisect/blobref at a blob is HOLD:bisect-refs-object, names the object type ('points at a blob'), not approvable"
else
  bad "P39: bisect blob ref (rc=$rc_p39, verdict='$(verdict "$J_P39" wt39blob)', approvable='$(approvable_of "$J_P39" wt39blob)', reason='$(reason_msg "$J_P39" wt39blob)')"
fi

exit $fail
