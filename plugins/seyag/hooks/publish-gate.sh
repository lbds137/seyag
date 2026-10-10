#!/bin/bash
# PreToolUse hook (matcher: Bash) — blocks a `gh` command that would make a
# repo or gist PUBLIC until the going-public checklist has passed for that
# exact target. The going-public skill (0.3.16) ships the checklist; this is
# its mechanical trigger, keyed on the skill's own unblock contract
# (skills/going-public/SKILL.md: "Mechanical gates elsewhere may key on
# SYG_PUBLISH_CHECKED=<repo>, set only after this checklist passes").
#
# WHAT COUNTS AS A PUBLISH (after `unwrap_runners` strips assignments and
# runner prefixes so argv[0] is the real program):
#   - `gh repo edit` carrying `--visibility public` (long-flag forms
#     `--visibility public` and `--visibility=public`; the value matches
#     exactly `public` case-insensitively — gh is case-insensitive on enum
#     values — while `private`/`internal` pass);
#   - `gh repo create`/`gh repo new` carrying `--public`;
#   - `gh gist create`/`gh gist new` carrying `-p`/`--public` (cluster
#     parsing respected: `-f` takes a value in `gist create`, so `-fp` is a
#     `--filename p`, NOT a `-p` hit);
#   - `gh api` writes (explicit `-X PATCH`/`-X PUT`/`-X POST`, or implicit via
#     `-f`/`-F`/`--field`/`--raw-field`/`--input`) to a `repos/OWNER/REPO`
#     endpoint carrying a field `private=false` or `visibility=public`
#     (attached, `=`-joined or separate field forms), or carrying any
#     `--input` while the WHOLE command text holds `"private": false` or
#     `"visibility": "public"` (case-insensitive, quotes optional or
#     backslash-escaped: the stdin body of a here-string, heredoc,
#     `echo … |` or `jq -n '{private:false}' |` pipe).
# WHERE COMMANDS ARE FOUND, in EXECUTION order: the splitter's top-level
# pipelines; a wrapper's string (`bash -c '…'`, `eval "…"`, …) right after
# the pipeline that runs it; a command substitution (`$(…)` or backticks,
# quoted or not: `url="$(gh repo create --public)"`, `echo "$(gh …)"`) right
# before the command whose word holds it. A substitution the walk can't place
# at a command (including one nested at MAX_WRAPPER_DEPTH) is judged against
# EVERY state the text passes through. Same
# mechanism as `upstream-submission-guard`, which shares the lib.
# FLAG PARSING: which flags take a value word is looked up in a table PER
# (group, subcommand), built from gh 2.101.0's own `--help` output (`gh repo
# edit --help`, `gh repo create --help`, `gh gist create --help`,
# `gh api --help`); any flag NOT listed is a boolean (takes no value word).
# Short flags are read the way gh's flag library reads them: `-x value`,
# `-xvalue`, `-x=value`, boolean clusters (`-pw` = `-p -w`); long flags as
# `--flag value` or `--flag=value`. `-R`/`--repo` is accepted before or after
# the subcommand (not on `gist`, where gh has no `-R`).
#
# TARGET RESOLUTION, mirroring how gh itself picks a repo, LOCAL config only
# (no network call is made): for `repo edit`/`repo create` the POSITIONAL
# operand (what gh 2.101 actually reads — its synopsis is
# `gh repo edit [<repository>] [flags]`, and it rejects `-R` client-side),
# else an explicit `-R`/`--repo`, else `GH_REPO`, else the effective
# directory's git remotes — the same order as `upstream-submission-guard`
# once the positional is read. A positional BARE NAME (`gh repo create three
# --public`; gh would default the owner to the authenticated user) parses to
# no slug and is UNRESOLVABLE. For `gh api` (which has no `-R`), a LITERAL
# `repos/OWNER/REPO` in the endpoint wins even over GH_REPO;
# `{owner}`/`{repo}` placeholders are filled from GH_REPO or the remotes. An
# explicit value parses in every form gh accepts (`OWNER/REPO`,
# `HOST/OWNER/REPO`, a `https://`/`ssh://` URL, scp `git@host:o/r(.git)`);
# a value holding `$` or a backtick, one that doesn't parse, or a repo
# command with NOTHING to resolve is an UNRESOLVABLE target: it blocks,
# never bypassable, with a line telling the agent to pass the literal
# owner/repo.
#
# EFFECTIVE DIRECTORY / EXPORTED STATE: the same tracking as the sibling —
# `cd`/`pushd`/`popd` (compounding), `export`/`declare -x`/`typeset -x`/
# `unset`, GIT_DIR/GIT_WORK_TREE pointing the remote reading elsewhere, and a
# `V=VALUE` assignment in the gh command's own prefix beating an exported
# value.
#
# UNBLOCK: the env var `SYG_PUBLISH_CHECKED`,
# read ONLY from the session
# environment the hook process runs in (never from the command text — a
# prefix assignment on the gh command does NOT bypass). For repos, the
# resolved target slug (case-insensitive) must be a colon-separated member of
# the env's list, and EVERY target of the command must be covered. For a gist
# (no repo target) any non-empty env value unblocks. No other unblock exists,
# by design — a gate is satisfied or escalated; the owner can always run the
# command herself via `!`. Known publish paths the gate does NOT see are
# listed under KNOWN GAPS below.
#
# KNOWN GAPS (accepted, not fixed here):
#   - `gh repo create three --public` with a BARE positional name blocks as
#     UNRESOLVABLE (gh would default the owner to the authenticated user,
#     which only a network call could name); pass `OWNER/NAME`. A
#     `-R`/`--repo` value is still parsed for parity, but gh 2.101 rejects
#     `-R` on the repo commands client-side — the positional is the real
#     carrier.
#   - `gh api -X PATCH repos/o/r --input body.json` (an `--input <file>`
#     whose body is not in the command text, or any write whose field values
#     are not visible there) carries no inspectable `private`/`visibility`
#     field and passes; so does an explicit `-X PATCH`/`-X PUT`/`-X POST`
#     with no field flags, and a field spelled `private=0`. An `--input -`
#     body built so the literal never appears in the command text (a printf
#     `%s` substitution, a key spelled with JSON unicode escapes, a variable or
#     a file read) passes too.
#   - `--public=false` (a pflag boolean spelled with a value) is read as a
#     publish — an accepted over-block.
#   - `gh api graphql` mutations are not inspected; a `GH_REPO` exported by
#     an EARLIER Bash tool call is invisible; the other sibling gaps about
#     subshell scope, run-time values and stdin-fed operands apply here too.
#
# FAIL-OPEN: no jq/python3/git, unparsable JSON or command, or an internal
# python error → exit 0 (allow). A command with no WORD-BOUNDED `gh` mention
# skips straight past a cheap bash prefilter without spawning python.
#
# The command goes to python on fd 3, never through the environment: Linux
# caps one env string at 128 KiB (MAX_ARG_STRLEN). Python's own stderr is
# discarded on the result capture.
#
# Fixture check: run hooks/publish-gate.probe.sh after ANY edit to this hook.

