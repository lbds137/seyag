"""What text a Bash command would send off the machine: the one walker behind
session-url-gate.sh and private-term-guard.sh.

`outbound_items(cmd, cwd, bypass_assignment, dir_filter=None,
commit_text_owner=None)` returns `Item(label, text, directory, kind, sha)`
records; each hook matches its own pattern over `text`. `label` names the
source and can hold user text (a commit subject, a path); `kind` (`text`,
`file`, `staged`, `commit-message`, `commit-diff`) and `sha` name it without
user text. `directory` is the
directory the command producing the item runs in (the event cwd tracked
across possible states by `lib/shell_state.py`'s `walk` — `cd`/`pushd`/`popd`,
`~` and `$NAME`/`${NAME}` from `PWD`, `OLDPWD`, tracked assignments and the
environment, plus git's `-C`), for a hook that judges the target repo.
Conditional/uncertain moves, `&`, pipelines and compound commands keep both
paths (up to `MAX_WORLDS = 64`). When a `cd` target is unresolvable, the state
resets to the event cwd and is marked `unknown`: it is judged at its `cwd` by
`dir_filter` as usual for files, staged lines and `git log`, and in addition
its command text is scanned regardless of `dir_filter` or `commit_text_owner`.
When `dir_filter(directory)` returns False, the remaining items of that
directory are not built (no file read, diff or log run).

Commands are found with the shared splitter (lib/shell_quotes.py): top-level
pipelines, wrapper strings such as `bash -c '…'`, and command substitutions
(two levels deep). A command whose own prefix holds `bypass_assignment` (e.g.
`SYG_ALLOW_SESSION_URL=1 git commit …`, `env SYG_ALLOW_SESSION_URL=1 gh …`)
yields nothing; a mention elsewhere in the text does not count. When
`SYG_GH_WRAPPERS` (a whitespace-separated token list; opt-in, empty by default;
the only input — no fallback to any other variable) is set and a command's argv
begins with that token sequence (the first token compared by basename against
the basename of `argv[0]`, the rest verbatim), the walker matches a `gh`
operation in either the plain two-word form (`<subcommand> <word>` where
`<subcommand>` is `pr`, `issue`, `repo`, `gist`, `release`, `run` or `api`,
anchored immediately after the wrapper tokens or immediately after a literal
`gh` word there) or, scanning forward, the colon form (`gh:<rest>`, e.g.
`gh:pr-edit`, `gh:repo-set-default`, `gh:api`, split on the first `-`), and
feeds the synthetic `gh` argv through the same `gh_text_exempt`,
`file_values_gh` and `repo_create_push_dir` path as a literal `gh` command
(when intervening words sit between the wrapper tokens and a colon-form match,
`gh_text_exempt` is skipped and the command text is always scanned). A
single-token wrapper that names a common script runner (e.g. `myops`) makes
plain `run`/`release` invocations scan as gh writes — configure the full prefix
(e.g. `myops ci`). Wrapper flags sitting before an anchored plain-form
operation leave the whole command unscanned (the colon form does scan past them, fail closed).

THE ADDED LAYER: git-hooks/pre-push scans what a push sends from a public
repo (message, identities, paths, added lines, tags, notes), however bash
built it. It is a layer on top of these items, not a replacement: every item
below is built as before wherever the hook is installed.

ITEMS, for every unbypassed command:
  - ("the command text", cmd): the WHOLE text, over-arm on purpose (it covers
    `-m`, heredoc and here-string bodies, `--body`, `--title`, `gh api -f
    body=…`), once per distinct directory, when a `git commit|tag|notes`
    (global options before the subcommand skipped) or any non-exempt `gh`
    command is present. A read-only `gh` command (`gh_text_exempt`: the read
    verbs of `pr`/`issue`/`run`/`repo`/`release`/`gist` in
    `GH_READ_SUBCOMMANDS`, `gh api` with a GET method, and bare/help-only
    `gh`) is skipped only under the closed-text rule — no `VAR=` assignment
    in its prefix and no `--web`/`--hostname`/`-H` flag; anything else keeps
    the text. A `git commit|tag|notes` command whose directory
    `commit_text_owner(d)` accepts adds no item either: private-term-guard
    passes lib/prepush_state.py's `text_owner_judge` there, handing the
    commit text to the enforcing pre-push (None, the default, keeps the item,
    as session-url-gate does).
  - ("file <f>", contents): a body read from a file: `git commit|tag|notes
    -F <f>` / `--file <f>` / `--file=<f>` (also inside a short cluster such as
    `-aF f`); for `gh`: `--body-file <f>`, `--notes-file <f>`, `-F <f>` (not
    on `gh api`), and on `gh api` a `-F`/`--field` value `key=@<f>` or
    `--input <f>`; `gh gist create|edit`: every positional file and
    `edit --add <f>`. `-` means stdin, i.e. the command text. `$NAME` and
    `${NAME}` in `<f>` (and in git `-C` and `gh repo create --source`) expand
    from `PWD`, `OLDPWD`, simple assignments in the command text and the
    environment before `~`, and a relative path resolves against the tracked
    directory (`cd ~` and `cd ~/x` expand HOME). At most 4 MiB is read; an
    unreadable file or a path still holding `$` yields nothing.
  - ("commit <sha> <subject>", subject + "\\n" + body): the messages of the
    commits a `git push` sends. Sources are the source side of each refspec
    (`foo`, `+foo:bar`, `HEAD:refs/…`; a delete `:dst` has none), else HEAD;
    `--all`/`--mirror` read every local branch and `--tags` every tag. The
    scan is `git log <sources> --not --remotes`, so commits already on any
    remote yield nothing. A refspec with `$`, a backtick or a glob reads as
    HEAD. `gh repo create … --push` scans HEAD in the repo directory
    (`--source <dir>` if given, else the tracked directory).
  - ("staged <path>", line): each line lib/commit_diff.py's `commit_lines`
    reports for a `git commit`, `git add`/`git stage` earlier in the same
    command tracked as there (an add is tracked even with a bypass prefix:
    the bypass belongs to the commit).
  - ("commit <sha> <path>", line): each added line of the pushed commits
    (same sources as the message scan), from commit_diff's
    `pushed_added_lines`.
  - ("push refspec", name): the destination of each literal refspec of a
    `git push`, as a short name (refs/heads/, refs/tags/, refs/notes/ stripped,
    as the pre-push scans it), so a new remote ref's name is seen before git
    runs: `dst` of `src:dst` or `+src:dst`, else the word itself. A `:name`
    deletion, the remote, and every name of a push that deletes are not names;
    a push deletes when --delete (or -d in a cluster) appears anywhere, the last
    of it and --no-delete winning. Only the words the command spells: `-u origin
    HEAD`, a bare `git push` and `--tags` name refs only git knows (the pre-push
    checks those). Where the pre-push owns the text (`commit_text_owner` says
    so: lib/prepush_state.py's text_owner_judge), this item stands down: the
    pre-push reads the new refs.

KNOWN GAPS (accepted): a body read through a substitution or non-plain
parameter expansion (`--body "$(cat f)"`, `-F "${f:-x}"`, or an unset/masked
variable), a file written earlier by another tool call and read by a wrapper
script, a subshell's `cd` keeping the moved directory alongside the entry
directory (and state forks past `MAX_WORLDS = 64` dropped), a function body's
`cd` walked as though the function ran at its definition, an unquoted empty
expansion that vanishes from `cd`'s words (`cd $UNSET ../x`) read as two
arguments so nothing moves, and `git push` of
refs that git log cannot resolve (skipped). A push's ref names that are not
literal refspecs (`-u origin HEAD`, a bare `git push`, `--tags`: the branch or
tag name is git's to resolve) are checked by the pre-push, not here. Where the
pre-push owns the text, the refspec item stands down, so an update of an
existing term-named ref passes there too, and a new one is the pre-push's to
refuse; where the text guard keeps the text, it cannot see the remote and
blocks an update of an existing term-named ref as well. The way out: delete
the ref, or the owner's `SYG_ALLOW_PRIVATE_TERM=1` on the push. Stdin redirects: `-F - < f`,
`--body-file - < f`, `cat f | gh … --body-file -`. Annotated tag messages on
push. commit_diff's own gaps for the staged lines (content written earlier in
the same command does not exist yet when a PreToolUse hook runs) and pushed
lines (a merge commit's own changes are not shown without `-m`; log output
past 4 MiB is not read). `--git-dir`/`--work-tree` and `GIT_DIR` are not
followed.

`prepush_bypasses(cmd, cwd, bypass_assignment, dir_filter)` lists the tokens
that would get a push past the pre-push hook (its docstring has the list);
session-url-gate.sh and private-term-guard.sh block them where the hook
enforces (lib/prepush_state.py's `enforcing_judge`). Its KNOWN GAPS:
`.git/config` (or a file it includes) edited by a non-git tool; `HOME`,
`XDG_CONFIG_HOME` or `PATH` changed by an earlier `export` (only a push's own
prefix is read); `git update-ref --stdin`.

No top-level side effects: importing this module runs nothing.
"""

