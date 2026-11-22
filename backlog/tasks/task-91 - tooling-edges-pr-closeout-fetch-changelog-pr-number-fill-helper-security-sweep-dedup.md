---
id: TASK-91
title: 'Tooling edges: pr-closeout fetch, CHANGELOG PR-number fill helper, security-sweep dedup'
status: To Do
assignee: []
created_date: '2026-11-22T16:45:00Z'
labels:
  - pr
  - release
  - security
dependencies: []
priority: medium
ordinal: 91000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Mining row w1115-23 (counts not recorded in the source row). Three edges to fix. (a) pr-closeout fetches before it judges a branch merged. (b) The helper that fills CHANGELOG (#PR) refs covers the newest section only and skips the template line; a global sed clobbered line 3 on 5 or more PRs (counts 7/6: items/sessions). Limit the fill to the newest section and exclude the template line. (c) security-sweep dedups repeated alerts (counts 2/2: items/sessions).
<!-- SECTION:DESCRIPTION:END -->