set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

INPUT=$(cat)
TOOL_NAME=$(jq -r '.tool_name // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ "$TOOL_NAME" != "Bash" ] && exit 0

CMD=$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ -z "$CMD" ] && exit 0

# Cheap prefilter: only a command with a WORD-BOUNDED "gh" mention can be a
# publish (same shape as the sibling's: "night" and "highlight" never spawn
# python; "/usr/bin/gh" still does).
if ! [[ "$CMD" =~ (^|[^[:alnum:]_.-])gh([^[:alnum:]_-]|$) ]]; then
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
from shell_quotes import strip_redirections, unwrap_runners
from shell_state import State, TRACKED_ENV, do_cd, do_popd, do_pushd, expand_home, walk

cmd = os.fsdecode(open(3, "rb").read()).removesuffix("\n")
payload_cwd = os.environ.get("CWD") or "."

ASSIGN_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$")

REPO_VERBS = ("edit", "create", "new")
GIST_VERBS = ("create", "new")
API_FIELD_FLAGS = {"--field", "--raw-field", "--input"}

# VALUE-TAKING flags per (group, subcommand), as (short, long) with short
# None for a long-only flag. Built from the `--help` output of gh 2.101.0
# for every subcommand this hook recognizes; any flag NOT listed is a
# boolean (takes no value word). Only needed so a value word is never
# mistaken for a positional operand, and a boolean never swallows one.
_REPO_EDIT = [
    (None, "--add-topic"), (None, "--default-branch"),
    ("-d", "--description"), ("-h", "--homepage"),
    (None, "--remove-topic"), (None, "--squash-merge-commit-message"),
    (None, "--visibility"),
]
_REPO_CREATE = [
    ("-d", "--description"), ("-g", "--gitignore"), ("-h", "--homepage"),
    ("-l", "--license"), ("-r", "--remote"), ("-s", "--source"),
    ("-t", "--team"), ("-p", "--template"),
]
_GIST_CREATE = [("-d", "--desc"), ("-f", "--filename")]
_API = [
    (None, "--cache"), ("-F", "--field"), ("-H", "--header"),
    (None, "--hostname"), (None, "--input"), ("-q", "--jq"),
    ("-X", "--method"), ("-p", "--preview"), ("-f", "--raw-field"),
    ("-t", "--template"),
]
# gh's inherited flag, valid before or after the subcommand word. `repo` and
# `api` get it (matching the sibling); `gist` does not — gh gist has no -R.
# NOTE: on gh 2.101.0 the repo commands take no -R (--help rejects it
# client-side: "unknown shorthand flag: 'R'"); the real repo target rides the
# POSITIONAL operand and is resolved in judge(). -R stays in the table for
# sibling parity and is harmless (gh rejects the command anyway).
INHERITED = [("-R", "--repo")]


