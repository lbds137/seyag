---
id: TASK-116
title: 'session mining extract: skip malformed JSONL lines; drop the headless enqueue echo'
status: To Do
assignee: []
created_date: '2026-11-23T03:31:00Z'
labels:
  - mining
  - bin
dependencies: []
priority: low
ordinal: 116000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
From session mining: the extract step's jq stops at the first malformed JSONL line (rc=1, extract truncated); `session-log` already skips such lines with a note, so the extract should do the same. Also, the harness's enqueue record of a headless prompt lands as a byte-identical mid-turn block (enqueue then dequeue milliseconds apart, not a second dispatch), which adds noise to reports: dedupe it.

Owner ruling: re-queue. Low recurrence; ride the next touch of the extract tooling unless it bites first.
<!-- SECTION:DESCRIPTION:END -->
