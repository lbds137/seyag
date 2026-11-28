---
id: TASK-83
title: 'pr-ci-wait prints the review summary the merge check wants'
status: Done
assignee: []
created_date: '2026-11-22T16:45:00Z'
updated_date: '2026-11-28T05:45:00Z'
labels:
  - pr
dependencies: []
priority: medium
ordinal: 83000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Mining row w1122-05 (counts 15/7: items/sessions). pr-merge-review-check trips on the first gh pr merge almost every time. Make the fired output of pr-ci-wait include the review summary that pr-merge-review-check looks for, so the check passes on the first try when the review is in.
<!-- SECTION:DESCRIPTION:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Shipped by lane A (B parked). On CI_COMPLETE with no automerge job, pr-ci-wait runs the real pr-merge-review-check hook through hooks/run.sh with a synthetic `gh pr merge N` payload and streams its block BEFORE the sentinel, so the review reaches the agent ahead of the line it acts on and the session's own first merge proceeds. SYG_CI_WAIT_PRIME_REVIEW=0 turns it off. A hook exit other than 0/2, or a timeout, warns "ack state unknown". Council review (openai) round 1 moved priming ahead of the sentinel and added the exit-code check. Ruled out: dropping the env test seam (the environment is already the trust boundary; sibling probes use the same seam). Residuals, recorded in the hook header: a non-streaming runner acks a review nobody read; the ack is per user, as it already was.
<!-- SECTION:FINAL_SUMMARY:END -->
