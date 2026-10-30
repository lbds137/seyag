"""What a command changes before its `git commit` runs.

A PreToolUse hook runs before the command, so a guard that reads the live
branch or the live checkout judges the state the command STARTS in. Two
shapes change that state before a later commit in the same `&&` chain
runs, and a guard that ignores them blocks a commit that lands somewhere else:

    git switch -c feat/x && git add a.ts && git commit -m y
        commits on feat/x, not on the branch checked out now
    git -C /other/repo commit -m x
    env -C /other/repo git commit -m x
    cd /other/repo && git commit -m x
        commit in another checkout entirely

`switch_target` names the branch a leading switch moves to, when nothing else
in the command can move the branch or the checkout; `commit_target_dir`
names every directory a commit in the command can run in: absolute ones, and
plain relative ones reached from the starting checkout (the caller resolves a
relative one against its own working directory). Both return None for
anything they cannot read with certainty, and None means "judge the live
state", the guards' baseline evaluation. A parse gap falls back to that
evaluation — which keeps a block on a protected branch, but on a feature
checkout can pass a commit that lands elsewhere. The commit-directory read
walks every top-level connector bash has (see below); what it still cannot
place keeps the empty reading: the shapes `_ShapeReader` refuses, listed
under `commit_target_dir`. The one exception is the commit-directory read's sentinel
`UNREADABLE_DIR`: a directory change before a commit that cannot be resolved
(see `commit_target_dir`), which the caller turns into a block with a remedy
rather than a live-state evaluation, because the live state is not the place
the commits run.

WHY ONLY A PURE `&&` CHAIN
--------------------------
`a && b` runs b only when a succeeded, so after `git switch X && …` the rest of
the chain runs on X or not at all. `a; b` runs b even when a FAILED (a dirty
tree that conflicts, a name that already exists for `-c`), so the commit can
land on the original branch; `||`, `|` and `&` give no ordering guarantee
either. So `switch_target` requires EVERY join in the command to be `&&` — a
`;` anywhere, even after the commit, lets a second commit run elsewhere. The
commit-directory read is different: a directory read from `cd`/`pushd`/`-C`
holds for the next segment only after an `&&`, so it walks a SET of possible
locations. After a `;` or a newline the next segment may run with the
previous cd failed or skipped, so it sees every location reached since the
start (`cd x && make; git commit` commits in `x` or the starting checkout);
after a `||` it runs only where the previous segment failed. A commit records
every location in the set, capped at `MAX_LOCATIONS`. The walk knows each
connector's truth (D4, docs/proposals/backlog/branch-commit-guard.md): the
directory persists across `&&`, `||`, `;`, a newline and inside a `{ … }`
group (walked inline), while a pipeline's segments, a backgrounded job (`&`
backgrounds the whole `&&`/`||` list before it) and a `( … )` subshell ISOLATE
theirs: a `cd` there cannot leak out, and a commit inside resolves under that
segment's own prefix, starting from the location the enclosing walk had when
the segment began (`cd /x && git commit | cat` commits in `x`;
`cd /x | cat; git commit` does not). That is a fact about the SHELL's
directory only; the branch is on-disk repository state, so none of it applies
to `switch_target`: a switch inside a pipeline stage, a background job or a
subshell moves HEAD for every later commit, which is why every such shape
keeps voiding the switch read below.

And the switch only holds until something moves the branch or the directory
again: `git switch -c x && git switch develop && git commit` commits on
develop, and `git switch -c x && git -C /other commit` commits in a checkout
the switch never touched. A blocklist of moving verbs cannot be complete (a
git alias such as `git co develop`, a shell function, `make`), so the rest of
the chain is read against an ALLOWLIST instead: every segment after the
leading switch must be `git <subcommand>` with no global flag at all and a
subcommand in `_INERT_GIT_SUBCOMMANDS` (add, commit, status, diff, log,
show), no `log`/`diff`/`show` segment may carry `--output` (it writes a file
of the caller's choosing), and no word of any later segment may have a
`.git` path component, compared without case (`.git/HEAD`, `./.git/x`,
`x/.GIT/y`: a write there rewrites HEAD or a ref directly). The joins must
all be `&&`; a numeric fd redirect (`2>&1`, `>&2`) is not read as a `&`, but
a pipe is still a non-`&&` join. On top of that, no substitution other than
the canonical `"$(cat <<'EOF' … EOF)"` message, no heredoc with an UNQUOTED
delimiter (`<<EOF`, `<<-EOF`: bash expands `$(…)` and backticks in its body
before the commit runs, and the body is stripped before the other checks
see it — a heredoc must use a quoted delimiter, `<<'EOF'` or `<<"EOF"`), no
`bash -c`/`eval` wrapper, and no GIT_DIR-style environment variable.
Everything else keeps the live-branch evaluation.

WHY PLAIN `git checkout <name>` IS NOT READ
-------------------------------------------
`git checkout <word>` switches branches when <word> is a branch and restores
files when it is a path, and the hook cannot tell which without the very ref
lookup it would have to trust. `git switch` and `checkout -b|-B` are
unambiguous.

CONSUMERS
---------
    the commit-branch-guard hook (lands in Slice B), through
    lib/commit_location.sh (both functions)

Run as a script it reads the command from GUARD_CMD and prints three lines:
the switch target; the distinct commit locations, TAB-separated (`<start>` is
the starting checkout, an absolute path or a relative path is another one), or
`UNREADABLE_DIR` ("?") alone when a directory change before a commit cannot
be read (the caller blocks on it); and "1" when every non-commit segment of
the commit-directory read is inert (see `_commit_target`). Each is empty when
None or False. The caller reads all three lines. Pinned by the rule table and
the `MainContract` class in `tests/branch_switch_test.py`.

The quote scanning is the shared single-scan `strip_quoted_indexed` in
shell_quotes.py, imported rather than copied (that module's docstring has the
measured reason two copies of quote logic are a bypass).
"""

import os
import re
import sys

from shell_quotes import (
    QUOTED_SPAN,
    command_pipelines,
    resolve_placeholders,
    strip_heredoc_bodies,
    strip_quoted_indexed,
    substitution_spans,
    substitution_spans_matching,
    wrapped_command_strings,
)

# Characters that end the first command in the quote-stripped view. `&` covers
# both `&&` (checked for explicitly below) and a background `&`; `(`/`)` a
# subshell or grouping; `<`/`>` a redirect.
_FIRST_SEGMENT_END = re.compile(r"[;&|\n()<>]")

# A first segment carrying any of these is not read: `$` and a backtick are
# expansions whose value is unknown here, `{`/`}` brace expansion or grouping,
# `#` a comment that may swallow the `&&` itself.
_UNREADABLE = re.compile(r"[$`{}#]")

# After every `&&` is blanked out, any of these left in the REST of the
# quote-stripped view means a join with no success ordering (`;`, `||`, `|`,
# `&`, a newline), a subshell or group, or a substitution — and the switch
# target is not trusted.
_NON_AND_SEPARATOR = re.compile(r"[;&|\n\r()`{}]")

# A numeric file-descriptor redirect, `N>&M` or `>&M` (`2>&1`, `>&2`): its `&`
# duplicates a descriptor rather than backgrounding the command, so it is
# blanked before the separator check. Digits only on both sides of `>&` —
# `>&file`, `&>file` and a bare `&` still read as a separator, and a pipe is
# never neutralised.
_FD_REDIRECT = re.compile(r"\d*>&\d+")

