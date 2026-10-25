#!/bin/bash
# PreToolUse hook (matcher: Bash): block a bare `git` command whose pathspec
# only makes sense from the repo ROOT while the shell has drifted into a
# subdirectory. Ported from Tzurot's .claude/hooks/cwd-drift-guard.sh and
# generalized: the original hard-coded Tzurot's top-level folder names; this
# copy asks the filesystem instead, so it works in any repo with no config.
#
# The shape it catches: `git add docs/x.md` run from inside `pkg/sub` resolves
# to `pkg/sub/docs/x.md` and fails with "did not match any files", often AFTER
# the tests it was gating already passed (or, for a `git checkout -- <path>`
# revert, silently leaves the change it meant to undo).
#
# THE RULE. Every git invocation in the command is judged on its own:
#   - ROOT = `git rev-parse --show-toplevel` from the effective cwd; drift means
#     the effective cwd is strictly below ROOT (`--show-prefix` is non-empty).
#     Not a repo, or no drift → allow.
#   - The git must be bare: `git -C <path>` and `git --git-dir…` are anchored
#     and never block.
#   - For each pathspec token (a non-option word after the subcommand, and every
#     word after `--`), take its first path component C (the text before the
#     first `/`, or the whole token). BLOCK iff C does NOT exist relative to the
#     effective cwd AND C DOES exist relative to ROOT. That is exactly the
#     always-wrong shape: the path only makes sense from the root.
#   - Stray copy: also BLOCK when the whole token exists both relative to the
#     cwd and relative to ROOT, is tracked at ROOT, and is untracked here. That
#     is the leftover of an earlier drifted write (`pkg/sub/docs/x.md` created
#     by mistake): without this, C exists in the cwd, the rule above allows,
#     and `git add docs/x.md` quietly stages the stray.
#
# Tokens that cannot be judged this way are SKIPPED (allowed): an absolute path;
# one starting with `~`, `-` or `:` (git pathspec magic); one containing a glob
# character `*`, `?` or `[`; one whose first component is `.` or `..`; one
# holding a `$` (unexpanded variable); one that was (partly) quoted, since the
# scan reads the quote-stripped command; a redirection target; and the value of
# `-m`/`--message` (an unquoted one-word commit message is not a path). Before
# `--` a positional word may be a ref rather than a path; it is judged anyway,
# and only blocks when a root entry of that exact name exists and the cwd has
# none.
#
# Deliberately NARROW. `pnpm`/`npm` from a subdir never block; `git status`,
# `git log` with no pathspec never block; a linked worktree's ROOT is its own
# toplevel, so it is not drift. When in doubt this hook allows: it may only
# ever ADD a block on an unambiguous mistake.
#
# COMMAND-TEXT SCOPE ONLY: this guard matches the command text's paths only; a
# wrapper script (or any child process) committing in a different checkout is
# outside its surface — see the delegation skill's wrapper caveat.
#
# EFFECTIVE CWD. A command that OPENS with `cd <dir>` runs its later steps from
# <dir>, so that target (resolved lexically) is judged instead of the payload
# cwd. A target this cannot read with certainty (a variable, substitution,
# glob, `~`, quote or backslash) allows the whole command. A `cd`/`pushd`/
# `popd` LATER in the chain stops the scan there: git steps after it run from
# a directory this hook does not track.
#
# Not ported: the original's refusal of `pnpm tracker` writes from a linked
# worktree, which is Tzurot-specific. No bypass token (the original has none).
#
# FAIL-SAFE: no cwd in the payload, no jq/python3/git, an unreadable command
# (unterminated quote) or any internal error → exit 0 (allow).
#
# Fixture check: run hooks/cwd-drift-guard.probe.sh after ANY edit to this hook.

set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

INPUT=$(cat)
TOOL_NAME=$(jq -r '.tool_name // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ "$TOOL_NAME" != "Bash" ] && exit 0

CMD=$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ -z "$CMD" ] && exit 0