import os
import re
import subprocess
from collections import namedtuple

from shell_quotes import (command_pipelines, strip_redirections, substitution_spans,
                          unwrap_runners)
from shell_state import State, do_cd, do_popd, do_pushd, expand_vars, walk
import commit_diff
from prepush_scan import short_ref

Item = namedtuple("Item", "label text directory kind sha")

MAX_FILE = 4 * 1024 * 1024
FILE_SUBCOMMANDS = ("commit", "tag", "notes")
_BUILTIN_RUNNERS = {"builtin", "command"}
_STATES_CACHE = []

# git global options that take a separate value word: commit_diff's set, so
# both parsers find the same subcommand.
GIT_VALUE_OPTS = {"-C"} | commit_diff.GIT_VAL_GLOBAL


class _WalkCtx:
    def __init__(self):
        self.visited = set()
        self.leftovers = []


def _states_by_command(cmd, cwd):
    start = cwd or "."
    if _STATES_CACHE and _STATES_CACHE[0][0] == (cmd, start):
        return _STATES_CACHE[0][1]
    by_command = {}
    by_seen = {}
    all_states = []
    all_seen = set()

    def _record_all(st):
        k = st._key()
        if k not in all_seen:
            all_seen.add(k)
            all_states.append(st.copy())

    def _run(argv, state, _ctx):
        _record_all(state)
        key = tuple(argv)
        bucket = by_command.setdefault(key, [])
        seen = by_seen.setdefault(key, set())
        k = state._key()
        if k not in seen:
            seen.add(k)
            bucket.append(state.copy())
        unwrapped, info = unwrap_runners(argv)
        if unwrapped and set(info["runners"]) <= _BUILTIN_RUNNERS:
            name = unwrapped[0]
            args = strip_redirections(unwrapped[1:])
            if name == "cd":
                do_cd(state, args)
            elif name == "pushd":
                do_pushd(state, args)
            elif name == "popd":
                do_popd(state, args)
        _record_all(state)

    init = State(start, payload_cwd=start)
    _record_all(init)
    walk(cmd, 0, init, _WalkCtx(), _run)
    res = (by_command, all_states)
    _STATES_CACHE[:] = [((cmd, start), res)]
    return res


def join_dir(base, rel, state=None):
    if not rel:
        return base
    if state is not None:
        rel = expand_vars(rel, state)
    rel = os.path.expanduser(rel)
    return rel if os.path.isabs(rel) else os.path.join(base, rel)


def git_parts(argv, base, state=None):
    """(subcommand, args after it, directory after -C options) for a git
    argv, or None when there is no subcommand."""
    directory = base
    i = 1
    while i < len(argv):
        w = argv[i]
        if w == "-C" and i + 1 < len(argv):
            directory = join_dir(directory, argv[i + 1], state=state)
            i += 2
        elif w in GIT_VALUE_OPTS:
            i += 2
        elif w.startswith("-"):
            i += 1
        else:
            return w, argv[i + 1:], directory
    return None


def is_git_long(word, name, floor):
    """True when `word` is the long option `name` (given with its `--`) as git
    reads it: the whole name, or a prefix of at least `floor` characters (the
    `--` counts) that git takes as the option, since git accepts any unique
    prefix of a long option. An `=value` tail is not part of the name."""
    opt = word.split("=", 1)[0]
    return opt.startswith("--") and len(opt) >= floor and name.startswith(opt)


