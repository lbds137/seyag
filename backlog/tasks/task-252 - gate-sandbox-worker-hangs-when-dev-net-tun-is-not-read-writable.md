---
id: TASK-252
title: gate-sandbox worker hangs when /dev/net/tun is not read-writable
status: Done
assignee:
  - Seyag
created_date: '2026-11-26T14:18:00Z'
updated_date: '2026-11-26T21:31:00Z'
labels:
  - gate-sandbox
  - bug
dependencies: []
priority: medium
ordinal: 252000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported by a peer session, 2026-11-26. When `/dev/net/tun` exists but the running user cannot open it read-write, the worker profile's launcher hangs instead of failing. Seen on a cloud CI VM (Ubuntu 24.04, `crw------- root /dev/net/tun`, unprivileged test user). The peer's container repro bind-mounted a regular file over `/dev/net/tun`, owned by container root at 0644. So the user could read it but not write it, and `[ -w ]` was false. That was enough to hang. After 60 s the only process left was `pasta --config-net … -- bash -c '…gate-sandbox-wall…'` with no child, so pasta never started the wall command (`plugins/seyag/bin/gate-sandbox` launcher array at :165). Unverified: that pasta blocks rather than exits on the real char device. The repro proves it only for the file; both fail open() with EACCES.

Fix direction: a sibling of the pasta-presence check (`gate-sandbox:123`) that exits 125 with a message saying pasta cannot build the network namespace when `/dev/net/tun` is missing or not read-writable (a real O_RDWR open probe, `exec 3<>"$tun"`, rather than permission bits, which mislead under ACLs or LSMs; agreed with the reporter). Add a probe case with a stubbed tun path, which may need a test seam such as an env override for the device path.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The worker profile exits 125 with a clear message when /dev/net/tun cannot be opened read-write, before launching pasta
- [x] #2 A probe case covers the unusable-tun path and passes in CI
- [x] #3 A usable tun keeps today's behaviour (existing worker probe cases unchanged)
<!-- AC:END -->
