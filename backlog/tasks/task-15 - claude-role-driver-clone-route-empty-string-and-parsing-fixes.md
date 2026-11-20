---
id: TASK-15
title: 'claude-role/driver-clone: route-empty-string and parsing fixes'
status: To Do
assignee: []
created_date: '2026-11-19T14:23:00Z'
updated_date: '2026-11-20T02:21:00Z'
labels:
  - bin
  - probes
dependencies: []
priority: medium
ordinal: 60
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
- driver-clone dies on `route: ""`, which claude-role and driver-clone themselves write
  (second-generation clone breaks; reachable).
- Section extraction ignores code fences.
- CRLF base file plus a --name value carrying CR.
- --handoff replacement can lose the blank line and mismatches the `## Next` prefix check.
<!-- SECTION:DESCRIPTION:END -->
