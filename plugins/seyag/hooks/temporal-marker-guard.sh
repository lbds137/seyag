#!/bin/bash
# PreToolUse hook (matcher: Bash) — blocks a `git commit` whose ADDED code-
# comment lines carry a temporal marker: a date, a PR/issue number, a review
# round or an epic-phase tag. Those rot the moment they are written; the
# invariant belongs in the comment, the history in the commit message or PR body.
#
# TRIGGER: a command the shared splitter (`lib/shell_quotes.py`) finds running
# `git commit`, global options honored (`git -C <dir>`; the repo dir otherwise
# comes from the event's cwd, tracking a literal `cd`). A command whose text
# lacks `commit` exits before any python spawns.
#
# LINES JUDGED: added lines of the change the commit will carry, as
# `lib/commit_diff.py` computes them (`commit_lines`; its docstring lists the
# sources: staged, a same-command `git add`/`git stage`, `commit -a`, a
# pathspec commit, and the over-approximation accepted).
#
# FILES JUDGED: the extensions in CODE_EXTS below, plus an extensionless file
# whose first line is a bash/sh/python/node shebang (read from the working
# tree). Markdown and other prose are never judged. A file whose first 5 lines
# hold `AUTO-GENERATED FILE` or `@generated` is skipped: a generator's
# `Generated at: <date>` header is a meta-stamp, not authored archaeology.
#
# COMMENT PREFIX, per language (full-line comments only; an inline trailing
# comment is intentionally not judged, since telling it from a string literal
# needs a real lexer): `#` for py/sh/bash/rb and bash/sh/python shebang files
# (plus `"""` / `'''` for python); `//`, `*`, `/*` for the C family, js/ts, go,
# rs, java, kt, cs, swift, prisma and node-shebang files. The split is
# per-language because a combined regex would flag a TS private field such as
# `#count = new Date('2026-…')`. A `#!` line is not a comment line.
#
# PATTERN: TEMPORAL_PATTERN below, the one copy (the probe extracts it from
# this file). The date alternative is decade-scoped so a spec reference such as
# "RFC 3339 (2002-07-15)" passes. A bare `#NNNN` is bounded to 4-5 digits as
# the hex-colour guard: a CSS hex is 3/4/6/8 characters, so `#123`, `#123456`
# and `#1a2b3c` pass (the one gap is an all-numeric 4-digit RGBA hex). The bare
# `PR N` form is word-bounded on both sides: without the leading bound a word
# ending in `pr` opens the match (`expr 3`), without the trailing one a
# hex-ish token reads as a number (`PR 1a2b3c`). The epic-phase forms (a phase
# number with a letter suffix, the words "epic" or "post" joined to "phase",
# and a phase number followed by a change verb) are epic archaeology; a bare
# phase number with a parenthesised word names an algorithm step and passes.
#
# BLOCK: exit 2, stderr lists `file:` and each offending line (trimmed; at most
# 10 lines in all, then "and N more").
#
# BYPASS: `SYG_ALLOW_TEMPORAL=1` as an assignment in the commit command's own
# prefix (`SYG_ALLOW_TEMPORAL=1 git commit …`, `env SYG_ALLOW_TEMPORAL=1 git
# commit …`); a mention elsewhere in the command text does not count, and an
# earlier `git add`'s prefix is not the commit's.
#
# KNOWN GAPS (accepted): `--git-dir`/`--work-tree` global options are not
# followed; a variable or glob in a `-C`/`cd` path or a pathspec is not
# resolved (git then fails and the hook allows); a subshell's `cd` leaks
# forward in the tracking; a quoted/special-character path in diff headers is
# not unquoted; untracked files over 1 MB are not read; `git commit
# --pathspec-from-file` and `xargs git add` stage paths the hook cannot see;
# content written earlier in the same command (`printf … >> f && git add f &&
# git commit`) does not exist yet when this PreToolUse hook runs; staging by
# `git merge --squash`, `git cherry-pick -n` or `git apply --cached` in the same
# command is likewise invisible. Every `git diff` call pins diff.relative,
# diff.srcPrefix and diff.dstPrefix so a repo's own config cannot move the
# headers the parser reads.
#
# FAIL-OPEN: no jq/python3/git, unparsable JSON or command, or any internal
# python error → exit 0.
#
# Fixture check: run hooks/temporal-marker-guard.probe.sh after ANY edit.

set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

INPUT=$(cat)
TOOL_NAME=$(jq -r '.tool_name // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ "$TOOL_NAME" = "Bash" ] || exit 0

CMD=$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ -n "$CMD" ] || exit 0

# Fast path: runs on every Bash call, and only a command mentioning `commit`
# can commit. Python decides the real structure.
[[ "$CMD" == *commit* ]] || exit 0

CWD=$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null) || CWD=""
HOOK_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"

TEMPORAL_PATTERN='PR #[0-9]+|\bPR [0-9]+\b|PR-[0-9]+(\.[0-9a-z]+)*|GH-[0-9]+|[Bb]ug #[0-9]+|[Ii]ssue #[0-9]+|\(#[0-9]+\)|(fix(e[sd])?|close[sd]?|resolve[sd]?) #[0-9]+|#[0-9]{4,5}([^0-9]|$)|202[0-9]-[0-9]{2}-[0-9]{2}|Surfaced 202[0-9]|caught in (round|PR )|flagged by (review|PR)|round[- ][0-9]+ (claude-review|review)|Epic Phase|[Pp]ost-[Pp]hase|Phase [0-9]+[a-z]|Phase [0-9]+ (made|added|introduced|landed|removed|renamed|dropped)'

