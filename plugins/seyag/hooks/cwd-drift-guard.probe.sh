#!/bin/bash
# Fixture check for cwd-drift-guard.sh — run after ANY edit to the hook.
# Asserts the exit-code table over the shapes that matter: a bare git command
# whose pathspec exists only from the repo root, run from a drifted subdir
# cwd, blocks (exit 2); everything else (git -C, at-root, pnpm, no pathspec,
# a path that exists from the cwd, a skipped token class) passes.
#
# The hook asks the FILESYSTEM whether a path exists from the cwd or from the
# root, so this probe builds a real fixture repo in a temp dir (removed on
# exit):
#
#   root/NOTES.md  root/src/a.py  root/docs/x.md  root/.github/ci.yml
#   root/pkg/sub/local.txt  root/pkg/other/docs/y.md (a name in BOTH places;
#   it lives under pkg/other, not pkg/sub, because a pkg/sub/docs would make
#   `git add docs/x.md` from pkg/sub a both-places name too)
#   plus root entries named `~tilde`, `:magic`, `docs*`, `-dash`, so the
#   skipped-token cases pass ONLY because of the skip rule, not because the
#   name is missing from the root.
#   wt/ is a linked worktree of root.
#   The stray-copy section adds pkg/stray/docs/x.md (untracked, shadowing the
#   tracked root docs/x.md) and pkg/kept/docs/x.md (the same path, tracked).
#
# Ported from Tzurot's .claude/hooks/cwd-drift-guard.probe.sh. Its 22 tracker
# cases are dropped with the tracker rule; its folder-list case (.github) is
# kept as a dot-directory case.
#
# Usage: hooks/cwd-drift-guard.probe.sh   (from anywhere)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$SCRIPT_DIR/cwd-drift-guard.sh"

