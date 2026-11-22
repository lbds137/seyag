---
id: TASK-78
title: 'secure knobs: a project .claude/settings.json env block bypasses the seyag.toml project-scope refusal'
status: To Do
assignee: []
created_date: '2026-11-22T07:10:00Z'
labels:
  - config
  - security
dependencies: []
priority: medium
ordinal: 78000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the TASK-59 review (L6). The project-scope refusal for security-material knobs (`_SYG_CFG_PROJECT_SECURE` in `plugins/seyag/hooks/lib/config-env.sh`, mirrored in `plugins/seyag/lib/config_env.py`) applies only to a project `.claude/seyag.toml`. A repo that ships the same knob in its committed `.claude/settings.json` `env` block reaches every tool through the harness environment, so the refusal can be bypassed.

This affects the whole class, not only the new `SYG_WORKTREE_ELIGIBLE_REASONS`: `SYG_WORKTREE_BASE`, `SYG_WORKTREE_REGENERABLE`, the keys-store and credit-route knobs. For `SYG_WORKTREE_ELIGIBLE_REASONS`, the tool's hard universe still caps the damage at four codes.

Fix: decide where the check belongs. Options:
- a SessionStart or config-env check that compares each secure knob's value against the user-scope sources and warns or refuses when only the project settings set it;
- documenting that project `settings.json` is owner-trusted.

Measure first which secure knobs any project settings file sets today.
<!-- SECTION:DESCRIPTION:END -->
