---
id: TASK-178
title: claude-role --list is slow under load (privacy pre-checks time out)
status: In Progress
assignee:
  - seyag-b
created_date: '2026-11-25T18:48:00Z'
labels:
  - claude-role
  - performance
dependencies: []
priority: medium
ordinal: 178000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
claude-role --list takes ~1.3 s idle and >20 s at load 50 (a consumer session's measurement, 11-25); consumer launchers' privacy pre-checks (20 s timeout) then fail closed and refuse launches. Third recurrence. Profile first (which step dominates: role-file parse, per-role subprocesses, session lookups), then make --list cheap. The consumer-side retry behind load-gate is tracked outside this repo.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Profile 11-25 (load 25, 23 role files): 1.5 s; strace 205 execve (92 awk + 92 cat + 17 basename), wait4 86% of syscall time: per file 4 field() awk calls, each piped to flat()'s cat, plus basename. Baseline before the fix, 11-25 21:05 at load 25: 2.85-4.54 s over 3 runs. Fix: --list parses every role file in one awk pass (shared parser text with field()). Deferred: --board and --json keep the per-field shape (5-9 awk per role); trigger to promote: a caller runs either under a timeout, or either shows in a load-time failure.

Review (Sonnet, cross-family to the GLM worker): 1500-file fuzz byte-identical to the old loop. MEDIUM fixed: an unreadable or dangling role file was fatal to gawk, dropping every later row (and the one before it) with exit 0, the dangerous direction for fail-closed privacy pre-checks; the file list now skips it with a stderr note, as the per-file loop's outcome was, and a probe case pins it (red-checked on the pre-fix script). Lows fixed: dead `front == 2` rule removed; the exec-count case pins awk to exactly 1. Ruled out: a gawk-only note for `nextfile` (POSIX 2024, in gawk, mawk 1.3.4+ and busybox).
<!-- SECTION:NOTES:END -->
