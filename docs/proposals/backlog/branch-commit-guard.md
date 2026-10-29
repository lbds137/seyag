# The branch-commit guard (flagship port: content-class × destination-class commit gating)

**Status: ACCEPTED 2026-10-29.** Council: 4 models briefed with identical adversarial
text, 3 answered (glm-5.3, kimi-k3, deepseek-v4-pro — the panel's findings converged
and every repair was adopted; qwen3.8-max-0902 failed idle at 1800 s and was not
re-briefed, recorded in § Council record). Owner: the seyag-repo policy row ruled IN
and the amended design CONFIRMED ALL (ask answered directly, 2026-10-29).
Implementation follows § Phasing; this PR carries the artifact only.

## Owner directives (verbatim)

- Port picks (owner, 2026-10-18): branch-commit named in the audit's queue;
  port-sources item 6: "Genericization: develop/board branch names → config",
  "Gaps to fix in the generic version: TASK-1048 (bash -c/unquoted-heredoc
  bypass; watch/su/ssh unprobed), TASK-1219 (cd+pipe/subshell keeps
  start-checkout eval; header FP on -m printf)".
- Repo CLAUDE.md, standing: "No direct pushes to main" — whose mechanical
  backstop is the repository's branch-protection ruleset (ref restriction); this
  design adds the client-side commit-act gate and says so precisely (D9).
- pr-merge-review-check (shipped): "Do NOT read this hook as branch protection.
  The systematic backstop for long-lived branches is the repository's own
  branch-protection ruleset."

## Grounding provenance

Four read-only lenses completed 2026-10-29, all claims line-cited in-session
against: tzurot `develop-code-commit-guard.sh` (1201L) + its probe (1696L) +
`board-commit-branch-gate.sh` (696L) + probe (1460L) + `lib/branch_switch.py`
(867L) + `branch_switch_test.py` (959L, 205-row rule table) +
`lib/commit_location.sh` (141L, literal-free) + `lib/shell_quotes.py` (851L) +
`lib/git_commit.py` (47L); seyag `plugins/seyag/hooks/lib/shell_quotes.py`
(2932L, a diverged superset) + `lib/commit_diff.py` (279L) + the
guards-commit/hooks/git-hooks layers + the delegation skill. Full reports are
session working material; this artifact carries what the design needs.

- **The two Tzurot hooks are a complementary 2-axis matrix, not two copies**:
  hook A blocks gated content ON long-lived branches; hook B blocks doc-ONLY
  commits everywhere OUTSIDE an allowed set — each covers the other's
  early-exit blind spot. Shared machinery ~80% (parse skeleton, quote scanner,
  `branch_switch.py`, `commit_location.sh`); genuinely divergent: bypass
  semantics (presence-unlock vs per-commit count-equality), file-set sources,
  and per-ambiguity fail directions.
- **The port-sources excision claim is wrong in the detail**: the header
  marker appears TWICE mid-file, interleaved with the gate; the true partition
  is header half (python 228-414 + bash 724-805) vs gate half (python 416-716
  + bash 807-1201), seamed by the two-line verdict protocol.
- **The wrapper/heredoc bypass confirmed live** at the scanner layer: the quote-stripper erases
  `bash -c`-wrapped invocations; unquoted-delimiter heredoc bodies are stripped
  as inert data though bash executes them (and `bash <<'EOF'` executes even
  quoted bodies); `watch`/`su -c`/`ssh` unprobed and mostly evaded.
- **The pipe/subshell cwd ambiguity confirmed live**: pipe/background/subshell shapes return no dir
  read → judged on the live checkout even when the commit runs elsewhere.
- **The seyag shell_quotes port is a diverged superset**: of branch_switch's
  six imports, three behave differently (multi-opener heredoc stripping,
  per-span substitution stripping, five-shell wrapper recognition) — the
  205-row table is the acceptance gate, and the scanner divergence itself
  needs a parity suite (the wrapper bypass lives at that layer, one above
  branch_switch).
- **commit_diff.py owns the content half** (staged + same-command adds + `-a` +
  pathspecs, untracked contents, 1 MiB cap, config-pinned diff headers); the
  WHERE half is absent from seyag. Complementary, not redundant.
