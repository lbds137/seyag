---
id: TASK-273
title: 'keys: classify a fast TPM device timeout as TPM busy and retry once'
status: To Do
assignee: []
created_date: '2026-11-28T15:00:00Z'
labels:
  - bin
  - keys
dependencies: []
priority: medium
ordinal: 273000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported 2026-11-28 by the machine's ops session (4 occurrences in 11 h; one killed a headless worker's key read at startup). `systemd-creds decrypt` exits 1 within ~2 s with "Failed to decrypt: io.systemd.System" while the kernel logs "tpm tpm0: Operation Timed out" and systemd-creds logs "Tss2_Tcti_Device_Init() … errno 62: Timer expired". `keys get` treats it as a hard decrypt failure: its hint (plugins/seyag/bin/keys:336-337, read on befdbe1) names a SYG_KEYS_NAME mismatch, a TPM reset or another user, which points the reader the wrong way. Only a slow call reaches the wall-clock timeout path (:301-325).

Fix shape: when the systemd-creds stderr carries the TPM-timeout signature (errno 62 / "Timer expired" from the TCTI init, "Operation Timed out"), classify it as "TPM busy/timed out", retry once after a short backoff, and on a second failure say that in the message instead of the name/reset/user hint. Decide whether it should also set the stall marker the slow-timeout path sets.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A stubbed SYG_KEYS_CREDS_CMD that exits 1 with the TPM-timeout stderr once, then succeeds, makes `keys get` succeed after one retry
- [ ] #2 A stub failing that way twice yields a "TPM busy/timed out" message, not the SYG_KEYS_NAME/reset/user hint
- [ ] #3 A plain decrypt failure (other stderr) keeps today's hint and is not retried
<!-- AC:END -->
