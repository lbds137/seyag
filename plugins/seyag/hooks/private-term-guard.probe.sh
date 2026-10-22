#!/bin/bash
# Fixture check for private-term-guard.sh — run after ANY edit to the hook.
# Builds throwaway git repos (some marked public, with bare temp remotes) and a
# temp terms file under a mktemp dir (removed on exit) and asserts: a listed
# term in the command text, a body file, a pushed commit's message or added
# line, or a line of the commit being made blocks (exit 2) in a public repo,
# with the term never echoed; the hook is off without a terms file, and silent
# in a repo not marked public; an own-prefix bypass passes; an invalid term
# line blocks by line number only; `git status` never starts python.
#
# Every call passes SYG_PRIVATE_TERMS_FILE explicitly (or unsets it), so the
# caller's own setting cannot leak in. The terms are invented words.
#
# Usage: hooks/private-term-guard.probe.sh   (from anywhere)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$SCRIPT_DIR/private-term-guard.sh"

TMP=$(mktemp -d) || { echo "FAIL [setup]: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export GIT_CEILING_DIRECTORIES="$TMP"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=probe GIT_AUTHOR_EMAIL=probe@example.invalid
export GIT_COMMITTER_NAME=probe GIT_COMMITTER_EMAIL=probe@example.invalid

# --- terms files -------------------------------------------------------------
# Term #1 quennith\s+varr, #2 zorbleflux (the 2nd term line, after a comment),
# #3 a case-sensitive term.
TERMS="$TMP/terms.txt"
printf '%s\n' '# probe terms' 'quennith\s+varr' '' 'zorbleflux' '(?-i:CaseOnlyGlimmet)' >"$TERMS"
COMMENTS="$TMP/comments.txt"
printf '%s\n' '# only a comment' '#zorbleflux' '' >"$COMMENTS"
BADRE="$TMP/badre.txt"
printf '%s\n' 'zorbleflux' '(unclosed[wibbet' >"$BADRE"

# --- repos ---------------------------------------------------------------------
# mkrepo <dir> <true|false|none> -> a repo with one pushed base commit
mkrepo() {
  local d="$1" flag="$2"
  git init -q --bare "$d.remote.git"
  git init -q "$d"
  git -C "$d" remote add origin "$d.remote.git"
  git -C "$d" commit -q --allow-empty -m "base"
  git -C "$d" branch -M main
  git -C "$d" push -q origin main 2>/dev/null
  [ "$flag" = none ] || git -C "$d" config seyag.publicRepo "$flag"
}

PUB="$TMP/pub"; mkrepo "$PUB" true
PRIV="$TMP/priv"; mkrepo "$PRIV" none
OFF="$TMP/off"; mkrepo "$OFF" false
STG="$TMP/stg"; mkrepo "$STG" true
printf 'intro\nthe zorbleflux plan\n' >"$STG/notes.md"
git -C "$STG" add notes.md
UNT="$TMP/unt"; mkrepo "$UNT" true
printf 'about zorbleflux\n' >"$UNT/loose.md"
PMSG="$TMP/pmsg"; mkrepo "$PMSG" true
git -C "$PMSG" commit -q --allow-empty -m "ship zorbleflux docs"
PMSG_SHA=$(git -C "$PMSG" rev-parse --short HEAD)
PLINE="$TMP/pline"; mkrepo "$PLINE" true
printf 'plain\nsee zorbleflux here\n' >"$PLINE/doc.md"
git -C "$PLINE" add doc.md
git -C "$PLINE" commit -q -m "add doc"
PLINE_SHA=$(git -C "$PLINE" rev-parse --short HEAD)
PLAIN="$TMP/plain"; mkdir -p "$PLAIN"
mkdir -p "$TMP/files"
printf 'body about zorbleflux\n' >"$TMP/files/body.txt"

FAILURES=0

# run <expected-exit> <label> <cwd> <extra env words...> -- <cmd>
# A blocking run also asserts that no term's text appears in the output.
run() {
  local expected="$1" label="$2" cwd="$3"
  shift 3
  local envs=()
  while [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  shift
  local cmd="$1"
  printf '%s' "$cmd" \
    | jq -Rsc --arg c "$cwd" '{tool_name:"Bash",tool_input:{command:.},cwd:$c}' \
    | env -u SYG_PRIVATE_TERMS_FILE "${envs[@]}" timeout 30 "$HOOK" >"$TMP/out" 2>&1
  local actual=$?
  if [ "$actual" -eq "$expected" ]; then
    printf 'PASS  (exit %d)  %s\n' "$actual" "$label"
  else
    printf 'FAIL  (exit %d, expected %d)  %s\n' "$actual" "$expected" "$label"
    sed 's/^/      /' "$TMP/out"
    FAILURES=$((FAILURES + 1))
  fi
  if [ "$expected" -eq 2 ]; then
    if grep -qiF -e zorbleflux -e quennith -e caseonlyglimmet -e wibblequat "$TMP/out"; then
      printf 'FAIL  (output)  term text echoed: %s\n' "$label"
      sed 's/^/      /' "$TMP/out"
      FAILURES=$((FAILURES + 1))
    else
      printf 'PASS  (output)  term text never echoed: %s\n' "$label"
    fi
  fi
}

# assert_out <label> <present|absent> <fixed string>: the LAST run's output.
assert_out() {
  local label="$1" mode="$2" s="$3" ok=1
  case "$mode" in
    present) grep -qF -- "$s" "$TMP/out" || ok=0 ;;
    absent) ! grep -qF -- "$s" "$TMP/out" || ok=0 ;;
  esac
  if [ "$ok" = 1 ]; then
    printf 'PASS  (output)  %s\n' "$label"
  else
    printf 'FAIL  (output)  %s\n' "$label"
    sed 's/^/      /' "$TMP/out"
    FAILURES=$((FAILURES + 1))
  fi
}