# The shell's persistent cwd, as reported in the hook payload. Absent → allow.
SHELL_CWD=$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ -z "$SHELL_CWD" ] && exit 0

# Cheap short-circuit before any git or python spawn: only a command with a
# `git` word can block. The command token is matched case-insensitively (an
# uppercase invocation is a shape the original's probe pins), spelled as
# classes rather than `grep -i` so the pattern can never fold a flag letter.
# The preceding class also admits `(` and a backtick (a substitution runs in
# the same cwd) and `/` (`/usr/bin/git`).
if ! grep -qE '(^|[[:space:]&|;(`/])[Gg][Ii][Tt][[:space:]]' <<<"$CMD"; then
  exit 0
fi

# Lexical path join: collapse `.` and `..` segments without touching the
# filesystem, so the `cd` handling needs no directory to exist.
normalize_path() {
  local input="$1" segment result=""
  # Word-splitting on `/` also performs pathname expansion, so disable globbing
  # for the loop. Every call site is a `$(…)` substitution, so `set -f` is
  # scoped to that subshell and cannot reach the caller.
  set -f
  local IFS='/'
  for segment in $input; do
    case "$segment" in
      ''|.) ;;
      ..) result="${result%/*}" ;;
      *) result="$result/$segment" ;;
    esac
  done
  printf '%s' "${result:-/}"
}

