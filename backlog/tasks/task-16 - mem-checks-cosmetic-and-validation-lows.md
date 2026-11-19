---
id: TASK-16
title: 'mem checks: cosmetic and validation lows'
status: Deferred
assignee: []
created_date: '2026-11-19T14:23:00Z'
labels:
  - bin
  - deferred
dependencies: []
ordinal: 16000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Deferred, low priority. Process names with spaces print wrong (cosmetic; ~10 such processes
exist on a real machine). Non-numeric MemAvailable is not validated (fixture-only). A
relative or user@service cgroup root selects another UID (non-default root only). Two probe
gaps: the in-loop no-MemAvailable case; an owner-default probe that is vacuous and does not
check the command line.
<!-- SECTION:DESCRIPTION:END -->
