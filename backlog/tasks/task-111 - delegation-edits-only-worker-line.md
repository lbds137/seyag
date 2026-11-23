---
id: TASK-111
title: 'delegation: dispatch template says when a worker cannot run Bash'
status: To Do
assignee: []
created_date: '2026-11-23T03:31:00Z'
labels:
  - mining
  - delegation
dependencies: []
priority: medium
ordinal: 111000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
From session mining (~36 items across ~13 sessions in one week, more before): headless edits-only workers and reviewers rediscover, one command at a time, that every Bash form is gated; once a verdict was lost to a gated write and the review ran twice.

Owner ruling: a line in the delegation prompt template. Shape: when the worker's route has no Bash, the spec says so up front, lists the checks the driver will run instead, and tells the worker to put its verdict in its final message rather than a file.
<!-- SECTION:DESCRIPTION:END -->
