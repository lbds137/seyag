# seyag

A Claude Code plugin marketplace with one plugin, `seyag`. The plugin is the portable "how to work honestly and well" layer, first built inside the Tzurot repo. It gives every Claude Code session on this machine the same working rules, shell-safety guards and turn-shape checks, whatever project the session is in.

It assumes the owner does not read diffs and is rarely watching the live transcript — on the Anthropic lane she drives from her phone, often by voice; on other lanes she's at the Deck keyboard or RDP-typing from her phone. Agent review and automated checks are the quality gate, and any blocking question has to go through `AskUserQuestion` so it rises above the transcript.

## What's in it

| Path | What it is |
|---|---|
| `plugins/seyag/rules/core.md` | The shared working rules, loaded into every session as a user-level rule (see Install): interaction style, working posture, evidence and claims, extra safety rules, reporting. Project rules win when they conflict. |
| `plugins/seyag/hooks/` | Hooks with a `*.probe.sh` test next to each. Shell-safety guards: `self-matching-pattern-guard`, `python-heredoc-edit-guard`, `grep-escaped-dollar-guard`, `cache-rm-redirect` (points a hand-rolled recursive delete of a regenerable cache at `safe-clean`), `broad-walk-guard` (blocks find/du/grep -r/rg/fd walks of `/`, `/home`, `~` or `~/gdrive`, whose rclone mount a walk can wedge), `recursive-rm-guard` (blocks recursive `rm` (`-r`, `-R`, any `--r…` prefix of `--recursive`), `find -delete`, `find -exec rm` and `xargs`/`parallel rm` with any flags, without the owner's approval; a single `rm file` stays allowed; it defers to `cache-rm-redirect` when every delete is a cache delete and exempting deletes strictly inside the job scratch dir `$CLAUDE_JOB_DIR/tmp`; bypass `SYG_ALLOW_RM=1`, only for a deletion she approved), `lossy-pipe-guard` (blocks `git commit`/`git push` piped into any filter, and a `gh` read such as `gh pr checks` piped into head/tail/sed; a project opts its own gh wrapper commands in with `SYG_LOSSY_PIPE_GH_WRAPPERS`, a whitespace-separated list of wrapper tokens), `cwd-drift-guard` (blocks a bare `git` command run from a subdirectory whose pathspec only exists from the repo root, such as `git add docs/x.md` from inside `pkg/sub`; it asks the filesystem, so it needs no per-repo config), `upstream-submission-guard` (blocks `gh pr/issue create|new|comment|review|edit`, a commented `close`/`reopen`, and a `gh api` write, to a repo the owner doesn't own until the project's AI-contribution stance has been checked; bypass `SYG_UPSTREAM_CHECKED=<owner/repo>` on the gh command itself, once the check is done), `publish-gate` (blocks a `gh` command that would make a repo or gist public — `gh repo edit --visibility public`, `gh repo create --public`, `gh gist create -p/--public`, and a `gh api` write (explicit PATCH/PUT/POST, or a field-flag write) to a `repos/OWNER/REPO` endpoint carrying `private=false` or `visibility=public` — until the going-public checklist has passed for that exact target; unblock `SYG_PUBLISH_CHECKED=<owner/repo>` in the session environment, colon-list ok, any non-empty value for a gist), `dispatch-posture-gate` (opt-in, OFF until a project sets `SYG_DISPATCH_SRC_RE`, an extended regex matched against the edited path relative to the project dir, e.g. `^(src|lib)/.*\.(ts|js)$`; then an inline Edit/Write/MultiEdit to a matching path blocks hard over 5 lines and once per commit at 5 or fewer, pointing at the `delegation` skill; subagent edits and `.claude/worktrees/` paths are exempt). Advisory staged-commit guard (never blocks, so no bypass env exists by design): `claim-shape-guard` (as a `git commit` is about to run, scans the staged diff's added lines for claim-shaped assertions such as "always populated" or "never null" — claims only the producer can settle — and delivers a verify-at-the-producer banner via `hookSpecificOutput.additionalContext`, the field PreToolUse actually delivers; `tracker/`, `backlog/`, `docs/`, `.claude/`, `.husky/` and every `*.md` are excluded). Turn-shape checks: `blocking-question-channel-check`, `turn-end-shape-gate`, `promise-ledger-check` (blocks a turn end once when the closing message defers work and nothing was filed this turn; filing means a write to a backlog/TODO file, a tracker, or a role file under `claude-memory/roles/`, and a project replaces that path list with `SYG_LEDGER_PATH_RE`). Prompt-time reminders: `queued-message-receipt`, `bare-token-binding-reminder`, `context-size-reminder`. Post-tool reminders: `pr-monitor-reminder` (after a `git push`/`gh pr create`, once per PR+head-SHA, reminds the session to arm a Monitor on `pr-ci-wait` instead of a hand-written poll loop; the banner reaches Claude via `hookSpecificOutput.additionalContext`, the field PostToolUse actually delivers — a bare stdout banner does not). `lib/delete_commands.py` is the delete analysis both rm guards share. `lib/shell_quotes.py` is the shared quote/heredoc scanner and command splitter (`simple_commands`/`command_pipelines`, `unwrap_runners`), pinned directly by `tests/shell_quotes.probe.sh` (cases ported from Tzurot's `shellQuotes.test.ts`). |
| `plugins/seyag/skills/council/` | `council` skill: how to use the council MCP server (model choice, debates, reading split panels). |
| `plugins/seyag/skills/advisor/` | `advisor` skill: escalates ONE knot to the strong lane — distill the sub-problem, dispatch a single strong-model subagent (never the transcript), weigh the answer like any reviewer's. Routing rule vs council and the escalation guardrails included. |
| `plugins/seyag/skills/usage-audit/` | `usage-audit` skill: weighted plan spend across every project folder on the machine, the delegation ratio, implied capacity, and a machine-local drift ledger (`~/.claude/usage-ledger.md`). Ported from Tzurot. |
| `plugins/seyag/skills/session-mining/` | `session-mining` skill: mines any project's session logs in three lenses (owner friction, agent-side misses and keepers, repeated manual procedures), then turns each finding into a rule, skill, hook or recorded guard. Ported from Tzurot; output stays machine-local under each project folder's `mined-corpus/`. Mined ranges go in a machine-wide ledger kept by `session-log mark`. |
| `plugins/seyag/skills/doc-audit/` | `doc-audit` skill: freshness and cost audit of the always-loaded context and the shared memory (verdicts per memory, the four-question cut test, spot-checks). Ported from Tzurot, machine-wide. |
| `plugins/seyag/skills/bug-remediation/` | `bug-remediation` skill: runtime evidence, root cause, an exhaustive class sweep (tests included), a regression test that fails pre-fix, a structural guard. Ported from Tzurot. |
| `plugins/seyag/skills/reuse-scout/` | `reuse-scout` skill: search for an existing primitive before writing new logic, and consolidate drifted duplicates. Ported from Tzurot. |
| `plugins/seyag/skills/delegation/` | `delegation` skill: the driver/worker model for code-heavy repos. The driver specs each unit (a fill-in spec template with project slots), dispatches it to a worktree-isolated `implementer` on the cheapest model that can do it, reads the full diff, transfers and commits. Covers the step-0 base self-heal, the transfer checks, the review-round cap, stale worktree and branch cleanup, concurrency and cloud units. Ported from Tzurot. |
| `plugins/seyag/skills/driver-choice/` | `driver-choice` skill: which model should drive a session. Classifies the next unit (big-picture vs drain), reads the plan meter's gap hint, and recommends a `/clear` + `/model` switch only at a clean boundary with the handoff on disk; the owner types `/model`. Lane-to-model mapping and the target band stay in machine-local memory. |
| `plugins/seyag/skills/discord-design-language/` | `discord-design-language` skill: the distilled Discord bot UI design language (3-second ack window, ephemeral-vs-public defaults, the customId delimiter invariant, fixed button order, the slash-command verb table, server-side checks on destructive confirms), usable when building or reviewing bot UI in any project. |
| `plugins/seyag/agents/implementer.md` | `implementer` subagent: carries out a tight spec exactly, runs the project's own checks, never commits, and reports in a fixed format. |
| `plugins/seyag/bin/safe-clean` | On every session's PATH. Deletes only regenerable caches (`__pycache__`, `node_modules`, `.pytest_cache`, `.ruff_cache`, `.mypy_cache`, `.turbo`, `htmlcov`, `.coverage`) inside a git repo; refuses symlinks, tracked content and everything else. `--dry-run`, `--find NAME [DIR]`. The `cache-rm-redirect` hook points hand-rolled `rm -rf`/`find -delete` on those names at it. |
| `plugins/seyag/bin/usage-sweep` | On PATH. Weighted token totals per model, per project folder and main-vs-subagent, from every `~/.claude/projects` session log, with the live `claude-usage` meter; `--points` prices each folder's share into meter points from `claude-usage`'s readings log. Counts each reply once at its largest output: Claude Code repeats a reply's usage on every content-block line (output growing as it streams), so summing lines overcounts about 2.2x. |
| `plugins/seyag/bin/session-extract` | On PATH. Writes a session's owner-lens (`.txt`) and agent-lens (`.agent.txt`) mining corpora, with `--since`. |
| `plugins/seyag/bin/session-log` | On PATH. Reads every project's session logs, and the claude.ai export archive (`~/Documents/claude-session-archive`, local wins on overlap): `list` (transcripts with their app session, times, turn counts, titles; `--paths-to FILE` writes the full paths for `session-extract`), `stats` (per-driver metrics: replies, tool-error classes incl. per-hook trips and classifier denials, bypass prefixes, block→retry, deduped tokens), `grep` (owner, agent or tool text, reminders stripped), `ledger`/`mark` (the machine-wide mining ledger at `~/.claude/mined-corpus/ledger.tsv`, keyed by app session, showing unmined ranges per lens). Times local for list/grep, UTC for the ledger; prints id prefixes only. |
| `plugins/seyag/bin/pr-ci-wait` | On PATH. `pr-ci-wait N [--sha FULL40]`: waits for a PR's CI (and, where configured, its review run) to settle, ported from Tzurot's `gh:ci-gate` — same sentinels (`CI_COMPLETE`, `CI_GATE_TIMEOUT`, `CI_GATE_STARTUP_FAILURE`, `CI_GATE_REVIEW_MISSING`), argument validation, head-drift check, and review-run grace clock, as a portable command any project's CI watch (a Monitor, or a background Bash task on a reduced toolset) can arm. `SYG_CI_ANCHOR` names the anchor workflow (unset falls back to a quiet-window rule); `SYG_CI_REVIEW` names the review workflow to assert (unset auto-detects `Claude Code Review`; set empty disables the assertion). Test knobs: `PR_CI_WAIT_POLL_S`, `PR_CI_WAIT_MAX_S`, `PR_CI_WAIT_GRACE_S`, `PR_CI_WAIT_HEARTBEAT_S`, `PR_CI_WAIT_SETTLE_S`, `PR_CI_WAIT_QUIET_S`. |
| `plugins/seyag/bin/repo-preset` | On PATH. `repo-preset show\|apply <owner/repo>`: makes a repo match the house preset via `gh api` — rebase-only merges, update-branch on, wiki off, minimal branch protection on the default branch (no forced pushes, no deletions); adopted from Tzurot's live settings, tweakable in one block at the top of the script. `show` is read-only. `apply --strict` additionally requires the `probes` check before merge. |
| `plugins/seyag/bin/context-audit` | On PATH. `weigh [DIR]` lists what a session there always loads, largest first; `refs` reports memory paths that no longer exist, dangling `[[links]]`, non-slug `name:` fields and index drift. Never touches `~/gdrive`. |
| `plugins/seyag/bin/branch-sweep` | On PATH. `branch-sweep [--apply] [--no-fetch] [--base <branch>]`: reports local branches whose tree is provably content-merged into the base (tree identity only, so squash-merges count where `git branch -d` refuses); dry run by default, `--apply` deletes exactly the ELIGIBLE ones. Skips the current branch, the base, main/master and every worktree checkout, always. |
| `plugins/seyag/bin/price-table` | On PATH. Generates the CC managed `modelPricing` table (verified real rates so CC does not price unknown ids at the opus-5 fallback): `emit\|merge\|apply\|sync\|audit\|json` — emit the candidate, merge it into the managed file's content, apply via a printed `! sudo install` line for the owner, sync OR-sourced rows against OR's models endpoint, audit transcripts for ids with no table row, or print the machine-readable table. Writes only the `modelPricing` key of `/etc/claude-code/managed-settings.json` (managed scope; never user settings). Hermetic probe: `tests/price-table.probe.sh`. |
| `plugins/seyag/bin/statusline` | Not on PATH — a settings.json `statusLine` entry points at it (the main statusline cannot come from a plugin). Renders the Deck's status bar: context window with a desync guard, provider split (Anthropic plan windows from the statusline input; on a z.ai-routed `ANTHROPIC_BASE_URL` the account's own quota via a dev-docs `zai-spend` binary; on an OpenRouter `base_url` a brand-yellow `openrouter.ai` label plus the remaining balance from `/api/v1/credits`, degrading to the plain gray host label when the credits cache is cold, malformed or the balance is zero; any other non-Anthropic base URL renders the host as a plain gray label, absent elsewhere → the segment quietly drops), effort drift vs per-model intent, cost escalation, model gradients, CC + SYG versions with update nudges. Deck-tuned segments degrade to the plain render off the Deck. Hermetic probe: `tests/statusline.probe.sh`. |
| `docs/local/adoption-tzurot.md` | (untracked, machine-local) The handover to Tzurot: which of its hooks and skills now have plugin versions, how they differ, and how to retire a twin. |
| `tests/run-probes.sh` | Runs every probe (hooks and `tests/*.probe.sh`). |

