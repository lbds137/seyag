#!/bin/bash
# Stop hook: when the agent tries to end a turn whose final message makes a
# deferred-work promise ("I'll file that later", "follow-up after this PR")
# WITHOUT a same-turn write to a ledger file, block the stop once and remind.
# The promise dies in chat otherwise, and the owner ends up asking "what's the
# plan for those?" a session later.
#
# Enforcement geometry: a deterministic scan of the ASSISTANT'S OWN output,
# blocking at most once via the native `stop_hook_active` flag. If the promise
# is already tracked, or is a process action that needs no ledger entry, the
# agent says so and stops again (the second stop is allowed).
#
# Trigger is deliberately narrow (deferred-WORK verbs + a deferral marker, or a
# line-leading queue label) to keep false positives low; the same-turn ledger
# write suppresses the common "promised AND filed in the same breath" case.
#
# Closing text comes from the Stop envelope's last_assistant_message (with the
# transcript tail as fallback): the harness truncates long values (they end
# "… [+N chars]"), and a trailing promise cut by the truncation turns a
# should-block turn into a pass. Accepted: judging the transcript instead when
# the field is present re-reads stale prior-turn closings — the false fires
# that motivated the field.
#
# What counts as a ledger write (same turn only):
#   - an Edit / Write / MultiEdit whose file_path matches the ledger regex.
#     Default: (^|/)(backlog/|tracker/|CURRENT\.md|BACKLOG\.md|TODO\.md|claude-memory/roles/)
#     `claude-memory/roles/` is there because every session on this machine
#     keeps its to-do list in ~/Documents/claude-memory/roles/<name>.md.
#     SYG_LEDGER_PATH_RE (a Python regex, matched with re.search against
#     the file_path) REPLACES the default when set and non-empty. If it is set
#     but does not compile, the default is used; the hook never crashes on it.
#   - a Bash command containing a tracker CLI filing call
#     (`tracker|backlog task create|edit`). Harmless where no such CLI exists.
#   - a Bash command that WRITES a ledger path: it names one (directly, or
#     relative to an earlier `cd` in the same command) and carries a write
#     shape (`sed -i`, `perl -i`, `>`/`>>`, `tee`, a python/node file write).
#     A read-only mention (`grep … roles/x.md`) does not credit. Unlike the
#     Tzurot original, which credits only the CLI shape: sessions here keep
#     their to-do lists in role files and often edit them through Bash.
#
# Ported from Tzurot's project hook of the same name (a same-named project hook
# overrides this one via run.sh). Generalized: the ledger path set, the env
# override, the tail-bounded read, and the banner's rule citation.
#
# Every external failure (no jq, no python3, unreadable transcript) exits 0.
# Pinned by promise-ledger-check.probe.sh.
#
# The seyag rules (rules/core.md) § "Everything not done gets a disposition
# when you decide".

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

path = os.environ["TRANSCRIPT"]
# Read only the tail: a long session's transcript can be hundreds of MB, and this
# runs at every turn end. Same bound as blocking-question-channel-check.sh.
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

# Walk from the end to the last GENUINE user message (a user turn carrying real
# text, not a tool_result envelope) — that bounds the current turn.
def is_genuine_user(entry):
    if entry.get("type") != "user" or entry.get("isMeta"):
        return False
    content = entry.get("message", {}).get("content")
    if isinstance(content, str):
        return len(content.strip()) > 0
    if isinstance(content, list):
        return any(b.get("type") == "text" for b in content)
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

# If the turn boundary can't be found, fail toward STRICT: an empty turn means
# wrote_ledger stays False, so an unfiled promise still fires (rather than
# crediting a ledger write from some earlier point in the session and silently
# defeating the same-turn check). The final message is scanned regardless.
# This includes a turn longer than the tail window: its start is out of view,
# so a write early in that turn is not credited and the turn blocks once. That
# is the same one-acked-turn cost as every other miss here, and the strict
# direction is this hook's posture (the inverse of the blocking-question check).
turn = records[turn_start:] if turn_start is not None else []

DEFAULT_LEDGER_RE = re.compile(
    r"(^|/)(backlog/|tracker/|CURRENT\.md|BACKLOG\.md|TODO\.md|claude-memory/roles/)"
)
LEDGER_RE = DEFAULT_LEDGER_RE
_override = os.environ.get("SYG_LEDGER_PATH_RE", "")
if _override:
    try:
        LEDGER_RE = re.compile(_override)
    except (re.error, TypeError, ValueError, RecursionError, OverflowError):
        LEDGER_RE = DEFAULT_LEDGER_RE

