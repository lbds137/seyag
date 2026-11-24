---
id: TASK-142
title: Wire long-job-chain-check --hook as a toggleable plugin PreToolUse hook
status: To Do
assignee: []
created_date: '2026-11-24T17:52:00Z'
labels:
  - extraction
  - hooks
dependencies: []
priority: medium
ordinal: 142000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
After TASK-141 ships long-job-chain-check, wire its --hook mode into hooks.json behind its own toggle (hook-wiring probe, replay-hook --since 7), so a machine no longer wires it by absolute path in settings. Trigger: TASK-141 merged.
<!-- SECTION:DESCRIPTION:END -->
