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
_JOB_DIR_WORD = re.compile(r"^(?:\$CLAUDE_JOB_DIR|\$\{CLAUDE_JOB_DIR\})(?=/|$)")


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
    behind a runner: `-exec env rm -rf {} +`)."""
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


def analyze(text):
    """Return `(hits, dir_changed, relinked)` for a raw Bash command.

    Each hit is a dict: `kind` ("rm" or "find"), `line` (the unwrapped argv,
    for messages), and
    - rm: `recursive`, `targets`, `stdin` (targets also come from stdin or an
      arg file: xargs/parallel), `stdin_cache` (that stdin is the output of the
      find DIRECTLY upstream in the same pipeline, which selects only cache
      names and deletes nothing);
    - find: `names` (its -name/-iname values), `roots` (its start paths).
    An rm is a hit when it is recursive or runs under xargs/parallel (a mass
    delete);
    a single `rm file` / `rm -f file` is not. A find is a hit when it deletes.

    `dir_changed`: some command changes directory (cd/pushd/popd, `env -C`,
    `sudo -D`), so a relative target cannot be resolved against the payload's
    cwd. `relinked`: the command runs ln/mv/install/`cp -s`, or assigns,
    exports or unsets CLAUDE_JOB_DIR, so a job-dir path may not be what it
    looks like.
    """
    hits = []
    dir_changed = relinked = False
    for pipeline in command_pipelines(text):
        upstream = None
        for raw in pipeline:
            if any(w.startswith("CLAUDE_JOB_DIR=") or w == "CLAUDE_JOB_DIR" for w in raw):
                relinked = True
            argv, info = unwrap_runners(raw)
            dir_changed = dir_changed or info["chdir"]
            prog = os.path.basename(argv[0]) if argv else ""
            if prog in _DIR_CHANGERS:
                dir_changed = True
            if prog in _RELINKERS or (prog == "cp" and any(
                    a == "--symbolic-link" or re.match(r"^-[a-zA-Z]*s", a) for a in argv[1:])):
                relinked = True
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
                                 "names": names, "roots": roots})
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


def in_job_tmp(target, job_dir, cwd, dir_changed):
    """True when `target` resolves strictly below `<job_dir>/tmp` (never the dir
    itself). A literal $CLAUDE_JOB_DIR prefix is expanded; any other `$`, a
    backtick, `~` or a brace expansion is unresolvable. A relative path resolves
    against `cwd`, and only when nothing in the command changed directory.
    realpath folds `..` and follows symlinks that exist. A glob is judged by the
    folder it expands in, which must be tmp itself or below it."""
    if not job_dir or not os.path.isdir(job_dir) or target == STDIN:
        return False
    job_tmp = os.path.realpath(os.path.join(job_dir, "tmp"))
    path = _JOB_DIR_WORD.sub(lambda m: job_dir, target)
    if any(c in path for c in "$`{") or path.startswith("~"):
        return False
    if not os.path.isabs(path):
        if not cwd or dir_changed:
            return False
        path = os.path.join(cwd, path)
    glob = min((path.find(c) for c in "*?[" if c in path), default=-1)
    if glob >= 0:
        rest = path[glob:]
        if "/.." in rest or rest.startswith(".."):
            return False
        base = os.path.realpath(os.path.dirname(path[:glob]))
        return base == job_tmp or base.startswith(job_tmp + "/")
    return os.path.realpath(path).startswith(job_tmp + "/")


def job_scratch(hit, job_dir, cwd, dir_changed):
    """True when this hit deletes only inside the job scratch dir: an rm whose
    every target is in there (cache targets are cache-rm-redirect's), a find
    whose every start path is. Stdin targets are never exempt."""
    if hit["kind"] == "rm":
        return all(in_job_tmp(t, job_dir, cwd, dir_changed) or is_cache(t)
                   for t in hit["targets"])
    return all(in_job_tmp(r, job_dir, cwd, dir_changed) for r in hit["roots"])
