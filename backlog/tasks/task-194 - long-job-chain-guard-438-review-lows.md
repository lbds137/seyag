---
id: TASK-194
title: 'long-job-chain-guard: #438 review lows'
status: To Do
assignee: []
created_date: '2026-11-26T07:58:00Z'
labels:
  - seyag
dependencies: []
priority: low
ordinal: 193000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Four lows from the claude-review of PR #438 (0.3.229, VERDICT PASS):
1. The fast path scans the whole hook JSON payload, not just .tool_input.command: a cwd or transcript_path containing long-job (or the runner basename) starts python on every Bash call. Match from the command field on, or document it in the header.
2. docs/config.md and knobs.tsv dropped the SYG_LONG_JOB_CMD caveat that a generic first word (bash) is matched too; with the hook that now costs a python start on every matching call. Restore the caveat.
3. CHANGELOG 0.3.229 items end (TASK-142)/(TASK-180) without (#438)/(#436); the header asks for (#PR).
4. The install note (drop a settings.json hook that already wires long-job-chain-check, or both fire) lives only in the PR body; add it to the CHANGELOG 0.3.229 section.
<!-- SECTION:DESCRIPTION:END -->
