---
id: TASK-133
title: 'run-probes.sh: -j accepts any digit count and wraps at 64 bits'
status: To Do
assignee: []
created_date: '2026-11-24T01:32:39Z'
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
