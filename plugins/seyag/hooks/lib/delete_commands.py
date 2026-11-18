"""What a Bash command deletes: the one analysis behind the two rm guards.

cache-rm-redirect.sh blocks a delete of a regenerable cache and points at
`safe-clean`; recursive-rm-guard.sh blocks every other recursive or mass
delete, and DEFERS to cache-rm-redirect when every delete in the command is a
cache delete, so the more specific message wins. Both read `analyze` and the
predicates below, so "rm-guard defers only when cache-rm-redirect blocks" holds
by construction: `cache_only(hit)` implies `cache_lines([hit])` is non-empty.
recursive-rm-guard.probe.sh checks it anyway, case by case.

cache-rm-redirect.sh's bash prefilter spells the CACHES names out once more (it
runs before python); its probe checks every name here gets past that prefilter.

Commands come from `command_pipelines` (lib/shell_quotes.py): newlines, chains,
subshells, wrapper strings (`bash -c`, `eval`, also behind `sudo`/`timeout`),
here-strings and heredocs fed to a shell. Runner prefixes (`sudo`, `env`,
`xargs -n 1`, `timeout 60`, `parallel … :::`, `distrobox enter X --`, …) come
off through `unwrap_runners`.
"""

import os
import re

from shell_quotes import command_pipelines, strip_redirections, unwrap_runners

CACHES = frozenset(
    {
        "__pycache__",
        ".pytest_cache",
        ".ruff_cache",
        ".mypy_cache",
        "node_modules",
        ".turbo",
        "htmlcov",
        ".coverage",
    }
)

STDIN = "(paths from stdin)"
_DIR_CHANGERS = ("cd", "pushd", "popd")
# Commands that can make a path under the job dir point somewhere else.
_RELINKERS = ("ln", "mv", "install")
_EXEMPT_NAMES = ("CLAUDE_JOB_DIR", "SYG_SCRATCH_ROOT")
_PLAIN_CHARS = r"[A-Za-z0-9_./*?+,:=@%^\[\]-]*"
_PLAIN_WORD = re.compile(r"[A-Za-z0-9_./*?+,:=@%^\[\]-]+")
_JOB_WORD = re.compile(r"\$(?:CLAUDE_JOB_DIR|\{CLAUDE_JOB_DIR\})" + _PLAIN_CHARS)
_PLAIN_SEPARATORS = ("&&", "||", ";", "|", "{}", "\\;")


def plain_command(text):
    """True when every whitespace-separated word of the whole command is one the
    exemption can judge from its text alone: a bare word of `A-Za-z0-9_./*?+,:=@%^-`
    (and `[]` for a glob class), a word starting with a literal `$CLAUDE_JOB_DIR` or
    `${CLAUDE_JOB_DIR}`, either of those inside one pair of double quotes, a `&&` `||`
    `;` `|` separator, or find's `{}` / `\\;`. Anything else (a quote, `$(`, a redirection,
    `~`, a backtick, a brace list, an unbalanced word) means the splitter's words may not be
    the shell's, so the command gets no exemption."""
    def ok(w):
        if len(w) >= 2 and w[0] == w[-1] == '"':
            w = w[1:-1]
        return bool(_PLAIN_WORD.fullmatch(w) or _JOB_WORD.fullmatch(w))
    return all(w in _PLAIN_SEPARATORS or ok(w) for w in text.split())


def tampers_with_exempt_vars(text):
    """True when CLAUDE_JOB_DIR or SYG_SCRATCH_ROOT appears in `text` other than as
    `$NAME` or `${NAME}` (assignment, subscript, `declare -n`, read, printf -v, unset,
    export, an env argument)."""
    for name in _EXEMPT_NAMES:
        if name in re.sub(r"\$(?:\{%s\}|%s(?![A-Za-z0-9_]))" % (name, name), "", text):
            return True
    return False


_ENV_OPT_TAMPER = re.compile(r"^(?:-[A-Za-z]*[SC]|--(?:c|s)[a-z-]*(?:=.*)?$)")  # `-iC<dir>` glues its value


