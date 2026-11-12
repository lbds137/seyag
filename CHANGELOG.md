# Changelog

All notable changes to the seyag plugin. Newest first. One `## <version> - <YYYY-MM-DD>` section per released version; under it, `###` categories in fixed order — Breaking Changes, Features, Bug Fixes, Improvements, Chores, Tests — empty ones omitted; items are `- **scope:** description (#PR)`, written from the version's merged commit subjects.

## 0.3.167 - 2026-11-12

### Bug Fixes

- **bin:** the `safe-worktree-clean --apply-hold` naming-refusal hint now names the approval it waits on — "only on the owner's yes for that tree: re-run the dry run and apply with `--only <tree>`" — instead of the bare "name it with --only"; a commit-carrying tree whose only carrying reasons are `worktree-refs` / `bisect-refs` / `rewritten-refs` now says its count is the branch's beyond-base commits and per-worktree refs hold more, and a failed or vacuous commit count prints `?` instead of a real-looking `0` (#313).

### Chores

- **bin:** `safe-worktree-clean` re-wraps the ragged header/`--help` lines the holdscope batch left behind and comments the display-only `", "` split that builds the sweep tree names (`--json`'s `sweep_plan_trees` is unaffected) (#313).
- **docs:** restores the `(#PR)` placeholder on the format line, which a cite-fill replace_all had clobbered to `(#310)` (#313).

### Tests

- **probes:** `tests/safe-worktree-clean.probe.sh` pins the reworded refusal (P31 with the reason-aware count, P40(ii), P42(ii)), adds the naming refusal under `--json` (stderr carries the line, stdout stays clean, P44), a detached-unreferenced bare-id refusal asserting the printed count (P25), a `rev-list --count`-failure case printing `?` via a git shim (P45), and the sweep parent pinning the same reason-aware count form at the sweep refusal (P46) (#313).

## 0.3.166 - 2026-11-12

### Bug Fixes

- **hooks:** `blocking-question-channel-check`'s pending-marker pass (the non-`?`-closing scan of the final paragraph) strips balanced quoted spans before matching — straight `"` pairs and curly `“ ”` pairs alike, each pair line-local so it cannot merge paragraphs or reach across the scanned scope, and each stripped span (quoted or inline code) becomes a clause boundary (` . `), so a negator in an earlier clause cannot reach across it to the marker, and a paragraph left holding only whitespace, dots and stripped-span placeholders does not become the scan scope (the previous paragraph is scanned, as before this change) — so a closing that only MENTIONS a pending-marker phrase (a quoted `"waiting on you"` naming alert text) ends its turn normally; the closing-`?` pass still reads the raw text (a quoted closing `?` stays the accepted FP shape), and an unbalanced quote changes nothing, still firing (accepted residual, now in the hook header's known-FP list) (#311).
- **rules:** core.md's blocking-questions bullet drops the stale ?-only promise ("the hook backstop fires only on a closing `?`", superseded by the pending-marker pass) and no replacement lands: the backstop contract stays documented in the hook header (authoritative), an always-loaded exclusions map would read as a bypass guide, and the bullet ends at "the transcript is not." — the file is no larger than 0.3.165 in lines and smaller in bytes (#311).

### Tests

- **probes:** `hooks/blocking-question-channel-check.probe.sh` gains 14 cases: the verbatim quoted-mention fixture silent (straight and curly pairs), an unquoted true positive still firing after the strip, a negated marker still silent, the unbalanced-quote residual still firing, an interleaved-quotes shape where the straight span cannot hide a marker outside it, stray quotes pairing as a false mention (inch marks — accepted fail-open residual), a fully-quoted marker in a genuine ask accepted-silent, two line-locality shapes (a stray quote or stray backtick in an earlier paragraph can no longer pair across the paragraph break and swallow a final-paragraph marker), two negator-clause shapes (clause punctuation inside a stripped span — quoted or code-span — keeps a negator in its own clause, so a real ask like `It's not "done." Waiting on you to test.` fires), and two scope-fallback shapes (a final paragraph holding only a stripped code span or quoted span does not become the scan scope — the marker paragraph before it still fires) (#311).

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
