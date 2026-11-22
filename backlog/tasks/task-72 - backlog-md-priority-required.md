---
id: TASK-72
title: 'backlog-md: --priority required when creating or promoting a task'
status: To Do
assignee: []
created_date: '2026-11-22T05:50:00Z'
labels:
  - backlog
dependencies: []
priority: medium
ordinal: 72000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Creating a task, or promoting one from parked to To Do, must set a priority. Today nothing enforces it.

Add:
- the rule to the backlog-md skill;
- a mechanical check: a PreToolUse guard on `backlog task create` and on edits that set status without `--priority`, and/or a store check that refuses a To Do task file with no `priority:`.

Pin both the create case and the promote case in the probe.
<!-- SECTION:DESCRIPTION:END -->
