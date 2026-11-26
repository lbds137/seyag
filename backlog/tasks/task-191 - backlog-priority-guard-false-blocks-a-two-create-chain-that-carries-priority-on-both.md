---
id: TASK-191
title: >-
  backlog-priority-guard false-blocks a two-create chain that carries --priority
  on both
status: To Do
assignee: []
created_date: '2026-11-26T01:24:00Z'
labels:
  - hooks
  - false-positive
dependencies: []
priority: high
ordinal: 190000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Seen 2026-11-25 (TASK-142 driver). A Bash command that ran two 'backlog task create ... --priority low -d <long single-quoted text>' calls (with ';' between them, the runner bin held in a shell variable, descriptions holding backticks, $( ), '"'"' quote splices and a heredoc marker) followed by a 'task edit 188 --append-notes' was refused with 'create: resulting status To Do' through run.sh. Each create run alone passes. Not reproduced with simplified shapes: a quoted <<EOF alone, a variable-held bin, and a create;edit chain all pass. The exact command is kept outside the repo in the main checkout's gitignored .claude/dispatch/task-191-repro.sh. Feed it as {tool_name:Bash,tool_input:{command}} to hooks/run.sh backlog-priority-guard (rc 2), then bisect it. Fix with a probe fixture first.
<!-- SECTION:DESCRIPTION:END -->
