#!/bin/bash
# PreToolUse hook (matcher: AskUserQuestion, component: ask-pretext): block an
# AskUserQuestion that points to text outside the dialog, or that follows
# readable earlier-message `!` commands or fenced code blocks in the current
# turn that the ask itself does not carry.
#
# Why it matters: on some clients (observed on a phone client), assistant text
# written before an AskUserQuestion is hidden behind the ask dialog. If the ask
# says "run the command above" or follows an earlier message's `!` command or
# code block without carrying it inside the question or option text, the user
# cannot see what they are being asked about.
#
# Runtime facts (probed headless and interactive):
#   - At PreToolUse on AskUserQuestion, the transcript on disk holds NO record
#     of the current assistant message (its text block and tool_use are written
#     after the hook runs). Records from EARLIER messages of the turn are on
#     disk.
#   - At PostToolUse on AskUserQuestion, the current message's text records and
#     its tool_use record ARE on disk (covered by ask-pretext-reminder.sh).
#
# Judged fields (scanned one by one, never joined via lib/ask_detect.py):
#   each question's `question` and `header`, and each option's `label`,
#   `description` and `preview` (`ask_fields(inp, include_header=True)`).
#
# Rules:
#   (a) Pointer: any judged field matching the calibrated case-insensitive
#       pointer regex blocks EVERY time (exit 2, stderr), with no state.
#   (b) Readable pre-ask code: tail-reads the transcript (4 MB), finds the
#       strict turn boundary (`is_genuine_user`; a "Stop hook feedback:" user
#       entry is not a boundary), skips sidechain records, and collects every
#       `text` block of main-lane assistant entries since the turn start.
#       Finds `!` commands (`commands_in`) and fenced code blocks
#       (`fenced_blocks`). A command is carried when its key appears as a
#       substring of some judged ask field after whitespace normalization
#       (runs collapsed to one space); a fenced block is carried when every one
#       of its content lines appears in some field. Any uncarried item blocks
#       ONCE per turn via
#       `${XDG_STATE_HOME:-$HOME/.local/state}/seyag/ask-pretext-guard/<session key>`,
#       storing `<turn-start record uuid, else its line hash>:<sha1 of sorted uncarried keys>`.
#       If the same line is already recorded, or the state file cannot be
#       written, rule (b) passes (never blocks without state, so retries cannot
#       loop). When (a) and (b) both apply, (a) wins and no (b) state is
#       written.
#
# KNOWN BOUNDS:
#   - Same-message pre-ask text is not yet on disk at PreToolUse and is
#     invisible to this guard; `ask-pretext-reminder.sh` covers it at
#     PostToolUse.
#   - Assistant prose recorded in the transcript as a `thinking` block with an
#     empty `thinking` field and a signature (and no `text` block) is
#     unreadable to any transcript-reading hook (TASK-67).
#
# Fail-open everywhere: missing jq or python3, a missing, unreadable or
# unparseable transcript, or any internal exception -> rule (b) passes. Rule (a)
# needs only `tool_input`, so it still runs when the transcript is missing. If
# `tool_input` is unparseable, exit 0.
#
# Pinned by ask-pretext-guard.probe.sh.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null) || exit 0
[ -n "$INPUT" ] || exit 0

HOOKS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK_LIB="$HOOKS_DIR/lib"

