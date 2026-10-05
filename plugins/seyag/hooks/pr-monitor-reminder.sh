#!/bin/bash
# PostToolUse hook (matcher: Bash) — after a `git push` or `gh pr create`,
# reminds the session to watch the portable `pr-ci-wait` gate (a Monitor
# where the toolset has one, a background `pr-ci-wait` otherwise) instead
# of sleep-polling `gh`. Ported from Tzurot's
# .claude/hooks/pr-monitor-reminder.sh, with two load-bearing fixes:
#
# 1. DELIVERY. Tzurot's copy printed its banner to plain stdout, and its own
#    header records that non-blocking PostToolUse stdout never reaches the
#    agent (probed and confirmed there). Per the Claude Code hooks reference
#    (https://code.claude.com/docs/en/hooks.md, "Add context for Claude" /
#    "PostToolUse decision control"), the field that DOES reach Claude for
#    PostToolUse is `hookSpecificOutput.additionalContext` — the same
#    mechanism this plugin's session-start.sh already uses for SessionStart.
#    RUNTIME-VERIFIED: a live session log recorded the banner as a
#    PostToolUse:Bash hook_additional_context attachment (Night House,
#    PR #72, 2026-09-27).
#
# 2. EFFECTIVE DIRECTORY. A push on this machine routinely runs from a
#    directory other than the one this hook process inherits: `git -C
#    <worktree> push …`, `cd <worktree> && git push …`, or a persistent shell
#    whose cwd differs from wherever the hook happens to execute. Every git/gh
#    call this hook makes (branch, PR lookup, dedup SHA, the printed Monitor
#    command) has to run against THAT directory, not a bare `git`/`gh` in
#    whatever cwd the hook process itself has. Resolved in priority order:
#      1. `git -C <dir>` on the matched push itself (composed left-to-right if
#         repeated, matching git's own semantics).
#      2. The last literal `cd <dir>` earlier in the same command chain
#         (a target holding `$`, a backtick, or `~`, or a `cd` with flags/
#         multiple words, gives up on `cd` entirely — no further, earlier `cd`
#         is tried either).
#      3. The payload's `.cwd` (the persistent shell's actual cwd for this
#         call — this is the field the pre-fix version of this hook never
#         read at all, and is therefore right MOST of the time even with no
#         `-C`/`cd` in sight).
#      4. This hook process's own cwd, as a last resort.
#    A relative `-C`/`cd` target resolves against the payload `.cwd` (never
#    against this hook process's own cwd). Structural parsing (finding the
#    matched push, an anchoring `-C`, and any earlier `cd`) uses the shared
#    quote-aware word splitter in lib/shell_quotes.py, not a regex over the
#    raw string — a `-C` value or commit message can itself contain the text
#    "push" or "cd " without being one.
#
# Fires only after a Bash tool call whose command contains a `git push`
# (optionally `-C`-anchored) or `gh pr create` (ignoring a plain `--tags`
# push, which has no PR association). PostToolUse fires only after the tool
# call itself succeeded — a nonzero-exit `git push`/`gh pr create` routes to
# PostToolUseFailure instead and never reaches this script, so no separate
# error check is needed here.
#
# Dedup per (repo toplevel, PR, head SHA) in a seen-file under
# ${XDG_RUNTIME_DIR:-/tmp} (override SYG_PR_MONITOR_SEEN_FILE for the
# probe), so one push prints once — and two different repos sharing a PR
# number don't collide.
#
# Stays silent in a project that ships its own
# .claude/hooks/pr-monitor-reminder.sh (Tzurot today): run.sh, the seyag
# plugin's hook dispatcher, already yields to that project-local copy before this
# script ever runs — no extra check needed here. This is how the twin is
# retired later: once Tzurot deletes its copy, the plugin's copy takes over
# automatically at the next /reload-plugins.
#
# Fail-open everywhere: missing jq/python3, an unreadable command (unterminated
# quote), no open PR, an unresolvable branch, or an unwritable seen-file all
# fall through to silence (exit 0) rather than blocking or erroring.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

INPUT=$(cat)
TOOL_NAME=$(jq -r '.tool_name // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ "$TOOL_NAME" = "Bash" ] || exit 0

COMMAND=$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ -n "$COMMAND" ] || exit 0

# Cheap pre-filter before spawning python: only a command mentioning `git` or
# `gh` at all can match either trigger shape.
if ! grep -qE '(^|[[:space:]&|;(`])(git|gh)([[:space:]]|$)' <<<"$COMMAND"; then
  exit 0
fi

PAYLOAD_CWD=$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null || echo "")

