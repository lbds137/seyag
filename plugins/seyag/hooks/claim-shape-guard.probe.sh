#!/bin/bash
# Fixture check for claim-shape-guard.sh — run after ANY edit to the hook.
#
# The hook exits 0 on every path (fail-open advisory), so exit code alone
# carries no information: every case asserts on OUTPUT. Fire means the JSON's
# hookSpecificOutput.additionalContext carries the CLAIM-SHAPE GUARD banner
# (and the expected claim line); silent means no stdout at all.
#
# The hook reads real git state (`git diff --cached` in CLAUDE_PROJECT_DIR),
# so the fixtures are staged changes in a THROWAWAY repo under $(mktemp -d) —
# the probe never touches this repo's index. Every case goes through the
# hook's real PreToolUse JSON stdin shape (like sibling probes), never by
# sourcing.
#
# Token semantics are ported pin-for-pin from the source probe this hook came
# from: one fixture per `cannot be` value token, the substring-collision pins
# behind the load-bearing ([^a-z]|$) boundary, the `reached` exclusion, the
# accepted inflected-form recall loss, and the meta-path/markdown exclusions.
# A later section pins which repo the scan targets: a `git -C <dir>` redirect
# (last-git-wins, word-bounded cut, quote strip, .cwd anchor, fail-open) and
# the payload's .cwd for a bare commit, against a second nested repo.
# Only the channel SHAPES differ (JSON additionalContext vs the source's
# git-hook stdout), so the fire/silent check reads the banner out of the JSON.
#
# Usage: plugins/seyag/hooks/claim-shape-guard.probe.sh   (from anywhere)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$SCRIPT_DIR/claim-shape-guard.sh"

REPO=$(mktemp -d)
EMPTY=""
trap 'rm -rf "$REPO"; [ -n "$EMPTY" ] && rm -rf "$EMPTY"' EXIT

git init -q -b main "$REPO" >/dev/null 2>&1 || {
    echo "FATAL: could not init throwaway repo" >&2
    exit 1
}
git -C "$REPO" config user.email probe@example.invalid
git -C "$REPO" config user.name 'Probe Seyag'
git -C "$REPO" config commit.gpgsign false

# An initial commit gives `git reset` a HEAD to unstage against, so each
# fixture below is measured in isolation rather than accumulating.
printf 'seed\n' >"$REPO/seed.txt"
git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" commit -q -m 'probe: seed' >/dev/null 2>&1

# A second throwaway repo NESTED in the first, same recipe: the git -C cases
# need a second repo to redirect to, and nesting gives the relative-path case
# a dir whose name resolves against a known parent. `other` is never staged in
# $REPO, so it cannot pollute $REPO's diff, and cleanup rides the $REPO trap
# above — no trap of its own.
OTHER="$REPO/other"
git init -q -b main "$OTHER" >/dev/null 2>&1 || {
    echo "FATAL: could not init nested throwaway repo" >&2
    exit 1
}
git -C "$OTHER" config user.email probe@example.invalid
git -C "$OTHER" config user.name 'Probe Seyag'
git -C "$OTHER" config commit.gpgsign false
printf 'seed\n' >"$OTHER/seed.txt"
git -C "$OTHER" add -A >/dev/null 2>&1
git -C "$OTHER" commit -q -m 'probe: seed' >/dev/null 2>&1

FAILURES=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# stage_fixture <relpath> <content>  — clear the index, then stage ONE file.
#
# The add is scoped to <relpath> rather than `-A` on purpose: `git reset`
# unstages but leaves every earlier fixture sitting untracked in the worktree,
# so an `-A` here would re-stage all of them and each case would inherit the
# previous ones' claim lines.
stage_fixture() {
    local relpath="$1" content="$2"
    git -C "$REPO" reset -q >/dev/null 2>&1
    mkdir -p "$REPO/$(dirname "$relpath")"
    printf '%s\n' "$content" >"$REPO/$relpath"
    git -C "$REPO" add -- "$relpath" >/dev/null 2>&1
}

