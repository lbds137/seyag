"""Shared transcript turn-scanning and Bash write-target extraction for Stop hooks.

Extracted from promise-ledger-check.sh (with its behaviour preserved byte-for-byte)
and shared with lesson-claim-check.sh.

Public functions:
    load_records(path)          tail-bounded JSONL read (TAIL_BYTES = 4_000_000)
    is_genuine_user(entry)      True for a non-meta user record carrying text
    current_turn(records)       slice from the last genuine user record (or [])
    closing_text(records, lam)  LAM when non-blank, else last assistant text block
    strip_code(text)            strip fenced code blocks, then inline code spans
    tool_uses(turn)             yield assistant tool_use blocks in the turn
    bash_write_targets(cmd)     strict list of paths a Bash command writes
    command_argvs(cmd)          argv of each simple command, runners unwrapped
"""

import json
import os
import re

from shell_quotes import (
    ESCAPED_BLANK,
    QUOTED_SPAN,
    heredoc_openers,
    simple_commands,
    strip_heredoc_bodies,
    strip_quoted_indexed,
    strip_redirections,
    unwrap_runners,
)

# Read only the tail: a long session's transcript can be hundreds of MB, and Stop
# hooks run at every turn end. Same bound as blocking-question-channel-check.sh.
TAIL_BYTES = 4_000_000

_WRITE_REDIR_OP = re.compile(r"^(?:\d+|&)?>>?$")
_WRITE_REDIR_GLUED = re.compile(r"^(?:\d+|&)?>>?(.+)$")

_PY_OPEN_RE = re.compile(
    r"""\bopen\(\s*(['"])([^'"]+)\1\s*,\s*(?:mode\s*=\s*)?(['"])[wa][^'"]*\3"""
)
_PY_PATH_WRITE_RE = re.compile(
    r"""\bPath\(\s*(['"])([^'"]+)\1\s*\)\s*\.\s*write_(?:text|bytes)\s*\("""
)
_NODE_WRITE_RE = re.compile(
    r"""\b(?:writeFileSync|appendFileSync)\(\s*(['"])([^'"]+)\1"""
)


def is_genuine_user(entry):
    """True when `entry` is a user turn carrying real text, not a tool_result envelope."""
    if entry.get("type") != "user" or entry.get("isMeta"):
        return False
    content = entry.get("message", {}).get("content")
    if isinstance(content, str):
        return len(content.strip()) > 0
    if isinstance(content, list):
        return any(b.get("type") == "text" for b in content)
    return False


def load_records(path):
    """Read up to TAIL_BYTES from the end of `path` and return parsed JSON records,
    or None on OSError. Drops the partial first line when truncated and skips
    undecodable lines."""
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - TAIL_BYTES))
            data = f.read()
    except OSError:
        return None
    truncated = size > TAIL_BYTES
    lines = data.decode("utf-8", "replace").splitlines()
    if truncated and lines:
        lines = lines[1:]  # the first line is cut mid-record
    records = []
    for ln in lines:
        ln = ln.strip()
        if not ln:
            continue
        try:
            records.append(json.loads(ln))
        except json.JSONDecodeError:
            continue
    return records


def current_turn(records):
    """Return the slice of `records` from the last genuine user record onward,
    or `[]` when no genuine user record is present in the window."""
    turn_start = None
    for i in range(len(records) - 1, -1, -1):
        if is_genuine_user(records[i]):
            turn_start = i
            break
    return records[turn_start:] if turn_start is not None else []


def closing_text(records, lam=""):
    """Return `lam` when non-blank, else the last assistant text block anywhere in `records`."""
    if lam and lam.strip():
        return lam
    final_text = ""
    for entry in records:
        if entry.get("type") != "assistant":
            continue
        for block in entry.get("message", {}).get("content", []) or []:
            if block.get("type") == "text":
                final_text = block.get("text", "")
    return final_text


