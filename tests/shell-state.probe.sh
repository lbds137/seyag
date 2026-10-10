#!/bin/bash
# Direct cases for plugins/seyag/hooks/lib/shell_state.py, the shell-state
# machine publish-gate.sh and upstream-submission-guard.sh walk a command line
# with. Both guards' probes pin it end to end; this one pins it directly, so a
# lib change cannot silently move its semantics. Pure machine assertions: no
# gh, git or network calls.
# Usage: tests/shell-state.probe.sh   (from anywhere)
# SHELL_STATE_LIB_DIR overrides the library directory (positive-control use).

set -uo pipefail
# Keep the import from dropping a __pycache__ beside the library.
export PYTHONDONTWRITEBYTECODE=1
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LIB=${SHELL_STATE_LIB_DIR:-$REPO/plugins/seyag/hooks/lib}
TMP=$(mktemp -d) || { echo "FAIL [setup]: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

LIB="$LIB" BASE="$TMP/work" HOME="$TMP/home" python3 - <<'PYEOF'
import os
import sys

sys.path.insert(0, os.environ["LIB"])
from shell_state import (
    MAX_WRAPPER_DEPTH,
    State,
    do_cd,
    do_popd,
    do_pushd,
    pipelines_of,
    resolve_cd,
    unresolvable_cd_target,
    walk,
)

BASE = os.environ["BASE"]
HOME = os.environ["HOME"]
START = BASE + "/start"  # a start cwd that differs from payload_cwd, so a reset shows
failures = 0


class Ctx:
    def __init__(self):
        self.visited = set()
        self.leftovers = []


def run(text, state=None, depth=0):
    """Walk `text`; return (per-command (name, cwd, env) records, ctx, state)."""
    state = state or State(BASE, payload_cwd=BASE)
    records = []

    def run_command(argv, st, ctx):
        records.append((argv[0],) + (st.cwd, tuple(sorted(st.env.items()))))
        verb = {"cd": do_cd, "pushd": do_pushd, "popd": do_popd}.get(argv[0])
        if verb:
            verb(st, argv[1:])

    ctx = Ctx()
    walk(text, depth, state, ctx, run_command)
    return records, ctx, state


def cwd_of_last(text, state=None):
    return run(text, state)[0][-1][1]


def check(name, got, want):
    global failures
    if got == want:
        print(f"PASS  {name}")
    else:
        failures += 1
        print(f"FAIL  {name}\n      got:  {got!r}\n      want: {want!r}")


def started():
    return State(START, payload_cwd=BASE)


# --- cd ------------------------------------------------------------------------
check("bare cd goes to $HOME", cwd_of_last("cd; true"), HOME)
check("cd - after a prior cd returns to the oldpwd", cwd_of_last("cd a; cd -; true"), BASE)
check("cd - after two cds returns to the first", cwd_of_last("cd a; cd b; cd -; true"), BASE + "/a")
check("cd - with no prior cd resets to payload_cwd", cwd_of_last("cd -; true", started()), BASE)
check("invalid cd option: the directory stays", cwd_of_last("cd a; cd -z b; true"), BASE + "/a")
check("too many cd arguments: the directory stays", cwd_of_last("cd a; cd b c; true"), BASE + "/a")
check("cd -- <dir> is followed", cwd_of_last("cd -- a; true"), BASE + "/a")
check("cd -P <dir> is followed", cwd_of_last("cd -P a; true"), BASE + "/a")
check("cd to a $-word resets to payload_cwd", cwd_of_last("cd $D; true", started()), BASE)
check("cd to a backtick word resets to payload_cwd", cwd_of_last("cd `pwd`; true", started()), BASE)
check("cd to a glob word resets to payload_cwd", cwd_of_last("cd a*; true", started()), BASE)
check("cd ~/sub expands to $HOME/sub (no reset)", cwd_of_last("cd ~/sub; true", started()), HOME + "/sub")
check("cd ~ expands to $HOME", cwd_of_last("cd ~; true", started()), HOME)
del os.environ["HOME"]  # this one case only: bare cd with HOME unset
try:
    check("bare cd with HOME unset resets to payload_cwd", cwd_of_last("cd; true", started()), BASE)
finally:
    os.environ["HOME"] = HOME

# --- pushd / popd ----------------------------------------------------------------
_, _, st = run("pushd a")
check("pushd <dir> moves and stacks the old dir", (st.cwd, st.stack), (BASE + "/a", [BASE]))
_, _, st = run("pushd a; pushd")
check("bare pushd swaps with the stack top", (st.cwd, st.stack), (BASE, [BASE + "/a"]))
_, _, st = run("pushd a; popd", started())
check("popd unwinds to the stacked dir", (st.cwd, st.stack), (START, []))
_, _, st = run("pushd a; pushd b; popd -- ", started())
check("popd -- unwinds one level", (st.cwd, st.stack), (START + "/a", [START]))
check("popd on an empty stack resets to payload_cwd", cwd_of_last("popd; true", started()), BASE)
check("bare pushd on an empty stack resets to payload_cwd", cwd_of_last("pushd; true", started()), BASE)
for flagged in ("pushd -n a", "pushd +1", "pushd a b"):
    _, _, st = run(f"pushd b; {flagged}", started())
    check(f"{flagged} resets to payload_cwd, stack unchanged", (st.cwd, st.stack), (BASE, [START]))
_, _, st = run("cd a; pushd -")
check("pushd - moves to the oldpwd and stacks the old dir", (st.cwd, st.stack), (BASE, [BASE + "/a"]))
_, _, st = run("pushd a; popd +1", started())
check("popd +1 resets to payload_cwd, stack unchanged", (st.cwd, st.stack), (BASE, [START]))

# --- State ---------------------------------------------------------------------
s = State("/w/x", {"GH_REPO": "o/r"}, payload_cwd="/w")
s.oldpwd = "/w/old"
s.stack = ["/w/s"]
c = s.copy()
check(
    "State.copy carries cwd/oldpwd/stack/env/payload_cwd",
    (c.cwd, c.oldpwd, c.stack, c.env, c.payload_cwd),
    ("/w/x", "/w/old", ["/w/s"], {"GH_REPO": "o/r"}, "/w"),
)
c.stack.append("/w/t")
c.env["GIT_DIR"] = "g"
check("State.copy is independent of the original", (s.stack, s.env), (["/w/s"], {"GH_REPO": "o/r"}))
s.env["GIT_DIR"] = "/w/.git"
check(
    "State.snapshot is (cwd, sorted env items)",
    s.snapshot(),
    ("/w/x", (("GH_REPO", "o/r"), ("GIT_DIR", "/w/.git"))),
)

# --- resolve_cd / unresolvable_cd_target -------------------------------------------
check("resolve_cd joins and normalizes a relative word", resolve_cd("/w/x", "y/../z"), "/w/x/z")
check("resolve_cd keeps an absolute word", resolve_cd("/w/x", "/abs//p/"), "/abs/p")
check("resolve_cd expands ~/", resolve_cd("/w/x", "~/p"), HOME + "/p")
check(
    "unresolvable_cd_target flags $, backtick and glob characters",
    [unresolvable_cd_target(w) for w in ("$D", "`pwd`", "a*", "a?", "a[b]")],
    [True] * 5,
)
check(
    "unresolvable_cd_target passes literal and ~ words",
    [unresolvable_cd_target(w) for w in ("a/b", "../c", "~", "~/d", "~other")],
    [False] * 5,
)

# --- pipelines_of ----------------------------------------------------------------
check(
    "pipelines_of splits pipelines into argv lists",
    pipelines_of("echo a | cat; true"),
    ([[["echo", "a"], ["cat"]], [["true"]]], "echo a | cat; true"),
)
check(
    "pipelines_of drops a heredoc body from the scan text",
    pipelines_of("cat <<EOF\nbody $(x)\nEOF\ntrue")[1],
    "cat <<EOF\n\ntrue",
)
check(
    "pipelines_of keeps the body when a shell reads its script from stdin",
    pipelines_of("bash <<EOF\ncd a\nEOF")[1],
    "bash <<EOF\ncd a\nEOF",
)

# --- walk order ----------------------------------------------------------------
recs, _, st = run('echo "$(cd a && true)"; true')
check(
    "a $(...) substitution walks before its command, on a state copy",
    [(n, cwd) for n, cwd, _ in recs],
    [("cd", BASE), ("true", BASE + "/a"), ("echo", BASE), ("true", BASE)],
)
check("the substitution's cd does not leak out", st.cwd, BASE)
recs, _, st = run("bash -c 'cd a; true'; true")
check(
    "a bash -c wrapper's commands run right after its pipeline, on a copy",
    [(n, cwd) for n, cwd, _ in recs],
    [("bash", BASE), ("cd", BASE), ("true", BASE + "/a"), ("true", BASE)],
)
recs, ctx, _ = run('echo "$(printf "%s" x)"')
check(
    "a span that survives into no word lands in ctx.leftovers",
    ([n for n, _, _ in recs], ctx.leftovers),
    (["echo"], [('printf "%s" x', 1)]),
)
recs, ctx, _ = run('echo "$(cd a)"', depth=MAX_WRAPPER_DEPTH - 1)
check(
    "below MAX_WRAPPER_DEPTH a substitution is walked",
    ([n for n, _, _ in recs], ctx.leftovers),
    (["cd", "echo"], []),
)
recs, ctx, _ = run('echo "$(cd a)"; bash -c "cd b"', depth=MAX_WRAPPER_DEPTH)
check(
    "at MAX_WRAPPER_DEPTH substitutions and wrappers are not walked (nor left over)",
    ([n for n, _, _ in recs], ctx.leftovers),
    (["echo", "bash"], []),
)
_, ctx, _ = run("cd a; true")
check(
    "walk records each state it passes through in ctx.visited",
    sorted(ctx.visited),
    [(BASE, ()), (BASE + "/a", ())],
)

print("---")
if failures:
    print(f"{failures} shell-state case(s) failed")
    sys.exit(1)
print("all shell-state cases passed")
PYEOF
exit $?