# The command goes to python on fd 3, never through the environment (one env
# string is capped at 128 KiB and a failed exec would fail open).
RESULT=$(CWD="$CWD" HOOK_LIB="$HOOK_LIB" TEMPORAL_PATTERN="$TEMPORAL_PATTERN" \
  PYTHONDONTWRITEBYTECODE=1 python3 - 3<<<"$CMD" <<'PYEOF' 2>/dev/null
import os
import re
import subprocess
import sys

sys.path.insert(0, os.environ["HOOK_LIB"])
from shell_quotes import command_pipelines, unwrap_runners
from commit_diff import commit_lines, join_dir, parse_add, parse_commit, parse_git, toplevel

cmd = os.fsdecode(open(3, "rb").read()).removesuffix("\n")
pattern = os.environ["TEMPORAL_PATTERN"]
cwd = os.environ.get("CWD") or "."

ASSIGN_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
MAX_SHOWN = 10

C_EXTS = {"ts", "tsx", "js", "jsx", "mjs", "cjs", "prisma", "go", "rs", "java",
          "kt", "c", "h", "cpp", "cs", "swift"}
HASH_EXTS = {"sh", "bash", "rb"}
CODE_EXTS = C_EXTS | HASH_EXTS | {"py"}
SHEBANG_RE = re.compile(r"^#!.*\b(bash|sh|python[0-9.]*|node)\b")

C_PREFIX = re.compile(r"^\s*(//|\*|/\*)")
HASH_PREFIX = re.compile(r"^\s*#(?!!)")
PY_PREFIX = re.compile(r"^\s*(#(?!!)|\"\"\"|''')")


def kind_of(top, path):
    """Comment-prefix regex for a judged file, None when not judged or generated."""
    full = os.path.join(top, path)
    base = os.path.basename(path)
    ext = base.rsplit(".", 1)[-1].lower() if "." in base else ""
    try:
        with open(full, "rb") as fh:
            head = fh.read(4096).decode("utf-8", errors="replace").split("\n")[:5]
    except OSError:
        return None
    if any("AUTO-GENERATED FILE" in h or "@generated" in h for h in head):
        return None
    if ext:
        if ext not in CODE_EXTS:
            return None
        if ext == "py":
            return PY_PREFIX
        return HASH_PREFIX if ext in HASH_EXTS else C_PREFIX
    m = SHEBANG_RE.match(head[0]) if head else None
    if not m:
        return None
    iv = m.group(1)
    if iv == "node":
        return C_PREFIX
    return PY_PREFIX if iv.startswith("python") else HASH_PREFIX


def temporal_hits(lines, prefix):
    cand = [ln for ln in lines if prefix.match(ln)]
    if not cand:
        return []
    r = subprocess.run(["grep", "-Ei", "--binary-files=text", "-e", pattern],
                       input="\n".join(cand).encode("utf-8", errors="replace"),
                       capture_output=True)
    return [h for h in r.stdout.decode("utf-8", errors="replace").split("\n") if h]


violations = {}  # path -> [trimmed line]
seen = set()
state_cwd = cwd
adds = []

for pipeline in command_pipelines(cmd):
    for argv in pipeline:
        unwrapped, _info = unwrap_runners(argv)
        if not unwrapped:
            continue
        name = os.path.basename(unwrapped[0])
        if name == "cd":
            tgt = [a for a in unwrapped[1:] if not a.startswith("-")]
            if len(tgt) == 1:
                state_cwd = join_dir(state_cwd, tgt[0])
            continue
        if name != "git":
            continue
        d, sub, rest = parse_git(unwrapped[1:], state_cwd)
        if sub in ("add", "stage"):
            spec = parse_add(rest)
            spec["dir"] = d
            adds.append(spec)
            continue
        if sub != "commit":
            continue
        prefix_words = argv[: max(0, len(argv) - len(unwrapped))]
        bypass = False
        for w in prefix_words:
            m = ASSIGN_RE.match(w)
            if m and m.group(1) == "SYG_ALLOW_TEMPORAL":
                bypass = m.group(2) == "1"
        if bypass:
            continue
        top = toplevel(d)
        if not top:
            continue
        by_file = {}
        for path, line in commit_lines(d, parse_commit(rest), adds):
            by_file.setdefault(path, []).append(line)
        for path, lines in by_file.items():
            prefix = kind_of(top, path)
            if prefix is None:
                continue
            for h in temporal_hits(lines, prefix):
                key = (top, path, h)
                if key in seen:
                    continue
                seen.add(key)
                violations.setdefault(path, []).append(h.strip())

if not violations:
    sys.exit(0)

total = sum(len(v) for v in violations.values())
print("TEMPORAL-MARKER GUARD: added code-comment line(s) carry a date, PR/issue number or review archaeology:")
shown = 0
for path, hits in violations.items():
    if shown >= MAX_SHOWN:
        break
    print(f"  {path}:")
    for h in hits:
        if shown >= MAX_SHOWN:
            break
        print(f"    {h[:200]}")
        shown += 1
if total > shown:
    print(f"  ... and {total - shown} more")
print("Dates, PR/issue numbers and review rounds in code comments rot; keep the invariant,")
print("put the history in the commit message or PR body.")
print("If a marker must stay (a quoted spec date), put SYG_ALLOW_TEMPORAL=1 in the commit command's own prefix.")
PYEOF
) || exit 0

[ -n "$RESULT" ] || exit 0
printf '%s\n' "$RESULT" >&2
exit 2
