---
id: TASK-70
title: 'context-audit: an automated trigger for the always-loaded budget, plus the purpose principle'
status: To Do
assignee: []
created_date: '2026-11-22T05:50:00Z'
labels:
  - context
  - rules
dependencies: []
priority: high
ordinal: 70000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Measured on one heavy consumer: about 48k tokens are loaded up front. The shared base is about 15k of that: core rules about 5.5k, the memory index about 4.7k, and about 37 skill descriptions about 3.7k.

Already shipped (checked against the code): `context-audit weigh` counts SessionStart hook output from the newest transcript, and `--budget BYTES` / `CONTEXT_AUDIT_BUDGET` exit 1 past a budget (815463c; `plugins/seyag/bin/context-audit:16-18`). doc-audit names a manual trigger: run it before a PR that grows the up-front set (`plugins/seyag/skills/doc-audit/SKILL.md:38`).

Missing: a trigger that fires without anyone remembering it.
1. A SessionStart warning (its own component, off by default or warn-only) when the folder's up-front set exceeds a configured budget, and/or a CI check for repos that set a budget.
2. Restate the rule in the warning or CI message text itself, not as new rule text: always-loaded text holds hard constraints and pointers; procedures go to skills; domain detail goes to `paths:`-scoped rules. core.md:147 and doc-audit already carry it; do not add a third copy or grow core.md.
3. The owner's principle that complexity must serve a purpose: keep a piece only where it earns its place, and show each piece next to its purpose. core.md:146 already carries the first half. Add "show each piece next to its purpose", for example as a purpose column in weigh's output or doc-audit's table, without growing core.md (see TASK-71).
<!-- SECTION:DESCRIPTION:END -->
