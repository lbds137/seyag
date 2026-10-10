#!/bin/bash
# PreToolUse hook (matcher: Bash) — blocks a `gh` command that would SUBMIT
# something (a PR, an issue, a comment, a review, an edit, a commented
# close/reopen, or a write via `gh api`) to a repo the owner does not own,
# until the project's
# stance on AI-assisted contributions has been checked. The owner's standing
# rule (shared memory, "Upstream AI stance first") is to check a project's
# stance on AI-assisted work before any upstream PR, issue or advisory; this
# hook makes that check structural instead of relying on remembering it.
#
# WHAT COUNTS AS A SUBMISSION (after `unwrap_runners` strips assignments and
# runner prefixes so argv[0] is the real program):
#   - `gh pr create`/`gh pr new`, `gh issue create`/`gh issue new`,
#     `gh pr comment`, `gh issue comment`, `gh pr review`, `gh pr edit`,
#     `gh issue edit`;
#   - `gh pr close`/`gh issue close`/`gh pr reopen`/`gh issue reopen` ONLY
#     when given `-c`/`--comment` (separate, `-cVALUE`, `-c=VALUE` or
#     `--comment=VALUE`; posts a comment with the state change); a bare
#     close/reopen is a no-content state change, not a submission, and passes;
#   - `gh api` with an explicit POST/PATCH/PUT (`-X`/`--method`, attached
#     [`-XPOST`, `-X=POST`], `=`-joined or separate, case-insensitive) or an
#     IMPLICIT POST (`-f`/`-F`/`--field`/`--raw-field`/`--input`, in any of
#     their attached [`-ftitle=a`], `=`-joined [`--field=k=v`] or separate
#     forms, present with no explicit method), to an endpoint matching
#     `repos/OWNER/REPO/(issues|pulls|security-advisories|commits/SHA/comments|comments)`
#     followed by nothing, a `/…` path or a `?…` query string (a leading `/`
#     and an `https://api.github.com/` prefix are both optional; `comments/N`
#     is a commit-comment edit).
# WHERE COMMANDS ARE FOUND, in EXECUTION order: the splitter's top-level
# pipelines; a wrapper's string (`bash -c '…'`, `eval "…"`, …) right after
# the pipeline that runs it; a command substitution (`$(…)` or backticks,
# quoted or not: `url="$(gh pr create …)"`, `echo "$(gh …)"`) right before
# the command whose word holds it. Wrapper and substitution commands run in a
# child shell, so their `cd`/`export` don't leak back out. A substitution
# the walk can't place at a command (its text survives into no word, e.g. a
# quoted `"$(gh … --title "x y")"` whose inner quotes bash removes) is
# judged against EVERY state the text passes
# through (each directory and exported value), blocking if any is non-own.
# FLAG PARSING: which flags take a value word is looked up in a table PER
# (group, subcommand), built from gh 2.101.0's own `--help` output — a short
# flag means different things per subcommand (`pr review -a/-r/-c` are
# booleans, `pr create -a/-r` take values; `-f`/`-F` are `--fill`/
# `--body-file` for `pr create` but field flags for `gh api`). A flag not in
# the table is a boolean. Short flags are read the way gh's flag library
# reads them: `-x value`, `-xvalue`, `-x=value`, and boolean clusters
# (`-dcbye` = `-d -c bye`); long flags as `--flag value` or `--flag=value`.
# `-R`/`--repo` is accepted before or after the subcommand.
# Anything else — a read (`gh pr view`, `gh pr checks`, `gh api` GET, a bare
# `gh pr close`/`gh pr reopen`) — passes.
#
# TARGET RESOLUTION, mirroring how gh itself picks a repo, LOCAL config only
# (no network call is made). For `gh api` (which has no `-R`):
#   1. a LITERAL `repos/OWNER/REPO/` in the endpoint — wins even over GH_REPO,
#      since gh only consults GH_REPO for an `{owner}`/`{repo}` placeholder;
#   2. else GH_REPO (see below), or else the effective directory's git
#      remotes (below), fills each placeholder; a literal part stays, so
#      `repos/other/{repo}/…` judges owner `other` (shown as `other/{repo}`
#      when nothing names the repo).
# For `pr`/`issue` commands, TWO kinds of target can coexist and are BOTH
# judged (block if either is non-own): an EXPLICIT target (`-R`/`--repo` on
# this gh invocation, the last one winning, else GH_REPO) and a URL target
# (every operand of a `comment`/`review`/`edit`/`close -c`/`reopen -c`
# command is scanned, not just one position, for an
# `http(s)://[www.]github.com/OWNER/REPO/(pull|issues)/N` link, host in any
# case). Neither present → the effective directory's git remotes.
# An explicit value parses in every form gh accepts: `OWNER/REPO`,
# `HOST/OWNER/REPO`, a `https://`/`ssh://` URL, scp `git@host:o/r(.git)`. gh
# never consults the remotes once one is given, so a value holding `$` or a
# backtick (`-R "$r"`, resolved only at run time) or one that doesn't parse
# is an UNVERIFIABLE target: it blocks, never bypassable, with a line telling
# the agent to pass the literal owner/repo. An empty value (`-R ""`) is unset,
# as in gh.
#
# EXPORTED STATE, tracked through the command text in execution order:
# `export V=x`, `declare -x`/`typeset -x V=x` set; `unset [-v] V`,
# `export -n V`, `declare +x V` clear. For GH_REPO, GIT_DIR and GIT_WORK_TREE,
# a `V=VALUE` assignment in THIS gh command's own prefix (the words
# `unwrap_runners` stripped off the front, so `env V=x gh …` counts too)
# beats the exported value. GIT_DIR/GIT_WORK_TREE point the remote reading at
# that repo (`git --git-dir=… --work-tree=…`); a `$`/backtick value is
# ignored (the directory's own repo is read).
#
# EFFECTIVE DIRECTORY for git-remote resolution: starts at the payload cwd;
# each `cd` earlier in the command text updates it, COMPOUNDING (a relative
# target resolves against the CURRENT effective directory, so `cd a && cd b`
# lands in `a/b`). Read the way bash does: options `-P`/`-L`/`-e`/`-@` and
# `--` before the target, `builtin cd`/`command cd`, bare `cd` → `$HOME`,
# `cd -` → the previous directory, `pushd DIR` (cd, pushing the old one),
# bare `pushd` (swap), `popd` (pop back); an invalid option or two operands
# is bash's own error and changes nothing. An unresolvable form resets the
# effective directory to the payload cwd: a target holding `$`, a backtick or
# a glob char, `cd -` with no earlier directory, `popd`/bare `pushd` on a
# stack this text didn't build, and `pushd`/`popd` `-n`/`+N`/`-N`.
#
# REMOTES: for each remote of the effective directory, `git remote get-url`
# (so a `url.<base>.insteadOf` rewrite is honored) is parsed for its host and
# owner/repo: userinfo (`user[:pass]@`) is stripped, the host is lowercased
# and a leading `www.`/`ssh.` is stripped, `http://`/`https://`/`ssh://`
# (with an optional port, e.g. `ssh://git@ssh.github.com:443/o/r.git`) and
# bare `git@host:o/r` (scp syntax) are all accepted, and any host CONTAINING
# "github" is a candidate (covers a personal ssh alias like
# `git@github.com-work:o/r.git`). Only candidates are judged; a non-GitHub
# remote is ignored outright. `remote.<name>.gh-resolved` (what
# `gh repo set-default` writes) set to `base` makes that remote's own
# owner/repo the sole target; set to a literal `owner/repo` string, it names
# a DIFFERENT sole target directly (rare, but that's what the field means).
# One or more `gh-resolved` hits always win over the plain candidate list.
# Not a repo, or no GitHub candidates → no targets → allow. A remote URL is
# parsed for its owner/repo only — never printed, logged or echoed (it can
# carry a token in its userinfo).
#
# OWN OWNERS: the `user:` value under the `github.com:` host in
# `${GH_CONFIG_DIR:-$HOME/.config/gh}/hosts.yml` (read with a line scan — the
# file also holds a token, only that one field is ever read), UNIONED with
# `SYG_OWN_OWNERS` (whitespace/comma-separated,
# case-insensitive) when
# it parses to at least one name; a value that parses to nothing (e.g. a bare
# `,`) is the same as leaving it unset. Neither source yields a name →
# allow (fail-open: can't judge).
#
# Blocks (exit 2) when any resolved target's owner is not an own owner
# (case-insensitive; the blocked-repo display keeps the original case).
#
# BYPASS: `SYG_UPSTREAM_CHECKED=<owner/repo>`, read ONLY from the SAME
# gh command's own prefix as GH_REPO above (never from elsewhere in the
# command text — a quoted mention, an unrelated command's prefix, or a
# heredoc body cannot bypass). A repeated assignment on the same gh command
# (`SYG_UPSTREAM_CHECKED=a/b SYG_UPSTREAM_CHECKED=c/d gh …`) is read
# as a SET, not just bash's own last-one-wins value, so two different
# non-own targets on one gh command can each get their own bypass. Passes
# only when every non-own target of THAT gh command is covered (case-
# insensitive).
#
# KNOWN GAPS (accepted, not fixed here):
#   - `gh api graphql` mutations are not inspected (its writes are inside the
#     GraphQL query body, not the HTTP method).
#   - a `GH_REPO` exported by an EARLIER Bash tool call, in a persistent
#     shell, is invisible — only an export within the SAME command text is
#     tracked.
#   - a subshell's cd leaks forward: `(cd fork); gh …`, an UNQUOTED
#     `x=$(cd fork)` and a pipeline stage `cd fork | cat` are read as though
#     the `cd` ran in the current shell, because the underlying command
#     splitter does not model subshell scope (a quoted `"$(…)"` is scoped).
#   - state the same command text changes outside the shell: `git remote
#     add`/`set-url`, `gh repo set-default`, a `cd` into a clone the text
#     creates (`gh repo fork --clone && cd x`) — remotes are read as they are
#     before the command runs.
#   - a URL operand held in a variable (`gh pr comment "$u"`), a program name
#     built at run time (`$(which gh)`), gh aliases, nesting past
#     MAX_WRAPPER_DEPTH.
#   - `env -C DIR` and `sudo -D DIR` change the directory a wrapped command
#     runs in; this hook does not read either.
#   - a `cd` target that isn't a single literal word (a variable, `$(...)`,
#     a backtick, a glob) is unresolvable; see EFFECTIVE DIRECTORY above.
#   - operands fed on stdin or by `xargs` (`echo URL | xargs gh pr comment
#     -b hi`) aren't seen: with no visible URL or `-R`, the local remotes
#     decide the target.
#   - a heredoc BODY is data (the splitter's convention): substitutions are
#     scanned in the body-stripped text, so a script written to disk through
#     `cat > f <<'EOF'` or a PR body mentioning `$(gh …)` passes. The cost is
#     an accepted UNDER-arm: an UNQUOTED-delimiter body (`<<EOF`) really runs
#     its `$(gh …)`, and that is not seen. A body a shell reads as its script
#     (`cat <<'EOF' | bash`, `bash <<'EOF'`) is scanned in full.
#   - OVER-BLOCK: when the text also holds a shell word (`bash`, `sh`, …),
#     `eval` or a heredoc, the splitter extracts substitutions from
#     single-quoted text too, so `echo '$(gh pr create -R other/x)'; bash -c
#     true` blocks.
#   - a substitution the walk can't place at a command (see WHERE COMMANDS
#     ARE FOUND) is judged against every state the text visits, so a later
#     `cd` into a fork can over-block it.
#
# FAIL-OPEN: no jq/python3/git, unparsable JSON or command, an internal
# python error, or no own-owner information → exit 0 (allow). A command with
# no WORD-BOUNDED `gh` mention skips straight past a cheap bash prefilter
# without spawning python — the sub-100ms path for the overwhelming majority
# of commands ("night", "high" and similar words that merely CONTAIN the
# letters g-h do not spawn python; `/usr/bin/gh` still does).
#
# The command goes to python on fd 3, never through the environment: Linux
# caps one env string at 128 KiB (MAX_ARG_STRLEN), and python failing to
# exec would fail open. Python's own stderr is discarded on the result
# capture, and the git-reading helpers decode with errors="replace" and
# catch any exception, so a non-UTF-8 byte in a remote URL or config value
# can never leak a traceback into the hook's output — it just fails to
# parse, same as any other unparsable remote.
#
# Fixture check: run hooks/upstream-submission-guard.probe.sh after ANY edit
# to this hook.

