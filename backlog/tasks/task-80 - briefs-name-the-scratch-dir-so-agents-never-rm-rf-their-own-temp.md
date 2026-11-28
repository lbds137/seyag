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

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Checked 2026-11-27 (Seyag, lane A) against origin/main 406ca3f. The spec template is already covered: delegation/SKILL.md:79 has the worker spec's Scratch line (from 16ce56c, 0.3.183), and agents/implementer.md:17 names scratch-dir too. What is left is the reviewer briefs, both in lane B's skills (lane split 11-24), so this task is routed to Seyag B:
1. delegation/SKILL.md:156, the fresh-context review agent brief: scratch the reviewer writes goes under the dir `scratch-dir <unit>-review` prints, and deletes strictly inside it need no approval (recursive-rm-guard exempts them).
2. review-response/SKILL.md, the "Substitute reviewer" bullet: the same clause.
3. Sweep pr-monitoring for any other reviewer-brief site before closing the class.
Lane A side, checked: advisor and council dispatch read-only opinions, and session-mining's miners write to the corpus, so none of them needs the line. No version bump in B's PR; A folds it into the next release.
<!-- SECTION:NOTES:END -->
