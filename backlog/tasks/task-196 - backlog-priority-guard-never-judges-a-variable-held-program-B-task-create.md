---
id: TASK-196
title: backlog-priority-guard never judges a variable-held program ($B task create)
status: To Do
assignee: []
created_date: '2026-11-26T08:15:00Z'
labels:
  - hooks
  - false-negative
dependencies: []
priority: low
ordinal: 194000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-26 while bisecting TASK-191. `B=node_modules/.bin/backlog; $B task create foo` exits 0 (unjudged) while `backlog task create foo` is blocked: cli_of compares argv[0]'s basename against PROGRAMS, and `$B` is never expanded, though shell_state tracks variable assignments. The header's ACCEPTED GAPS lists only argument words starting with $, not a variable-held program. Fix: resolve argv[0] through the walk's tracked vars when it is a bare `$NAME`/`${NAME}` with a known value (unknown value: allow, as today), with a probe fixture for both. Or, if ruled out, add the form to ACCEPTED GAPS.
<!-- SECTION:DESCRIPTION:END -->
