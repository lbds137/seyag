#!/bin/bash
# Fixture check for plugins/seyag/bin/worktree-gitfile-check: valid linked
# worktrees (with and without trailing newline, and with relative paths) pass;
# every refusal condition fails closed with exit 1 and one stderr line
# `worktree-gitfile-check: REFUSED: <tree>: <reason>`.
# Usage: tests/worktree-gitfile-check.probe.sh   (from anywhere)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/plugins/seyag/bin/worktree-gitfile-check"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

pass=0
fail=0

ok() {
  echo "ok:   $1"
  pass=$((pass + 1))
}

bad() {
  echo "FAIL: $1"
  fail=1
}

expect_pass() { # $1=repo $2=tree $3=label
  local err rc
  err=$(bash "$TOOL" --repo "$1" "$2" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] && [ -z "$err" ]; then
    ok "$3"
  else
    bad "$3 (rc=$rc, err='$err')"
  fi
}

expect_refused() { # $1=repo $2=tree $3=needle $4=label
  local err rc lines prefix
  err=$(bash "$TOOL" --repo "$1" "$2" 2>&1)
  rc=$?
  lines=$(printf '%s\n' "$err" | wc -l)
  prefix="worktree-gitfile-check: REFUSED: $2: "
  if [ "$rc" -eq 1 ] && [ "$lines" -eq 1 ] && [[ $err == "$prefix"* ]] && [[ $err == *"$3"* ]]; then
    ok "$4"
  else
    bad "$4 (rc=$rc, lines=$lines, err='$err', want prefix '$prefix' + '$3')"
  fi
}

mk_repo_with_wt() { # $1=name -> repo at $T/$1, linked worktree at $T/$1/.claude/worktrees/w1
  local r="$T/$1"
  git init -q -b main "$r"
  echo init >"$r/a.txt"
  git -C "$r" add a.txt
  git -C "$r" commit -qm init
  git -C "$r" worktree add -q -b worktree-agent-w1 "$r/.claude/worktrees/w1"
}

# 1. Valid linked worktree (with trailing newline, and without trailing newline).
mk_repo_with_wt r_valid
R="$T/r_valid"
WT="$R/.claude/worktrees/w1"
expect_pass "$R" "$WT" "valid worktree with trailing newline passes"
bash "$TOOL" --repo="$R" "$WT" >/dev/null 2>&1 && ok "valid worktree with --repo= form passes" || bad "valid worktree with --repo= form"

raw_line=$(cat "$WT/.git")
printf '%s' "$raw_line" >"$WT/.git"
[ "$(wc -l <"$WT/.git")" -eq 0 ] && ok "fixture: stripped trailing newline (wc -l is 0)" || bad "fixture: wc -l not 0"
expect_pass "$R" "$WT" "valid worktree without trailing newline passes"

# Relative gitdir in TREE/.git and relative back-pointer in <entry>/gitdir.
printf 'gitdir: ../../../.git/worktrees/w1\n' >"$WT/.git"
printf '../../../.claude/worktrees/w1/.git\n' >"$R/.git/worktrees/w1/gitdir"
expect_pass "$R" "$WT" "valid worktree with relative gitdir and relative back-pointer passes"

# 2. Usage errors (exit 2) and --help (exit 0).
bash "$TOOL" --help >/dev/null 2>&1 && ok "--help exits 0" || bad "--help"
for args in "" "--repo $R" "$WT" "--repo $R $WT extra" "--bogus $WT" "--repo= $WT"; do
  # shellcheck disable=SC2086
  err=$(bash "$TOOL" $args 2>&1 >/dev/null)
  rc=$?
  if [ "$rc" -eq 2 ] && [ -n "$err" ]; then
    ok "usage error exits 2: '$args'"
  else
    bad "usage error for '$args' (rc=$rc, err='$err')"
  fi
done

# 3. Rule 1: TREE/.git is a symlink, a real directory, or not a regular file.
mk_repo_with_wt r_rule1
R1="$T/r_rule1"
WT1="$R1/.claude/worktrees/w1"
mv "$WT1/.git" "$T/saved.gitfile"
ln -s "$T/saved.gitfile" "$WT1/.git"
expect_refused "$R1" "$WT1" "symlink" "rule 1: symlinked TREE/.git refuses"

