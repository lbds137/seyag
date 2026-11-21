---
id: TASK-59
title: 'safe-worktree-clean --apply-eligible: remove HOLD trees whose every reason is in a configured eligible set'
status: To Do
assignee: []
created_date: '2026-11-21T06:30:00Z'
labels:
  - worktrees
  - peer-ask
  - owner-friction
dependencies: []
priority: high
ordinal: 59000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Peer ask (machine-management session, 2026-11-21) after an owner ruling that a HOLD tree whose every reason is branch-name, ignored, untracked-new or untracked-differs needs no approval. Measured: 18 removal asks in 48 h, and 0 SAFE of 26+ trees in a fleet dry run. The auto-mode classifier still refused `--apply-hold` on a qualifying tree (it judges from the transcript, not standing instructions), so the fix is a permission allow rule for a dedicated mode. That is only safe if the tool itself enforces eligibility.

Build: a `--apply-eligible` mode that, in one step, dry-runs, then backs up and removes only trees whose every HOLD reason is in the knob-configured set. Any tree with a reason outside the set is refused by the tool's own code, never left to the caller.

- Eligible codes come from a new knob (e.g. `SYG_WT_ELIGIBLE_REASONS`, whitespace-separated reason codes). Default empty means the mode removes nothing, so default behaviour is unchanged.
- The knob is refused from project scope (path/safety knob class, see the cfg2 marking work), so a repo cannot widen it.
- Commit-carrying reasons (unmerged, detached-unreferenced, worktree-refs, bisect-refs, rewritten-refs) and dirty, live-cwd and lock are never eligible, even if listed in the knob.
- Update the delegation and pr-monitoring skill lines that call `--apply-hold` (currently "always the owner's call") to say "unless the owner configured an eligible-reasons knob".

Probes:
- listed-only reasons: removed, with backup;
- one unlisted reason: refused, tree intact;
- empty knob: nothing removed;
- a never-eligible code in the knob: still refused.
<!-- SECTION:DESCRIPTION:END -->
