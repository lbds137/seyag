#!/bin/bash
# Stop hook: when a turn writes a handoff but the closing assistant message
# names no next-session pick, block the stop once and remind.
#
# Trigger — both conditions must hold in the current turn:
#   (a) A tool_use block in the current turn wrote a handoff: an Edit, Write,
#       MultiEdit or NotebookEdit whose `.input.file_path` (or
#       `.input.notebook_path`) matches SYG_HANDOFF_PATHS (a Python regex) and,
#       on the wired SYG_HANDOFF_PATHS branch, whose `.input` strings or
#       resolved file section matches SYG_HANDOFF_SECTIONS (a multiline Python
#       regex, default `^##[ \t]*(?:Handoff|Next)\b`), or a Bash tool_use whose
#       `.input.command` matches SYG_HANDOFF_CMDS (a Python regex, e.g.
#       `myrole --set`).
#   (b) The turn's final assistant text contains none of the pick tokens:
#       `/clear`, `/compact`, or the standalone word `keep` (case-insensitive,
#       word-bounded).
#
# Toggle: when SYG_HANDOFF_PATHS or SYG_HANDOFF_CMDS is set, matches those
# patterns (replacing the built-in path defaults); when both are unset or empty
# (unwired), falls back to default handoff file paths (HANDOFF.md, handoff.md)
# and appends a one-line setup hint naming SYG_HANDOFF_PATHS and
# SYG_HANDOFF_CMDS (and the built-in pattern to keep the defaults while
# silencing the hint) so an unwired deployment is visible rather than silently
# inert. On the wired SYG_HANDOFF_PATHS branch, SYG_HANDOFF_SECTIONS narrows
# file-tool matches to inputs carrying a matching section heading (unset uses
# the case-sensitive default `^##[ \t]*(?:Handoff|Next)\b`; set-but-empty `""`
# disables narrowing for path-only matching; the built-in default paths, even
# when wired, and SYG_HANDOFF_CMDS Bash writes are not narrowed).
# SYG_DISABLE=handoff-pick-check turns the component off.
#
# Known false negative, accepted: a closing using `keep` in an ordinary sense
# (e.g. "I will keep the old flag") counts as a pick under the word-bounded
# match; the convention states the pick explicitly ("Pick: keep"), block-once
# bounds the miss, and a pick-shaped regex was rejected as brittle. In-section
# Edit/MultiEdit writes without heading lines in their input strings are
# resolved from the file on disk (capped at 1 MiB): a `new_string`/`old_string`
# whose first in-file occurrence lies under a different section than the edited
# one (short or repeated strings) can misresolve; a deletion (`new_string`
# absent, empty, or whitespace-only) whose `old_string` is absent from disk
# passes silently (unlocatable post-edit), while other unresolvable edits fire
# (fail-closed); partially-invalid bytes decode with `errors="replace"` and
# resolve normally (only a wholly-unreadable first MiB fails closed); and the
# 1 MiB cap is not detected — strings beyond it simply resolve as not-found
# (deletions pass, other edits fire); and a `#` line inside a fenced code
# block resolves as a section that cannot match (the block machinery is
# disproportionate for a block-once gate).
#
# Known residual, accepted: the envelope's last_assistant_message is truncated
# for long closings (it ends "… [+N chars]"); a pick token cut by the
# truncation still blocks — the fail-closed direction this gate prefers.
#
# Enforcement geometry mirrors the sibling Stop hooks: a deterministic scan of
# the current turn in a bounded transcript tail, blocking at most once per
# turn-end via the native `stop_hook_active` flag and at most once per handoff
# write via the fire-once memory below. Every external doubt — no jq, no
# python3, missing or unreadable transcript, no genuine user turn boundary in
# the tail, or a broken regex in SYG_HANDOFF_PATHS / SYG_HANDOFF_CMDS /
# SYG_HANDOFF_SECTIONS (a broken SYG_HANDOFF_SECTIONS disables the file branch
# like a broken SYG_HANDOFF_PATHS, never the SYG_HANDOFF_CMDS gate) — exits 0
# (fail-open).
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

INPUT=$(cat)

# Already blocked once this turn-end → allow the stop (no infinite loop).
ACTIVE=$(jq -r '.stop_hook_active // false' <<<"$INPUT" 2>/dev/null || echo "false")
[ "$ACTIVE" = "true" ] && exit 0