TMP=$(mktemp -d) || { echo "FAIL [setup]: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
# Hermetic: git must not find a repo above the fixture (the temp dir could sit
# inside one), so a "not a repo" case means what it says.
export GIT_CEILING_DIRECTORIES="$TMP"
export XDG_STATE_HOME="$TMP/state"
ROOT="$TMP/root"
SUB="$ROOT/pkg/sub"
WT="$TMP/wt"
WT2="$TMP/wt2"
NOREPO="$TMP/norepo"

mkdir -p "$ROOT/src" "$ROOT/docs" "$ROOT/.github" "$SUB" "$ROOT/pkg/other/docs" \
  "$ROOT/~tilde" "$ROOT/docs*" "$NOREPO"
echo a >"$ROOT/src/a.py"
echo x >"$ROOT/docs/x.md"
echo n >"$ROOT/NOTES.md"
echo c >"$ROOT/.github/ci.yml"
echo m >"$ROOT/:magic"
echo d >"$ROOT/-dash"
echo l >"$SUB/local.txt"
echo s >"$ROOT/pkg/other/docs/y.md"
echo o >"$ROOT/pkg/other/o.txt"
git init -q "$ROOT" >/dev/null 2>&1
git -C "$ROOT" add -A >/dev/null 2>&1
git -C "$ROOT" -c user.email=probe@example.invalid -c user.name=probe \
  commit -q -m init >/dev/null 2>&1
git -C "$ROOT" worktree add -q -b probe-fixture "$WT" >/dev/null 2>&1
git -C "$ROOT" worktree add -q -b probe-fixture-2 "$WT2" >/dev/null 2>&1

if [ ! -e "$WT/.git" ] || [ ! -e "$WT/docs/x.md" ] || [ ! -d "$WT/pkg/sub" ] || [ ! -e "$WT2/.git" ]; then
  # Without the fixture every case below would pass or fail for the wrong
  # reason.
  echo "FAIL [setup]: could not build the fixture repo and worktree"
  exit 1
fi

fail=0
count=0
# check <expected-exit> <label> <command> <cwd|__NONE__>
# TOOL=<name> in the caller's environment overrides tool_name (default Bash).
# SESSION=<id> overrides session_id (default probe-<count>; __NONE__ omits it).
# SYG_CWD_DRIFT_WORKTREE=<val> forwards the worktree toggle to the hook.
check() {
  local expected="$1" label="$2" cmd="$3" cwd="$4" tool="${TOOL:-Bash}" sess="${SESSION:-probe-$count}" payload got
  # The command reaches jq on stdin, not argv, so a case past 128 KiB is not capped by exec.
  if [ "$cwd" = "__NONE__" ]; then
    payload=$(printf '%s' "$cmd" | jq -Rs --arg t "$tool" '{tool_name:$t,tool_input:{command:.}}')
  elif [ "$sess" = "__NONE__" ]; then
    payload=$(printf '%s' "$cmd" | jq -Rs --arg t "$tool" --arg d "$cwd" \
      '{tool_name:$t,tool_input:{command:.},cwd:$d}')
  else
    payload=$(printf '%s' "$cmd" | jq -Rs --arg t "$tool" --arg d "$cwd" --arg s "$sess" \
      '{tool_name:$t,tool_input:{command:.},cwd:$d,session_id:$s}')
  fi
  printf '%s' "$payload" | SYG_CWD_DRIFT_WORKTREE="${SYG_CWD_DRIFT_WORKTREE:-}" bash "$HOOK" >/dev/null 2>&1
  got=$?
  count=$((count + 1))
  if [ "$got" != "$expected" ]; then
    echo "FAIL [$got≠$expected]: $label"
    fail=1
  else
    echo "ok   [$got]: $label"
  fi
}

# --- The core rule --------------------------------------------------------
check 2 "drift + root-relative dir pathspec" "git add docs/x.md" "$SUB"
check 2 "drift + bare root-file pathspec (NOTES.md)" "git add NOTES.md" "$SUB"
check 2 "drift pathspec on the line after another command" $'ls\ngit add docs/x.md' "$SUB"
check 2 "drift + dot-directory pathspec (.github)" "git add .github/ci.yml" "$SUB"
check 2 "drift one level down (pkg/other) + root pathspec" "git add src/a.py" "$ROOT/pkg/other"
check 2 "a path naming the drifted dir itself from inside it" "git add pkg/sub/local.txt" "$SUB"
check 0 "drift + path that exists from the cwd" "git add local.txt" "$SUB"
check 0 "a name existing in BOTH the cwd and the root" "git add docs/y.md" "$ROOT/pkg/other"
check 0 "a name existing in NEITHER place" "git add nowhere.txt" "$SUB"
check 0 "shell at repo root (no drift)" "git add docs/x.md" "$ROOT"
check 0 "git -C is root-anchored" "git -C $ROOT add docs/x.md" "$SUB"
check 0 "git -C \"\$(git rev-parse --show-toplevel)\" (the banner's fix)" \
  "git -C \"\$(git rev-parse --show-toplevel)\" add docs/x.md" "$SUB"
check 0 "pnpm from a subdir is legitimate" "pnpm --filter x test" "$SUB"
check 0 "git status (no pathspec)" "git status" "$SUB"
check 0 "git log (no pathspec)" "git log --oneline -5" "$SUB"
check 0 "not a repo" "git add docs/x.md" "$NOREPO"
check 0 "no cwd in payload (fail-safe)" "git add docs/x.md" "__NONE__"
check 0 "empty cwd in payload (fail-safe)" "git add docs/x.md" ""
TOOL=Read check 0 "non-Bash tool" "git add docs/x.md" "$SUB"

# --- `--` and positional words -------------------------------------------
check 2 "tokens after -- are pathspecs" "git checkout -- docs/x.md" "$SUB"
check 2 "a ref before -- does not hide the path after it" "git log main -- docs/x.md" "$SUB"
check 0 "after --, a path that exists from the cwd" "git checkout -- local.txt" "$SUB"

# --- Commit messages and quoting -----------------------------------------
check 0 "path-like text only INSIDE a quoted commit message" \
  "git commit -m \"update docs/x.md\"" "$SUB"
check 0 "an unquoted one-word -m message is not a path" "git commit -m docs" "$SUB"
check 0 "-am clusters: the message word is not a path" "git commit -am NOTES.md" "$SUB"
check 0 "a quoted pathspec is not judged (quote-stripped scan)" "git add \"docs/x.md\"" "$SUB"
# Two apostrophes STRADDLING a real pathspec. A naive two-pass quote strip
# pairs them and deletes the pathspec between; the shared scanner does not.
check 2 "apostrophes straddling a real pathspec" \
  "git commit -m \"it's\" && git add docs/x.md && echo \"don't\"" "$SUB"
check 0 "apostrophes, and the only path is inside quotes" \
  "git commit -m \"it's docs/x.md\" && echo \"don't\"" "$SUB"
check 0 "a heredoc commit message body is not scanned" \
  "git commit -F - <<'EOF'
git add docs/x.md
EOF" "$SUB"
check 2 "a comment-hidden opener does not swallow git add" \
  $'# <<x\ngit add docs/x.md\nx' "$SUB"
check 2 "a quote-hidden opener does not swallow git add" \
  $'echo "<<x"\ngit add docs/x.md\nx' "$SUB"

# --- Case and anchor flags -----------------------------------------------
check 2 "uppercase GIT is still detected" "GIT ADD docs/x.md" "$SUB"
check 0 "uppercase but root-anchored is exempt" "GIT -C $ROOT add docs/x.md" "$SUB"
check 0 "--git-dir is exempt" "git --git-dir=$ROOT/.git add docs/x.md" "$SUB"
check 0 "uppercase --git-dir (separate value) is exempt" "GIT --git-dir $ROOT/.git add docs/x.md" "$SUB"
# `-c key=val` overrides config and anchors nothing; folding it into `-C`
# would silently exempt a live shape.
check 2 "config -c does NOT exempt (it anchors nothing)" "git -c core.pager=cat add docs/x.md" "$SUB"
check 2 "uppercase GIT -c also does NOT exempt" "GIT -c core.pager=cat add docs/x.md" "$SUB"
check 2 "--git-directory is NOT --git-dir" "git --git-directory=x add docs/x.md" "$SUB"
# Quoted text merely CONTAINING the anchor flag must not exempt the real
# invocation beside it.
check 2 "quoted \"git -C\" does not exempt real drift" \
  "git commit -m \"see git -C /somewhere\" && git add docs/x.md" "$SUB"
check 2 "an anchored git earlier in the chain does not exempt a bare one" \
  "git -C $ROOT status && git add docs/x.md" "$SUB"

# --- Skipped token classes (each root entry exists, so only the skip allows)
check 0 "glob token is skipped" "git add docs*/x.md" "$SUB"
check 0 "absolute token is skipped" "git add $ROOT/docs/x.md" "$SUB"
check 0 "~ token is skipped" "git add ~tilde" "$SUB"
check 0 ": pathspec magic is skipped" "git add :magic" "$SUB"
check 0 "- token after -- is skipped" "git add -- -dash" "$SUB"
check 0 ". and .. tokens are skipped" "git add . ../../docs/x.md" "$SUB"
check 0 "unexpanded variable is skipped" "git add \$F/x.md" "$SUB"
check 0 "a redirection target is not a pathspec" "git diff > NOTES.md" "$SUB"
check 0 "a 2>&1 redirection does not split the command" "git status 2>&1" "$SUB"

# --- Command position and wrappers ---------------------------------------
check 2 "an env-assignment prefix does not hide git" "GIT_PAGER=cat git diff docs/x.md" "$SUB"
check 2 "timeout <n> git … is still git" "timeout 60 git add docs/x.md" "$SUB"
check 2 "git inside an unquoted substitution runs in the same cwd" \
  "x=\$(git ls-files docs) && echo \$x" "$SUB"
check 2 "git later in a pipeline" "echo hi | git hash-object --stdin docs/x.md" "$SUB"
check 0 "a git word that is only an echo argument" "echo git add docs/x.md" "$SUB"

# --- A `cd` inside the command -------------------------------------------
check 2 "cd into a subdir, then a root-relative git pathspec later in the chain" \
  "cd pkg/sub && git add docs/x.md" "$ROOT"
check 2 "cd into a subdir, tests, then git checkout -- <root path>" \
  "cd pkg/other && ls && git checkout -- src/a.py" "$ROOT"
check 0 "cd then git -C is still root-anchored" \
  "cd pkg/sub && git -C $ROOT checkout -- docs/x.md" "$ROOT"
check 0 "cd then a chain with no git step at all" "cd pkg/sub && ls" "$ROOT"
check 2 "a relative cd through .. still resolves to the drifted dir" \
  "cd ../other && git checkout -- src/a.py" "$SUB"
check 0 "cd to the repo root by absolute path self-corrects" "cd $ROOT && git add docs/x.md" "$SUB"
check 0 "cd to the root by a variable (unresolvable) allows" "cd \"\$ROOT_DIR\" && git add docs/x.md" "$SUB"
check 0 "cd out of the repo entirely is not this hook's concern" \
  "cd $NOREPO && git add docs/x.md" "$SUB"
# The separator strip before the classification is blind to escaping; the
# hook must fall open rather than compute a truncated cwd. The cwd is drifted
# so a 0 cannot come from the no-drift exit.
check 0 "an escaped separator in a cd target falls open" \
  "cd foo\\&bar && git add docs/x.md" "$SUB"
check 0 "a cd later in the chain stops the scan" "ls && cd $ROOT && git add docs/x.md" "$SUB"
check 0 "a subshell cd stops the scan" "(cd $ROOT && git add docs/x.md)" "$SUB"

# --- Stray copies ----------------------------------------------------------
# pkg/stray/docs/x.md is an UNTRACKED leftover of a drifted write, shadowing
# the tracked root docs/x.md; pkg/kept/docs/x.md is the same path TRACKED on
# purpose. Added after the fixture commit, so the tracked/untracked split is real.
# pkg/stray also holds a tracked keep.txt: a stray only counts inside a folder that
# already has tracked files. pkg/new has none (a package being scaffolded).
mkdir -p "$ROOT/pkg/stray/docs" "$ROOT/pkg/kept/docs" "$ROOT/pkg/new/docs"
echo stray >"$ROOT/pkg/stray/docs/x.md"
echo stray >"$ROOT/pkg/stray/NOTES.md"
echo keep >"$ROOT/pkg/stray/keep.txt"
echo kept >"$ROOT/pkg/kept/docs/x.md"
echo scaffold >"$ROOT/pkg/new/docs/x.md"
git -C "$ROOT" add pkg/kept/docs/x.md pkg/stray/keep.txt >/dev/null 2>&1
git -C "$ROOT" -c user.email=probe@example.invalid -c user.name=probe \
  commit -q -m kept >/dev/null 2>&1
echo s >"$ROOT/scratch.txt"; echo s >"$ROOT/pkg/stray/scratch.txt"   # untracked in both places
check 2 "an untracked stray shadowing a tracked root file blocks" "git add docs/x.md" "$ROOT/pkg/stray"
check 2 "a single-component stray (NOTES.md) blocks" "git add NOTES.md" "$ROOT/pkg/stray"
check 2 "a directory token holding a stray blocks" "git add docs" "$ROOT/pkg/stray"
check 2 "a read that would silently answer about the stray (git diff) blocks" "git diff docs/x.md" "$ROOT/pkg/stray"
check 0 "the same path tracked in the subdir too is intended" "git add docs/x.md" "$ROOT/pkg/kept"
check 0 "a folder with no tracked files (scaffolding) never counts as a stray" "git add docs/x.md" "$ROOT/pkg/new"
check 0 "untracked in both places is not a stray" "git add scratch.txt" "$ROOT/pkg/stray"
check 0 "an untracked new file with no root counterpart passes" "git add docs/new.md" "$ROOT/pkg/stray"
echo new >"$ROOT/pkg/stray/docs/new.md"
check 0 "…and still passes once the new file exists" "git add docs/new.md" "$ROOT/pkg/stray"
# A git that fails the ROOT-side ls-files must not turn "can't tell" into a block.
REAL_GIT=$(command -v git); FAKE="$TMP/fakebin"; mkdir -p "$FAKE"
cat >"$FAKE/git" <<EOF
#!/bin/bash
if [ "\$1" = "-C" ] && [ "\$2" = "$ROOT" ] && [ "\$3" = "ls-files" ]; then exit 128; fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$FAKE/git"
PATH="$FAKE:$PATH" check 0 "a failing root-side git check allows (never adds a block)" "git add docs/x.md" "$ROOT/pkg/stray"

# --- Worktrees -----------------------------------------------------------
# A linked worktree's root is its own toplevel, so a root-relative pathspec
# from there resolves exactly as it does from the main checkout's root.
check 0 "a worktree ROOT is a git toplevel, not drift" "git diff docs/x.md" "$WT"
check 2 "a subdir INSIDE a worktree is still drift" "git add docs/x.md" "$WT/pkg/sub"

# --- Linked worktree state-changing git subcommands (warn-once) ----------
# A bare state-changing git command landing in a linked worktree blocks once
# per (session_id, effective_cwd), naming both trees, the branch, and the repair.
SESSION=s-escape check 2 "linked worktree: bare git commit blocks on first call" "git commit -m x" "$WT"
SESSION=s-escape check 0 "linked worktree: bare git commit allows on second call (warn-once)" "git commit -m x" "$WT"
SESSION=s-escape check 0 "linked worktree: later state-changing subcommand in same cwd+session allows" "git push" "$WT"

count=$((count + 1))
if [ -f "$XDG_STATE_HOME/seyag/cwd-drift-guard/s-escape" ] \
  && grep -qxF "$WT" "$XDG_STATE_HOME/seyag/cwd-drift-guard/s-escape"; then
  echo "ok   [state]: state file records warned effective cwd ($WT)"
else
  echo "FAIL [state]: state file missing or wrong content for s-escape"
  fail=1
fi

SESSION=s-escape check 2 "linked worktree: switching to another worktree in same session warns again" "git commit -m x" "$WT2"
SESSION=s-escape check 0 "linked worktree: second call in second worktree allows" "git commit -m x" "$WT2"
SESSION=s-escape check 0 "linked worktree: returning to first worktree after cwd change does not re-warn" "git commit -m x" "$WT"
SESSION=s-escape check 2 "linked worktree: subdir inside worktree is a distinct effective cwd and warns" "git commit -m x" "$WT/pkg/sub"
SESSION=s-other  check 2 "linked worktree: a different session id warns independently" "git commit -m x" "$WT"

# Leading `cd <worktree>` with payload cwd in the main checkout:
SESSION=s-cd check 2 "cd <worktree> && git commit from main checkout blocks once" "cd $WT && git commit -m x" "$ROOT"
SESSION=s-cd check 0 "cd <worktree> && git commit second time in same session allows" "cd $WT && git commit -m x" "$ROOT"

# Banner text assertions (names effective cwd, branch, payload/main tree, repair, confirm-once):
WT_BANNER=$(jq -nc --arg d "$ROOT" --arg c "cd $WT && git commit -m x" --arg s "s-banner" \
  '{tool_name:"Bash",tool_input:{command:$c},cwd:$d,session_id:$s}' | bash "$HOOK" 2>&1 >/dev/null)
WT_BANNER_RC=$?
count=$((count + 1))
if [ "$WT_BANNER_RC" = 2 ] \
  && grep -qF "$WT" <<<"$WT_BANNER" \
  && grep -qF "probe-fixture" <<<"$WT_BANNER" \
  && grep -qF "$ROOT" <<<"$WT_BANNER" \
  && grep -qF "anchor the git step: git -C \"$ROOT\" commit" <<<"$WT_BANNER" \
  && grep -qF "cd \"$ROOT\" first." <<<"$WT_BANNER" \
  && grep -qE 're-running|same command|warn-once' <<<"$WT_BANNER"; then
  echo "ok   [banner]: linked-worktree block message names both trees, branch, repair, and confirm-once"
else
  echo "FAIL [banner]: linked-worktree block message missing required fields (rc=$WT_BANNER_RC)"
  fail=1
fi

# Every state-changing subcommand in the list triggers the block:
for subcmd_case in \
  "tag:git tag v1" \
  "notes:git notes add -m note" \
  "merge:git merge main" \
  "rebase:git rebase main" \
  "reset:git reset --hard" \
  "cherry-pick:git cherry-pick HEAD" \
  "revert:git revert HEAD" \
  "stash:git stash" \
  "am:git am patch.mbox" \
  "checkout:git checkout -b feat" \
  "switch:git switch main" \
  "branch:git branch feat" \
  "push:git push origin HEAD"
do
  sc_name="${subcmd_case%%:*}"
  sc_cmd="${subcmd_case#*:}"
  check 2 "linked worktree state-changing subcommand ($sc_name) blocks" "$sc_cmd" "$WT"
done
check 2 "linked worktree: git branch -d stays blocked" "git branch -d feat" "$WT"
check 2 "linked worktree: git branch -D stays blocked" "git branch -D feat" "$WT"
check 2 "linked worktree: git stash pop stays blocked" "git stash pop" "$WT"
check 2 "linked worktree: git -c key=val before state-changing subcommand still blocks" \
  "git -c user.name=probe commit -m x" "$WT"

# Read-only and index-only subcommands in a linked worktree never trigger the rule:
check 0 "linked worktree: git status allows" "git status" "$WT"
check 0 "linked worktree: git log allows" "git log --oneline -5" "$WT"
check 0 "linked worktree: git diff allows" "git diff" "$WT"
check 0 "linked worktree: git add at worktree root allows" "git add docs/x.md" "$WT"
check 0 "linked worktree: git fetch allows" "git fetch" "$WT"
check 0 "linked worktree: bare git branch (read-only) allows" "git branch" "$WT"
check 0 "linked worktree: git branch read-only flags allow" "git branch -a -r -l --list --show-current -v -vv" "$WT"
check 0 "linked worktree: bare git tag (read-only) allows" "git tag" "$WT"
check 0 "linked worktree: git tag -l / --list allows" "git tag -l" "$WT"
check 0 "linked worktree: git notes list allows" "git notes list" "$WT"
check 0 "linked worktree: git notes show allows" "git notes show" "$WT"
check 0 "linked worktree: git stash list allows" "git stash list" "$WT"
check 0 "linked worktree: git stash show allows" "git stash show" "$WT"
check 0 "linked worktree: git push --dry-run allows" "git push origin HEAD --dry-run" "$WT"

# Toggle and session_id fail-open rows:
SYG_CWD_DRIFT_WORKTREE=0 check 0 "linked worktree: SYG_CWD_DRIFT_WORKTREE=0 disables the rule" "git commit -m x" "$WT"
SESSION=__NONE__ check 0 "linked worktree: missing session_id in payload fails open" "git commit -m x" "$WT"
SESSION=../x     check 0 "linked worktree: invalid session_id (../x) fails open" "git commit -m x" "$WT"

# Rule is invisible off linked worktrees, and anchored commands pass:
check 0 "main checkout root: bare git commit allows (not a linked worktree)" "git commit -m x" "$ROOT"
check 0 "main checkout subdir: bare git commit with no pathspec allows" "git commit -m x" "$SUB"
check 0 "cd back to main checkout from worktree allows" "cd $ROOT && git commit -m x" "$WT"
check 0 "linked worktree: git -C <main> commit allows (anchored)" "git -C $ROOT commit -m x" "$WT"
check 0 "linked worktree: git --git-dir=<main>/.git commit allows (anchored)" \
  "git --git-dir=$ROOT/.git commit -m x" "$WT"
check 0 "linked worktree: git -C \"\$(git rev-parse --show-toplevel)\" commit allows" \
  "git -C \"\$(git rev-parse --show-toplevel)\" commit -m x" "$WT"

# 7-day state file pruning on write:
mkdir -p "$XDG_STATE_HOME/seyag/cwd-drift-guard"
echo "$WT" >"$XDG_STATE_HOME/seyag/cwd-drift-guard/stale-sess"
echo "$WT" >"$XDG_STATE_HOME/seyag/cwd-drift-guard/fresh-sess"
touch -d '8 days ago' "$XDG_STATE_HOME/seyag/cwd-drift-guard/stale-sess"
touch -d '2 days ago' "$XDG_STATE_HOME/seyag/cwd-drift-guard/fresh-sess"
SESSION=s-prune check 2 "linked worktree: write triggers prune of >7d state files" "git commit -m x" "$WT"
count=$((count + 1))
if [ ! -e "$XDG_STATE_HOME/seyag/cwd-drift-guard/stale-sess" ] \
  && [ -e "$XDG_STATE_HOME/seyag/cwd-drift-guard/fresh-sess" ]; then
  echo "ok   [prune]: >7d state file pruned and <7d state file preserved"
else
  echo "FAIL [prune]: expected stale-sess removed and fresh-sess kept"
  fail=1
fi

# Unwritable or unreadable state fails OPEN (exit 0):
echo not-a-dir >"$TMP/state-file"
XDG_STATE_HOME="$TMP/state-file" SESSION=s-badbase \
  check 0 "unwritable state base (file at XDG_STATE_HOME) fails open" "git commit -m x" "$WT"

touch "$XDG_STATE_HOME/seyag/cwd-drift-guard/s-unreadable"
chmod 000 "$XDG_STATE_HOME/seyag/cwd-drift-guard/s-unreadable"
SESSION=s-unreadable check 0 "unreadable state file (000) fails open" "git commit -m x" "$WT"
chmod 600 "$XDG_STATE_HOME/seyag/cwd-drift-guard/s-unreadable"

chmod 500 "$XDG_STATE_HOME/seyag/cwd-drift-guard"
SESSION=s-rodir check 0 "unwritable state dir (500) fails open" "git commit -m x" "$WT"
chmod 700 "$XDG_STATE_HOME/seyag/cwd-drift-guard"

# --- A command past 128 KiB (Linux's cap on one env string) --------------
BIG=$(printf '%*s' 214000 '' | tr ' ' x)
check 2 "drift behind a heredoc past 128 KiB still blocks" \
  "cat > notes.md <<'EOF'"$'\n'"$BIG"$'\nEOF\n'"git add docs/x.md" "$SUB"

echo "---"
echo "$count cases"
[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
