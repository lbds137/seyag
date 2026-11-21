---
id: TASK-46
title: >-
  Token-cost reduction: weighted usage lens + cost-driving process patterns
  (skill split for Seyag to decide)
status: To Do
assignee: []
created_date: '2026-11-20T19:58:00Z'
updated_date: '2026-11-20T20:04:00Z'
labels:
  - mining
dependencies: []
priority: medium
ordinal: 46000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Owner request (2026-11-20): session-mining should mine spend as well as behaviour and name process changes that would save usage.

Ask: per session and in aggregate, report the four usage kinds from each assistant record's message.usage (cache read, cache write, uncached input, output), deduped by message.id, weighted by the model's price ratios. Reuse usage-audit's per-model weighting; no second copy. Name the process patterns that drive the weighted total; each finding ends in a structural disposition, as the skill already requires.

Patterns to detect (all measurable from the transcript alone):
- Average context per call: cache reads scale with context x calls, so a long session at high context pays on every call.
- Compaction payoff: per compaction or clear, the rebuild's cache write vs the reads saved over the following calls ("compacting too often" vs "too late", with numbers).
- Cache rewrites after idle gaps longer than the cache TTL: a full-context write that is not a compaction.
- Re-reads of the same file within one session, and large tool outputs that stay in context.
- Subagent and headless-worker spend next to the driver's own.

Evidence (one driver session, measured 2026-11-20): 625 calls; cache read 108.9M, cache write 1.3M, output 0.33M tokens; average context ~174k. Weighted (read 0.1x input, 1h write 2x, output 5x), cache reads are ~72% of cost. A post-compaction rebuild (~50-60k written) cost about the reads of five calls at 233k, so earlier compaction would have saved usage there.

Done when: a mining run over a fixture transcript reports the four kinds, the weighted total and at least the context-per-call and compaction-payoff findings, matching a hand count; the weighting comes from usage-audit's table.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Owner addendum (2026-11-20): the owner keeps cost reduction (e.g. trimming always-loaded context) as a skill separate from session mining in another setup; Seyag decides the split. Goal: reduce spend where possible without sacrificing quality or the guardrails/rules that matter. Today three skills overlap: usage-audit (measures spend), doc-audit (always-loaded cost), session-mining (behaviour). Options: (a) one cost-reduction skill owns every lever (process patterns above + always-loaded context), takes measurement from usage-audit, and doc-audit keeps freshness only; (b) the cost lens extends usage-audit. Seyag picks and records why. Either way a guardrail check is required: every proposed cost cut names the rule, hook or guard it would weaken; if one exists, the cut is ruled out or goes to the owner.

Guidance deliverable (owner question 2026-11-20): today the clear/compact/keep pick is semantic only (core rule 'Sessions and handoffs': /clear for an unrelated next unit, /compact for the same thread, keep for a reply due within the hour; context-size-reminder fires at a size threshold). Nothing says when compacting pays for itself. Turn the compaction-payoff measurement into a written break-even rule wherever the split puts it (core rule line or the cost skill), and make context-size-reminder's banner state it. Shape: a rebuild costs about W written tokens at the write ratio; staying large costs (current context - post-compact context) x read ratio per call; compact once the expected remaining calls in the thread exceed the break-even count, and /clear when the next unit doesn't need the thread. Include the idle-gap case: past the cache TTL the next call rewrites the whole context anyway, so the boundary costs nothing extra. Derive the numbers from measured sessions, not this sketch.

Owner ruling (2026-11-20): the existing context thresholds (watch from ~20% of the window, compact past ~25%) are provisional, not decisions to preserve. If the measured break-even says otherwise, the data wins: update the thresholds and the reminder to match and record the reason.
<!-- SECTION:NOTES:END -->
