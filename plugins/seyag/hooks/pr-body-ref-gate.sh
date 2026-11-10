#!/bin/bash
# PreToolUse hook (matcher: Bash) — two rules over a PR-body write, plus
# `--check <body-file>` preflight mode.
#
# RULE 1 (unresolved tracker reference): blocks a PR-body write whose body
# claims a tracker reference ("filed as TASK-123", "closes doc-45") that does
# not resolve on ${SYG_PR_BODY_BASE_REF:-origin/main}.
#
# A PR body claiming a follow-up was "filed as TASK-N" over a task that was
# never committed is a false claim to every reader of that PR — `git
# ls-files`/`existsSync` cannot see an uncommitted tracker file from the PR's
# vantage point, and neither can the reviewer, another checkout, or the next
# session. Prose rules prescribing a `git ls-tree` verification check before
# writing a closing reference can be skipped; this hook moves the check to a
# deterministic trigger (`SYG_PR_BODY_RULE_REF` optionally cites the project's
# rule in the block banner).
#
# RULE 2 (claim-shaped body line): blocks — once per body text per UTC day —
# a PR-body write whose body carries a claim-shaped line
# (certainty/provenance/counted-noun vocabulary, or an uncited
# "verified"/"every caller"/closing reference) with no cite and no hedge. The
# shared vocabulary lives in the claim-shapes lib under this directory's lib/
# subfolder, sourced by this hook AND by pr-merge-review-check.sh — a change
# to that file changes both scans, and each hook's own probe is the test for
# its half. Rule 1 runs first and is a hard block (no ack, no retry-through);
# rule 2 runs only once rule 1 has not blocked, and acks per
# body-text-SHA-256-plus-UTC-date so an unchanged retry proceeds within the
# same day while a genuinely edited body — or the same body on a later day —
# is rescanned.
#
# Known false positive: rule 1 (only) scans the WHOLE Bash command string
# rather than a precisely-parsed body argument (see the KNOWN GAPS note
# below on why). A heredoc that merely CONTAINS `gh pr create --body "…"`
# prose therefore fires rule 1 too — deliberate, not widened. Rule 2 scans
# only the parsed PR body text (see extract_pr_body), never the command
# string, so a claim-shaped word sitting in --title or elsewhere in the
# command does not reach it; heredoc prose that writes out `gh pr create -b
# "…"` with no `--body` exits at the required-flag pre-check (data), while
# with `--body` in the prose it still matches extract_pr_body and blocks.
#
# Scope: `gh pr create`, `gh pr edit`, a command family registered via
# `SYG_PR_BODY_EXTRA_COMMANDS`, and a
# `gh api -X PATCH .../pulls/N -F body=@file` (or `-f body=<text>`) or
# `gh api .../pulls` POST invocation, each when carrying `--body`,
# `--body-file`, `-b`/`-F` (on `gh pr create|edit`), or a
# `-f/-F/--field/--raw-field body=` argument; plus direct `--check <body-file>`
# preflight.
# Rule 1's claim-verb spans ("filed as", "tracked in", "closes", "completes",
# and "finishes" allow up to 3 intervening tokens before the id; "close",
# "closed", "fix", "fixes", "fixed", "resolve", "resolves", and "resolved"
# require the id directly after the verb or optional colon) followed by a
# TASK-N or doc-N id are checked — a bare mention ("see TASK-99999 for
# background") makes no claim and is deliberately left alone.
#
# Fail-open throughout: a missing ${SYG_PR_BODY_BASE_REF} ref, a git error, an
# empty tracker/ listing, or an unsupported grep dialect all pass the command
# through rather than block it. A broken gate must never block a real PR.
# An unreadable --body-file is the one degraded case rather than a pass: the
# file's content is dropped from BODY_TEXT, rule 1's command-text scan still
# covers the rest of the command, and extract_pr_body's inline-value
# attempts still run for rule 2 (so an inline --body in the same command is
# still found even when a --body-file elsewhere is unreadable).
#
# KNOWN GAPS:
#   - Short flags `-b` and `-F` are covered on `gh pr create` and `gh pr edit`
#     (anchored to that simple command); registered extra command families
#     (`SYG_PR_BODY_EXTRA_COMMANDS`) require the long flags (`--body`,
#     `--body-file`) because their `-b` means something else.
#     `-f`/`--raw-field` carries a literal string, so `-f body=@x` is scanned
#     as the text `@x`; `-F`/`--field body=@x` reads the file at that path.
#   - Rule 1's scan covers the WHOLE command text, not a precisely-parsed
#     --body argument, so that the `--body "$(cat <<'EOF' … EOF)"` heredoc
#     form — the dominant shape — is covered without a shell
#     tokenizer. A reference sitting in `--title` is therefore also caught
#     by rule 1; that is a claim too, so it's deliberate rather than an
#     over-block to apologize for. Rule 2 does NOT share this gap — it never
#     sees the command text at all, only extract_pr_body's parsed output.
#   - A --body-file path that names no readable file without a shell is not
#     read: a `$(...)` or backtick in it, an unset or empty `$NAME` / `${NAME}`,
#     or a `$` kept literal by single quotes or backslash (`--body-file '$F'`,
#     `--body-file "\$F"`). Its FILE's
#     content goes unscanned (fail-open direction, same family as the
#     short-flag gap). Rule 1's command-text scan still covers the rest of the
#     command; an inline `--body` in the same command is separately picked up
#     by extract_pr_body's own inline-value parsing, so rule 2 still sees it.
#     Bare, "double-quoted" and 'single-quoted' paths without a `$` are read,
#     and bare or double-quoted `$NAME` / `${NAME}` expand from the hook's own
#     environment (the session's, not the live shell's): a variable set earlier
#     in the same command (`F=x; gh pr create --body-file "$F"`) is not seen,
#     and the session's value, if any, is used instead. A word that starts
#     bare stops at its first quote (`$D/"sub"/x.md` reads `$D/`), so a
#     wrapper's closing quote is never taken into the path; that word degrades.
#   - When `python3` is missing or fails, the hook itself still runs — only its
#     `python3` spawns degrade. `find_body_file_flag` falls back to a
#     `grep -obP` byte-offset scan across `--body-file` and `-F`, but ONLY
#     when the command contains none of `'`, `"`, `` ` ``, `#`, `\`, `<<` or `$(`
#     (nothing `masked_view` would mask), and `resolve_body_word` still needs
#     `python3` for any `$`, `\`, quote or `~/`. Outside that plain bare-word
#     domain, a `python3` failure yields no `--body-file` / `-F` body file
#     (`--body-file -` stdin bodies included); the `-F body=@path` form, the
#     substitution and inline-value ladders and rule 1's command-text scan
#     still run (fail-open direction, never a block), and the required-flag
#     pre-check falls back to its raw `CMD_JOINED` grep.
#   - The `--body-file` / `-F` search masks quoted spans, `#` comments and
#     heredoc bodies through shell_quotes.py, so a heredoc delimiter that lib
#     does not recognize leaves its body as command text, and a flag spelled
#     there can be read as the last one. An UNTERMINATED heredoc's body stays
#     command text the same way. A flag inside a `bash -c` / `eval`
#     string is searched only when the outer command has none.
#   - A whole-token QUOTED `-F body="@path"` is not recognized as a file
#     reference — the `@` matcher stops at the quote — so the literal text
#     `@path` is what gets scanned rather than the file's content (fail-open
#     direction, same family as the quoted --body-file gap above). Callers
#     never quote the whole `-F body=@path` token, so the gap is documented
#     rather than closed.
#   - A whole-token QUOTED field argument (`-f "body=…"`, and the same for
#     `-F` and `--field`) is not scanned by EITHER rule. The required-flag
#     check below matches `body=` only where it directly follows the flag's
#     whitespace; a leading quote sits there instead, so the check rejects
#     and the hook exits 0 before rule 1 or rule 2 runs. Pre-filter #1's
#     `body=` glob still admits the command — the flag check is what turns it
#     away. The miss has a SECOND layer behind that one: extract_pr_body's
#     inline-value patterns anchor on `body="` after the flag's whitespace
#     too, so widening only the flag check leaves BODY_TEXT empty and rule 2
#     with nothing to scan. Both were mutated to make the probe case below go
#     red, which is how the second layer was found. Probe: "whole-token-quoted
#     -f \"body=…\" is a documented fail-open miss", against the inline
#     `-f body="…"` control case immediately above it, which varies only where
#     the quote sits. Callers never write the whole-token quoted form, so
#     this is documented rather than closed, same fail-open family as the two
#     quoted-token bullets above.
#   - A PR body edited through the ISSUES endpoint (`gh api -X PATCH
#     .../issues/N -F body=…`, which GitHub accepts for a PR) is not
#     scanned: the PATCH shape is recognized by `pulls/N` only. Standard
#     conventions never edit a PR body that way.
#   - A PR number carried in a SHELL VARIABLE (`gh api -X PATCH
#     .../pulls/$N -f body=…`) is not scanned by either rule. The
#     IS_PATCH_PR_API check below anchors on `pulls/[0-9]+` against the raw
#     command text, which the hook never expands, so `pulls/$N` fails the
#     digit anchor, the PATCH family is not recognized, and a scripted
#     PR-body edit passes through unscanned (fail-open direction). Probe:
#     "shell-variable PR number is a documented fail-open miss", against the
#     same inline `-f body="…"` control case, which varies only the PR number
#     from a literal to `$N`. A command family registered via
#     SYG_PR_BODY_EXTRA_COMMANDS is matched by name and needs no `pulls/N`
#     at all.
#   - A RELATIVE --body-file path resolves against this hook's own cwd (it
#     inherits the harness's working directory; nothing cds on its behalf), not
#     the wrapped command's
#     cwd — `cd sub/dir && gh pr create --body-file ./x.md` therefore fails
#     the readability check, and only that FILE's content is lost; rule 1's
#     command text scan and extract_pr_body's inline-value attempts both
#     still run.
#   - `gh pr create --fill` sources the body from commit messages with no
#     --body flag at all, so the pre-filter passes it through unscanned.
#     Closing it would mean reconstructing the body from git log (or
#     blocking a legitimate flag); standard conventions avoid --fill, so the
#     gap is documented rather than closed.
#   - Rule 2's BLOCK — not its scan — fails open when `sha256sum` is missing
#     or yields an empty hash. The guard sits downstream of the
#     `flagged_count -eq 0` early return, so the scan has already run and
#     collected its flagged lines; what cannot be computed is the ack key
#     that scopes a block to one body text, and a shared empty key would ack
#     every body for the rest of the UTC day. Losing one write's worth of
#     blocking beats acking the whole day. Probe: "claim scan fails open when
#     sha256sum yields an empty hash" — that case covers the empty-hash half;
#     the missing-binary half is out of reach of the probe's PATH-PREPEND
#     technique, since a prepended directory cannot hide a binary from
#     `command -v` (replacing PATH outright could reach it). Both halves take
#     the same return, so the coverage is unaffected.
#   - Rule 1's whole-command scan also fires when PROSE in a non-PR command
#     merely mentions the PR-write families and flags — e.g.
#     `git commit -m "handle gh pr create --body; closes TASK-5"` hard-blocks
#     on an unresolved `TASK-5`. Deliberate breadth in the same family as the
#     heredoc-contains-text note in the header: anchoring `CMD_FAMILY_RE` at
#     a command start was ruled out because runner-prefixed real shapes
#     (`| xargs gh pr create`, `env … gh pr create`) would then fail open.
#   - A HERE-STRING (`gh pr create --body-file - <<< "…"`) is not read by
#     rule 2: `--body-file -` / `-F -` looks only for a `<<` heredoc, a
#     `< PATH` redirection after `-`, or `cat PATH |` before `gh`.
#   - Stdin fed from anything other than a heredoc, `< PATH` after `-`, or
#     `cat PATH |` before `gh` (e.g. `generate_body | gh pr create -F -`) is
#     not read by rule 2.
#   - A substitution on `--body`/`-b`/`body=` that is not a plain `cat PATH`
#     or `< PATH` with a literal unquoted path (e.g. `--body "$(cat "$F")"`)
#     is not read as a file by rule 2 and stays as literal text.
#   - A `;`, `&`, or `|` in a quoted URL, an earlier field value, or an
#     earlier argument (e.g. `--title "a | b"`) ends the simple command for
#     the `IS_POST_PR_API` check and for `extract_pr_body`'s `-b` patterns
#     (rule 2; the required-flag pre-check and `find_body_file_flag` read
#     `shell_quotes.masked_view`, so `-F` and rule 1 on `-b` are not cut off
#     unless `python3` is missing or fails).
#   - A backslash-newline line continuation before `-b` on the
#     `-b "$(cat <<'EOF' … EOF)"` heredoc form is not matched by the
#     TAG-aware heredoc capture (which reads `CMD` rather than `CMD_JOINED`
#     so a trailing backslash on a quoted-heredoc line cannot hide the
#     terminator, and keeps `GH_PR_CMD_PREFIX` free of nested
#     quantifiers); a heredoc body there that also carries an inner `"` falls
#     through to the `[^"]*` arm and truncates at that quote.
#   - A short-flag `gh pr create|edit -b/-F` inside a command string handed to
#     a program `shell_quotes.py` does not treat as a wrapper (`ssh` — e.g.
#     `ssh host "gh pr create --title t -b '…'"` — `su -c`, `sg … -c`,
#     `script -c`, `tmux new-session "…"`, `source <(echo …)`) is masked or
#     left as a non-gh argument in `masked_view` and `simple_commands`, so
#     `has_gh_pr_short_flag` rejects and each now exits 0 at the required-flag
#     pre-check before either rule runs (the old raw grep caught them;
#     fail-open direction; `--body` / `--body-file` in the same string still
#     match the raw long-flag check).
#   - A combined short-flag cluster (`-db "…"`, cobra's `-d -b`) is not
#     recognized as `-b` by the pre-check (fail-open).
#   - resolve_body_word reads two escapes differently from bash. Its tokenizer
#     splits a double-quoted piece at an escaped `\"` (`"d/a\"b\"c"` resolves
#     to `d/a\b\c`, bash reads `d/a"b"c`), and BODY_WORD_RE ends a bare word at
#     an escaped space (`dir/my\ file.md` reads as `dir/my\`). Both name a
#     nonexistent file in practice, so the body file goes unread (fail-open).
#   - A body FILE named inside a heredoc fed to a shell (`bash <<'E'` with
#     `gh pr create -F x.md` or `--body-file x.md` inside) is not read:
#     wrapped_command_strings does not yield shell-fed heredoc bodies, so
#     find_body_file_flag never searches them (an inline `-b "…"` there is
#     still caught by the pre-check's argv arm and the inline ladder).
#
#   The bullets above are misses. The bullets BELOW are deliberate
#   under-blocking — choices not to over-block. Append a new miss above this
#   line, not after it.
#
#   - CLAIM_CITE_EXEMPT_REGEX's backticked-span cite is broad on purpose: an
#     incidental backticked value containing a colon — a timestamp like
#     `4:30pm`, a ratio — sitting beside an uncited count on the same line
#     exempts that whole line, even though the backticked value cites
#     nothing. This is deliberate under-blocking: a retriable soft gate must
#     never over-block, and a false negative here costs nothing the reviewer
#     can't still catch, while a false positive costs a retry on every write.
#     Tighten only if false negatives show up in practice.
#   - Under an Acceptance heading, the closing-reference exemption is
#     LINE-scoped: the whole `closes TASK-N` line is exempt, including any
#     unrelated claim that happens to share that line. This is deliberate
#     under-blocking in the same direction as the backticked-span cite bullet
#     above — a retriable soft gate must never over-block. Narrow the
#     exemption to just the closing clause only if false negatives show up in
#     practice.
#   - A backticked command outside CLAIM_CITE_EXEMPT_REGEX's command
#     alternative, carrying no `/` or `:` of its own, does not count as a
#     cite. That alternative is the shared tooling vocabulary and grows on
#     demand — the cost of a miss is one retry.
#
# Fixture check: run plugins/seyag/hooks/pr-body-ref-gate.probe.sh after ANY edit.

