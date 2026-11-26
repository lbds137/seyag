---
id: TASK-258
title: 'backlog-md skill: a claim counts only once pushed to the default branch'
status: To Do
assignee: []
created_date: '2026-11-26T18:44:00Z'
labels:
  - skills
  - lane-a
dependencies: []
priority: medium
ordinal: 258000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested by a consumer session (2026-11-26). `plugins/seyag/skills/backlog-md/SKILL.md` § "Claiming across sessions" says to claim (assignee + In Progress) in the same CLI pass that starts the work, and its Commit discipline says store changes ride the session's working branch. Together they put a claim on a feature branch, invisible to every session reading the default branch, so two sessions can both win the same task. Nothing says when a claim becomes real.

Proposed text (wording is the implementer's):
1. **An unpushed claim is not a claim.** A claim counts only once its one-file frontmatter change (assignee + status) is pushed to the default branch. Claims never ride a feature branch; this is a named exception to Commit discipline, alongside the backlog-only direct commit.
2. **Claim protocol:** fetch; refuse if the task on `origin/<default>` already has a different In Progress assignee, naming that assignee; commit only that file on top of `origin/<default>` (in a temporary worktree, so the caller's branch is untouched) and push; on a non-fast-forward, re-fetch and re-check from the new tip, never rebase and replay the edit; a fetch or push failure means no claim. A re-claim by the same assignee is a no-op.
3. Optional: where the default branch refuses direct pushes, claims go to a dedicated claims branch that readers overlay. Decide whether to include it.
4. Optional hook: an env var (e.g. `SYG_TASK_CLAIM_CMD`) naming a project's claim command, which the skill tells sessions to run instead of a bare CLI edit when it is set. A new env name needs its `knobs.tsv` row and the regenerated `docs/config.md`.

The requester is building a claim command on its own side. Its probe: two simultaneous claims from one tip → exactly one wins, and the other names the winner. Check the skill's byte budget (`lines-check`) before adding text; cut elsewhere in the skill if needed.
<!-- SECTION:DESCRIPTION:END -->
