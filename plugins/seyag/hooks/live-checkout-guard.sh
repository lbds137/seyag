#!/bin/bash
# PreToolUse hook (matchers: Bash, Edit|Write|MultiEdit|NotebookEdit): block
# branch switches, stashes, commits, history/working-tree mutations, and
# non-ignored file edits inside a live plugin checkout (a directory-source
# checkout whose working tree is the code every session loads).
#
# LIVE ROOTS:
#   (a) the git toplevel of ${CLAUDE_PLUGIN_ROOT:-<hooks dir>/..} when inside a
#       git working tree, unless SYG_LIVE_CHECKOUT_AUTO=0; plus
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
#   resolves each git invocation's effective directory (after cd/pushd, then
#   `git -C <dir>` and `--work-tree` / `GIT_WORK_TREE`, or `--git-dir` /
#   `GIT_DIR` when only a git-dir is named). An unreadable cd target or an
#   unexpanded `$VAR` / glob in `-C`, `--work-tree`, `--git-dir`, `GIT_DIR`, or
#   `GIT_WORK_TREE` falls back to the payload cwd (the cwd-drift-guard
#   baseline). When the effective target is a live root:
#     BLOCK:
#       - `checkout` / `switch` to anything other than the default branch
#         (including `-b`, `-B`, `-c`, `-C`, `--create`, `--force-create`,
#         `-d`, `--detach`, `--orphan`, a sha, a tag);
#       - `checkout <ref> [--] <paths>` and `restore --source=<ref>` /
#         `-s <ref>` where <ref> is not the default branch or HEAD;
#       - `stash` except `list` / `show`;
#       - `commit`, `reset`, `rm`, `mv`;
#       - `merge`, `rebase`, `cherry-pick`, `revert`, `am` (except `--abort` or
#         `--quit`);
#       - `read-tree` with `-u` or `-m`;
#       - `pull` without `--ff-only`, or `pull --ff-only` with a refspec other
#         than the default branch;
#       - `apply` with `--apply` or `--index`, or without `--check` / `--stat` /
#         `--numstat` / `--summary`;
#       - `bisect start`.
#     ALLOW everything else, including:
#       - `checkout [--] <paths>` and plain `restore` (or with `--source` / `-s`
#         naming the default branch or HEAD);
#       - `checkout <default>` / `switch <default>`;
#       - `merge` / `rebase` / `cherry-pick` / `revert` / `am` with `--abort`
#         or `--quit`;
#       - `pull --ff-only` (with no refspec, a remote alone, or a remote plus
#         the default branch), `fetch`, all read-only subcommands;
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
#   `SYG_ALLOW_LIVE_CHECKOUT=1` as a word in the command's own text (Bash), or
#   in the hook's environment (all tools), for an action the owner approved.
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

TOOL_NAME=$(jq -r '.tool_name // empty' <<<"$INPUT" 2>/dev/null || echo "")
case "$TOOL_NAME" in
  Bash | Edit | Write | MultiEdit | NotebookEdit) ;;
  *) exit 0 ;;
esac

CMD=""
FILE_PATH=""
if [ "$TOOL_NAME" = "Bash" ]; then
  CMD=$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null || echo "")
  [ -n "$CMD" ] || exit 0
  # Cheap prefilter: only a command mentioning `git` (case-insensitive) or
  # ANSI-C / locale quoting that could spell it can ever block.
  if ! grep -qE '(^|[^[:alnum:]_.-])[Gg][Ii][Tt]([^[:alnum:]_-]|$)|\$['\''"]' <<<"$CMD"; then
    exit 0
  fi
elif [ "$TOOL_NAME" = "NotebookEdit" ]; then
  FILE_PATH=$(jq -r '.tool_input.notebook_path // empty' <<<"$INPUT" 2>/dev/null || echo "")
  [ -n "$FILE_PATH" ] || exit 0
else
  FILE_PATH=$(jq -r '.tool_input.file_path // empty' <<<"$INPUT" 2>/dev/null || echo "")
  [ -n "$FILE_PATH" ] || exit 0
fi

CWD=$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null || echo "")

HOOKS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK_LIB="$HOOKS_DIR/lib"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$HOOKS_DIR/.." && pwd)}"

