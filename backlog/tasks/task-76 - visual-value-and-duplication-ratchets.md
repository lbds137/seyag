---
id: TASK-76
title: 'guards: ratchets for raw visual values outside tokens and for code duplication'
status: To Do
assignee: []
created_date: '2026-11-22T05:50:00Z'
labels:
  - ui
  - guards
dependencies: []
priority: medium
ordinal: 76000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Two count-only-goes-down ratchets, each a component with a committed baseline file:
1. Raw visual values (font sizes, colours) outside the project's token block, counted per file. A new raw value fails; removing one lowers the baseline.
2. Generic code duplication, CPD-style (token-window clones over a configurable minimum). New clones fail; the baseline shrinks as clones are removed.

Both run in CI and as a local gate. The token-block location and the file globs are config, not hard-coded.

Pairs with TASK-75.
<!-- SECTION:DESCRIPTION:END -->
