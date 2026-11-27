---
id: TASK-260
title: >-
  probe-red-check --both under machine load: base run dies as INCONCLUSIVE and
  --both mode hides the base tail
status: To Do
assignee: []
created_date: '2026-11-27T05:43:00Z'
labels:
  - tools
  - testing
dependencies: []
priority: low
ordinal: 260000
---



## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-27 ~00:20-00:27 EST (Seyag B, b87 unit). `probe-red-check --both --base <sha> plugins/seyag/hooks/pr-body-ref-gate.probe.sh` reported `base INCONCLUSIVE | here PASS` twice at machine load ~16 (fleet lint jobs running), while a manual staging run — identical steps: `git worktree add --detach /tmp/x <sha>`, `cp` the uncommitted probe in, `cd` + `bash probe` — classified RED correctly (rc 1, 15 enumerated FAIL lines, same machine, same load band). So the probe CAN complete under that load; the tool's base run died (rc not in 0/1) at least twice, non-deterministically — a wall-clock/load-sensitive row likely killed the base run (TASK-257 family).

Two parts:
1. The base-run death under load (suspect: a timing row exits >1 under fleet load; candidate rows: the 16 KB perf row or the large-listing pipe-race fixture). Needs a load-reproduction run with the base tail captured.
2. The diagnosability gap (the fixable half): single mode prints `tail -n 15` of the base output on INCONCLUSIVE; `--both` mode prints only the per-probe summary line (`base <ref> INCONCLUSIVE | here PASS`) and suppresses the tail, so the base rc and its last output lines are lost exactly when they are needed. Fix: in --both, print the base tail (or write it to a temp file whose path the summary line names) whenever any probe classifies INCONCLUSIVE or WRONG REASON.

Fix shape for 2 is a few lines in the --both summary path; 1 needs a captured tail first. Evidence transcripts existed at /tmp/b87-redcheck.out, /tmp/b87-redcheck2.out, /tmp/b87-redbase.out (volatile); the numbers above are quoted from them.
<!-- SECTION:DESCRIPTION:END -->