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

2026-11-27, gap report from a peer session (quotes verified against `bin/fixup-push`: the help note at :33, the refusal at :282). Two more shapes the SHA-ancestry check refuses even when every diff is patch-identical: (a) rewording an already-pushed folded tip; (b) a branch folded locally (`git rebase --autosquash <fork-point>`) before fixup-push runs. All three proof shapes (squash, rebased, resolved) refuse with "remote branch has commits not in local (same base point: not a rebase)" — any local fold or amend drops the remote tip from local ancestry, so the help's "a reworded or re-authored commit passes" note describes a shape unreachable without a later base point. Repro: base commit + two pushed `fixup!` commits; autosquash locally; reword the folded tip → refused. The workaround (reset to the remote tip, then plain fixup-push) folds the branch itself but keeps the base commit's original message, so a message made stale by the fixups cannot be fixed before merge; a hand force-push is classifier-denied in agent sessions. Suggested shape: `--reword-file F` (or `--reword MSG`) composing with squash — when the local tip tree is byte-identical to the remote tip tree (or the fold is tree-identical), replace the message and push under the same pinned lease; the proof is tree identity plus "no fixup! remains", which squash already computes.
<!-- SECTION:NOTES:END -->
