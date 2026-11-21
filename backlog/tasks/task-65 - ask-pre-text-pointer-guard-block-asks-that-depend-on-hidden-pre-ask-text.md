---
id: TASK-65
title: 'ask-pre-text-pointer guard: block asks that depend on text the ask dialog hides'
status: Done
assignee: []
created_date: '2026-11-21T14:00:00Z'
labels:
  - guards
  - asks
dependencies: []
priority: high
ordinal: 65000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
On some clients (observed on a phone client), assistant text written earlier in a turn that then calls AskUserQuestion is not shown; the ask dialog replaces it. A session wrote a runnable `!` line in prose, then asked with "the `!` line is in my message above", and the owner could not see the line (twice in one day; a memory note failed to prevent it). TASK-53's ask-command-echo-check covers only the reverse case (a line that exists only in the ask is echoed in the closing text).

Shape (to refine at spec time; generic, toggleable like its siblings):
1. PreToolUse hook on AskUserQuestion that blocks when (a) the question, an option label, a description or a preview points outside the ask ("above", "my message", "previous message", "see below", "as I said"), or (b) the turn's assistant text before the ask, since the last genuine user entry, contains a runnable line (a `!` command or a fenced command block, reusing ask-command-echo-check's detector) or a fenced code block. Pre-ask prose without code is common, so (b) stays limited to code and commands.
2. Block message: text written before an ask is hidden on some clients; put what the owner needs inside the question or option text, or end the turn with plain text and no ask (a command for the owner to run: plain-text turn end, no ask).
3. Its own component toggle; fail-open on transcript read failures. Probes: pointer phrase → block; pre-ask `!` line → block; pre-ask prose without code → pass; command in the closing text after the ask → pass; first-person narration in the question without a pointer → pass.
4. Replay against local logs before shipping (a PreToolUse replay over AskUserQuestion payloads; extend tests/replay-hook.sh if it is Bash-only) and sample the blocked set.
<!-- SECTION:DESCRIPTION:END -->
