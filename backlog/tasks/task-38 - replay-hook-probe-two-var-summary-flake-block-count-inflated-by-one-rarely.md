---
id: TASK-38
title: >-
  replay-hook probe: two-var summary case flakes — an unarmed fixture hook is
  rarely counted as blocked (1/25 observed)
status: To Do
assignee: []
created_date: '2026-11-20T01:13:00Z'
labels:
  - probes
dependencies: []
priority: low
ordinal: 38000
---

<!-- SECTION:DESCRIPTION:BEGIN -->
Observed 2026-11-19 during the TASK-25 unit (replay-hook session_id injection), in
`tests/replay-hook.probe.sh`'s pre-existing "two-var field summary" case — untouched by
that unit's diff. One FAIL in the unit's full gate run, then 1 hit in 25 loop runs, 0 in
60 loop runs on a quiet machine:

```
FAIL: two-var field summary: replay-hook: fixture-two: 1/6 commands blocked across 2 files (INERT: FIXTURE_ARM_VAR unset or empty)
```

An unarmed fixture hook (must exit 0) was counted as blocked, inflating the count by one.
Hypotheses checked and cleared: pipe SIGPIPE under pipefail (0/1500 stress loop);
concurrent-shellcheck load overlaps the first hit but the loop hit is unattributed. Not
reproduced on a quiet machine; output of a hit not captured. The replay pipeline
(`printf | env ... bash hook` under pipefail) is unchanged from base. Probe
load-flake class (Lane B owned row). Next step: capture a failing run's full output
(loop until hit, tee to a file), then attribute — suspect ordering/interleave in the
`out=$(printf ... | env ...)` capture or a transient nonzero exit from the hook's env
prefix.
<!-- SECTION:DESCRIPTION:END -->
