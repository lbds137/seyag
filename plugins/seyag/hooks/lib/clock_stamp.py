"""Judge the clock stamps that an Edit, Write or MultiEdit adds (clock-stamp-guard.sh).

stdin: the PreToolUse payload. SYG_CLOCK_STAMP_PATHS_FILE: the glob config.
SYG_CLOCK_STAMP_NOW: optional epoch override of now. SYG_CLOCK_STAMP_HINT: optional
text appended to the block message. Exit 2 with the message on stderr when an added
stamp breaks a rule; exit 0 otherwise, and exit 0 on any internal error (fail open).
The stamp form and the rules are described in the shell header.
"""

import bisect
import datetime as dt
import fnmatch
import itertools
import json
import os
import re
import sys
import time
from collections import Counter, namedtuple

GRACE_S = 60
BANNER = "clock-stamp-guard: BLOCKED. This edit adds a clock stamp that was not read from the clock:"
READ_LINE = "Read the time with `date`, or use a tool that stamps it."
PLACEHOLDER_RULE = "placeholder: an x stands for a digit of the time"

STAMP_RE = re.compile(
    r"(?<![\d-])"
    r"(?:(?P<year>\d{4})-)?(?P<mon>\d{2})-(?P<day>\d{2})"
    r"(?P<sep>[ T])"
    r"(?P<hh>[\dxX]{2}):(?P<mm>[\dxX]{2})"
    r"(?::(?P<ss>[\dxX]{2})(?:\.(?P<frac>\d+))?)?"
    r"(?P<zone>Z|[+-]\d{2}:\d{2})?"
    r"(?!\d)",
    re.ASCII,
)
# Markup that may precede a line-leading stamp, then at most one leading word.
MARKUP_RE = re.compile(r"\s*(?:(?:[-*+>]|#+)[ \t]|\*\*|__|_)*[ \t]*")
WORD_RE = re.compile(r"\S+\s+")
FENCE_RE = re.compile(r"[ \t]*(`{3,}|~{3,})(.*)$")
HEADING_RE = re.compile(r"^ {0,3}##[ \t]+(.*?)(?:[ \t]+#+)?\s*$")
# A task checkbox after the markup: its line's stamp is a schedule, never line-leading.
CHECKBOX_RE = re.compile(r"\[[ xX]\]\s")

Stamp = namedtuple("Stamp", "text year mon day hh mm ss frac zone placeholder")
Occ = namedtuple("Occ", "line kind text stamp")


def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace", newline="") as f:
            return f.read()
    except OSError:
        return None


def load_config(path):
    """Return (globs, section names) from the paths file; a missing file is empty."""
    globs, names = [], set()
    text = read_text(path) if path else None
    if text is None:
        return globs, names
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("section:"):
            name = line[len("section:"):].strip()
            if name:
                names.add(name)
            continue
        globs.append(line)
    return globs, names


def expand_glob(glob, home):
    """Expand a leading ~ to HOME; None when the glob needs HOME and HOME is empty."""
    if glob == "~" or glob.startswith("~/"):
        if not home:
            return None
        if glob == "~":
            return home
        return home.rstrip("/") + glob[1:]
    return glob


def blank_spans(line):
    """Replace inline code spans (backtick run to the next run of the same length) with letters.

    The letters make the span one word for the line-leading check, and no stamp can match
    inside them.
    """
    if "`" not in line:
        return line
    out = list(line)
    n = len(line)
    i = 0
    while i < n:
        if line[i] != "`":
            i += 1
            continue
        j = i
        while j < n and line[j] == "`":
            j += 1
        run = j - i
        k = j
        end = -1
        while k < n:
            if line[k] != "`":
                k += 1
                continue
            m = k
            while m < n and line[m] == "`":
                m += 1
            if m - k == run:
                end = m
                break
            k = m
        if end < 0:
            i = j
            continue
        for p in range(i, end):
            out[p] = "c"
        i = end
    return "".join(out)


def _fence_open(line):
    """The fence run when the line opens a fenced block, else None.

    A backtick fence whose info string holds any backtick is an inline span on one
    line, not a fence.
    """
    m = FENCE_RE.match(line)
    if not m:
        return None
    run, rest = m.group(1), m.group(2)
    if run[0] == "`" and "`" in rest:
        return None
    return run


def _fence_step(fence, line):
    """The fence state after line, given the open fence run (or None) before it."""
    if fence is None:
        return _fence_open(line)
    s = line.strip()
    if s and set(s) == {fence[0]} and len(s) >= len(fence):
        return None
    return fence


