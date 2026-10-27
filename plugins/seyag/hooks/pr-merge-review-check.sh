#!/bin/bash
# PreToolUse hook: before `gh pr merge <N>`, fetch the latest claude[bot] review
# comment for that PR and dump its content into Claude's context. Blocks the
# merge on first invocation per (PR, review-comment-id, its updated_at);
# allows on retry once that same review comment has been "acked" (i.e.,
# already injected once).
#
# This enforces context-presence of the review before any merge call lands.
# The agent can still ignore what it sees — but the content is structurally
# in the context window, removing the "I forgot to fetch" path. The rule this
# backstops predates the hook and relied on agent attention; this file is the
# structural version.
#
# It also carries the default-branch merge reminder for PRs based on the
# repo's default branch, on the same blocking channel: non-blocking
# PostToolUse output never reaches the agent, so a reminder that rides it
# prints into a void. This hook fires on the same `gh pr merge` command and
# blocks, and blocking-path stderr does reach the agent.
#
# A `gh pr merge` naming its PR some other way arms the gate too. gh accepts
# `number | url | branch` as the selector (a leading `#` is stripped), so a
# positional non-flag argument is resolved with the same `gh pr view <selector>`
# gh itself would use. Only an invocation with NO positional argument at all is
# numberless: gh then infers the PR from the current branch, and the hook
# resolves it the same way, in this hook's cwd. Any lookup failure fails open.
#
# Fail-open surfaces: gh lookups that cannot run (the gate only means
# something when there is content to surface or a reminder to deliver), and
# a missing claim-shape lib (the hook stands down entirely). The ack-state
# WRITE on a healthy state file fails CLOSED with the escape named: an
# allow would print the review to a stream nobody sees. The ack state
# itself fails CLOSED: a symlink or an
# unreadable file at the state path is treated as NOT acked and is never
# written through — see the state section below.

set -uo pipefail

# A missing lib fails OPEN: the hook stands down entirely (a blocking gate
# must not die on infrastructure). The lib's presence — and the claim scan
# that needs it — is pinned by this hook's probe.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib/claim-shapes.sh" || exit 0

INPUT=$(cat)
TOOL_NAME=$(jq -r '.tool_name // empty' <<<"$INPUT" 2>/dev/null || echo "")
COMMAND=$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null || echo "")

[ "$TOOL_NAME" != "Bash" ] && exit 0

# Decide the PR number from the ARGUMENT VECTOR of a real `gh pr merge`
# invocation, not from a text scan of the whole command.
#
# The text scan this replaces was wrong in two ways that both END IN AN
# UNREVIEWED MERGE, which is the one outcome this hook exists to prevent. It
# matched the phrase anywhere in the command, so `gh pr comment N --body "...gh
# pr merge N..."` armed the gate on that decoy number; and it stripped to the FIRST
# occurrence, so `echo gh pr merge 1 && gh pr merge 2002` extracted 1. Either
# way the gate fetches some unrelated PR — and when that PR has no review and
# a base other than the default branch, the hook exits 0 and the real merge
# proceeds with nothing read.
#
# The arg-vector parse is the shared splitter in lib/shell_quotes.py
# (simple_commands), which already handles what a hand-rolled walk gets wrong:
# quote-aware words (a quoted --body is ONE argument and can never look like
# a command), operators, newlines and continuations as command boundaries,
# runner and assignment prefixes, comments, heredoc bodies as data, and
# recursion into `bash -c`/`eval`/here-string script strings to a fixed
# depth. python3 is a dependency of the sibling guards, so this adds no new
# one.
#
# Fails CLOSED by design, in both directions: an unparseable command falls
# back to the permissive raw scan rather than arming nothing, because
# silently not arming is the same hole under a different name.
#
# Cheap Bash-level reject FIRST. This hook is registered on every Bash call,
# so without this guard a python3 process would start for `ls`, `git status`,
# and every other command in the session — on a RAM-constrained machine, for
# a check that is irrelevant to all of them. The tokenizer below only ever
# runs on a command that at least mentions the phrase.
# Deliberately PERMISSIVE: a bare substring test on `merge`. It only decides
# whether to spawn python, and the tokenizer does the real work; every real
# `gh pr merge` invocation mentions `merge`, so a substring test cannot
# under-match one, however quoting or line continuations hide the words. The
# cost is one python spawn for any command that merely mentions merge (`git
# merge`, `git merge-base`, prose) — over-matching costs a spawn,
# under-matching costs a merge.
if [[ "$COMMAND" != *merge* ]]; then
    exit 0
fi

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"