set -uo pipefail

# A missing lib must fail OPEN, explicitly: without the guard the unbound
# regex would die inside a pipeline subshell and the scan would silently
# match nothing, which is the same outcome with a stderr trace attached.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib/claim-shapes.sh" || exit 0

# extract_pr_body: the SINGLE parser for "what is the PR body text", used by
# BOTH rules — rule 1 folds its output into SCAN_TEXT alongside the command
# text (unchanged from before this split); rule 2 scans ONLY this output,
# never the command text, so a claim-shaped word sitting in --title or
# elsewhere in the command cannot reach rule 2. Tries each supported flag
# shape in order of preference and sets the global BODY_TEXT. Signals a
# `grep -oP` dialect failure by RETURNING 3 rather than calling `exit`
# directly — `exit` inside a function invoked via command substitution would
# only kill a subshell, not the hook — and the caller turns a 3 into a
# top-level `exit 0`.
#
# Fail-open here means "extract what we can", NOT "abandon the check": an
# unreadable --body-file path or a quote-parsing miss on an inline value
# yields no text from THAT source and falls through to the next candidate
# source, rather than aborting the whole extraction. Probe: "prose
# --body-file mention still scans inline body" — rule 1's command-text half
# still catches that case regardless of what this function extracts.
#
# Known limitation: the inline-value patterns below do not handle an
# escaped quote embedded in the value (`--body "she said \"hi\""`) — the
# regex stops at the first literal quote character, the same imprecision as
# any non-tokenizing shell scan of --body text.
# Simple-command prefix anchoring `-b` and `-F` to the `gh … pr create|edit`
# simple command so an earlier command's `-F` (`git commit -F x && gh pr create --fill`)
# is not read as a PR body. The required-flag pre-check runs this prefix on
# `shell_quotes.masked_view` (matching `find_body_file_flag`'s `gh_span`, with
# a raw `CMD_JOINED` fallback when `python3` fails); `extract_pr_body`'s `-b`
# patterns still run it on raw `CMD` / `CMD_JOINED` and end the span at a
# quoted `;`/`&`/`|` (see the KNOWN GAPS bullet on a `;`, `&` or `|` in a
# quoted argument).
GH_PR_CMD_PREFIX='gh[^\n;&|]*\bpr[[:space:]]+(?:create|edit)\b[^\n;&|]*?[[:space:]]'
# One shell word as a --body-file / -F path (`\x27` is the single quote in PCRE
# and in Python's re, which find_body_file_flag compiles it with).
# A word that STARTS with a quote may run on through more quoted and bare
# pieces; a word that starts bare stops at its first quote, so a wrapper's
# closing quote (`bash -c "gh pr create --body-file x.md" ; echo "done"`) is
# never read as part of the path. A bare piece also stops at a shell
# metacharacter (`;&|()<>`), so `(... --body-file "x.md")`, `"x.md"|cat` and
# `"x.md";echo` name x.md.
BODY_WORD_RE='(?:(?:"[^"]*"|\x27[^\x27]*\x27)(?:[^\s\x27"&|;()<>]+|"[^"]*"|\x27[^\x27]*\x27)*|[^\s\x27"&|;()<>]+)'

