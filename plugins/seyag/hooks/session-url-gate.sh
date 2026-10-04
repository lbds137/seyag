#!/bin/bash
# PreToolUse hook (matcher: Bash) — a Claude session link
# (`https://claude.ai/code/session_<id>`) is a secret in any shared history:
# it must not enter a commit, tag, note, PR, issue, release or gist, in any
# project. Tzurot's .husky/commit-msg guards the commit-message path only; this
# hook checks the command text, bodies read from files, and the commit
# MESSAGES of a push (see KNOWN GAPS for what it does not see).
#
# SECRET PATTERN: `claude.ai/code/session_` followed by an id character
# [A-Za-z0-9] (host part case-insensitive, the rest case-sensitive). Prose
# naming the bare prefix, followed by a space, backtick or quote, passes.
#
# WHAT BLOCKS (commands are found with the shared splitter in lib/, the same
# one publish-gate uses: top-level pipelines, wrapper strings such as
# `bash -c '…'`, and command substitutions):
#   1. `git commit`, `git tag`, `git notes` (global options before the
#      subcommand are skipped; `-C <dir>` is honored), or ANY `gh` command,
#      when the WHOLE command text matches the pattern. That covers `-m`,
#      heredoc and here-string bodies, `--body`, `--title` and
#      `gh api -f body=…`. A link anywhere in the same text as such a command
#      is an over-arm on purpose (the recoverable direction).
#   2. A body read from a file, whose CONTENTS are matched: `git commit|tag|
#      notes -F <f>` / `--file <f>` / `--file=<f>` (also inside a short
#      cluster such as `-aF f`); for `gh`: `--body-file <f>`, `--notes-file
#      <f>`, `-F <f>` (not on `gh api`), and on `gh api` a `-F`/`--field`
#      value `key=@<f>` or `--input <f>`; `gh gist create|edit`: every
#      positional file and `edit --add <f>`. `-` means stdin, i.e. the command
#      text, already covered by 1. A relative path resolves against the
#      event's cwd, moved by `cd` words earlier in the command (`cd ~` and
#      `cd ~/x` expand HOME) and by git's `-C`. An unreadable file is not a
#      block.
#   3. `git push`: the messages of the commits being pushed. Sources are the
#      source side of each refspec given (`foo`, `+foo:bar`, `HEAD:refs/…`;
#      a delete `:dst` has none), else HEAD; `--all`/`--mirror` scan every
#      local branch and `--tags` every tag. The scan is
#      `git log <sources> --not --remotes`, so commits already on any remote
#      pass. A refspec with `$`, a backtick or a glob is read as HEAD.
#      `gh repo create … --push` runs the same scan on HEAD in the repo
#      directory (`--source <dir>` if given, else the tracked cwd).
#
# MESSAGE: names the path that matched (command text, file <f>, or commit
# <sha> <subject>), masks the id (`claude.ai/code/session_…`; the full link
# is never echoed), and says to remove the link and, for a commit already
# made, amend it before pushing.
#
# BYPASS: `SYG_ALLOW_SESSION_URL=1` as an assignment in the matched command's
# own prefix (`VAR=… git commit …`, `env VAR=… gh …`); a mention elsewhere in
# the text does not count. Only on the owner's word.
#
# KNOWN GAPS (accepted): a body read through a variable or a substitution
# (`-F "$f"`, `--body "$(cat f)"`), a file written earlier by another tool call
# and read by a wrapper script, a `cd` inside a subshell leaking into the
# tracked directory, and `git push` of refs that git log cannot resolve
# (skipped). Stdin redirects: `-F - < f`, `--body-file - < f`, `cat f | gh …
# --body-file -`. Annotated tag messages on push (only commit messages are
# scanned). File CONTENTS inside a commit: the committed diff's added lines are
# a separate scan this hook does not run.
#
# FAIL-OPEN: no jq/python3, unparsable JSON or command, or an internal python
# error → exit 0. Prefilter, in bash, before python spawns: a `gh` word always
# goes through; a `git` word goes through only with a word-bounded `commit`,
# `tag`, `notes` or `push` in the text, so `git status` and the like never
# start python.
#
# The command goes to python on fd 3, never through the environment (Linux
# caps one env string at 128 KiB). Python's stderr is discarded.
#
# Fixture check: run hooks/session-url-gate.probe.sh after ANY edit here.

set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

INPUT=$(cat)
TOOL_NAME=$(jq -r '.tool_name // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ "$TOOL_NAME" != "Bash" ] && exit 0

CMD=$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ -z "$CMD" ] && exit 0

if [[ "$CMD" =~ (^|[^[:alnum:]_.-])gh([^[:alnum:]_-]|$) ]]; then
  :
