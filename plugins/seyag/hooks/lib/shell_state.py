"""The shell-state machine the guards walk a command line with.

publish-gate.sh, upstream-submission-guard.sh and lib/outbound.py (for
session-url-gate.sh and private-term-guard.sh) judge commands by the directory
and variables they run under, which earlier commands in the same text can
change (cd/pushd/popd, export, VAR=val). This module walks the text in
execution order across a list of possible states ("worlds", capped at
MAX_WORLDS = 64; past it, the first MAX_WORLDS - 1 and the last are kept),
branching at conditional and uncertain directory moves, background lists,
pipelines and compound commands, and tracks the directory (with OLDPWD, the
pushd stack and unknown moves), shell variables for expansion (`expand_vars`),
and exported values; each caller passes its own `run_command(argv, state, ctx)`.
Known gap: variable assignments and directory moves inside `eval` (walked on a
state copy) and `source`/`.` scripts are not tracked in the outer state. Pinned
directly by tests/shell-state.probe.sh and end-to-end by the guards' probes.
"""

import os
import posixpath
import re
import shlex
import subprocess

# The underscored names are the splitter's own pieces behind simple_commands
# (see pipelines_of): used so wrapper and substitution commands can be placed
# in execution order, which simple_commands' appended output loses.
from shell_quotes import (
    MAX_WRAPPER_DEPTH,
    _Op,
    _PIPE_OPS,
    _pipelines,
    _reads_script_from_stdin,
    _tokens,
    strip_heredoc_bodies,
    strip_redirections,
    substitution_spans,
    unwrap_runners,
    wrapped_command_strings,
)

GLOB_CHARS = set("*?[")
MAX_WORLDS = 64

# Exported variables that decide a gh command's target, tracked through the
# command text (export / declare -x / typeset -x set, unset / export -n clear)
# and read from a gh command's own prefix.
TRACKED_ENV = ("GH_REPO", "GIT_DIR", "GIT_WORK_TREE")
CD_OPTION_RE = re.compile(r"^-[LPe@]+$")
_VAR_REF_RE = re.compile(r"\$(?:([A-Za-z_][A-Za-z0-9_]*)|\{([A-Za-z_][A-Za-z0-9_]*)\})")
_ASSIGN_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)(\+?)=(.*)$", re.S)
_IDENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_BUILTIN_RUNNERS = {"builtin", "command"}
_PWD_CD = ("$(pwd)", "`pwd`")
_TOPLEVEL_CD = (
    "$(git rev-parse --show-toplevel)",
    "`git rev-parse --show-toplevel`",
    '"$(git rev-parse --show-toplevel)"',
    '"`git rev-parse --show-toplevel`"',
)
_PWD_PREFIXES = ("$(pwd)/", "`pwd`/")


_TOPLEVELS = {}  # per process: up to MAX_WORLDS worlds may ask for the same cwd


def _git_toplevel(cwd):
    if cwd not in _TOPLEVELS:
        _TOPLEVELS[cwd] = _read_toplevel(cwd)
    return _TOPLEVELS[cwd]


def _read_toplevel(cwd):
    if not cwd or not posixpath.isdir(cwd):
        return None
    try:
        res = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
            capture_output=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if res.returncode != 0:
        return None
    top = res.stdout.decode("utf-8", "replace").rstrip("\r\n")
    return top if top.startswith("/") else None


def unresolvable_cd_target(word):
    # `~`-words other than `~` and `~/…` are judged in chdir, which has the
    # state the decision needs.
    return "$" in word or "`" in word or any(c in GLOB_CHARS for c in word)