T=(SYG_PRIVATE_TERMS_FILE="$TERMS")

# =============================================================================
# Off: no terms file
# =============================================================================
run 0 "off: SYG_PRIVATE_TERMS_FILE unset" "$PUB" -- \
  "git commit -m 'add zorbleflux'"
run 0 "off: terms file missing" "$PUB" SYG_PRIVATE_TERMS_FILE="$TMP/missing.txt" -- \
  "git commit -m 'add zorbleflux'"
run 0 "off: terms file with only comments" "$PUB" SYG_PRIVATE_TERMS_FILE="$COMMENTS" -- \
  "git commit -m 'add zorbleflux'"

# =============================================================================
# Not public
# =============================================================================
run 0 "not public: repo without the flag" "$PRIV" "${T[@]}" -- \
  "git commit -m 'add zorbleflux'"
run 0 "not public: flag false" "$OFF" "${T[@]}" -- \
  "git commit -m 'add zorbleflux'"
run 0 "not public: a non-repo cwd" "$PLAIN" "${T[@]}" -- \
  "git commit -m 'add zorbleflux'"

# =============================================================================
# Public: command text and body files
# =============================================================================
run 2 "public: term in git commit -m" "$PUB" "${T[@]}" -- \
  "git commit -m 'add zorbleflux'"
assert_out "message names the command text" present "matched in: the command text"
assert_out "2nd term line after a comment is #2 (header)" present "(#2 in \$SYG_PRIVATE_TERMS_FILE)"
assert_out "context masks the term as #2" present "[private term #2]"
run 0 "near-miss: clean git commit -m" "$PUB" "${T[@]}" -- \
  "git commit -m 'add docs'"
run 2 "public: case-insensitive match" "$PUB" "${T[@]}" -- \
  "git commit -m 'add ZorbleFLUX'"
run 0 "public: (?-i:...) term in another case passes" "$PUB" "${T[@]}" -- \
  "git commit -m 'add caseonlyglimmet'"
run 2 "public: (?-i:...) term in its own case blocks" "$PUB" "${T[@]}" -- \
  "git commit -m 'add CaseOnlyGlimmet'"
assert_out "case-sensitive term is #3" present "[private term #3]"
run 2 "public: term #1 with a regex class" "$PUB" "${T[@]}" -- \
  "git commit -m 'thanks Quennith   Varr'"
assert_out "first term is #1" present "[private term #1]"
run 2 "public: gh pr create --body-file with the term" "$PUB" "${T[@]}" -- \
  "gh pr create --title t --body-file $TMP/files/body.txt"
assert_out "message names a body file, not its path" present "matched in: a body file."
run 2 "public: git commit -F file with the term" "$PUB" "${T[@]}" -- \
  "git commit -F $TMP/files/body.txt"

# =============================================================================
# Public: lines of the commit being made
# =============================================================================
run 2 "public: staged markdown file holds the term, git commit -m clean" "$STG" "${T[@]}" -- \
  "git commit -m clean"
assert_out "message names staged lines, not the path" present "matched in: staged lines (see git diff --cached)."
run 2 "public: git add of an untracked file with the term, then commit" "$UNT" "${T[@]}" -- \
  "git add loose.md && git commit -m x"
run 0 "near-miss: the untracked file without the git add" "$UNT" "${T[@]}" -- \
  "git commit -m x"

# =============================================================================
# Public: push
# =============================================================================
run 2 "push: unpushed commit message holds the term" "$PMSG" "${T[@]}" -- \
  "git push origin main"
assert_out "message names the commit message by sha only" present "matched in: commit $PMSG_SHA message."
run 2 "push: unpushed commit's added line holds the term" "$PLINE" "${T[@]}" -- \
  "git push origin main"
assert_out "message names the commit diff by sha only" present "matched in: commit $PLINE_SHA diff."
git -C "$PLINE" push -q origin main 2>/dev/null
run 0 "push: the same commit once already pushed" "$PLINE" "${T[@]}" -- \
  "git push origin main"

# =============================================================================
# Directory tracking
# =============================================================================
run 2 "tracking: cd <public repo> && git commit from a non-repo cwd" "$PLAIN" "${T[@]}" -- \
  "cd $PUB && git commit -m 'add zorbleflux'"
run 2 "tracking: git -C <public repo> commit from a non-repo cwd" "$PLAIN" "${T[@]}" -- \
  "git -C $PUB commit -m 'add zorbleflux'"
run 0 "tracking: cd <private repo> from a public cwd" "$PUB" "${T[@]}" -- \
  "cd $PRIV && git commit -m 'add zorbleflux'"

# =============================================================================
# Bypass
# =============================================================================
run 0 "bypass: assignment in the commit's own prefix" "$PUB" "${T[@]}" -- \
  "SYG_ALLOW_PRIVATE_TERM=1 git commit -m 'add zorbleflux'"
run 2 "bypass elsewhere in the text does not count" "$PUB" "${T[@]}" -- \
  "echo SYG_ALLOW_PRIVATE_TERM=1; git commit -m 'add zorbleflux'"

# =============================================================================
# Invalid term line
# =============================================================================
run 2 "invalid regex line blocks" "$PUB" SYG_PRIVATE_TERMS_FILE="$BADRE" -- \
  "git commit -m 'add docs'"
assert_out "invalid regex message names line 2" present "$BADRE line 2 is not a valid regex; fix it"
assert_out "invalid regex message omits the line's text" absent "(unclosed[wibbet"
run 0 "invalid regex in a repo not marked public is not reached" "$PRIV" SYG_PRIVATE_TERMS_FILE="$BADRE" -- \
  "git commit -m 'add docs'"

