---
id: TASK-2
title: 'rm-guard: resolve single-assignment literal vars in same-command deletes'
status: Deferred
assignee: []
created_date: '2026-11-19T14:22:00Z'
labels:
  - hooks
  - deferred
dependencies: []
ordinal: 2000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Deferred; trigger: next recursive-rm-guard or delete_commands touch. 23 blocks in 14 days
where a job-tmp delete goes through a same-command variable (`T=$CLAUDE_JOB_DIR/tmp/x;
rm -rf "$T"`, `T=$(mktemp -d) ... rm -rf "$T"`). Resolve single-assignment literal vars;
keep refusing reassignment and loops.
<!-- SECTION:DESCRIPTION:END -->
