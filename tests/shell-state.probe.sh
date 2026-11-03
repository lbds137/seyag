#!/bin/bash
# Direct cases for plugins/seyag/hooks/lib/shell_state.py, the shell-state
# machine publish-gate.sh and upstream-submission-guard.sh walk a command line
# with. Both guards' probes pin it end to end; this one pins it directly, so a
# lib change cannot silently move its semantics. Pure machine assertions: no
# gh or network calls; git runs only on the scratch repo for the
# --show-toplevel cases.
# Usage: tests/shell-state.probe.sh   (from anywhere)
# SHELL_STATE_LIB_DIR overrides the library directory (positive-control use).

set -uo pipefail
# Keep the import from dropping a __pycache__ beside the library.
export PYTHONDONTWRITEBYTECODE=1
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LIB=${SHELL_STATE_LIB_DIR:-$REPO/plugins/seyag/hooks/lib}
TMP=$(mktemp -d) || { echo "FAIL [setup]: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export GIT_CEILING_DIRECTORIES="$TMP"

LIB="$LIB" BASE="$TMP/work" HOME="$TMP/home" python3 - <<'PYEOF'
import os
import subprocess
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
REPO_ROOT = BASE + "/repo"
REPO_SUB = REPO_ROOT + "/sub"
os.makedirs(BASE + "/a", exist_ok=True)
os.makedirs(START + "/a", exist_ok=True)
os.makedirs(REPO_SUB, exist_ok=True)
subprocess.run(["git", "init", "-q", REPO_ROOT], check=True)
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
check("cd to a backtick word resets to payload_cwd", cwd_of_last("cd `f`; true", started()), BASE)
check("cd to a glob word resets to payload_cwd", cwd_of_last("cd a*; true", started()), BASE)
check("cd ~/sub expands to $HOME/sub (no reset)", cwd_of_last("cd ~/sub; true", started()), HOME + "/sub")
check("cd ~ expands to $HOME", cwd_of_last("cd ~; true", started()), HOME)
check("cd ~other with no literal ~other dir resets to payload_cwd", cwd_of_last("cd ~other; true", started()), BASE)
_, _, st = run("cd ~+", started())
check("cd ~+ stays at the current dir, oldpwd set", (st.cwd, st.oldpwd), (START, START))
check("cd ~- after a prior cd returns to the oldpwd", cwd_of_last("cd a; cd ~-; true", started()), START)
# bash: with OLDPWD unset `~-` stays literal and cd fails, changing nothing.
_, _, st = run("cd ~-", started())
check("cd ~- with no prior cd is a known failure: nothing moves", (st.cwd, st.oldpwd), (START, None))
# `cd .` moves nothing but sets OLDPWD (bash does on every successful cd).
check("cd . updates the oldpwd: cd a; cd .; cd - stays in a", cwd_of_last("cd a; cd .; cd -; true", started()), START + "/a")
# bash leaves a ~user word for no such user literal, and cd enters a literal
# directory of that name in the cwd (a crafted repo).
os.makedirs(START + "/~other")
check("cd ~other with a literal ~other dir moves there", cwd_of_last("cd ~other; true", started()), START + "/~other")
del os.environ["HOME"]  # these cases only: bare cd with HOME unset
try:
    # bash: "cd: HOME not set"; the cd fails and touches neither PWD nor OLDPWD.
    _, _, st = run("cd", started())
    check("bare cd with HOME unset is a known failure: nothing moves", (st.cwd, st.oldpwd), (START, None))
    # The failed bare cd leaves OLDPWD at the start, so `cd -` goes back there.
    check("cd a; bare cd with HOME unset; cd - returns to the start", cwd_of_last("cd a; cd; cd -; true", started()), START)
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
# bash: with OLDPWD unset `pushd ~-` fails like `cd ~-` and pushes nothing.
_, _, st = run("pushd ~-; true", started())
check("pushd ~- with no prior cd is a known failure: no move, no stack entry", (st.cwd, st.stack), (START, []))
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
    "unresolvable_cd_target passes literal and ~-words (chdir judges ~-words)",
    [unresolvable_cd_target(w) for w in ("a/b", "../c", "~", "~/d", "~other", "~+", "~-")],
    [False] * 7,
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
_, _, st = run('x="$(cd /a && pwd)"')
check('x="$(cd /a && pwd)" does not move the tracked directory', st.cwd, BASE)
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
    "at MAX_WRAPPER_DEPTH a substitution is left over (not walked); wrappers are not walked",
    ([n for n, _, _ in recs], ctx.leftovers),
    (["echo", "bash"], [("cd a", MAX_WRAPPER_DEPTH + 1)]),
)
_, ctx, _ = run("cd a; true")
check(
    "walk records each state it passes through in ctx.visited",
    sorted(ctx.visited),
    [(BASE, ()), (BASE + "/a", ())],
)


