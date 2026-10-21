"""Shell quote stripping, shared by every hook that has to scan a command line.

SEYAG PLUGIN COPY: vendored from the Tzurot repo's .claude/hooks/lib. In this
plugin its consumers are the hooks listed under CONSUMERS below, each pinned by
its .probe.sh; this module is also pinned directly by tests/shell_quotes.probe.sh
(all run via tests/run-probes.sh). The CONSUMERS list below names this
plugin's consumers first, then Tzurot's; mentions of Tzurot hooks and of the
TS test are kept for provenance and say so.

WHY THIS IS A MODULE AND NOT THREE COPIES
-----------------------------------------
Three hooks need the same thing: replace each quoted span in a command string
with a placeholder, so that argument CONTENT (a commit message, a `-m` body, an
example command quoted in prose) cannot influence a structural scan of the
command. In Tzurot, where this module began, each of them had its own copy, and
the copies had already diverged — lossy-pipe-guard's was fixed while
develop-code-commit-guard's and cwd-drift-guard's kept the bug for another PR.

The bug is worth stating precisely, because the naive version looks obviously
correct and is not. Stripping single-quoted spans and double-quoted spans as two
INDEPENDENT passes pairs raw quote characters with no notion of which quote type
is already open, so an ordinary apostrophe inside a double-quoted argument is
read as a real delimiter and pairs with a later one:

    git commit -m "it's" | grep "isn't"     MEASURED: the guard exited 0
    echo "it's" && git commit -m "won't"    MEASURED: strips to `echo S`

In the first, the apostrophes in `it's` and `isn't` pair, erasing the pipe and
`grep` between them. In the second, they erase the entire `git commit`. Both are
ordinary English in a commit message, not adversarial input.

Swapping the pass order only mirrors the bug — a literal `"` inside a
single-quoted argument then pairs the same naive way — so the two-pass strategy
has no correct ordering. It needs STATE, which is what this scanner has.

FAILURE DIRECTION
-----------------
An UNTERMINATED quote strips NOTHING (returns None). Dropping to end-of-text
would delete a real invocation and produce a bypass; keeping the text merely
over-arms the caller, and over-arming is the recoverable direction for all three
consumers.

WHAT strip_quoted DOES NOT SEE
------------------------------
A quoted span is replaced WHOLE, which means a command substitution nested
inside one is erased along with it — while bash still executes the inner
command. Measured, all three forms ran the inner commit:

    echo "$(git commit -m x)"   ->  echo S   (the invocation is gone)
    echo "`git commit -m x`"    ->  echo S
    echo $(git commit -m x)     ->  intact   (unquoted survives the strip)

The even quote count means the scan closes cleanly and the caller never
reaches the unterminated-quote safe direction above. `substitution_spans`
exists for that: it reads the substitution CONTENTS straight out of the raw
text so a caller can scan them as commands in their own right, which is what
bash treats them as. `strip_heredoc_bodies` is its companion — without it a
span holding the repo's canonical `$(cat <<'EOF' … EOF)` commit message would
be scanned including the message body.

CONSUMERS
---------
In this plugin (hooks/):
    lossy-pipe-guard.sh           strip_quoted, strip_heredoc_bodies,
                                  substitution_spans_matching, heredoc_openers,
                                  HEREDOC_OPENER
    cwd-drift-guard.sh            strip_quoted_indexed, strip_heredoc_bodies,
                                  QUOTED_SPAN, ESCAPED_BLANK (substitution-blind,
                                  the lower-stakes drift-warning case)
    grep-escaped-dollar-guard.sh  strip_heredoc_bodies
    pr-monitor-reminder.sh        _words, strip_heredoc_bodies
    broad-walk-guard.sh           command_pipelines (the shared command splitter),
                                  unwrap_runners, strip_redirections
    lib/delete_commands.py        command_pipelines, unwrap_runners,
    (for cache-rm-redirect.sh     strip_redirections
     and recursive-rm-guard.sh)
Tzurot's own copy of this module also serves its develop-code-commit-guard and
board-commit-branch-gate (the latter uses strip_quoted_indexed plus
wrapped_command_strings, deliberately not executed_segments, because it
resolves add pathspecs back to real paths). The public functions here are
pinned directly by tests/shell_quotes.probe.sh.

A THIRD THING strip_quoted DOES NOT SEE, distinct from the substitution case
above: a WRAPPER's string argument. `bash -c "…"`, `sh -c "…"` and `eval "…"`
hand their argument to a shell as a command, so the strip that correctly makes
`echo "…"` inert erases a real invocation. There are two answers, depending on
what the caller needs: `executed_segments` for a caller that just wants
scan-ready segments, `wrapped_command_strings` for a caller that needs the
raw inner string to scan its own way. Both are separate functions rather than
a change to strip_quoted because the distinction is not about quoting at all
— it is about which COMMANDS execute their arguments.

In this plugin, behaviour is pinned by tests/shell_quotes.probe.sh (cases in
tests/shell_quotes_cases.py, ported from Tzurot's
packages/tooling/src/dev/shellQuotes.test.ts), plus each consumer's own
.probe.sh. Mentions of shellQuotes.test.ts below name that Tzurot suite, the
source of the ported cases.

A hook that cannot import this module fails OPEN (its python exits non-zero and
the hook allows the command). That direction is deliberate — a PreToolUse hook
that blocked every Bash call on an infrastructure error would be unusable — but
it does mean a missing lib silently disarms a blocking guard at runtime. The
backstop is CI, not runtime: every consumer's probe exercises a case that only
passes when the import works, and `guard:hook-probes` runs them in the lint job
and in `pnpm quality`.
"""

import re


def _scan_events(text, bash_words=False):
    """Walk `text` once with bash's quote state machine, yielding one event per
    unit of syntax. Every quote-aware reader in this module is built on this, so
    the state machine the module docstring argues for exists exactly once.

    Events, as `(kind, payload)`:

        ("char", c)          an ordinary character outside quotes
        ("escape", c)        a backslash-escaped character outside quotes;
                             payload is the character bash would produce
        ("continuation", "") a backslash-newline outside quotes, which bash
                             deletes entirely rather than making literal
        ("quoted", value)    a COMPLETE quoted span, emitted at the closing
                             quote; payload is the span's VALUE — delimiters
                             removed and escapes resolved as bash resolves them
                             for that quote type
        ("unterminated", "") the text ended with a quote still open; always the
                             last event when it appears

    A quoted span's inner characters produce no events of their own — a reader
    that wants them reads the `quoted` payload. `strip_quoted` discards that
    payload (a span is a placeholder to it); the readers that run a span's
    contents as a command need the value, which is why it is resolved here
    rather than left raw.

    Inside SINGLE quotes nothing escapes and the value is verbatim. Inside
    DOUBLE quotes a backslash is literal EXCEPT before `$`, a backtick, `"` or
    `\\` (where it is removed and the character kept, so `"a\\"b"` stays one
    span) and before a newline (where both are removed). That is bash's rule,
    argued from its documented quoting behaviour rather than a runtime repro.

    `bash_words=True` (the `_tokens` and heredoc-opener readers; `strip_quoted`
    and its siblings keep the plain behaviour their consumers are pinned on)
    adds what bash does outside quotes:
    - a `#` that STARTS a word begins a comment, so an apostrophe in it opens
      no quote (`# it's fine` NEWLINE `rm -rf x` hid the rm from every splitter
      consumer). `a#b` and `$#` are not comments. Outside quotes a stack
      tracks open `$(`/`<(`/`)` substitutions, plain `(` subshells,
      `$((`/`((` arithmetic, `${…}` parameter expansions and `case` commands:
      after a `)` word start is true unless that `)` closed a `$(`,
      `<(`/`>(` or `$((` substitution; `#` never starts a comment while the
      innermost construct is `${…}` or arithmetic; inside `$(…)` a comment
      ends at the newline. The stack has no depth cap — how deep the nesting
      is never changes how the text is read — and each push or pop is O(1).
    - a backtick span ends where bash ends it: at the next backtick not
      preceded by an unescaped backslash (quotes do NOT protect a backtick).
      Its interior is scanned as a command of its own that nothing opened in
      it can outlive: a comment ends at the closing backtick, and a quote
      still open there is a literal character (the recovery rule below). A
      backtick with no closing backtick is itself a literal character.
    - `((` is arithmetic only when the `)` that balances its inner `(` is
      immediately followed by `)`, as in bash; otherwise it is two nested
      subshells (`((echo a) )`), where `#` can start a comment. `$((` is
      always arithmetic.
    - inside a `case` command a pattern's `)` closes nothing, so
      `$(case a in a) …;; esac)` stays one substitution until its last `)`.
    - `$'…'` (ANSI-C quoting) yields its decoded value, and `$"…"` is a double-
      quoted string, so `rm $'-rf' x` reads as `rm -rf x`, not `rm $-rf x`.
    - when a quote is still open at the end of the text (or of the backtick
      span it opened in), that quote character is emitted as an ordinary
      `("char", q)` and scanning continues after it unquoted, so a stray quote
      can never hide later commands (`bash_words=False` keeps
      `unterminated`).
    """
    if not bash_words:
        yield from _scan_plain(text)
        return
    for kind, payload, _pos, _ctx in _scan(text):
        if kind == "run":
            for ch in payload:
                yield ("char", ch)
        else:
            yield (kind, payload)


def _scan_plain(text):
    """The `bash_words=False` reader behind `_scan_events`: quotes and
    backslashes only, ending with `unterminated` when a quote is left open."""
    quote = None
    span = []
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if quote is None:
            if ch == "\\" and i + 1 < n:
                nxt = text[i + 1]
                if nxt == "\n":
                    yield ("continuation", "")
                else:
                    yield ("escape", nxt)
                i += 2
                continue
            if ch in "\"'":
                quote = ch
                span = []
            else:
                yield ("char", ch)
        elif quote == '"':
            if ch == "\\" and i + 1 < n:
                nxt = text[i + 1]
                if nxt == "\n":
                    pass
                elif nxt in '$`"\\':
                    span.append(nxt)
                else:
                    span.append(ch)
                    span.append(nxt)
                i += 2
                continue
            if ch == quote:
                yield ("quoted", "".join(span))
                quote = None
            else:
                span.append(ch)
        else:
            # Inside single quotes there are no escapes; only the closing
            # quote ends the span.
            if ch == quote:
                yield ("quoted", "".join(span))
                quote = None
            else:
                span.append(ch)
        i += 1
    if quote is not None:
        yield ("unterminated", "")


