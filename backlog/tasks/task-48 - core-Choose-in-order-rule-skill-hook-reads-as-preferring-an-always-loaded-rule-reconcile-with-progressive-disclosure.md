---
id: TASK-48
title: >-
  core: 'Choose in order: rule, skill, hook' reads as preferring an
  always-loaded rule; reconcile with progressive disclosure
status: Done
assignee: []
created_date: '2026-11-21T01:31:00Z'
updated_date: '2026-11-21T03:03:00Z'
labels: []
dependencies: []
priority: medium
ordinal: 48000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the cross-family review (council, OpenAI) of the 0.3.197 core edit. core § Fix recurring failures structurally says 'Choose in order: a rule (always loaded), a skill, or a hook', which read literally prefers adding an always-loaded rule, while the new progressive-disclosure bullet says always-loaded text holds only hard constraints and pointers, and TASK-210(e) chose a hook over a rule line for memory routing. Candidate rewording: choose by fit (a rule for a constraint, a skill for a procedure, a hook for a deterministic check), prefer a hook where the trigger is mechanical. The order dates from before 0.3.21 (git log -S) with no recorded decision found; changing it changes a long-standing rule's meaning, so it is the owner's call. Promote when the owner rules.
<!-- SECTION:DESCRIPTION:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Owner ruling 2026-11-20: 'choose by fit' replaces 'choose in order'; hook when the trigger is mechanical, skill for a procedure, rule only for a hard constraint neither can carry. Shipped in 0.3.199.
<!-- SECTION:FINAL_SUMMARY:END -->
