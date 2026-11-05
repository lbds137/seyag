# Changelog

All notable changes to the seyag plugin. Newest first. One `## <version> - <YYYY-MM-DD>` section per released version; under it, `###` categories in fixed order — Breaking Changes, Features, Bug Fixes, Improvements, Chores, Tests — empty ones omitted; items are `- **scope:** description (#PR)`, written from the version's merged commit subjects.

## 0.3.133 - 2026-11-04

### Bug Fixes

- **usage-gate:** the `--ok` extra-usage pass's meter names the biller — below 100% of the week the pass still bills the plan, so it prints `meter=plan` with the note ` (extra usage bills only at 100%)`; at 100%+ it bills extra usage and keeps `meter=extra-usage` with the balance; pass/fail semantics unchanged

### Tests

- **reserve-week probes:** `week-burn-window.probe.sh` clears host-set `SYG_WEEK_BURN_RATE` / `SYG_WEEK_BURN_MARGIN_MIN` / `CLAUDE_USAGE_WEEK_RESERVE` — a deployment may legitimately set any of them (a capacity floor while a slope fix is pending, for example), and the probe's `env`-prefix invocations inherited them, flipping hold/burn rows while a shell without the variables ran green; rows that need the knobs still set their own

## 0.3.132 - 2026-11-04

### Bug Fixes

- **reserve-week:** `week-burn-window` freshness reads the `.last` fetch record's content — the fetch epoch `claude-usage` writes on every refresh — instead of its mtime, which sync and backup tools touch without a fetch; an unparsable record holds like a missing one (#241)
- **reserve-week:** `week-burn-window` slope: on a fresh fetch record the slope's endpoint becomes `(now, latest week)`, so a meter that climbed and parked decays honestly instead of reading a stale steep rate; the empty-window path is explicit and the window indexing stays inside its guarded branch (#241)
- **reserve-week:** the `CLAUDE_USAGE_WEEK_RESERVE` clamp's note prints once per `--ok` gate check on every lane (routed lanes included), not on the plan lane only (#241)

### Improvements

- **docs:** README's `week-burn-window` row — XDG path form, the effective-span hold, and the crash classes documented; CHANGELOG 0.3.131 recategorized Bug Fixes → Improvements (#241)

### Tests

- **reserve-week probes:** timeout bounds compare milliseconds; new rows wire the real `week-burn-window` to the real `--ok` gate end to end (fresh pass, degraded hold), and pin content-over-mtime freshness, the shared note on the z.ai lane, and the note-CMD interaction (#241)

## 0.3.131 - 2026-11-04

### Improvements

- **clock-stamp-guard:** the MultiEdit running text (disk text plus what earlier edits leave) is rebuilt only for MultiEdit — a single Edit no longer pays the per-edit rebuild; the header's disk-read paragraph names all three readers; KNOWN GAPS documents the replace_all shared-line judging and the checkbox-stamp escape (#240)

## 0.3.130 - 2026-11-04

### Chores

- **docs:** README rows for the usage-gate reserve commands and `week-burn-window`, the clock-stamp/branch-switch/prepush-scan libs, the review-response and going-public skills, and the SessionEnd wiring example; CHANGELOG adopted (#239)

## 0.3.129 - 2026-11-04

### Features

- **reserve-week:** the plan-week reserve follows `CLAUDE_USAGE_WEEK_RESERVE_CMD` — a command run at each `claude-usage --ok` gate check under a 5 s timeout whose trimmed stdout (an integer 1-99) wins the slot in success and failure, the same contract as the z.ai lane command (#238)
- **reserve-week:** new reference bin `week-burn-window`: reads the claude-usage readings log and prints 99 once the weekly reset is close enough that the week burns down before it, holding (exit 0) on every degraded input so a wired gate stays quiet outside the window (#238)

### Bug Fixes

- **reserve-week:** the static week-reserve overrides (`CLAUDE_USAGE_WEEK_RESERVE`, `CLAUDE_USAGE_ZAI_WEEK_RESERVE`) are validated to 1-99 before bash arithmetic; `100` and `0` are rejected with a stderr note and fall back to 75 — a machine pinning `100` for a gate-at-99%-style setup should pin `99` (#238)
