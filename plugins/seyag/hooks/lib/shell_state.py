"""The shell-state machine the submission guards walk a command line with.

publish-gate.sh and upstream-submission-guard.sh both judge a gh command by
the directory and exported variables it runs under, which earlier commands in
the same text can change (cd/pushd/popd, export). This module walks the text
in execution order, tracks the directory itself (with OLDPWD and the pushd
stack) and carries the exported values; each guard passes its own
`run_command(argv, state, ctx)`, which updates those values (export/unset
handling stays in the guards) and owns every verdict. Pinned directly by
tests/shell-state.probe.sh and end-to-end by both guards' probes.
"""

import os
import posixpath
import re
import shlex

# The underscored names are the splitter's own pieces behind simple_commands
# (see pipelines_of): used so wrapper and substitution commands can be placed
# in execution order, which simple_commands' appended output loses.
from shell_quotes import (
    MAX_WRAPPER_DEPTH,
    _pipelines,
    _reads_script_from_stdin,
    _tokens,
    strip_heredoc_bodies,
    substitution_spans,
    wrapped_command_strings,
)

GLOB_CHARS = set("*?[")

# Exported variables that decide a gh command's target, tracked through the
# command text (export / declare -x / typeset -x set, unset / export -n clear)
# and read from a gh command's own prefix.
TRACKED_ENV = ("GH_REPO", "GIT_DIR", "GIT_WORK_TREE")
CD_OPTION_RE = re.compile(r"^-[LPe@]+$")


def unresolvable_cd_target(word):
    return "$" in word or "`" in word or any(c in GLOB_CHARS for c in word)


def expand_home(word):
    home = os.environ.get("HOME", "")
    if word == "~":
        return home
    if word.startswith("~/"):
        return home + word[1:]
    return word


def resolve_cd(base_cwd, word):
    word = expand_home(word)
    if word.startswith("/"):
        return posixpath.normpath(word)
    return posixpath.normpath(posixpath.join(base_cwd, word))


class State:
    """What the shell carries from one command to the next that decides a gh
    command's target: the directory (with OLDPWD and the pushd stack) and the
    exported TRACKED_ENV values. `payload_cwd` is where the text starts, the
    directory an unknown move resets to."""

    def __init__(self, cwd, env=None, payload_cwd=None):
        self.cwd = cwd
        self.oldpwd = None
        self.stack = []
        self.env = dict(env or {})
        self.payload_cwd = payload_cwd

    def copy(self):
        s = State(self.cwd, self.env, self.payload_cwd)
        s.oldpwd = self.oldpwd
        s.stack = list(self.stack)
        return s

    def snapshot(self):
        return (self.cwd, tuple(sorted(self.env.items())))


def chdir(state, word):
    """Move to a literal directory word; None or an unresolvable word resets
    to the payload cwd (not a directory the hook can reason about)."""
    before = state.cwd
    if word is None or unresolvable_cd_target(word):
        state.cwd = state.payload_cwd
    else:
        state.cwd = resolve_cd(state.cwd, word)
    state.oldpwd = before


def do_cd(state, args):
    while args and args[0].startswith("-") and args[0] != "-":
        if args[0] == "--":
            args = args[1:]
            break
        if not CD_OPTION_RE.match(args[0]):
            return  # an invalid option: bash errors out, the directory stays
        args = args[1:]
    if len(args) > 1:
        return  # too many arguments: bash errors out, the directory stays
    if not args:
        chdir(state, os.environ.get("HOME") or None)  # bare cd: $HOME
    elif args[0] == "-":
        chdir(state, state.oldpwd)  # cd -: OLDPWD (unknown at start → reset)
    else:
        chdir(state, args[0])


def do_pushd(state, args):
    if args[:1] == ["--"]:
        args = args[1:]
    before = state.cwd
    if not args:
        # Swap with the top of the stack; a stack this text didn't build is
        # unknown, so an empty one resets.
        if not state.stack:
            chdir(state, None)
            return
        chdir(state, state.stack.pop(0))
        state.stack.insert(0, before)
        return
    if len(args) > 1 or (args[0].startswith(("-", "+")) and args[0] != "-"):
        chdir(state, None)  # -n, +N/-N rotations: not modelled, reset
        return
    chdir(state, state.oldpwd if args[0] == "-" else args[0])
    state.stack.insert(0, before)


def do_popd(state, args):
    if args[:1] == ["--"]:
        args = args[1:]
    if args or not state.stack:
        chdir(state, None)  # options, or a stack this text didn't build: reset
        return
    chdir(state, state.stack.pop(0))


def pipelines_of(text):
    """The top-level pipelines of `text`, exactly as `simple_commands` splits
    them (heredoc bodies dropped unless a shell reads its script from stdin),
    WITHOUT its trailing wrapper expansion — the walk below places each
    wrapper's commands right after the pipeline that runs them.
    Also returns the text the walk scans for substitutions: the same
    body-free text, since a heredoc body is data (the lib's convention; an
    unquoted-delimiter body's `$(…)` is an accepted under-arm)."""
    body_free = strip_heredoc_bodies(text)
    pipelines = _pipelines(_tokens(body_free))
    if body_free != text and any(
        _reads_script_from_stdin(c) for p in pipelines for c in p
    ):
        return _pipelines(_tokens(text)), text
    return pipelines, body_free


def walk(text, depth, state, ctx, run_command):
    """Walk `text`'s commands in EXECUTION order, updating `state`. A command
    substitution runs just before the command whose word holds it; a
    wrapper's string (`bash -c`, `eval`, …) runs as the pipeline does. Both
    run in a child shell, so each walks a COPY of the state."""
    pipelines, scan_text = pipelines_of(text)
    pending = list(substitution_spans(scan_text)) if depth < MAX_WRAPPER_DEPTH else []
    for pipeline in pipelines:
        for argv in pipeline:
            if pending:
                joined = " ".join(argv)
                for span in list(pending):
                    forms = (f"$({span})", f"`{span}`")
                    if any(f in w for f in forms for w in argv + [joined]):
                        pending.remove(span)
                        walk(span, depth + 1, state.copy(), ctx, run_command)
            ctx.visited.add(state.snapshot())
            run_command(argv, state, ctx)
            ctx.visited.add(state.snapshot())
        if depth < MAX_WRAPPER_DEPTH:
            joined = " | ".join(shlex.join(a) for a in pipeline)
            for inner in wrapped_command_strings(joined):
                walk(inner, depth + 1, state.copy(), ctx, run_command)
    ctx.leftovers.extend((span, depth + 1) for span in pending)
