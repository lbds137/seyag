---
id: TASK-177
title: >-
  long-job: #433 review lows (hint command path, StandardInput* prefix, CPU
  props under --heavy, heavy+alias probe)
status: To Do
assignee:
  - seyag-b
created_date: '2026-11-25T18:48:00Z'
labels:
  - long-job
dependencies: []
ordinal: 177000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
From #433's two PASS reviews (all low). (1) wait/--poll hints print the basename, which is not runnable when SYG_LONG_JOB_CMD's first word is an absolute path off PATH; and a launcher first word (nice/env) names the wrong runner. (2) -p StandardInputText=/StandardInputData= pass the stdio refusal; refuse StandardInput* by prefix. (3) -p CPUWeight/StartupCPUWeight/CPUQuota under --heavy recreate the starvation the slice drop prevents. (4) no real-unit case for the alias through the --lock re-exec (holding the gate lock line). Ruled out: moving disp above the lib load (the cannot-load message): disp needs syg_config_env, which the lib provides; --slice without .slice suffix (systemd-run appends it).
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Observed 11-25 (raises item 1's weight): with SYG_LONG_JOB_CMD set to a runner that has its OWN job store (not an exec wrapper over long-job), a direct `long-job run` printed `<runner>: started ...` and the hint `<runner> wait NAME`; that runner answered `no job named NAME`, while `long-job status NAME` saw it running. The display name is only correct when the first word execs long-job. Fix must cover this case, not just document it: e.g. use the alias only when long-job was reached through it (a marker the wrapper sets, or argv0/parent check), else say long-job.
<!-- SECTION:NOTES:END -->
