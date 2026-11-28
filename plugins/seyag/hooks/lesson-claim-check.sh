#!/bin/bash
# Stop hook: when the agent tries to end a turn whose closing message claims a
# lesson or behaviour change ("lesson learned", "next time I'll …", "I'll
# remember to …", "won't happen again") without a same-turn write to an
# enforcement surface or a filing for one, block the stop once.
#
# Purpose and asymmetry: a session keeps nothing across /clear, so an unbacked
# behaviour-change claim is false the moment the context clears. A false pass
# costs a false belief that survives into future sessions; a false block costs
# one acknowledged turn (`stop_hook_active` lets the second stop through). This
# hook therefore fails toward blocking (under-crediting uncertain Bash shapes).
#
# What credits the turn (same turn only, in this transcript):
#   - (a) an Edit, Write, MultiEdit or NotebookEdit whose file_path (or
#     notebook_path) matches SURFACE_RE;
#   - (b) a Bash tool_use where some path in turn_scan.bash_write_targets(cmd)
#     matches SURFACE_RE;
#   - (c) a Bash tool_use with a simple command whose argv, after runner
#     unwrapping, is `tracker|backlog(.md)? task create|edit` (an optional
#     leading `pnpm`, `npx`, or `npm exec|run`);
#   - (d) a SendMessage tool_use whose input.message matches FILING_RE (an
#     action verb (file, open, create, add) and a filing noun (task, hook,
#     rule, skill, guard, gate, check), or a TASK-N id).
#
# What does NOT credit, by design:
#   - any path outside SURFACE_RE, including notes, role or handoff files and
#     memory directories (notes and memory do not enforce behaviour);
#   - read-only Bash mentions of an enforcement path (including commands with
#     stderr redirects such as `2>&1` or writes to `/dev/null`);
#   - an ambiguous Bash command (an unbalanced quote, a backslash, `$'`, or a
#     `#` that may start a comment), and a write or filing reached only through
#     `cd`, `bash -c`, or a `$(...)` / backtick substitution: under-crediting
#     costs one acknowledged turn;
#   - an edit or filing made by a delegated worker subagent, which lands in
#     another transcript; that case blocks once, and the banner gives the
#     one-line acknowledgement route.
#
# Replay note: tests/replay-stop-hook.sh feeds no `last_assistant_message` in
# the Stop envelope, so a replay judges the transcript fallback: the current
# turn's last text after its last tool call (the whole tail window when no
# turn boundary is in it), and nothing when the closing was recorded only as
# signed-empty thinking blocks (TASK-262).
#
# Knobs (each replaces its default when set, non-empty and valid; an invalid
# regex falls back to the default without crashing):
#   - SYG_LESSON_SURFACE_RE: Python regex searched against written file paths.
#   - SYG_LESSON_FILING_RE:  case-insensitive Python regex searched against
#                            SendMessage input.message strings.
#   - SYG_LESSON_CLAIM_RE:   case-insensitive Python regex searched against
#                            the stripped closing text.
#
# Every external failure (no jq, no python3, unreadable transcript) exits 0.
# Pinned by lesson-claim-check.probe.sh.
#
# The seyag rules (rules/core.md) § "Fix recurring failures structurally".

set -uo pipefail

INPUT=$(cat)

# Already blocked once this turn-end → allow the stop (no infinite loop).
ACTIVE=$(jq -r '.stop_hook_active // false' <<<"$INPUT" 2>/dev/null || echo "false")
[ "$ACTIVE" = "true" ] && exit 0

