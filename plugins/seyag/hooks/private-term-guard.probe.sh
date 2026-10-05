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

if [ "$FAILURES" -ne 0 ]; then
  printf '\n%d probe case(s) FAILED\n' "$FAILURES"
  exit 1
fi
printf '\nall private-term-guard probe cases passed\n'
