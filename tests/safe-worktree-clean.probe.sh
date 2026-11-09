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
git -C "$B1W/pytestcache" status --porcelain=v1 --ignored=matching --untracked-files=all \
  | grep -qx '!! \.pytest_cache/README\.md' \
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
out=$("$TOOL" --repo "$O" --only "$O/.claude/worktrees/tree2" --only "$O/.claude/worktrees/tree3"); rc=$?
if [ "$rc" -eq 0 ] \
  && grep -q '^SAFE  \.claude/worktrees/tree2  \[worktree-agent-tree2\]$' <<<"$out" \
  && grep -q '^SAFE  \.claude/worktrees/tree3  \[worktree-agent-tree3\]$' <<<"$out"; then
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
"$TOOL" --help | grep -q 'safe-worktree-clean \[--apply\] \[--repo DIR\]' && ok "--help prints usage" || bad "--help"
"$TOOL" --bogus >/dev/null 2>&1; [ $? = 2 ] && ok "unknown argument exits 2" || bad "unknown argument"
"$TOOL" --repo "$T" >/dev/null 2>&1; [ $? = 2 ] && ok "a non-repo --repo exits 2" || bad "non-repo"
python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["base"]=="origin/main" and "locks" in d' \
  < <("$TOOL" --repo "$L" --json --locks) && ok "--json carries base and locks" || bad "--json shape"
exit $fail
