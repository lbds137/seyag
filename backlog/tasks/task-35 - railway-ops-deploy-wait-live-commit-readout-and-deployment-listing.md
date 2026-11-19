---
id: TASK-35
title: 'railway-ops: wait for a redeploy to go healthy, and show the live commit'
status: Deferred
assignee: []
created_date: '2026-11-19T21:08:00Z'
updated_date: '2026-11-19T21:09:00Z'
labels:
  - bin
  - skills
dependencies: []
ordinal: 35000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
railway-ops fires redeploys and returns: nothing confirms the new deployment reached SUCCESS, and nothing says which commit is live. Add (1) a wait (poll serviceInstance.latestDeployment until the new id reaches SUCCESS; fail fast on FAILED/CRASHED/REMOVED/SKIPPED/NEEDS_APPROVAL; a superseding id ends the wait), usable by redeploy and rotate-secret, and (2) a live deployment id/status/commit readout per service. Deployment LISTING is NOT a gap: railway CLI 4.11.2 has deployment list --json -e/-s (probed 2026-11-19); the skill's dashboard-ids pointer is a skill-text fix. Depends on TASK-34 (which mutation the wait follows). DEFERRED, trigger: the second customer lands on Railway, or a deploy incident (same trigger as the TASK-7 report's G2 wait-verb deferral). A reference deployment has both over the public GraphQL API.
<!-- SECTION:DESCRIPTION:END -->
