---
id: TASK-36
title: 'railway-ops skill refresh: inventory skill text, staleness fixes, IaC line'
status: To Do
assignee: []
created_date: '2026-11-19T21:19:00Z'
labels:
  - skills
  - bin
dependencies: []
ordinal: 36000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Operationalize the TASK-7 railway-ops inventory (report: .claude/dispatch/railway-inventory-result.md — local-only; this description is self-sufficient) as skill text in plugins/seyag/skills/railway-ops/SKILL.md. Items: (1) NEW section, deploy path + service layout: railway up -e/-s, GitHub-integration branch-to-environment mapping, per-service watchPatterns (monorepo path filters; no watch change = deployment SKIPPED), deployment list --json for ids/statuses, status --json serviceManifest as the layout readout. (2) Dev/prod environment-split section (draft text in the report): two environments default, prod protected, per-env tokens, shared tier vs overrides, branch-to-env deploy mapping, PRs deploy nowhere unless PR environments are enabled (project setting), promotion is dashboard-side (no CLI verb in 4.11.2), compare variable NAMES across envs never values. (3) Staleness fixes verified against CLI 4.11.2: trap 2 narrows to delete/shared (railway variables --set --skip-deploys exists); the deployment-ids pointer becomes deployment list --json; one warning line for railway down (destructive, gained -e); the linked-env redeploy trap re-verified current. (4) IaC line: Config as Code (railway.toml/json) deprecated, hard cutoff 2026-12-01 (existing services only, new services cannot opt in; deleting the file before migrating drops its settings); replacement .railway/railway.ts via railway config init|pull|plan|apply|migrate; installed CLI 4.11.2 has no config subcommand (probed), so a CLI upgrade is the precondition. (5) One-liners: healthchecks run at deploy time only (default 300 s window); pre-deploy command has no default timeout, separate container, no volume; volume-backed services get brief redeploy downtime (migrate-before-traffic, not boot-path); alerting/webhooks and usage are dashboard-side. Deferred bullets carried by siblings: wait + live-commit verb = TASK-35; redeploy image-reuse vs HEAD-rebuild = TASK-34; names-only vars diff = bullet here, its own task if promoted. FIRST STEP: grep tests for SKILL.md text pins (skill-name-lint, any railway-ops probe) and carry needed probe changes in the same diff.
<!-- SECTION:DESCRIPTION:END -->
