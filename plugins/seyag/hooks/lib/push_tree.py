"""Judge one Bash command for push-tree-guard.sh.

Walks the command text in execution order via `shell_state.walk`. Each simple
`git` or `gh` command the walk reaches is one occurrence, and the walker
reaches an occurrence once per possible shell state ("world"). Those world
calls come back to back, so consecutive calls with an identical argv form one
occurrence. An occurrence resolves to one event:
  ("commit", <dir> | None, "git commit")   a `git commit` (None: unknown tree)
  ("push",   <dir>, "git push" | "gh pr create")
                                           a push that is tree-dependent
Worlds that agree on the directory collapse to one event. Worlds that disagree
make the occurrence ambiguous: a commit becomes an unknown-tree commit, and a
push is dropped.

The events are judged against the session's stored state: line 1 is the last
commit's toplevel; each following line is one acknowledged pair
`<commit_top>\t<push_top>`, at most MAX_ACKS kept, newest last. A state file
whose second line has no tab (the older format) reads as commit only.

Imported (not piped) by `push-tree-guard.sh` so CPython caches its bytecode.
Runs on import; any exception prints nothing and exits 0.

Contract:
  - input: command text on fd 3; env `CWD` (the payload cwd) and `PT_STATE`
    (the state file path, the caller's key already validated).
  - output: at most one line, the first hit; nothing otherwise.
"""

import os
import posixpath
import re
import subprocess
import sys
import tempfile
import time

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

PRUNE_AGE = 7 * 86400
MAX_ACKS = 8
HEAD_SHAPED = re.compile(r"^(HEAD|@)([~^@].*)?$")
REFLESS_FLAGS = frozenset(("--all", "--branches", "--mirror", "--tags", "--delete", "-d"))
VALUE_OPTS = frozenset(("-o", "--push-option", "--repo", "--receive-pack", "--exec"))
DRY_RUN = frozenset(("-n", "--dry-run"))

_TOPS = {}  # per process: up to MAX_WORLDS worlds may ask for the same cwd


class Context:
    def __init__(self):
        self.groups = []  # one list of per-world candidate events per occurrence
        self.last_key = None
        self.visited = set()
        self.subst_states = set()
        self.judged = set()
        self.leftovers = []
        self.leftover_mode = False


def top_info(d):
    """(toplevel, common git dir) of the worktree at `d`, or None."""
    if d not in _TOPS:
        _TOPS[d] = _read_top(d)
    return _TOPS[d]


