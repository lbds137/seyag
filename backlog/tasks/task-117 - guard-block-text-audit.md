---
id: TASK-117
title: 'guard block-text audit: every block prints a runnable compliant retry'
status: To Do
assignee: []
created_date: '2026-11-23T03:31:00Z'
labels:
  - mining
  - guards
dependencies: []
priority: high
ordinal: 117000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
From session mining (the most-tripped row: ~225 items across ~143 sessions in one week, up from ~104/89 the week before): a guard's block text that does not print the compliant retry costs a re-learn per trip. Owner ruling: a one-time audit of every guard's block text, lossy-pipe-guard included; text only, no matcher change.

For each guard (lossy-pipe, pr-body-ref-gate, private-term-guard (the matched term is not shown), python-heredoc-edit-guard, temporal-marker-guard, broad-walk-guard, recursive-rm-guard, and the rest of the guard families): the block prints a retry the session can run as-is, built from the blocked command where possible; probes pin it. Known instance: recursive-rm-guard blocked a single literal path inside a worker's job-scratch folder although its own text says that shape is allowed; reproduce, then fix the text or the matcher (the latter is a matcher change: separate commit, own probe).

Moved out of TASK-20 (its mining-residuals bucket).
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Measured 2026-11-27 (Seyag), to see whether block texts fail to produce a compliant retry. Source: 7 days of local transcripts, `assistant`/`user` entries only (`api-request-blob` entries replay history and were excluded), deduped by tool_use id. Metric: does the session's next Bash call trip the same guard again? 1846 Bash blocks in all.

| Guard | Blocks | Next call trips it again |
|---|---|---|
| lossy-pipe | 683 | 4 |
| python-heredoc | 454 | 0 |
| cwd-drift | 212 | 0 |
| pr-body claim-shape | 99 | 7 (4 are an identical re-run, which passes by design) |
| private-term / session-url ("blocked:") | 86 | 1 |
| recursive-rm | 63 | 1 |
| self-matching | 42 | 2 |
| env-print | 33 | 6 |
| temporal-marker | 31 | 1 |

Every other guard re-tripped 0 times, including pr-merge (26), broad-walk (16), worktree-branch (16) and grep-dollar (15).

Reading:
- The current texts already get a compliant next call about 98% of the time.
- The one clear gap is env-print's jq variant. All 6 re-trips are sessions reading non-env fields (`.hooks…`, `.. | .command?`) from settings.json. The remedy lines offer only env-shaped selectors (`.env|keys`, `.env.VAR`) and never say which non-env selectors pass.
- What the metric cannot see: first trips in a new session, which no block text prevents. That is the "re-learn per trip" cost the mining row named.

Inventory of every wired PreToolUse guard's block text (verdict per message: as-is / generic / no-retry; probe pins): a driver-side Explore pass, 2026-11-27, summarised in the owner AskUserQuestion that night. NO-RETRY messages: private-term "Remove it."; dispatch-posture over-size and cumulative; upstream "don't submit" (deliberate); publish-gate unresolvable-repo branch; lossy-pipe job "Run it UNFILTERED"; pr-merge ack-state faults.

recursive-rm known instance, by code-reading only (not reproduced): a single literal path under `$CLAUDE_JOB_DIR/tmp/<name>` passes when CLAUDE_JOB_DIR is set in the hook's environment and names an existing directory (lib/delete_commands.py scratch_target / in_scratch; probe expects 0 for that case). Likely trigger of the reported block: a worker with CLAUDE_JOB_DIR unset, or the tmp dir itself as the target. Still to reproduce.

Owner ruling 2026-11-27 (AskUserQuestion, on the measurement above): narrow it. One PR, then close this task citing the measurement:
1. Fix env-print's jq remedy so it names the non-env selectors that pass.
2. Give private-term ("Remove it.") and dispatch-posture over-size/cumulative a retry line.
3. Pin those lines in the probes.
4. Reproduce the recursive-rm report.
The full per-guard rewrite is ruled out on that measurement.
<!-- SECTION:NOTES:END -->
