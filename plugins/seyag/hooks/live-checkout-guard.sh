#!/bin/bash
# PreToolUse hook (matchers: Bash, Edit|Write|MultiEdit|NotebookEdit): block
# branch switches, stashes, commits, history/working-tree mutations, and
# non-ignored file edits inside a live plugin checkout (a directory-source
# checkout whose working tree is the code every session loads).
#
# LIVE ROOTS:
#   (a) the git toplevel of ${CLAUDE_PLUGIN_ROOT:-<hooks dir>/..} when inside a
#       git working tree carrying `.claude-plugin/marketplace.json` at its
#       toplevel, unless SYG_LIVE_CHECKOUT_AUTO=0; plus
#   (b) each colon-separated absolute path in SYG_LIVE_CHECKOUTS resolved to its
#       git toplevel (non-repos and relative entries ignored).
#   Empty set -> exit 0 immediately.
#   Only the MAIN working tree of a live repo is live (--git-dir and
#   --git-common-dir resolve to the same realpath); a linked worktree of the
#   same repo is never live.
#
# DEFAULT BRANCH of a live root:
#   `git symbolic-ref --short refs/remotes/origin/HEAD` with the `origin/`
#   prefix stripped; fallback `main`.
#
# BASH TOOL:
#   Walks the command in execution order via lib/shell_quotes.py and
#   lib/shell_state.py (tracking cd/pushd/popd, GIT_DIR/GIT_WORK_TREE exports
#   and prefix assignments, wrapper strings, and command substitutions) and
#   resolves each git invocation's repository (`--git-dir` / `GIT_DIR` when
#   given, else the directory git starts in after cd/pushd and `git -C <dir>`)
#   plus its work tree (`--work-tree` / `GIT_WORK_TREE` when given). A target
#   equal to or under a path recorded from an earlier `git worktree add` in the
#   same command is treated as a linked worktree (not live) even before the
#   directory exists on disk; any other non-existent or unreadable cd target,
#   or unexpanded `$VAR` / glob in `-C`, `--work-tree`, `--git-dir`, `GIT_DIR`,
#   or `GIT_WORK_TREE`, falls back to the payload cwd (the cwd-drift-guard
#   baseline). The judging code is lib/live_checkout.py, imported (not piped)
#   so its bytecode is cached; its docstring has the contract. When either the
#   repository or the work tree is a live root:
#     BLOCK:
#       - `checkout` / `switch` to anything other than the default branch
#         (including `-b`, `-B`, `-c`, `-C`, `--create`, `--force-create`,
#         `-d`, `--detach`, `--orphan`, `-`, `@{-N}`, a sha, a tag, or a
#         remote-only branch `checkout <branch>` would DWIM-create);
#       - `checkout <ref> [--] <paths>` and `restore --source=<ref>` /
#         `-s <ref>` where <ref> is not the default branch or HEAD;
#       - `stash` except `list` / `show`;
#       - `commit`, `reset`, `rm`, `mv`;
#       - `merge`, `rebase`, `cherry-pick`, `revert`, `am` (except `--abort` or
#         `--quit`);
#       - `read-tree` with `-u` or `-m`;
#       - `update-ref` whose first ref operand is `HEAD` or `refs/heads/*`
#         (including `-d`), or with `--stdin`, and `symbolic-ref HEAD <ref>`
#         or `symbolic-ref -d HEAD`;
#       - `pull` unless the last of `--ff` / `--no-ff` / `--ff-only` is
#         `--ff-only`, or with `--rebase` / `-r` (except `--rebase=false`), or
#         `pull --ff-only` with a remote other than `origin` or a refspec other
#         than the default branch;
#       - `apply` with `--apply` or `--index`, or without `--check` / `--stat` /
#         `--numstat` / `--summary`;
#       - `clean` without `-n` / `--dry-run`;
#       - `sparse-checkout` with `set`, `add`, `reapply`, `init`, or `disable`;
#       - `bisect start`.
#     ALLOW everything else, including:
#       - `checkout [--] <paths>` and plain `restore` (or with `--source` / `-s`
#         naming the default branch or HEAD);
#       - `checkout <default>` / `switch <default>`;
#       - `merge` / `rebase` / `cherry-pick` / `revert` / `am` with `--abort`
#         or `--quit`;
#       - `pull --ff-only` (with no positional, `origin` alone, or `origin`
#         plus the default branch), `fetch`, all read-only subcommands;
#       - `worktree add|list|remove|prune`;
#       - `branch` (creating a branch ref does not move the checkout).
#
# EDIT / WRITE / MULTIEDIT / NOTEBOOKEDIT:
#   Resolves `tool_input.file_path` (`tool_input.notebook_path` for
#   `NotebookEdit`) to an absolute path (relative -> against the payload `cwd`).
#   When it lies under a live root's main working tree (and not inside a linked
#   worktree nested under it), ALLOW when `git -C <root> check-ignore -q <path>`
#   succeeds (exit 0; gitignored scratch such as a dispatch folder stays
#   writable), fail open on exit 128 or any error other than exit 1, and BLOCK
#   only on exit 1 (not ignored). Paths under `<root>/.git/` are blocked too.
#
# BYPASS:
#   `SYG_ALLOW_LIVE_CHECKOUT=1` as an assignment prefix on the git command (or
#   exported earlier in the command), or in the hook's environment (all tools),
#   for an action the owner approved.
#
# KNOWN BOUNDS:
#   - Bash-level file writes into the live checkout (`sed -i`, `>` / `>>`
#     redirects, `tee`, `cp`, `mv`, inline scripts) do not go through `git` or
#     `Edit`/`Write`/`MultiEdit`/`NotebookEdit` and are outside this hook's
#     surface.
#   - A child script or wrapper binary that chdirs into a live checkout and
#     runs git internally without naming it on the command line is not seen.
#   - Unjudged shapes: variable or escaped command names (`$GIT commit`,
#     `g\it`), `eval` of an unexpanded variable, `submodule update`, and
#     `branch -m` of the current branch.
#   - `--git-dir` / `GIT_DIR` naming a NON-live repository with no work tree,
#     run from inside a live root: git uses the cwd as that repository's work
#     tree, so its checkout writes into live files; judged by the repository
#     only, so allowed.
#
# FAIL-OPEN:
#   Malformed JSON, missing jq/python3/git, or any internal error -> exit 0
#   with nothing on stdout.
#
# Fixture check: run hooks/live-checkout-guard.probe.sh after ANY edit.