# Line 1 of the output: the PR number ("" when nothing resolved). Line 2: 1
# when the invocation the number came from carries the delete-branch flag
# (or, for a numberless invocation, the first one's flag). Line 3: every PR
# number the precise scan resolved, space-separated — the compound refusal
# counts them. Line 4: "numberless" when a real `gh pr merge` invocation
# exists whose arguments carry neither a PR-number token NOR a positional
# selector (gh then infers the PR from the current branch); a phrase that
# merely MENTIONS the merge in a non-command position sets nothing on this
# line, so a quoted body or another command's argument never triggers the
# numberless fallback. Line 5: the -R/--repo value the invocation scoped
# itself with, "" for the cwd repo. Line 6: the positional selector (a
# branch, URL or #N argument) of the first invocation that carries one, ""
# when none does; it names the PR only when line 1 is empty. Line 7: how
# many `gh pr merge` invocations the precise scan saw at all — numbered,
# selector and numberless alike; the compound refusal keys off it. Line 8:
# "<owner>/<repo>" when the selector is a GitHub PR URL (the URL carries its
# own repository), "" otherwise. Line 9: how many of the invocations are
# numberless. Line 10: "chdir" when a directory change (cd/pushd, or a
# chdir runner like `env -C`) precedes the merge in the same command.
# Line 11: "fanout" when a merge runs under xargs/parallel (once per
# input). Line 12: "unresolvable" when the winning repository scope is an
# exported GH_REPO with no literal value in this command or a non-literal
# -R/--repo/GH_REPO= value ($(), backticks, <(), $VAR).
# A broken shell_quotes import falls back to the permissive raw scan (it
# over-arms rather than disarms); the one residual fail-open left is python3
# itself missing — no tokenizer exists then, `|| MERGE_EXTRACT=""` stands the
# hook down, and reimplementing the splitter in bash is not worth that gap.
MERGE_EXTRACT=$(SYG_LIB_DIR="${SYG_PR_MERGE_LIB_DIR:-$LIB_DIR}" python3 - 3<<<"$COMMAND" <<'PY' 2>/dev/null
import os
import re
import sys

cmd = os.fsdecode(open(3, "rb").read()).removesuffix("\n")

# Cheap reject before any parsing: no `merge` substring, no gate. Keeps the
# common Bash call (which is not a merge) off the parsing path entirely, and
# mirrors the bash-level substring test in the invoking script: every real
# `gh pr merge` invocation mentions `merge`, so this cannot under-match one.
if "merge" not in cmd:
    sys.exit(0)

# `str.isdigit()` is true for superscripts and Arabic-Indic digits; the
# number scan wants the strictly-ASCII kind gh accepts.
ASCII_DIGITS = re.compile(r"[0-9]+")

# A GitHub PR URL selector: gh resolves it against the URL's OWN repository,
# overriding even a -R on the same command. Prefix-match (no end anchor) so a
# trailing /files or anchor still names the PR; scheme and www. optional
# because gh accepts the bare host form too.
PR_URL_RE = re.compile(
    r"^(?:https?://)?(?:www\.)?github\.com/([^/\s]+)/([^/\s]+)/pull/[0-9]+",
    re.IGNORECASE,
)

# GH_REPO= scopes every gh call like -R does. Read from the command's PREFIX
# (before the gh word) or from an earlier same-shell command (child-context
# subshells `(...)`, command substitutions `$(...)`/backticks, and process
# substitutions `<(...)`/`>(...)` are ignored for a top-level merge because
# their exports never reach the parent shell; if the armed merge ITSELF runs
# in a child context after an earlier child-context GH_REPO export/declare -x,
# the command is refused as unresolvable): `export GH_REPO=val`,
# `declare`/`typeset`/`readonly` with `-x` effective (no -n/-u/-p), and
# bare-assignment linkage (`export GH_REPO=a && GH_REPO=b`, or
# `GH_REPO=b && export GH_REPO`). A standalone `GH_REPO=x` with no export in
# this command stays unexported; a bare `export GH_REPO` / `declare -x GH_REPO`
# with no prior assignment in this command (or a non-literal
# `$()`/backtick/`<()`/`$VAR` winning scope) is refused as unresolvable. Not
# covered (same cross-call class as `cd` in an earlier Bash tool call):
# `GH_REPO` exported in an earlier Bash call and reassigned by a bare
# `GH_REPO=b` here.
GH_REPO_ASSIGN = re.compile(r"^GH_REPO=(.+)$")

_CHDIR_CMDS = ("cd", "pushd", "popd")
_CMD_SEPARATORS = ("&&", "||", ";;", "|&", "|", "&", ";")
# Words that OPEN a command position themselves: after `{`, `then`, `do`,
# `else`, `!` (and the other flow keywords, plus the `command`/`builtin`
# prefixes) the NEXT word is a command again — `{ cd x; …` and
# `if cd x; then …` run a real cd that a separator-only model missed.
_CMD_OPENERS = ("{", "}", "then", "else", "elif", "do", "!", "if", "while",
                "until", "time", "coproc", "command", "builtin")
# A separator GLUED into a whitespace word (`status;`, `repo;gh`, `dir&&gh`)
# still separates in bash, so every word is split on its separator
# boundaries before the walk. Longest first, or `&&` reads as two `&`.
_WORD_SEPARATORS = re.compile(r"(&&|\|\||;;|\|&|[|;&])")

def chdir_affects_merge(text):
    """Whether a directory change REALLY precedes a merge in `text` — the
    refinement that keeps the scope-moved refusal off subshell shapes.

    FAIL-TOWARD-REFUSING: the refinement may clear the refusal only on
    positive proof — a modeled `gh pr merge` (gh matched by BASENAME, a
    quoted command word resolved back to its value) and every
    cd/pushd/popd that precedes it accounted for. A cd in a comment, inside
    quotes as DATA (an argument), or in another command's arguments cannot
    move the merge's directory, and neither can a cd AFTER the merge or at
    a SHALLOWER paren depth than it (a child scope's directory change
    cannot leak up); a cd at the merge's depth or ANY DEEPER one can,
    because subshells and command substitutions inherit the moved
    directory. Anything the
    scan cannot model — an unterminated quote, a view that will not
    resolve, a merge its levels cannot see at all (the caller's walk found
    one, but no scanned level shows it: a cd at wrapper level 1 with the
    merge at level 2, a heredoc body fed to a stdin shell), or a top-level
    cd with the merge inside a wrapper string (the wrapper's shell INHERITS
    the moved directory, and neither level shows both events) — returns
    True and the refusal stands. Wrapper strings are judged in their own
    right, because what runs inside `bash -c`/`eval` is that string's own
    shell; heredoc bodies are neutralized first (data, not commands)."""
    def scan(view, values):
        """One shell level: (real merge seen, depth-0 cd seen, cd before a
        real merge at the same depth)."""
        events = []  # (order, depth, kind) — kind "cd" | "gh" | "merge"
        order = 0
        depth = 0
        ph = 0  # quoted-span values consumed so far: resolution runs in
        #         view order, so every part (skipped ones included) counts.
        for line in view.split("\n"):
            cmd_pos = True
            words = line.split()
            stop = False
            for wi, word in enumerate(words):
                parts = _WORD_SEPARATORS.split(word)
                for pi, part in enumerate(parts):
                    if not part:
                        continue
                    if part in _CMD_SEPARATORS:
                        cmd_pos = True
                        continue
                    if part.startswith("#"):
                        # Comment: the rest of the line is not commands, but
                        # its placeholders still count toward resolution.
                        ph += " ".join(
                            parts[pi:] + words[wi + 1:]).count(QUOTED_SPAN)
                        stop = True
                        break
                    # `part and` is load-bearing: `<<<` strips to "" and
                    # `""[:1] in "$<>"` is True, so without the guard this
                    # loop never terminates — the hook hangs into the
                    # harness timeout and degrades to a silent stand-down.
                    while part and part[0] in "$<>":
                        part = part[1:]
                    opens = 0
                    while part.startswith("("):
                        opens += 1
                        part = part[1:]
                    closes = 0
                    while part.endswith(")"):
                        closes += 1
                        part = part[:-1]
                    depth += opens
                    if opens:
                        cmd_pos = True
                    if part:
                        resolved, ph = resolve_placeholders(part, values, ph)
                        # A backtick-span interior keeps its opening delimiter
                        # glued to the first word (`cd`, `gh`), while the view
                        # here does not strip backtick spans — bash's own argv
                        # has no backtick, so strip it before the basename.
                        base = os.path.basename(resolved).lstrip("`")
                        if cmd_pos and base in _CHDIR_CMDS:
                            events.append((order, depth, "cd"))
                            order += 1
                        elif base == "gh":
                            events.append((order, depth, "gh"))
                            order += 1
                        elif resolved == "merge":
                            events.append((order, depth, "merge"))
                            order += 1
                        else:
                            order += 1
                        cmd_pos = part in _CMD_SEPARATORS \
                            or part in _CMD_OPENERS
                    if closes:
                        depth -= closes
                        cmd_pos = True
                if stop:
                    break
        merges = [i for i, e in enumerate(events) if e[2] == "merge"]
        ghs = [i for i, e in enumerate(events) if e[2] == "gh"]
        # Only a `merge` two words after a `gh` (`gh pr merge`; the middle
        # word records no event) is a merge invocation; a stray `merge`
        # word pairs with nothing.
        real_merges = [m for m in merges
                       if any(events[m][0] - events[g][0] == 2
                              for g in ghs)]
        # Depth is one-directional: a cd at depth D affects every LATER
        # merge at depth >= D, because a subshell or command substitution
        # inherits the moved directory. Only a merge at a SHALLOWER depth
        # is out of reach — a child's directory change cannot leak up.
        affects = any(e[2] == "cd" and e[1] <= events[m][1]
                      for i, e in enumerate(events)
                      if e[2] == "cd"
                      for m in real_merges
                      if m > i)
        top_cd = any(e[2] == "cd" and e[1] == 0 for e in events)
        return bool(real_merges), top_cd, affects

    def level(s):
        indexed = strip_quoted_indexed(strip_heredoc_bodies(s))
        if indexed is None:
            return None
        return scan(indexed[0], indexed[1])

    top = level(text)
    if top is None or top[2]:
        return True
    try:
        wrappers = wrapped_command_strings(text)
    except Exception:
        return True
    wrapper_merge = False
    for s in wrappers:
        w = level(s)
        if w is None or w[2]:
            return True
        wrapper_merge = wrapper_merge or w[0]
    # MODEL-COVERAGE MISMATCH: the caller's walk armed this refinement on a
    # merge it saw, yet NO scanned level (top + wrappers) shows a real
    # merge — the merge hides where this scan has no eyes: a cd at wrapper
    # level 1 with the merge at level 2, a heredoc BODY fed to a stdin
    # shell (bodies are data at every level), a nesting the wrapper walk
    # does not descend into. Blind means refuse: clearing here would let a
    # merge the scan cannot see run from a directory it did not check.
    if not top[0] and not wrapper_merge:
        return True
    # A top-level cd with the merge inside a wrapper: the wrapper's shell
    # starts where the parent left it, so the cd DOES move that merge. The
    # reverse (wrapper cd, top merge) cannot reach the caller's chdir flag
    # (the splitter lists a wrapper's commands after the top level), so
    # this is the only cross-level pairing the refinement owes an answer
    # to — and refusing is the safe direction.
    return bool(top[1] and wrapper_merge)

# `--delete-branch` and its shorthand. ANCHORED to a whole token, which is
# what scopes it: `--body "remove the -d flag"` is one token carrying spaces,
# so it cannot match, and `-delete` from a chained `find . -delete` is a
# different token belonging to a different command entirely.
#
# `-[A-Za-z]*d[A-Za-z]*` covers the cluster form (`-rd`) because pflag packs
# boolean shorthands. It cannot match `--delete-branch` itself — after the
# lead `-` the class admits letters only, and the second `-` stops it — so
# the two patterns never double-count.
#
# The cluster pattern accepts any letter run containing a `d`, which is exact
# only while `-d` is the sole `gh pr merge` shorthand containing that letter.
# Read off `gh pr merge --help` (gh 2.65.0, re-verified unchanged on the
# installed 2.101.0): -A -b -F -d -m -r -s -t, plus the inherited -R. Only
# `-d` qualifies today. A future gh adding another `d`-
# bearing shorthand would make this over-arm — the accepted direction here,
# but this list is what a reader should re-check rather than re-derive.
#
# The trailing `(?:=|$)` is load-bearing, not decoration. pflag accepts
# `--flag=value` for BOOLEANS: `--delete-branch=true` is a real invocation
# shape, and anchoring on `$` alone let it through — an UNDER-arm: the merge
# proceeds ungated and deletes the branch, the one direction this file must
# never fail in.
DELETE_FLAG_LONG = re.compile(r"^--delete-branch(?:=|$)")
DELETE_FLAG_OFF = re.compile(r"^--delete-branch=false$")
SHORT_CLUSTER = re.compile(r"^-([A-Za-z]+)$")

# `gh pr merge`'s VALUE-taking shorthands. pflag glues a value onto a short
# flag — `gh pr list -L2` behaves identically to `-L 2` — so in a single-dash
# cluster everything after the first value-taking letter is that value, not
# more flags. Without this, `-bd` (a body of "d") read as carrying `-d` and
# produced a false block on a merge that would never delete anything.
#
# From `gh pr merge --help` (gh 2.65.0, re-verified unchanged on 2.101.0):
# -A author-email, -b body, -F body-file, -t subject, plus the inherited
# -R repo. The booleans are -d, -m, -r, -s.
VALUE_TAKING_SHORTS = set("AbFtR")

# The LONG value-taking flags, same source (`gh pr merge --help`, 2.65.0 and
# 2.101.0): --author-email, --body, --body-file, --match-head-commit,
# --repo, --subject. Everything else on the subcommand is boolean (--admin,
# --auto, --disable-auto, --delete-branch, --help, --merge, --rebase,
# --squash), so only these six can consume the token after them.
LONG_VALUE_FLAGS = {
    "--author-email",
    "--body",
    "--body-file",
    "--match-head-commit",
    "--repo",
    "--subject",
}


def carries_delete_flag(token):
    """Whether one argument token is `--delete-branch` or a cluster holding -d.

    Scans a short cluster left to right and stops at the first value-taking
    letter, because pflag stops treating the rest as flags there. `-rd`
    carries the flag (`r` is boolean); `-bd` does not (`d` is `-b`'s value);
    `-db` does (`d` precedes the value-taker).

    The long form parses pflag's `=value` for the documented boolean:
    `--delete-branch=false` is an explicit opt-out and NOT the flag; `=true`
    and any other value are.

    A value passed as a SEPARATE token (`-t -drafty`, `--body -d`) is not
    this function's to catch: the caller's pending-aware walk skips tokens
    consumed by the previous flag, and only unconsumed tokens reach here.
    """
    if DELETE_FLAG_LONG.match(token):
        return not DELETE_FLAG_OFF.match(token)
    cluster = SHORT_CLUSTER.match(token)
    if cluster is None:
        return False
    for letter in cluster.group(1):
        if letter == "d":
            return True
        if letter in VALUE_TAKING_SHORTS:
            return False
    return False


def legacy_scan(text):
    """The permissive raw scan, kept as the fallback for input the splitter
    cannot model.

    Over-arming (the old bug) is recoverable — the agent sees a review for a
    PR it did not ask about and retries. Under-arming is not: the merge just
    proceeds. So when the parse cannot run, take the noisy option.

    Skips the token after a value-taking SHORT flag (a `gh pr merge -t 2026`
    armed PR 2026 here too). Residual gap, deliberate:
    long forms are not known to a raw text scan — `--anything 9 7` can still
    read 9 — because guessing which longs take values is how the number walk
    in scan_invocations earns its exactness; the precise scan knows the set.
    """
    after = re.split(r"gh\s+pr\s+merge", text, maxsplit=1)
    if len(after) < 2:
        return "", False, []
    skip_next = False
    for token in after[1].split():
        if skip_next:
            skip_next = False
            continue
        cluster = SHORT_CLUSTER.match(token)
        if cluster is not None and cluster.group(1) and \
                cluster.group(1)[-1] in VALUE_TAKING_SHORTS:
            skip_next = True
            continue
        if ASCII_DIGITS.fullmatch(token):
            return token, False, [token]
    return "", False, []


def token_value_role(token):
    """How one argument token consumes its successor: "value", "repo", or
    "none"; the second element is the GLUED value when one exists (`-Rother`,
    `--repo=other`), else None.

    pflag glues a value onto a short flag (`-t2026` is one argument), so a
    separate token is consumed only when the value-taker is the LAST letter
    of a short cluster or a long flag with no `=`. The short-cluster walk
    mirrors carries_delete_flag's: after the first value-taking letter, the
    rest of the cluster is that letter's value.
    """
    if token.startswith("--"):
        base, sep, val = token.partition("=")
        if base == "--repo":
            return ("repo", val if sep else None)
        if base in LONG_VALUE_FLAGS:
            return ("value", None)
        return ("none", None)
    cluster = SHORT_CLUSTER.match(token)
    if cluster is None:
        return ("none", None)
    letters = cluster.group(1)
    for i, letter in enumerate(letters):
        if letter in VALUE_TAKING_SHORTS:
            last = i == len(letters) - 1
            if letter == "R":
                return ("repo", None if last else letters[i + 1:])
            return ("value", None) if last else ("none", None)
    return ("none", None)


def scan_invocations(text):
    """Every `gh pr merge` invocation in `text`, as the shared splitter sees
    bash execute it.

    Returns (merges, numberless, first_flag, repo, selector, invoke_count,
    selector_repo, numberless_count, chdir, fanout, unresolvable):
    - merges: (number, delete_flag) per invocation whose arguments carry a
      bare PR-number token, in the splitter's command order;
    - numberless: True when a real invocation exists whose arguments carry NO
      number token and NO positional selector;
    - first_flag: the delete flag of the first invocation seen — the armed
      one when the numberless path ends up arming;
    - repo: the LAST -R/--repo value seen (gh lets the later flag win); ""
      when the invocation never scopes a repository — except that a GH_REPO=
      assignment scopes the same way and fills in when no -R did (-R wins
      over GH_REPO, gh's own precedence): either the invocation's own PREFIX
      (before the gh word) or an earlier same-shell (`in_child_context` False)
      `export` / `declare -x` / `typeset -x` / `readonly -x` (no -n/-u/-p) or
      bare-assignment linkage (`export GH_REPO=a && GH_REPO=b`, `GH_REPO=b &&
      export GH_REPO`) EARLIER in the text than the armed (first) invocation;
    - selector: the first invocation's positional non-flag, non-value
      argument (a branch, URL or #N — gh accepts all three as the PR
      selector); "" when no invocation carries one;
    - invoke_count: how many `gh pr merge` invocations the precise scan saw
      at all — numbered, selector and numberless alike. The compound refusal
      keys off it: a selector invocation beside any other is a compound too;
    - selector_repo: "<owner>/<repo>" when the selector is a GitHub PR URL
      (the URL carries its own repository); "" for a branch, a #N, or no
      selector;
    - numberless_count: how many of the invocations are numberless — the
      compound refusal prints one clause per numberless invocation;
    - chdir: True when a directory change (cd/pushd/popd, or a chdir runner
      like `env -C` wrapping the merge itself) precedes the merge in the
      same command — the merge's repository is then unresolvable from this
      hook's cwd, and the caller refuses rather than resolve the wrong
      repo's PR. A cd at a DEEPER scope than the merge (a subshell cd
      beside a top-level merge) does not count: a child's directory change
      cannot leak up; a cd at the merge's own depth or shallower does,
      because the merge inherits the moved directory;
    - fanout: True when a merge runs under xargs/parallel — once per input,
      so no single ack cycle can cover it;
    - unresolvable: True when the winning repository scope is an exported
      GH_REPO with no literal value in this command (`export GH_REPO` /
      `declare -x GH_REPO`), an armed merge in a child context preceded by a
      child-context GH_REPO export/declare -x, or a non-literal
      -R/--repo/GH_REPO= value (`$(...)`, backticks, `<(...)`, `$VAR`).

    The command word is matched by BASENAME, not literally: `/usr/bin/gh pr
    merge 7` and a mise shim path are real invocations.

    VALUE TOKENS ARE NOT PR NUMBERS: the number walk
    skips the token immediately following a value-taking flag — `-t 2026` is
    a subject, `-b 9 7` merges PR 7, `--subject 2024 2002` merges PR 2002 —
    per VALUE_TAKING_SHORTS and LONG_VALUE_FLAGS via token_value_role.
    Glued forms (`-t2026`) are one argument and never yield a separate token
    to skip.

    Redirections are dropped WITH their targets (strip_redirections), so
    `2>&1` and `> file` never contribute an argument: the `2` in
    `gh pr merge 2>&1` is part of the redirection, not a PR number, and a
    file named `-d` after `>` is a target, not a flag. The delete flag is
    read from THIS invocation's own arguments only — a later merge's, a
    chained command's or quoted prose's flag is irrelevant to it.
    """
    merges = []
    numberless = False
    numberless_count = 0
    first_flag = False
    seen = False
    repo = ""
    selector = ""
    selector_repo = ""
    invoke_count = 0
    chdir = False
    chdir_cd = False
    chdir_runner = False
    fanout = False
    gh_repo_env = ""
    gh_repo_bare = None
    gh_repo_exported = False
    gh_repo_unresolvable = False
    child_gh_repo_exported = False
    first_repo_env = ""
    first_env_unresolvable = False
    first_prefix_repo = ""
    pending_prefix_repo = None
    pending_prefix_target_idx = None
    chdir_seen = False
    commands = simple_commands_context(text)

    def _strip_comments_for_view(s):
        out = []
        i = 0
        n = len(s)
        q = None
        while i < n:
            ch = s[i]
            if q is None:
                if ch == "\\" and i + 1 < n:
                    out.append(s[i : i + 2])
                    i += 2
                    continue
                if ch in "\"'":
                    q = ch
                    out.append(ch)
                    i += 1
                    continue
                if ch == "#" and (i == 0 or s[i - 1] in " \t\n;&|()"):
                    nl = s.find("\n", i)
                    if nl == -1:
                        break
                    i = nl
                    continue
            elif q == '"':
                if ch == "\\" and i + 1 < n:
                    out.append(s[i : i + 2])
                    i += 2
                    continue
                if ch == '"':
                    q = None
            else:
                if ch == "'":
                    q = None
            out.append(ch)
            i += 1
        return "".join(out)

    def _quote_stripped_view(s):
        uncommented = _strip_comments_for_view(strip_heredoc_bodies(s))
        indexed = strip_quoted_indexed(uncommented)
        return indexed[0] if indexed is not None else uncommented

    view_parts = [_quote_stripped_view(text)]
    level_strs = [text]
    for _ in range(MAX_WRAPPER_DEPTH):
        nxt_strs = []
        for s in level_strs:
            try:
                for w in wrapped_command_strings(s):
                    view_parts.append(_quote_stripped_view(w))
                    nxt_strs.append(w)
            except Exception:
                pass
        level_strs = nxt_strs
        if not level_strs:
            break
    sub_view = "\n".join(view_parts)
    sub_pos = 0
    _SPLIT_SUB_AT_RE = re.compile(r"GH_REPO=[^\s;&|()]*[\$<>]\(")

    def is_nonliteral_repo(val):
        return bool(
            "$(" in val
            or "`" in val
            or "<(" in val
            or ">(" in val
            or re.search(r"\$[A-Za-z_{0-9*@?#!-]", val)
        )

    def bt_strip(val):
        # A backtick-span interior keeps its closing delimiter glued to the
        # last word, so a captured value can end in a stray `` ` `` that bash
        # never passes (`` gh pr merge 5 -R a/b `` inside a span arrives with
        # the value as `` a/b` ``). Strip it before literalness checks and
        # before the value is stored — the glue is parser artifact, not
        # content; bash's own value has no backtick.
        return val.rstrip("`")

    def normalize_sub_val(idx, val):
        # `_tokens` splits an unquoted `$(...)` or `<(...)` at its `(` op,
        # leaving the trailing `$` or `<` at the end of `commands[idx]` and
        # the interior in `commands[idx + 1]` (`in_child_context` True).
        if (
            val.endswith(("$", "<", ">"))
            and idx + 1 < len(commands)
            and commands[idx + 1][1]
        ):
            return val + "("
        return val

    def parse_x_flags(cmd_base, args):
        exported = cmd_base == "export"
        plus_x = False
        for tok in args:
            if tok == "--" or tok == "GH_REPO" or GH_REPO_ASSIGN.match(tok):
                break
            if (
                tok.startswith("-")
                and not tok.startswith("--")
                and "x" in tok[1:]
            ):
                exported = True
                plus_x = False
            elif tok.startswith("+") and "x" in tok[1:]:
                exported = False
                plus_x = True
        return exported, plus_x

    def consume_split_sub_is_prefix():
        # Distinguish `GH_REPO=$(...) gh pr merge ...` (prefix on the next
        # command after the substitution interior, whether top-level or in a
        # pipeline/background subshell) from `GH_REPO=$(...); gh pr merge ...`
        # (a separate bare-assignment command before a separator), attributing
        # the post-paren check to THIS split-sub assignment's own occurrence
        # in the quote- and comment-stripped view (`strip_quoted_indexed`) and
        # returning `(is_prefix, interior_cmd_count)` so the hand-off lands on
        # the command immediately following the substitution's interior.
        # LIMIT: the cursor assumes `sub_view` (built breadth-first over
        # wrapper levels) lists the occurrences in the same order the command
        # list (depth-first recursion) consumes them. Two NESTED wrappers
        # that each hold a split-sub `GH_REPO=$(…)` can pair a verdict with
        # the wrong occurrence — the misfire is a spurious or missed refusal,
        # never a wrong-repo capture; pinned by the split-sub rows.
        nonlocal sub_pos
        i = sub_pos
        n = len(sub_view)
        in_bt = False
        while i < n:
            ch = sub_view[i]
            if ch == "`":
                in_bt = not in_bt
                i += 1
                continue
            if not in_bt and (
                i == 0 or sub_view[i - 1] in " \t\n;&|()"
            ):
                m_sub = _SPLIT_SUB_AT_RE.match(sub_view, i)
                if m_sub is not None:
                    depth = 1
                    k = m_sub.end()
                    while k < n and depth > 0:
                        if sub_view[k] == "(":
                            depth += 1
                        elif sub_view[k] == ")":
                            depth -= 1
                        k += 1
                    interior = sub_view[m_sub.end() : max(m_sub.end(), k - 1)]
                    sub_pos = m_sub.end()
                    while k < n and sub_view[k] in " \t":
                        k += 1
                    is_prefix = k < n and sub_view[k] not in ";&|\n)'\""
                    n_interior = (
                        max(1, len(simple_commands_context(interior)))
                        if is_prefix
                        else 0
                    )
                    return is_prefix, n_interior
            i += 1
        sub_pos = n
        return False, 0

    for idx, (raw, in_child) in enumerate(commands):
        argv, runinfo = unwrap_runners(raw)
        # A backtick-span interior keeps its delimiters glued to the first and
        # last words (argv[0] = `export` or `gh`, last token = --rebase`), so
        # EVERY basename check below strips the leading delimiters — bash's
        # own argv has no backtick; the glue is a splitter artifact. Parens
        # are token separators and never glue; only the backtick shape needs
        # this.
        base0 = os.path.basename(argv[0]).lstrip("`") if argv else ""
        prefix_from_split_sub = None
        if (
            pending_prefix_repo is not None
            and idx == pending_prefix_target_idx
        ):
            prefix_from_split_sub = pending_prefix_repo
            pending_prefix_repo = None
            pending_prefix_target_idx = None
        split_sub_prefix = False
        split_sub_interior = 0
        if raw:
            last_m = GH_REPO_ASSIGN.match(raw[-1])
            if (
                last_m
                and "\n" not in last_m.group(1)
                and normalize_sub_val(idx, last_m.group(1)) != last_m.group(1)
            ):
                split_sub_prefix, split_sub_interior = (
                    consume_split_sub_is_prefix()
                )
        # Earlier simple-command `GH_REPO` tracking (same shell only:
        # `in_child` is True inside `(...)`, `$(...)`, backticks, and
        # `<(...)`/`>(...)`, plus multi-command pipelines and `&`-backgrounded
        # lists/compounds, whose environment changes never leak up to the
        # parent shell).
        # - `export` and `declare`/`typeset`/`readonly` with `-x` effective
        #   (no -n/-u/-p; `-x` sets and `+x` clears export status across flags
        #   before `--` and before the first GH_REPO word) export GH_REPO for
        #   subsequent commands in the same shell.
        # - Bare `GH_REPO=val` (`not argv`, no runner): if GH_REPO is already
        #   exported in this command, bash updates the exported value in
        #   place; otherwise record `gh_repo_bare` in case a later `export
        #   GH_REPO` / `declare -x GH_REPO` promotes it (and `declare +x
        #   GH_REPO=val` likewise records `gh_repo_bare` when unexported). A
        #   split-substitution prefix (`GH_REPO=$(...) cmd`) is recorded in
        #   `pending_prefix_repo` for the command immediately following the
        #   substitution's interior commands (`pending_prefix_target_idx`),
        #   even when `in_child` is True (piped or `&`-backgrounded merges run
        #   with the prefix-resolved GH_REPO inside their subshell).
        # - Bare `export GH_REPO` / `declare -x GH_REPO` with no `=`: promotes
        #   a prior `gh_repo_bare` in this command, or marks the env scope
        #   unresolvable when no prior assignment exists in this command.
        # - When `in_child` is True, a child-context `GH_REPO` export /
        #   `declare -x` is ignored for top-level merges, but recorded in
        #   `child_gh_repo_exported`: if the armed merge ITSELF runs with
        #   `in_child` True after such an export (`(export GH_REPO=other-x;
        #   gh pr merge N)` or a backtick-span sibling), the command is
        #   refused as unresolvable rather than silently gating the cwd repo.
        #   Known over-approximation (accepted): `(export GH_REPO=a);
        #   (gh pr merge N)` across two separate child constructs also refuses
        #   because the flat command list does not distinguish construct
        #   boundaries, and a shared backgrounded list or piped compound
        #   (`export GH_REPO=x && gh pr merge N &`, `if c; then export
        #   GH_REPO=x; gh pr merge N; fi | cat`) likewise refuses as
        #   unresolvable even though bash resolves `x` inside the subshell
        #   (fail-safe over-refusal); the escape (drop the parens/subshell or
        #   pass literal -R) costs one command, same as the chdir refusal's.
        #   Compound-tracker openers not covered: `select … done`,
        #   `function f { … }` (`{` is not at command start after `function f`),
        #   and `coproc { … }` (whose body always runs in a subshell).
        if not in_child:
            if not argv and not runinfo.get("runners") and len(raw) == 1:
                m = GH_REPO_ASSIGN.match(raw[0])
                if m and "\n" not in m.group(1):
                    val = bt_strip(normalize_sub_val(idx, m.group(1)))
                    if val != m.group(1) and split_sub_prefix:
                        pending_prefix_repo = val
                        pending_prefix_target_idx = (
                            idx + 1 + split_sub_interior
                        )
                    elif gh_repo_exported:
                        gh_repo_env = val
                        gh_repo_unresolvable = False
                    else:
                        gh_repo_bare = val
            elif argv:
                cmd_base = base0
                if cmd_base == "unset" and "-f" not in argv[1:]:
                    # `unset GH_REPO` removes the variable entirely (unless `-f`
                    # targets a shell function): the
                    # exported scope ends AND a later bare `export GH_REPO`
                    # exports nothing — so the remembered bare assignment is
                    # forgotten too, and a bare `export GH_REPO` afterwards
                    # hits the unresolvable refusal (bash exports nothing, so
                    # that refusal is the fail-safe over-approximation; the
                    # escape is dropping the no-op export, pinned by a row).
                    if any(tok == "GH_REPO" for tok in argv[1:]):
                        gh_repo_env = ""
                        gh_repo_exported = False
                        gh_repo_unresolvable = False
                        gh_repo_bare = None
                elif cmd_base == "export" \
                        and "-n" in argv[1:] \
                        and any(tok == "GH_REPO" for tok in argv[1:]):
                    # `export -n GH_REPO` UN-exports: the shell variable
                    # survives (a later bare `export GH_REPO` re-exports it),
                    # so the remembered bare assignment stays; only the
                    # exported scope clears. bash 5.3 measured (`env -i`:
                    # children see nothing afterwards). `export -n GH_REPO=x`
                    # stays unhandled — its assign-and-unexport combination is
                    # ambiguous and the shape is not covered.
                    # Combined flags like `export -fn GH_REPO` fall to the
                    # general arm (exact-token `-n` does not match); measured
                    # harmless in bash 5.3 (`env -i`): bash errors
                    # `GH_REPO: not a function` and the variable stays
                    # exported, so the capture stands.
                    gh_repo_env = ""
                    gh_repo_exported = False
                    gh_repo_unresolvable = False
                elif cmd_base in ("export", "declare", "typeset", "readonly") \
                        and not any(t in ("-n", "-u", "-p") for t in argv[1:]):
                    # `local -x GH_REPO=…` inside a function body is not
                    # covered (measured, bash 5.3, `env -i`: the local scope
                    # dies at function return, so a merge after the function
                    # sees no GH_REPO; a merge inside the body is not a
                    # one-liner shape this hook reads).
                    exported, plus_x = parse_x_flags(cmd_base, argv[1:])
                    for tok_i, tok in enumerate(argv[1:]):
                        m = GH_REPO_ASSIGN.match(tok)
                        if m and "\n" not in m.group(1):
                            val = (
                                normalize_sub_val(idx, m.group(1))
                                if tok_i == len(argv) - 2
                                else m.group(1)
                            )
                            if exported:
                                gh_repo_env = val
                                gh_repo_exported = True
                                gh_repo_unresolvable = False
                            elif gh_repo_exported and not plus_x:
                                gh_repo_env = val
                                gh_repo_unresolvable = False
                            else:
                                gh_repo_bare = val
                        elif tok == "GH_REPO" and exported:
                            if gh_repo_bare is not None:
                                gh_repo_env = gh_repo_bare
                                gh_repo_exported = True
                                gh_repo_unresolvable = False
                            elif not gh_repo_exported:
                                gh_repo_exported = True
                                gh_repo_unresolvable = True
                        elif tok == "GH_REPO" and plus_x:
                            gh_repo_env = ""
                            gh_repo_exported = False
                            gh_repo_unresolvable = False
        elif not argv and not runinfo.get("runners") and len(raw) == 1:
            m = GH_REPO_ASSIGN.match(raw[0])
            if m and "\n" not in m.group(1):
                val = bt_strip(normalize_sub_val(idx, m.group(1)))
                if val != m.group(1) and split_sub_prefix:
                    pending_prefix_repo = val
                    pending_prefix_target_idx = idx + 1 + split_sub_interior
                elif gh_repo_exported:
                    child_gh_repo_exported = True
        elif argv:
            cmd_base = base0
            if cmd_base in ("export", "declare", "typeset", "readonly") \
                    and not any(t in ("-n", "-u", "-p") for t in argv[1:]):
                exported, _ = parse_x_flags(cmd_base, argv[1:])
                if exported and any(
                    tok == "GH_REPO"
                    or (
                        (m := GH_REPO_ASSIGN.match(tok)) is not None
                        and "\n" not in m.group(1)
                    )
                    for tok in argv[1:]
                ):
                    child_gh_repo_exported = True
        if argv and base0 in ("cd", "pushd", "popd"):
            # A directory change before the merge (in list order) makes the
            # merge's repository unresolvable from this hook's cwd.
            chdir_seen = True
            continue
        if not argv or base0 != "gh" \
                or argv[1:3] != ["pr", "merge"]:
            continue
        args = strip_redirections(argv[3:])
        invoke_count += 1
        # The merge itself under a chdir runner (env -C, sudo -D) is the
        # same unresolvable-scope shape.
        if chdir_seen:
            chdir_cd = True
        if runinfo.get("chdir"):
            chdir_runner = True
        if runinfo.get("fanout") or runinfo.get("stdin"):
            # xargs/parallel run the merge once per input — no ack cycle can
            # cover that.
            fanout = True
        # GH_REPO= scopes gh like -R. PREFIX only (before the gh word), so a
        # --body value shaped like an assignment never scopes anything; a
        # single-line value only, like -R's own capture. Within one
        # invocation the last assignment wins, and -R wins over GH_REPO
        # (gh's own precedence).
        prefix_repo = prefix_from_split_sub or ""
        for tok in raw:
            if os.path.basename(tok) == "gh":
                break
            m = GH_REPO_ASSIGN.match(tok)
            if m and "\n" not in m.group(1):
                prefix_repo = bt_strip(m.group(1))
        first = not seen
        seen = True
        number = None
        sel = None
        pending = ""  # "value" | "repo" while the NEXT token is a flag's value
        flag = False
        for ai, a in enumerate(args):
            if pending:
                if pending == "repo":
                    # SINGLE-LINE values only, the same rule as the selector
                    # capture below: an owner/repo never spans lines, while a
                    # quoted multi-line --repo value does — and a newline on
                    # line 5 of the extraction would shift every line after
                    # it. Such a value assigns nothing, so the lookups scope
                    # to the cwd repo.
                    if "\n" not in a:
                        repo = (
                            bt_strip(
                                normalize_sub_val(idx, a)
                                if ai == len(args) - 1
                                else a
                            )
                        )
                pending = ""
                # A token consumed as the previous flag's VALUE is not a
                # flag itself — `--body -d` arms nothing.
                continue
            if carries_delete_flag(a):
                flag = True
            role, glued = token_value_role(a)
            if role == "repo":
                if glued is not None:
                    if "\n" not in glued:
                        repo = (
                            bt_strip(
                                normalize_sub_val(idx, glued)
                                if ai == len(args) - 1
                                else glued
                            )
                        )
                else:
                    pending = "repo"
                continue
            if role == "value":
                pending = "value"
                continue
            if ASCII_DIGITS.fullmatch(a):
                if number is None:
                    number = a
                # No break: the FIRST number wins, but the walk must reach
                # the end of the invocation — a `-R` after the PR number
                # still scopes the lookups.
                continue
            # A positional non-flag token (a branch, a URL, a #N — an empty
            # argument is not one) is gh's PR selector; it names the PR the
            # same way a bare number does, so the invocation is NOT
            # numberless. SINGLE-LINE tokens only: a real selector (branch
            # name, URL, #N) never spans lines, while a quoted multi-line
            # value of some long flag the walk does not know does — and a
            # newline in the selector would corrupt the line-oriented
            # extraction protocol below. Such a token counts for nothing
            # here, so its invocation stays numberless.
            if a and "\n" not in a and not a.startswith("-") and sel is None:
                sel = a
        if number is None:
            if sel is None:
                numberless = True
                numberless_count += 1
        else:
            merges.append((number, flag))
        if first:
            first_flag = flag
            first_prefix_repo = prefix_repo
            first_repo_env = gh_repo_env
            first_env_unresolvable = gh_repo_unresolvable or (
                in_child and child_gh_repo_exported
            )
        if sel is not None and not selector:
            selector = sel
            url = PR_URL_RE.match(sel)
            if url:
                selector_repo = f"{url.group(1)}/{url.group(2)}"
    if chdir_cd and not chdir_affects_merge(text):
        # Every cd the list order found sits in a subshell, a comment or
        # another command's arguments — none of them can move the merge.
        chdir_cd = False
    chdir = chdir_cd or chdir_runner
    # Precedence (matching gh): URL selector_repo > -R/--repo > prefix
    # GH_REPO= > earlier exported GH_REPO. Refuse when the WINNING source is
    # unresolvable or non-literal; a shadowed lower-precedence dynamic source
    # (`GH_REPO=$(calc) gh pr merge 2002 -R other-x`) does not refuse.
    unresolvable = False
    if seen:
        if selector_repo:
            pass
        elif repo:
            if is_nonliteral_repo(repo):
                unresolvable = True
                repo = ""
        elif first_prefix_repo:
            if is_nonliteral_repo(first_prefix_repo):
                unresolvable = True
            else:
                repo = first_prefix_repo
        elif first_env_unresolvable:
            unresolvable = True
        elif first_repo_env:
            if is_nonliteral_repo(first_repo_env):
                unresolvable = True
            else:
                repo = first_repo_env
    return merges, numberless, first_flag, repo, selector, invoke_count, \
        selector_repo, numberless_count, chdir, fanout, unresolvable


def deep_wrapper_args(text):
    """The wrapper string arguments one level past the splitter's recursion
    cap (MAX_WRAPPER_DEPTH): exactly the strings simple_commands stopped
    unwrapping.

    A merge nested deeper than the cap would otherwise vanish silently — the
    under-arm direction this file refuses — so the caller over-arms on them
    textually instead.
    """
    strings = [text]
    for _ in range(MAX_WRAPPER_DEPTH):
        nxt = []
        for s in strings:
            try:
                nxt.extend(wrapped_command_strings(s))
            except Exception:
                pass
        strings = nxt
        if not strings:
            return []
    deep = []
    for s in strings:
        try:
            deep.extend(wrapped_command_strings(s))
        except Exception:
            pass
    return deep


def extract(text):
    """(number, delete_flag, all_numbers, numberless, repo, selector,
    invoke_count, selector_repo, numberless_count, chdir, fanout,
    unresolvable) for `text`'s merges.

    Resolution order, each step only when the previous found nothing:
    1. the precise invocation scan;
    2. the permissive raw scan, when a quote left open anywhere in the
       command makes the splitter drop everything after it (over-arm, never
       arm-nothing);
    3. the raw textual scan over strings past the wrapper-depth cap;
    4. nothing — the caller decides on numberless.

    Steps 2 and 3 resolve at most one number and report NO delete flag,
    NO repo, NO selector, NO invocation count, NO selector repo, NO chdir,
    NO fanout and NO unresolvable: they exist to OVER-arm, and the
    not-ackable delete-branch guard, the compound refusal, -R scoping,
    selector resolution, the chdir refusal, the fan-out refusal and the
    unresolvable-scope refusal must never hang off an over-arm — a false
    block with no way out, or a lookup against a repo or selector a textual
    scan guessed at.
    """
    try:
        merges, numberless, first_flag, repo, selector, invoke_count, \
            selector_repo, numberless_count, chdir, fanout, unresolvable = \
            scan_invocations(text)
    except Exception:
        return legacy_scan(text) + (False, "", "", 0, "", 0, False, False, False)
    if merges:
        number, flag = merges[0]
        return number, flag, [m[0] for m in merges], numberless, repo, \
            selector, invoke_count, selector_repo, numberless_count, \
            chdir, fanout, unresolvable
    if strip_quoted(text) is None:
        return legacy_scan(text) + (False, "", "", 0, "", 0, False, False, False)
    for s in deep_wrapper_args(text):
        capped = strip_heredoc_bodies(s)
        m = re.search(r"gh\s+pr\s+merge\s+[\"']*(\d+)", capped)
        if m:
            return m.group(1), False, [m.group(1)], False, "", "", 0, "", \
                0, False, False, False
    return "", first_flag, [], numberless, repo, selector, invoke_count, \
        selector_repo, numberless_count, chdir, fanout, unresolvable


# The import sits HERE, not at the top: an import-time failure (a corrupt or
# missing shell_quotes.py, an unset SYG_LIB_DIR) must fall back to the legacy
# scan rather than exit non-zero into the shell's `|| MERGE_EXTRACT=""` and
# silently arm nothing. The functions above
# only touch shell_quotes names at CALL time, so defining them first is safe.
try:
    sys.path.insert(0, os.environ["SYG_LIB_DIR"])
    from shell_quotes import (  # noqa: E402
        MAX_WRAPPER_DEPTH,
        QUOTED_SPAN,
        resolve_placeholders,
        simple_commands_context,
        strip_heredoc_bodies,
        strip_quoted,
        strip_quoted_indexed,
        strip_redirections,
        unwrap_runners,
        wrapped_command_strings,
    )
except Exception:
    number, flag, all_numbers = legacy_scan(cmd)
    print(number)
    print("1" if flag else "0")
    print(" ".join(all_numbers))
    # All twelve lines, empty where empty — the bash reader's sed expects the
    # full protocol, same as the extract-exception fallback below.
    print("")
    print("")
    print("")
    print("")
    print("")
    print("")
    print("")
    print("")
    print("")
    sys.exit(0)

try:
    number, flag, all_numbers, numberless, repo, selector, invoke_count, \
        selector_repo, numberless_count, chdir, fanout, unresolvable = \
        extract(cmd)
except Exception:
    # The whole extraction, not just one stage. Anything escaping here would
    # exit non-zero, hit the shell's `|| MERGE_EXTRACT=""`, and silently arm
    # nothing — the direction this design refuses.
    number, flag, all_numbers = legacy_scan(cmd)
    numberless = False
    repo = ""
    selector = ""
    invoke_count = 0
    selector_repo = ""
    numberless_count = 0
    chdir = False
    fanout = False
    unresolvable = False
print(number)
print("1" if flag else "0")
print(" ".join(all_numbers))
print("numberless" if numberless else "")
print(repo)
print(selector)
print(invoke_count)
print(selector_repo)
print(numberless_count)
print("chdir" if chdir else "")
print("fanout" if fanout else "")
print("unresolvable" if unresolvable else "")
PY
) || MERGE_EXTRACT=""

