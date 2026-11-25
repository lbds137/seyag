---
id: TASK-162
title: 'fixup-push --resolved: pin intermediate commit content, not just paths'
status: Done
assignee:
  - Seyag B
created_date: '2026-11-25T05:40:00Z'
updated_date: '2026-11-25T05:53:00Z'
labels:
  - bin
  - tests
dependencies: []
priority: medium
ordinal: 162000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
From #415's claude-review (2026-11-25, PASS, lows). The reviewer graded these low; B rates item 1 medium because it is a hole in a publishing guard.
1. The `--resolved` intermediate check compares only WHICH paths each intermediate local commit changes (`diff-tree mb c` ⊆ BASE ∪ br_set), not their content. A file that only the branch changed can get arbitrary content in commit i, then be restored by commit k, and the push still passes. Example: a credential pasted into `f2.txt` in commit 1 and removed in commit 2. That content gets published, and because `f2.txt` is not in the overlap list, nothing prompts a re-review. The `rebased` shape has no such gap, because patch-ids pin every commit. Fix: pair each intermediate local commit with the remote commit at the same index (the subject check already pairs them by index) and require byte-identity outside BASE, the same way the tip check works. Add a probe where a branch-only file changes in an intermediate commit and is restored at the tip; it must be refused.
2. Notes wording: change "files the base changed after it" to "files the base changed after the local merge-base".
Disposition of the third low (`--resolved` is a silent no-op when the patch-identical proof passes or the remote is an ancestor): this is deliberate, and v9 pins it. No hint line.
<!-- SECTION:DESCRIPTION:END -->