LIVE_ROOTS=""
add_live_root() {
  local cand="$1" info top gd cd gd_real cd_real top_real
  [ -n "$cand" ] && [ -d "$cand" ] || return 0
  info=$(git -C "$cand" rev-parse --show-toplevel --git-dir --git-common-dir 2>/dev/null) || return 0
  top=$(printf '%s\n' "$info" | sed -n '1p')
  gd=$(printf '%s\n' "$info" | sed -n '2p')
  cd=$(printf '%s\n' "$info" | sed -n '3p')
  [ -n "$top" ] && [ -n "$gd" ] && [ -n "$cd" ] || return 0
  case "$gd" in /*) ;; *) gd="$cand/$gd" ;; esac
  case "$cd" in /*) ;; *) cd="$cand/$cd" ;; esac
  gd_real=$(realpath "$gd" 2>/dev/null || echo "")
  cd_real=$(realpath "$cd" 2>/dev/null || echo "")
  # Only the MAIN working tree of a live repo is live; linked worktrees are not.
  [ -n "$gd_real" ] && [ "$gd_real" = "$cd_real" ] || return 0
  top_real=$(realpath "$top" 2>/dev/null || printf '%s' "$top")
  case $'\n'"$LIVE_ROOTS"$'\n' in
    *$'\n'"$top_real"$'\n'*) ;;
    *) LIVE_ROOTS="${LIVE_ROOTS:+$LIVE_ROOTS$'\n'}$top_real" ;;
  esac
}

if [ "${SYG_LIVE_CHECKOUT_AUTO:-1}" != "0" ]; then
  add_live_root "$PLUGIN_ROOT"
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
Fix: do the work in a linked worktree (git worktree add -b <branch> $root/.claude/worktrees/<name> $def_branch) and commit/push from there; for Edit/Write, edit the same path inside that worktree.
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

RESULT=$(CWD="$CWD" LIVE_ROOTS="$LIVE_ROOTS" HOOK_LIB="$HOOK_LIB" PYTHONDONTWRITEBYTECODE=1 python3 - 3<<<"$CMD" <<'PYEOF' 2>/dev/null
import os
import posixpath
import re
import subprocess
import sys

sys.path.insert(0, os.environ["HOOK_LIB"])
from shell_quotes import (
    strip_heredoc_bodies,
    strip_quoted_indexed,
    strip_redirections,
    unwrap_runners,
)
from shell_state import (
    State,
    TRACKED_ENV,
    apply_dir_builtin,
    expand_home,
    expand_vars,
    unresolvable_cd_target,
    walk,
)

cmd = os.fsdecode(open(3, "rb").read()).removesuffix("\n")
payload_cwd = os.environ.get("CWD", "")
live_roots = {
    line.strip()
    for line in os.environ.get("LIVE_ROOTS", "").splitlines()
    if line.strip()
}
if not live_roots:
    sys.exit(0)

stripped = strip_quoted_indexed(strip_heredoc_bodies(cmd))
if stripped is None:
    # Unterminated quote: fail open.
    sys.exit(0)
view = stripped[0]

# Bypass word anywhere in the command's unquoted text.
if re.search(r"(?:^|[\s;|&()`])SYG_ALLOW_LIVE_CHECKOUT=1(?:$|[\s;|&()`])", view):
    sys.exit(0)

ASSIGN_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.S)
BUILTIN_RUNNERS = {"builtin", "command"}

GIT_GLOBAL_VALUE_OPTS = {
    "-c",
    "--namespace",
    "--super-prefix",
    "--config-env",
    "--exec-path",
}
TOPLEVEL_SUBST = (
    "$(git rev-parse --show-toplevel)",
    "`git rev-parse --show-toplevel`",
    '"$(git rev-parse --show-toplevel)"',
    '"`git rev-parse --show-toplevel`"',
)
PWD_SUBST = ("$(pwd)", "`pwd`", '"$(pwd)"', '"`pwd`"')

SWITCH_BLOCK_LONG = {"--create", "--force-create", "--detach", "--orphan"}
SWITCH_BLOCK_SHORT = set("cCd")
SWITCH_VALUE_OPTS = {"--conflict", "--track"}

CHECKOUT_VALUE_OPTS = {
    "--conflict",
    "--pathspec-from-file",
    "-U",
    "--unified",
    "--inter-hunk-context",
}
RESTORE_VALUE_OPTS = {
    "--conflict",
    "--pathspec-from-file",
    "-U",
    "--unified",
    "--inter-hunk-context",
}
PULL_VALUE_OPTS = {
    "-s",
    "--strategy",
    "-X",
    "--strategy-option",
    "--cleanup",
    "--depth",
    "--deepen",
    "--shallow-since",
    "--shallow-exclude",
    "--negotiation-tip",
    "-o",
    "--server-option",
    "--upload-pack",
    "-j",
    "--jobs",
    "--refmap",
}
ALWAYS_BLOCK_SUBCMDS = {
    "commit",
    "reset",
    "rm",
    "mv",
}
ABORTABLE_SUBCMDS = {
    "merge",
    "rebase",
    "cherry-pick",
    "revert",
    "am",
}
APPLY_SAFE_FLAGS = {"--check", "--stat", "--numstat", "--summary"}

_WT_MEMO = {}
_DEF_BRANCH_MEMO = {}


def is_valid_dir(d):
    return bool(d and d.startswith("/") and posixpath.isdir(d))


def worktree_live_root(d):
    """Return the canonical toplevel if `d` is inside a live root's MAIN working
    tree, else None."""
    if not is_valid_dir(d):
        return None
    if d not in _WT_MEMO:
        root_hit = None
        try:
            r = subprocess.run(
                ["git", "-C", d, "rev-parse", "--show-toplevel", "--git-dir", "--git-common-dir"],
                capture_output=True,
                text=True,
                errors="replace",
                timeout=5,
            )
            if r.returncode == 0:
                lines = [ln.rstrip("\r\n") for ln in r.stdout.splitlines()]
                if len(lines) >= 3 and all(lines[:3]):
                    top, gd, cd = lines[0], lines[1], lines[2]
                    if not gd.startswith("/"):
                        gd = posixpath.join(d, gd)
                    if not cd.startswith("/"):
                        cd = posixpath.join(d, cd)
                    gd_real = os.path.realpath(gd)
                    cd_real = os.path.realpath(cd)
                    top_real = os.path.realpath(top)
                    if gd_real == cd_real and top_real in live_roots:
                        root_hit = top_real
        except Exception:
            root_hit = None
        _WT_MEMO[d] = root_hit
    return _WT_MEMO[d]


def default_branch(root):
    if root not in _DEF_BRANCH_MEMO:
        br = "main"
        try:
            r = subprocess.run(
                ["git", "-C", root, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
                capture_output=True,
                text=True,
                errors="replace",
                timeout=5,
            )
            if r.returncode == 0:
                ref = r.stdout.strip()
                if ref.startswith("origin/") and len(ref) > len("origin/"):
                    br = ref[len("origin/") :]
        except Exception:
            pass
        _DEF_BRANCH_MEMO[root] = br
    return _DEF_BRANCH_MEMO[root]


def git_toplevel_of(d):
    if not is_valid_dir(d):
        return None
    try:
        r = subprocess.run(
            ["git", "-C", d, "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            errors="replace",
            timeout=5,
        )
        if r.returncode == 0:
            top = r.stdout.strip()
            return top if top.startswith("/") else None
    except Exception:
        pass
    return None


def is_commit(eff_dir, rev):
    if not is_valid_dir(eff_dir) or not rev:
        return False
    try:
        r = subprocess.run(
            ["git", "-C", eff_dir, "rev-parse", "--verify", "-q", f"{rev}^{{commit}}"],
            capture_output=True,
            text=True,
            errors="replace",
            timeout=5,
        )
        return r.returncode == 0
    except Exception:
        return False


def apply_dir_step(step, cur_dir, uncertain, state):
    """Apply a `-C <step>` directory change; return `(new_dir, new_uncertain)`.
    An unresolvable or non-existent target marks `uncertain=True` and resets to
    `payload_cwd`."""
    if step is None:
        return payload_cwd, True
    step = expand_vars(step, state)
    step = expand_home(step)
    if step in PWD_SUBST:
        if uncertain or not is_valid_dir(cur_dir):
            return payload_cwd, True
        return cur_dir, False
    if step in TOPLEVEL_SUBST:
        base = payload_cwd if (uncertain or not is_valid_dir(cur_dir)) else cur_dir
        top = git_toplevel_of(base)
        if top and is_valid_dir(top):
            return top, False
        return payload_cwd, True
    if not step or unresolvable_cd_target(step):
        return payload_cwd, True
    if step.startswith("/"):
        cand = posixpath.normpath(step)
        if is_valid_dir(cand):
            return cand, False
        return payload_cwd, True
    if uncertain or not is_valid_dir(cur_dir):
        return payload_cwd, True
    cand = posixpath.normpath(posixpath.join(cur_dir, step))
    if is_valid_dir(cand):
        return cand, False
    return payload_cwd, True


def judge_switch(rest, default_br):
    if "-h" in rest or "--help" in rest:
        return None
    pos = []
    i = 0
    while i < len(rest):
        w = rest[i]
        if w == "--":
            pos.extend(rest[i + 1 :])
            break
        if w.startswith("--"):
            name, eq, _ = w.partition("=")
            if name in SWITCH_BLOCK_LONG:
                return f"git switch {name} in live checkout"
            if name in SWITCH_VALUE_OPTS and not eq:
                i += 2
            else:
                i += 1
            continue
        if w.startswith("-") and w != "-":
            for ch in w[1:]:
                if ch in SWITCH_BLOCK_SHORT:
                    return f"git switch -{ch} in live checkout"
            i += 1
            continue
        pos.append(w)
        i += 1
    if len(pos) == 1 and pos[0] == default_br:
        return None
    target = pos[0] if pos else "(none)"
    return f"git switch to '{target}' in live checkout (default branch is '{default_br}')"


def judge_checkout(rest, default_br, eff_dir):
    if "-h" in rest or "--help" in rest:
        return None
    has_dd = "--" in rest
    before_dd = rest[: rest.index("--")] if has_dd else rest
    pos_before = []
    i = 0
    while i < len(before_dd):
        w = before_dd[i]
        if w.startswith("--"):
            name, eq, _ = w.partition("=")
            if name in ("--detach", "--orphan"):
                return f"git checkout {name} in live checkout"
            if name in CHECKOUT_VALUE_OPTS and not eq:
                i += 2
            else:
                i += 1
            continue
        if w.startswith("-") and w != "-":
            shorts = w[1:]
            for idx, ch in enumerate(shorts):
                if ch in ("b", "B", "d"):
                    return f"git checkout -{ch} in live checkout"
                if f"-{ch}" in CHECKOUT_VALUE_OPTS:
                    if idx == len(shorts) - 1:
                        i += 1
                    break
            i += 1
            continue
        pos_before.append(w)
        i += 1
    if has_dd:
        if not pos_before:
            return None
        if len(pos_before) == 1 and pos_before[0] in (default_br, "HEAD"):
            return None
        ref = pos_before[0]
        return f"git checkout {ref} -- <paths> in live checkout (only '{default_br}' or 'HEAD' is allowed)"
    if not pos_before:
        return None
    pos0 = pos_before[0]
    if not is_commit(eff_dir, pos0):
        return None
    if len(pos_before) > 1:
        if pos0 in (default_br, "HEAD"):
            return None
        return f"git checkout {pos0} -- <paths> in live checkout (only '{default_br}' or 'HEAD' is allowed)"
    if pos0 == default_br:
        return None
    return f"git checkout '{pos0}' in live checkout (default branch is '{default_br}')"


def judge_restore(rest, default_br):
    if "-h" in rest or "--help" in rest:
        return None
    before_dd = rest[: rest.index("--")] if "--" in rest else rest
    sources = []
    i = 0
    while i < len(before_dd):
        w = before_dd[i]
        if w.startswith("--"):
            name, eq, val = w.partition("=")
            if name == "--source":
                if eq:
                    sources.append(val)
                    i += 1
                else:
                    sources.append(before_dd[i + 1] if i + 1 < len(before_dd) else "")
                    i += 2
                continue
            if name in RESTORE_VALUE_OPTS and not eq:
                i += 2
            else:
                i += 1
            continue
        if w.startswith("-") and w != "-":
            shorts = w[1:]
            for idx, ch in enumerate(shorts):
                if ch == "s":
                    if idx < len(shorts) - 1:
                        rem = shorts[idx + 1 :]
                        sources.append(rem[1:] if rem.startswith("=") else rem)
                    else:
                        sources.append(before_dd[i + 1] if i + 1 < len(before_dd) else "")
                        i += 1
                    break
                if f"-{ch}" in RESTORE_VALUE_OPTS:
                    if idx == len(shorts) - 1:
                        i += 1
                    break
            i += 1
            continue
        i += 1
    for src in sources:
        if src not in (default_br, "HEAD"):
            return f"git restore --source={src} in live checkout (only '{default_br}' or 'HEAD' is allowed)"
    return None


def judge_pull(rest, default_br):
    if "-h" in rest or "--help" in rest:
        return None
    before_dd = rest[: rest.index("--")] if "--" in rest else rest
    if "--ff-only" not in before_dd or "--no-ff" in before_dd:
        return "git pull without --ff-only in live checkout"
    pos = []
    i = 0
    while i < len(rest):
        w = rest[i]
        if w == "--":
            pos.extend(rest[i + 1 :])
            break
        if w.startswith("--"):
            name, eq, _ = w.partition("=")
            if name in PULL_VALUE_OPTS and not eq:
                i += 2
            else:
                i += 1
            continue
        if w.startswith("-") and w != "-":
            shorts = w[1:]
            for idx, ch in enumerate(shorts):
                if f"-{ch}" in PULL_VALUE_OPTS:
                    if idx == len(shorts) - 1:
                        i += 1
                    break
            i += 1
            continue
        pos.append(w)
        i += 1
    if len(pos) <= 1:
        return None
    if len(pos) == 2 and pos[1] == default_br:
        return None
    return f"git pull --ff-only with refspec '{' '.join(pos[1:])}' in live checkout (only '{default_br}' is allowed)"


def judge_subcommand(subcmd, rest, default_br, eff_dir):
    if subcmd == "switch":
        return judge_switch(rest, default_br)
    if subcmd == "checkout":
        return judge_checkout(rest, default_br, eff_dir)
    if subcmd == "restore":
        return judge_restore(rest, default_br)
    if subcmd == "stash":
        if "-h" in rest or "--help" in rest:
            return None
        if rest and rest[0] in ("list", "show"):
            return None
        return "git stash in live checkout"
    if subcmd in ALWAYS_BLOCK_SUBCMDS:
        if "-h" in rest or "--help" in rest:
            return None
        return f"git {subcmd} in live checkout"
    if subcmd in ABORTABLE_SUBCMDS:
        if "-h" in rest or "--help" in rest:
            return None
        before_dd = rest[: rest.index("--")] if "--" in rest else rest
        if "--abort" in before_dd or "--quit" in before_dd:
            return None
        return f"git {subcmd} in live checkout"
    if subcmd == "read-tree":
        if "-h" in rest or "--help" in rest:
            return None
        before_dd = rest[: rest.index("--")] if "--" in rest else rest
        for w in before_dd:
            if w.startswith("-") and not w.startswith("--") and ("u" in w[1:] or "m" in w[1:]):
                return "git read-tree with -u/-m in live checkout"
        return None
    if subcmd == "pull":
        return judge_pull(rest, default_br)
    if subcmd == "apply":
        if "-h" in rest or "--help" in rest:
            return None
        before_dd = rest[: rest.index("--")] if "--" in rest else rest
        if (
            "--apply" not in before_dd
            and "--index" not in before_dd
            and any(w in APPLY_SAFE_FLAGS for w in before_dd)
        ):
            return None
        return "git apply in live checkout"
    if subcmd == "bisect":
        if "-h" in rest or "--help" in rest:
            return None
        first_pos = next((w for w in rest if not w.startswith("-")), None)
        if first_pos == "start":
            return "git bisect start in live checkout"
        return None
    return None


def do_export(state, args, declare):
    """`export [-n] NAME=V…`, `declare`/`typeset [-x|+x] NAME=V…`."""
    exporting = not declare
    unexport = False
    i = 0
    while i < len(args) and args[i][:1] in ("-", "+") and len(args[i]) > 1:
        opt = args[i]
        i += 1
        if opt == "--":
            break
        letters = opt[1:]
        if "f" in letters:
            return
        if opt.startswith("+"):
            if declare and "x" in letters:
                unexport = True
        elif declare:
            if "x" in letters:
                exporting = True
        elif "n" in letters:
            unexport = True
    for w in args[i:]:
        m = ASSIGN_RE.match(w)
        name = m.group(1) if m else w
        if name not in TRACKED_ENV:
            continue
        if unexport:
            state.env.pop(name, None)
        elif exporting and m:
            state.env[name] = m.group(2)
        elif exporting and name in state.vars:
            state.env[name] = state.vars[name] if state.vars[name] is not None else "$"


def do_unset(state, args):
    i = 0
    while i < len(args) and args[i].startswith("-"):
        opt = args[i]
        i += 1
        if opt == "--":
            break
        if "f" in opt[1:]:
            return
    for w in args[i:]:
        state.env.pop(w, None)


def apply_runner_chdirs(prefix_words, cur_dir, uncertain, state):
    """Apply `env -C <dir>` / `env --chdir=<dir>` steps in the runner prefix;
    any other runner chdir (`sudo -D`) marks the directory uncertain."""
    i = 0
    while i < len(prefix_words):
        w = prefix_words[i]
        if w in ("-C", "--chdir"):
            step = prefix_words[i + 1] if i + 1 < len(prefix_words) else None
            cur_dir, uncertain = apply_dir_step(step, cur_dir, uncertain, state)
            i += 2
            continue
        if w.startswith("--chdir="):
            cur_dir, uncertain = apply_dir_step(w[len("--chdir=") :], cur_dir, uncertain, state)
            i += 1
            continue
        if w.startswith("-C") and len(w) > 2 and not w.startswith("--"):
            cur_dir, uncertain = apply_dir_step(w[2:], cur_dir, uncertain, state)
            i += 1
            continue
        if w == "-D" or w.startswith("--chdir"):
            return payload_cwd, True
        i += 1
    return cur_dir, uncertain


class Context:
    def __init__(self):
        self.blocking = []
        self.visited = set()
        self.subst_states = set()
        self.judged = set()
        self.leftovers = []
        self.leftover_mode = False


def judge_git(argv, unwrapped, info, state, ctx):
    if "SYG_ALLOW_LIVE_CHECKOUT=1" in argv or state.vars.get("SYG_ALLOW_LIVE_CHECKOUT") == "1":
        return
    cur_dir = state.cwd
    uncertain = state.unknown or not is_valid_dir(cur_dir)
    if uncertain:
        cur_dir = payload_cwd
        uncertain = not is_valid_dir(cur_dir)

    prefix_len = max(0, len(argv) - len(unwrapped))
    prefix = argv[:prefix_len]
    if info.get("chdir"):
        cur_dir, uncertain = apply_runner_chdirs(prefix, cur_dir, uncertain, state)

    env = dict(state.env)
    p_idx = 0
    while p_idx < len(prefix):
        pw = prefix[p_idx]
        if pw == "-u" and p_idx + 1 < len(prefix):
            env.pop(prefix[p_idx + 1], None)
            p_idx += 2
            continue
        if pw.startswith("--unset="):
            env.pop(pw[len("--unset=") :], None)
            p_idx += 1
            continue
        m = ASSIGN_RE.match(pw)
        if m and m.group(1) in ("GIT_DIR", "GIT_WORK_TREE"):
            env[m.group(1)] = m.group(2)
        p_idx += 1

    has_work_tree = "GIT_WORK_TREE" in env
    work_tree_val = env.get("GIT_WORK_TREE")
    has_git_dir = "GIT_DIR" in env
    git_dir_val = env.get("GIT_DIR")

    words = unwrapped[:1] + strip_redirections(unwrapped[1:])
    args = words[1:]
    i = 0
    subcmd = None
    rest = []
    while i < len(args):
        w = args[i]
        if w == "--":
            break
        if not w.startswith("-") or w == "-":
            subcmd = w.lower()
            rest = args[i + 1 :]
            break
        if w == "-C":
            step = args[i + 1] if i + 1 < len(args) else None
            cur_dir, uncertain = apply_dir_step(step, cur_dir, uncertain, state)
            i += 2
            continue
        if w.startswith("-C") and len(w) > 2:
            cur_dir, uncertain = apply_dir_step(w[2:], cur_dir, uncertain, state)
            i += 1
            continue
        if w == "--work-tree":
            has_work_tree = True
            work_tree_val = args[i + 1] if i + 1 < len(args) else None
            i += 2
            continue
        if w.startswith("--work-tree="):
            has_work_tree = True
            work_tree_val = w[len("--work-tree=") :]
            i += 1
            continue
        if w == "--git-dir":
            has_git_dir = True
            git_dir_val = args[i + 1] if i + 1 < len(args) else None
            i += 2
            continue
        if w.startswith("--git-dir="):
            has_git_dir = True
            git_dir_val = w[len("--git-dir=") :]
            i += 1
            continue
        if w in GIT_GLOBAL_VALUE_OPTS:
            i += 2
            continue
        if w.startswith("-c") and len(w) > 2 and not w.startswith("--"):
            i += 1
            continue
        if w in ("-h", "--help", "-v", "--version"):
            return
        i += 1

    if not subcmd:
        return

    gd_expanded = expand_home(expand_vars(git_dir_val, state)) if git_dir_val is not None else None
    gd_unexpanded = has_git_dir and (not gd_expanded or unresolvable_cd_target(gd_expanded))

    if has_work_tree:
        cur_dir, uncertain = apply_dir_step(work_tree_val, cur_dir, uncertain, state)
        if gd_unexpanded:
            uncertain = True
        eff_dir = payload_cwd if (uncertain or not is_valid_dir(cur_dir)) else cur_dir
        live_root = worktree_live_root(eff_dir)
    elif has_git_dir:
        if gd_unexpanded or (not gd_expanded.startswith("/") and (uncertain or not is_valid_dir(cur_dir))):
            eff_dir = payload_cwd
            live_root = worktree_live_root(eff_dir)
        else:
            gd_path = gd_expanded if gd_expanded.startswith("/") else posixpath.join(cur_dir, gd_expanded)
            gd_real = os.path.realpath(gd_path)
            live_root = None
            for r in sorted(live_roots):
                if gd_real == os.path.realpath(posixpath.join(r, ".git")):
                    live_root = r
                    break
            if not live_root:
                return
            eff_dir = live_root
    else:
        eff_dir = payload_cwd if (uncertain or not is_valid_dir(cur_dir)) else cur_dir
        live_root = worktree_live_root(eff_dir)

    if not live_root:
        return

    def_br = default_branch(live_root)
    reason = judge_subcommand(subcmd, rest, def_br, eff_dir)
    if reason:
        ctx.blocking.append((live_root, def_br, reason))


def run_command(argv, state, ctx):
    unwrapped, info = unwrap_runners(argv)
    if not unwrapped:
        return
    if apply_dir_builtin(argv, state):
        if any("$" in a or "`" in a for a in argv):
            ctx.subst_states.add(state.snapshot())
        return
    raw_name = unwrapped[0]
    if set(info["runners"]) <= BUILTIN_RUNNERS:
        b_args = strip_redirections(unwrapped[1:])
        if raw_name in ("export", "declare", "typeset"):
            do_export(state, b_args, declare=raw_name != "export")
            ctx.subst_states.add(state.snapshot())
            return
        if raw_name == "unset":
            do_unset(state, b_args)
            ctx.subst_states.add(state.snapshot())
            return
    ctx.subst_states.add(state.snapshot())
    name = raw_name.rsplit("/", 1)[-1].lower()
    if name != "git":
        return
    key = (tuple(argv), state.cwd, state.unknown, tuple(sorted(state.env.items())))
    if ctx.leftover_mode:
        if any(k[0] == tuple(argv) for k in ctx.judged):
            return
    else:
        ctx.judged.add(key)
    judge_git(argv, unwrapped, info, state, ctx)


ctx = Context()
walk(cmd, 0, State(payload_cwd, payload_cwd=payload_cwd), ctx, run_command)

ctx.leftover_mode = True
states = sorted(ctx.subst_states or ctx.visited)
done = set()
while ctx.leftovers:
    span, depth = ctx.leftovers.pop(0)
    if (span, depth) in done:
        continue
    done.add((span, depth))
    for cwd, env in states:
        walk(span, depth, State(cwd, dict(env), payload_cwd), ctx, run_command)

if not ctx.blocking:
    sys.exit(0)

root, def_br, reason = ctx.blocking[0]
print(root)
print(def_br)
print(reason)
PYEOF
) || exit 0

[ -n "$RESULT" ] || exit 0

BLOCK_ROOT=$(printf '%s\n' "$RESULT" | sed -n '1p')
BLOCK_DEF=$(printf '%s\n' "$RESULT" | sed -n '2p')
BLOCK_REASON=$(printf '%s\n' "$RESULT" | sed -n '3p')
[ -n "$BLOCK_ROOT" ] && [ -n "$BLOCK_REASON" ] || exit 0

emit_block "$BLOCK_ROOT" "${BLOCK_DEF:-main}" "$BLOCK_REASON"
