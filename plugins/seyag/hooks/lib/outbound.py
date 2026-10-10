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

ITEMS, for every unbypassed command:
  - ("the command text", cmd): when a `git commit|tag|notes` (global options
    before the subcommand skipped) or ANY `gh` command is present: the WHOLE
    text, over-arm on purpose (it covers `-m`, heredoc and here-string bodies,
    `--body`, `--title`, `gh api -f body=…`). Once per distinct directory.
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
                args = strip_redirections(argv[1:])
                if prog == "cd" and not args:
                    target = os.environ.get("HOME")  # bare cd: $HOME
                    if not target:
                        continue  # no HOME: bash's cd fails, nothing moves
                elif prog == "cd" and args == ["-"]:
                    target = oldpwd  # cd -: None (no move yet) keeps
                else:
                    target = cd_target(prog, args, directory)
                if target is not None:
                    oldpwd, directory = directory, join_dir(directory, target)
                else:
                    oldpwd = directory  # unfollowed: it left the believed dir
                continue
            if prog == "gh":
                if bypassed:
                    continue
                if wanted(directory):
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