# The floors are the shortest prefix git reads as each option, measured on git
# commit, tag and notes add (`git <cmd> --<prefix>`: "ambiguous" or "unknown
# option" means it is not read). A floor is the minimum over those commands,
# so a prefix git rejects as ambiguous on one of them is read here too; git
# then errors out on that command, which is harmless. --file's floor is 4:
# `--fi` is ambiguous on commit (--fixup) and read as --file on tag and notes.
GIT_FILE_OPT = ("--file", 4)
GIT_VALUE_LONG = (("--message", 3), ("--reuse-message", 5), ("--reedit-message", 5),
                  ("--fixup", 5), ("--squash", 4), ("--author", 4), ("--date", 4),
                  ("--cleanup", 3), ("--template", 4), ("--trailer", 4))


def file_values_git(args):
    """Files named by -F / --file in a git commit|tag|notes argument list.
    Short clusters are read the way git reads them: a value letter takes the
    rest of the word, else the next word. A long option may be spelled by any
    prefix git accepts (is_git_long); a value option spelled that way still
    takes its value word."""
    out = []
    i = 0
    while i < len(args):
        w = args[i]
        if w == "--":
            break
        if is_git_long(w, *GIT_FILE_OPT):
            if "=" in w:
                out.append(w.split("=", 1)[1])
            elif i + 1 < len(args):
                out.append(args[i + 1])
                i += 1
        elif w.startswith("-") and not w.startswith("--") and len(w) > 1:
            j = 1
            while j < len(w):
                c = w[j]
                if c in "mCcFt":
                    value = w[j + 1:] or (args[i + 1] if i + 1 < len(args) else "")
                    if c == "F":
                        out.append(value)
                    if not w[j + 1:]:
                        i += 1
                    break
                if c in "Su":  # optional attached value only
                    break
                j += 1
        elif w.startswith("--") and "=" not in w and any(
                is_git_long(w, name, floor) for name, floor in GIT_VALUE_LONG):
            i += 1
        i += 1
    return out


GIST_VALUE_OPTS = {"-d", "--desc", "--description", "-f", "--filename"}


def file_values_gist(argv):
    """Files named by `gh gist create|edit`: every positional (for edit the
    first is the gist id, read as a file only if such a path exists) and
    `edit --add <f>`."""
    out = []
    i = 3
    while i < len(argv):
        w = argv[i]
        if w in ("-a", "--add"):
            if i + 1 < len(argv):
                out.append(argv[i + 1])
            i += 1
        elif w.startswith("--add="):
            out.append(w[len("--add="):])
        elif w in GIST_VALUE_OPTS:
            i += 1
        elif w.startswith("-") and w != "-":
            pass
        else:
            out.append(w)
        i += 1
    return out


def repo_create_push_dir(argv, base, state=None):
    """Directory to scan for `gh repo create … --push`, else None."""
    if len(argv) < 3 or argv[1] != "repo" or argv[2] != "create":
        return None
    if "--push" not in argv[3:]:
        return None
    source = ""
    i = 3
    while i < len(argv):
        w = argv[i]
        if w in ("-s", "--source") and i + 1 < len(argv):
            source = argv[i + 1]
            i += 1
        elif w.startswith("--source="):
            source = w[len("--source="):]
        i += 1
    return join_dir(base, source, state=state)


GH_GLOBAL_VALUE_OPTS = {
    "-R", "--repo", "--hostname", "--json", "-q", "--jq", "-t", "--template",
}
GH_API_VALUE_OPTS = GH_GLOBAL_VALUE_OPTS | {"--header", "--cache", "--preview"}
GH_READ_SUBCOMMANDS = {
    "pr": {"view", "list", "checks", "status", "diff"},
    "issue": {"view", "list", "status"},
    "run": {"view", "list", "watch"},
    "repo": {"view"},
    "release": {"view", "list"},
    "gist": {"view", "list"},
}


def gh_is_read(argv):
    """True when a `gh` argv is provably a read (publishes nothing); anything
    unrecognized returns False (fail closed)."""
    words = strip_redirections(argv[1:])
    pos = []
    i = 0
    n = len(words)
    while i < n and len(pos) < 2:
        w = words[i]
        if w == "--":
            pos.extend(words[i + 1: i + 1 + (2 - len(pos))])
            break
        if w in GH_GLOBAL_VALUE_OPTS:
            i += 2
            continue
        if "=" in w and w.split("=", 1)[0] in GH_GLOBAL_VALUE_OPTS:
            i += 1
            continue
        if w.startswith("-"):
            # Once the group word is found, any non-global flag before the verb
            # returns False: under Cobra's stripFlags an unknown `--long` flag
            # swallows the next word (`gh pr --body view create` runs `create`),
            # so requiring only known global options between group and verb is
            # conservative (fail-closed) under either parser convention.
            if pos:
                return False
            i += 1
            continue
        pos.append(w)
        i += 1
        if len(pos) == 1 and pos[0] == "api":
            break
    if not pos:
        return True
    sub = pos[0]
    if sub in GH_READ_SUBCOMMANDS:
        return len(pos) >= 2 and pos[1] in GH_READ_SUBCOMMANDS[sub]
    if sub != "api":
        return False
    methods = []
    has_field = False
    i = 0
    while i < n:
        w = words[i]
        nxt = words[i + 1] if i + 1 < n else ""
        if w in ("-X", "--method"):
            methods.append(nxt)
            i += 1
        elif w.startswith("--method="):
            methods.append(w[len("--method="):])
        elif w in ("-f", "--raw-field", "-F", "--field", "--input"):
            has_field = True
            i += 1
        elif w.startswith(("--raw-field=", "--field=", "--input=")):
            has_field = True
        elif w in GH_API_VALUE_OPTS:
            i += 1
        elif w.startswith("-") and not w.startswith("--") and len(w) > 1:
            j = 1
            while j < len(w):
                c = w[j]
                if c in "FHqXpftR":
                    rest = w[j + 1:]
                    val = rest[1:] if rest.startswith("=") else (rest or nxt)
                    if c == "X":
                        methods.append(val)
                    elif c in "fF":
                        has_field = True
                    if not rest:
                        i += 1
                    break
                j += 1
        i += 1
    if methods:
        return all(m.upper() == "GET" for m in methods)
    return not has_field


# The closed-text rule's forbidden gh flags: `--web`, `--hostname` (its value
# either way) and `-H` (alone or inside a short cluster; on `gh api` the same
# spelling is --header — still not exempt, fail closed) can aim the command
# outside the read the verb promises.
_GH_TEXT_EXEMPT_FLAGS = ("--web", "--hostname")
_ASSIGN_WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")


