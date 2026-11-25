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
