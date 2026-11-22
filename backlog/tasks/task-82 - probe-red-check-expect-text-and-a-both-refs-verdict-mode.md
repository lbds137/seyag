---
id: TASK-82
title: 'probe-red-check: --expect TEXT and a both-refs verdict mode'
status: To Do
assignee: []
created_date: '2026-11-22T16:45:00Z'
labels:
  - probes
dependencies: []
priority: high
ordinal: 82000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Mining rows w1122-04 (counts 12/10: items/sessions) and w1115-14 (counts 69/62: items/sessions). Sessions hand-build the check "does this fail at base?" with git archive and a rerun, and check red-for-the-right-reason by eye. probe-red-check <probe> [base] already runs a probe at a base ref; its current options must be verified before this change. Add --expect TEXT: the probe counts as red only when its failing output contains TEXT. Add a mode that runs the named probes at the base and at HEAD, and prints both verdicts.
<!-- SECTION:DESCRIPTION:END -->
