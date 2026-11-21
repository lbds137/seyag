#!/bin/bash
# PostToolUse hook (matcher: AskUserQuestion, component: ask-pretext-reminder):
# advisory reminder after an AskUserQuestion when the assistant wrote text in
# the SAME message before the ask that reaches SYG_ASK_PRETEXT_MIN_CHARS
# (default 200; a non-integer value means 200) or carries a `!` command or a
# fenced code block.
#
# Why it matters: on some clients (observed on a phone client), text written in
# the same message before an AskUserQuestion is hidden behind the ask dialog, so
# the user may have answered without seeing it.
#
# Runtime facts (probed headless and interactive):
#   - At PreToolUse on AskUserQuestion, same-message text is not yet on disk.
#   - At PostToolUse on AskUserQuestion, the current message's text records and
#     its tool_use record ARE on disk, sharing `message.id`.
#   - Non-blocking PostToolUse stdout reaches Claude only through
#     `hookSpecificOutput.additionalContext` (same JSON shape as
#     pr-monitor-reminder.sh).
#
# Rules:
#   1. Find the payload's `tool_use_id` in the transcript tail (4 MB): the
#      main-lane assistant record whose content has a `tool_use` with that id,
#      and take that record's `message.id` (M).
#   2. Collect the `text` blocks of main-lane assistant records with
#      `message.id == M` that come BEFORE the `tool_use` record (same-message
#      pre-ask text).
#   3. Let N be their total character count. Fires when
#      `N >= SYG_ASK_PRETEXT_MIN_CHARS` (default 200; non-integer -> 200), OR
#      when the text contains a `!` command (`commands_in`) or a fenced code
#      block (`fenced_blocks`) via `lib/ask_detect.py`.
#   4. `tool_use_id` not found, transcript unreadable, or anything else odd ->
#      silent exit 0. No state is needed: PostToolUse fires once per ask by
#      construction.
#
# KNOWN BOUNDS:
#   - Runs at PostToolUse (after the user has answered), so it cannot stop the
#     ask dialog itself; it nudges the model to repeat needed items in its
#     closing reply.
#   - Assistant prose recorded in the transcript as a `thinking` block with an
#     empty `thinking` field and a signature (and no `text` block) is
#     unreadable to any transcript-reading hook (TASK-67).
#
# Fail-open everywhere: always exits 0; missing jq or python3, missing,
# unreadable or unparseable transcript, unknown tool_use_id, or any internal
# exception -> silent exit 0.
#
# Pinned by ask-pretext-reminder.probe.sh.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null) || exit 0
[ -n "$INPUT" ] || exit 0

HOOKS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK_LIB="$HOOKS_DIR/lib"

TEXT=$(HOOK_LIB="$HOOK_LIB" SYG_ASK_PRETEXT_MIN_CHARS="${SYG_ASK_PRETEXT_MIN_CHARS:-}" \
  python3 -I "${SYG_PY_CACHE_ARG:--B}" 3<<<"$INPUT" << 'PYEOF' 2>/dev/null
import json, os, re, sys

sys.path.insert(0, os.environ["HOOK_LIB"])
from ask_detect import commands_in, fenced_blocks  # noqa: E402


def judge():
    try:
        raw_input = os.fsdecode(open(3, "rb").read())
        payload = json.loads(raw_input)
    except Exception:
        return ""
    if not isinstance(payload, dict):
        return ""
    tname = payload.get("tool_name")
    if isinstance(tname, str) and tname and tname != "AskUserQuestion":
        return ""
    tool_use_id = payload.get("tool_use_id")
    if not isinstance(tool_use_id, str) or not tool_use_id.strip():
        return ""
    tool_use_id = tool_use_id.strip()
    path = payload.get("transcript_path")
    if not isinstance(path, str) or not path or not os.path.isfile(path):
        return ""

    raw_min = os.environ.get("SYG_ASK_PRETEXT_MIN_CHARS", "").strip()
    if re.fullmatch(r"[0-9]+", raw_min):
        min_chars = int(raw_min)
    else:
        min_chars = 200

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
            records.append(rec)

    target_idx = None
    target_mid = None
    same_rec_texts = []
    for i in range(len(records) - 1, -1, -1):
        rec = records[i]
        if rec.get("isSidechain") or rec.get("type") != "assistant":
            continue
        msg = rec.get("message")
        if not isinstance(msg, dict):
            continue
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        pre_blocks = []
        found = False
        for b in content:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "tool_use" and b.get("id") == tool_use_id:
                found = True
                break
            if b.get("type") == "text" and isinstance(b.get("text"), str):
                pre_blocks.append(b["text"])
        if found:
            mid = msg.get("id")
            if isinstance(mid, str) and mid.strip():
                target_idx = i
                target_mid = mid.strip()
                same_rec_texts = pre_blocks
            break

    if target_idx is None or not target_mid:
        return ""

    texts = []
    for i in range(target_idx):
        rec = records[i]
        if rec.get("isSidechain") or rec.get("type") != "assistant":
            continue
        msg = rec.get("message")
        if not isinstance(msg, dict) or msg.get("id") != target_mid:
            continue
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        for b in content:
            if isinstance(b, dict) and b.get("type") == "text" and isinstance(b.get("text"), str):
                texts.append(b["text"])
    texts.extend(same_rec_texts)

    n_chars = sum(len(t) for t in texts)
    if n_chars == 0:
        return ""
    has_cmd = any(commands_in(t) for t in texts)
    has_fence = any(fenced_blocks(t) for t in texts)
    if n_chars < min_chars and not has_cmd and not has_fence:
        return ""

    extras = ""
    if has_cmd:
        extras += ", including a `!` command"
    if has_fence:
        extras += ", including a fenced code block"

    return (
        f"ask-pretext-reminder: you wrote {n_chars} characters in the same message before this AskUserQuestion{extras}. "
        "Some clients hide that text behind the ask dialog, so the user may have answered without seeing it. "
        "In your closing reply, repeat whatever they needed from it (commands in a fenced code block); "
        "if it was only narration, no repeat is needed."
    )


try:
    out = judge()
    if out:
        print(out)
except Exception:
    pass
PYEOF
) || exit 0

[ -n "$TEXT" ] || exit 0

jq -nc --arg ctx "$TEXT" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}'