def _compile_table(entries, inherited):
    entries = inherited + entries
    return ({s: l for s, l in entries if s}, {l for _, l in entries})


FLAG_TABLES = {
    ("repo", "edit"): _compile_table(_REPO_EDIT, INHERITED),
    ("repo", "create"): _compile_table(_REPO_CREATE, INHERITED),
    ("repo", "new"): _compile_table(_REPO_CREATE, INHERITED),
    ("gist", "create"): _compile_table(_GIST_CREATE, []),
    ("gist", "new"): _compile_table(_GIST_CREATE, []),
    ("api",): _compile_table(_API, INHERITED),
}
DEFAULT_FLAG_TABLE = _compile_table([], INHERITED)

# PATCH/PUT on the bare repo endpoint is the repo-edit call; a subpath
# (actions/, branches/, …) is a different write and is not judged here.
REPO_ENDPOINT_RE = re.compile(
    r"^(?:https://api\.github\.com/)?/?repos/([^/]+)/([^/?]+)(?:/)?(?:\?.*)?$"
)


def flag_table(operands):
    """The (short→long, value-long set) table for the subcommand known so
    far: `api` once the first operand is `api`, `(group, sub)` once both
    words are in; before that, only the inherited flags."""
    if operands and operands[0] == "api":
        key = ("api",)
    elif len(operands) >= 2:
        key = (operands[0], operands[1])
    else:
        key = None
    return FLAG_TABLES.get(key, DEFAULT_FLAG_TABLE)


