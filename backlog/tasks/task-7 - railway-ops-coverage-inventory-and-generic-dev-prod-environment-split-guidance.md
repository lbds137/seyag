---
id: TASK-7
title: >-
  railway-ops: coverage inventory and generic dev/prod environment-split
  guidance
status: To Do
assignee: []
created_date: '2026-11-19T14:22:00Z'
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