def strip_code(text):
    """Strip fenced code blocks first, then single-line inline backtick spans."""
    text = re.sub(r"```.*?```", "", text, flags=re.S)
    return re.sub(r"`[^`\n]*`", "", text)


def tool_uses(turn):
    """Yield every assistant `tool_use` content block in `turn`."""
    for entry in turn:
        if entry.get("type") != "assistant":
            continue
        for block in entry.get("message", {}).get("content", []) or []:
            if block.get("type") == "tool_use":
                yield block


def _extract_script_writes(text, add_target):
    """Extract literal file targets from Python and Node file-write calls in `text`."""
    for m in _PY_OPEN_RE.finditer(text):
        add_target(m.group(2))
    for m in _PY_PATH_WRITE_RE.finditer(text):
        add_target(m.group(2))
    for m in _NODE_WRITE_RE.finditer(text):
        add_target(m.group(2))


class _Sink:
    """Ordered, de-duplicated write targets, returned exactly as written."""

    def __init__(self, items, seen):
        self.items = items
        self.seen = seen

    def add(self, t):
        if not t:
            return
        if t not in self.seen:
            self.seen.add(t)
            self.items.append(t)


# Quoted spans are swapped for one private-use character per span (see `_tagged`),
# so a tag never equals an operator or a program name, and the tag's index
# recovers the span's value. The range sits outside the BMP-private codepoints
# shell_quotes uses, and `_tagged` refuses input that already contains it.
_TAG_BASE = 0xF0000
_INTERPRETER_RE = re.compile(r"^(?:python3(?:\.\d+)?|python|node|perl|ruby)$")


def _tagged(text):
    """`(scan_text, values)`: `text` with each quoted span replaced by a tag that
    indexes `values`. `(text, None)` when `text` cannot be indexed (an unterminated
    quote, or a character already in the tag range); callers then read it raw."""
    if any(ord(c) >= _TAG_BASE for c in text):
        return text, None
    got = strip_quoted_indexed(text)
    if got is None:
        return text, None
    view, values = got
    out = []
    k = 0
    for ch in view:
        if ch == QUOTED_SPAN:
            out.append(chr(_TAG_BASE + k))
            k += 1
        else:
            out.append(ch)
    return "".join(out), values


def _resolve(word, values):
    """`word` with each tag replaced by its quoted value and each escaped blank by a space."""
    if values is None:
        return word
    out = []
    for ch in word:
        o = ord(ch)
        if _TAG_BASE <= o < _TAG_BASE + len(values):
            out.append(values[o - _TAG_BASE])
        elif ch == ESCAPED_BLANK:
            out.append(" ")
        else:
            out.append(ch)
    return "".join(out)


def _interpreter_heredoc_bodies(cmd):
    """Bodies of heredocs whose command word is a Python, Node, Perl or Ruby interpreter."""
    bodies = []
    for m in heredoc_openers(cmd):
        before = simple_commands(cmd[: m.start()])
        if not before or not before[-1]:
            continue
        argv, _ = unwrap_runners(before[-1])
        if not argv or not _INTERPRETER_RE.match(os.path.basename(argv[0])):
            continue
        nl = cmd.find("\n", m.end())
        if nl < 0:
            continue
        strip_tabs = m.group(1) == "-"
        delim = m.group(3)
        lines = []
        for ln in cmd[nl + 1 :].split("\n"):
            if (ln.lstrip("\t") if strip_tabs else ln) == delim:
                break
            lines.append(ln)
        bodies.append("\n".join(lines))
    return bodies


