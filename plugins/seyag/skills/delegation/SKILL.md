---
name: delegation
description: 'Driver/worker delegation for code-heavy repos: the driver grounds and specs each unit, dispatches it to a worktree-isolated implementer on the cheapest model that can do it, reads the full diff, transfers and commits. Use when an implementation unit''s fix shape is known and exceeds ~5 lines, when a review round lands, or when adopting the delegation model in a project.'
---

# Delegation

The context that wrote a diff cannot see its own assumptions; a fresh reader can. Delegation splits the drafting context (worker) from the judging context (driver), and it is also how several projects fit inside one weekly quota: every main-loop tool call re-bills the whole driver context, so legwork belongs on a cheaper model in a smaller context. The driver's own full-diff read is the gate that makes the split safe.

## When to dispatch

- **Inline only at ≤ ~5 lines** of mechanical edit in a file already in context. Above that, dispatch, whatever the justification.
- **Review-round fixes are dispatched**: batch the round's findings into ONE dispatch per round (prefer a `SendMessage` resume of the unit's worker). Inline round-fixes are how self-fed loops start (round N fixing round N-1's fix).
- **Read fan-outs of ~4+ files, or a search across unknown locations,** go to an `Explore` agent with the cheap model passed on the call (`model: "haiku"`); an omitted `model` inherits the driver's.
- **Don't delegate work finishable in a handful of tool calls**, and don't re-read what the spec already quotes.
- **Batch a drain by defect class, not by area**: one unit fixes one kind of thing everywhere, so its premise ledger, sweep and canaries share one shape.

## Roles

| Role | Does | Never |
|---|---|---|
| **Driver** (orchestrator model) | Grounds the unit, re-verifies the premise ledger, writes the spec, dispatches; keeps everything needing secrets, `.env`, a local DB or live services; reads the FULL diff itself; transfers; runs main-tree gates; commits, pushes, opens PRs. | Delegates the diff read to a verifier subagent. |
| **Worker** (`seyag:implementer`) | Executes the spec in its own worktree, runs the gates, reports. Contract: `plugins/seyag/agents/implementer.md`. | Commits, designs, spawns subagents. |

Every single-hop dispatch passes `subagent_type: "seyag:implementer"`, `isolation: "worktree"`, and `model` explicitly (the agent's own default is the most expensive tier):

- **Worker tier (`model: "sonnet"`)** is the default for units whose spec describes the edit precisely: renames, sweeps, fixture updates, applying a settled pattern.
- **Strongest tier (`model: "opus"`)** for semantic or risky units: design judgment inside the diff, concurrency, security, data migrations.
- **On a routed gateway the tier names lie.** Aliases resolve through `ANTHROPIC_DEFAULT_<ALIAS>_MODEL`, so any alias, `opus` included, can reach a smaller or different model. Run `env | grep '^ANTHROPIC_DEFAULT_.*_MODEL='` once per session (no output: the aliases mean what they say) and pass the alias that reaches the tier you mean.
- **Nested** (one `general-purpose` strongest-tier orchestrator in the worktree that hands the edits to a worker-tier agent with NO isolation flag, editing the orchestrator's tree) only for large multi-step units. Single hop is the default: it is cheaper, and the driver's read is the gate either way.

Name roles, not model versions, in project docs: a new tier slots in without rewriting. The owner's current role split and budget targets (which model drives, which works, how much of each weekly cap to use) are machine-local policy in the shared memory, not in this skill; read them there.

`isolation: "worktree"` cuts the worktree from the DRIVER's own repo. When the unit targets another repo, create the worktree yourself (`git -C <repo> worktree add -b worktree-agent-<unit> <repo>/.claude/worktrees/<unit> <base sha>`, and add `.claude/worktrees/` to that repo's `.git/info/exclude`), then dispatch WITHOUT the isolation flag, naming the worktree's absolute path as the only place to work.

## The spec template

Every dispatch carries these sections by name; a missing one is a gap the worker fills by guessing. Put the spec INLINE in the Agent prompt, or name it by the MAIN checkout's ABSOLUTE path (a gitignored file there is fine: the worker reads it by path, not from its tree); keep a record copy in the project's gitignored dispatch folder. Gitignored and excluded files never enter an agent worktree, so a spec named by a relative path inside the repo is invisible to the worker. `<PROJECT: …>` marks what the adopting project fills once; `<…>` marks per-unit values.

```markdown
# Unit: <one-line task>

## Task
<The design decisions already made. The worker executes; it never designs.>

## Premise ledger
- <each runtime premise the spec asserts> — <the read or probe that established it>
- Already built? `<grep for the fix's own name>` → <result>
- Already covered? `<grep/search for an existing task, PR or branch>` → <result>

## Files in scope
<path:line cites, each marked "verify before editing, cites drift">
Enumerated by: `<exact grep>`; positive control: `<known-present instance it matched>`.
Cannot see: <structural copies the pattern misses, and the second sweep that covers them>.

## Ceilings
<Every enforced cap the change approaches, with current value and headroom,
or a pre-authorized split: <PROJECT: file/function length caps, always-loaded
line or byte budgets, API field limits>.>

## Landmines
<Known traps: formatters that rewrite the file, gated baselines, hooks,
fixture shapes. <PROJECT: standing landmines>. Edit files with the Edit tool,
never an interpreter rewrite script.>

## Authorized routine decisions
<2-3 calls the worker may make solo. Anything material not listed is a stop.>

## Stop conditions
<Task-specific stops, on top of the implementer contract's defaults.>

## Verification gates
## Purpose: <one sentence: what this unit exists to make true>
- Purpose canary: <the mutation that falsifies the Purpose line; run FIRST, report the failure count>
- <PROJECT: whole-package test/lint/typecheck commands copied from package.json,
  Makefile or CI, not file-scoped lists>, each run once by the driver before
  dispatch: a missing script's empty output looks like a pass; run
  sequentially with long timeouts
- Claim canaries: <for every behavior the PR will claim, the mutation that
  falsifies it, cut strictly inside the fixture, never on the boundary tested>

## Step 0
<PROJECT: install + build a bare worktree needs>, then the base check below
with base `<sha> <subject>`: a full SHA the driver read with `git rev-parse`
this turn, never a branch name (a branch moves under the worker). Its
`git reset --hard` is pre-authorized by the driver under exactly its four
conditions; it is the one exception to the ask-first rule.

## Report
Deviations; verbatim gate tails; one line per Premise ledger row (verified
with its command, falsified with what is true, or unreachable here);
claim/canary pairs with red tails; purpose-canary failure count; git state as
pasted `git status --short` / `git log -1` output; transfer notes (gates the
worktree could not reach, gitignored artifacts to leave behind).
```

A claim with no canary is unverified: give it one or scope the sentence down (core rules § Hedges and fixtures are priors). A purpose canary whose failure count is low against the code paths the purpose spans is a coverage gap to close before proceeding.

## Worktree contract

**The base is stale by default.** With `worktree.baseRef: "head"` Claude Code cuts the worktree from the MAIN checkout's HEAD at spawn time, not from the branch you intend: park the main checkout on the target branch at the spec's SHA BEFORE the Agent call, because a branch hop between two dispatches silently moves the next worktree's base. Other settings cut from the default branch or a stale HEAD. A worker that stops on a bare mismatch wastes the dispatch: Claude Code auto-removes a worktree whose worker changed nothing, so it cannot be resumed into it, and a mid-run `SendMessage` loses the race to the check. So step 0 authorizes a self-heal. Put this block in the spec verbatim with `<sha>` filled (a local-only commit is a valid base; the object store is shared):

```bash
REQ=<sha>   # <subject>
pwd | grep -q '/\.claude/worktrees/' || { echo 'STOP: not in an agent worktree'; exit 1; }
if [ "$(git rev-parse HEAD)" != "$(git rev-parse --verify -q "$REQ^{commit}")" ]; then
  git cat-file -e "$REQ^{commit}" 2>/dev/null \
    && [ -z "$(git status --porcelain)" ] \
    && case "$(git branch --show-current)" in worktree-agent-*) true ;; *) false ;; esac \
    && [ -z "$(git log --oneline "$REQ..HEAD")" ] \
    && git reset --hard "$REQ" \
    || { echo 'STOP: base differs and a self-heal condition fails'; exit 1; }
