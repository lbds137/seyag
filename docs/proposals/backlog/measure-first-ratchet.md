# The always-loaded-context ratchet (measure-first port)

**Status: ACCEPTED 2026-10-29.** Council: 4 models briefed with identical adversarial
text, 4 answered (glm-5.3, kimi-k3, deepseek-v4-pro before the owner pass;
qwen3.8-max-0902 after it — incremental fold below). Owner: skill-eval ruled
OBSOLETE and the design CONFIRMED ALL (ask answered directly, and relayed
independently through the owner's management session) — sign-off on both rulings.
Scope of that sign-off: the design as presented through the pre-qwen fold; the
post-pass qwen refinements below (including one declined dissent, recorded in
§ Council record) are engineering-level folds that did not go back to the owner.
Extends the measure-first item of the Tzurot port queue (owner-approved audit,
2026-10-18); dispositions for two sibling items (hook-probes parity, skill-eval)
land here. Implementation follows § Phasing; this PR carries the artifact only.

## Owner directives (verbatim)

- Port picks (owner, 2026-10-18): "Tzurot port picks … after audit-2: merge-review,
  branch-commit, design-boulder, PR-monitoring prose, bin worktree-transfer" —
  measure-first named in the same audit's queue (item 5: "Seyag equivalents need
  design (suite probes, not tooling package)").
- Repo CLAUDE.md, standing: "`plugins/seyag/rules/core.md` is always-loaded in every
  session on the machine … every added line is paid on every turn everywhere. Cut
  before adding."
- Rulings on this artifact (2026-10-28/29): skill-eval = "Obsolete — don't port",
  design = "Confirm all" (both channels, matching answers).

## Grounding provenance

All facts [V] verified this session (2026-10-28, checkout 4f41a76 / 0.3.108) unless
noted; this artifact carries everything the design needs.

- Tzurot sources read whole: `lines-check.WHY.md` (126L), `lines-surfaces.ts` (235L),
  `lines-check.ts` (593L), `lines-ceiling.ts` (108L), `check-hook-probes-registry.ts`
  (236L), `check-hook-probes.ts` (327L), and Tzurot's `skill-eval.sh` hook (259L).
- Seyag side verified: `tests/hook-wiring.probe.sh` already ships bidirectional
  hooks↔probes↔hooks.json↔components.tsv↔bins parity with written exemptions;
  `.github/workflows/probes.yml` gates every PR event with no path filters and no
  explicit job timeout; `tests/run-probes.sh` discovers probes by glob, redirects
  each probe's stdin from `/dev/null` and output to temp files, and has no
  per-probe timeout; the harness natively lists every plugin skill + description in
  every session context (observed).
- Measured surfaces (this checkout, moves with every edit — the baseline file is the
  live record going forward): rules `plugins/seyag/rules/core.md` 165 lines / 21,159
  bytes (one file in the glob); repo `CLAUDE.md` 23 / 4,666, with no `@`-imports;
  18 `SKILL.md` files, 2,011 lines / 190,372 bytes total, every one with a
  single-line `description:` frontmatter — plain unquoted scalars (backlog-md,
  going-public) and single-quoted scalars across the other sixteen; bodies
  lazy-loaded. One agent (`agents/implementer.md`, also a plain scalar) whose
  frontmatter description is likewise natively listed.

## System as-is

Seyag's whole gate is the probe suite (`tests/run-probes.sh -j N`): glob discovery
over `plugins/seyag/hooks/*.probe.sh` + `tests/*.probe.sh`, suite-order PASS/FAIL,
run by CI (`probes.yml`) on every PR with no path filters — doc-only pushes cannot
skip it. Registry parity (every hook probed and wired, every bin probed) is already
enforced by `tests/hook-wiring.probe.sh`, which leaves Tzurot's `guard:hook-probes`
with one residue: no per-probe timeout — a hung probe stalls the whole suite, and
`probes.yml` sets no explicit `timeout-minutes` (the GitHub default job ceiling is
the only backstop). Baseline tooling does not exist. Size measurement does: `plugins/seyag/bin/context-audit`
(Python, 291L) — `weigh` is the doc-audit skill's advisory, machine-wide audit (its
skill-description figure counts whole frontmatter blocks); its fence-aware `@`-import
scan (`IMPORT_RE`) and frontmatter parsing are the prior art this design reuses (D1).
The always-loaded context is paid on every session (plugin rules + skill/agent descriptions machine-wide; repo
CLAUDE.md per-repo) and grows through the cheapest commit path (prose edits), with
nothing structural pushing back.

