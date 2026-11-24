---
id: TASK-131
title: 'change-class: PR #387 review lows'
status: To Do
assignee: []
created_date: '2026-11-24T00:55:44Z'
labels:
  - ci
  - tests
dependencies: []
priority: low
ordinal: 131000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
claude-review on #387 (0.3.217) passed with six lows. Each fails safe, toward `full`, or is prose only. They're filed here so the next `change-class` touch picks them up.

1. `change-lanes` §4 does not name the `--base`/`--head` pair CI should pass. The base tip against a behind PR head diffs in the newer base changes, reversed: safe but noisy. State one form: the base tip with the PR merge commit (`github.sha` on `pull_request`), or the merge-base with the PR head.
2. Hard-deny misses some agent-instruction surfaces: `.windsurfrules`, `.clinerules`/`.clinerules/**`, `**/.claude-plugin/**`, `.aider*`. Add them, and tell policy authors in the skill to `deny` the rule and skill trees their own tooling loads (plugin `rules/`, `skills/**/SKILL.md`).
3. Probe case 8 pins only part of `HARD_DENY`. Add one line per entry, covering the hooks family, `AGENTS.md`/`GEMINI.md`, `.cursor/**`, `.claude/**` and the nested `.git*` segment fallback (`docs/.gitmodules`, `docs/.GitIgnore`), so that dropping an entry fails the probe.
4. Optional UX: `--help` counts only as argv[0] or argv[1], so `classify --json --help` exits 2 with "unknown argument". Deliberate per probe 17h; decide whether to keep it.
5. Optional: a delete in a class without `allow_delete` reports `mode: <path>`. A `delete:` prefix would read better in replay summaries; the probe would need to change with it.
6. TASK-130's tracked text: check it against the no-private-naming rule. The 2026-11-23 replay notes already anonymize the surveyed repos.
<!-- SECTION:DESCRIPTION:END -->