# The structural scan: finds the matched trigger segment (a `git ... push` or
# `gh pr create`), whether it's the create shape, whether that push carries
# `--tags`, and the effective directory per the priority order in the header.
# Prints four lines on a match (TRIGGER=1, IS_CREATE=0|1, HAS_TAGS=0|1, DIR=…);
# prints nothing (or TRIGGER=0) on no match. Any internal error/exception
# prints nothing, matching the fail-open direction. The command goes to python
# on fd 3, never through the environment: Linux caps one env string at 128 KiB
# (MAX_ARG_STRLEN), and python failing to exec would fail open.
HOOK_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
SCAN=$(HOOK_LIB="$HOOK_LIB" PAYLOAD_CWD="$PAYLOAD_CWD" \
  PYTHONDONTWRITEBYTECODE=1 python3 3<<<"$COMMAND" << 'PYEOF' 2>/dev/null
import os
import re
import sys

sys.path.insert(0, os.environ["HOOK_LIB"])
from shell_quotes import _words, strip_heredoc_bodies  # noqa: E402

cmd = os.fsdecode(open(3, "rb").read()).removesuffix("\n")
payload_cwd = os.environ.get("PAYLOAD_CWD", "") or None

ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")


def literal_ok(v):
    return v != "" and "$" not in v and "`" not in v and not v.startswith("~")


def resolve_against(value, base):
    if not literal_ok(value):
        return None
    if os.path.isabs(value):
        return os.path.normpath(value)
    if base:
        return os.path.normpath(os.path.join(base, value))
    return None


def skip_assignments(words):
    i = 0
    while i < len(words) and ASSIGNMENT.match(words[i]):
        i += 1
    return i


def cmd_name(word):
    return word.rsplit("/", 1)[-1]


def parse_git_push(words):
    """None, or {"c_dirs": [...], "push_args": [...]} for a `git ... push`
    segment (its own global options up to and including any -C, scanned;
    anything else is a conservative "no value" skip, matching this hook's
    narrow, habitual-shapes scope)."""
    i = skip_assignments(words)
    if i >= len(words) or cmd_name(words[i]) != "git":
        return None
    j = i + 1
    c_dirs = []
    while j < len(words):
        w = words[j]
        if w == "--":
            j += 1
            break
        if w == "-C":
            if j + 1 < len(words):
                c_dirs.append(words[j + 1])
                j += 2
                continue
            j += 1
            continue
        if w.startswith("-C") and len(w) > 2:
            c_dirs.append(w[2:])
            j += 1
            continue
        if w.startswith("-"):
            j += 1
            continue
        break
    if j >= len(words) or words[j] != "push":
        return None
    return {"c_dirs": c_dirs, "push_args": words[j + 1 :]}


def parse_gh_pr_create(words):
    i = skip_assignments(words)
    return (
        i + 2 < len(words)
        and cmd_name(words[i]) == "gh"
        and words[i + 1] == "pr"
        and words[i + 2] == "create"
    )


body = strip_heredoc_bodies(cmd)
if body is None:
    body = cmd  # unterminated heredoc marker text: fail-open direction

words = _words(body)
segments = []
current = []
for w in words:
    if w is None:
        if current:
            segments.append(current)
        current = []
    else:
        current.append(w)
if current:
    segments.append(current)

trigger_idx = None
is_create = False
has_tags = False
c_dir = None

for idx, seg in enumerate(segments):
    push = parse_git_push(seg)
    if push is not None:
        trigger_idx = idx
        has_tags = "--tags" in push["push_args"]
        cur = payload_cwd
        ok = True
        for d in push["c_dirs"]:
            resolved = resolve_against(d, cur)
            if resolved is None:
                ok = False
                break
            cur = resolved
        c_dir = cur if (ok and push["c_dirs"]) else None
        break
    if parse_gh_pr_create(seg):
        trigger_idx = idx
        is_create = True
        break

if trigger_idx is None:
    print("TRIGGER=0")
    raise SystemExit

effective_dir = c_dir

if effective_dir is None:
    # Priority 2: replay every `cd` before the trigger segment IN ORDER — a
    # `cd` persists across whatever non-cd commands come after it in the same
    # chain (real bash semantics; `echo hi` between two `&&`s does not reset
    # the shell's cwd), so a non-cd segment in between does NOT stop the
    # search the way it would for a one-shot "last cd" lookup. `current` is
    # the best estimate of cwd entering the next segment; `lost` means an
    # unresolvable `cd` (a `$`/backtick/`~` target, or one with flags or more
    # than one word) broke the chain of estimates — a later RELATIVE `cd`
    # can't recover from that, but a later ABSOLUTE `cd` always can, since it
    # does not depend on where the shell was beforehand.
    current = payload_cwd
    lost = False
    for seg in segments[:trigger_idx]:
        i = skip_assignments(seg)
        if not (i < len(seg) and seg[i] == "cd" and len(seg) - i == 2):
            continue
        target = seg[i + 1]
        if literal_ok(target) and os.path.isabs(target):
            current = os.path.normpath(target)
            lost = False
        elif literal_ok(target) and not lost and current:
            current = os.path.normpath(os.path.join(current, target))
            lost = False
        else:
            lost = True
    if not lost:
        effective_dir = current

if effective_dir is None:
    effective_dir = payload_cwd  # priority 3; priority 4 (hook's own cwd) is
    # left to the bash caller, which already has its own $PWD for free.

print("TRIGGER=1")
print(f"IS_CREATE={1 if is_create else 0}")
print(f"HAS_TAGS={1 if has_tags else 0}")
print(f"DIR={effective_dir or ''}")
PYEOF
) || exit 0