set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

INPUT=$(cat)
TOOL_NAME=$(jq -r '.tool_name // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ "$TOOL_NAME" != "Bash" ] && exit 0

CMD=$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ -z "$CMD" ] && exit 0

# Cheap prefilter: only a command with a WORD-BOUNDED "gh" mention can be a
# submission (a run of alnum/`_`/`.`/`-` on either side means it's part of a
# longer word: "night", "high", "highlight" never match; "/usr/bin/gh",
# "gh", "; gh " do). Loose about which boundary chars count on purpose —
# python decides the real structure; this only saves the python spawn for
# the overwhelming majority of commands that never mention gh.
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

CREATE_PAIRS = {("pr", "create"), ("issue", "create"), ("pr", "new"), ("issue", "new")}
COMMENT_PAIRS = {("pr", "comment"), ("issue", "comment")}
REVIEW_PAIRS = {("pr", "review")}
EDIT_PAIRS = {("pr", "edit"), ("issue", "edit")}
CLOSE_PAIRS = {("pr", "close"), ("issue", "close")}
REOPEN_PAIRS = {("pr", "reopen"), ("issue", "reopen")}
# close/reopen are submissions only when they carry a -c/--comment.
COMMENT_GATED_PAIRS = CLOSE_PAIRS | REOPEN_PAIRS
URL_SCAN_PAIRS = COMMENT_PAIRS | REVIEW_PAIRS | EDIT_PAIRS | COMMENT_GATED_PAIRS

