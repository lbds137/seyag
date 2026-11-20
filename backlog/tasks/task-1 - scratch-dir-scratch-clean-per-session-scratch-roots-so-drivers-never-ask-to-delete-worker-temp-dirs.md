---
id: TASK-1
title: >-
  scratch-dir/scratch-clean: per-session scratch roots so drivers never ask to
  delete worker temp dirs
status: Done
assignee: []
created_date: '2026-11-19T14:22:00Z'
updated_date: '2026-11-20T00:16:00Z'
labels:
  - bin
  - hooks
  - owner-decision
dependencies: []
ordinal: 1000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Workers of interactive drivers fall back to `mktemp -d` in shared /tmp because no session
scratch root exists outside background jobs; the driver then cannot prove the files are its
unit's own and must ask the owner before every delete (measured: ~10 approval rounds in 14
days, all from one session shape; job-scoped sessions with an existing root had zero owner
asks).

Fix shape (measured + agreed with owner 2026-11-17):
- `scratch-dir [NAME]` prints/creates `$CLAUDE_JOB_DIR/tmp/NAME` in a background job, else
  `${SYG_SCRATCH_ROOT:-/tmp/seyag-scratch-$UID}/<session id>/NAME` (root 0700, owner-checked,
  no symlinks). `$XDG_RUNTIME_DIR` is excluded as a default root (session-critical tmpfs, too
  small).
- `scratch-clean [<unit>]` deletes only ledger-recorded dirs under the root that this session
  created; refuses symlinks, anything outside the root, any path not in the ledger.
- recursive-rm-guard generalizes its job-tmp exemption to a roots list, exempting strictly
  below the session dir keyed on the payload session id.
- implementer agent + delegation skill: the driver mints the dir, the spec carries the
  absolute path.

Owner decisions still needed: the exemption widening in the rm guard, and an exception line in
the owner's file-deletion protocol ("scratch dirs made by scratch-dir and removed with
scratch-clean need no approval").

Related: same-command variable indirection (`T=$(mktemp -d); rm -rf "$T"`) is a separate
deferred task; 23 such blocks in 14 days.

**Disposition:** Shipped as PR #335: the scratch-dir bin (per-session scratch root inside job tmp), recursive-rm-guard exempting deletes strictly inside it keyed on the hook payload's session id, SYG_SCRATCH_ROOT / SYG_SCRATCH_RM_EXEMPT knobs, and the implementer + delegation contracts pointing workers at it. Status moved to Done by the store-reconciliation sweep (2026-11-19, changelog evidence; the flip rides the TASK-4 PR).
<!-- SECTION:DESCRIPTION:END -->
