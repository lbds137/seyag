---
id: TASK-47
title: >-
  claude-usage --posture prints 'extra pass on' from CLAUDE_USAGE_EXTRA_OK
  alone, ignoring extra_usage state
status: To Do
assignee: []
created_date: '2026-11-21T01:17:00Z'
labels: []
dependencies: []
priority: medium
ordinal: 47000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported 11-20 by a peer session. bin/claude-usage --posture sets pextra from CLAUDE_USAGE_EXTRA_OK=1 alone and never reads extra_usage, so it disagrees with --ok. Repro on one cache: --json extra_usage = {enabled:false, spend_limit_reached:false, disabled_reason:out_of_credits}; CLAUDE_USAGE_EXTRA_OK=1 --ok FAILs 'extra=off (out_of_credits)' (correct); CLAUDE_USAGE_EXTRA_OK=1 --posture prints 'extra pass on (past the wind-down while extra usage is under its limit)' (wrong). Fix: derive the clause from the same extra_state classifier the --ok week branch uses (ok / off:spend_limit_reached / off:<disabled_reason> / off:stale / off:no budget); print 'extra pass on' only for ok, else 'extra pass off (<reason>)'. Probe case: enabled:false + disabled_reason. Update the --posture header doc line.
<!-- SECTION:DESCRIPTION:END -->
