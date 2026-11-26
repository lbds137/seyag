---
id: TASK-200
title: backlog-priority-guard misses a create nested in a span fed to a shell
status: To Do
assignee: []
created_date: '2026-11-26T10:05:00Z'
labels:
  - hooks
  - false-negative
dependencies: []
priority: medium
ordinal: 200000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-26 by the TASK-191 round-3 worker; present before TASK-191 (rc 0 with the prose gate forced closed, which is the pre-TASK-191 path). `bash -c "$(echo 'x=$(npx backlog task create foo)')"` and `eval "$(printf %s 'x=$(npx backlog task create foo)')"` exit 0 though bash executes the create. walk extracts the outer span at depth 0, then recurses on the span text alone (`echo 'x=$(…)'`); there `_SKIP_UNSAFE_TEXT` finds no shell word (the `bash`/`eval` was in the outer text), so `substitution_span_offsets` takes its skip-single-quoted fast path and drops the inner create. Fix direction: carry "an enclosing context executes this text" into the recursive scan (e.g. pass the outer unsafe verdict down), with both commands as `run 2` probe rows. Not added to the probe in TASK-191 because they are red at base.
<!-- SECTION:DESCRIPTION:END -->