# A command that OPENS with `cd …` sets its own working directory. Only a
# single literal directory token is resolved; anything this cannot read with
# certainty allows the command.
#
# The backslash is in the unresolvable class because the separator strip below
# is blind to escaping: it truncates at the first `|`/`&`/`;` whether or not a
# backslash precedes it, so `cd foo\&bar && …` would leave the fragment `foo\`,
# a directory the command never enters. Pinned by the "escaped separator in a
# cd target" probe case.
EFFECTIVE_CWD="$SHELL_CWD"
LEADING_CD=0
CMD_HEAD=$(printf '%s' "$CMD" | sed -E 's/^[[:space:]]+//')
# grep DRAINS rather than `-q`-quits: under pipefail an early exit kills the
# producer with SIGPIPE and a real match reports as failure.
if printf '%s' "$CMD_HEAD" | grep -E '^cd[[:space:]]' >/dev/null; then
  CD_TARGET=$(printf '%s' "$CMD_HEAD" \
    | sed -E 's/^cd[[:space:]]+//; s/[[:space:]]*[|&;].*$//; s/[[:space:]]+$//')
  case "$CD_TARGET" in
    ''|-*|*'$'*|*'`'*|*'*'*|*'?'*|*'['*|*'~'*|*'"'*|*"'"*|*\\*|*' '*) exit 0 ;;
    /*) EFFECTIVE_CWD=$(normalize_path "$CD_TARGET") ;;
    *)  EFFECTIVE_CWD=$(normalize_path "${SHELL_CWD%/}/$CD_TARGET") ;;
  esac
  LEADING_CD=1
fi

# ROOT and the drift test in one git call. `--show-prefix` is the cwd's path
# below the toplevel: empty at the root, and empty at a linked WORKTREE's root
# too (its toplevel is itself), which is how the original's worktree-root
# exemption carries over. It also sidesteps comparing path strings, which a
# symlinked cwd would defeat. Not a repo, a missing directory, or the inside of
# `.git` → git fails → allow.
REPO_INFO=$(git -C "$EFFECTIVE_CWD" rev-parse --show-toplevel --show-prefix 2>/dev/null) || exit 0
ROOT=$(printf '%s\n' "$REPO_INFO" | sed -n '1p')
PREFIX=$(printf '%s\n' "$REPO_INFO" | sed -n '2p')
[ -n "$ROOT" ] || exit 0
[ -n "$PREFIX" ] || exit 0

# The scan. It reads the QUOTE-STRIPPED command (the shared scanner in
# lib/shell_quotes.py), so argument CONTENT (a commit message, a quoted example
# command) cannot decide a question about the command's SHAPE:
# `git commit -m "update docs/x.md"` has no pathspec. Heredoc bodies come off
# first for the same reason. strip_quoted_indexed rather than strip_quoted: its
# placeholder is a private-use character, so a quoted token is recognizable and
# skipped, where strip_quoted's `S` would read as a file named S.
#
# Prints each blocking token on its own line; prints nothing to allow. A python
# or import failure is also "nothing" (`|| exit 0`), matching the fail-safe.
#
# The command goes to python on fd 3, never through the environment: Linux caps
# one env string at 128 KiB (MAX_ARG_STRLEN), and python failing to exec would
# fail open.
HOOK_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
BLOCKED=$(HOOK_LIB="$HOOK_LIB" EFF="$EFFECTIVE_CWD" ROOT="$ROOT" \
  LEADING_CD="$LEADING_CD" PYTHONDONTWRITEBYTECODE=1 python3 3<<<"$CMD" << 'PYEOF'
import os
import re
import subprocess
import sys

sys.path.insert(0, os.environ["HOOK_LIB"])
from shell_quotes import (
    ESCAPED_BLANK,
    QUOTED_SPAN,
    strip_heredoc_bodies,
    strip_quoted_indexed,
)

cmd = os.fsdecode(open(3, "rb").read()).removesuffix("\n")
eff = os.environ["EFF"]
root = os.environ["ROOT"]
leading_cd = os.environ.get("LEADING_CD") == "1"

stripped = strip_quoted_indexed(strip_heredoc_bodies(cmd))
if stripped is None:
    # Unterminated quote (a bash syntax error anyway): nothing can be read
    # with certainty, so allow.
    raise SystemExit
view = stripped[0]

# Split into segments (lists of words). `;` `|` `&` newline `(` `)` and a
# backtick end a command; `&` that belongs to a redirection (`2>&1`, `&>f`,
# `<&3`) does not.
segments = [[]]
word = []


def end_word():
    if word:
        segments[-1].append("".join(word))
        word.clear()


n = len(view)
for i, ch in enumerate(view):
    if ch in " \t":
        end_word()
    elif ch == "&" and (
        (i > 0 and view[i - 1] in "<>") or (i + 1 < n and view[i + 1] == ">")
    ):
        word.append(ch)
    elif ch in ";|&\n()`":
        end_word()
        segments.append([])
    else:
        word.append(ch)
end_word()
segments = [s for s in segments if s]

ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
KEYWORDS = {"!", "{", "}", "if", "then", "else", "elif", "do", "while", "until"}
PREFIXES = {"command", "exec", "nohup", "time", "env", "timeout"}
REDIRECT = re.compile(r"^[0-9]*(&>>|&>|>>|>\||>&|>|<<<|<<-|<<|<&|<>|<)")
# Global options that take their value as the NEXT word unless `=`-joined.
GLOBAL_VALUE_OPTS = {"-c", "--work-tree", "--namespace", "--config-env", "--super-prefix"}
GLOB_CHARS = set("*?[")


def is_git(w):
    return w.lower() == "git" or w.endswith("/git")


def command_start(words):
    """Index of the command word, skipping assignments, keywords and simple
    prefix commands (their option words, and timeout's duration)."""
    k = 0
    while k < len(words):
        w = words[k]
        if ASSIGNMENT.match(w) or w in KEYWORDS:
            k += 1
            continue
        if w in PREFIXES:
            k += 1
            while k < len(words) and (words[k].startswith("-") or ASSIGNMENT.match(words[k])):
                k += 1
            if w == "timeout" and k < len(words) and re.match(r"^[0-9.]+[smhd]?$", words[k]):
                k += 1
            continue
        return k
    return k


def judge(token):
    if QUOTED_SPAN in token or ESCAPED_BLANK in token or "$" in token:
        return False
    if token[:1] in ("/", "~", "-", ":") or token == "":
        return False
    if any(c in GLOB_CHARS for c in token):
        return False
    first = token.split("/", 1)[0]
    if first in ("", ".", ".."):
        return False
    if (not os.path.lexists(os.path.join(eff, first))) and os.path.lexists(os.path.join(root, first)):
        return "exists only from the repo root"
    # A stray copy left by an earlier drifted write: the SAME full path is tracked
    # at the root and exists here untracked, so git would quietly act on the stray
    # (add stages it; diff and log answer about it). Skipped when the cwd holds no
    # tracked files at all: that is a package being scaffolded, not drift.
    if os.path.lexists(os.path.join(eff, token)) and os.path.lexists(os.path.join(root, token)):
        if cwd_has_tracked() and tracked(root, token) is True and tracked(eff, token) is False:
            return "an untracked copy here shadows the tracked file at the repo root"
    return False


def tracked(where, rel):
    """True = tracked, False = untracked (git said so), None = could not tell.
    Callers only block on a definite answer, so an error never adds a block."""
    try:
        r = subprocess.run(
            ["git", "-C", where, "ls-files", "--error-unmatch", "--", rel],
            capture_output=True, timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return True if r.returncode == 0 else (False if r.returncode == 1 else None)


_cwd_tracked = []


def cwd_has_tracked():
    if not _cwd_tracked:
        _cwd_tracked.append(tracked(eff, ".") is True)
    return _cwd_tracked[0]


blocked = []
first_segment = True
for words in segments:
    k = command_start(words)
    was_first = first_segment
    first_segment = False
    if k >= len(words):
        continue
    head = words[k]
    if head in ("cd", "pushd", "popd"):
        if was_first and leading_cd and head == "cd":
            continue  # the leading cd the hook already resolved
        break  # later steps run from a directory this hook does not track
    if not is_git(head):
        continue
    args = words[k + 1 :]
    # Global options up to the subcommand.
    j = 0
    anchored = False
    while j < len(args) and args[j].startswith("-") and args[j] != "--":
        opt = args[j]
        if opt.startswith("-C") or opt == "--git-dir" or opt.startswith("--git-dir="):
            anchored = True
            break
        j += 1
        if opt in GLOBAL_VALUE_OPTS:
            j += 1
    if anchored or j >= len(args) or args[j] == "--":
        continue
    # args[j] is the subcommand; judge what follows it.
    after_dd = False
    skip_next = False
    for w in args[j + 1 :]:
        if skip_next:
            skip_next = False
            continue
        m = REDIRECT.match(w)
        if m:
            if m.end() == len(w):
                skip_next = True  # the target is the next word
            continue
        if not after_dd:
            if w == "--":
                after_dd = True
                continue
            if w.startswith("-"):
                if w == "--message" or re.match(r"^-[A-Za-z]*m$", w):
                    skip_next = True  # the commit message, not a path
                continue
        why = judge(w)
        if why:
            blocked.append(f"{w}   ({why})")

sys.stdout.write("\n".join(blocked))
PYEOF
) || exit 0
[ -n "$BLOCKED" ] || exit 0

REL="${PREFIX%/}"
TOKENS=$(printf '%s\n' "$BLOCKED" | sed 's/^/    /')
cat >&2 << MSG
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CWD-DRIFT GUARD — command blocked
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
The shell is in a subdirectory of the repo ('$REL'), but this git
command names a path that only makes sense from the repo root:
$TOKENS
It will resolve against the subdir ('$REL/...'): it fails with "did not
match any files", or, where a stray copy exists here, quietly acts on the
stray instead of the tracked file.

Use either:
  - git -C "\$(git rev-parse --show-toplevel)" <subcommand> <paths>
    (root-anchored), or
  - run the git step in its own call from the repo root.
For a path marked "an untracked copy here shadows...", decide which file
you mean FIRST: if the copy under '$REL/' is a new file on purpose, name it
from the root ('$REL/<path>') with git -C; if it's a leftover, move its
content into the root file and delete the copy. Root-anchoring alone would
act on the root file and leave the copy behind.
See rules/core.md § Lossy steps are for known output shapes: suspect
the invocation, and check you are in the checkout you mean.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
MSG
exit 2
