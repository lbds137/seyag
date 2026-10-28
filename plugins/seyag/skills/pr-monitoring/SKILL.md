---
name: pr-monitoring
description: 'Automatic PR CI and review monitoring: arm pr-ci-wait on every PR create and push, verify the SHA-pinned workflow run list and three review endpoints when it fires, report CI and review state together, hand feedback to seyag:review-response, and merge only through a green, un-checked-out head branch. Use when opening a PR, pushing to an open PR, handling a pr-ci-wait sentinel, or merging a PR.'
---

# PR Monitoring

This skill consolidates the procedure around three shipped components: the
`pr-monitor-reminder` PostToolUse hook (which prints the canonical arm
template on every push and `gh pr create`), the `pr-ci-wait` gate binary on
`PATH`, and `seyag:review-response` (which classifies and applies reviewer
findings).

## When to arm

- **Arm immediately on every `gh pr create` and every `git push` to an open
  PR.** Never wait to be asked whether CI passed or whether a review landed.
- **Verify the push landed first** (the `-> <branch>` ref-update line, or
  `git status -sb` showing the branch in sync with its upstream) — a watcher
  armed on a push that never landed reports a stale run as fresh.
- **One Monitor per PR: `TaskStop` this PR's previous watcher before arming a
  new one** (a release PR alongside a feature PR keeps one each). The review
  fetch is not SHA-pinned, so a stale watcher reports current state under an
  older push's label. **If the task id is gone** (compaction): `TaskList`
  cannot enumerate monitors, so `TaskStop` the `task-id` carried by the next
  event that fires for a PR already reported at this SHA.
- **Arm command.** The `pr-monitor-reminder` hook output is the canonical
  template (`Monitor` when available, or a background `Bash` task otherwise).
  Run `pr-ci-wait` from a checkout that holds the branch and survives the
  unit, keeping the command substitution unresolved — never transcribe or
  hand-extend a SHA:

```bash
pr-ci-wait <N> --sha $(git rev-parse 'refs/heads/<branch>')
```

  Outside the push-triggered template, omit `--sha` so `pr-ci-wait` resolves
  and watches the PR's current head rather than pasting a SHA by hand.
- **Pass `description: "CI + reviews for PR #<N>"`, `timeout_ms: 1800000`
  (30 min), and `persistent: false`.** The `false` is a deliberate departure
  from the `Monitor` tool's own guidance — do not "correct" it back:
  `TaskList` cannot see a watcher, so its own timeout is the only thing
  bounding it. If it expires, re-arm.
- **Wait on `pr-ci-wait`, never on a `sleep` or a hand-written poll loop** —
  both were measured emitting a premature `CI_COMPLETE`.

## When the Monitor fires

`"Monitor script failed (exit 1)"` can be cosmetic: `pr-ci-wait` exits 1 on
every non-`CI_COMPLETE` sentinel, and a standalone `gh pr checks` exits
non-zero whenever any check is red (including a check intentionally red on a
fixup-bearing branch until autosquash). Read the event output for the
sentinel and final check list.

When the watcher fires, **all four** steps below must run in order — do not
stop after step 1 even if every check is green:

1. **Confirm CI state and the SHA-pinned workflow run list.** Note the final
   CI state from `gh pr checks <N>`, **and** run the SHA-pinned run-list
   query. **A green `gh pr checks` list is not proof CI ran**: a workflow run
   that dies before dispatch (`startup_failure`) creates zero check-runs, so
   it is absent from `gh pr checks` while surviving workflows print green:

```bash
gh api "repos/{owner}/{repo}/actions/runs?head_sha=$(git rev-parse HEAD)" \
  --jq '.workflow_runs[] | "\(.status) \(.conclusion // "-") \(.name)"'
```

   Do not substitute a client-side filter over `gh run list` (`head_sha`
   filters server-side, so the result is exhaustive). **An empty result
   minutes after a push means "not indexed yet"**: re-query before concluding
   anything. Anything not `completed success` (or `skipped`) is a finding;
   **pin on the SHA, never a timestamp window**. Re-derive numbers and
   enumerations in the PR body and commit body against the head REF
   (`git grep <pat> HEAD`, `git show HEAD:<path>`), never the working tree.

2. **Fetch new reviewer feedback from all three endpoint groups**
   (`issues/<N>/comments` alone does not cover inline review comments or
   review summaries):
   - Conversation + inline line-level review comments (where human reviewers
     leave blocking feedback):
     `gh api repos/{owner}/{repo}/issues/<N>/comments` and
     `gh api repos/{owner}/{repo}/pulls/<N>/comments`
   - Review summaries (Approve / Request Changes / Comment):
     `gh api repos/{owner}/{repo}/pulls/<N>/reviews`
   - PR-level state:
     `gh pr view <N>`

   Track the last-reported comment's timestamp so a later push does not
   re-report it (after a session restart, a re-fetch may re-surface
   already-reported comments once — expected, not a dedup bug), and
   **include human reviewers** alongside bots. **claude-review health**: a
   green check means the workflow _completed_, not that a review body was
   posted — if no new `claude[bot]` comment followed a green run, run
   `gh run rerun <run-id>` before proceeding.

