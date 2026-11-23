---
id: TASK-120
title: 'gate before commit is blind to new files: tracked-only lints (git ls-files) skip untracked files'
status: To Do
assignee: []
created_date: '2026-11-23T07:24:35Z'
labels:
  - probes
  - gate
dependencies: []
priority: medium
ordinal: 120000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Seen on PR #380: the driver ran the full gate (`bash tests/run-probes.sh -j 4`, 121/121) before committing, while the unit's new files were untracked. `tests/python-isolation.probe.sh` lists files with `git ls-files` (line 168), so it never saw the new `hooks/lib/handback_tasks.py`; CI then failed on it. Any probe that enumerates with `git ls-files` or `git grep` has the same blind spot on a pre-commit run.

Fix the class: either the gate step in CLAUDE.md and the delegation skill says to run after staging/committing, or the tracked-file enumerations also include untracked, non-ignored files (`git ls-files --cached --others --exclude-standard`). Sweep every probe that enumerates via git (`git grep -n "ls-files\|git grep" tests plugins/seyag/hooks/*.probe.sh`) and pick per probe. Probe: a planted untracked violating file is caught on a pre-commit run.
<!-- SECTION:DESCRIPTION:END -->
