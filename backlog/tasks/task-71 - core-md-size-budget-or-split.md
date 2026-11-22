---
id: TASK-71
title: 'core.md: budget or split it so consumers stay under their instruction-file limits'
status: To Do
assignee: []
created_date: '2026-11-22T05:50:00Z'
labels:
  - rules
  - context
dependencies: []
priority: high
ordinal: 71000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
core.md (always loaded) is 169 lines and 22,093 bytes on main. It pushes at least one consuming project over that project's own instruction-file line limit.

Options:
- (a) Set a hard byte/line budget for core.md, enforced by a probe, and cut it under the budget.
- (b) Split it: keep hard constraints in core, and move procedures into skills and domain detail into `paths:`-scoped rules, each behind a component toggle so a consumer loads only what it uses.

Choose by measurement: which sections each consumer actually needs, and what each consumer's limit is.

Done when: a probe pins the budget, and the measured consumers are under their limits.

Related: TASK-70.
<!-- SECTION:DESCRIPTION:END -->