rm -f "$WT1/.git"
expect_refused "$R1" "$WT1" "regular file" "rule 1: missing TREE/.git refuses"

expect_refused "$R1" "$R1" "directory" "rule 1: real .git directory refuses"

# 4. Rule 2: > 4096 bytes, > 1 line, NUL byte, empty, or no 'gitdir: ' prefix.
mk_repo_with_wt r_rule2
R2="$T/r_rule2"
WT2="$R2/.claude/worktrees/w1"
ENTRY2="$R2/.git/worktrees/w1"

printf 'gitdir: %s/%04096d\n' "$ENTRY2" 0 >"$WT2/.git"
expect_refused "$R2" "$WT2" "4096" "rule 2: .git over 4096 bytes refuses"

printf 'gitdir: %s\nextra-line\n' "$ENTRY2" >"$WT2/.git"
expect_refused "$R2" "$WT2" "more than one line" "rule 2: two newline-terminated lines refuses"

printf 'gitdir: %s\nsecond-unterminated' "$ENTRY2" >"$WT2/.git"
expect_refused "$R2" "$WT2" "more than one line" "rule 2: wc -l == 1 with a second line refuses"

printf 'gitdir: %s\n\n' "$ENTRY2" >"$WT2/.git"
expect_refused "$R2" "$WT2" "more than one line" "rule 2: trailing blank second line refuses"

printf 'gitdir: %s\0\n' "$ENTRY2" >"$WT2/.git"
expect_refused "$R2" "$WT2" "NUL" "rule 2: NUL byte in .git refuses"

: >"$WT2/.git"
expect_refused "$R2" "$WT2" "empty" "rule 2: 0-byte .git refuses"

printf '\n' >"$WT2/.git"
expect_refused "$R2" "$WT2" "empty" "rule 2: newline-only .git refuses"

printf '%s\n' "$ENTRY2" >"$WT2/.git"
expect_refused "$R2" "$WT2" "gitdir: " "rule 2: missing 'gitdir: ' prefix refuses"

printf 'gitdir: \n' >"$WT2/.git"
expect_refused "$R2" "$WT2" "empty" "rule 2: empty 'gitdir: ' target refuses"

# 5. Rule 3: target path is a symlink, does not exist, or is not <common>/worktrees/<id>.
mk_repo_with_wt r_rule3
R3="$T/r_rule3"
WT3="$R3/.claude/worktrees/w1"
ENTRY3="$R3/.git/worktrees/w1"

ln -s "$ENTRY3" "$T/sym-entry"
printf 'gitdir: %s\n' "$T/sym-entry" >"$WT3/.git"
expect_refused "$R3" "$WT3" "symlink" "rule 3: symlinked gitdir target refuses"

ln -s "$ENTRY3" "$R3/.git/worktrees/sym-in-wt"
printf 'gitdir: %s\n' "$R3/.git/worktrees/sym-in-wt" >"$WT3/.git"
expect_refused "$R3" "$WT3" "symlink" "rule 3: symlinked <common>/worktrees/<id> entry refuses"

printf 'gitdir: %s\n' "$R3/.git/worktrees/no-such-entry" >"$WT3/.git"
expect_refused "$R3" "$WT3" "does not exist" "rule 3: non-existent gitdir target refuses"

touch "$T/not-a-dir"
printf 'gitdir: %s\n' "$T/not-a-dir" >"$WT3/.git"
expect_refused "$R3" "$WT3" "not a directory" "rule 3: file gitdir target refuses"

mkdir -p "$T/crafted-gitdir"
printf 'gitdir: %s\n' "$T/crafted-gitdir" >"$WT3/.git"
expect_refused "$R3" "$WT3" "worktrees" "rule 3: directory not named <common>/worktrees/<id> refuses"

# 6. Rule 4: <entry>/commondir or <entry>/gitdir symlink, not a regular file, empty, or bad target.
mk_repo_with_wt r_rule4
R4="$T/r_rule4"
WT4="$R4/.claude/worktrees/w1"
ENTRY4="$R4/.git/worktrees/w1"