# The only segments a trusted chain may carry after the leading switch:
# `git <subcommand> …` with the subcommand as the SECOND word (no global flag,
# no assignment prefix, no wrapper such as `command`/`env`) and one of these
# subcommands, none of which can move HEAD or the directory (under the
# trusted-config assumption below). Anything else — a git alias (`git co`),
# `cd`, `make`, `pnpm`, a function, `$CMD` — voids the target, because what it
# runs cannot be known from the text. `mv` and `rm` are absent: they write
# paths of the caller's choosing, and `git mv -f h.txt .git/HEAD` rewrites HEAD
# (git 2.50.1 exits 0 despite "invalid path"). `push` is absent:
# `--receive-pack`/`--exec` run an arbitrary command over a local transport
# (measured, git 2.50.1).
#
# The trusted-config assumption, the one canonical statement of it for this
# module and the guard that consumes it: every read here assumes trusted
# repository config and hooks. diff.external, textconv, core.fsmonitor and
# commit hooks can run commands and are not modelled; not verified.
_INERT_GIT_SUBCOMMANDS = frozenset(("add", "commit", "status", "diff", "log", "show"))

# What separates the path steps of a resolved word for the `.git` component
# check: `/`, plus `=` (an `--option=<path>` value) and `<`/`>` (a redirect
# target written against its operator, `>.git/config`).
_PATH_STEP = re.compile(r"[/=<>]")

# Git environment variables that relocate the repository, work tree or index
# for every git call that follows. A mention ANYWHERE in the raw text (an
# `export`, a prefix assignment, even a quoted one) voids both reads.
_GIT_ENV = re.compile(r"GIT_DIR|GIT_WORK_TREE|GIT_INDEX_FILE|GIT_COMMON_DIR")

# The one command substitution a trusted chain may carry: the canonical
# message body `"$(cat <<'EOF' … EOF)"`, which after heredoc and quote
# stripping is a bare `cat <<MARKER`.
_CANONICAL_CAT = re.compile(r"\s*cat\s+<<-?\s*\w+\s*\Z")

# A heredoc opener (`<<WORD` / `<<-WORD`, not a here-string `<<<`) and the
# first character of its delimiter word. Bash expands `$(…)`, backticks and
# parameters in the body unless that word is quoted, and the body is stripped
# before every other check here, so an UNQUOTED delimiter hides a substitution
# that runs before the commit. A delimiter opening with `'`, `"` or `\` is
# quoted; anything else (including a partly-quoted `E"OF"`, which bash would
# also treat as quoted) counts as unquoted, the direction that keeps the live
# branch. Read on the RAW text: the canonical message's heredoc sits inside a
# double-quoted `$(…)`, invisible in the quote-stripped view.
_HEREDOC_DELIMITER = re.compile(r"(?<!<)<<(?!<)-?[ \t]*(\S)")
_QUOTED_DELIMITER_START = ("'", '"', "\\")

# Options of the allowlisted read-only subcommands that write a file of the
# caller's choosing (a ref, the HEAD file), which makes the segment not inert.
# git accepts no abbreviation of `--output` for log/diff/show (probed: git
# 2.50.1 rejects `--outp=`/`--out=` as an unrecognized argument).
_WRITING_OPTION = re.compile(r"--output(?:=|\Z)")
_OUTPUT_SUBCOMMANDS = frozenset(("log", "diff", "show"))

_SWITCH_CREATE = ("-c", "-C", "--create", "--force-create")
_CHECKOUT_CREATE = ("-b", "-B")

# The subset of git's ref-name rules (git-check-ref-format) a typed branch name
# can break, plus `$` and a backtick, whose presence after quote removal means
# a literal the guard would rather not trust. A rejected name returns None,
# i.e. the live branch is judged, so this list only has to be conservative.
_BAD_REF = re.compile(r"[\x00-\x20\x7f~^:?*\[\\$`]|\.\.|@\{|//|^[-/.]|[/.]$|\.lock$|^@$")


def _view(text):
    """`(view, values)` from the shared indexed strip, or None."""
    return strip_quoted_indexed(text)


def _words(view, values, start, end):
    """The resolved bash words of `view[start:end]`."""
    out = []
    for tok in re.finditer(r"\S+", view[start:end]):
        pos = start + tok.start()
        resolved, _ = resolve_placeholders(tok.group(), values, view.count(QUOTED_SPAN, 0, pos))
        out.append(resolved)
    return out


def _branch_name(word):
    if not word or QUOTED_SPAN in word or _BAD_REF.search(word):
        return None
    return word


def _first_segment(view):
    """`(start, end)` of the first command when it is joined to the next one by
    `&&`, else None."""
    start = len(view) - len(view.lstrip())
    stop = _FIRST_SEGMENT_END.search(view, start)
    if stop is None or view[stop.start() : stop.start() + 2] != "&&":
        return None
    if _UNREADABLE.search(view, start, stop.start()):
        return None
    return start, stop.start()


def _relocating_env(text):
    """True when the raw command names a git environment variable that moves
    the repository, work tree or index for every later git call."""
    return _GIT_ENV.search(text) is not None


def _unquoted_heredoc(text):
    """True when the raw command opens any heredoc whose delimiter is not
    quoted, so bash expands substitutions in its body."""
    return any(m.group(1) not in _QUOTED_DELIMITER_START for m in _HEREDOC_DELIMITER.finditer(text))


def _erased_executing_heredoc(text):
    """True when `strip_heredoc_bodies` erases a heredoc body that bash
    EXECUTES: the body of a heredoc fed to a shell (`bash <<'EOF'`,
    `cat <<EOF | sh`, quoted or unquoted delimiter) or of one inside a
    substitution whose output runs. The walk reads the stripped text, where
    such a body (and any commit in it, in whatever directory the chain has
    walked to) is gone; `command_pipelines` reads the same text but keeps the
    bodies bash runs, so a difference between its reading of the raw text and
    of the stripped text means an executing span was erased. A heredoc that is
    only data (a commit message, a script for `python3 -`) reads the same
    either way.

    This is the walker-side compensating entry for the one family the six
    shared strip helpers cannot surface on their own: `wrapped_command_strings`
    sees `-c` strings, `eval` and here-strings, not a heredoc fed to a shell."""
    stripped = strip_heredoc_bodies(text)
    if stripped == text:
        return False
    return command_pipelines(text) != command_pipelines(stripped)


# The deepest command-substitution nesting `_substitution_hides_execution`
# follows; past it the read is voided (fail-closed, as `MAX_LOCATIONS` is).
_MAX_SUBSTITUTION_DEPTH = 8


def _substitution_hides_execution(text, predicate, keep_bodies=False, depth=0):
    """True when a command substitution of `text`, at any nesting depth, holds
    an executing span that `substitution_spans_matching` strips past: it
    cleans each OUTERMOST span with `strip_quoted`, which erases a quoted
    argument of the span, so a quoted nested substitution
    (`$(echo "$(git commit …)")`) and a wrapper's quoted string
    (`"$(bash -c 'git commit …')"`, hidden from `wrapped_command_strings` by
    the enclosing quotes) both read as inert there. Each span's raw content
    is re-read on its own: a wrapper in it (`wrapped_command_strings`) or the
    span itself cleaned and accepted by `predicate` voids (the span is
    re-wrapped as `$(…)` so the shared clean applies to it), and the span's
    own nested spans are followed in turn.

    `keep_bodies` reads the raw text WITHOUT the heredoc strip, for the
    caller that found an unquoted heredoc delimiter: bash expands
    `$(…)`/backticks in that body, so a substitution there runs, and the
    strip would have erased it (a quoted body's span is data; reading it too
    only over-voids, the direction `_unquoted_heredoc` already takes)."""
    if depth > _MAX_SUBSTITUTION_DEPTH:
        return True
    for span in substitution_spans(text if keep_bodies else strip_heredoc_bodies(text)):
        if wrapped_command_strings(span) or substitution_spans_matching(f"$({span})", predicate):
            return True
        if _substitution_hides_execution(span, predicate, depth=depth + 1):
            return True
    return False


