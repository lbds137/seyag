---
id: TASK-130
title: >-
  Docs-only and bookkeeping change lanes: skill, change-class classifier,
  pre-push lane guard
status: In Progress
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

Decided before the spec (2026-11-23, driver):
- Plugin boundary. This applies the owner's 2026-11-16 ruling that repo-standards tooling (rulesets, workflow rollout, baseline audit) goes to a sibling plugin; it is not a new boundary call. The lane guard must live here, because the pre-push dispatcher is here. The classifier and the policy format are what that guard consumes, so they live here too. The CI workflow rollout and the ruleset bypass-readback fix belong to the sibling plugin's family; the ruleset tool is not in this repo. Nothing in this task starts the sibling plugin.
- CI distribution. Unit A settles the artifact either way: one stdlib-only Python file, with no plugin-lib imports and no project config loader, because the local guard runs the same file. Whether CI fetches it as a composite action at a pinned sha or as a raw file at a pinned sha is DEFERRED to the CI-wiring unit. The trigger is a replay result that clears the decision rule below. Probe the action-path mechanics at that point instead of deciding them from memory.
- Validator scope. Unit B v1 checks path and mode confinement only. Validator-by-ID is DEFERRED; the trigger is a lane-2 adopter whose repo rules require a store lint. Path confinement does NOT meet this repo's CLAUDE.md "store lint passes" precondition, or the council's "schema-validated" condition. So lane 2 stays closed in any repo whose rules require a lint until a validator ships.
- Toggles. Unit A's classifier is inert until invoked, and the per-repo policy file carries `mode = "report"` (the default) or `"enforce"`. Unit B's guard is off unless `git config --type=bool seyag.laneGuard` is true, following the seyag.publicRepo pattern. Guard policy is read with git show at the remote's old sha, never through the project config loader (which can set guard bypasses). A repo's own existing direct-push hook stays until that repo migrates.
- Split. Unit A = classifier + policy format + report-only replay + probe + skill. Its replay numbers decide unit B and the CI wiring.
- Replay unit: all five surveyed repos are rebase-merge only, so git log has no PR boundaries. A PR is replayed as the diff between its base and head SHAs as GitHub reports them; a repo with no PRs is replayed per commit, which overstates exemptions because a mixed push runs full CI. Raw replay output names private repos, so it stays in gitignored dispatch, and tracked text carries only anonymised aggregates.
- Decision rule, fixed before any numbers exist. CI wiring is worth it for a repo when the replay over its last 60 days of merged PRs shows exempt PRs times that repo's measured heavy-job minutes at 60 or more billed minutes a month, AND there are zero false exempts. A false exempt is an exempt PR whose historical heavy jobs failed; this is checked mechanically from the run conclusions, and every hit is hand-read. Unit B is worth it for a repo when the repo opts in AND the replay shows 10 or more standalone ledger-only PRs a month.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Skill documents the three lanes, the decision table and the per-repo config
- [x] #2 change-class bin classifies a diff with the fail-to-full rules above, pinned by a probe including rename, symlink, mode-change, gitlink and control-file cases
- [ ] #3 pre-push lane guard is opt-in (toggle), chains the repo hook, and its probe covers create/delete/non-FF/merge/revert-hiding/config-widening cases
- [ ] #4 Report-only replay against each adopting repo's history recorded before skips are enabled
- [ ] #5 Replacement line for the global push rule's interim clause (a pointer to the skill) handed to the platform session, which owns that file
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Unit A (0.3.217): `change-class` bin, probe and `change-lanes` skill. Fresh-context review (Anthropic family; the author was Gemini) found and the fix round closed: gitlink bumps hidden by `ignore = all` / `diff.ignoreSubmodules` (now `--ignore-submodules=none`), crashes instead of full (deep TOML, huge timeout, non-UTF-8 replay stdin), `$` matching before a trailing newline, no raw/numstat cross-check, no `.`/`..`/empty segment check, unescaped TAB in replay rows, `--help` taken as an option value, and `git show` replaced by `git cat-file blob`. Ruled out: bounding regex and parse time with `--timeout` (polynomial work over a trusted base-ref policy; the git calls are where unbounded time lives). Next: the report-only replay (AC #4) against the five surveyed repos' last 60 days, then the decision on unit B and the CI wiring under the rule above.
<!-- SECTION:NOTES:END -->