def _peek_char(text, j, end=None):
    """Index and character of the first char at or after `j` (and before
    `end`, default the end of `text`), skipping any backslash-newline
    continuation splices."""
    n = len(text) if end is None else end
    while j + 1 < n and text[j] == "\\" and text[j + 1] == "\n":
        j += 2
    if j < n:
        return j, text[j]
    return j, ""


# Construct kinds on the bash-words stack (`_bash_scan`): `subshell`, `subst`
# (`$(`), `proc_subst` (`<(`/`>(`), `arith` (`((` and parens inside
# arithmetic), `arith_subst` (`$((`), `param` (`${`), `dq_subst` /
# `dq_arith_subst` (`$(` / `$((` inside double quotes, `descend_dq` only),
# `backtick` (the root of a backtick span's own scan), `case_word` /
# `case_in` / `case_pat` / `case_cmd` (a `case` command before its subject,
# before `in`, reading a pattern, running a clause) and `pat_paren` (a paren
# inside a case pattern).
_NO_COMMENT = frozenset(("param", "arith", "arith_subst", "dq_arith_subst"))
_ARITH = frozenset(("arith", "arith_subst", "dq_arith_subst"))
_PAREN_CLOSES = frozenset(
    ("subshell", "subst", "proc_subst", "arith", "arith_subst", "dq_subst", "dq_arith_subst")
)
_CASE_OPEN = frozenset(("case_word", "case_in", "case_cmd"))
_COMMAND_CONTEXTS = frozenset(
    (None, "subshell", "subst", "proc_subst", "dq_subst", "backtick", "case_cmd")
)
# Reserved words after which the next word is still at command position.
_KEEP_CMD_POS = frozenset(("if", "then", "elif", "else", "do", "while", "until", "!", "{", "time"))
# The characters outside quotes that need more than "part of the current word".
_SPECIAL = frozenset("\\#$'\"`{}() \t\n;&|<>")
_INERT_RUN = re.compile(r"[^\\#$'\"`{}() \t\n;&|<>]+")
_DQ_STOP = re.compile(r'[\\"]')
_DQ_STOP_DESCEND = re.compile(r'[\\"$`]')
_BACKTICK_STOP = re.compile(r"[\\`]")
_PAREN_STOP = re.compile(r"[\\'\"()]")


class _ScanState:
    """What a bash-words scan of one text, within one bound, carries across
    the `_scan` calls that resume it (`_next_heredoc_line` resumes after each
    heredoc body): the construct stack, the backtick spans passed (for the
    caller to strip inside), and the memos that keep the scan linear.

    LINEAR QUOTE RECOVERY. A double-quoted RUN starts at an opening quote or
    where the scan returns to double quotes (after the `)` of a `$(…)` or a
    backtick span inside them) and ends at its closing quote or its next
    descent into `$(`/a backtick; a run that reaches the bound instead
    descends nowhere and passes every later position with the same backslash
    pairing (a run can only start just after a non-backslash character that
    the scan read unescaped), so every run starting at or after its start is
    unterminated too. `dq_fail_from` records the earliest such start, and a
    run starting at or after it is known unterminated without scanning;
    `sq_fail_from` does the same for `'` (no escapes, so "no `'` from here
    on"), `ansi_fail_from` for `$'…'` and `bt_fail_from` for a backtick span
    with no closing backtick. The scan never moves backwards, so each kind
    costs at most one scan to the bound.

    `paren_match` memoizes the `((` lookahead per `(` position, and `budget`
    caps the lookahead's total steps; past it a `((` keeps the arithmetic
    reading (the pre-lookahead behaviour)."""

    __slots__ = (
        "stack", "spans", "dq_fail_from", "sq_fail_from", "ansi_fail_from",
        "bt_fail_from", "la_dq_fail_from", "paren_match", "budget",
    )

    def __init__(self, root, size):
        self.stack = [] if root is None else [root]
        self.spans = []
        self.dq_fail_from = None
        self.sq_fail_from = None
        self.ansi_fail_from = None
        self.bt_fail_from = None
        self.la_dq_fail_from = None
        self.paren_match = {}
        self.budget = 8 * size + 1024


def _scan(text, start=0, *, descend_dq=False, state=None):
    """The bash-words scanner behind `_scan_events(bash_words=True)`,
    `_tokens` and the heredoc readers, yielding `(kind, payload, pos, ctx)`:
    `pos` is the character offset in `text` and `ctx` is `(innermost
    construct kind or None, inside a backtick span)`. The kinds are those of
    `_scan_events` minus `unterminated`, plus `("run", s)`: a run of ordinary
    word characters outside quotes, emitted whole so a long word is one event.

    With `descend_dq=True`, `$(` inside double quotes enters a nested
    unquoted command context (`dq_subst`) that returns to double quotes at
    its matching `)`, and a backtick span inside double quotes is scanned
    like an unquoted one (same boundary rule) before the double quotes
    resume. Without it a backtick inside double quotes is an ordinary
    character of the quoted value, as before. `state` (a `_ScanState`)
    carries the stack and memos across calls that resume the same text."""
    if state is None:
        state = _ScanState(None, len(text))
    return _bash_scan(text, start, len(text), descend_dq, state, False)


def _finish_word(word, stack, cmd_pos):
    """Apply a word that just ended to the `case` tracking on `stack`; return
    whether the next word is at command position. `word` is the word's text
    when it is short and wholly unquoted (a possible reserved word), else
    None."""
    top = stack[-1] if stack else None
    if top == "case_word":
        stack[-1] = "case_in"
        return False
    if top == "case_in":
        if word == "in":
            stack[-1] = "case_pat"
        return False
    if top == "case_pat":
        if word == "esac":
            stack.pop()
        return False
    if not cmd_pos or top not in _COMMAND_CONTEXTS:
        return False
    if word == "case":
        stack.append("case_word")
        return False
    if word == "esac" and top == "case_cmd":
        stack.pop()
        return False
    return word in _KEEP_CMD_POS


def _backtick_end(text, j, n, st):
    """Index of the backtick closing a span whose interior starts at `j`: the
    next backtick not preceded by an unescaped backslash, as bash finds it
    (quotes do not protect a backtick). -1 when there is none before `n`."""
    if st.bt_fail_from is not None and j >= st.bt_fail_from:
        return -1
    start = j
    while True:
        m = _BACKTICK_STOP.search(text, j, n)
        if m is None:
            st.bt_fail_from = start
            return -1
        p = m.start()
        if text[p] == "`":
            return p
        j = p + 2


def _dq_run(text, j, n, descend, st):
    """Read a double-quoted run from `j` (just past its opening quote, or past
    the `)`/backtick that returned to double quotes) without emitting events.

    Returns `("close", p, None, value)` at the closing quote `p`; with
    `descend`, `("subst", p, (k, is_arith), None)` at a `$(` (`k` the index
    of its paren, `is_arith` for `$((`) and `("bt", p, end, None)` at a
    backtick span closing at `end`; or None when the run reaches `n`
    unterminated. A backslash is literal except before `$`, a backtick, `"`,
    `\\\\` (removed, character kept) and a newline (both removed)."""
    stop = _DQ_STOP_DESCEND if descend else _DQ_STOP
    span = []
    while True:
        m = stop.search(text, j, n)
        if m is None:
            return None
        p = m.start()
        if p > j:
            span.append(text[j:p])
        c = text[p]
        if c == '"':
            return ("close", p, None, "".join(span))
        if c == "\\":
            if p + 1 < n:
                nxt = text[p + 1]
                if nxt == "\n":
                    pass
                elif nxt in '$`"\\':
                    span.append(nxt)
                else:
                    span.append(c + nxt)
                j = p + 2
            else:
                span.append(c)
                j = p + 1
            continue
        if c == "$":
            k, nxt = _peek_char(text, p + 1, n)
            if nxt == "(":
                _, after = _peek_char(text, k + 1, n)
                return ("subst", p, (k, after == "("), None)
            span.append(c)
            j = p + 1
            continue
        end = _backtick_end(text, p + 1, n, st)
        if end == -1:
            span.append(c)
            j = p + 1
            continue
        return ("bt", p, end, None)


def _lookahead_dq_end(text, j, n, st):
    """For the `((` lookahead: index of the `"` closing a double-quoted run
    from `j`, -1 when none does, None once the lookahead budget is spent."""
    if st.la_dq_fail_from is not None and j >= st.la_dq_fail_from:
        return -1
    start = j
    while True:
        st.budget -= 1
        if st.budget < 0:
            return None
        m = _DQ_STOP.search(text, j, n)
        if m is None:
            st.la_dq_fail_from = start
            return -1
        p = m.start()
        if text[p] == '"':
            return p
        j = p + 2


def _paren_match(text, k, n, st):
    """Index of the `)` balancing the `(` at `k`, counting parens outside
    quotes and escapes; -1 when none does before `n`; None once the state's
    lookahead budget is spent. Every `(` the walk opens is memoized with its
    match (or -1), so a later lookahead from inside this one is a dict hit
    and a walk jumps over any `(` already matched."""
    memo = st.paren_match
    if k in memo:
        return memo[k]
    opens = [k]
    j = k + 1
    while True:
        st.budget -= 1
        if st.budget < 0:
            return None
        m = _PAREN_STOP.search(text, j, n)
        if m is None:
            break
        p = m.start()
        c = text[p]
        if c == "\\":
            j = p + 2
        elif c == "'":
            close = -1
            if st.sq_fail_from is None or p + 1 < st.sq_fail_from:
                close = text.find("'", p + 1, n)
                if close == -1:
                    st.sq_fail_from = p + 1
            j = p + 1 if close == -1 else close + 1
        elif c == '"':
            close = _lookahead_dq_end(text, p + 1, n, st)
            if close is None:
                return None
            j = p + 1 if close == -1 else close + 1
        elif c == "(":
            seen = memo.get(p)
            if seen is None:
                opens.append(p)
                j = p + 1
            elif seen == -1:
                break
            else:
                j = seen + 1
        else:
            memo[opens.pop()] = p
            if not opens:
                return p
            j = p + 1
    for o in opens:
        memo[o] = -1
    return -1


def _dparen_is_arith(text, k, n, st):
    """True when the `((` whose inner `(` is at `k` is arithmetic: the `)`
    balancing that inner `(` is immediately followed by `)`. With no such
    `)` (or no lookahead budget left) it stays arithmetic, the reading
    before this lookahead existed."""
    close = _paren_match(text, k, n, st)
    if close is None or close < 0:
        return True
    _, after = _peek_char(text, close + 1, n)
    return after == ")"