# VALUE-TAKING flags per (group, subcommand), as (short, long) with short None
# for a long-only flag. Built from the `--help` output of gh 2.101.0 for every
# subcommand this hook recognizes; any flag NOT listed is a boolean (takes no
# value word). Only needed so a value word is never mistaken for a positional
# operand, and a boolean never swallows one. Per-subcommand because the same
# short flag differs: `pr review -a/-r/-c` are booleans (--approve,
# --request-changes, --comment), `pr create -a/-r` take values.
_PR_CREATE = [
    ("-a", "--assignee"), (None, "--attach"), ("-B", "--base"),
    ("-b", "--body"), ("-F", "--body-file"), ("-H", "--head"),
    ("-l", "--label"), ("-m", "--milestone"), ("-p", "--project"),
    (None, "--recover"), ("-r", "--reviewer"), ("-T", "--template"),
    ("-t", "--title"),
]
_ISSUE_CREATE = [
    ("-a", "--assignee"), (None, "--attach"), (None, "--blocked-by"),
    (None, "--blocking"), ("-b", "--body"), ("-F", "--body-file"),
    ("-l", "--label"), ("-m", "--milestone"), (None, "--parent"),
    ("-p", "--project"), (None, "--recover"), ("-T", "--template"),
    ("-t", "--title"), (None, "--type"),
]
_COMMENT = [(None, "--attach"), ("-b", "--body"), ("-F", "--body-file")]
VALUE_FLAGS = {
    ("pr", "create"): _PR_CREATE,
    ("pr", "new"): _PR_CREATE,
    ("issue", "create"): _ISSUE_CREATE,
    ("issue", "new"): _ISSUE_CREATE,
    ("pr", "comment"): _COMMENT,
    ("issue", "comment"): _COMMENT,
    ("pr", "review"): [("-b", "--body"), ("-F", "--body-file")],
    ("pr", "edit"): [
        (None, "--add-assignee"), (None, "--add-label"),
        (None, "--add-project"), (None, "--add-reviewer"), (None, "--attach"),
        ("-B", "--base"), ("-b", "--body"), ("-F", "--body-file"),
        ("-m", "--milestone"), (None, "--remove-assignee"),
        (None, "--remove-label"), (None, "--remove-project"),
        (None, "--remove-reviewer"), ("-t", "--title"),
    ],
    ("issue", "edit"): [
        (None, "--add-assignee"), (None, "--add-blocked-by"),
        (None, "--add-blocking"), (None, "--add-label"),
        (None, "--add-project"), (None, "--add-sub-issue"), (None, "--attach"),
        ("-b", "--body"), ("-F", "--body-file"), ("-m", "--milestone"),
        (None, "--parent"), (None, "--remove-assignee"),
        (None, "--remove-blocked-by"), (None, "--remove-blocking"),
        (None, "--remove-label"), (None, "--remove-project"),
        (None, "--remove-sub-issue"), ("-t", "--title"), (None, "--type"),
    ],
    ("pr", "close"): [("-c", "--comment")],
    ("issue", "close"): [
        ("-c", "--comment"), (None, "--duplicate-of"), ("-r", "--reason"),
    ],
    ("pr", "reopen"): [("-c", "--comment")],
    ("issue", "reopen"): [("-c", "--comment")],
    ("api",): [
        (None, "--cache"), ("-F", "--field"), ("-H", "--header"),
        (None, "--hostname"), (None, "--input"), ("-q", "--jq"),
        ("-X", "--method"), ("-p", "--preview"), ("-f", "--raw-field"),
        ("-t", "--template"),
    ],
}
# gh's inherited flag, valid before or after the subcommand word (`pr`/`issue`
# persistent flag; accepted anywhere here, as gh has no other `-R`).
INHERITED_VALUE_FLAGS = [("-R", "--repo")]
API_FIELD_FLAGS = {"--field", "--raw-field", "--input"}


