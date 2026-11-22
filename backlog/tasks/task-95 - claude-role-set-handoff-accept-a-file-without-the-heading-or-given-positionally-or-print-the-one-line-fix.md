---
id: TASK-95
title: 'claude-role --set --handoff: accept a file without the heading or given positionally, or print the one-line fix'
status: To Do
assignee: []
created_date: '2026-11-22T17:10:00Z'
labels:
  - session
dependencies: []
priority: low
ordinal: 95000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Mining row w1122-27 (3/3, 3/3, 4/3 items/sessions across three shapes). `claude-role --set … --handoff FILE` fails in two cases:
- the file lacks the leading `## Handoff` heading;
- the file is given positionally.

A third shape is a nonexistent `--file` flag.

Fix:
- Accept a handoff file without the heading, and add the heading itself.
- For a positional or unknown argument, print the exact corrected command in the error.

Probes: one for each of the three shapes.
<!-- SECTION:DESCRIPTION:END -->
