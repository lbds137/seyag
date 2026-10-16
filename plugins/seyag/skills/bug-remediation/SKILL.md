---
name: bug-remediation
description: 'The recurring-bug remediation protocol: runtime evidence, root cause, a diagnosis ledger before state-changing action, an exhaustive sweep of the bug''s class, a regression test that fails before the fix, and a structural guard. Use when a bug recurs, a "fixed" class regresses, the owner says a failure "keeps biting", or at the FIRST fix of a bug on one of several parallel flows (create/edit/view/delete, one of several similar commands or scripts), to sweep the siblings before calling it fixed.'
---

# Bug Remediation

Under-remediation recurs in a fixed shape: a symptom patch on the one visible instance, a mocked unit test, and the class comes back. The six steps run in order; skipping one is how the bug returns.

It also fires at the **first** fix of a bug on one of several parallel flows (a create/edit/browse/delete family, sibling commands, copies of a script). Before declaring it fixed, sweep every sibling for the same class, and label the claim code-read-only until a runtime check confirms it. Waiting for the recurrence costs a round trip the sweep avoids.

## 1. Runtime evidence first

- Reproduce, or capture the failing observation: a log line, a trace, a failing test. Never fix on a mechanism you only read in code; "code-reading suggests X" is a hypothesis until a tool confirms it (core rules § Reading code is not runtime verification).
- If the observation can't be captured today, ship the one diagnostic that produces it as its own commit and stop. The fix waits for the observation.
- Exhaust the query space before saying the data doesn't exist: an empty result indicts the query first (core rules § Lossy steps are for known output shapes).

## 2. Root cause, not band-aid

- Not final answers: symptom patches, instrumentation-only "fixes", graceful degradation that hides the failure, retry-until-it-works. They may ship as stopgaps; the item stays open until the mechanism is named and closed.
- The tell of a band-aid: the fix's explanation describes the symptom path, not why the state arose.

## 3. Diagnosis ledger before state-changing action

- Name the hypotheses H1, H2, ... with (unconfirmed) until a probe settles them.
- Before the first state-changing action on a shared path (a service restart, a
  config reset, a deploy, a peer ping that triggers a restart), run the cheapest
  probe on the far side of the link: the raw frame, an incognito client, stderr
  not discarded.
- Only a discriminating result may drop "(unconfirmed)" in any message.

## 4. Exhaustive class sweep

- Name the class ("every caller that builds this by hand", "every copy of this predicate", "every consumer of this field") and enumerate its members **deterministically**, with the project's own tools: a symbol index or export listing, the dependency graph, an AST or structural search, schema introspection. A sampled grep misses the last caller and the drifted copy. When grep is the tool, positive-control the pattern on a member you know exists (core rules § Positive-control a pattern).
- Sibling paths are part of the class: failure path, second attempt, mid-sequence error, the other enum value, the other locale, the other surface — each gets a test or a recorded reason its absence is correct.
- Fix every member in the same change, or file each unfixed member as its own tracked item before closing. Put the enumeration method and the full member list in the PR or commit body, so review can check the sweep and not just the diff.
- If the class exists because logic is duplicated, consolidation is part of the remediation: see the `reuse-scout` skill.
- **Sweep the class's tests too, and hold the ones you didn't write to step 5's bar.** An existing test for a member is not coverage until it's shown to fail on the pre-fix code. A fixture can be well-formed and never reach the bug (inputs on the wrong side of the trigger, one below the threshold, a shape the buggy branch never sees); it then passes before and after and reads as protection while giving none. For each member, name the test that covers it. A member with no test is a step-5 obligation, not a tracked item. The canary is cheap: back the fix out (once when the class was fixed in one change, else once per fix commit), run the whole set, and every test still green was measuring nothing.

## 5. Regression test at the right tier

- The test must fail on the pre-fix code. State which tier and why: a bug at a boundary between components needs a test that asserts what crosses that boundary, not a unit test that mocks the very seam it should verify.
- If the bug survived because coverage was green but blind, say so and fix the blind spot rather than adding one more green test beside it.

## 6. Structural guard

- Ask the three questions from core rules § Fix recurring failures structurally: a rule, a skill step, or a hook/CI check? For code classes, prefer an invariant the build enforces (a manifest test, a budget constant, a lint or guard check, a parity test) over documentation.
- A remediation with no recurrence blocker is incomplete. If nothing structural fits, record why in the PR or commit body.
- A new or changed hook is replayed against local session logs (`tests/replay-hook.sh <hook> [--since N]` for a Bash-matching hook, `tests/replay-stop-hook.sh` for a Stop hook) and the blocked set sampled before it ships; a false-positive rate you can't state is one you haven't measured.

## Closing checklist

- [ ] Runtime observation captured (or the diagnostic shipped and the item parked)
- [ ] Mechanism named; the fix explains the cause, not the symptom
- [ ] Hypotheses numbered; a discriminating probe ran before any state-changing action on a shared path
- [ ] Class enumerated deterministically; every member fixed or tracked
- [ ] Every existing test for the class canaried (revert the fix: anything still green measured nothing)
- [ ] Regression test fails pre-fix, at the right tier
- [ ] Structural guard shipped, or its absence justified
