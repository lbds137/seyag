#!/bin/bash
# Fixture check for plugins/seyag/bin/pr-open — run after ANY edit to it.
#
# The real pr-body-ref-gate and the real hook libs (session_link.py,
# private_terms.py) run in every case — no fakes for them. Only `gh` is
# faked: a shim on PATH that logs its args to a file and prints one canned
# PR URL (the fake-gh shim shape of tests/pr-ci-wait.probe.sh). A failed
# preflight must exit before gh is called once, so every failing case
# asserts the log is empty.
#
# HERMETIC: every pr-open call runs under `env -i` with an isolated HOME,
# so no ambient SYG_* var (this checkout's settings inject several) or
# global git config can flip a case's repo flag, terms file or base ref.
# All names here are invented (coupling-lint scans this file).
#
# Usage: tests/pr-open.probe.sh   (from anywhere)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN="$SCRIPT_DIR/../plugins/seyag/bin/pr-open"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

# --- the gh shim -------------------------------------------------------------
mkdir "$T/bin"
cat > "$T/bin/gh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
printf 'Creating pull request for example\n'
if [ "${FAKE_GH_NO_URL:-0}" = 1 ]; then
  exit "${FAKE_GH_EXIT:-0}"
fi
printf 'https://github.com/example/example/pull/42\n'
exit "${FAKE_GH_EXIT:-0}"
SHIM
chmod +x "$T/bin/gh"
GH_LOG="$T/gh-calls.log"
export FAKE_GH_LOG="$GH_LOG"

# --- the fixture repo and terms ----------------------------------------------
R="$T/repo"
mkdir -p "$R"
git -C "$R" init -q -b main
git -C "$R" config user.email t@t
git -C "$R" config user.name t
echo base > "$R/f.txt" && git -C "$R" add f.txt
git -C "$R" commit -qm base

TERMS="$T/terms"
printf 'lumina-vault\n' > "$TERMS"   # an invented term nothing matches
mkdir "$T/home"

# run_open TITLE BODYFILE [REPO-DIR] — env tuned via OPEN_ENV (array) and
# OPEN_ARGS (array); captures combined output in `out`, rc in `rc`, resets
# the gh log. A later OPEN_ENV assignment wins over the base env (case 7
# pins that env -i property).
OPEN_ENV=()
OPEN_ARGS=()
run_open() {
  : > "$GH_LOG"
  out=$(cd "${3:-$R}" && env -i \
    HOME="$T/home" PATH="$T/bin:$PATH" TERM=dumb \
    FAKE_GH_LOG="$GH_LOG" ${FAKE_GH_EXIT:+FAKE_GH_EXIT=$FAKE_GH_EXIT} \
    ${FAKE_GH_NO_URL:+FAKE_GH_NO_URL=$FAKE_GH_NO_URL} \
    SYG_PRIVATE_TERMS_FILE="$TERMS" SYG_PR_BODY_BASE_REF=no-such-ref \
    "${OPEN_ENV[@]+"${OPEN_ENV[@]}"}" "$BIN" --title "$1" --body-file "$2" \
    "${OPEN_ARGS[@]+"${OPEN_ARGS[@]}"}" 2>&1)
  rc=$?
}

# Case 1 — positive control: public repo, non-matching term, clean body.
printf 'Clean body describing the change.\n' > "$T/b1.md"
git -C "$R" config seyag.publicRepo true
run_open "Clean title" "$T/b1.md"
[ "$rc" -eq 0 ] && ok "case1: rc 0" || bad "case1: rc $rc: $out"
first_line=$(printf '%s\n' "$out" | sed -n '1p')
[ "$first_line" = "PR #42: https://github.com/example/example/pull/42" ] \
  && ok "case1: PR line first" || bad "case1: first line: $first_line"
[[ "$out" == *"cd '$R' && pr-ci-wait 42 --sha \$(git rev-parse 'refs/heads/main')"* ]] \
  && ok "case1: arm line, substitution literal" \
  || bad "case1: arm line missing/mangled: $out"
[ "$(wc -l < "$GH_LOG")" -eq 1 ] && ok "case1: exactly one gh call" \
  || bad "case1: gh calls: $(wc -l < "$GH_LOG")"

