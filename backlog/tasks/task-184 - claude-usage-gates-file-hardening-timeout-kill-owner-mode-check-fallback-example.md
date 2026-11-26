---
id: TASK-184
title: >-
  claude-usage gates file: hardening from #436 review (timeout -k, owner/mode
  check, fallback example)
status: To Do
assignee:
  - Seyag B
created_date: '2026-11-26T01:50:00Z'
labels:
  - claude-usage
  - bin
dependencies: []
priority: low
ordinal: 183500
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The #436 claude-review (PASS, lows only) on apply_gates_file in plugins/seyag/bin/claude-usage: (1) `timeout 5` signals only its direct child, so a gates file that traps SIGTERM runs unbounded: pass `-k 1`; a backgrounded grandchild holding stdout keeps the `$(...)` open: document "don't leave background children holding stdout" in the header (and the same for the existing `_CMD` runners, which share the pattern). (2) Before running the gates file, check it is owned by the user (`-O`) and not group- or world-writable; on failure skip it with one note, like the not-executable case. (3) Add a docs/config.md or header example pairing a `_CMD` with its static, since a file-set `_CMD` that fails falls back to the default, not the env static (the accepted slot-rule behaviour). Probe rows for (1) a SIGTERM-trapping file and (2) a group-writable file. The project-scope exec-list entry (`_SYG_CFG_PROJECT_EXEC`, hooks lane) was sent to lane A, not tracked here.
<!-- SECTION:DESCRIPTION:END -->
