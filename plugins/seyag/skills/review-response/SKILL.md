---
name: review-response
description: 'PR review-response iteration: classify each finding by EDIT SHAPE (trivial → auto-apply as a test-gated fixup commit; semantic → decided when engineering-only, ASK when it carries a product/UX, user-visible, schema, spend, data-rights, or security dimension, changes an existing test assertion, or changes an async boundary or external contract), check reviewer-vs-agent signal conflict, batch-present the four sections, step back at ~3 automated rounds (rule of thumb), and hard-cap at ~6 — hand off to a fresh context or the owner. Invoke as /review-response (seyag:review-response) the moment a claude-review or human reviewer posts findings on a PR — before applying anything. Also invoke when the PR''s claude-review check quota-walls (fast is_error failures): run the rule-0 substitute before anything else.'
---

# Review-Response Iteration

When `claude-review` or any PR reviewer returns findings, the agent follows this procedure **instead of** asking the user about every item. Run it the moment findings land, as part of the project's own PR-monitoring/ship flow, before anything is applied.

## Why this procedure exists

This procedure shifts trivial chores to auto-apply (under tight constraints) and engineering-only behavior changes to reported decisions, while preserving explicit approval for anything with a product/UX, user-visible, schema, spend, data-rights, or security dimension, and for any change to an existing test assertion, an async boundary, or an external contract.

**Key design principle**: `claude-review` is the same model family as the agent. It has no special epistemic authority. When the reviewer's severity label conflicts with the agent's own classification, that's **uncertainty**, not an override opportunity in either direction. The safe resolution is always ASK.

## The rules

### 0. Reviewer unavailable: the quota-wall substitute

When the PR's `claude-review` CI check cannot run because the Anthropic
weekly quota is exhausted — the signature is fast failures with
`is_error: true` on the check result (typically ×2–3) against the week meter
at its cap — the gate is not dead, the reviewer is. Owner ruling
(2026-10-02): substitute, don't loop.

- **Substitute reviewer**: a fresh-context review subagent on the current
  lane — never the authoring session, read-only, adversarial. Its report
  ranks findings BLOCKER / SHOULD-FIX / NIT and carries an intent-match
  paragraph (what the diff is FOR, in the reviewer's own words, so a
  mismatch is itself a finding).
