---
id: TASK-80
title: 'Briefs name the scratch dir so agents never rm -rf their own temp'
status: To Do
assignee: []
created_date: '2026-11-22T16:45:00Z'
labels:
  - delegation
  - worktrees
dependencies: []
priority: medium
ordinal: 80000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Mining row w1122-01 (counts 21/15, 13/9, 17/6: items/sessions). Agents and reviewers delete their own mktemp or job scratch with rm -rf and trip recursive-rm-guard. The guard text already names scratch-dir (plugins/seyag/hooks/recursive-rm-guard.sh), but the delegation spec template and the review-brief templates do not. Add a line to both: scratch goes under T=$(scratch-dir NAME), and deletes inside that directory need no approval.
<!-- SECTION:DESCRIPTION:END -->