def parse_gh_args(words):
    """words = argv[1:] of a (post-unwrap) gh invocation. Returns
    (repo_flag, operands, method, any_field, field_values, visibility,
    public_bool, input_given), where any_field means a field-family flag of
    the current subcommand's table was given, field_values lists the
    `-f`/`-F` k=v values, visibility is the `--visibility` value, public_bool
    means a boolean `-p`/`--public` was given, and input_given means an
    `--input` (any value) was given."""
    repo_flag = None
    operands = []
    method = None
    any_field = False
    field_values = []
    visibility = None
    public_bool = False
    input_given = False

    def record(long_name, value):
        nonlocal repo_flag, method, any_field, visibility, input_given
        if long_name == "--repo":
            repo_flag = value
        elif long_name == "--method":
            method = value
        elif long_name == "--visibility":
            visibility = value
        elif long_name in API_FIELD_FLAGS:
            any_field = True
            if long_name == "--input":
                input_given = True
            elif value is not None:
                field_values.append(value)

    i = 0
    n = len(words)
    while i < n:
        w = words[i]
        if w == "--":
            operands.extend(words[i + 1:])
            break
        shorts, value_longs = flag_table(operands)
        if w.startswith("--"):
            name, eq, val = w.partition("=")
            if name in value_longs:
                if eq:
                    record(name, val)
                    i += 1
                else:
                    record(name, words[i + 1] if i + 1 < n else None)
                    i += 2
            else:
                if name == "--public":
                    public_bool = True
                i += 1  # a boolean long flag (or unknown): no value word
            continue
        if w.startswith("-") and len(w) > 1:
            # A short-flag cluster, read like gh's flag library (pflag):
            # booleans may be clustered (`-pw`); the first value flag takes
            # the rest of the word (`-fbody`, `-f=body`) or else the next
            # word.
            consumed_next = False
            j = 1
            while j < len(w):
                short = "-" + w[j]
                rest = w[j + 1:]
                if rest.startswith("="):
                    if short in shorts:
                        record(shorts[short], rest[1:])
                    break
                if short in shorts:
                    if rest:
                        record(shorts[short], rest)
                    else:
                        record(shorts[short], words[i + 1] if i + 1 < n else None)
                        consumed_next = True
                    break
                if short == "-p":
                    public_bool = True
                j += 1  # a boolean short flag: keep reading the cluster
            i += 2 if consumed_next else 1
            continue
        operands.append(w)
        i += 1
    return (repo_flag, operands, method, any_field, field_values, visibility,
            public_bool, input_given)


def field_flips_public(value):
    """True when a `-f`/`-F` value is `private=false` or `visibility=public`
    (keys and values case-insensitive)."""
    key, eq, val = value.partition("=")
    if not eq:
        return False
    k = key.strip().lower()
    v = val.strip().lower()
    return (k == "private" and v == "false") or (k == "visibility" and v == "public")


# The JSON form of the same flip, for an `--input` body visible in the command
# text (case-insensitive, like the field form). Quotes around the key and the
# value are optional and may be backslash-escaped, so a double-quoted shell
# string (`echo "{\"private\": false}"`) and a jq object literal
# (`jq -n '{private:false}'`) both match. The word guards keep `isprivate` /
# `falsehood` out.
INPUT_BODY_FLIP_RE = re.compile(
    r'(?<!\w)\\*"?private\\*"?\s*:\s*false(?!\w)'
    r'|(?<!\w)\\*"?visibility\\*"?\s*:\s*\\*"?public(?!\w)',
    re.IGNORECASE,
)


