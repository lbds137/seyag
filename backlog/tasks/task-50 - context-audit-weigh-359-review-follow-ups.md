---
id: TASK-50
title: 'context-audit weigh: #359 review follow-ups'
status: To Do
assignee: []
created_date: '2026-11-21T02:51:00Z'
labels:
  - context-audit
  - review-followup
dependencies: []
priority: low
ordinal: 50000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
claude-review on #359 (merged as 0.3.198) left six low findings: (1) found is set on a hook_success with empty content and 0-byte additionalContext rows are appended, so an all-empty startup batch hides an older transcript with real output; the #359 PR body wrongly said found is set only on a counted record. Set found only on counted bytes and skip 0-byte rows. (2) memory_dir slugs with replace('/', '-') while slug_of replaces every non-alphanumeric; memory_dir should reuse slug_of and honour CLAUDE_PROJECTS_DIR like session_start_rows. (3) session_start_rows stats the projects dir without the under_mount guard the docstring promises. (4) Claude Code shortens very long project folder names (hash suffix); slug_of will miss them (fails safe with the not-counted note): add a comment or match. (5) newest-by-mtime can pick a long-running session whose startup batch predates the current hooks: doc-audit Trigger should say to start a fresh session first. (6) probe cases missing: repo-root fallback, fall-through past a newer transcript with no SessionStart records, 20-file cap.
<!-- SECTION:DESCRIPTION:END -->
