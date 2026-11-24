---
name: testing-discipline
description: 'Measure-then-fix for slow test suites, and a checklist for writing tests well: time the suite and its slowest tests before any speed claim, fix in a fixed order, record before/after numbers under stated conditions. Use when a suite runs over its time budget (suite-time flags it), when someone asks why tests are slow or how to speed them up, and when writing a new test suite or test file.'
---

# Testing discipline

Slow suites are usually slow because of how they were written, and machine contention multiplies it. The fix starts with numbers, not a guess, and the cheapest speed-up is writing tests well the first time.

## 1. Measure before any speed claim

- Never quote a remembered suite time. Run it now. (An agent once cited about 100 s for a gate that took 263 s.)
- Wrap the run: `suite-time run --name NAME -- CMD...` records wall time, child CPU, load, CPU count and free memory, and appends a row to its log. It composes inside other runners.
- Get the slowest N from the runner's own report:
  - pytest: `--durations=N`.
  - vitest: `--reporter=json --outputFile=FILE` (per-test `duration` in ms, per-file `startTime`/`endTime`), or `--slowTestThreshold=MS`.
  - bats: `-T`.
  - Go: `go test -json` (`Elapsed` per test).
  - Any runner that writes JUnit XML: `suite-time slowest FILE.xml`.
  - Anything else: check its `--help` before writing a flag down.
- Read wall against CPU. Wall far above CPU means waiting (locks, IO, swap, sleeps), and the fix is not faster code. (A probe ran 150 s wall on 26 s of CPU.) CPU counts only the suite's own process tree: work done in a database container or a server the tests call shows up as waiting.
- In CI, read the slowest jobs and steps over recent runs: `gh run view RUN_ID --json jobs` (each job and step has `startedAt` and `completedAt`).
- Find the critical path. With N workers the slowest single file sets the floor, and trimming the rest won't move the total. (One file was 145 s of a 180 s suite; a fixture fix elsewhere saved 2 s.)
- Record the conditions with every number: same command, worker count, machine load. Compare like with like. (One suite ran 214 to 865 s on the same code, depending on load.)

## 2. Budgets

- Give each suite a budget with `SYG_SUITE_BUDGET_S` or `--budget`. `suite-time` flags a run over budget. It also flags a run slower than the median of its last 5 clean runs by more than `SYG_SUITE_TIME_TOLERANCE` percent (default 20).
- Over budget, you have two choices: fix it now, or raise the budget deliberately, with the reason written where the budget lives. Silence is not one of them.

## 3. Fix in this order, re-measuring after each step

1. **Shared fixtures over per-test setup.** Build expensive state once per file or suite and reset it cheaply. Build one template and copy it, rather than rebuilding per case. (A probe built about 58 fresh git repositories, one per case.)
2. **Process isolation only where needed.** A fresh process or fork per test file costs startup on every file. Use it for tests that mutate global state, not by default.
3. **No real sleeps or timeouts in unit tests.** Use fake timers or an injectable clock, or make the threshold a parameter so the test waits 0.1 s instead of 5. (A 6 s sleep existed only to test a "waiting after 5 s" notice.) Race and stress loops stay, bounded and split into their own file so they parallelize.
4. **Parallelism sized to the machine, not set to max.** Memory per worker binds before cores do. Nested parallelism multiplies (packages times workers per package). A shared lock serializes "parallel" work: a test that spawns hundreds of runs queued on one lock gets slower as the machine gets busier. Split the critical-path file so it can run in parallel. On a host that sets `SYG_RESOURCE_PROFILE`/`SYG_MAX_PARALLEL`, a repo's gates read the ceiling with `resource-profile --jobs <default>` and map it onto their own knobs: turbo `--concurrency`, jest/vitest `--maxWorkers`, `make -j`; under `resource-profile --profile` = `low`, a `NODE_OPTIONS=--max-old-space-size` cap. Read it from the environment or the user config, never from a checkout's `.env`, which a worktree doesn't have.

Never weaken or drop an assertion to buy speed. Split it instead. Put the before and after rows (`suite-time log --name NAME`) in the commit or PR.

## 4. Writing tests well

One line each, with a short why:

- Test behaviour through the public interface, not internals, so refactors don't break tests.
- Let each test own its state. No order dependence; reset mocks and fakes per test.
- Name the behaviour and the condition, so a failure reads as a spec.
- Assert what crosses a faked seam, both the arguments out and the results in. A sentinel returned by a fake external must reach the final output.
- With stacked checks, make every upstream check pass, so the check under test is the only thing that can fail; an exit code alone doesn't say which check fired. Canary it: break that one check and watch the exact assertion go red.
- Build fixtures from real specimens and change only what the test needs. Synthetic data carries real properties (spaces, non-ASCII, length, nesting); a toy input hides interactions. To refute a finding, vary one property at a time.
- Use realistic IDs and values. Validators silently drop toy ones, so the test passes for the wrong reason.
- Cover every mode and branch arm, not just the default.
- Keep one in-order test for a pipeline that passes a shared object between steps. Per-step tests can't see each other's writes.
- Run the tier and config you changed. Excluded tests "pass" by not running, and a run from the wrong config can leak state that looks like flakiness.
- With async code and fake timers, attach the rejection expectation before advancing the clock. An `await` under fake timers can let a pending timer fire first.
- Skip no test: fix it or delete it. Fix a flaky test now. Don't test trivial getters or a library's own behaviour.
- Coverage shows what ran, not what was checked. Where it pays, mutation testing finds the gaps. A surviving mutant labelled "hard to test" is a gap, not an equivalent.
- Speed is part of writing the test: start with fake clocks, shared fixtures and no network. Time a new test file once (the runner's report or `suite-time`) before calling it done.

## Trigger

The description names the triggers. `suite-time` prints a pointer to this skill when a run goes over budget. The budget is a per-project knob, unset by default, so nothing is flagged until a project sets one.
