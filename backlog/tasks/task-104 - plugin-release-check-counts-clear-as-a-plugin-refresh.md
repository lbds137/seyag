---
id: TASK-104
title: 'plugin-release-check: /clear is counted as a plugin refresh, but only /reload-plugins or a new process re-reads hook registration'
status: Done
assignee:
  - seyag
created_date: '2026-11-22T22:40:00Z'
updated_date: '2026-11-23T00:40:00Z'
labels:
  - peer-ask
  - bug
priority: high
dependencies: []
ordinal: 104000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Peer report from the machine-management session, 2026-11-22, proven at runtime on Claude Code 2.1.330 with a `--plugin-dir` test plugin. The plugin's UserPromptSubmit hook appends a tag to a marker file, and before each step one more hook was added to `hooks.json`:

- A plain prompt fired A only.
- `/clear` then a prompt fired A only.
- `/compact` then a prompt fired A only.
- `/reload-plugins` then a prompt fired A, C, B and D.

So `/clear` and `/compact` do not re-read hook registration; only `/reload-plugins` or a process start does.

`plugin-release-check` treats `/clear` as a refresh (`plugins/seyag/bin/plugin-release-check:230`, the `/(reload-plugins|clear)` match, and the header at lines 30-31). A session that `/clear`'d after a release is reported current when it is not.

Nuance: hook scripts run from the plugin's checkout, so their code is current after any merge. What goes stale is the registration: hooks added, removed or re-matched in `hooks.json`. The SessionStart `seyag plugin <version>` line reads `plugin.json` at run time, so it does not prove the loaded registration either.

Fix:
1. Count only `/reload-plugins` and process start (the agents-list `startedAt`) as refreshes. Pin `/clear` and `/compact` as non-refreshes in the probe.
2. Preferred: record what the session actually loaded. One option is a SessionStart hook on the `startup` source, plus whatever fires on reload, if any event does (verify; if none fires, keep the command inference for reload only), that writes the registration's version or hash per session id. The check then reads that record.

Open gap: the repro used `--plugin-dir`. A second case on a directory-marketplace install would confirm that loader too.
<!-- SECTION:DESCRIPTION:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Fix 1 shipped in 0.3.208: only `/reload-plugins` and process start count; probe canaries 10, 15 and 16 pin `/clear` as a non-refresh. Fix 2 (record what the session loaded) is ruled out: `startedAt` already gives the process-start case, and no hook event fires on `/reload-plugins` (one real transcript checked: no hook attachment follows the reload line), so a per-session record would carry nothing the command inference lacks. Promote again if a release adds a hook event that fires on reload. The directory-marketplace loader case is unverified; it doesn't change the fix, since the check now counts fewer refreshes, not more.
<!-- SECTION:FINAL_SUMMARY:END -->
