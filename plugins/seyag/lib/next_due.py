"""Due-time ## Next items: claude-role's parser for them, shared with any launcher that reads the json form.

A role file's "## Next" bullet (a "- " or "N. " line, optionally indented, outside a code fence;
"## Next steps" is another section) carrying "(due YYYY-MM-DD HH:MM)" or "(due YYYY-MM-DD)"
(00:00 local) is due once that local time has passed. Only the first marker on a line counts.

CLI:  python3 -I next_due.py lines FILE [NOW_EPOCH]   SessionStart "Due now" lines, or nothing
      python3 -I next_due.py json FILE NOW_EPOCH      [{stamp, age, text}] for a launcher, or nothing
NOW_EPOCH empty or absent means the real clock.
"""
import datetime
import json
import re
import sys
import time

MARKER = re.compile(r"(?<!\w)\(due (\d{4}-\d{2}-\d{2})(?: (\d{2}):(\d{2}))?\)")  # not "d(due …)"
CLOSING = "Do the due item first; when done, delete its bullet or drop its (due …) marker."


def due_items(raw, now_ep):
    """(stamp "YYYY-MM-DD HH:MM", due epoch, bullet text) for each passed marker, in file order."""
    lines = raw.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    body = lines.index("---", 1) + 1 if lines and lines[0] == "---" and "---" in lines[1:] else 0
    heads, unfenced, fence = [], set(), ""
    for i in range(body, len(lines)):  # CommonMark fences, as claude-role's own scan reads them
        m = re.match(r" {0,3}(`{3,}|~{3,})(.*)$", lines[i])
        if m and not fence and not (m[1][0] == "`" and "`" in m[2]):
            fence = m[1]
        elif m and fence and m[1][0] == fence[0] and len(m[1]) >= len(fence) and not m[2].strip():
            fence = ""
        elif not fence:
            unfenced.add(i)
            if lines[i].startswith("## "):
                heads.append(i)
    out = []
    for start in (i for i in heads if re.match(r"## Next[ \t]*$", lines[i])):
        stop = next((i for i in heads if i > start), len(lines))
        for i in range(start + 1, stop):
            bm = re.match(r"^[ \t]*(?:-|\d+\.) (.*)$", lines[i]) if i in unfenced else None
            dm = MARKER.search(bm.group(1)) if bm else None
            if not dm:
                continue
            hh, mm = int(dm.group(2) or 0), int(dm.group(3) or 0)
            try:
                due = datetime.datetime.fromisoformat(dm.group(1)).replace(hour=hh, minute=mm)
            except ValueError:  # not a calendar date, or HH/MM out of range
                continue
            due_ep = int(due.timestamp())
            if due_ep <= now_ep:
                out.append((f"{dm.group(1)} {hh:02d}:{mm:02d}", due_ep, bm.group(1)))
    return out


def due_lines(raw, now_ep):
    """The SessionStart block: one "Due now" line per passed item plus the closing line, or ""."""
    items = due_items(raw, now_ep)
    if not items:
        return ""
    return "".join(f"Due now (## Next, due {s}): {t}\n" for s, _, t in items) + CLOSING + "\n"


def _age(mins):
    return f"{mins}m ago" if mins < 60 else f"{mins // 60}h ago" if mins < 1440 else f"{mins // 1440}d ago"


def main(argv):
    if len(argv) not in (3, 4) or argv[1] not in ("lines", "json"):
        sys.exit("usage: next_due.py lines|json FILE [NOW_EPOCH]")
    now_ep = int(argv[3]) if len(argv) == 4 and argv[3] else int(time.time())
    try:
        raw = open(argv[2], encoding="utf-8", errors="replace").read()
    except OSError:
        return  # a missing or unreadable role file has nothing due; the callers lint those
    if argv[1] == "lines":
        sys.stdout.write(due_lines(raw, now_ep))
        return
    items = [{"stamp": s, "age": _age(max(0, (now_ep - e) // 60)), "text": t[:120]}
             for s, e, t in due_items(raw, now_ep)]
    if items:
        print(json.dumps(items, ensure_ascii=False))


if __name__ == "__main__":
    main(sys.argv)