def gh_text_exempt(argv, prefix):
    """True when a `gh` command's text is not scanned: a read command
    (`gh_is_read`) whose prefix carries no `VAR=` assignment (an assignment
    can change what gh runs or reads) and whose words carry none of the
    closed-text flags. Fail closed: any other shape keeps the whole text.
    `gh api` GET calls without a forbidden flag stay exempt as before."""
    if any(_ASSIGN_WORD.match(w) for w in prefix):
        return False
    for w in argv[1:]:
        if any(w == f or w.startswith(f + "=") for f in _GH_TEXT_EXEMPT_FLAGS):
            return False
        if w.startswith("-") and not w.startswith("--") and len(w) > 1 and "H" in w:
            return False
    return gh_is_read(argv)


def file_values_gh(argv):
    if len(argv) > 2 and argv[1] == "gist" and argv[2] in ("create", "edit"):
        return file_values_gist(argv)
    is_api = len(argv) > 1 and argv[1] == "api"
    out = []
    i = 1
    n = len(argv)
    while i < n:
        w = argv[i]
        nxt = argv[i + 1] if i + 1 < n else ""
        if is_api:
            field = None
            if w in ("-F", "--field"):
                field, i = nxt, i + 1
            elif w.startswith("--field="):
                field = w[len("--field="):]
            elif w.startswith("-F") and len(w) > 2:
                field = w[2:]
            if field is not None and "=@" in field:
                out.append(field.split("=@", 1)[1])
            if w == "--input":
                out.append(nxt)
                i += 1
            elif w.startswith("--input="):
                out.append(w[len("--input="):])
        else:
            if w in ("--body-file", "--notes-file", "-F"):
                out.append(nxt)
                i += 1
            elif w.startswith("--body-file="):
                out.append(w[len("--body-file="):])
            elif w.startswith("--notes-file="):
                out.append(w[len("--notes-file="):])
            elif w.startswith("-F") and not w.startswith("--") and len(w) > 2:
                out.append(w[2:])
        i += 1
    return out


GH_WRAPPER_SUBCOMMANDS = frozenset(GH_READ_SUBCOMMANDS) | {"api"}


def _gh_wrapper_argv(argv):
    """`(gh_argv, skipped)` when `SYG_GH_WRAPPERS` is set, `argv` begins with
    that whitespace-separated token sequence (`wrappers[0]` compared by
    basename against the basename of `argv[0]` and the remaining tokens
    verbatim), and either the plain two-word form (`<subcommand> <word>` with
    `<subcommand>` in `GH_WRAPPER_SUBCOMMANDS`) sits immediately after the
    wrapper tokens (or immediately after a literal `gh` word there) or a word
    after the wrapper tokens matches the colon form (`gh:<rest>`, split on the
    first `-`); `skipped` is True when intervening words sit between the
    wrapper-token prefix and the matched `gh` operation; else `(None, False)`."""
    try:
        wrappers = os.environ.get("SYG_GH_WRAPPERS", "").split()
        n = len(wrappers)
        if not wrappers or len(argv) <= n:
            return None, False
        if argv[0].rsplit("/", 1)[-1] != wrappers[0].rsplit("/", 1)[-1] or argv[1:n] != wrappers[1:]:
            return None, False
        plain = n + 1 if argv[n] == "gh" else n
        if plain + 1 < len(argv) and argv[plain] in GH_WRAPPER_SUBCOMMANDS:
            return ["gh"] + argv[plain:], False
        for i in range(n, len(argv)):
            w = argv[i]
            if w.startswith("gh:"):
                rest = w[3:]
                if rest:
                    return ["gh"] + rest.split("-", 1) + argv[i + 1:], i > n
    except Exception:
        return None, False
    return None, False


def read_file(path, directory, state=None):
    """Decoded contents (at most MAX_FILE bytes), or None."""
    if not path or path == "-":
        return None
    expanded = expand_vars(path, state) if state is not None else path
    if "$" in expanded:
        return None
    try:
        with open(join_dir(directory, path, state=state), "rb") as fh:
            data = fh.read(MAX_FILE)
    except OSError:
        return None
    return data.decode("utf-8", "replace")


# git push's long options (floors as in GIT_VALUE_LONG): --all, --mirror and
# --branches read every local branch, --tags every tag, and the value options
# take their value word.
PUSH_BRANCH_LONG = (("--all", 4), ("--mirror", 3), ("--branches", 3))
PUSH_VALUE_LONG = (("--push-option", 4), ("--receive-pack", 6), ("--exec", 3), ("--repo", 5))


def _push_takes_value(w):
    """True when a git push word takes the next word as its value."""
    return w == "-o" or ("=" not in w and any(
        is_git_long(w, name, floor) for name, floor in PUSH_VALUE_LONG))


# git push's --delete (floor 4: "--de"); --no-delete's floor is 7 ("--no-de":
# "--no-d" is ambiguous with --no-dry-run), measured on git 2.55.0.
PUSH_DELETE_LONG = ("--delete", 4)
PUSH_NO_DELETE_LONG = ("--no-delete", 7)


def _push_short(w):
    """`(delete, takes_value)` for a single-dash git push word. It walks the
    letters: `d` is --delete; `o` (--push-option) takes the rest of the word or
    the next word as its value, so the walk stops there (`-od` is -o with the
    value `d`, not a delete; `-fo x` takes x)."""
    delete = False
    for j in range(1, len(w)):
        c = w[j]
        if c == "d":
            delete = True
        elif c == "o":
            return delete, j == len(w) - 1
    return delete, False


def _push_scan(args):
    """`(positionals, deleting)` for a git push's arguments: the positional
    words in order (index 0 is the remote), option values skipped. git permutes
    options, so --delete (or -d, in a cluster) counts wherever it stands; the
    last of --delete and --no-delete wins."""
    positionals = []
    deleting = False
    i = 0
    while i < len(args):
        w = args[i]
        if is_git_long(w, *PUSH_NO_DELETE_LONG):
            deleting = False
        elif is_git_long(w, *PUSH_DELETE_LONG):
            deleting = True
        elif w.startswith("--"):
            if _push_takes_value(w):
                i += 1
        elif w.startswith("-") and len(w) > 1:
            delete, takes_value = _push_short(w)
            deleting = deleting or delete
            if takes_value:
                i += 1
        elif not w.startswith("-"):
            positionals.append(w)
        i += 1
    return positionals, deleting