def _names_git_dir(word):
    """True when a resolved word has a `.git` path component (compared without
    case: a case-insensitive file system resolves `.GIT` to the same
    directory). A path inside the repository directory can rewrite HEAD or a
    ref directly, whatever the verb that writes it."""
    return any(step.lower() == ".git" for step in _PATH_STEP.split(word))


def _blank_fd_redirects(part):
    """`part` with every numeric fd redirect blanked to the same length, so
    offsets into the original still line up."""
    return _FD_REDIRECT.sub(lambda m: " " * len(m.group()), part)


def _has_non_and_join(blanked):
    """True when `blanked` (fd redirects already blanked) holds any join other
    than `&&`, a subshell or group, or a substitution."""
    return _NON_AND_SEPARATOR.search(blanked.replace("&&", " ")) is not None


def _rest_moves(view, values, start):
    """True unless `view[start:]` is provably unable to move the branch or the
    directory (trusted-config assumption: see `_INERT_GIT_SUBCOMMANDS`): the
    whole remainder is `&&`-joined (a numeric fd redirect such as `2>&1` is
    not a join), every segment is `git <subcommand> …` with the
    subcommand (the second word, so no global flag) in
    `_INERT_GIT_SUBCOMMANDS`, no word of any segment has a `.git` path
    component (`.git/HEAD`, `./.git/x`, `x/.GIT/y`), and no `log`/`diff`/
    `show` segment carries `--output` (it writes an arbitrary file). The
    subcommand is read UNRESOLVED from the quote-stripped view, so a quoted
    `"git"` is a placeholder, not `git`; the `.git` and `--output` checks read
    the RESOLVED words, so a quoted `".git/HEAD"` or `"--output=…"` is still
    seen."""
    rest = _blank_fd_redirects(view[start:])
    if _has_non_and_join(rest):
        return True
    pos = start
    for segment in rest.split("&&"):
        seg_start, pos = pos, pos + len(segment) + 2
        if _segment_moves(view, values, seg_start, seg_start + len(segment)):
            return True
    return False


def _segment_moves(view, values, start, end):
    """True unless `view[start:end]` is one inert segment: `git <subcommand>
    …` with the subcommand (the second word, so no global flag and no prefix
    assignment) in `_INERT_GIT_SUBCOMMANDS`, no word with a `.git` path
    component, and no `--output` on a `log`/`diff`/`show`. The subcommand is
    read UNRESOLVED (a quoted `"git"` is a placeholder, not `git`); the `.git`
    and `--output` checks read the RESOLVED words."""
    words = view[start:end].split()
    if len(words) < 2 or words[0] != "git" or words[1] not in _INERT_GIT_SUBCOMMANDS:
        return True
    resolved = _words(view, values, start, end)
    if any(_names_git_dir(w) for w in resolved):
        return True
    return words[1] in _OUTPUT_SUBCOMMANDS and any(_WRITING_OPTION.match(w) for w in resolved)


def switch_target(text):
    """The branch a leading `git switch …` / `git checkout -b|-B …` moves to,
    when nothing else in the command can move the branch or the checkout
    (trusted-config assumption: see `_INERT_GIT_SUBCOMMANDS`); else None.

    Read: `git switch <name>`, `git switch -c|-C|--create|--force-create
    <name> [start]`, `git checkout -b|-B <name> [start]`. Not read (None): a
    global flag before the subcommand (`git -C dir switch …` switches ANOTHER
    checkout), any other flag, plain `git checkout <name>`, a leading
    assignment, and every command that is not a pure `&&` chain.

    The target is only true for the WHOLE command when nothing after the
    switch undoes it, so the rest of the chain must be provably inert (each
    of these returns None): any separator other than `&&` anywhere (`;`,
    `||`, `|`, `&`, a newline, a subshell or group, a backtick or `$(`; the
    `&` of a numeric fd redirect, `2>&1` or `>&2`, is not a separator); a
    command substitution other than the canonical `cat <<MARKER` message, or
    a `bash -c`/`eval` wrapper, anywhere, quoted or not; any heredoc whose
    delimiter is unquoted (`<<EOF`, `<<-EOF`), whatever its body, because
    bash expands substitutions in that body before the commit runs (a
    delimiter opening with `'`, `"` or `\\` is quoted; a here-string `<<<` is
    not a heredoc); any later segment that is not `git <subcommand>` with no
    global flag and a subcommand in the allowlist `_INERT_GIT_SUBCOMMANDS`
    (add, commit, status, diff, log, show) — so a git alias, `cd`, `make`,
    `env`, `command`, a function, `$CMD`, `git mv` and `git rm` all void the
    target; a `log`/`diff`/`show` segment carrying `--output` or
    `--output=`; any later word with a `.git` path component, compared
    without case (`.git/HEAD`, `./.git/x`, `x/.GIT/y`, a redirect target
    `>.git/config`, an `--opt=.git/x` value); and a
    GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE / GIT_COMMON_DIR mention
    anywhere in the raw text.
    """
    if _relocating_env(text):
        return None
    # Any substitution can run arbitrary commands BEFORE the commit (it is
    # expanded while the commit's arguments are built), and a quoted one is
    # invisible in the stripped view, so it is checked on the raw text. The
    # one exception is the repo's canonical message shape,
    # `-m "$(cat <<'EOF' … EOF)"`, whose span is a bare `cat <<MARKER`.
    if substitution_spans_matching(text, lambda s: _CANONICAL_CAT.match(s) is None):
        return None
    if wrapped_command_strings(text):
        return None
    # The heredoc strip below removes every body before any check sees it, and
    # the substitution scan above runs on the stripped text too, so a
    # substitution in an UNQUOTED-delimiter body (which bash expands before
    # the commit runs) is otherwise invisible. Refuse any such heredoc.
    if _unquoted_heredoc(text):
        return None
    scanned = _view(strip_heredoc_bodies(text))
    if scanned is None:
        return None
    view, values = scanned
    # A heredoc strip keeps the newline that ends the opener's line; a
    # trailing one separates nothing.
    view = view.rstrip()
    bounds = _first_segment(view)
    if bounds is None:
        return None
    if _rest_moves(view, values, bounds[1] + 2):
        return None
    words = _words(view, values, *bounds)
    if len(words) < 3 or words[0] != "git":
        return None
    verb, rest = words[1], words[2:]
    creates = (verb == "switch" and rest[0] in _SWITCH_CREATE) or (verb == "checkout" and rest[0] in _CHECKOUT_CREATE)
    if creates:
        if len(rest) not in (2, 3):
            return None
        if len(rest) == 3 and (not rest[2] or rest[2].startswith("-")):
            return None
        return _branch_name(rest[1])
    if verb == "switch" and len(rest) == 1:
        return _branch_name(rest[0])
    return None


# Global options `git` accepts before the subcommand that a commit-dir read can
# step over; none takes a value. `--git-dir` and `--work-tree` are deliberately
# absent — they relocate the repository in ways a toplevel comparison does not
# model — and so is `-c`: a `-c <key>=<value>` can relocate the work tree
# (`core.worktree`) or run a command, and no list of dangerous keys is
# attempted. Meeting any flag outside this list returns None.
_GIT_SKIP_FLAG = (
    "--no-pager",
    "-P",
    "--paginate",
    "-p",
    "--no-optional-locks",
    "--literal-pathspecs",
    "--no-replace-objects",
)

