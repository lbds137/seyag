---
id: TASK-14
title: 'relay-ruling: --run accepts more operators than the error text promises'
status: To Do
assignee: []
created_date: '2026-11-19T14:23:00Z'
updated_date: '2026-11-20T02:21:00Z'
labels:
  - bin
  - probes
dependencies: []
priority: medium
ordinal: 70
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
`relay-ruling --run` accepts `;`, `||`, `&`, `|` (and `&&&`) after the cd-to-absolute-path
prefix although the error text promises `&&`. The owner pastes the produced line into a
shell, so `;`/`&` would run the command in the wrong directory. Require exactly ` && `. Fold
in the review note about running in one login shell.
<!-- SECTION:DESCRIPTION:END -->