- **The dispatching session posts the verdict as a comment on the PR
  itself** — the audit trail lives on the PR, not in session chat, and the
  read-only subagent cannot post it — stating explicitly that it
  substitutes the quota-walled `claude-review`, naming the head SHA it
  reviewed, and never carrying an `@`-mention (`@claude` in a PR comment
  fires the repo's Claude workflow — the loop this rule bans).
- Its findings then process under rules 1–4 like any reviewer's
  (SHOULD-FIX reads as "medium / blocking" in rule 2's table, NIT as
  "nit"), and the substitute verdict counts as a round under rules 5/5a.
- **Merge stays gated on the owner's explicit word.** A clean substitute
  review lets her override the block early; it never satisfies an automerge
  "review passed" condition on its own.
- **Never re-trigger the failing check in a loop.** After the weekly reset
  (~Sun 02:00 ET) the dispatching session re-runs the failed claude-review
  job exactly once (`gh run rerun --failed`); if it walls again, the
  substitute verdict plus her word is the ship path — with one substitute
  re-run on the new tip first if commits landed after the reviewed SHA.

### 1. Classify the edit shape first

Before applying any review suggestion, classify the concrete diff the agent would produce. Match against the whitelists in "Edit-shape whitelist" below.

- Matches a **trivial-shape** whitelist entry → eligible for auto-apply (continue to rule 2)
- Matches an **explicit non-trivial** entry → semantic → route by the second axis below (continue to rule 2 first; a decided item needs rule 2's no-conflict result)
- Matches neither → default to semantic-shape → route by the second axis below (continue to rule 2 first)

**Unclassifiable defaults to semantic.** The whitelist fails closed.

Line count is not a classifier. A one-line regex-flag change is semantic; a 20-line scope-local rename is trivial.

**Second axis — who owns the decision.** A semantic finding whose options differ only on engineering grounds is DECIDED by the agent: apply it under rule 3's test gate and report it under Auto-applied tagged `[semantic:decided]`, with the reasoning and the option not taken. **Asks** is reserved for findings with a product/UX, user-visible, schema, spend, data-rights, or security dimension. Changing or deleting an EXISTING test assertion is always an Ask, never decided — it is a spec change, and seyag core.md § Safety forbids modifying a test, lint rule or guard just to get past it. Two explicit non-trivial shapes are always an Ask too: an **async boundary change** (an ordering or race bug often has no test to break, so rule 3's gate cannot catch a wrong decision) and an **external contract change** (the other side of the contract is outside this diff). The other four shapes (regex, operator flip, null guard, default value) stay decide-eligible because each changes a value-level result that one input/output test pins, so a decided fix that adds that test puts it under rule 3's gate. This boundary fails closed: if a dimension might be present, it is an Ask. The round report still shows every decided item, so the owner can reverse any of them.

### 2. Check for signal conflict

Compare the reviewer's severity label against the edit shape from rule 1:

| Reviewer says                                                                                                 | Agent classifies | Result                                                                                                               |
| ------------------------------------------------------------------------------------------------------------- | ---------------- | -------------------------------------------------------------------------------------------------------------------- |
| "nit / minor / not blocking"                                                                                  | trivial          | **Continue** (aligned)                                                                                               |
| "nit / minor / not blocking"                                                                                  | semantic         | **ASK** (disagreement)                                                                                               |
| "medium / blocking / must fix"                                                                                | trivial          | **ASK** (disagreement)                                                                                               |
| "medium / blocking / must fix"                                                                                | semantic         | **DECIDE or ASK** (aligned on severity — rule 1's second axis: engineering-only decides, owner dimension asks)       |
| Self-dismisses ("actually fine")                                                                              | Agent agrees     | **DISMISS** (note in summary)                                                                                        |
| Self-dismisses                                                                                                | Agent disagrees  | **ASK** (with dissenting analysis)                                                                                   |
| Scopes a finding by origin ("pre-existing" / "not a regression" / "not introduced here")                      | Any              | **MERITS JUDGMENT** (origin ≠ verdict; see below)                                                                    |
| Contradicts own round-(N-1) call on same item                                                                 | Any              | **DISMISS** (cite prior round's rationale)                                                                           |
| Defers to future work in THIS file/diff ("next time you touch this")                                          | Any              | **DO IT NOW** (colocated and small by construction — filing costs more than fixing; see below)                       |
| Defers to a named cross-file batch ("next X pass/sweep", "worth a follow-up PR")                              | Any              | **FILE THE BATCH** up the granularity ladder — track the pass, not a row awaiting it (see below)                     |
| Defers action on a named OBSERVABLE ("monitor over time" / "if the retry count grows" / "when p95 exceeds X") | Any              | **BACKLOG CANDIDATE** (an observable must be named; pure-aesthetic deferrals → Dismissed; tracked per the project's tracking surface) |

**Any disagreement between reviewer and agent defaults to ASK.** Neither side has special authority, and uncertainty is the honest state when signals conflict.

**Docs-only findings resolve to the agent.** When the edit shape is documentation-only (comment/docstring fix or documentation-only addition) and the subject carries none of the owner dimensions, a severity-label conflict is an engineering call, not an Ask: decide on the merits and report it in the round summary (apply → Auto-applied; decline → Dismissed, with the reason). Owner ruling (2026-10-09): docs shapes have no owner dimension to protect, so the disagreement default does not apply to them.

**Origin-language is not a disposition.** "Pre-existing," "not a regression," "not introduced by this PR," and "consistent with existing code" are claims about where a behavior came from, not whether it is correct — a reviewer using them is scoping blame, not issuing a verdict, and such phrasing must not be pattern-matched to the self-dismissal rows above. A finding scoped by origin routes to a merits judgment landing on exactly one of: (a) **fix now** (ride-along or follow-up PR), (b) **backlog entry** with a promote-when trigger, or (c) **correct-as-is** with the technical argument stated in the round summary (e.g. "client-side abort can't interrupt the executor-thread inference, so cancellation buys nothing" — a real reason, where "it was already like that" is not). "Pre-existing" may never be the operative reason in any disposition (seyag core.md § Fix what you touch, file what you find — a known defect you are not fixing now always gets an entry, never a silent pass). Second-hand adoption counts as the same failure: laundering a dismissal through the reviewer's framing ("reviewer says it's not a regression") is identical to saying it yourself.

**Where a deferred finding goes** — decided by **what would have to happen for it to be picked up again**:

| The reviewer's deferral rests on...                                                                          | Disposition           |
| ------------------------------------------------------------------------------------------------------------ | --------------------- |
| Future work in **this file or diff** ("next time you touch this")                                            | **Do it now**         |
| A **named batch across files** ("next tooling-DRY pass", "next `.claude/rules` PR", "a follow-up sweep")     | **File the batch**    |
| An observable outside our control (a user report, a metric threshold, a provider change, a feature arriving) | **Backlog candidate** |
| Nothing — taste, or a self-dismissal ("actually fine", "could be cleaner someday")                           | **Dismissed**         |

**Do it now** is the disposition that defaults wrong without this rule. The finding is also, by construction, **small and colocated** — the reviewer named this PR's own code — so the file is already open and the fix is usually smaller than the row describing it. Fix it here.

Do-it-now sends the finding back through **rule 1**, not around it: a trivial-shape fix auto-applies under the test gate and reports under Auto-applied; a semantic-shape one routes by rule 1's second axis, decided or asked. This disposition changes the destination, never the safety rails.

**A rejected do-it-now does not evaporate — re-route it.** When the user rejects the fix (or a trivial-shape one fails its test gate and escalates to an Ask that's then rejected), the finding has been neither fixed nor tracked, and do-it-now filed nothing by design. That is the only path in this table that can end in _neither_, which is exactly the silent-loss this rule exists to prevent. On rejection, **default to backlog candidate** and report it under Backlog candidates in the same round summary. Re-route to **file the batch** only when the rejection itself reveals the finding belongs to an already-named cross-file pass — the ordinary case cannot, because do-it-now's own classifying condition is _this file or diff_, and file-the-batch is for a pass rather than a place. The user rejecting _this fix, now_ is not a decision to forget the finding — only an explicit "don't track this either" is, and that reads as **Dismissed**.

**File the batch** is the one to reach for when the reviewer named a _pass_ rather than a _place_. "Next tooling-DRY pass" describes work across files this PR never opens — so "colocated and small" is false, and do-it-now would be wrong. But a row waiting to be noticed during that pass is equally wrong: nobody rediscovers it. **Track the pass itself** — one entry on the project's tracking surface (backlog/TODO file, tracker, role file, or dispatch ledger — core.md § Everything not done gets a disposition) that owns the whole batch — and let this finding be one of its members, at the granularity of the pass: one PR's worth of sweeping is a single tracking entry; a sweep that needs its own phased rollout gets its own theme entry. Same disposition for a finding that's simply too big for this PR (needs a migration, crosses a service boundary, would double the diff) — those were never follow-up rows.

**Grep for the batch before creating it.** Different PRs surface the same pass repeatedly ("next tooling-DRY pass" appears from whichever file the reviewer happened to be reading), so a rule that files a fresh entry each time reproduces the fragmentation it was written to fix, one rung higher. Search the project's tracking surfaces for the pass by name AND by the module it sweeps; if a batch entry already owns it, **add this finding as a member** and say which entry you joined. Only create a new one when the search is genuinely empty.

**Backlog candidate** is the honest deferral. File it on the project's tracking surface at the granularity-appropriate destination, capturing both the concern and the criterion. (A promote-when trigger is optional metadata on the item, never a filing gate — the disposition is honest because the criterion is written down, not because a date was promised.)

**On a process-work PR, a low-priority backlog candidate is not filed as a task.** The residue of hook, skill, rule, tooling, and CI PRs (substance under `.claude/`, scripts, workflows, bookkeeping riding along, no runtime or test-infra file touched) can carry its disposition in the PR body instead — fixed here, declined with the technical reason, or filed only when it earns the weight. In the round summary it lands under Backlog candidates tagged `[residue]` with that disposition, so the routing stays checkable; the fails-closed owner-call boundary from core.md § Everything not done gets a disposition applies unchanged, and "if declining feels wrong, file it" is the signal to file.

**Dismissed** closes the matter; note it in the summary and move on. A reviewer self-dismissal ("non-issue," "current is correct") that the agent agrees with has no trigger, and neither does a vague preference with no named event.

**Reviewer self-contradiction across rounds**: when round-N reviewer reverses its round-(N-1) stance on the same item (e.g., round 3 says "drop the `?? ''` as unreachable," round 4 says "add `?? ''` back for defensive typing"), the reviewer is not authoritative on its own prior disagreement. Dismiss and cite the earlier round's reasoning in the summary. Don't ping-pong. This is distinct from genuine new information surfacing — a round-N reviewer observation that _builds on_ round-(N-1) (adds context, corrects an error) is normal; a direct reversal on the same fact-pattern is noise.

### 3. Apply with test-suite gating

For items that passed rules 1 and 2 with no conflict — trivial-shape, or semantic and `[semantic:decided]` under rule 1's second axis:

1. Apply the edit as a `git commit --fixup=<target-sha>` commit. `target-sha` is the original commit that introduced the code being changed.
2. Run the package-level test for the modified file.
3. Tests pass → keep the fixup commit.
4. Tests fail → **escalate to ASK immediately**, with the test failure output attached. A trivial-shape edit that breaks tests is the signal that the whitelist mis-classified it, and a `[semantic:decided]` edit that breaks tests is the signal that the finding was not engineering-only; escalation preserves the safety net.

**Riders are caught at review, not at commit.** A fix that ADDS code rather than changing it gets systematically less scrutiny than planned work — "one clause" / "~10 lines" is exactly the size that skips the checks a planned change gets.

The three questions below are **review-side** — what a flagged rider is usually failing, not a ritual to recite before committing; at commit time the rider is already written and the cheap answer is "it's fine".

- (a) Does the addition need its own test? (New function/branch → yes by default; "it's small" is not an exemption.)
- (b) Does it stale a comment or doc elsewhere — including schema doc comments and files the fix doesn't touch?
- (c) Does moving code between files change what a coverage or mutation gate measures? (Extraction can drop a module below a per-file gate that the old file's average was hiding.)

Rule 3's test gate catches breakage; these catch absence.

**Removing a safety mechanism to satisfy a review finding gets the FULL
argument, written against the final diff.** When a fix removes a transaction,
lock, guard, or retry as "unnecessary", check the justifying argument against
the code that will actually run, line by line — not the code the argument
pictures — and write the justification AFTER reading the final diff, never
before. Pin the property the argument rests on with a test where one is
assertable.

**Fixup commits stay visible through review; they autosquash once, right
before merge.** Keep pushing them as-is between rounds — do not `rebase
--autosquash` and do not force-push per round. Fixup commits sitting on the
branch as `fixup! <target message>` are fine through review; reviewers and CI
can read them, and a force-push per round costs a full CI + review re-run
every cycle and drops reviewer inline-comment anchors. **Critical: `gh pr
merge --rebase` does NOT autosquash fixup commits.** It runs `git rebase`,
not `git rebase --autosquash` — fixups land on the base branch with their
`fixup!` titles intact and clutter `git log` permanently. Autosquash
deliberately, once, at the end (how, and what the branch's commit messages
need by then, is the project's own workflow — this skill owns the
review-response routing, not the fixup-commit cycle's mechanics).

For items escalated to ASK: do not apply. Skip to rule 4.

### 3a. Review-round fixes are a dispatch

seyag:delegation already owns this: a review round's fixes are batched into ONE worker dispatch, the worker applies and gates, the driver reads the diff, and the round cap there matches this skill's. Follow that skill; this skill adds nothing to it. (Dedupe port: the source skill carried the dispatch section in-skill; the seyag version points at delegation, the single owner of the dispatch model.)

### 4. Batch-present at end of round

After processing all review items in a round, present one consolidated message to the user. The format is prescribed for scannability and to make the round-4 convergence check mechanical:

```
## Round N findings

### Auto-applied (M items, M fixup commits)
  [trivial:rename]     parseInput → parseUserInput  (src/handler.ts:22)
  [trivial:import]     remove unused 'Buffer'       (src/utils.ts:3)
  [trivial:comment]    fix typo in JSDoc            (src/types.ts:47)
  [do-it-now:trivial]  drop the dead `retries` param (src/queue.ts:88)
                       reviewer deferred to "next queue touch" — that's here
  [semantic:decided]   guard the optional cache hit (src/cache.ts:40)
                       engineering-only; null guard over a non-null assertion — a miss falls through to the fetch

### Asks (K items)

#### 1. [semantic:control-flow] Replace early-return guard with if/else
   Reviewer: "This endpoint should reject unauthenticated requests early."
   Agent analysis: Agree. Proposed diff:
     - if (!auth) return 401
     + if (auth) { ... } else { return 401 }
   Approve / Reject / Modify?

#### 2. [semantic:logic] Change `&&` to `||` in guard
   Reviewer (nit): "I think this should be ||"
   Agent analysis: This is a truthiness flip — escalating per signal conflict.
   Approve / Reject / Modify?

### Dismissed
  [reviewer self-dismiss]  "Nit about naming — actually current is fine"

### Backlog candidates
  [future] Reviewer suggested follow-up for sort-stability invariant.
  [batch]  Duplicated retry preamble across ~6 tooling commands
           → joined the owning batch entry on the tracking surface, this finding is member 1
```

The four sections (Auto-applied / Asks / Dismissed / Backlog candidates) MUST appear even when empty, so the round structure is consistent and round count is visibly mechanical. The dispositions added by rules 1 and 2 report inside these four, not beside them, and each is **tagged so the routing is checkable rather than asserted**:

- A **decided** item (rule 1's second axis) lands under Auto-applied tagged `[semantic:decided]`, with the reasoning and the option not taken, so the owner can reverse it.
- A **do-it-now** item lands under Auto-applied or Asks depending on its shape, tagged `[do-it-now:trivial]` / `[do-it-now:semantic]` with the reviewer's deferral quoted — that pairing is the whole justification for fixing it here instead of filing it, so it belongs in the report.
- A **file-the-batch** item lands under Backlog candidates tagged `[batch]`, naming which batch entry now owns the pass.
- A **residue** item (process-work PR, low priority) lands under Backlog candidates tagged `[residue]` with its PR-body disposition — declined with the reason, or filed with the sentence that earns it.

**A correction EDITS the original sentence; it does not annotate it.** A round
that falsifies a claim usually produces two edits — the code fix, reported
above, and the claim itself, which is easy to leave behind. Appending "update:
actually…" under a wrong sentence in a PR body, a comment, or a doc leaves that
sentence leading the document, and the lead is what the next reader takes away.
Rewrite it. (General to any corrected claim; it sits here because the round
summary is where the falsification lands.)

**Never present a raw unified diff.** Categorization IS the presentation — it lets the user bulk-confirm the auto-applied group and focus attention on the semantic asks without having to visually separate them.

### 5. Step back at ~3 automated rounds

**This is a rule of thumb, not a hard stop** (owner call). Three rounds is where a loop usually stops being refinement — but a round-4 finding that is genuinely substantive (it makes a claim in the diff false, it names a real defect) gets FIXED, not deferred to a menu. Use judgement, and say in the round summary that the guideline was passed and why.

When a PR reaches **round 4 without user intervention** and the remaining items are nits rather than defects, stop and present consolidated status:

```
PR #N has completed 3 rounds of review-respond. Remaining unresolved items:

1. [semantic:control-flow] ... (raised round 2, still open)
2. [semantic:contract] ...     (raised round 3, new)

Each round's fixes have surfaced new findings. Options:
- Merge as-is (remaining items → the project's tracking surface)
- Rewrite the PR to address remaining items differently
- Review the loop — maybe the PR scope is wrong
```

Long review loops are usually a convergence failure rather than genuine quality refinement, and the user is better positioned than the agent to decide whether to merge, rewrite, or abandon.

The cap resets on user intervention. **"User intervention" means the user explicitly answered an ASK, approved/rejected an auto-apply call, or directed the agent to take a specific action.** Merely reading a round summary without a response, acknowledging with a thumbs-up emoji, or a "continue" that doesn't address an open ASK does not count — those are light-touch signals the user is still present, but the decision-fatigue pressure the round cap exists to bound is about _active_ user engagement, not _passive_ presence. When in doubt: if the user said something that would differently route an item (answered an ASK, amended a fix, told the agent to do X), reset the counter; if they didn't, don't reset.

### 5a. Hard cap at ~6 rounds: hand off, don't keep iterating

The soft guideline above governs rounds where the residue is nits. **This cap
governs everything, substantive findings included**: when a PR reaches **round 7 without user intervention** (i.e., past ~6
automated rounds), stop iterating in the current context — even on a finding
that would otherwise be FIXED under rule 5. Instead, hand off:

- **Spawn a fresh-context implementer** with the open findings plus the round
  history as its spec (the branch state carries the code; the spec carries the
  intent), and review its diff as any worker's — the seyag:delegation
  dispatch; or
- **Escalate to the owner** with the round ledger when the loop's shape suggests
  the PR's scope is wrong rather than its execution.

Why a hard cap: past ~6 rounds the iterating context generates the defects it then fixes, because its checks inherit the assumptions accumulated across its own rounds. A fresh context is the countermeasure, not more care in the stale one. Same reset-on-user-intervention rule as the soft guideline.

## Edit-shape whitelist

The whitelist loads with this skill. Entries are evaluated in order. The user may extend either list as they develop priors about the agent's judgment.

### Trivial shapes (auto-apply eligible, subject to test gate)

- **Rename within scope** — variable or parameter rename with zero call-site changes outside the current file, no exported-symbol change, no file rename
- **Unused import removal** — remove an import statement where the imported symbol has zero references in the file (IDE-detectable)
- **Comment or docstring fix** — edits to `//`, `/* */`, JSDoc blocks, or Python docstrings that don't touch any code tokens
- **Type annotation addition** — adding `: T` to a variable, parameter, or return type; adding a type guard that only narrows for the compiler; **not** type changes that alter runtime control flow
- **Formatting per linter** — apply `prettier` or `eslint --fix` output verbatim; no manual edits
- **String literal typo fix** — text-content correction in a regular string literal; **not** inside regex patterns, SQL queries, shell commands, URL paths, or any other language-in-a-string context
- **Test-only addition covering this PR's own behavior** — adding `it()`/`describe()` blocks to a `*.test.ts` that exercise behavior THIS PR introduced or changed, with zero production-file edits. Safe because it cannot alter runtime behavior and the test gate proves the assertion holds. **Excludes**: changing or deleting an EXISTING assertion (that's a spec change — always ASK, never `[semantic:decided]`), adding a test that requires a production edit to pass (the production edit is the real change — classify THAT), and touching the project's pinned known-gaps/baseline files (widening those is never a trivial edit). Reviewers routinely flag missing coverage on new gating behavior; asking every time is pure decision fatigue.
- **Documentation-only addition** — adding content to backlog files, release notes, `CHANGELOG.md`, `README.md`, or any file under `docs/`. Includes new sections and new entries, not just fixes. **Excludes** edits to `.claude/rules/*.md` and `.claude/skills/*/SKILL.md`, which are load-bearing constraints/procedures — treat those as semantic-shape even though they're markdown. Adding to a documentation file that this PR didn't otherwise touch is still allowed under this shape; "scope expansion" only applies to CODE files (see below).

Implicit rule: "touches a file not in the PR's diff so far" is NOT a blocker for auto-apply as long as the edit is one of the trivial shapes above. The blast radius concern comes from the _shape_ of the change, not the _location_. A backlog-file addition to a file the PR hasn't touched is still a trivial-shape edit; a logic change in an untouched code file is still semantic-shape.

### Explicit non-trivial (always semantic regardless of surface simplicity — async boundary and external contract changes always ASK, the rest route by rule 1's second axis)

Each of these is flagged because the shape seduces the reader into thinking "this is just a small change" when it alters runtime behavior.

- **Regex pattern or flag change** — including `/g`, `/i`, `/m`, `/s`, capture-group changes, alternation changes. A regex is a language, not a string.
- **Truthiness or comparison operator flip** — `&&` ↔ `||`, `==` ↔ `===`, `!=` ↔ `!==`, `!x` ↔ `!!x`, `x ?? y` ↔ `x || y`, any nullish-coalescing change
- **Null or undefined guard addition** — adding `if (x) return`, `if (!x) throw`, `x?.y` where none existed. Even when it looks defensive, it changes runtime behavior.
- **Async boundary change** — adding or removing `await`, `Promise.all`, `Promise.race`, `.catch`, any timing-sensitive construct
- **Default parameter value change** — flipping a boolean default, changing a numeric threshold, adding a required param
- **External contract change** — API endpoint shape, HTTP header, request/response schema, env var name, event payload, emitted log structure (log parsing counts as contract)

### Extending the whitelist

When the user observes the agent making a category of change it handles well, add it to **Trivial shapes** with format:

```markdown
- **[shape name]** — [precise definition, including explicit non-inclusions] — [why this shape is safe to auto-apply]
```

When the user observes a mis-classification the agent should have avoided, add the specific shape to **Explicit non-trivial** with the mis-classification incident noted.

Keep each entry self-contained so an observer can verify a candidate diff against one entry without reading the full file.

## Checklist for the agent

Before each round's consolidated message:

- [ ] If the claude-review check failed with the is_error quota-wall signature, the substitute review ran and its verdict comment is on the PR (rule 0) — before any findings processing
- [ ] Every review item classified against trivial / non-trivial / unknown (rule 1), and every semantic item routed by decision owner — `[semantic:decided]` only when no product/UX, user-visible, schema, spend, data-rights, or security dimension exists and no existing test assertion, async boundary, or external contract changes
- [ ] Every auto-apply candidate checked against reviewer label for signal conflict (rule 2)
- [ ] Every "no action now" item routed by what would reopen it — Do it now (this file/diff) / File the batch (a named cross-file pass) / Backlog candidate (a named observable) / Dismissed (nothing) per rule 2's deferral rows; a Do-it-now item re-enters rule 1 and lands under Auto-applied or Asks; on a process-work PR a low-priority Backlog candidate becomes a `[residue]` line in the PR body instead of a task
- [ ] Every origin-scoped finding ("pre-existing" / "not a regression") given a merits disposition — never Dismissed on origin alone (rule 2's origin-language row)
- [ ] Every auto-applied fixup commit has a green package-level test run (rule 3)
- [ ] Round-N message contains all four sections, even empty ones (rule 4)
- [ ] If this is round 4+, consolidated status menu presented instead of another iteration (rule 5)
- [ ] If this is round 7+, findings handed off to a fresh-context implementer or the owner instead of fixed directly (rule 5a)

## Relationship to the rules

- **The merge gate is the project's own ship flow.** This procedure governs iteration _before_ that gate; nothing here loosens it.
- **seyag core.md § Safety** ("Never modify a test, lint rule or guard just to get past it") remains in force. The test-suite gate in rule 3 fails closed — a trivial-shape edit that breaks tests is escalated, not covered up by modifying tests.
- **seyag core.md § Fix what you touch, file what you find / Everything not done gets a disposition** governs where every deferred, rejected or dismissed finding lands — this skill's dispositions route into that surface, and none of them may end in _neither_.
- **seyag:delegation** owns the dispatch of review-round fixes (rule 3a) and the fresh-context handoff at the hard cap (rule 5a).
- **The quota-wall substitute (rule 0) is the owner's standing ruling (2026-10-02)**, exercised live on a parked PR before this section existed: the substitute verdict substitutes the reviewer, never the merge gate.
