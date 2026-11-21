#!/bin/bash
# PreToolUse hook (matcher: Bash): deny `git worktree add` commands targeting a
# path under `.claude/worktrees/<x>` when the branch being created fails
# `SYG_WORKTREE_BRANCH_RE` (unset or empty: `^worktree-agent-`), the exact
# extended regex `safe-worktree-clean` and `worktree-transfer` enforce.
#
# WHY:
#   `safe-worktree-clean` holds any worktree under `.claude/worktrees/` whose
#   branch fails `SYG_WORKTREE_BRANCH_RE` (`HOLD:branch-name`), so a routine
#   cleanup of a merged agent worktree needs the owner's approval when the
#   branch was misnamed at creation time.
#
# JUDGED ADDS (`hooks/lib/worktree_branch.py` + `hooks/lib/worktree_add.py`):
#   Walks the command text in execution order via `lib/shell_state.py`
#   (tracking `cd`/`pushd`/`popd`, shell variables, wrapper commands, and
#   command substitutions), parses git global options (`-C <dir>`, etc.) via
#   `lib/commit_diff.py`, and parses `git worktree add` options:
#     - Only paths whose normalized resolution has a `.claude/worktrees`
#       segment pair followed by at least one more segment
#       (`.../.claude/worktrees/<x>`) are judged; worktrees outside
#       `.claude/worktrees/` are never gated here.
#     - Explicit branch (`-b <name>` or `-B <name>`, separate, attached as
#       `-b<name>`, or inside a short cluster such as `-qb <name>` / `-qb<name>`,
#       last flag wins): `<name>` is judged (`explicit`).
#     - Detached (`-d` or `--detach`, including `d` in a short cluster):
#       creates no branch; allowed.
#     - No `-b`/`-B`, no `-d`/`--detach`, and a `<commit-ish>` positional is
#       given (`git worktree add <path> <commit-ish>`): checks out an existing
#       branch or detaches at the commit-ish; allowed (see KNOWN BOUNDS for
#       remote DWIM).
#     - Implied branch (`git worktree add <path>` with no `-b`/`-B`, no
#       `-d`/`--detach`, and no `<commit-ish>`, including `--orphan` without
#       `-b`): git names the new branch after `basename(<path>)`. When
#       `git -C <effdir> show-ref --verify -q refs/heads/<basename>` exits 0,
#       that local branch already exists and is skipped; otherwise `<basename>`
#       is judged (`implied`).
#
# REGEX MATCHING:
#   Matched in bash with `[[ $branch =~ $RE ]]` so the ERE dialect equals
#   `safe-worktree-clean`'s:
#     - rc 0: allowed.
#     - rc 1: denied (exit 2) with a Fix line suggesting
#       `worktree-agent-<slug>` when that candidate matches `SYG_WORKTREE_BRANCH_RE`,
#       or `use a branch name matching <re>` when a custom pattern does not
#       match `worktree-agent-<slug>`. Every denied add in the command is listed.
#     - rc 2 (invalid extended regex): allowed (exit 0) with one non-blocking
#       `hookSpecificOutput.additionalContext` warning on stdout noting that
#       `safe-worktree-clean` will HOLD every tree as `branch-name` until fixed.
#
# OFF SWITCH:
#   No per-command bypass env exists by design (the fix is always a branch
#   rename). Disable the component with `SYG_DISABLE=worktree-branch` or set
#   `SYG_WORKTREE_BRANCH_RE` to the pattern your branches use.
#
# KNOWN BOUNDS:
#   - Remote DWIM branch creation: `git worktree add <path> <name>` without
#     `-b`/`-B` where `<name>` is not a local branch but exists on a remote can
#     DWIM-create a local branch `<name>`. Because `<commit-ish>` is present,
#     this guard treats it as checking out `<commit-ish>` and allows it
#     (tracked as TASK-64).
#   - Unexpanded `$VAR`, backticks, or globs in the target path or effective
#     directory after `shell_state` expansion cannot be resolved statically and
#     are allowed.
#   - `env -C <dir>` / `--work-tree` / `GIT_DIR` prefix overrides not handled by
#     `commit_diff.parse_git` resolve relative paths against the shell state's
#     tracked cwd.
#   - A child script or binary that runs `git worktree add` internally is not
#     visible on the Bash command line.
#
# FAIL-OPEN:
#   Malformed JSON, missing jq/python3/git, or any internal error -> exit 0
#   with nothing on stdout.
#
# Fixture check: run hooks/worktree-branch-guard.probe.sh after ANY edit.