# Line 1: the PR number. Line 2: 1 when the armed invocation carries the
# delete-branch flag. Line 3: every PR number the precise command-position
# scan resolved, space-separated. Line 4: "numberless" when a numberless
# invocation exists. Line 5: the -R/--repo scope ("" = the cwd repo; a
# GH_REPO= assignment prefix fills in when no -R named one). Line 6:
# the positional selector, "" when the invocation names no PR that way.
# Line 7: the precise scan's total `gh pr merge` invocation count. Line 8:
# the selector's own repository when the selector is a GitHub PR URL.
# Line 9: the numberless invocation count. Line 10: "chdir" when a directory
# change precedes the merge in the same command. Line 11: "fanout" when a
# merge runs under xargs/parallel. Line 12: "unresolvable" when the winning
# repository scope is an unresolvable export/declare -x GH_REPO or non-literal
# -R/--repo/GH_REPO= value. All empty when the extraction produced nothing.
PR_NUM=$(printf '%s\n' "$MERGE_EXTRACT" | sed -n '1p')
MERGE_DELETES_BRANCH=$(printf '%s\n' "$MERGE_EXTRACT" | sed -n '2p')
MERGE_ALL_PRS=$(printf '%s\n' "$MERGE_EXTRACT" | sed -n '3p')
MERGE_NUMBERLESS=$(printf '%s\n' "$MERGE_EXTRACT" | sed -n '4p')
MERGE_COUNT=$(printf '%s\n' "$MERGE_ALL_PRS" | wc -w)
REPO_ARG=$(printf '%s\n' "$MERGE_EXTRACT" | sed -n '5p')
MERGE_SELECTOR=$(printf '%s\n' "$MERGE_EXTRACT" | sed -n '6p')
MERGE_INVOKE_COUNT=$(printf '%s\n' "$MERGE_EXTRACT" | sed -n '7p')
SELECTOR_REPO=$(printf '%s\n' "$MERGE_EXTRACT" | sed -n '8p')
MERGE_NUMBERLESS_COUNT=$(printf '%s\n' "$MERGE_EXTRACT" | sed -n '9p')
MERGE_CHDIR=$(printf '%s\n' "$MERGE_EXTRACT" | sed -n '10p')
MERGE_FANOUT=$(printf '%s\n' "$MERGE_EXTRACT" | sed -n '11p')
MERGE_UNRESOLVABLE=$(printf '%s\n' "$MERGE_EXTRACT" | sed -n '12p')