# =============================================================================
# Labels carry no user text: anchored and lookaround terms
# =============================================================================
ANCH="$TMP/anch.txt"
printf '%s\n' '^zorbleflux' '(?<=secret-)wibblequat' >"$ANCH"
A=(SYG_PRIVATE_TERMS_FILE="$ANCH")
ANPUSH="$TMP/anpush"; mkrepo "$ANPUSH" true
git -C "$ANPUSH" commit -q --allow-empty -m "zorbleflux leaks here"
ANPUSH_SHA=$(git -C "$ANPUSH" rev-parse --short HEAD)
run 2 "anchored term over a pushed commit subject" "$ANPUSH" "${A[@]}" -- \
  "git push origin main"
assert_out "anchored subject: named by sha only" present "matched in: commit $ANPUSH_SHA message."
ANSTG="$TMP/anstg"; mkrepo "$ANSTG" true
printf 'zorbleflux first\n' >"$ANSTG/zorbleflux.md"
git -C "$ANSTG" add zorbleflux.md
run 2 "anchored term in a staged file named after the term" "$ANSTG" "${A[@]}" -- \
  "git commit -m clean"
LBSTG="$TMP/lbstg"; mkrepo "$LBSTG" true
printf 'the secret-wibblequat line\n' >"$LBSTG/wibblequat.md"
git -C "$LBSTG" add wibblequat.md
run 2 "lookbehind term in a staged file named after the term" "$LBSTG" "${A[@]}" -- \
  "git commit -m clean"
run 2 "lookbehind term in the command text" "$PUB" "${A[@]}" -- \
  "git commit -m 'the secret-wibblequat plan'"

# =============================================================================
# Directory tracking: ~, cd options, redirections, unresolvable directories
# =============================================================================
run 2 "tracking: git -C ~/pub commit (HOME expanded)" "$PLAIN" "${T[@]}" HOME="$TMP" -- \
  "git -C ~/pub commit -m 'add zorbleflux'"
run 2 "tracking: cd -P <public repo> && git commit" "$PLAIN" "${T[@]}" -- \
  "cd -P $PUB && git commit -m 'add zorbleflux'"
run 2 "tracking: cd <public repo> >/dev/null && git commit" "$PLAIN" "${T[@]}" -- \
  "cd $PUB >/dev/null && git commit -m 'add zorbleflux'"
run 2 "tracking: pushd <public repo> >/dev/null && git commit" "$PLAIN" "${T[@]}" -- \
  "pushd $PUB >/dev/null && git commit -m 'add zorbleflux'"
# The shared outbound cd rules (session-url-gate's cd group), judged by
# directory: the body file's path is absolute, so only the directory decides.
run 2 "tracking: cd <public repo> && git commit -F <file with the term>" "$PLAIN" "${T[@]}" -- \
  "cd $PUB && git commit -F $TMP/files/body.txt"
run 2 "tracking: cd <public>; cd <private>; cd - returns to the public repo" "$PLAIN" "${T[@]}" -- \
  "cd $PUB; cd $PRIV; cd - >/dev/null && git commit -F $TMP/files/body.txt"
run 2 "tracking: unfollowed cd \$VAR still moves OLDPWD: cd - returns to the public repo" "$PLAIN" "${T[@]}" UNSET="$PRIV" -- \
  "cd $PUB && cd \$UNSET && cd - && git commit -F $TMP/files/body.txt"
run 2 "tracking: bare cd goes to \$HOME (the public repo)" "$PLAIN" "${T[@]}" HOME="$PUB" -- \
  "cd && git commit -F $TMP/files/body.txt"
run 0 "near-miss: bare cd leaves the public cwd for \$HOME (a private repo)" "$PUB" "${T[@]}" HOME="$PRIV" -- \
  "cd && git commit -F $TMP/files/body.txt"
# With HOME unset bash's bare cd fails and leaves OLDPWD at the start, so
# `cd -` returns there (a non-repo dir), not to the public repo.
run 0 "tracking: bare cd with HOME unset moves nothing: cd - returns to the start" "$PLAIN" -u HOME "${T[@]}" -- \
  "cd $PUB && cd && cd - && git commit -F $TMP/files/body.txt"
# With no such user bash leaves `~other` literal and cd enters a directory of
# that name in the cwd: here a crafted public repo.
mkdir -p "$TMP/tilde"; mkrepo "$TMP/tilde/~other" true
run 2 "tracking: cd ~other enters a literal ~other public repo" "$TMP/tilde" "${T[@]}" -- \
  "cd ~other && git commit -F $TMP/files/body.txt"
run 0 "near-miss: cd ~other with no literal ~other dir stays put" "$PLAIN" "${T[@]}" -- \
  "cd ~other && git commit -F $TMP/files/body.txt"
run 2 "fail closed: unresolvable directory judged by the public cwd" "$PUB" "${T[@]}" -- \
  "git -C $TMP/missing commit -m 'add zorbleflux'"
run 0 "near-miss: unresolvable directory with a private cwd" "$PRIV" "${T[@]}" -- \
  "git -C $TMP/missing commit -m 'add zorbleflux'"

# =============================================================================
# Latency: a repo not marked public gets no diff work
# =============================================================================
GITSHIM="$TMP/gitshim"
mkdir -p "$GITSHIM"
REAL_GIT=$(command -v git)
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s/gitlog"\nexec "%s" "$@"\n' "$TMP" "$REAL_GIT" >"$GITSHIM/git"
chmod +x "$GITSHIM/git"
PRIVSTG="$TMP/privstg"; mkrepo "$PRIVSTG" none
printf 'the zorbleflux plan\n' >"$PRIVSTG/notes.md"
git -C "$PRIVSTG" add notes.md
diff_check() { # diff_check <expect ran|none> <label>
  local got=none
  grep -qE '(^| )diff( |$)' "$TMP/gitlog" 2>/dev/null && got=ran
  if [ "$got" = "$1" ]; then
    printf 'PASS  (git shim)  %s\n' "$2"
  else
    printf 'FAIL  (git shim, %s, expected %s)  %s\n' "$got" "$1" "$2"
    FAILURES=$((FAILURES + 1))
  fi
}
rm -f "$TMP/gitlog"
run 0 "latency: staged term in a private repo" "$PRIVSTG" "${T[@]}" PATH="$GITSHIM:$PATH" -- \
  "git commit -m clean"
