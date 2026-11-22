---
id: TASK-69
title: 'ask-pretext: #367 PASS-round lows'
status: To Do
assignee: []
created_date: '2026-11-21T17:20:00Z'
labels:
  - guards
  - asks
dependencies: []
priority: medium
ordinal: 69000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Lows from the #367 PASS review (claude-review on 4ba6c8d):

1. **Self-referencing pointers in rule (a).** `see below`, `(shown|listed) below` and `(previous|earlier|prior|last) message` can match a question that refers to the dialog's own options ("Pick one of the approaches listed below"), or one whose topic is a message ("edit its last message?"). Rule (a) has no escape. Narrow these alternatives, for example by skipping `below` in a `question` that has options, and pin a "listed below" case. The replay found 0 hits in 255 asks.
2. **`preview` scanned by rule (a).** Rule (a) scans `preview`, which often holds quoted code or diffs (`# see above`). Exclude `preview` from rule (a) and keep it for rule (b)'s carried check, or record it as a KNOWN BOUND.
3. **Over-approximation in rule (b).** Rule (b) treats all earlier-message turn text as hidden, but text written before an intervening tool call was on screen before the ask. Document this as a deliberate over-approximation in the guard header.
4. **Duplicated hook invocation in replay.** `tests/replay-hook.sh` repeats the long `env -u … bash hook` invocation four times. Fold it into one `run_hook` function.
5. **Replay memory (optional).** The non-Bash replay path holds the whole log in jq memory and runs `head` once per ask. Make it two-pass streaming if logs grow.
6. **Knob category (optional).** Recategorize `SYG_ASK_PRETEXT_MIN_CHARS` if a reminder category fits better than `guards`.
7. **Missing probe cases:**
   - a `!` line inside a fenced block is reported once, not as both `C:` and `F:` (it is currently reported twice);
   - the "listed below" option self-reference from item 1.
<!-- SECTION:DESCRIPTION:END -->