# A URL selector carries its OWN repository, and gh resolves the PR there
# even beside a -R (the URL wins). Mirror that here: the URL's repo OVERRIDES
# any -R from the command before the scope args are built, so the resolution,
# resolve_repo, the review fetch, the no-review reason and the diff scan all
# read the URL's repo. Scoping them to the cwd or -R repo instead would fetch
# that repo's same-numbered PR — surfacing and acking the WRONG review, or
# none at all and an ungated merge. The delete-branch worktree check skips
# this shape for the same reason: local worktrees cannot answer for the
# URL's repo.
if [ -n "$SELECTOR_REPO" ]; then
    REPO_ARG="$SELECTOR_REPO"
fi

# -R/--repo scoping: every gh lookup the hook makes must
# look at the repository the invocation named, not whatever the cwd resolves
# to — otherwise `gh pr merge 7 -R other/x` fetches the cwd repo's #7 review
# and the other repo's merge runs ungated. Read off the arg vector (line 5),
# so a `-R` in quoted prose never scopes anything. Empty = no scoping.
REPO_SCOPE_ARGS=()
if [ -n "$REPO_ARG" ]; then
    REPO_SCOPE_ARGS=(-R "$REPO_ARG")
fi

RULE='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'

# COMPOUND MERGE REFUSAL. Arming the gate on the FIRST merge in a command is
# right as far as it goes — and observed insufficient: a single call chaining
# two merges fired the gate for the first PR only, and the second merged with
# no ack cycle of its own. The gate is attention-independent by design, so a
# shape that silently halves its coverage is a hole, not a nit.
#
# NOT ACKABLE, on purpose. Acking would let the identical command through on
# the retry and reproduce the hole exactly; the way past this is to run one
# merge per command, which is also what makes each PR's review reachable.
# Recovery costs one extra Bash call, so the direction is safe.
#
# Placed BEFORE every other decision the hook makes: the selector/numberless
# PR resolution just below is a network call, and so are the delete-branch
# precondition's ref lookup, resolve_repo and the review fetch. The refusal
# needs only what the extraction resolved locally, so it must not pay for
# round trips it refuses to use; running it first also keeps a PR with no
# review comment — which exits 0 further down — from carrying a second merge
# through on that path.
#
# Counts only what the PRECISE command-position scan resolved. The fallback
# paths (the raw scan, the depth cap) exist to over-arm, and they report at
# most one invocation for exactly this reason: hanging a refusal with no ack
# past it off a deliberate over-arm leaves no way out.
#
# A NUMBERLESS invocation beside a numbered one is one of these compounds
# too (`gh pr merge 7 && gh pr merge` armed only #7; the bare merge inferred
# its own PR from the branch and ran ungated). So is a SELECTOR invocation
# beside any other (`gh pr merge feature-x && gh pr merge 7` armed only #7;
# the selector merge resolves its own PR and runs with no ack cycle). The
# refusal fires on more-than-one numbered merge, (numbered AND numberless),
# or (more than one invocation AND a selector present); the banner names
# every numberless invocation and every selector invocation, one generic
# clause each — a selector names a PR, but not one the gate armed. A
# GENUINELY single numberless or selector merge still arms its PR normally
# — this changes refusal, not arming. Two BARE numberless merges in one
# command stay unrefused: both resolve the same cwd-branch PR, so one ack
# cycle covers both.
if [ "${MERGE_COUNT:-0}" -gt 1 ] 2>/dev/null \
    || { [ "${MERGE_COUNT:-0}" -ge 1 ] 2>/dev/null \
        && [ "$MERGE_NUMBERLESS" = "numberless" ]; } \
    || { [ "${MERGE_INVOKE_COUNT:-0}" -gt 1 ] 2>/dev/null \
        && [ -n "$MERGE_SELECTOR" ]; }; then
    REFUSAL_PRS="$MERGE_ALL_PRS"
    REFUSAL_TOTAL="$MERGE_COUNT"
    # One clause per invocation kind, count-derived, so a triple like two
    # bare merges beside a selector merge breaks down honestly.
    NUMBERLESS_MERGES=${MERGE_NUMBERLESS_COUNT:-0}
    while [ "$NUMBERLESS_MERGES" -gt 0 ]; do
        REFUSAL_PRS="${REFUSAL_PRS:+$REFUSAL_PRS }+ a numberless merge (gh infers the PR from the current branch)"
        REFUSAL_TOTAL=$((REFUSAL_TOTAL + 1))
        NUMBERLESS_MERGES=$((NUMBERLESS_MERGES - 1))
    done
    if [ -n "$MERGE_SELECTOR" ]; then
        # Selector invocations = everything the precise scan saw that is
        # neither numbered nor numberless.
        SELECTOR_MERGES=$((MERGE_INVOKE_COUNT - MERGE_COUNT))
        SELECTOR_MERGES=$((SELECTOR_MERGES - ${MERGE_NUMBERLESS_COUNT:-0}))
        while [ "$SELECTOR_MERGES" -gt 0 ]; do
            REFUSAL_PRS="${REFUSAL_PRS:+$REFUSAL_PRS }+ a merge naming its PR by branch or URL"
            REFUSAL_TOTAL=$((REFUSAL_TOTAL + 1))
            SELECTOR_MERGES=$((SELECTOR_MERGES - 1))
        done
    fi
    {
        printf '%s\n' "$RULE"
        printf 'ONE MERGE PER COMMAND — compound merge refused\n'
        printf '%s\n\n' "$RULE"
        printf 'This command invokes `gh pr merge` more than once: %s\n\n' "$REFUSAL_PRS"
        printf 'The review gate arms on the FIRST invocation only, so every merge after it\n'
        printf 'would run without its own review-ack cycle — the check would report green\n'
        printf 'having read one review out of %s.\n\n' "$REFUSAL_TOTAL"
        printf 'Run them as separate calls, one PR per command, so each merge is gated:\n'
        printf '  gh pr merge <first>    # read its review, then retry\n'
        printf '  gh pr merge <second>\n\n'
        printf 'This refusal is not ackable — retrying the same compound command reproduces\n'
        printf 'the same gap. Nothing was acked, so no state needs undoing.\n'
        printf '%s\n' "$RULE"
    } >&2
    exit 2
