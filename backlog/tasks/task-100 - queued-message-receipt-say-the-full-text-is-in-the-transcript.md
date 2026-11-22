---
id: TASK-100
title: 'queued-message-receipt: say the full text is in the transcript, or print short messages whole'
status: To Do
assignee: []
created_date: '2026-11-22T20:30:00Z'
labels:
  - peer-ask
  - owner-friction
priority: low
dependencies: []
ordinal: 100000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Peer ask (the machine-management session). The MID-TURN MESSAGES block from `plugins/seyag/hooks/queued-message-receipt.sh` previews each queued message cut off at about 80 characters.

One session saw only that preview and told its owner it "never got the full text". The message was in its transcript and arrived as the next turn.

Fix:
- After the previews, add one line saying that the full text is in the session transcript, or arrives as the next turn, and must be read before calling it missing.
- Better: print a message whole when it is short. Make the length threshold a knob.

Pin both in `queued-message-receipt.probe.sh`: the pointer line, a short message printed whole, and a long one still truncated.
<!-- SECTION:DESCRIPTION:END -->