elif [[ "$CMD" =~ (^|[^[:alnum:]_.-])git([^[:alnum:]_-]|$) ]] \
  && [[ "$CMD" =~ (^|[^[:alnum:]_-])(commit|tag|notes|push)([^[:alnum:]_-]|$) ]]; then
  :
else
  exit 0
fi

CWD=$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null) || CWD=""

HOOK_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
RESULT=$(CWD="$CWD" HOOK_LIB="$HOOK_LIB" PYTHONDONTWRITEBYTECODE=1 python3 - 3<<<"$CMD" <<'PYEOF' 2>/dev/null
import os
import re
import subprocess
import sys

# An import failure exits non-zero, which the caller treats as allow (fail-open).
sys.path.insert(0, os.environ["HOOK_LIB"])
from shell_quotes import command_pipelines, substitution_spans, unwrap_runners

cmd = os.fsdecode(open(3, "rb").read()).removesuffix("\n")
payload_cwd = os.environ.get("CWD") or "."

SECRET = re.compile(r"(?i:claude\.ai)/code/session_[A-Za-z0-9]")
MASK = re.compile(r"(?i:claude\.ai)/code/session_[A-Za-z0-9_-]*")
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
BYPASS = "SYG_ALLOW_SESSION_URL=1"
MAX_FILE = 4 * 1024 * 1024
FILE_SUBCOMMANDS = ("commit", "tag", "notes")

# git global options that take a separate value word.
GIT_VALUE_OPTS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace",
                  "--super-prefix", "--config-env"}


def mask(text):
    return MASK.sub("claude.ai/code/session_…", text)


def join_dir(base, rel):
    if not rel:
        return base
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


def read_hit(path, directory):
    if not path or path == "-":
        return False
    try:
        with open(join_dir(directory, path), "rb") as fh:
            data = fh.read(MAX_FILE)
    except OSError:
        return False
    return SECRET.search(data.decode("utf-8", "replace")) is not None


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


def pushed_commits(args, directory):
    hits = []
    seen = set()
    for src in dict.fromkeys(push_sources(args)):
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
            if SECRET.search(parts[1] + "\n" + parts[2]):
                seen.add(parts[0])
                hits.append((parts[0], parts[1]))
    return hits


def all_pipelines(text, depth=0):
    result = list(command_pipelines(text))
    if depth < 2:
        for span in substitution_spans(text):
            result.extend(all_pipelines(span, depth + 1))
    return result


text_hit = SECRET.search(cmd) is not None
findings = []
directory = payload_cwd

for pipeline in all_pipelines(cmd):
    for raw in pipeline:
        argv, _ = unwrap_runners(raw)
        if not argv:
            continue
        prefix = raw[: len(raw) - len(argv)]
        bypassed = BYPASS in prefix
        prog = argv[0].rsplit("/", 1)[-1]
        if prog in ("cd", "pushd") and len(argv) == 2 and not re.search(r"[$`]|^-", argv[1]):
            target = os.path.expanduser(argv[1])
            if not target.startswith("~"):
                directory = join_dir(directory, target)
            continue
        if prog == "gh":
            if bypassed:
                continue
            if text_hit:
                findings.append("the command text")
                continue
            for f in file_values_gh(argv):
                if read_hit(f, directory):
                    findings.append(f"file {f}")
            push_dir = repo_create_push_dir(argv, directory)
            if push_dir is not None:
                for sha, subject in pushed_commits([], push_dir):
                    findings.append(f"commit {sha} {mask(subject)}")
            continue
        if prog != "git":
            continue
        parts = git_parts(argv, directory)
        if parts is None or bypassed:
            continue
        sub, args, gdir = parts
        if sub in FILE_SUBCOMMANDS:
            if text_hit:
                findings.append("the command text")
                continue
            for f in file_values_git(args):
                if read_hit(f, gdir):
                    findings.append(f"file {f}")
        elif sub == "push":
            for sha, subject in pushed_commits(args, gdir):
                findings.append(f"commit {sha} {mask(subject)}")

if findings:
    uniq = list(dict.fromkeys(findings))
    print("blocked: a Claude session link (claude.ai/code/session_…) would go out; matched in: "
          + "; ".join(uniq) + ".")
    print("Session links are secrets in shared history. Remove the link (relay session links "
          "in chat only). For a commit already made, `git commit --amend` (or reword it "
          "without an interactive editor) before pushing.")
    print("Only on the owner's word: prefix the command itself with SYG_ALLOW_SESSION_URL=1.")
PYEOF
)
[ -z "$RESULT" ] && exit 0
printf '%s\n' "$RESULT" >&2
exit 2