def push_destinations(args):
    """The destination names of a git push's literal refspecs, as the
    pre-push scans them: `dst` of `src:dst` or `+src:dst`, else the word itself
    (its own destination), with refs/heads/, refs/tags/ and refs/notes/
    stripped. A `:name` deletion, the remote, and every name of a push that
    deletes (--delete anywhere; see _push_scan) are not new names. `src:` (an
    empty destination) names src."""
    positionals, deleting = _push_scan(args)
    if deleting:
        return []
    out = []
    for word in positionals[1:]:  # positionals[0] is the remote
        ref = word[1:] if word.startswith("+") else word
        src, sep, dst = ref.partition(":")
        if sep and not src:
            continue  # a :name deletion
        name = short_ref((dst or src) if sep else ref)
        if name:
            out.append(name)
    return out


def push_sources(args):
    sources = []
    extra = []
    positionals = []
    i = 0
    while i < len(args):
        w = args[i]
        if any(is_git_long(w, name, floor) for name, floor in PUSH_BRANCH_LONG):
            extra.append("--branches")
        elif is_git_long(w, "--tags", 4):
            extra.append("--tags")
        elif _push_takes_value(w):
            i += 1
        elif w.startswith("-"):
            pass
        else:
            positionals.append(w)
        i += 1
    for ref in positionals[1:]:  # positionals[0] is the remote
        ref = ref[1:] if ref.startswith("+") else ref
        src = ref.split(":", 1)[0]
        if ":" in ref and not src:
            continue  # a delete
        if re.search(r"[$`*?\[\]\s]", src) or src.startswith("-"):
            src = "HEAD"
        sources.append(src)
    if not sources and not extra and len(positionals) < 2:
        sources = ["HEAD"]
    return sources + extra


def pushed_messages(sources, directory):
    """(sha_short, subject, body) for each unpushed commit reachable from
    `sources`, each commit once."""
    out = []
    seen = set()
    for src in dict.fromkeys(sources):
        try:
            res = subprocess.run(
                ["git", "-C", directory, "log", "--format=%x01%h%x02%s%x02%B",
                 src, "--not", "--remotes"],
                capture_output=True, timeout=20)
        except (OSError, subprocess.SubprocessError):
            continue
        if res.returncode != 0:
            continue
        for rec in res.stdout.decode("utf-8", "replace").split("\x01"):
            if not rec.strip():
                continue
            parts = rec.split("\x02", 2)
            if len(parts) < 3 or parts[0] in seen:
                continue
            seen.add(parts[0])
            out.append((parts[0], parts[1], parts[2]))
    return out


def all_pipelines(text, depth=0):
    result = list(command_pipelines(text))
    if depth < 2:
        for span in substitution_spans(text):
            result.extend(all_pipelines(span, depth + 1))
    return result


def _refspec_items(args, directory):
    """Text items for the destination names of a push's literal refspecs (the
    short names, see push_destinations), so a term in a new remote ref's name
    is seen before git runs. The label is the constant `push refspec`, not the
    name: session-url-gate prints the label of a hit, and the name is not to be
    printed; the text carries the name, and dedupe keys on it."""
    return [Item("push refspec", name, directory, "text", None)
            for name in push_destinations(args)]


def _push_items(sources, directory):
    items = []
    for sha, subject, body in pushed_messages(sources, directory):
        items.append(Item(f"commit {sha} {subject}", subject + "\n" + body, directory,
                          "commit-message", sha))
    for sha, _subject, path, line in commit_diff.pushed_added_lines(directory, sources):
        items.append(Item(f"commit {sha} {path}", line, directory, "commit-diff", sha))
    return items


_GIT_CONFIG_ENV = "GIT_CONFIG_(?:COUNT|PARAMETERS|GLOBAL|SYSTEM)"
_ENV_ASSIGN = re.compile(r"(?<![A-Za-z0-9_$])(" + _GIT_CONFIG_ENV + r")(?:\[[^\]]*\])?\+?="
                         r"|\$\{(" + _GIT_CONFIG_ENV + r"):=")
_ENV_DECLARE = re.compile(
    r"(?<![A-Za-z0-9_])(?:export|declare|typeset|readonly|local|read|mapfile|readarray|printf)"
    r"(?![A-Za-z0-9_])[^;&|\n]*?(?<![A-Za-z0-9_${])(" + _GIT_CONFIG_ENV + r")(?![A-Za-z0-9_])")
HOOKS_PATH_KEY = "core.hookspath"


def _redirecting_key(key):
    """`key` (any case) changes what the pre-push does: core.hooksPath, an
    include that can set it, the seyag.publicRepo flag, the
    seyag.privateTermsFile path, or a git alias (`alias.*`)."""
    k = key.lower()
    return (k in (HOOKS_PATH_KEY, "include.path", "seyag.publicrepo", "seyag.privatetermsfile")
            or k.startswith(("includeif.", "alias.")))


def _key_label(key):
    k = key.lower()
    for prefix, label in (("includeif.", "includeIf"), ("alias.", "alias.*")):
        if k.startswith(prefix):
            return label
    return {HOOKS_PATH_KEY: "core.hooksPath", "include.path": "include.path",
            "seyag.publicrepo": "seyag.publicRepo",
            "seyag.privatetermsfile": "seyag.privateTermsFile"}[k]


# Sections whose removal or rename changes the pre-push: core (hooksPath)
# and seyag (publicRepo, privateTermsFile).
GUARDED_SECTIONS = {"core", "seyag"}


# git config: options taking a separate value word; read and write actions;
# the subcommand words of the newer `git config <verb>` form.
CONFIG_VALUE_OPTS = {"-f", "--file", "--blob", "--type", "--default", "--comment",
                     "--value", "--url"}
CONFIG_WRITE_FLAGS = {"--unset", "--unset-all", "--replace-all", "--add"}
CONFIG_READ_FLAGS = {"--get", "--get-all", "--get-regexp", "--get-urlmatch", "-l", "--list",
                     "--get-color", "--get-colorbool"}
CONFIG_VERBS = {"list", "get", "set", "unset", "rename-section", "remove-section", "edit"}


