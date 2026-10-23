#!/bin/bash
# Stop hook: when a turn writes a handoff but the closing assistant message
# names no next-session pick, block the stop once and remind.
#
# Trigger — both conditions must hold in the current turn:
#   (a) A tool_use block in the current turn wrote a handoff: an Edit, Write,
#       MultiEdit or NotebookEdit whose `.input.file_path` matches
#       SYG_HANDOFF_PATHS (a Python regex), or a Bash tool_use whose
#       `.input.command` matches SYG_HANDOFF_CMDS (a Python regex, e.g.
#       `myrole --set`).
#   (b) The turn's final assistant text contains none of the pick tokens:
#       `/clear`, `/compact`, or the standalone word `keep` (case-insensitive,
#       word-bounded).
#
# Toggle: when BOTH SYG_HANDOFF_PATHS and SYG_HANDOFF_CMDS are unset or empty,
# the hook is inert and exits 0 before reading stdin or the transcript. The
# component is in the full profile only and ships inert; machine wiring (the
# settings.json `env` block) is what turns it on.
#
# Known false negative, accepted: a closing using `keep` in an ordinary sense
# (e.g. "I will keep the old flag") counts as a pick under the word-bounded
# match; the convention states the pick explicitly ("Pick: keep"), block-once
# bounds the miss, and a pick-shaped regex was rejected as brittle.
#
# Enforcement geometry mirrors the sibling Stop hooks: a deterministic scan of
# the current turn in a bounded transcript tail, blocking at most once per
# turn-end via the native `stop_hook_active` flag and at most once per handoff
# write via the fire-once memory below. Every external doubt — no jq, no
# python3, missing or unreadable transcript, no genuine user turn boundary in
# the tail, or a broken regex in SYG_HANDOFF_PATHS / SYG_HANDOFF_CMDS — exits
# 0 (fail-open).
#
# Fire-once memory: the first reaction to a handoff write is the last.
# Cron/scheduled prompts and stop-hook feedback arrive as isMeta user entries
# and never bound a turn, so poll turn-ends share the last owner turn's
# window; without memory, one write re-arms the gate at every poll stop until
# a closing happens to name a pick. The state file
# ${XDG_STATE_HOME:-~/.local/state}/seyag/handoff-pick-check/<transcript
# basename>.offset holds the byte offset (decimal) of the START of the newest
# matching write record the gate has accounted for — advanced on a fire AND on
# a pick-accompanied pass (a picked write must not re-arm absorbed poll turns
# either). A later evaluation blocks only when a matching write starts PAST
# the stored offset; transcripts append only within a session, so a start
# offset identifies a write. Unreadable, corrupt or unwritable state (the
# directory included) fails open: the gate degrades to firing on every
# evaluation of an unaccounted write, as it did before.
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
base = size - len(data)  # file offset of the tail's first byte
truncated = base > 0
# Split the raw bytes, not the decoded text, so every record keeps its exact
# byte offset in the file (a UTF-8 continuation byte is never 0x0A, so the
# newline split is byte-safe) — the fire-once memory identifies a write by
# where its record starts.
raw_lines = data.split(b"\n")
offsets = []
pos = base
for ln in raw_lines:
    offsets.append(pos)
    pos += len(ln) + 1
lines = [ln.decode("utf-8", "replace") for ln in raw_lines]
if truncated and lines:
    lines = lines[1:]  # the first line is cut mid-record
    offsets = offsets[1:]


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
for off, ln in zip(offsets, lines):
    ln = ln.strip()
    if not ln:
        continue
    try:
        records.append((off, json.loads(ln)))
    except json.JSONDecodeError:
        continue

turn_start = None
for i in range(len(records) - 1, -1, -1):
    if is_genuine_user(records[i][1]):
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
    if name in ("Edit", "Write", "MultiEdit", "NotebookEdit") and paths_re is not None:
        fp = inp.get("file_path") or inp.get("notebook_path")
        return isinstance(fp, str) and bool(paths_re.search(fp))
    if name == "Bash" and cmds_re is not None:
        cmd = inp.get("command")
        return isinstance(cmd, str) and bool(cmds_re.search(cmd))
    return False


# The newest matching write in the window (records are in file order, so the
# last match wins); its record-start byte offset is the write's identity.
newest_write_off = None
for off, entry in turn:
    if entry.get("type") != "assistant":
        continue
    for block in entry.get("message", {}).get("content", []) or []:
        if is_handoff_write(block):
            newest_write_off = off

if newest_write_off is None:
    print("ok"); sys.exit()

state_home = os.environ.get("XDG_STATE_HOME") or "~/.local/state"
state_dir = os.path.join(os.path.expanduser(state_home), "seyag", "handoff-pick-check")
state_file = os.path.join(state_dir, os.path.basename(path) + ".offset")

stored = None
try:
    with open(state_file) as f:
        stored = int(f.read().strip())
except (OSError, ValueError):
    stored = None

if stored is not None and newest_write_off <= stored:
    print("ok"); sys.exit()  # this write already fired (or was picked for)

try:
    os.makedirs(state_dir, exist_ok=True)
    with open(state_file, "w") as f:
        f.write(str(newest_write_off))
except OSError:
    pass  # fail-open: no memory → every turn-end re-fires, as before

final_text = ""
for _, entry in turn:
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
