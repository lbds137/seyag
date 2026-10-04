---
name: session-mining
description: 'Mine Claude Code session logs from any project on this machine in three lenses: owner friction (user turns), the agent-side record (misses nobody remarked on, and moves that worked and should recur), and procedures (multi-step work hand-built again and again that a script or skill should own). Every finding ends with a structural disposition: rule, skill, hook, script, or a recorded load-bearing guard. Use periodically, around a model or driver handoff, or when a pattern feels recurrent but unquantified. For an ad-hoc question about past sessions ("what went wrong yesterday with X", "which session decided Y"), run session-log list or grep instead of hand-written jq over the logs.'
---

# Session Mining: three lenses

Mines session JSONLs in three lenses and turns what they find into structure. The OWNER lens reads user turns for friction; the AGENT lens reads the assistant's own record for misses nobody remarked on and for moves that worked; the PROCEDURE lens reads for repeated manual work: what's tedious and automatable is the third thing mining learns from, next to friction and misses. A friction-only run produces a refit that dismantles what was working; a positives-only run papers over misses. So every run carries all three lenses, and every finding, negative or positive, ends with a disposition. The pipeline is **extract → mine → synthesize → operationalize**. The deliverable is the structural fix at the end, never the report (core rules § Fix recurring failures structurally).

## When to run

- Every 4-6 weeks of active work in a project, or once ~500 new user messages have piled up since its last run.
- Before or after a model/driver handoff or a major process change.
- On a hunch with a count of one: a correction that feels like it happened before, but whose prior instance you can't cite.
- On request ("mine the sessions", "why does this keep happening").

## Scope and layout

Session logs live per project folder under `~/.claude/projects/<slug>/`, where the slug is the session's launch path with `/` turned into `-` (`-home-deck-Projects-tzurot`). Mining output lives beside them, per slug:

```
~/.claude/projects/<slug>/mined-corpus/corpus/    extracts (<session>.txt, <session>.agent.txt)
~/.claude/projects/<slug>/mined-corpus/reports/   miner reports, SYNTHESIS-<date>.md, README.md (the run ledger)
~/.claude/mined-corpus/                            cross-project SYNTHESIS-<date>.md and its README, when a run spans slugs
~/.claude/mined-corpus/ledger.tsv                  the machine-wide mined-range ledger (session-log mark / ledger)
```

Tzurot's slug already holds a long mining history in this layout; its `reports/README.md` is authoritative for dispositions and guard ledgers there (mined ranges live in the machine-wide ledger — `session-log ledger`). Slugs under `-tmp*` are scratchpad sessions, usually noise.

The owner's claude.ai export archive (`~/Documents/claude-session-archive/cse_*.jsonl`, written by dev-docs' export script — which she runs herself in the page console — and its splitter) holds cloud sessions and history older than the local ~30-day window. `session-log` reads it as a second source, local transcripts winning on overlap by event uuid; `session-extract` reads its files directly (same line shape), but events lacking `timestamp` fall outside a `--since` filter (confirmed: with `--since` every block count on such a file drops to 0), so extract archive files without `--since`. Mark archive ranges with the `cse_` id.

**Privacy boundary:** extracts and reports hold verbatim user quotes and session content. They are machine-local working material: never commit them, reference them from a tracked doc, or paste them into PR bodies or commit messages. Only the operationalized outcomes (a rule line, a skill step, a hook) enter a repo, carrying the invariant without the archaeology. Session ids are secrets.

## Ad-hoc reading

For any question about what happened in past sessions ("what went wrong yesterday with X", "which session decided Y"), reach for `session-log` before writing jq. Find the session with `session-log list --since yesterday --project <substr>`; find the moment with `session-log grep --since <T> <PATTERN>` (default role is owner turns; `--role agent|tool|all` widens it); then read around the hit with `session-extract` or the JSONL directly. `list`/`grep` include the claude.ai export archive alongside local transcripts (`--no-archive` to skip it). Same privacy boundary as mining output applies: results stay in the terminal or private files, never a tracked doc or a PR body.

## Step 0: inventory what's unmined

```bash
session-log ledger --unmined                                        # unmined ranges per lens, machine-wide, grouped by app session
session-log list --since <date>                                     # sizes, turn counts, titles for the window
session-log list --since <date> --paths-to "$C/window-paths.txt"    # full paths for session-extract; never paste them
```