def _collect(cmd, sink):
    """Add to `sink` every path `cmd` writes, in command order."""
    # Heredoc bodies are data here; the interpreter ones are scanned separately.
    scan_text = strip_heredoc_bodies(cmd)
    text, values = _tagged(scan_text)

    for raw in simple_commands(text):
        if not raw:
            continue

        # 1. Output redirections, read from the tagged words: a quoted `>` carries a
        # tag, so it never equals the operator.
        i = 0
        while i < len(raw):
            w = raw[i]
            if _WRITE_REDIR_OP.match(w):
                if i + 1 < len(raw):
                    t = _resolve(raw[i + 1], values)
                    if t and not t.startswith("&"):
                        sink.add(t)
                i += 2
                continue
            m = _WRITE_REDIR_GLUED.match(w)
            if m:
                # A blank in the target is allowed only when it came from a quoted span
                # (`>'a b.md'`): an unquoted blank would have split the word.
                quoted = values is not None and any(
                    _TAG_BASE <= ord(c) < _TAG_BASE + len(values) for c in m.group(1)
                )
                t = _resolve(m.group(1), values)
                if t and not t.startswith("&") and (quoted or not any(c.isspace() for c in t)):
                    sink.add(t)
            i += 1

        argv_t, _ = unwrap_runners(raw)
        argv_t = strip_redirections(argv_t)
        if not argv_t:
            continue
        argv = [_resolve(w, values) for w in argv_t]
        prog = os.path.basename(argv[0])

        # 2. Inline code of an interpreter: `python3 -c "..."`, `node -e "..."`.
        if _INTERPRETER_RE.match(prog):
            for j in range(1, len(argv) - 1):
                if argv[j] in ("-c", "-e"):
                    _extract_script_writes(argv[j + 1], sink.add)

        # 3. `tee`: every non-option operand in the simple command.
        if prog == "tee":
            opts_done = False
            for a in argv[1:]:
                if not opts_done and a == "--":
                    opts_done = True
                    continue
                if not opts_done and a.startswith("-"):
                    continue
                if a:
                    sink.add(a)
            continue

        # 4. `sed -i` and `perl -i...`: file operands after the script, or all
        # non-option operands when `-e` or `-f` is present.
        if prog in ("sed", "perl"):
            in_place = False
            has_script_opt = False
            operands = []
            opts_done = False
            args = argv[1:]
            j = 0
            while j < len(args):
                a = args[j]
                if opts_done:
                    if a:
                        operands.append(a)
                    j += 1
                    continue
                if a == "--":
                    opts_done = True
                    j += 1
                    continue
                if a.startswith("--") and prog == "sed":
                    if a == "--in-place" or a.startswith("--in-place="):
                        in_place = True
                    elif a in ("--expression", "--file"):
                        has_script_opt = True
                        j += 2
                        continue
                    elif a.startswith(("--expression=", "--file=")):
                        has_script_opt = True
                    j += 1
                    continue
                if a.startswith("-") and a != "-":
                    flags = a[1:]
                    if "i" in flags:
                        in_place = True
                        if prog == "sed" and flags == "i" and j + 1 < len(args) and args[j + 1] == "":
                            j += 2
                            continue
                    pre_i, sep, post_i = flags.partition("i")
                    active_flags = pre_i + ("i" if sep else "")
                    if sep and post_i[:1] in ("p", "n", "e", "E", "f", "r", "s", "z", "u"):
                        active_flags += post_i
                    script_chars = ("e", "f", "E") if prog == "perl" else ("e", "f")
                    if any(c in active_flags for c in script_chars):
                        has_script_opt = True
                        if active_flags[-1:] in script_chars and (
                            not sep or post_i == active_flags[len(pre_i) + 1 :]
                        ):
                            j += 2
                            continue
                    j += 1
                    continue
                if a:
                    operands.append(a)
                j += 1
            if in_place:
                file_ops = operands if has_script_opt else operands[1:]
                for f in file_ops:
                    sink.add(f)
            continue

        # 5. `cp`, `mv` and `install`: the target is the `-t DIR` / `--target-directory`
        # value when given (the operands are then sources), else the last operand.
        if prog in ("cp", "mv", "install"):
            target_dir = None
            operands = []
            opts_done = False
            args = argv[1:]
            j = 0
            while j < len(args):
                a = args[j]
                j += 1
                if opts_done:
                    if a:
                        operands.append(a)
                elif a == "--":
                    opts_done = True
                elif a.startswith("--target-directory="):
                    target_dir = a.split("=", 1)[1]
                elif a == "--target-directory":
                    target_dir = args[j] if j < len(args) else None
                    j += 1
                elif a.startswith("--"):
                    continue
                elif a.startswith("-") and a != "-":
                    # A short cluster: `-t DIR`, `-tDIR`, `-rt DIR`; `-S SUFFIX` takes a value too.
                    for k in range(1, len(a)):
                        if a[k] not in "St":
                            continue
                        rest = a[k + 1 :]
                        if rest:
                            value = rest
                        else:
                            value = args[j] if j < len(args) else None
                            j += 1
                        if a[k] == "t":
                            target_dir = value
                        break
                elif a.startswith("-"):
                    continue
                elif a:
                    operands.append(a)
            if target_dir:
                sink.add(target_dir if target_dir.endswith("/") else target_dir + "/")
                continue
            min_ops = 1 if prog == "install" else 2
            if len(operands) >= min_ops:
                sink.add(operands[-1])
            continue

    for body in _interpreter_heredoc_bodies(cmd):
        _extract_script_writes(body, sink.add)


