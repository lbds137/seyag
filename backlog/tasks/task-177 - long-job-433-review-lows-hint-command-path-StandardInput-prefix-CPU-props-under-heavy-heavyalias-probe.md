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
