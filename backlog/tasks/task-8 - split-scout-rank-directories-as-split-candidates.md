---
id: TASK-8
title: 'split-scout: rank directories as split candidates'
status: To Do
assignee: []
created_date: '2026-11-19T14:23:00Z'
labels:
  - bin
  - skills
dependencies: []
ordinal: 8000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Generic tool that ranks tool-directory trees as split candidates. Signals: size (non-test
lines, file count), 30-day churn, co-change coupling from git history (files changing
together across dirs = one hidden unit; same-dir files that never co-change = two units),
optional import fan-in/fan-out adapter (e.g. dependency-cruiser JSON), junk-drawer dirs
(utils/helpers/common) over a size threshold. Output: ranked table plus --json for briefing.
Top candidate goes to the owning repo's design session, never straight to a refactor.
Slot: after the mining asks-lens hands off. Design notes live in a private planning doc.
<!-- SECTION:DESCRIPTION:END -->