fi

# SCOPE-MOVED REFUSAL. A directory change (cd/pushd/popd, or a chdir runner
# like `env -C` wrapping the merge itself) before the merge in the SAME
# command means this hook cannot know which repository the merge targets:
# resolving in its own cwd fetches the WRONG repo's PR — the review of a PR
# that is not the one merging, or none, and the merge runs ungated. The same
# class of hole as -R scoping, caught one command-shape earlier.
#
# NOT ACKABLE, for the same reason as the compound refusal: the way past is
# to run the merge from the directory it targets (or with -R naming that
# repo), which is also what makes the review reachable, and recovery costs
# one extra Bash call. Placed with the compound refusal — before any network
# call, because it needs only the local extraction.
#
# SKIPPED when the invocation already pins its repository (a URL selector's
# own repo, -R, or a GH_REPO= assignment — all of them land in REPO_ARG
# before this point): a named repo resolves the same from any directory, so
# the cd cannot move the merge's scope — the banner's own -R advice is
# exactly that escape, already taken.
if [ "$MERGE_CHDIR" = "chdir" ] && [ -z "$REPO_ARG" ]; then
    {
        printf '%s\n' "$RULE"
        printf 'MERGE SCOPE MOVED — merge after a directory change refused\n'
        printf '%s\n\n' "$RULE"
        printf 'This command changes directory before `gh pr merge`, so the PR cannot be\n'
        printf 'resolved against the directory the merge will run in. Resolving from this\n'
        printf 'hook'\''s cwd would surface the WRONG repository'\''s review — or none — and let\n'
        printf 'the merge through ungated.\n\n'
        printf 'Run the merge from the directory it targets, as its own command:\n'
        printf '  cd <target-dir>\n'
        printf '  gh pr merge <PR>\n'
        printf 'or, without changing directory, name the repository explicitly:\n'
        printf '  gh pr merge <PR> -R <owner>/<repo>\n\n'
        printf 'This refusal is not ackable — retrying the same shape reproduces the same\n'
        printf 'wrong-scope risk. Nothing was acked, so no state needs undoing.\n'
        printf '%s\n' "$RULE"
    } >&2
    exit 2
fi

# FAN-OUT REFUSAL. `gh pr merge` under xargs or parallel runs once per input
# line: the gate arms on the one invocation the scan sees, and every other
# input merges with no ack cycle of its own — the compound-merge hole with a
# loop around it. Same family, same treatment: NOT ACKABLE (the way past is
# one merge per command, which is also what makes each review reachable),
# and placed with the other refusals, before any network call.
if [ "$MERGE_FANOUT" = "fanout" ]; then
    {
        printf '%s\n' "$RULE"
        printf 'FAN-OUT MERGE REFUSED — one merge per review cycle\n'
        printf '%s\n\n' "$RULE"
        printf 'This command runs `gh pr merge` under xargs/parallel, which executes it once\n'
        printf 'per input — no single review-ack cycle can cover that, and every input after\n'
        printf 'the first would merge ungated.\n\n'
        printf 'Run the merges as separate calls, one PR per command, so each is gated:\n'
        printf '  gh pr merge <first>    # read its review, then retry\n'
        printf '  gh pr merge <second>\n\n'
        printf 'This refusal is not ackable — retrying the same shape reproduces the same\n'
        printf 'gap. Nothing was acked, so no state needs undoing.\n'
        printf '%s\n' "$RULE"
    } >&2
    exit 2
fi

# UNRESOLVABLE-SCOPE REFUSAL. When the winning repository scope comes from a
# bare `export GH_REPO` / `declare -x GH_REPO` (with no literal assignment in
# the same command), a child-context merge preceded by a child-context
# `GH_REPO` export/`declare -x`, or a non-literal `-R`/`--repo`/`GH_REPO=`
# value (`$(...)`, backticks, `<(...)`, `$VAR`), this hook cannot resolve
# which repository the merge targets: falling back to the cwd repository would
# fetch the WRONG repo's review — or none — and let the merge through
# ungated.
#
# NOT ACKABLE, for the same reason as the scope-moved refusal above: pass a
# literal repository slug on the merge command, which also makes the review
# reachable in one retry. Placed with the other refusals, before any network
# call.
if [ "$MERGE_UNRESOLVABLE" = "unresolvable" ]; then
    {
        printf '%s\n' "$RULE"
        printf 'MERGE SCOPE UNRESOLVABLE — dynamic repository scope refused\n'
        printf '%s\n\n' "$RULE"
        printf 'This command scopes `gh pr merge` with a `GH_REPO` or `-R`/`--repo` value that\n'
        printf 'cannot be resolved statically (an exported `GH_REPO` with no literal value in\n'
        printf 'this command, or a shell expansion such as `$(...)` or `$VAR`). Falling back\n'
        printf 'to this hook'\''s cwd would surface the WRONG repository'\''s review — or none —\n'
        printf 'and let the merge through ungated.\n\n'
        printf 'Pass a literal repository slug on the merge command:\n'
        printf '  gh pr merge <PR> -R <owner>/<repo>\n'
        printf 'or as a literal prefix assignment:\n'
        printf '  GH_REPO=<owner>/<repo> gh pr merge <PR>\n\n'
        printf 'This refusal is not ackable — retrying the same shape reproduces the same\n'
        printf 'wrong-scope risk. Nothing was acked, so no state needs undoing.\n'
        printf '%s\n' "$RULE"
    } >&2
    exit 2
fi