def _bash_scan(text, start, bound, descend, st, in_bt):
    """The `_scan` generator over `text[start:bound]`. `st` is the
    `_ScanState`; `in_bt` marks a backtick span's own scan, whose bound is the
    span's closing backtick."""
    stack = st.stack
    ctx = (stack[-1] if stack else None, in_bt)
    word_start = True
    cmd_pos = True
    word_begin = -1
    word_plain = False
    prev = ""
    lone_dollar = False
    dq_from = -1
    i = start
    n = bound
    while True:
        if dq_from >= 0:
            # Double quotes opened (or returned to) at `dq_from`.
            q = dq_from
            dq_from = -1
            j = q + 1
            res = None
            if st.dq_fail_from is None or j < st.dq_fail_from:
                res = _dq_run(text, j, n, descend, st)
                if res is None:
                    st.dq_fail_from = j
            if word_begin < 0:
                word_begin = q
            word_plain = False
            if res is None:
                # Unterminated: the quote is a literal character.
                yield ("char", '"', q, ctx)
                prev = '"'
                lone_dollar = False
                word_start = False
                i = q + 1
                continue
            what, p, extra, value = res
            if what == "close":
                yield ("quoted", value, q, ctx)
                word_start = False
                prev = ""
                lone_dollar = False
                i = p + 1
            elif what == "subst":
                k, is_arith = extra
                kind = "dq_arith_subst" if is_arith else "dq_subst"
                stack.append(kind)
                ctx = (kind, in_bt)
                word_start = True
                cmd_pos = True
                word_begin = -1
                prev = "("
                lone_dollar = False
                i = k + 1
            else:
                st.spans.append((p + 1, extra))
                yield from _bash_scan(
                    text, p + 1, extra, descend, _ScanState("backtick", extra - p), True
                )
                dq_from = extra
            continue
        if i >= n:
            break
        ch = text[i]
        if ch not in _SPECIAL:
            j = _INERT_RUN.match(text, i, n).end()
            if word_begin < 0:
                word_begin = i
                word_plain = True
            yield ("run", text[i:j], i, ctx)
            word_start = False
            prev = text[j - 1]
            lone_dollar = False
            i = j
            continue
        if ch == "\\" and i + 1 < n:
            nxt = text[i + 1]
            if nxt == "\n":
                yield ("continuation", "", i, ctx)
                if word_begin >= 0:
                    word_plain = False
            else:
                yield ("escape", nxt, i, ctx)
                word_start = False
                prev = ""
                lone_dollar = False
                if word_begin < 0:
                    word_begin = i
                word_plain = False
            i += 2
            continue
        if ch == "#" and word_start and ctx[0] not in _NO_COMMENT:
            newline = text.find("\n", i, n)
            if newline == -1:
                break
            i = newline
            continue
        if ch == "$" and i + 1 < n and text[i + 1] in "\"'":
            if word_begin < 0:
                word_begin = i
            word_plain = False
            if text[i + 1] == '"':
                prev = "$"
                lone_dollar = False
                i += 1  # `$"…"` is a double-quoted string (locale translation)
                continue
            value = end = None
            if st.ansi_fail_from is None or i + 2 < st.ansi_fail_from:
                value, end = _ansi_c_span(text, i + 2, n)
                if end is None:
                    st.ansi_fail_from = i + 2
            word_start = False
            lone_dollar = False
            if end is None:
                yield ("char", "$", i, ctx)
                yield ("char", "'", i + 1, ctx)
                prev = "'"
                i += 2
                continue
            yield ("quoted", value, i, ctx)
            prev = ""
            i = end + 1
            continue
        if ch == "'":
            if word_begin < 0:
                word_begin = i
            word_plain = False
            close = -1
            if st.sq_fail_from is None or i + 1 < st.sq_fail_from:
                close = text.find("'", i + 1, n)
                if close == -1:
                    st.sq_fail_from = i + 1
            word_start = False
            lone_dollar = False
            if close == -1:
                # Unterminated: the quote is a literal character.
                yield ("char", "'", i, ctx)
                prev = "'"
                i += 1
                continue
            yield ("quoted", text[i + 1 : close], i, ctx)
            prev = ""
            i = close + 1
            continue
        if ch == '"':
            prev = ""
            lone_dollar = False
            dq_from = i
            continue
        if ch == "`":
            if word_begin < 0:
                word_begin = i
            word_plain = False
            yield ("char", "`", i, ctx)
            end = _backtick_end(text, i + 1, n, st)
            if end >= 0:
                st.spans.append((i + 1, end))
                yield from _bash_scan(
                    text, i + 1, end, descend, _ScanState("backtick", end - i), True
                )
                yield ("char", "`", end, ctx)
                i = end + 1
            else:
                i += 1  # no closing backtick: a literal character
            word_start = False
            prev = "`"
            lone_dollar = False
            continue
        if ch in " \t\n;&|<>()":
            # A word ends here; apply it to the `case` tracking first, so the
            # `)` after `esac` is yielded with the construct it really closes.
            if word_begin >= 0:
                cmd_pos = _finish_word(
                    text[word_begin:i] if word_plain and i - word_begin <= 5 else None,
                    stack,
                    cmd_pos,
                )
                word_begin = -1
                ctx = (stack[-1] if stack else None, in_bt)
            if ch == "(":
                top = ctx[0]
                yield ("char", ch, i, ctx)
                k, nxt = _peek_char(text, i + 1, n)
                if top in _ARITH:
                    kind = "subst" if prev == "$" and nxt != "(" else "arith"
                elif prev == "$" and nxt == "(":
                    kind = "arith_subst"
                elif prev == "$":
                    kind = "subst"
                elif prev in ("<", ">"):
                    kind = "proc_subst"
                elif top == "param":
                    kind = None
                elif top == "case_pat":
                    # A pattern's optional leading `(` opens nothing.
                    kind = None if word_start else "pat_paren"
                elif top == "pat_paren":
                    kind = "pat_paren"
                elif nxt == "(" and _dparen_is_arith(text, k, n, st):
                    kind = "arith"
                else:
                    kind = "subshell"
                if kind is not None:
                    stack.append(kind)
                    ctx = (kind, in_bt)
                word_start = True
                cmd_pos = True
            elif ch == ")":
                top = ctx[0]
                if top == "case_pat":
                    # The `)` ending a case pattern; a command follows.
                    yield ("char", ch, i, ctx)
                    stack[-1] = "case_cmd"
                    ctx = ("case_cmd", in_bt)
                    word_start = True
                    cmd_pos = True
                elif top == "pat_paren":
                    yield ("char", ch, i, ctx)
                    stack.pop()
                    ctx = (stack[-1] if stack else None, in_bt)
                    word_start = False
                else:
                    # A `case` still open here never saw its `esac`.
                    while top in _CASE_OPEN:
                        stack.pop()
                        top = stack[-1] if stack else None
                    ctx = (top, in_bt)
                    yield ("char", ch, i, ctx)
                    closed = stack.pop() if top in _PAREN_CLOSES else None
                    ctx = (stack[-1] if stack else None, in_bt)
                    cmd_pos = False
                    if closed in ("dq_subst", "dq_arith_subst"):
                        word_start = False
                        prev = ch
                        lone_dollar = False
                        dq_from = i
                        continue
                    word_start = closed not in ("subst", "proc_subst", "arith_subst")
            else:
                yield ("char", ch, i, ctx)
                if ch in "<>":
                    cmd_pos = False
                    word_start = False
                else:
                    word_start = True
                    if ch != " " and ch != "\t":
                        cmd_pos = True
                        if (
                            ch == ";"
                            and ctx[0] == "case_cmd"
                            and i + 1 < n
                            and text[i + 1] in ";&"
                        ):
                            # `;;`, `;&`, `;;&` end a clause; patterns follow.
                            stack[-1] = "case_pat"
                            ctx = ("case_pat", in_bt)
            prev = ch
            lone_dollar = False
            i += 1
            continue
        # `{`, `}`, a plain `$`, a `#` that starts no comment, a lone trailing
        # backslash: one character of the current word.
        if word_begin < 0:
            word_begin = i
            word_plain = True
        if ch == "$" or ch == "\\":
            word_plain = False
        yield ("char", ch, i, ctx)
        if ch == "{":
            if lone_dollar:
                stack.append("param")
                ctx = ("param", in_bt)
        elif ch == "}":
            if ctx[0] == "param":
                stack.pop()
                ctx = (stack[-1] if stack else None, in_bt)
        word_start = False
        lone_dollar = (ch == "$") and not lone_dollar
        prev = ch
        i += 1


_ANSI_C_ESCAPES = {
    "a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f", "n": "\n",
    "r": "\r", "t": "\t", "v": "\v", "\\": "\\", "'": "'", '"': '"', "?": "?",
}


_ANSI_C_STOP = re.compile(r"[\\']")
_HEX_DIGITS = {
    width: re.compile(r"[0-9A-Fa-f]{1,%d}" % width) for width in (2, 4, 8)
}
_OCTAL_DIGITS = re.compile(r"[0-7]{1,3}")


def _ansi_c_span(text, start, end=None):
    """Decode a `$'…'` body starting at `text[start]` (and ending before
    `end`, default the end of `text`); return `(value, index of the closing
    quote)`, or `(None, None)` when it never closes."""
    n = len(text) if end is None else end
    out = []
    i = start
    while i < n:
        m = _ANSI_C_STOP.search(text, i, n)
        if m is None:
            return None, None
        if m.start() > i:
            out.append(text[i : m.start()])
            i = m.start()
        ch = text[i]
        if ch == "'":
            return "".join(out), i
        if i + 1 >= n:
            out.append(ch)
            i += 1
            continue
        nxt = text[i + 1]
        if nxt in _ANSI_C_ESCAPES:
            out.append(_ANSI_C_ESCAPES[nxt])
            i += 2
        elif nxt in "xuU":
            width = {"x": 2, "u": 4, "U": 8}[nxt]
            digits = _HEX_DIGITS[width].match(text, i + 2, n)
            # Past U+10FFFF chr() raises, and an exception here fails every
            # consuming hook open; such an escape stays literal instead.
            if digits and int(digits.group(0), 16) <= 0x10FFFF:
                out.append(chr(int(digits.group(0), 16)))
                i += 2 + len(digits.group(0))
            else:
                out.append("\\" + nxt)
                i += 2
        elif nxt in "01234567":
            digits = _OCTAL_DIGITS.match(text, i + 1, n).group(0)
            out.append(chr(int(digits, 8) & 0xFF))
            i += 1 + len(digits)
        elif nxt == "c" and i + 2 < n:
            out.append(chr(ord(text[i + 2]) & 0x1F))
            i += 3
        else:
            out.append("\\" + nxt)
            i += 2
    return None, None


