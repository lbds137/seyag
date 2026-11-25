---
id: TASK-153
title: >-
  shell_quotes: bash --rcfile/--init-file value read as the script operand, so a
  stdin heredoc script is treated as data
status: To Do
assignee: []
created_date: '2026-11-25T02:25:00Z'
labels:
  - hooks
dependencies: []
priority: medium
ordinal: 150000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the TASK-146 review (driver-measured 11-24): `bash --rcfile /dev/null <<'EOF'\n# fine\ngh pr merge 2002\nEOF` returns no merges from scan_invocations, with or without an apostrophe. `_reads_script_from_stdin` skips option values only for -o/+o/-O/+O, so /dev/null becomes operands[0]. Fix: also skip the values of --rcfile and --init-file (check bash --help for any other value-taking long options); add probe rows.
<!-- SECTION:DESCRIPTION:END -->