def fenced_flags(lines, fence=None):
    """True for each line inside a fenced block (fence lines included).

    fence is the fence run already open before the first line, or None.
    """
    flags = []
    for line in lines:
        before = fence
        fence = _fence_step(fence, line)
        flags.append(before is not None or fence is not None)
    return flags


def _date_ok(year, mon, day):
    try:
        dt.date(int(year) if year else 2000, mon, day)
    except ValueError:
        return False
    return True


def _fill_ok(digits, hi):
    """True when some fill of the x/X holes yields a value in 0..hi (no holes: the value itself)."""
    holes = [i for i, c in enumerate(digits) if c in "xX"]
    for fill in itertools.product("0123456789", repeat=len(holes)):
        chars = list(digits)
        for i, c in zip(holes, fill):
            chars[i] = c
        if int("".join(chars)) <= hi:
            return True
    return False


def _offset_ok(zone):
    """A +-HH:MM offset in the real range -12:00 to +14:00 with minutes under 60."""
    hh, mm = int(zone[1:3]), int(zone[4:6])
    if mm > 59 or hh > 23:
        return False
    minutes = (hh * 60 + mm) * (1 if zone[0] == "+" else -1)
    return -720 <= minutes <= 840


def parse_stamp(m):
    g = m.groupdict()
    if not _date_ok(g["year"], int(g["mon"]), int(g["day"])):
        return None
    if not (_fill_ok(g["hh"], 23) and _fill_ok(g["mm"], 59)):
        return None
    if g["ss"] is not None and not _fill_ok(g["ss"], 59):
        return None
    placeholder = any(c in "xX" for c in g["hh"] + g["mm"] + (g["ss"] or ""))
    text = m.group(0)
    zone = g["zone"]
    if zone and zone != "Z":
        # An offset is kept after T, or after a space when the stamp has seconds, and
        # only in range; otherwise it is trimmed off.
        if (g["sep"] != "T" and g["ss"] is None) or not _offset_ok(zone):
            text = text[: m.start("zone") - m.start()]
            zone = None
    return Stamp(text, g["year"], g["mon"], g["day"], g["hh"], g["mm"],
                 g["ss"], g["frac"], zone, placeholder)


def _is_leading(line, markup_end, start):
    if CHECKBOX_RE.match(line, markup_end):
        return False
    if start == markup_end:
        return True
    m = WORD_RE.match(line, markup_end)
    return m is not None and m.end() == start


def occurrences(masked):
    """Occ for each judged stamp in the masked lines.

    kind is 'placeholder' (any position) or 'leading' (real digits, line-leading).
    Mid-line real stamps are not judged and are left out.
    """
    out = []
    for idx, line in enumerate(masked):
        if not line.strip():
            continue
        markup_end = MARKUP_RE.match(line).end()
        for m in STAMP_RE.finditer(line):
            st = parse_stamp(m)
            if st is None:
                continue
            if st.placeholder:
                kind = "placeholder"
            elif _is_leading(line, markup_end, m.start()):
                kind = "leading"
            else:
                continue
            out.append(Occ(idx, kind, st.text, st))
    return out


class Scan:
    """One text, scanned once: lines, fenced flags, judged stamps and headings."""

    def __init__(self, text, fence=None):
        self.text = text
        self.lines = text.split("\n")
        self.flags = fenced_flags(self.lines, fence)
        self.masked = [" " * len(s) if f else blank_spans(s) for s, f in zip(self.lines, self.flags)]
        self.head_idx, self.head_start, self.head_name = [], [], []
        pos = 0
        for i, (s, f) in enumerate(zip(self.lines, self.flags)):
            if not f:
                m = HEADING_RE.match(s)
                if m:
                    self.head_idx.append(i)
                    self.head_start.append(pos)
                    self.head_name.append(m.group(1))
            pos += len(s) + 1
        self.occ = occurrences(self.masked)

    def section_above(self, idx):
        """Name of the last '## ' heading above line idx, or None."""
        k = bisect.bisect_left(self.head_idx, idx)
        return self.head_name[k - 1] if k else None

    def section_before(self, off):
        """Name of the last '## ' heading that starts before character offset off, or None."""
        k = bisect.bisect_left(self.head_start, off)
        return self.head_name[k - 1] if k else None