# The connectors the commit-dir walk splits the quote-stripped view on: `&&`,
# `||` and `|&` are one operator each, then the single characters.
_CONNECTOR = re.compile(r"&&|\|\||\|&|[;&|\n()]")
# A parameter expansion `${…}`: a connector character inside it (`${x//|/y}`)
# is part of the word. A brace inside a word (`${D}`, `/{a,b}`) is an
# expansion that `_changed_dir` reads as unreadable, never a group.
_PARAM_EXPANSION = re.compile(r"\$\{[^}]*\}")
# A redirect whose `&` or `|` is part of the redirection, not a connector
# (`>&file`, `<&file`, `&>file`, `>|file`; the numeric `2>&1` form is blanked
# first, see `_connector_view`). The reader does not model these: the empty
# reading stands.
_REDIRECT_CONNECTOR = re.compile(r"[<>]&|&>|>\|")
# A `#` standing at the start of a word, and a `case` word: each makes a
# connector character after it unreadable here (a comment's text is not
# commands; a case pattern's `)` closes no subshell), so the empty reading
# stands when one of them meets a pipe, `&`, or a paren.
_COMMENT_WORD = re.compile(r"(?:^|\s)#")
_CASE_WORD = re.compile(r"(?<![\w.-])case(?![\w.-])")
# What may follow a closing `)` or `}` before the next connector: nothing, or
# a redirection of the group (`) > log`, `} 2>/dev/null`).
_REDIRECT_ONLY = re.compile(r"\s*(?:\d*[<>]|\Z)")
# The deepest `( … )` / `{ … }` nesting the reader follows; past it the read
# is void (the empty reading, as `_MAX_SUBSTITUTION_DEPTH` is for spans).
_MAX_NESTING = 12
# CDPATH mentioned anywhere in the raw text (an assignment, an `export`, even
# a quoted one): a relative cd/pushd may then search it.
_CDPATH_MENTION = re.compile(r"CDPATH")
# HOME mentioned anywhere in the raw text (`HOME=/x cd ~/y`, `export HOME=…`,
# even a quoted one): a tilde argument may then expand to a different home
# than the hook process's own.
_HOME_MENTION = re.compile(r"HOME")
# The most locations the commit-dir walk keeps. Each location costs the caller
# one `git rev-parse` in commit_location.sh, and plain `;`-joined relative cds
# double the set per segment, so past this the walk gives up (fail-closed).
MAX_LOCATIONS = 32
# Separates the distinct locations on line 2 of the script output. A tab can
# never appear in a read path: `_absolute_dir` and `_plain_relative` refuse
# every control character (rows: "a tab in a cd path is unreadable").
LOCATION_SEPARATOR = "\t"
_COMMIT_WORD = re.compile(r"(?i)(?<![\w-])commit(?![\w-])")


def _mentions_commit(span):
    return _COMMIT_WORD.search(span) is not None


# A shell prefix assignment word, `NAME=value` (value possibly empty).
_PREFIX_ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")


def _mentions_cdpath(text):
    """True when the raw command mentions `CDPATH` anywhere, the same
    mention rule as `_relocating_env` for the GIT_* variables."""
    return _CDPATH_MENTION.search(text) is not None


def _mentions_home(text):
    """True when the raw command mentions `HOME` anywhere, the same mention
    rule as `_mentions_cdpath`."""
    return _HOME_MENTION.search(text) is not None


def _has_parent_step(path):
    """True when `path` has a `..` component. `cd` and `git -C` resolve one
    PHYSICALLY — through a symlink it climbs out of the link's TARGET, not the
    directory the text names — while `os.path.normpath` drops it lexically, so
    `/other/l/..` (with `l` a link into this repo) would read as `/other`.
    No such path is read; there is no realpath resolution."""
    return ".." in path.split("/")


def _absolute_dir(word):
    # Absolute only: a relative dir resolves against the SHELL's cwd, which the
    # hook does not reliably know. `~`, expansions and globs are refused by the
    # same rule (none of them start with `/`, or they carry `$`/`*`), and so is
    # a brace in the word (`/{a,b}` is a brace expansion; row: "a
    # brace-expansion cd argument is unreadable").
    if not word.startswith("/") or QUOTED_SPAN in word or _has_parent_step(word):
        return None
    if re.search(r"[\x00-\x1f$`*?\[{}]", word):
        return None
    return word


# The directory state after a `cd`/`pushd`/`popd` (or a `-C` step) the hook
# cannot resolve. It can never be a real absolute path, which always starts
# with `/`, so it cannot collide with one.
UNREADABLE_DIR = "?"

_DIR_CHANGERS = ("cd", "pushd", "popd")

# Pre-words whose command still runs in the current shell: `!` inverts only
# the exit status, `time` only reports on it. A directory change behind them
# moves the directory all the same, so the mover read steps past a run of
# them (`_dir_change_words`; rows: "R1: a !-prefixed cd moves the dir read",
# "R1: a time-prefixed cd moves the dir read").
_TRANSPARENT_PRE = frozenset(("!", "time"))

# The compound-command keywords: a segment whose leading command word is one
# of these cannot be placed by the flat reader (what bash runs and skips
# inside the compound is unknowable — a changer in a branch or loop body may
# or may not run, and a &&-skipped compound must not let its states cross a
# `;` boundary), so the segment reads as an unresolvable change rather than
# as a placed step (rows: "R1: a cd behind then/do/else reads unreadable").
# `!` and `time` are deliberately absent — they are transparent
# (`_TRANSPARENT_PRE`) — and so are the grouping braces, which the shape
# reader places as groups, never as words.
_CONDITIONAL_KEYWORDS = frozenset(
    ("if", "then", "elif", "else", "fi", "do", "done", "while", "until", "for", "select", "case", "esac")
)

# `source x` / `. x` run a script in the current shell, so what they change
# (the directory included) is unknown.
_SOURCE_WORDS = ("source", ".")

# The walk state for the checkout the command STARTS in, whose directory the
# hook does not know (a commit there is judged on the live state). Distinct
# from None, which means "void", and from `UNREADABLE_DIR`; not an absolute
# path, and not returned from `_commit_target` (row: "two bare commits read
# nothing"). A walk state that is none of `_START`, `UNREADABLE_DIR` or an
# absolute path is a RELATIVE location reached from the starting checkout by
# plain relative steps. Compare states with `==`, never `is`.
_START = "<start>"


def _plain_relative(step):
    """True when a relative directory word can be joined onto a known base:
    non-empty, no `..` step, no unresolved quoted span, no control character,
    `$`, backtick, glob character, brace (a brace expansion), `~`, `<` or `>`
    (the last two so a quoted relative `"<start>"` cannot collide with the
    `_START` marker; row: "a quoted relative cd named like the start marker is
    unreadable")."""
    return (
        bool(step)
        and QUOTED_SPAN not in step
        and not _has_parent_step(step)
        and not re.search(r"[\x00-\x1f$`*?\[{}~<>]", step)
    )


def _step_dir(step, base):
    """The directory after one `-C <step>` (git or env) from `base` (`_START`,
    an absolute path, a relative location or `UNREADABLE_DIR`), or None when it
    cannot be read. An absolute step stands alone; a relative one stays
    unreadable on an unreadable base (row: "an unreadable cd keeps a relative -C
    unreadable") and joins onto a known base, which from the starting checkout
    makes the step itself the relative location (row: "a relative -C from the
    starting checkout reads the relative path"). A non-plain one is void."""
    if step.startswith("/"):
        return _absolute_dir(step)
    if base == UNREADABLE_DIR:
        return base
    if not _plain_relative(step):
        return None
    if base == _START:
        return step
    return os.path.join(base, step)


