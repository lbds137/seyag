---
id: TASK-86
title: 'SessionStart role trim/refresh directive skips worker sessions'
status: To Do
assignee: []
created_date: '2026-11-22T16:45:00Z'
labels:
  - session
dependencies: []
priority: medium
ordinal: 86000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Mining row w1122-08 (counts 7/7: items/sessions). The role trim/refresh directive reaches worker sessions whose worktree name matches a live role. Detect a worker session, either a linked worktree on an agent branch or the headless worker marker, and skip the directive for it.
<!-- SECTION:DESCRIPTION:END -->
