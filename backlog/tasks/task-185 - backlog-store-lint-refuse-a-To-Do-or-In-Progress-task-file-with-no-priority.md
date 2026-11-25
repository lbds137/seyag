---
id: TASK-185
title: 'backlog store lint: refuse a To Do or In Progress task file with no priority'
status: To Do
assignee: []
created_date: '2026-11-25T20:19:00Z'
labels:
  - bin
  - backlog
dependencies: []
priority: medium
ordinal: 184000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Split from TASK-72 (Seyag A). TASK-72 ships a PreToolUse guard (backlog-priority-guard) that blocks CLI creates and status moves leaving a task without a priority. It cannot see frontmatter hand-edited via Edit/Write or sed, nor task restore of an archived priority-less task. A store lint bin (B lane: plugins/seyag/bin) would catch the resulting file state. Note: wiring a store lint here also meets the CLAUDE.md condition that keeps the backlog-only direct-to-main path closed, so landing it is an owner decision on that path too.
<!-- SECTION:DESCRIPTION:END -->
