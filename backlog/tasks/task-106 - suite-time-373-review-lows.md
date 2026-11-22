---
id: TASK-106
title: 'suite-time: #373 review lows (SIGTERM forwarding, non-UTF-8 baseline, slowest --, tolerance probe)'
status: To Do
assignee: []
created_date: '2026-11-22T23:55:00Z'
labels:
  - bin
dependencies: []
priority: low
ordinal: 106000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
These are the lows from the claude-review of #373 (TASK-101), which merged with a PASS verdict. The reviewer traced them by reading the code, so reproduce each one before fixing it. Item 1 of that review (the README skill row) and item 2 (the `(#PR)` fill) shipped in the follow-up PR.

1. **SIGTERM sent to the wrapper alone.** `spawn` handles only `KeyboardInterrupt`. A SIGTERM to the `suite-time` PID alone, as from a CI step timeout, a long-job runner or `kill <pid>`, kills the wrapper at once. The child is orphaned and keeps running, no log row is written, and the caller sees 143. Forward SIGTERM to the child and keep waiting, about three lines, and pin it with a probe: the wrapper is killed, the child sees the TERM, the row is logged with the child's status.
   - This differs from the SIGINT case #373 ruled out. An interactive Ctrl-C reaches the whole foreground group, but a non-interactive SIGTERM reaches only the wrapper.
2. **Non-UTF-8 command never gets a baseline.** The log write uses `backslashreplace`, so a surrogate-escaped argument is stored as the literal text `\udcff`. The in-memory `cmd_text` and the default `name` keep the surrogate, so `prior_walls` never matches them. Apply the same round-trip before comparing, or document it as a known limit. Probe case 12 only checks that the run survives.
3. **`slowest` rejects a file named `-x.xml`.** Accept `--` as an end-of-options marker.
4. **Untested tolerance fallback.** Add a probe case for an invalid `SYG_SUITE_TIME_TOLERANCE` (non-numeric and negative) that pins the warning text and the fallback to 20.
<!-- SECTION:DESCRIPTION:END -->
