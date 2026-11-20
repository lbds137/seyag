---
id: TASK-37
title: 'coupling-lint: widen TOKENS toward the CLAUDE.md private-name rule'
status: To Do
assignee: []
created_date: '2026-11-19T21:46:00Z'
updated_date: '2026-11-20T02:21:00Z'
labels:
  - tests
dependencies: []
priority: medium
ordinal: 50
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
tests/coupling-lint.probe.sh pins six tokens (the array lives in that probe), but the repo CLAUDE.md rule is broader: new tracked text never names the owner private sessions, private projects, personal paths or machine-only tools. A review round (PR #349, 2026-11-19) caught personal-docs paths, a machine-job wrapper, the machine-management session name, a model-alias reviewer name and a bare session id passing the lint while violating the rule; all were fixed by hand in text, the lint itself was not widened. WIDEN: add the classes (machine tool names, personal docs paths, cross-session role names beyond the store claim convention, bare session ids) as tokens or as a pattern check, keep the allowlist shrinking not growing, and decide the assignee-claim exemption explicitly (store claim names are role names, currently allowed). Trigger: next coupling-lint touch or next de-naming incident.
<!-- SECTION:DESCRIPTION:END -->