def _git_config_tokens(rest):
    """`(tokens, scope)` for one `git config` argument list. Tokens:
    `-e/--edit` (or the `edit` verb); `--remove-section`/`--rename-section`
    (or the verbs) of the core or seyag section; and a WRITE to a
    `_redirecting_key`: `set`/`unset` verbs, `--unset`, `--unset-all`,
    `--replace-all`, `--add`, or the classic `git config <key> <value>`. A
    read (`--get…`, `--list`, `get`, a bare `<key>`) passes. `scope` says
    which config the command touches, so the caller judges it there:
    "global" (`--global`, `--system`), ("file", f) (`--file f`, `-f f`,
    `--file=f`), else "dir" (the repo the command runs in)."""
    verb = rest[0] if rest and rest[0] in CONFIG_VERBS else None
    words = rest[1:] if verb else rest
    flags, positionals, i = set(), [], 0
    scope = "dir"
    while i < len(words):
        w = words[i]
        if w in ("-f", "--file") and i + 1 < len(words):
            scope = ("file", words[i + 1])
        elif w.startswith("--file="):
            scope = ("file", w[len("--file="):])
        if w in CONFIG_VALUE_OPTS:
            i += 2
            continue
        if w.startswith("-"):
            flags.add(w.split("=", 1)[0])
        else:
            positionals.append(w)
        i += 1
    if scope == "dir" and flags & {"--global", "--system"}:
        scope = "global"
    if verb == "edit" or "-e" in flags or "--edit" in flags:
        return ["git config --edit"], scope
    section_op = verb in ("rename-section", "remove-section") or \
        flags & {"--rename-section", "--remove-section"}
    if section_op:
        if positionals and positionals[0].lower() in GUARDED_SECTIONS:
            return [f"git config remove/rename of section {positionals[0].lower()}"], scope
        return [], scope
    if not positionals or not _redirecting_key(positionals[0]):
        return [], scope
    label = f"git config write of {_key_label(positionals[0])}"
    if verb in ("set", "unset") or flags & CONFIG_WRITE_FLAGS:
        return [label], scope
    if verb is None and not flags & CONFIG_READ_FLAGS and len(positionals) >= 2:
        return [label], scope
    return [], scope


