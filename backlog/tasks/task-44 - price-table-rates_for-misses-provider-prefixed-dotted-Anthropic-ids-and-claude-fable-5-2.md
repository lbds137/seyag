---
id: TASK-44
title: >-
  price-table: rates_for misses provider-prefixed dotted Anthropic ids and
  claude-fable-5-2
status: To Do
assignee: []
created_date: '2026-11-20T17:54:00Z'
labels:
  - bug
dependencies: []
priority: medium
ordinal: 44000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
price-table --audit (run 2026-11-20) reports 2 uncovered ids in the last 30d: anthropic/claude-haiku-5.5 (an OpenRouter session on a ~anthropic/claude-*-latest alias records the resolved concrete id) and claude-fable-5-2. rates_for matches neither, so cost ledgers record cost_usd null for those sessions and the day total undercounts until the provider cost report closes the day. Fix: normalise an anthropic/ prefix plus a dotted version (claude-haiku-5.5) to the dashed key (claude-haiku-5-5) inside rates_for so future versions are covered, and add the missing Fable 5.2 row. Regression test per id form (prefixed dotted, bare dashed, unknown id). Done when price-table --audit reports 0 uncovered for both ids.
<!-- SECTION:DESCRIPTION:END -->
