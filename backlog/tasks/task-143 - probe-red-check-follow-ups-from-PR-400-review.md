---
id: TASK-143
title: 'probe-red-check: follow-ups from the PR #400 review'
status: To Do
assignee: []
created_date: '2026-11-24T17:52:00Z'
labels:
  - probe-red-check
  - tests
dependencies: []
priority: low
ordinal: 143000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The six low findings from the review of PR #400 (TASK-82: --expect and --both), deferred there and collected here.
1. No probe case runs --both with --expect, so the WRONG REASON path inside --both (exit 1) is untested.
2. An option given after the positionals (`probe-red-check PROBE --expect X`) prints bare usage, or "no such probe: --expect". Add a reason line naming the misplaced option, and consider accepting options anywhere or a `--` separator.
3. In --both, a failed worktree add on a later probe exits before the summary line, so the earlier probes' verdicts are lost.
4. The TERM trap only runs after the probe's `$(...)` returns, so a TERM during a long probe is deferred and case 12 can pass falsely.
5. Fixed in PR #401: TASK-139's text named a machine-local job wrapper.
6. HEAD_SHORT is empty on an unborn HEAD (a repo with no commits), which leaves a blank in the output.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Items 1, 2, 3, 4 and 6 are each fixed with a probe case, or ruled out with the reason recorded here
<!-- AC:END -->