def gh_publication(unwrapped_argv):
    """Return a dict describing the publish, or None (not a publish)."""
    # Redirections (`2>&1`, `>out.txt 2>&1`, …) belong to the shell, never to
    # gh's argv: left in, `2>&1` parses as a positional operand and a trailing
    # one is read as the repo target, degrading an explicit `-R`/positional
    # resolution to UNRESOLVABLE. The runner-prefix words judge() scans for
    # TRACKED_ENV assignments are stripped separately (by unwrap_runners) and
    # stay untouched.
    words = strip_redirections(unwrapped_argv[1:])
    (repo_flag, operands, method, any_field, field_values, visibility, public,
     input_given) = parse_gh_args(words)
    if not operands:
        return None
    head = operands[0]
    if head == "repo" and len(operands) >= 2 and operands[1] in REPO_VERBS:
        verb = "create" if operands[1] == "new" else operands[1]
        if verb == "edit":
            hit = visibility is not None and visibility.lower() == "public"
        else:
            hit = public
        if not hit:
            return None
        # The first positional operand after the verb: on gh 2.101.0 this (not
        # -R) is what carries the target for `repo edit [<repository>]` and
        # `gh repo create [<name>]`.
        return {
            "gist": False, "api": False,
            "kind": f"gh repo {verb}",
            "repo_flag": repo_flag,
            "positional": operands[2] if len(operands) >= 3 else None,
        }
    if head == "gist" and len(operands) >= 2 and operands[1] in GIST_VERBS:
        if not public:
            return None
        return {"gist": True, "api": False, "kind": "gh gist create"}
    if head == "api" and len(operands) >= 2:
        m = REPO_ENDPOINT_RE.match(operands[1])
        if not m:
            return None
        explicit_method = method.upper() if method else None
        # Explicit POST is a write like the implicit one (gh's default); GET stays out.
        if explicit_method:
            is_write = explicit_method in ("PATCH", "PUT", "POST")
        else:
            is_write = any_field
        if not is_write:
            return None
        # An `--input` body fed on stdin (here-string, heredoc, `echo … |`)
        # sits in the command text, not in a field flag: with any `--input`,
        # the WHOLE command text is scanned for the JSON flip as well.
        flips = any(field_flips_public(v) for v in field_values) or (
            input_given and INPUT_BODY_FLIP_RE.search(cmd) is not None
        )
        if not flips:
            return None
        meth_label = explicit_method or "POST"
        return {
            "gist": False, "api": True,
            "kind": f"gh api {meth_label} {operands[1]}",
            "endpoint": (m.group(1), m.group(2)),
            "repo_flag": None,
        }
    return None


def parse_repo_value(value):
    """(owner, repo) from a -R/--repo/GH_REPO value in any form gh accepts —
    `OWNER/REPO`, `HOST/OWNER/REPO`, a `scheme://[user@]host/o/r` URL
    (https, ssh, …; `.git` optional) or scp `[user@]host:o/r(.git)` — else
    None."""
    if "://" in value:
        m = re.match(
            r"^[A-Za-z][\w+.-]*://(?:[^@/]+@)?[^/:]+(?::\d+)?/([^/]+)/([^/]+?)(?:\.git)?/?$",
            value,
        )
        return (m.group(1), m.group(2)) if m else None
    m = re.match(r"^(?:[^@/:]+@)?[^/:]+:([^/]+)/([^/]+?)(?:\.git)?/?$", value)
    if m:
        return (m.group(1), m.group(2))
    parts = value.split("/")
    if len(parts) in (2, 3) and all(parts):
        return (parts[-2], parts[-1])
    return None


# A target the hook cannot read: a -R/--repo/GH_REPO value holding `$` or a
# backtick (resolved only at run time), one that doesn't parse, or a repo
# command with nothing to resolve. gh never consults the remotes once such a
# value is given, so it is judged as a target of its own — never owned,
# never bypassable.
UNRESOLVABLE = ("\0unresolvable", "\0unresolvable")
UNRESOLVABLE_DISPLAY = "an unresolvable target (pass the literal owner/repo to name it)"


def explicit_target(value):
    """The target a -R/--repo/GH_REPO value names: None when unset or empty
    (gh then falls back to the remotes, as the empty `-R ""` does),
    UNRESOLVABLE when it can't be read, else (owner, repo)."""
    if not value:
        return None
    if "$" in value or "`" in value:
        return UNRESOLVABLE
    return parse_repo_value(value) or UNRESOLVABLE


def parse_github_remote_url(url):
    """Parse a git remote URL into (owner, repo) if its host is a GitHub
    candidate (contains "github", case-insensitive, after stripping a
    leading www./ssh.), else None. Userinfo (a token) is discarded, never
    returned or logged."""
    try:
        if "://" in url:
            m = re.match(r"^\w+://(?:[^@/]+@)?([^/:]+)(?::\d+)?/(.+)$", url)
            if not m:
                return None
            host, path = m.group(1), m.group(2)
        else:
            m = re.match(r"^(?:[^@/]+@)?([^:/]+):(.+)$", url)
            if not m:
                return None
            host, path = m.group(1), m.group(2)
        host = host.lower()
        host = re.sub(r"^(www\.|ssh\.)", "", host)
        if "github" not in host:
            return None
        path = path.rstrip("/")
        if path.endswith(".git"):
            path = path[: -len(".git")]
        parts = path.split("/")
        if len(parts) != 2 or not parts[0] or not parts[1]:
            return None
        return (parts[0], parts[1])
    except Exception:
        return None