def _compile_table(entries):
    entries = INHERITED_VALUE_FLAGS + entries
    return ({s: l for s, l in entries if s}, {l for _, l in entries})


FLAG_TABLES = {key: _compile_table(v) for key, v in VALUE_FLAGS.items()}
DEFAULT_FLAG_TABLE = _compile_table([])

ENDPOINT_RE = re.compile(
    r"^(?:https://api\.github\.com/)?/?repos/([^/]+)/([^/?]+)/(?:"
    r"issues|pulls|security-advisories|commits/[^/?]+/comments|comments"
    r")(?:[/?].*)?$"
)

# http or https, an optional `www.`, the host in any case (owner/repo keep
# their case for display).
GITHUB_URL_RE = re.compile(
    r"^https?://(?i:(?:www\.)?github\.com)/([^/]+)/([^/]+)/(?:pull|issues)/\d+"
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
    (repo_flag_value, operands, method, has_field, has_comment), where
    has_field/has_comment mean a VALUE-taking --field-family/--comment flag
    of the current subcommand's table was given."""
    repo_flag = None
    operands = []
    method = None
    has_field = False
    has_comment = False

    def record(long_name, value):
        nonlocal repo_flag, method, has_field, has_comment
        if long_name == "--repo":
            repo_flag = value
        elif long_name == "--method":
            method = value
        elif long_name in API_FIELD_FLAGS:
            has_field = True
        elif long_name == "--comment":
            has_comment = True

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
                i += 1  # a boolean long flag (or unknown): no value word
            continue
        if w.startswith("-") and len(w) > 1:
            # A short-flag cluster, read like gh's flag library (pflag):
            # booleans may be clustered (`-de`); the first value flag takes
            # the rest of the word (`-cbye`, `-c=bye`) or else the next word.
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
                j += 1  # a boolean short flag: keep reading the cluster
            i += 2 if consumed_next else 1
            continue
        operands.append(w)
        i += 1
    return repo_flag, operands, method, has_field, has_comment


def scan_github_urls(operands):
    urls = []
    for op in operands:
        m = GITHUB_URL_RE.match(op)
        if m:
            urls.append((m.group(1), m.group(2)))
    return urls


def gh_submission(unwrapped_argv):
    """Return a dict describing the submission, or None (not a submission)."""
    words = unwrapped_argv[1:]
    repo_flag, operands, method, has_field, has_comment = parse_gh_args(words)
    if not operands:
        return None
    head = operands[0]
    if head in ("pr", "issue") and len(operands) >= 2:
        pair = (head, operands[1])
        if pair in CREATE_PAIRS:
            return {
                "api": False, "kind": f"gh {head} {operands[1]}",
                "repo_flag": repo_flag, "url_targets": [],
            }
        if pair in URL_SCAN_PAIRS:
            if pair in COMMENT_GATED_PAIRS and not has_comment:
                return None  # a bare close/reopen has no content to submit
            return {
                "api": False, "kind": f"gh {head} {operands[1]}",
                "repo_flag": repo_flag,
                "url_targets": scan_github_urls(operands[2:]),
            }
        return None
    if head == "api":
        if len(operands) < 2:
            return None
        endpoint = operands[1]
        m = ENDPOINT_RE.match(endpoint)
        if not m:
            return None
        owner, repo = m.group(1), m.group(2)
        explicit_method = method.upper() if method else None
        if explicit_method:
            is_write = explicit_method in ("POST", "PATCH", "PUT")
        else:
            is_write = has_field
        if not is_write:
            return None
        meth_label = explicit_method or "POST"
        return {
            "api": True, "kind": f"gh api {meth_label} {endpoint}",
            "repo_flag": None, "endpoint_owner": owner, "endpoint_repo": repo,
            "url_targets": [],
        }
    return None


def parse_repo_value(value):
    """(owner, repo) from a -R/--repo/GH_REPO value in any form gh 2.101.0
    accepts — `OWNER/REPO`, `HOST/OWNER/REPO`, a `scheme://[user@]host/o/r`
    URL (https, ssh, …; `.git` optional) or scp `[user@]host:o/r(.git)` —
    else None."""
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


# A -R/--repo/GH_REPO value the hook cannot read: it holds `$` or a backtick
# (a variable or substitution, resolved only at run time), or it doesn't
# parse. gh never consults the remotes once such a value is given, so it is
# judged as a target of its own — never owned, never bypassable.
UNVERIFIABLE = ("\0unverifiable", "\0unverifiable")
UNVERIFIABLE_DISPLAY = "an unverifiable -R/--repo/GH_REPO value"


def explicit_target(value):
    """The target a -R/--repo/GH_REPO value names: None when unset or empty
    (gh then falls back to the remotes, as the empty `-R ""` does),
    UNVERIFIABLE when it can't be read, else (owner, repo)."""
    if not value:
        return None
    if "$" in value or "`" in value:
        return UNVERIFIABLE
    return parse_repo_value(value) or UNVERIFIABLE


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


def load_own_owners():
    owners = set()
    gh_config_dir = os.environ.get("GH_CONFIG_DIR") or os.path.join(
        os.environ.get("HOME", ""), ".config", "gh"
    )
    hosts_path = os.path.join(gh_config_dir, "hosts.yml")
    try:
        with open(hosts_path, "r", encoding="utf-8", errors="replace") as fh:
            in_github_host = False
            for line in fh:
                line = line.rstrip("\n")
                if re.match(r"^github\.com:\s*$", line):
                    in_github_host = True
                    continue
                if not in_github_host:
                    continue
                if re.match(r"^\S", line):
                    break  # dedented back out of the github.com: block
                m = re.match(r"^\s+user:\s*(\S+)", line)
                if m:
                    owners.add(m.group(1).strip().lower())
                    break
    except OSError:
        pass
    raw = os.environ.get("SYG_OWN_OWNERS", "").strip()
    if raw:
        owners |= {p.lower() for p in re.split(r"[\s,]+", raw) if p}
    return owners


own_owners = load_own_owners()
if not own_owners:
    # Can't judge any target as "not own" — fail open for the whole command.
    sys.exit(0)

# Runner prefixes that still run the shell builtin: `builtin cd x`, `command cd x`.
BUILTIN_RUNNERS = {"builtin", "command"}

# The shell-state machine (State, cd/pushd/popd, walk) is lib/shell_state.py, shared with publish-gate.sh.


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
        self.blocking = []  # (kind, {display owner/repo}, unverifiable?)
        self.visited = set()  # State snapshots the text passes through
        self.judged = set()  # argv tuples judged in execution order
        self.leftovers = []  # (span, depth) not placed at a command
        self.leftover_mode = False


def judge(argv, unwrapped, state, ctx):
    # GH_REPO / GIT_DIR / GIT_WORK_TREE / SYG_UPSTREAM_CHECKED in THIS
    # command's own prefix: the words unwrap_runners consumed off the front
    # (assignments and runner names, including `env VAR=v gh ...`), read
    # before they were stripped; a prefix value beats an exported one.
    prefix = argv[: max(0, len(argv) - len(unwrapped))]
    env = dict(state.env)
    bypass_values = set()
    for w in prefix:
        m = ASSIGN_RE.match(w)
        if not m:
            continue
        key, val = m.group(1), m.group(2)
        if key in TRACKED_ENV:
            env[key] = val
        elif key == "SYG_UPSTREAM_CHECKED":
            bypass_values.add(val.lower())

    sub = gh_submission(unwrapped)
    if sub is None:
        return

    def remotes():
        return git_remotes_targets(
            state.cwd, usable_git_path(env.get("GIT_DIR")),
            usable_git_path(env.get("GIT_WORK_TREE")),
        )

    gh_repo = explicit_target(env.get("GH_REPO"))
    if sub["api"]:
        o, r = sub["endpoint_owner"], sub["endpoint_repo"]
        o_ph, r_ph = o == "{owner}", r == "{repo}"
        if not o_ph and not r_ph:
            targets = [(o, r)]  # a literal endpoint: gh ignores GH_REPO
        elif gh_repo == UNVERIFIABLE:
            targets = [UNVERIFIABLE]
        else:
            bases = [gh_repo] if gh_repo else remotes()
            if bases:
                targets = [(b[0] if o_ph else o, b[1] if r_ph else r) for b in bases]
            elif not o_ph:
                targets = [(o, r)]  # the owner is literal; shown as `o/{repo}`
            else:
                targets = []
    else:
        explicit = explicit_target(sub["repo_flag"]) if sub["repo_flag"] else gh_repo
        targets = ([explicit] if explicit else []) + sub["url_targets"]
        if not targets:
            targets = remotes()

    non_own = {}
    unverifiable = False
    for t in targets:
        if t == UNVERIFIABLE:
            unverifiable = True
            continue
        o, r = t
        if not o or not r or o.lower() in own_owners:
            continue
        non_own[f"{o.lower()}/{r.lower()}"] = f"{o}/{r}"
    if not non_own and not unverifiable:
        return
    if not unverifiable and set(non_own) <= bypass_values:
        return
    ctx.blocking.append((sub["kind"], set(non_own.values()), unverifiable))


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
# against EVERY state the text passed through: block if any resolves non-own.
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

kinds = sorted({k for k, _, _ in ctx.blocking})
kind_label = kinds[0] if len(kinds) == 1 else "gh command"
all_non_own = set()
any_unverifiable = False
for _, disp, unv in ctx.blocking:
    all_non_own |= disp
    any_unverifiable = any_unverifiable or unv
targets_sorted = sorted(all_non_own)
bypass_prefix = " ".join(f"SYG_UPSTREAM_CHECKED={t}" for t in targets_sorted)
shown = targets_sorted + ([UNVERIFIABLE_DISPLAY] if any_unverifiable else [])
print(" ".join(kind_label.split()))
print(" ".join(", ".join(shown).split()))
print(bypass_prefix)
print("1" if any_unverifiable else "0")
print(", ".join(targets_sorted))
PYEOF
) || exit 0

