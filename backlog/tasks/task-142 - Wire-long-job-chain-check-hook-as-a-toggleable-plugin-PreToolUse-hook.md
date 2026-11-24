---
id: TASK-142
title: Wire long-job-chain-check --hook as a toggleable plugin PreToolUse hook
status: To Do
assignee: []
created_date: '2026-11-24T17:52:00Z'
updated_date: '2026-11-24T22:32:00Z'
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

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Known gap to decide before wiring the hook as blocking (found in #404 round 2): long-job-chain-check folds $( … ) and backticks into one word and does not recurse, so 'x=$(long-job run x -- a && b)' is not refused although b runs at once outside the job (same as the original machine checker; the probe pins it as clean, tests/long-job-chain-check.probe.sh case 'folds $(...) into one word'). Fix: recurse into $( ) bodies like eval, then flip that probe case to refuse.
<!-- SECTION:NOTES:END -->
