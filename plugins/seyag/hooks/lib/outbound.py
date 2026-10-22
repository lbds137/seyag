"""What text a Bash command would send off the machine: the one walker behind
session-url-gate.sh and private-term-guard.sh.

`outbound_items(cmd, cwd, bypass_assignment, dir_filter=None)` returns
`Item(label, text, directory, kind, sha)` records; each hook matches its own
pattern over `text`. `label` names the source and can hold user text (a
commit subject, a path); `kind` (`text`, `file`, `staged`, `commit-message`,
`commit-diff`) and `sha` name it without user text. `directory` is the
directory the command producing the item runs in (the event cwd moved by
`cd`/`pushd` words and git's `-C`, `~` expanded), for a hook that judges the
target repo. `cd`/`pushd` are followed with redirection words dropped and
`-P`/`-L`/`--` before the one target; a bare `cd` moves to `$HOME` (with
HOME unset or empty bash's cd fails and nothing moves), `cd -` to the
directory the last move, followed or not, left (kept when none was), and a
target holding `$` or a backtick is not followed. A `~user` word that
doesn't expand is followed into the literal directory of that name when one
exists. When
`dir_filter(directory)` returns False, the items of that directory are not
built (no file read, diff or log run).

Commands are found with the shared splitter (lib/shell_quotes.py): top-level
pipelines, wrapper strings such as `bash -c '…'`, and command substitutions
(two levels deep). A command whose own prefix holds `bypass_assignment` (e.g.
`SYG_ALLOW_SESSION_URL=1 git commit …`, `env SYG_ALLOW_SESSION_URL=1 gh …`)
yields nothing; a mention elsewhere in the text does not count.

THE ADDED LAYER: git-hooks/pre-push scans what a push sends from a public
repo (message, identities, paths, added lines, tags, notes), however bash
built it. It is a layer on top of these items, not a replacement: every item
below is built as before wherever the hook is installed.

ITEMS, for every unbypassed command:
  - ("the command text", cmd): the WHOLE text, over-arm on purpose (it covers
    `-m`, heredoc and here-string bodies, `--body`, `--title`, `gh api -f
    body=…`), once per distinct directory, when a `git commit|tag|notes`
    (global options before the subcommand skipped) or any non-read `gh`
    command (read-only `gh` commands — `pr`/`issue`/`run`/`repo`/`release`/
    `gist` `view`/`list`/`status`/`checks`/`diff`/`watch`, `gh api` with a GET
    method, and bare/help-only `gh` — are skipped) is present.
  - ("file <f>", contents): a body read from a file: `git commit|tag|notes
    -F <f>` / `--file <f>` / `--file=<f>` (also inside a short cluster such as
    `-aF f`); for `gh`: `--body-file <f>`, `--notes-file <f>`, `-F <f>` (not
    on `gh api`), and on `gh api` a `-F`/`--field` value `key=@<f>` or
    `--input <f>`; `gh gist create|edit`: every positional file and
    `edit --add <f>`. `-` means stdin, i.e. the command text. A relative path
    resolves against the tracked directory (`cd ~` and `cd ~/x` expand HOME).
    At most 4 MiB is read; an unreadable file yields nothing.
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

KNOWN GAPS (accepted): a body read through a variable or a substitution
(`-F "$f"`, `--body "$(cat f)"`), a file written earlier by another tool call
and read by a wrapper script, a `cd` inside a subshell leaking into the
tracked directory, and `git push` of refs that git log cannot resolve
(skipped). Stdin redirects: `-F - < f`, `--body-file - < f`, `cat f | gh …
--body-file -`. Annotated tag messages on push. commit_diff's own gaps for
the staged lines (content written earlier in the same command does not exist
yet when a PreToolUse hook runs) and pushed lines (a merge commit's own
changes are not shown without `-m`; log output past 4 MiB is not read).
`--git-dir`/`--work-tree` and `GIT_DIR` are not followed.

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
import commit_diff

Item = namedtuple("Item", "label text directory kind sha")

MAX_FILE = 4 * 1024 * 1024
FILE_SUBCOMMANDS = ("commit", "tag", "notes")

# git global options that take a separate value word: commit_diff's set, so
# both parsers find the same subcommand.
GIT_VALUE_OPTS = {"-C"} | commit_diff.GIT_VAL_GLOBAL


def join_dir(base, rel):
    if not rel:
        return base
    rel = os.path.expanduser(rel)
    return rel if os.path.isabs(rel) else os.path.join(base, rel)


def git_parts(argv, base):
    """(subcommand, args after it, directory after -C options) for a git
    argv, or None when there is no subcommand."""
    directory = base
    i = 1
    while i < len(argv):
        w = argv[i]
        if w == "-C" and i + 1 < len(argv):
            directory = join_dir(directory, argv[i + 1])
            i += 2
        elif w in GIT_VALUE_OPTS:
            i += 2
        elif w.startswith("-"):
            i += 1
        else:
            return w, argv[i + 1:], directory
    return None


def file_values_git(args):
    """Files named by -F / --file in a git commit|tag|notes argument list.
    Short clusters are read the way git reads them: a value letter takes the
    rest of the word, else the next word."""
    out = []
    i = 0
    while i < len(args):
        w = args[i]
        if w == "--":
            break
        if w == "--file":
            if i + 1 < len(args):
                out.append(args[i + 1])
            i += 2
            continue
        if w.startswith("--file="):
            out.append(w[len("--file="):])
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
        elif w.startswith("--") and "=" not in w and w in (
                "--message", "--reuse-message", "--reedit-message", "--fixup", "--squash",
                "--author", "--date", "--cleanup", "--template", "--trailer"):
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


def repo_create_push_dir(argv, base):
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
    return join_dir(base, os.path.expanduser(source))


GH_GLOBAL_VALUE_OPTS = {
    "-R", "--repo", "--hostname", "--json", "-q", "--jq", "-t", "--template",
}
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
        if w.startswith("-"):
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


def read_file(path, directory):
    """Decoded contents (at most MAX_FILE bytes), or None."""
    if not path or path == "-":
        return None
    try:
        with open(join_dir(directory, path), "rb") as fh:
            data = fh.read(MAX_FILE)
    except OSError:
        return None
    return data.decode("utf-8", "replace")


def push_sources(args):
    sources = []
    extra = []
    positionals = []
    i = 0
    while i < len(args):
        w = args[i]
        if w in ("--all", "--mirror", "--branches"):
            extra.append("--branches")
        elif w == "--tags":
            extra.append("--tags")
        elif w in ("-o", "--push-option", "--receive-pack", "--exec", "--repo"):
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




def cd_target(prog, args, base=None):
    """The directory a `cd`/`pushd` moves to (HOME expanded), or None when it
    is not followed. `args` are its words after the program, redirection
    words already dropped; `-P`/`-L` (cd only) and `--` may precede the one
    target; `cd -`, a second operand, any other option and a target holding
    `$` or a backtick are not followed. A `~user` word that doesn't expand
    is followed into the literal directory of that name under `base` (bash
    leaves the word literal and enters it) when one exists, else not
    followed. `~+`/`~-` are not followed: this walker keeps no PWD/OLDPWD
    for them (lib/shell_state.py, which does, resolves both)."""
    opts = ("-P", "-L") if prog == "cd" else ()
    while args and args[0] in opts:
        args = args[1:]
    if args and args[0] == "--":
        args = args[1:]
    if len(args) != 1 or re.search(r"[$`]|^-", args[0]):
        return None
    target = os.path.expanduser(args[0])
    if not target.startswith("~"):
        return target
    if target in ("~+", "~-") or base is None:
        return None
    literal = os.path.join(base, target)
    return literal if os.path.isdir(literal) else None


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

    def counts(scope, gdir):
        if dir_filter is None and global_filter is None:
            return True
        if scope == "global":
            return bool(global_filter and global_filter())
        if isinstance(scope, tuple):
            path = join_dir(gdir, scope[1])
            if os.path.realpath(path) in _global_config_paths():
                return bool(global_filter and global_filter())
            owner = _config_file_owner(path)
            return bool(owner and dir_filter and dir_filter(owner))
        return bool(dir_filter and dir_filter(gdir))

    directory = cwd or "."
    oldpwd = None
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
            if prog in ("cd", "pushd"):
                directory, oldpwd = _cd_move(prog, argv, directory, oldpwd)
                continue
            if bypassed:
                if _carries_bypass(raw, unwrapped, argv, bypass_assignment):
                    bypass_raws.append(raw)
                continue
            if prog == "git":
                parts = git_parts(argv, directory)
                gdir = parts[2] if parts else directory
                for token, scope in _git_bypass_tokens(argv, prefix):
                    if counts(scope, gdir):
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


def _cd_move(prog, argv, directory, oldpwd):
    """`(directory, oldpwd)` after one `cd`/`pushd` (outbound_items' rules)."""
    args = strip_redirections(argv[1:])
    if prog == "cd" and not args:
        target = os.environ.get("HOME")  # bare cd: $HOME
        if not target:
            return directory, oldpwd  # no HOME: bash's cd fails, nothing moves
    elif prog == "cd" and args == ["-"]:
        target = oldpwd  # cd -: None (no move yet) keeps
    else:
        target = cd_target(prog, args, directory)
    if target is not None:
        return join_dir(directory, target), directory
    return directory, directory  # unfollowed: it left the believed dir


def outbound_items(cmd, cwd, bypass_assignment, dir_filter=None):
    items = []
    text_dirs = set()
    adds = []
    directory = cwd or "."
    oldpwd = None  # the directory the last cd/pushd left, followed or not
    verdicts = {}

    def wanted(d):
        if dir_filter is None:
            return True
        if d not in verdicts:
            verdicts[d] = bool(dir_filter(d))
        return verdicts[d]

    def command_text(d):
        if d not in text_dirs:
            text_dirs.add(d)
            items.append(Item("the command text", cmd, d, "text", None))

    def files(names, d):
        for f in names:
            text = read_file(f, d)
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
            if prog in ("cd", "pushd"):
                directory, oldpwd = _cd_move(prog, argv, directory, oldpwd)
                continue
            if prog == "gh":
                if bypassed:
                    continue
                if wanted(directory):
                    if not gh_is_read(argv):
                        command_text(directory)
                    files(file_values_gh(argv), directory)
                push_dir = repo_create_push_dir(argv, directory)
                if push_dir is not None and wanted(push_dir):
                    items.extend(_push_items(push_sources([]), push_dir))
                continue
            if prog != "git":
                continue
            parts = git_parts(argv, directory)
            if parts is None:
                continue
            sub, args, gdir = parts
            if sub in ("add", "stage"):
                spec = commit_diff.parse_add(args)
                spec["dir"] = gdir
                adds.append(spec)
                continue
            if bypassed or not wanted(gdir):
                continue
            if sub in FILE_SUBCOMMANDS:
                command_text(gdir)
                files(file_values_git(args), gdir)
                if sub == "commit":
                    for path, line in commit_diff.commit_lines(
                            gdir, commit_diff.parse_commit(args), adds):
                        items.append(Item(f"staged {path}", line, gdir, "staged", None))
            elif sub == "push":
                items.extend(_push_items(push_sources(args), gdir))
    return items