## Install

The plugin installs from a local marketplace, and the rules load through a user-level rules link:

```bash
claude plugin marketplace add ~/Projects/seyag
claude plugin install seyag@lbds137 --scope user
mkdir -p ~/.claude/rules && ln -s ~/Projects/seyag/plugins/seyag/rules/core.md ~/.claude/rules/seyag-core.md
```

**Why a rules link and not a hook:** Claude Code shows a hook's output to the session in full only up to about 10 KB (measured 2026-09-25: 9.5 KB arrived whole, 12 KB became a 2 KB preview). `core.md` is about 18 KB. Files in `~/.claude/rules/` load into every session in full. If the link is missing, the SessionStart hook says so in one line.

**Two copies, two kinds of change.** Claude Code keeps an installed copy under `~/.claude/plugins/cache/<marketplace>/seyag/<version>/` and reads the plugin's *inventory* from it: which hooks are registered (`hooks/hooks.json`), which skills and agents exist. The hook *scripts* and `bin/` run from `~/Projects/seyag/plugins/seyag` (checked 2026-09-25). So:
- An edit to an existing hook script, a skill's text or a `bin/` tool reaches sessions without a refresh (`/reload-plugins` for a running session).
- A new or removed hook, skill or agent, or any `hooks.json` change, stays inactive until the installed copy is refreshed. Bump `version` in `plugins/seyag/.claude-plugin/plugin.json`, commit, then:

