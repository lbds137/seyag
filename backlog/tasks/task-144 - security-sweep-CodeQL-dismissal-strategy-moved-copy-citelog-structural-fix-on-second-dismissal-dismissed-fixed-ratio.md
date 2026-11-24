---
id: TASK-144
title: >-
  security-sweep: CodeQL dismissal strategy (moved-copy cite+log, structural fix
  on second dismissal, dismissed:fixed ratio)
status: To Do
assignee:
  - Seyag
created_date: '2026-11-24T18:08:00Z'
labels:
  - security
dependencies: []
priority: high
ordinal: 143000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Owner ruling 2026-11-24 (relayed by the machine session via relay-ruling, her AUQ answer 'Yes, cite + log'): a session may dismiss an alert that is a moved copy of an already-dismissed one (same rule, same sink and flow, no new source) without asking, citing the original alert number and date and appending to a reviewable log; anything new still goes to the owner with the prior-dismissal lookup in the ask; define moved copy tightly, unsure = new. (a) skill security-sweep section 2: prior-dismissal lookup before any ask; moved-copy path; log location named in the skill. (b) second dismissal of a class -> structural fix filed: test paths via CodeQL config paths-ignore/query-filters (needs advanced setup, default setup cannot), by-design sinks via a recognized sanitizer/check or models-as-data, else accepted risk recorded in the tracking surface; accepted-risk dismissals stay labeled won't-fix, not false positive. (c) bin/security-sweep --json + session line: per-repo dismissed:fixed ratio over a window, flag when dismissals outrun fixes (bin is lane B's: A sends B the spec). Starts after TASK-141's PR is open.
<!-- SECTION:DESCRIPTION:END -->
