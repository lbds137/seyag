---
id: TASK-171
title: 'Probe hardening: the #423 review lows'
status: In Progress
assignee:
  - Seyag B
created_date: '2026-11-25T11:30:00Z'
labels:
  - tests
dependencies: []
priority: low
ordinal: 171000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
From #423's claude-review (2026-11-25, PASS, four lows). Each item's disposition:
1. `tests/fixup-push.probe.sh` v19 relies on `REAL_GIT` set ~850 lines earlier in case aj; re-assign it beside v19's `GIT_WRAPPER_DIR`. To do.
2. `tests/claude-role.probe.sh` over-noupd case never shows the fixture is over the cap; add a guard (a one-char holds= growth on a copy refuses, as over1.md does for status_at). To do.
3. Same case: the label says "changes nothing else" but only the updated: insert is checked; diff the file against its pre-write content minus the updated: line. To do.
4. `setup_conflict_fixture` failures cascade into unrelated FAIL lines because callers ignore its return 1; `git rebase --abort` in the helper's failure paths. To do.
<!-- SECTION:DESCRIPTION:END -->