def expand_vars(word, state):
    """Replace `$NAME` and `${NAME}` in `word` from `state` (`PWD`, `OLDPWD`,
    `state.vars`, else `os.environ`). A name with no value, a `vars` entry of
    None, or any other `$` form leaves `$` in the word so it stays
    unresolvable."""
    if word is None or "$" not in word:
        return word

    def _sub(m):
        name = m.group(1) or m.group(2)
        if name == "PWD":
            val = state.cwd
        elif name == "OLDPWD":
            val = state.oldpwd
        elif name in state.vars:
            val = state.vars[name]
        else:
            val = os.environ.get(name)
        return val if val else m.group(0)

    return _VAR_REF_RE.sub(_sub, word)


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
    """What the shell carries from one command to the next: the directory
    (with OLDPWD, the pushd stack, `unknown` when an unresolvable cd target
    reset to `payload_cwd`, and per-command `uncertain`), tracked shell
    variables `vars`, and the exported TRACKED_ENV values. `payload_cwd` is
    where the text starts, the directory an unknown move resets to."""

    def __init__(self, cwd, env=None, payload_cwd=None):
        self.cwd = cwd
        self.oldpwd = None
        self.stack = []
        self.env = dict(env or {})
        self.payload_cwd = payload_cwd
        self.vars = {}
        self.unknown = False
        self.uncertain = False

    def copy(self):
        s = State(self.cwd, self.env, self.payload_cwd)
        s.oldpwd = self.oldpwd
        s.stack = list(self.stack)
        s.vars = dict(self.vars)
        s.unknown = self.unknown
        s.uncertain = self.uncertain
        return s

    def snapshot(self):
        return (self.cwd, tuple(sorted(self.env.items())))

    def _key(self):
        return (
            self.cwd,
            self.oldpwd,
            tuple(self.stack),
            tuple(sorted(self.env.items())),
            tuple(sorted(self.vars.items())),
            self.unknown,
        )


def chdir(state, word):
    """Expand `$NAME`/`${NAME}` via `expand_vars` and move to `word`
    (`$(pwd)`/`` `pwd` `` stays at `state.cwd` and `$(pwd)/…`/`` `pwd`/… ``
    joins against it; `$(git rev-parse --show-toplevel)` and its backtick/
    unquoted spellings resolve via `git -C <state.cwd> rev-parse
    --show-toplevel` when `state.cwd` exists); None or an unresolvable word
    resets to `payload_cwd` (an unresolvable word also sets
    `state.unknown = True`, cleared by a later literal absolute or `~`
    target). Sets `state.uncertain = True` when the target is None,
    unresolvable, or not an existing directory. Returns True when the move
    happened (resolved or reset), False for a known failure that leaves the
    state as it is."""
    if word is not None:
        word = expand_vars(word, state)
    if word in _PWD_CD:
        state.oldpwd = state.cwd
        return True
    if word in _TOPLEVEL_CD:
        top = _git_toplevel(state.cwd)
        if top is not None:
            word = top
    pwd_prefix = False
    for prefix in _PWD_PREFIXES:
        if word is not None and word.startswith(prefix):
            word = posixpath.join(state.cwd, word[len(prefix):])
            pwd_prefix = True
            break
    if word is not None and word.startswith("~") and word != "~" \
            and not word.startswith("~/"):
        # bash always expands `~+` to PWD and `~-` to OLDPWD; with no OLDPWD
        # `~-` stays literal and cd fails, changing nothing: a known failure,
        # so the state stays as it is and False tells the caller.
        if word == "~+":
            state.oldpwd = state.cwd
            if state.unknown or not posixpath.isdir(state.cwd):
                state.uncertain = True
            return True
        if word == "~-":
            if state.oldpwd is None:
                return False
            chdir(state, state.oldpwd)
            return True
        # `~user`/`~N`: when bash can't expand the word it stays literal and
        # cd enters a literal directory of that name in the cwd (a crafted
        # `~other` repo), so one that exists is followed. Without one, bash
        # went to a home (`~user`) or a dirstack entry (`~N`) the hook can't
        # know, or failed and stayed: reset. Accepted edge: a user that exists
        # AND a literal directory of the same name; bash goes home, the model
        # follows the literal one.
        if not posixpath.isdir(posixpath.join(state.cwd, word)):
            word = None
    before = state.cwd
    if word is None or unresolvable_cd_target(word):
        if word is not None:
            state.unknown = True
        state.cwd = state.payload_cwd
        state.uncertain = True
    else:
        if not pwd_prefix and (word.startswith("/") or word == "~" or word.startswith("~/")):
            state.unknown = False
        state.cwd = resolve_cd(state.cwd, word)
        if not posixpath.isdir(state.cwd):
            state.uncertain = True
    state.oldpwd = before
    return True