def git_argv(dir_, git_dir, work_tree):
    """`git -C DIR [--git-dir=…] [--work-tree=…]`: a GIT_DIR/GIT_WORK_TREE
    the gh command would inherit points the remote reading at that repo; a
    relative value resolves against DIR, as git's own `-C` then `--git-dir`
    order does."""
    argv = ["git", "-C", dir_]
    if git_dir:
        argv.append(f"--git-dir={git_dir}")
    if work_tree:
        argv.append(f"--work-tree={work_tree}")
    return argv


def git_run(base, *args):
    try:
        r = subprocess.run(
            base + list(args),
            capture_output=True, text=True, errors="replace", timeout=5,
        )
    except Exception:
        return None
    return r.stdout if r.returncode == 0 else None


def git_config(base, key):
    out = git_run(base, "config", "--get", key)
    return out.strip() if out is not None else None


def git_remote_get_url(base, name):
    out = git_run(base, "remote", "get-url", name)
    return out.strip() if out is not None else None


def git_remotes_targets(effective_dir, git_dir=None, work_tree=None):
    base = git_argv(effective_dir, git_dir, work_tree)
    out = git_run(base, "remote")
    if out is None:
        return []
    names = [line.strip() for line in out.splitlines() if line.strip()]
    candidates = []
    resolved = []
    for name in names:
        url = git_remote_get_url(base, name)
        parsed = parse_github_remote_url(url) if url else None
        if parsed:
            candidates.append(parsed)
        gh_resolved = git_config(base, f"remote.{name}.gh-resolved")
        if gh_resolved == "base":
            if parsed:
                resolved.append(parsed)
        elif gh_resolved:
            m = re.match(r"^([^/\s]+)/([^/\s]+)$", gh_resolved)
            if m:
                resolved.append((m.group(1), m.group(2)))
    if resolved:
        seen = []
        for t in resolved:
            if t not in seen:
                seen.append(t)
        return seen
    return candidates


# Runner prefixes that still run the shell builtin: `builtin cd x`, `command cd x`.
BUILTIN_RUNNERS = {"builtin", "command"}

# The shell-state machine (State, cd/pushd/popd, walk) is lib/shell_state.py, shared with upstream-submission-guard.sh.


def do_export(state, args, declare):
    """`export [-n] NAME=V…`, `declare`/`typeset [-x|+x] NAME=V…`."""
    exporting = not declare
    unexport = False
    i = 0
    while i < len(args) and args[i][:1] in ("-", "+") and len(args[i]) > 1:
        opt = args[i]
        i += 1
        if opt == "--":
            break
        letters = opt[1:]
        if "f" in letters:
            return  # functions, not variables
        if opt.startswith("+"):
            if declare and "x" in letters:
                unexport = True
        elif declare:
            if "x" in letters:
                exporting = True
        elif "n" in letters:
            unexport = True  # export -n
    for w in args[i:]:
        m = ASSIGN_RE.match(w)
        name = m.group(1) if m else w
        if name not in TRACKED_ENV:
            continue
        if unexport:
            state.env.pop(name, None)
        elif exporting and m:
            state.env[name] = m.group(2)


def do_unset(state, args):
    i = 0
    while i < len(args) and args[i].startswith("-"):
        opt = args[i]
        i += 1
        if opt == "--":
            break
        if "f" in opt[1:]:
            return  # unset -f: functions
    for w in args[i:]:
        state.env.pop(w, None)


def usable_git_path(value):
    """A GIT_DIR/GIT_WORK_TREE value the hook can hand to git, else None (a
    `$`/backtick value is resolved only at run time; the directory's own repo
    is read instead)."""
    if not value or "$" in value or "`" in value:
        return None
    return expand_home(value)


