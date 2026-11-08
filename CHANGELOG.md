# Changelog

All notable changes to the seyag plugin. Newest first. One `## <version> - <YYYY-MM-DD>` section per released version; under it, `###` categories in fixed order — Breaking Changes, Features, Bug Fixes, Improvements, Chores, Tests — empty ones omitted; items are `- **scope:** description (#PR)`, written from the version's merged commit subjects.

## 0.3.141 - 2026-11-08

### Bug Fixes

- **security-sweep:** a repo token starting with `-` in `SYG_SECURITY_SWEEP_REPOS` no longer drops the whole SessionStart sweep (tokens pass as `--repo=TOKEN`; `--session-line` and `--warm-cache` parse errors exit 0 silently); a structurally corrupt cache entry (wrong-typed count, severities, rule ids, alert entries or types) is refetched instead of failing the run or hiding alerts.

### Improvements

- **security-sweep:** new `--cap SECONDS` (exit 124; at most one day) replaces the `timeout` binary for the SessionStart 2 s cap, so the cap holds where `timeout` is missing; new `--warm-cache` makes the detached cache-warming run take a non-blocking lock per repo set, so repeated starts no longer stack runs; abbreviated flags are refused; under `--strict`, exit 1 (alerts) is documented to win over exit 2 (errors).
- **delegation skill:** § Parallel work — three tiers (local workers, cloud units, parallel local drivers) with a selection table and the parallel-driver contract; the cloud-unit cap is a project rule with two numbers (default one and one); cloud ledger, setup-script environment, cloud step 0 as a project file, CI caveat and resume fallback (#257); the ledger timing is stated once, a mechanical placement check is added, and § Adopting names the cloud pieces (#258).
- **probes:** load-flaky timing rows assert the property instead of wall time: release-marker holds in place of sleep races (security-sweep, session-start), CPU-time bounds (shell_quotes perf rows, session-url-gate latency), wider pr-ci-wait give-up ceilings and a marker rendezvous for the run.probe.sh parallel row (#256).

## 0.3.140 - 2026-11-08

### Features

- **security-sweep:** new `security-sweep` bin reports open code-scanning, dependabot and secret-scanning alerts per repo (a count, `off` or `error` per surface; secret values dropped at fetch time; disabled-scanning responses read as `off`; `--strict` exits 1 on critical/high or secret alerts and 2 on an uncached fetch error or an internal error; `--json` carries alert numbers), an opt-in `security` SessionStart line (`SYG_SECURITY_SWEEP=1` or `SYG_SECURITY_SWEEP_REPOS`; headless-off) and a disposition skill (#254).

### Improvements

- **pr-monitoring skill:** retry a first Monitor call once on InputValidationError; after an automerge, close linked issues still open and delete the branch only when `branch-sweep` marks it eligible (#251).
- **session-log:** stats name `command hook <N>` blocks by their banner title (`hook:cwd-drift-guard`). Guard keys change at this release: earlier counts sit under `hook:<N>`, so guard-ledger comparisons across it don't line up by key, and renaming a banner title renames its row (#252).
- **pr-monitoring skill:** close-out follow-ups — a failed linked-issue read is reported, never treated as closed; the branch delete is `git branch -D --`; a SKIP from the unit's own worktree is cleared by a `safe-worktree-clean` dry run plus `git worktree remove` on that one tree, never `--apply` (#253).
- **claude-usage:** `--posture` prints the configured week thresholds (`week posture: wind-down R% · stop S% · now W%`); the new `CLAUDE_USAGE_WEEK_STOP` (default 80) is reported only (#255).

## 0.3.139 - 2026-11-07

### Features

- **hooks:** `live-checkout-guard` keeps a directory-source plugin checkout on its default branch. The live root is auto-detected from `CLAUDE_PLUGIN_ROOT` (when its git toplevel has `.claude-plugin/marketplace.json`) plus `SYG_LIVE_CHECKOUTS`. In it the hook blocks branch switches, stash, commits, history and tree mutations, non-ff-only pulls, and Edit/Write/MultiEdit/NotebookEdit on tracked files, while allowing linked worktrees (including a worktree added earlier in the same command) and gitignored paths. It ships as component `live-checkout`, with bypass `SYG_ALLOW_LIVE_CHECKOUT=1` (#250).

### Improvements

- **delegation skill / CLAUDE.md:** a live-checkout project never parks or transfers into its main checkout. The unit's worktree is cut from `origin/main`, and the driver commits there (#250).

## 0.3.138 - 2026-11-05

### Bug Fixes

- **versioning skill:** the notes range is `<prev-release-base>..HEAD` on the PR branch — notes are written before the merge lands, so no merge SHA exists yet; review-round fixups collapse into their parent item and the bump-and-notes commit itself is not an item (#249)
- **versioning skill:** the pre-1.0 scheme is patch per merged batch, dropping the minor clause that contradicted it — every 0.3.x batch, features included, has bumped patch; post-1.0 semver keeps behavior → minor, and a project may reserve minor for breaking changes (#249)
- **versioning skill:** the floor checklist scopes to compatibility fields (minimum host version, engines, permissions) instead of "any field besides the version", matching the core.md floor clause (#249)

### Improvements

- **core.md:** merge rule wording — the bump and notes land in "the PR that completes the batch", not "the same PR"; the literal reading would bump every PR in a multi-PR batch (#249)
- **versioning skill:** the multi-PR case lives in the skill text — one bump per batch, carried by the completing PR or a dedicated release PR; the cross-reference names the exact heading (§ Evidence and claims) (#249)
- **versioning skill:** the defer-to-project paragraph covers the version scheme — a project with its own pre-1.0 convention pins it in its CLAUDE.md (#249)

## 0.3.137 - 2026-11-05

### Features

- **versioning skill:** release mechanics for a versioned project — the merge PR carries the version bump and the release notes; defer-to-project version file and notes location, pre-1.0 patch-per-batch scheme, notes format with fixed category order, commit subjects as the source of truth, two-theme cut, and a floor checklist citing the verifying probe (#248)

### Improvements

- **core.md:** merge rule — in a project that versions, the session driving a merge bumps the version and lands the release notes in the same PR; the unfinished-batch clause folds into the completion-claims line (#248)
- **core.md:** floor clause — a compatibility floor or new manifest field (minimum host version) is an external-system claim: it cites the probe that verified it (#248)

## 0.3.136 - 2026-11-05

### Bug Fixes

- **probes.yml:** workflow-level `permissions: contents: read` — both jobs need only checkout and local git over a full clone, closing the two missing-workflow-permissions code scanning alerts (#246)
- **keys:** the `keys set` name summary derives from the pre-write store plus the argv name, so the printed string never traces to the secret's buffer — closes the clear-text-logging alert; printed message byte-identical to the probe pin (#246)

## 0.3.135 - 2026-11-05

### Improvements

- **reserve-week:** `week-burn-window` docs — the override is never floored but the > 100 clamp still applies; a deployment whose real burn capacity is under 1 %/h should set `SYG_WEEK_BURN_RATE`; the `RATE_FLOOR` comment is now a one-line pointer to the sibling end-to-end row (#245)

### Tests

- **reserve-week probes:** a `SYG_WEEK_BURN_RATE=0.5` row with the reset 50000 s out discriminates the never-floored override property — the 0.1 row burns either way, so a guard-dropped mutant fails exactly the new row; probe header re-wrapped (#245)

## 0.3.134 - 2026-11-04

### Bug Fixes

- **reserve-week:** `week-burn-window` floors every computed rate — slope, fresh-endpoint decay, parked/flat — at the 1 %/h capacity default (raised from 0.5, where it covered only rate <= 0): a hold suppresses the very rate it measures, so a held meter's tiny positive decay slope (~0.17 %/h live) stretched the burn window to ~110 h and printed the burn ~3 days early; floored, a held or trickle week burns only once the reset is close enough, and `SYG_WEEK_BURN_RATE` still overrides entirely (#244)
- **review-response:** the round's fixup batch is held in automerge repos (#243)
- **review-response:** plain commits in automerge repos, with the batch gate scoped to them (#243)
- **review-response:** the fixup flow is scoped to controlled-merge repos (#243)
- **review-response, delegation:** the automerge carve-out is carried across review-response + delegation (#243)

## 0.3.133 - 2026-11-04

### Bug Fixes

- **usage-gate:** the `--ok` extra-usage pass's meter names the biller — below 100% of the week the pass still bills the plan, so it prints `meter=plan` with the note ` (extra usage bills only at 100%)`; at 100%+ it bills extra usage and keeps `meter=extra-usage` with the balance; pass/fail semantics unchanged (#242)

### Tests

- **reserve-week probes:** `week-burn-window.probe.sh` clears host-set `SYG_WEEK_BURN_RATE` / `SYG_WEEK_BURN_MARGIN_MIN` / `CLAUDE_USAGE_WEEK_RESERVE` — a deployment may legitimately set any of them (a capacity floor while a slope fix is pending, for example), and the probe's `env`-prefix invocations inherited them, flipping hold/burn rows while a shell without the variables ran green; rows that need the knobs still set their own (#242)

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
