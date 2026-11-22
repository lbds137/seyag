---
id: TASK-92
title: 'Version-drift nudge and blocked-page-read hint'
status: To Do
assignee: []
created_date: '2026-11-22T16:45:00Z'
labels:
  - session
  - guards
dependencies: []
priority: medium
ordinal: 92000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Mining rows w1108-08 (counts 15/11: items/sessions) and w1108-09 (counts 7/4: items/sessions). (a) Add a nudge when the loaded plugin version differs from the checkout's version. (b) When a page read is blocked, with a 402, 403 or refusal, a hint names the working fallback route. The route is configured by a knob and is never a hardcoded tool.
<!-- SECTION:DESCRIPTION:END -->