Compare each session's span against the ledger's unmined ranges. **Never re-mine a range through a lens already applied to it**, because re-mined findings inflate recurrence counts. The rule is per lens: a range mined owner-only is still unmined for the agent lens. Raw JSONLs age out (Claude Code deletes old transcripts after `cleanupPeriodDays`, 30 by default; owners also delete them for disk space) while their extracts and ledger marks survive, so a range whose raw file is gone can take only the lenses whose extract exists: the owner lens needs `.txt`, the agent and procedure lenses need `.agent.txt`. Extract new deltas promptly. The active session can be included; note that its tail is still being written.

Ranges mined before the ledger existed are recorded only in each slug's `reports/README.md`. Before trusting `ledger --unmined` for a slug, check its README's range history against the ledger and import any missing range once with `session-log mark`: a window mark covers every transcript of the slug that falls inside it, so mark each transcript on disk with the window's FROM/TO.

**Read the prior run's dispositions** in the slug's `reports/README.md` (mined ranges now live in the machine-wide ledger above, not there; the README keeps dispositions and guard ledgers only): confirm each `shipped` item landed (the commit or PR exists), each tracker ref still resolves, and each `recorded-load-bearing` guard still exists by name. Flag any proposal whose disposition is missing or dangling. Then tally each hook's trips across the last three README entries' guard ledgers: a hook at zero in all three is a retirement question for the owner (Step 3).

## Step 1: extract

```bash
C=~/.claude/projects/<slug>/mined-corpus/corpus
session-extract --since 2026-09-20T06:00 "$C" ~/.claude/projects/<slug>/<session>.jsonl ...
```

`session-extract` (plugin `bin/`, fixture-tested) writes two files per session and prints a count line for each. **Read the count line:** zero user blocks on a session you know had conversation means the field shapes drifted. Before mining, positive-control the agent lens: a session known to have tripped a hook must show a non-zero `tool errors` count.

- `<session>.txt` (owner lens): user turns, plus mid-turn messages marked `[mid-turn]`. Messages typed while a turn runs are `queue-operation` entries, not `user` entries, and they're often the corrections issued while the owner watched something go wrong. They're appended after the user turns; the timestamps interleave them. **Most `[mid-turn]` blocks aren't the owner:** task notifications and Monitor output enqueue the same way (122 of 164 in one measured Tzurot session). Tell the miner, so automated traffic doesn't inflate owner-lens counts. The extract is **deliberately raw**: system reminders, caveats and compaction summaries stay in. Compaction summaries preserve verbatim quotes from compacted-away turns, and some of the best findings survive only there.
- `<session>.agent.txt` (agent lens): assistant text in full, one stub line per tool call, and tool results only when they errored. Hook blocks and gate refusals land there, which is what makes guard trips countable. Thinking blocks are dropped (size), so self-corrections resolved silently inside thinking are invisible.

The procedure lens reads one stub-only file for the whole window across all its sessions:

```bash
grep -H '^--- ' "$C"/*.agent.txt > "$C/procedures-<date>.txt"
```

Positive-control it: non-empty, and its line count should be roughly the sum of the `tool calls` + `tool errors` counts printed by `session-extract` for the window's sessions.

## Step 1b: metrics (scripted, before any miner)

Run `session-log stats --since <T> --until <T> --subagents` (and again with `--json > reports/metrics-<daterange>.json`) before mining. Its `hook:<name>` rows are the GUARD LEDGER's trip counts; its driver rows are the DRIVER SPLIT numbers; its retry table (a block followed, in the next reply, by the same tool = retried, by a different tool = moved_on) is block→retry evidence for over-aggressive hooks; its `classifier-denied:<reason>` rows are the CLASSIFIER row. Give miners the class table as context instead of having them re-count.

Positive-control it: without `--subagents`, the top-level `tool_errors` total should be close to the sum of `session-extract`'s `tool errors` counts for the same window.

## Step 2: mine (parallel reader agents)

Mining a delta costs one agent per corpus file per lens: two per session plus one procedure miner per run. Before a fan-out of more than ~10 agents, state the expected cost in usage-window terms and get the owner's opt-in (core rules § Big token spends). Each miner writes its own report file (two miners on one file is a write race): `reports/<session-prefix>-<daterange>-report.md` and `...-agent-report.md`.

**Owner-lens taxonomy** (every item in exactly one):

