#!/bin/bash
# Stop hook: when an AskUserQuestion in the current turn carried a runnable line
# (a `!` command or a URL) that the closing message does not repeat in a copyable
# form, block the stop once and ask for the repeat.
#
# Why it matters: on a phone client, text inside an AskUserQuestion dialog cannot
# be selected or copied, and text written before the ask is hidden. The owner
# answers the ask, THEN needs the command or link in the turn's closing message
# (the ask is blocking inside a turn: its answer returns as a tool_result and the
# turn continues, so the closing text comes after the answer).
#
# What counts as runnable, per ask (question text, and each option's label,
# description and preview, scanned field by field, never joined):
#   - a `!` command: a `!` at a line start or after whitespace, `(` or a
#     backtick, then a first token that is not prose ("the one ! line"). Inside
#     a backtick span the command ends at the closing backtick, else at the end
#     of the line.
#   - a URL (http/https), unless it is a placeholder (`/i/<code>`), an RFC 2606
#     example/test host, localhost or 127.0.0.1.
# Multi-word backtick spans are NOT a trigger: measured, they are mostly command
# mentions rather than things to run.
#
# What satisfies it, in the closing text (the Stop envelope's
# last_assistant_message when non-blank, else the last text block after the last
# AskUserQuestion): a fenced code block line carrying the command (after
# dropping a leading `!` or `$ `), or for a URL a fenced line holding it or a
# line that is the URL alone. Inline backticks and prose mentions do not count.
#
# Enforcement geometry mirrors blocking-question-channel-check.sh: a tail read of
# the transcript, a strict turn boundary (no genuine user entry found → silent),
# at most one block via the native `stop_hook_active` flag, fail-open on every
# external failure (no jq, no python3, unreadable or unparseable transcript).
#
# Pinned by ask-command-echo-check.probe.sh.

set -uo pipefail

INPUT=$(cat)

# Already blocked once this turn-end → allow the stop (no infinite loop).
ACTIVE=$(jq -r '.stop_hook_active // false' <<<"$INPUT" 2>/dev/null || echo "false")
[ "$ACTIVE" = "true" ] && exit 0