read_body_path() {
  local resolved
  case "$1" in
    /*) resolved="$1" ;;
    *) resolved="$PWD/$1" ;;
  esac
  # A regular, readable file only: a directory (`--body-file .`) degrades, and
  # the inline ladder still runs.
  if [ -f "$resolved" ] && [ -r "$resolved" ]; then
    BODY_TEXT=$(cat "$resolved" 2>/dev/null)
    BODY_FROM_FILE=1
    return 0
  fi
  return 1
}

# resolve_body_word RAW: sets BODY_PATH to the path the shell word RAW names,
# or BODY_PATH_UNRESOLVED=1 when it names none this hook can read: an unset or
# empty $NAME / ${NAME}, a $(...) or backtick, or any `$` left after expansion
# (a single-quoted or backslash-escaped $ is literal, so it is left too). Bare
# and double-quoted text de-escapes backslash sequences and expands $NAME from
# THIS hook's environment (the session's, as the hook was started), never the
# live shell's; a leading bare `~/` is $HOME/, and only when $2 is 1 (a space,
# not `=`, came before the word, as the shell does it). Nothing is run through
# a shell. Not full bash fidelity: an escaped `\"` inside a double-quoted word
# and an escaped space in a bare word are misread (see the KNOWN GAPS bullet on
# resolve_body_word). A word with no `$`, `\`, quote or leading `~/` is its own
# path, so the common case never starts python.
resolve_body_word() {
  BODY_PATH="$1"
  BODY_PATH_UNRESOLVED=0
  case "$1" in
    *'$'* | *'\'* | *'"'* | *"'"* | \~/*) ;;
    *) return 0 ;;
  esac
  if BODY_PATH=$(python3 - "$1" "$2" <<'PYEOF' 2>/dev/null
import os
import re
import sys

raw = sys.argv[1]
tilde_ok = sys.argv[2] == "1"
pieces = re.findall(r"'[^']*'|\"[^\"]*\"|[^'\"]+", raw)
if "".join(pieces) != raw:
    sys.exit(1)
out = []
for index, piece in enumerate(pieces):
    if piece.startswith("'"):
        out.append(piece[1:-1])
        continue
    quoted = piece.startswith('"')
    text = piece[1:-1] if quoted else piece
    if index == 0 and not quoted and tilde_ok and text.startswith("~/"):
        text = "$HOME/" + text[2:]

    def value(match):
        if match.group(1) is not None:
            return match.group(1)
        name = match.group(2) or match.group(3)
        if name is None:
            return ""
        found = os.environ.get(name, "")
        if not found:
            raise LookupError
        return found

    # Single pass de-escapes \X (\ $ " ` in "", any char bare), drops \+newline, and expands $NAME/${NAME} so \$NAME stays literal.
    pattern = (
        r'\\([\\$"`])|\\\n|\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))'
        if quoted
        else r"\\([^\n])|\\\n|\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))"
    )
    try:
        text = re.sub(pattern, value, text)
    except LookupError:
        sys.exit(1)
    out.append(text)
path = "".join(out)
if not path or any(ch in path for ch in "$`"):
    sys.exit(1)
sys.stdout.write(path)
PYEOF
  ); then
    return 0
  fi
  BODY_PATH=""
  BODY_PATH_UNRESOLVED=1
}

# find_body_file_flag: sets the caller's body_file to the raw word of the body
# file gh reads, and BODY_TILDE_OK. `--body-file` and `-F` are ONE flag to gh
# (`gh pr create --help`: "-F, --body-file file"), so the LAST occurrence in
# command order wins across both spellings. Each spelling keeps its own scope:
# `--body-file` anywhere in the command (registered extra command families
# use it too), `-F` only after `pr create|edit` in a gh simple command (the
# GH_PR_CMD_PREFIX span) and only when IS_GH_PR_WRITE is 1. The search runs on
# shell_quotes.masked_view of the command: quoted spans, `#` comments and
# heredoc bodies are filled, so no flag is found in data, and the view is
# length-preserving, so the word is sliced from the command at the matched
# offset with its raw quoting intact for resolve_body_word. Command-text
# backslash-newlines read as a blank (CMD_JOINED's reading); one inside a
# heredoc body stays data. When the outer command has no flag at all, each
# `bash -c` / `eval` string (wrapped_command_strings, recursively) is searched
# the same way and the first with a flag wins. BODY_TILDE_OK becomes 1 only
# for a whitespace separator: the shell expands a leading `~/` after
# whitespace, never after `=`, and a word with no separator is not
# tilde-expanded either. When python3 is missing or exits nonzero, a command
# with none of `'`, `"`, `` ` ``, `#`, `\`, `<<` or `$(` falls back to a `grep -obP`
# byte-offset scan across both flags; anything else yields no body file, never
# a block.
find_body_file_flag() {
  local found rc hits hit offset best_offset best_match rest
  case "$CMD" in
    *--body-file*) ;;
    *-F*) [ "${IS_GH_PR_WRITE:-0}" -eq 1 ] || return 0 ;;
    *) return 0 ;;
  esac
  found=$(HOOK_LIB="$(dirname "${BASH_SOURCE[0]}")/lib" BODY_WORD_RE="$BODY_WORD_RE" \
    PYTHONDONTWRITEBYTECODE=1 python3 - "${IS_GH_PR_WRITE:-0}" 3<<<"$CMD" <<'PYEOF' 2>/dev/null
import os
import re
import sys

sys.path.insert(0, os.environ["HOOK_LIB"])
from shell_quotes import MASK_FILL, MAX_WRAPPER_DEPTH, masked_view, wrapped_command_strings

gh_write = sys.argv[1] == "1"
cmd = os.fsdecode(open(3, "rb").read()).removesuffix("\n")
# re.ASCII throughout: the grep -P searches this replaced were ASCII, so a
# Unicode blank (U+00A0) inside a path does not end the word here either.
word_re = re.compile(os.environ["BODY_WORD_RE"], re.ASCII)
# Line-bound separators, as the grep -oP line scans were; a command-text
# continuation is already two blanks in the view.
long_flag = re.compile(r"--body-file(=|[^\S\n]+)", re.ASCII)
# GH_PR_CMD_PREFIX's span, split so every -F after `pr create|edit` is found
# rather than the first.
gh_span = re.compile(r"gh[^\n;&|]*\bpr[^\S\n]+(?:create|edit)\b([^\n;&|]*)", re.ASCII)
short_flag = re.compile(r"(?<=\s)-F(=|[^\S\n]*)", re.ASCII)


def search(text):
    view = masked_view(text, join_continuations=True)
    joined = "".join(t if v == MASK_FILL else v for v, t in zip(view, text))
    hits = [(m.start(), m.end(), m.group(1)) for m in long_flag.finditer(view)]
    if gh_write:
        for span in gh_span.finditer(view):
            hits.extend(
                (m.start(), m.end(), m.group(1))
                for m in short_flag.finditer(view, span.start(1), span.end(1))
            )
    best = None
    for start, end, sep in hits:
        word = word_re.match(joined, end)
        if word and (best is None or start > best[0]):
            best = (start, "1" if sep[:1] not in ("", "=") else "0", word.group(0))
    return best


def find(text, depth):
    best = search(text)
    if best is None and depth < MAX_WRAPPER_DEPTH:
        for inner in wrapped_command_strings(text):
            best = find(inner, depth + 1)
            if best is not None:
                break
    return best


best = find(cmd, 0)
if best is not None:
    sys.stdout.write(best[1] + best[2])
PYEOF
  )
  rc=$?
  if [ "$rc" -eq 0 ]; then
    [ -n "$found" ] || return 0
    BODY_TILDE_OK="${found:0:1}"
    body_file="${found:1}"
    return 0
  fi
  case "$CMD" in
    *"'"* | *'"'* | *"\`"* | *'#'* | *'\'* | *'<<'* | *"\$("* ) return 0 ;;
  esac
  hits=$(printf '%s' "$CMD" | grep -obP -- '--body-file(?:=|[[:blank:]]+)[^\s&|;()<>]+' 2>/dev/null || true)
  if [ "${IS_GH_PR_WRITE:-0}" -eq 1 ]; then
    # Greedy `(?:[^\n;&|]*[[:space:]])?` lands `\K` on the last `-F` in each
    # GH_PR_CMD_PREFIX span, which has the greatest byte offset in that span.
    hits="$hits
$(printf '%s' "$CMD" | grep -obP -- "${GH_PR_CMD_PREFIX}(?:[^\n;&|]*[[:space:]])?\K-F(?:=|[[:blank:]]*)[^\s&|;()<>]+" 2>/dev/null || true)"
  fi
  best_offset=-1
  best_match=""
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    offset="${hit%%:*}"
    if [ "$offset" -gt "$best_offset" ]; then
      best_offset="$offset"
      best_match="${hit#*:}"
    fi
  done <<<"$hits"
  [ -n "$best_match" ] || return 0
  case "$best_match" in
    --body-file*) rest="${best_match#--body-file}" ;;
    -F*) rest="${best_match#-F}" ;;
    *) return 0 ;;
  esac
  case "$rest" in
    =*)
      BODY_TILDE_OK=0
      body_file="${rest#=}"
      ;;
    [[:blank:]]*)
      BODY_TILDE_OK=1
      body_file="${rest#"${rest%%[![:blank:]]*}"}"
      ;;
    *)
      BODY_TILDE_OK=0
      body_file="$rest"
      ;;
  esac
}

# has_gh_pr_short_flag: tests `${GH_PR_CMD_PREFIX}-(b|F)` on
# shell_quotes.masked_view(..., join_continuations=True) of the command (and
# any wrapped_command_strings, matching find_body_file_flag), or matches any
# shell_quotes.simple_commands argv (after unwrap_runners strips runner and
# VAR=val env prefixes) whose program word is `gh` / `*/gh` with `pr` and
# `create|edit` (allowing gh global flags between) and a later `-b*` or `-F*`
# word (skipping a value-taking flag's value, so a QUOTED title value that
# starts with `-F` / `-b` is not a flag; a bare one still reaches the masked
# grep; shell-fed heredoc bodies count while prose heredocs stay data), falling
# back to raw CMD_JOINED when python3 is missing or exits nonzero.
has_gh_pr_short_flag() {
  local masked rc
  case "$CMD" in
    *[[:space:]]-b* | *[[:space:]]-F*) ;;
    *) return 1 ;;
  esac
  masked=$(HOOK_LIB="$(dirname "${BASH_SOURCE[0]}")/lib" \
    PYTHONDONTWRITEBYTECODE=1 python3 - 3<<<"$CMD" <<'PYEOF' 2>/dev/null
import os
import sys

sys.path.insert(0, os.environ["HOOK_LIB"])
from shell_quotes import (
    MAX_WRAPPER_DEPTH,
    masked_view,
    simple_commands,
    unwrap_runners,
    wrapped_command_strings,
)

cmd = os.fsdecode(open(3, "rb").read()).removesuffix("\n")

VALUE_FLAGS = frozenset((
    "-a", "--assignee", "--attach", "-B", "--base", "-H", "--head",
    "-l", "--label", "-m", "--milestone", "-p", "--project", "--recover",
    "-r", "--reviewer", "-T", "--template", "-t", "--title", "-R", "--repo",
    "--add-assignee", "--add-label", "--add-project", "--add-reviewer",
    "--remove-assignee", "--remove-label", "--remove-project", "--remove-reviewer",
))


def emit(text, depth):
    sys.stdout.write(masked_view(text, join_continuations=True) + "\n")
    if depth < MAX_WRAPPER_DEPTH:
        for inner in wrapped_command_strings(text):
            emit(inner, depth + 1)


def argv_has_short_flag(argv):
    argv, _ = unwrap_runners(argv)
    if not argv or not (argv[0] == "gh" or argv[0].endswith("/gh")):
        return False
    for i in range(1, len(argv) - 1):
        if argv[i] == "pr" and argv[i + 1] in ("create", "edit"):
            j = i + 2
            while j < len(argv):
                w = argv[j]
                if w in VALUE_FLAGS:
                    j += 2
                    continue
                if w.startswith(("-b", "-F")) and not w.startswith("--"):
                    return True
                j += 1
    return False


emit(cmd, 0)
if any(argv_has_short_flag(argv) for argv in simple_commands(cmd)):
    sys.stdout.write("gh pr create -b\n")
PYEOF
  )
  rc=$?
  if [ "$rc" -ne 0 ]; then
    masked="$CMD_JOINED"
  fi
  printf '%s' "$masked" | grep -P -- "${GH_PR_CMD_PREFIX}-(b|F)" >/dev/null 2>&1
}

extract_pr_body() {
  BODY_TEXT=""
  BODY_FROM_FILE=0
  BODY_PATH_UNRESOLVED=0
  local body_file rc body sub_file
  BODY_TILDE_OK=0
  body_file=""
  find_body_file_flag
  # The matched word names a file through its quotes and $NAMEs. An
  # unresolvable word keeps its raw text (so the fallbacks below stay skipped,
  # as an unreadable path always has) and sets BODY_PATH_UNRESOLVED, which
  # keeps read_body_path from being tried.
  if [ -n "$body_file" ]; then
    resolve_body_word "$body_file" "$BODY_TILDE_OK"
    [ "$BODY_PATH_UNRESOLVED" -eq 1 ] || body_file="$BODY_PATH"
  fi
  # --body-file - / -F - reads from stdin: look in order for gh's own heredoc
  # body (inline, BODY_FROM_FILE stays 0), then `< PATH` after `-`, then
  # `cat PATH |` before `gh`.
  if [ "$body_file" = "-" ]; then
    # Raw text first: a joined body could hide its terminator. The joined text
    # then finds an opener on a continuation line of the gh command.
    body=""
    for stdin_text in "$CMD" "$CMD_JOINED"; do
      [ -z "$body" ] || break
      body=$(printf '%s' "$stdin_text" | grep -zoP -- '(?m)^(?=[^\n]*\bgh\b[^\n;&|]*\b(?:pr[ \t]+(?:create|edit)|api)\b[^\n;&|]*?(?:--body-file[= ]+|-F(?:=|[ \t]*))-(?:[ \t]|$))[^\n]*?(?<!<)<<(?!<)-?[ \t]*[\x27"]?(\w+)[\x27"]?[^\n]*\n\K(?s:.*?)(?=\n\t*\1(?:\n|$))' | head -zn1 | tr -d '\0')
    done
    if [ -n "$body" ]; then
      BODY_TEXT="$body"
      return 0
    fi
    body_file=$(printf '%s' "$CMD_JOINED" | grep -oP -- '\bgh\b[^\n;&|]*\b(?:pr[[:space:]]+(?:create|edit)|api)\b[^\n;&|]*?(?:--body-file[= ]+|-F(?:=|[[:space:]]*))-[^\n;&|<>]*?(?<!<)<(?!<)[[:space:]]*\K[^\s'"'"'"<>|$()]+')
    rc=$?
    if [ "$rc" -gt 1 ]; then
      return 3
    fi
    if [ -z "$body_file" ]; then
      body_file=$(printf '%s' "$CMD_JOINED" | grep -oP -- '\bcat[[:space:]]+\K[^\s'"'"'"<>|$()]+(?=[ \t]*\|[^\n;&|]*\bgh\b[^\n;&|]*\b(?:pr[[:space:]]+(?:create|edit)|api)\b[^\n;&|]*?(?:--body-file[= ]+|-F(?:=|[[:space:]]*))-(?:[[:space:];&|<>]|$))')
      rc=$?
      if [ "$rc" -gt 1 ]; then
        return 3
      fi
    fi
  fi
  # -F body=@<path> / --field body=@<path> (the PATCH/POST form's file shape).
  # `-f`/`--raw-field` sends its value as a LITERAL STRING (gh api --help:
  # "-f, --raw-field key=value  Add a string parameter in key=value format"),
  # so `-f body=@x` is inline text rather than a file reference — that shape
  # is handled by the inline ladder below, never here.
  if [ -z "$body_file" ]; then
    body_file=$(printf '%s' "$CMD" | grep -oP -- '(-F|--field)[[:space:]]+body=@\K[^\s'"'"'"]+')
    rc=$?
    if [ "$rc" -gt 1 ]; then
      return 3
    fi
  fi
  if [ -n "$body_file" ] && [ "$BODY_PATH_UNRESOLVED" -eq 0 ] && read_body_path "$body_file"; then
    return 0
  fi

  # Command-substitution file forms (`--body "$(cat PATH)"`, `--body="$(cat PATH)"`,
  # `--body "$(< PATH)"`, and the same with `-b` and `-f|-F|--field|--raw-field body=`):
  # tried before the inline ladder so a readable literal PATH is read from disk,
  # while anything with whitespace, quotes, `$`, parens, or angle brackets falls
  # through to stay as text.
  sub_file=$(printf '%s' "$CMD" | grep -oP -- '(?:--body(?:=|[[:space:]]+)|(?:-f|-F|--field|--raw-field)[[:space:]]+body=)"\$\((?:cat[[:space:]]+|<[[:space:]]*)\K[^\s'"'"'"$()<>]+(?=[[:space:]]*\)\")')
  rc=$?
  if [ "$rc" -gt 1 ]; then
    return 3
  fi
  if [ -z "$sub_file" ] && [ "${IS_GH_PR_WRITE:-0}" -eq 1 ]; then
    sub_file=$(printf '%s' "$CMD_JOINED" | grep -oP -- "${GH_PR_CMD_PREFIX}"'-b(?:=|[[:space:]]*)"\$\((?:cat[[:space:]]+|<[[:space:]]*)\K[^\s'"'"'"$()<>]+(?=[[:space:]]*\)\")')
    rc=$?
    if [ "$rc" -gt 1 ]; then
      return 3
    fi
  fi
  if [ -n "$sub_file" ] && read_body_path "$sub_file"; then
    return 0
  fi

  # Inline forms, most-specific (quoted) first so a quoted value's own
  # spaces aren't truncated by the bare-value pattern below. `-z` puts PCRE
  # in NUL-record mode so `[^"]*` / `[^']*` span newlines across multi-line
  # inline values and `--body "$(cat <<'EOF' … EOF)"` heredocs; `head -zn1`
  # takes the first NUL-terminated match record and `tr -d '\0'` strips the
  # NUL terminator before command substitution.
  #
  # Heredoc form (`--body "$(cat <<'EOF' … EOF)"`, quoted or unquoted TAG,
  # `--body`, `-b`, and `(-f|-F|--field|--raw-field) body=` alike): tried BEFORE
  # the plain `[^"]*` ladder below because a literal `"` inside a heredoc is
  # ordinary body text and would truncate a `[^"]*` capture at that first quote.
  # `\K` after the opener's newline and a lookahead on the `\1` terminator line
  # capture only the body lines themselves; non-matching commands fall through.
  # shellcheck disable=SC2016
  body=$(printf '%s' "$CMD" | grep -zoP -- '(?:--body(?:=|[[:space:]]+)|(?:-f|-F|--field|--raw-field)[[:space:]]+body=|'"${GH_PR_CMD_PREFIX}"'-b(?:=|[[:space:]]*))"\$\(cat[[:space:]]*<<-?[ \t]*[\x27"]?(\w+)[\x27"]?[ \t]*\n\K(?s:.*?)(?=\n\1(?:\n|\)|$))' | head -zn1 | tr -d '\0')
  if [ -n "$body" ]; then BODY_TEXT="$body"; return 0; fi
  body=$(printf '%s' "$CMD" | grep -zoP -- '--body="\K[^"]*' | head -zn1 | tr -d '\0')
  if [ -n "$body" ]; then BODY_TEXT="$body"; return 0; fi
  body=$(printf '%s' "$CMD" | grep -zoP -- "--body='\K[^']*" | head -zn1 | tr -d '\0')
  if [ -n "$body" ]; then BODY_TEXT="$body"; return 0; fi
  body=$(printf '%s' "$CMD" | grep -zoP -- '--body[[:space:]]+"\K[^"]*' | head -zn1 | tr -d '\0')
  if [ -n "$body" ]; then BODY_TEXT="$body"; return 0; fi
  body=$(printf '%s' "$CMD" | grep -zoP -- "--body[[:space:]]+'\K[^']*" | head -zn1 | tr -d '\0')
  if [ -n "$body" ]; then BODY_TEXT="$body"; return 0; fi
  body=$(printf '%s' "$CMD" | grep -zoP -- '--body=\K[^[:space:]]+' | head -zn1 | tr -d '\0')
  if [ -n "$body" ]; then BODY_TEXT="$body"; return 0; fi
  body=$(printf '%s' "$CMD" | grep -zoP -- '--body[[:space:]]+\K[^[:space:]"'"'"']\S*' | head -zn1 | tr -d '\0')
  if [ -n "$body" ]; then BODY_TEXT="$body"; return 0; fi

  if [ "${IS_GH_PR_WRITE:-0}" -eq 1 ]; then
    body=$(printf '%s' "$CMD_JOINED" | grep -zoP -- "${GH_PR_CMD_PREFIX}"'-b(?:=|[[:space:]]*)"\K[^"]*' | head -zn1 | tr -d '\0')
    if [ -n "$body" ]; then BODY_TEXT="$body"; return 0; fi
    body=$(printf '%s' "$CMD_JOINED" | grep -zoP -- "${GH_PR_CMD_PREFIX}-b(?:=|[[:space:]]*)'\K[^']*" | head -zn1 | tr -d '\0')
    if [ -n "$body" ]; then BODY_TEXT="$body"; return 0; fi
    body=$(printf '%s' "$CMD_JOINED" | grep -zoP -- "${GH_PR_CMD_PREFIX}"'-b=\K[^[:space:]]+' | head -zn1 | tr -d '\0')
    if [ -n "$body" ]; then BODY_TEXT="$body"; return 0; fi
    body=$(printf '%s' "$CMD_JOINED" | grep -zoP -- "${GH_PR_CMD_PREFIX}"'-b[[:space:]]+\K[^[:space:]"'"'"']\S*' | head -zn1 | tr -d '\0')
    if [ -n "$body" ]; then BODY_TEXT="$body"; return 0; fi
  fi

  # -f body=<text> / -F body=<text> / --field body=<text> / --raw-field body=<text> —
  # inline string field on the PATCH/POST form. `-f`/`--raw-field` always sends
  # a literal string. `-F`/`--field` sends a literal string too UNLESS the value
  # starts with `@`, in which case gh reads it as a file path — that shape
  # is handled above, before this ladder, so a `-F body=@path` command never
  # reaches here. Quoted forms come first so a quoted value's own spaces
  # survive.
  body=$(printf '%s' "$CMD" | grep -zoP -- '(-f|-F|--field|--raw-field)[[:space:]]+body="\K[^"]*' | head -zn1 | tr -d '\0')
  if [ -n "$body" ]; then BODY_TEXT="$body"; return 0; fi
  body=$(printf '%s' "$CMD" | grep -zoP -- "(-f|-F|--field|--raw-field)[[:space:]]+body='\K[^']*" | head -zn1 | tr -d '\0')
  if [ -n "$body" ]; then BODY_TEXT="$body"; return 0; fi
  body=$(printf '%s' "$CMD" | grep -zoP -- '(-f|-F|--field|--raw-field)[[:space:]]+body=\K\S+' | head -zn1 | tr -d '\0')
  if [ -n "$body" ]; then BODY_TEXT="$body"; return 0; fi

  return 0
}

CHECK_MODE=0
if [ "$#" -gt 0 ]; then
  if [ "$1" != "--check" ] || [ "$#" -ne 2 ] || [ -z "${2:-}" ]; then
    echo "Usage: pr-body-ref-gate.sh [--check <body-file>]" >&2
    exit 1
  fi
  if [ ! -f "$2" ] || [ ! -r "$2" ]; then
    echo "pr-body-ref-gate: cannot read file: $2" >&2
    exit 1
  fi
  CHECK_MODE=1
  BODY_TEXT=$(cat "$2" 2>/dev/null) || {
    echo "pr-body-ref-gate: cannot read file: $2" >&2
    exit 1
  }
  SCAN_TEXT="$BODY_TEXT"
else
  INPUT=$(cat)

  # Raw pre-filter #1, before any jq fork: this runs on every Bash call, so the
  # cheapest possible reject dominates. CLI flags have no case variance, so a
  # case-sensitive glob here is not a hole (unlike the nocasematch situation a
  # command-word pre-filter has to account for with `git commit`/`gh pr` prose).
  # `body=` widens this to the `gh api -F body=@file` / `-f body=<text>`
  # shapes, which never write literal `--body`; `pr create` and `pr edit`
  # admit short-flag (`-b`/`-F`) PR writes, and those commands are rare so
  # nothing is added for an ordinary Bash call.
  case "$INPUT" in
    *"--body"* | *"body="* | *"pr create"* | *"pr edit"*) ;;
    *) exit 0 ;;
  esac

  # Raw pre-filter #2: narrow to the PR-write command families before paying
  # for jq when no extra command family ERE is configured. The PATCH/POST shapes
  # always carry the literal `gh api`, so the cheap glob narrows on that;
  # the later `gh api` checks below do the real narrowing.
  EXTRA_COMMANDS="${SYG_PR_BODY_EXTRA_COMMANDS:-}"
  if [ -z "$EXTRA_COMMANDS" ]; then
    case "$INPUT" in
      *"pr create"* | *"pr edit"* | *"gh api"*) ;;
      *) exit 0 ;;
    esac
  fi

  TOOL_NAME=$(jq -r '.tool_name // empty' <<<"$INPUT" 2>/dev/null || echo "")
  [ "$TOOL_NAME" != "Bash" ] && exit 0

  CMD=$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null || echo "")
  [ -z "$CMD" ] && exit 0
  CMD_JOINED="${CMD//\\$'\n'/ }"

  # Command-family check on the decoded command, case-insensitively. The `gh …`
  # alternative allows global flags between `gh` and `pr`, because adjacency-only
  # spellings miss `gh --repo owner/name pr create`. The PATCH alternative is
  # checked as ANDed greps and the POST alternative uses lookaheads within one
  # simple command, so the method, path, and field tokens can appear in any order.
  IS_PATCH_PR_API=0
  if printf '%s' "$CMD" | grep -iE 'gh[[:space:]]+api' >/dev/null &&
    printf '%s' "$CMD" | grep -iE -- '(-X|--method)[[:space:]=]*PATCH' >/dev/null &&
    printf '%s' "$CMD" | grep -iE 'pulls/[0-9]+' >/dev/null; then
    IS_PATCH_PR_API=1
  fi
  IS_POST_PR_API=0
  if printf '%s' "$CMD_JOINED" | grep -iP -- '\bgh[[:space:]]+api\b(?=[^\n;&|]*\bpulls(?:[[:space:]"\x27?]|$))(?=[^\n;&|]*(?:-f|-F|--field|--raw-field)[[:space:]]+body=)(?![^\n;&|]*(?:-X|--method)[[:space:]=]*GET\b)' >/dev/null 2>&1; then
    IS_POST_PR_API=1
  fi
  BASE_CMD_FAMILY_RE='gh([[:space:]]+[^[:space:]]+)*[[:space:]]+pr[[:space:]]+(create|edit)'
  IS_GH_PR_WRITE=0
  if printf '%s' "$CMD" | grep -iE "$BASE_CMD_FAMILY_RE" >/dev/null; then
    IS_GH_PR_WRITE=1
  fi
  CMD_FAMILY_RE="$BASE_CMD_FAMILY_RE"
  if [ -n "$EXTRA_COMMANDS" ]; then
    CMD_FAMILY_RE="($CMD_FAMILY_RE)|($EXTRA_COMMANDS)"
  fi
  if [ "$IS_GH_PR_WRITE" -ne 1 ] &&
    ! printf '%s' "$CMD" | grep -iE "$CMD_FAMILY_RE" >/dev/null &&
    [ "$IS_PATCH_PR_API" -ne 1 ] &&
    [ "$IS_POST_PR_API" -ne 1 ]; then
    exit 0
  fi

  # Require --body/--body-file, or (for the PATCH/POST forms) a
  # -f/-F/--field|--raw-field body= argument, or (when IS_GH_PR_WRITE=1) a
  # -b/-F token in the same simple command after `pr create|edit`, on the
  # decoded command.
  if ! printf '%s' "$CMD" | grep -E -- '--body(-file)?\b|(-f|-F|--field|--raw-field)[[:space:]]+body=' >/dev/null &&
    ! { [ "$IS_GH_PR_WRITE" -eq 1 ] && has_gh_pr_short_flag; }; then
    exit 0
  fi

  extract_pr_body
  EXTRACT_RC=$?
  if [ "$EXTRACT_RC" -eq 3 ]; then
    exit 0
  fi

  SCAN_TEXT="$CMD"
  # An INLINE body is already present verbatim in the command text, so
  # appending the extracted copy would scan it twice; only a body read from a
  # FILE adds text the command string does not already carry.
  if [ "$BODY_FROM_FILE" -eq 1 ] && [ -n "$BODY_TEXT" ]; then
    SCAN_TEXT="$SCAN_TEXT
