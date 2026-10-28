#!/bin/bash
# PreToolUse hook (matcher: Bash) — in a repo marked public, blocks outbound
# text that holds a private term the owner listed locally: a name, a private
# project, a personal path, anything that must not reach public history.
#
# THE ADDED LAYER: git-hooks/pre-push (opt-in, `seyag-git-hooks install
# --global`) also scans what a push from a public repo sends (message,
# author, committer, added paths and lines, tags, notes), however bash built
# it. It adds to this hook and replaces nothing: every item below is checked
# as before. Where that pre-push is in force (lib/prepush_state.py's
# `enforcing`), this hook also blocks the ways past it (PRE-PUSH BYPASSES).
#
# TRIGGER: a command the shared splitter (`lib/shell_quotes.py`) finds running
# `git commit|tag|notes|push|config` or any `gh` command, with the terms file
# configured and the target repo marked public. The bash prefilter is
# session-url-gate's: a `gh` word always goes through; a `git` word only with
# a word-bounded `commit`, `tag`, `notes`, `push` or `config`, or `hookspath`,
# `include`, `alias`, `update-ref` or `send-pack` in any case, in the text,
# so `git status` and the like never start python.
#
# CONFIG:
#   - SYG_PRIVATE_TERMS_FILE names a local file, never tracked in this plugin:
#     one Python regex per line, trailing whitespace (and a CR) stripped;
#     blank lines and lines whose first non-space character is `#` are
#     ignored. Terms match case-INSENSITIVELY; wrap a term as `(?-i:...)` to
#     make it case-sensitive. Unset or empty, a missing or unreadable file, or
#     a file with no term lines → the hook is off. A term line that does not
#     compile blocks (only for a command that would be scanned) with its line
#     number, never its text. Reading, matching and masking live in
#     lib/private_terms.py, shared with git-hooks/pre-push.
#   - A repo is public when `git -C <dir> config --type=bool --get
#     seyag.publicRepo` prints `true` (`git config seyag.publicRepo true` in
#     each local clone; the going-public skill says when), or when the value
#     is set but is not a boolean (fail closed, as git-hooks/pre-push reads
#     it; lib/prepush_state.py's `public_flag`). <dir> is the event
#     cwd moved by `cd`/`pushd` and git's `-C`, per command, as lib/outbound.py
#     tracks it. A <dir> not inside a git work tree (a path the tracking got
#     wrong, a missing directory) is judged by the event cwd's repo instead,
#     so a tracking miss in a public repo still checks. Unset or false → that
#     command's text is not checked, and its files, diff and log are not read.
#
# WHAT IS SCANNED: every item `lib/outbound.py` returns (its docstring is the
# list): the command text of a `git commit|tag|notes` or `gh` command, body
# files (`-F`,
# `--body-file`, `@file`, gist files), the messages of pushed commits, and the
# added lines of the commit being made and of pushed commits, in every file.
# Read-only gh commands (the read verbs of pr/issue/run/repo/release/gist in
# GH_READ_SUBCOMMANDS, gh api with a GET method) do not publish, so their
# command text is not scanned — under the closed-text rule only: no `VAR=`
# assignment in the command's own prefix, and no `--web`, `--hostname` or
# `-H` flag; any other shape keeps the whole text scanned. A `git
# commit|tag|notes` command also adds no command-text item where the pre-push
# is in force AND the global seyag.privateTermsFile names this hook's terms
# file (lib/prepush_state.py's `text_owner_judge`: a push from a terminal is
# checked with the same terms), so the pre-push owns that text at push time —
# except while the command text holds a pre-push bypass token the owner's
# bypass could waive (a SYG_ALLOW_PRIVATE_TERM=1 push --no-verify beside the
# commit): there the text stays with this hook. Body files, staged lines,
# pushes and bypass blocks are never handed over.
#
# PRE-PUSH BYPASSES: where the pre-push is in force (a public repo with the
# seyag hooks dir as its effective core.hooksPath and no alias that skips
# it), exit 2 naming the token, whatever the terms match: `git push
# --no-verify` (or a prefix git accepts, down to `--no-v`), a push argument
# holding `$` or a backtick, a `HOME=`/`XDG_CONFIG_HOME=`, `env -i` or `env
# -u HOME` prefix on a push; `git -c`/`--config-env` setting core.hooksPath,
# include.path, includeIf.*, seyag.publicRepo, seyag.privateTermsFile or
# alias.*; a `git config` write of one of those keys (`set`, `unset`,
# `--unset`, `--unset-all`, `--replace-all`, `--add`, `<key> <value>`, any
# scope), `git config -e/--edit`, and a remove or rename of the core or seyag
# section (a read passes); `git update-ref refs/remotes/…`; `git send-pack`;
# an assignment or export of GIT_CONFIG_COUNT, GIT_CONFIG_PARAMETERS,
# GIT_CONFIG_GLOBAL or GIT_CONFIG_SYSTEM anywhere in the text (the BYPASS
# waives such an assignment only inside the prefix of the command that
# carries it and runs a program, `SYG_ALLOW_PRIVATE_TERM=1
# GIT_CONFIG_GLOBAL=x git push`; a BYPASS on another command, text that
# only looks like one (quoted, a comment, a heredoc body), an export or a
# `${…:=…}` waives nothing, nor does a command led by a shell keyword or
# grouping (`{`, `if`, `!`, `time`, `for … do`) or one after `env -` (fail
# closed: move the assignment onto a plain command); the
# other tokens are waived per command, as below). Elsewhere (no
# install, a husky repo) they pass. A `git config --global|--system` write
# is judged by whether the global install is present (whatever the cwd), and
# a `--file <f>` write by the repo that owns f. `prepush_bypasses` in
# lib/outbound.py is the list. This hook blocks them only when the terms
# file is set; session-url-gate.sh blocks the same tokens without one. The
# BYPASS is the one described under BYPASS below.
#
# BLOCK: exit 2, stderr names the lowest-numbered matching term (`#N`: its
# 1-based index among the term lines, comments and blanks not counted) and
# where it matched, by kind only, never by user text: `the command text`,
# `a body file` (or `N body files`), `staged lines (see git diff --cached)`,
# `commit <sha> message`, `commit <sha> diff`. Then up to 5 context lines (160
# characters each), one per kind, with every term match replaced by
# `[private term #N]`. The term text and the matched span are never printed.
# Matching that takes over 5 s (a catastrophic pattern) blocks with a message
# naming the terms file.
#
# BYPASS: `SYG_ALLOW_PRIVATE_TERM=1` as an assignment in the matched command's
# own prefix (`VAR=1 git commit …`, `env VAR=1 gh …`); a mention elsewhere in
# the text does not count. Only on the owner's word.
#
# KNOWN GAPS (accepted): a `gh -R other/repo` target is judged by the flag of
# the local cwd repo, and a gist by the cwd repo's flag (a gist from a public
# repo's directory is checked, one from a private repo's is not);
# `--git-dir`/`--work-tree` and `GIT_DIR` are not followed (covered only by
# the event-cwd fallback above); a merge commit's own changes are not read on
# push (`git log -p` shows none without `-m`), nor pushed diffs past 4 MiB of
# log output; outbound.py's gaps: a body read through a variable or
# substitution, stdin redirects (`-F - < f`, `cat f | gh … --body-file -`),
# content written earlier in the same command, annotated tag messages on push.
# Where the pre-push is in force, it covers these for what a push sends. Ways
# past the pre-push the bypass list does not see: editing `.git/config` (or a
# file it includes) with a non-git tool; `HOME`, `XDG_CONFIG_HOME` or `PATH`
# changed by an earlier `export` (only a push's own prefix is read); `git
# update-ref --stdin`.
#
# FAIL-OPEN: no jq/python3/git, unparsable JSON or command, or an internal
# python error → exit 0. The command goes to python on fd 3, never through the
# environment (Linux caps one env string at 128 KiB). Python's stderr is
# discarded.
#
# Fixture check: run hooks/private-term-guard.probe.sh after ANY edit here.

