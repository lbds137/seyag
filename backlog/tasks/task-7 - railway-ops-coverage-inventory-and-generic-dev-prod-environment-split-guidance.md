---
id: TASK-7
title: >-
  railway-ops: coverage inventory and generic dev/prod environment-split
  guidance
status: Done
assignee:
  - seyag
created_date: '2026-11-19T14:22:00Z'
updated_date: '2026-11-19T21:02:00Z'
labels:
  - skills
  - bin
dependencies: []
ordinal: 7000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Inventory only, not a build. List what a real Railway-hosted deployment has (service layout,
env/secret templates, deploy and PR-environment flow, healthchecks, config conventions,
migrations on deploy, logs/alerting) that the railway-ops skill and CLI do not cover yet,
ranked by how much each gap costs a new project's spin-up. The reference deployment is
private; output is generic (config/env hooks, no project names). Second customer: the
chat-server fork's client+server once public.

Owner addition 2026-11-17: the output includes generic dev/prod environment-split guidance
(env naming, which environment a PR deploys to, promote flow, per-environment secrets) as
skill text plus any CLI gaps.
<!-- SECTION:DESCRIPTION:END -->

## Comments

<!-- COMMENTS:BEGIN -->
created: 2026-11-19T21:02:00Z

---

DONE 2026-11-19 (seyag). Inventory only, nothing built. Full report: .claude/dispatch/railway-inventory-result.md (private names there; tracked text stays generic). Method: skill + CLI read in full; live probes against CLI 4.11.2 and the reference deployment (status --json, volume list, deployment list --json) — all read-only. Headline: railway-ops covers variables/restarts/rotation/capped logs and nothing else; status --json already exposes the full per-service serviceManifest (builder, watchPatterns, healthcheckPath, preDeployCommand, replicas, cron) that the skill never routes to. Ranked gaps: P0 deploy-path skill text (G1) + post-redeploy health verification (G2: 6/7 reference services have no healthcheck; verb candidate wait <env> <svc> deferred, trigger = second customer); P1 dev/prod split guidance (G3, draft skill text in report), vars diff <A> <B> names-only verb (G4, the one CLI gap worth building, deferred same trigger), volumes + managed-DB skill text (G5/G6); P2 alerting/usage = dashboard-side one-liners (G7/G8). All other native verbs ruled out as railway-ops additions with reasons in the report. Staleness verified against 4.11.2: variables --set --skip-deploys exists (trap 2 narrows to delete/shared), deployment list --json replaces the dashboard-ids pointer, down gained -e (new destructive verb, one warning line), redeploy still linked-env-only (trap 1 holds). Residues: reference checkout has no .railway-ops.json (adoption is that repo call); volumes backup story + dashboard promote flow unverified (labelled in report); lockfile/node_modules residue filed as TASK-33.

---
<!-- COMMENTS:END -->
