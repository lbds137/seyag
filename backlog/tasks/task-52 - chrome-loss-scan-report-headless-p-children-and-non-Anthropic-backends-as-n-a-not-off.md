---
id: TASK-52
title: >-
  chrome-loss-scan: report headless -p children and non-Anthropic backends as
  n/a, not off
status: To Do
assignee: []
created_date: '2026-11-21T04:12:00Z'
labels:
  - chrome-loss-scan
  - peer-ask
dependencies: []
ordinal: 52000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Peer ask (machine-management session, 2026-11-20). A doctor row 'every live Claude session has Claude in Chrome' goes red whenever a headless worker is alive; those sessions can never carry Chrome. Signals (measured by the requester on live transcripts): a headless -p child's records carry "entrypoint":"sdk-cli" (442/442 on one worker), interactive and --bg sessions carry "cli" (7 transcripts); a non-Anthropic backend shows assistant message.model not matching claude-* (831 x a GLM model on one transcript). Build: a state n/a when either signal holds, n/a rows excluded from exit 1, --json carries a reason ("headless" or "model <name>"). Also fix the stale docstring claiming claude agents --json lists real sessions but not headless -p children: it lists them with kind interactive. Verify both signals on fresh transcripts before building (they are a peer's measurement).
<!-- SECTION:DESCRIPTION:END -->