def _home_dir(arg, tilde_quoted, home_mentioned=False):
    """The absolute path a leading-tilde `cd` argument names: bare `~` is the
    hook process's own `HOME`, `~/rest` is `HOME` + `/rest`. This ASSUMES the
    shell running the command has the same `HOME`; that is not verified, so a
    command that mentions `HOME` anywhere (`HOME=… cd ~/x`, `export HOME=…`)
    makes the argument unreadable instead (row: "a HOME mention makes a tilde
    cd unreadable"). None also when `HOME` is unset, empty or not absolute, the
    tilde was quoted (bash does not expand it, and the resolved word cannot
    tell), or the form is `~user` / `~+` / `~-`."""
    if home_mentioned or tilde_quoted or not (arg == "~" or arg.startswith("~/")):
        return None
    home = os.environ.get("HOME", "")
    if not home.startswith("/"):
        return None
    return home + arg[1:]


# A word that IS a redirection (`2>/dev/null`, `>/dev/null`, `2>&1`): bash
# strips redirections from a simple command before it runs, so such a word is
# never one of the changer's arguments. Only a word OPENING with the operator
# matches; an argument that merely contains `<`/`>` (a quoted dir named
# `a>b`) is left for `_plain_relative`/`_absolute_dir` to refuse (row: "a
# quoted relative cd with a > is unreadable").
_ARG_REDIRECT = re.compile(r"\d*[<>]")


def _changed_dir(words, here, cdpath=False, tilde_quoted=False, home_mentioned=False):
    """The directory state after a `cd`/`pushd`/`popd` segment, from `here`.

    Redirection words (`2>/dev/null`, `>/dev/null`, `2>&1`) are dropped from
    the arguments first — bash strips redirections from a simple command
    before it runs — but one whose target has a `.git` path component keeps
    the segment unreadable: the shell would still create or truncate that
    file (rows: "R1: a redirect on the cd argument reads the cd", "R1: a
    redirect into .git on the cd still blocks"). Leading `--`, `-L` and `-P`
    words (any number, any order) are skipped; what
    remains must be exactly one argument that is not another flag or a `+N`
    stack index, else `UNREADABLE_DIR` (rows: "a bare cd before a commit
    blocks", "cd - before a commit blocks", "cd with an unsupported flag is
    unreadable", "cd with only a flag is unreadable"). `pushd -n` is covered by
    the flag rule: it manipulates the stack without changing directory, so it
    is treated as unreadable (fail-closed). `popd` is `UNREADABLE_DIR` (row:
    "popd before a commit blocks"). An absolute argument sets the directory
    whatever came before it (row: "a second absolute cd moves the dir read");
    one the hook cannot read (a `..` step, an expansion, a glob) is
    unreadable. A bare `~` or `~/rest` is read through the hook's own `HOME`
    and then like any absolute argument (rows: "a cd to ~/x reads HOME/x", "a
    bare cd ~ reads HOME", "a cd to ~user/x is unreadable", "a cd to ~/x with
    HOME unset is unreadable", "a quoted tilde is unreadable", "a HOME mention
    makes a tilde cd unreadable"). A plain
    relative argument joins onto the current location; from the starting
    checkout it becomes the relative location itself (row: "a relative cd from
    the starting checkout reads the relative path"), and on an unreadable
    state it leaves it as it was. When `CDPATH` is set and non-empty in the
    hook's environment, or `cdpath` says the raw command mentions it, the shell
    may search it for a relative argument, so every relative `cd`/`pushd`
    argument is `UNREADABLE_DIR` (rows: "a relative cd is unreadable while
    CDPATH is set", "an exported CDPATH mention makes a relative cd
    unreadable", "a CDPATH prefix assignment makes a relative cd unreadable")."""
    if words[0] == "popd":
        return UNREADABLE_DIR
    args = words[1:]
    dropped = [w for w in args if _ARG_REDIRECT.match(w)]
    if dropped:
        # A redirection is not an argument, so it does not make the changer
        # unreadable; but a target with a `.git` path component would be
        # written by the shell all the same, and keeps the fail-closed
        # reading through the `.git`-mention rule.
        if any(_names_git_dir(w) for w in dropped):
            return UNREADABLE_DIR
        args = [w for w in args if not _ARG_REDIRECT.match(w)]
    while args and args[0] in ("--", "-L", "-P"):
        args = args[1:]
    if len(args) != 1 or args[0].startswith(("-", "+")):
        return UNREADABLE_DIR
    arg = args[0]
    if arg.startswith("~"):
        arg = _home_dir(arg, tilde_quoted, home_mentioned) or arg
    if arg.startswith("/"):
        return _absolute_dir(arg) or UNREADABLE_DIR
    if not _plain_relative(arg) or cdpath or os.environ.get("CDPATH"):
        return UNREADABLE_DIR
    if here == UNREADABLE_DIR:
        return here
    if here == _START:
        return arg
    return os.path.join(here, arg)


def _commit_dir(words, base):
    """The directory a `[env -C <dir> …] git [globals] commit …` segment runs
    in, starting from `base` (`_START`, an absolute or relative location, or
    `UNREADABLE_DIR`),
    or None when it cannot be read (void). A bare commit returns `base`
    unchanged, `_START` included.

    Leading `NAME=value` prefix assignments (the override token's position)
    are skipped: they set the commit's environment, not its directory. A
    GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE / GIT_COMMON_DIR one never gets
    here — `_relocating_env` has already voided the whole read.

    `env` in front of git is read only through `-C <dir>`, `--chdir <dir>` or
    `--chdir=<dir>` (at least one), each resolved like a `git -C` step;
    any other `env` option, or `env` with no directory option, is not read."""
    while words and _PREFIX_ASSIGNMENT.match(words[0]):
        words = words[1:]
    if not words:
        return None
    here = base
    if words[0] == "env":
        i, moved = 1, False
        while i < len(words):
            word = words[i]
            if _PREFIX_ASSIGNMENT.match(word):
                i += 1
            elif word in ("-C", "--chdir") or word.startswith("--chdir="):
                if word.startswith("--chdir="):
                    step, width = word[len("--chdir=") :], 1
                elif i + 1 < len(words):
                    step, width = words[i + 1], 2
                else:
                    return None
                here = _step_dir(step, here)
                if here is None:
                    return None
                moved = True
                i += width
            else:
                break
        if not moved:
            return None
        words = words[i:]
    if not words or words[0] != "git":
        return None
    i = 1
    while i < len(words) and words[i].startswith("-"):
        flag = words[i]
        if flag == "-C":
            if i + 1 >= len(words):
                return None
            here = _step_dir(words[i + 1], here)
            if here is None:
                return None
            i += 2
        elif flag in _GIT_SKIP_FLAG:
            i += 1
        else:
            return None
    if i >= len(words) or words[i] != "commit":
        return None
    return here


