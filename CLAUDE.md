# seyag

The portable Claude Code process layer for every project on Lila's Steam Deck: hooks, rules, skills, the implementer agent. The "Seyag" session (role file `roles/seyag.md` in claude-memory) is the plugin's author. The "Deck management" session installs releases and coordinates reloads.

## Gate
`bash tests/run-probes.sh` from the repo root, every probe PASS, before any push. A new or changed hook is also replayed against local session logs first, and its blocked set sampled: `tests/replay-hook.sh <hook> --since 7` for a Bash-matching hook, `tests/replay-stop-hook.sh <hook> --since 7` for a Stop hook.

## How changes ship
- Branch, PR, CI probes plus Claude review. A non-draft PR rebase-merges itself once the review passes and probes are green; a draft is held for Lila; a PR that changes the review workflow merges by hand. No direct pushes to main.
- Implementation over 5 lines, prose included (owner's ruling 2026-09-25), goes through the `delegation` skill: spec in `.claude/dispatch/` (gitignored); worker in a hand-made worktree (`git worktree add -b worktree-agent-<x> .claude/worktrees/<x> <base>`), dispatched WITHOUT the isolation flag and pointed at the worktree's absolute path (a worktree-isolated driver session, e.g. one that entered a worktree itself, cannot reach a second worktree, so there the worker edits the driver's tree directly and the transfer step is skipped); the driver reads the full diff; a fresh-context review agent; transfer with the skill's block; probes from the main checkout.
- The step-0 self-heal block in the delegation skill is the one sanctioned `git reset --hard` in this repo.
- A release is one version bump of `plugins/seyag/.claude-plugin/plugin.json` per merged batch. Installing it (`claude plugin marketplace update lbds137 && claude plugin update seyag@lbds137 --scope user`; these keep the install record and statusline version current, while the code loads from this checkout, so `/reload-plugins` is what puts a merge live) and asking Lila to `/reload-plugins` the open sessions is the Deck management session's job: message it when the merge lands (auto-merge or by hand), with the version.
- The marketplace installs from this local checkout's working tree, so keep the main checkout on `main`; release branches live in their own worktrees.

## Ceilings and landmines
- `plugins/seyag/rules/core.md` is always-loaded in every session on the machine (19.7 KB at 0.3.8): every added line is paid on every turn everywhere. Cut before adding.
- Probes pin message text and output shapes; a wording change usually needs its probe changed in the same diff.
- `hooks/session-start.sh` prints `seyag plugin <version>` as its first line on every start; `deck-sessions` (dev-docs) reads it from session logs. Keep the prefix.
- Session-mining corpora and reports under `~/.claude/projects/*/mined-corpus/` are private working material; only operationalized outcomes (a rule line, a skill step, a hook) enter this repo.
- Local-only list: nothing here needs secrets, a database or live services.
- Public repo, built for anyone's use: every feature is a generic, configurable mechanism (env var, config file, frontmatter field). New tracked text never names the owner's private sessions, private projects, personal paths or machine-only tools; that wiring lives in the machine's own config, and fixtures use invented names. Existing machine coupling is listed in `tests/coupling-allowlist.txt` and shrinks rather than grows.