diff_check none "private repo: no git diff ran"
rm -f "$TMP/gitlog"
run 2 "latency positive control: staged term in a public repo" "$STG" "${T[@]}" PATH="$GITSHIM:$PATH" -- \
  "git commit -m clean"
diff_check ran "public repo: git diff ran (the shim sees diffs)"

# =============================================================================
# Output ceiling: many hits stay under 2 KB
# =============================================================================
BIG="$TMP/big"; mkrepo "$BIG" true
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  printf 'line zorbleflux %s %s\n' "$i" "$(printf 'x%.0s' {1..200})" >"$BIG/f$i.md"
  git -C "$BIG" add "f$i.md"
  git -C "$BIG" commit -q -m "zorbleflux commit $i"
done
for i in $(seq 1 30); do
  printf 'zorbleflux staged %s\n' "$i" >"$BIG/s$i.md"
done
git -C "$BIG" add .
run 2 "worst case: many staged files and pushed commits" "$BIG" "${T[@]}" -- \
  "git commit -F $TMP/files/body.txt -m 'zorbleflux' && git push origin main"
size=$(wc -c <"$TMP/out")
if [ "$size" -lt 2048 ]; then
  printf 'PASS  (output)  worst-case message is %d bytes (< 2048)\n' "$size"
else
  printf 'FAIL  (output)  worst-case message is %d bytes (>= 2048)\n' "$size"
  FAILURES=$((FAILURES + 1))
fi
lines=$(grep -c '^  ' "$TMP/out")
if [ "$lines" -le 5 ]; then
  printf 'PASS  (output)  worst case shows %d context lines (<= 5)\n' "$lines"
else
  printf 'FAIL  (output)  worst case shows %d context lines (> 5)\n' "$lines"
  FAILURES=$((FAILURES + 1))
fi

# =============================================================================
# Catastrophic pattern: matching is time-boxed
# =============================================================================
REDOS="$TMP/redos.txt"
printf '%s\n' '(a+)+$' >"$REDOS"
run 2 "catastrophic pattern blocks after the time box" "$PUB" SYG_PRIVATE_TERMS_FILE="$REDOS" -- \
  "git commit -m '$(printf 'a%.0s' {1..40})b'"
assert_out "time-box message names the file" present "matching the terms took over 5 s; simplify the patterns in $REDOS"
assert_out "time-box message omits the pattern" absent "(a+)+"

# =============================================================================
# Terms file: CRLF, trailing whitespace, indented comments
# =============================================================================
CRLF="$TMP/crlf.txt"
printf '   # quennith\r\nzorbleflux  \r\n' >"$CRLF"
run 2 "CRLF and trailing spaces stripped from a term line" "$PUB" SYG_PRIVATE_TERMS_FILE="$CRLF" -- \
  "git commit -m 'add zorbleflux'"
assert_out "an indented comment is not a term line (term is #1)" present "[private term #1]"
INDENT="$TMP/indent.txt"
printf '   # zorbleflux\n' >"$INDENT"
run 0 "a file with only an indented comment is off" "$PUB" SYG_PRIVATE_TERMS_FILE="$INDENT" -- \
  "git commit -m 'note:   # zorbleflux'"

# =============================================================================
# Prefilter
# =============================================================================
# A python3 shim records each spawn; it is the only way to tell "prefilter
# skipped" from "python ran and allowed".
SHIM="$TMP/shim"
mkdir -p "$SHIM"
REAL_PY=$(command -v python3)
printf '#!/bin/bash\n: >"%s/spawned"\nexec "%s" "$@"\n' "$TMP" "$REAL_PY" >"$SHIM/python3"
chmod +x "$SHIM/python3"

spawn_check() { # spawn_check <expect spawned|skipped> <label>
  local got=skipped
  [ -e "$TMP/spawned" ] && got=spawned
  if [ "$got" = "$1" ]; then
    printf 'PASS  (shim)  %s\n' "$2"
  else
    printf 'FAIL  (shim, %s, expected %s)  %s\n' "$got" "$1" "$2"
    FAILURES=$((FAILURES + 1))
  fi
}
rm -f "$TMP/spawned"
run 0 "prefilter: git status with a term in the text" "$PUB" "${T[@]}" PATH="$SHIM:$PATH" -- \
  "git status # zorbleflux"
spawn_check skipped "git status never spawned python"
rm -f "$TMP/spawned"
run 2 "prefilter positive control: git commit runs python" "$PUB" "${T[@]}" PATH="$SHIM:$PATH" -- \
  "git commit -m 'add zorbleflux'"
spawn_check spawned "git commit spawned python (the shim sees spawns)"

# =============================================================================
# The added layer: with git-hooks/pre-push in force, every item stays (base)
# =============================================================================
# "In force" = the scratch global config's core.hooksPath is the plugin's
# git-hooks dir (lib/prepush_state.py); the repos above are marked public.
HOOKS_DIR=$(cd "$SCRIPT_DIR/../git-hooks" && pwd)
ACTIVE="$TMP/gactive"
printf '[core]\n\thooksPath = %s\n' "$HOOKS_DIR" >"$ACTIVE"
AC=(GIT_CONFIG_GLOBAL="$ACTIVE")
HUSKY="$TMP/husky"; mkrepo "$HUSKY" true
git -C "$HUSKY" config core.hooksPath .husky/_
run 2 "pre-push in force: git commit -m text item stays" "$PUB" "${T[@]}" "${AC[@]}" -- \
  "git commit -m 'add zorbleflux'"
assert_out "in force: the commit text matched" present "matched in: the command text"
run 2 "pre-push in force: git tag -a -m text item stays" "$PUB" "${T[@]}" "${AC[@]}" -- \
  "git tag -a v9 -m 'zorbleflux'"
