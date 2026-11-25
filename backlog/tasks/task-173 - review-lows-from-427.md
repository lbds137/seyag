---
id: TASK-173
title: 'probes: the #427 review lows'
status: To Do
assignee: []
created_date: '2026-11-25T14:10:00Z'
updated_date: '2026-11-25T14:18:24Z'
labels:
  - probes
dependencies: []
priority: low
ordinal: 173000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
From #427's claude-review (2026-11-25, PASS, three lows). Trigger: the next touch of either safe-worktree-clean probe or worker-sandbox case 7c, or the next free lane-B slot.
1. Obsolete: TASK-172's file rode in #427's commit, not a backlog-only one; already merged, nothing to undo.
2. `ref_plan_p33b`, `ref_plan_p38`, `fail_plan` and `check38b` sit in tests/safe-worktree-clean-fixture.sh but only tests/safe-worktree-clean-apply-hold.probe.sh calls them. Move them into that probe and update the comment that names the fixture as their home (the phrase 'defined in tests/safe-worktree-clean-fixture.sh').
3. tests/worker-sandbox.probe.sh 7c asserts only that the control run lacks "No route to host"; a control that failed some other way (empty output) also passes. Assert `$ctl` contains "timed out" too, after checking connect.py prints that on this route on the CI host as well as the Deck.
<!-- SECTION:DESCRIPTION:END -->
