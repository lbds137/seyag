---
id: TASK-261
title: >-
  probe-red-check cannot see the FAIL-bracket failure-line family: 35 probe
  files' real reds classify INCONCLUSIVE
status: To Do
assignee: []
created_date: '2026-11-27T06:16:00Z'
labels:
  - tools
  - testing
dependencies: []
priority: low
ordinal: 261000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-27 ~01:05 EST (Seyag B, b87 unit red-first re-proof). The b87 probe prints its assertion failures as `FAIL [exit=0 want=2 | substr(...)]: label` (one space, bracket detail — pr-body-ref-gate.probe.sh:184 assert_blocks). probe-red-check's FAIL_RE is `^FAIL(:|  )` — the deliberate TASK-155 ruling (shipped 11-25), whose negative fixture pins 'FAIL with one space' as INCONCLUSIVE. A healthy base run of the b87 probe against origin/main (replicated exactly per run_at_base: detached worktree at origin/main, probe copied in, bash from the worktree root) exits rc 1 with 21 intended FAIL-bracket lines and classify_base counts 0 matching FAIL lines -> INCONCLUSIVE ('died before any assertion' is factually wrong: the probe ran to completion). So probe-red-check can never prove red-first for the bracket family — deterministic, load-independent.

Inventory (2026-11-27, git grep -l -E 'FAIL \\[' origin/main -- '*.probe.sh'): 35 probe files contain the bracket form; 110 files match FAIL(:|  ). Positive control: pr-body-ref-gate.probe.sh is in the 35.

This extends (or carves an exception from) TASK-155's deliberate contract — a decision reversal, so do it deliberately: (a) widen FAIL_RE to also accept 'FAIL [' (e.g. ^FAIL(:|  |[[:space:]]*\\[)) and update TASK-155's negative fixture; or (b) migrate the bracket family to the standard two shapes (a hooks-probe sweep, mostly lane A's area). Either way the fix belongs partly to lane B (bin) and partly to lane A (probes); coordinate the split. The b87 PR carries only the manual red-first proof (21 enumerated FAIL-bracket lines); it does not fix this.

Related: TASK-260 (same tool, different half — TASK-260's part-1 'non-deterministic base-run death under load' is now suspected to be this same shape misclassification, not a load death; its body was corrected in the same store commit).
<!-- SECTION:DESCRIPTION:END -->
