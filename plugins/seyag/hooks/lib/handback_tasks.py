"""List the background tasks a subagent started and has not ended, for
handback-live-task-gate.sh.

Reads one agent transcript (env `HT_TRANSCRIPT`, a JSONL file) and prints one
line per live task, `<id>\t<label>`, in launch order. Nothing when none is live.

A task is OWNED by the agent when a user entry carries `toolUseResult` with a
non-empty string `backgroundTaskId` (a Bash call with run_in_background). It is
ENDED when either:
  (a) a `task-notification` entry (origin.kind) names it in a `<task-id>` tag,
      unless that text's `<status>` is `running` or `pending` (a text with no
      status tag ends it; the status is compared stripped and lowercased), or
  (b) a `TaskStop` or `KillShell` call on it has a tool_result whose text
      contains "Successfully stopped task" or "is not running". Any other
      result (another error, say) leaves the task live.
A task-notification queued mid-turn arrives as an `attachment` entry of type `queued_command` (origin kind `task-notification`), and its `prompt` is read the same way as a notification's content.

Tool ids and tool names are used only when they are strings; a record whose
ids are not strings is skipped, and the rest of the transcript is still read.

The label is the launching call's `input.description`, else its `input.command`.
Imported by `handback-live-task-gate.sh` (python3 -I "${SYG_PY_CACHE_ARG:--B}" -c 'import handback_tasks')
so CPython caches its bytecode. Runs on import; any exception prints nothing
and exits 0. The file is read whole only up to MAX_BYTES; a larger one prints
nothing.

Contract:
  - input: env `HT_TRANSCRIPT` (the agent transcript path, already validated).
  - output: one line per live task; nothing otherwise.
  - also imported by `handoff-pick-check.sh`, through `scan_entries` and
    `live_task_ids`, with `HT_TRANSCRIPT` unset, so `_main` prints nothing.
"""

import json
import os
import re
import sys

MAX_BYTES = 32 * 1024 * 1024
TASK_ID = re.compile(r"<task-id>([^<]+)</task-id>")
STATUS = re.compile(r"<status>([^<]*)</status>")
NON_TERMINAL = frozenset(("running", "pending"))
ENDING_TOOLS = frozenset(("TaskStop", "KillShell"))
# The harness's TaskStop result wording as captured on Claude Code 2.1.330.
# Re-check these phrases when the harness changes.
STOP_PHRASES = ("Successfully stopped task", "is not running")


def _key(value):
    """The value when it is a string (usable as an id), else None."""
    return value if isinstance(value, str) else None


def _text_of_content(content):
    """Every string a task-notification can carry: the content string, or the
    `text` field of each list block."""
    if isinstance(content, str):
        return [content]
    if isinstance(content, list):
        return [b["text"] for b in content if isinstance(b, dict) and isinstance(b.get("text"), str)]
    return []


def _result_text(block):
    """A tool_result's text: its content string, or the joined `text` fields of
    its list blocks."""
    content = block.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(b["text"] for b in content if isinstance(b, dict) and isinstance(b.get("text"), str))
    return ""


def _notified_ids(text):
    """The task ids one task-notification text ends: none when its status is
    running or pending, else every `<task-id>` it names."""
    status = STATUS.search(text)
    if status and status.group(1).strip().lower() in NON_TERMINAL:
        return []
    return [m.strip() for m in TASK_ID.findall(text)]


def _clean(text):
    return re.sub(r"[\r\n\t]+", " ", text).strip()


def _launch_label(blocks, tool_uses):
    """The label of the call whose tool_result carries the task id: its
    `description`, else its `command` cut to 80 characters."""
    for block in blocks:
        if block.get("type") != "tool_result":
            continue
        use = tool_uses.get(_key(block.get("tool_use_id")))
        if use is None:
            continue
        inp = use[1]
        desc = inp.get("description")
        if isinstance(desc, str) and desc:
            return desc
        cmd = inp.get("command")
        return cmd[:80] if isinstance(cmd, str) else ""
    return ""


def scan_entries(entries):
    """Return (owned, ended) over already-parsed transcript entries: owned is
    [(id, label)] in first-seen order, ended is the set of task ids they end.
    Entries that are not dicts are skipped."""
    owned = []
    seen_owned = set()
    ended = set()
    tool_uses = {}  # tool_use id -> (name, input)
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        message = entry.get("message")
        content = message.get("content") if isinstance(message, dict) else None
        blocks = [b for b in content if isinstance(b, dict)] if isinstance(content, list) else []

        for block in blocks:
            if block.get("type") == "tool_use":
                bid = _key(block.get("id"))
                if bid is not None:
                    inp = block.get("input")
                    tool_uses[bid] = (_key(block.get("name")), inp if isinstance(inp, dict) else {})

        origin = entry.get("origin")
        if isinstance(origin, dict) and origin.get("kind") == "task-notification":
            for text in _text_of_content(content):
                ended.update(_notified_ids(text))

        attachment = entry.get("attachment")
        if entry.get("type") == "attachment" and isinstance(attachment, dict) \
                and attachment.get("type") == "queued_command":
            queued_origin = attachment.get("origin")
            if isinstance(queued_origin, dict) and queued_origin.get("kind") == "task-notification":
                for text in _text_of_content(attachment.get("prompt")):
                    ended.update(_notified_ids(text))

        for block in blocks:
            if block.get("type") != "tool_result":
                continue
            use = tool_uses.get(_key(block.get("tool_use_id")))
            if use is None or use[0] not in ENDING_TOOLS:
                continue
            text = _result_text(block)
            if not any(phrase in text for phrase in STOP_PHRASES):
                continue
            inp = use[1]
            task = inp.get("task_id") or inp.get("shell_id")
            if isinstance(task, str) and task:
                ended.add(task)

        result = entry.get("toolUseResult")
        if isinstance(result, dict):
            tid = _key(result.get("backgroundTaskId"))
            if tid and tid not in seen_owned:
                seen_owned.add(tid)
                owned.append((tid, _clean(_launch_label(blocks, tool_uses))))
    return owned, ended


def live_task_ids(entries):
    """The owned task ids that the entries do not end, in launch order."""
    owned, ended = scan_entries(entries)
    return [tid for tid, _ in owned if tid not in ended]


def _parsed_lines(fh):
    for raw in fh:
        try:
            yield json.loads(raw)
        except ValueError:
            continue


def _scan(path):
    """Return (owned, ended) for the transcript file at path (see scan_entries)."""
    with open(path, encoding="utf-8", errors="replace") as fh:
        return scan_entries(_parsed_lines(fh))


def _main():
    path = os.environ.get("HT_TRANSCRIPT", "")
    if not path or os.path.getsize(path) > MAX_BYTES:
        return
    owned, ended = _scan(path)
    lines = [f"{tid}\t{label}" for tid, label in owned if tid not in ended]
    if lines:
        sys.stdout.write("\n".join(lines) + "\n")


try:
    _main()
except Exception:
    sys.exit(0)