set -uo pipefail

syg_drain_stdin() { IFS= read -r -d '' _ || true; }

type -P jq python3 git >/dev/null 2>&1 || { syg_drain_stdin; exit 0; }

INPUT=$(cat 2>/dev/null) || exit 0
[ -n "$INPUT" ] || exit 0

TOOL_NAME='' CMD='' CWD=''
{
  IFS= read -r -d '' TOOL_NAME \
    && IFS= read -r -d '' CMD \
    && IFS= read -r -d '' CWD
} < <(jq -j '
  def s: if . == null then "" elif type == "string" then . else tostring end
    | split(([0]|implode)) | join("")
    | ([10]|implode) as $nl | until((endswith($nl)|not); .[:-1]);
  "\(.tool_name | s)\u0000\(.tool_input.command | s)\u0000\(.cwd | s)\u0000"
' <<<"$INPUT" 2>/dev/null) || exit 0
[ "$TOOL_NAME" = "Bash" ] || exit 0
[ -n "$CMD" ] || exit 0

case "$CMD" in
  *worktree*) ;;
  *) exit 0 ;;
esac
case "$CMD" in
  *add*) ;;
  *) exit 0 ;;
esac

HOOKS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK_LIB="$HOOKS_DIR/lib"

RESULT=$(CWD="$CWD" python3 -I "${SYG_PY_CACHE_ARG:--B}" -c 'import sys; sys.path.insert(0, sys.argv[1]); import worktree_branch' "$HOOK_LIB" 3<<<"$CMD" 2>/dev/null) || exit 0
[ -n "$RESULT" ] || exit 0

RE=${SYG_WORKTREE_BRANCH_RE:-}
[ -n "$RE" ] || RE='^worktree-agent-'

denied=0
TAB=$(printf '\t')
while IFS="$TAB" read -r kind branch wt_path; do
  [ -n "$kind" ] && [ -n "$branch" ] && [ -n "$wt_path" ] || continue
  [[ $branch =~ $RE ]] 2>/dev/null
  # shellcheck disable=SC2319 # the condition's own status is wanted: 2 means an invalid regex
  rc=$?
  case $rc in
    0) continue ;;
    2)
      printf '%s' "worktree-branch-guard: SYG_WORKTREE_BRANCH_RE is not a valid extended regex ($RE); safe-worktree-clean will HOLD every tree as branch-name until it is fixed" \
        | jq -Rsc '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: .}}'
      exit 0
      ;;
  esac

  base=${wt_path##*/}
  slug=${base//[^A-Za-z0-9._-]/-}
  case "$slug" in
    worktree-agent-*) cand="$slug" ;;
    *) cand="worktree-agent-$slug" ;;
  esac

  if [[ $cand =~ $RE ]] 2>/dev/null; then
    fix="name the branch $cand: git worktree add -b $cand $wt_path <base>"
  else
    fix="use a branch name matching $RE"
    [ "$kind" = "implied" ] && fix="$fix (git worktree add -b <branch> $wt_path <base>)"
  fi
  if [ "$kind" = "implied" ]; then
    fix="without -b, git names the new branch after the directory ($branch); $fix"
  fi

  cat >&2 <<EOF
WORKTREE-BRANCH GUARD — blocked: branch $branch for $wt_path does not match SYG_WORKTREE_BRANCH_RE ($RE)
Why: safe-worktree-clean holds a tree under .claude/worktrees/ whose branch fails that pattern (HOLD:branch-name), so removing it later needs the owner's approval.
Fix: $fix
Off switch: SYG_DISABLE=worktree-branch (or set SYG_WORKTREE_BRANCH_RE to the pattern your branches use).
EOF
  denied=1
done <<<"$RESULT"

[ "$denied" -eq 1 ] && exit 2
exit 0
