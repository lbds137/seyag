---
id: TASK-151
title: >-
  handoff-pick-check: default section regex counts a ## Next-only edit as a
  handoff write
status: To Do
assignee: []
created_date: '2026-11-25T02:10:00Z'
labels:
  - hooks
dependencies: []
priority: low
ordinal: 148000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported by lane B 11-24: the HANDOFF PICK Stop gate fired three times in one session on role-file edits that changed only ## Next (queueing incoming asks) and never touched ## Handoff; each was dismissed with a one-line "not a unit-closing handoff". Cause (checked 11-24): SYG_HANDOFF_SECTIONS is unset on the reporting machine, so the default `^##[ \t]*(?:Handoff|Next)\b` (hooks/handoff-pick-check.sh:172) applies, and it includes Next by design; 6f1aa76, which added the narrowing, records no reason for including Next. Proposed: default to `^##[ \t]*Handoff\b` (a unit-closing handoff rewrites Handoff; a Next-only edit queues work), update the header doc, and add a probe row (Next-only Edit on a wired path passes; Handoff Edit still blocks). Config-only alternative for one machine: set SYG_HANDOFF_SECTIONS to the Handoff-only regex. The SYG_HANDOFF_CMDS branch (`claude-role --set ... --handoff`) is already Handoff-specific and unchanged.
<!-- SECTION:DESCRIPTION:END -->
