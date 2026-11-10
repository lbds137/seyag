#!/bin/bash
# PreToolUse:Bash hook (seyag plugin): block filesystem walks rooted at /, the home folder or ~/gdrive.
#
# Blocks (exit 2) a Bash command that runs find, du, fd, rg, or grep -r/-R starting at /,
# /home, the home folder, or anything under ~/gdrive. On this machine ~/gdrive is an rclone
# mount: a walk that reaches it lists the whole Drive over the network and can wedge the
# mount in uninterruptible I/O. `-prune` doesn't help a walk of /: it still crawls every
# other tree first. Relative paths resolve against the tool call's cwd; a walker given no path
# walks that cwd (except rg fed by a pipe, which reads stdin). An in-command `cd` is not
# followed: `cd ~/gdrive/x && grep -r foo` from elsewhere is a known gap. An option's value
# (`rg -C 3`, `grep -A 3`, `fd -e md`) is not a path; `rg --files` takes no pattern, so all its
# operands are paths; fd's --search-path and --base-directory are roots; fd -x/-X's command
# ends at a `;` word, after which fd reads its own args again.
# Allowed: find with -maxdepth 2 or less from roots outside ~/gdrive (from / or ~ it reaches at
# most the mount's top level), and find with -maxdepth 1 or 0 from a folder below the mount's
# top level (`~/gdrive/<x>/…`: one readdir, like ls). Otherwise a find rooted in ~/gdrive blocks:
# -maxdepth 2 there lists Drive folders over the network, and any depth at ~/gdrive itself does.
#
# Bypass: put SYG_ALLOW_BROAD_WALK=1 in the command (the walk is meant to be
# broad).
# Command boundaries (newlines, comments, wrapper strings such as `sudo bash -c '...'` or
# `eval find ...`) come from the shared splitter, command_pipelines in lib/shell_quotes.py, and
# runner prefixes (sudo, env, timeout, nice, xargs, ...) from its unwrap_runners.
# Fail-open: no python3/jq, unparsable input or command, lib import failure → exit 0.

set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

INPUT=$(cat)
CMD=$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null) || exit 0
[ -n "$CMD" ] || exit 0
case "$CMD" in *SYG_ALLOW_BROAD_WALK=1*) exit 0 ;; esac
# Cheap prefilter: nothing to do unless a walking command appears at all.
case "$CMD" in
  *find* | *du* | *grep* | *rg* | *fd*) ;;
  *) exit 0 ;;
esac
CWD=$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null) || CWD=""