mv "$ENTRY4/commondir" "$T/commondir.bak"
ln -s "$T/commondir.bak" "$ENTRY4/commondir"
expect_refused "$R4" "$WT4" "commondir" "rule 4: symlinked commondir refuses"

rm -f "$ENTRY4/commondir"
expect_refused "$R4" "$WT4" "commondir" "rule 4: missing commondir refuses"

: >"$ENTRY4/commondir"
expect_refused "$R4" "$WT4" "commondir" "rule 4: empty commondir refuses"

mkdir -p "$T/other-common"
printf '%s\n' "$T/other-common" >"$ENTRY4/commondir"
expect_refused "$R4" "$WT4" "commondir" "rule 4: commondir not pointing to <common> refuses"

cp "$T/commondir.bak" "$ENTRY4/commondir"
mv "$ENTRY4/gitdir" "$T/gitdir.bak"
ln -s "$T/gitdir.bak" "$ENTRY4/gitdir"
expect_refused "$R4" "$WT4" "gitdir" "rule 4: symlinked entry gitdir refuses"

rm -f "$ENTRY4/gitdir"
expect_refused "$R4" "$WT4" "gitdir" "rule 4: missing entry gitdir refuses"

: >"$ENTRY4/gitdir"
expect_refused "$R4" "$WT4" "gitdir" "rule 4: empty entry gitdir refuses"

printf '%s\n' "$T/other-tree/.git" >"$ENTRY4/gitdir"
expect_refused "$R4" "$WT4" "gitdir" "rule 4: entry gitdir not pointing back to <real TREE>/.git refuses"

cp "$T/gitdir.bak" "$ENTRY4/gitdir"
expect_pass "$R4" "$WT4" "rule 4: restored commondir and gitdir pass again"

# 7. Rule 5: <common> is under TREE, or is not <real MAIN_TOP>/.git, or MAIN_TOP/.git is a file.
mk_repo_with_wt r_rule5a
mk_repo_with_wt r_rule5b
R5A="$T/r_rule5a"
R5B="$T/r_rule5b"
WT5A="$R5A/.claude/worktrees/w1"
WT5B="$R5B/.claude/worktrees/w1"

# A valid worktree belonging to another repo (R5B) checked against R5A.
expect_refused "$R5A" "$WT5B" "$R5A/.git" "rule 5: worktree of another repo refuses"

# WT5A repointed at R5B's worktree entry with R5B's entry gitdir pointing back to WT5A.
printf 'gitdir: %s\n' "$R5B/.git/worktrees/w1" >"$WT5A/.git"
printf '%s\n' "$(realpath -e "$WT5A")/.git" >"$R5B/.git/worktrees/w1/gitdir"
expect_refused "$R5A" "$WT5A" "$R5A/.git" "rule 5: tree repointed to another repo's entry with matching back-pointer refuses"

# <common> inside TREE itself.
IN_COMMON="$WT5A/fake-common/.git"
mkdir -p "$IN_COMMON/worktrees/w1"
printf '../..\n' >"$IN_COMMON/worktrees/w1/commondir"
printf '%s\n' "$(realpath -e "$WT5A")/.git" >"$IN_COMMON/worktrees/w1/gitdir"
printf 'gitdir: %s\n' "$IN_COMMON/worktrees/w1" >"$WT5A/.git"
expect_refused "$R5A" "$WT5A" "inside" "rule 5: <common> under TREE refuses"

# Main repo whose .git is itself a file (--separate-git-dir) fails closed.
git init -q -b main --separate-git-dir="$T/sep.git" "$T/sep-main"
echo s >"$T/sep-main/s.txt"
git -C "$T/sep-main" add s.txt && git -C "$T/sep-main" commit -qm init
git -C "$T/sep-main" worktree add -q -b worktree-agent-sep "$T/sep-wt"
expect_refused "$T/sep-main" "$T/sep-wt" ".git" "rule 5: --separate-git-dir main repo (main .git is a file) refuses"

# 8. Rule 6: nested .git paths below TREE.
git init -q -b main "$T/sub-leaf"
echo leaf >"$T/sub-leaf/leaf.txt"
git -C "$T/sub-leaf" add leaf.txt && git -C "$T/sub-leaf" commit -qm "leaf init"

