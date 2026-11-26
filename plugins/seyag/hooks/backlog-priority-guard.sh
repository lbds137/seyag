#!/bin/bash
# PreToolUse:Bash hook (seyag plugin): refuse a backlog.md create or promote that
# would leave a To Do / In Progress task without a priority.
#
# WHAT IT BLOCKS (exit 2, message on stderr), per violating command:
#   - `backlog task create …` whose RESULTING status — the -s/--status/--status=
#     value if given, else the store's config.yml default_status, else To Do — is
#     a priority-required status (SYG_BACKLOG_PRIORITY_STATUSES, comma-separated,
#     case-insensitive; default "To Do,In Progress"), when the command passes no
#     --priority/--priority= and no --draft (a --draft create parks the task in
#     drafts/, which this guard never judges);
#   - `backlog task edit ID… [opts]` whose -s/--status/--status= value is a
#     required status, with no --priority, when a positional ID's task file
#     (<store>/backlog/tasks/<prefix>-<N> - *.md, prefix from config.yml
#     task_prefix, default task; matched case-insensitively) has no priority:
#     key with a non-empty value in its YAML frontmatter (between the first two
#     --- lines). An ID with no file is allowed: the CLI errors itself.
#     Positionals are words not starting with - and not consumed as an option's
#     value; every option takes one value word except the value-less flags
#     --plain, --draft, -h, --help, --no-dod-defaults and anything starting
#     --clear- or --no-; a glued -sVALUE is the status. -h/--help on any judged
#     verb is never blocked;
#   - `backlog draft promote ID` (the CLI lands the task in To Do and has no
#     --priority option) when To Do is a required status and the draft file
#     (<store>/backlog/drafts/draft-<N> - *.md; IDs N, DRAFT-N, draft-N) has no
#     priority — set it first with `backlog draft edit <ID> --priority <p>`.
# Everything else (view, list, archive, restore, demote, draft edit/create, task
# edit without a required status) is allowed.
#
# PROGRAM FORMS judged (basenames, after lib unwrap_runners): `backlog` (or its
# npm package name `backlog.md`, wherever `backlog` is accepted);
# `npx`/`pnpx`/`bunx` [option words; -p/--package take a value] backlog;
# `pnpm`/`yarn` [option words] [exec|run|dlx] backlog. A pnpm/yarn -C DIR/--dir DIR/--dir=DIR re-roots the
# store lookup relative to the command's effective cwd. Observed in 14 days of
# local logs: npx backlog 978, pnpm -s backlog 896, bare backlog 329,
# pnpm exec backlog 35, pnpm backlog 30, npx --no-install backlog 22.
#
# WHERE COMMANDS ARE FOUND: lib/shell_state.walk, the same walker as
# publish-gate — `cd X && backlog …`, newlines, `bash -c '…'` and `$(…)`
# included; the store is looked up per command by walking up from that
# command's effective cwd (state.cwd) to the first directory holding
# backlog/config.yml (stop at /). A `$(…)`/backtick span opening inside single
# quotes is prose and is not walked when `shell_quotes.prose_skip_safe` holds,
# decided once per command. Its rule: a shell word or `<<` inside a quoted
# argument of a `backlog … task create|edit` or `draft promote` command (the
# command running up to the next unquoted `;`, `&`, `|`, `)` or newline) no
# longer sends the scan to extract-everything; every other occurrence is
# honoured as before. A command that defines a function or alias, or reads
# `$_`, keeps the old behaviour. A shell word outside a backlog argument still
# catches what it caught before; one inside a backlog argument no longer
# arms the catch for a wrapper the scanner does not know (accepted gap below).
# No store, or an unresolvable (None/relative) cwd, allows the command.
# Block if any walked world yields a violation.
#
# ACTIVATION: the session env SYG_TRACKING_SURFACE must equal backlog-md (the
# project's backlog.md opt-in pin in .claude/settings.json env); anything else
# exits 0 before python starts.
#
# BYPASS: SYG_ALLOW_NO_PRIORITY=1 anywhere in the command text (the owner
# approved a priority-less task).
#
# FAIL-OPEN (exit 0): no jq/python3, unparsable JSON or empty command, lib
# import failure, any python exception. The command goes to python on fd 3,
# never through the environment (Linux caps one env string at 128 KiB);
# python's own stderr is discarded on the result capture.
#
# ACCEPTED GAPS (not fixed here):
#   - frontmatter hand-edited via the Edit/Write tools or sed (only the backlog
#     CLI's own writes are guarded);
#   - `task restore` of an archived priority-less To Do task;
#   - other wrappers: node_modules/.bin/backlog IS covered (basename match),
#     `node path/to/cli.js` is not;
#   - a `task create`/`task edit` with any argument word starting with $ (`"$@"`,
#     `$A`, `"${args[@]}"`, `$1`) is never judged: the expansion may carry
#     --priority (a word merely containing $ later, like "costs $5", is judged);
#   - a variable-held program (`B=…/backlog; $B task create …`) is never judged
#     (TASK-196);
#   - single-quoted text piped into a shell (`printf %s '…backlog task create…' | bash`)
#     is not judged (TASK-196 notes);
#   - a single-quoted `$(…)` create run by a wrapper the scanner does not know
#     (`$SHELL -c '…'`, `source /dev/stdin <<< '…'`, `flock F -c '…'`) is not
#     judged; before TASK-191 it was judged only when a shell word sat elsewhere
#     in the command, and a shell word inside a backlog argument no longer counts
#     (TASK-196 notes);
#   - over-block: a shell word or `<<` outside a backlog argument (`python3 -c
#     '…bash…'`, `echo 'bash runs'`) still makes quoted prose elsewhere in the
#     command judged, as before TASK-191;
#   - the CLI's MCP/browser surfaces.
#
# Fixture check: run hooks/backlog-priority-guard.probe.sh after ANY edit.

