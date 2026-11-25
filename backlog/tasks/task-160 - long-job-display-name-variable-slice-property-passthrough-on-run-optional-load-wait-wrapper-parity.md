---
id: TASK-160
title: >-
  long-job: display-name variable, slice/property passthrough on run, optional
  load wait (wrapper parity)
status: To Do
assignee: []
created_date: '2026-11-25T04:08:00Z'
labels:
  - long-job
  - feature
dependencies: []
priority: medium
ordinal: 152000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Generic ask from a deployment that wraps long-job: three mechanisms so a local wrapper can become a pure exec wrapper.

1. Display name: long-job hardcodes its own name in messages and hints ("long-job: ended: act on the result above", "run long-job wait NAME --poll", "long-job status"). A wrapper that execs the read verbs therefore changes the "<runner>: ended" sentinel its callers wake on, and the hints name the default state dir. Honour a display-name variable in every message and hint; reuse SYG_LONG_JOB_CMD, which long-job-chain-check already reads.
2. Slice / systemd property passthrough on `run`: `--slice NAME` and a repeatable `-p KEY=VALUE` passed to systemd-run, so a deployment can put plain jobs in a weighted slice with a memory backstop.
3. Load wait: optionally run `load-gate --wait` inside the unit after the memory wait (a flag, or as part of the --heavy port in TASK-145).

Why: without 2 and 3 wrapping regresses every job (slice placement, load wait); without 1, delegating only wait/status breaks the documented "<runner>: ended" wake rule. Until these ship the requester keeps run/wait/status local and uses only long-job-chain-check.

Owner: bin/** lane. Related: TASK-145 (--heavy port).
<!-- SECTION:DESCRIPTION:END -->