def strip_quoted(text):
    """Replace each quoted span with `S`. Returns None if a quote is unclosed."""
    out = []
    for kind, payload in _scan_events(text):
        if kind == "char":
            out.append(payload)
        elif kind == "quoted":
            # Emitted at the closing quote rather than the opening one. The
            # span's own characters produce no output either way, so the
            # placeholder lands in the same position in the result.
            out.append("S")
        elif kind == "escape":
            # Outside quotes bash lets a backslash escape ANY character, and
            # the escaped character keeps its own value — `t\ail` runs tail.
            # Collapsing every escape to a placeholder therefore HID command
            # names from the scan: measured, a commit piped into that
            # spelling of tail exited 0 while bash ran it as tail exactly as
            # written. Emit the real character instead — EXCEPT the ones that
            # are syntax to the splitters in the calling hooks. An escaped `|`
            # is a literal pipe character in an argument, not a pipeline
            # operator, but once the backslash is gone `segment.split("|")`
            # cannot tell the difference: measured, `git commit -m x\|tail`
            # blocked as though the commit were piped into tail, when bash
            # runs no pipeline at all. Same reasoning for the chain separators
            # and for a quote, which must not be able to open a span. A
            # placeholder keeps the character from acting as syntax while
            # preserving the token boundary.
            #
            # No `\n` in that set: a backslash-newline arrives as its own
            # `continuation` event and never reaches here — and a placeholder
            # would be wrong for it anyway. bash DELETES that pair rather than
            # making it literal, which is exactly the distinction the two
            # events encode.
            out.append("Q" if payload in "\"'|&;" else payload)
        elif kind == "unterminated":
            return None
        # A `continuation` contributes nothing: bash removes the backslash AND
        # the newline and splices the two lines with nothing between them.
        # Emitting a placeholder here fabricated a non-whitespace token between
        # two words bash runs adjacently, and every target regex requires `\s+`
        # adjacency — measured, `git \<newline>  commit -m x` stripped to
        # `git Q  commit` and detection returned False, so a perfectly ordinary
        # multi-line commit slipped the blocking guard. Dropping both
        # characters reproduces the splice exactly, including the case that
        # must NOT match: `git\<newline>commit` splices to `gitcommit`, one
        # token.
    return "".join(out)


# Private-use-area codepoints (never emitted by ordinary command text), so a
# placeholder cannot collide with characters a caller might legitimately be
# scanning. "Never emitted by ordinary text" is not the same as "cannot
# appear", though, so `strip_quoted_indexed` REFUSES any input that already
# contains either codepoint: a literal one therefore never reaches a view or
# an index count at all. In a view a stray occurrence is indistinguishable
# from a real placeholder, and a caller that locates a token's values by
# COUNTING placeholders before that token then reads a shifted index for every
# LATER token — not merely a wrong value in the token the stray sits in, which
# is the narrower case this comment used to reason about.
#
# `resolve_placeholders` still leaves a SURPLUS placeholder in the token
# rather than raising. Behind that refusal it is defence in depth, for a
# caller that builds its own view instead of taking one from
# `strip_quoted_indexed`: the token then fails the caller's allowlist match
# and the caller OVER-reports a non-allowlisted path. That is the fail-open
# direction Tzurot's board-commit-branch-gate.sh documents for scan trouble: a
# widened file set can only ever make a commit PASS, never wrongly block one.
# Not assumed — still pinned by the surplus-placeholder case in
# shellQuotes.test.ts.
QUOTED_SPAN = "\ue000"
ESCAPED_BLANK = "\ue001"


def strip_quoted_indexed(text):
    """Like `strip_quoted`, but RESOLVABLE: each quoted span becomes
    `QUOTED_SPAN` and each backslash-escaped space/tab outside quotes becomes
    `ESCAPED_BLANK`, so a caller that splits the view on whitespace keeps
    every bash word whole and can map each placeholder back to its value.

    Returns `(view, values)` with `values[i]` the value of the i-th quoted
    span in `text` order. `None` on TWO conditions: an unterminated quote,
    exactly as `strip_quoted`; and a `text` that ALREADY contains
    `QUOTED_SPAN` or `ESCAPED_BLANK`, for the reason in the comment above
    them. Escaped separators/quotes still become `Q` — same set, same reason
    as `strip_quoted`; a continuation still contributes nothing.

    One deliberate difference from `strip_quoted`, which emits a REAL space
    for an escaped blank: here it is a non-whitespace placeholder, so a regex
    that requires `\\s` between two words no longer matches across it. That
    matches bash, where `git\\ commit` is ONE word and runs no commit — the
    old literal space was an over-arm. Pinned by "a backslash-escaped space
    outside quotes becomes ESCAPED_BLANK" in tests/shell_quotes_cases.py (and,
    in Tzurot, by board-commit-branch-gate.probe.sh).

    A second function rather than a change to `strip_quoted`: `strip_quoted`'s
    `S` output is pinned by packages/tooling/src/dev/shellQuotes.test.ts and
    read by three other hooks, so its output shape is a contract this
    function must not disturb.
    """
    # A private-use codepoint already in the INPUT is indistinguishable from a
    # placeholder in the view and would shift every LATER token's value index,
    # so the caller gets the same signal an unterminated quote gives it and
    # falls back to the raw text.
    if QUOTED_SPAN in text or ESCAPED_BLANK in text:
        return None
    out = []
    values = []
    for kind, payload in _scan_events(text):
        if kind == "char":
            out.append(payload)
        elif kind == "quoted":
            out.append(QUOTED_SPAN)
            values.append(payload)
        elif kind == "escape":
            if payload in "\"'|&;":
                out.append("Q")
            elif payload in " \t":
                out.append(ESCAPED_BLANK)
            else:
                out.append(payload)
        elif kind == "unterminated":
            return None
    return "".join(out), values


def resolve_placeholders(token, values, next_index):
    """Return `(resolved, index)`: `token` with each `QUOTED_SPAN` replaced by
    `values[next_index]`, `values[next_index + 1]`, … in order, and each
    `ESCAPED_BLANK` replaced by a real space; `index` is `next_index` advanced
    past the last value consumed.

    The caller finds `next_index` for a token by counting `QUOTED_SPAN`
    characters in the view BEFORE that token's start.

    A surplus placeholder — more than `len(values) - next_index` remaining —
    is left in place rather than raising: see the module comment on
    `QUOTED_SPAN` for why leaving it is the correct fail-open direction here.
    """
    out = []
    for ch in token:
        if ch == QUOTED_SPAN:
            if next_index < len(values):
                out.append(values[next_index])
                next_index += 1
            else:
                out.append(ch)
        elif ch == ESCAPED_BLANK:
            out.append(" ")
        else:
            out.append(ch)
    return "".join(out), next_index


def substitution_spans(text):
    """Return the CONTENT of every `$(...)` and backtick span in `text`.

    Read from the RAW text, tracking only as much quote context as decides
    whether bash would EXECUTE a span. A span inside DOUBLE quotes really is
    executed, so it is extracted exactly like an unquoted one. A span whose
    opening character sits inside a SINGLE-quoted region is inert prose to
    bash and is skipped: extracting it made a blocking guard fire on content
    being WRITTEN, such as a backticked git command in a single-quoted `sed`
    replacement or tracker description. Pinned by "a span inside single quotes
    is not extracted" and its double-quoted counterpart in
    packages/tooling/src/dev/shellQuotes.test.ts.

    THE SKIP FAILS CLOSED. It is the one place this function REMOVES text from
    a blocking guard's scan, and it models only plain quoting, so it runs only
    when the text is free of everything that modelling cannot see. On any of
    the following the WHOLE text falls back to extract-everything, the
    behaviour the guards had before the skip existed:

    - a heredoc operator `<<` (a here-string `<<<` is fine): an unquoted-marker
      body runs its `$( )` and makes its apostrophes literal;
    - a shell word (`bash`, `sh`, `zsh`, `dash`, `ksh`) or `eval`: a wrapper's
      single-quoted argument, or single-quoted text piped into a shell, IS
      executed;
    - an unquoted `#`: a comment makes its apostrophes and double quotes
      literal, and whether a `#` starts one is not modelled;
    - a `$'…'` region whose content ends in a backslash: ANSI-C quoting escapes
      that quote, so the region really ends later (the escape itself is not
      modelled — every other region closes at its first `'`, which is also
      right for `$'…'` without a trailing backslash);
    - any extracted span that may have ended at the wrong character: its own
      quotes are unbalanced, a quoted region in it holds a paren, or it carries
      a `#` or a `case` word (the structural paren count below then resumes the
      outer scan with the wrong quote state).

    Within the skip, two more rules keep it from over-skipping: an apostrophe
    inside double quotes is literal (double-quote state is tracked for exactly
    that), and an UNTERMINATED single quote skips nothing — the apostrophe is
    read as literal, where skipping to end of text would hide every later span.
    Each fallback trigger is pinned by its own case in shellQuotes.test.ts and
    each observed bypass shape by a probe row in the two blocking guards.

    KNOWN UNDER-ARM, same file, pinned by "a quoted `)` inside a span ends it
    early": `)` is counted structurally, so `$(echo ")" && git commit)` yields
    only `echo "` and anything after that paren escapes the scan. Modelling
    quotes inside the span would mean a second scanner with its own failure
    directions; the threat model here is habitual command shapes, matching the
    boundary the consuming hooks already state.

    Nesting is handled by PAREN DEPTH and nothing else: `$(a $(b))` yields the
    single span `a $(b)`, inner text verbatim. The callers run a regex over the
    content, and a regex sees the inner text just as well inside the outer —
    so recursing would only produce duplicate hits.

    An UNTERMINATED span runs to end of text. Unlike strip_quoted's
    strip-nothing rule, that direction is safe here: this function only ADDS
    text for the caller to scan, so an over-long span can over-arm and can
    never hide an invocation.
    """
    if _SKIP_UNSAFE_TEXT.search(text) is None:
        spans = _extract_spans(text, skip_single_quoted=True)
        if spans is not None and not any(_span_desyncs(s) for s in spans):
            return spans
    return _extract_spans(text, skip_single_quoted=False)


# Constructs the single-quote skip cannot model. Any match anywhere in the text
# turns the skip off for the WHOLE text, which restores extract-everything:
#
# - `<<` not part of `<<<`: a heredoc body is not shell-quoted text — in an
#   UNQUOTED-marker body an apostrophe is literal and `$( )` runs — so an
#   apostrophe there would open a region that swallows live spans.
# - a shell (`bash`, `sh`, `zsh`, `dash`, `ksh`) or `eval` word: a wrapper's
#   single-quoted argument IS executed (`bash -c '…'`, `eval '…'`), and so is
#   single-quoted text piped into a shell. Matched as a bare word rather than
#   only beside `-c`, which catches the pipe form too; `/bin/sh` still matches
#   because `/` is allowed before the name.
#
# Deliberately generous: a false match only turns the skip off, which returns
# the extract-everything behaviour the guards had before the skip existed.
_SKIP_UNSAFE_TEXT = re.compile(
    r"(?<!<)<<(?!<)" r"|(?<![\w.-])(?:eval|bash|sh|zsh|dash|ksh)(?![\w.-])"
)

