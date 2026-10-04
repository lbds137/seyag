#!/bin/bash
# PreToolUse hook (matcher: Bash) — as a `git commit` is about to run, scan the
# STAGED diff's added lines for claim-shaped assertions — "always populated",
# "never null", "cannot happen", "guaranteed to", "only ever". (An add-chain or
# `commit -a` also scans `git diff HEAD`; see the note above SCAN_WORKTREE.)
#
# Those phrasings state what a field or value HOLDS at runtime, which is a
# claim only the producer can settle (seyag core.md § Don't present
# speculation as fact — the producer is authoritative on what a field HOLDS).
# A doc comment states the author's intent at writing time and drifts silently;
# near-identical sibling interfaces make a plausible-looking declaration weak
# evidence.
#
# `cannot be` is NARROWED to a following value token (null/empty/set/…) rather
# than matching bare. Unqualified, it fired on ordinary design prose about code
# STRUCTURE — "cannot be collapsed into one", "cannot be extracted", "cannot be
# reused" — which asserts nothing about runtime and has no producer to cite.
# That noise is not free: a guard whose output is mostly false positives trains
# the reader to skim past the true ones. The other arms (`always populated`,
# `never null`, `cannot happen`) are already runtime-claim-shaped and are left
# alone.
#
# The trailing ([^a-z]|$) is LOAD-BEARING, not tidiness. awk's `~` is a
# substring match with no \b, so an unanchored alternation matched whenever the
# next word merely STARTS with a token: "cannot be settled" hit `set`, "cannot
# be negatively impacted" hit `negative`, "cannot be zeroed out" hit `zero`.
# That is the same design-prose false positive the narrowing exists to remove,
# reintroduced through the back door.
#
# `[^a-z]` is a broad boundary, not a true word break — awk ERE has no \b — so
# ANY hyphenated compound built on a token still fires: "cannot be
# false-positive", "cannot be zero-indexed", "cannot be null-terminated". The
# limitation is not specific to one token, and a reader who assumes otherwise
# will be surprised by the second one. Left as is: the constructions are rare,
# and over-firing on an advisory guard costs a glance where under-firing costs
# the signal entirely.
#
# `reached` was considered for the token list and left OUT: "this branch cannot
# be reached" is a control-flow claim, not a claim about what a value holds, so
# it sits outside this guard's stated scope and reads like the design prose
# above. If reachability claims ever deserve a guard, that is its own decision
# with its own evidence. Pinned silent in the probe so the decision cannot be
# reverted by accident.
#
# ACCEPTED RECALL LOSS: only the exact token form fires, so inflected ones no
# longer do — "cannot be nulled / emptied / populating" are real value claims
# that now pass unflagged, where the bare arm caught them. This is a deliberate
# trade of recall for precision, not an oversight, and it is not free.
#
# Not fixed by adding the inflections, because the ambiguity is genuine rather
# than a vocabulary gap: "the count cannot be zeroed out" is pinned SILENT here
# as design prose, yet it is defensible as a value claim. Deciding that sentence
# either way requires the reader's context, which is exactly the judgement the
# bare arm made badly and noisily. A guard that fires on the unambiguous forms
# and stays quiet on the arguable ones is the version people keep reading.
#
# Channel: this runs as a PreToolUse Bash hook, NOT as a git hook. Plain hook
# stdout does not reach the agent — the same gap pr-monitor-reminder.sh probed
# and confirmed for every matcher — so the channel that DELIVERS is
# hookSpecificOutput.additionalContext, per the Claude Code hooks reference
# ("Add context for Claude": PreToolUse additionalContext reaches Claude next
# to the tool result). No permissionDecision field is ever emitted, so the
# hook cannot block: the commit proceeds either way, and the banner is read
# BEFORE the commit object exists — an earlier moment than the source's
# pre-commit channel, which an agent only sees after `git commit` returns.
# The practical remedy is an ordinary edit (or `git commit --amend`), same
# direction as the source.
#
# Path exclusions: tracker/, backlog/, docs/, .claude/, .husky/, and ALL *.md
# files. Markdown is prose that legitimately DESCRIBES these phrasings
# (CLAUDE.md, READMEs, backlog notes — this hook's own source too); the
# guarded surface is claims entering CODE. `.husky/` is inherited from the
# source this hook was ported from, for the same reason as `.claude/`: hook-
# and skill-config surfaces necessarily quote the phrasings they guard, and
# repos that still carry a pre-commit hook flag its own description comment.
# Filtering happens on the diff's `+++ b/<path>` headers, so a mixed commit
# still scans its code files.
#
# Advisory only: never blocks, always exits 0, and every git/awk/jq failure
# fails open.
#
# Fixture check: run plugins/seyag/hooks/claim-shape-guard.probe.sh after
# ANY edit.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
TOOL_NAME=$(jq -r '.tool_name // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ "$TOOL_NAME" = "Bash" ] || exit 0

COMMAND=$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ -n "$COMMAND" ] || exit 0

