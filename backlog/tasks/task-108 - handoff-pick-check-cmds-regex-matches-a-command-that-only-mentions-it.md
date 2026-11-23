---
id: TASK-108
title: 'handoff-pick-check: SYG_HANDOFF_CMDS matches a command that only mentions the pattern'
status: To Do
assignee: []
created_date: '2026-11-23T03:00:00Z'
labels:
  - hooks
dependencies: []
priority: low
ordinal: 108000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
`SYG_HANDOFF_CMDS` is searched against the raw Bash command text, so a command that only carries the pattern as data counts as a handoff write. Observed during TASK-107: a replay script launched with `export SYG_HANDOFF_CMDS='<the regex>'` inside it, and the gate blocked that turn's stop.

Fix shape: match against the executed argvs (`turn_scan.command_argvs`, as TASK-107's emitter mode does), joined back with spaces, instead of the raw text. Keep a raw-text fallback for the ambiguous commands where `command_argvs` returns `[]`. Probe it with a command that quotes the pattern as data (passes) next to a real handoff command (fires).
<!-- SECTION:DESCRIPTION:END -->