class Context:
    def __init__(self):
        self.blocking = []  # (kind, gist?, {display owner/repo}, unresolvable?)
        self.visited = set()  # State snapshots the text passes through
        self.judged = set()  # argv tuples judged in execution order
        self.leftovers = []  # (span, depth) not placed at a command
        self.leftover_mode = False


def judge(argv, unwrapped, state, ctx):
    # GH_REPO / GIT_DIR / GIT_WORK_TREE in THIS command's own prefix: the
    # words unwrap_runners consumed off the front (assignments and runner
    # names, including `env VAR=v gh ...`), read before they were stripped;
    # a prefix value beats an exported one. SYG_PUBLISH_CHECKED is
    # deliberately NOT read here — it unblocks only from the session
    # environment the hook process runs in.
    prefix = argv[: max(0, len(argv) - len(unwrapped))]
    env = dict(state.env)
    for w in prefix:
        m = ASSIGN_RE.match(w)
        if not m:
            continue
        key, val = m.group(1), m.group(2)
        if key in TRACKED_ENV:
            env[key] = val

    sub = gh_publication(unwrapped)
    if sub is None:
        return

    def remotes():
        return git_remotes_targets(
            state.cwd, usable_git_path(env.get("GIT_DIR")),
            usable_git_path(env.get("GIT_WORK_TREE")),
        )

    if sub["gist"]:
        ctx.blocking.append((sub["kind"], True, set(), False))
        return

    if sub["api"]:
        o, r = sub["endpoint"]
        o_ph, r_ph = o == "{owner}", r == "{repo}"
        gh_repo = explicit_target(env.get("GH_REPO"))
        if not o_ph and not r_ph:
            targets = [(o, r)]  # a literal endpoint: gh ignores GH_REPO
        elif gh_repo == UNRESOLVABLE:
            targets = [UNRESOLVABLE]
        else:
            bases = [gh_repo] if gh_repo else remotes()
            if bases:
                targets = [(b[0] if o_ph else o, b[1] if r_ph else r) for b in bases]
            elif not o_ph:
                targets = [(o, r)]  # the owner is literal; shown as `o/{repo}`
            else:
                targets = [UNRESOLVABLE]
    else:
        gh_repo = explicit_target(env.get("GH_REPO"))
        # Resolution order: the positional operand (what gh 2.101 actually
        # reads for repo edit/create), else -R/--repo, else GH_REPO, else the
        # remotes. A bare positional name (`gh repo create three --public`)
        # parses to no slug — the owner would be the authenticated user,
        # unknowable without a network call — so it is UNRESOLVABLE
        # (fail-closed), same as a `$`/backtick value.
        if sub["positional"] is not None:
            explicit = explicit_target(sub["positional"])
        elif sub["repo_flag"]:
            explicit = explicit_target(sub["repo_flag"])
        else:
            explicit = gh_repo
        targets = [explicit] if explicit else remotes()
        if not targets:
            targets = [UNRESOLVABLE]

    displays = set()
    unresolvable = False
    for t in targets:
        if t == UNRESOLVABLE:
            unresolvable = True
            continue
        o, r = t
        if not o or not r:
            continue
        displays.add(f"{o}/{r}")
    if not displays and not unresolvable:
        return
    ctx.blocking.append((sub["kind"], False, displays, unresolvable))


def run_command(argv, state, ctx):
    unwrapped, info = unwrap_runners(argv)
    if not unwrapped:
        return
    name = unwrapped[0]
    if set(info["runners"]) <= BUILTIN_RUNNERS:
        args = strip_redirections(unwrapped[1:])
        if name == "cd":
            do_cd(state, args)
            return
        if name == "pushd":
            do_pushd(state, args)
            return
        if name == "popd":
            do_popd(state, args)
            return
        if name in ("export", "declare", "typeset"):
            do_export(state, args, declare=name != "export")
            return
        if name == "unset":
            do_unset(state, args)
            return
    if name.rsplit("/", 1)[-1] != "gh":
        return
    key = tuple(argv)
    if ctx.leftover_mode:
        if key in ctx.judged:
            return  # already judged at its real position
    else:
        ctx.judged.add(key)
    judge(argv, unwrapped, state, ctx)