$BODY_TEXT"
  fi
fi

# Rule 1 (unresolved tracker reference), wrapped as a function so rule 2 can
# run whenever rule 1 does NOT block — including every fail-open path below
# (no ids found, no ${SYG_PR_BODY_BASE_REF}, empty listings) — rather than only
# on the narrow all-refs-resolved path. Returns 2 (and prints the block) or 0.
run_ref_check() {
# Claim-verb spans only — a bare mention makes no claim. Intervening tokens
# are restricted to horizontal whitespace ON PURPOSE: the pattern must not
# span a newline, which keeps this conservative (a claim verb on one line and
# an unrelated id on a later line never matches).
#
# Both alternations carry a negative lookbehind so a longer or hyphenated word
# ending in a verb or an id does not match: `(?<![A-Za-z-])` keeps
# `discloses`/`encloses`/`pre-fix` from matching a closing verb, and keeps
# `SUBTASK-100` and `asciidoc-12` from matching an id. The `-` in the class is
# what rejects a hyphenated prefix token (`pre-fix`, `SUB-TASK-100`). The id
# lookbehind sits AFTER the `[\x60*_(\[]*` wrapper class, so a backticked or
# bracketed id still matches — the wrapper char, not a letter, is what precedes
# the id. grep runs this with -i; probed, the lookbehinds are not widened by it.
#
# The trailing `(…)*` chain picks up a comma/`and`-separated RUN of ids after
# one verb. Without it the `{0,3}` window capped a span at ~4 ids and the
# fifth was never extracted — a fail-open under-check. The chain uses only
# horizontal whitespace, preserving the no-newline invariant above.
# The optional `:?` after the verb covers GitHub's `Closes: TASK-N` colon
# convention — probed unmatched without it.
# Probes: "discloses", "SUBTASK", backticked-id, five-chained-ids, and
# colon-after-verb cases.
REF_PATTERN='(?<![A-Za-z-])(?:(?:filed as|tracked in|closes|completes|finishes):?(?:[ \t]+[^ \t]+){0,3}|(?:close[d]?|fix(?:es|ed)?|resolve[sd]?):?)[ \t]+[\x60*_(\[]*(?<![A-Za-z-])(TASK-[0-9]+|doc-[0-9]+)([\x60*_)\]]*[ \t]*[,;]?[ \t]*(and[ \t]+)?[\x60*_(\[]*(?<![A-Za-z-])(TASK-[0-9]+|doc-[0-9]+))*'
REF_SPANS=$(printf '%s' "$SCAN_TEXT" | grep -oPi "$REF_PATTERN")
RC=$?
if [ "$RC" -gt 1 ]; then
  return 0
fi
if [ "$RC" -eq 1 ]; then
  return 0
fi

IDS=$(printf '%s\n' "$REF_SPANS" | grep -oPi '(?<![A-Za-z-])(TASK-[0-9]+|doc-[0-9]+)' | tr '[:upper:]' '[:lower:]' | sort -u)
# `set -o pipefail` (top of file) is what makes this RC carry a mid-pipeline
# grep failure rather than sort's status — probed: a PCRE error propagates
# as 2 through tr|sort under pipefail. Removing pipefail would silently turn
# this into a sort-only check; the [ -z "$IDS" ] below is the backstop.
RC=$?
if [ "$RC" -gt 1 ]; then
  return 0
fi
[ -z "$IDS" ] && return 0

local base_ref="${SYG_PR_BODY_BASE_REF:-origin/main}"
local task_paths="${SYG_PR_BODY_TASK_PATHS:-tracker/tasks tracker/archive/tasks}"
local doc_paths="${SYG_PR_BODY_DOC_PATHS:-tracker/docs tracker/archive/docs}"
local rule_ref="${SYG_PR_BODY_RULE_REF:-}"
local -a task_path_arr=() doc_path_arr=()
read -r -a task_path_arr <<<"$task_paths"
read -r -a doc_path_arr <<<"$doc_paths"

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
git -C "$ROOT" rev-parse --verify --quiet "$base_ref" >/dev/null 2>&1 || return 0

TASK_LIST=""
if [ "${#task_path_arr[@]}" -gt 0 ]; then
  TASK_LIST=$(git -C "$ROOT" ls-tree -r --name-only "$base_ref" -- "${task_path_arr[@]}" 2>/dev/null) || return 0
fi
DOC_LIST=""
if [ "${#doc_path_arr[@]}" -gt 0 ]; then
  DOC_LIST=$(git -C "$ROOT" ls-tree -r --name-only "$base_ref" -- "${doc_path_arr[@]}" 2>/dev/null) || return 0
fi

# Empty listing fail-open, per-kind: an empty listing is an infrastructure
# signal (no tracker dir on that ref, a shallow clone), never evidence that a
# specific id is missing. Ids of an empty-listing kind are SKIPPED rather than
# the whole check abandoned, so the other kind still resolves against its own
# populated listing.
MISSING=""
while IFS= read -r id; do
  [ -z "$id" ] && continue
  case "$id" in
    task-*)
      [ -z "$TASK_LIST" ] && continue
      # `-q` is exactly the wrong flag under `set -o pipefail` when the
      # producer can outlive the consumer. The listing runs past the 64 KB
      # pipe buffer, so `grep -q` exits on a match while `printf` still has
      # bytes to write; `printf` dies of SIGPIPE (141), pipefail reports the
      # pipeline as failed even though the id MATCHED, and a perfectly
      # resolvable id lands in MISSING and blocks a correct body. It favours
      # ids that sort EARLY, since a late match lets `printf` finish first.
      # Letting grep DRAIN its input instead makes the status grep's alone;
      # the cost is one full read of a ~100 KB listing, nothing next to the
      # `git ls-tree` that produced it. Pinned by the probe's large-listing
      # pass case, whose fixture is sized so the `-q` form fails every run.
      # Every pipe-fed grep in this file is drained for the same reason, the
      # body and command producers included.
      printf '%s\n' "$TASK_LIST" | grep -iE -- "/${id}([^0-9]|$)" >/dev/null && continue
      ;;
    doc-*)
      [ -z "$DOC_LIST" ] && continue
      printf '%s\n' "$DOC_LIST" | grep -iE -- "/${id}([^0-9]|$)" >/dev/null && continue
      ;;
    *)
      continue
      ;;
  esac
  MISSING="$MISSING$id
