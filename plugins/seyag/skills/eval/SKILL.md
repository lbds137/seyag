---
name: eval
description: 'Design and run a measurement that settles a model, lane, tooling or working-style question: pre-register the question, arms, sample, metrics and decision rule before anything runs; record harness conditions per arm; blind-review comparisons; land a result doc whose retest triggers let a new release list every finding it invalidates. Use when adopting a model or lane for a role, when a new model lands in a tier and old guidance may not hold, when two routing skills disagree, when asked "which model should do X" and no recorded result answers it, and before any side-by-side comparison of models, lanes or styles is improvised.'
---

# Eval

An eval is a measurement bought to settle a decision, and it is only worth its cost with five parts kept intact: a question tied to a decision, a design fixed before the first run, evidence that can be re-read, a verdict allowed to say "cannot decide", and a recorded outcome with retest triggers. An eval missing any part produces an anecdote with numbers on it. This skill is INVOKED — by the session or the owner — before ad-hoc comparisons happen, not after.

## Before running (pre-registration)

Write the design down — in the result doc's own skeleton — and freeze it. Results are appended under it later and never edited into it.

1. **Question and decision.** What is being measured, and which line changes or doesn't because of it: a posture file's lane assignment, a skill's default tier, a hook's fate. An eval with no decision attached is curiosity, and is priced as such.
2. **Shape.** Pick one; do not force comparison machinery onto the others:
   - **Comparison** — which X for role Y. Arms run the SAME spec, from the same base, each in its own worktree; the sample's unit class and size are named (and the verdict is scoped to that shape); a failing arm gets exactly one feedback round, verbatim output, no other help.
   - **Measurement** — is X good enough. A baseline or threshold, a case set or corpus, and a sizing pass before any fan-out (count first, then divide).
   - **Lift (observational)** — did X change behavior. Mined from logs, no arms dispatched; the counterfactual is named or the claim is stated as a bound; the measuring script gets a positive control.
   - **Boundary suite** — does X follow its instructions as written. The case set is designed with the owner BEFORE it is written, and both failure directions are scored (false-pass and false-block).
3. **Arm conditions are part of the result.** Every arm records its harness: interactive vs headless, tools available, sandbox and read scope, wrapper or runner version, effort level, gates reachable or not, driver-capable vs headless-only, and commands the harness offers only to some roles (a first-party-only advisor command is a harness fact). An arm's number measures the model as that harness allows it at that version — never the model alone. A lane restricted to certain roles is a harness property of its arms.
4. **Harness control arms.** When an arm runs in a restricted harness, add a same-model control arm where one exists (the same model through an unrestricted harness). For a unit class the harness does not bias — a self-contained task with no user in the loop — a headless run of an interactive product should match its interactive twin, which is what makes the pair a clean control. Holding the model fixed isolates the harness penalty, which a cross-family comparison otherwise confounds with model differences. Where billing route is the only difference, add the cheap expected-equal sanity arm.
5. **Metrics, scoring and the decision rule — fixed before results.** For comparisons: one blind reviewer, fresh context, label order randomized and recorded apart from the brief, ONE review pass per comparison — scores compare only within a pass (reviewer noise between passes is routinely 1–2 points on identical diffs); the pass's own noise band is measured by re-scoring one diff inside it, and a gap smaller than that band decides nothing; severity weights stated; a decision rule that can output "cannot decide", with what would decide it.
6. **Gate-proof mutation (comparisons).** A comparison's design names its gate-proof mutation before any arm runs: one concrete defect in a class the metric or blind reviewer must catch, cut strictly inside one arm's artifact, to be injected after the arms run and before the verdict. Freeze what a miss means with the decision rule: if the metric or review pass misses the injected defect, it cannot decide on that class, and the verdict is bounded and says so.
7. **Cost capture per arm.** Meter deltas, dollars, quota points, wall seconds — before and after readings; shared meters make every delta an upper bound, and the doc says so; aborted tries are counted too. Review and orchestration costs are recorded apart from arm costs, never inside an arm's mean.

## Running

One arm at a time; nothing is pushed mid-eval; the best passing arm's branch is kept and the others are removed only on the owner's yes. Arms run through the project's own gates where the unit class has them — and an arm that cannot reach its gates records that as an arm condition, with what the gate would plausibly have caught marked as inference. The orchestrator or measuring session edits nothing itself. The dispatch machinery itself (specs, worktrees, feedback rounds, transfer) is the `delegation` skill's; this skill fixes what is measured, not how workers are run.

## Review packet

For a comparison, the orchestrator — never an arm — assembles one blind-review packet for a single review pass: every arm's full diff, randomized arm labels with the label-to-arm mapping recorded on disk apart from the reviewer's brief, the frozen severity vocabulary and weights, and the named anchor arm (for noise-band re-scoring or a fresh pass's tie-back, per Verdict). The reviewer sees the spec and the anonymized diffs in one pass and nothing identifying which model or harness produced which arm.

## Gate proof

For a comparison, before the verdict, prove the gate can fire: inject the frozen gate-proof mutation into ONE arm's copy (never both, never the anchor), re-run the metric or review pass element that must catch it, record both the clean and mutated runs in the result doc, and restore the copy. A mutation the gate fails to catch is a result, not a failed eval — the verdict reports the gate as blind to that defect class and bounds its conclusion accordingly. Never let the mutation reach a pushed branch, a transferred tree, or a second pass's inputs.

## Verdict

Apply the frozen rule to the recorded numbers and say which side each number falls on. Failures are quoted verbatim with their causes; inference is marked as inference, including "the gate would plausibly have caught this". "Cannot decide" is a real verdict — it names the blocker (sample too small, gates unrunnable, noise band larger than the gap) and the condition that would reopen the question. Score differences inside the pass's measured noise band decide nothing. An arm that lands after the pass ran joins a FRESH pass that re-scores one stable arm as an anchor; it still compares only within that pass. Scores in one result doc are never compared with another's — a question spanning two docs is a new eval with both as arms.

## Result doc

The deliverable, written even when the verdict is "cannot decide". Skeleton:

> Question → decision it drives → date → arms with harness conditions each → sample and unit class → metric, scoring, decision rule (as frozen) → results, failures and retries → scope (what this result covers; what it deliberately doesn't) → verdict → **decision taken** (the exact line that changed, or didn't, and where it now reads) → **retest triggers**.

Retest triggers are concrete and checkable: a new model in the tier, a harness or wrapper version change for any arm, an expiry date, or a named observable crossing a threshold. Read alone, the trigger lines must let a new model release list every finding it invalidates.

## Registry

Results live in a per-machine registry whose location is machine config (an env var or config file); where none is configured yet, the adopting project names one in its own config before the first result lands. A registry entry is an index row — question, date, verdict, decision taken, triggers — pointing at the result doc, which stays whole. Posture, rule and skill lines that a result set cite the registry entry they were set from. Before answering any "which model for X" question, read the registry first: an entry whose triggers have fired is stale, and says so in its own terms.

## Boundaries

- Comparisons and measurements of models, lanes, tooling and working styles: this skill.
- One strong opinion on a single knot: the `advisor` skill, not an eval.
- Which lane should drive a session: the `driver-choice` skill; an eval result is one of its inputs, never a substitute for the meter reading it requires.
- A product repo's own quality suites keep their own runners (measurement shape applies; the spine — pre-registration, quoted evidence, honest verdict, triggers — is the shared part).
