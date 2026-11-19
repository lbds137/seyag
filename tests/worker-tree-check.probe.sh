#!/usr/bin/env bash
# Probe for bin/worker-tree-check: a repointed gitfile runs a crafted core.fsmonitor on the host at
# git status, and the check must refuse the tree before that happens.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
C="$REPO/plugins/seyag/bin/worker-tree-check"
T=$(realpath "$(mktemp -d)"); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $*"; }
expect() { # WANT_RC NAME CMD...
  local want=$1 name=$2; shift 2
  local out rc; out=$("$@" 2>&1); rc=$?
  [ "$rc" = "$want" ] && ok || bad "$name: rc $rc, want $want: $out"
}
# Honest fixtures sit under $T (in /tmp), so the fixture's stand-in for "a directory a worker can
# write" is one directory inside it: crafted gitdirs go there. One case runs the real default below.
export SYG_WORKER_TREE_CHECK_UNTRUSTED=$T/evilroot

git init -q "$T/main"; git -C "$T/main" config user.email p@e; git -C "$T/main" config user.name p
echo x >"$T/main/f"; git -C "$T/main" add f; git -C "$T/main" commit -qm one
newtree() { git -C "$T/main" worktree add -q "$T/$1" -b "$1"; }
# A crafted gitdir shaped like a worktrees/ entry with forged back-pointers: everything a check that
# trusts the gitfile's own answer would accept. Its config runs the payload as core.fsmonitor.
craft() { # NAME TREE -> prints the entry path; the common dir goes under $1
  local e=$1 tree=$2
  mkdir -p "$e/worktrees/x"
  cp -a "$T/main/.git/objects" "$T/main/.git/refs" "$T/main/.git/HEAD" "$e/"
  printf '[core]\n\trepositoryformatversion = 0\n\tfsmonitor = %s\n' "$T/payload" >"$e/config"
  echo "ref: refs/heads/$(basename "$tree")" >"$e/worktrees/x/HEAD"
  echo ../.. >"$e/worktrees/x/commondir"
  echo "$tree/.git" >"$e/worktrees/x/gitdir"
  echo "$e/worktrees/x"
}
printf '#!/bin/sh\n: >"%s/PWNED"\nexit 1\n' "$T" >"$T/payload"; chmod +x "$T/payload"

newtree good
expect 0 "an untouched linked worktree passes" "$C" "$T/good"
expect 0 "with --linked and the right --repo" "$C" --linked --repo "$T/main" "$T/good"
mkdir -p "$T/good/a/b"
expect 0 "from a subdirectory" "$C" "$T/good/a/b"
expect 0 "a main checkout passes" "$C" "$T/main"
expect 1 "--linked refuses a real .git directory" "$C" --linked "$T/main"
mkdir "$T/norepo"
expect 0 "no .git above: nothing for git to read" "$C" "$T/norepo"
expect 1 "--linked with no .git above" "$C" --linked "$T/norepo"
expect 1 "--repo with no .git above" "$C" --repo "$T/main" "$T/norepo"
expect 2 "a missing directory is a usage error" "$C" "$T/nope"
expect 2 "an unknown flag is a usage error" "$C" --nope "$T/good"
expect 1 "--repo names another repo" "$C" --repo "$T/norepo" "$T/good"