git init -q -b main "$T/sub-top"
echo top >"$T/sub-top/top.txt"
git -C "$T/sub-top" add top.txt && git -C "$T/sub-top" commit -qm "top init"
git -C "$T/sub-top" -c protocol.file.allow=always submodule add -q "$T/sub-leaf" nested 2>/dev/null
git -C "$T/sub-top" commit -qm "add nested sub"

git init -q -b main "$T/r_rule6_sub"
R6S="$T/r_rule6_sub"
echo main >"$R6S/m.txt"
git -C "$R6S" add m.txt && git -C "$R6S" commit -qm "main init"
git -C "$R6S" -c protocol.file.allow=always submodule add -q "$T/sub-top" sub 2>/dev/null
git -C "$R6S" commit -qm "add sub"
git -C "$R6S" worktree add -q -b worktree-agent-w1 "$R6S/.claude/worktrees/w1"
WT6S="$R6S/.claude/worktrees/w1"
git -C "$WT6S" -c protocol.file.allow=always submodule update --init -q 2>/dev/null
expect_pass "$R6S" "$WT6S" "rule 6: real submodule initialised in linked tree passes"
git -C "$WT6S" -c protocol.file.allow=always submodule update --init --recursive -q 2>/dev/null
expect_pass "$R6S" "$WT6S" "rule 6: nested submodule initialised with --recursive passes"

# Nested refusals.
mk_repo_with_wt r_rule6
R6="$T/r_rule6"
WT6="$R6/.claude/worktrees/w1"
ENTRY6="$R6/.git/worktrees/w1"

mkdir -p "$WT6/sub/.git"
expect_refused "$R6" "$WT6" "sub/.git is a directory" "rule 6: nested real .git directory refuses"
rm -rf "$WT6/sub"

mkdir -p "$WT6/a/b/c/.git"
expect_refused "$R6" "$WT6" "a/b/c/.git is a directory" "rule 6: deep nested a/b/c/.git directory refuses"
rm -rf "$WT6/a"

mkdir -p "$ENTRY6/modules/oksub" "$WT6/sub"
printf 'gitdir: %s\n' "$ENTRY6/modules/oksub" >"$T/nested-valid.gitfile"
ln -s "$T/nested-valid.gitfile" "$WT6/sub/.git"
expect_refused "$R6" "$WT6" "symlink" "rule 6: symlinked nested .git refuses"
rm -rf "$WT6/sub"

mkdir -p "$T/crafted-sub-gitdir" "$WT6/sub"
printf 'gitdir: %s\n' "$T/crafted-sub-gitdir" >"$WT6/sub/.git"
expect_refused "$R6" "$WT6" "sub/.git" "rule 6: nested gitfile to a crafted directory refuses"

printf 'gitdir: %s\n' "$ENTRY6/modules/../.." >"$WT6/sub/.git"
expect_refused "$R6" "$WT6" "sub/.git" "rule 6: nested gitfile to <entry>/modules/../.. refuses"

printf 'gitdir: %s/modules/oksub\0\n' "$ENTRY6" >"$WT6/sub/.git"
expect_refused "$R6" "$WT6" "NUL" "rule 6: nested gitfile with a NUL refuses"

printf 'gitdir: %s/modules/oksub\nextra\n' "$ENTRY6" >"$WT6/sub/.git"
expect_refused "$R6" "$WT6" "more than one line" "rule 6: nested gitfile with two lines refuses"
rm -rf "$WT6/sub"

mkdir -p "$WT6/unreadable"
trap 'chmod 700 "$WT6/unreadable" 2>/dev/null; rm -rf "$T"' EXIT
if [ "$(id -u)" -eq 0 ]; then
  ok "skipped: unreadable directory row (running as root)"
else
  chmod 000 "$WT6/unreadable"
  expect_refused "$R6" "$WT6" "find" "rule 6: directory find cannot read refuses"
  chmod 700 "$WT6/unreadable"
fi