# No PR number: either the command only mentioned the phrase without invoking
# it (nothing to gate on), or it invoked `gh pr merge` naming its PR some
# other way. gh accepts `number | url | branch` as the argument (a leading
# `#` is stripped), so a positional selector is resolved with the same
# `gh pr view <selector>` gh itself would use — REPO_SCOPE_ARGS rides along:
# gh prefers a URL selector's own repository, and -R scopes a branch
# selector's lookup. Only an invocation with NO positional argument at all is
# numberless: gh then infers the PR from the current branch, resolved the
# same way in this hook's cwd. Any lookup failure (unknown branch, not a PR
# branch, gh missing or unauthenticated) fails open: exit 0, no gate. Every
# lookup runs under `timeout 10`, so a HUNG gh fails into this file's chosen
# direction rather than the harness's.
if [ -z "$PR_NUM" ]; then
    if [ -n "$MERGE_SELECTOR" ]; then
        PR_NUM=$(timeout 10 gh pr view "$MERGE_SELECTOR" "${REPO_SCOPE_ARGS[@]}" --json number -q .number 2>/dev/null || echo "")
    elif [ "$MERGE_NUMBERLESS" = "numberless" ]; then
        PR_NUM=$(timeout 10 gh pr view "${REPO_SCOPE_ARGS[@]}" --json number -q .number 2>/dev/null || echo "")
    else
        exit 0
    fi
    [[ "$PR_NUM" =~ ^[0-9]+$ ]] || exit 0
fi

# Ack state. The per-(PR, review-comment-id) acks and the per-PR
# default-branch-reminder acks live in ONE line-oriented file under the
# user's own state directory — per-user, never in a shared world-writable
# location like /tmp, and created with restrictive modes (directory 700,
# file 600 via umask).
#
# The invariant: state is never written THROUGH a symlink, and a state file
# that is not a readable regular file is treated as NOT acked — the gate
# fails CLOSED. A symlink or a clobbered file at the state path must not
# become a merge-through or a write-through: the gate blocks, says why on
# stderr, and writes nothing until the path is fixed by hand. This is the
# one place the hook fails closed on bad state, deliberately — a planted
# state file is tampering, not an environment fault.
#
# Write failures on a healthy state file split by WHICH ack: the review ack
# fails CLOSED with the escape named (an allow would print a review to a
# stream nobody sees); the reminder ack fails OPEN — when its append fails
# inside release_block_then_exit, the hook takes exit 0 and stderr on an
# exit-0 hook reaches nobody, so the reminder banner printed above is lost
# for that attempt (and for retries while the write fault persists).
# Failing open is still right so a broken state write never blocks merges
# forever.
STATE_BASE="${XDG_STATE_HOME:-$HOME/.local/state}"
SEYAG_DIR="$STATE_BASE/seyag"
STATE_DIR="$SEYAG_DIR/pr-merge-review-check"
STATE_FILE="$STATE_DIR/ack"
ACK_STATE_FAULT=""

# ack_state_usable: 0 when the state is safe to read and write (absent
# counts as safe — the ordinary first-run state). Any anomaly is named in
# ACK_STATE_FAULT for the caller to print.
#
# The never-write-through-a-symlink invariant covers the DIRECTORIES on the
# path too: a symlink at STATE_DIR or at the seyag-level
# parent lets a planted directory become the ack store, exactly like a
# symlink at the file did — the file-level check alone tested the FILE, which
# through a directory link is just the attacker's choice of target. A
# non-directory sitting where STATE_DIR belongs is the same fail-closed class:
# the mkdir would fail as a generic write fault instead
# of a named one, and the generic path fails OPEN.
ack_state_usable() {
    ACK_STATE_FAULT=""
    if [ -L "$STATE_DIR" ]; then
        ACK_STATE_FAULT="symlink at $STATE_DIR (the state directory)"
        return 1
    fi
    if [ -L "$SEYAG_DIR" ]; then
        ACK_STATE_FAULT="symlink at $SEYAG_DIR (the seyag state directory)"
        return 1
    fi
    if [ -e "$STATE_DIR" ] && [ ! -d "$STATE_DIR" ]; then
        ACK_STATE_FAULT="$STATE_DIR exists and is not a directory"
        return 1
    fi
    if [ -L "$STATE_FILE" ]; then
        ACK_STATE_FAULT="symlink at $STATE_FILE"
        return 1
    fi
    if [ -e "$STATE_FILE" ] && { [ ! -f "$STATE_FILE" ] || [ ! -r "$STATE_FILE" ]; }; then
        ACK_STATE_FAULT="$STATE_FILE is not a readable regular file"
        return 1
    fi
    return 0
}

# ack_state_holds <key>: exact-line lookup. A faulted state never holds
# anything, so an ack can never be read through an anomaly.
ack_state_holds() {
    ack_state_usable || return 1
    grep -qxF "$1" "$STATE_FILE" 2>/dev/null
}

# ack_append <key>: best-effort append; refuses to write when the state is
# faulted. 0 on success, 1 on refusal or write failure.
ack_append() {
    ack_state_usable || return 1
    # shellcheck disable=SC2174  # -m on the deepest dir is the intent: parents keep their distro modes, the state dir itself is 700 (pinned by the probe)
    mkdir -p -m 700 "$STATE_DIR" 2>/dev/null || return 1
    # -m only applies at CREATION: a pre-existing state
    # dir left wide (755, by an older version or by hand) self-heals here.
    chmod 700 "$STATE_DIR" 2>/dev/null || true
    (umask 077; printf '%s\n' "$1" >>"$STATE_FILE") 2>/dev/null
}

# Ack keys, defined BEFORE the lookups because two independent concerns key
# off the state: the review gate (per PR+comment-id) and the default-branch
# reminder (per PR). The release key carries the repo identity so the same
# PR number in two repositories cannot ack each other's reminders; an
# unresolved repo falls back to a shared "unresolved" spelling, which fails
# open (a reminder may repeat) rather than colliding.
RELEASE_REPO="unresolved"
RELEASE_KEY=""

# Base-branch and head-ref resolution. Queried fresh every time it is
# needed, NOT cached across invocations.
#
# The default-branch reminder must be reachable BEFORE the review-existence
# early-exits — a default-branch PR whose review posted nothing would
# otherwise merge with no reminder at all, which is the exact silent-drop
# class this hook exists to end.
#
# Fails open to "": an unreadable base skips the reminder block rather than
# blocking a merge on a `gh` blip. The head ref fails open the same way,
# which is what makes the delete-branch guard below degrade to "allow" on a
# `gh` outage rather than to "cannot merge".
PR_BASE=""
PR_HEAD=""
PR_VIEW_RESOLVED=0
resolve_pr_view() {
    [ "$PR_VIEW_RESOLVED" = 1 ] && return 0
    PR_VIEW_RESOLVED=1
    local view
    view=$(timeout 10 gh pr view "${REPO_SCOPE_ARGS[@]}" "$PR_NUM" --json baseRefName,headRefName \
        --jq '(.baseRefName // ""), (.headRefName // "")' \
        2>/dev/null || echo "")
    PR_BASE=$(printf '%s\n' "$view" | sed -n '1p')
    PR_HEAD=$(printf '%s\n' "$view" | sed -n '2p')
    return 0
}

# Repo identity and default branch, from one memoized `gh repo view` call:
# the identity scopes the REST review fetch and the reminder ack key (no
# hard-coded repo — this hook runs in any repository gh can resolve from
# the cwd), the default branch decides whether a merge targets it. Fails
# open to "": an unreadable repo means no reminder and no review fetch, the
# same degradation a `gh` outage already causes further down.
REPO=""
DEFAULT_BRANCH=""
REPO_RESOLVED=0
resolve_repo() {
    [ "$REPO_RESOLVED" = 1 ] && return 0
    REPO_RESOLVED=1
    local view
    # Scoped with -R when the invocation named a repo: gh then resolves THAT
    # repo, and its nameWithOwner confirms/refines REPO (the ack key below
    # carries the resolved spelling). With -R and a failing lookup, REPO
    # stays empty and the review fetch below falls back to REPO_ARG.
    view=$(timeout 10 gh repo view "${REPO_SCOPE_ARGS[@]}" --json nameWithOwner,defaultBranchRef \
        --jq '(.nameWithOwner // ""), (.defaultBranchRef.name // "")' \
        2>/dev/null || echo "")
    REPO=$(printf '%s\n' "$view" | sed -n '1p')
    DEFAULT_BRANCH=$(printf '%s\n' "$view" | sed -n '2p')
    RELEASE_REPO="${REPO:-unresolved}"
    RELEASE_KEY="RELEASE:${RELEASE_REPO}:${PR_NUM}"
    return 0
}

# True when this PR merges into the repo's default branch and that reminder
# has not been shown yet.
#
# The ack check runs FIRST, before any network call, so a PR whose reminder
# was already shown costs nothing to re-evaluate.
#
# DELIBERATE ACCEPT for the remaining case: a FIRST block on an ordinary
# feature PR pays the lookups to discover it is not default-branch-relevant.
# The same path already makes network calls to fetch the review, so it is
# network-bound regardless, and it is a blocking gate that happens once per
# review cycle, not a latency-sensitive loop. It fails open, so a `gh`
# outage degrades to "no reminder", never "cannot merge".
#
# A cheaper short-circuit — caching the base per PR — was tried and removed:
# a PR retargeted between two merge attempts keeps serving the stale answer,
# which either suppresses the reminder or fires it spuriously. A stale
# answer here reproduces the exact silent-drop class this hook exists to
# prevent.
release_reminder_due() {
    resolve_repo
    if ack_state_holds "$RELEASE_KEY"; then
        return 1
    fi
    resolve_pr_view
    [ -n "$DEFAULT_BRANCH" ] || return 1
    [ "$PR_BASE" = "$DEFAULT_BRANCH" ] || return 1
    return 0
}

# --- delete-branch precondition --------------------------------------------
#
# `--delete-branch` deletes the LOCAL branch by first switching the CURRENT
# worktree off it, then running the equivalent of `git branch -D`.
#
# That second half fails outright when some OTHER worktree still holds the
# branch — git's refusal is "cannot delete branch 'X' used by worktree at
# '<path>'". By then the merge has already landed, so the result is: PR
# merged, remote branch gone, local branch alive, and a non-zero `gh` exit
# that reads like the merge itself failed. The branch then looks live to
# every later `git branch` and survives silently.
#
# Hence the scope is OTHER worktrees only. The current worktree sitting on
# the head branch is the ORDINARY case — it is what "merge my feature
# branch" looks like — and gh resolves it by switching away, so refusing it
# would block the most common merge invocation.
#
# This guard is deliberately NOT ackable, unlike the review gate. An ack
# exists so a merge can proceed once the agent has READ something; here
# nothing has been read — a precondition is unmet, and retrying without
# fixing it must keep failing or the guard is decorative.
#
# Do NOT read this hook as branch protection. The systematic backstop for
# long-lived branches is the repository's own branch-protection ruleset,
# which is what actually stops the admin-privileged delete path. That is the
# thing to fix if it ever regresses, not this hook.
#
# The flag comes from the ARGUMENT VECTOR, scoped to the armed invocation's
# own arguments — not from a raw pass over the command text. A raw pass
# matches any dash-token containing a `d` anywhere in the command, so
# `gh pr merge N --rebase && git branch -d old` and `... && find . -delete`
# both armed it, as did a `-d` inside a quoted `--body`. That is precisely
# the quoted-prose false-positive class the arg-vector parse exists to
# eliminate, reintroduced one check later — and because this guard is NOT
# ackable, a false block is not a recoverable annoyance.
# The cwd repository's owner/name, parsed LOCALLY from the git remote — no
# network, no gh. Handles the https and ssh URL shapes (scheme, user@host,
# host:path, trailing .git and /); anything unparseable yields "" and the
# caller treats that as SAME-repo (the guard stays on — the safe direction;
# when -R names this repo the escape is dropping the redundant -R, though
# with a non-GitHub cwd remote a different-repo -R has no one-command escape
# — the block is the documented safe direction there).
cwd_repo_slug() {
    local url
    url=$(git remote get-url origin 2>/dev/null \
        || git remote get-url "$(git remote 2>/dev/null | sed -n 1p)" 2>/dev/null \
        || echo "")
    [ -n "$url" ] || { printf '\n'; return 0; }
    url=${url#ssh://}; url=${url#http://}; url=${url#https://}
    url=${url#git@}
    case "$url" in
        *:*) url=${url#*:} ;;  # scp form: the host rides the colon
        *) url=${url#*/} ;;    # plain form: the leading component is the host
    esac
    url=${url%/}; url=${url%.git}
    case "$url" in
        */*) printf '%s/%s\n' "${url%/*}" "${url##*/}" ;;
        *) printf '\n' ;;
    esac
}

# GitHub owner/repo is case-INSENSITIVE, and gh also accepts a
# HOST/OWNER/REPO spelling for -R, so `-R Owner/Repo` and
# `-R github.com/owner/repo` name this repo as surely as the exact slug.
# `repo_slug_hoststrip` drops a leading host component (the only three-part
# form gh accepts), used by both the same-repo compare below (lowercased via
# `repo_slug_normalized`) and the review-fetch fallback when `gh repo view`
# fails (`repos/github.com/owner/repo/...` is a 404 REST path).
repo_slug_hoststrip() {
    local slug=$1
    case "$slug" in
        */*/*) slug=${slug#*/} ;;
    esac
    printf '%s\n' "$slug"
}

