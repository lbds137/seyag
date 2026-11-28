---
id: TASK-270
title: Find what creates the scratch root with mode 755
status: To Do
priority: low
labels: [scratch]
created_date: '2026-11-28'
---

## Description

On 2026-11-28 the default scratch root (`/tmp/seyag-scratch-<uid>`) existed empty with mode 755 at 00:40, creator unknown, so `scratch-dir` refused it ("mode is not 700") until it was chmod'ed by hand. `scratch-dir` itself creates the root 0700 (`ensure_private`, `mkdir -m 700`), so something else made it.

## Next

- Grep the plugin and the machine's own tooling for the root path (`seyag-scratch-`) and any `mkdir -p` on it.
- Decide between finding the creator and having `scratch-dir` repair a root it owns that is empty and group/other-readable. That is a security call: the owner's.