"
done <<<"$IDS"

[ -z "$MISSING" ] && return 0

{
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "PR BODY REF GATE — unresolved tracker reference(s)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "This PR body claims one or more tracker references that do not"
  echo "resolve on $base_ref:"
  printf '%s' "$MISSING"
  echo
  echo "These do not resolve on $base_ref. A tracker file that exists"
  echo "only in the working tree does not exist from the reviewer's"
  echo "vantage point — not \`git log\`, not another checkout, not the next"
  echo "session."
  echo
  echo "Verify (one command per unresolved id):"
  while IFS= read -r miss; do
    [ -z "$miss" ] && continue
    case "$miss" in
      task-*) VERIFY_DIR="${task_path_arr[0]:-tracker/tasks}" ;;
      *) VERIFY_DIR="${doc_path_arr[0]:-tracker/docs}" ;;
    esac
    printf "  git ls-tree -r --name-only %s -- %s/ | grep -E '/%s([^0-9]|$)'\n" "$base_ref" "${VERIFY_DIR%/}" "$miss"
  done <<<"$MISSING"
  echo
  echo "Fix: commit and push the tracker file to $base_ref first, or correct"
  echo "the reference."
  echo
  if [ -n "$rule_ref" ]; then
    printf 'Per %s\n' "$rule_ref"
  fi
  if [ "$CHECK_MODE" -eq 0 ]; then
    printf 'Preflight: bash %s --check <body-file> before composing the command.\n' "${BASH_SOURCE[0]}"
  fi
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
} >&2
return 2
}