HOOK_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# The command goes to python on fd 3, never through the environment: Linux caps one env string
# at 128 KiB (MAX_ARG_STRLEN), and python failing to exec would fail open.
HITS=$(CWD="$CWD" HOOK_LIB="$HOOK_LIB" python3 - 3<<<"$CMD" <<'PYEOF'
import os, sys

# An import failure exits non-zero, which the caller treats as allow (fail-open).
sys.path.insert(0, os.environ["HOOK_LIB"])
from shell_quotes import command_pipelines, strip_redirections, unwrap_runners

HOME = os.path.realpath(os.path.expanduser("~"))
GDRIVE = os.path.join(HOME, "gdrive")
BROAD = {"/", "/home", HOME}
CWD = os.environ.get("CWD") or os.getcwd()


def resolve(path):
    for var in ("${HOME}", "$HOME"):
        if path == var or path.startswith(var + "/"):
            path = HOME + path[len(var):]
    path = os.path.expanduser(path)
    glob = min((path.find(c) for c in "*?[" if c in path), default=-1)
    if glob >= 0:  # the shell expands it: judge the folder it expands in (/* walks /home too)
        path = os.path.dirname(path[:glob]) or "."
    if not os.path.isabs(path):
        path = os.path.join(CWD, path)
    return os.path.normpath(path)


def in_gdrive(path):
    path = resolve(path)
    return path == GDRIVE or path.startswith(GDRIVE + "/")


def broad(path):
    return resolve(path) in BROAD or in_gdrive(path)


# Per walker: the short and long options that take a SEPARATE value (never a path), and the
# options that start another command's args, up to a `;` word (fd -x/-X run it per result).
VALUE_OPTS = {
    "rg": (set("gtTABCmefjMdEr"),
           {"--glob", "--iglob", "--type", "--type-not", "--max-depth", "--max-count",
            "--context", "--before-context", "--after-context", "--regexp", "--file",
            "--threads", "--max-columns", "--encoding", "--replace", "--sort", "--sortr",
            "--type-add"},
           set()),
    "grep": (set("ABCmefdD"),
             {"--include", "--exclude", "--exclude-dir", "--context", "--before-context",
              "--after-context", "--max-count", "--regexp", "--file"},
             set()),
    "fd": (set("eEtdxXjSc"),
           {"--extension", "--exclude", "--type", "--max-depth", "--min-depth", "--exact-depth",
            "--exec", "--exec-batch", "--threads", "--size", "--changed-within",
            "--changed-before", "--owner", "--color", "--base-directory", "--search-path"},
           {"-x", "-X", "--exec", "--exec-batch"}),
}
for _alias, _walker in (("egrep", "grep"), ("fgrep", "grep"), ("ugrep", "grep"), ("fdfind", "fd")):
    VALUE_OPTS[_alias] = VALUE_OPTS[_walker]


def scan(prog, args):
    """(positionals, options) of a walker's args: options as (name, value or None), with a
    value-taking option's value (attached `-C3`/`--context=3`, or the next word) never read
    as a positional. Short clusters split (`-nC 3` is -n, then -C 3). `--` ends options."""
    short_values, long_values, stops = VALUE_OPTS.get(prog, (set(), set(), set()))
    pos, opts = [], []
    i = 0
    while i < len(args):
        a = args[i]
        i += 1
        if a == "--":
            pos += args[i:]
            break
        if a.startswith("--"):
            key, eq, value = a.partition("=")
            value = value if eq else None
            if key in long_values and not eq and i < len(args):
                value, i = args[i], i + 1
            opts.append((key, value))
        elif a.startswith("-") and a != "-":
            for j in range(1, len(a)):
                if a[j] in short_values:
                    value = a[j + 1:] or None
                    if value is None and i < len(args):
                        value, i = args[i], i + 1
                    opts.append(("-" + a[j], value))
                    break
                opts.append(("-" + a[j], None))
        else:
            pos.append(a)
            continue
        if opts and opts[-1][0] in stops:
            # fd's command runs up to a `;` word (`\;` and `';'` both arrive as `;`), and fd
            # parses its own args after it; with no `;`, the rest of argv is the command.
            if ";" not in args[i:]:
                break
            i = args.index(";", i) + 1
    return pos, opts

hits = []
# With no path operand each walker walks the cwd ("."), except rg fed by a pipe (it reads stdin).
command = os.fsdecode(open(3, "rb").read()).removesuffix("\n")
cmds = [(argv, k == 0) for pipeline in command_pipelines(command)
        for k, argv in enumerate(pipeline)]
for argv, first_in_pipeline in cmds:
    argv, _ = unwrap_runners(argv)  # assignments, sudo/env/timeout 60/nice -n 5/xargs -n 1/...
    if not argv:
        continue
    argv = argv[:1] + strip_redirections(argv[1:])
    prog, args = os.path.basename(argv[0]), argv[1:]
    roots = []
    if prog == "find":
        i = 0
        while i < len(args) and args[i] in ("-H", "-L", "-P"):
            i += 1
        while i < len(args) and not args[i].startswith(("-", "(", "!")):
            roots.append(args[i])
            i += 1
        roots = roots or ["."]
        if "-maxdepth" in args:
            j = len(args) - 1 - args[::-1].index("-maxdepth")
            if j + 1 < len(args) and args[j + 1].isdigit() and int(args[j + 1]) <= 2:
                if int(args[j + 1]) <= 1:  # one readdir, like ls: only the mount root lists it all
                    roots = [r for r in roots if resolve(r) == GDRIVE]
                else:
                    roots = [r for r in roots if in_gdrive(r)]  # shallow, but still in the mount
    elif prog == "du":
        roots = [a for a in args if not a.startswith("-")] or ["."]
    elif prog in ("fd", "fdfind"):
        pos, opts = scan(prog, args)
        roots = pos[1:]  # the first is the pattern
        roots += [v for k, v in opts if k in ("--search-path", "--base-directory") and v]
        roots = roots or ["."]
    elif prog == "rg":
        pos, opts = scan(prog, args)
        names = {k for k, _ in opts}
        no_pattern = names & {"-e", "--regexp", "-f", "--file", "--files", "--type-list"}
        roots = pos if no_pattern else pos[1:]
        roots = roots or (["."] if first_in_pipeline else [])
    elif prog in ("grep", "egrep", "fgrep", "ugrep"):
        pos, opts = scan(prog, args)
        names = {k for k, _ in opts}
        if names & {"-r", "-R", "--recursive", "--dereference-recursive"}:
            roots = pos if names & {"-e", "--regexp", "-f", "--file"} else pos[1:]
            roots = roots or ["."]
    hits += [prog + " " + r for r in roots if broad(r)]

print("\n".join(hits))
PYEOF
) || exit 0

[ -n "$HITS" ] || exit 0

cat >&2 <<EOF
BROAD-WALK GUARD — this walk starts at /, the home folder, or inside ~/gdrive

$(printf '%s\n' "$HITS" | sed 's/^/  - /')

~/gdrive is an rclone mount of the whole Google Drive: a walk that reaches it lists the Drive
over the network and can wedge the mount. Start the walk where the thing lives instead:
  the project folder, or ~/Documents/dev-docs for environment files;
  Go modules: ~/go/pkg/mod (missing one: go mod download -json <mod>@<ver>);
  mise tools: ~/.local/share/mise; commands on PATH: command -v <name>.
If a broad walk is really meant, prefix the command with SYG_ALLOW_BROAD_WALK=1.
EOF
exit 2