def raw_tampers(raw):
    """True when this command's raw words can change what a scratch path means: env
    -S/-C (split-string, chdir), parallel :::: / --workdir, ln/mv/install, cp -s,
    shopt, `set -o`/`set +o`, `bash -O`/`+O`; found at any word position, so also
    inside a find -exec."""
    for i, w in enumerate(raw):
        base, rest = os.path.basename(w), raw[i + 1:]
        if base in _RELINKERS or base == "shopt":
            return True
        if base == "cp" and any(a == "--symbolic-link" or re.match(r"^-[A-Za-z]*s", a)
                                for a in rest):
            return True
        if w == "set" and any(re.match(r"^[-+][A-Za-z]*o", a) for a in rest):
            return True
        if base in ("bash", "sh", "zsh", "dash") and any(re.match(r"^[-+][A-Za-z]*O", a)
                                                         for a in rest):
            return True
        if base == "parallel" and any(a == "::::" or a.startswith(("--workdir", "--wd"))
                                      for a in rest):
            return True
        if base == "env":
            j = 0
            while j < len(rest) and (rest[j].startswith("-") or "=" in rest[j]):
                if _ENV_OPT_TAMPER.match(rest[j]):
                    return True
                j += 2 if rest[j] in ("-u", "--unset") else 1
    return False
_JOB_DIR_WORD =re.compile(r"^(?:\$CLAUDE_JOB_DIR|\$\{CLAUDE_JOB_DIR\})(?=/|$)")


def is_cache(path):
    return path != STDIN and os.path.basename(path.rstrip("/")) in CACHES


def rm_args(args):
    """(recursive, targets) for rm's arguments. Options stop at `--`; `rm -- -r`
    deletes a file named -r. GNU accepts any unambiguous prefix of a long
    option, and every `--r…` prefix of --recursive is unambiguous for rm."""
    recursive, targets, options_done = False, [], False
    for a in strip_redirections(args):
        if options_done or a == "-" or not a.startswith("-"):
            targets.append(a)
        elif a == "--":
            options_done = True
        elif a.startswith("--"):
            key = a.split("=", 1)[0]
            recursive = recursive or (len(key) >= 3 and "--recursive".startswith(key))
        elif "r" in a or "R" in a:
            recursive = True
    return recursive, targets


def find_args(args):
    """(roots, -name values, deletes) for find's arguments. A find deletes with
    -delete, or with -exec/-execdir/-ok/-okdir running rm (any flags, also
    behind a runner: `-exec env rm -rf {} +`). Detection only: whether a delete
    may be exempt is find_scratch_shape's call."""
    i = 0
    while i < len(args) and args[i] in ("-H", "-L", "-P"):
        i += 1
    roots = []
    while i < len(args) and not args[i].startswith(("-", "(", "!")):
        roots.append(args[i])
        i += 1
    names = [args[j + 1] for j in range(len(args) - 1) if args[j] in ("-name", "-iname")]
    deletes = "-delete" in args
    for j, a in enumerate(args):
        if a in ("-exec", "-execdir", "-ok", "-okdir"):
            inner = []
            for w in args[j + 1 :]:
                if w in (";", "+"):
                    break
                inner.append(w)
            inner, _ = unwrap_runners(inner)
            if inner and os.path.basename(inner[0]) == "rm":
                deletes = True
    return roots or ["."], names, deletes


_FIND_VALUE_TESTS = {
    "-name": r".*", "-iname": r".*", "-path": r".*", "-ipath": r".*", "-type": r"[bcdflps]",
    "-mindepth": r"[0-9]+", "-maxdepth": r"[0-9]+", "-mtime": r"[+-]?[0-9]+",
    "-mmin": r"[+-]?[0-9]+", "-newer": r".*",
}
_FIND_FLAG_TESTS = ("-empty", "-print")
_RM_WORD = re.compile(r"^(?:rm|.*/rm)$")
_RM_OPT = re.compile(r"^(?:-[rRfvdI]+|--recursive|--force|--verbose|--dir)$")