[ -n "$RESULT" ] || exit 0

KIND=$(printf '%s\n' "$RESULT" | sed -n '1p')
TARGETS=$(printf '%s\n' "$RESULT" | sed -n '2p')
BYPASS_PREFIX=$(printf '%s\n' "$RESULT" | sed -n '3p')
UNVERIFIABLE=$(printf '%s\n' "$RESULT" | sed -n '4p')
VERIFIED=$(printf '%s\n' "$RESULT" | sed -n '5p')
[ -n "$BYPASS_PREFIX" ] || BYPASS_PREFIX='SYG_UPSTREAM_CHECKED=<owner/repo>'

{
cat <<EOF
UPSTREAM SUBMISSION GUARD — $KIND would reach a repo the owner doesn't own: $TARGETS
Before anything goes upstream, check the project's stance on AI-assisted work:
  grep CONTRIBUTING*, README*, CODE_OF_CONDUCT* (and .github/ copies) for
  AI|LLM|machine-generated|Copilot|ChatGPT, and search its issues and
  discussions for "AI".
- Hostile to AI contributions: don't submit. Tell the owner it was skipped
  and why. Never suggest she reword or re-file it as her own work.
- A security vulnerability is the exception: draft a PRIVATE report, openly
  labelled as AI-found, and bring it to the owner; she decides and files it.
- Stance checked and fine: record the check in the project's notes, then
  re-run with the prefix on the gh command itself:
    $BYPASS_PREFIX gh …
EOF
if [ "$UNVERIFIABLE" = 1 ]; then
cat <<'EOF'
The -R/--repo/GH_REPO value can't be read from the command text (a variable,
a substitution or an unparsable form), and gh won't fall back to the remotes:
re-run with the literal owner/repo so it can be judged (the bypass then works).
EOF
fi
if [ -n "$VERIFIED" ]; then
cat <<EOF
If $VERIFIED is really your own fork's parent by accident, pass
-R <your-owner>/<repo> (or run \`gh repo set-default\`) so gh targets your fork.
EOF
fi
} >&2
exit 2
