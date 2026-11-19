---
id: TASK-32
title: 'asks lens follow-up batch: review-r3 lows on #348'
status: To Do
assignee: []
created_date: '2026-11-19T19:33:00Z'
labels:
  - bin
  - mining
dependencies: []
ordinal: 32000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Seven PASS-review lows (claude-review, 2026-11-19, PR #348 merged 396d1fb). One follow-up PR when promoted.
1. A rejected AskUserQuestion counts twice: the rejection tool_result emits deny AND the auq stays pending until the next owner turn. Fix: skip the deny match when the result's tool_use_id is in auq_pending; add fixture.
2. Clockless archive asks (_created_at only) report wait_s=None + expired=1 and add to unanswered/expired in --summary; unknowable, not unanswered. Decide: separate state (empty expired / unmeasured count) or skill-text note.
3. Hook blocks from seyag's own guards match blocked-by-hook and inflate deny with agent-facing corrections. Decide: skill note, or own filterable category.
4. BANG matches shell negation in fenced code (re-raise of round-3 L6, declined: trades rare noise for missed handoffs). Fixture only if bang counts start driving build-the-check decisions.
5. ask_category runs on the full deny body while detection reads body[:600]; classify on body[:600] for consistency.
6. Optional perf: --app could bridge_id(path)-skip non-matching files before scanning (cmd_grep has the same shape).
7. Docs: --no-text parenthetical (it/rows disagreement, nested parens) in SKILL.md + CHANGELOG - rewrite as 'omit the text column; project name and 8-char session id remain'.
<!-- SECTION:DESCRIPTION:END -->