# A `case` word inside a span can end it early at a pattern's bare `)`.
_CASE_WORD = re.compile(r"(?<![\w.-])case(?![\w.-])")


def _span_desyncs(span):
    """True when an extracted span may have ended at the wrong character.

    The span scan counts `(`/`)` and backticks structurally, so a quoted `)`
    ends a `$( )` span early, a quoted `(` ends it late, and a `case` pattern's
    bare `)` or a comment's `)` ends it early too. Either way the outer scan
    resumes at the wrong place with the wrong quote state. The tells, checked
    generously: the span's own quotes are unbalanced, a quoted region inside it
    holds a paren, or it carries a `#` or a `case` word.
    """
    if "#" in span or _CASE_WORD.search(span):
        return True
    for kind, payload in _scan_events(span):
        if kind == "unterminated":
            return True
        if kind == "quoted" and ("(" in payload or ")" in payload):
            return True
    return False


def _extract_spans(text, skip_single_quoted):
    """The span scan behind `substitution_spans`.

    With `skip_single_quoted` False this reads the raw text quote-blind and
    extracts every span. With it True it tracks double-quote state and skips a
    span opening inside a single-quoted region — and returns None, meaning
    "fall back", on reaching a construct whose quoting it cannot model:

    - an unquoted, unescaped `#`: a comment makes its apostrophes literal, but
      whether a `#` starts one depends on word boundaries the scanner does not
      track, and guessing wrong in either direction desyncs the quote state.
    - a single-quoted region preceded by `$` whose content ends in a backslash:
      in ANSI-C quoting (`$'a\\''`) that backslash escapes the quote, so the
      region really closes later. Plain `'…'` closing at the first quote is
      right for every other case, including `$$'a\\'` where the `$` is the PID
      parameter and the region is plain; that case falls back too, harmlessly.
    """
    spans = []
    i = 0
    end_of_text = len(text)
    in_double = False
    while i < end_of_text:
        ch = text[i]
        if ch == "\\" and i + 1 < end_of_text:
            # An escaped `$` or backtick opens nothing, and an escaped quote
            # opens no region.
            i += 2
            continue
        if skip_single_quoted:
            if ch == '"':
                in_double = not in_double
                i += 1
                continue
            if not in_double:
                if ch == "#":
                    return None
                if ch == "'":
                    close = text.find("'", i + 1)
                    if close != -1:
                        if (
                            i > 0
                            and text[i - 1] == "$"
                            and close - 1 > i
                            and text[close - 1] == "\\"
                        ):
                            return None
                        i = close + 1
                        continue
                    # Unterminated: read the apostrophe as literal and keep
                    # scanning; skipping to end of text would hide every span.
        if ch == "$" and i + 1 < end_of_text and text[i + 1] == "(":
            j = i + 2
            depth = 1
            while j < end_of_text:
                if text[j] == "\\" and j + 1 < end_of_text:
                    j += 2
                    continue
                if text[j] == "(":
                    depth += 1
                elif text[j] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            if j >= end_of_text:
                spans.append(text[i + 2 :])
                break
            spans.append(text[i + 2 : j])
            i = j + 1
            continue
        if ch == "`":
            j = i + 1
            while j < end_of_text:
                if text[j] == "\\" and j + 1 < end_of_text:
                    j += 2
                    continue
                if text[j] == "`":
                    break
                j += 1
            if j >= end_of_text:
                spans.append(text[i + 1 :])
                break
            spans.append(text[i + 1 : j])
            i = j + 1
            continue
        i += 1
    return spans


# `(?<!<)` keeps a here-string (`<<<word`) from reading as a heredoc opener:
# its trailing `<` plus a bare word matches the same characters, and the marker
# then never terminates, so the whole remainder of the span would be dropped.
#
# The marker is `\w+`, deliberately WIDER than pr-merge-review-check.sh's own
# stripper (`[A-Za-z_][A-Za-z_0-9]*`): bash accepts a digit-leading delimiter
# (`cat <<1EOF`), and a wider marker over-strips, which only ever removes
# candidate text a caller would scan — the recoverable direction here. Each
# hook strips the heredoc forms its own matching cares about (module docstring),
# so the two need not agree.
#
# PUBLIC, unlike the other module-private names: lossy-pipe-guard.sh has to
# REJOIN an emptied heredoc onto its opener line, and the opener half of that
# substitution is this same pattern. Spelling it out a second time in the hook
# is exactly the divergence this module exists to prevent — the copy there was
# written without the here-string lookbehind above and false-blocked a
# here-string followed by a piped command, so the hook composes from this name
# instead. Two consequences for anyone editing the pattern: the group NUMBERING
# (1 = the `-` indent flag, 2 = the quote character, 3 = the marker) is part of
# the exported contract (callers read them; the hook's rejoin itself now keeps
# the whole matched opener, `group(0)`, so a partly quoted delimiter such as
# `<<E"OF"` survives it unchanged); and both consumers are pinned by the
# heredoc and here-string cases in lossy-pipe-guard.probe.sh, which is where a
# change to the pattern would surface.
HEREDOC_OPENER = re.compile(r"(?<!<)<<(-?)\s*(['\"]?)(\w+)\2(?:['\"]?\w+['\"]?)*")


def _heredoc_marker(match):
    """Return the delimiter word after `<<`/`<<-` with bash quote removal
    applied (`<<E"OF"` and `<<'E'OF` both yield `EOF`)."""
    text = match.string
    i = match.start(2)
    out = []
    quote = None
    while i < len(text):
        ch = text[i]
        if quote is None:
            if ch == "\\" and i + 1 < len(text):
                if text[i + 1] != "\n":
                    out.append(text[i + 1])
                i += 2
                continue
            if ch == "$" and text[i + 1 : i + 2] == '"':
                i += 1
                continue
            if ch == "$" and text[i + 1 : i + 2] == "'":
                val, end = _ansi_c_span(text, i + 2)
                if end is not None:
                    out.append(val)
                    i = end + 1
                    continue
            if ch in "\"'":
                quote = ch
            elif ch in " \t\n;&|()<>":
                break
            else:
                out.append(ch)
        elif quote == '"':
            if ch == "\\" and i + 1 < len(text):
                nxt = text[i + 1]
                if nxt == "\n":
                    pass
                elif nxt in '$`"\\':
                    out.append(nxt)
                else:
                    out.append(ch)
                    out.append(nxt)
                i += 2
                continue
            if ch == '"':
                quote = None
            else:
                out.append(ch)
        else:
            if ch == "'":
                quote = None
            else:
                out.append(ch)
        i += 1
    return "".join(out)


def _terminator_re(match):
    indent = "\t*" if match.group(1) == "-" else ""
    return re.compile(
        r"^" + indent + re.escape(_heredoc_marker(match)) + r"$", re.M
    )


def _next_heredoc_line(text, pos, state):
    """Scan `text` from `pos` for the first logical line carrying one or more
    live heredoc openers (outside quotes, `#` comments, arithmetic and
    backtick spans). Returns `(openers, newline_index)` where `openers` is the
    non-empty list of `HEREDOC_OPENER` match objects on that line and
    `newline_index` is the index of the unquoted `\\n` ending the line (or
    `-1` if `text` ends before any newline), or `(None, -1)` when no opener is
    found. `state` (a `_ScanState`) carries the construct stack from call to
    call; the backtick spans this call passed are appended to `state.spans`.

    An opener inside a backtick span is never collected for the outer line,
    and a newline inside one never ends it: bash reads the span as a string of
    its own, so its heredocs take their bodies from the span's own lines
    (`_strip_span_bodies`)."""
    openers = []
    skip_until = pos
    for kind, ch, i, ctx in _scan(text, pos, descend_dq=True, state=state):
        if i < skip_until or kind != "char" or ctx[1]:
            continue
        if ch == "<" and ctx[0] not in _NO_COMMENT:
            match = HEREDOC_OPENER.match(text, i)
            if match is not None:
                openers.append(match)
                skip_until = match.end()
        elif ch == "\n" and openers:
            return openers, i
    if openers:
        return openers, -1
    return None, -1


def _consume_bodies(text, openers, cursor, no_terminator_from):
    """Consume the bodies of `openers`, in order, from `cursor` (just past the
    newline ending their line). Returns `(end, True)` past the last
    terminator, or `(cursor, False)` at the first body with no terminator.

    `no_terminator_from` is the failed-terminator memo shared by every body
    search over one text: a `(indent flag, marker)` search that found nothing
    from `p` finds nothing from any later position either, so it is never
    repeated."""
    for match in openers:
        key = (match.group(1) == "-", _heredoc_marker(match))
        failed = no_terminator_from.get(key)
        if failed is not None and cursor >= failed:
            return cursor, False
        end = _terminator_re(match).search(text, cursor)
        if end is None:
            no_terminator_from[key] = cursor
            return cursor, False
        cursor = end.end()
    return cursor, True


def _strip_span_bodies(text, start, end, spans):
    """`text[start:end]` with the interior of each backtick span in `spans`
    (in order, all inside that range) replaced by its own
    `strip_heredoc_bodies`: a heredoc inside a span takes its body from the
    span's own lines, so a body that terminates before the span ends is
    stripped and one that does not keeps its text.

    EXCEPT where a stripped body may hold commands bash runs, which the old
    reading (span bodies kept as text) exposed: a span holding a `$(` or an
    escaped backtick (an unquoted-delimiter body expands them), or one whose
    own commands include a shell reading its script from stdin
    (`` x=`bash <<EOF … EOF` ``, where the glued first word `` x=`bash ``
    hides the shell from `command_pipelines`' own check). Such a span is kept
    whole — the over-arm direction, and safe for quoting: the span bounds its
    body's quotes either way."""
    pieces = []
    for span_start, span_end in spans:
        pieces.append(text[start:span_start])
        inner = text[span_start:span_end]
        stripped = strip_heredoc_bodies(inner)
        if stripped != inner and (
            "$(" in inner
            or "\\`" in inner
            or any(
                _reads_script_from_stdin(argv)
                for pipeline in _pipelines(_tokens(stripped))
                for argv in pipeline
            )
        ):
            stripped = inner
        pieces.append(stripped)
        start = span_end
    pieces.append(text[start:end])
    return "".join(pieces)