set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

INPUT=$(cat)
TERMS_FILE=${SYG_PRIVATE_TERMS_FILE:-}
[ -n "$TERMS_FILE" ] || exit 0

TOOL_NAME=$(jq -r '.tool_name // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ "$TOOL_NAME" = "Bash" ] || exit 0

CMD=$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ -n "$CMD" ] || exit 0

read -r GH_WRAPPER_FIRST _ <<<"${SYG_GH_WRAPPERS:-${SYG_LOSSY_PIPE_GH_WRAPPERS:-}}"
if [[ "$CMD" =~ (^|[^[:alnum:]_.-])gh([^[:alnum:]_-]|$) ]]; then
  :
elif [ -n "$GH_WRAPPER_FIRST" ] \
  && [[ "$CMD" =~ (^|[^[:alnum:]_.-])"$GH_WRAPPER_FIRST"([^[:alnum:]_-]|$) ]]; then
  :
elif [[ "$CMD" =~ (^|[^[:alnum:]_.-])git([^[:alnum:]_-]|$) ]] \
  && [[ "$CMD" =~ (^|[^[:alnum:]_-])(commit|tag|notes|push)([^[:alnum:]_-]|$) ]]; then
  :
elif [[ "$CMD" =~ (^|[^[:alnum:]_.-])git([^[:alnum:]_-]|$) ]] \
  && [[ "${CMD,,}" =~ hookspath|include|alias|update-ref|send-pack|(^|[^[:alnum:]_-])config([^[:alnum:]_-]|$) ]]; then
  :
else
  exit 0
fi

[ -f "$TERMS_FILE" ] && [ -r "$TERMS_FILE" ] || exit 0

CWD=$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null) || CWD=""

