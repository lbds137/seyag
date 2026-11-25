---
id: TASK-152
title: >-
  shell_quotes: a data-heredoc apostrophe swallows a merge in a stdin-shell
  context (precise scan miss)
status: To Do
assignee: []
created_date: '2026-11-25T02:25:00Z'
labels:
  - hooks
dependencies: []
priority: medium
ordinal: 149000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the TASK-146 review (driver-measured 11-24 on scan_invocations): R1a `bash <<'EOF'\ncat <<'DOC' >/dev/null\nit's data\nDOC\ngh pr merge 2002 -t 'title'\nEOF` and R1b (a data heredoc holding an apostrophe, then `bash <<'EOF'` with a merge and a later quoted word) return no merges; without the apostrophe both return 2002. The cited reading: `_command_pipelines_context` tokenizes the raw text (no heredoc stripping) when `_reads_script_from_stdin` holds, so the apostrophe pairs with a later quote. pr-merge-review-check masks it with a base-identical legacy fallback (TASK-146); fix in lib/shell_quotes.py with probe rows, and check the other guards that use the same path.
<!-- SECTION:DESCRIPTION:END -->