# A tracker CLI filing call (e.g. `pnpm tracker task create ...`) reaches the
# transcript as a Bash tool_use with no file_path to match. Credit the command
# string instead. Matched loosely (any `tracker task create|edit` /
# `backlog task create|edit` substring) because the command arrives inside
# arbitrary shell composition; this is a crediting check, not a gate on the
# command's shape.
TRACKER_CLI_RE = re.compile(r"\b(?:tracker|backlog(?:\.md)?)\s+task\s+(?:create|edit)\b")

# (a) same-turn ledger writes. LIMITATION: only direct Edit/Write/MultiEdit/
# Bash in THIS transcript count — a ledger file written by a delegated
# subagent (Agent tool) lands in a different transcript and won't be seen
# here. There is no way for the closing message to assert the write happened:
# naming the file used to satisfy an escape hatch, and that hatch is
# deliberately gone (see below). So a subagent-delegated filing WILL block
# once, and the only recovery is the ordinary one — say where it was filed and
# stop again, which `stop_hook_active` lets through. That is the accepted
# one-acked-turn cost, not a defect.
#
# A Bash command also credits when it WRITES a ledger path: it names one (as a
# token, or as a token relative to a `cd` target earlier in the same command,
# e.g. `cd ~/Documents/claude-memory && sed -i … roles/x.md`) AND it carries a
# write shape. Sessions on this machine routinely update their role files that
# way. Loose on purpose: a stray credit costs one missed reminder, while a
# missing one blocks a turn that did file.
BASH_WRITE_RE = re.compile(
    r"\bsed\s+(?:-[^\s]*\s+)*-i|\bperl\s+(?:-[^\s]*\s+)*-[^\s]*i|>>?|\btee\b"
    r"|open\([^)]*,\s*['\"][wa]|write_text\(|writeFileSync\(|appendFileSync\("
)
CD_RE = re.compile(r"(?:^|[;&|(]\s*)cd\s+(['\"]?)([^\s'\";&|)]+)\1")
TOKEN_SPLIT_RE = re.compile(r"[\s'\"`;&|()<>=]+")

def bash_writes_ledger(cmd):
    if not BASH_WRITE_RE.search(cmd):
        return False
    tokens = [t for t in TOKEN_SPLIT_RE.split(cmd) if t]
    cds = [m.group(2).rstrip("/") for m in CD_RE.finditer(cmd)]
    for t in tokens:
        if LEDGER_RE.search(t):
            return True
        if any(LEDGER_RE.search(d + "/" + t) for d in cds):
            return True
    return False

def is_ledger_write(block):
    if block.get("type") != "tool_use":
        return False
    if block.get("name") in ("Edit", "Write", "MultiEdit"):
        return bool(LEDGER_RE.search(str(block.get("input", {}).get("file_path", ""))))
    if block.get("name") == "Bash":
        cmd = str(block.get("input", {}).get("command", ""))
        return bool(TRACKER_CLI_RE.search(cmd)) or bash_writes_ledger(cmd)
    return False

wrote_ledger = any(
    is_ledger_write(block)
    for entry in turn
    if entry.get("type") == "assistant"
    for block in (entry.get("message", {}).get("content", []) or [])
)

# (b) closing text: the Stop envelope's last_assistant_message when present,
# else the last text block ANYWHERE (robust to the boundary-not-found case;
# it's always the closing message we read to end).
lam = os.environ.get("LAM", "")
if lam.strip():
    final_text = lam
else:
    final_text = ""
    for entry in records:
        if entry.get("type") != "assistant":
            continue
        for block in entry.get("message", {}).get("content", []) or []:
            if block.get("type") == "text":
                final_text = block.get("text", "")

if wrote_ledger or not final_text.strip():
    print("ok"); sys.exit()

# Strip fenced code blocks and inline spans BEFORE any matching. A pasted type
# declaration is the strongest false trigger there is — `remaining: number;` is a
# line-leading queue word with a colon at distance zero, exactly the label shape
# every position and anchor rule below is tuned to catch. In typed code,
# `remaining` / `outstanding` / `queued` are ordinary field names.
#
# Lexical, not semantic: this removes markdown code regions by their delimiters,
# the same class of operation as reading a tool name out of the transcript. It
# does not interpret what the code says. A real label survives an inline span
# inside it, because only the span itself is removed.
#
# SHARED, not queue-list-scoped: this rewrites `final_text` for every matcher
# below, PROMISE and ALT included. The motivating case was a pasted type
# declaration, but the consequence reaches further — "I'll `refactor` this
# later" no longer fires, because the verb is inside the stripped span. Accepted
# under the same cost model, and stated here so a future editor does not assume
# the prose matchers see the raw message.
#
# Known uncovered shapes, all judged acceptable against the one-acked-turn cost:
# an UNTERMINATED fence (a truncated paste) is not stripped, but that fails
# toward firing, which is the safe direction; 4-space INDENTED code blocks are
# not stripped at all; and a status heading like "## Remaining Tasks" fires,
# which is arguably correct rather than a false positive — such a heading is a
# list of deferred work.
#
# One known FALSE NEGATIVE, the expensive direction, kept deliberately: a
# trigger word wrapped in its own span ("**Still `queued`**: …") does not fire.
# Note this is NOT merely because the span is removed — a backtick SPLITS the
# phrase, so "still queued" fails to match whether the span survives or not.
# Keeping trigger-bearing spans therefore does not fix it; only deleting the
# backtick characters would, and that turns "`remaining: number` is the field"
# into a line-leading label, trading this rare miss for a likelier misfire.
# Widen this only on an observed misfire, not on speculation: every previous
# attempt to pre-empt a shape here made the matcher worse.
final_text = re.sub(r"```.*?```", "", final_text, flags=re.S)
final_text = re.sub(r"`[^`\n]*`", "", final_text)
if not final_text.strip():
    print("ok"); sys.exit()

