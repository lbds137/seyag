---
id: TASK-5
title: 'config-env: parse-time performance on dense-escape inputs'
status: Deferred
assignee: []
created_date: '2026-11-19T14:22:00Z'
labels:
  - perf
  - deferred
dependencies: []
ordinal: 5000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Deferred. Measured on the release tree: a plain 200KB config parses in ~2s; a
dense-escape-heavy 200KB input takes over 30s. Trigger: a real config hitting it, or the next
config-env loader touch. Profile first; the key-normalization loops were already made linear
in the 0.3.188 unit.
<!-- SECTION:DESCRIPTION:END -->