def heredoc_openers(text, bodies_stripped=False, include_spans=False):
    """Return the `HEREDOC_OPENER` match objects for every live heredoc opener
    in `text` (outside quotes, `#` comments, arithmetic, `${…}` and — unless
    `include_spans=True` — backtick spans), skipping over terminated heredoc
    bodies just as `strip_heredoc_bodies` does (unless `bodies_stripped=True`,
    when the bodies have already been removed), with the same failed-terminator
    memo (`_consume_bodies`).

    `include_spans=True` requires `bodies_stripped=True` (raises `ValueError`
    otherwise): span bodies are stripped per-span by `strip_heredoc_bodies`, so
    afterward a single scan yields outer and backtick-span openers in text
    order for callers that rejoin emptied lines (`lossy-pipe-guard.sh`)."""
    if include_spans and not bodies_stripped:
        raise ValueError("include_spans requires bodies_stripped=True")
    if "<<" not in text:
        return []
    if include_spans:
        result = []
        skip_until = 0
        for kind, ch, i, ctx in _scan(text, descend_dq=True):
            if i < skip_until or kind != "char":
                continue
            if ch == "<" and ctx[0] not in _NO_COMMENT:
                match = HEREDOC_OPENER.match(text, i)
                if match is not None:
                    result.append(match)
                    skip_until = match.end()
        return result
    result = []
    pos = 0
    state = _ScanState(None, len(text))
    no_terminator_from = {}
    while pos < len(text):
        openers, newline = _next_heredoc_line(text, pos, state)
        if not openers:
            break
        result.extend(openers)
        if newline == -1:
            break
        if bodies_stripped:
            pos = newline + 1
            continue
        cursor, terminated = _consume_bodies(
            text, openers, newline + 1, no_terminator_from
        )
        pos = cursor if terminated else newline + 1
    return result


def strip_heredoc_bodies(text):
    """Return `text` with every heredoc BODY removed, terminator line included.

    A QUOTED-delimiter heredoc body (`<<'EOF'` / `<<"EOF"`) is DATA — bash
    executes no word in it however command-shaped it looks. The companion to
    `substitution_spans`: the repo's canonical commit form is
    `git commit -m "$(cat <<'EOF' … EOF)"`, so a caller scanning that span would
    otherwise scan the commit MESSAGE, and a message discussing git commit
    habits would arm a blocking guard. Pinned by the strip_heredoc_bodies cases
    in tests/shell_quotes_cases.py and by "a heredoc BODY inside a span is not
    a target" in hooks/lossy-pipe-guard.probe.sh.

    An UNQUOTED delimiter (`<<EOF`) is the one exception to "body is data": bash
    performs command/parameter substitution inside it exactly as in a
    double-quoted string, so a genuinely-executing `$(git …)` there is stripped
    as if inert — an accepted UNDER-arm. It matches what the guards' own
    top-level heredoc collapse already does, needs deliberate nested
    construction to reach, and sits inside the habitual-shapes threat model the
    consumers state; not verified against a runtime repro, argued from bash's
    documented expansion rules.

    Handles `<<MARKER`, `<<'MARKER'`, `<<"MARKER"` and the `<<-` indent form.
    The terminator must be the whole line; leading tabs are tolerated only
    for `<<-`, matching bash.

    Openers are recognized only at outside-quote (plus `$(…)` inside double
    quotes), outside-comment, outside-backtick, and outside-arithmetic/param
    positions using the shared scanner (`_scan`), so a
    `<<word` inside `# <<word`, `"a <<word"`, `'<<word'` or `$((1<<2))` never
    consumes the lines that follow. Every opener on a logical line is collected
    and their bodies are consumed in order after the unquoted newline ending
    that line (`cmd <<A <<B` strips body A then body B), resuming the scan
    after the last terminator. A backtick span is a string bash parses on its
    own, so a heredoc inside one takes its body from the span's own lines:
    each span's interior is stripped by its own recursive call.

    An UNTERMINATED heredoc KEEPS the text after the opener rather than dropping
    it — the same over-arm direction as the sibling `strip_heredocs` in
    pr-merge-review-check.sh, and for the same reason. Keeping the tail can only
    ADD text a guard scans (over-block, recoverable); dropping it can hide a
    target (a bypass, the one direction this must never take). Pinned by
    "a target after an unterminated heredoc opener still matches" in
    shellQuotes.test.ts and by the equivalent probe cases.
    """
    if "<<" not in text:
        return text  # no opener can match without `<<`
    out = []
    pos = 0
    state = _ScanState(None, len(text))
    no_terminator_from = {}
    while True:
        state.spans = []
        openers, newline = _next_heredoc_line(text, pos, state)
        if not openers or newline == -1:
            out.append(_strip_span_bodies(text, pos, len(text), state.spans))
            return "".join(out)
        # Keep the redirection operator(s) and the rest of the logical line
        # carrying them; only what the operators INTRODUCE is data.
        out.append(_strip_span_bodies(text, pos, newline + 1, state.spans))
        cursor, terminated = _consume_bodies(
            text, openers, newline + 1, no_terminator_from
        )
        if not terminated:
            # Unterminated: keep everything after the last consumed body (or
            # opener line) instead of dropping it.
            out.append(text[cursor:])
            return "".join(out)
        pos = cursor


def substitution_spans_matching(raw_text, predicate):
    """True if any command substitution in `raw_text`, cleaned as bash sees it,
    satisfies `predicate` (a text -> bool test).

    Both blocking guards need the identical thing — scan each `$(…)`/backtick
    span for their own target — and had the same three-step loop copy-pasted;
    this module exists BECAUSE three copies of quote logic diverged once, so the
    loop lives here rather than in each hook.

    The cleaning mirrors what a guard already does to the command itself, in the
    same order:

    1. strip heredoc bodies from the WHOLE raw command FIRST, so a `$(git …)`
       sitting in inert heredoc DATA is gone before extraction and cannot be
       pulled out as a span (a per-span strip cannot see it — the extracted span
       carries no heredoc marker). This is what keeps a documented bypass
       example inside a heredoc'd commit message from false-blocking.
    2. extract the substitution spans that remain, and strip heredoc bodies from
       each extracted span as well (an opener inside a quoted `"$(cat <<'EOF'
       …)"` span is inside outer quotes at step 1 and becomes top-level once the
       span is unwrapped).
    3. strip_quoted each span, so a quoted argument that merely MENTIONS the
       target (`$(gh pr comment --body "…git commit…")`) is inert prose. None
       means an unbalanced quote inside the span; fall back to the raw span so a
       broken quote state over-arms rather than escaping.

    Pinned by the substitution-span cases in hooks/lossy-pipe-guard.probe.sh
    (heredoc-body, single-quoted-span and quoted-prose cases) and in
    tests/shell_quotes_cases.py.
    """
    for span in substitution_spans(strip_heredoc_bodies(raw_text)):
        span = strip_heredoc_bodies(span)
        scanned = strip_quoted(span)
        if predicate(scanned if scanned is not None else span):
            return True
    return False


# A wrapper is a command whose STRING ARGUMENT bash then executes as a command
# in its own right. `eval` takes it directly; the shells take it after `-c`.
_WRAPPER_SHELLS = ("bash", "sh", "zsh", "dash", "ksh")

# `-c` as bash accepts it, including a short-option cluster ending in it
# (`bash -lc "…"`, `sh -ec "…"`). Matching the cluster over-arms — a flag
# spelled `-abc` that is not really `-c` would still have its next word
# scanned — which only ever ADDS text to scan.
_DASH_C = re.compile(r"^-[A-Za-z]*c$")

# Characters that end a word AND a command, so the next word is at command
# position. `(` is included because `(cmd)` and `$(cmd)` both start one.
_WORD_SEPARATORS = ";&|\n()"

# A leading env-assignment word (`VAR=value`) does NOT consume command
# position: bash runs `VAR=1 bash -c "…"` with the assignment applied to the
# wrapper, so the wrapper is still a wrapper and its string argument is still
# a command. Reading the assignment word itself as the command name hid every
# wrapper standing behind one — measured, `FOO=1 bash -c "git add tracker/ &&
# git commit -m x"` yielded no segments at all, so a blocking consumer saw
# nothing to assess. Spelled to match the assignment class the consuming
# hooks' own bypass patterns already use (`ASSIGNMENTS` in
# Tzurot's board-commit-branch-gate.sh).
_ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

# Recursion bound for wrappers nested inside wrappers, matching the intent of
# `extract`'s cap in pr-merge-review-check.sh: a fixed ceiling so a pathological
# input cannot recurse without end. Depth 0 is the command itself, so three
# levels of wrapper get unwrapped and a fourth is left as the placeholder text
# the caller's own quote strip produced for it — an under-arm at a nesting
# depth no habitual command shape reaches.
MAX_WRAPPER_DEPTH = 3


def _words(text):
    """Split `text` into bash words, with `None` marking a command separator.

    Each word is its VALUE as bash would compute it — quotes removed, escapes
    resolved, adjacent pieces concatenated — because that value is what bash
    runs and what a wrapper hands to a new shell. `"pnpm tracker task create"`
    and `pnpm\\ tracker\\ task\\ create` are the same word here, as they are to
    bash.

    Deliberately NOT a general tokenizer: it knows quoting (via the shared
    scanner) and unquoted whitespace and separators, and nothing else.
    Redirections, assignments, and expansions are left as ordinary words —
    `wrapped_command_strings` only needs to recognize a command name, a flag,
    and the word after it.

    An unterminated quote ends the scan where it opens, so the trailing text is
    dropped. That is the same direction `strip_quoted` takes on unbalanced
    quotes, and the caller keeps the whole quote-stripped command as its first
    segment regardless, so nothing a balanced command contains can be hidden.

    Comments, `$'…'`/`$"…"` and the `&` of a redirection (`2>&1`, `&>f`) are
    read as bash reads them; see `_scan_events(bash_words=True)` and `_tokens`.
    `&&`, `||` and `|&` are ONE separator each.
    """
    return [None if isinstance(t, _Op) else t for t in _tokens(text)]


class _Op(str):
    """A control operator in `_tokens` output (`;`, `&`, `|`, `&&`, `||`,
    `|&`, `;;`, `(`, `)`, newline), as distinct from a word with that value."""


# Operators that join two commands into one pipeline.
_PIPE_OPS = ("|", "|&")

# The word `_tokens` puts at command position in front of text glued after a
# `$(…)`, so that text reads as arguments of no program.
_SUBSTITUTION_REST = "$(…)"