# NO filename escape hatch. An earlier version passed the turn whenever the
# closing message mentioned any ledger filename, on the theory that naming the
# file meant the promise was tracked there. That inference is topic-correlated,
# not commitment-specific, and it collapses on exactly the days it matters: when
# the backlog IS the work, those filenames appear constantly for unrelated
# reasons, and every promise made that day sails through. Removed deliberately —
# a false positive costs one acknowledged turn (this hook blocks at most once),
# while a false negative costs an untracked commitment. The costs are asymmetric
# by orders of magnitude, so this fails toward firing.

# Deferred-WORK promise: a work verb + a deferral marker, reasonably close.
# Narrow on purpose — "I'll merge once CI passes" (process, not backlogged
# work) lacks a work verb here and is correctly ignored. A work verb right
# after an article is a NOUN, not a promise ("I'll commit the fix … once",
# "I'll push the update once CI passes"), excluded by the lookbehinds below.
# Measured 2026-09-25 over 3,706 turn ends: 36 fires, 24 true, 10 misfires,
# of which this noun shape was one. Six of the other nine are a queue label
# ("Remaining:", "Still open:") over in-flight PR/CI/review status; no
# lexical rule separates those labels from a real open list ("Still open:
# CI, and the GitGuardian dismissal you owe"), so they stay, ~1 ack per 600
# turn ends. Measured trade: a genuine promise whose verb is only in noun
# position ("I'll make a fix for that later") no longer fires; none of the
# 24 true fires had that shape. Widen on an observed miss, not speculation.
PROMISE = re.compile(
    r"\b(?:I['’]?ll|I\s+will)\s+(?:\w+\s+){0,3}?"
    r"(?<!\bthe\s)(?<!\ba\s)(?<!\ban\s)(?<!\bthis\s)(?<!\bthat\s)(?<!\bits\s)(?<!\bmy\s)(?<!\bour\s)"
    r"(add|fix|file|handle|implement|build|write|create|update|migrate|refactor|clean\s*up|revisit|circle\s+back)"
    r"\b.{0,60}?\b(later|after\s+(this|the)|once\b|next\s+session|tomorrow|down\s+the\s+line|follow[-\s]?up)",
    re.I | re.S,
)
ALT = re.compile(
    r"\b(let['’]?s\s+not\s+forget|as\s+a\s+follow[-\s]?up|in\s+a\s+follow[-\s]?up\s+PR)\b",
    re.I,
)

# The QUEUE-LIST shape. PROMISE above only matches first-person prose ("I'll fix
# that later") — but deferred work is far more often written as an enumeration
# under a label: "**Still queued**: the two audit findings, the orphan doc, …".
# That form carries no future-tense verb and no deferral marker, so it slipped
# past the prose matcher on every occurrence of a full session.
#
# POSITION is the discriminator, not proximity. A label LEADS A LINE; a prose
# mention sits mid-sentence. An earlier version only required the anchor
# punctuation within ~60 chars of the queue word, which fires on ordinary writing
# in an em-dash-heavy style: "two runs are still queued on GitHub's side — nothing
# for us to do" matched, and so did "the work here is outstanding — nice catch".
# A hook firing on normal sentences at every turn-end trains reflexive
# acknowledgement, which destroys the signal more thoroughly than missing would.
#
# So the queue word must start a line (after an optional list marker and optional
# bold/italic markup), with the anchor following inside a SHORT same-line window.
QUEUE_WORDS = (
    r"still\s+queued|queued(?:\s+up)?|remaining|outstanding|next\s+up|"
    r"left\s+to\s+do|still\s+open|queue[sd]?\s+behind|still\s+to\s+(?:do|come)"
)