def _read_top(d):
    if not d or not posixpath.isdir(d):
        return None
    env = {k: v for k, v in os.environ.items() if k not in ("GIT_DIR", "GIT_WORK_TREE")}
    try:
        r = subprocess.run(
            [
                "git", "-C", d, "rev-parse", "--path-format=absolute",
                "--show-toplevel", "--git-common-dir",
            ],
            capture_output=True,
            env=env,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    lines = r.stdout.decode("utf-8", "replace").splitlines()
    if len(lines) != 2 or not all(x.startswith("/") for x in lines):
        return None
    return lines[0], lines[1]


def push_tree_dependent(rest):
    """True when a `git push` with these words publishes the HEAD of its tree."""
    if any(w in DRY_RUN for w in rest):
        return False
    flags, positional = set(), []
    dashdash = False
    i = 0
    while i < len(rest):
        w = rest[i]
        i += 1
        if dashdash:
            positional.append(w)
        elif w == "--":
            dashdash = True
        elif w in VALUE_OPTS:
            i += 1
        elif w.startswith("-"):
            flags.add(w)
        else:
            positional.append(w)
    refspecs = positional[1:]
    for r in refspecs:
        src = r[1:] if r.startswith("+") else r
        if HEAD_SHAPED.match(src.split(":", 1)[0]):
            return True
    if refspecs:
        return False
    return not (flags & REFLESS_FLAGS)


def judge_git(unwrapped, state, payload_cwd):
    base = payload_cwd if state.unknown else state.cwd
    eff_dir, subcmd, rest = commit_diff.parse_git(strip_redirections(unwrapped[1:]), base)
    eff_dir = expand_home(expand_vars(eff_dir, state))
    unresolvable = unresolvable_cd_target(eff_dir)
    if subcmd == "commit" and "--dry-run" not in rest:
        if state.unknown or unresolvable:
            return ("commit", None, "git commit")
        return ("commit", eff_dir, "git commit")
    if subcmd == "push" and not state.unknown and not unresolvable:
        if push_tree_dependent(rest):
            return ("push", eff_dir, "git push")
    return None


def judge_gh(unwrapped, state):
    if state.unknown or unwrapped[1:3] != ["pr", "create"]:
        return None
    for w in unwrapped[3:]:
        if w in ("--head", "-H") or w.startswith("--head=") or w.startswith("-H"):
            return None
    return ("push", state.cwd, "gh pr create")


def _main():
    cmd = os.fsdecode(open(3, "rb").read()).removesuffix("\n")
    payload_cwd = os.environ.get("CWD", "")
    state_path = os.environ.get("PT_STATE", "")

    stripped = strip_quoted_indexed(strip_heredoc_bodies(cmd))
    if stripped is None:
        sys.exit(0)

    def run_command(argv, state, ctx):
        # Every call, git or not, ends the previous occurrence's run of
        # identical calls, so a repeated command later in the text is a new one.
        key = tuple(argv)
        if key != ctx.last_key or not ctx.groups:
            ctx.groups.append([])
            ctx.last_key = key
        unwrapped, _ = unwrap_runners(argv)
        if not unwrapped:
            return
        if apply_dir_builtin(argv, state):
            if any("$" in a or "`" in a for a in argv):
                ctx.subst_states.add(state.snapshot())
            return
        ctx.subst_states.add(state.snapshot())
        name = unwrapped[0].rsplit("/", 1)[-1].lower()
        if name not in ("git", "gh"):
            return
        wkey = (
            tuple(argv),
            state.cwd,
            state.unknown,
            tuple(sorted(state.env.items())),
        )
        if ctx.leftover_mode:
            if any(k[0] == tuple(argv) for k in ctx.judged):
                return
        else:
            ctx.judged.add(wkey)
        if name == "git":
            ev = judge_git(unwrapped, state, payload_cwd)
        else:
            ev = judge_gh(unwrapped, state)
        if ev is not None:
            ctx.groups[-1].append(ev)

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

    if ctx.groups and state_path:
        judge(ctx.groups, state_path)


def resolve(groups):
    """One event per occurrence, in order: worlds that agree on the directory
    collapse; disagreeing worlds make a commit unknown-tree and drop a push."""
    events = []
    for cands in groups:
        if not cands:
            continue
        dirs = {d for _, d, _ in cands}
        if len(dirs) == 1:
            events.append(cands[0])
        elif cands[0][0] == "commit":
            events.append(("commit", None, cands[0][2]))
    return events


def read_state(path):
    """(commit_top, acks) from the state file; a missing file is ("", []); None
    when the file exists but cannot be read. acks is a list of (commit, push)."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().split("\n")
    except FileNotFoundError:
        return "", []
    except OSError:
        return None
    commit = lines[0].rstrip("\r")
    rest = [ln.rstrip("\r") for ln in lines[1:] if ln]
    if any("\t" not in ln for ln in rest):
        return commit, []
    acks = []
    for ln in rest:
        c, _, p = ln.partition("\t")
        acks.append((c, p))
    return commit, acks[-MAX_ACKS:]


def write_state(path, commit_top, acks):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    cutoff = time.time() - PRUNE_AGE
    try:
        for entry in os.scandir(d):
            try:
                if entry.is_file(follow_symlinks=False) and entry.stat(follow_symlinks=False).st_mtime < cutoff:
                    os.unlink(entry.path)
            except OSError:
                pass
    except OSError:
        pass
    text = commit_top + "\n" + "".join(f"{c}\t{p}\n" for c, p in acks)
    fd, tmp_path = tempfile.mkstemp(prefix=".tmp.", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp_path, path)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def judge(groups, state_path):
    stored = read_state(state_path)
    if stored is None:
        return
    stored_commit, stored_acks = stored
    acked = set(stored_acks)
    sim = stored_commit
    hits = []
    for kind, d, label in resolve(groups):
        if kind == "commit":
            info = top_info(d) if d else None
            sim = info[0] if info else ""
            continue
        info = top_info(d)
        if info is None:
            continue
        top, common = info
        if not sim or top == sim or (sim, top) in acked:
            continue
        cinfo = top_info(sim)
        if cinfo is None or cinfo[1] != common:
            continue
        if not any(h[1] == sim and h[2] == top for h in hits):
            hits.append((label, sim, top))
    if hits:
        # The command will not run: the record stays, the pairs are acknowledged.
        commit = stored_commit
        acks = (list(stored_acks) + [(h[1], h[2]) for h in hits])[-MAX_ACKS:]
    else:
        commit = sim
        acks = list(stored_acks)
    if (commit, acks) == (stored_commit, stored_acks):
        return
    try:
        write_state(state_path, commit, acks)
    except OSError:
        return
    if hits:
        print("\t".join(hits[0]))


try:
    _main()
except Exception:
    sys.exit(0)
