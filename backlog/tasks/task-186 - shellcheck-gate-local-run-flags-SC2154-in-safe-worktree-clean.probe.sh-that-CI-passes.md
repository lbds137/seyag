---
id: TASK-186
title: >-
  shellcheck-gate: local run flags SC2154 in safe-worktree-clean.probe.sh that
  CI passes
status: To Do
assignee: []
created_date: '2026-11-25T21:05:00Z'
labels:
  - probes
  - tests
dependencies: []
priority: low
ordinal: 185000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by Seyag A on 2026-11-25 at base 1a642fb. Running 'bash plugins/seyag/bin/shellcheck-gate -S warning' locally reports SC2154 (fail is referenced but not assigned) at tests/safe-worktree-clean.probe.sh:935 ('exit $fail'). fail is assigned in the sourced tests/safe-worktree-clean-fixture.sh:15. CI's shellcheck job passed on main 18f8644, so the local gate and CI disagree: either their shellcheck versions or the source-following (-x / source= directive) differ. Fix options: a '# shellcheck source=' directive at the source line, or align shellcheck-gate with CI's flags. Owner of the file: lane B (the probe came with #427/#431).
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Root cause (Seyag B, 2026-11-26, probed): chunking, not versions. shellcheck follows a sourced file only when it is named in the same invocation or -x is given. CI runs one invocation over all of tests/shell-files.sh; shellcheck-gate runs xargs -n 20, and the fixture is file 160 and the probe file 161 of that list, so they land in different chunks. Probe: `uvx --from shellcheck-py shellcheck -S warning tests/safe-worktree-clean.probe.sh` exits 1; adding the fixture to the same call exits 0. The source= directive is already at probe line 12. Fix shape: run each chunk with -x (external sources; the directive then resolves whatever the chunking), and add a probe that puts a source/sourcer pair across a chunk boundary (SYG_SHELLCHECK_CHUNK=1).
<!-- SECTION:NOTES:END -->