## Audience of the ratchet (stated per council)

This ratchet audits the SEYAG REPO's own context costs: what maintainer sessions and
this repo's CI pay for seyag's shipped surfaces (plugin rules + descriptions,
machine-wide for every session that loads the plugin) and for the repo CLAUDE.md
(seyag-repo sessions). An adopter's own repo CLAUDE.md is their context, not seyag's
gate; the plugin ships the mechanism, a repo adopts it with its own surfaces.

## Perimeter

**Measured (v1):** checked-in files the harness pays for on every session — plugin
rules, repo CLAUDE.md, skill/agent frontmatter descriptions.

**Explicitly NOT measured, with reasons:**

- **Skill/agent BODIES** — lazy-loaded on invoke; not always-paid.
- **Hook-injected context** (SessionStart/UserPromptSubmit `additionalContext`) —
  a per-prompt cost class the ratchet does not see; it is also where Tzurot's
  skill-eval banner lived. Follow-up trigger: any hook that injects a large static
  block gets its output measured or its size budgeted then (council's hollowing
  path — shrink rules, grow a hook — is closed by this trigger plus review
  visibility).
- **Machine-local files** (`~/.claude/CLAUDE.md`, memory) — not in the repo, not
  measurable by CI (the same allowance Tzurot's ceiling makes).
- **MCP tool schemas** — seyag ships no MCP config today; if one lands, it is an
  always-paid surface and joins the set (first-use trigger, per council).
- **README, hooks.json, components.tsv** — not context.

**Known harness dependencies, stated:** the surface set mirrors how the harness
loads plugin rules and lists skills/agents *today*, observed live [V]. If the
harness changes that behavior (recursion, listing truncation, lazy descriptions),
the ratchet can gate a phantom or miss real cost — the impl version + drift hash
force a re-look at measurement changes, but harness-side change is invisible to
the repo and is this design's standing limitation. Re-check trigger: any harness
release note touching rules loading or skill listing.

## Decisions

### D1 — Ship the ratchet as a bin + probe pair (house shape)

`plugins/seyag/bin/lines-check` (bash; `jq` required, fail-loud if absent — the
house pattern `run.sh` uses): `--check` (default; exit non-zero on any failure),
`update-baseline [--surface S] [--dry-run]`, `--breakdown`, `--baseline PATH`,
`--root DIR` (canaries/tests). Exit-code contract: 0 pass, 1 check failed (over
budget, hollow, measurement-refused, import found, nested dir, fixture leak),
2 usage/environment, 3 baseline/schema/config error (missing, invalid, or
canonical-set-inconsistent baseline) — prose never carries the verdict alone, and
each canary below pins its code. `tests/lines-check.probe.sh`: the live repo passes `--check`; a
canary fixture tree (fake repo root with its own baseline) asserts exact failure
shapes via stable tokens and exit codes; positive-control mutants built in fixture
copies only (the hook-wiring pattern — never the live tree). README row per house
convention; hook-wiring's bin-probe rule satisfied by the probe (components.tsv is
hooks-only — bins are covered by the bin-probe rule, no registration needed).

