---
name: change-lanes
description: 'Three lanes and change-class classifier for docs-only and bookkeeping changes. Use when deciding where a docs or bookkeeping change lands, setting up policy, wiring CI skips, or replaying in report mode.'
---

# Change lanes (`change-lanes`)

Keep two questions separate:
1. **Lane question:** *May this ref update bypass branch/PR review?*
2. **Classifier question:** *Which heavy CI checks are irrelevant to this tree diff?*

Answering them together either runs full code CI on closeout bookkeeping or weakens review on standalone prose changes.

## 1. The three lanes

| Change | Lane | CI | Review |
|---|---|---|---|
| **1. Closeout bookkeeping** (tracker, backlog, or status updates that close a unit) | Rides on the unit's own PR | No extra CI run (shares the unit PR's run) | Reviewed with the unit PR |
| **2. Standalone ledger data** (`backlog/`, `tracker/`, or status files only) | Direct to the integration branch **only** where the repo opts in and a pre-push lane guard enforces the class | Push CI still runs (saves PR overhead, not CI) | Bypasses PR only under the guard + store lint |
| **3. Prose docs** (`docs/**`, root `*.md`) | PR in every repo | In-run `change-class` step may skip heavy code jobs; one always-reporting required gate | AI review always runs (`paths-ignore` only for wholly optional workflows, never review) |

### Lane 2 boundaries
- The pre-push lane guard is planned and tracked in this repo's backlog, not shipped yet; until it lands, a repo keeps its own direct-push hook.
- A local pre-push guard is an **accident guard, not branch protection**: a ruleset admin bypass is actor-wide.
- Where a repo's rules require a store lint before direct commits, lane 2 stays closed until a schema/store validator exists.

## 2. The classifier (`change-class`)

```sh
change-class classify [--repo DIR] --base REV --head REV (--policy FILE | --policy-ref REV) [--policy-path PATH] [--json] [--timeout SECS]
```

Default stdout emits six `key=value` lines in fixed order for `$GITHUB_OUTPUT`:

```text
verdict=exempt|full
classes=<comma-separated class names, sorted; empty when full>
skip=true|false
mode=report|enforce|none
policy=<git blob sha of the policy bytes, or none>
reason=<one short line, no newlines>
```

- `skip=true` only when `verdict=exempt` **and** `mode=enforce`.
- `--json` emits one JSON object with the same six keys (`skip` as a boolean) plus `paths` (`path`, `status`, `old_mode`, `new_mode`, `class`, `reason`).
- Exit code is `0` for any verdict (`full` included) and `2` for usage errors.

### Fail-to-full rules
`change-class` inspects `git diff-tree -r -z --no-renames` (`--raw` and `--numstat`) and fails to `verdict=full` on the first tripwire:
- **Whole-diff checks (1–9):** `policy-missing:`, `policy-invalid:`, `unknown-base:` / `unknown-head:`, `git-error:`, `timeout:`, `empty-diff:`, `too-many-files:` (`> limits.max_files`), `too-many-lines:` (`> limits.max_lines`) or `file-too-large: <path>` (`> limits.max_file_lines`), `binary: <path>`.
- **Per-path checks in diff order (10–13):**
  - `mode: <path>` — status outside `A`/`M`/`D`, any old or new mode not `100644` (rejects symlinks `120000`, gitlinks `160000`, executable files `100755`, type/mode changes), or a `D` entry in a class without `allow_delete = true`.
  - `path-encoding: <path>` — path bytes are not valid UTF-8.
  - `denied: <path>` — matches a built-in hard-deny glob or a policy `deny` glob (deny wins over every class).
  - `unclassed: <path>` — matches no declared class.

### Hard-deny families and glob semantics
- **Hard-deny families (case-insensitive, never loosenable by policy):**
  - Control files: `.github/**`, `**/.git*` (`.gitattributes`, `.gitmodules`, `.gitignore`, `.github`), `**/CODEOWNERS`.
  - Agent instructions: `**/.claude/**`, `**/CLAUDE.md`, `**/CLAUDE.local.md`, `**/AGENTS.md`, `**/GEMINI.md`, `**/.cursorrules`, `**/.cursor/**`.
  - Hooks: `**/.husky/**`, `**/.pre-commit-config.yaml`, `**/lefthook.yml`, `**/lefthook.yaml`, `**/.githooks/**`, `**/hooks/**`.
- **Glob semantics:** anchored at the repo root against `/`-separated paths. `**` as a whole segment matches zero or more segments; `*` matches non-`/` characters; `?` matches one non-`/` character; all other characters are literal. `*.md` matches root-level Markdown only; `**/*.md` matches any depth. Class globs are case-sensitive.

## 3. Policy format (`.github/change-class.toml`)

```toml
version = 1
mode = "report"            # "report" (default when absent) | "enforce"
deny = ["docs/generated/**"]   # optional extra deny globs

[limits]                   # optional table; defaults shown
max_files = 50
max_lines = 2000
max_file_lines = 300

[class.docs]
paths = ["docs/**", "*.md"]
allow_delete = false       # optional, default false

[class.ledger]
paths = ["backlog/**"]
```

## 4. Trust rules and rollout

- **Read policy from the base:** CI must pass `--policy-ref <base sha>` (reading `.github/change-class.toml` via `git cat-file blob <base>:.github/change-class.toml`), never the PR head or working tree.
- **Self-guarding policy path:** `.github/change-class.toml` lives under `.github/**` (hard-denied), so any PR that edits the policy always runs `full` CI.
- **No verdict reuse across base changes:** re-classify against the current base commit on every run.
- **Report-first rollout (`change-class replay`):**
  1. Start with `mode = "report"`.
  2. Replay historical merged PRs with `change-class replay --repo DIR --policy FILE` over `ID<TAB>BASE<TAB>HEAD` pairs from each merged PR's landed range (for rebase-merged PRs, `mergeCommit~N..mergeCommit` where `N` is the PR's commit count).
  3. Switch to `mode = "enforce"` only after the replay clears the repo's decision rule: projected billed minutes saved over the threshold the repo sets, **and** zero false exempts (an exempt PR whose historical heavy jobs failed, with every hit hand-read).