run 2 "pre-push in force: git notes add -m text item stays" "$PUB" "${T[@]}" "${AC[@]}" -- \
  "git notes add -m 'zorbleflux'"
run 2 "pre-push active: a body file still blocks" "$PUB" "${T[@]}" "${AC[@]}" -- \
  "git commit -F $TMP/files/body.txt"
run 2 "pre-push active: staged lines still block" "$STG" "${T[@]}" "${AC[@]}" -- \
  "git commit -m clean"
run 2 "pre-push active: pushed commit messages still block" "$PMSG" "${T[@]}" "${AC[@]}" -- \
  "git push origin main"
run 2 "husky-style repo-local hooksPath: base behaviour" "$HUSKY" "${T[@]}" "${AC[@]}" -- \
  "git commit -m 'add zorbleflux'"
assert_out "husky repo: the command text matched" present "matched in: the command text"
run 2 "pre-push in force, a waived bypass token on the push: the commit text still blocks" "$PUB" "${T[@]}" "${AC[@]}" -- \
  "git commit -m 'add zorbleflux' && SYG_ALLOW_PRIVATE_TERM=1 git push --no-verify origin main"
assert_out "the commit text matched" present "matched in: the command text"
run 0 "pre-push active in a repo not marked public: unchanged (not checked)" "$PRIV" "${T[@]}" "${AC[@]}" -- \
  "git commit -m 'add zorbleflux'"

# =============================================================================
# Pre-push bypass tokens: blocks only where the hook is in force
# =============================================================================
run 0 "no install: git push --no-verify passes" "$PUB" "${T[@]}" -- "git push --no-verify origin main"
run 0 "husky repo with the install: git push --no-verify passes" "$HUSKY" "${T[@]}" "${AC[@]}" -- \
  "git push --no-verify origin main"
# From here on T carries the install, so each case runs where the hook is in force.
T=(SYG_PRIVATE_TERMS_FILE="$TERMS" GIT_CONFIG_GLOBAL="$ACTIVE")
run 2 "block: git push --no-verify" "$PUB" "${T[@]}" -- "git push --no-verify origin main"
assert_out "names the token" present "blocked: --no-verify would get a push past the seyag pre-push"
run 2 "block: git push --no-verif (a prefix git accepts)" "$PUB" "${T[@]}" -- "git push --no-verif origin main"
run 2 "block: git push --no-v (shortest prefix)" "$PUB" "${T[@]}" -- "git push --no-v origin main"
run 0 "twin: git push -n (push's -n is --dry-run)" "$PUB" "${T[@]}" -- "git push -n origin main"
run 0 "twin: git push -fn (cluster, still --dry-run)" "$PUB" "${T[@]}" -- "git push -fn origin main"
run 0 "twin: git push origin main" "$PUB" "${T[@]}" -- "git push origin main"
run 0 "twin: git commit -n (no-verify of commit hooks, not the push)" "$PUB" "${T[@]}" -- "git commit -n -m ok"
run 0 "twin: git commit --no-verify (pre-push still runs)" "$PUB" "${T[@]}" -- "git commit --no-verify -m ok"
run 2 "block: git -c core.hooksPath=/dev/null push" "$PUB" "${T[@]}" -- "git -c core.hooksPath=/dev/null push origin main"
assert_out "names -c core.hooksPath" present "blocked: -c core.hooksPath would get"
run 2 "block: git -c core.HOOKSPATH= (key case)" "$PUB" "${T[@]}" -- "git -c core.HOOKSPATH=x commit -m ok"
run 2 "block: git --config-env=core.hooksPath=V" "$PUB" "${T[@]}" -- "git --config-env=core.hooksPath=V push"
run 0 "twin: git -c user.name=x commit -m ok" "$PUB" "${T[@]}" -- "git -c user.name=x commit -m ok"
run 2 "block: git -c include.path=" "$PUB" "${T[@]}" -- "git -c include.path=/tmp/acme.cfg push origin main"
assert_out "names -c include.path" present "blocked: -c include.path would get"
run 2 "block: git -c includeIf.*.path=" "$PUB" "${T[@]}" -- "git -c includeIf.gitdir:/x/.path=/tmp/acme.cfg push"
run 0 "twin: git -c user.email= (not an include)" "$PUB" "${T[@]}" -- "git -c user.email=a@b.c commit -m ok"
# git config: writes and edits block, reads pass.
run 2 "block: git config core.hooksPath <value>" "$PUB" "${T[@]}" -- "git config core.hooksPath /tmp/elsewhere"
assert_out "names the write" present "blocked: git config write of core.hooksPath would get"
run 2 "block: git config --global core.hookspath <value>" "$PUB" "${T[@]}" -- "git config --global core.hookspath /x"
run 2 "block: git config --worktree core.hooksPath <value>" "$PUB" "${T[@]}" -- "git config --worktree core.hooksPath /x"
run 2 "block: git config --file f core.hooksPath <value>" "$PUB" "${T[@]}" -- "git config --file .git/config core.hooksPath /x"
run 2 "block: git config --unset core.hooksPath" "$PUB" "${T[@]}" -- "git config --unset core.hooksPath"
run 2 "block: git config --unset-all core.hooksPath" "$PUB" "${T[@]}" -- "git config --local --unset-all core.hooksPath"
run 2 "block: git config --replace-all core.hooksPath" "$PUB" "${T[@]}" -- "git config --replace-all core.hooksPath /x"
run 2 "block: git config --add core.hooksPath" "$PUB" "${T[@]}" -- "git config --add core.hooksPath /x"
run 2 "block: git config set core.hooksPath (verb form)" "$PUB" "${T[@]}" -- "git config set --global core.hooksPath /x"
run 2 "block: git config unset core.hooksPath (verb form)" "$PUB" "${T[@]}" -- "git config unset core.hooksPath"
run 2 "block: git config --local include.path <file>" "$PUB" "${T[@]}" -- "git config --local include.path /tmp/acme.cfg"
run 2 "block: git config -e" "$PUB" "${T[@]}" -- "git config -e"
assert_out "names the edit" present "blocked: git config --edit would get"
run 2 "block: git config --global --edit" "$PUB" "${T[@]}" -- "git config --global --edit"
run 2 "block: git config edit (verb form)" "$PUB" "${T[@]}" -- "git config edit --local"
run 0 "read twin: git config core.hooksPath" "$PUB" "${T[@]}" -- "git config core.hooksPath"
run 0 "read twin: git config --get core.hooksPath" "$PUB" "${T[@]}" -- "git config --get core.hooksPath"
run 0 "read twin: git config --show-origin --get-all core.hooksPath" "$PUB" "${T[@]}" -- \
  "git config --show-origin --get-all core.hooksPath"
