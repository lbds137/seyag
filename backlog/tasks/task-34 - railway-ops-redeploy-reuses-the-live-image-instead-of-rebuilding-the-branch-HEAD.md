---
id: TASK-34
title: >-
  railway-ops: redeploy reuses the live image instead of rebuilding the branch
  HEAD
status: To Do
assignee: []
created_date: '2026-11-19T21:08:00Z'
labels:
  - bin
  - skills
dependencies: []
ordinal: 34000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
railway-ops redeploy, rotate-secret and the vars-set follow-up call serviceInstanceRedeploy (bin/railway-ops SERVICE_INSTANCE_REDEPLOY_MUTATION, redeploy_service), which rebuilds the branch HEAD. A reference deployment measured that at 1-28 min per service and switched variable-only restarts to deploymentRedeploy(id: <latestDeployment id, status SUCCESS>, usePreviousImageTag: true): 19 s, and the new deployment snapshotted the current variables (measured there 2026-10-22; its code comment says not pinned by a unit test). A rebuild can also ship commits not yet live for a service whose watch paths skipped them. UNVERIFIED from here. Settle first: a live probe on a dev env (latestDeployment status + id, deploymentRedeploy with usePreviousImageTag, confirm the build is skipped and the new variable value is live), then: rotate-secret and the vars-set hint use the image-reusing path; redeploy gains an explicit --rebuild choice; refuse when latestDeployment is not SUCCESS. Found by the TASK-7 inventory.
<!-- SECTION:DESCRIPTION:END -->
