---
id: TASK-62
title: 'chrome-loss-scan #363 review lows'
status: To Do
assignee: []
created_date: '2026-11-21T06:30:00Z'
labels:
  - chrome-loss-scan
  - review-lows
dependencies: []
priority: low
ordinal: 62000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Review lows from #363. Fold at the next chrome-loss-scan touch:
- an `na_reason` substring prefilter;
- reword "non-Claude backend" to "non-first-party model id" (Bedrock, Vertex and OpenRouter Claude ids count as Claude);
- docstring "non-synthetic" wording;
- text-mode hint that `--json` lists the n/a rows;
- drop the "this machine's configured value" aside in TASK-56;
- a probe case pinning last-entrypoint-wins.
<!-- SECTION:DESCRIPTION:END -->