_AMBIGUOUS_HASH = re.compile(r"(?:^|\s)#")


def _ambiguous(cmd):
    """True when `cmd` holds a construct this reader cannot read with certainty:
    an unbalanced quote, a backslash, `$'`, or a `#` that may start a comment.
    Checked on the raw text, conservatively (a quoted backslash or `#` also counts)."""
    if strip_quoted_indexed(cmd) is None:
        return True
    return "\\" in cmd or "$'" in cmd or bool(_AMBIGUOUS_HASH.search(cmd))


def command_argvs(cmd):
    """argv (word values, runner prefixes unwrapped) of each simple command `cmd`
    runs at top level. `[]` for an ambiguous command, as in `bash_write_targets`."""
    if not cmd or not cmd.strip() or _ambiguous(cmd):
        return []
    scan_text, values = _tagged(strip_heredoc_bodies(cmd))
    out = []
    for raw in simple_commands(scan_text):
        argv, _ = unwrap_runners(raw)
        if argv:
            out.append([_resolve(w, values) for w in argv])
    return out


def bash_write_targets(cmd):
    """Return the list of file paths that `cmd` writes, exactly as written.

    An ambiguous command gives no credit (by design): an unbalanced quote, a
    backslash, `$'`, or a `#` that may start a comment returns `[]`. There is no
    `cd` tracking: a relative target is returned as written, and a `cd` in the
    same command is not applied to it. There is no recursion into `bash -c`,
    `$(...)` or backticks: a write inside them is not reported.

    Recognised write shapes:
    - Redirects: `>`, `>>`, `N>`, `N>>`, `&>`, `&>>` followed by a target not
      starting with `&` (`2>&1` and `>&2` are fd duplications, not file writes).
      Only UNQUOTED operators count: a quoted `'>'` is an argument. A quoted
      target (`> 'hooks/x'`) is still a target.
    - `tee`: every non-option operand in the simple command.
    - `sed -i` and `perl -i...`: the file operands (after the script operand, or
      every non-option operand when `-e` or `-f` is present).
    - `cp`, `mv` and `install`: the `-t DIR` / `--target-directory` value when
      given, else the last non-option operand.
    - Python, Node, Perl and Ruby inline writes: the `-c` / `-e` argument of an
      interpreter (`python`, `python3`, `python3.N`, `node`, `perl`, `ruby`), and the
      body of a heredoc whose command word is one of them. Within that code: first
      string literal of `open(..., 'w'|'a'...)`, string literal in
      `Path("...").write_text(` / `.write_bytes(`, and first string literal of
      `writeFileSync(` / `appendFileSync(`.
      Interpreter-shaped text anywhere else (a commit message, a `cat` heredoc) is not scanned.
    """
    if not cmd or not cmd.strip() or _ambiguous(cmd):
        return []
    sink = _Sink([], set())
    _collect(cmd, sink)
    return sink.items
