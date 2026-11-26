---
id: TASK-188
title: >-
  lossy-pipe-guard false-blocks a for-list naming the runner when an unrelated
  loop body pipes to a filter
status: To Do
assignee: []
created_date: '2026-11-26T01:11:00Z'
updated_date: '2026-11-26T01:23:00Z'
labels:
  - hooks
  - false-positive
dependencies: []
priority: low
ordinal: 187000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Seen 2026-11-25 (TASK-142 driver): a measurement loop `for c in "long-job run x -- a && b" ...; do echo "$c" | head -1; done` was blocked as a filtered long-job run. The runner words sit inside a quoted for-list item (data), and the pipe-to-filter belongs to an unrelated echo in the loop body. Fix shape: match the runner only where it is a command word (the long-job-chain-check command_word/KEYWORDS logic from TASK-142 is a candidate to share), then replay with tests/replay-hook.sh lossy-pipe-guard --since 7 before landing.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Second sighting 2026-11-25: a backlog task create whose quoted -d text named the runner, piped to head, was blocked.
<!-- SECTION:NOTES:END -->