def commit_target_dir(text):
    """Every directory a `git commit` in `text` can run in, TAB-separated
    (`LOCATION_SEPARATOR`), else None; `UNREADABLE_DIR` alone when a directory
    change before a commit cannot be read. Each location is absolute, a
    normalised plain RELATIVE path reached from the starting checkout (no `..`
    step; the caller resolves it against its own working directory, which is
    the starting checkout), or the marker `<start>` for the starting checkout
    itself when it is one of several (a lone `<start>` reads None).

    The directory is followed through the command in order as a SET of
    possible locations: every `cd <dir>` / `pushd <dir>` moves each element
    (an absolute one outright, a plain relative one joined onto the current
    location; from the starting checkout the relative path itself is the
    location, so `cd sub && git commit` reads `sub`; a bare `~` or `~/rest`
    through the hook's `HOME` unless the command mentions `HOME`), and each commit may add `git -C <dir>` or
    `env -C <dir>` (`--chdir`) steps resolved the same way. A `!` or `time`
    before the changer is stepped past (its command runs in the current shell;
    rows: "R1: a !-prefixed cd moves the dir read", "R1: a time-prefixed cd
    moves the dir read"), and a redirection word on the changer
    (`cd /x 2>/dev/null`) is dropped from its arguments, as bash strips
    redirections before the command runs — one naming a `.git` path component
    keeps the fail-closed reading (row: "R1: a redirect into .git on the cd
    still blocks"). The walk keeps two
    exact sets of states: those where the last status is zero (`ok`) and those
    where it is non-zero (`fail`); a cd that fails leaves a state where it was.
    After an `&&` the next segment sees the states where the previous one
    succeeded, and the states that failed skip it and carry forward. After a
    `||` it sees the states where the previous one failed, and the succeeded
    ones carry forward. After a `;` or a newline it sees both (rows: "a ;
    before a cd reads both locations", "a newline before a cd reads both
    locations", "a || before a cd reads both locations", "a ; after && reads
    the union reached since the start", "a || before a cd keeps the location
    where the cd is skipped", "a || cd starts where the previous cd failed",
    "a || cd then ; reads both cds and the start, never the joined path", "a
    || before a non-cd segment changes nothing"). The set is capped at
    `MAX_LOCATIONS`: past it the walk fails closed to `UNREADABLE_DIR` (row:
    "about 20 ;-joined relative cds hit the location cap"; boundary rows: "5
    ;-joined relative cds read 32 locations", "6 ;-joined relative cds hit the
    location cap"). A
    change AFTER the last commit is not read (row: "a pushd after the commit
    does not move it"). A numeric fd redirect such as `2>&1` is not a join.

    The persistent connectors (`&&`, `||`, `;`, a newline, a `{ … }` group's
    contents) carry the location state; the isolated segments do not leak
    theirs (D4; `_SegmentWalk`): the stages of a pipeline (`|`, `|&`), the
    `&&`/`||` list a `&` backgrounds, and a `( … )` subshell. A commit inside
    one resolves under that segment's own cd prefix, from the location the
    enclosing walk had when the segment began: rows "a cd in a pipeline
    segment does not move a commit after it", "a cd in a pipeline segment does
    not move a commit in a sibling segment", "a subshell cd does not leak", "a
    cd in a background job does not move a later commit", "a subshell starts
    from the enclosing location", "a brace group persists the cd into its
    commit". An unresolvable location in or before an isolated segment that
    holds a commit is `UNREADABLE_DIR` (rows: "an unresolvable cd before a
    pipeline blocks a commit inside it", "an unresolvable cd inside a brace
    group in a pipeline blocks its commit", "an unresolvable cd in a subshell
    blocks its commit"), while one that only ran in another segment is not
    (rows: "an unresolvable cd in a pipeline segment does not block a commit
    outside it", "an unresolvable cd in a background job does not block a
    later commit", "an unresolvable cd inside a subshell does not leak").

    `UNREADABLE_DIR` (a block, not a live-state evaluation) when a commit
    follows a change that cannot be resolved (`popd`, `cd -`, a bare `cd`, a
    flag other than `--`/`-L`/`-P` or a second argument on `cd`/`pushd`, a
    segment whose leading command word is a compound-command keyword
    (`if`/`then`/`do`/…: what bash runs and skips inside the compound cannot
    be read from the text; rows: "R1: a cd behind then/do/else reads
    unreadable"),
    `~user`, an expansion, a glob, a `..` step, or a relative argument while
    `CDPATH` is set or mentioned, or a `source x` / `. x` segment, which runs
    arbitrary code in the shell) in ANY possible location, unless a later
    absolute `cd`/`-C` resets the directory. A `..` step is refused because
    `cd` and `git -C` may follow a symlink where `normpath` only edits the
    text (not verified here). In a `-C` step the unresolvable inputs are not
    read (None) instead. Commits that all run in the starting checkout read
    nothing; commits in several locations are NOT collapsed here — the caller
    resolves them to checkouts and judges whether they span more than one.

    None for any commit the hook cannot place, so the live state is judged:
    a `(` that does not start a command (`$(date)` unquoted, `<(…)`, `f()`),
    `((` arithmetic, a `)` or a `}` closing nothing, a group or subshell left
    open, a whole-word `{` or `}` anywhere else (an argument; rows: "a stray
    brace word is not a group, so it is not read", "an unterminated brace
    group is not read", "a stray closing brace is not read"), a redirect that
    carries its own `&` or `|` (`>&file`, `&>file`, `>|file`), a comment or a
    `case` word beside a pipe, `&` or paren, a CR, nesting past
    `_MAX_NESTING`. The connectors themselves are read (rows: "a pipe,
    background or subshell shape reads its own segment (pipe)", "(background)",
    "(subshell)", "(group)", "a brace group persists the cd into its commit",
    and the isolation rows around them). A brace
    inside a word is an expansion, not a group, and reads as unreadable (rows:
    "a ${VAR} cd argument is an unreadable expansion", "a brace-expansion cd
    argument is unreadable"),
    a `commit` word in a segment that is not a plain
    `[env -C <dir>] git [globals] commit` (row: "a commit word outside a git
    commit segment voids the dir read"), a commit segment carrying any
    `-c <key>=<value>` global flag (`core.worktree` relocates the work tree; no
    list of safe keys is attempted; row: "a -c global flag voids the dir
    read"), a commit inside a command substitution or a `bash -c`/`eval`
    wrapper, a heredoc body that a shell executes (`bash <<'EOF'`, either
    delimiter form: the heredoc strip would erase the commit it carries, so
    `_erased_executing_heredoc` voids the read like a wrapper), a substitution
    nested inside another that the span clean erases (a quoted `$(…)` or a
    wrapper's quoted string inside a span) or one in the body of an unquoted
    heredoc (`_substitution_hides_execution`),
    an unexpandable `-C` directory, and a GIT_DIR / GIT_WORK_TREE /
    GIT_INDEX_FILE / GIT_COMMON_DIR mention anywhere in the raw text (an
    exported one relocates the commit whatever `-C` says; row: "a quoted
    GIT_COMMON_DIR mention voids the dir read").

    Leading `NAME=value` prefix assignments on a commit segment (such as
    `SYG_ALLOW_COMMIT_BRANCH=1 git -C <dir> commit`) are skipped,
    not refused; a GIT_* one still voids the read through the mention rule
    above. (`switch_target` is unchanged: a leading assignment voids it.)
    """
    return _commit_target(text)[0]


class _UnreadableShape(Exception):
    """A top-level shape `_ShapeReader` cannot place: the empty reading."""


def _connector_view(view):
    """`view` with numeric fd redirects (`2>&1`) and `${…}` expansions blanked
    to the same length, so the `&` of a redirect and a connector character in
    an expansion are not read as connectors; offsets still line up with
    `view`."""
    blanked = _blank_fd_redirects(view)
    return _PARAM_EXPANSION.sub(lambda m: "x" * len(m.group()), blanked)


def _read_shape(view, connectors):
    """The connector structure of the quote-stripped `view` as nested units
    (`_ShapeReader`), or `_UnreadableShape`. `connectors` is
    `_connector_view(view)`, the text the connector search runs on. The
    quote, heredoc and substitution handling is the scanner's, upstream: the
    view has its quoted spans as placeholders and its heredoc bodies gone, so
    this only has to split what is left, and it refuses (the empty reading)
    every construct it cannot place rather than guess."""
    tokens = []
    pos = 0
    for match in _CONNECTOR.finditer(connectors):
        tokens.append(("seg", pos, match.start()))
        tokens.append(("op", match.group()))
        pos = match.end()
    tokens.append(("seg", pos, len(view)))
    return _ShapeReader(view, tokens).read_list(None, 0)


