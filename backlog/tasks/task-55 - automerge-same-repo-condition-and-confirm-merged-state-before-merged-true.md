---
id: TASK-55
title: 'automerge: same-repo condition, and confirm state MERGED before merged=true'
status: To Do
assignee: []
created_date: '2026-11-21T04:55:00Z'
labels:
  - ci
  - automerge
  - review-follow-up
dependencies: []
priority: low
ordinal: 55000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Older than #362; surfaced by the same outside review (relayed 2026-11-20). In .github/workflows/claude-code-review.yml:
1. The automerge job's `if:` gates on the author login (repository owner, or dependabot) but not on `github.event.pull_request.head.repo.full_name == github.repository`; only the branch-delete step checks that. Add the explicit same-repo condition to the job (the dependabot arm included: dependabot branches are same-repo).
2. merged=true is written as soon as `gh pr merge` exits 0 (~L233). Under a merge queue that exit means "enqueued", so post-merge could start before anything landed. Read `gh pr view --json state` and write merged=true only on state MERGED (else merged=false with a log line). No merge queue runs here today; the workflow is generic, so other adopters may have one.

Checked and ruled out (2026-11-20, code reading of origin/main ff338d6): "post-merge skipped when only the branch delete fails". Every failure path in the delete step warns and exits 0 (the list-PRs failure, a # or % in the name, the DELETE call itself), so the automerge job still succeeds and post-merge, gated on needs.automerge.result == 'success' plus merged == 'true', still runs. Reopen if a delete-step change adds a non-zero exit.
<!-- SECTION:DESCRIPTION:END -->
