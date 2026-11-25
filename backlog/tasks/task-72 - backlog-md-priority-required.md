---
id: TASK-72
title: 'backlog-md: --priority required when creating or promoting a task'
status: Done
assignee:
  - Seyag
created_date: '2026-11-22T05:50:00Z'
updated_date: '2026-11-25T21:43:00Z'
labels:
  - backlog
dependencies: []
priority: high
ordinal: 72000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Creating a task, or promoting one from parked to To Do, must set a priority. Today nothing enforces it.

Add:
- the rule to the backlog-md skill;
- a mechanical check: a PreToolUse guard on `backlog task create` and on edits that set status without `--priority`, and/or a store check that refuses a To Do task file with no `priority:`. A promote is judged on the resulting file: a task whose file already has `priority:` passes `backlog task edit --status "To Do"` without the flag; one whose file has none is refused.

Pin both the create case and the promote case in the probe.
<!-- SECTION:DESCRIPTION:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Shipped in 0.3.228: backlog-priority-guard (PreToolUse Bash, component backlog-priority) blocks a priority-less task create, a task edit into To Do/In Progress of a priority-less task, and draft promote of a priority-less draft; the backlog-md skill states the rule. The store-check half is TASK-185 (B lane).
<!-- SECTION:FINAL_SUMMARY:END -->