# Case 2 — session link in the body: blocked before gh, id masked.
# The fixture link is assembled at runtime: a literal session_* id in this
# tracked text would trip session-url-gate on every commit touching it.
LINK='https://claude.ai/code/session_'"fixt1234"
printf 'See %s for the log.\n' "$LINK" > "$T/b2.md"
git -C "$R" config seyag.publicRepo false
run_open "Clean title" "$T/b2.md"
first_line=$(printf '%s\n' "$out" | sed -n '1p')
[[ "$rc" -eq 1 && "$first_line" == "pr-open: BLOCK: session link in body line 1: "* ]] \
  && ok "case2: session-link body block" || bad "case2: rc $rc, first: $first_line"
[[ "$out" == *"claude.ai/code/session_…"* && "$out" != *"fixt1234"* ]] \
  && ok "case2: link masked, id absent" || bad "case2: mask leak: $out"
[ ! -s "$GH_LOG" ] && ok "case2: gh never called" || bad "case2: gh called"
# Case 3 — session link in the title.
run_open "Title with $LINK in it" "$T/b2.md"
first_line=$(printf '%s\n' "$out" | sed -n '1p')
[[ "$rc" -eq 1 && "$first_line" == "pr-open: BLOCK: session link in title line 1: "* ]] \
  && ok "case3: session-link title block" || bad "case3: rc $rc, first: $first_line"
[ ! -s "$GH_LOG" ] && ok "case3: gh never called" || bad "case3: gh called"

# Case 4 — private term in the body of a public repo.
printf 'Ships the lumina-vault rewrite.\n' > "$T/b4.md"
git -C "$R" config seyag.publicRepo true
run_open "Clean title" "$T/b4.md"
first_line=$(printf '%s\n' "$out" | sed -n '1p')
[[ "$rc" -eq 1 && "$first_line" == "pr-open: BLOCK: private term in body line 1: "* ]] \
  && ok "case4: private-term block" || bad "case4: rc $rc, first: $first_line"
[[ "$out" == *"[private term #1]"* && "$out" != *"lumina-vault rewrite."* ]] \
  && ok "case4: match rendered as placeholder" || bad "case4: term leak: $out"
[ ! -s "$GH_LOG" ] && ok "case4: gh never called" || bad "case4: gh called"

# Case 5 — non-public repo: the term scan is skipped, PR still created.
git -C "$R" config seyag.publicRepo false
run_open "Clean title" "$T/b4.md"
[ "$rc" -eq 0 ] && ok "case5: non-public skips the scan, rc 0" \
  || bad "case5: rc $rc: $out"
[ "$(wc -l < "$GH_LOG")" -eq 1 ] && ok "case5: PR created" \
  || bad "case5: gh calls: $(wc -l < "$GH_LOG")"

# Case 6 — seyag.publicRepo set but not boolean: fail closed.
git -C "$R" config seyag.publicRepo maybe
run_open "Clean title" "$T/b1.md"
first_line=$(printf '%s\n' "$out" | sed -n '1p')
[ "$rc" -eq 1 ] && [ "$first_line" = "pr-open: BLOCK: seyag.publicRepo is set but not a boolean" ] \
  && ok "case6: non-boolean flag fails closed" || bad "case6: rc $rc, first: $first_line"
[ ! -s "$GH_LOG" ] && ok "case6: gh never called" || bad "case6: gh called"

# Case 7 — terms file with a line that does not compile: names the line,
# never the term text.
printf 'proj-[\n' > "$T/badterms"   # an unclosed bracket, not a valid regex
git -C "$R" config seyag.publicRepo true
OPEN_ENV=(SYG_PRIVATE_TERMS_FILE="$T/badterms")
run_open "Clean title" "$T/b1.md"
first_line=$(printf '%s\n' "$out" | sed -n '1p')
[ "$rc" -eq 1 ] && [ "$first_line" = "pr-open: BLOCK: terms file line 1 does not compile" ] \
  && ok "case7: non-compiling term line named by number" \
  || bad "case7: rc $rc, first: $first_line"
[[ "$out" != *"proj-["* ]] && ok "case7: term text never printed" \
  || bad "case7: term text leaked: $out"
[ ! -s "$GH_LOG" ] && ok "case7: gh never called" || bad "case7: gh called"
OPEN_ENV=()

