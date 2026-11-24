---
id: TASK-82
title: 'probe-red-check: --expect TEXT and a both-refs verdict mode'
status: Done
assignee:
  - Seyag B
created_date: '2026-11-22T16:45:00Z'
updated_date: '2026-11-24T14:13:00Z'
labels:
  - probes
dependencies: []
priority: high
ordinal: 82000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Mining rows w1122-04 (counts 12/10: items/sessions) and w1115-14 (counts 69/62: items/sessions). Sessions hand-build the check "does this fail at base?" with git archive and a rerun, and check red-for-the-right-reason by eye. probe-red-check <probe> [base] already runs a probe at a base ref; its current options must be verified before this change. Add --expect TEXT: the probe counts as red only when its failing output contains TEXT. Add a mode that runs the named probes at the base and at HEAD, and prints both verdicts.
<!-- SECTION:DESCRIPTION:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
probe-red-check gains --expect TEXT (exit 3 WRONG REASON) and --both (base RED + here PASS in one run; exit 0 all ok / 1 definite failure / 2 inconclusive). Deliberate narrowing of "failing output": --expect matches only ^FAIL: lines, as a literal substring, so text on an ok: line cannot pass as the red reason (mutation-canary on that condition: CAUGHT by the okline case). Here = the working tree, base worktree fresh per probe. Deferred, not built: treating a death whose error names only the missing name as RED under --expect stays a by-eye check (delegation skill); promote if a session hand-checks it again.
<!-- SECTION:FINAL_SUMMARY:END -->