def find_scratch_shape(args):
    """The paths a find must keep inside the scratch dir, or None when its
    arguments (everything after `find`) are not EXACTLY the one shape that may
    be exempt: start paths (none starting with `-`, `!`, `(`, `)` or being `,`),
    then tests from -name/-iname/-path/-ipath/-type/-mindepth/-maxdepth/-mtime/
    -mmin/-newer/-empty/-print, then one action: -delete, `-exec rm [-rRfvdI
    opts] {} +` or `{} ;`. No other option, operator, runner or action."""
    args = strip_redirections(args)
    i, paths = 0, []
    while i < len(args) and args[i] and args[i][0] not in "-!()" and args[i] != ",":
        paths.append(args[i])
        i += 1
    if not paths:
        return None
    while i < len(args):
        a = args[i]
        if a in _FIND_FLAG_TESTS:
            i += 1
        elif a in _FIND_VALUE_TESTS and i + 1 < len(args) \
                and re.fullmatch(_FIND_VALUE_TESTS[a], args[i + 1]):
            if a == "-newer":
                paths.append(args[i + 1])
            i += 2
        else:
            break
    rest = args[i:]
    if rest == ["-delete"]:
        return paths
    if len(rest) >= 4 and rest[0] == "-exec" and _RM_WORD.match(rest[1]) \
            and rest[-2] == "{}" and rest[-1] in (";", "\\;", "+") \
            and all(_RM_OPT.match(w) for w in rest[2:-2]):
        return paths
    return None


def analyze(text):
    """Return `(hits, dir_changed, relinked)` for a raw Bash command.

    Each hit is a dict: `kind` ("rm" or "find"), `line` (the unwrapped argv,
    for messages), and
    - rm: `recursive`, `targets`, `stdin` (targets also come from stdin or an
      arg file: xargs/parallel), `stdin_cache` (that stdin is the output of the
      find DIRECTLY upstream in the same pipeline, which selects only cache
      names and deletes nothing);
    - find: `names` (its -name/-iname values), `roots` (its start paths),
      `scratch_paths` (the paths find_scratch_shape says must stay in scratch, or
      None when the find is not in the one shape that may be exempt).
    An rm is a hit when it is recursive or runs under xargs/parallel (a mass
    delete);
    a single `rm file` / `rm -f file` is not. A find is a hit when it deletes.

    `dir_changed`: some command changes directory (cd/pushd/popd, `env -C`,
    `sudo -D`), so a relative target cannot be resolved against the payload's
    cwd. `relinked` (no scratch exemption for this command): the text is not
    all plain words (`plain_command`), holds an extglob opener, mentions
    CLAUDE_JOB_DIR / SYG_SCRATCH_ROOT other than as `$NAME`
    (`tampers_with_exempt_vars`), or some command changes what a scratch path
    means (`raw_tampers`: env -S/-C, parallel ::::/--workdir, ln/mv/install,
    `cp -s`, shopt, `set -o`, `bash -O`).
    """
    hits = []
    dir_changed = False
    # An extglob (`@(..)`, `+(..)`, `!(..)`, `*(..)`, `?(..)`) reaches the splitter cut at the `(`,
    # so the word it hands back is not what the shell would expand: no exemption for the command.
    # The whole command text must be plain words (the splitter has no spans to judge one delete's
    # own words, so a quote or `$(` in an unrelated command also costs the exemption: an accepted
    # over-block) and must not touch the exemption variables.
    relinked = bool(re.search(r"[@!+*?]\(", text)) or not plain_command(text) \
        or tampers_with_exempt_vars(text)
    for pipeline in command_pipelines(text):
        upstream = None
        for raw in pipeline:
            if raw_tampers(raw):
                relinked = True
            argv, info = unwrap_runners(raw)
            dir_changed = dir_changed or info["chdir"]
            prog = os.path.basename(argv[0]) if argv else ""
            if prog in _DIR_CHANGERS:
                dir_changed = True
            if prog == "rm":
                recursive, targets = rm_args(argv[1:])
                from_stdin = info["stdin"] or info["arg_file"]
                if recursive or info["fanout"]:
                    stdin_cache = False
                    if info["stdin"] and not info["arg_file"] and upstream:
                        up, _ = unwrap_runners(upstream)
                        if up and os.path.basename(up[0]) == "find":
                            _, names, deletes = find_args(up[1:])
                            stdin_cache = bool(names) and not deletes and all(
                                n in CACHES for n in names)
                    hits.append({
                        "kind": "rm", "line": " ".join(argv), "recursive": recursive,
                        "targets": targets + ([STDIN] if from_stdin else []),
                        "stdin": from_stdin, "stdin_cache": stdin_cache,
                    })
            elif prog == "find":
                roots, names, deletes = find_args(argv[1:])
                if deletes:
                    hits.append({"kind": "find", "line": " ".join(argv),
                                 "names": names, "roots": roots,
                                 "scratch_paths": find_scratch_shape(argv[1:])})
            upstream = raw
    return hits, dir_changed, relinked