def do_cd(state, args):
    while args and args[0].startswith("-") and args[0] != "-":
        if args[0] == "--":
            args = args[1:]
            break
        if not CD_OPTION_RE.match(args[0]):
            return  # an invalid option: bash errors out, the directory stays
        args = args[1:]
    if len(args) > 1 and args[0].startswith("`") and "`" in args[-1]:
        args = [" ".join(args)]
    elif args == ["git", "rev-parse", "--show-toplevel"]:
        args = ["`git rev-parse --show-toplevel`"]
    if len(args) > 1:
        return  # too many arguments: bash errors out, the directory stays
    if not args:
        home = os.environ.get("HOME")  # bare cd: $HOME
        if home:
            chdir(state, home)
        # else: no HOME, bash's cd fails and nothing moves
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
    if chdir(state, state.oldpwd if args[0] == "-" else args[0]):
        state.stack.insert(0, before)  # a failed pushd pushes nothing


def do_popd(state, args):
    if args[:1] == ["--"]:
        args = args[1:]
    if args or not state.stack:
        chdir(state, None)  # options, or a stack this text didn't build: reset
        return
    chdir(state, state.stack.pop(0))


def apply_dir_builtin(argv, state):
    """Apply a `cd`, `pushd` or `popd` in `argv` to `state`, where `argv` is a
    command as the walker hands it over (runner words such as `builtin` and
    `command` may lead it, and redirections are ignored). True when it was one
    of the three; any other command leaves `state` alone and gives False."""
    unwrapped, info = unwrap_runners(argv)
    if not unwrapped or not (set(info["runners"]) <= _BUILTIN_RUNNERS):
        return False
    name = unwrapped[0]
    args = strip_redirections(unwrapped[1:])
    if name == "cd":
        do_cd(state, args)
    elif name == "pushd":
        do_pushd(state, args)
    elif name == "popd":
        do_popd(state, args)
    else:
        return False
    return True


def _tokens_of(text):
    body_free = strip_heredoc_bodies(text)
    tokens = _tokens(body_free)
    pipelines = _pipelines(tokens)
    if body_free != text and any(
        _reads_script_from_stdin(c) for p in pipelines for c in p
    ):
        tokens = _tokens(text)
        return tokens, _pipelines(tokens), text
    return tokens, pipelines, body_free


def pipelines_of(text):
    """The top-level pipelines of `text`, exactly as `simple_commands` splits
    them (heredoc bodies dropped unless a shell reads its script from stdin),
    WITHOUT its trailing wrapper expansion — the walk below places each
    wrapper's commands right after the pipeline that runs them.
    Also returns the text the walk scans for substitutions: the same
    body-free text, since a heredoc body is data (the lib's convention; an
    unquoted-delimiter body's `$(…)` is an accepted under-arm)."""
    _, pipelines, scan_text = _tokens_of(text)
    return pipelines, scan_text


def _dedup(worlds):
    out = []
    seen = set()
    for w in worlds:
        k = w._key()
        if k not in seen:
            seen.add(k)
            out.append(w)
    if len(out) > MAX_WORLDS:
        return out[: MAX_WORLDS - 1] + [out[-1]]
    return out


def _assign_word(m, state):
    name, plus, val = m.group(1), m.group(2), m.group(3)
    if plus:
        state.vars[name] = None
        return
    val = expand_vars(val, state)
    if not val or unresolvable_cd_target(val):
        state.vars[name] = None
    else:
        state.vars[name] = val


