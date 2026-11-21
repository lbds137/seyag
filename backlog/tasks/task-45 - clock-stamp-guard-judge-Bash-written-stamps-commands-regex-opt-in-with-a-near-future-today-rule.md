---
id: TASK-45
title: >-
  clock-stamp-guard: judge Bash-written stamps (commands-regex opt-in) with a
  near-future-today rule
status: To Do
assignee: []
created_date: '2026-11-20T19:42:00Z'
labels:
  - hooks
dependencies: []
priority: medium
ordinal: 45000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
clock-stamp-guard known gap 1: notes written through Bash (a task-tracker CLI's --append-notes, printf >>, sed -i) never reach the Edit|Write|MultiEdit hook, and its future rule only judges line-leading stamps. Measured on one machine in one day: 4 of 4 unread clock stamps were written through Bash, all dated today and 2-8 min ahead of the real clock; 2 were mid-line (behind a `~` or a few words). The hook saw none.

Mechanism:
1. Bash branch, opt-in by config. New file SYG_CLOCK_STAMP_COMMANDS_FILE (default ${XDG_CONFIG_HOME:-$HOME/.config}/seyag/clock-stamp-commands): one Python regex per line, `#` comments. Missing or empty file = Bash branch off. A Bash call is judged when any simple command in it matches a regex (example line: `^(pnpm -s )?backlog task (edit|create)\b`). Optional: also judge a call whose write redirect, tee or sed -i targets a path in the existing paths file.
2. In a judged Bash call, every stamp in the command text counts, line-leading or mid-line (no old text to subtract; heredoc bodies included). Inline code spans stay exempt.
3. Rule "near-future today": block a stamp dated today (local) whose time is more than 60 s and at most SYG_CLOCK_STAMP_NEAR_SECS (default 10800) ahead of now. Other days and same-day times further ahead pass. A `~` or `ca.` prefix still makes it a stamp. The x-placeholder rule applies unchanged.
4. Optional, same knob: apply near-future-today to mid-line stamps in the Edit|Write branch too.
5. Message as today: each stamp, its rule, current local time, SYG_CLOCK_STAMP_HINT.

Must pass: a stamp at or behind now; `due 11-22 06:30` read on 11-20; `resets Sun 11-22 01:00`; same-day 18:00 read at 14:00; a stamp in an inline code span; a command no regex matches; any call with the commands file missing.
Must block (via SYG_CLOCK_STAMP_NOW): line-leading `11-20 11:13` at 11:10; mid-line `... ~10:40` at 10:35; mid-line `... 14:40` at 14:33; `11-20 14:45` at 14:39; x-placeholder stamps in a matched Bash command.
<!-- SECTION:DESCRIPTION:END -->