fi
git log -1 --format='%h %s'
```

It resets only when the SHA exists, the tree is clean, the branch is the agent's own `worktree-agent-*`, and no commits sit past the SHA; otherwise it stops. Run in a scratch repo, it healed a stale base and stopped on each failing condition (commits past the SHA, dirty tree, wrong branch, unreachable SHA, not a worktree). This is the ONE sanctioned `git reset --hard`, and an adopting project must record that exception in its own rules next to its ask-first list.

- **Right after dispatch**, run `git worktree list`: a new tree must be listed. Only the main tree listed means the worker shares your tree; freeze your own checkout/pull/rebase/merge until it reports.
- **A `SendMessage` resume can silently drop isolation.** Before resuming, confirm the worker's tree still exists (a no-edit worker's tree is gone: dispatch fresh). As soon as the resume returns, re-run `git worktree list` and `git branch --show-current`, and treat the diff as suspect until both look right.
- **A bare worktree has no dependencies or build output.** Step 0 runs the project's install and build first, or the first gate fails for reasons unrelated to the diff.
- **Git state comes only from a command the worker just ran**, never from loaded context: the session-start snapshot is hours stale and workers have reported it as current.

## When the worker reports

Read the FULL diff yourself, in the worktree, never through a verifier subagent: the judging context must be the one carrying the spec's intent. Then:

- **Verify, don't relay.** Re-run `git -C <worktree> log -1`, `status --porcelain` and `diff --stat` for every git claim in the report, and `git -C <worktree> diff --stat -- <file>` for every "added tests to X". Re-run any gate whose tail is missing or truncated. A worker's "this canary cannot redden" is also a claim: build the discriminating fixture.
- Check each reported deviation against the spec's intent, not just its letter.
- **Sweep outward from the diff**: name the prose, prompts and constants outside the diff that DESCRIBE the changed behavior, and read each (core rules § A changed premise sweeps its prose). Neither the worker nor a diff-only reviewer can see these.
- **Then a fresh-context review agent** (core rules § Subagents by default), given the spec and the worktree path (for a cloud unit, the `origin/<base>...origin/<branch>` range), with `model` passed: an independent read finds what a driver checking the diff against its own spec can't. Its findings go back to the worker as one review round.

**Transfer**, from the main tree on the unit's branch, with the dependencies checked in order. The main tree must ignore `.claude/worktrees/` (`.gitignore` or `.git/info/exclude`), or the clean-tree check stops on it. Tested in a scratch repo: byte-identical on a clean modify+new+delete transfer; stops on an empty patch, a worker commit, a moved or detached main branch, and a dirty main tree (unstaged edit, untracked file):

```bash
WT=<worktree path>; BASE=<base sha>; PATCH=<scratch dir>/unit.patch
git -C "$WT" add -A && git -C "$WT" diff --cached --binary > "$PATCH"
[ -s "$PATCH" ] || { echo 'STOP: empty patch, nothing to transfer'; exit 1; }
[ -z "$(git -C "$WT" log --oneline "$BASE..HEAD")" ] || { echo 'STOP: worker committed'; exit 1; }
[ "$(git rev-parse HEAD)" = "$(git rev-parse "$BASE")" ] || { echo 'STOP: main moved off base'; exit 1; }
[ -n "$(git branch --show-current)" ] || { echo 'STOP: main is detached'; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo 'STOP: main tree not clean'; exit 1; }
git apply --index "$PATCH" && git diff --cached --binary | cmp - "$PATCH" && echo 'byte-identical'
```

`add -A` comes first because a plain `git diff` omits new files. After `byte-identical`, read `git -C "$WT" status --porcelain --ignored` for anything left behind that should have transferred (gitignored build output is expected), then remove the worktree and its branch:

```bash
BR=$(git -C "$WT" branch --show-current); case "$BR" in worktree-agent-*) ;; *) echo "STOP: $BR is not an agent branch"; exit 1;; esac; git worktree remove --force "$WT" && git branch -D "$BR"
```

Tested: it stops on a non-agent branch and otherwise removes the tree and deletes its branch. That `--force` removal is sanctioned here, resting on both the byte-identical check and the no-commits check, and post-session under § Stale worktrees and branches. Then rebuild every edited package's build output (stale output lets gates pass on source they never compiled), run the main-tree gates one at a time, commit, push, and open the PR per the project's git workflow.

## Stale worktrees and branches

Claude Code never removes an agent worktree, its lock or its `worktree-agent-*` branch after the owning session ends.

- **After the session ends**, a dead lock pid gates removal: run `git -C <wt> status --porcelain` (edits never transferred) and `git -C <wt> log --oneline HEAD --not --remotes` (unpushed commits), stderr attached (a `2>/dev/null` check has reported 0 falsely); anything listed is the owner's call. Then `git worktree unlock <wt> && git worktree remove --force <wt> && git worktree prune`.
- **In-session, the only removal gate is the transfer pair** (byte-identical patch, no worker commits). The lock's pid is the session's own pid, shared by every tree it cut, so a liveness check on it reports alive for all of them and gates nothing (after a `/clear`: core rules § Sessions and handoffs).
- **Orphan branches outnumber trees, and `git branch -d` refusing is no signal**: a rebase-merge rewrites SHAs, so an equivalent commit is never an ancestor and `-d` refuses nearly everything. After `git fetch`, the gate is `git cherry origin/<base> <branch>`: no `+` lines means every commit has an equivalent on the base, delete with `-D`. Verify each `+` commit by subject (`git log origin/<base> --fixed-strings --grep=<subject>`, usually a pre-rebase copy of merged work); an unmatched one is the owner's call. A squash-merged base matches no patch-id, so every commit prints `+` and the subject check is the whole gate.

## Failure and redo

- **A flagged stop is a good outcome.** When the worker stopped WITH edits in its tree, resolve it and resume the SAME worker with `SendMessage` (context intact, cache-riding). Spawn fresh only when its grounding is suspect (stale base, confused state), its agent id was lost to a compaction, or it stopped with no edits (next bullet); after a `/clear`, spawn fresh WITHOUT the isolation flag, pointed at the surviving worktree by absolute path.
- **Never resume a worker after a no-edit stop.** Its worktree was auto-removed, and a `SendMessage` resume then runs in the DRIVER's tree; dispatch fresh.
- **A worker-tier unit that ships a semantic defect** moves that unit class to the strongest tier, and the project records the defect where its tier evidence lives. Move it back only when the analysis blames spec or scope rather than the tier.
- **A main-tree gate that catches what the worktree gates missed** goes into every future spec's gate list.
- **Review-round cap ~6 per PR.** Past it, stop iterating in this context: hand the open findings plus the round history to a fresh implementer, or bring the owner the round ledger when the scope looks wrong rather than the execution.
- If a reviewer or the worker catches you mis-reporting the unit, say so first (core rules § Reviews are collaborators).

## Concurrency and economy

- **One local gate-running unit at a time.** Heavy gates never run in parallel on a resource-limited machine; the worker's gates count against that one slot.
- **Gate every new unit on the machine's usage gate** (`claude-usage --ok 90` on this Deck; exit 0 = go).
- **Before estimating whether the next units fit the week**, run `usage-sweep --since <session start> --points` for this project's meter points so far, instead of eyeballing from the live percentage.
- **How many cloud units may run is owner policy** (it bills the weekly quota); it lives with the model-role split in the shared memory, not here. Read it before launching one.
- **The dispatching turn states the expected wall time** (roughly 20–45 min for an initial unit, 5–20 min for a review round) so the owner has a not-stuck-yet horizon.
- **Cheapest model that can do the unit**, per § Roles; pass `model` on every Agent call.
- **While a worker runs**, prepare the next unit's grounding (core rules § Momentum); never touch the worker's files.

## Cloud units

A unit's worker and gates can run in a Claude Code cloud VM that clones the GitHub repo.

- The base must be **pushed**; the delivery is a **pushed branch** whose name the spec gives (so the project's pre-push naming hooks pass), and the driver opens the PR. The driver's review is `git fetch`, then `git diff origin/<base>...origin/<branch>`.
- `claude --cloud "<prompt>"` refuses a non-TTY caller. Write a launcher script (`cd <repo> && exec claude --cloud "$(cat <spec file>)"`) and run it under `timeout 150 script -qfec 'sh <launcher>' /dev/null` (it prints `Created cloud session` and exits within seconds); record the session id the moment it prints, where it survives `/clear`. Never pipe into `claude --cloud`: with stdin piped it runs locally and ignores the flag (observed). The Agent tool's `isolation: "remote"` is not a cloud path.
- **The cloud VM never loads the seyag rules.** Every cloud spec pastes core rules § Safety verbatim under a `## Seyag safety rules` heading, together with the global ask-first list it extends (`~/.claude/CLAUDE.md` § Safety Rules), which the VM cannot read; re-copied at each launch so it can't drift from the rule files.
- **The cloud unit's classifier blocks history rewrites and `.claude/hooks/` edits** (observed in accept-edits; other modes untested). A cloud review round therefore lands as a `--fixup` commit the cloud unit pushes; fixups stack across rounds and stay on the branch until the last one, because after a force-push the cloud checkout is behind rewritten history and the resync it needs is the class the classifier blocks. After the last round the driver runs `git fetch && git switch <branch> && GIT_SEQUENCE_EDITOR=true git rebase --autosquash origin/<base>` (tested on git 2.50: non-interactive, folds the fixups; `--autosquash` without `-i` needs git ≥ 2.44) and `git push --force-with-lease`, ask-first per core rules § Safety unless the project pre-authorizes it for agent branches. A cloud unit starts in accept-edits unless a launch flag or the repo's `defaultMode` says otherwise (observed on launches without the flag; the flag path is untested).
- The result is read with `get_run_log` (the RemoteTrigger MCP tool), which truncates each entry near 400 characters: the spec tells the unit to write its report to a file and print it in chunks of at most 350 characters.
- Cloud review rounds resume the same cloud session with `SendMessage`.
- Secrets, `.env` values, live services and production data stay local. The project supplies its own cloud step-0 environment script (`<PROJECT: toolchain install, services, deps and build>`), opening with a check that it is not on the local machine.
- Relay the session link to the owner in chat only, never in a commit, PR or doc.
- Closing a cloud unit: `/exit` is unavailable there; archive it from the app. The phone UI can keep showing it as connected afterward (owner-observed 2026-09-25, not reproduced by us).

