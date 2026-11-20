---
id: TASK-11
title: 'versioning/pr-monitoring: close the draft-then-cite race'
status: To Do
assignee: []
created_date: '2026-11-19T14:23:00Z'
updated_date: '2026-11-20T02:21:00Z'
labels:
  - skills
dependencies: []
priority: medium
ordinal: 40
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The draft-then-cite flow (open draft, push the changelog cite, flip ready) raced once: push
and ready within ~1s left the surviving review run on the push's draft payload, so automerge
skipped; close/reopen fixed it. Fix in the versioning or pr-monitoring skill: after the cite
push, flip ready only once that push's review run has started — or open non-draft with the
cite predicted from the newest issue/PR number (the flow that worked since). Also: the
post-merge watcher should report "automerge skipped on a green PR" as its own sentinel rather
than a generic CI-complete state.
<!-- SECTION:DESCRIPTION:END -->
