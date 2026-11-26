---
id: TASK-34
title: >-
  railway-ops: redeploy reuses the live image instead of rebuilding the branch
  HEAD
status: Done
assignee:
  - Seyag B
created_date: '2026-11-19T21:08:00Z'
updated_date: '2026-11-26T12:14:00Z'
labels:
  - bin
  - skills
dependencies: []
priority: high
ordinal: 20
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
railway-ops redeploy, rotate-secret and the vars-set follow-up call serviceInstanceRedeploy (bin/railway-ops SERVICE_INSTANCE_REDEPLOY_MUTATION, redeploy_service), which rebuilds the branch HEAD. A reference deployment measured that at 1-28 min per service and switched variable-only restarts to deploymentRedeploy(id: <latestDeployment id, status SUCCESS>, usePreviousImageTag: true): 19 s, and the new deployment snapshotted the current variables (measured there 2026-10-22; its code comment says not pinned by a unit test). A rebuild can also ship commits not yet live for a service whose watch paths skipped them. UNVERIFIED from here. Settle first: a live probe on a dev env (latestDeployment status + id, deploymentRedeploy with usePreviousImageTag, confirm the build is skipped and the new variable value is live), then: rotate-secret and the vars-set hint use the image-reusing path; redeploy gains an explicit --rebuild choice; refuse when latestDeployment is not SUCCESS. Found by the TASK-7 inventory.

Needs owner: a dev environment on the reference Railway project to probe the image-reusing redeploy path (latestDeployment id/status, build skipped, variables live) - the settle-first step, routed via the machine-management session.

Owner approved the settle-first probe on a dev environment 2026-11-19 (AUQ): one latestDeployment read plus one image-reusing deploymentRedeploy (~19 s), variables snapshot verified. The probe and the follow-up code changes are session work, queued after the python-config PR; nothing waits on the owner here.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Settle-first probe RUN 2026-11-26 ~06:49 EST (Seyag B), reference project development env, service api-gateway, per the 11-19 approval:
- latestDeployment a8c5dd26 SUCCESS, commit b4902c5c, imageDigest sha256:b717af89...; develop HEAD was 358166134 (docs-only, watch paths skipped it), so a rebuild would have moved the commit.
- Marker variable (service scope, skipDeploys) upserted after that build; deploymentRedeploy(id, usePreviousImageTag: true) -> bce4fdf3: INITIALIZING t+1s, DEPLOYING t+7s, SUCCESS t+14s, never BUILDING; same commitHash and same imageDigest; meta.reason=redeploy.
- railway ssh printenv in the new container: marker present, RAILWAY_DEPLOYMENT_ID=bce4fdf3. Variables snapshot fresh: VERIFIED.
- latestDeployment flips to the NEW record at INITIALIZING, so a second caller mid-redeploy reads non-SUCCESS and refuses.
- variableDelete of the service-scoped marker triggered NO deploy within 90 s (one observation, one service).
- A serverless web service's latestDeployment status is SLEEPING (serverless sleep), not SUCCESS: the refusal rule must decide SLEEPING.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Shipped: railway-ops redeploy reuses the live image (deploymentRedeploy usePreviousImageTag), refused unless latestDeployment is SUCCESS (SLEEPING refused with wake guidance); --rebuild keeps serviceInstanceRedeploy; rotate-secret pre-flights carriers before the upsert and redeploys by reuse. Probe cases 6, 6b-6f, 7g; purpose canary reddened 4. Follow-up stays TASK-35 (wait for healthy + live commit).
<!-- SECTION:FINAL_SUMMARY:END -->
