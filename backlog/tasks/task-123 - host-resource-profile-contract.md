---
id: TASK-123
title: 'Host resource profile: one contract that gates, probes and skills honour on low-memory machines'
status: Done
assignee: []
created_date: '2026-11-23T16:15:00Z'
labels:
  - bin
  - skills
dependencies: []
priority: medium
ordinal: 123000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Request from the machine-management session (2026-11-23). Seen on one machine: a repo's pre-push hook had its own low-resource flag, read only from the environment or the checkout's `.env`. A worktree has no `.env` and the core-count auto-detect did not fire, so a push from a worktree fanned out lint and starved the machine.

- Define one host-set contract: `SYG_RESOURCE_PROFILE=low|normal`, plus an optional `SYG_MAX_PARALLEL=N`.
- Read order: the environment first, then the main checkout (`git rev-parse --git-common-dir`), not only the worktree. Offer a MemAvailable-based auto-detect.
- Seyag's own gates and probe runner honour it (`tests/run-probes.sh -j`).
- The delegation and testing-discipline skills tell repos to map it onto their tools' knobs: turbo `--concurrency`, jest/vitest `--maxWorkers`, a `NODE_OPTIONS` heap cap, `make -j`.
- Today seyag has `mem-gate` (`SYG_MEM_GATE_MIN_MB`), a launch gate, and no parallelism knob: `git grep -nIiE 'SYG_RESOURCE|MAX_PARALLEL|low[-_ ]resource'` matched nothing, while the same search matched `mem-gate` (driver, 2026-11-23).
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
- **Ruled out: the main-checkout read (`--git-common-dir`).** The environment and the user config file (`${XDG_CONFIG_HOME:-$HOME/.config}/seyag/config.toml`) already reach every worktree, so a host setting needs no repo file. Reading a repo's files would also let a tracked file loosen a host ceiling. The requester agreed on 2026-11-23.
- **New `host` flag in knobs.tsv.** It refuses a knob from the project file (`.claude/seyag.toml`), as `path` does. All the new knobs carry it, and so does `SYG_MEM_GATE_MIN_MB`, which a project file could previously lower.
- **`auto` profile.** It is computed at call time: a memory ceiling from MemAvailable, and a ceiling of 1 while CPU pressure (`some avg60`) is at or above 50, as the requester asked. Unset keeps today's behaviour, and the profile only ever lowers `-j`.
<!-- SECTION:NOTES:END -->