run 0 "read twin: git config --type=path --get core.hooksPath" "$PUB" "${T[@]}" -- \
  "git config --type=path --get core.hooksPath"
run 0 "read twin: git config get core.hooksPath (verb form)" "$PUB" "${T[@]}" -- "git config get core.hooksPath"
run 0 "read twin: git config --get include.path" "$PUB" "${T[@]}" -- "git config --get include.path"
run 0 "read twin: git config --list" "$PUB" "${T[@]}" -- "git config --list"
run 0 "twin: git config user.name probe" "$PUB" "${T[@]}" -- "git config user.name probe"
run 2 "block: GIT_CONFIG_GLOBAL= prefix" "$PUB" "${T[@]}" -- "GIT_CONFIG_GLOBAL=/dev/null git push origin main"
assert_out "names GIT_CONFIG_GLOBAL" present "blocked: GIT_CONFIG_GLOBAL would get"
run 2 "block: export GIT_CONFIG_COUNT" "$PUB" "${T[@]}" -- \
  "export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/x; git push origin main"
run 2 "block: GIT_CONFIG_PARAMETERS= in a commit's prefix" "$PUB" "${T[@]}" -- \
  "GIT_CONFIG_PARAMETERS=\"'core.hookspath'='/x'\" git commit -m ok"
run 2 "block: declare -x GIT_CONFIG_SYSTEM" "$PUB" "${T[@]}" -- "declare -x GIT_CONFIG_SYSTEM; git push origin main"
run 0 "twin: reading \$GIT_CONFIG_GLOBAL" "$PUB" "${T[@]}" -- "echo \"\$GIT_CONFIG_GLOBAL\"; git commit -m ok"
run 2 "block: HOME= on a push" "$PUB" "${T[@]}" -- "HOME=/tmp/acme git push origin main"
assert_out "names HOME=" present "blocked: HOME= on a push would get"
run 2 "block: XDG_CONFIG_HOME= on a push" "$PUB" "${T[@]}" -- "XDG_CONFIG_HOME=/tmp/acme git push origin main"
run 2 "block: env -i on a push" "$PUB" "${T[@]}" -- "env -i git push origin main"
run 2 "block: env -u HOME on a push" "$PUB" "${T[@]}" -- "env -u HOME git push origin main"
run 0 "twin: HOME= on a commit (not a push)" "$PUB" "${T[@]}" -- "HOME=/tmp/acme git commit -m ok"
run 0 "twin: env -u FOO on a push" "$PUB" "${T[@]}" -- "env -u FOO git push origin main"
run 2 "block: git -c seyag.publicRepo=false push" "$PUB" "${T[@]}" -- "git -c seyag.publicRepo=false push origin main"
run 2 "block: git config seyag.publicRepo false" "$PUB" "${T[@]}" -- "git config seyag.publicRepo false"
run 0 "read twin: git config --get seyag.publicRepo" "$PUB" "${T[@]}" -- "git config --get seyag.publicRepo"
run 2 "block: git config --global seyag.privateTermsFile <path>" "$PUB" "${T[@]}" -- \
  "git config --global seyag.privateTermsFile /tmp/empty"
run 2 "block: git -c alias.p= ... p" "$PUB" "${T[@]}" -- "git -c alias.p='push --no-verify' p origin main"
assert_out "names -c alias.*" present "blocked: -c alias.* would get"
run 2 "block: git config alias.p <value>" "$PUB" "${T[@]}" -- "git config alias.p 'push --no-verify'"
run 0 "read twin: git config --get-regexp alias" "$PUB" "${T[@]}" -- "git config --get-regexp '^alias\\.'"
run 2 "block: git config --remove-section core" "$PUB" "${T[@]}" -- "git config --remove-section core"
assert_out "names the section" present "blocked: git config remove/rename of section core would get"
run 2 "block: git config --rename-section seyag" "$PUB" "${T[@]}" -- "git config --rename-section seyag old"
run 2 "block: git config remove-section core (verb form)" "$PUB" "${T[@]}" -- "git config remove-section --local core"
run 0 "twin: git config --remove-section user" "$PUB" "${T[@]}" -- "git config --remove-section user"
run 2 "block: git update-ref refs/remotes/…" "$PUB" "${T[@]}" -- "git update-ref refs/remotes/origin/main HEAD"
run 0 "twin: git update-ref refs/heads/…" "$PUB" "${T[@]}" -- "git update-ref refs/heads/scratch HEAD"
run 2 "block: a push argument holding \$" "$PUB" "${T[@]}" -- "git push origin \"\$BRANCH\""
run 2 "block: a push argument holding a backtick" "$PUB" "${T[@]}" -- "git push origin \`cat ref\`"
run 2 "block: git send-pack" "$PUB" "${T[@]}" -- "git send-pack ../pub.remote.git main"
assert_out "names send-pack" present "blocked: git send-pack would get"
run 0 "twin: git send-pack in a repo not marked public" "$PRIV" "${T[@]}" -- "git send-pack ../priv.remote.git main"
# Global and --file config writes are judged where they land, not by the cwd.
run 2 "block: --global hooksPath write from a private repo's cwd (global install present)" "$PRIV" "${T[@]}" -- \
  "git config --global core.hooksPath /tmp/elsewhere"
