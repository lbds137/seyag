---
id: TASK-73
title: 'memory-route-gate: new memory files written through Bash bypass the gate'
status: To Do
assignee: []
created_date: '2026-11-22T05:50:00Z'
labels:
  - guards
  - memory
dependencies: []
priority: low
ordinal: 73000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Write-time memory routing shipped as `memory-route-gate` (b4f8671, component `memory-route`, on in `full`). It refuses a Write that creates a new file in the memory directory until the frontmatter carries a `why-memory:` line of at least three words, and it prints the doc-audit routing table.

Its header lists a known gap: Bash writes (`printf >`, `tee`, `cp`) do not go through Write. The gap had no tracking entry until now.

Fix: add a Bash-side check for redirections, tee and cp whose target is a new `.md` directly under a memory directory. Reuse the gate's directory resolution, and add probe cases.
<!-- SECTION:DESCRIPTION:END -->
