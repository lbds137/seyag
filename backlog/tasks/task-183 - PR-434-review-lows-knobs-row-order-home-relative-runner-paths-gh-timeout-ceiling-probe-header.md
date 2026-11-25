---
id: TASK-183
title: '#434 review lows: knobs row order, home-relative runner paths, gh timeout ceiling, probe header'
status: To Do
assignee: []
created_date: '2026-11-25T20:00:00Z'
labels:
  - hooks
  - review-lows
dependencies: []
priority: low
ordinal: 183000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The Claude review of PR #434 passed (merge 42952bb, 0.3.227) and raised four lows. Each needs a fix or a recorded ruling:

1. `plugins/seyag/config/knobs.tsv`: the `SYG_PR_MONITOR_GH_TIMEOUT` row sits after `SYG_PR_OPEN_UPSTREAM_CHECK`. In C-locale order it belongs before `SYG_PR_MONITOR_SEEN_FILE`. Two older inversions exist as well (`LIVE_CHECKOUT_AUTO`/`LIVE_CHECKOUTS`, the `SESSION_CONTEXT_THRESHOLD_FABLE` block). Decide whether to add a probe that pins the order.
2. lossy-pipe-guard: the optional path prefix in `JOB_TARGET`, `(?:[A-Za-z0-9._/-]+/)?`, cannot start with `~` or `$`. So `~/bin/long-job run x -- y | tail` and `$HOME/bin/long-job run … | grep X` are not blocked. `SUITE_TARGET` has the same gap. Fix both (`~/`, `$HOME/`, `${HOME}/`) with probe cases, or list the miss in the header the way rule 3 lists its misses.
3. pr-monitor-reminder: `SYG_PR_MONITOR_GH_TIMEOUT` has no ceiling, so a value such as 600 brings back the hung-gh stall the bound exists to prevent. Clamp it (30?), or say so in the knob text.
4. `pr-monitor-reminder.probe.sh` header: it says case 16 "re-pins the default". Case 16 actually sets the knob to 2, and the unset path is covered only through 16c's fallback branch. Fix the wording and rewrap the long line.
<!-- SECTION:DESCRIPTION:END -->