# Headings get one extra word — a bare "queue" — under a STRICTER rule than the
# phrases get. The vocabularies are deliberately not identical: "## Queue" is
# unambiguously a deferred-work list, while "the BullMQ queue: jobs run in order"
# is ordinary prose in any codebase with a job queue (BullMQ, Redis, a task
# runner). Heading position is strong evidence, so it can afford a weaker word;
# the list matcher cannot.
#
# But heading position alone is not enough for a word this weak: "## Queue
# Configuration" and "## Queue Health" are headings ABOUT a job system, not
# lists of deferred work. So bare "queue" must be the WHOLE heading, while the
# multi-word phrases may appear anywhere in one ("## Remaining Tasks" is a
# deferred-work list no matter what follows the trigger).

# Lead-in punctuation. ASCII hyphen included deliberately: the owner dictates by
# voice, and transcribers render a spoken pause as a plain "-", never an em dash.
# An anchor class omitting it would miss the most likely real form while
# accepting the typographically-correct one nobody types.
#
# Dash-family anchors REQUIRE leading whitespace; colons do not. Without that,
# the window reaches the hyphen inside an ordinary compound word: "Remaining
# work is user-facing polish." matched, because the lazy scan walked 13 chars
# and found the "-" in "user-facing". Technical prose is dense with such
# compounds (fail-closed, read-only, cross-user, long-lived), so that is a
# routine sentence, not a contrived one. Colons need no whitespace guard — they
# never occur inside a word.
#
# The WINDOW is what stops a colon reaching across a clause, and 6 is measured
# rather than guessed. Tail length between the trigger word and the anchor:
#   real labels  → 0, 0, 0, 2, 6   ("Remaining:", "**Still queued**:", "Remaining Tasks:")
#   ordinary prose → 8, 9, 9       ("Remaining question:", "Outstanding balance:")
# A window of 6 keeps every label form actually written and rejects all three
# prose forms. It gives up one uncommon true positive — "Still queued behind
# them:" at 12 — which is the deliberate trade: a false positive at every
# turn-end trains reflexive acknowledgement, and that destroys the signal more
# thoroughly than an occasional miss.
QUEUE_ANCHOR = r"(?:\s[-–—]|[:：])"

# Where a label may begin: line start, OR immediately after a sentence boundary
# on the same line ("All green. Remaining: the sweep."). Sentence-start is
# included because a label routinely follows a closing sentence, and requiring
# line-start alone rejected that real form. It does NOT reintroduce the
# mid-sentence false positives — those have the queue word inside a clause, not
# opening one. Then optional furniture: indent, list bullet or ordinal, bold.
QUEUE_LEAD = (
    r"(?:^|\n|(?<=[.!?])[ \t])[ \t]{0,3}"
    r"(?:[-*+]\s+|\d+[.)]\s+)?(?:\*\*|__|\*)?[ \t]*"
)

QUEUE_LIST = re.compile(
    rf"{QUEUE_LEAD}({QUEUE_WORDS})\b[^\n]{{0,6}}?{QUEUE_ANCHOR}", re.I
)
QUEUE_HEADING = re.compile(
    rf"(?:^|\n)\s{{0,3}}#{{1,6}}\s*(?:"
    rf"[^\n]{{0,40}}?\b({QUEUE_WORDS})\b"  # phrases: anywhere in the heading
    rf"|queue\s*:?\s*(?=\n|$)"             # bare "queue": must BE the heading
    rf")",
    re.I,
)

if (
    PROMISE.search(final_text)
    or ALT.search(final_text)
    or QUEUE_LIST.search(final_text)
    or QUEUE_HEADING.search(final_text)
):
    print("promise")
else:
    print("ok")
PYEOF
) || exit 0

[ "$VERDICT" != "promise" ] && exit 0

cat >&2 << 'MSG'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PROMISE LEDGER — deferred-work promise without a same-turn ledger write
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Your closing message defers work, but nothing was written this turn to
a ledger: a backlog/TODO file, a tracker, or this session's role file.
It matched one of:
  - a prose promise      — "I'll add that later" / "as a follow-up"
  - an enumerated queue  — "**Still queued**: a, b, c" / "## Remaining"
The second form is the one that reads as innocuous: a list under a
label carries no future-tense verb and no deferral marker, which is
exactly why it goes unnoticed long enough to lose real commitments.
A promise that lives only in chat dies at the next compaction.

Do ONE of:
  - File it now (the project's backlog/TODO file or tracker, or this
    session's role file), then stop; or
  - If it's already tracked or is a process action that needs no
    ledger entry, say where/why in one line and stop again (this
    gate fires only once per turn — the next stop proceeds).
(the seyag rules, rules/core.md § "Everything not done gets a
disposition when you decide")
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
MSG
exit 2