# The attack itself. First the positive control: this fixture really does run the payload through
# git status, so a refusal below is refusing something real.
newtree evil
craft "$T/evilroot/evilcommon" "$T/evil" >"$T/entry"
echo "gitdir: $(cat "$T/entry")" >"$T/evil/.git"
git -C "$T/evil" status --short >/dev/null 2>&1
[ -e "$T/PWNED" ] && ok || bad "control: the crafted gitdir did not run the payload through git status"
rm -f "$T/PWNED"
# Forged back-pointers pass everything but the anchors, which is the point of having two.
expect 1 "--repo refuses the crafted gitdir" "$C" --repo "$T/main" "$T/evil"
expect 1 "the location rule refuses it" "$C" "$T/evil"
expect 1 "and so does the real default, this fixture being under /tmp" env -u SYG_WORKER_TREE_CHECK_UNTRUSTED "$C" "$T/evil"
# Only the SYG_ name is read: the control shows /var/tmp-only distrust lets this /tmp fixture through,
# and the old unprefixed name set the same way changes nothing (default /tmp distrust still refuses)
expect 0 "control: SYG_WORKER_TREE_CHECK_UNTRUSTED=/var/tmp trusts a /tmp fixture" env SYG_WORKER_TREE_CHECK_UNTRUSTED=/var/tmp "$C" "$T/good"
expect 1 "the old WORKER_TREE_CHECK_UNTRUSTED name is not read" env -u SYG_WORKER_TREE_CHECK_UNTRUSTED WORKER_TREE_CHECK_UNTRUSTED=/var/tmp "$C" "$T/good"
expect 1 "SYG_WORKER_TREE_CHECK_UNTRUSTED=/ distrusts every path" env SYG_WORKER_TREE_CHECK_UNTRUSTED=/ "$C" "$T/good"
git -C "$T/main" worktree repair "$T/evil" >/dev/null 2>&1
expect 0 "the repair line the refusal names restores it" "$C" --repo "$T/main" "$T/evil"

