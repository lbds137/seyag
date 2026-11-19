---
id: TASK-3
title: 'rm-guard: reduce plain-word false positives and document known parser limits'
status: Deferred
assignee: []
created_date: '2026-11-19T14:22:00Z'
labels:
  - hooks
  - deferred
dependencies: []
ordinal: 3000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Deferred; trigger: next recursive-rm-guard or delete_commands touch. Owner ruling: the
exemption bar is guardrail against careless deletes, not hostile agents.

- Allow `2>/dev/null`, `>/dev/null`, `2>&1` as plain words, and split `;`/`&&`/`||`/`|`
  without surrounding spaces (16/1154 historical job-tmp cleanups block under the current
  plain-word gate). The block message should name the plain-word rule.
- Document the known parser limits in the guard's own comments or docs: `IFS=` prefix,
  `VAR+=`/`VAR[0]=` prefix assignments hiding cd/rm from analysis, abbreviated runner flags
  (`sudo --chd=`/`-nD`, `parallel ::::+`/`--workd`/`--arg-f`, `env -iu`/`--un`, `xargs -0a`,
  `cp --sym`), `parallel rm` plus the cache-dir heuristic.
<!-- SECTION:DESCRIPTION:END -->