set -uo pipefail

syg_drain_stdin() { IFS= read -r -d '' _ || true; }

if [ "${SYG_ALLOW_LIVE_CHECKOUT:-}" = "1" ]; then
  syg_drain_stdin
  exit 0
fi

command -v jq >/dev/null 2>&1 || { syg_drain_stdin; exit 0; }
command -v python3 >/dev/null 2>&1 || { syg_drain_stdin; exit 0; }
command -v git >/dev/null 2>&1 || { syg_drain_stdin; exit 0; }

INPUT=$(cat 2>/dev/null) || exit 0
[ -n "$INPUT" ] || exit 0

TOOL_NAME='' CMD='' FILE_PATH='' CWD=''
# One jq fork reads every field the guard uses, as @sh assignments it evals.
# Parity with the old $(jq -r ...) reads, which bash $() applied to each field:
# NUL bytes are dropped and every trailing newline is stripped (both in s).
# Missing or null -> empty; a non-string scalar or an object -> its JSON text
# (tostring). FILE_PATH is notebook_path for NotebookEdit, else file_path.
PAYLOAD_FIELDS=$(jq -r '
  def s: if . == null then "" elif type == "string" then . else tostring end
    | split(([0]|implode)) | join("")
    | ([10]|implode) as $nl | until((endswith($nl)|not); .[:-1]);
  "TOOL_NAME=\(.tool_name | s | @sh) CMD=\(.tool_input.command | s | @sh) FILE_PATH=\(if .tool_name == "NotebookEdit" then (.tool_input.notebook_path | s) else (.tool_input.file_path | s) end | @sh) CWD=\(.cwd | s | @sh)"
' <<<"$INPUT" 2>/dev/null) || exit 0
eval "$PAYLOAD_FIELDS" || exit 0
case "$TOOL_NAME" in
  Bash | Edit | Write | MultiEdit | NotebookEdit) ;;
  *) exit 0 ;;