def _tokens(text):
    """`_words` with each separator kept as an `_Op` naming the operator, so a
    reader can tell a pipe (`|`, `|&`) from a list separator (`;`, `&&`, …)."""
    events = list(_scan(text))
    tokens = []
    value = []
    started = False

    def flush():
        if started:
            tokens.append("".join(value))

    def char_at(k):
        if 0 <= k < len(events) and events[k][0] == "char":
            return events[k][1]
        return None

    k = 0
    while k < len(events):
        kind, payload, _pos, ctx = events[k]
        if kind in ("quoted", "escape", "run"):
            # A quoted span starts a word even when empty: `cmd ""` passes one
            # empty argument, and dropping it would shift the `-c` lookahead.
            # A `run` is a stretch of plain word characters.
            if not started:
                started, value = True, []
            value.append(payload)
        elif kind == "char":
            nxt = char_at(k + 1)
            redirect_amp = payload == "&" and (
                (char_at(k - 1) or "") in ("<", ">") or nxt == ">"
            )
            if payload in " \t":
                flush()
                started, value = False, []
            elif payload in _WORD_SEPARATORS and not redirect_amp:
                flush()
                started, value = False, []
                op = payload
                if payload == "|" and nxt in ("|", "&"):
                    op, k = "|" + nxt, k + 1
                elif payload == "&" and nxt == "&":
                    op, k = "&&", k + 1
                elif payload == ";" and nxt in (";", "&"):
                    op, k = ";" + nxt, k + 1
                tokens.append(_Op(op))
                if payload == ")" and ctx[0] in ("subst", "arith_subst"):
                    # Text glued after a `$(…)` (`/proc/$(pgrep x)/fd`) is the rest
                    # of a WORD, not a new command: a placeholder takes command
                    # position so `/fd` is never read as the program `fd`.
                    after = events[k + 1] if k + 1 < len(events) else None
                    if after and (after[0] in ("quoted", "escape", "run") or (
                            after[0] == "char" and after[1] not in " \t\n;&|()<>")):
                        tokens.append(_SUBSTITUTION_REST)
            else:
                if not started:
                    started, value = True, []
                value.append(payload)
        # A `continuation` splices the lines with nothing between them, so it
        # neither ends the current word nor contributes to it.
        k += 1
    flush()
    return tokens


def wrapped_command_strings(text):
    """Return the argument of every wrapper invocation in `text`, unquoted.

    A wrapper is recognized only at COMMAND POSITION — the start of `text` or
    just after a separator — so `echo bash -c "…"` yields nothing: that `bash`
    is an argument being printed, not a shell being run. A leading path is
    tolerated (`/bin/sh -c "…"`), because it is the same program.

    `eval` concatenates its arguments with spaces and executes the result, and
    so does this: `eval rm -rf x` yields `rm -rf x`. `trap` runs its first
    argument later (`trap 'rm -rf "$tmp"' EXIT` yields `rm -rf "$tmp"`), except
    in its `-p`/`-l` listing forms. `watch` without `-x`/`--exec` joins its
    arguments into an `sh -c` string, so `watch -n 5 'rm -rf x'` yields `rm -rf x`.

    Runner prefixes (`sudo`, `timeout 60`, `env -i`, `nice -n 5`, …;
    `unwrap_runners`) are skipped first, so `sudo bash -c "…"` is a wrapper.
    A shell reading its script from stdin also counts: its here-string
    (`bash <<< "…"`) and, over-arming on purpose, the arguments of an `echo` or
    `printf` piped straight into it (`echo "…" | bash`).

    PUBLIC because a second caller needs it directly: Tzurot's board-commit-branch-gate.sh
    wants the RAW, unquoted inner string rather than `executed_segments`' already
    quote-stripped segments — it builds its own resolvable `strip_quoted_indexed`
    view per level so a quoted pathspec inside a wrapper still resolves back to
    a real path, which a pre-stripped segment cannot supply.

    A leading env-assignment word (`VAR=value`, one or more) is skipped rather
    than treated as the command: bash still runs the WORD AFTER it at command
    position, so `FOO=1 bash -c "…"` is still a wrapper invocation.
    """
    return _wrapped_strings(_pipelines(_tokens(text)))


def _wrapped_strings(pipelines):
    """`wrapped_command_strings` over text already split by `_pipelines`, so
    a caller holding the pipelines does not tokenize the text twice."""
    found = []
    for pipeline in pipelines:
        upstream = None
        for raw in pipeline:
            argv, info = unwrap_runners(raw)
            name = argv[0].rsplit("/", 1)[-1] if argv else ""
            if "watch" in info["runners"] and not info["watch_exec"] and argv:
                # Without -x/--exec, watch joins its args with spaces and runs them via
                # `sh -c`: `watch -n 5 'rm -rf x'` runs rm.
                found.append(" ".join(argv))
            if name == "eval":
                if len(argv) > 1:
                    found.append(" ".join(argv[1:]))
            elif name == "trap":
                # `trap ACTION SIG…` runs ACTION later (on EXIT, a signal), so it is a
                # command. `trap -p`/`-l` take no action; `trap - SIG` and `trap '' SIG`
                # yield nothing harmful. A lone operand is really a sigspec to reset;
                # splitting it anyway only adds text to scan.
                args = argv[1:]
                if args[:1] == ["--"]:
                    args = args[1:]
                elif args and re.match(r"^-[lp]+$", args[0]):
                    args = []
                if args:
                    found.append(args[0])
            elif name in _WRAPPER_SHELLS:
                for j in range(1, len(argv)):
                    if _DASH_C.match(argv[j]):
                        if j + 1 < len(argv):
                            found.append(argv[j + 1])
                        break
                if _reads_script_from_stdin(argv):
                    found.extend(_here_strings(argv))
                    if upstream and upstream[0].rsplit("/", 1)[-1] in ("echo", "printf"):
                        args = upstream[1:]
                        while args and re.match(r"^-[neE]+$", args[0]):
                            args = args[1:]
                        if args:
                            found.append(" ".join(args))
            upstream = argv
    return found


def _here_strings(argv):
    """The text of each here-string (`<<< word`, `<<<word`) in `argv`."""
    found = []
    for j, word in enumerate(argv):
        opener = re.match(r"^\d*<<<", word)
        if not opener:
            continue
        if word == opener.group(0):
            if j + 1 < len(argv):
                found.append(argv[j + 1])
        else:
            found.append(word[opener.end() :])
    return found


def executed_segments(text):
    """Return every command text bash would EXECUTE from `text`, scan-ready.

    The first element is always `text` with its quoted spans stripped — what a
    structural scan has always read. Each further element is the argument of a
    wrapper invocation (`bash -c`, `sh -c`, `zsh -c`, `eval`), itself stripped
    the same way, recursively.

    WHY A SCAN NEEDS MORE THAN strip_quoted
    ---------------------------------------
    Stripping quoted spans is what makes `echo "pnpm tracker task create x"`
    inert: the argument is data the command prints, and letting its CONTENT
    decide a structural question is the bug this whole module exists for. But
    the same strip erases `bash -c "pnpm tracker task create x"`, where the
    identical characters are a command bash runs. The strip cannot tell those
    apart on its own — only knowing which commands EXECUTE a string argument
    can, which is what `wrapped_command_strings` supplies.

    A caller scans every returned segment, so a target anywhere in the chain is
    seen. `echo` is not a wrapper, so its argument stays a placeholder and the
    inert case above stays inert.

    WHAT THIS DOES NOT SEE
    ----------------------
    A wrapper whose argument is built rather than written — `bash -c "$CMD"`,
    `eval "$(…)"` — yields the placeholder or the substitution text, not the
    command that eventually runs. Nothing textual can resolve that; the
    consumers' threat model is habitual command shapes, and `substitution_spans`
    covers the substitution half for the callers that want it.

    Recursion stops at `MAX_WRAPPER_DEPTH`; see that constant.

    Pinned by the wrapper cases in packages/tooling/src/dev/shellQuotes.test.ts
    and by the wrapped-tracker-mutation fixtures in Tzurot's
    .claude/hooks/cwd-drift-guard.probe.sh (the plugin's cwd-drift-guard did not
    port the tracker refusal, so it has no such fixtures).
    """
    return _executed_segments(text, 0)


def _executed_segments(text, depth):
    scanned = strip_quoted(text)
    # An unterminated quote strips NOTHING, so fall back to the raw text: for
    # every consumer that is the over-arming direction, the same one
    # `substitution_spans_matching` takes for a broken span.
    segments = [text if scanned is None else scanned]
    if depth >= MAX_WRAPPER_DEPTH:
        return segments
    for inner in wrapped_command_strings(text):
        segments.extend(_executed_segments(inner, depth + 1))
    return segments


# Reserved words that can open a simple command without being its program:
# `if rm -rf x; then …`, `do rm -rf "$d"; done`, `{ rm -rf x; }`, `! cmd`.
# Dropped from the front of an argv so argv[0] is the program bash runs.
_LEADING_KEYWORDS = frozenset(
    ("!", "{", "}", "if", "then", "elif", "else", "while", "until", "do", "time")
)

# Shells that run a script read from stdin when given no script operand
# (`cat <<'EOF' | bash`, `bash <<'EOF'`, `sh -s <<EOF`).
_STDIN_SHELLS = ("bash", "sh", "zsh", "dash", "ksh")

# A redirection word: an operator alone (`<<`, `2>`) takes the NEXT word as its
# target; an operator glued to its target (`<<EOF`, `2>/dev/null`) is one word.
_REDIRECT_OPERATOR = re.compile(r"^\d*(?:<<<|<<-?|<>|<|>>|>|&>>?)$")
_REDIRECT_WORD = re.compile(r"^\d*(?:<|>|&>)")


def _pipelines(tokens):
    """Group `_tokens` output into pipelines, each a list of argv lists (one
    per simple command, leading reserved words dropped). Commands joined by
    `|`/`|&` share a pipeline; every other operator ends one. Empty commands
    vanish."""
    pipelines = []
    pipeline = []
    current = []
    for token in tokens + [_Op(";")]:
        if isinstance(token, _Op):
            while current and current[0] in _LEADING_KEYWORDS:
                current = current[1:]
            if current:
                pipeline.append(current)
            current = []
            if token not in _PIPE_OPS and pipeline:
                pipelines.append(pipeline)
                pipeline = []
        else:
            current.append(token)
    return pipelines


