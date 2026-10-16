#!/bin/bash
# Stop hook: when a turn writes a handoff but the closing assistant message
# names no next-session pick, block the stop once and remind.
#
# Trigger — both conditions must hold in the current turn:
#   (a) A tool_use block in the current turn wrote a handoff: an Edit or Write
#       whose `.input.file_path` matches SYG_HANDOFF_PATHS (an ERE), or a Bash
#       tool_use whose `.input.command` matches SYG_HANDOFF_CMDS (an ERE, e.g.
#       `myrole --set`).
#   (b) The turn's final assistant text contains none of the pick tokens:
#       `/clear`, `/compact`, or the standalone word `keep` (case-insensitive,
#       word-bounded).
#
# Toggle: when BOTH SYG_HANDOFF_PATHS and SYG_HANDOFF_CMDS are unset or empty,
# the hook is inert and exits 0 before reading stdin or the transcript. The
# component ships in every profile and ships inert; machine wiring (the
# settings.json `env` block) is what turns it on.
#
# Enforcement geometry mirrors the sibling Stop hooks: a deterministic scan of
# the current turn in a bounded transcript tail, blocking at most once via the
# native `stop_hook_active` flag. Every external doubt — no jq, no python3,
# missing or unreadable transcript, no genuine user turn boundary in the tail,
# or a broken regex in SYG_HANDOFF_PATHS / SYG_HANDOFF_CMDS — exits 0
# (fail-open).
#
# Pinned by handoff-pick-check.probe.sh.
#
# The seyag rules (rules/core.md) § "Sessions and handoffs".

set -uo pipefail

[ -n "${SYG_HANDOFF_PATHS:-}${SYG_HANDOFF_CMDS:-}" ] || exit 0

INPUT=$(cat)

# Already blocked once this turn-end → allow the stop (no infinite loop).
ACTIVE=$(jq -r '.stop_hook_active // false' <<<"$INPUT" 2>/dev/null || echo "false")
[ "$ACTIVE" = "true" ] && exit 0

TRANSCRIPT=$(jq -r '.transcript_path // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ] && exit 0

VERDICT=$(TRANSCRIPT="$TRANSCRIPT" python3 << 'PYEOF'
import json, os, re, sys


def compile_opt(var):
    pat = os.environ.get(var, "")
    if not pat:
        return None
    try:
        return re.compile(pat)
    except (re.error, TypeError, ValueError, RecursionError, OverflowError):
        return None


paths_re = compile_opt("SYG_HANDOFF_PATHS")
cmds_re = compile_opt("SYG_HANDOFF_CMDS")
if paths_re is None and cmds_re is None:
    print("ok"); sys.exit()

path = os.environ["TRANSCRIPT"]
# Read only the tail: a long session's transcript can be hundreds of MB, and this
# runs at every turn end. Same bound as the sibling Stop hooks.
TAIL_BYTES = 4_000_000
try:
    with open(path, "rb") as f:
        f.seek(0, os.SEEK_END)
        size = f.tell()
        f.seek(max(0, size - TAIL_BYTES))
        data = f.read()
except OSError:
    print("ok"); sys.exit()
truncated = size > TAIL_BYTES
lines = data.decode("utf-8", "replace").splitlines()
if truncated and lines:
    lines = lines[1:]  # the first line is cut mid-record


# A user turn carrying real text, not a tool_result envelope — that bounds the
# current turn (same delimiter the sibling Stop hooks use).
def is_genuine_user(entry):
    if entry.get("type") != "user" or entry.get("isMeta"):
        return False
    content = entry.get("message", {}).get("content")
    if isinstance(content, str):
        return len(content.strip()) > 0
    if isinstance(content, list):
        return any(isinstance(b, dict) and b.get("type") == "text" for b in content)
    return False


records = []
for ln in lines:
    ln = ln.strip()
    if not ln:
        continue
    try:
        records.append(json.loads(ln))
    except json.JSONDecodeError:
        continue

turn_start = None
for i in range(len(records) - 1, -1, -1):
    if is_genuine_user(records[i]):
        turn_start = i
        break

if turn_start is None:
    print("ok"); sys.exit()
turn = records[turn_start:]


def is_handoff_write(block):
    if not isinstance(block, dict) or block.get("type") != "tool_use":
        return False
    name = block.get("name")
    inp = block.get("input")
    if not isinstance(inp, dict):
        return False
    if name in ("Edit", "Write") and paths_re is not None:
        fp = inp.get("file_path")
        return isinstance(fp, str) and bool(paths_re.search(fp))
    if name == "Bash" and cmds_re is not None:
        cmd = inp.get("command")
        return isinstance(cmd, str) and bool(cmds_re.search(cmd))
    return False


wrote_handoff = any(
    is_handoff_write(block)
    for entry in turn
    if entry.get("type") == "assistant"
    for block in (entry.get("message", {}).get("content", []) or [])
)

if not wrote_handoff:
    print("ok"); sys.exit()

final_text = ""
for entry in turn:
    if entry.get("type") != "assistant":
        continue
    for block in entry.get("message", {}).get("content", []) or []:
        if isinstance(block, dict) and block.get("type") == "text":
            final_text = block.get("text", "")

PICK_RE = re.compile(r"(?<![\w/])/(?:clear|compact)\b|\bkeep\b", re.I)

print("ok" if PICK_RE.search(final_text) else "missing")
PYEOF
) || exit 0

[ "$VERDICT" = "missing" ] || exit 0

cat >&2 << 'MSG'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
HANDOFF PICK — handoff written without a next-session pick
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
This turn wrote a handoff, but your closing message named no
next-session pick. Name one pick:
  - /clear (unrelated next unit)
  - /compact (same thread)
  - keep (reply due within the hour; warm cache)
The owner runs it — never schedule wakeups to keep the cache warm —
and is every owner directive from this session on disk?

If this write was not a unit-closing handoff, say so in one line and
stop again (this gate fires only once per turn — the next stop
proceeds).
(the seyag rules, rules/core.md § "Sessions and handoffs")
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
MSG
exit 2