def cwds_of(target, text, state=None):
    recs, _, _ = run(text, state)
    return [cwd for name, cwd, _ in recs if name == target]


# --- multi-world walk (and-or, pipelines, compounds, vars, unknown) -------------
check("cd a && true with a existing: one world, a", cwds_of("true", "cd a && true"), [BASE + "/a"])
check(
    "cd missing && true; x: x runs at both, moved last",
    cwds_of("x", "cd missing && true; x"),
    [BASE, BASE + "/missing"],
)
check("false && cd a; x: both", cwds_of("x", "false && cd a; x"), [BASE, BASE + "/a"])
check("false || cd a; x: both", cwds_of("x", "false || cd a; x"), [BASE, BASE + "/a"])
check(
    "cd a || x; y: x at start (throwaway), y at a only",
    (cwds_of("x", "cd a || x; y"), cwds_of("y", "cd a || x; y")),
    ([BASE], [BASE + "/a"]),
)
check("cd a || exit 1; y: y at a only", cwds_of("y", "cd a || exit 1; y"), [BASE + "/a"])
check(
    "cd missing || exit 1; y: y at missing only",
    cwds_of("y", "cd missing || exit 1; y"),
    [BASE + "/missing"],
)
check("cd a & x: both", cwds_of("x", "cd a & x"), [BASE, BASE + "/a"])
check("cd a | x: both", cwds_of("x", "cd a | x"), [BASE, BASE + "/a"])
check("(cd a); x: both", cwds_of("x", "(cd a); x"), [BASE, BASE + "/a"])
check("(cd a && x): x at a only", cwds_of("x", "(cd a && x)"), [BASE + "/a"])
check("{ cd a; }; x: a only", cwds_of("x", "{ cd a; }; x"), [BASE + "/a"])
check("{ cd a; } & x: both", cwds_of("x", "{ cd a; } & x"), [BASE, BASE + "/a"])
check("{ cd a; } | x: both", cwds_of("x", "{ cd a; } | x"), [BASE, BASE + "/a"])
check(
    "if false; then cd a; fi; x: both",
    cwds_of("x", "if false; then cd a; fi; x"),
    [BASE, BASE + "/a"],
)
check("if cd a; then x; fi: x at a only", cwds_of("x", "if cd a; then x; fi"), [BASE + "/a"])
check(
    "if t; then y; else cd a; x; fi: x at a and start",
    cwds_of("x", "if t; then y; else cd a; x; fi"),
    [BASE + "/a", BASE],
)
check(
    "for d in a b; do cd a; done; x: both",
    cwds_of("x", "for d in a b; do cd a; done; x"),
    [BASE, BASE + "/a"],
)
check(
    "case k in k) cd a;; esac; x: both",
    cwds_of("x", "case k in k) cd a;; esac; x"),
    [BASE, BASE + "/a"],
)
check(
    "case k in a) cd a;; b) x;; esac: both at clause b",
    cwds_of("x", "case k in a) cd a;; b) x;; esac"),
    [BASE, BASE + "/a"],
)
check(
    "case k in k) cd a; esac; x: both without ;;",
    cwds_of("x", "case k in k) cd a; esac; x"),
    [BASE, BASE + "/a"],
)
check(
    "while f; do cd a; done; x: both",
    cwds_of("x", "while f; do cd a; done; x"),
    [BASE, BASE + "/a"],
)
check("cd a && if: x at a only", cwds_of("x", "cd a && if true; then echo; fi; x"), [BASE + "/a"])
check("cd a && for: x at a only", cwds_of("x", "cd a && for i in 1; do echo; done; x"), [BASE + "/a"])
check("cd a && case: x at a only", cwds_of("x", "cd a && case x in x) echo;; esac; x"), [BASE + "/a"])
check("cd a && while: x at a only", cwds_of("x", "cd a && while false; do :; done; x"), [BASE + "/a"])
check("cd a && { ...; } | cat: x at a only", cwds_of("x", "cd a && { echo; } | cat; x"), [BASE + "/a"])
check(
    "cd missing && if true; then echo; fi; x: both",
    cwds_of("x", "cd missing && if true; then echo; fi; x"),
    [BASE, BASE + "/missing"],
)