## Adopting it in a project

1. Fill the PROJECT slots once, in the project's own rules or a project skill: the whole-package gate commands (copied from its manifest or CI), its ceilings, its standing landmines, and the local-only list (secrets, DB, live services).
2. Record the step-0 self-heal as the one sanctioned `git reset --hard` in the project's rules.
3. Name the gitignored folder where specs and cloud session ids live, and ignore `.claude/worktrees/` (`.gitignore` or `.git/info/exclude`) so the transfer's clean-tree check passes.
4. Set `"worktree": {"baseRef": "head"}` in the project's tracked `.claude/settings.json` and park the main checkout on the unit's branch before each Agent call; the step-0 self-heal stays the backstop. Claude Code reads that settings file from the MAIN checkout at its HEAD, not from the driver's branch: the setting must be committed at the main checkout's HEAD, or the driver must work from the main checkout. Otherwise the agent tree is cut from the main checkout's HEAD and only the step-0 self-heal saves the dispatch.
5. Optional: the inline-edit size gate is the seyag hook `dispatch-posture-gate` (OFF by default). Opt in by setting `SYG_DISPATCH_SRC_RE` in the project's `.claude/settings.json` `env` to an extended regex over the project-relative path of the files it should guard (e.g. `^(src|lib)/.*\.(ts|js)$`); it then hard-blocks an inline edit over 5 lines and blocks once per commit at 5 or fewer, exempting subagents and `.claude/worktrees/`. The premise-ledger presence gate is not in seyag yet; a project that wants it now writes its own.