# Programs that run the command in their trailing arguments. Per runner: the
# short and long options that take a SEPARATE value, the options that change
# the directory the command runs in, and (xargs) the long options known to take
# none. `timeout` also takes a positional duration; `parallel` takes its inputs
# after `:::`; `distrobox enter NAME … -- cmd` is handled on its own.
_RUNNERS = {
    "sudo": ({"-u", "-g", "-C", "-D", "-p", "-U", "-r", "-t", "-T"},
             {"--user", "--group", "--close-from", "--chdir", "--prompt", "--other-user",
              "--role", "--type", "--host", "--command-timeout"},
             {"-D", "--chdir"}),
    "doas": ({"-u", "-C"}, set(), set()),
    "env": ({"-u", "-C", "-S"}, {"--unset", "--chdir", "--split-string"}, {"-C", "--chdir"}),
    "nice": ({"-n"}, {"--adjustment"}, set()),
    "nohup": (set(), set(), set()),
    "setsid": (set(), set(), set()),
    "coproc": (set(), set(), set()),
    "command": (set(), set(), set()),
    "builtin": (set(), set(), set()),
    "exec": ({"-a"}, set(), set()),
    "time": ({"-f", "-o"}, {"--format", "--output"}, set()),
    "timeout": ({"-s", "-k"}, {"--signal", "--kill-after"}, set()),
    "ionice": ({"-c", "-n", "-p", "-P", "-u"}, {"--class", "--classdata", "--pid", "--pgid", "--uid"}, set()),
    "stdbuf": ({"-i", "-o", "-e"}, {"--input", "--output", "--error"}, set()),
    "watch": ({"-n", "-q"}, {"--interval", "--equexit"}, set()),
    "pkexec": (set(), {"--user"}, set()),
    "unbuffer": (set(), set(), set()),
    "xargs": ({"-I", "-n", "-P", "-L", "-d", "-E", "-s", "-a"},
              {"--max-args", "--max-procs", "--max-lines", "--delimiter", "--eof", "--max-chars",
               "--arg-file", "--process-slot-var"},
              set()),
    "parallel": ({"-j", "-N", "-n", "-P", "-S", "-L", "-l", "-d", "-E", "-I", "-a", "-s"},
                 {"--jobs", "--max-args", "--sshlogin", "--delimiter", "--arg-file", "--colsep",
                  "--max-replace-args", "--tag-string", "--joblog", "--results", "--timeout",
                  "--retries", "--delay", "--tmpdir", "--workdir", "--basefile", "--halt"},
                 set()),
}
_XARGS_NO_VALUE_LONG = {
    "--null", "--no-run-if-empty", "--verbose", "--interactive", "--exit", "--open-tty",
    "--show-limits", "--replace", "--help", "--version",
}


def unwrap_runners(argv):
    """Strip leading `VAR=val` assignments and runner prefixes from one simple
    command; return `(argv, info)` with argv[0] the program that really runs.

    `info` holds: `runners` (names stripped, in order); `stdin` (True when the
    command's trailing arguments also come from stdin — xargs, or parallel
    without `:::`); `arg_file` (xargs/parallel `-a FILE`: they come from a
    file); `chdir` (a runner changed the directory: `env -C`, `sudo -D`);
    `fanout` (xargs or parallel runs the command once per input); `watch_exec`
    (watch was given `-x`/`--exec`, so it runs argv directly instead of joining
    it into an `sh -c` string).

    Option values are consumed per runner (`_RUNNERS`), so `xargs -n 1 rm` runs
    rm, not `1`. An xargs long option not known to take no value consumes the
    next word too (conservative: an unknown value would otherwise become the
    program). `env -S 'cmd args'` splits its string into the command.
    """
    info = {"runners": [], "stdin": False, "arg_file": False, "chdir": False, "fanout": False,
            "watch_exec": False}
    argv = list(argv)
    while argv:
        if _ASSIGNMENT.match(argv[0]):
            argv.pop(0)
            continue
        name = argv[0].rsplit("/", 1)[-1]
        if name in ("distrobox", "distrobox-enter"):
            rest = argv[1:] if name == "distrobox-enter" else argv[2:]
            if (name == "distrobox-enter" or argv[1:2] == ["enter"]) and "--" in rest:
                info["runners"].append("distrobox")
                argv = rest[rest.index("--") + 1 :]
                continue
            break
        spec = _RUNNERS.get(name)
        if spec is None:
            break
        short_values, long_values, chdirs = spec
        info["runners"].append(name)
        argv = argv[1:]
        while argv and argv[0].startswith("-") and argv[0] != "-":
            flag = argv.pop(0)
            if flag == "--":
                break
            if flag.startswith("--"):
                key, has_value = flag.split("=", 1)[0], "=" in flag
                if key in chdirs:
                    info["chdir"] = True
                if key in ("--arg-file",):
                    info["arg_file"] = True
                if name == "watch" and key == "--exec":
                    info["watch_exec"] = True
                takes = key in long_values or (name == "xargs" and key not in _XARGS_NO_VALUE_LONG)
                value = flag.split("=", 1)[1] if has_value else None
                if takes and not has_value and argv:
                    value = argv.pop(0)
                if key == "--split-string" and value is not None:
                    argv = [w for w in _words(value) if w is not None] + argv
                continue
            short = flag[:2]
            if short in chdirs:
                info["chdir"] = True
            if short == "-a" and name in ("xargs", "parallel"):
                info["arg_file"] = True
            if name == "watch" and "x" in flag[1:].split("n", 1)[0]:  # -x, -tx (not -n's value)
                info["watch_exec"] = True
            value = None
            if flag in short_values and argv:
                value = argv.pop(0)
            elif short in short_values and len(flag) > 2:
                value = flag[2:]
            if name == "env" and short == "-S" and value is not None:
                argv = [w for w in _words(value) if w is not None] + argv
        if name == "timeout" and argv:
            argv = argv[1:]  # the duration
        if name in ("xargs", "parallel"):
            info["fanout"] = True
            inputs = next((j for j, w in enumerate(argv) if re.match(r"^::::?\+?$", w)), None)
            if name == "parallel" and inputs is not None:
                argv = argv[:inputs] + [w for w in argv[inputs:] if not re.match(r"^::::?\+?$", w)]
            else:
                info["stdin"] = True
    return argv, info


def strip_redirections(args):
    """`args` without redirections (`2>&1`, `>` `file`, `<<EOF`, …)."""
    kept = []
    skip = False
    for word in args:
        if skip:
            skip = False
        elif _REDIRECT_OPERATOR.match(word):
            skip = True
        elif not _REDIRECT_WORD.match(word):
            kept.append(word)
    return kept


def _reads_script_from_stdin(argv):
    """True when `argv` runs a shell whose script is its stdin: a shell with no
    `-c` and no script operand (redirections aside), or one given `-s`."""
    argv, _ = unwrap_runners(argv)
    if not argv or argv[0].rsplit("/", 1)[-1] not in _STDIN_SHELLS:
        return False
    operands = []
    rest = argv[1:]
    j = 0
    while j < len(rest):
        word = rest[j]
        if _REDIRECT_OPERATOR.match(word):
            j += 2
            continue
        if _REDIRECT_WORD.match(word):
            j += 1
            continue
        if _DASH_C.match(word):
            return False
        if word in ("-o", "+o", "-O", "+O"):
            j += 2  # `set -o`-style option name, not a script operand
            continue
        if word == "-s" or (word.startswith("-") and not word.startswith("--") and "s" in word):
            return True
        if word == "-" or not word.startswith("-"):
            operands.append(word)
        j += 1
    return not operands or operands[0] == "-"


def simple_commands(text):
    """Return every simple command bash would EXECUTE from `text`, as argv
    lists of word VALUES (quotes removed, escapes resolved).

    THE command splitter for the seyag plugin's argv-reading guards
    (cache-rm-redirect.sh, broad-walk-guard.sh, recursive-rm-guard.sh), so the
    boundaries are defined once. They each carried a private `shlex` splitter
    with `whitespace_split`, which reads an unquoted newline as ordinary
    whitespace: `cd /tmp` NEWLINE `rm -rf x/__pycache__` glued the second line
    onto `cd`'s argv and passed the guard (measured, both hooks).

    Boundaries, as bash draws them:
    - an unquoted newline, `;`, `&`, `|`, `&&`, `||`, `|&`, `(`, `)` end a
      command; a newline inside quotes does not, and neither does the `&` of a
      redirection (`2>&1`, `&>file`);
    - a backslash-newline continues the same command (bash deletes the pair);
    - leading reserved words (`if`, `then`, `do`, `{`, `!`, `time`, …) are
      dropped, so argv[0] is the program;
    - heredoc BODIES are data and are not split into commands
      (`strip_heredoc_bodies`), EXCEPT when a command in the text is a shell
      reading its script from stdin (`cat <<'EOF' | bash`, `bash <<'EOF'`,
      `sh -s <<EOF`): then bash runs the body, so the bodies are split too.
      That covers every heredoc in the text, not only the one fed to the
      shell — an over-arm, the recoverable direction;
    - the string argument of a wrapper (`bash -c`, `sh -c`, `zsh -c`, `eval`,
      a `trap` action, `watch`'s joined arguments, also behind a runner such as `sudo`/`timeout`; a
      here-string or an `echo … |` fed to a shell; `wrapped_command_strings`) is split as
      commands in its own right, recursively to `MAX_WRAPPER_DEPTH`.

    An UNTERMINATED quote ends the scan where it opens (the `_words` rule):
    the commands before it are returned, the text after it is not.

    A `#` that starts a word begins a comment to the end of the line, as in
    bash, so nothing in a comment is a command and an apostrophe in it opens
    no quote.

    NOT SEEN: a command inside a QUOTED substitution (`echo "$(rm -rf x)"`)
    or a backtick span (an unquoted `$(…)` is split at its parens and seen);
    a command a script FILE runs.
    """
    return [argv for pipeline in command_pipelines(text) for argv in pipeline]


def command_pipelines(text):
    """`simple_commands`, grouped by pipeline: a list of pipelines, each the
    list of argv lists `|`/`|&` join, in order. A consumer that must know what
    feeds a command's stdin (`find … | xargs rm`) reads this."""
    return _command_pipelines(text, 0)


def _command_pipelines(text, depth):
    body_free = strip_heredoc_bodies(text)
    pipelines = _pipelines(_tokens(body_free))
    if body_free != text and any(
        _reads_script_from_stdin(c) for pipeline in pipelines for c in pipeline
    ):
        pipelines = _pipelines(_tokens(text))
    if depth < MAX_WRAPPER_DEPTH:
        # `pipelines` is exactly `_pipelines(_tokens(scanned text))`, so the
        # wrapper strings come from it rather than from a second tokenization;
        # the list is complete before the loop extends `pipelines`.
        for inner in _wrapped_strings(pipelines):
            pipelines.extend(_command_pipelines(inner, depth + 1))
    return pipelines