**Measurement core (reused, per review round 2)**: measurement lives in
`context-audit`, which gains a repo-scoped `measure` verb emitting JSON — the three
surface numbers with D2's decoded-description byte model, per-file breakdown rows,
and the instructions total (D8's tripwire sum). `lines-check` is the bash policy
gate over that JSON (`jq` required; fail-loud if `python3`/`context-audit` are
absent — both already shipped, `context-audit` itself being a Python bin). One
extractor, no YAML scalar decoding re-implemented in bash (the riskiest part of D2
per the round-2 review); the advisory `weigh` and the repo gate keep separate
outputs, and the description byte model canonical for the GATE is the decoded
value, while weigh's whole-frontmatter figure remains the audit's own advisory
view — each README row states which it reports. The baseline meta's impl version
bumps when the `measure` output contract changes.

**Canary/mutant set (each pins one failure mode):**

1. over-budget surface → fail (exit 1) naming surface + dimension (both breach
   shapes: lines-only-over and bytes-only-over);
2. hollow measurement (glob matches zero files) → fail (exit 1), never pass at 0;
3. missing baseline file → fail (exit 3) with the refresh instruction (hard,
   never ungated);
4. baseline missing a canonical surface → fail (exit 3, union iteration); a
   baseline-only stray entry fails too (exit 3, the evaluator's "not measured by
   this tool" class);
5. **grace inflation** (baseline diff raising grace without content growth) →
   passes `--check` BY DESIGN, and the test pins that the delta is what the
   reviewer sees — the threat model in the README row says it plainly: the
   ratchet catches unintentional growth; intentional growth is a visible baseline
   diff in review, and the reviewer is that gate;
6. description extraction totality (D2): a folded multi-line description, a
   missing `description:` key, and malformed frontmatter each fail as
   measurement-refused (exit 1), never partial-measure — with positive cases for
   every accepted form — plain unquoted, single-quoted, and double-quoted with an
   escape sequence (e.g. `\"`) — each decoding to its true value; three live
   files are plain scalars, so a quoted-only extractor would refuse the live
   repo;
7. an `@`-import inside a measured file → fail (exit 1; bytes must not migrate
   off the measured set). Detection is the shared import scan — fence- and
   backtick-aware, `context-audit`'s `IMPORT_RE` semantics — so an inline
   backtick token like `` `pkg@somehost` `` does not match; no imports exist in
   measured files today [V];
8. a subdirectory under a measured glob → fail loud (exit 1; forces the
   recursion-premise re-check instead of silently ignoring nested files);
9. fixture isolation: no path under `tests/` (fixtures, canaries) ever enters a
   live measurement (exit 1 if one does) — the live globs are scoped to
   production plugin paths by construction, and this canary proves it;
10. invalid baseline → schema error (exit 3), with atomic writes on the refresh
    path (temp file → validate → rename; a failed refresh never leaves a partial
    baseline).

**Safe traversal** (council): measurement reads regular files only — a symlink,
FIFO or device file in a measured surface fails loud rather than measuring zero or
hanging on a special file; paths stay under `--root`.

*Rejected — probe-only*: the update path needs an operator-facing command; a gate
that cannot sanction its own refresh invites hand-edited JSON.
*Rejected — TS tooling package*: no TS build in seyag (the worktree-transfer port
established the interpreter-rewrite rule).
*Declined (council, recorded): renaming the bin `size-ratchet`* — cosmetic;
Tzurot-continuity naming wins.

### D2 — Surfaces (v1): `rules`, `claude-md`, `descriptions`

- `rules` — `plugins/seyag/rules/*.md`, summed across files (core.md is the whale;
  future rules files land in the same sum, which is the point).
- `claude-md` — repo `CLAUDE.md` alone (paid in every seyag-repo session; grows
  through the same cheap prose path; no `@`-imports allowed in it — canary 7).
- `descriptions` — the frontmatter `description:` of every
  `plugins/seyag/skills/*/SKILL.md` **and** `plugins/seyag/agents/*.md`, summed.
  One surface, one extraction mechanism. **Totality invariant**: every matched
  file yields exactly one complete single-line description or the surface FAILS
  as measurement-refused — under-extraction must never read as a low number
  (a folded YAML value under a naive extractor is the exact PR this ratchet
  exists to catch). **Accepted forms, named explicitly**: single-line plain
  unquoted scalars, single-line single-quoted scalars (with the `''`→`'` escape),
  and single-line double-quoted scalars — each measured to its decoded value;
  anything else (folded or block scalars, missing keys, malformed frontmatter) is
  measurement-refused. The live set today: plain scalars (backlog-md, going-public,
  the agent) and single-quoted scalars (the other sixteen skills). The description
  is the dominant *variable* part of what the harness natively lists per
  skill/agent — a proxy for that listing, not a claim of completeness.

**Descriptions byte model** (council addendum, qwen): the measured value is the
EXTRACTED description string — the decoded YAML scalar's UTF-8 byte length — not
the raw frontmatter line (quoting and indentation are syntax, not cost). Skill
names, identifiers and the skill count are visible in `--breakdown` but ungated in
v1: the description is the dominant variable cost, and count growth moves the
surface anyway (each new skill carries its description bytes). A rendered-listing
cost model (names + formatting + escaping as the harness renders them) is the
honest v2 refinement if listing overhead ever proves material.

*Rejected — gating skill BODIES* (Tzurot's `skills` surface): bodies are
lazy-loaded in the current harness; gating them manages a cost that is not
always-paid.
*Rejected — deferring agent descriptions to a second agent*: implementer.md is
already listed and already paid; deferring would baseline unratified growth at
the surface's birth (council: off-by-one, corrected).
*Deferred with trigger, FIRST occurrence* (council, qwen's generalization
adopted): any new always-paid class — first MCP config, first context-emitting
hook with large static output, first harness-listed file class — joins the set
when it first appears, not at some later threshold. The union-iteration
mechanism (D4) makes adding a surface a config line and a baseline refresh, with
the migration cost D4 names.

### D3 — Two dimensions, lines and bytes, both gated

Tzurot's why transfers verbatim: density varies across the corpus, so a
line-only ratchet rates dense files "comfortable" while they carry the payload;
bytes are exact, deterministic, tokenizer-free; a derived token figure is display
only and never gates. For whole-file surfaces bytes are the on-disk byte length
of the working-tree file — the artifact the harness actually loads — measured by
the Python core (`len(read_bytes())`, equivalent to `wc -c`); the file content is
never trimmed or normalized. The `descriptions` surface measures its extracted
values instead, per D2's byte model. The fleet and CI are LF-only; implementation
adds/verifies a `.gitattributes` eol pin for measured paths so EOL churn cannot
move the number. README limitation line (council): *bytes is a proxy for tokens;
divergence (e.g. CJK-heavy prose) is a known limitation, not a bug* — the two
dimensions are chosen to diverge on each other's blind spots (line-joining
inflates bytes, line-splitting inflates lines). Lines count newline-terminated
lines, plus a final unterminated line — Tzurot's countLines arithmetic, chosen so
a file missing its trailing newline does not silently drop its last line from the
count. That is not strict `wc -l`, which counts newlines only; the design drops
the wc-compatible label. Both dimensions gate, and if line semantics ever prove
unstable across contributors, lines demote to display-only — bytes carries the
gate alone.

### D4 — Baseline mechanics from Tzurot, plus the panel's closes

JSON baseline at `.github/baselines/lines-baseline.json`:
`{surfaces: {<name>: {lines, grace_lines, bytes, grace_bytes}}, meta:
{impl_version, config_hash, notes}}`.

- Limit = baseline + grace, per dimension; both dimensions gate independently and
  both are reported.
- **Hollow fails**: a surface whose glob matches zero files is a failure, never a
  0-line pass (a moved directory must not disarm the gate) — and hollow is
  evaluated after extraction too (D2's totality), not only after globbing.
- **Union iteration**: evaluate the canonical surface set ∪ the baseline's keys —
  a canonical surface missing from the baseline fails instead of silently going
  ungated; a baseline entry the tool no longer measures fails too.
- **Scoped refresh**: `update-baseline` unscoped rebuilds from the canonical set
  (prunes strays, self-healing); `--surface S` rewrites only S and carries all
  other entries verbatim (so a trim's tightening lands without loosening an
  unrelated grown surface — the failure that happened in Tzurot), warning when a
  scoped refresh would leave canonical surfaces untracked. Refreshing from a
  hollow measurement fails with exit 3 — it would bless a broken surface path. A
  scoped refresh validates the whole baseline, not
  just its target — strays and schema errors fail the refresh, they are not
  silently preserved.
- **Shrink guard** (council, qwen): refreshes print old→new deltas per surface
  (Tzurot's `formatDelta` behavior, made explicit here) and WARN when a surface's
  measured value drops by more than half without a corresponding impl-version
  bump — a silent shrink (extractor regression, moved file) must not be lockable
  in as the new truth without the delta being visible in review. Baseline-lowering
  diffs are review-gated like any other.
- **Drift check**: the baseline records a hash of the measurement config — impl
  version, surface set, globs, exclusions, AND extraction/normalization logic.
  Bump the impl version when any of those change; the failure text names the
  refresh. The hash deliberately does NOT cover grace values: grace is owner
  policy visible in the diff (canary 5 pins that visibility), not a measurement
  input.
- **Grace policy** (stated, per council): absolute values sized from seyag intent
  at implementation (rules absorbs one new rule section; claude-md a process
  paragraph; descriptions one new skill or a rewording pass), recorded in the
  baseline `notes`. Tightening is free at any time; loosening is a visible
  baseline diff in review — the ratchet's threat model is unintentional growth,
  not motivated growth. Schema validation (canary 10) keeps grace non-negative
  integers; a governance escalation (caps, CODEOWNERS) is recorded as declined
  for v1 in the council record, with its trigger.
- **Migration cost, stated** (council): adding a surface to the canonical set
  fails every in-flight PR until each rebases and refreshes; the surface-adding
  PR carries the baseline refresh, and the failure text names that.
- **`--breakdown`**: per-file ranking, worst-first by bytes, printed after every
  outcome including broken-state exits; never gates. The tracked-instructions
  total prints on every `--check` (council: the O1 trigger must observe itself).
- Initial margins sized at implementation; numbers live in the baseline file and
  are measured fresh there.

### D5 — `skill-eval.sh` is OBSOLETE; do not port (owner-ruled)

Both grounds, stated (council split on emphasis, unanimous on the decision;
owner ruled OBSOLETE 2026-10-28/29 on both channels):

1. The discovery gap the hook's banner addressed is closed — the harness
   natively lists every skill + description in every session context [V,
   observed live].
2. The residual gap (the model sees the list and still doesn't invoke — the
   ~20% figure's actual meaning) is real, but the hook is the wrong lever for
   it: an always-on UserPromptSubmit hook at Tzurot-measured ~97–213 ms per
   prompt (that environment's number, not seyag-measured — labeled as such)
   buys a per-prompt banner machine-wide. The cheaper levers are description
   quality and rules-text triggers, which seyag already uses.

Re-check triggers (folded from council): the harness stops natively listing
plugin skills, skill activation measurably regresses, or skills land that the
harness will not auto-surface.

### D6 — Per-probe timeout in `run-probes.sh`: port, with a correct kill model

Each probe child runs under GNU `timeout` with **`-k 5`** (a TERM-ignoring child
must not hang the waiter). Default (non-`--foreground`) mode signals the child's
process **group**, so grandchildren die with it unless they daemonize — the
honest residual: "we stopped waiting" ≠ "it stopped" *for a daemonizing escapee*,
bounded by the job. The two structural hang vectors are already closed in
`run-probes.sh` and stay closed: probe stdin is `/dev/null`, probe output goes
to temp files (no surviving grandchild can hold a pipe the runner reads). The
probe contract stays synchronous — a probe that forks background survivors and
exits 0 is a probe bug, and the process-group kill is the backstop, not a
license.

**Composition with the existing runner**: `tests/run-probes.sh` already runs
each probe inside a `set -m` subshell — the probe is its own process-group
leader — and after exit sweeps the group with TERM, then KILL for survivors,
with a 143 exit path when the runner itself is signalled. D6's `timeout` wraps
`bash "$p"` INSIDE that subshell, so its group signaling covers the probe tree;
the existing post-exit sweep stays in place as the second net (it also reaps
anything the timeout killed); and a timeout death (124/137) is recorded through
the runner's existing `.rc` file machinery in `reap_one` exactly like any other
non-zero exit — never as a silent pass, and distinguishable from the runner's
own 143 path.

- Default ceiling: a generous multiple (≥5×) of the slowest probe measured under
  parallel conditions, with an absolute floor; the effective value prints in the
  suite banner so a too-tight default is attributable, and CI may pin
  `SYG_PROBE_TIMEOUT`. Non-numeric or empty → default (no disable footgun).
- Portability: if no `timeout` binary exists, one stderr note and the suite runs
  unbounded — the exact pattern `run.sh` uses for its own timeout dependency,
  pinned by a probe case (macOS adopters get the note, not silence; CI is Linux
  and always enforces). Qwen's dissent (fail loud, never run unbounded) is
  recorded and declined: fail-loud breaks local runs entirely for a ceiling that
  is a backstop, not the primary hang defense; the note keeps the state visible.
  Per-probe declared timeout manifests: deferred — the global ceiling plus the CI
  pin covers v1; add per-probe values only if a probe legitimately needs more
  time than the floor (trigger: first such probe).
- Exit contract: 124 (and 137) map to FAIL naming the probe, with the note
  "usually the ceiling; an external cancel looks the same"; partial output is
  preserved and printed — a timeout must not hide the failure it interrupts.
- Canary: a hung-probe fixture (`sleep` under a small `SYG_PROBE_TIMEOUT`)
  asserting fast suite failure + the named-probe FAIL shape.

### D7 — Gating arrives by construction; the suite's runtime contract is the one change

The probe joins the suite's glob discovery → `probes.yml` runs it on every PR
(no path filters [V]) → doc-only pushes are gated, which is the property Tzurot
had to build a special path for. A growth PR carries its own baseline diff:
growth becomes a visible decision in review, never drift. Baseline bumps never
ride unrelated PRs (scoped refresh exists precisely so they don't have to).

Stated precisely (council): no NEW workflow files or triggers — but D6 changes
the suite's runtime contract for every probe, and `probes.yml` gains an explicit
`timeout-minutes` (today only the GitHub default job ceiling bounds a hung run).
Rollback for D6: unset `SYG_PROBE_TIMEOUT` / revert the `run-probes.sh` hunks.

Governance (council, qwen's strongest push): the gate is self-hosted — a PR can
weaken bin, probe, baseline or suite, and no in-repo mechanism can stop that.
Seyag's existing answer is the review flow: every PR carries the full suite +
claude-review, main is protected, and the owner reviews baseline diffs (canary 5
makes them legible). CODEOWNERS on the gate paths is DECLINED for v1 — the repo
has one effective reviewer today and CODEOWNERS adds process without adding a
second pair of eyes; promote-when: a second maintainer lands. Required-check
status and fork-PR behavior are today's already-shipped configuration, out of
this design's scope.

*Declined (council idea, recorded): a CI-side `update-baseline --dry-run`
equality check.* It breaks on the legitimate grace-absorbing flow — an
in-grace PR's baseline (stale measured values, tool-preserved margins) would
never equal a fresh measurement, so exact equality would red every normal PR.
The reviewer-facing controls (delta print, PR diff, threat-model line) are the
mechanism.

### D8 — Hard instructions ceiling: declined for v1 (see O1)

Tzurot adds a fixed 147k-char (UTF-16) ceiling over CLAUDE.md + rules because
per-surface baselines can each be fine while the sum blows past the harness's own
warning total. Seyag's rules + repo CLAUDE.md measure ~26 KB — 17% of that
mirror (the full always-paid sum the tripwire watches, descriptions included, is
larger) — and the sum is already ratcheted per-surface; the ceiling would be
inert for
years at current sizes, and its hedge (it mirrors observed harness behavior, not
a documented contract) would need re-verification at the only time it could bind.

**Tripwire (council; scope and unit pinned per review round 2):** `--check`
always prints the tracked-instructions total — the FULL always-paid set (rules +
claude-md + descriptions), the same quantity the promoted ceiling would gate,
not the rules+claude-md subset — and emits a non-gating WARN at ≥60,000 UTF-16
code units. The v1 figure is computed by the Python measurement core as decoded
code points (astral characters count one where UTF-16 counts two — labeled an
approximation in the output); at promotion the ceiling switches to exact UTF-16
code units, matching what the harness sums.
*Promote-when*: the WARN fires in practice, or an adopter reports harness
memory-file warnings. At promotion (council, qwen's scope correction adopted):
the ceiling sums ALL always-paid surfaces (rules + claude-md + descriptions),
measured in UTF-16 chars to match what the harness sums — the Tzurot
CLAUDE.md+rules scope is already too narrow for seyag's surface set. A third
suggested trigger (bytes-per-token divergence) was declined as unobservable
without a tokenizer; the README proxy line (D3) covers the concern.

## What this deliberately does NOT do

- No token-based gating (tokenizer dependency; tokens are display-only).
- No skills-body gating (lazy-loaded, not always-paid).
- No README/hooks.json/components.tsv gating (not context).
- No docs-only fast path (Tzurot's hole came FROM one; seyag has none and gets none).
- No content rules — the ratchet gates SIZE only; editing discipline stays with
  the rules.
- No hook-injected-context gating in v1 (perimeter; first-use trigger recorded).
- No grace caps / CODEOWNERS in v1 (threat model stated; triggers recorded).

## Phasing

| Slice | Content | Notes |
| --- | --- | --- |
| A | `bin/lines-check` + `tests/lines-check.probe.sh` + canary/mutant set (D1) + baseline capture + README row | delegation unit; driver gates; the probe auto-joins CI |
| B | per-probe timeout in `run-probes.sh` + `probes.yml` `timeout-minutes` + canary (D6) | small, independent; after A |
| — | skill-eval disposition | recorded in this artifact (D5); no repo change |

## § Council record

Panel: 4 models briefed with identical adversarial text (2026-10-28); **4
answered** — `z-ai/glm-5.3`, `moonshotai/kimi-k3`, `deepseek/deepseek-v4-pro`
before the owner pass, `qwen/qwen3.8-max-0902` after it (its task outlived the
other three; its incremental findings were folded post-pass as engineering
refinements that touch no owner dimension — stated here so the sequencing is
honest).

**Adopted** (attributed):

- Grace-inflation bypass: the drift hash does not cover grace values; canary 5 +
  explicit threat-model line instead of a false mechanical gate
  (deepseek; kimi converged on reviewer-visibility).
- Description-extraction totality invariant + folded-YAML / missing-key /
  malformed-frontmatter canaries — under-extraction is the hollow-check's blind
  spot (kimi; named "the PR the ratchet exists to catch"; qwen extended to
  parse-count mismatch, covered by totality).
- Agent descriptions gated NOW, not at a second agent — the off-by-one
  (glm + kimi independently; qwen generalized to first-occurrence triggers for
  every new always-paid class — adopted).
- D6 kill model corrected: `-k`, process-group signaling stated accurately,
  default ≥5× parallel-measured with a floor + banner print + CI pin option,
  numeric validation, 124/137 exit contract with partial output preserved,
  portability note matching the run.sh pattern, hung-probe canary, synchronous
  probe contract (glm, kimi, deepseek convergent; glm corrected the group-signal
  fact deepseek misstated; qwen's process-tree pushes were already folded).
- D7 wording: D6 is a suite-contract change; `timeout-minutes` added to
  `probes.yml` (deepseek + kimi).
- `@`-import ban and nested-dir canary for measured files (kimi; glm's
  perimeter framing; qwen's import-resolution alternative declined in favor of
  the ban — seyag measured files carry no imports, so the ban is cheaper than a
  resolver).
- Perimeter section made explicit: hook-injected context, machine-local files,
  MCP schemas, with first-use triggers (glm's "the tax bracket is unmeasured").
- D5 rationale synthesized to both grounds + re-check triggers, and the
  97–213 ms figure labeled Tzurot-environment (glm + deepseek on the label;
  kimi on the triggers; qwen's wording "native listing removes enough of the
  discovery value that the remaining activation benefit is not worth the
  machine-wide latency" adopted into the owner-facing rationale).
- O1 tripwire: non-gating WARN at the promote threshold, self-observing
  (glm + kimi; qwen's richer aggregate report folded into the same line).
- Instructions-total printed on every `--check` (kimi; same fold as the tripwire).
- Working-tree measurement kept over blob measurement, with a `.gitattributes`
  eol pin (glm raised EOL/BOM; working tree is what the harness loads — the
  measured artifact — and the fleet is LF-only; recorded as a decision, not a
  dismissal).
- Migration-cost note for new surfaces (deepseek).
- Descriptions byte model: extracted-value bytes, not raw frontmatter line
  (qwen post-pass — the D2/D3 tension was real and is now stated).
- Shrink guard on refreshes (qwen post-pass: poisoned-baseline path).
- Safe traversal: regular files only; atomic baseline writes; schema validation
  with a dedicated exit code (qwen post-pass; Tzurot's parse-shape checks
  carried over and hardened).
- Fixture isolation canary (qwen post-pass; disjoint by construction, now
  proven).
- Audience section (qwen post-pass: maintainer vs adopter contexts stated).
- Ceiling scope at promotion: all always-paid surfaces, UTF-16 chars
  (qwen post-pass).

**Declined** (with reasons, no tombstones):

- `components.tsv` registration for the bin (glm) — bins aren't hooks; the fact
  was wrong, hook-wiring's bin-probe rule already covers it.
- Canonical greppable baseline format replacing JSON (kimi) — against house
  jq convention; fail-loud on absent jq is the house pattern.
- CI dry-run equality check (kimi) — breaks on the grace-absorbing flow (D7).
- Harness-behavior meta-probe (deepseek) — unimplementable from inside the repo;
  carried as the stated limitation + re-check trigger instead.
- Harness-version pinning in baseline meta (glm) — scope; the impl-version drift
  hash plus the stated limitation cover the class.
- Blob-not-working-tree measurement (glm) — the working tree is the paid
  artifact; the `.gitattributes` pin addresses the EOL mechanism.
- Rename to `size-ratchet` (glm) — cosmetic.
- Third O1 trigger, bytes-per-token divergence (deepseek) — unobservable without
  a tokenizer; the README proxy line covers it.
- CODEOWNERS on gate paths (qwen) — one effective reviewer today; promote-when a
  second maintainer lands (D7).
- Per-probe timeout manifests (qwen) — deferred with trigger (D6).
- Fail-loud on missing `timeout` binary (qwen, dissent recorded) — the house
  note-and-run-unbounded pattern keeps local runs working; CI always enforces.

**Split resolved without tiebreaker:** D5's rationale (glm/deepseek: cost-led;
kimi: premise-led; qwen sided with the synthesis) — the decision was unanimous
across all four, so the disagreement was wording, not a fork; both grounds are
stated and the emphasis question never reached the owner as a decision.

## Open calls

| # | Call | Status |
| --- | --- | --- |
| O1 | Instructions ceiling now vs deferred (D8) | CONFIRMED declined for v1 (owner): inert at ~26 KB vs a 147k mirror; WARN tripwire makes the trigger self-observing; promote-when the WARN fires or an adopter reports harness warnings |