# Case 8 — the ref gate blocks: the base branch carries a POPULATED
# tracker dir (an absent tracker dir fail-opens in the gate: an empty
# ls-tree listing is infrastructure, never evidence a specific id is
# missing — so the pinned shape is a populated listing with the id absent).
git -C "$R" checkout -qb tracker-base
mkdir -p "$R/tracker/tasks"
echo t > "$R/tracker/tasks/TASK-1.md"
git -C "$R" add -A
git -C "$R" commit -qm tracker
git -C "$R" checkout -q main
printf 'Ships the fix, filed as TASK-999.\n' > "$T/b8.md"
OPEN_ENV=(SYG_PR_BODY_BASE_REF=tracker-base)
run_open "Clean title" "$T/b8.md"
[ "$rc" -eq 2 ] && ok "case8: ref-gate rc passes through (2)" \
  || bad "case8: rc $rc"
[[ "$out" == *"pr-open: BLOCK: pr-body-ref-gate failed (rc 2)"* ]] \
  && ok "case8: pr-open names the gate failure" || bad "case8: line missing: $out"
[[ "$out" == *"unresolved tracker reference"* ]] \
  && ok "case8: the gate's own banner passes through" || bad "case8: no gate banner"
[ ! -s "$GH_LOG" ] && ok "case8: gh never called" || bad "case8: gh called"
OPEN_ENV=()

# Case 9 — gh itself fails: pr-open exits with gh's rc, no arm line.
printf 'Clean body.\n' > "$T/b9.md"
git -C "$R" config seyag.publicRepo true
FAKE_GH_EXIT=1
run_open "Clean title" "$T/b9.md"
FAKE_GH_EXIT=
[ "$rc" -eq 1 ] && ok "case9: gh's rc passes through" || bad "case9: rc $rc"
[[ "$out" != *"PR #42"* ]] && ok "case9: no arm line" || bad "case9: arm line: $out"

# Case 10 — the pre-push fallback: SYG_PRIVATE_TERMS_FILE empty, the term
# list found via global git config seyag.privateTermsFile (isolated HOME).
printf 'Ships the lumina-vault rewrite.\n' > "$T/b10.md"
HOME="$T/home" git config --global seyag.privateTermsFile "$TERMS"
OPEN_ENV=(SYG_PRIVATE_TERMS_FILE=)
git -C "$R" config seyag.publicRepo true
run_open "Clean title" "$T/b10.md"
OPEN_ENV=()
first_line=$(printf '%s\n' "$out" | sed -n '1p')
[[ "$rc" -eq 1 && "$first_line" == "pr-open: BLOCK: private term in body line 1: "* ]] \
  && ok "case10: global-config fallback supplies the terms" \
  || bad "case10: rc $rc, first: $first_line"
[ ! -s "$GH_LOG" ] && ok "case10: gh never called" || bad "case10: gh called"

# Case 11 — fallback off: empty env var and no global config -> no term
# check, PR still created (the hook's own fail mode for no terms).
mkdir "$T/home2"
OPEN_ENV=(SYG_PRIVATE_TERMS_FILE= HOME="$T/home2")
run_open "Clean title" "$T/b10.md"
OPEN_ENV=()
[ "$rc" -eq 0 ] && ok "case11: no terms anywhere -> no term check, rc 0" \
  || bad "case11: rc $rc: $out"
[ "$(wc -l < "$GH_LOG")" -eq 1 ] && ok "case11: PR created" \
  || bad "case11: gh calls: $(wc -l < "$GH_LOG")"

# Case 12 — a toplevel holding an apostrophe: the arm line escapes it the
# pr-monitor-reminder way so the printed command pastes cleanly.
R2="$T/repo'fix"
mkdir -p "$R2"
git -C "$R2" init -q -b main
git -C "$R2" config user.email t@t && git -C "$R2" config user.name t
echo base > "$R2/f.txt" && git -C "$R2" add f.txt && git -C "$R2" commit -qm base
git -C "$R2" config seyag.publicRepo false
printf 'Clean body.\n' > "$T/b12.md"
run_open "Clean title" "$T/b12.md" "$R2"
[ "$rc" -eq 0 ] && ok "case12: rc 0 with an apostrophe toplevel" \
  || bad "case12: rc $rc: $out"
[[ "$out" == *"repo'\\''fix'"* ]] \
  && ok "case12: embedded quote escaped in the arm line" \
  || bad "case12: arm line: $(printf '%s\n' "$out" | sed -n '2p')"