def added(new, old):
    """Occurrences in new whose key (kind, text) survives the multiset subtraction of old.

    Every occurrence in new that carries a surviving key is returned, so each such line
    is judged.
    """
    remaining = Counter((o.kind, o.text) for o in old.occ)
    seen, surviving = set(), []
    for o in new.occ:
        key = (o.kind, o.text)
        if remaining[key] > 0:
            remaining[key] -= 1
        elif key not in seen:
            seen.add(key)
            surviving.append(key)
    grouped = {}
    for o in new.occ:
        grouped.setdefault((o.kind, o.text), []).append(o)
    return [o for key in surviving for o in grouped[key]]


def _tz_of(st):
    if st.zone is None:
        return None
    if st.zone == "Z":
        return dt.timezone.utc
    sign = 1 if st.zone[0] == "+" else -1
    return dt.timezone(sign * dt.timedelta(hours=int(st.zone[1:3]), minutes=int(st.zone[4:6])))


def _epoch(naive, tz):
    if tz is None:
        return naive.astimezone().timestamp()
    return naive.replace(tzinfo=tz).timestamp()


def instant(st, now):
    """Epoch of a real stamp. An MM-DD stamp takes the candidate year nearest to now."""
    tz = _tz_of(st)
    frac = float("0." + st.frac) if st.frac else 0.0
    ss = int(st.ss) if st.ss else 0
    if st.year:
        years = [int(st.year)]
    else:
        now_year = dt.datetime.fromtimestamp(now, tz).year if tz else dt.datetime.fromtimestamp(now).year
        years = [now_year - 1, now_year, now_year + 1]
    best = None
    for y in years:
        try:
            naive = dt.datetime(y, int(st.mon), int(st.day), int(st.hh), int(st.mm), ss)
        except ValueError:
            continue
        ep = _epoch(naive, tz) + frac
        if st.year:
            return ep
        d = abs(ep - now)
        if best is None or d < best[0]:
            best = (d, ep)
    return None if best is None else best[1]


def section_matches(sec, names):
    """True when heading text sec is a configured name, or starts with one followed by a space, a tab or '('."""
    return any(sec == n or (sec.startswith(n) and sec[len(n):len(n) + 1] in (" ", "\t", "("))
               for n in names)


def violations_for(new, old, now, names, section_of):
    out = []
    for o in added(new, old):
        if o.kind == "placeholder":
            out.append((o.text, PLACEHOLDER_RULE, new.lines[o.line]))
            continue
        if names:
            sec = section_of(o.line)
            if sec is not None and not section_matches(sec, names):
                continue
        try:
            ep = instant(o.stamp, now)
        except Exception:
            continue
        if ep is not None and ep > now + GRACE_S:
            out.append((o.text, "future: %d s ahead of now" % int(ep - now), new.lines[o.line]))
    return out


class Text:
    """One state of the file's text: the disk text, or the working text after earlier MultiEdit
    edits (built from a string). Its text is read on first use from the path; its Scan is built
    only if a section lookup needs it, and its per-line fence table only if a fence lookup needs
    it. All cached."""

    def __init__(self, path=None, text=None):
        self.path = path
        self._read = path is None
        self._text = text
        self._scanned = False
        self._scan = None
        self._starts = None
        self._befores = None

    @property
    def text(self):
        if not self._read:
            self._text = read_text(self.path)
            self._read = True
        return self._text

    def scan(self):
        if not self._scanned:
            self._scanned = True
            self._scan = Scan(self.text) if self.text is not None else None
        return self._scan

    def fence_at(self, off):
        """The fence run open before the disk line holding character offset off, or None."""
        if self._starts is None:
            starts, befores = [], []
            fence, pos = None, 0
            for line in self.text.split("\n"):
                starts.append(pos)
                befores.append(fence)
                fence = _fence_step(fence, line)
                pos += len(line) + 1
            self._starts, self._befores = starts, befores
        return self._befores[bisect.bisect_right(self._starts, off) - 1]


def section_for_edit(new, idx, state, off):
    """Section of new line idx: its own heading above, else the heading before off in state's text."""
    name = new.section_above(idx)
    if name is None and off >= 0:
        scan = state.scan()
        if scan is not None:
            name = scan.section_before(off)
    return name


def match_offsets(text, old, replace_all):
    """Offsets of old in text, as str.replace finds them: left to right, non-overlapping.
    Only the first when replace_all is false."""
    offs = []
    i = text.find(old)
    while i >= 0:
        offs.append(i)
        if not replace_all:
            break
        i = text.find(old, i + len(old))
    return offs


def replaced(text, old, new_s, replace_all):
    """text after one Edit: the first occurrence of old becomes new_s, or every one when replace_all."""
    return text.replace(old, new_s) if replace_all else text.replace(old, new_s, 1)