HOOK_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
RESULT=$(CWD="$CWD" HOOK_LIB="$HOOK_LIB" TERMS_FILE="$TERMS_FILE" PYTHONDONTWRITEBYTECODE=1 \
  python3 - 3<<<"$CMD" <<'PYEOF' 2>/dev/null
import os
import signal
import sys

# An import failure exits non-zero, which the caller treats as allow (fail-open).
sys.path.insert(0, os.environ["HOOK_LIB"])
from outbound import bypass_block_message, outbound_items, prepush_bypasses
from prepush_state import (enforcing_judge, global_install_present, public_judge,
                           text_owner_judge)
from private_terms import compile_terms, context_line, masked, read_terms, spans

cmd = os.fsdecode(open(3, "rb").read()).removesuffix("\n")
payload_cwd = os.environ.get("CWD") or "."
terms_file = os.environ["TERMS_FILE"]

BYPASS = "SYG_ALLOW_PRIVATE_TERM=1"
MAX_CONTEXT = 5
MAX_LINE = 160
MAX_LABELS = 8
MATCH_SECONDS = 5

terms = read_terms(terms_file)  # [(line number in the file, regex source)]
if not terms:
    sys.exit(0)


# The repo flag of a directory; one outside any git work tree is judged by the
# event cwd's repo (fail closed on a tracking miss).
is_public = public_judge(payload_cwd)
in_force = enforcing_judge(payload_cwd)

# The ways past the pre-push block only where that hook is in force.
bypass_tokens = prepush_bypasses(cmd, payload_cwd, BYPASS,
                                 dir_filter=in_force,
                                 global_filter=global_install_present)
if bypass_tokens:
    print(bypass_block_message(bypass_tokens, BYPASS))
    sys.exit(0)

# Same-text push shapes (the prepush review's MUST-FIX 1): a bypass token in
# the text that the owner's bypass waives (SYG_ALLOW_PRIVATE_TERM=1 git push
# --no-verify beside the commit) leaves what the push sends uncovered, so the
# commit text stays with this hook: no hand-over while any token would count.
owner = None if prepush_bypasses(cmd, payload_cwd, None,
                                 dir_filter=in_force,
                                 global_filter=global_install_present) \
    else text_owner_judge(payload_cwd, terms_file)

items = outbound_items(cmd, payload_cwd, BYPASS, dir_filter=is_public,
                       commit_text_owner=owner)
if not items:
    sys.exit(0)

compiled, bad_line = compile_terms(terms)  # [(term number, regex)]
if compiled is None:
    print(f"private-term-guard: {terms_file} line {bad_line} is not a valid regex; fix it")
    sys.exit(0)


def kind_key(it):
    """A name for the item's source that carries no user text."""
    if it.kind == "text":
        return "the command text"
    if it.kind == "file":
        return "file"
    if it.kind == "staged":
        return "staged lines (see git diff --cached)"
    if it.kind == "commit-message":
        return f"commit {it.sha} message"
    if it.kind == "commit-diff":
        return f"commit {it.sha} diff"
    return "outbound text"


class MatchTimeout(Exception):
    pass


def on_alarm(_signum, _frame):
    raise MatchTimeout()


hit_terms = set()
keys = []        # kind keys in order of first hit
body_files = set()
context = []
signal.signal(signal.SIGALRM, on_alarm)
signal.alarm(MATCH_SECONDS)
try:
    for it in items:
        found = spans(compiled, it.text)
        if not found:
            continue
        hit_terms.update(n for _s, _e, n in found)
        key = kind_key(it)
        if key == "file":
            body_files.add(it.label)
        if key in keys:
            continue
        keys.append(key)
        if len(context) < MAX_CONTEXT:
            shown_key = "a body file" if key == "file" else key
            context.append(f"  {shown_key}: {context_line(masked(it.text, found))}"[:MAX_LINE])
except MatchTimeout:
    print(f"private-term-guard: matching the terms took over {MATCH_SECONDS} s; "
          f"simplify the patterns in {terms_file}")
    sys.exit(0)
finally:
    signal.alarm(0)

if not keys:
    sys.exit(0)


def label_of(key):
    if key != "file":
        return key
    return "a body file" if len(body_files) == 1 else f"{len(body_files)} body files"


shown = [label_of(k) for k in keys[:MAX_LABELS]]
more = f" and {len(keys) - MAX_LABELS} more" if len(keys) > MAX_LABELS else ""
print(f"blocked: a private term (#{min(hit_terms)} in $SYG_PRIVATE_TERMS_FILE) would go out "
      f"to a public repo; matched in: {'; '.join(shown)}{more}.")
for line in context:
    print(line)
print("Remove it. Only on the owner's word: prefix the command itself with SYG_ALLOW_PRIVATE_TERM=1.")
PYEOF
) || exit 0

[ -n "$RESULT" ] || exit 0
printf '%s\n' "$RESULT" >&2
exit 2
