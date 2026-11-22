---
id: TASK-103
title: 'lossy-pipe-guard: a test runner''s --help piped into head is blocked as a suite run'
status: To Do
assignee: []
created_date: '2026-11-22T22:30:00Z'
labels:
  - guard-friction
priority: low
dependencies: []
ordinal: 103000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Observed 2026-11-22: `npx vitest --help 2>&1 | grep ... | head -8` was blocked as "check-suite output truncated".

A `--help`/`-h` or `--version` invocation runs no tests, so the suite family should exempt it. Reading a runner's flags is the way to learn them, and the guard makes that read harder.

Fix with a probe pinning both sides: help piped to head passes, while a real `vitest run | head` stays blocked.
<!-- SECTION:DESCRIPTION:END -->