ctx = Context()
walk(cmd, 0, State(payload_cwd, payload_cwd=payload_cwd), ctx, run_command)

# A substitution span the walk couldn't place at a command (its text doesn't
# survive into any word as written, e.g. one holding inner quotes) is judged
# against EVERY state the text passed through: block if any resolves.
ctx.leftover_mode = True
states = sorted(ctx.visited)
done = set()
while ctx.leftovers:
    span, depth = ctx.leftovers.pop(0)
    if (span, depth) in done:
        continue
    done.add((span, depth))
    for cwd, env in states:
        walk(span, depth, State(cwd, dict(env), payload_cwd), ctx, run_command)

if not ctx.blocking:
    sys.exit(0)

kinds = sorted({k for k, _, _, _ in ctx.blocking})
kind_label = kinds[0] if len(kinds) == 1 else "gh command"
gist = any(g for _, g, _, _ in ctx.blocking)
unresolvable = any(u for _, _, _, u in ctx.blocking)
displays = set()
slugs = set()
for _, g, ds, u in ctx.blocking:
    displays |= ds
# slugs come from real owner/repo targets only; the gist placeholder names
# no slug (any non-empty env value unblocks it), and an unresolvable target
# names none either (never bypassable).
for d in displays:
    slugs.add(d.lower())
if gist and not displays:
    displays.add("a gist")  # a gist has no repo target to name
elif unresolvable and not displays:
    displays.add(UNRESOLVABLE_DISPLAY)
print(" ".join(kind_label.split()))
print("1" if gist else "0")
print("1" if unresolvable else "0")
print(" ".join(", ".join(sorted(displays)).split()))
print(":".join(sorted(slugs)))
PYEOF
) || exit 0

[ -n "$RESULT" ] || exit 0

KIND=$(printf '%s\n' "$RESULT" | sed -n '1p')
GIST=$(printf '%s\n' "$RESULT" | sed -n '2p')
UNRESOLVABLE=$(printf '%s\n' "$RESULT" | sed -n '3p')
DISPLAYS=$(printf '%s\n' "$RESULT" | sed -n '4p')
SLUGS=$(printf '%s\n' "$RESULT" | sed -n '5p')

# The unblock lives in the SESSION environment the hook process runs in —
# never in the command text (a prefix assignment on the gh command is not a
# bypass). For repos every target slug must be a colon-separated member
# (case-insensitive); for a gist any non-empty value unblocks; an
# unresolvable target is never bypassable.
checked="${SYG_PUBLISH_CHECKED:-}"
ok=1
if [ "$UNRESOLVABLE" = 1 ]; then
  ok=0
fi
if [ -n "$SLUGS" ]; then
  allowed=":$(printf '%s' "$checked" | tr '[:upper:]' '[:lower:]'):"
  oldIFS=$IFS
  IFS=':'
  for slug in $SLUGS; do
    case "$allowed" in
      *":$slug:"*) ;;
      *) ok=0 ;;
    esac
  done
  IFS=$oldIFS
fi
if [ "$GIST" = 1 ] && [ -z "$checked" ]; then
  ok=0
fi
[ "$ok" = 1 ] && exit 0

if [ "$GIST" = 1 ] && [ -z "$SLUGS" ]; then
  SLUG_HINT="<any non-empty value>"
elif [ -n "$SLUGS" ]; then
  SLUG_HINT="$SLUGS"
else
  SLUG_HINT="<owner/repo>"
fi

{
echo "blocked: $KIND would make $DISPLAYS public. Run the going-public checklist (seyag:going-public) for it first; on pass set SYG_PUBLISH_CHECKED=$SLUG_HINT (colon-list ok; any non-empty value for a gist) (it is read from the session's environment at start: the owner restarts the session with it exported, or runs the command herself with \`!\`)."
if [ "$UNRESOLVABLE" = 1 ]; then
cat <<'EOF'
The target can't be read from the command text (a variable, a substitution,
an unparsable value, or nothing to resolve): re-run with the literal
owner/repo so it can be judged (the env unblock then works).
EOF
fi
} >&2
exit 2