def edit_blocks(state, old, new_s, replace_all, now, names):
    """Violations of one Edit against state's text. Each occurrence of old is judged inside its
    own line: the text before and after it on that line wraps both new_s and old, under the fence
    open at the line's start (no newline is added, so line indexes hold). Blocks identical to one
    an earlier occurrence gave are reported once."""
    text = state.text if old else None
    offs = match_offsets(text, old, replace_all) if text is not None else []
    if not offs:
        new = Scan(new_s)
        return violations_for(new, Scan(old), now, names,
                              lambda i, n=new: section_for_edit(n, i, state, -1))
    blocks = []
    for off in offs:
        ls = text.rfind("\n", 0, off) + 1
        end = off + len(old)
        le = text.find("\n", end)
        if le < 0:
            le = len(text)
        prefix, suffix = text[ls:off], text[end:le]
        fence = state.fence_at(ls)
        new = Scan(prefix + new_s + suffix, fence)
        old_scan = Scan(prefix + old + suffix, fence)
        got = violations_for(new, old_scan, now, names,
                             lambda i, n=new, o=off: section_for_edit(n, i, state, o))
        blocks += [b for b in got if b not in blocks]
    return blocks


def now_epoch():
    raw = os.environ.get("SYG_CLOCK_STAMP_NOW", "").strip()
    if re.fullmatch(r"-?\d+", raw):
        return int(raw)
    return int(time.time())


def local_now(now):
    d = dt.datetime.fromtimestamp(now).astimezone()
    return d.strftime("%Y-%m-%d %H:%M:%S ") + (d.tzname() or d.strftime("%z"))


def render(blocks, now):
    out = [BANNER]
    for text, rule, line in blocks:
        out.append("  %s  %s" % (text, rule))
        out.append("      line: %s" % line.strip()[:200])
    out.append("now: " + local_now(now))
    out.append(READ_LINE)
    hint = os.environ.get("SYG_CLOCK_STAMP_HINT", "").strip()
    if hint:
        out.append(hint)
    return "\n".join(out) + "\n"


def check(payload):
    if not isinstance(payload, dict):
        return None
    tool = payload.get("tool_name")
    if tool not in ("Edit", "Write", "MultiEdit"):
        return None
    tin = payload.get("tool_input")
    if not isinstance(tin, dict):
        return None
    file_path = tin.get("file_path")
    if not isinstance(file_path, str) or not file_path:
        return None
    globs, names = load_config(os.environ.get("SYG_CLOCK_STAMP_PATHS_FILE", ""))
    if not globs:
        return None
    cwd = payload.get("cwd")
    if not isinstance(cwd, str) or not cwd:
        cwd = os.getcwd()
    abs_path = os.path.abspath(os.path.join(cwd, file_path))
    real = os.path.realpath(abs_path)
    home = os.environ.get("HOME", "")
    pats = [p for p in (expand_glob(g, home) for g in globs) if p]
    if not any(fnmatch.fnmatchcase(c, p) for p in pats for c in (abs_path, real)):
        return None

    now = now_epoch()
    state = Text(path=abs_path)
    blocks = []
    if tool == "Write":
        new = Scan(tin.get("content") if isinstance(tin.get("content"), str) else "")
        blocks = violations_for(new, state.scan() or Scan(""), now, names, new.section_above)
    else:
        if tool == "Edit":
            pairs = [(tin.get("old_string"), tin.get("new_string"), tin.get("replace_all") is True)]
        else:
            edits = tin.get("edits") if isinstance(tin.get("edits"), list) else []
            pairs = [(e.get("old_string"), e.get("new_string"), e.get("replace_all") is True)
                     for e in edits if isinstance(e, dict)]
        # Edits run in order, each against the text the earlier edits leave (the disk text for the first).
        for old, new_text, replace_all in pairs:
            old = old if isinstance(old, str) else ""
            new_s = new_text if isinstance(new_text, str) else ""
            blocks += edit_blocks(state, old, new_s, replace_all, now, names)
            if tool == "MultiEdit":
                # Only MultiEdit consults this text again (its later edits are judged
                # against it); a single Edit has no later pair, so the running text is
                # never rebuilt for it.
                if old and state.text is not None and old in state.text:
                    state = Text(text=replaced(state.text, old, new_s, replace_all))
                elif not old and not state.text:
                    # An empty old_string on a missing or empty file creates it: its text is the new text.
                    state = Text(text=new_s)
    if not blocks:
        return None
    return render(blocks, now)


def main():
    try:
        msg = check(json.loads(sys.stdin.read()))
    except Exception:
        return 0
    if msg:
        sys.stderr.write(msg)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
