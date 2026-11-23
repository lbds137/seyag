---
id: TASK-130
title: >-
  Docs-only and bookkeeping change lanes: skill, change-class classifier,
  pre-push lane guard
status: To Do
assignee: []
created_date: '2026-11-23T21:35:00Z'
labels:
  - policy
  - ci
  - git-hooks
dependencies: []
priority: high
ordinal: 130000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Owner ask (2026-11-23): one generic policy for where docs-only and bookkeeping changes land, which CI they skip, and how review still happens. Today each repo improvises. Measured (that repo's own CI-minutes task, 2026-11-23 jobs API): one private repo merged 170 PRs in a month, 25 of them .md-only. A CODE PR bills about 20 minutes. An .md-only PR there already skips its heavy jobs via paths-ignore and bills about 6 (review, automerge poller, small jobs). So lane 1 saves about 150 min/month in that repo, and the classifier's CI savings land mainly in repos whose CI has no path filter. Cost figure corrected from the first filing, which misapplied the 20-minute code-PR figure to .md PRs. This retires the global push rule's 'interim until the generic docs-only rule lands' clause.

Design (survey of five repos, council review by openai/gpt-6.2-astra):
- Lane 1: closeout bookkeeping rides on the unit's own PR. No extra CI.
- Lane 2 (off by default, per-repo opt-in): standalone ledger data (backlog/tracker/status) goes direct to the integration branch. A pre-push guard in the plugin's git-hooks dispatcher enforces it: policy read from the trusted pre-update tip; refuse create, delete, non-fast-forward and merges; every outgoing commit checked against its parent for in-class paths; a validator picked by ID (no repo shell command) run on the proposed tip; control files hard-denied. It is an accident guard, not protection: an admin ruleset bypass is actor-wide.
- Lane 3: standalone prose docs go by PR. A shipped change-class classifier is used by CI in an in-run classify step: NUL-delimited raw paths and modes, --no-renames, tree diff vs the current base, fails to full CI on anything unknown. Only ordinary files under declared docs roots are exemptable; symlinks, gitlinks, mode changes, .gitattributes, CODEOWNERS, .gitmodules, workflows, hooks and agent-instruction files are always full. Size limits apply. One always-reporting required gate. The AI review always runs. paths-ignore only for wholly optional workflows.
- Repo specifics live in a tracked per-repo config, outside every exempt class.
- Rollout: report-only mode first, replaying each repo's historical diffs before any skip or bypass is enabled. Separately, the ruleset tooling must verify bypass actors and modes on readback.

Owner ruling (2026-11-23 16:37, via the platform session): prose docs go by PR in every repo, including repos that today have a direct-doc exception. No repo puts docs in its direct class; lane 2 is standalone ledger data only. Rollout per repo waits on the report-only replay plus the platform session's go.

Open before the spec (decide and record here):
- Plugin-boundary check (repo CLAUDE.md): per-repo config surfaces are a named split trigger; decide seyag vs a repo-standards sibling plugin.
- How a repo's CI gets the classifier when the runner has no plugin: one stdlib-only file at a pinned sha, or an action in this repo.
- Split: unit A = classifier + policy format + replay/report-only mode + probe + skill. Its replay numbers decide whether unit B (pre-push lane guard, an edit to the fail-closed hook every push runs through) and the CI wiring earn their cost.
- Guard policy is read with git show at the remote's old sha, never through the project config loader (which can set guard bypasses). The toggle follows the seyag.publicRepo git-config pattern, because hooks run outside sessions. A repo's own existing direct-push hook stays until that repo migrates.
- Validator-by-ID runs repo-pinned code inside a hook. v1 may stay at path and mode confinement only.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Skill documents the three lanes, the decision table and the per-repo config
- [ ] #2 change-class bin classifies a diff with the fail-to-full rules above, pinned by a probe including rename, symlink, mode-change, gitlink and control-file cases
- [ ] #3 pre-push lane guard is opt-in (toggle), chains the repo hook, and its probe covers create/delete/non-FF/merge/revert-hiding/config-widening cases
- [ ] #4 Report-only replay against each adopting repo's history recorded before skips are enabled
- [ ] #5 Replacement line for the global push rule's interim clause (a pointer to the skill) handed to the platform session, which owns that file
<!-- AC:END -->
