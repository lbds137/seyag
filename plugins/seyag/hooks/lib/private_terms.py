"""The private-terms list: loading, matching and masking. One copy, shared by
hooks/private-term-guard.sh (the text guard) and git-hooks/pre-push (the
enforcement on the bytes git sends).

The terms file (`SYG_PRIVATE_TERMS_FILE`) holds one Python regex per line,
trailing whitespace (and a CR) stripped; blank lines and lines whose first
non-space character is `#` are ignored. Terms match case-INSENSITIVELY; a
`(?-i:...)` term is case-sensitive. A term is named by its number `#N`: its
1-based index among the term lines, comments and blanks not counted. Masking
replaces every match with `[private term #N]`, so no part of a match survives.

No top-level side effects: importing this module runs nothing.
"""

import re

PLACEHOLDER = "[private term #"


def read_terms(path):
    """`[(line number in the file, regex source)]` for the term lines of
    `path`, or None when it cannot be read."""
    try:
        with open(path, "rb") as fh:
            raw = fh.read().decode("utf-8", "replace")
    except OSError:
        return None
    terms = []
    for lineno, line in enumerate(raw.splitlines(), 1):
        line = line.rstrip()
        if not line or line.lstrip().startswith("#"):
            continue
        terms.append((lineno, line))
    return terms


def compile_terms(terms):
    """`(compiled, None)` with `compiled` a list of `(term number, regex)`, or
    `(None, line number)` naming the first term line that does not compile."""
    compiled = []
    for n, (lineno, src) in enumerate(terms, 1):
        try:
            compiled.append((n, re.compile(src, re.IGNORECASE)))
        except Exception:
            return None, lineno
    return compiled, None


def spans(compiled, text):
    """`(start, end, term number)` for every non-empty match in `text`."""
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