# Cheap pre-filter before spawning git: only a word-bounded `git` followed by
# a word-bounded `commit` anywhere in the command can be a commit invocation.
# (Sibling prefilter style. A false positive here only costs one
# `git diff --cached`, so the filter stays loose rather than reimplementing
# the command parser — the guard is advisory and fail-open.)
if ! grep -qE '(^|[[:space:]&|;(`])git([[:space:]]|$)' <<<"$COMMAND"; then
  exit 0
fi
if ! grep -qE '(^|[[:space:]&|;(`=-])commit([[:space:]]|$)' <<<"$COMMAND"; then
  exit 0
fi

# The staged diff to scan is the one the COMMIT will commit, not necessarily
# the session project's. A `git -C <dir> commit` runs in <dir> (the
# delegation flow commits a worktree from a session rooted elsewhere), and a
# bare commit runs in the shell's own persistent cwd — either can be a
# different repo than CLAUDE_PROJECT_DIR, whose diff is then the wrong one:
# silently empty, so real claims pass unflagged.
# The -C must belong to the git the commit belongs to: the command is cut at
# the first WORD-BOUNDED commit (a `commit` inside "committing", a path
# segment or a -m message must not cut early), and only the LAST git token
# before that cut can carry it — an earlier sibling's `git -C` in a chained
# verify (`git -C <wt> diff --stat && git commit`) redirects the scan to a
# repo this commit never touches. Only the spaced global form is parsed: an
# attached -C<dir> (which git itself rejects), `commit -C <rev>` (message
# reuse, which sits after the cut) and a `git -C` quoted inside a -m message
# (same) all fall through. A variable or space-bearing path and an
# unreadable dir or cwd anchor fail open below, same as before this
# redirect existed. Two accepted losses, both pinned in the probe: a quoted
# string BEFORE the commit holding a word-bounded ` commit ` plus a `git -C`
# cuts the head at the quoted text and can redirect on its quoted dir; and
# successive `-C` pairs — git chdirs to the LAST, this parse keeps the FIRST.
# The three EREs live in variables: a raw backtick in a class is read as
# command substitution when the pattern sits inline in [[ =~ ]] (the file
# does not parse), and a quoted pattern would match literally — the variable
# form is the sanctioned ERE path.
# The greedy .* in GIT_BOUNDARY_RE is load-bearing twice: it selects the LAST
# boundary-git AND anchors the match at offset 0, so its length is the tail's
# offset — a non-greedy rewrite breaks the slice.
GIT_C_DIR=""
GIT_COMMIT_RE='(^|[[:space:]&|;(`=-])commit([[:space:]]|$)'
GIT_BOUNDARY_RE='(^|.*[[:space:]&|;(`])git([[:space:]]|$)'
GIT_C_TAIL_RE='^[[:space:]]*-C[[:space:]]+([^[:space:]]+)'
CMD_HEAD=$COMMAND
CMD_TAIL=""
if [[ $COMMAND =~ $GIT_COMMIT_RE ]]; then
    CMD_HEAD=${COMMAND%%"$BASH_REMATCH"*}
    CMD_TAIL=${COMMAND#*"$BASH_REMATCH"}
fi

# Nothing is staged yet when the commit's content arrives in the SAME command:
# PreToolUse runs before the chain executes, so `git add X && git commit` and
# `git commit -a/-am/--all` show an empty index here. For those two shapes the
# scan ALSO reads `git diff HEAD` (tracked working-tree changes vs HEAD), with
# the reported lines deduped. The add test is loose (a `git … add|stage` in the
# head, not crossing a ;|& separator), and the -a test reads only the commit's
# own segment (backslash-newline continuations joined first, then cut at the
# first ;|& or newline, so a heredoc or multi-line message body never counts)
# for `--all` or a short-flag cluster holding `a`; a `-a` quoted inside a
# one-line -m message still widens the scan. Over-firing costs a glance.
# ACCEPTED LOSS, pinned in the probe: a brand-new UNTRACKED file added in the
# same command is not in `git diff HEAD`, so its claims pass unflagged; and the
# widened scan also shows tracked changes the add leaves out of the commit.
# ACCEPTED MISS: the cut is not quote-aware, so a separator inside a quoted
# message ends the segment early — `git commit -m "a & b" -a` is not widened.
# ACCEPTED OVER-FIRE, the inverse: `git commit -m "flag -a is neat"` widens.
SCAN_WORKTREE=0
GIT_ADD_RE='(^|[[:space:]&|;(`])git[[:space:]]([^&|;]*[[:space:]])?(add|stage)([[:space:]]|$)'
COMMIT_ALL_RE='(^|[[:space:]])(--all|-[[:alpha:]]*a[[:alpha:]]*)([[:space:]]|$)'
CMD_TAIL_JOINED=${CMD_TAIL//$'\\\n'/ }
COMMIT_SEG=${CMD_TAIL_JOINED%%[;&|$'\n']*}
if [[ $CMD_HEAD =~ $GIT_ADD_RE ]] || [[ $COMMIT_SEG =~ $COMMIT_ALL_RE ]]; then
    SCAN_WORKTREE=1
fi
if [[ $CMD_HEAD =~ $GIT_BOUNDARY_RE ]]; then
    GIT_TAIL=${CMD_HEAD:${#BASH_REMATCH[0]}}
    if [[ $GIT_TAIL =~ $GIT_C_TAIL_RE ]]; then
        GIT_C_DIR="${BASH_REMATCH[1]}"
        # one wrapping quote pair, so a quoted worktree path still resolves
        GIT_C_DIR="${GIT_C_DIR%\"}"; GIT_C_DIR="${GIT_C_DIR#\"}"
        GIT_C_DIR="${GIT_C_DIR%\'}"; GIT_C_DIR="${GIT_C_DIR#\'}"
    fi
fi
SHELL_CWD=$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null || echo "")
if [ -n "$GIT_C_DIR" ]; then
    # a relative -C dir resolves against the shell's cwd, the same anchor
    # the command itself runs from; with no cwd in the payload, the hook's own
    # inherited cwd anchors the resolution instead.
    if [ -n "$SHELL_CWD" ] && ! cd "$SHELL_CWD" 2>/dev/null; then exit 0; fi
    cd "$GIT_C_DIR" 2>/dev/null || exit 0
else
    cd "${SHELL_CWD:-${CLAUDE_PROJECT_DIR:-.}}" 2>/dev/null \
      || cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
fi

# Single `git diff --cached` piped through one awk pass: file-header tracking
# for the path exclusions, then the claim-shape match over added lines only.
# The -c overrides force canonical a/ b/ unquoted headers regardless of the
# user's diff.mnemonicPrefix / core.quotePath config, which the path
# exclusions depend on.
# The 3-line cap lives INSIDE awk rather than in a `head -3`: under
# `pipefail`, head closing the pipe early makes the whole substitution exit
# nonzero, and a fail-open `|| MATCHES=""` there would silently discard the
# very matches it just found. The cap is COMMIT-wide, not per-file — the
# banner is a pointer to the staged change, not an exhaustive report.
# With SCAN_WORKTREE set, `git diff HEAD` follows the staged diff in the same
# awk pass; a line already reported (it is staged AND differs from HEAD) is
# skipped by the seen[] dedupe, which also applies to the staged-only scan.
scan_diffs() {
    git -c diff.mnemonicprefix=false -c core.quotepath=false diff --cached 2>/dev/null
    if [ "$SCAN_WORKTREE" -eq 1 ]; then
        git -c diff.mnemonicprefix=false -c core.quotepath=false diff HEAD 2>/dev/null
    fi
    return 0
}
MATCHES=$(scan_diffs | awk '
/^\+\+\+ /{
    path = substr($0, 5)
    sub(/^b\//, "", path)
    skip = (path ~ /^(tracker|backlog|docs|\.claude|\.husky)\// || path ~ /\.md$/) ? 1 : 0
    next
}
/^\+/{
    if (skip || n >= 3) next
    line = substr($0, 2)
    if (tolower(line) ~ /always (populated|set|non-null|present|returns)|never (null|empty|undefined|happens|fires)|cannot be (null|empty|undefined|unset|set|present|absent|missing|zero|negative|false|true|populated)([^a-z]|$)|cannot (happen|match|occur)|guaranteed to|(is|are) always|only ever/) {
        shown = substr(line, 1, 100)
        if (seen[shown]++) next
        print shown
        n++
    }
}
')

# Any git/awk failure leaves this empty, which is the fail-open path.
[ -z "${MATCHES//[[:space:]]/}" ] && exit 0

# Command substitution strips the LAST newline of the indented block, so the
# format string carries an explicit \n between the matches and the guidance
# line — otherwise the guidance glues onto the final match.
TEXT=$(printf 'CLAIM-SHAPE GUARD: staged line(s) assert what a field/value always or never holds:\n%s\nPer seyag core.md § Don'\''t present speculation as fact (the producer is authoritative): verify each at its producer/assignment site and cite it, or amend.\n' \
  "$(printf '%s\n' "$MATCHES" | sed 's/^/  /')")

# Advisory delivery: additionalContext is the field PreToolUse actually
# delivers to Claude (see the channel note in the header). Plain stdout is
# NOT printed as well — it never reaches the agent, so it would only be a
# second copy of the wording to keep in sync. No permissionDecision field is
# ever emitted: this hook never blocks.
jq -n --arg ctx "$TEXT" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $ctx}}'

exit 0