os.environ["D"] = "a"
try:
    check("cd $D with D in the environment: followed", cwd_of_last("cd $D; true", started()), START + "/a")
    _, _, st = run("D=$(f); cd $D", started())
    check(
        "D in the environment and D=$(f); cd $D: still reset (mask)",
        (st.cwd, getattr(st, "unknown", None)),
        (BASE, True),
    )
    _, _, st = run("unset D; cd $D", started())
    check("unset D; cd $D: reset", (st.cwd, getattr(st, "unknown", None)), (BASE, True))
    _, _, st = run("cd ${D:-a}", started())
    check("cd ${D:-a}: reset", (st.cwd, getattr(st, "unknown", None)), (BASE, True))
    _, _, st = run('read D; cd "$D"', started())
    check('D in the environment and read D; cd "$D": reset, unknown', (st.cwd, st.unknown), (BASE, True))
    _, _, st = run('D+=x; cd "$D"', started())
    check('D in the environment and D+=x; cd "$D": reset, unknown', (st.cwd, st.unknown), (BASE, True))
    check(
        "mapfile/readarray/printf -v/getopts mask D in the environment",
        [
            (run(f'{cmd}; cd "$D"', started())[2].cwd, run(f'{cmd}; cd "$D"', started())[2].unknown)
            for cmd in ("mapfile -t D", "readarray D", "printf -v D %s b", "getopts a D")
        ],
        [(BASE, True)] * 4,
    )
finally:
    del os.environ["D"]

os.environ["D"] = "env_d"
try:
    check(
        'D in the environment and export D=a; cd "$D"; x: moves to a',
        cwds_of("x", 'export D=a; cd "$D"; x', started()),
        [START + "/a"],
    )
finally:
    del os.environ["D"]

check("D=a; cd $D; x: a", cwds_of("x", "D=a; cd $D; x"), [BASE + "/a"])
check('export D=a; cd "$D"; x: a', cwds_of("x", 'export D=a; cd "$D"; x'), [BASE + "/a"])
check(
    "declare/typeset/local/readonly/export -n/+x D=a; cd $D; x: a",
    [
        cwds_of("x", f'{cmd} D=a; cd "$D"; x')
        for cmd in ("declare", "typeset", "local", "readonly", "export -n", "declare +x")
    ],
    [[BASE + "/a"]] * 6,
)
_, _, st = run("D=$(f); cd $D", started())
check("D=$(f); cd $D: reset, unknown set", (st.cwd, getattr(st, "unknown", None)), (BASE, True))
check("cd $PWD/a: followed", cwd_of_last("cd $PWD/a; true", started()), START + "/a")
check('cd a; cd "$OLDPWD"; x: start', cwds_of("x", 'cd a; cd "$OLDPWD"; x', started()), [START])
check("cd /a: followed", cwd_of_last("cd /a; true", started()), "/a")
_, _, st = run('cd "$(pwd)"', started())
check('cd "$(pwd)": stays at current dir, not unknown or uncertain', (st.cwd, st.unknown, st.uncertain), (START, False, False))
_, _, st = run("cd `pwd`", started())
check("cd `pwd`: stays at current dir, not unknown or uncertain", (st.cwd, st.unknown, st.uncertain), (START, False, False))
for spelling in (
    'cd "$(git rev-parse --show-toplevel)"',
    "cd $(git rev-parse --show-toplevel)",
    'cd "`git rev-parse --show-toplevel`"',
    "cd `git rev-parse --show-toplevel`",
):
    _, _, st = run(spelling, State(REPO_SUB, payload_cwd=BASE))
    check(
        f"{spelling}: from a repo subdirectory moves to the repo root",
        (st.cwd, st.oldpwd, st.unknown, st.uncertain),
        (REPO_ROOT, REPO_SUB, False, False),
    )