TRANSCRIPT=$(jq -r '.transcript_path // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ] && exit 0
# Stop envelope's last_assistant_message: closing text before the async transcript catches up.
LAM=$(jq -r '.last_assistant_message // empty' <<<"$INPUT" 2>/dev/null || echo "")

VERDICT=$(TRANSCRIPT="$TRANSCRIPT" LAM="$LAM" python3 -I "${SYG_PY_CACHE_ARG:--B}" << 'PYEOF'
import json, os, re, string, sys


def judge():
    path = os.environ["TRANSCRIPT"]
    # Tail read: a long session's transcript can be hundreds of MB and this runs
    # at every turn end.
    tail_bytes = 4_000_000
    with open(path, "rb") as f:
        f.seek(0, os.SEEK_END)
        size = f.tell()
        f.seek(max(0, size - tail_bytes))
        data = f.read()
    lines = data.decode("utf-8", "replace").splitlines()
    if size > tail_bytes and lines:
        lines = lines[1:]  # the first line is cut mid-record

    records = []
    for ln in lines:
        ln = ln.strip()
        if not ln:
            continue
        try:
            rec = json.loads(ln)
        except json.JSONDecodeError:
            continue
        if isinstance(rec, dict):
            records.append(rec)

    # A user entry carrying real text, not a tool_result envelope: the turn boundary.
    def is_genuine_user(entry):
        if entry.get("type") != "user" or entry.get("isMeta"):
            return False
        content = entry.get("message", {}).get("content")
        if isinstance(content, str):
            return len(content.strip()) > 0
        if isinstance(content, list):
            return any(isinstance(b, dict) and b.get("type") == "text" for b in content)
        return False

    turn_start = None
    for i in range(len(records) - 1, -1, -1):
        if not records[i].get("isSidechain") and is_genuine_user(records[i]):
            turn_start = i
            break
    if turn_start is None:
        return "ok"  # strict: only judge asks known to be in this turn
    turn = [e for e in records[turn_start:] if not e.get("isSidechain")]

    # Walk the turn's assistant blocks in order: asks, and the last text after the last ask.
    ask_inputs = []
    text_after_ask = ""
    for entry in turn:
        if entry.get("type") != "assistant":
            continue
        content = entry.get("message", {}).get("content", []) or []
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "tool_use" and block.get("name") == "AskUserQuestion":
                ask_inputs.append(block.get("input") or {})
                text_after_ask = ""
            elif block.get("type") == "text":
                text_after_ask = block.get("text", "") or ""
    if not ask_inputs:
        return "ok"

    def fields(inp):
        if not isinstance(inp, dict):
            return
        for q in inp.get("questions") or []:
            if not isinstance(q, dict):
                continue
            if isinstance(q.get("question"), str):
                yield q["question"]
            for opt in q.get("options") or []:
                if not isinstance(opt, dict):
                    continue
                for k in ("label", "description", "preview"):
                    if isinstance(opt.get(k), str):
                        yield opt[k]

    prose_tokens = {"line", "lines", "command", "commands", "prefix", "prefixed"}
    cmd_re = re.compile(r"(?:^|(?<=[\s(`]))!\s*([A-Za-z0-9~./$_-][^\s`]*)")

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

    url_re = re.compile(r"https?://[^\s<>`\"'\])]+")
    skip_hosts = ("example.com", "example.net", "example.org")
    skip_suffixes = (".example", ".test", ".invalid", ".localhost")

    def urls_in(text):
        out = []
        for m in url_re.finditer(text):
            if text[m.end():m.end() + 1] == "<":
                continue
            url = m.group(0).rstrip(".,;:!?")
            host = re.split(r"[/?#]", url.split("://", 1)[1], maxsplit=1)[0]
            host = host.rsplit("@", 1)[-1]
            host = re.sub(r":\d*$", "", host).lower()
            if host in ("localhost", "127.0.0.1"):
                continue
            if any(host == d or host.endswith("." + d) for d in skip_hosts):
                continue
            if host.endswith(skip_suffixes):
                continue
            out.append(url)
        return out

    keys = []  # (kind, key), deduped, first-seen order
    seen = set()
    for inp in ask_inputs:
        for text in fields(inp):
            for kind, found in (("C", commands_in(text)), ("U", urls_in(text))):
                for key in found:
                    if (kind, key) not in seen:
                        seen.add((kind, key))
                        keys.append((kind, key))
    if not keys:
        return "ok"

    lam = os.environ.get("LAM", "")
    closing = lam if lam.strip() else text_after_ask

    fenced = []
    in_fence = False
    closing_lines = closing.splitlines()
    for ln in closing_lines:
        s = ln.strip()
        if s.startswith("```") or s.startswith("~~~"):
            in_fence = not in_fence
            continue
        if in_fence:
            norm = re.sub(r"^(?:!|\$ )\s*", "", s)
            fenced.append(re.sub(r"\s+", " ", norm).strip())

    def bare_url_line(ln):
        s = re.sub(r"^[-*]\s+", "", ln.strip()).strip()
        return s.strip("`").strip("<>").strip("`")

    def satisfied(kind, key):
        if kind == "C":
            for L in fenced:
                if not L:
                    continue
                if L == key or key in L:
                    return True
                if len(L) >= 6 and key.startswith(L + " "):
                    return True
            return False
        if any(key in L for L in fenced):
            return True
        return any(bare_url_line(ln) == key for ln in closing_lines)

    missing = [(k, key) for k, key in keys if not satisfied(k, key)]
    if not missing:
        return "ok"
    return "miss\n" + "\n".join(f"{k}\t{key[:200]}" for k, key in missing)


try:
    print(judge())
except Exception:
    print("ok")
PYEOF
) || exit 0

case $VERDICT in
  miss*) ;;
  *) exit 0 ;;
esac

cat >&2 << 'MSG'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ASK-DIALOG COMMAND — not repeated in the closing message
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
An AskUserQuestion this turn carried a command or link. Dialog text
can't be copied on a phone, and text written before the ask is hidden
there, so the owner needs it in your closing message.

Missing from the closing message:
MSG
while IFS=$'\t' read -r KIND KEY; do
  case $KIND in
    C) printf >&2 '  ! %s\n' "$KEY" ;;
    U) printf >&2 '  %s\n' "$KEY" ;;
  esac
done <<<"${VERDICT#miss}"
cat >&2 << 'MSG'

Repeat each one now in a fenced code block (a link may instead stand
alone on its own line), then end the turn. If a line was illustrative
(nothing she runs or opens), say so in one line and stop again (this
gate fires only once per turn).
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
MSG
exit 2