3. **Report in one consolidated message, then invoke `seyag:review-response`.**
   In one concise message, report CI pass/fail **and** any new review
   findings (blocking vs. non-blocking); if there are no new reviews, say so.
   **Read every `###` section of each review body — do not rely on the
   trailing Summary** — and every `claude[bot]` entry when there are several.
   If CI fails or CodeQL flags a new alert, surface it via
   `PushNotification`. Applying feedback is `seyag:review-response`'s job:
   **invoke `/review-response` (`seyag:review-response`) first, before
   touching anything**.

4. **Handle the gate sentinel.** `pr-ci-wait` waits for the anchor CI
   workflow (or the quiet-window run set) to finish with nothing else on that
   SHA in flight and for the review workflow run to exist and complete, hands
   off to `gh pr checks --watch`, prints **one** sentinel, and prints the
   final `gh pr checks <N>` list. Read **which** sentinel printed:

| Sentinel | Meaning | Action |
|---|---|---|
| `CI_COMPLETE` | CI settled with nothing in flight and the review run completed. | Proceed to steps 1–3 above. |
| `CI_GATE_TIMEOUT` | `pr-ci-wait` hit its give-up ceiling (25 min default). | Re-arm; do **not** assume CI passed. |
| `CI_GATE_STARTUP_FAILURE` | A workflow died before dispatch (`startup_failure`, invisible in `gh pr checks`). | Run `gh run rerun <run-id>`, then re-arm. |
| `CI_GATE_REVIEW_MISSING` | CI settled, but no review workflow run appeared within the 5-min grace window. | Re-query the run list; if still absent, the workflow never dispatched (`gh run rerun` has nothing to rerun and re-pushing is not a reliable lever) — check its `on:` filter against the PR event. |
| _(none printed)_ | The Monitor's own 30-min `timeout_ms` killed the process first. | Re-arm. |

## Infrastructure-shaped failures

**A red check with zero steps never ran — that is infrastructure, not your
diff**, and is rerun-eligible per the project's failure-shape policy.
`gh pr checks` renders it like a real failure, so inspect the job step counts
whenever a job fails without an obvious cause:

```bash
gh api "repos/{owner}/{repo}/actions/runs/<run-id>/jobs?per_page=100" \
  --jq '.jobs[] | "\(.conclusion // "-") steps=\(.steps | length) \(.name)"'
```

## Merge mechanics

- **The head branch must be checked out NOWHERE before merging.**
  `--delete-branch` fails locally when the head branch is checked out in any
  worktree: git refuses to delete a checked-out branch, `gh` reports the
  local failure, and the remote merge still succeeds, leaving the local
  branch behind silently. Check the easy-to-forget checkouts before running
  `gh pr merge`: any **worker worktree** and the **main checkout** still
  sitting on the branch after a local review.
- **Merge gate is green-only.** Every check must be green before
  `gh pr merge`, release PRs included; infrastructure-shaped failures get
  `gh run rerun <run-id> --failed` and a re-armed Monitor, never a merge
  through red. A check that cannot be rerun (some default-setup scans) needs
  a fresh event: amend the single unmerged commit or push a content-free
  trigger commit, then re-arm.
- **Chain same-turn verification with `&&`.** When a merge follows a
  verification run in the same turn (a re-fetched check list, a review
  re-read), chain them with `&&` so a failed check halts before the
  destructive step.
- **Re-derive diffstats against the MERGE-BASE.** When the target branch
  moved under a long-lived feature branch, re-derive diffstats and counts
  against `$(git merge-base <target> HEAD)`, not the target's current `HEAD`.

## Why the gate is shaped this way

The `--sha $(git rev-parse ...)` substitution resolves when the Monitor
executes, not when the push ran, eliminating hand-transcription errors (which
pass format checks and require `git cat-file -e` to reject). A bare `HEAD` can
drift if the checkout hops branches between push and arm or if the shell cwd
sits in a different checkout than the worktree holding the branch; pinning
`'refs/heads/<branch>'` from a surviving checkout that holds the branch closes
both hazards. `pr-ci-wait` also compares `--sha` against GitHub's PR head (with
one re-read for replication lag) and refuses a mismatch so drift costs a
re-arm rather than a mis-watch (fail-open if GitHub is unreachable, so arming
promptly still matters), and refuses an empty `--sha` as a substitution
misfire rather than defaulting to the previous head before GitHub indexes the
push. Finally, `sleep` and hand-rolled poll loops were measured emitting
premature `CI_COMPLETE`, and an "anything in flight?" check alone releases
before a not-yet-created review workflow dispatches — so `pr-ci-wait` requires
both CI settlement and positive existence/completion of the review workflow
run.