class _ShapeReader:
    """Reads the tokens of `_read_shape` (alternating segments and connectors,
    starting and ending with a segment) into a tree:

        list   = [(and_or, background)]    split on `;`, a newline, `&`
        and_or = [(op, pipeline)]          op is None, `&&` or `||`
        pipeline = [stage]                 split on `|` and `|&`
        stage  = ("simple", start, end) | ("sub", list) | ("group", list)

    bash's precedence: `|` binds tighter than `&&`/`||`, which bind tighter
    than `;`, a newline and `&`; a `&` backgrounds the whole and-or list
    before it. A `( … )` is a subshell stage and a `{ … }` a group stage; the
    `{` and `}` count only as a whole word at the start of a command, and any
    other whole-word brace is refused. A `(` that is not at the start of a
    command (`$(`, `<(`, `f()`, `echo (`), a `)` with nothing to close, a
    group or subshell left open, anything but a redirection after a closer,
    and nesting past `_MAX_NESTING` raise `_UnreadableShape`."""

    def __init__(self, view, tokens):
        self.view = view
        self.tokens = tokens
        self.i = 0

    def _op(self):
        if self.i < len(self.tokens) and self.tokens[self.i][0] == "op":
            return self.tokens[self.i][1]
        return None

    def _redirects_only(self, start, end):
        if _REDIRECT_ONLY.match(self.view[start:end]) is None:
            raise _UnreadableShape

    def read_list(self, closer, depth):
        """The units up to `closer` (None for the end of the text, `)` for a
        subshell, `}` for a group); the closer is consumed."""
        if depth > _MAX_NESTING:
            raise _UnreadableShape
        units = []
        while True:
            _, start, end = self.tokens[self.i]
            if closer == "}":
                text = self.view[start:end]
                if text.split()[:1] == ["}"]:
                    at = start + len(text) - len(text.lstrip())
                    self._redirects_only(at + 1, end)
                    self.i += 1
                    return units
            and_or = self.read_and_or(depth)
            op = self._op()
            if op is None:
                if closer is not None:
                    raise _UnreadableShape
                units.append((and_or, False))
                return units
            if op == ")":
                if closer != ")":
                    raise _UnreadableShape
                self.i += 1
                units.append((and_or, False))
                return units
            if op not in (";", "\n", "&"):
                raise _UnreadableShape
            units.append((and_or, op == "&"))
            self.i += 1

    def read_and_or(self, depth):
        parts = [(None, self.read_pipeline(depth))]
        while self._op() in ("&&", "||"):
            op = self.tokens[self.i][1]
            self.i += 1
            parts.append((op, self.read_pipeline(depth)))
        return parts

    def read_pipeline(self, depth):
        stages = [self.read_stage(depth)]
        while self._op() in ("|", "|&"):
            self.i += 1
            stages.append(self.read_stage(depth))
        return stages

    def read_stage(self, depth):
        _, start, end = self.tokens[self.i]
        text = self.view[start:end]
        words = text.split()
        if words[:1] == ["{"]:
            # The group's first command is the rest of this segment.
            at = start + len(text) - len(text.lstrip())
            self.tokens[self.i] = ("seg", at + 1, end)
            return ("group", self.read_list("}", depth + 1))
        if self.i + 1 < len(self.tokens) and self.tokens[self.i + 1] == ("op", "("):
            if words:
                raise _UnreadableShape
            self.i += 2
            units = self.read_list(")", depth + 1)
            _, after_start, after_end = self.tokens[self.i]
            self._redirects_only(after_start, after_end)
            self.i += 1
            return ("sub", units)
        if "{" in words or "}" in words:
            raise _UnreadableShape
        self.i += 1
        return ("simple", start, end)


class _SegmentWalk:
    """Follows the possible-location sets through the tree `_ShapeReader`
    reads. Persistent connectors thread the `(ok, fail)` states through (`&&`,
    `||`, `;`, a newline, a `{ … }` group's contents inline). An ISOLATED
    segment is walked as a chain of its own from the state at its start, its
    commits recorded under its own cd prefix, and it hands nothing back: the
    stages of a multi-stage pipeline, the and-or list a `&` backgrounds, and a
    `( … )` subshell. After one, the enclosing walk continues from the
    location it had before (the status is unknown, so both `ok` and `fail`
    hold it). `results` collects every commit's location, `inert` clears when
    any non-commit, non-cd segment may move the branch or the directory.

    Not modelled: `shopt -s lastpipe`, under which the last stage of a pipeline
    runs in the current shell."""

    def __init__(self, view, values, cdpath, home, inert=True):
        self.view = view
        self.values = values
        self.cdpath = cdpath
        self.home = home
        self.inert = inert
        self.results = set()

    def run_list(self, units, ok, fail):
        for and_or, background in units:
            if background:
                self.run_and_or(and_or, ok, fail)
                ok = ok | fail
                fail = set(ok)
            else:
                ok, fail = self.run_and_or(and_or, ok, fail)
        return ok, fail

    def run_and_or(self, parts, ok, fail):
        for op, stages in parts:
            # The join BEFORE a pipeline picks its input: after `&&` it runs
            # only from the states where the previous one succeeded, after
            # `||` only from those where it failed; at the start of a list
            # item (the first part: after `;`, a newline or `&`) from both.
            # The states that skip it carry forward unchanged.
            if op == "&&":
                run, skipped = ok, fail
            elif op == "||":
                run, skipped = fail, ok
            else:
                run, skipped = ok | fail, set()
            seg_ok, seg_fail = self.run_pipeline(stages, run)
            if op == "&&":
                ok, fail = seg_ok, seg_fail | skipped
            elif op == "||":
                ok, fail = seg_ok | skipped, seg_fail
            else:
                ok, fail = seg_ok, seg_fail
            if len(ok | fail) > MAX_LOCATIONS:
                ok = fail = {UNREADABLE_DIR}
        return ok, fail

    def run_pipeline(self, stages, run):
        if len(stages) == 1:
            return self.run_stage(stages[0], run)
        for stage in stages:
            self.run_stage(stage, run)
        return set(run), set(run)

    def run_stage(self, node, run):
        if node[0] == "simple":
            return self.run_simple(node[1], node[2], run)
        if node[0] == "group":
            return self.run_list(node[1], set(run), set())
        self.run_list(node[1], set(run), set())
        return set(run), set(run)

    def run_simple(self, start, end, run):
        words = _words(self.view, self.values, start, end)
        seg_ok = seg_fail = set(run)
        if words:
            mover = _dir_change_words(words)
            if mover is not None:
                tilde = _tilde_quoted(self.view, start, end)
                seg_ok = {_changed_dir(mover, h, self.cdpath, tilde, self.home) for h in run}
            elif _conditional_dir_change(words):
                # A compound-command keyword makes the segment unplaceable —
                # what bash runs and skips inside the compound is unknowable,
                # with or without a changer behind it; the walk refuses the
                # confident wrong answer ("no change") and reads the same
                # value an unresolvable cd produces. `inert` is cleared (a
                # re-pointing command behind a keyword must not earn the
                # different-repository silence), and a commit word behind the
                # keyword voids the whole read: that commit's directory is as
                # unplaceable as the segment, so it is recorded unreadable
                # instead of being dropped from the results.
                seg_ok = {UNREADABLE_DIR for _ in run}
                self.inert = False
                if any(w.lower() == "commit" for w in words):
                    self.results.update(UNREADABLE_DIR for _ in run)
            elif _is_source(words):
                seg_ok = seg_fail = {UNREADABLE_DIR}
                self.inert = False
            elif not any(w.lower() == "commit" for w in words):
                if _segment_moves(self.view, self.values, start, end):
                    self.inert = False
            else:
                self.results.update(_commit_dir(words, h) for h in run)
        return seg_ok, seg_fail


