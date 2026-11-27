---
id: TASK-40
title: 'probes: changelog-version pin check (promoted from TASK-26)'
status: To Do
assignee: []
created_date: '2026-11-20T02:59:00Z'
updated_date: '2026-11-27T15:44:00Z'
labels:
  - probes
dependencies: []
priority: medium
ordinal: 40000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Owner promoted 2026-11-19 (AUQ, the seyag session, from the TASK-26 candidate list): a probe pinning that plugins/seyag/.claude-plugin/plugin.json's version equals the newest CHANGELOG section heading, so a version bump can never land without its release notes (or vice versa).

Update 2026-11-27 (from the #457 review): the newest-section equality pin alone would NOT have caught #457's collision — that PR bumped plugin.json to 0.3.235, which equaled the newest CHANGELOG section (released hours earlier by #456), so equality held and the duplicate would have shipped; it was caught only by session review. Add a second assertion to this probe: the new version must be unique across released history — it must not match any OLDER CHANGELOG section heading (and no existing release tag, where tags exist). Failure message should name the earlier release that took the version.
<!-- SECTION:DESCRIPTION:END -->
