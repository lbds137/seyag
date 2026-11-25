---
id: TASK-85
title: 'fixup-push: handle amend!, reword and cross-commit fixup shapes or print the manual sequence'
status: To Do
assignee: []
created_date: '2026-11-22T16:45:00Z'
updated_date: '2026-11-25T14:58:12Z'
labels:
  - pr
dependencies: []
priority: medium
ordinal: 85000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Mining row w1122-07 (counts 13/4: items/sessions). fixup-push refuses these commit shapes: amend!, reword and cross-commit fixups. Support them, or have the refusal print the exact manual sequence that is safe to run.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-25, a further case reported by a peer project session (not reproduced here). The session re-derived a pushed commit's message after a squash, leaving the base point unmoved. Both `fixup-push` and `fixup-push --onto-base` refused with "remote branch has commits not in local (same base point: not a rebase)", so a message-only rewrite (same parent, byte-identical tree) needed an owner-approved raw `git push --force-with-lease`. Proposed shape: when local and remote HEAD share a parent and a tree and differ only in message, prove both and push with the lease. Probe case: amend only the message of a pushed single-commit branch, then run fixup-push; it must push, and must still refuse when the tree or the parent differs.
<!-- SECTION:NOTES:END -->