```bash
claude plugin marketplace update lbds137
claude plugin update seyag@lbds137 --scope user
```

and run `/reload-plugins` in each session. `/clear` does not reload hooks; only `/reload-plugins` after the install refresh does. The SessionStart hook prints `seyag plugin <version>` on every start (so a fleet tool can read each live session's version from its log) and warns in one line when the installed copy's `hooks.json`, skills or agents differ from the source.

**Headless runs** (`claude -p`, SDK scripts; `CLAUDE_CODE_SESSION_ATTENDED=0`) skip the turn-shape hooks, which are about talking to a person. The shell guards still run. The rules file still loads, at about 4.5k tokens per call.

**Fail-open:** `run.sh` skips a hook that has a syntax error instead of letting bash's exit 2 block every Bash call.

**Heredoc edit guard:** `python-heredoc-edit-guard.sh` blocks an inline `python3`/`node -e` script only when it writes a target it also reads (a read-modify-write edit). A script that reads inputs and writes a different output, which is routine in data-processing projects, passes. Bypass: `SYG_ALLOW_HEREDOC_EDIT=1`.

## Project overrides

If a project has its own copy of a hook under the same name, `.claude/hooks/<same-name>.sh`, the plugin's version stands down in that project and the project's version runs. This way Tzurot, which still carries its own copies, doesn't get every check twice. The same applies to the rules: `core.md` says project CLAUDE.md and `.claude/rules/` take precedence.

## Bypass tokens

To get one command past a blocking guard on purpose, put an env prefix on that command:

| Token | Guard |
|---|---|
| `SYG_ALLOW_HEREDOC_EDIT=1` | python-heredoc-edit-guard |
| `SYG_ALLOW_CACHE_RM=1` | cache-rm-redirect (an rm the owner approved) |
| `SYG_ALLOW_RM=1` | recursive-rm-guard (only a deletion the owner approved in this conversation) |
| `SYG_ALLOW_GREP_DOLLAR=1` | grep-escaped-dollar-guard |
| `SYG_ALLOW_BROAD_WALK=1` | broad-walk-guard (a walk meant to be broad) |
| `SYG_UPSTREAM_CHECKED=<owner/repo>` | upstream-submission-guard (after the AI-stance check passed; put it in the gh command's own prefix — a mention elsewhere in the command text does not count — one assignment per non-own repo) |
| `SYG_PUBLISH_CHECKED=<owner/repo>` | publish-gate (after the going-public checklist passed for that exact target; read from the session environment the hook runs in, never from the command text — colon-separated list ok, any non-empty value unblocks a gist) |

The context-size reminder has two tuning variables: `SYG_CONTEXT_THRESHOLD` (in tokens, default 500000) and `SYG_CONTEXT_COOLDOWN_MIN` (default 30).

The prompt hooks keep one small state file per session in `/tmp/claude-<uid>/` (`queued-receipt-state-*`, `context-reminder-*`). The SessionStart hook deletes those older than `SYG_STATE_MAX_DAYS` days (whole days, default 7); a live session rewrites its receipt state on every prompt. Tzurot's copies write the same names into the same dir; Tzurot's own session-start hook doesn't prune, but any other project's session start prunes for everyone.

## Tests

```bash
tests/run-probes.sh
```

`tests/replay-hook.sh <hook-name> [--since N]` replays one Bash-matching hook against the Bash commands recorded in local Claude Code session logs and reports what it would have blocked, without changing anything. `tests/replay-stop-hook.sh <hook-name> [--since N]` does the same for a Stop hook: it rebuilds the transcript as it stood at every turn end and reports which turn ends the hook would have blocked, next to the blocks the logs actually record.

Runtime dependencies for the hooks: bash, `jq`, `python3` and GNU grep.

## License

MIT, see `LICENSE`.