# Case 13 — the 5 s time box: a catastrophic pattern blocks with a message
# naming the terms file, the pattern text never printed (the hook's fixture).
REDOS="$T/redos"
printf '%s\n' '(a+)+$' > "$REDOS"
printf '%s\n' "$(printf 'a%.0s' {1..40})b" > "$T/b13.md"
OPEN_ENV=(SYG_PRIVATE_TERMS_FILE="$REDOS")
git -C "$R" config seyag.publicRepo true
run_open "Clean title" "$T/b13.md"
OPEN_ENV=()
[ "$rc" -eq 1 ] \
  && [[ "$out" == *"pr-open: BLOCK: matching the terms took over 5 s; simplify the patterns in $REDOS"* ]] \
  && ok "case13: time-box message names the terms file" \
  || bad "case13: rc $rc, out: $out"
[[ "$out" != *"(a+)+"* ]] && ok "case13: pattern text never printed" \
  || bad "case13: pattern leaked: $out"
[ ! -s "$GH_LOG" ] && ok "case13: gh never called" || bad "case13: gh called"

# Case 14 — every supported option forwards to gh in one call: the shim
# logs the whole command line, so one positive control pins the five.
printf 'Clean body.\n' > "$T/b14.md"
git -C "$R" config seyag.publicRepo false
OPEN_ARGS=(--base dev --head main --draft)
run_open "Clean title" "$T/b14.md"
OPEN_ARGS=()
[ "$rc" -eq 0 ] && ok "case14: all-options run rc 0" || bad "case14: rc $rc: $out"
logged=$(sed -n '1p' "$GH_LOG")
[[ "$logged" == *"--title Clean title"* && "$logged" == *"--body-file $T/b14.md"* \
  && "$logged" == *"--base dev"* && "$logged" == *"--head main"* \
  && "$logged" == *"--draft"* ]] \
  && ok "case14: the five supported options forwarded to gh" || bad "case14: gh line: $logged"

# Case 15 — detached HEAD without --head: named error before any scan,
# gh never called (the branch state is restored right after the run).
printf 'Clean body.\n' > "$T/b15.md"
git -C "$R" checkout -q --detach
run_open "Clean title" "$T/b15.md"
git -C "$R" checkout -q main
first_line=$(printf '%s\n' "$out" | sed -n '1p')
[ "$rc" -eq 2 ] && [ "$first_line" = "pr-open: detached HEAD; pass --head BRANCH" ] \
  && ok "case15: detached HEAD named" || bad "case15: rc $rc, first: $first_line"
[ ! -s "$GH_LOG" ] && ok "case15: gh never called" || bad "case15: gh called"

# Case 16 — --head on a detached checkout: the arm line names the ref the
# flag chose (the escaped-quote shape since the branch-escape fix; plain
# main carries no quote, so the plain text asserts the same bytes).
git -C "$R" checkout -q --detach
OPEN_ARGS=(--head main)
run_open "Clean title" "$T/b15.md"
OPEN_ARGS=()
git -C "$R" checkout -q main
[ "$rc" -eq 0 ] && ok "case16: --head main accepted, rc 0" || bad "case16: rc $rc: $out"
[[ "$out" == *"refs/heads/main"* ]] && ok "case16: arm line uses the --head ref" \
  || bad "case16: arm line: $(printf '%s\n' "$out" | sed -n '2p')"

# Case 17 — the fork form of --head: rejected before gh (the arm line
# cannot watch a fork ref from this checkout).
OPEN_ARGS=(--head someone:main)
run_open "Clean title" "$T/b15.md"
OPEN_ARGS=()
first_line=$(printf '%s\n' "$out" | sed -n '1p')
[ "$rc" -eq 2 ] && [[ "$first_line" == *"fork form"* ]] \
  && ok "case17: fork-form --head rejected" || bad "case17: rc $rc, first: $first_line"
[ ! -s "$GH_LOG" ] && ok "case17: gh never called" || bad "case17: gh called"

