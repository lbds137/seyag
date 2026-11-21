"""Judge one Bash command for worktree-branch-guard.sh.

Walks the command text in execution order via `shell_state.walk` and lists each
`git worktree add` under `.claude/worktrees/<x>` that creates a new local branch
(either explicitly via `-b`/`-B` or implicitly from the directory basename when
neither `-b`/`-B`, `-d`/`--detach`, nor `<commit-ish>` is given and no local
branch of that name already exists).

Imported (not piped) by `worktree-branch-guard.sh` so CPython caches its
bytecode. Runs on import; any exception prints nothing and exits 0.

Contract:
  - input: command text on fd 3; env `CWD` (the payload cwd).
  - output: one line per judged add, deduplicated in order:
      `<kind>\\t<branch>\\t<resolved path>`
    where `<kind>` is `explicit` or `implied`.
"""

import os
import posixpath
import subprocess
import sys

import commit_diff
from shell_quotes import (
    strip_heredoc_bodies,
    strip_quoted_indexed,
    strip_redirections,
    unwrap_runners,
)
from shell_state import (
    State,
    apply_dir_builtin,
    expand_home,
    expand_vars,
    unresolvable_cd_target,
    walk,
)
from worktree_add import parse_worktree_add


class Context:
    def __init__(self):
        self.hits = []
        self.seen_hits = set()
        self.visited = set()
        self.subst_states = set()
        self.judged = set()
        self.leftovers = []
        self.leftover_mode = False


def has_worktrees_segment(path):
    segs = [s for s in path.split("/") if s]
    return any(
        segs[i] == ".claude" and segs[i + 1] == "worktrees"
        for i in range(len(segs) - 2)
    )


def local_branch_exists(eff_dir, branch):
    if not eff_dir or not posixpath.isdir(eff_dir):
        return False
    try:
        env = {
            k: v
            for k, v in os.environ.items()
            if k not in ("GIT_DIR", "GIT_WORK_TREE")
        }
        r = subprocess.run(
            ["git", "-C", eff_dir, "show-ref", "--verify", "-q", f"refs/heads/{branch}"],
            capture_output=True,
            env=env,
            timeout=5,
        )
        return r.returncode == 0
    except Exception:
        return False


def judge_git(unwrapped, state, ctx, payload_cwd):
    args = strip_redirections(unwrapped[1:])
    base = payload_cwd if state.unknown else state.cwd
    eff_dir, subcmd, rest = commit_diff.parse_git(args, base)
    if not subcmd or subcmd.lower() != "worktree":
        return
    parsed = parse_worktree_add(rest)
    if parsed is None or parsed["path"] is None:
        return

    eff_dir = expand_home(expand_vars(eff_dir, state))
    raw_path = expand_home(expand_vars(parsed["path"], state))
    if (
        not raw_path
        or unresolvable_cd_target(raw_path)
        or (eff_dir and unresolvable_cd_target(eff_dir))
    ):
        return

    if raw_path.startswith("/"):
        resolved = posixpath.normpath(raw_path)
    elif eff_dir:
        resolved = posixpath.normpath(posixpath.join(eff_dir, raw_path))
    else:
        resolved = posixpath.normpath(raw_path)

    if not has_worktrees_segment(resolved):
        return

    if parsed["new_branch"]:
        branch = expand_home(expand_vars(parsed["new_branch"], state))
        if not branch or unresolvable_cd_target(branch):
            return
        kind = "explicit"
    elif parsed["detach"]:
        return
    elif parsed["commitish"] is not None:
        return
    else:
        branch = posixpath.basename(resolved)
        if not branch:
            return
        if local_branch_exists(eff_dir, branch):
            return
        kind = "implied"

    item = (kind, branch, resolved)
    if item not in ctx.seen_hits:
        ctx.seen_hits.add(item)
        ctx.hits.append(item)


def _main():
    cmd = os.fsdecode(open(3, "rb").read()).removesuffix("\n")
    payload_cwd = os.environ.get("CWD", "")

    stripped = strip_quoted_indexed(strip_heredoc_bodies(cmd))
    if stripped is None:
        sys.exit(0)

    def run_command(argv, state, ctx):
        unwrapped, _ = unwrap_runners(argv)
        if not unwrapped:
            return
        if apply_dir_builtin(argv, state):
            if any("$" in a or "`" in a for a in argv):
                ctx.subst_states.add(state.snapshot())
            return
        ctx.subst_states.add(state.snapshot())
        raw_name = unwrapped[0]
        name = raw_name.rsplit("/", 1)[-1].lower()
        if name != "git":
            return
        key = (
            tuple(argv),
            state.cwd,
            state.unknown,
            tuple(sorted(state.env.items())),
        )
        if ctx.leftover_mode:
            if any(k[0] == tuple(argv) for k in ctx.judged):
                return
        else:
            ctx.judged.add(key)
        judge_git(unwrapped, state, ctx, payload_cwd)

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

    for kind, branch, resolved in ctx.hits:
        print(f"{kind}\t{branch}\t{resolved}")


try:
    _main()
except Exception:
    sys.exit(0)