TRANSCRIPT=$(jq -r '.transcript_path // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ] && exit 0
# Stop envelope's last_assistant_message: closing text before the async transcript catches up.
LAM=$(jq -r '.last_assistant_message // empty' <<<"$INPUT" 2>/dev/null || echo "")

VERDICT=$(TRANSCRIPT="$TRANSCRIPT" LAM="$LAM" python3 << 'PYEOF'
import json, os, re, sys


def compile_opt(var):
    pat = os.environ.get(var, "")
    if not pat:
        return None
    try:
        return re.compile(pat)
    except (re.error, TypeError, ValueError, RecursionError, OverflowError):
        return None


DEFAULT_HANDOFF_PATHS = re.compile(
    r"(^|/)(?:HANDOFF\.md|handoff\.md)$"
)
DEFAULT_HANDOFF_SECTIONS = re.compile(
    r"^##[ \t]*(?:Handoff|Next)\b", re.MULTILINE
)
raw_paths = os.environ.get("SYG_HANDOFF_PATHS", "")
raw_cmds = os.environ.get("SYG_HANDOFF_CMDS", "")
wired = bool(raw_paths or raw_cmds)
if wired:
    paths_re = compile_opt("SYG_HANDOFF_PATHS")
    cmds_re = compile_opt("SYG_HANDOFF_CMDS")
    if paths_re is None and cmds_re is None:
        print("ok"); sys.exit()
    if paths_re is not None:
        raw_sections = os.environ.get("SYG_HANDOFF_SECTIONS")
        if raw_sections is None:
            sections_re = DEFAULT_HANDOFF_SECTIONS
        elif raw_sections == "":
            sections_re = None
        else:
            try:
                sections_re = re.compile(raw_sections, re.MULTILINE)
            except (re.error, TypeError, ValueError, RecursionError, OverflowError):
                paths_re = None
                sections_re = None
                if paths_re is None and cmds_re is None:
                    print("ok"); sys.exit()
    else:
        sections_re = None
else:
    paths_re = DEFAULT_HANDOFF_PATHS
    cmds_re = None
    sections_re = None

path = os.environ["TRANSCRIPT"]
# Read only the tail: a long session's transcript can be hundreds of MB, and this
# runs at every turn end. Same bound as the sibling Stop hooks.
TAIL_BYTES = 4_000_000
FILE_BYTES = 1_048_576
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


HEADING_RE = re.compile(r"^[ \t]*#{1,6}[ \t].*", re.MULTILINE)


def iter_strings(obj):
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for v in obj.values():
            yield from iter_strings(v)
    elif isinstance(obj, list):
        for item in obj:
            yield from iter_strings(item)


def item_fires(item, text):
    if not isinstance(item, dict):
        return True
    new_str = item.get("new_string")
    is_deletion = not (isinstance(new_str, str) and new_str.strip())
    p = -1
    for key in ("new_string", "old_string"):
        s = item.get(key)
        if isinstance(s, str) and s.strip():
            p = text.find(s)
            if p != -1:
                break
    if p == -1:
        return not is_deletion
    section = None
    for m in HEADING_RE.finditer(text):
        if m.start() <= p:
            section = m.group(0)
        else:
            break
    return bool(section is not None and sections_re.search(section.lstrip()))


def is_handoff_write(block):
    if not isinstance(block, dict) or block.get("type") != "tool_use":
        return False
    name = block.get("name")
    inp = block.get("input")
    if not isinstance(inp, dict):
        return False
    if name in ("Edit", "Write", "MultiEdit", "NotebookEdit") and paths_re is not None:
        fp = inp.get("file_path") or inp.get("notebook_path")
        if not (isinstance(fp, str) and paths_re.search(fp)):
            return False
        if sections_re is None or DEFAULT_HANDOFF_PATHS.search(fp):
            return True
        if any(sections_re.search(s) for s in iter_strings(inp)):
            return True
        if name == "Edit":
            items = [inp]
        elif name == "MultiEdit":
            edits = inp.get("edits")
            if not isinstance(edits, list) or not edits:
                return True
            items = edits
        else:
            return False
        try:
            with open(fp, "rb") as f:
                text = f.read(FILE_BYTES).decode("utf-8", "replace")
        except OSError:
            return True
        if not text.strip("\ufffd"):
            return True
        return any(item_fires(it, text) for it in items)
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

# Closing text: the Stop envelope's last_assistant_message when present, else
# the turn's last text block from the transcript.
lam = os.environ.get("LAM", "")
if lam.strip():
    final_text = lam
else:
    final_text = ""
    for _, entry in turn:
        if entry.get("type") != "assistant":
            continue
        for block in entry.get("message", {}).get("content", []) or []:
            if isinstance(block, dict) and block.get("type") == "text":
                final_text = block.get("text", "")

PICK_RE = re.compile(r"(?<![\w/])/(?:clear|compact)\b|\bkeep\b", re.I)

if PICK_RE.search(final_text):
    print("ok")
elif wired:
    print("missing")
else:
    print("missing:unwired")
PYEOF
) || exit 0

case "$VERDICT" in
  missing | missing:unwired) ;;
  *) exit 0 ;;
esac

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
MSG
if [ "$VERDICT" = "missing:unwired" ]; then
  cat >&2 << 'HINT'
Setup hint: SYG_HANDOFF_PATHS and SYG_HANDOFF_CMDS are unset; set them in settings.json env to wire your project's handoff paths and commands (to keep the built-in defaults and silence this hint, set SYG_HANDOFF_PATHS to the built-in pattern `(^|/)(?:HANDOFF\.md|handoff\.md)$`).
HINT
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
exit 2
