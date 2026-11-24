---
id: TASK-110
title: 'mutation-canary bin: apply a named mutation, run a probe, report the failing cases, restore'
status: Done
assignee: []
created_date: '2026-11-23T03:31:00Z'
updated_date: '2026-11-24T04:00:00Z'
labels:
  - mining
  - bin
dependencies: []
priority: high
ordinal: 110000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
From session mining (~46 items across ~41 sessions in one week, plus more in other lanes): mutation canaries are hand-built per unit in every code repo, and several first tries were vacuous (the mutation never reached the code the probe runs).

Owner ruling: a small bin. Shape: take a file, a literal old/new pair (or a patch) and a probe command; refuse when the old text is absent or not unique; apply on a scratch copy of the worktree or with a guaranteed restore; run the probe; report red/green plus the failing case labels; restore and verify the file is byte-identical. A canary that stays green is reported as such (the vacuous case). `probe-red-check` is the neighbour to reuse from.
<!-- SECTION:DESCRIPTION:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Shipped in 0.3.220. Added `plugins/seyag/bin/mutation-canary` (literal `--file`/`--old`/`--old-file`/`--new`/`--new-file` and `--patch` modes, `--fail-pattern`, `--no-baseline`, `--timeout`, `--restore`, crash-safe journal under `$(git rev-parse --git-dir)/mutation-canary`, byte-identical and mode-verified restore across normal exit and INT/TERM/HUP traps, inverted exit codes 0 caught / 1 survived / 2 inconclusive, timeout, baseline red, usage or refusal / 3 restore problem) and `tests/mutation-canary.probe.sh` (27 hermetic cases at 0.3.220), plus rows in `tests/probe-durations.tsv` and `README.md` (with `probe-red-check`) and the trigger sentence in `plugins/seyag/skills/delegation/SKILL.md`.
<!-- SECTION:FINAL_SUMMARY:END -->