[ -n "$SCAN" ] || exit 0
TRIGGER=$(printf '%s\n' "$SCAN" | sed -n 's/^TRIGGER=//p')
[ "$TRIGGER" = "1" ] || exit 0
IS_CREATE=$(printf '%s\n' "$SCAN" | sed -n 's/^IS_CREATE=//p')
HAS_TAGS=$(printf '%s\n' "$SCAN" | sed -n 's/^HAS_TAGS=//p')
DIR=$(printf '%s\n' "$SCAN" | sed -n 's/^DIR=//p')

# A tag-only push has no PR association.
[ "$HAS_TAGS" = "1" ] && exit 0

DIR="${DIR:-$PWD}"  # priority 4: nothing else resolved, fall back to the
                     # hook process's own cwd.

PR_NUM=""

# `gh pr create` returns the PR URL on stdout — parsing it avoids the
# replication lag a `gh pr list` lookup hits immediately after creation, and
# needs no directory (the URL is already absolute).
if [ "$IS_CREATE" = "1" ]; then
  OUTPUT=$(jq -r '.tool_response.stdout // .tool_result.stdout // .tool_response.output // empty' <<<"$INPUT" 2>/dev/null || echo "")
  PR_NUM=$(grep -oE 'pull/[0-9]+' <<<"$OUTPUT" | head -1 | grep -oE '[0-9]+$' || echo "")
fi

# Fallback (the primary path for `git push`): resolve the PR from the
# effective directory's current branch. Silently exits if the branch has no
# open PR, or if DIR is not (or no longer) a readable git repo. Bounded at 2s:
# an unbounded `gh` here would stall the whole PostToolUse hook (and, with it,
# the tool call it fires after) on a network hang. A timeout kill (exit 124)
# gets its own stderr note, same fail-open direction (PR_NUM stays empty).
if [ -z "$PR_NUM" ]; then
  BRANCH=$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  [ -z "$BRANCH" ] && exit 0
  GH_LIST_OUT=$(cd "$DIR" 2>/dev/null && timeout 2 gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number' 2>/dev/null)
  GH_LIST_RC=$?
  if [ "$GH_LIST_RC" -eq 124 ]; then
    echo "pr-monitor-reminder: gh pr list timed out after 2s; skipping this reminder" >&2
    exit 0
  fi
  PR_NUM="$GH_LIST_OUT"
fi

if [ -z "$PR_NUM" ] || [ "$PR_NUM" = "null" ]; then
  exit 0
fi

TOPLEVEL=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || echo "")
[ -n "$TOPLEVEL" ] || exit 0

# Dedup per (repo toplevel, PR, head SHA) so one push prints once. /tmp (or
# the runtime dir) is bounded naturally by reboot/session churn.
SHA=$(git -C "$TOPLEVEL" rev-parse HEAD 2>/dev/null || echo "nosha-$$")
KEY="${TOPLEVEL}:${PR_NUM}:${SHA}"
SEEN_FILE="${SYG_PR_MONITOR_SEEN_FILE:-${XDG_RUNTIME_DIR:-/tmp}/.claude_pr_monitor_seen.$(id -u)}"
if [ -f "$SEEN_FILE" ] && grep -qxF "$KEY" "$SEEN_FILE" 2>/dev/null; then
  exit 0
fi
if ! printf '%s\n' "$KEY" >>"$SEEN_FILE" 2>/dev/null; then
  exit 0
fi
chmod 600 "$SEEN_FILE" 2>/dev/null || true

