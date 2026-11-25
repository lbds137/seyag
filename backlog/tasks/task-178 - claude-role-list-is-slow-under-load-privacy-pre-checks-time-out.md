---
id: TASK-178
title: claude-role --list is slow under load (privacy pre-checks time out)
status: To Do
assignee: []
created_date: '2026-11-25T18:48:00Z'
labels:
  - claude-role
  - performance
dependencies: []
ordinal: 178000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
claude-role --list takes ~1.3 s idle and >20 s at load 50 (Deck Platform's measurement, 11-25); consumers' privacy pre-checks (zai-worker, cc-route; 20 s timeout) then fail closed and refuse launches. Third recurrence. Profile first (which step dominates: role-file parse, per-role subprocesses, session lookups), then make --list cheap. The consumer-side retry behind load-gate is tracked outside this repo.
<!-- SECTION:DESCRIPTION:END -->
