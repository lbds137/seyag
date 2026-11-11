"""Judge one Bash command for live-checkout-guard.sh.

Decides whether the command's git steps would switch, stash, commit, or
otherwise mutate a live plugin checkout (the rules are in live-checkout-guard.sh's
header). The body is top-level code with no main(): it runs on import, and
its functions read the module globals it assigns, so keep it that way.

Only live-checkout-guard.sh imports this module, and only through
`python3 -c 'import live_checkout'` with hooks/lib first on sys.path. Being
imported (not run as a script or piped through a heredoc) is what lets
CPython cache its bytecode under run.sh's PYTHONPYCACHEPREFIX; the caller also
sets PYTHONSAFEPATH=1 so the process cwd (a session's repo) is never searched
for modules.

Contract:
  - input: the command text on fd 3; env CWD (the payload cwd) and LIVE_ROOTS
    (newline-separated live roots, each already a realpath).
  - output: when the command blocks, exactly three lines on stdout: the live
    root, its default branch, and the reason. Otherwise nothing; the module
    exits 0 by sys.exit(0) when there is nothing to judge.
  - fail-open is the caller's job: any exception here exits non-zero with
    stdout empty, and the caller treats that as allow.
"""

import os
import posixpath
import re
import subprocess
import sys

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

ASSIGN_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.S)
PREV_BRANCH_RE = re.compile(r"^@\{-[0-9]+\}$")
BUILTIN_RUNNERS = {"builtin", "command"}
LIVE_TRACKED_ENV = set(TRACKED_ENV) | {"SYG_ALLOW_LIVE_CHECKOUT"}

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