- Seyag detection convention is structural argv (`command_pipelines` +
  `unwrap_runners` + `parse_git`); config precedents: `SYG_WORKTREE_BRANCH_RE`
  (ERE, unset-default, INVALID-REFUSES), opt-in-RE guards, `SYG_ALLOW_*`
  per-command prefix bypasses, the `guards-commit` component group.

## System as-is

Seyag gates commits today only at the session layer for TEXT hazards
(temporal-marker-guard blocking, claim-shape-guard advisory, the outbound text
labels); the git-hooks layer covers push-time private-term scanning in
marked-public repos and otherwise passes through. Nothing gates WHERE a commit
lands or WHAT CLASS of content lands there. The delegation flow commits in the
main tree on spec-named unit branches after transfer; workers never commit;
the step-0 self-heal's `git reset --hard` is the one sanctioned reset; the
skill's stated blind spot ("command-text guards cannot see through wrapper
scripts") is why the git-hooks layer exists.

## Audience

Seyag-the-repo opts in with its own policy (D9). Adopters configure their own
rows; the plugin ships the mechanism, the lib ports, and the canary probe — no
default policy (the dispatch-posture-gate opt-in precedent).

## Perimeter

**Gated (v1):** `git commit` commands issued through the Bash tool in
PreToolUse, judged on (content class of the would-be-committed set) ×
(destination class of the branch/checkout the commit lands on), per the
project's policy rows.

**Explicitly NOT gated, with reasons:**

