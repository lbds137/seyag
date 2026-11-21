---
id: TASK-68
title: 'env-print-guard: a jq filter whose output is redirected to a file is not an env print'
status: To Do
assignee: []
created_date: '2026-11-21T15:23:00Z'
labels:
  - guards
dependencies: []
priority: low
ordinal: 68000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
`env-print-guard` blocked `jq '.hooks.PreToolUse[0].matcher="X"' settings.json > s2.json && …`, a filter rewriting a scratch hook-settings file with no `env` key. It was blocked as "bulk jq filter … exposes secret/environment values in the transcript". The guard's stated remedy, "sink both fds", requires redirecting stderr as well. A stdout redirect to a file already keeps the values out of the transcript.

Fix: treat a jq stage whose stdout is redirected to a file, with no later pipe, as not printing. Keep the block when stdout reaches the terminal, and add probe cases for both.
<!-- SECTION:DESCRIPTION:END -->
