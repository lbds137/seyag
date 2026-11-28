---
id: TASK-276
title: 'security-sweep: lazy-import concurrent.futures on early-exit paths'
status: To Do
assignee: []
created_date: '2026-11-28T16:35:00Z'
labels:
  - bin
  - faster-tests
dependencies: []
priority: low
ordinal: 276000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Deferred from FASTER TESTS 5/N (security-sweep probe canary phase). `plugins/seyag/bin/security-sweep` imports `concurrent.futures` (ThreadPoolExecutor, wait) at module top (line 36), so even invocations that exit before any fan-out (usage errors, config refusals, cache hits) pay the import. Measured 2026-11-28 on c88c520: A/B base probe run 3x each, 22.06 s vs 20.61 s mean with the import moved into the fan-out function. The runs were noisy (one run at 18.96 s), and about 11 s of suite wall is projected across the probe's many short invocations. Only early-exit paths benefit.

Shape: move the import into the function that builds the pool. Because this is a bin change, it needs its own parity check (same stdout/stderr/rc across the probe's rows) and a fresh A/B with at least 5 runs per arm, so the result clears the noise above.

Promote when: the security-sweep probe is again in the suite's top 5 after 5/N lands, or the next PR that touches this bin's imports.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 concurrent.futures imported only on the path that fans out
- [ ] #2 A/B with at least 5 runs per arm recorded in the PR, with mean and spread
- [ ] #3 security-sweep probe green; output parity on every row
<!-- AC:END -->