def _config_file_owner(path):
    """The repo a config file belongs to: walking up from the file, the
    parent of a `.git` directory, a directory holding `.git`, or a bare git
    dir (HEAD, objects/ and config side by side); None when there is none."""
    d = os.path.dirname(os.path.abspath(path))
    while True:
        if os.path.basename(d) == ".git":
            return os.path.dirname(d)
        if os.path.exists(os.path.join(d, ".git")):
            return d
        if all(os.path.exists(os.path.join(d, n)) for n in ("HEAD", "objects", "config")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def _global_config_paths():
    """The files `git config --global` reads and writes, resolved."""
    if os.environ.get("GIT_CONFIG_GLOBAL"):
        return {os.path.realpath(os.environ["GIT_CONFIG_GLOBAL"])}
    home = os.environ.get("HOME", "")
    xdg = os.environ.get("XDG_CONFIG_HOME") or os.path.join(home, ".config")
    return {os.path.realpath(os.path.join(home, ".gitconfig")),
            os.path.realpath(os.path.join(xdg, "git", "config"))}


PUSH_ENV_KEYS = ("HOME", "XDG_CONFIG_HOME")


def _push_env_tokens(prefix):
    """Tokens in a git push's own prefix that swap the global config out:
    a `HOME=`/`XDG_CONFIG_HOME=` assignment, `env -i` (`-`,
    `--ignore-environment` and any abbreviation down to `--i`; unambiguous
    on coreutils before 9.1, while from 9.1 the forms shorter than
    `--ignore-e` are ambiguous and rejected, matched anyway, fail closed),
    or `env -u HOME`
    (`-uHOME`, `--unset HOME`, `--unset=HOME`, or a `--u…` abbreviation of
    `--unset` in either form)."""
    tokens = []
    for j, w in enumerate(prefix):
        nxt = prefix[j + 1] if j + 1 < len(prefix) else ""
        after_env = "env" in prefix[:j]
        opt, has_value, value = w.partition("=")
        if any(w.startswith(k + "=") for k in PUSH_ENV_KEYS):
            tokens.append(f"{w.split('=', 1)[0]}= on a push")
        elif after_env and (w in ("-i", "-") or (
                len(w) >= len("--i") and "--ignore-environment".startswith(w))):
            tokens.append("env -i on a push")
        elif after_env and (
                (w == "-u" and nxt in PUSH_ENV_KEYS)
                or w in tuple("-u" + k for k in PUSH_ENV_KEYS)
                or (len(opt) >= len("--u") and "--unset".startswith(opt)
                    and (value if has_value else nxt) in PUSH_ENV_KEYS)):
            tokens.append("env -u HOME on a push")
    return tokens


def _past_env_operands(raw, argv):
    """`argv` (unwrap_runners' result for `raw`) stepped past what it leaves
    of env's own arguments: a lone `-` (GNU env's `-i`), and the value of an
    abbreviated `--unset` (`--uns HOME`), which unwrap_runners reads as the
    program. Each step re-unwraps the rest. A `git` word is never stepped
    past as such a value (`env --un git push --no-verify` stays a git
    command: strictness over fidelity, the base reading)."""
    while argv:
        prefix = raw[: len(raw) - len(argv)]
        if "env" not in prefix:
            break
        last = prefix[-1] if prefix else ""
        if argv[0] == "-" or (len(last) >= len("--u") and last != "--unset"
                              and "--unset".startswith(last)
                              and argv[0].rsplit("/", 1)[-1] != "git"):
            argv, _ = unwrap_runners(argv[1:])
        else:
            break
    return argv


def _git_bypass_tokens(argv, prefix=()):
    """The pre-push bypass tokens in one git argv (`prefix`: its assignment
    and runner words): `-c`/`--config-env` setting a `_redirecting_key` (any
    subcommand); the `git config` writes, edits and section operations of
    `_git_config_tokens`; `git update-ref` of a `refs/remotes/…` ref (a
    forged remote-tracking ref hides commits from the scan); and on `push` a
    `--no-verify` or a prefix git accepts for it, down to `--no-v` (push's
    `-n` is `--dry-run`: it passes), an argument holding `$` or a backtick,
    and the `_push_env_tokens` of its prefix; any `git send-pack` (it pushes
    without running pre-push). Returns `[(token, scope)]`, scope as
    `_git_config_tokens` gives it ("dir" for every non-config token)."""
    tokens = []
    i, sub, rest = 1, None, []
    while i < len(argv):
        w = argv[i]
        if w in ("-c", "--config-env") and i + 1 < len(argv):
            key = argv[i + 1].split("=", 1)[0]
            if _redirecting_key(key):
                tokens.append(f"{w} {_key_label(key)}")
            i += 2
        elif w.startswith("--config-env="):
            key = w[len("--config-env="):].split("=", 1)[0]
            if _redirecting_key(key):
                tokens.append(f"--config-env {_key_label(key)}")
            i += 1
        elif w == "-C" or w in commit_diff.GIT_VAL_GLOBAL:
            i += 2
        elif w.startswith("-"):
            i += 1
        else:
            sub, rest = w, argv[i + 1:]
            break
    found = [(t, "dir") for t in tokens]
    if sub == "config":
        config_tokens, scope = _git_config_tokens(rest)
        found.extend((t, scope) for t in config_tokens)
    if sub == "send-pack":
        found.append(("git send-pack", "dir"))
    if sub == "update-ref" and any(w.startswith("refs/remotes/") for w in rest):
        found.append(("git update-ref refs/remotes/", "dir"))
    if sub == "push":
        for w in rest:
            if "$" in w or "`" in w:
                found.append(("a push argument holding $ or a backtick", "dir"))
            if w == "--":
                continue
            if len(w) >= len("--no-v") and "--no-verify".startswith(w):
                found.append(("--no-verify", "dir"))
        found.extend((t, "dir") for t in _push_env_tokens(list(prefix)))
    return found


def bypass_block_message(tokens, bypass_assignment):
    """The block message both outbound guards print for prepush_bypasses
    tokens (fixed strings only, never user text)."""
    return (f"blocked: {', '.join(tokens)} would get a push past the seyag pre-push "
            "check (git-hooks/pre-push), which is in force for this public repo.\n"
            "Drop it. Only on the owner's word: prefix the command itself with "
            f"{bypass_assignment}.")


def prepush_bypasses(cmd, cwd, bypass_assignment=None, dir_filter=None, global_filter=None):
    """Tokens in `cmd` that would get a push past git-hooks/pre-push, for the
    commands whose own prefix lacks `bypass_assignment`: the git tokens of
    `_git_bypass_tokens`; and anywhere in the text an assignment (`NAME=`,
    `NAME+=`, `${NAME:=…}`) or an export/declare/read/printf mention of
    GIT_CONFIG_COUNT, GIT_CONFIG_PARAMETERS, GIT_CONFIG_GLOBAL or
    GIT_CONFIG_SYSTEM. That text-wide scan always runs; a `NAME=` match is
    waived only when it is an assignment in the prefix of a command whose own
    prefix carries the bypass (`BYPASS GIT_CONFIG_GLOBAL=x git push`,
    `_in_bypassed_prefix`); every other match counts, a bypass elsewhere in
    the text notwithstanding. Each token once, in order.

    Each token counts only where the hook is in force (both filters None:
    everywhere). The guards pass lib/prepush_state.py's `enforcing_judge` as
    `dir_filter` and `global_install_present` as `global_filter`. A token's
    scope picks the judge: a git command's own directory (`dir_filter`); a
    `git config --global|--system` write, or `--file` of a global config
    file, by `global_filter()` (whatever the cwd); `--file <f>` by the repo
    that owns f (`dir_filter(owner)`; no owning repo: not counted); the
    GIT_CONFIG_* matches by `dir_filter(cwd)`, asked only after a match."""
    tokens = []
    base_dir = cwd or "."
    dir_exists = {}
    verdicts = {}

    def exists(d):
        if d not in dir_exists:
            dir_exists[d] = os.path.isdir(d)
        return dir_exists[d]

    def dir_wanted(d):
        if dir_filter is None:
            return False
        key = d if exists(d) else base_dir
        if key not in verdicts:
            verdicts[key] = bool(dir_filter(key))
        return verdicts[key]

    def counts(scope, gdir, state=None):
        if dir_filter is None and global_filter is None:
            return True
        if scope == "global":
            return bool(global_filter and global_filter())
        if isinstance(scope, tuple):
            path = join_dir(gdir, scope[1], state=state)
            if os.path.realpath(path) in _global_config_paths():
                return bool(global_filter and global_filter())
            owner = _config_file_owner(path)
            return bool(owner and dir_wanted(owner))
        if state is not None and state.unknown:
            return True
        return dir_wanted(gdir)

    by_command, all_states = _states_by_command(cmd, cwd)
    bypass_raws = []  # the commands that carry the bypass in their own prefix
    for pipeline in all_pipelines(cmd):
        for raw in pipeline:
            unwrapped, _ = unwrap_runners(raw)
            argv = _past_env_operands(raw, unwrapped)
            if not argv:
                continue
            prefix = raw[: len(raw) - len(argv)]
            bypassed = bypass_assignment is not None and bypass_assignment in prefix
            prog = argv[0].rsplit("/", 1)[-1]
            if bypassed:
                if _carries_bypass(raw, unwrapped, argv, bypass_assignment):
                    bypass_raws.append(raw)
                continue
            if prog == "git":
                for st in by_command.get(tuple(raw), all_states):
                    parts = git_parts(argv, st.cwd, state=st)
                    gdir = parts[2] if parts else st.cwd
                    for token, scope in _git_bypass_tokens(argv, prefix):
                        if counts(scope, gdir, st):
                            tokens.append(token)
    env_hits = [m.group(m.lastindex) for m in _ENV_ASSIGN.finditer(cmd)
                if not _in_bypassed_prefix(cmd, m, bypass_assignment, bypass_raws)]
    env_hits += [m.group(m.lastindex) for m in _ENV_DECLARE.finditer(cmd)]
    if env_hits and counts("dir", cwd or "."):
        tokens.extend(env_hits)
    return list(dict.fromkeys(tokens))


# Characters that end a simple command (shell_quotes' word separators).
_COMMAND_START = re.compile(r"[;&|\n()][^;&|\n()]*\Z")
# Text that makes the words before a match unplaceable (quoting, expansion,
# redirection, grouping, a comment).
_UNPLACEABLE = re.compile(r"""['"\\`$<>{}#]""")


def _in_bypassed_prefix(cmd, m, bypass_assignment, bypass_raws):
    """True when the `_ENV_ASSIGN` match `m` (a `NAME=` form, not
    `${NAME:=…}`) is an assignment in the prefix of a command whose own
    prefix carries `bypass_assignment` (`BYPASS=1 GIT_CONFIG_GLOBAL=x git
    push`) and that runs a program (not only redirections). The command is
    read from the last separator before the match; the words before the
    match there must hold no quote, expansion, redirection, brace or comment
    character, and must be the command's first words as the splitter reads
    them. The command read there must also be one of `bypass_raws`, the
    bypass-carrying commands the splitter found in the whole text, so text
    inside quotes, a comment or a heredoc body (which the splitter does not
    run) is never waived. Anything else is not placed: False (the match
    counts)."""
    if bypass_assignment is None or m.lastindex != 1 or not bypass_raws:
        return False
    head = cmd[: m.start()]
    sep = _COMMAND_START.search(head)
    start = sep.start() + 1 if sep else 0
    before = cmd[start: m.start()]
    if _UNPLACEABLE.search(before) or (before and before[-1] not in " \t"):
        return False
    words = before.split()
    pipelines = command_pipelines(cmd[start:])
    if not pipelines or not pipelines[0]:
        return False
    raw = pipelines[0][0]
    n = len(words)
    if raw[:n] != words or len(raw) <= n or not raw[n].startswith(m.group(0)):
        return False
    if raw not in bypass_raws:
        return False
    unwrapped, _ = unwrap_runners(raw)
    return n < len(raw) - len(unwrapped) and _carries_bypass(
        raw, unwrapped, _past_env_operands(raw, unwrapped), bypass_assignment)


def _carries_bypass(raw, unwrapped, argv, bypass_assignment):
    """`raw` carries the bypass for the GIT_CONFIG_* waiver: the bypass is in
    its prefix as unwrap_runners alone reads it (`unwrapped`: the base rule,
    so this is never wider than it), and it runs a program, not only
    redirections (`argv`, after `_past_env_operands`)."""
    return (bool(unwrapped) and bypass_assignment in raw[: len(raw) - len(unwrapped)]
            and bool(strip_redirections(argv)))


def outbound_items(cmd, cwd, bypass_assignment, dir_filter=None,
                   commit_text_owner=None):
    items = []
    text_dirs = set()
    adds = []
    by_command, all_states = _states_by_command(cmd, cwd)
    base_dir = cwd or "."
    dir_exists = {}
    verdicts = {}
    owners = {}
    staged_cache = {}
    push_cache = {}

    def exists(d):
        if d not in dir_exists:
            dir_exists[d] = os.path.isdir(d)
        return dir_exists[d]

    def wanted(d):
        if dir_filter is None:
            return True
        key = d if exists(d) else base_dir
        if key not in verdicts:
            verdicts[key] = bool(dir_filter(key))
        return verdicts[key]

    def text_owned(d):
        if commit_text_owner is None:
            return False
        key = d if exists(d) else base_dir
        if key not in owners:
            owners[key] = bool(commit_text_owner(key))
        return owners[key]

    def cached_push_items(sources, d):
        if not exists(d):
            return ()
        key = (d, tuple(sources))
        if key not in push_cache:
            push_cache[key] = _push_items(sources, d)
        return push_cache[key]

    def cached_commit_lines(d, args):
        if not exists(d):
            return ()
        key = (d, tuple(args), len(adds))  # an earlier `git add` changes the answer
        if key not in staged_cache:
            staged_cache[key] = commit_diff.commit_lines(
                d, commit_diff.parse_commit(args), adds)
        return staged_cache[key]

    def command_text(d):
        if d not in text_dirs:
            text_dirs.add(d)
            items.append(Item("the command text", cmd, d, "text", None))

    def files(names, d, state):
        for f in names:
            text = read_file(f, d, state=state)
            if text is not None:
                items.append(Item(f"file {f}", text, d, "file", None))

    for pipeline in all_pipelines(cmd):
        for raw in pipeline:
            argv, _ = unwrap_runners(raw)
            if not argv:
                continue
            prefix = raw[: len(raw) - len(argv)]
            bypassed = bypass_assignment in prefix
            prog = argv[0].rsplit("/", 1)[-1]
            states = by_command.get(tuple(raw), all_states)
            gh_argv, gh_skipped = (argv, False) if prog == "gh" else _gh_wrapper_argv(argv)
            if gh_argv is not None:
                if bypassed:
                    continue
                for st in states:
                    directory = st.cwd
                    if (st.unknown or wanted(directory)) and (
                            gh_skipped or not gh_text_exempt(gh_argv, prefix)):
                        command_text(directory)
                    if wanted(directory):
                        files(file_values_gh(gh_argv), directory, st)
                    push_dir = repo_create_push_dir(gh_argv, directory, state=st)
                    if push_dir is not None and exists(push_dir) and wanted(push_dir):
                        items.extend(cached_push_items(push_sources([]), push_dir))
                continue
            if prog != "git":
                continue
            for st in states:
                parts = git_parts(argv, st.cwd, state=st)
                if parts is None:
                    continue
                sub, args, gdir = parts
                if sub in ("add", "stage"):
                    spec = commit_diff.parse_add(args)
                    spec["dir"] = gdir
                    adds.append(spec)
                    continue
                if bypassed:
                    continue
                if sub in FILE_SUBCOMMANDS and (
                        st.unknown or (wanted(gdir) and not text_owned(gdir))):
                    command_text(gdir)
                if not wanted(gdir):
                    continue
                if sub in FILE_SUBCOMMANDS:
                    files(file_values_git(args), gdir, st)
                    if sub == "commit" and exists(gdir):
                        for path, line in cached_commit_lines(gdir, args):
                            items.append(Item(f"staged {path}", line, gdir, "staged", None))
                elif sub == "push":
                    # Where the pre-push owns the text it reads the new refs
                    # exactly (an update too); this item stands down there, on
                    # the commit text's own condition.
                    if st.unknown or not text_owned(gdir):
                        items.extend(_refspec_items(args, gdir))
                    if exists(gdir):
                        items.extend(cached_push_items(push_sources(args), gdir))
    out = []
    seen = set()
    for it in items:
        k = (it.kind, it.label, it.text, it.directory)
        if k not in seen:
            seen.add(k)
            out.append(it)
    return out
