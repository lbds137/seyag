#!/bin/bash
# PreToolUse hook (matcher: Bash): block once a push (`git push`, `gh pr create`)
# that runs in a different worktree of the same repo than the session's last
# `git commit`. Component `push-tree`; `SYG_DISABLE=push-tree` turns it off.
#
# WHY:
#   A shell that an earlier call cd'd into another unit's worktree keeps that
#   directory. A later push or `gh pr create` from it publishes the wrong branch.
#   cwd-drift-guard covers main-vs-linked only; this covers any two worktrees of
#   one repo, the main checkout included.
#
# THE RULE (judged by `hooks/lib/push_tree.py`, walking the command text via
# `lib/shell_state.py`, so `cd` and `git -C` are followed in execution order):
#   - Per session (and agent), the state records the toplevel of the last commit
#     (line 1) and each acknowledged (commit tree, push tree) pair (one tab-
#     separated line each, at most 8, newest last).
#   - `git commit` (not --dry-run) moves the commit toplevel; a commit whose
#     tree is unknown makes it unknown. Acknowledgements are not reset by a
#     commit.
#   - A tree-dependent push (`git push` with no refspec, or a refspec whose
#     source is HEAD or @; `-n`/`--dry-run` is never judged) and `gh pr create`
#     without --head/-H is a hit when its toplevel differs from the commit
#     toplevel, the (commit tree, push tree) pair is not acknowledged, and the
#     two share a git common dir (another repo never blocks). Every hit of one
#     command is recorded as acknowledged, but the record stays where it was,
#     because the command does not run. The first hit exits 2 once; re-running
#     the same command passes.
#   - A command whose shell may be in more than one directory (a conditional cd)
#     judges each occurrence per directory. Occurrences that disagree make a
#     commit unknown and drop a push.
#   - A push whose refspec names a branch, or that deletes or sends only tags,
#     is not judged.
#
# KNOWN BOUNDS:
#   - The commit is recorded at PreToolUse, so a commit that then fails or has
#     nothing to commit still moves the record.
#   - The acknowledgement is per (commit tree, push tree) pair, not per command:
#     after a commit in the same tree, any later push from an acknowledged tree
#     passes.
#   - Option values that look like flags (`-o --dry-run`), short flag bundles,
#     concurrent calls in one session, and paths containing tabs or newlines are
#     not handled.
#   - Command-text scope only: a wrapper script that pushes is invisible.
#   - `git push` with a remote's push refspec config or `push.default=matching`
#     is judged as tree-dependent when no refspec is given.
#   - Git aliases (`git ci`, `git -c alias.p=push p`) are not judged, and the
#     prefilter skips a command whose only commit or push is an alias.
#   - A bare push in a linked worktree can trip cwd-drift-guard and this guard
#     in the same call, so it may take two re-runs.
#
# FAIL-OPEN:
#   No session id (or an invalid one), an invalid agent id, unreadable or
#   unwritable state, malformed JSON, missing jq/python3/git, or any internal
#   error -> exit 0 with nothing on stdout or stderr.
#
# Fixture check: run hooks/push-tree-guard.probe.sh after ANY edit.

set -uo pipefail

syg_drain_stdin() { IFS= read -r -d '' _ || true; }

type -P jq python3 git >/dev/null 2>&1 || { syg_drain_stdin; exit 0; }

INPUT=$(cat 2>/dev/null) || exit 0
[ -n "$INPUT" ] || exit 0

TOOL_NAME='' CMD='' CWD='' SESSION_ID='' AGENT_ID=''
{
  IFS= read -r -d '' TOOL_NAME \
    && IFS= read -r -d '' CMD \
    && IFS= read -r -d '' CWD \
    && IFS= read -r -d '' SESSION_ID \
    && IFS= read -r -d '' AGENT_ID
} < <(jq -j '
  def s: if . == null then "" elif type == "string" then . else tostring end
    | split(([0]|implode)) | join("")
    | ([10]|implode) as $nl | until((endswith($nl)|not); .[:-1]);
  "\(.tool_name | s)\u0000\(.tool_input.command | s)\u0000\(.cwd | s)\u0000\(.session_id | s)\u0000\(.agent_id | s)\u0000"
' <<<"$INPUT" 2>/dev/null) || exit 0
[ "$TOOL_NAME" = "Bash" ] || exit 0
[ -n "$CMD" ] || exit 0
[ -n "$CWD" ] || exit 0

case "$CMD" in
  *commit*|*push*|*pr*create*) ;;
  *) exit 0 ;;
esac

# State key, validated the way cwd-drift-guard validates its own (no state when
# either id is invalid: nothing recorded, nothing blocked).
[[ "$SESSION_ID" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$SESSION_ID" != "." ] && [ "$SESSION_ID" != ".." ] || exit 0
KEY=$SESSION_ID
if [ -n "$AGENT_ID" ]; then
  [[ "$AGENT_ID" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$AGENT_ID" != "." ] && [ "$AGENT_ID" != ".." ] || exit 0
  KEY="$SESSION_ID.$AGENT_ID"
fi
STATE_BASE="${XDG_STATE_HOME:-${HOME:-}/.local/state}"
STATE_FILE="$STATE_BASE/seyag/push-tree-guard/$KEY"

HOOKS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK_LIB="$HOOKS_DIR/lib"

RESULT=$(CWD="$CWD" PT_STATE="$STATE_FILE" python3 -I "${SYG_PY_CACHE_ARG:--B}" -c 'import sys; sys.path.insert(0, sys.argv[1]); import push_tree' "$HOOK_LIB" 3<<<"$CMD" 2>/dev/null) || exit 0
[ -n "$RESULT" ] || exit 0

TAB=$(printf '\t')
IFS="$TAB" read -r label commit_top push_top <<<"$RESULT" || exit 0
[ -n "$label" ] && [ -n "$commit_top" ] && [ -n "$push_top" ] || exit 0

branch_of() {
  local b
  b=$(git -C "$1" branch --show-current 2>/dev/null)
  printf '%s' "${b:-(detached HEAD)}"
}
b1=$(branch_of "$commit_top")
b2=$(branch_of "$push_top")

cat >&2 <<EOF
PUSH-TREE GUARD — blocked once: '$label' runs in a different worktree than this session's last commit
    last commit in: $commit_top (branch '$b1')
    this command in: $push_top (branch '$b2')
If you meant the committed tree: anchor it (git -C "$commit_top" push ..., or cd "$commit_top" first).
If this tree is right, re-run the same command: it passes (warn-once per commit tree and push tree).
Off switch: SYG_DISABLE=push-tree.
EOF
exit 2