VERDICT=$(HOOK_LIB="$HOOK_LIB" python3 -I "${SYG_PY_CACHE_ARG:--B}" 3<<<"$INPUT" << 'PYEOF' 2>/dev/null
import hashlib, json, os, re, sys

sys.path.insert(0, os.environ["HOOK_LIB"])
from ask_detect import ask_fields, commands_in, fenced_blocks  # noqa: E402

POINTER_RE = re.compile(
    r"\b(?:(?:see|shown|listed|described|written|explained|outlined|noted|quoted|posted|given|mentioned|detailed|pasted)\s+(?:it\s+)?above"
    r"|above\s+(?:message|reply|response)"
    r"|the\s+(?:line|command|commands|table|list|plan|summary|diff|output|details|options?|block|snippet|link|url|text|steps?)\s+above"
    r"|in\s+my\s+(?:last\s+|previous\s+|earlier\s+|prior\s+)?(?:message|reply|response|turn|note|text)"
    r"|(?:previous|earlier|prior|last)\s+message"
    r"|see\s+below"
    r"|(?:shown|listed)\s+below"
    r"|as\s+I\s+(?:said|mentioned|noted|wrote|explained|described)"
    r"|scroll\s+up)\b",
    re.IGNORECASE,
)


def judge():
    try:
        raw_input = os.fsdecode(open(3, "rb").read())
        payload = json.loads(raw_input)
    except Exception:
        return "ok"
    if not isinstance(payload, dict):
        return "ok"
    tname = payload.get("tool_name")
    if isinstance(tname, str) and tname and tname != "AskUserQuestion":
        return "ok"
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return "ok"

    raw_fields = list(ask_fields(tool_input, include_header=True))
    if not raw_fields:
        return "ok"

    # Rule (a): pointer phrase in any judged field blocks every time, no state.
    for field in raw_fields:
        m = POINTER_RE.search(field)
        if m:
            phrase = re.sub(r"\s+", " ", m.group(0)).strip()
            return "ptr:" + phrase

    # Rule (b): readable earlier-message pre-ask code in this turn.
    path = payload.get("transcript_path")
    if not isinstance(path, str) or not path or not os.path.isfile(path):
        return "ok"

    tail_bytes = 4_000_000
    with open(path, "rb") as f:
        f.seek(0, os.SEEK_END)
        size = f.tell()
        f.seek(max(0, size - tail_bytes))
        data = f.read()
    lines = data.decode("utf-8", "replace").splitlines()
    if size > tail_bytes and lines:
        lines = lines[1:]

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
            records.append((rec, ln))

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
        if not records[i][0].get("isSidechain") and is_genuine_user(records[i][0]):
            turn_start = i
            break
    if turn_start is None:
        return "ok"

    turn_rec, turn_raw = records[turn_start]
    turn = [rec for rec, _ in records[turn_start:] if not rec.get("isSidechain")]

    texts = []
    for entry in turn:
        if entry.get("type") != "assistant":
            continue
        content = entry.get("message", {}).get("content", []) or []
        if not isinstance(content, list):
            continue
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                t = block.get("text", "") or ""
                if isinstance(t, str) and t:
                    texts.append(t)
    if not texts:
        return "ok"

    norm_fields = [re.sub(r"\s+", " ", f) for f in raw_fields]

    def cmd_carried(key):
        return any(key in nf for nf in norm_fields)

    def fence_carried(blk):
        for ln in blk:
            norm_ln = re.sub(r"\s+", " ", ln)
            if not any(ln in rf or norm_ln in nf for rf, nf in zip(raw_fields, norm_fields)):
                return False
        return True

    uncarried = []  # (kind, display_text, hash_key)
    seen = set()
    for t in texts:
        for key in commands_in(t):
            if not cmd_carried(key):
                hk = "C:" + key
                if hk not in seen:
                    seen.add(hk)
                    uncarried.append(("C", key, hk))
        for blk in fenced_blocks(t):
            if not fence_carried(blk):
                hk = "F:" + "\n".join(blk)
                if hk not in seen:
                    seen.add(hk)
                    first_ln = re.sub(r"[\r\n\t]+", " ", blk[0])[:80]
                    uncarried.append(("F", first_ln, hk))

    if not uncarried:
        return "ok"

    turn_uuid = turn_rec.get("uuid")
    if isinstance(turn_uuid, str) and turn_uuid.strip():
        turn_id = re.sub(r"\s+", "", turn_uuid.strip())
    else:
        turn_id = hashlib.sha1(turn_raw.encode("utf-8", "replace")).hexdigest()

    keys_sha1 = hashlib.sha1(
        "\n".join(sorted(hk for _, _, hk in uncarried)).encode("utf-8", "replace")
    ).hexdigest()
    ident = f"{turn_id}:{keys_sha1}"

    sid = payload.get("session_id")
    if not isinstance(sid, str) or not sid:
        sid = os.path.basename(path)
    skey = re.sub(r"[^A-Za-z0-9._-]", "_", sid)

    body = "\n".join(f"{k}\t{disp}" for k, disp, _ in uncarried)
    return f"code:{skey}\t{ident}\n{body}"


try:
    print(judge())
except Exception:
    print("ok")
PYEOF
) || exit 0

case $VERDICT in
  ptr:*)
    PHRASE=${VERDICT#ptr:}
    cat >&2 <<EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ASK POINTS OUTSIDE ITSELF — blocked
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
This ask refers to text outside the dialog ("$PHRASE").
Text written before an ask is hidden on some clients, so the user
cannot see what it points to. Put what they need inside the question
or option text, or end the turn with plain text and no ask (a command
for the user to run: plain-text turn end, no ask).
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
    exit 2
    ;;
  code:*) ;;
  *) exit 0 ;;
esac

FIRST_LINE=${VERDICT%%$'\n'*}
HEADER=${FIRST_LINE#code:}
SKEY=${HEADER%%$'\t'*}
IDENT=${HEADER#*$'\t'}
BODY=${VERDICT#*$'\n'}

[ -n "$SKEY" ] && [ -n "$IDENT" ] || exit 0

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/seyag/ask-pretext-guard"
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

# State unwritable -> pass. Rule (b) never blocks without state, because a retry would loop.
if ! write_state 2>/dev/null; then
  exit 0
fi

cat >&2 <<'MSG'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ASK AFTER HIDDEN CODE — blocked once
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Text written before an ask is hidden on some clients, so the user
cannot see what it points to. Put what they need inside the question
or option text, or end the turn with plain text and no ask (a command
for the user to run: plain-text turn end, no ask).

Not inside the ask:
MSG
while IFS=$'\t' read -r KIND KEY; do
  case $KIND in
    C) printf >&2 '  ! %s\n' "$KEY" ;;
    F) printf >&2 '  fenced block: %s\n' "$KEY" ;;
  esac
done <<<"$BODY"
cat >&2 <<'MSG'

This fires once per turn: if it was illustrative, ask again unchanged.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
MSG
exit 2
