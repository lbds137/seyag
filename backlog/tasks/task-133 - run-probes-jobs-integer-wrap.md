---
id: TASK-133
title: 'run-probes.sh: -j accepts any digit count and wraps at 64 bits'
status: Done
assignee: []
created_date: '2026-11-24T01:32:39Z'
updated_date: '2026-11-24T02:26:00Z'
labels:
  - tests
dependencies: []
priority: low
ordinal: 133000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the TASK-123 review (2026-11-23). In `tests/run-probes.sh`, `-j`/`--jobs` is checked only against `^[0-9]+$` and then evaluated with `$((10#$JOBS))`. That arithmetic wraps at 64 bits, so `-j 99999999999999999999` becomes `7766279631452241919` and is used as the job count.

`resource-profile --jobs` now caps input at 9 digits and exits 2 on larger values. When that happens, the runner's clamp fails open and keeps the wrapped value.

Fix: cap the runner's own `-j` pattern the same way (`^[0-9]{1,9}$`, otherwise usage), and add a runner-probe case for it.
<!-- SECTION:DESCRIPTION:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Shipped in 0.3.219 with TASK-134: run-probes.sh strips leading zeros, then refuses more than 9 significant digits with usage (exit 2) before the 10# arithmetic, so -j 99999999999999999999 and --jobs=1234567890 now print usage instead of wrapping; -j 0000000000001 stays valid (counts significant digits, not raw length, unlike the ^[0-9]{1,9}$ sketch here). Runner-probe cases pin all three.
<!-- SECTION:FINAL_SUMMARY:END -->
