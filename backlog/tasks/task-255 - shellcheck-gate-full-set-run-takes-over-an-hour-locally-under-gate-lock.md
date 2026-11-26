---
id: TASK-255
title: 'shellcheck-gate: full-set run takes over an hour locally under gate-lock'
status: To Do
assignee: []
created_date: '2026-11-26T16:15:00Z'
labels:
  - bin
  - lane-b
dependencies: []
priority: high
ordinal: 255000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported by a consumer session (2026-11-26), observed by that session, not reproduced here: a full-set `shellcheck-gate -S warning $(bash tests/shell-files.sh)` held the gate lock for over 60 minutes, twice in one morning. It was still advancing chunk by chunk through `xargs -n 20 -P 1 uvx --from shellcheck-py ...`. The same check runs in about a minute in CI, and 3 files take about 1 s locally without the lock. Gates queued behind it timed out, including another project's worker gates, which hit a 1 h print timeout.

Hypothesis (the reporter's, unmeasured): per-chunk `uvx` startup under load dominates.

Fix shape: measure first (time per chunk; `uvx` resolve versus shellcheck itself; the lock wait versus the run). Then cut the cost, e.g. resolve the shellcheck binary once and run chunks against it directly, or use bigger or parallel chunks within the memory gate. Record the before/after numbers here. Related: TASK-256 (gate-lock hold limit and holder report).
<!-- SECTION:DESCRIPTION:END -->
