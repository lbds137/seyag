---
id: TASK-258
title: 'backlog-md skill: a claim counts only once pushed to the default branch'
status: Done
assignee:
  - Seyag
created_date: '2026-11-26T18:44:00Z'
updated_date: '2026-11-26T21:15:00Z'
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

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Shipped in 0.3.232: items 1, 2 and 4. Item 4 is `SYG_TASK_CLAIM_CMD`, advertised at SessionStart before the pick line, with a knobs.tsv row; the config scan skips `*.md`, so a knob read only by the skill would fail the stale check, and the SessionStart reader is what makes it a real, documented knob.

Item 3 (a claims branch that readers overlay): **deferred**. Nobody consumes it yet, and it would need every store reader to apply the overlay. A project whose integration branch refuses direct pushes names its own path through `SYG_TASK_CLAIM_CMD`. Trigger: a consumer project with a push-closed integration branch asks for a shared claims-branch convention, or two projects build one each.

Protocol evidence (scratch bare repo, two clones on one tip, the steps run literally by a script, sed standing in for the CLI edit):
- 8 fresh simultaneous runs: exactly one claim landed each time (origin held 2 commits, init and one claim), and the loser named the winner.
- A truly simultaneous loser saw `cannot lock ref ... incorrect old value`, not a non-fast-forward. That is why step 4 keys on "the tip moved" after a re-fetch, not on the rejection text.
- A same-assignee re-claim was a no-op (no new commit). A fetch failure gave no claim.
- A pre-receive hook refusing the push on an unmoved tip gave no claim, and the task stayed To Do.

Cross-family review (council, openai/gpt-6.2-sol) found a shared-ref race the two-clone test could not reach. Worktrees of one repository share `origin/<integration>`, so a session that reads the task and then cuts its worktree from the ref can build on another session's claim, overwrite its assignee, and still push as a fast-forward. Reproduced in a scratch repo with both claimers in one clone and a 2 s window between the read and the cut:
- Old text, both steps from the ref: 3/3 runs gave a double win (2 claim commits, the second overwrote the first assignee).
- New text, capturing `$base` once and using it for the read and the cut: 3/3 runs gave 1 claim commit, and the loser re-checked and named the winner.

Also taken from the review: only an unassigned To Do task is claimable; three attempts at most; a release only of your own claim; explicit `origin`; a push that landed but lost its reply resolves at step 2.

Not taken (low):
- The hook pastes the configured value into a code span, so a backtick in it would break the span. Same shape as the sibling `_CMD` lines, and the value is user scope.
- The coordination-notes sentence predates this change.
<!-- SECTION:NOTES:END -->
