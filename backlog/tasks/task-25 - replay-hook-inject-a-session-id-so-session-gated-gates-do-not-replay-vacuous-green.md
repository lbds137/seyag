---
id: TASK-25
title: >-
  replay-hook: inject a session id so session-gated gates do not replay
  vacuous-green
status: Done
assignee:
  - seyag-b
created_date: '2026-11-19T14:24:00Z'
labels:
  - probes
dependencies: []
ordinal: 25000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The hook replay tool has no session id to inject, so session-gated gates replay without
their gating condition and pass vacuously. Inject one (fixture shape per the replay tool's
docs).
<!-- SECTION:DESCRIPTION:END -->
