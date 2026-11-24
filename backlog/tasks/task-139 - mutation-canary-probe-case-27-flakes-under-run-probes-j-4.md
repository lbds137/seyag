---
id: TASK-139
title: mutation-canary probe case 27 flakes under run-probes -j 4
status: To Do
assignee: []
created_date: '2026-11-24T15:13:00Z'
labels:
  - mutation-canary
  - tests
dependencies: []
priority: medium
ordinal: 139000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Observed 2026-11-24: in a full `bash tests/run-probes.sh -j 4` run (deck-job b82-suite, branch worktree-agent-b82, mutation-canary unchanged by that branch), case 27 reported "FAIL: 27. double TERM during cleanup: stubborn probe (459336) still alive" while its exit-143 and restore checks passed. `bash tests/mutation-canary.probe.sh` alone right after: all ok. Hypothesis, not confirmed: the check runs `kill -0 $stpid` the instant the tool exits, and under load the KILLed stubborn child can still be alive or not yet reaped (kill -0 succeeds on a zombie). If so, the tool is right and the probe races. Candidate fix: poll `kill -0` for up to a few seconds before failing, or check /proc/PID/stat for state Z. Rule out first that the tool exits before its KILL escalation lands (a real leak).
<!-- SECTION:DESCRIPTION:END -->
