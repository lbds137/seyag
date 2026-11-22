---
id: TASK-81
title: 'session-extract: collapse a repeated identical owner block in the same turn'
status: To Do
assignee: []
created_date: '2026-11-22T16:45:00Z'
labels:
  - session-mining
dependencies: []
priority: low
ordinal: 81000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Mining row w1122-03 (counts 13/13: items/sessions). Headless sessions carry the whole user payload twice in owner extracts. Drop an owner block that is identical to the previous one in the same turn, and print a count line of the blocks dropped.
<!-- SECTION:DESCRIPTION:END -->
