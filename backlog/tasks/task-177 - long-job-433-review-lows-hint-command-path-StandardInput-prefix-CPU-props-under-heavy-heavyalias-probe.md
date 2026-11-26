---
id: TASK-177
title: >-
  long-job: #433 review lows (hint command path, StandardInput* prefix, CPU
  props under --heavy, heavy+alias probe)
status: In Progress
assignee:
  - seyag-b
created_date: '2026-11-25T18:48:00Z'
labels:
  - long-job
dependencies: []
priority: low
ordinal: 177000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
From #433's two PASS reviews (all low). (1) wait/--poll hints print the basename, which is not runnable when SYG_LONG_JOB_CMD's first word is an absolute path off PATH; and a launcher first word (nice/env) names the wrong runner. (2) -p StandardInputText=/StandardInputData= pass the stdio refusal; refuse StandardInput* by prefix. (3) -p CPUWeight/StartupCPUWeight/CPUQuota under --heavy recreate the starvation the slice drop prevents. (4) no real-unit case for the alias through the --lock re-exec (holding the gate lock line). Ruled out: moving disp above the lib load (the cannot-load message): disp needs syg_config_env, which the lib provides; --slice without .slice suffix (systemd-run appends it).
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Observed 11-25 (raises item 1's weight): with SYG_LONG_JOB_CMD set to a runner that has its OWN job store (not an exec wrapper over long-job), a direct `long-job run` printed `<runner>: started ...` and the hint `<runner> wait NAME`; that runner answered `no job named NAME`, while `long-job status NAME` saw it running. The display name is only correct when the first word execs long-job. Fix must cover this case, not just document it: e.g. use the alias only when long-job was reached through it (a marker the wrapper sets, or argv0/parent check), else say long-job.

Scope revised 11-25 21:10 (Seyag B), per the note above: the handoff's "full first word in hints + a doc line" was a no-op for the recorded case (a bare on-PATH runner with its own store prints the same hint). Probed: inside an exec'd bash script neither $0 (even after `exec -a`) nor $PPID names the wrapper. So item 1 becomes a marker: new env-only knob SYG_LONG_JOB_AS, set by an exec wrapper (bare name or absolute path); message prefix and ended sentinel use its basename, wait/status hints the whole value; unset or invalid gives long-job. long-job stops reading SYG_LONG_JOB_CMD for its name (chain-check and lossy-pipe-guard still match it). Wrapper contract change: an exec wrapper must set SYG_LONG_JOB_AS (CHANGELOG line, and Deck Platform told at merge).

Review (Sonnet, cross-family to the GLM worker) PASS, lows: CPUShares/StartupCPUShares added to the --heavy drop (fixed). Ruled out: a warning on an invalid SYG_LONG_JOB_AS (it only affects hint text; a note on every call would be noise; S10 pins the silent fallback). The released 0.3.227 CHANGELOG entry still describes the SYG_LONG_JOB_CMD rule; the new entry (PR body, for lane A) says SYG_LONG_JOB_AS replaces it.
<!-- SECTION:NOTES:END -->
