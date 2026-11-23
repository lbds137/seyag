---
id: TASK-107
title: 'Pick command knob: sessions run their boundary pick (SYG_PICK_CMD)'
status: Done
assignee: []
created_date: '2026-11-23T01:39:56Z'
labels:
  - hooks
  - rules
dependencies: []
priority: high
ordinal: 107000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A machine can apply a session's boundary pick (`/clear`, `/compact`, keep) automatically when the session records it as a command call, instead of a "Pick:" line the owner has to act on. Sessions that end with only a written pick sit stalled until the owner runs it.

Knob `SYG_PICK_CMD` (single-line command; unset keeps today's behaviour):
- SessionStart advertises `<cmd> clear|compact|keep` as the last Bash call at a finished unit, with the pick left out of the reply.
- `handoff-pick-check` counts the pick only when the turn ran that command after the newest handoff write (same Bash record allowed; argv[0] must be the command, so mentions don't count; an `is_error` tool_result doesn't count). Pick words in the closing text no longer satisfy the gate in this mode.
- `core.md`'s "She runs it" clause points at the SessionStart line.
- The `_CMD` suffix keeps it out of project-scope config (a repo must not choose what the session runs).
<!-- SECTION:DESCRIPTION:END -->
