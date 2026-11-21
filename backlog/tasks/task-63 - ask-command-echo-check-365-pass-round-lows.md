---
id: TASK-63
title: 'ask-command-echo-check: #365 PASS-round lows'
status: To Do
assignee: []
created_date: '2026-11-21T13:00:00Z'
labels:
  - ask-command-echo
  - review-lows
dependencies: []
priority: medium
ordinal: 63000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Six lows from the #365 PASS review (claude-review on ecddab1): (1) url_re keeps a trailing `**`/`__`: add `*_` to the rstrip set, and let bare_url_line accept leading `<` and `*`; (2) a bang followed by a backtick (`` ! `cmd` ``) is undetected: pin it as fire or silent; (3) last_assistant_message may carry PRE-ask text when no text follows the last ask: use it only when the transcript has no text after the last ask yet, plus a probe case; (4) URL substring containment is undocumented in the hook header; (5) the closing message is the last text block only: document it; (6) add the probe to tests/probe-durations.tsv.
<!-- SECTION:DESCRIPTION:END -->
