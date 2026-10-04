#!/bin/bash
# Fixture check for temporal-marker-guard.sh — run after ANY edit to the hook.
#
# Three layers:
#   1. TEMPORAL_PATTERN over catch/ignore strings. The pattern is EXTRACTED
#      from the hook (a copy here would drift silently); an empty extraction
#      would make `grep -Ei ""` match everything, so it hard-fails instead.
#   2. The composed decision (file filter, comment prefix, pattern) driven end
#      to end: a throwaway git repo per case, the hook fed a PreToolUse event.
#   3. Which change the commit carries: staged, same-command `git add`,
#      `commit -a`, pathspec commits, untracked files, `git -C`.
#
# Usage: hooks/temporal-marker-guard.probe.sh   (from anywhere)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$SCRIPT_DIR/temporal-marker-guard.sh"

TMP=$(mktemp -d) || { echo "FAIL [setup]: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export GIT_CEILING_DIRECTORIES="$TMP"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=probe GIT_AUTHOR_EMAIL=probe@example.invalid
export GIT_COMMITTER_NAME=probe GIT_COMMITTER_EMAIL=probe@example.invalid

FAILURES=0

TEMPORAL_PATTERN=$(sed -n "s/^TEMPORAL_PATTERN='\(.*\)'$/\1/p" "$HOOK")
if [ -z "$TEMPORAL_PATTERN" ]; then
  printf 'FATAL: could not extract TEMPORAL_PATTERN from %s (it must stay a single-quoted one-liner).\n' "$HOOK" >&2
  exit 1
fi

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

pattern_case() {
  local want="$1" s="$2" got='ignore'
  printf '%s\n' "$s" | grep -qEi "$TEMPORAL_PATTERN" && got='catch'
  if [ "$got" = "$want" ]; then pass "($got) pattern: $s"; else fail "($got, expected $want) pattern: $s"; fi
}

# run_hook <command> <cwd> -> exit code of the hook; its stderr in $ERR
run_hook() {
  local cmd="$1" cwd="$2" ev
  ev=$(jq -n --arg c "$cmd" --arg d "$cwd" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')
  ERR=$(printf '%s' "$ev" | bash "$HOOK" 2>&1 >/dev/null)
  return $?
}

# new_repo -> echoes a fresh repo dir holding one committed seed file
new_repo() {
  local d
  d=$(mktemp -d "$TMP/r.XXXXXX")
  git -C "$d" init -q
  echo seed > "$d/seed.txt"
  git -C "$d" add seed.txt
  git -C "$d" commit -q -m seed
  echo "$d"
}

expect() { # expect <block|pass> <label> <cmd> <cwd>
  local want="$1" label="$2" rc got
  run_hook "$3" "$4"; rc=$?
  got=pass; [ "$rc" -eq 2 ] && got=block
  if [ "$got" = "$want" ] && { [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; }; then
    pass "($got) $label"
  else
    fail "($got rc=$rc, expected $want) $label"
  fi
}

# staged_case <block|pass> <filename> <content-line>: the line committed from the index
staged_case() {
  local want="$1" file="$2" line="$3" d
  d=$(new_repo)
  mkdir -p "$d/$(dirname "$file")"
  printf '%s\n' "$line" > "$d/$file"
  git -C "$d" add -- "$file"
  expect "$want" "$file: $line" 'git commit -m x' "$d"
}

# ===========================================================================
printf '\n--- TEMPORAL_PATTERN: must catch ---\n'
for s in 'Fixes #42' 'bug #1254' 'the #1254 drift' '(#1254)' 'Phase 5b' 'Epic Phase 3' \
  'Post-Phase 4' 'Phase 6 made X' 'round 1 review' 'round-1 review' 'round-2 claude-review' \
  'Added 2026-05-06 to fix data loss' 'Surfaced 2026-04-25 by claude-bot' 'PR #985 final round review' \
  'GH-1254 regression' 'caught in round 3' 'see PR 2288' 'the PR 3 backfill'; do
  pattern_case catch "$s"
done
printf '\n--- TEMPORAL_PATTERN: must ignore ---\n'
for s in '#FF0000' '#123456' '#123' '#1a2b3c' 'close the door' 'Phase 1 (scan)' 'Phase 2 (flush)' \
  'round-trip review' 'round-trips through the encoder' 'a rounded-corner review panel' \
  'RFC 3339 (2002-07-15)' 'PRs since 2026' 'expr 3 evaluates left to right' 'PR 1a2b3c is a color'; do
  pattern_case ignore "$s"
done

# ===========================================================================
printf '\n--- composed: TS/JS comment shapes block ---\n'
staged_case block foo.ts '// Caught in PR #1254'
staged_case block foo.ts ' * Surfaced 2026-04-25 by claude-bot'
staged_case block foo.ts '/* fixes #4242 */'
staged_case block foo.ts '  // Epic Phase 5b introduced this'
staged_case block foo.tsx '// round-2 claude-review'
staged_case block foo.ts '// PR #123'
staged_case block foo.go '// Surfaced 2026-04-25'
staged_case block foo.rs '/// Caught in round 3'
staged_case block foo.prisma '// added 2026-01-02'

printf '\n--- composed: code (not comments) passes ---\n'
staged_case pass foo.ts "  #count = new Date('2026-01-01');"
staged_case pass foo.ts "const cutoff = '2026-01-01';"
staged_case pass foo.ts 'const x = "PR #123";'
# An inline trailing comment is a documented scope boundary (needs a lexer).
staged_case pass foo.ts 'doSomething(); // Caught in PR #1254'
# A hash line is not a comment in a C-family file.
staged_case pass foo.ts '# Surfaced 2026-04-25'

printf '\n--- composed: python ---\n'
staged_case block foo.py '# 2026-01-02'
staged_case block foo.py '# Surfaced 2026-04-25'
staged_case block foo.py '"""Fixes #4242."""'
staged_case block foo.py "'''Caught in round 3.'''"
staged_case pass foo.py "label = 'see 2026-01-02'"
staged_case pass foo.py "cutoff = '2026-01-01'"
staged_case pass foo.py '// Surfaced 2026-04-25'
staged_case pass foo.py '# round-trips through the encoder'

printf '\n--- composed: shell and ruby ---\n'
staged_case block foo.sh '# fixed in round 3 claude-review'
staged_case block foo.sh '  # caught in PR 12'
staged_case block foo.bash '# Surfaced 2026-04-25'
staged_case block foo.rb '# see GH-77'
staged_case pass foo.sh 'echo "fixed in 2026-01-02"'
staged_case pass foo.sh '# a plain explanation of the invariant'
staged_case pass foo.sh '#!/usr/bin/env bash'

printf '\n--- composed: hex colours and clean comments pass ---\n'
staged_case pass foo.sh '# color #1a2b3c'
staged_case pass foo.sh '# color #123'
staged_case pass foo.ts '// color #123456'
staged_case pass foo.ts '// close the door behind you'
staged_case pass foo.ts ' * Phase 1 (scan) walks the tree'
staged_case pass foo.ts '// RFC 3339 (2002-07-15)'

printf '\n--- composed: files not judged ---\n'
staged_case pass notes.md '# Surfaced 2026-04-25 PR #123'
staged_case pass data.txt '# Surfaced 2026-04-25'
staged_case pass cfg.yaml '# PR #123'
# Generated headers (first 5 lines) are skipped.
d=$(new_repo)
printf '// AUTO-GENERATED FILE\n// Generated at: 2026-04-25\n' > "$d/gen.ts"
git -C "$d" add gen.ts
expect pass 'AUTO-GENERATED FILE header' 'git commit -m x' "$d"
d=$(new_repo)
printf '// @generated\n// Surfaced 2026-04-25\n' > "$d/gen2.ts"
git -C "$d" add gen2.ts
expect pass '@generated header' 'git commit -m x' "$d"
# The same file without the header blocks (the skip is what lets it pass).
d=$(new_repo)
printf '// header\n// Surfaced 2026-04-25\n' > "$d/gen3.ts"
git -C "$d" add gen3.ts
expect block 'same body, no generated header' 'git commit -m x' "$d"

printf '\n--- composed: extensionless shebang scripts ---\n'
d=$(new_repo)
printf '#!/bin/bash\n# fixed in PR #123\n' > "$d/tool"
git -C "$d" add tool
expect block 'extensionless bash shebang' 'git commit -m x' "$d"
d=$(new_repo)
printf '#!/usr/bin/env python3\n# Surfaced 2026-04-25\n' > "$d/pytool"
git -C "$d" add pytool
expect block 'extensionless python shebang' 'git commit -m x' "$d"
d=$(new_repo)
printf 'no shebang\n# Surfaced 2026-04-25\n' > "$d/plain"
git -C "$d" add plain
expect pass 'extensionless without shebang' 'git commit -m x' "$d"

printf '\n--- diff shape: a removed line passes, an unchanged old line passes ---\n'
d=$(new_repo)
printf '// Surfaced 2026-04-25\nconst a = 1;\n' > "$d/old.ts"
git -C "$d" add old.ts; git -C "$d" commit -q -m old
printf 'const a = 1;\nconst b = 2;\n' > "$d/old.ts"
git -C "$d" add old.ts
expect pass 'REMOVED line with a date' 'git commit -m x' "$d"
d=$(new_repo)
printf '// Surfaced 2026-04-25\nconst a = 1;\n' > "$d/old.ts"
git -C "$d" add old.ts; git -C "$d" commit -q -m old
printf '// Surfaced 2026-04-25\nconst a = 1;\nconst b = 2;\n' > "$d/old.ts"
git -C "$d" add old.ts
expect pass 'pre-existing dated comment left untouched' 'git commit -m x' "$d"

# ===========================================================================
printf '\n--- which change the commit carries ---\n'
d=$(new_repo)
expect pass 'nothing staged, plain commit' 'git commit -m x' "$d"

d=$(new_repo)
printf '// PR #123\n' > "$d/f.ts"
expect block 'git add f && git commit, f unstaged at hook time (untracked)' 'git add f.ts && git commit -m x' "$d"
expect block 'git add -A && git commit (untracked)' 'git add -A && git commit -m x' "$d"
expect block 'git add . && git commit (untracked)' 'git add . && git commit -m x' "$d"
expect pass 'git add -u && git commit (untracked file not widened)' 'git add -u && git commit -m x' "$d"
expect pass 'git add other-path && git commit' 'git add seed.txt && git commit -m x' "$d"
expect pass 'git add of a dated file in another repo is not this commit' "git -C $TMP add f.ts && git commit -m x" "$d"

d=$(new_repo)
printf '// base\n' > "$d/t.ts"; git -C "$d" add t.ts; git -C "$d" commit -q -m base
printf '// base\n// PR #123\n' > "$d/t.ts"
expect block 'tracked modification, git add t.ts && commit' 'git add t.ts && git commit -m x' "$d"
expect block 'git add -u && commit (tracked)' 'git add -u && git commit -m x' "$d"
expect block 'git add -A && commit (tracked)' 'git add -A && git commit -m x' "$d"
expect block 'git add -- t.ts && commit' 'git add -- t.ts && git commit -m x' "$d"
expect block 'git commit -a' 'git commit -a -m x' "$d"
expect block 'git commit -am' 'git commit -am x' "$d"
expect block 'git commit --all' 'git commit --all -m x' "$d"
expect block 'git commit <pathspec>' 'git commit t.ts -m x' "$d"
expect block 'git commit -o <pathspec>' 'git commit -o t.ts -m x' "$d"
expect block 'git commit --only -- <pathspec>' 'git commit -m x --only -- t.ts' "$d"
expect pass 'plain git commit, change unstaged and not added' 'git commit -m x' "$d"
expect pass 'git commit of a different pathspec' 'git commit seed.txt -m x' "$d"
expect block 'git -C <dir> commit -a from elsewhere' "git -C $d commit -a -m x" "$TMP"
expect block 'cd <dir> && git commit -a' "cd $d && git commit -a -m x" "$TMP"
expect block 'git -c user.name=x commit -a' 'git -c user.name=x commit -a -m x' "$d"
expect block 'env-prefixed commit' 'env FOO=1 git commit -a -m x' "$d"
expect block 'commit inside bash -c' "bash -c 'git commit -a -m x'" "$d"

printf '\n--- git stage is git add ---\n'
r=$(new_repo)
printf '// PR #123\n' > "$r/s.ts"
expect block 'git stage <path> && git commit (untracked)' 'git stage s.ts && git commit -m x' "$r"
expect pass 'git stage of another path' 'git stage seed.txt && git commit -m x' "$r"
printf '// base\n' > "$r/u.ts"; git -C "$r" add u.ts; git -C "$r" commit -q -m base
printf '// base\n// PR #123\n' > "$r/u.ts"
expect block 'git stage -u && git commit (tracked)' 'git stage -u && git commit -m x' "$r"

printf '\n--- repo diff config cannot move the parsed headers ---\n'
r=$(new_repo)
mkdir -p "$r/sub"
git -C "$r" config diff.relative true
printf '// PR #123\n' > "$r/sub/r.ts"
git -C "$r" add sub/r.ts
expect block 'diff.relative=true, cwd in a subdirectory, staged' 'git commit -m x' "$r/sub"
r=$(new_repo)
git -C "$r" config diff.dstPrefix dst/
printf '// PR #123\n' > "$r/p.ts"
git -C "$r" add p.ts
expect block 'diff.dstPrefix=dst/ (staged)' 'git commit -m x' "$r"
r=$(new_repo)
mkdir -p "$r/sub"
git -C "$r" config diff.relative true
git -C "$r" config diff.srcPrefix src/
printf '// base\n' > "$r/sub/t.ts"; git -C "$r" add sub/t.ts; git -C "$r" commit -q -m base
printf '// base\n// PR #123\n' > "$r/sub/t.ts"
expect block 'diff.relative + srcPrefix, commit -a from a subdirectory' 'git commit -a -m x' "$r/sub"

printf '\n--- bypass ---\n'
expect pass 'SYG_ALLOW_TEMPORAL=1 in the commit prefix' 'SYG_ALLOW_TEMPORAL=1 git commit -a -m x' "$d"
expect pass 'env SYG_ALLOW_TEMPORAL=1 in the commit prefix' 'env SYG_ALLOW_TEMPORAL=1 git commit -a -m x' "$d"
expect block 'bypass on the add, not the commit' 'SYG_ALLOW_TEMPORAL=1 git add t.ts && git commit -m x' "$d"
expect block 'bypass in the message text' 'git commit -a -m "SYG_ALLOW_TEMPORAL=1"' "$d"
expect block 'bypass in an echo before' 'echo SYG_ALLOW_TEMPORAL=1; git commit -a -m x' "$d"
expect block 'bypass with a value other than 1' 'SYG_ALLOW_TEMPORAL=0 git commit -a -m x' "$d"

printf '\n--- unrelated commands never block ---\n'
expect pass 'no commit word' 'ls -la' "$d"
expect pass 'commit word, not a git commit' 'echo commit' "$d"
expect pass 'git log mentioning commit' 'git log --oneline commit' "$d"
expect pass 'git status' 'git status' "$d"
expect pass 'not a repo' 'git commit -a -m x' "$TMP"

printf '\n--- block message ---\n'
run_hook 'git commit -a -m x' "$d"
case "$ERR" in
  *"t.ts:"*"PR #123"*"keep the invariant"*"SYG_ALLOW_TEMPORAL=1"*) pass 'stderr names file, line, remedy and bypass' ;;
  *) fail "stderr shape: $ERR" ;;
esac
d=$(new_repo)
for i in $(seq 1 12); do printf '// PR #%d\n' "$((100 + i))"; done > "$d/many.ts"
git -C "$d" add many.ts
run_hook 'git commit -m x' "$d"
case "$ERR" in
  *"and 2 more"*) pass 'more than 10 lines: capped with "and 2 more"' ;;
  *) fail "cap shape: $ERR" ;;
esac
n=$(printf '%s\n' "$ERR" | grep -c '^    // PR #')
[ "$n" -eq 10 ] && pass 'exactly 10 lines listed' || fail "listed $n lines, expected 10"

printf '\n--- non-Bash tool and malformed input fail open ---\n'
printf '%s' '{"tool_name":"Write","tool_input":{"command":"git commit -a"}}' | bash "$HOOK" >/dev/null 2>&1 \
  && pass 'non-Bash tool' || fail 'non-Bash tool'
printf '%s' 'not json' | bash "$HOOK" >/dev/null 2>&1 \
  && pass 'malformed event' || fail 'malformed event'

if [ "$FAILURES" -gt 0 ]; then
  printf '\n%d probe(s) FAILED\n' "$FAILURES" >&2
  exit 1
fi
printf '\nAll probes passed\n'