run 2 "block: --system alias write from a private repo's cwd" "$PRIV" "${T[@]}" -- \
  "git config --system alias.p 'push --no-verify'"
run 0 "twin: --global write of a plain key from a private repo's cwd" "$PRIV" "${T[@]}" -- \
  "git config --global user.name probe"
run 0 "twin: --global hooksPath write with no global install" "$PRIV" SYG_PRIVATE_TERMS_FILE="$TERMS" -- \
  "git config --global core.hooksPath /tmp/elsewhere"
run 2 "block: --file <public repo's config> from a private repo's cwd" "$PRIV" "${T[@]}" -- \
  "git config --file $PUB/.git/config core.hooksPath /tmp/elsewhere"
run 0 "twin: --file <private repo's config>" "$PUB" "${T[@]}" -- \
  "git config --file $PRIV/.git/config core.hooksPath /tmp/elsewhere"
run 2 "block: --file <the global config file> from a private repo's cwd" "$PRIV" "${T[@]}" -- \
  "git config --file $ACTIVE core.hooksPath /tmp/elsewhere"
run 0 "bypass: own-prefix token on the push" "$PUB" "${T[@]}" -- \
  "SYG_ALLOW_PRIVATE_TERM=1 git push --no-verify origin main"
run 0 "bypass: own-prefix token waives a GIT_CONFIG_ assignment" "$PUB" "${T[@]}" -- \
  "SYG_ALLOW_PRIVATE_TERM=1 GIT_CONFIG_GLOBAL=/dev/null git push origin main"
run 2 "block: a bypass on another command does not waive an export of GIT_CONFIG_GLOBAL" "$PUB" "${T[@]}" -- \
  "SYG_ALLOW_PRIVATE_TERM=1 true; export GIT_CONFIG_GLOBAL=/tmp/x; git push origin main"
assert_out "names GIT_CONFIG_GLOBAL past another command's bypass" present "blocked: GIT_CONFIG_GLOBAL would get"
run 2 "block: a bypass on another command does not waive a GIT_CONFIG_GLOBAL= prefix" "$PUB" "${T[@]}" -- \
  "SYG_ALLOW_PRIVATE_TERM=1 true; GIT_CONFIG_GLOBAL=/tmp/x git push origin main"
run 2 "block: a bypassed push does not waive a later push's GIT_CONFIG_GLOBAL= prefix" "$PUB" "${T[@]}" -- \
  "SYG_ALLOW_PRIVATE_TERM=1 GIT_CONFIG_GLOBAL=/tmp/x git push origin main; GIT_CONFIG_GLOBAL=/tmp/y git push origin main"
run 0 "bypass: env BYPASS GIT_CONFIG_GLOBAL= on the push itself is waived" "$PUB" "${T[@]}" -- \
  "env SYG_ALLOW_PRIVATE_TERM=1 GIT_CONFIG_GLOBAL=/dev/null git push origin main"
# Text that only looks like a bypassed command (quoted, commented, a heredoc
# body, a string another program runs) waives nothing; these block at base too.
run 2 "block: a bypassed-looking command inside double quotes is not waived" "$PUB" "${T[@]}" -- \
  "echo \"x; SYG_ALLOW_PRIVATE_TERM=1 GIT_CONFIG_GLOBAL=/tmp/x git push\""
run 2 "block: a bypassed-looking command inside single quotes is not waived" "$PUB" "${T[@]}" -- \
  "echo 'x; SYG_ALLOW_PRIVATE_TERM=1 GIT_CONFIG_GLOBAL=/tmp/x git push'"
run 2 "block: a bypassed-looking command in a comment is not waived" "$PUB" "${T[@]}" -- \
  "# note; SYG_ALLOW_PRIVATE_TERM=1 GIT_CONFIG_GLOBAL=/tmp/x git push"
run 2 "block: a bypassed-looking command in a commit message is not waived" "$PUB" "${T[@]}" -- \
  "git commit -m \"fix (SYG_ALLOW_PRIVATE_TERM=1 GIT_CONFIG_GLOBAL=/tmp/x git push)\""
run 2 "block: a bypassed-looking line in a heredoc body is not waived" "$PUB" "${T[@]}" -- \
  $'cat <<X; git push\nx\nSYG_ALLOW_PRIVATE_TERM=1 GIT_CONFIG_GLOBAL=/tmp/x foo\nX'
PYSYS="python3 -c \"import os; os.system('x; SYG_ALLOW_PRIVATE_TERM=1 GIT_CONFIG_GLOBAL=/tmp/x git push')\""
run 2 "block: a bypassed-looking command in a python string is not waived" "$PUB" "${T[@]}" -- "$PYSYS"
run 2 "block: a bypassed prefix with only a redirection (no command) is not waived" "$PUB" "${T[@]}" -- \
  "set -a; SYG_ALLOW_PRIVATE_TERM=1 GIT_CONFIG_GLOBAL=/tmp/x >/dev/null; git push origin main"
run 2 "block: env --unset HOME on a push (space form)" "$PUB" "${T[@]}" -- "env --unset HOME git push origin main"
assert_out "names env -u HOME" present "blocked: env -u HOME on a push would get"
run 2 "block: env - on a push (GNU env's -i)" "$PUB" "${T[@]}" -- "env - git push origin main"
assert_out "names env -i" present "blocked: env -i on a push would get"
run 0 "twin: env --unset FOO on a push" "$PUB" "${T[@]}" -- "env --unset FOO git push origin main"
run 2 "block: env --uns HOME on a push (abbreviated --unset)" "$PUB" "${T[@]}" -- "env --uns HOME git push origin main"
assert_out "names env -u HOME for --uns" present "blocked: env -u HOME on a push would get"
run 0 "twin: env --uns FOO on a push" "$PUB" "${T[@]}" -- "env --uns FOO git push origin main"
run 2 "block: env --ignore-e on a push (abbreviated --ignore-environment)" "$PUB" "${T[@]}" -- \
  "env --ignore-e git push origin main"
