---
id: TASK-114
title: 'pr-monitoring: a pr-state bin, and a CONFLICTING check before diagnosing silent CI'
status: To Do
assignee: []
created_date: '2026-11-23T03:31:00Z'
labels:
  - mining
  - pr
dependencies: []
priority: low
ordinal: 114000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
From session mining: silent CI was diagnosed by hypothesis for hours, twice, while the PR was CONFLICTING; looking up a PR's state (review bot's issue comment, field names) takes several tries; the PR report step is hand-built with many jq shapes across many PRs; fixup commits conflict with a fixup gate at the last round.

Owner ruling: a pr-monitoring skill row plus a small pr-state bin. Shape: one call prints mergeable state, checks for the head SHA, and the review verdict; the skill says to run it first when CI is silent. Check what `pr-ci-wait`'s zero-job handling already covers.
<!-- SECTION:DESCRIPTION:END -->