# Drops lines inside triple-backtick / `~~~` fences, printing everything
# else through unchanged. Shared by both passes below so the fence
# toggle-state machine exists exactly once — a fence-opening/closing line
# itself toggles the state and is dropped, never printed.
strip_fenced_lines() {
  local fence_open=0
  local fence_line
  # `|| [ -n "$fence_line" ]` keeps a final line with no trailing newline —
  # BODY_TEXT is piped in via `printf '%s'`, not a here-string, so it lacks
  # the newline `<<<` would otherwise append; without this, `read` fails on
  # that last partial line and the loop body never runs for it, silently
  # dropping a single-line (or last-line) body.
  while IFS= read -r fence_line || [ -n "$fence_line" ]; do
    # A fence indented under a list item still toggles the fence state, so
    # the leading-whitespace-stripped line — not the raw line — is what gets
    # matched against the fence markers.
    local stripped
    stripped=${fence_line#"${fence_line%%[![:space:]]*}"}
    case "$stripped" in
      '```'* | '~~~'*)
        if [ "$fence_open" -eq 0 ]; then fence_open=1; else fence_open=0; fi
        continue
        ;;
    esac
    [ "$fence_open" -eq 1 ] && continue
    printf '%s\n' "$fence_line"
  done
}

# Rule 2 (claim-shaped body line, blocked once per body text per UTC day in
# gate mode; `SYG_PR_BODY_CLAIM_SCAN=0` disables it while keeping rule 1).
# Runs over BODY_TEXT — extract_pr_body's parsed PR-body output (or the
# --check file's content) — ONLY, never the raw command text SCAN_TEXT
# carries for rule 1. A command with no body at all (BODY_TEXT empty) makes
# this a no-op.
run_claim_scan() {
  [ "${SYG_PR_BODY_CLAIM_SCAN:-1}" = "0" ] && return 0
  [ -z "$BODY_TEXT" ] && return 0

  # Unfenced text computed ONCE and shared by both passes below — the
  # Acceptance-heading detector and the main scan loop must agree on which
  # lines are "real" body text vs. example prose inside a fenced block.
  local unfenced
  unfenced=$(printf '%s' "$BODY_TEXT" | strip_fenced_lines)

  # Acceptance-heading detector: a heading found INSIDE a fenced code block is
  # example prose, not a real Acceptance section, so it runs over the
  # already-unfenced text. A single pass over the whole body (rather than
  # folding this into the main scan loop below) is required so the narrowing
  # sees the FINAL value — a real Acceptance heading appearing AFTER the
  # closing `Closes TASK-N` line must still count. Case-insensitive so a
  # lowercase `## acceptance` heading counts the same as `## Acceptance`.
  local has_acceptance=0
  if printf '%s' "$unfenced" | grep -iE '^[[:space:]]*##+[[:space:]]*Acceptance' >/dev/null; then
    has_acceptance=1
  fi

  local flagged_count=0
  local flagged_lines=""
  local line
  while IFS= read -r line; do
    if printf '%s' "$line" | grep -E '^[[:space:]]*>' >/dev/null; then continue; fi
    # A heading is a section label, not a claim — "## Verified, and how"
    # names what the section covers rather than asserting something is true.
    if printf '%s' "$line" | grep -E '^[[:space:]]*#{1,6}[[:space:]]' >/dev/null; then
      continue
    fi

    if ! printf '%s' "$line" | grep -iE "$CLAIM_SHAPE_CORE_REGEX|$CLAIM_SHAPE_PR_BODY_EXTRA_REGEX" >/dev/null; then
      continue
    fi
    if printf '%s' "$line" | grep -iE "$CLAIM_CITE_EXEMPT_REGEX" >/dev/null; then
      continue
    fi
    # Closing-reference narrowing: a bare closing-reference (`closes TASK-N`,
    # `fixes doc-N`, etc.) line is exempt once the body carries an Acceptance
    # heading — the heading is the cite for a closing reference's own claim
    # (the item is actually done).
    if [ "$has_acceptance" -eq 1 ] && printf '%s' "$line" | grep -iE "$CLAIM_CLOSING_REF_REGEX" >/dev/null; then
      continue
    fi

    flagged_count=$((flagged_count + 1))
    if [ "$flagged_count" -le 20 ]; then
      flagged_lines="$flagged_lines$line
"
    fi
  done <<<"$unfenced"

  [ "$flagged_count" -eq 0 ] && return 0

  # Block once per body TEXT PER UTC DAY (not per PR, not forever) in gate
  # mode — an unchanged retry proceeds within the same day; a body edited to
  # fix the flagged lines is a new key and is scanned again; the day boundary
  # bounds how long a stale ack can silently suppress a re-scan. The key is
  # written before the blocking exit (fail-open on an unwritable ack file,
  # since blocking on retry would infinite-loop). `--check` preflight never
  # reads or writes ack state, since a preflight ack would pre-acknowledge a
  # blocked body for the real gate.
  local ack_state_fault=""
  if [ "$CHECK_MODE" -eq 0 ]; then
    # No sha256sum means no ack key to scope the block to THIS body text; a
    # shared empty key would ack every body for the rest of the UTC day, so
    # fail open instead of computing a degraded key. Note what is lost: this
    # guard is downstream of the `flagged_count -eq 0` return above, so the
    # scan itself has already run and flagged its lines — only the BLOCK is
    # given up here, for this one write.
    command -v sha256sum >/dev/null 2>&1 || return 0
    local body_hash
    body_hash=$(printf '%s' "$BODY_TEXT" | sha256sum | cut -d' ' -f1)
    # Same reasoning as the availability check above: an empty hash is as
    # unusable as a missing binary for scoping the ack key.
    [ -z "$body_hash" ] && return 0
    local today
    today=$(date -u +%F)
    local ack_key="${today}:${body_hash}"
    local state_base="${XDG_STATE_HOME:-$HOME/.local/state}"
    local seyag_dir="$state_base/seyag"
    local ack_file="${SYG_PR_BODY_ACK_FILE:-$seyag_dir/pr-body-claim-ack}"
    local ack_dir
    ack_dir=$(dirname "$ack_file")

    # Mirror pr-merge-review-check.sh's state-path invariant: never read or
    # write through a symlink (at the state dir or the ack file itself) or a
    # non-regular file / non-directory. An unhealthy
    # state is treated as NOT acked and fails closed without touching the
    # target; a write failure on a healthy state fails open with a stderr note.
    if [ -L "$ack_dir" ]; then
      ack_state_fault="symlink at $ack_dir (the state directory)"
    elif [ -e "$ack_dir" ] && [ ! -d "$ack_dir" ]; then
      ack_state_fault="$ack_dir exists and is not a directory"
    elif [ -L "$ack_file" ]; then
      ack_state_fault="symlink at $ack_file"
    elif [ -e "$ack_file" ] && { [ ! -f "$ack_file" ] || [ ! -r "$ack_file" ]; }; then
      ack_state_fault="$ack_file is not a readable regular file"
    fi

    if [ -z "$ack_state_fault" ]; then
      if [ -f "$ack_file" ] && grep -qxF "$ack_key" "$ack_file" 2>/dev/null; then
        return 0
      fi

      if [ ! -d "$ack_dir" ]; then
        # shellcheck disable=SC2174  # -m on the deepest dir is the intent: parents keep their distro modes, the state dir itself is 700
        if ! mkdir -p -m 700 "$ack_dir" 2>/dev/null; then
          echo "pr-body-ref-gate (claim scan): could not write ack file $ack_file — failing open" >&2
          return 0
        fi
      elif [ -z "${SYG_PR_BODY_ACK_FILE:-}" ]; then
        chmod 700 "$ack_dir" 2>/dev/null || true
      fi

      local tmp_ack=""
      if [ ! -e "$ack_file" ] || [ -w "$ack_file" ]; then
        tmp_ack=$(umask 077; mktemp "$ack_dir/.pr-body-claim-ack.XXXXXX" 2>/dev/null || echo "")
      fi
      if [ -z "$tmp_ack" ]; then
        echo "pr-body-ref-gate (claim scan): could not write ack file $ack_file — failing open" >&2
        return 0
      fi
      # Concurrent acks are last-writer-wins (read-filter-mv); a lost ack costs one extra block — acceptable by design.
      if ! {
        if [ -f "$ack_file" ]; then
          grep -E "^${today}:" "$ack_file" 2>/dev/null || true
        fi
        printf '%s\n' "$ack_key"
      } >"$tmp_ack" 2>/dev/null || ! mv -f "$tmp_ack" "$ack_file" 2>/dev/null; then
        rm -f "$tmp_ack" 2>/dev/null || true
        echo "pr-body-ref-gate (claim scan): could not write ack file $ack_file — failing open" >&2
        return 0
      fi
      chmod 600 "$ack_file" 2>/dev/null || true
    fi
  fi

  local rule_ref="${SYG_PR_BODY_RULE_REF:-}"
  {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "PR BODY CLAIM-SHAPE GATE — uncited/unhedged claim line(s)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ "$flagged_count" -gt 20 ]; then
      printf 'This PR body carries %s claim-shaped line(s), showing the first 20:\n\n' "$flagged_count"
    else
      printf 'This PR body carries %s claim-shaped line(s):\n\n' "$flagged_count"
    fi
    printf '%s' "$flagged_lines"
    if [ "$flagged_count" -gt 20 ]; then
      printf '+%s more\n' "$((flagged_count - 20))"
    fi
    echo
    echo "Verify each line with a command or a file:line cite on the same"
    echo "line, or hedge it in place (\"unverified\", \"not verified\")."
    echo "A retry proceeds once this body's text is unchanged, within the"
    echo "same UTC day."
    echo
    if [ -n "$rule_ref" ]; then
      printf 'Per %s\n' "$rule_ref"
    fi
    if [ "$CHECK_MODE" -eq 0 ]; then
      printf 'Preflight: bash %s --check <body-file> before composing the command.\n' "${BASH_SOURCE[0]}"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ -n "$ack_state_fault" ]; then
      printf 'WARNING: the pr-body claim-ack state is unusable (%s) — this block\n' "$ack_state_fault"
      printf 'cannot be acked, so retries will keep blocking until the state path is fixed.\n'
      printf 'Nothing was written through it.\n'
    fi
  } >&2
  return 2
}

run_ref_check
REF_RC=$?
if [ "$REF_RC" -eq 2 ]; then
  exit 2
fi

run_claim_scan
CLAIM_RC=$?
if [ "$CLAIM_RC" -eq 2 ]; then
  exit 2
fi

exit 0