def _track_vars(argv, state):
    words = strip_redirections(argv)
    if not words:
        return
    matches = [_ASSIGN_RE.match(w) for w in words]
    if all(matches):
        for m in matches:
            _assign_word(m, state)
        return
    unwrapped, info = unwrap_runners(argv)
    if not unwrapped or not (set(info["runners"]) <= _BUILTIN_RUNNERS):
        return
    name = unwrapped[0]
    args = strip_redirections(unwrapped[1:])
    if name == "unset":
        i = 0
        while i < len(args) and args[i].startswith("-"):
            opt = args[i]
            i += 1
            if opt == "--":
                break
            if "f" in opt[1:]:
                return
        for w in args[i:]:
            state.vars.pop(w, None)
            state.vars[w] = None
    elif name in ("export", "declare", "typeset", "local", "readonly"):
        i = 0
        while i < len(args) and args[i][:1] in ("-", "+") and len(args[i]) > 1:
            opt = args[i]
            i += 1
            if opt == "--":
                break
            if "f" in opt[1:]:
                return
        for w in args[i:]:
            m = _ASSIGN_RE.match(w)
            if m:
                _assign_word(m, state)
    elif name == "read":
        i = 0
        while i < len(args) and args[i].startswith("-") and len(args[i]) > 1:
            opt = args[i]
            i += 1
            if opt == "--":
                break
            for j, ch in enumerate(opt[1:], 1):
                if ch in "dinNptu":
                    if j == len(opt) - 1:
                        i += 1
                    break
        for w in args[i:] or ["REPLY"]:
            v = w.split("[", 1)[0]
            if _IDENT_RE.match(v):
                state.vars[v] = None
    elif name in ("mapfile", "readarray"):
        i = 0
        while i < len(args) and args[i].startswith("-") and len(args[i]) > 1:
            opt = args[i]
            i += 1
            if opt == "--":
                break
            for j, ch in enumerate(opt[1:], 1):
                if ch in "dnOsuCc":
                    if j == len(opt) - 1:
                        i += 1
                    break
        v = (args[i] if i < len(args) else "MAPFILE").split("[", 1)[0]
        if _IDENT_RE.match(v):
            state.vars[v] = None
    elif name == "printf":
        i = 0
        while i < len(args) and args[i].startswith("-") and len(args[i]) > 1:
            opt = args[i]
            i += 1
            if opt == "--":
                break
            if opt == "-v":
                if i < len(args):
                    v = args[i].split("[", 1)[0]
                    if _IDENT_RE.match(v):
                        state.vars[v] = None
                    i += 1
            elif opt.startswith("-v"):
                v = opt[2:].split("[", 1)[0]
                if _IDENT_RE.match(v):
                    state.vars[v] = None
    elif name == "getopts":
        if args[:1] == ["--"]:
            args = args[1:]
        if len(args) >= 2:
            v = args[1].split("[", 1)[0]
            if _IDENT_RE.match(v):
                state.vars[v] = None


