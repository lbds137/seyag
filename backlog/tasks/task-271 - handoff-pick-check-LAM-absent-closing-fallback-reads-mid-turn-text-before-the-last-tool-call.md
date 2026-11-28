---
id: TASK-271
title: >-
  handoff-pick-check: LAM-absent closing fallback reads mid-turn text before the
  last tool call
status: To Do
assignee: []
created_date: '2026-11-28T08:00:00Z'
labels:
  - hooks
dependencies: []
priority: low
ordinal: 271000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found while doing TASK-262. When last_assistant_message is blank or absent, handoff-pick-check.sh reads the closing as the last text block in the turn (the `turn_last_text` loop before `if newest_write_off is None`), with no reset at tool_use blocks. If the turn ends on a closing recorded only as signed-empty thinking, mid-turn narration written before the last tool call is judged as the closing. A pick word in that narration passes the gate without a real pick (false negative). The other judging paths are unchanged.

Fix: use TASK-262's turn_scan.closing_text semantics (the last text after the last tool_use), plus the signed-empty disposition if one fits this hook's cost model. Add a probe row with an est-shaped final entry. Older-CC path only: current Claude Code carries the field (probed 2026-11-27, TASK-67).
<!-- SECTION:DESCRIPTION:END -->
