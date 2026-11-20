# Changelog

All notable changes to the seyag plugin. Newest first. One `## <version> - <YYYY-MM-DD>` section per released version; under it, `###` categories in fixed order — Breaking Changes, Features, Bug Fixes, Improvements, Chores, Tests — empty ones omitted; items are `- **scope:** description (#PR)`, written from the version's merged commit subjects.

## 0.3.194 - 2026-11-19

### Features

- **config_env:** `lib/config_env.py` joins as the python twin of `hooks/lib/config-env.sh`: same config files, precedence (user then project, project overwrites user, the environment wins over both even set-but-empty), mechanical key rule, refusals and warning text byte-for-byte; hand-parsed on purpose, because tomllib accepts a different subset and words its errors differently. Every python bin in `bin/` (17, plus the `zai-spend` link) adopts it before its first knob read and its shebang becomes `env -S python3 -I -B`; hook children keep inheriting `run.sh`'s shell exports. User config now reaches the knobs those bins read: `SYG_CREDIT_{LEDGER,GRANTS,ANCHOR,WHEN,SETTLE_DAYS,ROUTE}`, `SYG_KEYS_{STORE,NAME,WITH_KEY,LEGACY_FILE,TIMEOUT_S,LOCK_WAIT_S,STALL_S}`, `CC_ROUTE_KEYS`, `PRICE_TABLE_MANAGED_FILE`, `SYG_NEEDS_OWNER_SECTION`, `SYG_AGY_{SUMMARIES_DB,BRAIN_DIR,CONVERSATIONS_DIR}`, `CLAUDE_USAGE_TTL`, `SYG_WSDIFF_LENIENT_NAMES`. `SYG_AGY_BRAIN_DIR`/`SYG_AGY_SUMMARIES_DB` drop `envonly` and keep `path`; `SYG_OWNER_NAME` stays `envonly` (a project must not rename the owner in relay headers). (#354)
- **config_env:** a project `.claude/seyag.toml` can no longer set the security-material knobs — `_SYG_CFG_PROJECT_SECURE` in both loaders, list parity pinned by the (w) battery: `SYG_KEYS_NAME`/`SYG_KEYS_WITH_KEY` (a repo must not weaken the credential store: `--with-key` downgrades TPM binding, `--name` can break decrypt) and `ZAI_AUTH_TOKEN`/`SYG_CREDIT_WHEN`/`SYG_CREDIT_ROUTE` (a repo must not fake the token and route labels its spend is billed and audited by). Refused from project scope as `security-material knob`, settable from user config and the environment; owner ruling 2026-11-19. (#354)
- **replay-hook:** the replay tools inject a session id (filename stem / parent session dir, one jq pass) so session-gated gates replay non-vacuously, and both scrub the four persist-path env vars from the replayed environment. (#352)

### Bug Fixes

- **config_env:** a NUL byte in a config value truncates its line the way bash's C strings do (both loaders), so a bad value costs its own line instead of silently dropping every later export; the export loop gained a per-name guard, and the (w) battery asserts the line after a truncated one still applies. (#354)
- **session-stalled:** malformed `claude agents --json` entries (non-dict, missing or null sessionId, null pid) are skipped with one warn naming the index; a null name no longer prints as `None`; a transcript is matched by exact basename so a glob-character sessionId cannot cross-match another session's file; the find runs without `-quit`, making the error path deterministic instead of readdir-order dependent. (#354)
- **session-context:** non-object entries in the agents list and in `SYG_SESSION_CONTEXT_EXTRA_CMD` output are skipped with a per-entry warn instead of producing a phantom 0-token row or dying mid-list; when EVERY entry is skipped the run is loud again (exit 1, format-change alarm) rather than a clean empty table. (#354)
- **driver-busy-hours:** `--slug` values containing `/` or `..` are a usage error before any scan — a trailing slash used to resolve to an empty folder name and merge agy sessions that have no workspace. (#354)

### Improvements

- **tests:** the python-isolation lint requires `-I` AND a bytecode guard (`-B`, `-Xpycache_prefix=`, or a `SYG_PY_CACHE_ARG` reference) on every inline python3 site and tokenizes joined flag forms (`-Bc -uc -Xutf8 -Wignore:: -WI`, unspaced `-X/-W <val><<`); `claude-role`'s next_due import runs `python3 -I -B`; the heredoc-edit guard blocks unspaced `-X/-W <val><<'E'` forms; the changelog-format probe fails loudly when its mutation sed errors (a shim case proves a non-GNU sed no longer passes vacuously). (#354)
- **probes:** cut per-file shellcheck analysis memory via scoped phase functions (measured peaks 3675 MB → 632 MB and 1090 MB → 363 MB). (#351)

### Tests

- **probes:** `tests/config-env.probe.sh` gains the (w) python-parity battery (22 cases running BOTH loaders on identical fixtures, byte-compared env exports and stderr: valid/refusals/malformed/multiline/NUL/secure/CRLF/40-char-bound/foreign-symlink/SYG_CONFIG=0), list-parity pins that both loaders' harness, project-exec and project-secure lists stay equal, and an adoption pin (every python bin carries the `-I -B` shebang and the wiring call); `tests/config-reference.probe.sh` pins the agy rows' new `user only` rendering (x4) and the five security-material rows (x5). Red-first: all seven touched probes failed against the base (probe-red-check, rc=0). (#354)

### Chores

- **backlog:** store batch riding the release: TASK-1/9/12 flipped Done with dispositions (shipped #335/#332/#337), TASK-4 claimed, TASK-42 filed (cfg2b: bash consumers wire the loader; renumbered twice — 38 and 39 were taken by parallel merged tasks before this branch landed), TASK-17 carries the owner ruling (net added links: build), the prioritization pass landed separately (#353). (#354)

## 0.3.193 - 2026-11-19

### Improvements

- **skills:** railway-ops skill refresh operationalizing the TASK-7 inventory: a deploy-path and service-layout section (`railway up` and the GitHub-integration branch-to-environment mapping with per-service `watchPatterns` that skip untouched services, `railway deployment list --json` as the deployment-id source, `railway status --json` `serviceManifest` as the pre-touch readout, Config-as-Code hard cutoff 2026-12-01 with the IaC `.railway/railway.ts` migration pointer and the CLI-4.11.2-may-lack-`config` caveat), a dev/prod split section (two environments as the default with per-environment tokens, shared-tier secrets versus per-service overrides, PRs deploy nowhere unless PR environments are enabled, promotion as a dashboard-only operation, compare variable names never values), and an ops-edges section (deploy-time healthchecks with `healthcheck.railway.app` as the probe host, pre-deploy command semantics for migrations, volume-backed redeploy downtime, dashboard-side alerting and usage), plus staleness fixes for CLI 4.11.2 (`railway variables --set` exists but cannot delete or manage shared ones and prints values; the `railway down` warning). (#350)

### Chores

- **backlog:** TASK-36 flipped Done; TASK-37 filed (widen the coupling-lint token list toward the CLAUDE.md private-name rule; trigger: next lint touch or de-naming incident). The release also carries the store follow-ups that landed on main after the 0.3.192 release commit: the peer-session fold (TASK-34/35, TASK-36, TASK-8 notes) and review-round-1 de-naming of store text to local-only pointers. (#350)

### Tests

- **probes:** railway-ops probe gains block 18: six presence greps pin the refreshed skill text (the cutoff date, the deployment-list id source, the PR-deploy rule, the pre-deploy no-default-timeout, the healthcheck host, the IaC init verb). (#350)

## 0.3.192 - 2026-11-19

### Chores

- **backlog:** TASK-7 (railway-ops coverage inventory) closed Done, inventory only, nothing built: the tracked disposition records the ranked gap list — P0 deploy-path and service-layout skill text plus post-redeploy health verification (6 of 7 reference services carry no healthcheck; `wait <env> <svc>` verb candidate deferred with a trigger), P1 generic dev/prod environment-split skill text, a names-only `vars diff <A> <B>` verb candidate (the one CLI gap recommended for building, deferred with the same trigger), volumes and managed-DB skill text, P2 dashboard-side alerting/usage one-liners — and CLI 4.11.2 staleness findings for the railway-ops skill (`railway variables --set --skip-deploys` exists, `railway deployment list --json` supplies deployment ids, `railway down` gained `-e`, the linked-env `redeploy` trap re-verified current). Full inventory report lives in the private dispatch dir; tracked text stays generic. (#349)
- **backlog:** store batch riding the same PR: TASK-6 flipped Done with the owner-ruled headline metric (owner asks per merged PR, corrections/reverts paired; weekly per-category counts as context) and its store text de-named for the coupling lint; TASK-30 reopened In Progress with the one-probe-spike profile and bisect plan (second lane's claim); TASK-31 (bin SCRIPT_DIR resolution), TASK-32 (asks-lens round-3 follow-ups), TASK-33 (commit or gitignore pnpm-lock.yaml, gitignore node_modules), TASK-34 (railway-ops redeploy image-reuse vs HEAD rebuild, probe first), TASK-35 (redeploy wait + live-commit readout, Deferred) and TASK-36 (railway-ops skill refresh: inventory skill text, staleness fixes, IaC line) filed; TASK-8 carries a CLI-added updated_date line and the split-scout design notes from a released accidental-parallel claim. (#349)

## 0.3.191 - 2026-11-19

### Features

- **bin:** `session-log asks` — a deterministic owner-asks lens over local transcripts and the claude.ai archive: four kinds (`auq` AskUserQuestion calls, `bang` hand-the-owner-a-command lines, `deny` permission/classifier denials, `proseask` destructive/cleanup/merge questions with `bang` precedence), first-match mechanical-category classification (`prod-deploy`, `worktree-removal`, `scratch-delete`, `force-push`, `other`), event-uuid dedupe with local-over-archive priority, waiting-cost columns (`wait_s` to the next owner turn in the same transcript — an `AskUserQuestion`'s answer `tool_result` counts as the reply, deny rows carry no wait because they are block events rather than waiting asks, and compaction-summary entries are not owner turns; `expired` past 24h or unanswered), `structural`/`text` privacy classes (`--no-text` rows carry no text (it still carries the project name and the 8-char session id) and may leave the machine to a generic read lane), `--summary` and `--json` aggregates, `--kinds`/`--category` filters, and the shared `--since/--until/--project/--app` filters. Deterministic and re-runnable by design: no mining-ledger lens, no extract files. (#348)

### Improvements

- **skills:** the session-mining skill documents the asks lens — kinds, the no-ledger-lens rule, the mechanical-vs-genuine disposition rule (every repeated mechanical category gets `build-the-check <what>` or `stays-human (<why>)` in the run report), the two privacy classes and their routing boundary, the weekly/monthly cadence, and the headline metric (owner-ruled: owner asks per merged PR per repo, corrections/reverts paired; weekly per-category counts as context). (#348)
- **bin/shellcheck-gate:** chunked, gate-locked shellcheck runner bounds the gate's memory spike; the local gate recipe runs it directly. (#347)

### Tests

- **probes:** the session-log probe gains the asks fixtures and ~50 assertions: per-kind detection and `bang`-over-`proseask` precedence, category classification, uuid dedupe across local and archive, wait pairing through the real AskUserQuestion answer shape (non-error `tool_result` with the matching `tool_use_id`), error-result non-answers, mid-turn enqueue pairing, classifier-availability and output-echo non-matches, the proseask keyword requirement (a modal question without a destructive keyword emits no row), the archive mixed-clock skip, locally-duplicated owner turns still pairing, `--summary`/`--json` shapes with nulls, `--no-text` privacy across every output path, `--max` capping rows but never the summary, and exit codes 0/1/2. (#348)

## 0.3.190 - 2026-11-19

### Features

- **tracking:** the repo adopts a backlog.md task store: `backlog/` at the repo root (`config.yml` with statuses To Do/In Progress/Done/Deferred and the label list, 30 migrated tasks created through the pinned CLI), `package.json` pinning `backlog.md@1.55.3`, and the tracked `.claude/settings.json` opt-in `SYG_TRACKING_SURFACE=backlog-md` (pin and store land together per the skill's stale-opt-in guardrail). The multi-session claim convention — claim via `assignee` plus `status: In Progress` in one CLI pass, never edit another session's in-progress task — is documented in the backlog-md skill. (#345)

### Improvements

- **bin:** safe-worktree-clean's restore hint recreates per-worktree refs under neutral `refs/seyag-restored/<plan-id>/` names. (#344)

## 0.3.189 - 2026-11-19

### Bug Fixes

- **bin:** fixup-push's `--onto-base` checkout refusal names the untracked-file collision: git's own stderr is discarded at that call, so an untracked file blocking the rewritten tree used to surface only as "checkout of the rewritten branch failed"; the refusal now ends "(an untracked file colliding with the rewritten tree is the usual cause)". (#343)

### Tests

- **probes:** fixup-push probe pins the step-13 "worktree changed during the run" refusal through both diff arms (a gh-shim side effect stages or dirties a tracked file on the second `pr view`; each arm proven load-bearing by its own neutered-guard canary), pins the empty-commit `rebase proof failed` refusal (modern git takes the patch-id proof's exit path; the probe cannot distinguish it from the count check, so a dedicated canary proves the guards load-bearing), and pins the new untracked-collision refusal text (red at base). (#343)

## 0.3.188 - 2026-11-18

### Features

- **bin:** `pr-open` runs `upstream-submission-guard.sh --check` as step 1 of its chain: PASS proceeds, BLOCK/UNKNOWN exit before `gh` with the verdict line re-printed and BLOCK's stance guidance passing through; a missing `python3` skips it with the scans (fail-open parity, the skip note names all three); `SYG_PR_OPEN_UPSTREAM_CHECK=0` skips it, the 0-disables vocabulary of `SYG_PR_BODY_CLAIM_SCAN`. (#341)

### Bug Fixes

- **config-env:** a project `.claude/seyag.toml` can no longer set path-valued knobs. A cloned repo could aim `SYG_LAUNCH_RECORD_DIR` at any directory (launch-record then wrote and 14-day-pruned files there), append JSONL through `SYG_CLASSIFIER_LEDGER` into an arbitrary file (a `$( )` in a recorded command executed when the file was sourced), redirect `SYG_ROLE_PREAMBLE_FILE`/`SYG_ROLE_DIR`/`SYG_PROJECT_NAMES_FILE`/`SYG_DRIVER_CLONE_PROJECTS` writes and reads, and read an arbitrary file into session context through the role preamble. `knobs.tsv` gains a sixth `flags` column; `path` rows (51) are refused from project scope like `_CMD` knobs (`'$name' cannot be set from project scope (path knob)`) while staying settable from user config and the environment. (#342)
- **config-env:** environment-only rows are no longer accepted by the loader. `SYG_OWNER_NAME`, `SYG_AGY_BRAIN_DIR` and `SYG_AGY_SUMMARIES_DB` carry the new `envonly` flag and are refused from every config file with `'name' is environment only (not settable from a config file)` instead of being accepted and silently ignored by their readers. (#342)
- **config-env:** warnings never echo file content. A `.claude/seyag.toml` symlinked to a secrets file previously had whole `=`-less lines (secret values included) echoed to stderr via the malformed-line, invalid-section and malformed-key warnings; those three now print file, line and rule only, and every name-derived echo (unknown key, duplicates, refusals, value errors) is truncated to 40 characters. (#342)
- **config-env:** an invalid `[section]` header now closes the active section, so its followers can no longer land on the previous section's knob names (`[ claude_usage.zai ]` used to leave `week_reserve = 40` exported as `CLAUDE_USAGE_WEEK_RESERVE`); the followers warn as unknown keys. (#342)
- **config-env:** multiline-string bodies are skipped, not parsed as keys. The `"""`/`'''` opener still warns once, but the body lines (previously applied as ordinary knobs when the opener's key was settable, and still applied when it was unknown, refused or duplicate) are consumed to the closing delimiter; the sniff runs before key-name resolution, so every opener behaves the same. (#342)
- **config-env:** a bare token that is numeric-shaped but not a plain integer or float (`+5`, `1e3`, `1_000`, `0x1f`) warns with `unsupported value: number form not supported (use plain digits or a quoted string)` instead of the misleading strings-and-paths message, and a tab-less `knobs.tsv` row warns (`malformed row: skipped`) instead of being skipped silently; comment and blank rows stay silent. (#342)

### Improvements

- **config-env:** long values no longer stall every hook call. The basic-string decode is chunk-wise with a regex split (a bracket-glob split cost ~1 s per call on a 200 KB value), the key-validity check and env-name build are single-pass (`${path//./_}` + one regex), and the edge-whitespace trims only run when the edge actually holds whitespace. A 200 KB plain value loads in ~2 s (was >17 s); escape-dense values remain quadratic (a 200 KB `\t`-run exceeds 30 s) — hostile-input-only, filed for a follow-up (index-loop rewrite or a max-value-length cap). (#342)
- **bin:** `pr-open`'s `--repo` refusal reason is reworded (the guard can judge via `--check`; the wrapper stays own-repo-scoped by the owner ruling) and the header fork-base-gap paragraph is replaced — the default path's publish target is judged from the `GH_REPO` env, else cwd remotes, the same env the later `gh` call runs in. (#341)

### Tests

- **probes:** `tests/config-env.probe.sh` pins the path-knob refusals (top-level and sectioned forms, user-scope control), the envonly refusal in both scopes, the flags-coverage pins over the real registry (path heuristic with an 18-entry reasoned allowlist, envonly↔description parity, a required-list for bind/glob/db rows the heuristic cannot see), the content-free raw echoes and 40-char name bound, the invalid-header section reset, the multiline skip (mid-file, EOF, single-line, unknown-key opener, refused-key opener), the number-form message and the tab-less-row warn; the (f) battery is re-pinned byte-exact for the new message shapes. `tests/config-reference.probe.sh` moves its fixtures to the 6-field schema and pins flags validation, the `Config` column (`user + project` / `user only` / `env only`) and flags-on-internal refusals. Red-first: the new config-env cases (8) and the re-pinned batteries failed against the unfixed tree and pass after. (#342)
- **probes:** `tests/pr-open.probe.sh` gains fixture own-owner remotes with a `SYG_OWN_OWNERS` base env, a BASE_ENV hoist, a stale-comment fix, the pr-monitoring SKILL.md chain sentence synced, and cases 25-28 (whole-line-anchored BLOCK passthrough, UNKNOWN no-basis, toggle-off, python3-free skip), red-first at `d26a087`. (#341)

## 0.3.187 - 2026-11-18

### Bug Fixes

- **worker-sandbox, gate-sandbox:** a sibling linked worktree (outside its main checkout) whose `.git` gitfile was replaced by a `git init` directory previously passed `worker-sandbox`'s no-flag `worker-tree-check "$PWD"` call, allowing host git in `worker-sandbox` and `gate-sandbox` to run that repository's config (such as `core.fsmonitor`). New opt-in knobs `SYG_WORKER_SANDBOX_REPO` and `SYG_GATE_SANDBOX_REPO` name the main checkout top directory: when set, `worker-sandbox` and `gate-sandbox` validate that the path is an existing directory and run `worker-tree-check --repo` before any host git runs on the tree (refusing a swapped sibling or a tree belonging to another repo with exit 125 while keeping main-checkout runs passing), and `worker-sandbox` exports `SYG_GATE_SANDBOX_REPO` to `gate-sandbox`. Default behaviour when unset or empty is unchanged until a launcher sets the knob (an inherited `SYG_GATE_SANDBOX_REPO` now anchors the worker's own check too). (#340)
- **worker-tree-check:** the tree's own entry check now refuses a `commondir` or `gitdir` pointer file containing a NUL byte (`the entry's commondir holds a NUL byte`, `the entry's gitdir holds a NUL byte`), closing the mismatch where bash's `read` dropped the NUL while git stopped at it, and refuses an unreadable `commondir` or `gitdir` pointer file (`the entry's commondir is unreadable`, `the entry's gitdir is unreadable`) instead of reporting it as a NUL byte, while `pointer()` returns 1 on an unreadable or NUL-containing pointer file (NUL scan capped at 4096 bytes) so the other-entries `worktrees/*/gitdir` loops silently skip it. (#340)
- **gate-sandbox:** the `EXIT` trap removing the private `gate-sandbox-vitetemp.*` directory is now armed immediately after `mktemp -d` succeeds instead of right before `bwrap`, so a later pre-launch 125 refusal (such as a bad `SYG_GATE_SANDBOX_RO_BINDS` entry) no longer leaks the temporary directory in `TMPDIR`. (#340)
- **worker-sandbox:** the pre-bind path check over `--settings`, the resolved claude binary and the bin directory now also refuses paths containing `->` (`a path with a colon or '->' can't be bound`), since `SYG_GATE_SANDBOX_RO_BINDS` splits on the first `->`. (#340)
- **gate-sandbox:** `SYG_GATE_SANDBOX_TOOLCHAIN` now follows symlink chains hop by hop for both each entry and its non-hidden child symlinks, refusing any hop inside or merely passing through the worktree (lexical spellings, symlinked components, symlinked ancestors, and chains that pass through the tree and hop back out) as well as cyclic or unresolvable prefixes with exit 125 (`refused: inside the worktree`, `refused: resolves inside the worktree`, `refused: unreadable`); non-hidden child symlinks with a chain into or through the tree, a cycle, or an unresolvable prefix now refuse the run with 125 where previously such children were skipped. (#340)

### Improvements

- **gate-sandbox, README:** comments and docs state what holds: IPv6 link-local routes (`fe80::/10`) are not walled while the host's own link-local addresses are walled as `/128` like every other host address; `SYG_GATE_SANDBOX_WALL` refuses a keyword or non-address before launch while a malformed address or prefix length that passes the shape regex fails the launch with 125 when its route is added (`--print-wall` prints it as given); and the README's `gate-sandbox` row matches `worker-sandbox`'s exit 125 wording (pre-launch check refusal vs namespace failure inside `bwrap` or `pasta`). (#340)

### Tests

- **probes:** red-first cases in `tests/gate-sandbox.probe.sh` (4c-pin toolchain `resolves inside the worktree` text, G1 swapped sibling with positive control, G2 missing repo directory, G3 main checkout, G3b/G3c linked worktree with matching and different repo anchors, G3d anchored default-profile sandbox build on a linked worktree, G4 `.vite-temp` mountpoint assert and scratch cleanup on a later 125, G6 toolchain symlink inside the worktree, G6b prefix-walk and `..`/`/./` cases, G6c entry through a symlinked ancestor with an in-tree plant, G6d/G6d-relative hop-by-hop chain-through-tree and absolute/relative stow-shape entries plus relative-chain marker-reachability positive control and mis-resolution refusal guard, G6e child symlink chain through the worktree), `tests/worker-sandbox.probe.sh` (W1 swapped sibling, W2 missing repo directory, W2b/W2c matching and different repo anchors, W2d inherited `SYG_GATE_SANDBOX_REPO` anchor on a swapped sibling, W2e inherited `SYG_GATE_SANDBOX_REPO` missing-directory message pin, W3 `--settings` path containing `->`, W4 sandboxed run with `SYG_WORKER_SANDBOX_REPO`), and `tests/worker-tree-check.probe.sh` (T1/T2 NUL byte in the entry's `commondir` and `gitdir`, T3/T3b root-guarded unreadable entry `gitdir` and `commondir` pointers, T4 oversized entry `commondir` pointer with a late NUL past 4096 bytes). (#340)

## 0.3.186 - 2026-11-18

### Features

- **pr-ci-wait:** new sentinel `CI_GATE_AUTOMERGE_SKIPPED` (exit 1). With `SYG_CI_AUTOMERGE_JOB` set, after a green release it reads the latest completed non-cancelled review run's jobs on its own attempt; when that job was `skipped` while every non-cancelled run on the SHA is green and the PR is open, non-draft, unmerged, still at this SHA and authored by the authenticated gh user, it reports the skip with the close/reopen re-trigger instead of `CI_COMPLETE`. Advisory: any lookup failure degrades to `CI_COMPLETE`. This repo opts in with `automerge`. The sentinel lists in the README, pr-monitoring skill and pr-monitor-reminder banner carry it. (#339)

### Improvements

- **versioning:** new "Citing the PR number" section: predict the number as the newest issue/PR + 1 and re-check before opening a non-draft PR; for a draft, flip ready only once the cite push's review run exists, since a flip seconds after a push can leave the surviving review run on a draft payload. (#339)

### Tests

- **probes:** `tests/pr-ci-wait.probe.sh` pins the race shape (two green review runs and a newer cancelled one; the newest non-cancelled is read) plus draft, merged, closed, red CI, other author, moved head, missing job, check off, and each lookup failure; the fake gh tells the job-list and PR-state calls apart from the existing job-count and head-SHA calls. (#339)

## 0.3.185 - 2026-11-18

### Bug Fixes

- **session-url-gate, pre-push:** a session link on an added line now blocks only when it is new in that diff: a link the same diff also removes (an edited line that keeps its link) is carried, matched by full link and by count. Netting is per diff call on commit and per commit on push and in the pre-push scanner, never across commits, so a link added in an unpushed commit still blocks on that commit; `--cc` merge hunks keep the old rule. private-term-guard is unchanged (`outbound_items(net_tokens=…)` is opt-in). (#338)

### Tests

- **probes:** session-url-gate pins an edited line keeping its link, staged or added in the same command (passes), a changed id and a second added copy (block), and an A-adds/B-edits push that blocks naming A, plus regression rows for an untouched link beside an unrelated edit and a `git mv` of a linked file (both pass); `tests/git-hooks.probe.sh` pins the same for the pre-push plus a merge adding its own link; private-term-guard pins that an edited line keeping a term still blocks. (#338)

## 0.3.184 - 2026-11-18

### Bug Fixes

- **worker-tree-check:** closes three ways a worker-written tree passed while host git would read a config the worker planted: with no `.git` above DIR it now refuses under `--linked`/`--repo` and, without them, refuses a HEAD anywhere from DIR up to `/` (a bare-shaped gitdir planted where the `.git` file was); a real `.git` directory now honours `--repo` (it must be MAIN_TOP's own) and runs the HEAD walk under it; and a DIR inside a linked worktree its repo still registers, whose `.git` file is gone, is refused. Also refuses a symlinked gitdir written with a trailing `/` or `/.` and a gitfile with a second line but no final newline, and `SYG_WORKER_TREE_CHECK_UNTRUSTED=/` now distrusts every path. Help text says what holds. (#337)

### Tests

- **probes:** `tests/worker-tree-check.probe.sh` pins each new refusal against the old script (red-first), with a positive control that git really runs the planted payload and a check that the probe itself never does, plus the documented no-scan of a main checkout without `--repo`. (#337)

## 0.3.183 - 2026-11-18

### Features

- **scratch-dir:** new bin: a per-session scratch dir (job tmp inside a job); recursive-rm-guard allows deletes strictly inside it, keyed on the hook payload's session id (`SYG_SCRATCH_ROOT`, `SYG_SCRATCH_RM_EXEMPT`). Implementer and delegation contracts point workers at it. (#335)

## 0.3.182 - 2026-11-17

### Improvements

- **rules:** core.md's ask-before-force-push line exempts `fixup-push`, which proves the rewrite and refuses otherwise; the push is announced (#334)

## 0.3.181 - 2026-11-17

### Features

- **fixup-push:** new bin: rewrites an open PR's own feature branch (autosquash with the base kept, or `--onto-base` rebase) and force-pushes it with a pinned lease, only after proving the rewrite (tree equality or an unchanged patch-id list) and that the branch is not default or protected; refuses any rewrite it cannot prove (#333)

## 0.3.180 - 2026-11-17

### Improvements

- **rules:** core.md's ask rule names the harness's ask tool (`AskUserQuestion`; agy: `ask_question`) and covers non-blocking owner decisions that already have a recommendation: they go out at the next turn end, with background work left running, instead of waiting for a later batch (#332).

## 0.3.179 - 2026-11-17

### Features

- **bin:** six session-log tools join the plugin: `classifier-denials` (auto-mode classifier denials per project, policy vs infrastructure), `chrome-loss-scan` (live sessions that lost their Claude in Chrome tools), `driver-busy-hours` (busy time of a project's main-loop sessions over a window), `session-stalled` (sessions whose last entry is an API error, with the quota reset time), `session-context` (context size per running session, flagged past a threshold) and `relay-ruling` (builds a relayed ruling's text from the transcript, never from memory) (#331).
- **session-context:** another harness's sessions join through `SYG_SESSION_CONTEXT_EXTRA_CMD` (a command printing a JSON array), labelled `SYG_SESSION_CONTEXT_EXTRA_MODEL` and flagged at `SYG_SESSION_CONTEXT_EXTRA_THRESHOLD`; a failing command warns on stderr and keeps the Claude rows. Flag thresholds are `SYG_SESSION_CONTEXT_THRESHOLD` (500000) and `SYG_SESSION_CONTEXT_THRESHOLD_FABLE` (200000), validated as whole numbers of at most 15 digits (a bad one exits 2); a row whose `tokens` is not a number takes the failure path, and a row-building failure exits 1 instead of printing nothing; a session with no working directory shows a blank folder, and a non-string name, folder, sessionId or status (in the agents list or an extra row) reads as blank or its default (#331).
- **relay-ruling:** `SYG_OWNER_NAME` names the owner in the relay header; the destructive-step line names the section from `SYG_NEEDS_OWNER_SECTION` (#331).
- **session-stalled, driver-busy-hours:** knobs `SYG_STALLED_ZAI_TZ`, `SYG_AGY_SUMMARIES_DB` and `SYG_AGY_BRAIN_DIR`; `SYG_STALLED_NOW` is the test seam (#331).
- **classifier-denials:** the project-name prefix strip is derived from `$HOME` (#331).
- **bin:** the six tools read transcripts from `CLAUDE_PROJECTS_DIR`, else `${CLAUDE_CONFIG_DIR:-~/.claude}/projects`; the python tools (`chrome-loss-scan`, `driver-busy-hours`, `relay-ruling`) read their knobs from the environment only, not config.toml (#331).
- **classifier-denials:** a projects root whose path holds glob characters (`[`, `*`, `?`) is read as a literal path, and a transcript line that is a bare JSON string or list is skipped instead of failing the run; a line whose timestamp is not a string is skipped too (#331).
- **chrome-loss-scan:** a transcript that can't be opened or read is reported as `unreadable` (`unknown` in the text output) and exits 1, instead of a traceback; a session id that isn't a string is reported as `no-transcript` and exits 1, instead of a crash; transcript records that aren't JSON objects are skipped; a projects root with glob characters is read as a literal path; a delta's names that are not a list, and list items that are not strings, are ignored (#331).
- **relay-ruling:** a message, origin or attachment field that isn't an object reads as empty, so the lookup still finds the owner's turn; a non-string text part is skipped, a non-string timestamp reads as an unknown time, and a non-string session id reads as missing (#331).
- **driver-busy-hours:** the help text describes the Antigravity (agy) merge and its knobs; an empty `CLAUDE_PROJECTS_DIR`, `SYG_AGY_SUMMARIES_DB` or `SYG_AGY_BRAIN_DIR` counts as unset; a transcript message that is not an object, or has a non-string model, adds no reply to the per-model counts (its timestamp still counts toward busy time); a non-string id counts as no id (#331).
- **session-context:** a reply whose token counts are not numbers is skipped, so an older reply counts instead of the session showing 0 tokens; a non-string model reads as blank (#331).

### Tests

- **session-log tools:** hermetic probes `tests/classifier-denials.probe.sh`, `tests/chrome-loss-scan.probe.sh`, `tests/driver-busy-hours.probe.sh`, `tests/session-stalled.probe.sh`, `tests/session-context.probe.sh` and `tests/relay-ruling.probe.sh` (stub `claude`, fixture transcripts, fake `HOME`; the old agy database names are ignored) (#331).
- **coupling-lint:** tokens match case-insensitively, so a lowercase owner or tool name no longer slips past the allowlist (#331).

## 0.3.178 - 2026-11-17

### Bug Fixes

- **python-heredoc-edit-guard:** an interpreter option between the name and the inline marker no longer defeats the guard (`python3 -I -c`, `python3 -X utf8 - <<E`, `python3 -Ic`, `python3 -I<<E`, `node --no-warnings -e`, `node --max-old-space-size 4096 -e`); versioned names (`python3.12 -c`) match; `node -p`/`-pe`/`--print` count like `-e` (#330).
- **hooks:** a caller's relative `PYTHONPYCACHEPREFIX` never reaches the hooks' `python3 -I` (they get `-B`); `run.sh` exports `SYG_PY_CACHE_ARG=-B` for it, and only an absolute prefix becomes `-Xpycache_prefix` (#330).

### Tests

- **python-isolation:** the lint covers path-prefixed, versioned and bare `python` call sites; the runtime rows add `live-checkout-guard`, which reaches its `python3 -c` judge; a docstring in `hooks/lib/upstream_guard_lib.py` now says `Python` so prose stays out of the widened lint (#330).
- **statusline:** the fixture server runs under `python3 -I -B` (#330).

## 0.3.177 - 2026-11-17

### Bug Fixes

- **hooks, bin:** every inline `python3` (`-c`, `-`, a heredoc or here-string on stdin) in the hooks and bins now runs isolated (`-I`), so a module file such as `re.py` or `json.py` in the session's working directory can no longer shadow the standard library inside a hook. `-I` also ignores `PYTHONPYCACHEPREFIX`, so `run.sh` exports the bytecode cache as `SYG_PY_CACHE_ARG` (`-Xpycache_prefix=<dir>`, or `-B` when the caller set `PYTHONDONTWRITEBYTECODE` or no cache dir exists) and hooks call `python3 -I "${SYG_PY_CACHE_ARG:--B}"`; a direct run with it unset falls back to `-B`. `live-checkout-guard` drops its `PYTHONSAFEPATH` and `sys.path` strip for the same `-I` (#329).

### Tests

- **python-isolation:** `tests/python-isolation.probe.sh` lints every shipped inline `python3` site for `-I` (with a positive control over fixture strings), runs four hooks (one per invocation form) from a directory planting `re.py`/`json.py`/`shlex.py`/`subprocess.py` behind a `python3` shim, and checks no `__pycache__` lands in the plugin tree; `run.probe.sh` pins the `SYG_PY_CACHE_ARG` values; a run.sh row checks the prefix reaches the hook's python and bytecode lands under it (#329).

## 0.3.176 - 2026-11-17

### Breaking Changes

- **claude-role:** the launcher variables are renamed to the plugin's namespace: `CLAUDE_ROLE_HEADLESS` to `SYG_ROLE_HEADLESS`, `CLAUDE_ROLE_TASK` to `SYG_ROLE_TASK`, `CLAUDE_ROLE_NOW_EPOCH` to `SYG_ROLE_NOW_EPOCH`; the old names are ignored. A wrapper that still sets them maps them across (#328).

### Features

- **claude-role:** the role-file tool (`claude-role`: hook mode, `--board`, `--in-person`, `--json`, `--list`, `--path`, `--size`, `--set`, `--need`, `--need-done`, `--note`, `--next`) moves into `bin/` from the owner's machine tooling, with every machine coupling lifted into a knob: role dir `SYG_ROLE_DIR` (default `${XDG_DATA_HOME:-~/.local/share}/seyag/roles`), first-line context text `SYG_ROLE_CONTEXT_LINE` (empty by default: nothing is printed and nothing counts toward the cap), the instruction block as a template `SYG_ROLE_PREAMBLE_FILE` (`{role}`, `{path}`, `{needs}`, `{in_person}` replaced in one literal pass; a generic built-in text when unset), section names `SYG_NEEDS_OWNER_SECTION` / `SYG_IN_PERSON_SECTION` (defaults `Needs Owner`, `In Person`), board context sizes from `SYG_ROLE_CONTEXT_CMD`, route checks via `SYG_ROUTE_SHOW_CMD` and `SYG_ROLE_HEADLESS_ROUTES`. `--in-person` is the documented flag name (`--deck` stays an alias); the `--list` columns and the `--json` keys (`.deck`, `.needs`) are unchanged. The read verbs exit 1 with a message when the role dir is missing; hook mode stays silent. The head (context line plus instruction block) is one function shared by `--size`, `--set`'s cap check and the hook, so the size line and the hook output cannot drift. Not wired into `hooks.json` yet (#328).
- **driver-clone:** `driver-clone REPO LANE --name "Short Name"` (a parallel driver lane in its own clone, with a role file stub and a folder-trust bullet) joins `bin/`: projects dir `SYG_DRIVER_CLONE_PROJECTS`, an optional short-name table `SYG_PROJECT_NAMES_FILE` (unset: the base role's `role:` field is the short name and no row is written), closing step `SYG_DRIVER_CLONE_START_HINT`, test seam `SYG_DRIVER_CLONE_ROLE_BIN`. The base short name loses a CR and one layer of quotes and is refused, before anything is cloned, when it holds a quote, backslash, tab or newline (#328).
- **lib/next_due.py:** the due-time Next item parser claude-role reads (`## Next` bullets carrying `(due YYYY-MM-DD[ HH:MM])`) joins `plugins/seyag/lib/` (#328).

### Chores

- **coupling-lint:** `claude-role` leaves the lint's machine-tool token list (it ships in this repo now), with its two allowlist lines (#328).

### Tests

- **claude-role, driver-clone:** `tests/claude-role.probe.sh`, `tests/claude-role-escapes.probe.sh` and `tests/driver-clone.probe.sh` run hermetically against a temp role dir (`SYG_CONFIG=0`): the defaults, a byte-exact configured hook output (a `&` and `\1` role name, a template ending in a blank line), the section, context-command and route knobs, the missing role dir, the ignored old variable names, and both driver-clone name-table paths (#328).

## 0.3.175 - 2026-11-16

### Bug Fixes

- **mem-watch:** the threshold compares the raw MemAvailable kB instead of the one-decimal GB display value, so 1.95 to 2.0 GB now trips `--threshold-gb 2` (#327).
- **mem-watch:** a counter that vanishes or cannot be read is no longer read as 0 and then as a kill: with no value this pass nothing is compared, the first readable value is the baseline, and a smaller value (the slice restarted) rebaselines; only a larger value triggers. A non-numeric value counts as no value too. Lines print `n/a` for a missing value. A reset and a kill inside one interval read as a reset, so that kill is missed (#327).
- **mem-watch:** the counter search matches only `app.slice/memory.events` (not a child scope's) and takes this user's `user-<uid>.slice` first, else a candidate with no `user-N.slice` in its path, never another uid's (#327).

### Tests

- **mem-watch, mem-gate:** `tests/mem-watch.probe.sh` pins the just-under threshold (once and loop), a vanished counter, a non-numeric counter, a reset counter, own-uid preference, another uid's slice alone, a child scope, and a root below the user slice; the existing oom case uses the running uid; `tests/mem-gate.probe.sh` notes that the `owner_default` daemon exclusion and parent walk have no direct coverage (#327).

## 0.3.174 - 2026-11-16

### Features

- **mem-gate:** the shared memory gate (`mem-gate [--ok [MB]]`, `--wait [MB] [--timeout S] [--interval S]`, `--owner PID`) joins the plugin's `bin/`: exit 0 when MemAvailable is at least MB, 1 below it or timed out, 2 on a usage error, a meminfo without `MemAvailable` (also when it disappears mid-wait) or a lib that cannot be loaded, 3 when the owner is gone; MB defaults to the new `SYG_MEM_GATE_MIN_MB` knob (default 2048) and an explicit MB wins; test seam `SYG_MEM_GATE_MEMINFO` (#326).
- **mem-watch:** the memory watcher (`mem-watch [--threshold-gb N] [--interval S] [--once] [--owner PID]`) joins `bin/`: exits when MemAvailable drops below the threshold or the user app slice's `oom_kill` counter increments; the counter is searched under the new `SYG_MEM_WATCH_CGROUP_ROOT` knob (default `/sys/fs/cgroup/user.slice`), test seam `SYG_MEM_WATCH_MEMINFO`. `--interval 0` is a usage error (it would busy-loop), a meminfo without a `MemAvailable` line exits 2 instead of reading as below threshold, a `lib/owner.sh` that cannot be loaded exits 2, and the top-3 text prints `PID comm N MB` (#326).
- **lib/owner.sh:** the owner-tracking helpers (`owner_default`, `owner_init`, `owner_alive`, `owner_or_exit`) as a sourced `plugins/seyag/lib/owner.sh`, shared by `mem-gate` and `mem-watch`; `tests/shell-files.sh` lists `plugins/seyag/lib/*.sh` so shellcheck and the syntax probe cover it (#326).

### Tests

- **mem-gate, mem-watch:** `tests/mem-gate.probe.sh` and `tests/mem-watch.probe.sh` pin both tools against fixture meminfo and cgroup trees: thresholds, the knob, leading-zero numbers, wait timeout and recovery, the oom trigger, the missing-MemAvailable exit (also mid-wait), a lib that cannot be loaded, owner gone and usage errors (#326).

## 0.3.173 - 2026-11-16

### Breaking Changes

- **worker-sandbox:** runs `worker-tree-check` on the current tree before any host git runs on it (`--check` included), so it now refuses (125, "worker-tree-check refused", nothing runs) trees the check rejects without `--repo`: a linked worktree holding any nested `.git` (submodules, editable git checkouts) and a gitdir under `SYG_WORKER_TREE_CHECK_UNTRUSTED` (default `/tmp:/var/tmp:/dev/shm`); set that knob for hermetic fixtures under `/tmp` (#325).

### Bug Fixes

- **gate-lock:** the TERM/INT/HUP trap is installed before the command is forked, so a signal between the fork and the trap is no longer lost or fatal, and the final exit code is read with a second `wait` so a signal-interrupted wait can't report 128+N for a command that exited with its own code; the command now reads gate-lock's own stdin (a background job otherwise got `/dev/null`) (#325).
- **gate-sandbox:** `SYG_GATE_SANDBOX_ENV` entries must be variable names (anything else refuses with 125; the list is no longer expanded unquoted, so a glob can't match files); a `SYG_GATE_SANDBOX_TOOLCHAIN` entry resolving inside the worktree is refused with 125 and a symlinked entry is bound at its resolved target on its own path; an extra `SYG_GATE_SANDBOX_WALL` entry must be an address or CIDR (a keyword like `default` would have walled everything) and a malformed one refuses with 125 before anything prints; untracked secret-shaped files are masked at any depth outside `node_modules`, `.git`, `site-packages`, `dist-packages`, `.tox`, `.nox` and `target` (the pruned dirs keep a venv's `*.pem` CA bundles readable), not only the first five levels; pasta runs with `--dns none`, which silences its "Couldn't get any nameserver address" line on every worker run without changing name resolution (#325).

### Improvements

- **gate-sandbox, worker-sandbox:** comments and usage say what holds: masking is by name only at any depth, IPv6 link-local (not IPv4 169.254/16 on a non-default interface) is the unreachable-through-pasta exception, a device with a default route in any table counts as a default interface (broader than full-tunnel), exit 125 means a pre-launch check refused while a namespace failure inside bwrap or pasta exits with that tool's code, `SYG_WORKER_TREE_CHECK_UNTRUSTED` is read by `worker-tree-check`, and gate-sandbox runs host git on its tree so a worker-written tree wants `worker-tree-check` first; comment lines rewrapped to 100 columns (#325).

### Tests

- **probes:** `tests/gate-lock.probe.sh` pins INT and HUP forwarding (as TERM), stdin passthrough and that the old `GATE_LOCK_FILE` name does not override `SYG_GATE_LOCK_FILE`; `tests/gate-sandbox.probe.sh` pins the ENV and TOOLCHAIN refusals, a symlinked toolchain entry, the old `GATE_SANDBOX_ENV` name passing nothing, and vite scratch-dir cleanup on TERM and HUP; `tests/worker-sandbox.probe.sh` pins the tree-check refusal (forged gitfile, symlinked `.git` split from gate-sandbox's own refusal), the WALL shape refusals and the kernel-invalid `10.0.0.0/33` launch failure, a seven-levels-deep masked `.env`, multipath, nhid and prefixed-local rows in the `--print-wall` fixture, the old `WORKER_SANDBOX_ENV` name, and no pasta nameserver warning; `tests/worker-tree-check.probe.sh` pins that the old `WORKER_TREE_CHECK_UNTRUSTED` name is not read (#325).

## 0.3.172 - 2026-11-16

### Bug Fixes

- **gate-sandbox:** the worker profile's network wall now covers every address the host answers on, and every route (any routing table) through an interface that carries no default route, e.g. container bridges (docker, libvirt) and an interface-based VPN that doesn't carry the default route, not only loopback and the one address pasta copies in. The routes are added as `unreachable` inside pasta's namespace before bwrap runs and the launch fails with 125 if any add fails; the worker is out of pasta's user namespace (`--unshare-user` is now explicit) and cannot undo them. A host whose routes can't be read (an `ip` query fails, or the local table lacks 127.0.0.1) refuses with 125 rather than launch with a smaller wall. Not walled, by design: the default interface's own routes (the LAN; a full-tunnel VPN's own subnet), userspace VPNs with no interface, AF_VSOCK, and addresses the host gains after launch. `gate-sandbox --print-wall` prints the computed set, one prefix per line. New knobs `SYG_GATE_SANDBOX_WALL` and `SYG_WORKER_SANDBOX_WALL` add extra CIDRs.
- **gate-sandbox:** the worker profile now refuses with 125 when `ip` (iproute2) or `bwrap` is missing, or bubblewrap lacks `--size` (older than 0.10), instead of failing later in bwrap.

### Tests

- **probes:** `tests/worker-sandbox.probe.sh` asserts every host address unreachable from inside (docker0 is the live case on CI; only "refused" or "No route to host" counts), the knob as a live "No route to host" wall, `gate-sandbox --print-wall` on a stubbed fixture host and as live unreachable routes, that the worker cannot delete routes, flush the table or add rules (each failing with "Operation not permitted", CapEff zero), the fail-closed refusals (a failing `ip` query, a local table without loopback, no `ip`, no `bwrap`, a bwrap without `--size`) and the bad-CIDR refusal, the bad-tree-mode message, and the `SYG_WORKER_SANDBOX_ENV` and `SYG_WORKER_SANDBOX_PATH` knob rows; `tests/gate-sandbox.probe.sh` adds rows for `SYG_GATE_SANDBOX_TOOLCHAIN` and `SYG_GATE_SANDBOX_ENV`.

## 0.3.171 - 2026-11-16

### Features

- **gate-lock:** moved in from a machine-config repo as a generic tool; runs one gate command under a machine-wide flock (a busy lock waits, TERM is forwarded and waited out, exit 125 for its own errors); env knob renamed to `SYG_GATE_LOCK_FILE`.
- **gate-sandbox:** moved in from a machine-config repo as a generic tool; runs a command in a bubblewrap sandbox scoped to one git worktree, with a worker profile for whole headless workers; env knobs renamed to `SYG_GATE_SANDBOX_PROFILE`, `SYG_GATE_SANDBOX_TREE`, `SYG_GATE_SANDBOX_SCRATCH`, `SYG_GATE_SANDBOX_RO_BINDS`, `SYG_GATE_SANDBOX_ENV` and `SYG_GATE_SANDBOX_PATH`; new knob `SYG_GATE_SANDBOX_TOOLCHAIN` (the read-only toolchain paths, default unchanged).
- **worker-sandbox:** moved in from a machine-config repo as a generic tool; runs claude for a headless worker inside gate-sandbox's worker profile; env knobs renamed to `SYG_WORKER_SANDBOX_TREE`, `SYG_WORKER_SANDBOX_SCRATCH`, `SYG_WORKER_SANDBOX_CLAUDE` and `SYG_WORKER_SANDBOX_RO_BINDS`; new knobs `SYG_WORKER_SANDBOX_ENV` (extra variables passed in; the launcher-specific default is gone) and `SYG_WORKER_SANDBOX_PATH` (inner PATH tail). The network wall refuses host loopback and the one address pasta copies from the host; the host's other addresses and the LAN answer, and names resolve only where the host resolves through nss-resolve or a non-loopback nameserver (wall hardening is a later unit).
- **worker-tree-check:** moved in from a machine-config repo as a generic tool; refuses a worker-writable git tree whose gitfile, nested repos or HEAD entries could make host git run attacker config, without running git on it; env knob renamed to `SYG_WORKER_TREE_CHECK_UNTRUSTED`.

### Fixes

- **gate-sandbox:** the worker profile no longer follows a `node_modules` symlink planted in a repo's main checkout. Its "this repo's own main checkout" test resolved the very link it was judging there, so a worker could get another repo's dependencies bound in and make the host write `.vite-temp` through the link. The source copy had the same hole; a main-checkout case in `tests/worker-sandbox.probe.sh` pins it.

### Tests

- **probes:** ported `tests/gate-sandbox.probe.sh`, `tests/worker-tree-check.probe.sh` and `tests/worker-sandbox.probe.sh`; new `tests/gate-lock.probe.sh`; new sourced helper `tests/sandbox-capable.sh` replaces whole-probe skips with a bwrap/pasta capability check, and CI sets `SYG_PROBE_REQUIRE_SANDBOX=1` so the sandbox cases can never be skipped there.

## 0.3.170 - 2026-11-16

### Features

- **mining-coverage:** moved in from a machine-config repo as a generic tool; checks that session-mining reports' `COVERED <extract> <first>-<last>` ledgers cover every extract line by line and prints each `HOLE` range.
- **pin-actions:** moved in from a machine-config repo as a generic tool; pins every GitHub Actions `uses:` in the given workflow files to a commit SHA with a version-tag comment, or lists the unpinned ones with `--check`; test seam renamed to `SYG_PIN_ACTIONS_GH`.
- **gate-run:** moved in from a machine-config repo as a generic tool; runs several gate steps in one directory with one log per step and exits nonzero unless every step passed (zero steps is exit 7).
- **mem-pressure-log:** moved in from a machine-config repo as a generic tool; appends one JSON line of memory and PSI pressure readings per run, with log rotation, for timer-driven diagnosis of memory dips; env knobs renamed to `SYG_MEM_PRESSURE_MAX_BYTES`, `SYG_MEM_PRESSURE_MEMINFO`, `SYG_MEM_PRESSURE_PSI` and `SYG_MEM_PRESSURE_STATE_DIR`.

### Tests

- **probes:** ported `tests/mining-coverage.probe.sh`, `tests/pin-actions.probe.sh`, `tests/gate-run.probe.sh` and `tests/mem-pressure-log.probe.sh`.

## 0.3.169 - 2026-11-16

### Features

- **rules:** core.md "Subagents by default": a review comes from another model family where one is reachable, same-family as a labelled fallback; new `SYG_CROSS_REVIEW_CMD` knob (user scope) advertised at SessionStart beside the memory and long-job gates (#320).

### Tests

- **probes:** session-start gains `SYG_CROSS_REVIEW_CMD` cases (line appended on startup/clear/compact, absent when unset, empty or multi-line, not gated by the rules component, the value printed and never evaluated); config-env gains user-scope apply and project-scope refusal cases (#320).

## 0.3.168 - 2026-11-16

### Features

- **bin:** `keys get NAME [NAME...]` and the new `keys env NAME [NAME...]` resolve several names with at most one store decrypt (one TPM call instead of one per key); `env` prints `export NAME=<shell-quoted>` lines for `eval`; all or nothing: any missing name exits 1 with nothing on stdout; a non-UTF-8 or line-breaking value is a clean error (#319).

### Tests

- **probes:** `tests/keys.probe.sh` gains multi-name cases: argument order, one decrypt per call (counted on the mock log), zero decrypts when env covers every name, all-or-nothing on a missing name, duplicate-name and line-break errors, `env` eval round-trip of a value with quotes and spaces, and CR or non-UTF-8 values as clean errors (#319).

## 0.3.167 - 2026-11-12

### Features

- **bin:** `probe-red-check <probe> [base]` proves a new probe red against a base ref (temp detached worktree, realpath-guarded against outside-tree fabrication, RED/NOT RED/INCONCLUSIVE) and `pr-closeout <N> [--apply]` mechanizes the post-automerge close-out (MERGED gate, linked-issue closes with the exact Fixed-by comment, branch disposition via the real branch-sweep/`safe-worktree-clean --only`, dry run by default, HOLD left for the owner) (#312).
- **hooks:** `upstream-submission-guard.sh --check [<owner/repo>]` preflight: a wrapper bin stance-checks a target before composing the publish command (stdout is one `PASS`/`BLOCK <owner/repo>[,…]`/`UNKNOWN <reason>` line, PASS exits 0, BLOCK/UNKNOWN exit 1; bare form resolves `GH_REPO` env, else cwd remotes; no bypass env applies; fail-closed where the hook is fail-open), with target/owner resolution single-sourced into `lib/upstream_guard_lib.py` (#316).

### Bug Fixes

- **bin:** the `safe-worktree-clean --apply-hold` naming-refusal hint now names the approval it waits on — "only on the owner's yes for that tree: re-run the dry run and apply with `--only <tree>`" — instead of the bare "name it with --only"; a commit-carrying tree whose only carrying reasons are `worktree-refs` / `bisect-refs` / `rewritten-refs` now says its count is the branch's beyond-base commits and per-worktree refs hold more, and a failed or vacuous commit count prints `?` instead of a real-looking `0` (#313).
- **hooks:** `blocking-question-channel-check`'s stripped-span placeholder is punctuation-conditional — a stripped span becomes ` . ` only when its text holds clause punctuation, else a plain space — so a punctuation-free span between a negator and the marker no longer manufactures a clause boundary (base silence restored; the pass fails open) (#314).
- **bin:** `pr-open`'s watcher arm line omits `--sha` when `--head` named a branch no local ref backs — pasting a `rev-parse` that resolves to nothing — and prints the fallback note on stderr while stdout stays the parseable arm line; pr-ci-wait then watches the PR's current head (#315).
- **docs:** the config table stops attributing pr-ci-wait's `SYG_CI_ANCHOR`/`SYG_CI_REVIEW` rows to `bin/pr-open` (it only arms the watcher; it never reads them), and `SYG_PR_BODY_BASE_REF`'s header note says the ref resolves even when `--base` names another base — the hook has no `--base` (#315).

### Chores

- **bin:** `safe-worktree-clean` re-wraps the ragged header/`--help` lines the holdscope batch left behind and comments the display-only `", "` split that builds the sweep tree names (`--json`'s `sweep_plan_trees` is unaffected) (#313).
- **docs:** restores the `(#PR)` placeholder on the format line, which a cite-fill replace_all had clobbered to `(#310)` (#313).
- **hooks:** the pending-marker-pass header re-flowed: the scan sentence runs to `SYG_BQ_PENDING_MARKERS (...)`, the paragraph-filter and banner notes sit after the negator paragraph, and the banner note names the conditional placeholder (#314).
- **docs:** the 0.3.166 bq-fp bullets shortened to commit-subject length; details stay in the hook header (authoritative) (#314).

### Tests

- **probes:** `tests/safe-worktree-clean.probe.sh` pins the reworded refusal (P31 with the reason-aware count, P40(ii), P42(ii)), adds the naming refusal under `--json` (stderr carries the line, stdout stays clean, P44), a detached-unreferenced bare-id refusal asserting the printed count (P25), a `rev-list --count`-failure case printing `?` via a git shim (P45), and the sweep parent pinning the same reason-aware count form at the sweep refusal (P46) (#313).
- **probes:** `hooks/blocking-question-channel-check.probe.sh` gains 4 cases: a punctuation-free code span and quoted span between a negator and the marker stay silent (red-first against the unfixed hook), a STOP word + "not" shape keeps firing after a punctuation-free span (base semantics restored, red-first against HEAD), and an em-dash inside a stripped span still makes the boundary (pins the widened punctuation class) (#314).
- **probes:** `tests/pr-open.probe.sh` gains the missing-local-ref arm-fallback case (arm line without `--sha`, fallback note, one gh call, exact stdout) and term-scan coverage for title-only blocks and body hits reported by line number (#315).
- **probes:** `hooks/upstream-submission-guard.probe.sh` gains 17 `--check` preflight cases (14 verdict runs and 3 output asserts): explicit own/non-own targets (stdout verdict line; BLOCK stderr carries the stance guidance and no bypass prefix), bare cwd resolution (own, non-own, all-candidates fork), `GH_REPO` env beating cwd remotes both ways, UNKNOWN pins (no own-owner basis fail-closed, unparsable target, no parsable GitHub remote in the cwd, unparsable `GH_REPO`), the two-arg usage error, control characters failing closed (a newline in the target arg yields exactly one UNKNOWN line; a newline in a bare-form remote URL fails closed through the parser's rejection), and a stdin pipe every case proves unread (red-first against the pre-extraction hook) (#316).

## 0.3.166 - 2026-11-12

### Bug Fixes

- **hooks:** `blocking-question-channel-check`'s pending-marker pass: balanced quoted spans (straight and curly) strip line-locally and each stripped span (quoted or inline code) becomes a clause boundary, so quoted marker mentions no longer fire and a negator cannot reach across a span; a stripped-span-only final paragraph falls back to the previous paragraph (#311).
- **rules:** core.md's blocking-questions bullet drops the stale ?-only backstop promise and no replacement lands: the contract stays documented in the hook header (authoritative), and the bullet ends at "the transcript is not." (#311).

### Tests

- **probes:** `hooks/blocking-question-channel-check.probe.sh` gains 14 cases: quoted-mention silence (straight and curly pairs), the unquoted true positive, negated-marker silence, the unbalanced-quote and stray-pair residuals, a fully-quoted marker in a genuine ask accepted-silent, interleaved quotes, two line-locality shapes, two negator-clause shapes and two scope-fallback shapes (#311).

## 0.3.165 - 2026-11-12

### Features

- **bin:** every `safe-worktree-clean` plan id now names the exact tree list it removes: each dry run with approvable trees prints `hold plan <id> would remove <N> tree(s): <paths>` (truncated at three paths with `… +<k> more`; `sweep plan <id> would remove …` for the sweep id), `--json` carries the full lists as `hold_plan_trees` per repo and `sweep_plan_trees` on the sweep object, and `hold_plan_commit_carrying` / `sweep_plan_commit_carrying` list the plan's commit-carrying trees with their commit counts beyond the base (#310).

### Bug Fixes

- **bin:** `safe-worktree-clean --apply-hold` no longer lets an approved plan id remove a commit-carrying tree (reason `unmerged`, `detached-unreferenced`, `worktree-refs`, `bisect-refs` or `rewritten-refs` — any code that can carry commits not provably on the base or another branch) the invocation did not name: the apply refuses with one line per offending tree (its path and beyond-base commit count), exit 2, nothing removed, unless the invocation names that tree with `--only`; with `--only` the plan is recomputed over exactly the named trees, so a change to an unrelated tree no longer invalidates the approval. A sweep id is unscoped (`--only` is refused for several repos), so a sweep plan containing a commit-carrying tree refuses at the sweep parent before any child applies; the per-repo scoped flow (`--only` + `--apply-hold`) is the approval path for those trees (#310).

### Improvements

- **docs:** the README safe-worktree-clean row and the delegation / pr-monitoring skills describe the naming rule and the scoped `--only` approval flow for commit-carrying trees (#310).

### Tests

- **probes:** `tests/safe-worktree-clean.probe.sh` pins the naming refusal (bare id names the tree and its commit count, removes nothing, writes no backup), the summary and truncation lines, the sweep-level refusal at the parent with the repo-prefixed line, the new JSON fields, and scoped-id staleness (a named tree changing invalidates, an unrelated tree changing does not); the bare `--apply-hold` fixtures whose plans carry commits (P4, P9, P25, P28, P30, P31, P37) move to the scoped flow, and P40-P43 cover the new behavior end to end (#310).

## 0.3.164 - 2026-11-11

### Features

- **hooks:** hard context tier: at or above `SYG_CONTEXT_BLOCK` (a new opt-in knob, unset or non-numeric keeps the tier off, in the reminder and the gate alike — switching the tier off, emptying both clear lists, or disabling the `context-block` component releases an already-armed session or refuses to arm one at all) `context-size-reminder` arms `context-block-gate` instead of printing the soft banner; one handoff write — a `SYG_CONTEXT_BLOCK_CMDS` Bash command prefix (literal prefix, no word boundary; a matching compound command clears and runs whole — operator-config trust) or a `SYG_CONTEXT_BLOCK_PATHS` path glob matched literally against a `Write`/`Edit`/`MultiEdit`/`NotebookEdit` file path (`/../` paths never clear) — lifts it for the rest of the session (subagent tool calls carry the parent's session id, so a running subagent of an armed session is blocked too and cannot lift the block unless it writes the handoff itself). Both clear lists empty fails open to the soft banner (one note per session); an armed-uncleared session re-emits the instruction on every prompt, even below the threshold and on the first post-compaction prompt (rendered from the armed marker's stored total), so the gate never blocks with only its stderr as explanation; re-arming ignores the soft cooldown; a cleared session keeps exactly the soft tier's behaviour. The instruction's machine-config line renders each clear list with its entries joined by ", ", never raw config syntax. New `context-block` component, in the `full` and `guards` profiles; the probes pin the tier against a temp `SYG_STATE_DIR` so a suite run never touches the live state dir (#307).
- **hooks:** `context-block-gate` (new, matcher-less PreToolUse, so its tier-off and not-armed fast paths are fork-free — one builtin stdin drain that also keeps >64 KiB payloads from reading as blocks under a pipefail caller, then one builtin glob; the armed path pays one jq, folded and split in a single call): while armed and uncleared it passes read-only tools — `Read`, `Grep`, `Glob`, and a conservative single-command Bash allowlist (readers with their writing forms refused — `git --output*`, `rg --pre*`, `find` acting flags, split without pathname expansion — and git read-only subcommands with `branch` bare or listing-flags-only, the same read-only forms `cwd-drift-guard` allows) — allows the handoff write itself (the clear fires on the attempted write, before the permission decision), and blocks everything else with a pinned message, compound command shapes included; fail-open on anything it cannot decide (#307).
- **hooks:** `SYG_STATE_DIR` (already the session-start prune root) now relocates the prompt hooks' state family too: `queued-message-receipt`, `context-size-reminder` and `context-block-gate` write their per-session state through it, so a machine setting it keeps prune and state in one place (and replay-hook isolates them) (#307).
- **hooks:** `session-start` ages out the hard tier's `context-block-*` state markers (armed/done/note) with the other prompt-hook state files, so one stale armed marker cannot keep the gate's every-tool-call glob matching forever (#307).

### Improvements

- **docs:** README covers the `context-block` component, the hard tier and its state markers; `docs/config.md` gains the three new knobs (#307).

### Tests

- **probes:** `tests/context-block.probe.sh` pins the arm branch (fires at threshold, replaces the soft banner, idempotent re-arm, cooldown-immune, cleared equals today's soft semantics, empty-lists fail-open note once per session) and the end-to-end arm/block/clear flow; `hooks/context-block-gate.probe.sh` pins the gate (every compound shape and every find acting flag, git branch read-only vs writing forms, `notebook_path` and `MultiEdit` clears, done-marker lift, fail-open shapes); `session-start`'s probe pins the marker age-out (#307).

## 0.3.163 - 2026-11-11

### Bug Fixes

- **hooks:** the pipe-early-exit lint's reader and join fixes: an `xargs` prefix no longer counts as a reader word; `RE_B` command boundaries and `|&` pipeline handling; split-line pipeline joins; `-L` and `--files-without-match` count as reader forms; group (brace/subshell) forms; and a quoted `#` now cuts a comment in `strip_quotes` instead of joining into the word (#305, #306).

- **bin:** api-credit guards its `argv.log` write and its jq exit status as a pair, so a jq failure no longer reads as success (#305).

### Improvements

- **bin:** safe-worktree-clean: comment accuracy and a reworded no-live-refs HOLD reason (the P37(ii)/(iii) probe pin wording follows; the pinned counts are unchanged); one existing knob row description reworded, docs/config.md regenerated (#305).

### Tests

- **probes:** safe-worktree-clean gains the P38b real-failure probe family and a P39 bisect-refs-object fixture (#305).

## 0.3.162 - 2026-11-11

### Features

- **config:** optional config files fill in unset env knobs — user `${XDG_CONFIG_HOME:-$HOME/.config}/seyag/config.toml`, project `.claude/seyag.toml`; the environment wins over both, even set empty. Keys map mechanically to env names (the key path uppercased, separators to underscores); the settable set is the config/knobs.tsv user rows minus the harness-owned names; `_CMD` and binary-path keys are refused from project scope; `SYG_CONFIG=0` disables. Wired into `hooks/run.sh` (before component resolution, and before event mode's timeout read) and `bin/claude-usage` (the wiring pattern example; other bins adopt later). docs/config.md gains the generated "Config files" section (#303).

### Tests

- **probes:** config-env probe pins the loader: scope and precedence, both key forms, the settable-set parity with the doc generator's SCAN_EXACT_NAMES, the `_CMD` refusal, the malformed/unsupported battery byte-exact, the fail-open unreadable-file cases, and both integrations (a fixture plugin tree through run.sh, and claude-usage --posture) (#303).

## 0.3.161 - 2026-11-11

### Breaking Changes

- **bin:** safe-worktree-clean's hashed state-sha stream changed format; pre-upgrade `hold plan:` ids stop validating and re-verify exits 2 (fails safe, nothing removed) — re-run a fresh dry run for open plans after upgrading (#300).

### Tests

- **probes:** the pr-merge-review-check probe splits into two balanced files (command-match and merge-form sections vs the review surface and scans) so the CI shards stop carrying one 100 s probe; hook-wiring gains the probe-hook exemption kind for the second half, with a staleness check on those entries (#301).

## 0.3.160 - 2026-11-11

### Improvements

- **hooks:** cwd-drift-guard resolves the linked-worktree git dirs with one realpath call instead of two (#299).

### Tests

- **probes:** live-checkout-guard pins that a realpath failure on the worktree toplevel alone allows the edit (the pre-0.3.159 code compared the unresolved top and blocked) (#299).

## 0.3.159 - 2026-11-11

### Bug Fixes

- **hooks:** live-checkout-guard strips the cwd from the judge's sys.path itself; 0.3.158's PYTHONSAFEPATH=1 alone did nothing before Python 3.11, so the planted-module protection it described held only on 3.11+ (#297).

### Improvements

- **hooks:** cwd-drift-guard's raw prefilter ignores the `cwd` and `transcript_path` values, so a path spelling `git` no longer costs the fast path (#297).
- **hooks:** the live-checkout-guard Edit/Write nested-worktree check, the judge-result split (live-checkout-guard) and the repo-info split and session/agent id read (cwd-drift-guard) drop their per-line sed, realpath and jq forks (#297).

### Tests

- **probes:** a pre-3.11 emulation row for the planted module; cwd-drift fast-path rows for git-spelling paths (#297).

## 0.3.158 - 2026-11-10

### Improvements

- **hooks:** live-checkout-guard's judge moves from a `python3 -` heredoc into `hooks/lib/live_checkout.py`, imported so its bytecode is cached instead of recompiled on every call; the import runs with `PYTHONSAFEPATH=1`, so a module planted in the session's cwd is no longer imported. The guard reads its payload with one jq fork instead of four and resolves live roots without per-line forks; cwd-drift-guard skips any payload that cannot spell `git` before its first jq fork and reads its fields with one jq fork. Both keep the old field handling (NUL bytes dropped, trailing newlines stripped) (#296).

### Tests

- **probes:** live-checkout-guard pins the planted-module case, one jq fork per call, an object-valued command failing open, bytecode cached through run.sh, a NUL inside `git stash` and a trailing newline in cwd; cwd-drift-guard pins `git` after a JSON newline or tab, spelled with a `\u` escape or split by a NUL, and the zero-jq fast path (#296).

## 0.3.157 - 2026-11-10

### Improvements

- **hooks:** run.sh skips the per-call `bash -n` syntax check while a syntax-ok stamp (under the cache dir, at the hook's mirrored absolute path) is newer than the hook, and finds its own directory without a subshell; a hook edited after its stamp is checked again, and with no cache dir every call is checked as before (#295).

### Tests

- **probes:** hook-wiring pins the stamp (broken hook skipped and unstamped, stamp written and honoured, re-check after an edit, no cache dir or a cache path that is a file, relative and `..` invocations); the probes that run fixture copies of run.sh (hook-wiring, run.probe, pr-monitor-reminder) keep their stamps and bytecode out of the real cache (#295).

## 0.3.156 - 2026-11-10

### Improvements

- **CI:** each probe-shard job runs shard `strategy.job-index`+1 of `strategy.job-total`, so the shard spec comes from the matrix itself: any matrix edit (fewer or more entries, another axis, `include:`, a duplicate value) still gives every job its own slice and every probe one run (#294).

### Tests

- **probes:** run-probes-runner pins the duration-table parser: a CRLF row, a leading zero, the 9-digit cap, rounding on the second decimal only, and malformed, signed, empty or over-long values counting as 10 s (#294).

## 0.3.155 - 2026-11-10

### Improvements

- **CI:** the Probes workflow runs shellcheck as its own job and the probe suite as 3 parallel shards; an aggregator job keeps the required `probes` check name and passes only when shellcheck and every shard passed (#293).
- **run-probes:** `--shard I/N` runs one duration-balanced slice of the suite (greedy over `tests/probe-durations.tsv`, a probe without a row counts as 10 s); every run starts probes longest-first while output stays in suite order; `--durations-out FILE` refreshes the table from a full passing run (refused with `--shard`, skipped when a probe fails) (#293).

### Tests

- **probes:** run-probes-runner covers the shard partition and balance, longest-first launch, a missing table, bad `--shard` specs, an empty shard, and `--durations-out` (#293).

## 0.3.154 - 2026-11-10

### Improvements

- **config reference:** the legacy `TZUROT_ALLOW_*` aliases are scanned and listed; a non-UTF-8 file is scanned with a warning instead of skipped; prose defaults render as plain text; README's hook rows and hook prose no longer restate knob defaults (docs/config.md holds them), and README's hooks row escapes its `|` (#292).
- **claude-usage / plugin-release-check:** `claude-usage --json` adds `as_of` (the plan cache's fetch time, epoch seconds) and `source` (`api`, or `none` past the gate's max age or with no weekly figure, as `--ok`). `plugin-release-check`'s header names the release time's kind (`checkout received` or `commit time`), and refresh rows name the command that counted (`by /reload-plugins` or `by /clear`) (#290).
- **worktree-transfer:** when main is behind and the worktree's (or `--base`'s) commits ahead change no paths, the refusal now says "rerun with --rebase-base" (in `--base` mode adding that --base must be the worktree HEAD) instead of "land them on main first" (#291).

### Tests

- **probes:** security-sweep.probe and safe-worktree-clean.probe no longer write bytecode into the plugin tree (#290, #292); pr-body-ref-gate's attached `--title=` row quotes its value (#292).

## 0.3.153 - 2026-11-10

### Improvements

- **hooks:** a hook's python keeps its bytecode (the shared lib and the stdlib modules it imports) in a per-user directory (`PYTHONPYCACHEPREFIX`, default `$XDG_CACHE_HOME/seyag/pycache` or `~/.cache/seyag/pycache`) instead of recompiling the lib on every call; nothing is written into the plugin tree, and a prefix the caller already set wins. Hook probes and the replay harnesses still run without bytecode, env-print-guard's `env -i` rows included (#289).
- **pr-ci-wait:** the heartbeat names a held job-count lookup (`release held: job-count lookup failing`) (#288).

### Tests

- **run.sh probe:** run.probe.sh pins the cache prefix: HOME default, XDG_CACHE_HOME, a relative XDG falling back, a caller's prefix, a caller's PYTHONDONTWRITEBYTECODE kept, and no cache dir (#289).
- **probes:** checks under `tests/` that piped into `grep -q` under pipefail now capture the producer's output first, fixing a SIGPIPE flake (43-53 failures in 2000 runs under load before, 0 after, per #288); a new `tests/pipe-early-exit.probe.sh` lints `tests/*.sh` for the pattern, and keys.probe no longer writes `bin/__pycache__` (#288).

## 0.3.152 - 2026-11-09

### Tests

- **hook probes:** 29 `producer | grep -q` lines (about 36 greps) across 7 hook probes read a here-string instead, so grep -q's early exit can no longer SIGPIPE the producer and fail the row under pipefail (#287).
- **pr-body-ref-gate probe:** rows pin a value-taking flag as the last word (`--fill -t`) and the attached `--title=-Fix…` form; the 0.3.151 note now calls the escaped-`$` rows mutation guards, since the old code passed them too (#287).

## 0.3.151 - 2026-11-09

### Bug Fixes

- **pr-body-ref-gate:** the short-flag pre-check skips the value of a value-taking flag, so a QUOTED title value that starts with `-F` / `-b` (`--title "-Fix: closes TASK-N" --fill`) no longer triggers a whole-command scan; a body-file word de-escapes in one pass as bash does (`"a\\b"` reads `a\b`, bare `\l` reads `l`, an escaped `\$NAME` stays literal and unread); the no-python3 fallback also refuses commands with a backtick; a combined short-flag cluster (`-db`) is a documented miss, and so are an escaped `\"` and an escaped space in a body-file word and a body file named inside a heredoc fed to a shell (#286).
- **safe-worktree-clean:** refs/worktree/* commits are held (HOLD:worktree-refs, approvable, backed up in reflog.pack; non-commit refs HOLD:worktree-refs-object), quoted README restore refspec, batched plan-id hashing, no sweep id after a failed child dry run, plain-name run stamp, per-tree-path backup leaf names (#284).
- **pr-ci-wait:** a failed run that created zero jobs (attempt-pinned job count) takes CI_GATE_STARTUP_FAILURE instead of releasing; cancelled runs unchecked; a failed lookup holds release; pr-monitoring skill wording follow-ups from #262 (#285).

### Tests

- **pr-body-ref-gate probe:** no-python3 fallback rows for `$(`, backslash and backtick commands and for an earlier non-gh `-F`; red-first rows for the value skip and the de-escape; mutation-guard rows for the escaped-`$` single pass (#286).

## 0.3.150 - 2026-11-09

### Features

- **config reference:** `docs/config.md` lists every environment setting seyag's plugin code reads (`SYG_*` plus `CLAUDE_USAGE_*`, `ZAI_*`, `PR_CI_WAIT_*`, eight more prefixes and eight exact names; 179 in all, 134 user-facing), each with its default, what it does and the files that mention it, grouped by component, with internal names (test clocks, plumbing) listed separately. It is generated from the hand-kept `plugins/seyag/config/knobs.tsv` by `tests/config-reference.py`; README points to it (#283).
- **safe-worktree-clean:** sweeps several repos in one run (`--repo` repeatable, `--repos-file`); `--apply-hold <plan id>` removes HOLD trees that only hold uncommitted or unmerged work after a verified backup (tree.tgz, branch.bundle, reflog.pack, staged/uncommitted patches, changes.txt, README restore commands), one owner approval per sweep; a stale id, a backup dir inside the repo or on tmpfs (override SYG_WORKTREE_BACKUP_ALLOW_VOLATILE=1), or a repo listed twice exits 2 with nothing removed (#282).

### Tests

- **config-reference probe:** fails when the code reads a name with no `knobs.tsv` row, a row names nothing the code reads, a row is malformed (field count, scope, group, empty default or description, over 220 characters, duplicate), or `docs/config.md` differs byte-for-byte from the render (CRLF included); positive controls for `${X:-}`, bare `$X`, `os.environ.get`, awk `ENVIRON[...]`, and exclusions for `.md`, `*.probe.sh`, non-UTF-8 files and `knobs.tsv` itself (#283).

## 0.3.149 - 2026-11-09

### Bug Fixes

- **pr-body-ref-gate:** the required-flag pre-check reads a masked view, so a quoted `;`, `&` or `|` before `-F` / `-b` (`--title "a;b" -F x.md`) no longer skips the body scan, and prose in a heredoc that mentions `gh pr create -b` is data, no longer an over-block, while a heredoc fed to a shell (`bash <<'EOF'`, `cat <<EOF | bash`) is still read as commands, runner and env prefixes (`sudo gh`, `env gh`, `VAR=1 gh`) included; a `-b` inside a command string handed to a non-wrapper (`ssh`, `su -c`, `sg -c`, `script -c`, `tmux`, `source <(…)`) is now a documented miss; without a working python3, a command free of quotes, comments, backslashes, heredocs and `$(` still reads a plain `--body-file` / `-F` word (last one wins) instead of no body file; a backslash-newline inside a double-quoted body-file path is removed as bash does (an escaped `\\` before the newline stays) (#281).

### Improvements

- **core rules:** the `claude-usage --posture` pointer moves onto the wind-down threshold it names (core.md 24 B smaller) (#281).

### Chores

- **shell_quotes:** two comment lines reflowed (#281).

### Tests

- **pr-body-ref-gate probes:** rows for a quoted `;` before `-F` and `-b`, five no-python3 fallback rows (python3 shim: plain word, quoted decoy, last-wins both ways), the double-quoted backslash-newline path and its escaped-backslash twin, shell-fed heredocs (`bash <<'EOF'`, `cat <<EOF | bash`), the `ssh` documented miss; the heredoc-prose row now asserts pass (#281).

## 0.3.148 - 2026-11-09

### Bug Fixes

- **pr-body-ref-gate:** reads the body file gh actually posts: `--body-file` and `-F` are one flag and the last occurrence wins across both spellings (it read the first `-F`, and preferred `--body-file` over a later `-F`); the search runs on a masked view, so a flag inside a quoted argument (substitutions in it included), a `#` comment or a heredoc body never counts, and a `bash -c` / `eval` string is searched when the outer command has no flag; a python3 failure skips the body-file read instead of exiting the hook (#280).
- **shell_quotes:** the heredoc opener recognizes a backslash-quoted delimiter (`<<\EOF`) and delimiters with non-word characters (`<<'END-X'`), whose bodies were left unstripped; new public `masked_view`, a length-preserving view with quoted spans, comments and heredoc bodies filled (#280).
- **worktree-transfer:** when main HEAD is behind, the refusal hint follows the relation: an unpulled main gets `git pull --ff-only`, commits missing from main get "land them on main first"; the rebase-proof conflict refusal attributes each path ("changed on main" / "changed only on the worktree's branch"), including criss-cross merges; a worker's empty commits no longer refuse (#279).

### Improvements

- **core rules, driver-choice:** the week's wind-down and stop thresholds come from `claude-usage --posture`, not the memory; the README row says the same (#280).

### Tests

- **pr-body-ref-gate probes:** 18 rows for flag order across spellings, continuations, escaped quotes, multi-line and substitution-bearing quoted text, `cat <<A <<B`, `<<\EOF`, `<<'END-X'` and a heredoc body's trailing `\`; shell_quotes cases for the widened opener and `masked_view`; a scanner-parity row for shell-fed `<<\EOF` / `<<'END-X'` bodies; the branch-switch `<<\EOF` row now reads its target like its quoted siblings (#280).

## 0.3.147 - 2026-11-09

### Tests

- **security-sweep probes:** rows 9w and 9x share one mid-write harness (`cap_mid_write.py`, mode `alarm` or `term-alarm`) instead of two copies; new canary r7-2 (a grace re-arm that requires no prior SIGTERM) fails 9x only (#278).
- **safe-worktree-clean probes:** the two-flag `--only` row's tree4 setup is checked (a failed `add_tree` no longer lets `! grep tree4` pass vacuously), and the `--only <nosuch> --locks-apply` row asserts its exit-2 message and the lock's STALE eligibility (#277).

## 0.3.146 - 2026-11-09

### Features

- **worktree-transfer:** `--rebase-base` transfers onto a moved main after a printed path-identity proof (check 9 rebase-proof); the moved-main refusals point at it (#274).

### Bug Fixes

- **security-sweep:** the main thread waits on its repo futures in 0.1 s slices instead of a blocking `result()`, so a cap alarm or SIGTERM the kernel delivers to a worker thread is handled within about 0.1 s instead of after every repo finishes (under parallel load the blocking wait stalled 7 of 720 runs for the whole write, the sliced wait 0 of 480) (#275).

### Improvements

- **delegation:** the spec template's red-first case: the red comes from the case's own assertion, not from an error on a name only the fix adds; reach the behavior through pre-fix names where possible, and where the new name is itself the fix, its absence is the only red (#271, #272, #274).
- **security-sweep:** `--help`, the README and the session-start comment say the mid-write grace is about 1 s; the `_CAP_GRACE_S` comment says the bound holds only for writes off the main thread (#275).

### Tests

- **security-sweep probes:** 9w drives `main()` with SIGALRM masked on the main thread, so the cap alarm always lands on the writing worker (it flaked when delivery was left to the kernel); new row 9x pins the grace after a SIGTERM then the cap alarm; canary r8-1 (blocking wait) fails 9w; r7-1 now launches between r1-3 and r3-2 and the scheduling comment names it (#275).
- **safe-worktree-clean / branch-sweep probes:** `branch-sweep --prefix --apply` asserts its deletion line; `--only` narrowing and the `--only`/`--locks` header sentence are pinned (#273).

## 0.3.145 - 2026-11-08

### Features

- **safe-worktree-clean / branch-sweep:** `safe-worktree-clean --only PATH` (exit 2 for a path the run would not judge) and `branch-sweep --only NAME` / `--prefix P` (`ABSENT` for a missing `--only` name); the pr-monitoring close-out uses them, one scoped command per step with no separate fetch and `--apply` only with `--only`; every SKIP/HOLD gate still applies (#268).

### Bug Fixes

- **security-sweep:** `--cap` now bounds wall time when the cap expires mid-write: the write gets 1 s more, then the run exits even mid-write (it may leave a `.tmp` file); the `_cap_exit` comment notes the group gets SIGTERM twice per capped exit (#270).

### Improvements

- **safe-worktree-clean:** the header says a matched `--only` does not narrow `--locks`, and an unmatched one exits 2 before `--locks` runs (#269).

### Tests

- **safe-worktree-clean / branch-sweep probes:** rows pin repeated `--only`, the `--only`/`--prefix` union, `--prefix --apply` and `--only --json` (#269).
- **security-sweep probes:** row 9w (cap grace past a stalled write) with canary r7-1; 9v waits for the first SIGTERM to be handled before sending the second; the purpose canary names the FAIL it stopped on (#270).

## 0.3.144 - 2026-11-08

### Bug Fixes

- **security-sweep:** a second signal racing a capped run's exit can no longer skip the group SIGTERM (the first two exit entries each signal the group); a second SIGTERM exits at once even mid-write, so a write stuck on a stalled filesystem cannot hold the run (#267).

### Improvements

- **claude-usage `--posture`:** on the z.ai lane a reading older than the TTL is tagged ` (cache Nm old)` like `--ok`, and past the 30-minute cutoff it prints `?` and keeps the tag; on the plan lane ` (week reset since cache)` is dropped while now stays `?` (#266).

### Tests

- **security-sweep probes:** rows 9u (racing exit entry) and 9v (second SIGTERM mid-write) with canaries r6-1 and r6-2; a canary that did not fail its target row names the FAIL it stopped on; 9t drops a redundant condition and says which check reads the sweep's own exit code (#267).

## 0.3.143 - 2026-11-08

### Bug Fixes

- **security-sweep:** an external SIGTERM to a capped run now waits for an in-flight cache write like the cap itself does, so the 0.3.142 claim of no partial `.tmp` file now also holds for SIGTERM (0.3.142 still exited mid-write on one); a capped run ignores SIGTTIN/SIGTTOU, so under `stty tostop` its terminal output no longer stops it (#265).

### Improvements

- **pr-monitoring skill:** the wait pointer is scoped to waits the harness doesn't report back on (#262).
- **review-response skill:** rule 2a — each finding's class gets one positive-controlled sweep, recorded as `command → N sites, M defective`, before it is applied or presented; delegation's "Sweep outward" bullet matches (#263); its review lows tighten the rule's wording, example sites and cite (#264).

### Tests

- **security-sweep probes:** the cap rows install handlers through the bin's own `_install_cap` instead of hand-copied wiring, and the worker-thread rows wait for the handler instead of sleeping, so canary r4-4 no longer flakes under load; new rows for an external SIGTERM mid-write (main and worker thread) and for `stty tostop`, each with a canary; canary re-runs stop at their first FAIL and run four at a time (the full probe went from ~450 s under load to ~120 s) (#265).

## 0.3.142 - 2026-11-08

### Bug Fixes

- **security-sweep:** when `--cap` expires, the run now stops its `gh` children too (it leads its own process group and sends it SIGTERM, as GNU timeout does) instead of leaving them to run to their per-call timeout; a cap firing during a cache write lets the write finish, so no partial `.tmp` file is left behind, whichever thread is writing (#261).

### Improvements

- **session-start:** the detached cache-warming run is built as its own argument list instead of by rewriting one index of the capped run's list (#261).
- **security-sweep probes:** the cap rows bound wall time at 8 s (was 20 s); docs say "a built-in 2 s cap" (#261).
- **delegation skill:** § Concurrency has one wait rule for jobs the harness doesn't report on — a scheduled one-shot tick running a non-blocking status check, never until/while loops, blocking background waits or hand-written Monitor loops (Agent-tool workers need no tick), with PR CI (`pr-ci-wait`) as the stated exception and a pr-monitoring pointer back; the placement check cuts both names at the first dot and stops while unrecorded (#260).

## 0.3.141 - 2026-11-08

### Bug Fixes

- **security-sweep:** a repo token starting with `-` in `SYG_SECURITY_SWEEP_REPOS` no longer drops the whole SessionStart sweep (tokens pass as `--repo=TOKEN`; `--session-line` and `--warm-cache` parse errors exit 0 silently); a structurally corrupt cache entry (wrong-typed count, severities, rule ids, alert entries or types) is refetched instead of failing the run or hiding alerts.

### Improvements

- **security-sweep:** new `--cap SECONDS` (exit 124; at most one day) replaces the `timeout` binary for the SessionStart 2 s cap, so the cap holds where `timeout` is missing; new `--warm-cache` makes the detached cache-warming run take a non-blocking lock per repo set, so repeated starts no longer stack runs; abbreviated flags are refused; under `--strict`, exit 1 (alerts) is documented to win over exit 2 (errors).
- **delegation skill:** § Parallel work — three tiers (local workers, cloud units, parallel local drivers) with a selection table and the parallel-driver contract; the cloud-unit cap is a project rule with two numbers (default one and one); cloud ledger, setup-script environment, cloud step 0 as a project file, CI caveat and resume fallback (#257); the ledger timing is stated once, a mechanical placement check is added, and § Adopting names the cloud pieces (#258).
- **probes:** load-flaky timing rows assert the property instead of wall time: release-marker holds in place of sleep races (security-sweep, session-start), CPU-time bounds (shell_quotes perf rows, session-url-gate latency), wider pr-ci-wait give-up ceilings and a marker rendezvous for the run.probe.sh parallel row (#256).

## 0.3.140 - 2026-11-08

### Features

- **security-sweep:** new `security-sweep` bin reports open code-scanning, dependabot and secret-scanning alerts per repo (a count, `off` or `error` per surface; secret values dropped at fetch time; disabled-scanning responses read as `off`; `--strict` exits 1 on critical/high or secret alerts and 2 on an uncached fetch error or an internal error; `--json` carries alert numbers), an opt-in `security` SessionStart line (`SYG_SECURITY_SWEEP=1` or `SYG_SECURITY_SWEEP_REPOS`; headless-off) and a disposition skill (#254).

### Improvements

- **pr-monitoring skill:** retry a first Monitor call once on InputValidationError; after an automerge, close linked issues still open and delete the branch only when `branch-sweep` marks it eligible (#251).
- **session-log:** stats name `command hook <N>` blocks by their banner title (`hook:cwd-drift-guard`). Guard keys change at this release: earlier counts sit under `hook:<N>`, so guard-ledger comparisons across it don't line up by key, and renaming a banner title renames its row (#252).
- **pr-monitoring skill:** close-out follow-ups — a failed linked-issue read is reported, never treated as closed; the branch delete is `git branch -D --`; a SKIP from the unit's own worktree is cleared by a `safe-worktree-clean` dry run plus `git worktree remove` on that one tree, never `--apply` (#253).
- **claude-usage:** `--posture` prints the configured week thresholds (`week posture: wind-down R% · stop S% · now W%`); the new `CLAUDE_USAGE_WEEK_STOP` (default 80) is reported only (#255).

## 0.3.139 - 2026-11-07

### Features

- **hooks:** `live-checkout-guard` keeps a directory-source plugin checkout on its default branch. The live root is auto-detected from `CLAUDE_PLUGIN_ROOT` (when its git toplevel has `.claude-plugin/marketplace.json`) plus `SYG_LIVE_CHECKOUTS`. In it the hook blocks branch switches, stash, commits, history and tree mutations, non-ff-only pulls, and Edit/Write/MultiEdit/NotebookEdit on tracked files, while allowing linked worktrees (including a worktree added earlier in the same command) and gitignored paths. It ships as component `live-checkout`, with bypass `SYG_ALLOW_LIVE_CHECKOUT=1` (#250).

### Improvements

- **delegation skill / CLAUDE.md:** a live-checkout project never parks or transfers into its main checkout. The unit's worktree is cut from `origin/main`, and the driver commits there (#250).

## 0.3.138 - 2026-11-05

### Bug Fixes

- **versioning skill:** the notes range is `<prev-release-base>..HEAD` on the PR branch — notes are written before the merge lands, so no merge SHA exists yet; review-round fixups collapse into their parent item and the bump-and-notes commit itself is not an item (#249)
- **versioning skill:** the pre-1.0 scheme is patch per merged batch, dropping the minor clause that contradicted it — every 0.3.x batch, features included, has bumped patch; post-1.0 semver keeps behavior → minor, and a project may reserve minor for breaking changes (#249)
- **versioning skill:** the floor checklist scopes to compatibility fields (minimum host version, engines, permissions) instead of "any field besides the version", matching the core.md floor clause (#249)

### Improvements

- **core.md:** merge rule wording — the bump and notes land in "the PR that completes the batch", not "the same PR"; the literal reading would bump every PR in a multi-PR batch (#249)
- **versioning skill:** the multi-PR case lives in the skill text — one bump per batch, carried by the completing PR or a dedicated release PR; the cross-reference names the exact heading (§ Evidence and claims) (#249)
- **versioning skill:** the defer-to-project paragraph covers the version scheme — a project with its own pre-1.0 convention pins it in its CLAUDE.md (#249)

## 0.3.137 - 2026-11-05

### Features

- **versioning skill:** release mechanics for a versioned project — the merge PR carries the version bump and the release notes; defer-to-project version file and notes location, pre-1.0 patch-per-batch scheme, notes format with fixed category order, commit subjects as the source of truth, two-theme cut, and a floor checklist citing the verifying probe (#248)

### Improvements

- **core.md:** merge rule — in a project that versions, the session driving a merge bumps the version and lands the release notes in the same PR; the unfinished-batch clause folds into the completion-claims line (#248)
- **core.md:** floor clause — a compatibility floor or new manifest field (minimum host version) is an external-system claim: it cites the probe that verified it (#248)

## 0.3.136 - 2026-11-05

### Bug Fixes

- **probes.yml:** workflow-level `permissions: contents: read` — both jobs need only checkout and local git over a full clone, closing the two missing-workflow-permissions code scanning alerts (#246)
- **keys:** the `keys set` name summary derives from the pre-write store plus the argv name, so the printed string never traces to the secret's buffer — closes the clear-text-logging alert; printed message byte-identical to the probe pin (#246)

## 0.3.135 - 2026-11-05

### Improvements

- **reserve-week:** `week-burn-window` docs — the override is never floored but the > 100 clamp still applies; a deployment whose real burn capacity is under 1 %/h should set `SYG_WEEK_BURN_RATE`; the `RATE_FLOOR` comment is now a one-line pointer to the sibling end-to-end row (#245)

### Tests

- **reserve-week probes:** a `SYG_WEEK_BURN_RATE=0.5` row with the reset 50000 s out discriminates the never-floored override property — the 0.1 row burns either way, so a guard-dropped mutant fails exactly the new row; probe header re-wrapped (#245)

## 0.3.134 - 2026-11-04

### Bug Fixes

- **reserve-week:** `week-burn-window` floors every computed rate — slope, fresh-endpoint decay, parked/flat — at the 1 %/h capacity default (raised from 0.5, where it covered only rate <= 0): a hold suppresses the very rate it measures, so a held meter's tiny positive decay slope (~0.17 %/h live) stretched the burn window to ~110 h and printed the burn ~3 days early; floored, a held or trickle week burns only once the reset is close enough, and `SYG_WEEK_BURN_RATE` still overrides entirely (#244)
- **review-response:** the round's fixup batch is held in automerge repos (#243)
- **review-response:** plain commits in automerge repos, with the batch gate scoped to them (#243)
- **review-response:** the fixup flow is scoped to controlled-merge repos (#243)
- **review-response, delegation:** the automerge carve-out is carried across review-response + delegation (#243)

## 0.3.133 - 2026-11-04

### Bug Fixes

- **usage-gate:** the `--ok` extra-usage pass's meter names the biller — below 100% of the week the pass still bills the plan, so it prints `meter=plan` with the note ` (extra usage bills only at 100%)`; at 100%+ it bills extra usage and keeps `meter=extra-usage` with the balance; pass/fail semantics unchanged (#242)

### Tests

- **reserve-week probes:** `week-burn-window.probe.sh` clears host-set `SYG_WEEK_BURN_RATE` / `SYG_WEEK_BURN_MARGIN_MIN` / `CLAUDE_USAGE_WEEK_RESERVE` — a deployment may legitimately set any of them (a capacity floor while a slope fix is pending, for example), and the probe's `env`-prefix invocations inherited them, flipping hold/burn rows while a shell without the variables ran green; rows that need the knobs still set their own (#242)

## 0.3.132 - 2026-11-04

### Bug Fixes

- **reserve-week:** `week-burn-window` freshness reads the `.last` fetch record's content — the fetch epoch `claude-usage` writes on every refresh — instead of its mtime, which sync and backup tools touch without a fetch; an unparsable record holds like a missing one (#241)
- **reserve-week:** `week-burn-window` slope: on a fresh fetch record the slope's endpoint becomes `(now, latest week)`, so a meter that climbed and parked decays honestly instead of reading a stale steep rate; the empty-window path is explicit and the window indexing stays inside its guarded branch (#241)
- **reserve-week:** the `CLAUDE_USAGE_WEEK_RESERVE` clamp's note prints once per `--ok` gate check on every lane (routed lanes included), not on the plan lane only (#241)

### Improvements

- **docs:** README's `week-burn-window` row — XDG path form, the effective-span hold, and the crash classes documented; CHANGELOG 0.3.131 recategorized Bug Fixes → Improvements (#241)

### Tests

- **reserve-week probes:** timeout bounds compare milliseconds; new rows wire the real `week-burn-window` to the real `--ok` gate end to end (fresh pass, degraded hold), and pin content-over-mtime freshness, the shared note on the z.ai lane, and the note-CMD interaction (#241)

## 0.3.131 - 2026-11-04

### Improvements

- **clock-stamp-guard:** the MultiEdit running text (disk text plus what earlier edits leave) is rebuilt only for MultiEdit — a single Edit no longer pays the per-edit rebuild; the header's disk-read paragraph names all three readers; KNOWN GAPS documents the replace_all shared-line judging and the checkbox-stamp escape (#240)

## 0.3.130 - 2026-11-04

### Chores

- **docs:** README rows for the usage-gate reserve commands and `week-burn-window`, the clock-stamp/branch-switch/prepush-scan libs, the review-response and going-public skills, and the SessionEnd wiring example; CHANGELOG adopted (#239)

## 0.3.129 - 2026-11-04

### Features

- **reserve-week:** the plan-week reserve follows `CLAUDE_USAGE_WEEK_RESERVE_CMD` — a command run at each `claude-usage --ok` gate check under a 5 s timeout whose trimmed stdout (an integer 1-99) wins the slot in success and failure, the same contract as the z.ai lane command (#238)
- **reserve-week:** new reference bin `week-burn-window`: reads the claude-usage readings log and prints 99 once the weekly reset is close enough that the week burns down before it, holding (exit 0) on every degraded input so a wired gate stays quiet outside the window (#238)

### Bug Fixes

- **reserve-week:** the static week-reserve overrides (`CLAUDE_USAGE_WEEK_RESERVE`, `CLAUDE_USAGE_ZAI_WEEK_RESERVE`) are validated to 1-99 before bash arithmetic; `100` and `0` are rejected with a stderr note and fall back to 75 — a machine pinning `100` for a gate-at-99%-style setup should pin `99` (#238)
