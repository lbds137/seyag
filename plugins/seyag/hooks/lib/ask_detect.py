"""Shared AskUserQuestion field walker and `!` command / fenced-block detectors.

Used by:
  - hooks/ask-command-echo-check.sh (Stop)
  - hooks/ask-pretext-guard.sh (PreToolUse:AskUserQuestion)
  - hooks/ask-pretext-reminder.sh (PostToolUse:AskUserQuestion)

No top-level side effects: importing this module runs nothing.
"""

import re
import string

prose_tokens = {"line", "lines", "command", "commands", "prefix", "prefixed"}
# A space after the bang: `!guild_id` is code negation, not a command
# (every real `!` line measured carried one).
cmd_re = re.compile(r"(?:^|(?<=[\s(`]))!\s+([A-Za-z0-9~./$_-][^\s`]*)")


def ask_fields(inp, include_header=False):
    if not isinstance(inp, dict):
        return
    for q in inp.get("questions") or []:
        if not isinstance(q, dict):
            continue
        if isinstance(q.get("question"), str):
            yield q["question"]
        if include_header and isinstance(q.get("header"), str):
            yield q["header"]
        for opt in q.get("options") or []:
            if not isinstance(opt, dict):
                continue
            for k in ("label", "description", "preview"):
                if isinstance(opt.get(k), str):
                    yield opt[k]


def commands_in(text):
    out = []
    for line in text.splitlines():
        pos = 0
        while True:
            m = cmd_re.search(line, pos)
            if not m:
                break
            bang = m.start()
            if bang > 0 and line[bang - 1] == "`":
                close = line.find("`", bang)
                end = len(line) if close == -1 else close
            else:
                end = len(line)
            pos = max(end, m.end())
            first = m.group(1).lower().rstrip(string.punctuation)
            if first in prose_tokens:
                continue
            # A command closing a question or a parenthesis keeps none of it.
            key = re.sub(r"\s+", " ", line[bang + 1:end].lstrip()).rstrip(" .,;:?!)")
            if len(key) >= 2:
                out.append(key)
    return out


def fenced_blocks(text: str) -> list[list[str]]:
    blocks: list[list[str]] = []
    cur: list[str] = []
    in_fence = False
    for ln in text.splitlines():
        s = ln.strip()
        if s.startswith("```") or s.startswith("~~~"):
            if in_fence:
                if cur:
                    blocks.append(cur)
                cur = []
                in_fence = False
            else:
                cur = []
                in_fence = True
            continue
        if in_fence and s:
            cur.append(s)
    return blocks
