---
id: TASK-51
title: 'run.sh event mode: printf into jq can EPIPE when hooks.json is unparsable'
status: To Do
assignee: []
created_date: '2026-11-21T03:26:00Z'
labels:
  - hooks
  - flake
dependencies: []
priority: low
ordinal: 51000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
CI flake on #361 (probe-shard 1/3, run 44860788711): run.probe.sh case ev-badjson failed on stderr 'hooks/run.sh: line 202: printf: write error: Broken pipe'. Mechanism (code-reading, not runtime-confirmed): in event mode run.sh pipes printf '%s' "$PAYLOAD" into jq --slurpfile hj hooks.json; with an unparsable hooks.json jq exits before reading stdin, and when it wins the race the printf builtin reports EPIPE, so the probe's empty-stderr assertion fails intermittently. Passed locally (112/112) and on #358-#360 CI. Fix: feed jq from a here-string (as memory-route-gate does since #358) or validate hooks.json before the pipe; add a probe case with a large payload against a bad hooks.json so the race is forced.
<!-- SECTION:DESCRIPTION:END -->