- **The commit-message header** (Tzurot's commitlint half) — dropped with
  disposition (D7); Tzurot keeps it.
- **Push-time and other commit-CREATING verbs** (`git push`, `merge`, `rebase`,
  `cherry-pick`, `reset`, `branch -f`, `commit-tree`+`update-ref`,
  `symbolic-ref`) — this guard sees the `commit` verb only; landing gated
  content on a protected ref through those verbs is the ruleset's ref
  restriction to stop, and this design claims none of that role (D8/D9).
- **Remote execution** — `ssh <other-host> 'git commit …'` commits where no
  local git call can see; such commands are AMBIGUOUS for block rows (see D4),
  not silent passes. `ssh localhost`/`127.0.0.1` is local and judged normally.
- **File and state indirection** — a wrapper SCRIPT on disk (`bash script.sh`),
  `make`/`npm run`/interpreted launchers, and session-persisted state (shell
  functions, aliases, exported variables from earlier Bash calls) hide the
  commit from static argv inspection entirely. Git aliases are the same class:
  an inline `git -c alias.x=commit x` is detected (the value carries "commit"),
  a `git config alias.ci commit` from a prior call is NOT — a documented hole
  with its own canary. The structural complement is the git-hooks layer
  (deferred, first-adopter trigger).
- **Branch protection** — the repo's ruleset remains the systematic backstop
  (D8).

**Known model limits, stated:** the inert-git-subcommand allowlist assumes
trusted config (diff.external, textconv, core.fsmonitor, commit hooks run
commands — unmodeled, one canonical statement); MAX_LOCATIONS=32 with over-cap
fail-closed to ambiguous; HOME/CDPATH env coupling; unknown branch-mutating
argv (`--orphan`, `worktree add -b`) resolves the destination as ambiguous,
NEVER as unchanged.

## Decisions

### D1 — One generic hook over a policy table; the grammar is record-safe and refuse-secure

`commit-branch-guard` (PreToolUse Bash, `guards-commit` component). Policy:
`SYG_COMMIT_BRANCH_POLICY`, settings env, **newline-separated rows** (a
settings JSON string carries `\n`; ERE alternation can never collide with the
record separator). Each row:

    <name>:<quantifier>:<files-ERE>:<branch-ERE>:<action>

- `quantifier` — `any` (default spelled out; the row fires when ANY
  would-be-committed file matches) or `all` (fires only when EVERY file in the
  set matches — the doc-only semantics hook B needs). An `all` row over an
  EMPTY set does not fire — empty-set judgment belongs to the `-` files-ERE
  (the `--allow-empty` mechanism; vacuous truth is excluded).
- `files-ERE` — ERE over the would-be-committed paths, relative to the
  candidate checkout root. A literal `:` inside the ERE is written `[:]`
  (the documented spelling rule; the field parser splits on `:` outside
  brackets). The special value `-` matches the EMPTY set only (so
  `--allow-empty` is row data).
- `branch-ERE` — ERE over the destination branch name; the detached-HEAD
  destination is the literal sentinel `(detached)` (rows match it explicitly;
  `.*` catches it, `^main$` does not). A leading `!` negates: `!^(develop|main)`
  fires when the destination does NOT match — hook B's "everywhere outside" is
  now expressible.
- `action` — `block` (exit 2 with the banner) or `warn` (exit 0 with the
  advisory delivered through `hookSpecificOutput.additionalContext` — plain
  stderr never reaches the model, per the claim-shape-guard's channel note; a
  canary asserts delivery). ALL FIVE FIELDS ARE REQUIRED — the defaults are
  the recommended spellings, not omittable fields (a four-field row is
  ambiguous under the raw-`:` split and refuses).

Evaluation: ALL rows whose files-ERE matches (per quantifier) and whose
branch test hits are collected; any `block` hit → exit 2 naming every hitting
row (name sanitized of control characters — row names reach the banner);
else any `warn` hit → the advisory; else exit 0. Empty variable → hook inert
(exit 0 everywhere).

**Invalid config refuses secure**: a row with the wrong field count, an
uncompileable ERE, an unknown quantifier/action, a colliding or
control-character name, or an ERE containing a raw `:` → the guard exits 2
with a remediation naming the row — the `SYG_WORKTREE_BRANCH_RE`
invalid-refuses precedent — and a config-lint canary pins it. An adopter's
typo must never silently disarm the guard. A structural fast path (no
git-like argv in the command) exits before any of this machinery.

*Rejected — `|`-separated rows*: ERE alternation is `|`; the flagship rows
were unrepresentable and fail-open parsing would silently degrade them to
inert (three-model convergence).
*Rejected — JSON/TOML policy files*: no house precedent for guard config
files; env + documented spelling is the `SYG_WORKTREE_BRANCH_RE` lineage.

### D2 — The WHERE half ports onto seyag's lib; flip adjudication is two-axis; the scanner gets its own parity suite

`branch_switch.py` (switch_target, commit_target_dir, the two-set
cd/pushd/`-C` walk, UNREADABLE_DIR, MAX_LOCATIONS=32) and
`commit_location.sh` (start/resolve, CL_* verdicts) port into
`plugins/seyag/hooks/lib/`, consumed by the guard. `branch_switch_test.py`
ports and MUST pass against seyag's diverged `shell_quotes.py`. **Flip
adjudication is per-axis** (council): a flip caused by seyag stripping MORE
data is accepted as conservative with a row comment ONLY when the stripped
span was inert; a flip where an EXECUTING span (a `$()` interior, a
heredoc fed to a shell, an eval-joined tail) is erased from the walk is a
compensating-walker-entry requirement, never an accepted "conservative" —
stripping is the evasion direction for invocation detection. Separately, the
scanner divergence gets its own **parity suite**: heredoc-to-shell execution
in both delimiter forms, `$()`/backtick runtime construction, here-strings,
eval-join — the layer the wrapper bypass actually lives at, one above branch_switch.
The three-line script contract, the 32-location cap (over-cap → ambiguous),
and the single canonical trusted-config statement are preserved. Genericized
on arrival: no Tzurot tracker IDs in the test table.

*Rejected — re-implementing the walk in bash*: the two-set semantics and the
test table are the assets. *Rejected — vendoring tzurot's shell_quotes*: two
scanners in one tree is the drift the divergence report warns about.

### D3 — Detection: the structural argv convention; the runner table: `su` and `flock` join, the rest reused

Commit detection = `command_pipelines` + `unwrap_runners` + `parse_git`
subcommand check (the temporal-marker-guard skeleton). **Runner-table
changes, decided**: `su` and `flock` join; the existing `watch`/`sudo`/
`doas`/`timeout` entries are reused as-is (`shell_quotes.py:2318-2337` —
Slice A/B must not re-add them). `su` non-login forms are cwd/env-preserving;
`su -`/`-l`/`--login` reset cwd and scrub env → the location resolves to
ambiguous; `sudo -i`/`--login` are LOGIN forms in the same class (sudo's
`env_reset` also scrubs the `GIT_DIR` family) → ambiguous; plain `sudo` is
cwd-preserving but its env_reset means the relocation env family will not
survive it (noted next to the su env clause). The INTERIORS of any wrapped
command are always scanned at EXECUTING positions — wrapper `-c` strings,
heredocs fed to a shell, `$()`/backtick interiors — plus unknown-runner argv
where `git` sits at a command position and `commit` is its parsed subcommand
(the `parse_git` check). Read-only shapes are NOT commits: `git log --grep
commit`, `echo git commit -m x`, `git show HEAD -- commit` exit 0 (canary
group 2 pins the false-positive controls).
**ssh**: `localhost`/`127.0.0.1` targets are local and judged normally; any
other target carrying an inner commit is AMBIGUOUS (block rows block, warn
rows advise) — a 5-second local bypass via `ssh localhost` does not exist.
Git aliases: the inline `-c alias.x=commit` form is detected; config-file
aliases are a documented hole with a canary.

*Rejected — porting GIT_COMMIT_RE*: a second detection convention, a
ReDoS-shaped regex, and a pattern-string slice contract; seyag's argv walk is
already probe-pinned by three guards.

### D4 — Pipe/subshell cwd ambiguity: the walk knows each connector's truth; ambiguity is per-policy

The two-set walk implements the connector semantics bash actually has:
cwd/branch state persists across `&&`, `||`, `;` and inside `{ }`; `|`,
`&`-backgrounding, and `( )` ISOLATE their segments (a `cd` in a pipeline
segment or background job cannot affect the commit — unioning that location
would be a false block). A commit reachable from multiple distinct checkouts,
after an unresolvable change (`cd -`, `popd`, `~user`, `..` with CDPATH), or
relocated by the `GIT_DIR`/`GIT_WORK_TREE`/`GIT_INDEX_FILE` env family or
`--git-dir`/`--work-tree` flags (assignment-prefix parsing already exists in
the walker) → the location set is AMBIGUOUS: `block` rows block with the
remedy (`git -C <abs> commit`, or the cd as its own call; compound commands
are told to split); `warn` rows advise. A commit word inside a substitution
argument (`out=$(git commit …)`) is a runtime-executed command and is judged,
not stripped past (canary-pinned — the pipe/subshell family's substitution rows).

*Rejected — naive location spreading across all connectors*: over-spread
locations produce false ambiguity, and ambiguity-fatigue trains users into
reflexive bypasses.

### D5 — Content: commit_diff.py is the file-set source; semantics verified against git

The would-be-committed set comes from `commit_lines`/`parse_add`/`parse_commit`
— with three semantics pinned by canary before the guard ships: `-a` stages
TRACKED files only (an untracked file must not enter the set under `-a`);
`git commit <paths>` is `--only` semantics (worktree content of the named
paths, the rest of the index excluded) while `--include` is additive; and
`--pathspec-from-file`/`--amend` resolve explicitly (`--amend` judges the
amended commit's own branch — same destination rule). Empty set: only rows
whose files-ERE is `-` match (so `--allow-empty` is policy data). An
AMBIGUOUS file set (an unresolvable add source — the content-side of D4's
relocation ambiguity) evaluates as the wide fallback: `any` rows fire on it,
`all` rows are satisfied, and the row action follows — the conservative
direction. Paths are
relative to the candidate checkout root — content is computed AT the candidate
location when the walk resolves one (a gated file that exists only in the
sibling reached via `-C` must block). The >1 MiB untracked cap falls back WIDE
(over-inclusion), and a block row firing on a wide fallback blocks — wide is
never a pass for block rows.

*Rejected — `gate_classify` as code*: a hardcoded extension blocklist is
Tzurot's stack frozen into seyag; rows are data.

### D6 — Bypass and toggle: friction with an audit trail, not enforcement

Per-command bypass `SYG_ALLOW_COMMIT_BRANCH=1` as an assignment in the
commit's own prefix (walker `bypass_assignment` semantics; `=0`/empty do not
waive; a token in prose/quotes/heredoc bodies is not a bypass; POLICY and
SYG_DISABLE are never honored from command text). Every bypass use appends a
line to an audit file under the XDG state dir
(`${XDG_STATE_HOME:-$HOME/.local/state}/seyag/` — the cwd-drift-guard
convention; reboot-durable, unlike the /tmp default of `SYG_STATE_DIR`),
append-only, in addition to stderr — the durable trail is the FILE, not
exit-0 stderr, whose session persistence is not assumed; a canary asserts the
append. Component toggle `guards-commit`; `SYG_DISABLE`; the
project-local hook override. Chained commands are judged per commit
invocation by the argv walk.

*Rejected — Tzurot's per-hook token family*: one token per policy row mints
tokens; the house has one bypass family.

### D7 — The Tzurot header half: dropped with disposition

Commitlint limits, TASK-N ids, subject case, the /tmp ack file — Tzurot's
pipeline front-run; seyag has no commitlint. Dropped (three-model council
consensus: the cleanest decision in the draft); the verdict protocol
collapses to one line, the only persistent state in the source disappears.
*Rejected — porting it as policy rows*: a different axis, no seyag consumer,
the ack-file machine is the fragile coupling; revival later is a clean add.

### D8 — Positioning: the commit-act gate, precisely scoped

The guard sees the `commit` verb only. Landing gated content on a protected
ref via `push`/`merge`/`rebase`/`cherry-pick`/`reset`/`branch -f`/
`symbolic-ref`/`commit-tree` is the ruleset ref restriction's role — this
design claims none of it and says so in the guard's docs. The delegation flow
is respected by construction: driver-only commits after transfer, workers
never commit, step-0's sanctioned reset involves no commit, and
`SYG_WORKTREE_BRANCH_RE` remains the matcher for whether an agent may
self-select a worktree branch (policy rows are a separate, general branch
matcher — the clarified sentence).

### D9 — The seyag-repo policy: one row, honestly labeled (owner call — O1)

`main-gate:any:\.(sh|py|md|json|yml|tsv|txt|yaml)$|^\.claude/|^\.github/|^plugins/seyag/bin/:^main$:block` —
"no seyag-stack commits while on main." (The set includes `.tsv`/`.txt`/`.yaml`
— components.tsv and the coupling allowlist are seyag-stack by any definition —
and `^plugins/seyag/bin/`, because the stack's 24 extensionless bin tools carry
no extension for the suffix ERE to catch.)
It mechanizes the commit-act half of
the standing rule; the push half stays with the ruleset ref restriction, the
bypass is friction + audit, and non-stack content (Dockerfile, LICENSE,
no-extension files, `--allow-empty`) is out of the row's scope by data. Ships
in this repo's settings, not as a plugin default; in the settings JSON each
backslash doubles (`\\.sh` decodes to the `\.sh` D1 validates) — Slice C pins
the literal JSON value. No docs-on-unit-branch row
without an observed failure mode (unit branches are pushed and PR'd; nothing
strands).

### D10 — Canary set: each group pins one failure mode, with its exit code and stable token

1. Row semantics: gated file × blocked branch → exit 2 naming row+files+
   destination; non-gated file same branch → exit 0; `all` quantifier (mixed
   docs+code does NOT fire the doc row — hook B's real semantics);
   `-`/empty-set rows and `--allow-empty`; detached-HEAD sentinel matching.
2. Destination resolution: `switch -c`/`-C`, `checkout -b`/`-B` (the real
   create/switch flags), bare commit on the live branch, `git -C elsewhere
   commit`, `cd elsewhere && git commit`; branch-nomatch (`!`) rows firing
   outside the allowed set.
3. Ambiguity + pipe/subshell cwd: `cd -`/`popd`/`~user` → exit 2 with remedy;
   multi-checkout → same; pipeline/background/subshell/group cwd truths each
   pinned (`cd /x | git commit` judges the LIVE dir; `{ cd /x; git commit; }`
   judges /x); `out=$(git commit …)` judged; branch-mutating unknown
   (`symbolic-ref`, `--orphan`) → ambiguous, never unchanged.
4. Wrapper/heredoc bypass: `bash -c 'git commit …'` → blocked; `watch -n1 '…'` → blocked;
   `su -c '…'` → blocked; `su -l '…'` → ambiguous; `sudo -i sh -c 'cd <repo>
   && git commit'` → ambiguous (the login-form class); unquoted-heredoc body
   carrying a commit → row action, never silent pass; quoted-heredoc-to-shell
   (`bash <<'EOF'`) → judged; other-host ssh with an inner commit → ambiguous;
   ssh localhost → judged normally.
5. Relocation: `GIT_DIR=… GIT_WORK_TREE=… git commit`, `git --git-dir=…
   --work-tree=… commit` → ambiguous → block-row block; content computed at
   the candidate location (gated file only in the `-C` sibling → blocks).
6. Bypass: prefix waives; `=0`/empty don't; prose/quotes don't; chained mixed
   → the un-bypassed commit still judged; every bypass APPENDS the audit-file
   line (the file asserted, not stderr).
7. Content sources: `git add` + pathspec; `commit -a` tracked-only (untracked
   `.sh` + `-am` → no untracked in set); `<paths>` = `--only`; `--include`
   additive; `--pathspec-from-file` → ambiguous file set (evaluated as the
   wide fallback: `any` rows fire, `all` rows satisfied — the conservative
   direction); `--amend` same-branch; wide-fallback blocks for block rows;
   an `all` row over `--allow-empty` does not fire and a `-` row does (the
   empty-set rule, pinned once).
8. Config: empty policy inert; INVALID rows → exit 2 with the row named
   (refuse-secure); `[:]` spelling accepted; name collision and control-char
   names refused; `warn` rows deliver `additionalContext` (asserted, not
   assumed) and never downgrade an ambiguous posture; crash (injected
   exception) → exit 2, not fail-open.
9. Hygiene: fixture trees never touch the live repo; HOME/CDPATH pinned per
   the branch_switch test convention; a no-git-argv command exits via the
   fast path.

## What this deliberately does NOT do

- No commit-message/header policy (D7; Tzurot keeps its half).
- No push-time or other-verb enforcement in v1 (perimeter; the ruleset owns
  ref restriction; git-hooks dispatcher deferred with a first-adopter trigger).
- No remote-commit judgment (ambiguous instead; D3).
- No default policy rows in the plugin (D9 ships in seyag's own settings).
- No claim to branch protection (D8).
- No new quote scanner, no new content extractor (D2/D5).

## Phasing

| Slice | Content | Notes |
| --- | --- | --- |
| A | `branch_switch.py` + `commit_location.sh` + `branch_switch_test.py` port onto seyag's lib; 205 rows adjudicated per-axis; the scanner parity suite (heredoc-to-shell, `$()`, backticks, here-strings, eval-join) | delegation unit; the tables are the acceptance gate. SHIPPED 2026-10-29: the ported 205-row table grew to 247 through the review rounds (28 D4 isolation rows replacing the five empty-reading rows; 14 R1 rows for keyword-prefixed movers and redirect-suffixed cds); D4's connector truth is implemented (the walker reads `\|`/`&`/`( )` as isolating, `{ }` as persisting); review F3's predicted gap disproved at runtime (the scanner resolves a command word's quoted content), its marker came off; the test modules moved to `tests/` and the resolver gained its own probe |
| B | the `commit-branch-guard` hook over the D1 grammar + D10 canary probe + components.tsv/hooks.json wiring + README row + the replay gate (`tests/replay-hook.sh commit-branch-guard --since 7`, the D9 row exported) | delegation unit; joins guards-commit; CLAUDE.md requires the replay before a new hook ships |
| C | seyag-repo policy row in settings (D9, with the JSON-escaped spelling pinned) + docs | small; driver-side + docs PR |

## § Council record

Panel: 4 models briefed with identical adversarial text (2026-10-29); **3
answered** — `z-ai/glm-5.3`, `moonshotai/kimi-k3`,
`deepseek/deepseek-v4-pro`. `qwen/qwen3.8-max-0902`'s call failed idle at
1800 s (second engagement failure for that id this session); the fold ran on
the responding panel per the council skill, with the owner pass as the final
gate.

**Adopted** (attributed; convergent findings marked):

- **Grammar rebuilt (glm + kimi + deepseek, unanimous)**: newline rows, `!`
  branch negation, `any|all` quantifier, `[:]` spelling, detached-HEAD
  sentinel, empty-set token, invalid-config REFUSES (deepseek: the
  invalid-row fail-open contradicted the cited invalid-refuses precedent),
  name sanitization, all-match evaluation, the fast path.
- **Hook B unrepresentability (all three)**: branch-nomatch + the `all`
  quantifier are what make "doc-only, everywhere outside" expressible; under
  the draft's ∃ semantics hook B was an approximation marketed as a port.
- **Stripping adjudication split (glm + kimi)**: FP-axis flips accept;
  FN-axis flips (executing spans erased) require compensating entries; the
  scanner-layer parity suite added — the wrapper bypass lives one layer above
  branch_switch (kimi: "the 851L→2932L scanner divergence gets no parity
  suite" was the draft's gap).
- **Relocation axis (glm + kimi + deepseek)**: GIT_DIR/GIT_WORK_TREE/
  GIT_INDEX_FILE env + --git-dir/--work-tree flags → ambiguous; assignment
  parsing exists in the walker.
- **Connector truth table (kimi, correcting the draft's naive spread)**:
  `|`/`&`/`( )` isolate, `&&`/`||`/`;`/`{ }` persist — false-ambiguity pins.
- **Perimeter rewrite (glm + kimi + deepseek)**: session-persisted functions/
  aliases/exports, wrapper scripts, make/npm join ssh in an explicit
  indirection list; `ssh localhost` judged local (deepseek's 5-second bypass);
  other-host ssh ambiguous rather than exit 0.
- **D9 relabeled (all three)**: "no seyag-stack commits while on main"; the
  push rule's backstop is the ruleset; bypass = friction + audit line; glm's
  verb list (merge/rebase/cherry-pick/…) joined the scope sentence.
- **Crash refuses (kimi)**: an opt-in guard fails toward on; catch-all →
  exit 2. Warn delivers via `additionalContext` with a delivery canary
  (kimi + deepseek: exit-0 stderr is invisible).
- **D2 two-axis adjudication + D5 git-semantics pins (kimi + deepseek)**:
  `-a` tracked-only, `<paths>`=`--only`, `--include` additive,
  `--pathspec-from-file`/`--amend` explicit, wide-fallback blocks.
- **su login forms → ambiguous (kimi)**; runner table: `su` and `flock` join,
  the existing `watch`/`sudo`/`doas`/`timeout` entries reused (deepseek's
  stale-claim catch against `_RUNNERS`), interiors-always-scanned as the
  content-based rule
  (deepseek); `switch -c`/`checkout -b` flag correction (deepseek caught the
  draft's non-existent `switch -b` example); branch-mutating unknown →
  ambiguous never unchanged (kimi); symbolic-ref evasion named (kimi); alias
  hole documented + canaried (kimi); bypass audit line + `=0` non-waive +
  policy-never-from-command-text (kimi); row-name forgery sanitized
  (deepseek); fast path (deepseek); content-at-candidate-location (glm);
  substitution-argument rows (glm); 32-cap wrapper-heavy note (deepseek).

**Declined** (with reasons, no tombstones):

- Re-run of the silent qwen slot before folding — three convergent panels +
  the owner gate made a fourth position redundant; recorded here rather than
  re-briefed.
- GIT_COMMIT_RE port, tzurot shell_quotes vendoring, naive connector spread,
  inline>5-line policy rows — per-decision rejections above.

**Splits resolved without tiebreaker**: none — the responding panel was
convergent on every repair; the disagreements were additive (each model's
unique catches folded without contention).

## Open calls

| # | Call | Status |
| --- | --- | --- |
| O1 | seyag-repo policy row (D9) | CONFIRMED (owner): ship the relabeled ^main$ row in this repo's settings |
| O2 | `su` in the runner table, login forms ambiguous (D3) | CONFIRMED (council 3-0, folded into D3) |
| O3 | `warn` action in v1, delivered via additionalContext | CONFIRMED (council 3-0, folded into D1/D10) |
