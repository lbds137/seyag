---
id: TASK-250
title: session-mining re-checks a shipped closure before it stays closed
status: To Do
assignee: []
created_date: '2026-11-26T11:20:00Z'
labels:
  - skills
  - session-mining
dependencies: []
priority: medium
ordinal: 250000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A mining finding's closure row marked "shipped" counts as closed when the fix lands, not when the problem stops. A fix that covers only part of the pattern therefore never resurfaces: later mining runs treat the finding as done. Seen on one finding (raw role-file edits causing overflow): the shipped fix covered one write path, the main path (direct edits) kept producing the same overflow for about 18 more days, and no later mining week raised it again.

Mechanism (generic, in the seyag:session-mining skill and any helper it uses): a shipped closure row carries a re-check date (shipped + 7 days) and the finding's original signal (the count or query that raised it). On the first mining run after that date, re-count the signal on transcripts newer than the ship date. If the rate has not dropped materially (threshold stated in the skill), reopen the row as "partial", with both rates, and report it in that run's output. A row stays "shipped" only after a re-check passes.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The closure-row format has a re-check date and the original signal (query or count recipe)
- [ ] #2 The mining procedure re-counts every row past its re-check date before new findings are reported
- [ ] #3 A row whose rate did not drop materially reopens as "partial" with before/after rates in the run report
- [ ] #4 The threshold for "materially" is stated in the skill with its reasoning
<!-- AC:END -->
