---
id: TASK-174
title: 'lossy-pipe-guard: cover the long-job runner''s run verb piped into a filter'
status: To Do
assignee: []
created_date: '2026-11-25T15:00:00Z'
labels:
  - hooks
  - guard
dependencies: []
priority: medium
ordinal: 174000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Spec from lane B (11-25). Case: `<runner> run NAME -- CMD | grep …` hid a memory-gate refusal the runner printed before the job started, and the session read "no output" as "running fine".

Shape: when a pipeline's first word is `long-job` or matches the first word of `SYG_LONG_JOB_CMD` (so nothing machine-specific enters the repo; the same matching `long-job-chain-check` uses), its second word is `run`, and it is piped into head/tail/sed/grep/awk, block with the advice the commit/push family gives: run it unfiltered, since the output is short when it works.

Evidence it is not covered: `git grep -i 'deck-job\|long-job' plugins/seyag/hooks` on origin/main 6591e61 matches only session-start, not lossy-pipe-guard (per lane B; re-run before building).

Before landing: replay with `tests/replay-hook.sh lossy-pipe-guard --since 7` and sample the blocked set. Owner: hooks lane (A).
<!-- SECTION:DESCRIPTION:END -->