_, _, st = run('cd "$(git rev-parse --show-toplevel)"', started())
check(
    'cd "$(git rev-parse --show-toplevel)": outside any repo is unknown',
    (st.cwd, st.oldpwd, st.unknown, st.uncertain),
    (BASE, START, True, True),
)
_, _, st = run("cd `git rev-parse --show-toplevel`", started())
check(
    "cd `git rev-parse --show-toplevel`: outside any repo is unknown",
    (st.cwd, st.oldpwd, st.unknown, st.uncertain),
    (BASE, START, True, True),
)
check(
    "cd miss; x with miss never created: both worlds kept",
    cwds_of("x", "cd miss; x"),
    [BASE, BASE + "/miss"],
)
check(
    "pushd miss; x with miss never created: both worlds kept",
    cwds_of("x", "pushd miss; x"),
    [BASE, BASE + "/miss"],
)
_, _, st = run('cd "$(pwd)/a"', started())
check('cd "$(pwd)/a": joins current dir with the rest', (st.cwd, st.unknown, st.uncertain), (START + "/a", False, False))
_, _, st = run("cd `pwd`/a", started())
check("cd `pwd`/a: joins current dir with the rest", (st.cwd, st.unknown, st.uncertain), (START + "/a", False, False))
_, _, st = run('cd "$(git rev-parse --show-toplevel)/a"', started())
check('cd "$(git rev-parse --show-toplevel)/a": suffix stays unknown', (st.cwd, st.unknown, st.uncertain), (BASE, True, True))
_, _, st = run("cd $NOPE; cd /abs", started())
check("cd $NOPE; cd /abs: unknown clear", (st.cwd, getattr(st, "unknown", None)), ("/abs", False))
_, _, st = run("cd $NOPE; cd sub", started())
check("cd $NOPE; cd sub: unknown set", (st.cwd, getattr(st, "unknown", None)), (BASE + "/sub", True))
worlds_7 = cwds_of(
    "x",
    "false && cd d1; false && cd d2; false && cd d3; false && cd d4; "
    "false && cd d5; false && cd d6; false && cd d7; x",
)
check("7 relative conditional cds: at most 64 worlds, no exception", len(worlds_7), 64)
recs_8, _, st_8 = run(
    "false && cd d1; false && cd d2; false && cd d3; false && cd d4; "
    "false && cd d5; false && cd d6; false && cd d7; false && cd d8; x"
)
x_cwds_8 = [cwd for name, cwd, _ in recs_8 if name == "x"]
deepest_8 = BASE + "/d1/d2/d3/d4/d5/d6/d7/d8"
check(
    "8 conditional relative cds: at most 64 worlds, last record and final state.cwd at deepest path",
    (len(x_cwds_8), recs_8[-1][1], st_8.cwd),
    (64, deepest_8, deepest_8),
)

# --- apply_dir_builtin: only builtin runners reach the dir builtins ------------
from shell_state import apply_dir_builtin

for runner in ("sudo", "env", "nohup"):
    st = State(BASE, payload_cwd=BASE)
    got = (apply_dir_builtin([runner, "cd", BASE + "/a"], st), st.cwd)
    check(f"apply_dir_builtin: {runner} cd leaves the dir (not a builtin runner)", got, (False, BASE))
st = State(BASE, payload_cwd=BASE)
check(
    "apply_dir_builtin: builtin cd moves the dir",
    (apply_dir_builtin(["builtin", "cd", BASE + "/a"], st), st.cwd),
    (True, BASE + "/a"),
)
st = State(BASE, payload_cwd=BASE)
check(
    "apply_dir_builtin: command pushd moves the dir",
    (apply_dir_builtin(["command", "pushd", BASE + "/a"], st), st.cwd),
    (True, BASE + "/a"),
)
check(
    "apply_dir_builtin: command popd moves back",
    (apply_dir_builtin(["command", "popd"], st), st.cwd),
    (True, BASE),
)
check(
    "apply_dir_builtin: a non-directory command is not applied",
    (apply_dir_builtin(["export", "X=1"], st), st.cwd),
    (False, BASE),
)

print("---")
if failures:
    print(f"{failures} shell-state case(s) failed")
    sys.exit(1)
print("all shell-state cases passed")
PYEOF
exit $?