esac

if [ "$TOOL_NAME" = "Bash" ]; then
  [ -n "$CMD" ] || exit 0
  # Cheap prefilter: only a command mentioning `git` (case-insensitive) or
  # ANSI-C / locale quoting that could spell it can ever block.
  if ! grep -qE '(^|[^[:alnum:]_.-])[Gg][Ii][Tt]([^[:alnum:]_-]|$)|\$['\''"]' <<<"$CMD"; then
    exit 0
  fi
else
  [ -n "$FILE_PATH" ] || exit 0
fi

HOOKS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK_LIB="$HOOKS_DIR/lib"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$HOOKS_DIR/.." && pwd)}"

LIVE_ROOTS=""
add_live_root() {
  local cand="$1" need_marketplace="${2:-0}" info top gd cd gd_real cd_real top_real
  local -a parts real
  [ -n "$cand" ] && [ -d "$cand" ] || return 0
  info=$(git -C "$cand" rev-parse --show-toplevel --git-dir --git-common-dir 2>/dev/null) || return 0
  IFS=$'\n' read -r -d '' -a parts <<<"$info" || true
  top=${parts[0]-}
  gd=${parts[1]-}
  cd=${parts[2]-}
  [ -n "$top" ] && [ -n "$gd" ] && [ -n "$cd" ] || return 0
  case "$gd" in /*) ;; *) gd="$cand/$gd" ;; esac
  case "$cd" in /*) ;; *) cd="$cand/$cd" ;; esac
  # One realpath fork for all three. A failure on gd or cd (as before) or on top
  # (new: it used to fall back to the unresolved top) leaves fewer than three
  # lines, and the root is skipped.
  IFS=$'\n' read -r -d '' -a real < <(realpath -- "$gd" "$cd" "$top" 2>/dev/null) || true
  [ "${#real[@]}" -eq 3 ] || return 0
  gd_real=${real[0]}
  cd_real=${real[1]}
  top_real=${real[2]}
  # Only the MAIN working tree of a live repo is live; linked worktrees are not.
  [ -n "$gd_real" ] && [ "$gd_real" = "$cd_real" ] || return 0
  if [ "$need_marketplace" = "1" ] && [ ! -f "$top_real/.claude-plugin/marketplace.json" ]; then
    return 0
  fi
  case $'\n'"$LIVE_ROOTS"$'\n' in
    *$'\n'"$top_real"$'\n'*) ;;
    *) LIVE_ROOTS="${LIVE_ROOTS:+$LIVE_ROOTS$'\n'}$top_real" ;;
  esac
}

if [ "${SYG_LIVE_CHECKOUT_AUTO:-1}" != "0" ]; then
  add_live_root "$PLUGIN_ROOT" 1
fi
if [ -n "${SYG_LIVE_CHECKOUTS:-}" ]; then
  IFS=':' read -r -a _syg_extra_roots <<<"$SYG_LIVE_CHECKOUTS"
  for _syg_cand in "${_syg_extra_roots[@]}"; do
    case "$_syg_cand" in
      /*) add_live_root "$_syg_cand" ;;
    esac
  done
fi

[ -n "$LIVE_ROOTS" ] || exit 0

default_branch_of() {
  local root="$1" ref
  ref=$(git -C "$root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo "")
  case "$ref" in
    origin/?*) printf '%s' "${ref#origin/}" ;;
    *) printf 'main' ;;
  esac
}

emit_block() {
  local root="$1" def_branch="$2" reason="$3"
  cat >&2 <<EOF
LIVE-CHECKOUT GUARD — blocked: $reason
Live root: $root (default branch: $def_branch)
Why: this checkout's files are the code every session loads; switching branches, stashing, committing, or leaving tracked edits in it makes that state live in every session on the machine.
Fix: do the work in a linked worktree (git fetch origin && git worktree add -b <branch> $root/.claude/worktrees/<name> origin/$def_branch) and commit/push from there; for Edit/Write, edit the same path inside that worktree.
Bypass (only for an action the owner approved): SYG_ALLOW_LIVE_CHECKOUT=1
EOF
  exit 2
}

if [ "$TOOL_NAME" != "Bash" ]; then
  case "$FILE_PATH" in
    /*) RESOLVED="$FILE_PATH" ;;
    *)
      [ -n "$CWD" ] || exit 0
      RESOLVED="${CWD%/}/$FILE_PATH"
      ;;
  esac
  RESOLVED=$(realpath -m -- "$RESOLVED" 2>/dev/null) || exit 0
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    case "$RESOLVED" in
      "$root"/.git | "$root"/.git/*)
        REL="${RESOLVED#"$root"/}"
        emit_block "$root" "$(default_branch_of "$root")" "$TOOL_NAME of $REL in live checkout"
        ;;
      "$root"/*)
        walk_dir=$(dirname "$RESOLVED")
        while [ ! -d "$walk_dir" ] && [ "$walk_dir" != "$root" ] && [ "$walk_dir" != "/" ]; do
          walk_dir=$(dirname "$walk_dir")
        done
        wt_info=$(git -C "$walk_dir" rev-parse --show-toplevel --git-dir --git-common-dir 2>/dev/null) || continue
        wt_top=$(printf '%s\n' "$wt_info" | sed -n '1p')
        wt_gd=$(printf '%s\n' "$wt_info" | sed -n '2p')
        wt_cd=$(printf '%s\n' "$wt_info" | sed -n '3p')
        case "$wt_gd" in /*) ;; *) wt_gd="$walk_dir/$wt_gd" ;; esac
        case "$wt_cd" in /*) ;; *) wt_cd="$walk_dir/$wt_cd" ;; esac
        wt_gd_real=$(realpath "$wt_gd" 2>/dev/null || echo "")
        wt_cd_real=$(realpath "$wt_cd" 2>/dev/null || echo "")
        wt_top_real=$(realpath "$wt_top" 2>/dev/null || printf '%s' "$wt_top")
        if [ "$wt_top_real" != "$root" ] || [ -z "$wt_gd_real" ] || [ "$wt_gd_real" != "$wt_cd_real" ]; then
          continue
        fi
        git -C "$root" check-ignore -q -- "$RESOLVED" 2>/dev/null
        ci_rc=$?
        if [ "$ci_rc" -ne 1 ]; then
          continue
        fi
        ignored_parent=0
        p_dir=$(dirname "$RESOLVED")
        while [ ! -e "$p_dir" ] && [ "$p_dir" != "$root" ] && [ "$p_dir" != "/" ]; do
          git -C "$root" check-ignore -q -- "$p_dir/" 2>/dev/null
          ci_rc=$?
          if [ "$ci_rc" -ne 1 ]; then
            ignored_parent=1
            break
          fi
          p_dir=$(dirname "$p_dir")
        done
        [ "$ignored_parent" -eq 1 ] && continue
        REL="${RESOLVED#"$root"/}"
        emit_block "$root" "$(default_branch_of "$root")" "$TOOL_NAME of $REL in live checkout"
        ;;
    esac
  done <<<"$LIVE_ROOTS"
  exit 0
fi

# The judge is hooks/lib/live_checkout.py, imported so CPython caches its
# bytecode. PYTHONSAFEPATH=1 keeps the cwd off sys.path; the lib dir is added
# first. Any failure -> exit 0 (fail open).
RESULT=$(CWD="$CWD" LIVE_ROOTS="$LIVE_ROOTS" PYTHONSAFEPATH=1 python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import live_checkout' "$HOOK_LIB" 3<<<"$CMD" 2>/dev/null) || exit 0

[ -n "$RESULT" ] || exit 0

BLOCK_ROOT=$(printf '%s\n' "$RESULT" | sed -n '1p')
BLOCK_DEF=$(printf '%s\n' "$RESULT" | sed -n '2p')
BLOCK_REASON=$(printf '%s\n' "$RESULT" | sed -n '3p')
[ -n "$BLOCK_ROOT" ] && [ -n "$BLOCK_REASON" ] || exit 0

emit_block "$BLOCK_ROOT" "${BLOCK_DEF:-main}" "$BLOCK_REASON"
