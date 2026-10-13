---
name: usage-audit
description: 'Measure Claude plan usage across every Claude Code session on this machine: weighted token spend per model and per project folder, delegation ratio, implied weekly capacity, and a machine-local drift ledger. Use near the weekly reset, after an unusually heavy day, or whenever the owner asks how much of the plan has been spent or whether the week will last.'
---

# Usage Audit

Turns the local session logs plus the live plan meter into four numbers: weighted spend per model, the share that ran in subagents rather than main loops, the implied weekly capacity, and whether that capacity has drifted since the last reading. Anthropic doesn't publish the plan limits, so the measurement has to be repeatable (same window, same weights, same aggregation), and every run leaves a ledger row so drift shows as a trend.

## Privacy boundary

The ledger is machine-local: `~/.claude/usage-ledger.md`. Never commit it, reference it from a tracked doc, or paste it into a PR, issue or commit message. Session logs carry session ids, and session ids are secrets. Aggregates ("~400M weighted this week") are fine in chat and, bare, in tracked docs.

Tzurot's older, Tzurot-only ledger is `~/.claude/projects/-home-deck-Projects-tzurot/usage-ledger.md`. Its weighted totals were computed before the dedupe fix below, so they are roughly 2x high and can't be compared with this ledger's rows. Its meter readings and dated facts (promotion end, cloud billing) still hold.

## Step 1: the window and the meter

```bash
claude-usage --json    # weekly_pct, weekly_resets_at (epoch), scoped (per-model cap, e.g. "Fable 27%")
```

The window normally opens at `weekly_resets_at - 7 days`, and that's the default `usage-sweep` uses. **An applied mid-week reset moves the window start without moving `weekly_resets_at`.** Check the ledger's latest rows and ask the owner if a reset might have been applied. If one was, pass its instant with `--since`. A wrong window start is the most common way the implied capacity comes out absurd.

## Step 2: the sweep

```bash
usage-sweep                          # every ~/.claude/projects folder, since the window start
usage-sweep --since 2026-09-24T01:15Z
usage-sweep --json                   # for the numbers you put in the ledger
```

### Per-model rates

```bash
usage-sweep --fit
usage-sweep --fit --probe START END --slug <folder>
```

Rates need dense readings, so run the poller recipe (`CLAUDE_USAGE_TTL=55 claude-usage --json >/dev/null` every 60 s) during a measurement.

It reads every main-loop session file and every `subagents/` file (subagent spend is real spend), skips `mined-corpus/`, and **counts each reply once, at its largest `output_tokens`**. Claude Code writes each content block of a reply (thinking, text, tool_use) as its own JSONL line, and each of those lines repeats the reply's usage. The input and cache fields are identical across the lines, while `output_tokens` grows as the reply streams. So summing lines overcounts about 2.2x (measured 2026-09-25 over this machine's logs: 1743M line-summed against 801M counted per reply), and keeping the first line undercounts output by about 30%. `--no-dedupe` reproduces the old line-summing method, only for comparing against old rows.

Folder names starting with `-tmp` embed a session id, so the sweep prints them as one `-tmp*` row.

Weights (fixed; don't re-derive them mid-audit): input 1x, output 5x, cache read 0.1x, cache write 1.25x. Cache reads are usually 75-80% of the weighted bill, so the lever is the number of main-loop tool calls, not reply length: each call re-reads the whole context.

What the sweep can't see:
- **Cloud sessions** (`claude --cloud`, claude.ai/code) leave no local JSONL, and `claude --teleport` without a new turn doesn't write one either (probed 2026-09-25). How they bill has changed as credits came and went, so confirm the current billing with the owner rather than assuming. If they bill the plan, the meter counts them and the sweep doesn't: note cloud units in the row and treat the implied capacity as inflated.
- **Other devices** on the same plan.

An empty or tiny total indicts the invocation first: a wrong `--since`, or a wrong `--slug` (an unknown one is rejected). It doesn't show a quiet week.

**Per-tool attribution** (optional, for finding the lever inside one main loop): group the output tokens of one session file by tool name.

```bash
jq -r 'select(.type=="assistant") | .message.usage as $u
  | (.message.content[]? | select(.type=="tool_use") | .name) as $t | "\($t) \($u.output_tokens // 0)"' <session>.jsonl \
| awk '{s[$1]+=$2; n[$1]++} END {for (t in s) printf "%-24s out %9d  calls %5d\n", t, s[t], n[t]}' | sort -k5 -rn
```

It ranks where the calls are rather than partitioning the total: a reply's output is attributed to each tool it calls.

## Step 3: calibrate and act

`implied capacity = total weighted ÷ (weekly_pct / 100)` holds only when the sweep covers the whole meter window and no cloud or other-device spend hit the plan.

- Compare it with the prior rows in this ledger. Flag drift over ~15% as "limits may have moved" and say so, but never adopt a new capacity from one reading: a wrong window start looks identical.
- **Don't divide one model's spend by its scoped meter.** Anthropic's per-model weighting differs from ours, and per-model division has given inconsistent answers from same-day readings. For per-model questions (is Fable tight?), read the `scoped` percentage directly.
- **The meter is the instrument for pace.** Compare `weekly_pct` and the scoped percentage with pro-rata (days elapsed ÷ 7):
  - Ahead of pro-rata: name the project's lever, such as a cheaper driver model, lighter days or boundary compaction, and recommend it to the owner at the moment of the reading. That's her call.
  - Comfortably under: say so and change nothing. The audit also licenses normal pace.

## Step 4: append the ledger row

```
| date | window | weighted total (deduped) | meter (all · scoped · 5h) | implied capacity | delegation | per-folder top 3 | notes |
```

Create the file with a header line (machine-local, never committed, weights, dedupe) if it doesn't exist. Notes carry the caveats: cloud units in the window, an applied reset, a model mix far from usual.

If a project stamps its audit cadence somewhere (Tzurot: `pnpm ops cadence:mark usage-audit` in its repo), stamp it there too, with the date only and no figures.

## Anti-patterns

| Don't | Why |
|---|---|
| Sum usage lines without deduping by message id | ~2.2x overcount |
| Sweep one project folder | The meter is shared by every session on the plan |
| Skip `subagents/` files | Understates delegated work and inverts the delegation ratio |
| Trust `weekly_resets_at - 7d` after an applied reset | The window start moved |
| Adopt a new capacity from one reading | A wrong window looks identical to moved limits |
| Commit the ledger or quote a session id | Machine-local by design; ids are secrets |

## Related

- `session-mining`: the qualitative sibling. This skill counts tokens; that one counts friction and keepers.
- `claude-usage`: the live meter and the 5-hour gate (`--ok`, `--wait`).
