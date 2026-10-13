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
