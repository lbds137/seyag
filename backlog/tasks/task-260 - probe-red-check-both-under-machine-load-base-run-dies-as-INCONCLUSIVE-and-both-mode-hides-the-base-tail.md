---
id: TASK-260
title: >-
  probe-red-check --both under machine load: base run dies as INCONCLUSIVE and
  --both mode hides the base tail
status: To Do
assignee: []
created_date: '2026-11-27T05:43:00Z'
updated_date: '2026-11-27T06:17:00Z'
labels:
  - tools
  - testing
dependencies: []
priority: low
ordinal: 260000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-27 ~00:20-00:27 EST (Seyag B, b87 unit); premise-corrected 01:20. Symptom as filed: 'probe-red-check --both --base <sha> plugins/seyag/hooks/pr-body-ref-gate.probe.sh' reported 'base INCONCLUSIVE | here PASS' twice at machine load ~16 while a manual staging run classified RED (rc 1, 15 enumerated FAIL lines, same machine, same load band) — read then as a load-sensitive base-run death. Correction (01:05 replication, exact run_at_base steps): the base run does NOT die. It exits rc 1 with 21 intended failure lines — but this probe's assert helpers print 'FAIL [exit=... want=...]: label' (one space, bracket detail), and FAIL_RE '^FAIL(:|  )' (the deliberate TASK-155 ruling, negative fixture pinned) counts 0 of them -> deterministic INCONCLUSIVE, no load sensitivity needed. The 00:20-00:27 pair and the 01:11 run are all explained by the shape, not by load; part 1's timing-row suspect list is withdrawn. The shape misclassification now lives in TASK-261 (fix + family inventory there); TASK-155's contract is the thing to deliberately extend or carve. Remaining here, unchanged — the diagnosability gap: single mode prints 'tail -n 15' of the base output on INCONCLUSIVE; --both mode prints only the per-probe summary line and suppresses the tail, so the base rc and its last output lines are lost exactly when they are needed. Fix: in --both, print the base tail (or write it to a temp file whose path the summary line names) whenever any probe classifies INCONCLUSIVE or WRONG REASON. A few lines in the --both summary path. With the tail visible, TASK-261's shape would have been diagnosed in the first run instead of via manual staging. Evidence transcripts existed at /tmp/b87-redcheck.out, /tmp/b87-redcheck2.out, /tmp/b87-redbase.out, /tmp/b87-base-replica.out (volatile; numbers quoted from them).
<!-- SECTION:DESCRIPTION:END -->
