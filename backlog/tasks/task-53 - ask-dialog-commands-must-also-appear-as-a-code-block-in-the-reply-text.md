---
id: TASK-53
title: 'Ask-dialog commands must also appear as a code block in the reply text'
status: To Do
assignee: []
created_date: '2026-11-21T04:45:00Z'
labels:
  - stop-hook
  - owner-friction
  - peer-ask
dependencies: []
priority: high
ordinal: 53000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Owner friction (relayed by the machine-management session, 2026-11-20; the owner reports it "multiple times now (across multiple sessions)"): on a phone client, text inside an AskUserQuestion dialog can't be selected or copied, so a command the owner must run (a `!` line, a URL, a recipe) that appears only in the question is unusable.

Proposed fix, hook by fit:
1. A Stop hook (sibling of, or a mode inside, plugins/seyag/hooks/blocking-question-channel-check.sh, which already reads the turn's AskUserQuestion input): when the turn's AskUserQuestion input carries a runnable line (a `!`-prefixed command, a fenced or backticked command, a URL), block the stop unless the turn's final assistant text also contains that exact line inside a fenced code block. Ships with its own toggle.
2. One sentence in core § "Her decisions go through a formal channel": a command she must run goes in the reply text as its own code block, and the ask names it rather than carrying it. Cut a line elsewhere in core first (byte ceiling).
3. Probe: line only in the ask → block; line in both → pass; ask with no command → pass. Also decide and pin: option labels/descriptions/previews are scanned like the question text; inline prose backticks naming a file (not a command) don't count.
Before building, replay the hook against local logs (tests/replay-stop-hook.sh --since 7) and sample its blocked set.
<!-- SECTION:DESCRIPTION:END -->