TRANSCRIPT=$(jq -r '.transcript_path // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ] && exit 0
# Stop envelope's last_assistant_message: closing text before the async transcript catches up.
LAM=$(jq -r '.last_assistant_message // empty' <<<"$INPUT" 2>/dev/null || echo "")

HOOKS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK_LIB="$HOOKS_DIR/lib"

VERDICT=$(HOOK_LIB="$HOOK_LIB" TRANSCRIPT="$TRANSCRIPT" LAM="$LAM" python3 -I "${SYG_PY_CACHE_ARG:--B}" << 'PYEOF'
import os, re, sys

sys.path.insert(0, os.environ["HOOK_LIB"])
from turn_scan import (  # noqa: E402
    bash_write_targets,
    closing_text,
    command_argvs,
    current_turn,
    load_records,
    strip_code,
    tool_uses,
)

records = load_records(os.environ["TRANSCRIPT"])
if records is None:
    print("ok"); sys.exit()

turn = current_turn(records)

DEFAULT_SURFACE_RE = re.compile(
    r"(^|/)(rules/|skills/|hooks/|agents/|backlog/|tracker/|(CLAUDE|CLAUDE\.local|BACKLOG|TODO)\.md$|settings(\.local)?\.json$)"
)
SURFACE_RE = DEFAULT_SURFACE_RE
_surface_override = os.environ.get("SYG_LESSON_SURFACE_RE", "")
if _surface_override:
    try:
        SURFACE_RE = re.compile(_surface_override)
    except (re.error, TypeError, ValueError, RecursionError, OverflowError):
        SURFACE_RE = DEFAULT_SURFACE_RE

DEFAULT_FILING_RE = re.compile(
    r"\b(?:please\s+)?(?:file|open|create|add)\s+(?:(?:a|an|the|one)\s+)?(?:new\s+)?(?:task|ticket|issue|backlog\s+(?:item|task)|hook|rule|skill|guard|gate|check)\b"
    r"|\bTASK-\d+\b",
    re.I,
)
FILING_RE = DEFAULT_FILING_RE
_filing_override = os.environ.get("SYG_LESSON_FILING_RE", "")
if _filing_override:
    try:
        FILING_RE = re.compile(_filing_override, re.I)
    except (re.error, TypeError, ValueError, RecursionError, OverflowError):
        FILING_RE = DEFAULT_FILING_RE

TRACKER_PROGRAMS = ("tracker", "backlog", "backlog.md")


def is_tracker_filing(argv):
    """True when `argv` is `tracker|backlog|backlog.md task create|edit`, reached
    directly or through `pnpm`, `npx`, or `npm exec|run`."""
    words = list(argv)
    if words[:1] == ["pnpm"] or words[:1] == ["npx"]:
        words = words[1:]
    elif words[:2] in (["npm", "exec"], ["npm", "run"]):
        words = words[2:]
    if not words or os.path.basename(words[0]) not in TRACKER_PROGRAMS:
        return False
    return words[1:3] in (["task", "create"], ["task", "edit"])


def is_enforcing_credit(block):
    name = block.get("name")
    inp = block.get("input") or {}
    if not isinstance(inp, dict):
        return False
    if name in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        path = str(inp.get("file_path") or inp.get("notebook_path") or "")
        return bool(SURFACE_RE.search(path))
    if name == "Bash":
        cmd = str(inp.get("command") or "")
        if any(is_tracker_filing(argv) for argv in command_argvs(cmd)):
            return True
        return any(SURFACE_RE.search(p) for p in bash_write_targets(cmd))
    if name == "SendMessage":
        msg = str(inp.get("message") or "")
        return bool(FILING_RE.search(msg))
    return False


credited = any(is_enforcing_credit(block) for block in tool_uses(turn))

# `turn or records`: a found boundary is never empty; with none, the whole tail is read.
final_text = closing_text(turn or records, os.environ.get("LAM", ""))
if credited or not final_text.strip():
    print("ok"); sys.exit()

final_text = strip_code(final_text)
# Strip markdown blockquote lines (first non-blank character is `>`).
final_text = "\n".join(
    ln for ln in final_text.splitlines() if not ln.lstrip().startswith(">")
)
# Strip double-quoted spans (ASCII "..." or curly “...”) of 120 characters or fewer
# that hold no sentence end; a longer or sentence-bearing span is kept as prose.
def _quote_span(m):
    s = m.group(0)
    return "" if len(s) <= 120 and not re.search(r"[.!?]\s", s) else s


# A line with an odd count of ASCII `"` has an unpaired quote, so its quotes are
# not paired up: nothing is stripped from it.
def _strip_quotes(line):
    if line.count('"') % 2:
        return line
    return re.sub(r'"[^"\n]*"|“[^”\n]*”', _quote_span, line)


final_text = "\n".join(_strip_quotes(ln) for ln in final_text.split("\n"))
if not final_text.strip():
    print("ok"); sys.exit()

HONEST_RE = re.compile(
    r"\bnothing\s+(?:yet\s+)?enforces\b"
    r"|\bnot\s+(?:yet\s+)?enforced\b"
    r"|\bno\s+(?:hook|rule|skill|artifact)\s+(?:yet\s+)?enforces\b"
    r"|\bwon['’]t\s+claim\b",
    re.I,
)

DEFAULT_CLAIM_RE = re.compile(
    r"\bI(?:['’]ll|\s+will)\s+(?:be\s+sure\s+to|remember\b|keep\s+(?:that|this|it)\s+in\s+mind)"
    r"|\bI(?:['’]ll|\s+will)\s+(?:always|never|not\s+repeat|be\s+(?:more\s+)?(?:careful|vigilant|mindful)|make\s+sure\b|make\s+(?:it\s+a\s+point|a\s+habit)|take\s+care\s+to|ensure\b)"
    r"|\b(?:next\s+time|going\s+forward|from\s+now\s+on|in\s+(?:the\s+)?future|moving\s+forward|from\s+here\s+on(?:\s+out)?|henceforth)\s*,?\s+I(?:['’]ll|\s+will|['’]d|\s+always)\b"
    r"|\bnext\s+time(?!\s+(?:I|I['’]m|we|you|the)\b)[^.\n]{0,40}?,\s*I(?:['’]ll|\s+will)\b"
    r"|\bI(?:['’]ll|\s+will)\b(?:[^.\n]|\.(?=\S)){0,60}?\b(?:next\s+time(?!\s+(?:I|I['’]m|we|you|it|the)\b)|going\s+forward|from\s+now\s+on|moving\s+forward|from\s+here\s+on(?:\s+out)?|henceforth)\b"
    r"|\b(?:going\s+forward|from\s+now\s+on|moving\s+forward)\s*,?\s+(?:I\s+)?always\b"
    r"|\b(?:I\s+never|I(?:['’]ll|\s+will)\s+(?:not|never)|I\s+(?:won['’]t|will\s+not))\b(?:[^.\n]|\.(?=\S)){0,50}?\bagain\b"
    r"|\b(?:won['’]t|will\s+not)\s+happen\s+again\b"
    r"|\bI(?:['’]ve|\s+have)?\s+learned\s+(?:my|the|a|that|this|from\s+(?:this|that|it))\s+(?:lesson|mistake)\b"
    r"|(?:^|[.!?]\s+|\b(?:the|hard|a|one|my|that['’]s\s+a)\s+)\s*(?:[-*+]\s+|#+\s+)?(?:\*\*)?lesson\s+learned\b"
    r"|^\s*(?:[-*+]\s+)?(?:\*\*)?(?:lesson|takeaway)(?:\*\*)?\s*:"
    r"|\b(?:one|a|the|my|that['’]s\s+a)\s+lesson\b(?:[^.\n]|\.(?=\S)){0,40}?\b(?:notes?|noted|memory|remember)"
    r"|\bnoted\s+for\s+(?:the\s+)?(?:future|next\s+time|next\s+session)\b|\bremembered\s+for\s+next\s+(?:time|session)\b",
    re.I | re.M,
)
CLAIM_RE = DEFAULT_CLAIM_RE
_claim_override = os.environ.get("SYG_LESSON_CLAIM_RE", "")
if _claim_override:
    try:
        CLAIM_RE = re.compile(_claim_override, re.I | re.M)
    except (re.error, TypeError, ValueError, RecursionError, OverflowError):
        CLAIM_RE = DEFAULT_CLAIM_RE

# Each paragraph is judged alone: a claim blocks unless its own paragraph is honest.
blocked = any(
    CLAIM_RE.search(para) and not HONEST_RE.search(para)
    for para in re.split(r"\n\s*\n", final_text)
)
print("claim" if blocked else "ok")
PYEOF
) || exit 0

[ "$VERDICT" != "claim" ] && exit 0

cat >&2 << 'MSG'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
LESSON CLAIM — a behaviour-change claim with no enforcing artifact this turn
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
A session keeps nothing across /clear, and notes, role files and memory
don't enforce anything.

Do ONE of:
  - build the rule, hook or skill now, or file it in the tracker or with
    the owning session, then stop;
  - drop the claim and say plainly that nothing enforces it, then stop;
  - if a worker or another session already built or filed it, name the
    path or task id in one line and stop again; this check fires once
    per turn.
(the seyag rules, rules/core.md § "Fix recurring failures structurally")
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
MSG
exit 2