| Category | Captures |
|---|---|
| CORRECTION | Owner corrects a factual or behavioral error |
| REPEAT | Owner re-reports a bug believed fixed, or re-issues a prior instruction |
| FRUSTRATION | Emotional signal: profanity, lost confidence, exasperation |
| TRUST-CHECK | Owner verifies a claim instead of accepting it ("are you sure") |
| REDIRECT | Owner re-scopes mid-task (the agent was heading the wrong way) |
| PROCESS-GAP | Owner names a missing process, tool or rule |
| PREFERENCE | A durable working-style preference |
| DECISION | An owner directive that should be durable session state |
| RATIFIED | Owner endorses a behavior in so many words, or accepts a non-obvious recommendation unchanged |
| TEDIUM | Owner does, or asks the agent for, the same multi-step manual work again (a request matching an earlier one, or manual steps she reports doing herself) |

Per item: `#` · timestamp · **verbatim quote** (never paraphrase; mark compaction-recovered quotes `[via summary]`) · 1-2 sentences of context · **Before?** (seen earlier in this corpus, with the tell, such as the owner's own "again"). Trailing sections: `RECURRING WITHIN THIS FILE` (2+ hits) and `TOP 10 LOAD-BEARING QUOTES`.

**Agent-lens taxonomy:**

| Category | Captures |
|---|---|
| SELF-CORRECTION | The agent reverses its own prior factual claim |
| TOOL-MISUSE | A command failed on the invocation shape, not the data (wrong cwd, malformed ref, filtered push), including every hook block |
| REWORK | Work redone because of an agent error |
| GOOD-MOVE | An action no rule, skill or hook prescribes, that worked, in a situation that will recur |
| GUARD-HELD | An existing hook, gate or skill step fired and was right |

A hook block is filed once, as TOOL-MISUSE, and also counts in its hook's GUARD LEDGER row; GUARD-HELD is for a catch with no misuse item of its own. Per item: `#` · timestamp · the move or miss in one line · outcome · **Prescribed?** (a rule, skill or hook already names it, with the pointer; a yes on a GOOD-MOVE candidate reclassifies it as GUARD-HELD) · **Recurred?** (recurrence is the promotion key; a one-off is memory at most). Read marker-first: `tool-error` lines, the `[agent]` blocks around them, then a GOOD-MOVE sweep (tells: a check whose result changed the next action; a defect caught before commit or push). Never read linearly. Trailing sections: `GUARD LEDGER` (per guard: trips / escapes / false positives; 0/0/0 is a finding) and `KEEP LIST`.

**Procedure-lens taxonomy:** one miner for the whole window, reading the stub file — repetition is cross-session, and a per-session miner can't see it.

| Category | Captures |
|---|---|
| PROCEDURE | The same multi-step tool-call sequence (3+ calls toward one goal) hand-built in 2+ sessions, or 3+ times in one |

Per item: `#` · the sequence normalized, one line per step · occurrences (session prefix + timestamp each) · cost (calls per occurrence × occurrences) · **Covered?** (an existing script, plugin `bin/`, `~/.local/bin` tool or skill step that already does it; a yes makes it a `DISCOVERABILITY` item: the fix is a trigger sentence at the moment of need, not a new tool) · proposed disposition. Reading order: group stubs by tool and command head (first command word, jq filter shape, script path), then look for recurring sequences. Trailing section: `TOP PROCEDURES` by occurrences × cost.

Report file: `reports/procedures-<daterange>-report.md`.

**Driver attribution** (when the window spans model switches): the driver is the pair (model, message-id prefix), not `.message.model` alone: `msg_` + `claude-*` = Anthropic, `msg_` + any other model = z.ai, `gen-` = OpenRouter (`<synthetic>` is a Claude Code placeholder, not a switch). `session-log stats --by session` gives the timeline per transcript. Tag every item with the driver in effect, and add a `DRIVER SPLIT` section.

**Orchestrator quality** (when the window includes orchestrated or delegated work): flag separate ORCH items for review rounds over ~3 on one PR, defect origin (spec, worker, or the orchestrator's own edits), self-fed review loops (round N fixing round N-1's fix), work claims a reviewer or the owner had to correct, and wrong premises in a dispatched spec that the worker caught. Attribute honestly: when the evidence lands on a different driver than the one the lens targets, the caveat header says so.

Each report opens with a caveat header: date range, message count, and how much survives only via compaction summaries.

## Step 3: synthesize

One pass, inline or one agent, reading every report of the run:

1. **Rank by recurrence across corpora**, not by severity within one session.
2. **Check each top pattern against existing structure.** That means the project's rules, skills and hooks plus this plugin's (`core.md`, `hooks/`, `skills/`):
   - No rule exists: a missing-structure finding (write one).
   - **A rule exists and is still violated:** a compliance finding. Another rule restating it is worthless; look for a hook, a decision-point trigger sentence in the existing rule, or a workflow change that removes the opportunity to fail.
3. **Harvest positives with the same bar.** Rank GOOD-MOVE and RATIFIED by recurrence. A guard with trips and zero escapes is recorded as load-bearing, so a later economy pass can't cut it on cost alone. A guard with zero trips across three or more runs is a retirement question for the owner, never kept by reflex. The cross-lens link happens here: an owner RATIFIED item names the adjacent agent move as a GOOD-MOVE candidate.
4. **Rank PROCEDURE and TEDIUM by occurrences, and link them across lenses:** a TEDIUM request whose steps match a PROCEDURE item is one finding with both counts, the same way RATIFIED links to GOOD-MOVE.
5. Write `SYNTHESIS-<date>.md` with the ranking, numbered proposals and an execution plan. A cross-slug run writes it under `~/.claude/mined-corpus/`.

## Step 4: operationalize (the deliverable)

Pick the surface by audience: one repo's contributors get that project's rules, skills or hooks; every session on this machine gets this plugin (`~/Projects/seyag`) or the shared memory. Then climb the ladder: **rule** (hard constraint) → **skill** (procedure step) → **hook or script** (deterministic trigger, mechanical correction) → **memory** (narrative or per-user context only, never a "try harder" note).

Positives take the mirror ladder: a GOOD-MOVE that a command can run becomes a script or hook with its probe, plus a trigger sentence in the rule or skill that owns the moment. One that needs judgment but recurs becomes a named step in the governing skill. RATIFIED becomes the default written into the rule or skill that governs the choice. GUARD-HELD becomes `recorded-load-bearing <trips/escapes/FPs>` in the README, or `retire-candidate` handed to the owner. A PROCEDURE becomes a script (with a probe) plus a trigger sentence where the moment happens, or a skill step when it needs judgment; a DISCOVERABILITY item becomes only the trigger sentence.

- Each change goes through its repo's own gate: the project's review-gated PR (Tzurot), or `tests/run-probes.sh` green before push (seyag).
- Present findings to the owner ranked, with evidence counts and one proposed fix each. Mining output is a proposal, not a mandate.
- **Record mined ranges** with `session-log mark --lens <lens> <transcript> <from> <to>` for every range and lens (the machine-wide ledger `session-log ledger` reads), not in the README. **Update the slug's `reports/README.md`:** the run's consolidated GUARD LEDGER (every hook in the plugin and the project's `.claude/hooks/`, with trips / escapes / false positives, zero-trip hooks included); and **one disposition per proposal**, exactly one of `shipped <commit/PR>`, `tracked <ref>`, `rejected (<reason>)`, `recorded-load-bearing <counts>`, `retire-candidate`. A proposal with no disposition evaporates between runs; the next run's Step 0 reads these.
- Anything deferred gets an entry in the project's tracking surface in the same session. A report row doesn't count as tracking.
- If the project stamps its cadence (Tzurot: `pnpm ops cadence:mark session-mining`), stamp it.

## Anti-patterns

| Don't | Do instead |
|---|---|
| Re-mine a range through a lens already applied | Step 0 ledger check, per lens |
| Paraphrase and present it as a quote | Verbatim only; `[via summary]` when compaction-recovered |
| Fix a violated-rule finding with another rule | A hook, a decision-point trigger, or a workflow change |
| Land findings as "try harder" memory notes | A structural fix, or an explicit accepted-risk disposition |
| Commit or reference corpus or report content | Only operationalized outcomes enter a repo |
| Rank severity-first from one dramatic session | Recurrence across corpora is the key |
| Mine friction only | Harvest GOOD-MOVE and RATIFIED with recurrence counts |
| Keep a guard because it exists | Count trips; zero over three runs goes to the owner |
| Read the agent extract linearly | Marker-first |
| Hand-write jq to answer a question about past sessions | session-log list or grep |
| Mine procedures per session | One procedure miner over the whole window's stubs |
