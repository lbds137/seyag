---
id: TASK-187
title: >-
  backlog-priority-guard: #437 review lows (pinned package spec, workspace
  selectors, empty --priority, promote-only fix line)
status: To Do
assignee: []
created_date: '2026-11-25T23:35:00Z'
labels:
  - hooks
dependencies: []
priority: low
ordinal: 186000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Claude review of PR #437 (VERDICT PASS) left four lows in plugins/seyag/hooks/backlog-priority-guard.sh. (1) npx/pnpm dlx backlog.md@<version> is not judged: strip a trailing @version before the PROGRAMS compare (keep a leading @ for scoped names). (2) pnpm --filter X / -F X and yarn workspace X before backlog are not judged (fail open): consume the selector value, or list under ACCEPTED GAPS. (3) --priority with an empty value counts as set: require a non-empty value. (4) A promote-only block still prints the 'add --priority' line, which draft promote does not take: print it only when a create/edit violation is present. Each fix gets a probe case. Bypass-substring finding (=10 also bypasses) needs no change: it matches the sibling guards.
<!-- SECTION:DESCRIPTION:END -->