run 2 "block: env --i on a push (shortest abbreviation of --ignore-environment)" "$PUB" "${T[@]}" -- \
  "env --i git push origin main"
# An abbreviated --unset before git: git is still read as the program (as at
# base), so its own tokens still block.
run 2 "block: env --un git push --no-verify (git stays the program)" "$PUB" "${T[@]}" -- \
  "env --un git push --no-verify origin main"
run 2 "block: env --u git push --no-verify" "$PUB" "${T[@]}" -- "env --u git push --no-verify"
run 2 "block: env --uns git -c core.hooksPath= push" "$PUB" "${T[@]}" -- "env --uns git -c core.hooksPath=/x push"
run 2 "block: env --un git config --global core.hooksPath" "$PUB" "${T[@]}" -- \
  "env --un git config --global core.hooksPath /x"
run 2 "block: comment-hidden opener before git push --no-verify" "$PUB" "${T[@]}" -- \
  $'# <<x\ngit push --no-verify origin main\nx'
run 2 "block: quote-hidden opener before git push --no-verify" "$PUB" "${T[@]}" -- \
  $'echo "<<x"\ngit push --no-verify origin main\nx'
run 0 "not public: git push --no-verify in a repo not marked public" "$PRIV" "${T[@]}" -- \
  "git push --no-verify origin main"
run 0 "off without a terms file: git push --no-verify (session-url-gate blocks it)" "$PUB" \
  GIT_CONFIG_GLOBAL="$ACTIVE" -- "git push --no-verify origin main"
# An alias that skips the hook means it is not in force: status reports it,
# and these blocks stand down (the text items still run).
ALIASED="$TMP/aliased"; mkrepo "$ALIASED" true
git -C "$ALIASED" config alias.yeet 'push --no-verify'
run 0 "an alias holding --no-verify: hook not in force, the token passes" "$ALIASED" "${T[@]}" -- \
  "git push --no-verify origin main"
T=(SYG_PRIVATE_TERMS_FILE="$TERMS")

# An invalid seyag.publicRepo counts as public (fail closed, as the pre-push
# reads it); a valid false stays off (the "not public: flag false" case).
INVAL="$TMP/inval"; mkrepo "$INVAL" yesplz
run 2 "an invalid seyag.publicRepo (yesplz) counts as public" "$INVAL" "${T[@]}" -- \
  "git commit -m 'add zorbleflux'"
assert_out "invalid publicRepo: the commit text matched" present "matched in: the command text"

# =============================================================================
# Read-only gh commands: command text is not scanned; writes/unknowns fail closed
# =============================================================================
mkdir -p "$PUB/zorbleflux"
run 0 "gh read (1): cd <dir-with-private-term> && gh pr view 1 --json number" "$PUB" "${T[@]}" -- \
  "cd $PUB/zorbleflux && gh pr view 1 --json number"
run 0 "gh read (2): gh api repos/x/y --jq .name with a private term in the text" "$PUB" "${T[@]}" -- \
  "gh api repos/x/y --jq .name # zorbleflux"
run 2 "gh write (3): gh api -X POST repos/x/y --input body.json with a private term" "$PUB" "${T[@]}" -- \
  "gh api -X POST repos/x/y --input body.json # zorbleflux"
run 2 "gh write (4): gh api -f note=x with a private term (fields without explicit GET stay scanned)" "$PUB" "${T[@]}" -- \
  "gh api repos/x/y -f note=zorbleflux"
run 2 "gh write (5): gh pr create -t <term>" "$PUB" "${T[@]}" -- \
  "gh pr create -t zorbleflux --body clean"
run 2 "gh unknown subcommand (6): gh frobnicate <term> fails closed" "$PUB" "${T[@]}" -- \
  "gh frobnicate zorbleflux"
run 2 "compound (7): git commit -m <term> && gh pr view 1 still scans the commit" "$PUB" "${T[@]}" -- \
  "git commit -m 'add zorbleflux' && gh pr view 1"
run 0 "gh read (8): gh run list with a private term" "$PUB" "${T[@]}" -- \
  "gh run list # zorbleflux"
run 0 "gh read (9): gh api with fields and explicit -X GET" "$PUB" "${T[@]}" -- \
  "gh api -X GET repos/x/y -f q=zorbleflux"
run 2 "gh write (10): gh api --method=POST with a private term" "$PUB" "${T[@]}" -- \
  "gh api --method=POST repos/x/y # zorbleflux"
run 2 "gh write (11): gh api clustered -XPOST with a private term" "$PUB" "${T[@]}" -- \
  "gh api -XPOST repos/x/y # zorbleflux"
run 0 "gh read (12): gh -R owner/repo before the subcommand" "$PUB" "${T[@]}" -- \
  "gh -R owner/repo pr view 1 # zorbleflux"
run 0 "gh read (13): bare gh with a private term in a comment" "$PUB" "${T[@]}" -- \
  "gh # zorbleflux"
run 2 "gh write (14): unknown flag before verb (gh pr --body view create) fails closed" "$PUB" "${T[@]}" -- \
  "gh pr --body view create --title zorbleflux"
run 2 "gh write (15): long-option value -XGET (gh api --jq -XGET -f) is not a method flag" "$PUB" "${T[@]}" -- \
  "gh api repos/x/y --jq -XGET -f title=zorbleflux"

if [ "$FAILURES" -ne 0 ]; then
  printf '\n%d probe case(s) FAILED\n' "$FAILURES"
  exit 1
fi
printf '\nall private-term-guard probe cases passed\n'