# Single-quoted for the printed command (below): a literal path, safe even if
# it holds a space or other shell metacharacter, with any embedded single
# quote itself escaped the standard way.
Q_TOPLEVEL="'$(printf '%s' "$TOPLEVEL" | sed "s/'/'\\\\''/g")'"

# The `$(...)` below is printed UNRESOLVED, on purpose — copy the line
# verbatim except for the already-resolved, single-quoted toplevel path.
# Hand-transcribing a SHA has failed repeatedly (twice by completing an
# abbreviated one with invented characters — see pr-ci-wait's own head-SHA
# validation, which exists because of exactly that), and the substitution
# resolves the SHA when the watcher actually runs rather than at arm time,
# closing that window entirely. The toplevel path is baked in as a literal
# because it's already known now — nothing is gained by re-deriving it in the
# watcher's own (potentially different) cwd.
#
# The command `cd`s into the toplevel FIRST, rather than only anchoring the
# `--sha` substitution's own `git rev-parse HEAD`: pr-ci-wait itself has no
# `-C`/`--cwd` flag, so its `gh api repos/{owner}/{repo}/...` calls, its
# `git cat-file -e` existence check, and its `.github/workflows` review
# auto-detect all resolve against whatever directory the MONITOR happens to
# run the whole command from — which is the hook's own premise NOT to trust
# (the session's cwd can differ from the toplevel for the same reasons the
# effective-directory resolution above exists). Anchoring only the `--sha`
# substitution left every other call unanchored; `cd`-ing the whole command
# fixes all of them at once.
TEXT=$(cat <<EOF
PR WATCH REMINDER — push detected on PR #$PR_NUM ($TOPLEVEL)

Watch CI + reviews for this push via ONE of the two paths below, chosen by
whether your own toolset includes the Monitor tool (with ToolSearch to load
it). If a watcher for PR #$PR_NUM from an earlier push is still running —
a Monitor or a background pr-ci-wait task — TaskStop it first: one watcher
per PR.

PATH A — your toolset includes Monitor:
1. Monitor is a deferred tool: load it first with ToolSearch
   (query: "select:Monitor") before calling it.
2. Arm it: description "CI + reviews for PR #$PR_NUM", timeout_ms: 1800000,
   persistent: false (deliberately NOT true — a forgotten session-length
   watcher cannot be cleaned up), and this command exactly, substitution
   included — do NOT resolve the SHA yourself and paste the result:

     cd $Q_TOPLEVEL && pr-ci-wait $PR_NUM --sha \$(git rev-parse HEAD)

3. When it fires, read which sentinel printed: CI_COMPLETE (released),
   CI_GATE_TIMEOUT, CI_GATE_STARTUP_FAILURE, CI_GATE_REVIEW_MISSING — or none
   at all, meaning the Monitor's own timeout fired first; re-arm.
   Then fetch reviews (three different endpoints; conversation comments,
   inline code-review comments, and review summaries are NOT the same thing):
     gh pr view $PR_NUM --comments
     gh api repos/{owner}/{repo}/pulls/$PR_NUM/reviews
     gh api repos/{owner}/{repo}/pulls/$PR_NUM/comments
   Report CI state and new review findings together, in one message.

PATH B — reduced toolset (no Monitor/ToolSearch): watch via the Bash tool's
BACKGROUND mode (run_in_background — a foreground Bash call is killed at its
10-minute cap, while a background task may run 30+ minutes).
1. Arm it with this command exactly, substitution included — do NOT resolve
   the SHA yourself and paste the result:

     cd $Q_TOPLEVEL && pr-ci-wait $PR_NUM --sha \$(git rev-parse HEAD)

   There is no persistent flag here; the same guard applies — one watcher
   per PR (stop the stale one first: TaskStop with its task id), and act
   on the sentinel as soon as the task exits instead of leaving it armed.
2. When the task completes, read which sentinel printed in its task output:
   CI_COMPLETE (released), CI_GATE_TIMEOUT, CI_GATE_STARTUP_FAILURE,
   CI_GATE_REVIEW_MISSING — or none at all; re-arm.
   Then fetch reviews (three different endpoints; conversation comments,
   inline code-review comments, and review summaries are NOT the same thing):
     gh pr view $PR_NUM --comments
     gh api repos/{owner}/{repo}/pulls/$PR_NUM/reviews
     gh api repos/{owner}/{repo}/pulls/$PR_NUM/comments
   Report CI state and new review findings together, in one message.

Either path: never wait on a hand-written \`sleep\`/\`gh\` poll loop — that
is exactly what arming the watcher replaces.
EOF
)

jq -n --arg ctx "$TEXT" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}'