CHECKOUT_VALUE_OPTS = {
    "--pathspec-from-file",
}
RESTORE_VALUE_OPTS = {
    "--pathspec-from-file",
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
SPARSE_CHECKOUT_BLOCK_SUBCMDS = {"set", "add", "reapply", "init", "disable"}

_WT_MEMO = {}
_DEF_BRANCH_MEMO = {}


def is_valid_dir(d):
    return bool(d and d.startswith("/") and posixpath.isdir(d))


def is_in_new_worktree(d, ctx):
    if not d or not d.startswith("/"):
        return False
    norm = posixpath.normpath(d)
    for wt in ctx.new_worktrees:
        if norm == wt or norm.startswith(wt.rstrip("/") + "/"):
            return True
    return False


def is_known_dir(d, ctx):
    return is_valid_dir(d) or is_in_new_worktree(d, ctx)


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


def is_tracked_or_existing_path(eff_dir, path):
    if not is_valid_dir(eff_dir) or not path:
        return False
    if os.path.lexists(posixpath.join(eff_dir, path)):
        return True
    try:
        r = subprocess.run(
            ["git", "-C", eff_dir, "ls-files", "--error-unmatch", "--", path],
            capture_output=True,
            text=True,
            errors="replace",
            timeout=5,
        )
        return r.returncode == 0
    except Exception:
        return False


def has_remote_branch(eff_dir, branch):
    if not is_valid_dir(eff_dir) or not branch or branch == "HEAD":
        return False
    try:
        r = subprocess.run(
            ["git", "-C", eff_dir, "for-each-ref", "--format=%(refname)", "refs/remotes"],
            capture_output=True,
            text=True,
            errors="replace",
            timeout=5,
        )
        if r.returncode != 0:
            return False
        for line in r.stdout.splitlines():
            parts = line.strip().split("/", 3)
            if len(parts) == 4 and parts[0] == "refs" and parts[1] == "remotes" and parts[3] == branch:
                return True
        return False
    except Exception:
        return False


def apply_dir_step(step, cur_dir, uncertain, state, ctx):
    """Apply a `-C <step>` directory change; return `(new_dir, new_uncertain)`.
    An unresolvable or non-existent target (unless equal to or under a recorded
    new linked worktree) marks `uncertain=True` and resets to `payload_cwd`."""
    if step is None:
        return payload_cwd, True
    step = expand_vars(step, state)
    step = expand_home(step)
    if step in PWD_SUBST:
        if uncertain or not is_known_dir(cur_dir, ctx):
            return payload_cwd, True
        return cur_dir, False
    if step in TOPLEVEL_SUBST:
        if not uncertain and is_in_new_worktree(cur_dir, ctx):
            return cur_dir, False
        base = payload_cwd if (uncertain or not is_valid_dir(cur_dir)) else cur_dir
        top = git_toplevel_of(base)
        if top and is_valid_dir(top):
            return top, False
        return payload_cwd, True
    if not step or unresolvable_cd_target(step):
        return payload_cwd, True
    if step.startswith("/"):
        cand = posixpath.normpath(step)
        if is_known_dir(cand, ctx):
            return cand, False
        return payload_cwd, True
    if uncertain or not is_known_dir(cur_dir, ctx):
        return payload_cwd, True
    cand = posixpath.normpath(posixpath.join(cur_dir, step))
    if is_known_dir(cand, ctx):
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
            name, _, _ = w.partition("=")
            if name in SWITCH_BLOCK_LONG:
                return f"git switch {name} in live checkout"
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
    if len(pos_before) == 1 and (pos0 == "-" or PREV_BRANCH_RE.match(pos0)):
        return f"git checkout '{pos0}' in live checkout (default branch is '{default_br}')"
    if PREV_BRANCH_RE.match(pos0) and len(pos_before) > 1:
        return f"git checkout {pos0} -- <paths> in live checkout (only '{default_br}' or 'HEAD' is allowed)"
    if not is_commit(eff_dir, pos0):
        if (
            len(pos_before) == 1
            and "--no-guess" not in before_dd
            and pos0 != default_br
            and not is_tracked_or_existing_path(eff_dir, pos0)
            and has_remote_branch(eff_dir, pos0)
        ):
            return f"git checkout '{pos0}' in live checkout (default branch is '{default_br}')"
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
    pos = []
    last_ff = None
    i = 0
    while i < len(rest):
        w = rest[i]
        if w == "--":
            pos.extend(rest[i + 1 :])
            break
        if w in ("--ff", "--no-ff", "--ff-only"):
            last_ff = w
            i += 1
            continue
        if w.startswith("--"):
            name, eq, val = w.partition("=")
            if name == "--rebase":
                if not eq or val != "false":
                    return "git pull with --rebase in live checkout"
                i += 1
                continue
            if name in PULL_VALUE_OPTS and not eq:
                i += 2
            else:
                i += 1
            continue
        if w.startswith("-") and w != "-":
            shorts = w[1:]
            for idx, ch in enumerate(shorts):
                if ch == "r":
                    return "git pull with --rebase in live checkout"
                if f"-{ch}" in PULL_VALUE_OPTS:
                    if idx == len(shorts) - 1:
                        i += 1
                    break
            i += 1
            continue
        pos.append(w)
        i += 1
    if last_ff != "--ff-only":
        return "git pull without --ff-only in live checkout"
    if not pos:
        return None
    if pos[0] != "origin":
        return f"git pull --ff-only from '{pos[0]}' in live checkout (only 'origin' is allowed)"
    if len(pos) == 1 or (len(pos) == 2 and pos[1] == default_br):
        return None
    return f"git pull --ff-only with refspec '{' '.join(pos[1:])}' in live checkout (only '{default_br}' is allowed)"


def judge_update_ref(rest):
    if "-h" in rest or "--help" in rest:
        return None
    pos = []
    i = 0
    while i < len(rest):
        w = rest[i]
        if w == "--":
            pos.extend(rest[i + 1 :])
            break
        if w == "--stdin":
            return "git update-ref --stdin in live checkout"
        if w.startswith("--"):
            i += 1
            continue
        if w.startswith("-") and w != "-":
            shorts = w[1:]
            for idx, ch in enumerate(shorts):
                if ch == "m":
                    if idx == len(shorts) - 1:
                        i += 1
                    break
            i += 1
            continue
        pos.append(w)
        i += 1
    if pos and (pos[0] == "HEAD" or pos[0].startswith("refs/heads/")):
        return f"git update-ref {pos[0]} in live checkout"
    return None


def judge_symbolic_ref(rest):
    if "-h" in rest or "--help" in rest:
        return None
    pos = []
    delete = False
    i = 0
    while i < len(rest):
        w = rest[i]
        if w == "--":
            pos.extend(rest[i + 1 :])
            break
        if w.startswith("--"):
            if w == "--delete":
                delete = True
            i += 1
            continue
        if w.startswith("-") and w != "-":
            shorts = w[1:]
            for idx, ch in enumerate(shorts):
                if ch == "d":
                    delete = True
                if ch == "m":
                    if idx == len(shorts) - 1:
                        i += 1
                    break
            i += 1
            continue
        pos.append(w)
        i += 1
    if pos and pos[0] == "HEAD" and (delete or len(pos) >= 2):
        return "git symbolic-ref HEAD in live checkout"
    return None


def judge_clean(rest):
    if "-h" in rest or "--help" in rest:
        return None
    before_dd = rest[: rest.index("--")] if "--" in rest else rest
    i = 0
    while i < len(before_dd):
        w = before_dd[i]
        if w == "--dry-run":
            return None
        if w.startswith("--"):
            name, eq, _ = w.partition("=")
            if name == "--exclude" and not eq:
                i += 2
            else:
                i += 1
            continue
        if w.startswith("-") and w != "-":
            shorts = w[1:]
            for idx, ch in enumerate(shorts):
                if ch == "n":
                    return None
                if ch == "e":
                    if idx == len(shorts) - 1:
                        i += 1
                    break
            i += 1
            continue
        i += 1
    return "git clean in live checkout"


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
    if subcmd == "update-ref":
        return judge_update_ref(rest)
    if subcmd == "symbolic-ref":
        return judge_symbolic_ref(rest)
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
    if subcmd == "clean":
        return judge_clean(rest)
    if subcmd == "sparse-checkout":
        if "-h" in rest or "--help" in rest:
            return None
        before_dd = rest[: rest.index("--")] if "--" in rest else rest
        first_pos = next((w for w in before_dd if not w.startswith("-")), None)
        if first_pos in SPARSE_CHECKOUT_BLOCK_SUBCMDS:
            return f"git sparse-checkout {first_pos} in live checkout"
        return None
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
        if name not in LIVE_TRACKED_ENV:
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


def apply_runner_chdirs(prefix_words, cur_dir, uncertain, state, ctx):
    """Apply `env -C <dir>` / `env --chdir=<dir>` steps in the runner prefix;
    any other runner chdir (`sudo -D`) marks the directory uncertain."""
    i = 0
    while i < len(prefix_words):
        w = prefix_words[i]
        if w in ("-C", "--chdir"):
            step = prefix_words[i + 1] if i + 1 < len(prefix_words) else None
            cur_dir, uncertain = apply_dir_step(step, cur_dir, uncertain, state, ctx)
            i += 2
            continue
        if w.startswith("--chdir="):
            cur_dir, uncertain = apply_dir_step(w[len("--chdir=") :], cur_dir, uncertain, state, ctx)
            i += 1
            continue
        if w.startswith("-C") and len(w) > 2 and not w.startswith("--"):
            cur_dir, uncertain = apply_dir_step(w[2:], cur_dir, uncertain, state, ctx)
            i += 1
            continue
        if w == "-D" or w.startswith("--chdir"):
            return payload_cwd, True
        i += 1
    return cur_dir, uncertain


def record_worktree_add(rest, eff_dir, state, ctx):
    """When `rest` is `add [options] <path> [<commit-ish>]`, resolve `<path>`
    against `eff_dir` and record it in `ctx.new_worktrees`."""
    if "-h" in rest or "--help" in rest:
        return
    add_idx = None
    for idx, w in enumerate(rest):
        if w == "--":
            break
        if w.startswith("-") and w != "-":
            continue
        if w == "add":
            add_idx = idx
        break
    if add_idx is None:
        return
    wt_raw = None
    j = add_idx + 1
    while j < len(rest):
        w = rest[j]
        if w == "--":
            if j + 1 < len(rest):
                wt_raw = rest[j + 1]
            break
        if w.startswith("--"):
            name, eq, _ = w.partition("=")
            if name == "--reason" and not eq:
                j += 2
            else:
                j += 1
            continue
        if w.startswith("-") and w != "-":
            shorts = w[1:]
            for s_idx, ch in enumerate(shorts):
                if ch in ("b", "B"):
                    if s_idx == len(shorts) - 1:
                        j += 1
                    break
            j += 1
            continue
        wt_raw = w
        break
    if not wt_raw:
        return
    wt_exp = expand_home(expand_vars(wt_raw, state))
    if not wt_exp or unresolvable_cd_target(wt_exp):
        return
    if wt_exp.startswith("/"):
        wt_abs = posixpath.normpath(wt_exp)
    elif eff_dir and eff_dir.startswith("/"):
        wt_abs = posixpath.normpath(posixpath.join(eff_dir, wt_exp))
    else:
        return
    for cand in (wt_abs, posixpath.normpath(os.path.realpath(wt_abs))):
        if not any(r == cand or r.startswith(cand.rstrip("/") + "/") for r in live_roots):
            ctx.new_worktrees.add(cand)


class Context:
    def __init__(self):
        self.blocking = []
        self.visited = set()
        self.subst_states = set()
        self.judged = set()
        self.leftovers = []
        self.leftover_mode = False
        self.new_worktrees = set()


def judge_git(argv, unwrapped, info, state, ctx):
    prefix_len = max(0, len(argv) - len(unwrapped))
    prefix = argv[:prefix_len]
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
        if m and m.group(1) in LIVE_TRACKED_ENV:
            env[m.group(1)] = m.group(2)
        p_idx += 1

    if env.get("SYG_ALLOW_LIVE_CHECKOUT") == "1":
        return

    cur_dir = state.cwd
    uncertain = state.unknown or not is_known_dir(cur_dir, ctx)
    if uncertain:
        cur_dir = payload_cwd
        uncertain = not is_known_dir(cur_dir, ctx)

    if info.get("chdir"):
        cur_dir, uncertain = apply_runner_chdirs(prefix, cur_dir, uncertain, state, ctx)

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
            cur_dir, uncertain = apply_dir_step(step, cur_dir, uncertain, state, ctx)
            i += 2
            continue
        if w.startswith("-C") and len(w) > 2:
            cur_dir, uncertain = apply_dir_step(w[2:], cur_dir, uncertain, state, ctx)
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

    start_dir = payload_cwd if (uncertain or not is_known_dir(cur_dir, ctx)) else cur_dir

    if has_git_dir:
        if gd_unexpanded or (not gd_expanded.startswith("/") and (uncertain or not is_known_dir(cur_dir, ctx))):
            repo_dir = payload_cwd
            repo_live_root = None if is_in_new_worktree(repo_dir, ctx) else worktree_live_root(repo_dir)
        else:
            gd_path = gd_expanded if gd_expanded.startswith("/") else posixpath.join(cur_dir, gd_expanded)
            gd_real = os.path.realpath(gd_path)
            repo_live_root = None
            for r in sorted(live_roots):
                if gd_real == os.path.realpath(posixpath.join(r, ".git")):
                    repo_live_root = r
                    break
    else:
        repo_live_root = None if is_in_new_worktree(start_dir, ctx) else worktree_live_root(start_dir)

    wt_live_root = None
    wt_eff_dir = start_dir
    if has_work_tree:
        wt_dir, wt_uncertain = apply_dir_step(work_tree_val, cur_dir, uncertain, state, ctx)
        if gd_unexpanded:
            wt_uncertain = True
        wt_eff_dir = payload_cwd if (wt_uncertain or not is_known_dir(wt_dir, ctx)) else wt_dir
        if not is_in_new_worktree(wt_eff_dir, ctx):
            wt_live_root = worktree_live_root(wt_eff_dir)

    if subcmd == "worktree":
        base_dir = wt_eff_dir if has_work_tree else (payload_cwd if gd_unexpanded else start_dir)
        record_worktree_add(rest, base_dir, state, ctx)

    live_root = repo_live_root or wt_live_root
    if not live_root:
        return

    # Pathspecs resolve against the directory git starts in; keep it when the
    # repository was discovered from there and no other work tree is named.
    eff_dir = start_dir if (repo_live_root and not has_git_dir and not has_work_tree) else live_root
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
    key = (
        tuple(argv),
        state.cwd,
        state.unknown,
        tuple(sorted(state.env.items())),
        frozenset(ctx.new_worktrees),
    )
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
