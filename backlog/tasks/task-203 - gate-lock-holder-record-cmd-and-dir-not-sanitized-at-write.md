---
id: TASK-203
title: 'gate-lock: holder record cmd= and dir= are not sanitized at write'
status: Done
assignee:
  - Seyag B
created_date: '2026-11-26T22:15:02Z'
labels:
  - bin
  - security
  - lane-b
dependencies: []
priority: high
ordinal: 203000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the claude-review of PR #449 (2026-11-26, low severity, security class). `write_record` passes only the label through `sanitize_val`; the command and directory basenames are written raw (`plugins/seyag/bin/gate-lock`, the `printf -v rec` in `write_record`). A directory basename containing a newline injects extra `key=value` lines into the holder record; a reader keeps the last value per key, so a forged `pid=`+`start=` pair makes a waiter print that same-user process's live working directory from `/proc`. Impact is limited to same-user processes and needs a newline in a directory name, but the feature's stated contract is that every record value is sanitized, so write time must match.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Done by Seyag B in the TASK-203 PR. Fix: `write_record` passes `cmd` and `dir` through `sanitize_val` after `base_of`, so every record value is stripped of control characters and capped at 120 bytes at write (the label already was; readers sanitize at read). Probe R8 pins it: a holder running from a directory named with newline/CR/BEL and a command named with newline/CR/ESC produces exactly the 7 `key=` lines with no control characters in the values. The same PR carries the other #449 review lows and the deck-platform raced-pid fix (walker ENOENT suppression, fallback skip instead of `? 0s`).
<!-- SECTION:NOTES:END -->
