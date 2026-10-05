#!/bin/bash
# PreToolUse hook (matcher: Bash) — in a repo marked public, blocks outbound
# text that holds a private term the owner listed locally: a name, a private
# project, a personal path, anything that must not reach public history.
#
# TRIGGER: a command the shared splitter (`lib/shell_quotes.py`) finds running
# `git commit|tag|notes|push` or any `gh` command, with the terms file
# configured and the target repo marked public. The bash prefilter is
# session-url-gate's: a `gh` word always goes through; a `git` word only with
# a word-bounded `commit`, `tag`, `notes` or `push` in the text, so `git
# status` and the like never start python.
#
# CONFIG:
#   - SYG_PRIVATE_TERMS_FILE names a local file, never tracked in this plugin:
#     one Python regex per line, trailing whitespace (and a CR) stripped;
#     blank lines and lines whose first non-space character is `#` are
#     ignored. Terms match case-INSENSITIVELY; wrap a term as `(?-i:...)` to
#     make it case-sensitive. Unset or empty, a missing or unreadable file, or
#     a file with no term lines → the hook is off. A term line that does not
#     compile blocks (only for a command that would be scanned) with its line
#     number, never its text.
#   - A repo is public when `git -C <dir> config --type=bool --get
#     seyag.publicRepo` prints `true` (`git config seyag.publicRepo true` in
#     each local clone; the going-public skill says when). <dir> is the event
#     cwd moved by `cd`/`pushd` and git's `-C`, per command, as lib/outbound.py
#     tracks it. A <dir> not inside a git work tree (a path the tracking got
#     wrong, a missing directory) is judged by the event cwd's repo instead,
#     so a tracking miss in a public repo still checks. Unset or false → that
#     command's text is not checked, and its files, diff and log are not read.
#
# WHAT IS SCANNED: every item `lib/outbound.py` returns (its docstring is the
# list): the command text of a `git commit|tag|notes` or `gh` command, body
# files (`-F`, `--body-file`, `@file`, gist files), the messages of pushed
# commits, and the added lines of the commit being made and of pushed commits,
# in every file.
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

if [[ "$CMD" =~ (^|[^[:alnum:]_.-])gh([^[:alnum:]_-]|$) ]]; then
  :
elif [[ "$CMD" =~ (^|[^[:alnum:]_.-])git([^[:alnum:]_-]|$) ]] \
  && [[ "$CMD" =~ (^|[^[:alnum:]_-])(commit|tag|notes|push)([^[:alnum:]_-]|$) ]]; then
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
import re
import signal
import subprocess
import sys

# An import failure exits non-zero, which the caller treats as allow (fail-open).
sys.path.insert(0, os.environ["HOOK_LIB"])
from outbound import outbound_items

cmd = os.fsdecode(open(3, "rb").read()).removesuffix("\n")
payload_cwd = os.environ.get("CWD") or "."
terms_file = os.environ["TERMS_FILE"]

BYPASS = "SYG_ALLOW_PRIVATE_TERM=1"
PLACEHOLDER = "[private term #"
MAX_CONTEXT = 5
MAX_LINE = 160
MAX_LABELS = 8
MATCH_SECONDS = 5

try:
    with open(terms_file, "rb") as fh:
        raw = fh.read().decode("utf-8", "replace")
except OSError:
    sys.exit(0)

terms = []  # (line number in the file, regex source)
for lineno, line in enumerate(raw.splitlines(), 1):
    line = line.rstrip()
    if not line or line.lstrip().startswith("#"):
        continue
    terms.append((lineno, line))
if not terms:
    sys.exit(0)


def git_out(d, *args):
    try:
        r = subprocess.run(["git", "-C", d, *args], capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return ""
    if r.returncode != 0:
        return ""
    return r.stdout.decode("utf-8", "replace").strip()


_public = {}


def flag_true(d):
    return git_out(d, "config", "--type=bool", "--get", "seyag.publicRepo") == "true"


def is_public(d):
    """The repo flag of `d`; a `d` outside any git work tree is judged by the
    event cwd's repo (fail closed on a tracking miss)."""
    if d not in _public:
        if git_out(d, "rev-parse", "--is-inside-work-tree") == "true":
            _public[d] = flag_true(d)
        else:
            _public[d] = flag_true(payload_cwd)
    return _public[d]


items = outbound_items(cmd, payload_cwd, BYPASS, dir_filter=is_public)
if not items:
    sys.exit(0)

compiled = []  # (term number, regex)
for n, (lineno, src) in enumerate(terms, 1):
    try:
        compiled.append((n, re.compile(src, re.IGNORECASE)))
    except Exception:
        print(f"private-term-guard: {terms_file} line {lineno} is not a valid regex; fix it")
        sys.exit(0)


def spans(text):
    found = []
    for n, rx in compiled:
        for m in rx.finditer(text):
            if m.end() > m.start():
                found.append((m.start(), m.end(), n))
    return found


def masked(text, found):
    """`text` with every match replaced by its placeholder; overlapping
    matches merge into one span named by the lowest term number, so no part
    of any match survives."""
    merged = []
    for s, e, n in sorted(found):
        if merged and s < merged[-1][1]:
            ps, pe, pn = merged[-1]
            merged[-1] = (ps, max(pe, e), min(pn, n))
        else:
            merged.append((s, e, n))
    out, pos = [], 0
    for s, e, n in merged:
        out.append(text[pos:s])
        out.append(f"{PLACEHOLDER}{n}]")
        pos = e
    out.append(text[pos:])
    return "".join(out)


def context_line(text):
    """The first line of masked `text` holding a placeholder, windowed so the
    placeholder shows."""
    lines = text.split("\n")
    line = next((ln for ln in lines if PLACEHOLDER in ln), lines[0]).strip()
    i = line.find(PLACEHOLDER)
    if i > 60:
        line = "…" + line[i - 40:]
    return line


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
        found = spans(it.text)
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