repo_slug_normalized() {
    repo_slug_hoststrip "$1" | tr '[:upper:]' '[:lower:]'
}

# The whole check is skipped when the invocation scopes a DIFFERENT
# repository (-R/--repo, or a URL selector's own repo): the local worktrees
# belong to this checkout's repo and cannot safely answer for another
# repo's head branch — a same-named local branch would be a false,
# non-ackable block with no recovery path. An -R naming THIS repo — in any
# spelling gh accepts — is the same merge as an unscoped one, so the guard
# applies to it too. When the cwd remote is absent or unparseable (`cwd`
# empty), the guard ALSO stays on (same-repo direction, matching
# `cwd_repo_slug`'s contract above). The escape depends on the case: a
# same-repo -R can simply be dropped, but with a non-GitHub cwd remote a
# different-repo -R has no one-command escape — the block stands as the
# documented safe direction.
if [ "$MERGE_DELETES_BRANCH" = "1" ]; then
    GUARD_APPLIES=1
    CWD_SLUG=$(cwd_repo_slug)
    if [ -n "$REPO_ARG" ] && [ -n "$CWD_SLUG" ]; then
        [ "$(repo_slug_normalized "$REPO_ARG")" = "$(repo_slug_normalized "$CWD_SLUG")" ] || GUARD_APPLIES=0
    fi
    if [ "$GUARD_APPLIES" = "1" ]; then
    resolve_pr_view
    # Every step below fails open to "no conflict": no head ref (gh blip),
    # not a git repo, no worktree holds the branch. Blocking a merge on a
    # broken lookup would be a worse failure than the one being prevented.
    CURRENT_TREE=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    # An empty CURRENT_TREE is checked EXPLICITLY rather than left to fall
    # through. Without this the comparison below is `path != ""`, which is
    # true for every worktree including the one running the merge — so a
    # failure of this one command turns the guard from fail-open into
    # block-everything, exactly inverting the property the comment above
    # claims.
    if [ -n "$PR_HEAD" ] && [ -n "$CURRENT_TREE" ]; then
        # `git worktree list --porcelain` lists the MAIN checkout as a
        # worktree too, so this one command covers both trees. A detached
        # worktree emits `detached` instead of a `branch` line and simply
        # never matches. Paths are read with substr rather than by
        # field-splitting so a worktree path containing spaces survives.
        # `cur` comes through the ENVIRONMENT, not `-v`. awk interprets
        # C-style escapes in a `-v` assignment, so a worktree path
        # containing a literal backslash (valid on Linux, unlike in a git
        # ref name) would be rewritten before the comparison. ENVIRON is
        # not escape-processed. `want` stays on `-v` because git ref names
        # cannot contain a backslash at all.
        CONFLICT_TREE=$(git worktree list --porcelain 2>/dev/null | CUR_TREE="$CURRENT_TREE" awk \
            -v want="branch refs/heads/$PR_HEAD" '
            BEGIN { cur = ENVIRON["CUR_TREE"] }
            /^worktree / { path = substr($0, 10); next }
            $0 == want   { if (path != cur) { print path; exit } }
        ')
        if [ -n "$CONFLICT_TREE" ]; then
            {
                printf '%s\n' "$RULE"
                printf 'PR MERGE BLOCKED — head branch is checked out in another worktree\n'
                printf '%s\n\n' "$RULE"
                printf 'PR #%s head branch:  %s\n' "$PR_NUM" "$PR_HEAD"
                printf 'Held by worktree:    %s\n\n' "$CONFLICT_TREE"
                printf 'With --delete-branch (or -d), gh merges FIRST and then deletes the local\n'
                printf 'branch. git refuses that delete while another worktree holds the branch,\n'
                printf 'so the merge lands, the remote branch goes away, and the local branch\n'
                printf 'survives looking live — while gh exits non-zero as if nothing merged.\n\n'
                # Both paths are single-quoted so the suggestions stay
                # copy-paste-safe. The detection side was hardened for a
                # worktree path containing a space; printing an unquoted path
                # would break the remediation on that exact case —
                # `git worktree remove /tmp/my worktree` takes an extra
                # positional, and `-C /tmp/my` leaves `worktree` parsed as the
                # subcommand. A path containing a single quote would still
                # mangle these, which is why they are suggestions to read, not
                # commands the hook runs.
                printf 'Fix one of these, then re-run the same command:\n'
                printf "  git worktree remove '%s'\n" "$CONFLICT_TREE"
                printf '  # refuses on a dirty tree — that means uncommitted work lives there.\n'
                printf '  # Look before forcing; the option below needs no --force at all.\n'
                printf '  # or, if that worktree is still needed, move it off the branch:\n'
                printf "  git -C '%s' checkout --detach\n\n" "$CONFLICT_TREE"
                printf 'Retrying without doing one of those will be blocked again — this is a\n'
                printf 'precondition, not a review gate, so there is nothing to acknowledge.\n'
                printf '%s\n' "$RULE"
            } >&2
            exit 2
        fi
    fi
    fi
fi

# The reminder body. Written to stderr by both call paths below — beside the
# review on the normal path, alone when no review exists. FORWARD-looking (it
# fires before the merge, not after).
#
# The text is the project's own: SYG_MERGE_REVIEW_RELEASE_REMINDER replaces
# the default sentence entirely (multi-line text is fine). The default names
# no project, tool or machine — one short neutral sentence, because a public
# plugin cannot know what a repo's post-merge steps are.
print_release_block() {
    local default_reminder="This PR merges into the repository's default branch — run this project's post-merge steps (version bump, release, deploy) before starting other work."
    printf '%s\n' "$RULE"
    printf 'DEFAULT-BRANCH MERGE — PR #%s merges into the repo'\''s default branch (%s).\n\n' \
        "$PR_NUM" "${DEFAULT_BRANCH:-<unresolved>}"
    printf '%s\n\n' "${SYG_MERGE_REVIEW_RELEASE_REMINDER:-$default_reminder}"
    printf 'Retry the same merge command to proceed.\n'
    printf '%s\n' "$RULE"
}

# Taken by the two "no usable review" exits below. Without a review there is
# nothing to inject, so the review gate itself allows the merge — but a
# default-branch PR still owes its reminder, and stderr only reaches the
# agent on the blocking path, so delivering it means exiting 2 once. A
# feature PR is unaffected and still exits 0 immediately.
#
# $1 is the reason line, because the call sites are NOT the same state: one
# found no comment, another found one that would not parse, a third has
# already surfaced the review. Saying "none found" for all of them would be
# a banner asserting something untrue.
#
# $2 overrides the body's first line for the same reason. It defaults to the
# no-review wording, which is wrong for the acked-retry caller: there, a
# review exists and was already shown, so claiming the gate "has nothing to
# surface" would be the same species of false banner.
release_block_then_exit() {
    if release_reminder_due; then
        {
            printf '%s\n' "$RULE"
            printf 'PR MERGE GATE — %s for PR #%s\n' "${1:-no usable review}" "$PR_NUM"
            printf '%s\n\n' "$RULE"
            printf '%s\n' "${2:-The review gate has nothing to surface, so it is not blocking on that.}"
            printf 'This block is the default-branch merge reminder, which does NOT depend on a\n'
            printf 'review existing. Retry the same merge command to proceed.\n\n'
            print_release_block
            printf '%s\n' "$RULE"
        } >&2
        if ! ack_state_usable; then
            # Fail CLOSED on a faulted state path: no write through it, and
            # the merge stays blocked until the path is fixed.
            printf 'WARNING: the merge-review ack state is unusable (%s) — this reminder\n' "$ACK_STATE_FAULT" >&2
            printf 'cannot be acked, so retries will keep blocking until the state path is fixed.\n' >&2
            printf 'Nothing was written through it.\n' >&2
            exit 2
        fi
        if ack_append "$RELEASE_KEY"; then
            chmod 600 "$STATE_FILE" 2>/dev/null || true
            exit 2
        fi
        # Healthy state, failed write — fail open rather than block forever.
        # No warning: this is the exit-0 path, where stderr reaches nobody
        # (the header's rule), so both a warning line and the reminder banner
        # printed above are lost for this attempt (and for retries while the
        # write fault persists); failing open avoids blocking merges forever.
    fi
    exit 0
}

# Fetch the most recent reviewer comment on this PR. Pull body + id +
# updated_at so the ack key re-arms when a review EDITS its comment in place
# (a fresh review re-runs the gate too).
#
# `--paginate --slurp` is required, and so is the PIPE to jq: gh rejects
# `--slurp` together with `--jq` ("the --slurp option is not supported with
# --jq or --template"), and asking for `--jq` anyway makes the whole fetch
# fail into the no-review path — a silently inert gate. Piping keeps both:
# gh emits every page wrapped in one outer array, and jq selects across all
# of them. The pagination itself is the point: this endpoint accepts
# per_page (and page) but not sort/direction — those belong to the
# repository-wide comments listing — so a single ask returns the FIRST
# (oldest) page, and on a busy PR the newest review sits past it: the filter
# would silently surface an OLDER review (fires but injects the wrong
# content — the worst failure mode for this gate). sort_by|last picks the
# NEWEST matching comment across every page.
#
# The reviewer identity is configurable: SYG_MERGE_REVIEW_LOGIN overrides the
# default `claude[bot]` for repos whose review comes from another bot. The
# login reaches jq as a --arg VALUE — data, not filter text.
REVIEW_JSON=""
REVIEW_LOGIN="${SYG_MERGE_REVIEW_LOGIN:-claude[bot]}"
resolve_repo
# -R scoping: prefer the RESOLVED nameWithOwner (canonical spelling of the
# -R target); fall back to REPO_ARG itself (host component stripped so
# `-R github.com/owner/repo` builds a valid REST path) when repo view failed,
# so a lookup blip does not silently unscope the fetch back to the cwd repo.
REPO_FOR_FETCH="${REPO:-$(repo_slug_hoststrip "$REPO_ARG")}"
if [ -n "$REPO_FOR_FETCH" ]; then
    REVIEW_JSON=$(timeout 10 gh api --paginate --slurp "repos/${REPO_FOR_FETCH}/issues/${PR_NUM}/comments?per_page=100" 2>/dev/null \
        | jq --arg login "$REVIEW_LOGIN" \
            '[.[][] | select(.user.login == $login)] | sort_by(.created_at) | last' \
        2>/dev/null || echo "")
fi

# No claude[bot] review comment on this PR (yet, or ever). Allow the merge —
# the gate is only meaningful when there's actually content to surface. The
# agent should still read whatever review IS available.
#
# When the reminder block is about to print, it names WHY there is no review
# if the reason is a sanctioned one, so the agent does not chase a rerun that
# cannot produce one:
#   - the PR edits the review workflow file: a review action that validates
#     its own workflow file commonly skips itself on a mismatch. This hook
#     cannot observe the action, so the wording says "most likely" and
#     points at the review job's log;
#   - the PR is dependabot's: review jobs commonly skip PRs by that author.
#
# Both facts come from their OWN `gh pr view` call, made only here — on the
# no-review path, after release_reminder_due has passed — never from
# resolve_pr_view, so a failure of this lookup cannot cost the reminder its
# base. It is bounded by `timeout` and any failure (non-zero exit, timeout,
# unreadable output) leaves both facts empty, which keeps the plain wording.
#
# `gh` reports the dependabot author as `app/dependabot` (probed with
# `gh pr list --author app/dependabot`); the webhook spelling
# `dependabot[bot]` is matched too. A PR whose base is not the default
# branch still exits 0 silently — release_block_then_exit prints nothing
# there.
# Configurable: SYG_MERGE_REVIEW_WORKFLOW overrides the review workflow file
# whose self-edit explains a missing review (repos name it differently).
# Like the login above, it reaches its jq filter as an ENCODED literal, not
# spliced text.
REVIEW_WORKFLOW_PATH="${SYG_MERGE_REVIEW_WORKFLOW:-.github/workflows/claude-code-review.yml}"
REVIEW_WF_JSON=$(jq -n --arg v "$REVIEW_WORKFLOW_PATH" '$v')
no_review_reason() {
    NO_REVIEW_HEADER="no review comment found"
    NO_REVIEW_DETAIL=""
    release_reminder_due || return 0
    local facts pr_author pr_edits_review_workflow
    facts=$(timeout 10 gh pr view "${REPO_SCOPE_ARGS[@]}" "$PR_NUM" --json author,files \
        --jq "(.author.login // \"\"),
              ([.files[]?.path] | any(. == ${REVIEW_WF_JSON}) | tostring)" \
        2>/dev/null) || facts=""
    pr_author=$(printf '%s\n' "$facts" | sed -n '1p')
    pr_edits_review_workflow=$(printf '%s\n' "$facts" | sed -n '2p')
    if [ "$pr_edits_review_workflow" = "true" ]; then
        NO_REVIEW_HEADER="no review comment (most likely skipped itself)"
        NO_REVIEW_DETAIL="This PR changes $REVIEW_WORKFLOW_PATH. A review action commonly skips
itself when the PR edits its own workflow file; confirm in the review job's
log before rerunning it."
    elif [ "$pr_author" = "app/dependabot" ] || [ "$pr_author" = "dependabot[bot]" ]; then
        NO_REVIEW_HEADER="no review comment (dependabot PRs are typically skipped by the review workflow's author filter)"
        NO_REVIEW_DETAIL="This PR is dependabot's, and review workflows commonly skip PRs by that
author, so there is most likely no review to wait for or rerun."
    fi
    return 0
}

if [ -z "$REVIEW_JSON" ] || [ "$REVIEW_JSON" = "null" ]; then
    no_review_reason
    if [ -n "$NO_REVIEW_DETAIL" ]; then
        release_block_then_exit "$NO_REVIEW_HEADER" "$NO_REVIEW_DETAIL"
    fi
    release_block_then_exit "$NO_REVIEW_HEADER"
fi

REVIEW_ID=$(jq -r '.id // empty' <<<"$REVIEW_JSON")
REVIEW_CREATED=$(jq -r '.created_at // empty' <<<"$REVIEW_JSON")
REVIEW_TS=$(jq -r '.updated_at // empty' <<<"$REVIEW_JSON")
REVIEW_BODY=$(jq -r '.body // empty' <<<"$REVIEW_JSON")

if [ -z "$REVIEW_ID" ] || [ -z "$REVIEW_BODY" ]; then
    # Malformed response or empty review. Allow the merge rather than block on
    # an unparseable state. The reminder is independent of that and still owed.
    release_block_then_exit "a review comment was found but did not parse"
fi

# Origin-language scan: reviews that scope findings as "pre-existing" /
# "not a regression" invite dismissal-by-origin — origin is not a
# correctness verdict, so when the vocabulary appears, the injected block
# below demands a per-finding merits disposition before the merge retry.
# Line-count (not boolean) so the warning can say how much of it there is;
# false positives cost one reminder paragraph, never a block. grep -c prints
# 0 on no-match but exits 1; the herestring isn't a pipeline (pipefail
# doesn't apply) and errexit isn't set, so `|| true` changes nothing today —
# it documents that the non-zero exit is expected and keeps the guard
# correct if `set -e` ever arrives.
ORIGIN_HITS=$(grep -icE 'pre-?existing|pre-?dates|not a regression|not introduced (by|in) this|existing behavior|consistent with existing|already (present|existed)' <<<"$REVIEW_BODY" || true)

# Per-(PR, comment-id, updated_at) key. A fresh review (different
# comment-id) forces re-engagement, and so does an EDIT: sticky and
# edit-in-place review modes update one comment, keeping the id but moving
# updated_at — the moved timestamp re-arms the gate carrying the new body. A
# retry after ack proceeds. Scoped to the comment the fetch PICKED (the
# newest by created_at — that sort is deliberate, so an edit to an OLDER
# comment cannot outrank the newest round and re-arm the gate on it): an
# edit re-arms only when it is the picked comment that moved.
ACK_KEY="${PR_NUM}:${REVIEW_ID}:${REVIEW_TS}"

# Acked-retry path: the review has already been surfaced for this comment-id,
# so the review gate itself is satisfied. The default-branch reminder is
# still evaluated, because it is a separate obligation with a separate ack —
# a PR retargeted between two attempts on the SAME review comment must not
# keep a stale "already reminded" verdict.
#
# A FAULTED state reads as NOT acked here, so the gate re-blocks below and
# keeps blocking until the state path is fixed — the fail-closed direction.
if ack_state_holds "$ACK_KEY"; then
    release_block_then_exit "the review was already acked" \
        "The review for this PR was surfaced and acknowledged on an earlier call."
fi

# Added-comment claim scan. Placed AFTER the acked-retry return on purpose:
# this is the only path that adds a second network call, and the retry path
# must stay at the round trips it already pays.
#
# `gh pr diff <number>` writes the unified diff to stdout, and `--color`
# defaults to `auto` — so a captured, non-TTY stdout carries no ANSI escapes
# and the added-line prefix is a plain `+`. Anything else — no such PR, no
# network, an old gh without the subcommand — leaves PR_DIFF empty and the
# scan silently produces nothing. A diff fetch that fails must never block a
# merge nor warn about itself; the gate's subject is the review, not the
# diff.
PR_DIFF=$(timeout 10 gh pr diff "${REPO_SCOPE_ARGS[@]}" "$PR_NUM" 2>/dev/null || echo "")

# The comment lines this diff ADDS, filtered to claim vocabulary in three
# classes: certainty, provenance, and counted nouns. This is the surface the
# RE-DERIVE reminder below structurally cannot reach — that one re-runs the
# numbers in the PR body and commit message, both of which are read again at
# review time, while a claim committed into a permanent code comment is not.
# `^\+[^+]` keeps the `+++ b/path` file header out. False positives cost one
# paragraph, never a block — the same trade the origin scan above accepts.
#
# The vocabulary and its anchoring live in lib/claim-shapes.sh, sourced at
# the top; a missing lib degrades this scan to nothing, never to a block.
#
# The comment-shape detector accepts three gaps by design rather than
# pretending to parse: a docstring or block-comment CONTINUATION line is not
# detected (line-greping a diff cannot track comment state, so only the
# `"""`/`'''`/`/*` OPENING line is seen); a TRAILING end-of-line comment
# (`code(); // claim`) is not detected, since the marker must be the line's
# first non-whitespace content; and the `*` branch also matches a Markdown
# bullet. Each costs or saves one banner paragraph, never a block.
CLAIM_ALL=$(grep -E '^\+[^+]' <<<"$PR_DIFF" |
    grep -E "^\+[[:space:]]*(//|\*|/\*|#|\"\"\"|''')" |
    grep -iE "$CLAIM_SHAPE_CORE_REGEX" || true)

# Count the FULL match set, THEN cap what gets displayed. Counting after the
# cap would make every total above the cap report AS the cap — a silent
# truncation. The banner below names the truncation instead.
CLAIM_DISPLAY_CAP=12
CLAIM_HITS=0
CLAIM_LINES=""
if [ -n "$CLAIM_ALL" ]; then
    CLAIM_HITS=$(grep -c '' <<<"$CLAIM_ALL" || true)
    CLAIM_LINES=$(head -n "$CLAIM_DISPLAY_CAP" <<<"$CLAIM_ALL")
fi

# First-call path: inject the review into stderr FIRST, then ack and exit 2.
#
# Inject-before-ack ordering matters: if anything interrupts between the two
# steps, the failure mode under inject-first is "review printed but no ack" →
# next call re-injects (harmless double-display). The reversed order would
# mean "ack written but no inject" → next call sees the ack and silently
# allows the merge without ever surfacing the review, which is the exact
# failure mode this gate exists to prevent.
#
# printf rather than heredoc: an unquoted heredoc terminates on a bare
# delimiter line in the body, so a review that contained `EOF` on its own
# line would silently truncate the injected content. printf has no such
# delimiter semantics — `%s` swallows whatever the variable holds.
RELEASE_DUE=0
if release_reminder_due; then RELEASE_DUE=1; fi
{
    printf '%s\n' "$RULE"
    printf 'PR MERGE GATE — latest %s review for PR #%s\n' "$REVIEW_LOGIN" "$PR_NUM"
    printf 'Posted: %s (updated %s)\n' "$REVIEW_CREATED" "$REVIEW_TS"
    printf '%s\n\n' "$RULE"
    printf '%s\n\n' "$REVIEW_BODY"
    printf '%s\n' "$RULE"
    printf 'This review'\''s content is now in your context.\n\n'
    printf '  - If the review is LGTM with no actionable items, retry the same merge\n'
    printf '    command — it will proceed (this comment-id is now acked).\n'
    printf '  - If the review surfaced a substantive finding (a review can differ from\n'
    printf '    what an earlier round saw), report it to the user and ask whether to\n'
    printf '    proceed, fix, or backlog.\n\n'
    printf 'RE-DERIVE THE NUMBERS: before retrying the merge, re-run the command behind\n'
    printf 'every count, ratio, and enumeration in the PR body and commit message and\n'
    printf 'fix what moved — self-reported numbers are written once at peak confidence\n'
    printf 'and never re-read, and reviewers have caught stale ones on most PRs that\n'
    printf 'carried them.\n\n'
    if [ "${CLAIM_HITS:-0}" -gt 0 ] 2>/dev/null; then
        if [ "$CLAIM_HITS" -gt "$CLAIM_DISPLAY_CAP" ]; then
            printf '⚠ CLAIM-SHAPED ADDED COMMENTS (showing first %s of %s).\n' \
                "$CLAIM_DISPLAY_CAP" "$CLAIM_HITS"
        else
            printf '⚠ CLAIM-SHAPED ADDED COMMENTS (%s line(s)).\n' "$CLAIM_HITS"
        fi
        printf '%s\n\n' "$CLAIM_LINES"
        printf 'Added comments asserting certainty, provenance, or counts are claims the\n'
        printf 're-derive step above cannot reach: it re-runs the numbers in the PR body\n'
        printf 'and commit message, not prose committed beside the code, which nothing\n'
        printf 'reads again. Before retrying the merge, verify each line above against\n'
        printf 'the code it describes — grep the assignment or call sites — or hedge it\n'
        printf 'in the comment itself. A permanent comment that a later reader falsifies\n'
        printf 'is the defect class this scan exists for.\n\n'
        printf 'Verify against the PR HEAD REF, not the working tree. This instruction\n'
        printf 'fires at merge time, when the shell is standing on whatever branch was\n'
        printf 'last checked out while the code these comments describe lives on the PR\n'
        printf 'branch — a working-tree grep has already answered with the pre-PR text\n'
        printf 'for a line this scan flagged. Read it off the ref instead:\n\n'
        printf '  git show origin/%s:<path>\n' "${PR_HEAD:-<pr-head-branch>}"
        printf '  git grep <pattern> origin/%s\n\n' "${PR_HEAD:-<pr-head-branch>}"
    fi
    if [ "${ORIGIN_HITS:-0}" -gt 0 ] 2>/dev/null; then
        printf '⚠ ORIGIN-LANGUAGE DETECTED (%s matching line(s)). This review scopes at\n' "$ORIGIN_HITS"
        printf 'least one finding as pre-existing / not-a-regression. Origin is NOT a\n'
        printf 'correctness verdict. Before retrying the merge, give each such finding a\n'
        printf 'merits disposition in your user-facing summary: fix now / backlog entry\n'
        printf 'with promote-when / correct-as-is WITH the technical reason. "Pre-existing"\n'
        printf 'may not be the operative reason.\n\n'
    fi
    if [ "$RELEASE_DUE" = 1 ]; then
        print_release_block
    fi
    printf 'Do NOT bypass this gate by editing the ack state. The gate'\''s purpose is to\n'
    printf 'ensure the latest review is in context at merge time — not an obstacle to\n'
    printf 'be routed around.\n'
    printf '%s\n' "$RULE"
} >&2

# Now write the ack. A FAULTED state path is refused above all else: the
# block has printed, the warning says the retry will block too, and nothing
# is written through the anomaly (fail closed).
if ! ack_state_usable; then
    printf 'WARNING: the merge-review ack state is unusable (%s) — this block\n' "$ACK_STATE_FAULT" >&2
    printf 'cannot be acked, so retries will keep blocking until the state path is fixed.\n' >&2
    printf 'Nothing was written through it.\n' >&2
    exit 2
fi
# Fail-CLOSED if the write itself fails (disk full, unwritable directory).
# Blocking here does not dead-end the agent: an allow would print the review
# to a stream nobody sees (stderr reaches the agent only on the BLOCKING
# path) and silently defeat the gate for as long as the fault lasts. The
# escape is the OWNER's, not the agent's: SYG_DISABLE is read from the
# session environment (settings/launch), so an inline prefix on the merge
# command reaches nothing — the agent's move is to report the fault.
if ! ack_append "$ACK_KEY"; then
    printf 'WARNING: pr-merge-review-check ack write failed (%s) — the merge stays blocked\n' "$STATE_FILE" >&2
    printf 'so this review is not lost to a stream nobody sees. Report the fault to the session\n' >&2
    printf 'owner: SYG_DISABLE=guards-pr disables this gate, but only from the SESSION\n' >&2
    printf 'environment (settings/launch) — not from this shell.\n' >&2
    exit 2
fi
# Ack the default-branch reminder too when it was just shown, so the retry
# after this review block (or a fresh review re-arming the gate) sees it
# already recorded. Best-effort (`|| true` before `exit 2`): this exit is
# already blocking for the review, so a failed reminder append here never
# adds another block (if the write fault persists on the acked-retry path,
# release_block_then_exit fails open and the retry's reminder banner is lost).
if [ "$RELEASE_DUE" = 1 ]; then
    ack_append "$RELEASE_KEY" || true
fi
chmod 600 "$STATE_FILE" 2>/dev/null || true

exit 2
