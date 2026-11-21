---
id: TASK-54
title: 'automerge: explicit false outputs and an early live head-SHA check'
status: To Do
assignee: []
created_date: '2026-11-21T04:55:00Z'
labels:
  - ci
  - automerge
  - review-follow-up
dependencies: []
priority: low
ordinal: 54000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Follow-ups from the outside review of #362 (TASK-10, merged ff338d6), relayed by the machine-management session 2026-11-20. Both in .github/workflows/claude-code-review.yml, automerge job:
1. The live-state step writes ready=true only (case arm in the `Read the live draft state` step), and the `Merge` step writes merged=true only; write ready=false / merged=false explicitly on the other paths instead of leaving the outputs empty, so downstream `== 'true'` checks and logs read plainly.
2. Read the PR's live head SHA early in the job (next to the live draft read) and stop with a clear log line when it differs from the reviewed SHA, before the up-to-40-minute checks wait. `gh pr merge --match-head-commit` stays the final guard.
<!-- SECTION:DESCRIPTION:END -->
