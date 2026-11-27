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
#     backtick, then at least one space (`!flag` is code negation), then a
#     first token that is not prose ("the one ! line"). Inside
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
# The command match is loose: a fenced line that CONTAINS the key satisfies it,
# and so does a fenced line of at least 6 chars that is a whole-word prefix of
# the key (the ask's unbackticked line can run on into prose), so a shorter echo
# can pass; accepted under fail-open. With a blank or absent envelope field
# (the fallback path), the judged closing is the last transcript text after the
# last ask; when that search finds no text — for instance when the closing was
# recorded only as signed-empty thinking blocks, an Anthropic-lane shape
# (TASK-67) — the fenced list comes out empty and the gate
# blocks once. Accepted: fail-closed on an unreadable closing, bounded by the
# block-once guard; the retry is not guaranteed readable text.
#
# Enforcement geometry mirrors blocking-question-channel-check.sh: a tail read of
# the transcript, a strict turn boundary (no genuine user entry found → silent),
# fail-open on every external failure (no jq, no python3, unreadable or
# unparseable transcript).
#
# Block-once is per ask, not per stop chain: asks often happen inside a retry that
# another Stop hook triggered, so the stop that follows them carries
# `stop_hook_active: true` and a flag-based exit would never judge them. The hook
# judges every stop and blocks at most once per LAST AskUserQuestion of the turn
# (its tool_use id, else a hash of its input), remembered in a state file under
# ${XDG_STATE_HOME:-~/.local/state}/seyag/ask-command-echo-check/<session key>.
# If that file cannot be written it blocks only when `stop_hook_active` is false.
# State files older than 7 days are pruned on each write (same convention as
# cwd-drift-guard).
# A "Stop hook feedback:" user entry is not a turn boundary.
#
# Pinned by ask-command-echo-check.probe.sh.

set -uo pipefail

INPUT=$(cat)

ACTIVE=$(jq -r '.stop_hook_active // false' <<<"$INPUT" 2>/dev/null || echo "false")

TRANSCRIPT=$(jq -r '.transcript_path // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ] && exit 0
# Stop envelope's last_assistant_message: closing text before the async transcript catches up.
LAM=$(jq -r '.last_assistant_message // empty' <<<"$INPUT" 2>/dev/null || echo "")

HOOKS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK_LIB="$HOOKS_DIR/lib"

VERDICT=$(HOOK_LIB="$HOOK_LIB" TRANSCRIPT="$TRANSCRIPT" LAM="$LAM" python3 -I "${SYG_PY_CACHE_ARG:--B}" << 'PYEOF'
import hashlib, json, os, re, sys

sys.path.insert(0, os.environ["HOOK_LIB"])
from ask_detect import ask_fields, commands_in  # noqa: E402


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
        fb = "Stop hook feedback:"
        if isinstance(content, str):
            return len(content.strip()) > 0 and not content.lstrip().startswith(fb)
        if isinstance(content, list):
            for b in content:
                if isinstance(b, dict) and b.get("type") == "text":
                    return not str(b.get("text") or "").lstrip().startswith(fb)
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
    last_ask_id = ""
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
                last_ask_id = block.get("id") if isinstance(block.get("id"), str) else ""
                text_after_ask = ""
            elif block.get("type") == "text":
                text_after_ask = block.get("text", "") or ""
    if not ask_inputs:
        return "ok"

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
        for text in ask_fields(inp):
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
    ident = last_ask_id.strip()
    if not ident:
        ident = "sha1:" + hashlib.sha1(
            json.dumps(ask_inputs[-1], sort_keys=True).encode("utf-8", "replace")
        ).hexdigest()
    ident = re.sub(r"\s+", "", ident)
    return "miss:" + ident + "\n" + "\n".join(f"{k}\t{key[:200]}" for k, key in missing)


try:
    print(judge())
except Exception:
    print("ok")
PYEOF
) || exit 0

case $VERDICT in
  miss:*) ;;
  *) exit 0 ;;
esac
IDENT=${VERDICT%%$'\n'*}
IDENT=${IDENT#miss:}
BODY=${VERDICT#*$'\n'}

# Block once per ask: skip when the state file already holds this ask's identity.
SESSION_ID=$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null || echo "")
SKEY=${SESSION_ID:-$(basename "$TRANSCRIPT")}
SKEY=$(printf '%s' "$SKEY" | tr -c 'A-Za-z0-9._-' '_')
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/seyag/ask-command-echo-check"
STATE_FILE="$STATE_DIR/$SKEY"
if [ -f "$STATE_FILE" ] && [ "$(head -n 1 "$STATE_FILE" 2>/dev/null)" = "$IDENT" ]; then
  exit 0
fi
write_state() {
  local tmp
  mkdir -p "$STATE_DIR" || return 1
  # Prune regular files (not symlinks) older than 7 days; errors ignored.
  find "$STATE_DIR" -maxdepth 1 -type f -mtime +7 -exec rm -f -- {} + 2>/dev/null || true
  # Atomic write: temp file in the state dir, then rename onto the state file.
  tmp=$(mktemp "$STATE_DIR/.tmp.XXXXXX") || return 1
  if printf '%s\n' "$IDENT" >"$tmp" && mv -f "$tmp" "$STATE_FILE"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}
if ! write_state 2>/dev/null; then
  # State unwritable: fall back to the native once-per-stop-chain rule, never fail closed.
  [ "$ACTIVE" = "true" ] && exit 0
fi

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
done <<<"$BODY"
cat >&2 << 'MSG'

Repeat each one now in a fenced code block (a link may instead stand
alone on its own line), then end the turn. If a line was illustrative
(nothing the user runs or opens), say so in one line and stop again (this
gate fires only once per ask).
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
MSG
exit 2