def _commit_target(text):
    """`(directory, others_inert)`: the `commit_target_dir` reading, plus
    whether every segment other than the commit segment(s) and the
    `cd`/`pushd`/`popd` segments is inert (`_segment_moves`, the per-segment
    rule `switch_target` applies). A non-inert one (`ln -sfn`, `mv`, a git
    alias) can re-point the read directory after the hook resolved it, so a
    False must not earn the different-repository silence; the directory is
    still returned, because re-pointing at a sibling worktree only adds a
    block. A directory change does not clear it: it is how the directory is
    set, followed in order (row: "a relative cd joins onto a known absolute
    dir"); the one exception is `source`/`.`, which runs arbitrary code and
    clears it like `make` (row: "a source after the commit does not block, but
    clears inert"). `(None, False)` whenever no directory is read;
    `(UNREADABLE_DIR, False)` when any commit follows a directory change that
    cannot be resolved in any possible location. Otherwise the TAB-joined,
    sorted distinct locations: the `_START` marker (the starting checkout)
    appears only beside other locations (row: "two bare commits read
    nothing"), and a relative location is a normalised relative path."""
    if _relocating_env(text):
        return None, False
    if substitution_spans_matching(text, lambda s: _COMMIT_WORD.search(s) is not None):
        return None, False
    if wrapped_command_strings(text):
        return None, False
    if _erased_executing_heredoc(text):
        return None, False
    if _substitution_hides_execution(text, _mentions_commit):
        return None, False
    if _unquoted_heredoc(text) and _substitution_hides_execution(text, _mentions_commit, keep_bodies=True):
        return None, False
    scanned = _view(strip_heredoc_bodies(text))
    if scanned is None:
        return None, False
    view, values = scanned
    if "`" in view:
        return None, False
    # A heredoc strip keeps the newline that ends the opener's line; a
    # trailing one separates nothing.
    view = view.rstrip()
    # D4 (artifact docs/proposals/backlog/branch-commit-guard.md): the
    # connectors are read as bash reads them. `&&`, `||`, `;`, a newline and a
    # `{ … }` group persist the location state; a pipeline segment, a
    # backgrounded job and a `( … )` subshell isolate theirs (`_read_shape`,
    # `_SegmentWalk`). What the reader cannot place keeps the empty reading: a
    # CR, `((`, a redirect that carries a `&` or `|` of its own, a comment or
    # a `case` beside a connector character, and the shapes `_ShapeReader`
    # refuses.
    connectors = _connector_view(view)
    if "\r" in view or "((" in connectors or _REDIRECT_CONNECTOR.search(connectors):
        return None, False
    flat = connectors.replace("&&", "  ").replace("||", "  ")
    if re.search(r"[|&()]", flat) and (_COMMENT_WORD.search(flat) or _CASE_WORD.search(flat)):
        return None, False
    try:
        units = _read_shape(view, connectors)
    except _UnreadableShape:
        return None, False

    # A numeric fd redirect (`2>&1`) is not a connector, but it clears
    # `inert` all the same: round 1's flat split read its `&` as a separator
    # and left a non-inert `1` segment, and that fail-closed reading stays
    # pinned (row: "commit-dir read: a 2>&1 redirect clears inert").
    walk = _SegmentWalk(
        view, values, _mentions_cdpath(text), _mentions_home(text), inert=_FD_REDIRECT.search(view) is None
    )
    # Two exact sets of possible locations: `ok` holds the states in which the
    # last status is zero, `fail` those in which it is non-zero.
    walk.run_list(units, {_START}, set())
    results, inert = walk.results, walk.inert
    if not results:
        return None, False
    if UNREADABLE_DIR in results:
        return UNREADABLE_DIR, False
    if len(results) > MAX_LOCATIONS:
        return UNREADABLE_DIR, False
    if None in results:
        return None, False
    found = {r if r == _START else os.path.normpath(r) for r in results}
    if found == {_START}:
        return None, False
    return LOCATION_SEPARATOR.join(sorted(found)), inert


def _tilde_quoted(view, start, end):
    """True when the last word of `view[start:end]` (the `cd` argument) holds
    a quoted span, so a leading `~` in its resolved form was not an unquoted
    tilde bash would expand. A word mixing an unquoted leading tilde with a
    quoted part (`~/"x y"`) is deliberately read as unreadable too: that is
    conservative, and bash's tilde handling next to quotes is not modelled."""
    tokens = view[start:end].split()
    return bool(tokens) and QUOTED_SPAN in tokens[-1]


def _command_words(words, transparent=False):
    """`words` from the command word on, past `NAME=value` assignments and
    `command`/`builtin`, which leave a directory change in place; with
    `transparent`, past runs of `!`/`time` too — their command runs in the
    current shell whatever they report, so the mover read finds the changer
    behind them."""
    while words and (
        _PREFIX_ASSIGNMENT.match(words[0])
        or words[0] in ("command", "builtin")
        or (transparent and words[0] in _TRANSPARENT_PRE)
    ):
        words = words[1:]
    return words


def _dir_change_words(words):
    """`words` from the `cd`/`pushd`/`popd` word on when the segment is one,
    else None. A run of `!`/`time` before the changer is stepped past: their
    command runs in the current shell, so the changer behind them still moves
    the directory (rows: "R1: a !-prefixed cd moves the dir read", "R1: a
    time-prefixed cd moves the dir read")."""
    words = _command_words(words, transparent=True)
    if words and words[0] in _DIR_CHANGERS:
        return words
    return None


def _conditional_dir_change(words):
    """True when the segment's leading command word is a compound-command
    keyword (`_CONDITIONAL_KEYWORDS`): the flat reader cannot place what bash
    runs and skips inside the compound — a `cd` behind `then` may or may not
    run, and a `&&`-skipped compound must not let its states cross a `;`
    boundary — so the segment reads as an unresolvable change rather than as
    a placed step (rows: "R1: a cd behind then reads unreadable", "R1: a
    keyword segment with no dir-changer neither moves nor blocks").
    """
    words = _command_words(words, transparent=True)
    return bool(words) and words[0] in _CONDITIONAL_KEYWORDS


def _is_source(words):
    """True when the segment's command word is `source` or `.`: it runs a
    script in the current shell, which can change directory or anything else."""
    words = _command_words(words)
    return bool(words) and words[0] in _SOURCE_WORDS


if __name__ == "__main__":
    command = os.environ.get("GUARD_CMD", "")
    # Line 1: the switch target; line 2: the distinct commit locations,
    # TAB-separated (`<start>` = the starting checkout), or the sentinel "?"
    # alone when a directory change before a commit cannot be read (the caller
    # blocks on it); line 3: "1" when every non-commit, non-cd segment is
    # inert. Each line is empty for None or False.
    try:
        target = switch_target(command)
    except Exception:
        # Fail toward the live-state evaluation, the guards' pre-existing
        # behaviour, rather than toward any reading of the command.
        target = None
    try:
        commit_dir, others_inert = _commit_target(command)
    except Exception:
        commit_dir, others_inert = None, False
    print(target or "")
    print(commit_dir or "")
    print("1" if others_inert else "")
    sys.exit(0)
