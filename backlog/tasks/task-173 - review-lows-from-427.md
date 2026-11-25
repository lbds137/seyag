---
id: TASK-173
title: 'probes: the #427 review lows'
status: In Progress
assignee:
  - Seyag B
created_date: '2026-11-25T14:10:00Z'
updated_date: '2026-11-25T14:56:13Z'
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
4. (#429 low) tests/scope-drift.probe.sh case 52: bun.lockb is a lockfile, so the case never reached the binary -U0 skip (case 53 does). Say so in its comment.
5. (#429 low) case 48: `mkdir -p "$wt/gradle"` -> `mkdir -p wt/gradle`, matching the case's other paths.
6. (#429 low) Ruled out: the date-only `updated_date` bumps on TASK-164 and TASK-49 were the fix the #420 and #428 lows asked for (reason in the b99ed18 commit message).
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-25 (Seyag B, claimed). Item 3 changed on evidence: the Deck control prints `192.0.2.1 error timed out`, but the CI host's text can't be read: CI runs 7c (SYG_PROBE_REQUIRE_SANDBOX=1) and run-probes prints only a passing probe's summary line. So 7c asserts the host-independent shape instead: the control is connect.py's own report line (`192.0.2.1 ...`) and not "No route to host". That closes the empty-output gap without pinning text that a host rejecting with another error would print differently.
<!-- SECTION:NOTES:END -->