def walk(text, depth, state, ctx, run_command):
    """Walk `text`'s commands in EXECUTION order across possible states
    ("worlds", capped at MAX_WORLDS), updating `state` to the final S-path
    world. A command substitution runs just before the command whose word
    holds it; a wrapper's string (`bash -c`, `eval`, …) runs as the pipeline
    does. Both run in a child shell, so each walks a COPY of the world. At
    MAX_WRAPPER_DEPTH a substitution is not walked inline but left over, so
    the caller's replay still judges it."""
    tokens, _, scan_text = _tokens_of(text)
    pending = list(substitution_spans(scan_text))
    merged = []
    t_idx = 0
    while t_idx < len(tokens):
        tok = tokens[t_idx]
        if (
            tokens[t_idx : t_idx + 6]
            == ["$", _Op("("), "git", "rev-parse", "--show-toplevel", _Op(")")]
        ):
            merged.append("$(git rev-parse --show-toplevel)")
            t_idx += 6
        elif tokens[t_idx : t_idx + 4] == ["$", _Op("("), "pwd", _Op(")")]:
            merged.append("$(pwd)")
            t_idx += 4
        elif (
            tokens[t_idx : t_idx + 3] == ["git", "rev-parse", "--show-toplevel"]
            and "git rev-parse --show-toplevel" in pending
            and merged
            and merged[-1] in ("cd", "pushd", "--")
        ):
            merged.append("`git rev-parse --show-toplevel`")
            t_idx += 3
        elif (
            isinstance(tok, _Op)
            and tok == "&"
            and merged
            and isinstance(merged[-1], _Op)
            and merged[-1] == ";;"
        ):
            merged[-1] = _Op(";;&")
            t_idx += 1
        else:
            merged.append(tok)
            t_idx += 1

    pieces = []
    cur = []
    for tok in merged:
        if isinstance(tok, _Op) and tok not in _PIPE_OPS:
            pieces.append((cur, tok))
            cur = []
        else:
            cur.append(tok)
    if cur:
        pieces.append((cur, _Op(";")))

    worlds = [state.copy()]
    list_entry = [w.copy() for w in worlds]
    S = [w.copy() for w in worlds]
    F = []
    list_op = None
    else_entries = []
    frames = []

    def _pop_frame(kinds):
        for idx in range(len(frames) - 1, -1, -1):
            if frames[idx][0] in kinds:
                return frames.pop(idx)[1]
        return None

    def _top_frame(kinds):
        for idx in range(len(frames) - 1, -1, -1):
            if frames[idx][0] in kinds:
                return frames[idx][1]
        return None

    def _run_one(argv, w, matched_spans):
        for span in matched_spans:
            walk(span, depth + 1, w.copy(), ctx, run_command)
        before = w.copy()
        w.uncertain = False
        ctx.visited.add(w.snapshot())
        _track_vars(argv, w)
        run_command(argv, w, ctx)
        ctx.visited.add(w.snapshot())
        unwrapped, _ = unwrap_runners(argv)
        if unwrapped and unwrapped[0] in ("exit", "return"):
            return [], []
        if w._key() == before._key():
            return [w], [w.copy()]
        if not w.uncertain:
            return [w], []
        return [w], [before]

    def _take_matched(argv):
        """The pending substitution spans this command's words spell (`$(span)`
        or `` `span` ``), removed from `pending` and returned in its order."""
        matched = []
        if pending and depth < MAX_WRAPPER_DEPTH:
            joined = " ".join(argv)
            for span in list(pending):
                forms = (f"$({span})", f"`{span}`")
                if any(f in w for f in forms for w in argv + [joined]):
                    pending.remove(span)
                    matched.append(span)
        return matched

    def _run_pipeline(stages, in_worlds):
        if len(stages) == 1:
            argv = stages[0]
            matched = _take_matched(argv)
            p_s, p_f = [], []
            for w in in_worlds:
                s1, f1 = _run_one(argv, w.copy(), matched)
                p_s.extend(s1)
                p_f.extend(f1)
            p_s, p_f = _dedup(p_s), _dedup(p_f)
            if depth < MAX_WRAPPER_DEPTH:
                joined = shlex.join(argv)
                wrap_worlds = _dedup(p_f + p_s) or [w.copy() for w in in_worlds]
                for inner in wrapped_command_strings(joined):
                    for w in wrap_worlds:
                        walk(inner, depth + 1, w.copy(), ctx, run_command)
            return p_s, p_f

        acc = [w.copy() for w in in_worlds]
        for argv in stages:
            matched = _take_matched(argv)
            stage_s, stage_f = [], []
            for w in acc:
                s1, f1 = _run_one(argv, w.copy(), matched)
                stage_s.extend(s1)
                stage_f.extend(f1)
            acc = _dedup(acc + stage_f + stage_s)
        if depth < MAX_WRAPPER_DEPTH:
            joined = " | ".join(shlex.join(a) for a in stages)
            for inner in wrapped_command_strings(joined):
                for w in acc:
                    walk(inner, depth + 1, w.copy(), ctx, run_command)
        return [w.copy() for w in acc], [w.copy() for w in acc]

    for piece, op in pieces:
        idx = 0
        while idx < len(piece) and not isinstance(piece[idx], _Op):
            w = piece[idx]
            if w in ("!", "then", "do"):
                idx += 1
                continue
            if w == "time":
                idx += 1
                if idx < len(piece) and piece[idx] == "-p":
                    idx += 1
                if idx < len(piece) and piece[idx] == "--":
                    idx += 1
                continue
            if w in ("if", "while", "until"):
                cur = _dedup(F + S) if list_op else worlds
                frames.append((w, [st.copy() for st in cur]))
                idx += 1
                continue
            if w == "case":
                cur = _dedup(F + S) if list_op else worlds
                frames.append(("case", [st.copy() for st in cur]))
                break
            if w == "for":
                if idx + 1 < len(piece) and not isinstance(piece[idx + 1], _Op):
                    vname = piece[idx + 1]
                    for st in worlds + S + F + list_entry:
                        st.vars[vname] = None
                cur = _dedup(F + S) if list_op else worlds
                frames.append(("for", [st.copy() for st in cur]))
                break
            if w == "{":
                cur = _dedup(F + S) if list_op else worlds
                frames.append(("{", [st.copy() for st in cur]))
                idx += 1
                continue
            if w in ("else", "elif"):
                entry = _top_frame(("if",))
                if entry is not None:
                    worlds = _dedup(worlds + [st.copy() for st in entry])
                    S = [st.copy() for st in worlds]
                    if list_op is None:
                        list_entry = [st.copy() for st in worlds]
                    if w == "else":
                        else_entries.append([st.copy() for st in entry])
                idx += 1
                continue
            if w in ("fi", "done", "esac"):
                kinds = (
                    ("if",)
                    if w == "fi"
                    else (("case",) if w == "esac" else ("while", "until", "for"))
                )
                entry = _pop_frame(kinds)
                if entry is not None:
                    worlds = _dedup([st.copy() for st in entry] + worlds)
                    S = [st.copy() for st in worlds]
                    if list_op is None:
                        list_entry = [st.copy() for st in worlds]
                idx += 1
                continue
            if w == "}":
                entry = _pop_frame(("{",))
                nxt = piece[idx + 1] if idx + 1 < len(piece) else op
                if entry is not None and isinstance(nxt, _Op) and nxt in ("|", "|&", "&"):
                    worlds = _dedup([st.copy() for st in entry] + worlds)
                    S = [st.copy() for st in worlds]
                    if list_op is None:
                        list_entry = [st.copy() for st in worlds]
                idx += 1
                continue
            break

        stages = [argv for p in _pipelines(piece) for argv in p]
        if stages:
            if list_op is None or list_op == "&&":
                p_s, p_f = _run_pipeline(stages, S)
                S = p_s
                F = _dedup(F + p_f)
            else:
                if F:
                    p_s, p_f = _run_pipeline(stages, F)
                    S = _dedup(S + p_s)
                    F = p_f
                else:
                    _run_pipeline(stages, [st.copy() for st in list_entry])

        if op in ("&&", "||"):
            list_op = str(op)
        else:
            if stages or list_op is not None:
                combined = _dedup(F + S)
                if not combined:
                    combined = [st.copy() for st in list_entry]
                worlds = combined
            if op == "&":
                worlds = _dedup([st.copy() for st in list_entry] + worlds)
            if else_entries:
                for entry in else_entries:
                    worlds = _dedup(worlds + [st.copy() for st in entry])
                else_entries = []
            if op in (";;", ";&", ";;&"):
                entry = _top_frame(("case",))
                if entry is not None:
                    worlds = _dedup([st.copy() for st in entry] + worlds)
            elif op == "(":
                frames.append(("(", [st.copy() for st in worlds]))
            elif op == ")":
                if frames and frames[-1][0] == "(":
                    entry = frames.pop()[1]
                    worlds = _dedup([st.copy() for st in entry] + worlds)
            list_entry = [st.copy() for st in worlds]
            S = [st.copy() for st in worlds]
            F = []
            list_op = None

    if worlds:
        last = worlds[-1]
        state.cwd = last.cwd
        state.oldpwd = last.oldpwd
        state.stack = list(last.stack)
        state.env = dict(last.env)
        state.vars = dict(last.vars)
        state.unknown = last.unknown
        state.uncertain = last.uncertain
    ctx.leftovers.extend((span, depth + 1) for span in pending)