set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# Activation: only a backlog.md project (the settings env pin) runs this guard.
[ "${SYG_TRACKING_SURFACE:-}" = "backlog-md" ] || exit 0

INPUT=$(cat)
CMD=$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null) || CMD=""
[ -n "$CMD" ] || exit 0

# Bypass: the owner approved a priority-less task.
case "$CMD" in *SYG_ALLOW_NO_PRIORITY=1*) exit 0 ;; esac
# Cheap prefilter: nothing to judge without a backlog mention at all.
case "$CMD" in *backlog*) ;; *) exit 0 ;; esac

CWD=$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null) || CWD=""
[ -n "$CWD" ] || CWD=$PWD

HOOK_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# Python prints the body between the header and the bypass line: one line per
# violation, then the fix line(s). An empty body (or any python failure) allows.
RESULT=$(CWD="$CWD" HOOK_LIB="$HOOK_LIB" python3 -I "${SYG_PY_CACHE_ARG:--B}" - 3<<<"$CMD" <<'PYEOF' 2>/dev/null
import os
import posixpath
import re
import sys

# An import failure exits non-zero, which the caller treats as allow (fail-open).
sys.path.insert(0, os.environ["HOOK_LIB"])
from shell_quotes import prose_skip_safe, strip_redirections, unwrap_runners
from shell_state import State, apply_dir_builtin, resolve_cd, walk

cmd = os.fsdecode(open(3, "rb").read()).removesuffix("\n")
payload_cwd = os.environ.get("CWD") or os.getcwd()

REQUIRED = {
    w.strip().casefold()
    for w in (os.environ.get("SYG_BACKLOG_PRIORITY_STATUSES")
              or "To Do,In Progress").split(",")
    if w.strip()
}
# Options that take no value word when judging task edit positionals (and task
# create flags): everything else is read as one option word plus one value.
BOOLEANS = {"--plain", "--draft", "-h", "--help", "--no-dod-defaults"}
# Also value-less: any option starting with one of these (--clear-labels,
# --no-dod-defaults, ...; backlog 1.55.3 lists no value-taking option so named).
BOOLEAN_PREFIXES = ("--clear-", "--no-")
# Basenames of the CLI program (the npm package is backlog.md).
PROGRAMS = {"backlog", "backlog.md"}
HELP = {"-h", "--help"}
CONFIG_CACHE = {}


def config_value(store, key):
    """One `key: value` line of the store's backlog/config.yml, unquoted; None
    when the file or the key is missing (or the value is empty)."""
    if store not in CONFIG_CACHE:
        try:
            with open(posixpath.join(store, "backlog", "config.yml"),
                      encoding="utf-8", errors="replace") as f:
                CONFIG_CACHE[store] = f.read().splitlines()
        except OSError:
            CONFIG_CACHE[store] = []
    for line in CONFIG_CACHE[store]:
        m = re.match(r"^\s*[A-Za-z0-9_]+:\s*(.*?)\s*$", line)
        if m and line.split(":", 1)[0].strip() == key:
            return m.group(1).strip("\"'") or None
    return None


def find_store(cwd):
    """Nearest ancestor of cwd (inclusive) holding backlog/config.yml; the store
    root directory, or None at / without a hit."""
    d = posixpath.normpath(cwd)
    while True:
        if os.path.isfile(posixpath.join(d, "backlog", "config.yml")):
            return d
        if d == "/":
            return None
        d = posixpath.dirname(d)


def has_priority(path):
    """True when the file's YAML frontmatter (between the first two --- lines)
    holds a priority: key with a non-empty value."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return True  # unreadable: the CLI will complain, not this guard
    if not lines or lines[0].strip() != "---":
        return True  # no frontmatter to judge
    for line in lines[1:]:
        if line.strip() == "---":
            break
        m = re.match(r"^\s*priority:\s*(\S.*?)\s*$", line)
        if m and m.group(1).strip().strip("\"'"):
            return True
    return False


def store_file(store, subdir, want):
    """First <store>/backlog/<subdir> entry whose name starts with `want`
    (case-insensitive, `want` already ends with " - "); None when absent."""
    try:
        for entry in os.scandir(posixpath.join(store, "backlog", subdir)):
            if entry.name.lower().startswith(want) and entry.name.endswith(".md"):
                return entry.path
    except OSError:
        return None
    return None


def scan_options(words):
    """One pass over the CLI words of a judged verb: returns (positionals,
    booleans, status_value, has_priority). Every option word except the known
    boolean flags is treated as taking one value word, so a value is never
    mistaken for a positional ID."""
    positionals, bools, status, prio = [], set(), None, False
    i = 0
    while i < len(words):
        w = words[i]
        if w == "--":
            positionals.extend(words[i + 1:])
            break
        if w.startswith("-") and w != "-":
            if w in BOOLEANS or w.startswith(BOOLEAN_PREFIXES):
                bools.add(w)
                i += 1
                continue
            if w.startswith("-s") and len(w) > 2 and not w.startswith("--"):
                status = w[2:]  # glued -sVALUE (quotes already removed)
                i += 1
                continue
            if "=" in w:
                key, val = w.split("=", 1)
                i += 1
            else:
                key, val = w, None
                i += 1
                if i < len(words):
                    val = words[i]
                    i += 1
            if key in ("-s", "--status"):
                status = val
            elif key == "--priority":
                prio = True
            continue
        positionals.append(w)
        i += 1
    return positionals, bools, status, prio


def cli_of(unwrapped):
    """(cli_argv_after_backlog, reroot) when unwrapped runs the backlog CLI,
    else None. Basenames are compared, so node_modules/.bin/backlog matches.
    reroot is a pnpm/yarn -C/--dir directory that re-roots the store lookup."""
    argv = strip_redirections(list(unwrapped))
    if not argv:
        return None
    name = argv[0].rsplit("/", 1)[-1]
    rest = argv[1:]
    if name in PROGRAMS:
        return rest, None
    if name in ("npx", "pnpx", "bunx"):
        i = 0
        while i < len(rest) and rest[i].startswith("-") and rest[i] != "-":
            # -p/--package VALUE consumes the next word; --package=VALUE is one.
            i += 2 if rest[i] in ("-p", "--package") else 1
        if i < len(rest) and rest[i].rsplit("/", 1)[-1] in PROGRAMS:
            return rest[i + 1:], None
        return None
    if name in ("pnpm", "yarn"):
        reroot = None
        i = 0
        while i < len(rest) and rest[i].startswith("-") and rest[i] != "-":
            flag = rest[i]
            if flag.startswith("--dir="):
                reroot = flag.split("=", 1)[1]
                i += 1
            elif flag in ("--dir", "-C"):
                if i + 1 < len(rest):
                    reroot = rest[i + 1]
                i += 2
            else:
                i += 1
        if i < len(rest) and rest[i] in ("exec", "run", "dlx"):
            i += 1
        if i < len(rest) and rest[i].rsplit("/", 1)[-1] in PROGRAMS:
            return rest[i + 1:], reroot
    return None


class Context:
    def __init__(self):
        self.lines = []  # violation lines, in first-seen order
        self.seen = set()
        self.promotes = []  # draft IDs a promote would strand without a priority
        self.visited = set()  # State snapshots the text passes through
        self.leftovers = []  # (span, depth) not placed at a command
        self.leftover_mode = False

    def add(self, line, promote=None):
        if line not in self.seen:
            self.seen.add(line)
            self.lines.append(line)
        if promote is not None and promote not in self.promotes:
            self.promotes.append(promote)


def judge(cli, reroot, state, ctx):
    if not cli:
        return
    base = state.cwd
    if reroot is not None:
        base = resolve_cd(base, reroot) if base is not None else None
    if not base or not base.startswith("/"):
        return  # unresolvable cwd: that command is allowed
    store = find_store(base)
    if store is None:
        return
    prefix = (config_value(store, "task_prefix") or "task").lower()
    ident_re = re.compile(
        rf"^(?:{re.escape(prefix)}-)?(\d+(?:\.\d+)*)$", re.IGNORECASE)

    if (len(cli) >= 2 and cli[0] == "task" and cli[1] in ("create", "edit")
            and any(w.startswith("$") for w in cli[2:])):
        return  # an expansion may carry --priority: not judged

    if len(cli) >= 2 and cli[0] == "task" and cli[1] == "create":
        _, bools, status, prio = scan_options(cli[2:])
        if prio or "--draft" in bools or HELP & bools:
            return
        if status is None:
            status = config_value(store, "default_status") or "To Do"
        if status.strip().casefold() in REQUIRED:
            ctx.add(f'create: resulting status "{status}"')
        return

    if len(cli) >= 2 and cli[0] == "task" and cli[1] == "edit":
        ids, bools, status, prio = scan_options(cli[2:])
        if HELP & bools:
            return
        if prio or status is None or status.strip().casefold() not in REQUIRED:
            return
        for ident in ids:
            m = ident_re.match(ident)
            if not m:
                continue
            f = store_file(store, "tasks", f"{prefix}-{m.group(1)} - ".lower())
            if f is not None and not has_priority(f):
                ctx.add(f"edit {ident}: file has no priority")
        return

    if len(cli) >= 2 and cli[0] == "draft" and cli[1] == "promote":
        if "to do" not in REQUIRED:
            return
        idents, bools, _, _ = scan_options(cli[2:])
        if HELP & bools:
            return
        for ident in idents:
            m = re.match(r"^(?:draft-)?(\d+(?:\.\d+)*)$", ident, re.IGNORECASE)
            if not m:
                continue
            f = store_file(store, "drafts", f"draft-{m.group(1)} - ".lower())
            if f is not None and not has_priority(f):
                ctx.add(f"draft promote {ident}: file has no priority",
                        promote=ident)
        return


def run_command(argv, state, ctx):
    if apply_dir_builtin(argv, state):
        return
    unwrapped, info = unwrap_runners(argv)
    if not unwrapped:
        return
    hit = cli_of(unwrapped)
    if hit is None:
        return
    judge(hit[0], hit[1], state, ctx)


ctx = Context()
# Decided once on the whole command; nested and leftover walks inherit it.
prose_gate = prose_skip_safe(cmd)
walk(cmd, 0, State(payload_cwd, payload_cwd=payload_cwd), ctx, run_command,
     skip_single_quoted_spans=prose_gate)

# A substitution span the walk couldn't place at a command (its text doesn't
# survive into any word as written) is judged against EVERY state the text
# passed through: block if any resolves, same as publish-gate.
ctx.leftover_mode = True
states = sorted(ctx.visited)
done = set()
while ctx.leftovers:
    span, depth = ctx.leftovers.pop(0)
    if (span, depth) in done:
        continue
    done.add((span, depth))
    for cwd, env in states:
        walk(span, depth, State(cwd, dict(env), payload_cwd), ctx, run_command,
             skip_single_quoted_spans=prose_gate)

if not ctx.lines:
    sys.exit(0)

for line in ctx.lines:
    print(f"  - {line}")
print("add --priority high|medium|low (backlog.md's configured priorities)")
for ident in ctx.promotes:
    print(f"set it first: backlog draft edit {ident} --priority <p>")
PYEOF
) || exit 0

[ -n "$RESULT" ] || exit 0

cat >&2 <<EOF
BACKLOG PRIORITY GUARD — task left without a priority
$RESULT
If the owner approved a priority-less task, prefix the command with SYG_ALLOW_NO_PRIORITY=1.
EOF
exit 2
