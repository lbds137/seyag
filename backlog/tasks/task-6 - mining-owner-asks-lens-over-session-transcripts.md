---
id: TASK-6
title: 'mining: owner-asks lens over session transcripts'
status: Done
assignee:
  - seyag
created_date: '2026-11-19T14:22:00Z'
updated_date: '2026-11-19T21:19:00Z'
labels:
  - mining
  - skills
dependencies: []
ordinal: 6000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Five items, owner-directed 2026-11-17. Aim: fewer owner interventions, more work per token, complexity pushed into checks.
1. An asks extractor + owner-lens category for repeated mechanical asks (ask-the-owner tool calls, hand-the-owner-a-command lines, permission/classifier denials; mechanical vs genuine; each mechanical category gets a build-the-check or stays-human disposition). A private prototype exists; dedupe by message uuid (98/636 dupes, 79 without timestamps); top buckets: prod deploy 35, worktree removal 31, scratch deletes 25, force-push 17.
2. Did-the-fix-work recount of already-shipped findings.
3. Waiting-cost columns (latency, unanswered/expired, blocked time).
4. Privacy classification for miner agents and generic read-lane routing.
5. Weekly delta runs plus periodic full synthesis.
Headline metric RULED 2026-11-19 (owner AUQ): owner asks per merged PR, corrections/reverts paired; weekly per-category counts printed as context.
<!-- SECTION:DESCRIPTION:END -->