# run <command> [project-dir] [shell-cwd] — feeds the hook its real PreToolUse
# JSON stdin shape with CLAUDE_PROJECT_DIR at the throwaway repo (default).
# The optional 3rd arg sets the payload's top-level `cwd` (the Bash shell's
# persistent cwd, the same key cwd-drift-guard.sh reads); without it the
# payload is the older shape with no cwd key. Sets RC, OUT (raw stdout) and
# CTX (the banner text; empty when nothing printed).
run() {
    local payload dir="${2:-$REPO}" cwd="${3:-}"
    if [ -n "$cwd" ]; then
        payload=$(jq -n --arg c "$1" --arg d "$cwd" \
            '{tool_name:"Bash", tool_input:{command:$c}, cwd:$d}')
    else
        payload=$(jq -n --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}')
    fi
    OUT=$(printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$dir" "$HOOK" 2>/dev/null)
    RC=$?
    CTX=$(jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$OUT" 2>/dev/null || echo "")
}

check_fire() { # $1=label  $2=expected line fragment inside the banner
    if [ "$RC" -eq 0 ] && [[ "$CTX" == *"CLAIM-SHAPE GUARD"* && "$CTX" == *"$2"* ]]; then
        pass "$1"
    else
        fail "$1"; printf 'rc=%s out=%s\n' "$RC" "$OUT" | sed 's/^/      /'
    fi
}

check_silent() { # $1=label
    if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
        pass "$1"
    else
        fail "$1"; printf 'rc=%s out=%s\n' "$RC" "$OUT" | sed 's/^/      /'
    fi
}

CMD='git commit -m "probe"'

# --- the channel shape, once -------------------------------------------------
stage_fixture 'src/channel.ts' '// this field is always populated by the enqueue path'
run "$CMD"
[ "$RC" -eq 0 ] \
  && [[ $(jq -r '.hookSpecificOutput.hookEventName' <<<"$OUT") == "PreToolUse" ]] \
  && pass "banner arrives as PreToolUse hookSpecificOutput.additionalContext, exit 0" \
  || { fail "banner arrives as PreToolUse hookSpecificOutput.additionalContext, exit 0"; printf '%s\n' "$OUT" | sed 's/^/      /'; }
check_fire "claim-shaped comment staged in a .ts file" "always populated"

# --- excluded meta paths and markdown (ported exclusion pins) ----------------
stage_fixture 'tracker/task-1.md' '// this field is always populated by the enqueue path'
run "$CMD"
check_silent "same claim line under tracker/ (excluded meta path)"

stage_fixture 'docs/reference/notes.md' 'The producer guarantees the id is never null here.'
run "$CMD"
check_silent "claim line under docs/ (excluded meta path)"

# A NON-markdown fixture on purpose: a .md file here would be silenced by the
# markdown-wide exclusion regardless of whether the .claude/ path-prefix branch
# works at all, so the case would pass through a regression in that branch.
stage_fixture '.claude/hooks/probe-fixture.sh' '# a field that is always set needs a producer citation'
run "$CMD"
check_silent "claim line under .claude/ (excluded meta path, non-markdown)"

# Inherited from the source hook: hook-config surfaces necessarily quote the
# phrasings the guard looks for, so .husky/ stays excluded here too.
stage_fixture '.husky/pre-commit' '# scan for "always populated" / "never null" claims'
run "$CMD"
check_silent "claim phrasing in a .husky/ hook script (excluded, inherited from source)"

stage_fixture 'CLAUDE.md' 'The pool max is guaranteed to apply at boot.'
run "$CMD"
check_silent "claim line in root CLAUDE.md (excluded meta file)"

stage_fixture 'services/voice-engine/CLAUDE.md' 'Responses are always present here.'
run "$CMD"
check_silent "claim line in a per-service CLAUDE.md (excluded meta file)"

stage_fixture 'CURRENT.md' 'The nightly sync is always gated on the hour window.'
run "$CMD"
check_silent "claim line in a root .md (markdown-wide exclusion)"

# --- other runtime-claim arms fire in a code file ----------------------------
stage_fixture 'src/plain.ts' 'export const limit = 100;'
run "$CMD"
check_silent "staged change with no claim shapes"

stage_fixture 'src/never.ts' 'const id = row.id; // never undefined once the job is queued'
run "$CMD"
check_fire "never-<state> phrasing in a code file" "never undefined"

stage_fixture 'src/cannot.ts' 'return dedupe(rows); // a duplicate id cannot happen here'
run "$CMD"
check_fire "cannot-<verb> phrasing in a code file" "cannot happen"

# One pin per remaining cannot-<verb> sub-branch: the alternation is
# 3 branches wide and a typo in any single branch must fail here rather than
# silently stop catching that claim shape.
stage_fixture 'src/cannotmatch.ts' 'filter(rows); // a duplicate cannot match under this key'
run "$CMD"
check_fire "cannot-<verb>: cannot match" "cannot match"

stage_fixture 'src/cannotoccur.ts' 'drain(q); // a partial write cannot occur before the flush'
run "$CMD"
check_fire "cannot-<verb>: cannot occur" "cannot occur"

stage_fixture 'src/isalways.ts' 'seed(map); // the map is always seeded before first read'
run "$CMD"
check_fire "is-always phrasing in a code file" "always seeded"

stage_fixture 'src/arealways.ts' 'use(rows); // rows are always sorted by the caller'
run "$CMD"
check_fire "are-always phrasing in a code file" "are always sorted"

stage_fixture 'src/guaranteed.ts' 'flush(); // the buffer is guaranteed to flush on close'
run "$CMD"
check_fire "guaranteed-to phrasing in a code file" "guaranteed to flush"

stage_fixture 'src/onlyever.ts' 'const job = queue[0]; // this queue only ever holds one job'
run "$CMD"
check_fire "only-ever phrasing in a code file" "only ever holds"

# --- the always-arm, one fixture per sub-alternative -------------------------
stage_fixture 'src/aw0.ts' '// the field is always populated at this point'
run "$CMD"
check_fire "always-arm: always populated" "always populated"

stage_fixture 'src/aw1.ts' '// the field is always set at this point'
run "$CMD"
check_fire "always-arm: always set" "always set"

stage_fixture 'src/aw2.ts' '// the field is always non-null at this point'
run "$CMD"
check_fire "always-arm: always non-null" "always non-null"

stage_fixture 'src/aw3.ts' '// the field is always present at this point'
run "$CMD"
check_fire "always-arm: always present" "always present"

stage_fixture 'src/aw4.ts' '// the field is always returned at this point'
run "$CMD"
check_fire "always-arm: always returned" "always returned"

# --- always-arm sub-branch, CONFOUND-FREE (one fixture per sub-token) --------
# MASKING TRAP the fixtures above carry: every one of them reads "is always",
# so the broader (is|are) always alternative fires on all five and deleting the
# entire always (populated|set|non-null|present|returns) sub-branch would pass
# them silently — aw4 ("always returned") never even contained the sub-token,
# leaving `returns` with zero real coverage. Each fixture below fires through
# the sub-branch ALONE: active voice, no is/are before "always", and none of
# the other arms' phrasings (never/cannot/guaranteed to/only ever) anywhere in
# the line, so a typo in any single sub-token fails here instead of hiding.
stage_fixture 'src/awf0.ts' 'load(rows); // this loader always populated the cache on boot'
run "$CMD"
check_fire "always-arm sub-token (confound-free): always populated" "always populated"

stage_fixture 'src/awf1.ts' 'boot(cfg); // this parser always set the flag before first read'
run "$CMD"
check_fire "always-arm sub-token (confound-free): always set" "always set"

stage_fixture 'src/awf2.ts' 'deref(p); // this wrapper keeps the handle always non-null after init'
run "$CMD"
check_fire "always-arm sub-token (confound-free): always non-null" "always non-null"

stage_fixture 'src/awf3.ts' 'validate(row); // this schema keeps every field always present in the output'
run "$CMD"
check_fire "always-arm sub-token (confound-free): always present" "always present"

stage_fixture 'src/awf4.ts' 'get(k); // this getter always returns the cached value'
run "$CMD"
check_fire "always-arm sub-token (confound-free): always returns" "always returns"

# --- the never-arm, one fixture per sub-alternative --------------------------
stage_fixture 'src/nv0.ts' '// the field is never null at this point'
run "$CMD"
check_fire "never-arm: never null" "never null"

stage_fixture 'src/nv1.ts' '// the field is never empty at this point'
run "$CMD"
check_fire "never-arm: never empty" "never empty"

stage_fixture 'src/nv2.ts' '// the field is never undefined at this point'
run "$CMD"
check_fire "never-arm: never undefined" "never undefined"

stage_fixture 'src/nv3.ts' '// the callback never happens at this point'
run "$CMD"
check_fire "never-arm: never happens" "never happens"

stage_fixture 'src/nv4.ts' '// the alarm never fires at this point'
run "$CMD"
check_fire "never-arm: never fires" "never fires"

# --- `cannot be` narrowing: both directions ----------------------------------
# `cannot be` is narrowed to a following VALUE token. Both directions are
# pinned, because the allow side is the whole point of the narrowing: bare
# `cannot be` fired on ordinary design prose about code structure, and a guard
# that mostly cries wolf trains the reader to skim past its true positives.
stage_fixture 'src/cannotnull.ts' 'assert(id); // the id cannot be null once queued'
run "$CMD"
check_fire "cannot-be with a value token is still a runtime claim" "cannot be null"

stage_fixture 'src/cannotempty.ts' 'use(rows); // the batch cannot be empty here'
run "$CMD"
check_fire "cannot-be-empty is still a runtime claim" "cannot be empty"

# The exact line that false-fired in practice, on a comment about why two
# regex copies stay separate.
stage_fixture 'src/collapse.ts' '// They cannot be collapsed into one: each needs its own stripping'
run "$CMD"
check_silent "cannot-be-collapsed is design prose, not a runtime claim"

stage_fixture 'src/extract.ts' '// this helper cannot be extracted without three callbacks'
run "$CMD"
check_silent "cannot-be-extracted is design prose"

stage_fixture 'src/reuse.ts' '// the adapter cannot be reused across implementors'
run "$CMD"
check_silent "cannot-be-reused is design prose"

# --- the cannot-be value tokens, ONE FIXTURE PER TOKEN -----------------------
# The alternation is 13 branches wide and the probe is the only verification
# this hook gets, so a typo in any single branch must fail here rather than
# silently stop catching that claim shape. (Ported pin-for-pin from the
# source probe.)
stage_fixture 'src/tok0.ts' '// the value cannot be null at this point'
run "$CMD"
check_fire "value token: cannot be null" "cannot be null"

stage_fixture 'src/tok1.ts' '// the value cannot be empty at this point'
run "$CMD"
check_fire "value token: cannot be empty" "cannot be empty"

stage_fixture 'src/tok2.ts' '// the value cannot be undefined at this point'
run "$CMD"
check_fire "value token: cannot be undefined" "cannot be undefined"

stage_fixture 'src/tok3.ts' '// the value cannot be unset at this point'
run "$CMD"
check_fire "value token: cannot be unset" "cannot be unset"

stage_fixture 'src/tok4.ts' '// the value cannot be set at this point'
run "$CMD"
check_fire "value token: cannot be set" "cannot be set"

stage_fixture 'src/tok5.ts' '// the value cannot be present at this point'
run "$CMD"
check_fire "value token: cannot be present" "cannot be present"

stage_fixture 'src/tok6.ts' '// the value cannot be absent at this point'
run "$CMD"
check_fire "value token: cannot be absent" "cannot be absent"

stage_fixture 'src/tok7.ts' '// the value cannot be missing at this point'
run "$CMD"
check_fire "value token: cannot be missing" "cannot be missing"

stage_fixture 'src/tok8.ts' '// the value cannot be zero at this point'
run "$CMD"
check_fire "value token: cannot be zero" "cannot be zero"

stage_fixture 'src/tok9.ts' '// the value cannot be negative at this point'
run "$CMD"
check_fire "value token: cannot be negative" "cannot be negative"

stage_fixture 'src/tok10.ts' '// the value cannot be false at this point'
run "$CMD"
check_fire "value token: cannot be false" "cannot be false"

stage_fixture 'src/tok11.ts' '// the value cannot be true at this point'
run "$CMD"
check_fire "value token: cannot be true" "cannot be true"

stage_fixture 'src/tok12.ts' '// the value cannot be populated at this point'
run "$CMD"
check_fire "value token: cannot be populated" "cannot be populated"

# The `$` half of the boundary. Every fire fixture above has trailing text, so
# a typo shrinking ([^a-z]|$) to ([^a-z]) would pass all of them while silently
# dropping every claim that ENDS at the token — a completely ordinary shape for
# a short inline comment.
stage_fixture 'src/tokeol.ts' '// the id cannot be null'
run "$CMD"
check_fire "value token at end of line (the \$ half of the boundary)" "cannot be null"

# HYPHENATED COMPOUNDS STILL FIRE — the other half of the ([^a-z]|$) boundary.
# `[^a-z]` is a broad boundary, not a true word break (awk ERE has no \b), so
# any hyphenated compound built on a value token fires, exactly as the hook's
# LOAD-BEARING header note documents. These pins make that deliberate behavior
# visible: a future edit that "fixes" the boundary into a true word break
# passes every fire case above (they all end at non-hyphen boundaries) while
# silently flipping this documented behavior — these two cases are what fail.
stage_fixture 'src/hyph0.ts' '// this header cannot be null-terminated'
run "$CMD"
check_fire "hyphenated compound: cannot be null-terminated fires (documented boundary breadth)" "cannot be null-terminated"

stage_fixture 'src/hyph1.ts' '// cannot be zero-indexed'
run "$CMD"
check_fire "hyphenated compound: cannot be zero-indexed fires (documented boundary breadth)" "cannot be zero-indexed"

# One uppercase fixture pins the awk tolower: the token list is lowercase, and
# a regression dropping the tolower would silence every capitalized claim.
stage_fixture 'src/upper.ts' '// Cannot Be Null'
run "$CMD"
check_fire "uppercase phrasing fires (awk tolower pinned)" "Cannot Be Null"

# The `reached` exclusion is a reasoned decision, so it gets a pin like every
# other one. Under the old bare arm this fired; it must now stay silent, and an
# accidental re-addition of the token to the list has to fail here.
stage_fixture 'src/reached.ts' '// this branch cannot be reached'
run "$CMD"
check_silent "reached is out of scope by design (control flow, not a value)"

# The accepted recall loss, pinned so it reads as chosen rather than missed: an
# inflected form no longer fires. If a future edit decides to catch these, this
# case is where that intent gets stated.
stage_fixture 'src/nulled.ts' '// the config cannot be nulled once persisted'
run "$CMD"
check_silent "inflected forms fall outside the narrowed pattern (accepted)"

# `unset` gets its own collision pin because English is unusually rich in words
# that start with it — "unsettled", "unsettling" — making it the token most
# likely to meet a real collision.
stage_fixture 'src/unsettled.ts' '// this precedent cannot be unsettled by one case'
run "$CMD"
check_silent "collision: 'unsettled' must not match the 'unset' token"

# --- SUBSTRING COLLISIONS ----------------------------------------------------
# awk's `~` is a substring match with no \b support, so an unanchored
# alternation fired on ordinary English whose next word merely STARTS with a
# value token — reintroducing the exact false-positive class this narrowing
# exists to remove. The trailing ([^a-z]|$) is what stops it, and these pin it
# per colliding token.
stage_fixture 'src/coll0.ts' '// this cannot be settled without more data'
run "$CMD"
check_silent "collision: 'settled' must not match the 'set' token"

stage_fixture 'src/coll1.ts' '// this cannot be negatively impacted'
run "$CMD"
check_silent "collision: 'negatively' must not match the 'negative' token"

stage_fixture 'src/coll2.ts' '// the count cannot be zeroed out'
run "$CMD"
check_silent "collision: 'zeroed' must not match the 'zero' token"

stage_fixture 'src/coll3.ts' '// this cannot be falsely triggered'
run "$CMD"
check_silent "collision: 'falsely' must not match the 'false' token"

stage_fixture 'src/coll4.ts' '// this cannot be presently disabled'
run "$CMD"
check_silent "collision: 'presently' must not match the 'present' token"

# --- the 3-line COMMIT-wide cap ---------------------------------------------
# Five claim lines staged in one file; the banner is a pointer, not an
# exhaustive report, so exactly 3 match lines arrive.
git -C "$REPO" reset -q >/dev/null 2>&1
mkdir -p "$REPO/src"
cat >"$REPO/src/capped.ts" <<'EOF'
const a = 1; // always populated
const b = 2; // never null
const c = 3; // cannot happen
const d = 4; // guaranteed to run
const e = 5; // only ever one
EOF
git -C "$REPO" add -- src/capped.ts >/dev/null 2>&1
run "$CMD"
LINES=$(printf '%s\n' "$CTX" | grep -cE '^  ' || true)
if [ "$RC" -eq 0 ] && [[ "$CTX" == *"CLAIM-SHAPE GUARD"* ]] && [ "$LINES" -eq 3 ]; then
    pass "3-line cap: five claim lines staged, banner carries exactly 3"
else
    fail "3-line cap: five claim lines staged, banner carries exactly 3 (got $LINES)"; printf '%s\n' "$CTX" | sed 's/^/      /'
fi

# --- mixed staging: the excluded path must not suppress the code file --------
git -C "$REPO" reset -q >/dev/null 2>&1
mkdir -p "$REPO/docs" "$REPO/src"
printf '%s\n' 'Docs prose: the value is always present.' >"$REPO/docs/mixed.md"
printf '%s\n' 'const v = ctx.value; // guaranteed to exist after step 2' >"$REPO/src/mixed.ts"
git -C "$REPO" add -- docs/mixed.md src/mixed.ts >/dev/null 2>&1
run "$CMD"
check_fire "mixed staging: excluded doc beside a claim-shaped code file" "guaranteed to exist"

# --- An UNSTAGED claim must not fire — the guard reads the index -------------
git -C "$REPO" reset -q >/dev/null 2>&1
printf '%s\n' 'const x = 1; // this is always set before use' >"$REPO/src/unstaged.ts"
run "$CMD"
check_silent "claim-shaped line present in the worktree but not staged"

# --- Empty index (nothing staged at all) ------------------------------------
git -C "$REPO" reset -q >/dev/null 2>&1
run "$CMD"
check_silent "empty index"

# --- pre-filter: not a git commit -> no scan, no output ---------------------
printf '%s\n' 'const y = 1; // this is always set before use' >"$REPO/src/armed.ts"
git -C "$REPO" add -- src/armed.ts >/dev/null 2>&1
run 'git status --short'
check_silent "git command that is not a commit -> silent even with claims staged"
run 'echo hello'
check_silent "non-git command -> silent even with claims staged"

# --- fail-open shape: not a git repo at all -> silent, exit 0 ---------------
EMPTY=$(mktemp -d)
run 'git commit -m "probe"' "$EMPTY"
check_silent "CLAUDE_PROJECT_DIR outside any repo -> silent, exit 0"

# --- which repo the commit targets: git -C and the shell's own cwd -----------
# The hook scans the diff the COMMIT will commit, not CLAUDE_PROJECT_DIR's: a
# spaced `git -C <dir>` global option redirects the scan to <dir>, and a bare
# commit runs in the payload's .cwd (the shell's persistent cwd) when it
# carries one. The non-redirect traps (`commit -C <rev>` message reuse, an
# in-message `git -C`), the one-quote-pair strip on the -C dir (with its
# unquoted no-op control), the .cwd anchor a relative -C resolves against,
# fail-open on an unreadable -C dir AND on an unreadable payload-cwd anchor,
# the last-git-wins rule for a chained verify, the word-bounded commit cut,
# and the accepted leading-cd, quoted-early-cut and first--C-wins losses each
# get their own pin below. Between
# cases BOTH indexes reset, so a claim staged in one repo never leaks into
# the other's verdict.
stage_other() { # <relpath> <content> — mirror of stage_fixture for $OTHER
    git -C "$OTHER" reset -q >/dev/null 2>&1
    mkdir -p "$OTHER/$(dirname "$1")"
    printf '%s\n' "$2" >"$OTHER/$1"
    git -C "$OTHER" add -- "$1" >/dev/null 2>&1
}

git -C "$REPO" reset -q; git -C "$OTHER" reset -q
stage_other 'src/redirect.ts' '// this field is always populated at boot'
run "git -C \"$OTHER\" commit -m \"probe\""
check_fire "git -C <dir> commit scans THAT dir's staged diff" "always populated"

git -C "$REPO" reset -q; git -C "$OTHER" reset -q
stage_fixture 'src/notother.ts' '// this field is always populated at boot'
run "git -C \"$OTHER\" commit -m \"probe\""
check_silent "git -C <dir> commit ignores the session project's staged diff"

git -C "$REPO" reset -q; git -C "$OTHER" reset -q
stage_fixture 'src/msgreuse.ts' '// this field is always populated at boot'
run 'git commit -C HEAD'
check_fire "commit -C <rev> (message reuse) does not redirect" "always populated"

git -C "$REPO" reset -q; git -C "$OTHER" reset -q
stage_fixture 'src/inmsg.ts' '// this field is always populated at boot'
run "git commit -m \"next: use git -C $OTHER commit there\""
check_fire "git -C quoted inside a -m message does not redirect" "always populated"

git -C "$REPO" reset -q; git -C "$OTHER" reset -q
stage_other 'src/unquoted.ts' '// this field is always populated at boot'
run "git -C $OTHER commit -m \"probe\""
check_fire "unquoted -C dir redirects (strip must be a no-op)" "always populated"

git -C "$REPO" reset -q; git -C "$OTHER" reset -q
stage_other 'src/extraspace.ts' '// this field is always populated at boot'
run "git  -C \"$OTHER\" commit -m \"probe\""
check_fire "extra spaces before -C still redirect (tail regex takes zero-or-more)" "always populated"

git -C "$REPO" reset -q; git -C "$OTHER" reset -q
stage_other 'src/relative.ts' '// this field is always populated at boot'
pushd / >/dev/null 2>&1 || exit 1
run "git -C other commit -m \"probe\"" "$EMPTY" "$REPO"
popd >/dev/null 2>&1 || exit 1
check_fire "relative -C resolves against the payload cwd, not the hook's" "always populated"

git -C "$REPO" reset -q; git -C "$OTHER" reset -q
stage_fixture 'src/unreadable.ts' '// this field is always populated at boot'
pushd "$REPO" >/dev/null 2>&1 || exit 1
run 'git -C /nonexistent-csgc commit -m "probe"'
popd >/dev/null 2>&1 || exit 1
check_silent "-C to an unreadable dir fails open silent"

git -C "$REPO" reset -q; git -C "$OTHER" reset -q
# Both indexes carry the claim: $OTHER catches a fall-through to the hook's own cwd, $REPO a fallback to CLAUDE_PROJECT_DIR; the correct fail-open exit stays silent against both.
stage_other 'src/anchorfail.ts' '// this field is always populated at boot'
stage_fixture 'src/anchorfail-project.ts' '// this field is always populated at boot'
pushd "$REPO" >/dev/null 2>&1 || exit 1
run "git -C other commit -m \"probe\"" "$REPO" "/nonexistent-csgc-anchor"
popd >/dev/null 2>&1 || exit 1
check_silent "unreadable payload cwd anchor fails open silent"

git -C "$REPO" reset -q; git -C "$OTHER" reset -q
stage_other 'src/barecwd.ts' '// this field is always populated at boot'
run 'git commit -m "probe"' "$REPO" "$OTHER"
check_fire "bare commit scans the shell cwd's repo (payload .cwd)" "always populated"

git -C "$REPO" reset -q; git -C "$OTHER" reset -q
stage_fixture 'src/bareelsewhere.ts' '// this field is always populated at boot'
run 'git commit -m "probe"' "$REPO" "$OTHER"
check_silent "bare commit with a shell cwd elsewhere ignores the project's claims"

git -C "$REPO" reset -q; git -C "$OTHER" reset -q
stage_fixture 'src/siblinggitc.ts' '// this field is always populated at boot'
run "git -C \"$OTHER\" status && git commit -m \"probe\""
check_fire "an earlier sibling git -C does not redirect the bare commit" "always populated"

git -C "$REPO" reset -q; git -C "$OTHER" reset -q
stage_other 'src/committing.ts' '// this field is always populated at boot'
run "echo committing work && git -C \"$OTHER\" commit -m \"probe\""
check_fire "commit inside a word (\"committing\") does not cut the head early" "always populated"

git -C "$REPO" reset -q; git -C "$OTHER" reset -q
stage_other 'src/ledcd.ts' '// this field is always populated at boot'
run 'cd other && git commit -m "probe"' "$REPO" "$REPO"
check_silent "leading cd before the commit is not tracked (accepted)"

git -C "$REPO" reset -q; git -C "$OTHER" reset -q
stage_fixture 'src/quotedcut.ts' '// this field is always populated at boot'
run "echo \"use git -C $OTHER commit there\" && git commit -m \"probe\""
check_silent "quoted pre-commit text with a word-bounded commit cuts early (accepted)"

git -C "$REPO" reset -q; git -C "$OTHER" reset -q
stage_fixture 'src/doublec.ts' '// this field is always populated at boot'
run "git -C \"$REPO\" -C \"$OTHER\" commit -m \"probe\""
check_fire "successive -C pairs: the first dir wins here (accepted; git chdirs to the last)" "always populated"

# --- same-command content: add-chains and commit -a scan `git diff HEAD` -----
# The hook runs before the chain executes, so `git add X && git commit` and
# `git commit -am` arrive with an empty index. A TRACKED file is committed
# clean, then modified unstaged, for each case; the modification is reverted
# after the section so no later case inherits it. The untracked-file case pins
# the accepted loss: a brand-new file is not in `git diff HEAD`.
git -C "$REPO" reset -q; git -C "$OTHER" reset -q
mkdir -p "$REPO/src"
printf '%s\n' 'const t = 0;' >"$REPO/src/tracked.ts"
git -C "$REPO" add -- src/tracked.ts >/dev/null 2>&1
git -C "$REPO" commit -q -m 'probe: tracked seed' >/dev/null 2>&1
printf '%s\n' 'const t = 0; // this field is always populated at boot' >"$REPO/src/tracked.ts"

run 'git add src/tracked.ts && git commit -m "probe"'
check_fire "add-chain: git add X && git commit scans the tracked worktree change" "always populated"

run 'git commit -am "probe"'
check_fire "commit -am scans the tracked worktree change" "always populated"

run 'git commit -m "probe"'
check_silent "plain commit with the claim tracked-modified but unstaged stays silent"

git -C "$REPO" add -- src/tracked.ts >/dev/null 2>&1
run 'git add src/tracked.ts && git commit -m "probe"'
LINES=$(printf '%s\n' "$CTX" | grep -cE '^  ' || true)
if [ "$RC" -eq 0 ] && [[ "$CTX" == *"always populated"* ]] && [ "$LINES" -eq 1 ]; then
    pass "add-chain over an already-staged change reports the line once (dedupe)"
else
    fail "add-chain over an already-staged change reports the line once (dedupe; got $LINES)"; printf '%s\n' "$CTX" | sed 's/^/      /'
fi
git -C "$REPO" reset -q >/dev/null 2>&1
git -C "$REPO" checkout -q -- src/tracked.ts >/dev/null 2>&1

printf '%s\n' '// this field is always populated at boot' >"$REPO/src/brandnew.ts"
run 'git add src/brandnew.ts && git commit -m "probe"'
check_silent "add-chain of a brand-new untracked file is not in git diff HEAD (accepted)"

# The -a test reads only the commit's own line: a ` -a ` inside a heredoc
# message body must not widen the scan; `-am` on the command line still does.
printf '%s\n' 'const t = 0; // this field is always populated at boot' >"$REPO/src/tracked.ts"
run $'git commit -F- <<EOF\nfix: stop passing -a to the tool\nEOF'
check_silent "a -a inside a heredoc message body does not widen the scan"
run 'git commit -am x'
check_fire "commit -am x still widens after the newline cut" "always populated"
run $'git commit \\\n  -a -m x'
check_fire "a -a after a backslash-newline continuation widens (continuation joined)" "always populated"
run 'git commit -m "a & b" -a'
check_silent "a separator inside a quoted message ends the segment early (accepted miss)"
run 'git commit -m "flag -a is neat"'
check_fire "a quoted -a in a one-line -m message widens the scan (accepted over-fire)" "always populated"
git -C "$REPO" checkout -q -- src/tracked.ts >/dev/null 2>&1

echo "---"
echo "$FAILURES failed"
[ "$FAILURES" -eq 0 ]
