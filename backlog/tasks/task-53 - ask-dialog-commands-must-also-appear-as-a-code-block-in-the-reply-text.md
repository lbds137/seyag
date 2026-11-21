---
id: TASK-53
title: 'Ask-dialog commands must also appear as a code block in the reply text'
status: Done
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

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Shipped as the Stop hook `ask-command-echo-check` (component `ask-command-echo`, on in `full`, off headless) with the matching rules in its header: a `!` command or URL in an AskUserQuestion's question, option label, description or preview must reappear in the closing message inside a fenced code block (a URL may stand alone on its own line); inline backticks and prose mentions do not count; multi-word backtick spans are not a trigger. Step 2 (the core sentence) deliberately not done: the hook enforces it mechanically, core.md is at its byte ceiling, and core's own "choose by fit" puts mechanical triggers in hooks. A PreToolUse alternative was ruled out because the owner reads the command after answering (deck session evidence: ask carrying a `!` merge line, answer, closing text without the line, then the owner's complaint), not before.
<!-- SECTION:NOTES:END -->
