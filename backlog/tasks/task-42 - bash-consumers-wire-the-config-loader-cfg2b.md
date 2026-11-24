---
id: TASK-42
title: 'bash consumers: wire the config loader (cfg2b)'
status: To Do
assignee: []
created_date: '2026-11-20T03:08:00Z'
labels:
  - bin
dependencies: []
priority: medium
ordinal: 42000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Bash bins that read user-scope knobs but never load the config files, so scope=user config.toml values are ignored by them (the python bins are covered by the shared python loader, TASK-4). Biggest gap: the statusline (reads ~20 registry knobs including SYG_STATUSLINE_ZAI_USAGE, and carries its own mini TOML parser for the extra-usage file at statusline:631-676). Then: gate-sandbox, worker-sandbox, safe-worktree-clean, plugin-release-check, pr-open, shellcheck-gate, mem-gate, mem-pressure-log, mem-watch, week-burn-window, gate-lock, seyag-git-hooks (note: the git pre-push chain reads SYG_PRIVATE_TERMS_FILE outside the hook runner, which IS config-wired - a config-set private-terms file is silently ignored there today), removed-identifier-sweep. Pattern to copy: the guarded loader block in the usage bin (source the shell lib, call syg_config_env with the plugin root). Old cfg2 plan parked this as cfg2b. NOTE: renumbered twice - first filed as TASK-38, then TASK-39; both IDs were taken by parallel merged tasks before this branch landed.
<!-- SECTION:DESCRIPTION:END -->
