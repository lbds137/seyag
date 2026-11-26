---
id: TASK-190
title: 'long-job-chain-check: inherited parser gaps now visible through the hook'
status: To Do
assignee: []
created_date: '2026-11-26T01:23:00Z'
labels:
  - hooks
  - false-negative
dependencies: []
priority: low
ordinal: 189000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
From the TASK-142 review (2026-11-25); same verdicts on the pre-142 checker, but the hook makes them live. Each returns clean while bash runs the chain: `long-job run x -- a &>/dev/null && b` (&> lexed as & then >); a comment holding an apostrophe before the chain (shlex fails on the unbalanced quote); ANSI-C quoting `echo $'it\'s' && long-job run y -- c && d`. Fix each with a probe fixture first.
<!-- SECTION:DESCRIPTION:END -->