def cache_lines(hits):
    """What cache-rm-redirect blocks: a recursive rm with a cache target (or
    fed by an upstream cache find), or a deleting find selecting a cache name."""
    lines = []
    for h in hits:
        if h["kind"] == "rm" and h["recursive"]:
            lines += [t for t in h["targets"] if is_cache(t)]
            if h["stdin_cache"]:
                lines.append("find -name ... | xargs rm (" + h["line"] + ")")
        elif h["kind"] == "find":
            lines += ["find -name " + n for n in h["names"] if n in CACHES]
    return lines


def worktree_target(hits):
    """True when an rm target or a find root lies in a .claude/worktrees path (the text of
    the path only: a relative target is not resolved against a cd)."""
    return any(re.search(r"(^|/)\.claude/worktrees(/|$)", p)
               for h in hits for p in h.get("targets", []) + h.get("roots", []))


def cache_only(hit):
    """True when this hit deletes only caches; cache_lines([hit]) is then non-empty."""
    if hit["kind"] == "rm":
        return hit["recursive"] and bool(hit["targets"]) and all(
            is_cache(t) or (t == STDIN and hit["stdin_cache"]) for t in hit["targets"])
    return bool(hit["names"]) and all(n in CACHES for n in hit["names"])


def in_scratch(target, root, cwd, dir_changed, job_dir=""):
    """True when `target` resolves strictly below `root` (never the dir itself),
    the already-realpath'd scratch dir that bounds the exemption. A literal
    $CLAUDE_JOB_DIR prefix is expanded with `job_dir` (only that prefix); any
    other `$`, a backtick, `~` or a brace expansion is unresolvable. A relative
    path resolves against `cwd`, and only when nothing in the command changed
    directory. realpath folds `..` and follows symlinks that exist. A glob is
    judged by the folder it expands in, which must be root itself or below it;
    it may sit only in the last path component, which must not start with `.`
    or `[`."""
    if not root or target == STDIN:
        return False
    path = _JOB_DIR_WORD.sub(lambda m: job_dir, target) if job_dir else target
    # `(` `)` cover extglob (`@(..)`, `!(..)`, `+(..)`, `*(..)`, `?(..)`); a backslash escapes.
    if any(c in path for c in "$`{()\\") or path.startswith("~"):
        return False
    if not os.path.isabs(path):
        if not cwd or dir_changed:
            return False
        path = os.path.join(cwd, path)
    if any(c in path for c in "*?["):
        head, _, last = path.rpartition("/")
        # A glob only in the last component, which cannot start with `.` (it could match `.`/`..`
        # or a dotfile) or `[` (`[.]`); a glob earlier, or a `/` after one, is not judged.
        if any(c in head for c in "*?[") or last[:1] in ("", ".", "["):
            return False
        base = os.path.realpath(head or "/")
        return base == root or base.startswith(root + "/")
    return os.path.realpath(path).startswith(root + "/")


def scratch_target(hit, roots, cwd, dir_changed, job_dir=""):
    """True when this hit deletes only inside the scratch dirs `roots` (each
    already realpath'd): an rm whose every target is in one of them (cache
    targets are cache-rm-redirect's), a find whose every start path is. Stdin
    targets are never exempt. A find is exempt only in find_scratch_shape's
    allowlisted shape, with every path it names inside."""
    def inside(t):
        return any(in_scratch(t, r, cwd, dir_changed, job_dir) for r in roots)
    if hit["kind"] == "rm":
        return bool(hit["targets"]) and all(inside(t) or is_cache(t) for t in hit["targets"])
    paths = hit["scratch_paths"]
    return paths is not None and all(inside(p) for p in paths)
