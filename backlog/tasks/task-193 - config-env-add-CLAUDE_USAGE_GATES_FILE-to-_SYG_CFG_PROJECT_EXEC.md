---
id: TASK-193
title: 'config-env: add CLAUDE_USAGE_GATES_FILE to _SYG_CFG_PROJECT_EXEC'
status: To Do
assignee: []
created_date: '2026-11-26T01:50:00Z'
labels:
  - hooks
  - security
dependencies: []
priority: low
ordinal: 192000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
From the #436 claude-review (TASK-180, 2026-11-25), routed to lane A. Defence in depth: knobs.tsv's path flag already refuses the gates file from project scope (pinned in tests/claude-usage.probe.sh); also list it in _SYG_CFG_PROJECT_EXEC in plugins/seyag/hooks/lib/config-env.sh (near :79) so the exec-knob refusal covers it too. Add a probe case for the project-scope refusal through config-env.
<!-- SECTION:DESCRIPTION:END -->
