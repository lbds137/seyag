---
id: TASK-83
title: 'pr-ci-wait prints the review summary the merge check wants'
status: To Do
assignee: []
created_date: '2026-11-22T16:45:00Z'
labels:
  - pr
dependencies: []
priority: medium
ordinal: 83000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Mining row w1122-05 (counts 15/7: items/sessions). pr-merge-review-check trips on the first gh pr merge almost every time. Make the fired output of pr-ci-wait include the review summary that pr-merge-review-check looks for, so the check passes on the first try when the review is in.
<!-- SECTION:DESCRIPTION:END -->