# Each shape a worker can leave behind
newtree bad
reset_bad() { git -C "$T/main" worktree repair "$T/bad" >/dev/null 2>&1; rm -rf "$T/bad/.git.d"; }
real=$(cat "$T/bad/.git")
echo "gitdir: $T/good/../main/.git/worktrees/good" >"$T/bad/.git"
expect 1 "another worktree's entry (back-pointer)" "$C" "$T/bad"
reset_bad
printf '%s\n%s\n' "$real" "$real" >"$T/bad/.git"
expect 1 "two lines" "$C" "$T/bad"
reset_bad
entry=${real#gitdir: }
printf 'gitdir: %s\njunk' "$entry" >"$T/bad/.git"
expect 1 "two lines with no final newline" "$C" "$T/bad"
reset_bad
echo "not a gitfile" >"$T/bad/.git"
expect 1 "no gitdir line" "$C" "$T/bad"
reset_bad
: >"$T/bad/.git"
expect 1 "an empty file" "$C" "$T/bad"
reset_bad
echo "gitdir: $T/no/such/dir" >"$T/bad/.git"
expect 1 "a gitdir that does not exist" "$C" "$T/bad"
reset_bad
mkdir -p "$T/bad/.inner/worktrees/x"
echo ../.. >"$T/bad/.inner/worktrees/x/commondir"
echo "$T/bad/.git" >"$T/bad/.inner/worktrees/x/gitdir"
echo "gitdir: $T/bad/.inner/worktrees/x" >"$T/bad/.git"
expect 1 "a gitdir inside the tree" "$C" "$T/bad"
rm -rf "$T/bad/.inner"; reset_bad
ln -s "$(sed 's/^gitdir: //' "$T/bad/.git")" "$T/gitdir-link"
echo "gitdir: $T/gitdir-link" >"$T/bad/.git"
expect 1 "a symlinked gitdir" "$C" "$T/bad"
reset_bad
link=$T/gitdir-link
echo "gitdir: $link/" >"$T/bad/.git"
expect 1 "a symlinked gitdir with a trailing slash" "$C" "$T/bad"
reset_bad
echo "gitdir: $link/." >"$T/bad/.git"
expect 1 "a symlinked gitdir ending in /." "$C" "$T/bad"
reset_bad
cp "$T/bad/.git" "$T/saved"; rm -f "$T/bad/.git"; ln -s "$T/saved" "$T/bad/.git"
expect 1 "a symlinked .git" "$C" "$T/bad"
rm -f "$T/bad/.git"; cp "$T/saved" "$T/bad/.git"
rm -f "$T/bad/.git"; mkdir "$T/bad/.git"
expect 1 "--linked refuses a .git directory in a sibling tree" "$C" --linked "$T/bad"
rmdir "$T/bad/.git"; cp "$T/saved" "$T/bad/.git"
expect 0 "restored" "$C" --linked "$T/bad"
newtree swapdir; rm -f "$T/swapdir/.git"; git init -q "$T/swapdir"
git -C "$T/swapdir" config core.fsmonitor "$T/payload"; rm -f "$T/PWNED"
expect 1 "--repo refuses a sibling tree whose .git was swapped for a repo dir" "$C" --repo "$T/main" "$T/swapdir"
[ ! -e "$T/PWNED" ] && ok || bad "the check itself ran swapdir's fsmonitor"
git -C "$T/swapdir" status --short >/dev/null 2>&1
[ -e "$T/PWNED" ] && ok || bad "control: git status in swapdir did not run the payload"
rm -f "$T/PWNED"
expect 1 "--repo refuses a main checkout other than MAIN_TOP" "$C" --repo "$T/norepo" "$T/main"
# Where a dispatcher puts trees: under the main checkout, so the registry above can name them.
git -C "$T/main" worktree add -q "$T/main/.claude/worktrees/nested" -b nested
N=$T/main/.claude/worktrees/nested
expect 0 "a nested tree passes" "$C" "$N"
cp "$N/.git" "$T/saved"; rm -f "$N/.git"; mkdir "$N/.git"
expect 1 "a registered tree's .git swapped for a directory, without --linked" "$C" "$N"
rmdir "$N/.git"; cp "$T/saved" "$N/.git"
rm -f "$N/.git"
expect 1 "a registered tree whose .git file is deleted and nothing planted, without flags" "$C" "$N"
cp "$T/saved" "$N/.git"
echo garbage >"$T/main/.git/worktrees/good/gitdir.bak"
: >"$T/main/.git/worktrees/good/gitdir.orig"
mkdir -p "$T/main/.git/worktrees/broken"; ln -s /nonexistent "$T/main/.git/worktrees/broken/gitdir"
out=$("$C" "$T/main" 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "another entry's bad pointer must stay silent: rc $rc: $out"
rm -rf "$T/main/.git/worktrees/broken" "$T/main/.git/worktrees/good/gitdir.bak" "$T/main/.git/worktrees/good/gitdir.orig"

# A NUL: bash's read drops it while git stops at it, so the check would judge the real entry's path
# and git would read the crafted gitdir before the NUL. The control proves git does that here.
newtree nul
craft "$T/nulcommon" "$T/nul" >"$T/entry"
printf 'gitdir: %s\0/../../../main/.git/worktrees/nul\n' "$(cat "$T/entry")" >"$T/nul/.git"
rm -f "$T/PWNED"
git -C "$T/nul" status --short >/dev/null 2>&1
[ -e "$T/PWNED" ] && ok || bad "control: git did not follow the gitfile up to the NUL"
rm -f "$T/PWNED"
expect 1 "a NUL in the gitfile" "$C" --linked --repo "$T/main" "$T/nul"
git -C "$T/main" worktree repair "$T/nul" >/dev/null 2>&1
printf '%s\0/../main/.git\n' "$T/nulcommon" >"$T/main/.git/worktrees/nul/commondir"
out=$("$C" --linked --repo "$T/main" "$T/nul" 2>&1); rc=$?
[ "$rc" = 1 ] && [[ $out == *"the entry's commondir holds a NUL byte"* ]] && ok || bad "T1 NUL in the entry's commondir: rc $rc: $out"
echo ../.. >"$T/main/.git/worktrees/nul/commondir"
printf '%s\0/../nul/.git\n' "$T/nowhere" >"$T/main/.git/worktrees/nul/gitdir"
out=$("$C" --linked --repo "$T/main" "$T/nul" 2>&1); rc=$?
[ "$rc" = 1 ] && [[ $out == *"the entry's gitdir holds a NUL byte"* ]] && ok || bad "T2 NUL in the entry's gitdir: rc $rc: $out"
git -C "$T/main" worktree repair "$T/nul" >/dev/null 2>&1
# mode-000 cases mean nothing to root, who reads through them
if [ "$(id -u)" != 0 ]; then
chmod 000 "$T/main/.git/worktrees/nul/gitdir"
out=$("$C" --linked --repo "$T/main" "$T/nul" 2>&1); rc=$?
chmod 644 "$T/main/.git/worktrees/nul/gitdir"
[ "$rc" = 1 ] && [[ $out == *"the entry's gitdir is unreadable"* ]] && ok || bad "T3 unreadable entry gitdir: rc $rc: $out"
chmod 000 "$T/main/.git/worktrees/nul/commondir"
out=$("$C" --linked --repo "$T/main" "$T/nul" 2>&1); rc=$?
chmod 644 "$T/main/.git/worktrees/nul/commondir"
[ "$rc" = 1 ] && [[ $out == *"the entry's commondir is unreadable"* ]] && ok || bad "T3b unreadable entry commondir: rc $rc: $out"
fi
{ printf '.'; head -c 4969 /dev/zero | tr '\0' /; printf '../../nulcommon\0/../main/.git\n'; } >"$T/main/.git/worktrees/nul/commondir"
out=$("$C" --linked --repo "$T/main" "$T/nul" 2>&1); rc=$?
echo ../.. >"$T/main/.git/worktrees/nul/commondir"
[ "$rc" = 1 ] && [[ $out == *"the entry's commondir is over 4096 bytes"* ]] && ok || bad "T4 oversized entry commondir with late NUL: rc $rc: $out"
# Each back-pointer alone, in a gitdir outside the location rule's reach: only that pointer can refuse
newtree ptr
mkdir -p "$T/ptrcommon/worktrees/x"
echo "gitdir: $T/ptrcommon/worktrees/x" >"$T/ptr/.git"
echo "$T/ptr/.git" >"$T/ptrcommon/worktrees/x/gitdir"; echo /elsewhere >"$T/ptrcommon/worktrees/x/commondir"
expect 1 "only commondir is wrong" "$C" "$T/ptr"
echo ../.. >"$T/ptrcommon/worktrees/x/commondir"; echo "$T/good/.git" >"$T/ptrcommon/worktrees/x/gitdir"
expect 1 "only the entry's gitdir is wrong" "$C" "$T/ptr"
git -C "$T/main" worktree repair "$T/ptr" >/dev/null 2>&1
{ printf 'gitdir: '; head -c 5000 /dev/zero | tr '\0' a; echo; } >"$T/ptr/.git"
expect 1 "an oversized gitfile" "$C" "$T/ptr"
git -C "$T/main" worktree repair "$T/ptr" >/dev/null 2>&1
echo "gitdir: ../main/.git/worktrees/ptr" >"$T/ptr/.git"
expect 0 "a relative gitdir resolves from the tree" "$C" --linked --repo "$T/main" "$T/ptr"

# A nested repo: the pointer is sound, and git recurses into what sits below it. Each row names how
# it got there, because each one reaches git differently.
plant() { # DIR: a real repo with one commit, whose config runs the payload as core.fsmonitor
  git init -q "$1"; git -C "$1" config user.email p@e; git -C "$1" config user.name p
  echo y >"$1/y"; git -C "$1" add y; git -C "$1" commit -qm one
  git -C "$1" config core.fsmonitor "$T/payload"
}
newtree sub1; plant "$T/sub1/sub"; git -C "$T/sub1" add sub 2>/dev/null; rm -f "$T/PWNED"
expect 1 "a nested repo staged as a gitlink" "$C" "$T/sub1"
[ ! -e "$T/PWNED" ] && ok || bad "the check itself ran the nested fsmonitor"
expect 1 "and with --linked --repo" "$C" --linked --repo "$T/main" "$T/sub1"
git -C "$T/sub1" status --short >/dev/null 2>&1
[ -e "$T/PWNED" ] && ok || bad "control: git status did not recurse into the staged gitlink"
newtree sub2; plant "$T/sub2/a/b/sub"; rm -f "$T/PWNED"
expect 1 "an untracked nested repo, deep" "$C" "$T/sub2"
git -C "$T/sub2" add -A 2>/dev/null; git -C "$T/sub2" status --short >/dev/null 2>&1
[ -e "$T/PWNED" ] && ok || bad "control: an untracked nested repo did not reach the payload through add -A then status"
newtree sub3; echo 'sub/' >"$T/sub3/.gitignore"; plant "$T/sub3/sub"
expect 1 "a nested repo the tree ignores" "$C" "$T/sub3"
newtree sub4; mkdir "$T/sub4/sub"; echo "gitdir: $T/evilroot/evilcommon" >"$T/sub4/sub/.git"
expect 1 "a nested gitfile" "$C" "$T/sub4"
newtree sub5; mkdir "$T/sub5/sub"; ln -s "$T/evilroot/evilcommon" "$T/sub5/sub/.git"
expect 1 "a nested .git symlink" "$C" "$T/sub5"
newtree sub6; plant "$T/sub6/sub"
expect 1 "DIR inside the nested repo, which a walk up alone would pass" "$C" "$T/sub6/sub"
newtree sub7; mkdir -p "$T/sub7/locked/x"; chmod 000 "$T/sub7/locked"
expect 1 "a directory the check can't read" "$C" "$T/sub7"
chmod 755 "$T/sub7/locked"
expect 0 "the same tree once it can be read" "$C" "$T/sub7"
rm -rf "$T/sub1/sub"; git -C "$T/sub1" rm -q --cached sub 2>/dev/null
expect 0 "the tree passes again with the repo gone" "$C" --linked --repo "$T/main" "$T/sub1"
# A gitdir with no .git name: discovery finds it from inside, and core.worktree claims the real tree
newtree gd; git init -q --bare "$T/gd/gd"
git -C "$T/gd/gd" config core.bare false; git -C "$T/gd/gd" config core.worktree "$T/gd"
git -C "$T/gd/gd" config core.fsmonitor "$T/payload"; mkdir "$T/gd/gd/deep"; rm -f "$T/PWNED"
expect 1 "DIR is a planted gitdir" "$C" --linked --repo "$T/main" "$T/gd/gd"
expect 1 "DIR is below one" "$C" "$T/gd/gd/deep"
[ ! -e "$T/PWNED" ] && ok || bad "the check itself ran the planted gitdir's fsmonitor"
( cd "$T/gd/gd" && git status --short >/dev/null 2>&1 )
[ -e "$T/PWNED" ] && ok || bad "control: git status from inside the planted gitdir did not run the payload"
# The same with no local objects: they come from a commondir, whose config runs the payload
newtree gd3; git init -q --bare "$T/gd3c"; git -C "$T/gd3c" config core.repositoryformatversion 1
git -C "$T/gd3c" config extensions.worktreeConfig true; git -C "$T/gd3c" config core.fsmonitor "$T/payload"
mkdir "$T/gd3/cd"; cp "$T/gd3c/HEAD" "$T/gd3/cd/HEAD"; echo "$T/gd3c" >"$T/gd3/cd/commondir"
printf '[core]\n\tbare = false\n\tworktree = %s\n' "$T/gd3" >"$T/gd3/cd/config.worktree"; rm -f "$T/PWNED"
expect 1 "DIR is a gitdir borrowing a commondir's objects" "$C" --linked --repo "$T/main" "$T/gd3/cd"
( cd "$T/gd3/cd" && git status --short >/dev/null 2>&1 )
[ -e "$T/PWNED" ] && ok || bad "control: the commondir gitdir did not run the payload"
# The same with HEAD a dangling symlink: git accepts it, and -e alone reads it as absent
newtree gd4; mkdir -p "$T/gd4/s/objects" "$T/gd4/s/refs"; ln -s refs/heads/master "$T/gd4/s/HEAD"
printf '[core]\n\trepositoryformatversion = 0\n\tbare = false\n\tworktree = %s\n\tfsmonitor = %s\n' "$T/gd4" "$T/payload" >"$T/gd4/s/config"; rm -f "$T/PWNED"
expect 1 "DIR is a gitdir whose HEAD is a dangling symlink" "$C" --linked --repo "$T/main" "$T/gd4/s"
( cd "$T/gd4/s" && git status --short >/dev/null 2>&1 )
[ -e "$T/PWNED" ] && ok || bad "control: the dangling-HEAD gitdir did not run the payload"
newtree gd2; mkdir -p "$T/gd2/objects/x"; echo y >"$T/gd2/HEAD"
expect 0 "a HEAD at the top is the tree's own file, not a planted subdirectory" "$C" "$T/gd2/objects/x"
expect 0 "a main checkout's own gitdir is not judged: a launcher's own check names that case" "$C" "$T/main/.git"
newtree rmgit; rm -f "$T/rmgit/.git"; git init -q --bare "$T/rmgit"
git -C "$T/rmgit" config core.bare false; git -C "$T/rmgit" config core.worktree "$T/rmgit"
git -C "$T/rmgit" config core.fsmonitor "$T/payload"; rm -f "$T/PWNED"
expect 1 "a sibling tree with .git deleted and a bare gitdir planted (--linked --repo): no .git above it" "$C" --linked --repo "$T/main" "$T/rmgit"
expect 1 "a sibling tree with .git deleted and a bare gitdir planted (no flags)" "$C" "$T/rmgit"
[ ! -e "$T/PWNED" ] && ok || bad "the check itself ran rmgit's fsmonitor"
git -C "$T/rmgit" status --short >/dev/null 2>&1
[ -e "$T/PWNED" ] && ok || bad "control: git status in rmgit did not run the payload"
git -C "$T/main" worktree add -q "$T/main/.claude/worktrees/n2" -b n2
N2=$T/main/.claude/worktrees/n2
rm -f "$N2/.git"; git init -q --bare "$N2"
git -C "$N2" config core.bare false; git -C "$N2" config core.worktree "$N2"
git -C "$N2" config core.fsmonitor "$T/payload"; rm -f "$T/PWNED"
expect 1 "a nested tree with .git deleted and a bare gitdir planted (--repo): the registry still names it" "$C" --repo "$T/main" "$N2"
expect 1 "a nested tree with .git deleted and a bare gitdir planted (no flags): the registry still names it" "$C" "$N2"
[ ! -e "$T/PWNED" ] && ok || bad "the check itself ran n2's fsmonitor"
git -C "$N2" status --short >/dev/null 2>&1
[ -e "$T/PWNED" ] && ok || bad "control: git status in n2 did not run the payload"
rm -rf "$N2" "$T/main/.git/worktrees/n2"
# The --repo HEAD walk alone: a gitdir planted in a main-checkout subdirectory no registry names
git init -q --bare "$T/main/plain"
git -C "$T/main/plain" config core.bare false; git -C "$T/main/plain" config core.worktree "$T/main/plain"
git -C "$T/main/plain" config core.fsmonitor "$T/payload"; rm -f "$T/PWNED"
expect 1 "--repo: a HEAD planted below a main checkout" "$C" --repo "$T/main" "$T/main/plain"
expect 0 "without --repo a main checkout is not scanned (documented scope)" "$C" "$T/main/plain"
[ ! -e "$T/PWNED" ] && ok || bad "the check itself ran plain's fsmonitor"
git -C "$T/main/plain" status --short >/dev/null 2>&1
[ -e "$T/PWNED" ] && ok || bad "control: git status in plain did not run the payload"
rm -f "$T/PWNED"; rm -rf "$T/main/plain"
git init -q --bare "$T/bareout"
git -C "$T/bareout" config core.bare false; git -C "$T/bareout" config core.worktree "$T/bareout"
git -C "$T/bareout" config core.fsmonitor "$T/payload"; rm -f "$T/PWNED"
expect 1 "no .git above, with a bare gitdir planted at DIR" "$C" "$T/bareout"
[ ! -e "$T/PWNED" ] && ok || bad "the check itself ran bareout's fsmonitor"
git -C "$T/bareout" status --short >/dev/null 2>&1
[ -e "$T/PWNED" ] && ok || bad "control: git status in bareout did not run the payload"
rm -f "$T/PWNED"

# False-positive guards: both of these exist on the machine this runs on
plant "$T/main/vendored"
expect 0 "a main checkout may hold a nested repo" "$C" "$T/main"
expect 0 "and that repo passes from inside" "$C" "$T/main/vendored"
newtree sub8
expect 0 "a linked tree beside it is unaffected" "$C" "$T/sub8"
rm -rf "$T/main/vendored"
echo 'not a repo' >"$T/sub8/.gitkeep"; mkdir "$T/sub8/.github"; echo x >"$T/sub8/.github/.gitkeep"
expect 0 "names that only start with .git" "$C" "$T/sub8"

echo "worker-tree-check.probe: $pass passed, $fail failed"
[ "$fail" = 0 ]