# 9. Rule 7: planted repo (HEAD with objects, refs, or commondir) below TREE.
plant_repo() { # $1=dir $2=hook
  mkdir -p "$1/objects" "$1/refs/heads"
  printf 'ref: refs/heads/main\n' >"$1/HEAD"
  : >"$1/objects/.keep"
  : >"$1/refs/heads/.keep"
  printf '[core]\n\trepositoryformatversion = 0\n\tbare = false\n\tworktree = ..\n\tfsmonitor = %s\n' "$2" >"$1/config"
}

mk_repo_with_wt r_rule7
R7="$T/r_rule7"
WT7="$R7/.claude/worktrees/w1"
HOOK7="$T/r7-hook.sh"
printf '#!/bin/sh\n: > "%s/r7-marker"\n' "$T" >"$HOOK7"
chmod +x "$HOOK7"

plant_repo "$WT7/sub" "$HOOK7"
expect_refused "$R7" "$WT7" "sub" "rule 7: HEAD with objects and refs at sub/ refuses"
rm -rf "$WT7/sub"

plant_repo "$WT7/a/b/c" "$HOOK7"
expect_refused "$R7" "$WT7" "a/b/c" "rule 7: deep planted repo at a/b/c/ refuses"
rm -rf "$WT7/a"

plant_repo "$WT7/sub" "$HOOK7"
rm -f "$WT7/sub/HEAD"
ln -s refs/heads/main "$WT7/sub/HEAD"
expect_refused "$R7" "$WT7" "sub" "rule 7: dangling symlink HEAD with objects and refs refuses"
rm -rf "$WT7/sub"

mkdir -p "$WT7/sub"
printf 'ref: refs/heads/main\n' >"$WT7/sub/HEAD"
printf '..\n' >"$WT7/sub/commondir"
expect_refused "$R7" "$WT7" "sub" "rule 7: HEAD with commondir alone refuses"
rm -rf "$WT7/sub"

mkdir -p "$WT7/sub/objects"
printf 'ref: refs/heads/main\n' >"$WT7/sub/HEAD"
expect_refused "$R7" "$WT7" "sub" "rule 7: HEAD with objects alone refuses"
rm -rf "$WT7/sub"

mkdir -p "$WT7/sub/refs"
printf 'ref: refs/heads/main\n' >"$WT7/sub/HEAD"
expect_refused "$R7" "$WT7" "sub" "rule 7: HEAD with refs alone refuses"
rm -rf "$WT7/sub"

mkdir -p "$WT7/sub"
printf 'ref: refs/heads/main\n' >"$WT7/sub/HEAD"
ln -s nowhere "$WT7/sub/objects"
expect_refused "$R7" "$WT7" "sub" "rule 7: dangling-symlink objects beside HEAD refuses"
rm -rf "$WT7/sub"

mkdir -p "$WT7/sub/HEAD" "$WT7/sub/objects"
expect_refused "$R7" "$WT7" "sub" "rule 7: directory named HEAD beside objects refuses"
rm -rf "$WT7/sub"

mkdir -p "$WT7/sub"
printf 'ref: refs/heads/main\n' >"$WT7/sub/HEAD"
expect_pass "$R7" "$WT7" "rule 7: HEAD file alone at sub/ passes"

printf 'unrelated\n' >"$WT7/sub/other.txt"
expect_pass "$R7" "$WT7" "rule 7: sub/HEAD beside an unrelated file passes"
rm -rf "$WT7/sub"

mkdir -p "$WT7/sub/objects" "$WT7/sub/refs"
: >"$WT7/sub/objects/.keep"
: >"$WT7/sub/refs/.keep"
expect_pass "$R7" "$WT7" "rule 7: objects and refs with no HEAD passes"
rm -rf "$WT7/sub"

mkdir -p "$WT7/objects" "$WT7/refs"
printf 'ref: refs/heads/main\n' >"$WT7/HEAD"
: >"$WT7/objects/.keep"
: >"$WT7/refs/.keep"
expect_pass "$R7" "$WT7" "rule 7: tree-top HEAD with objects and refs beside it passes"
rm -rf "$WT7/HEAD" "$WT7/objects" "$WT7/refs"

[ "$fail" -eq 0 ] || exit 1
echo "PASS: worktree-gitfile-check ($pass cases)"