# Case 18 — usage errors: an unknown flag, a flag missing its value, and an
# unreadable body file each exit 2 with an empty gh log.
OPEN_ARGS=(--bogus)
run_open "Clean title" "$T/b15.md"
OPEN_ARGS=()
[ "$rc" -eq 2 ] && ok "case18a: unknown flag rc 2" || bad "case18a: rc $rc: $out"
[ ! -s "$GH_LOG" ] && ok "case18a: gh never called" || bad "case18a: gh called"
OPEN_ARGS=(--title)
run_open "Clean title" "$T/b15.md"
OPEN_ARGS=()
[ "$rc" -eq 2 ] && ok "case18b: missing value rc 2" || bad "case18b: rc $rc: $out"
[ ! -s "$GH_LOG" ] && ok "case18b: gh never called" || bad "case18b: gh called"
printf 'Clean body.\n' > "$T/noread.md"
chmod 000 "$T/noread.md"
run_open "Clean title" "$T/noread.md"
first_line=$(printf '%s\n' "$out" | sed -n '1p')
[ "$rc" -eq 2 ] && [[ "$first_line" == "pr-open: cannot read body file: "* ]] \
  && ok "case18c: unreadable body rc 2" || bad "case18c: rc $rc, first: $first_line"
[ ! -s "$GH_LOG" ] && ok "case18c: gh never called" || bad "case18c: gh called"
chmod 644 "$T/noread.md"

# Case 19 — gh succeeds but prints no pull URL: rc 1, the missing URL
# named on stderr, no arm line (FAKE_GH_NO_URL trims the shim's URL line).
printf 'Clean body.\n' > "$T/b19.md"
FAKE_GH_NO_URL=1
run_open "Clean title" "$T/b19.md"
FAKE_GH_NO_URL=
[ "$rc" -eq 1 ] && ok "case19: missing URL rc 1" || bad "case19: rc $rc: $out"
[[ "$out" == *"no PR URL in gh's output"* ]] && ok "case19: missing URL named" \
  || bad "case19: no message: $out"
[[ "$out" != *"PR #42"* ]] && ok "case19: no arm line" || bad "case19: arm line: $out"

# Case 20 — python3 missing: the scans fail open but the skip is named on
# stderr, and the PR still creates (a command the user runs explicitly, so
# the skip must be visible). A python3-free PATH: a pruned mirror of the
# system bin dirs (python*/pip*/idle*/pydoc* dropped), with the shim dir
# first so gh still resolves to the fake.
NOPY="$T/nopy"
mkdir "$NOPY"
for d in /usr/bin /bin; do
  for f in "$d"/*; do
    b=${f##*/}
    case $b in python* | pip* | idle* | pydoc*) continue ;; esac
    [ -e "$NOPY/$b" ] || ln -s "$f" "$NOPY/$b" 2>/dev/null
  done
done
if [ -e "$NOPY/bash" ] && [ -e "$NOPY/git" ] && [ -e "$NOPY/sed" ] \
  && ! env PATH="$T/bin:$NOPY" bash -c 'command -v python3' >/dev/null 2>&1; then
  OPEN_ENV=(PATH="$T/bin:$NOPY")
  run_open "Clean title" "$T/b15.md"
  OPEN_ENV=()
  [ "$rc" -eq 0 ] && ok "case20: no python3 -> scans skipped, rc 0" \
    || bad "case20: rc $rc: $out"
  [[ "$out" == *"pr-open: python3 missing; the session-link and private-term scans were skipped"* ]] \
    && ok "case20: the skip named on stderr" || bad "case20: no skip note: $out"
  [ -s "$GH_LOG" ] && ok "case20: PR created" || bad "case20: gh not called"
else
  bad "case20: could not build a python3-free PATH on this machine"
fi

# Case 21 — --repo refused outright (owner ruling): upstream-submission-guard
# cannot check a foreign repo through this wrapper; gh log stays empty.
printf 'Clean body.\n' > "$T/b21.md"
git -C "$R" config seyag.publicRepo false
OPEN_ARGS=(--repo example/other)
run_open "Clean title" "$T/b21.md"
OPEN_ARGS=()
[ "$rc" -eq 2 ] && ok "case21: --repo refused, rc 2" || bad "case21: rc $rc: $out"
first_line=$(printf '%s\n' "$out" | sed -n '1p')
[[ "$first_line" == "pr-open: --repo is not supported"* ]] \
  && ok "case21: refusal names upstream-submission-guard" \
  || bad "case21: first line: $first_line"
[ ! -s "$GH_LOG" ] && ok "case21: gh never called" || bad "case21: gh called"

echo "---"
if [ "$fail" -eq 0 ]; then
  echo "all ok"
else
  echo "$fail failing case group(s)"
fi
exit "$fail"
