#!/bin/bash
# Hermetic fixture check for plugins/seyag/bin/fixup-push against a bare origin,
# a fixture clone on branch `feat` with base `main`, and a `gh` shim on PATH.
# Never touches GitHub.
#
# Usage: tests/fixup-push.probe.sh   (from anywhere)

set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN="$SCRIPT_DIR/../plugins/seyag/bin/fixup-push"

WORK=$(mktemp -d)
export WORK
trap 'rm -rf "$WORK"' EXIT
FAKE_BIN="$WORK/fakebin"
HOME_DIR="$WORK/home"
WT_TMP="$WORK/tmp"
mkdir -p "$FAKE_BIN" "$HOME_DIR" "$WT_TMP"
export HOME="$HOME_DIR"

cat > "$FAKE_BIN/gh" <<'SHIM'
#!/bin/bash
set -uo pipefail
CMD=${1:-}; shift || true
if [ "${FAKE_GH_FAIL:-}" = "$CMD" ]; then
  echo "gh shim: forced failure for $CMD" >&2
  exit 1
fi
case $CMD in
  repo)
    sub=${1:-}; shift || true
    target=${1:-}; shift || true
    json_val=""
    q_val=""
    while [ $# -gt 0 ]; do
      case $1 in
        --json) json_val=$2; shift ;;
        -q) q_val=$2; shift ;;
        *) echo "gh shim: unexpected repo flag: $1" >&2; exit 64 ;;
      esac
      shift
    done
    if [ "$sub" != "view" ] || [ "$target" != "github.com/acme/widget" ] \
      || [ "$json_val" != "nameWithOwner,defaultBranchRef" ] \
      || [ "$q_val" != '.nameWithOwner + " " + .defaultBranchRef.name' ]; then
      echo "gh shim: unexpected args: repo $sub $target --json $json_val -q $q_val" >&2
      exit 64
    fi
    printf '%s %s\n' "${FAKE_NWO:-acme/widget}" "${FAKE_DEFAULT:-main}"
    exit 0
    ;;
  pr)
    sub=${1:-}; shift || true
    if [ "$sub" = "list" ]; then
      if [ "${FAKE_GH_FAIL:-}" = "prlist" ]; then
        echo "gh shim: forced failure for prlist" >&2
        exit 1
      fi
      repo_val=""
      base_val=""
      state_val=""
      json_val=""
      q_val=""
      while [ $# -gt 0 ]; do
        case $1 in
          --repo) repo_val=$2; shift ;;
          --base) base_val=$2; shift ;;
          --state) state_val=$2; shift ;;
          --json) json_val=$2; shift ;;
          -q) q_val=$2; shift ;;
          *) echo "gh shim: unexpected pr list flag: $1" >&2; exit 64 ;;
        esac
        shift
      done
      expect_branch=${FAKE_EXPECT_BRANCH:-feat}
      if [ "$repo_val" != "github.com/acme/widget" ] \
        || [ "$base_val" != "$expect_branch" ] \
        || [ "$state_val" != "open" ] \
        || [ "$json_val" != "number" ] \
        || [ "$q_val" != "length" ]; then
        echo "gh shim: unexpected args: pr list --repo $repo_val --base $base_val --state $state_val --json $json_val -q $q_val" >&2
        exit 64
      fi
      printf '%s\n' "${FAKE_CHILD_PRS:-0}"
      exit 0
    fi

    target=${1:-}; shift || true
    repo_val=""
    json_val=""
    q_val=""
    while [ $# -gt 0 ]; do
      case $1 in
        --repo) repo_val=$2; shift ;;
        --json) json_val=$2; shift ;;
        -q) q_val=$2; shift ;;
        *) echo "gh shim: unexpected pr flag: $1" >&2; exit 64 ;;
      esac
      shift
    done
    want_json="number,state,headRefName,baseRefName,isCrossRepository,headRepository,headRepositoryOwner"
    want_q='[.number,.state,.headRefName,.baseRefName,.isCrossRepository,(.headRepositoryOwner.login + "/" + .headRepository.name)]|@tsv'
    expect_branch=${FAKE_EXPECT_BRANCH:-feat}
    if [ "$sub" != "view" ] || [ "$target" != "$expect_branch" ] \
      || [ "$repo_val" != "github.com/acme/widget" ] \
      || [ "$json_val" != "$want_json" ] \
      || [ "$q_val" != "$want_q" ]; then
      echo "gh shim: unexpected args: pr $sub $target --repo $repo_val --json $json_val -q $q_val" >&2
      exit 64
    fi

    pr_count=1
    if [ -f "$WORK/pr_view.count" ]; then
      pr_count=$(($(cat "$WORK/pr_view.count") + 1))
    fi
    printf '%s\n' "$pr_count" > "$WORK/pr_view.count"

    effective_state="${FAKE_PR_STATE:-OPEN}"
    if [ -n "${FAKE_PR_CLOSE_ON:-}" ] && [ "$pr_count" -ge "$FAKE_PR_CLOSE_ON" ]; then
      effective_state="CLOSED"
    fi
    effective_base="${FAKE_PR_BASE:-${FAKE_DEFAULT:-main}}"
    if [ "$pr_count" -ge 2 ] && [ -n "${FAKE_PR_BASE_ON2:-}" ]; then
      effective_base="$FAKE_PR_BASE_ON2"
    fi
    printf '42\t%s\t%s\t%s\t%s\t%s\n' \
      "$effective_state" \
      "${FAKE_PR_HEAD:-$expect_branch}" \
      "$effective_base" \
      "${FAKE_CROSS:-false}" \
      "${FAKE_HEAD_REPO:-acme/widget}"
    exit 0
    ;;
  api)
    endpoint=""
    jq_val=""
    hostname_val=""
    while [ $# -gt 0 ]; do
      case $1 in
        --hostname) hostname_val=$2; shift ;;
        --jq) jq_val=$2; shift ;;
        -*) echo "gh shim: unexpected api flag: $1" >&2; exit 64 ;;
        *) endpoint=$1 ;;
      esac
      shift
    done
    if [ "$hostname_val" != "github.com" ]; then
      echo "gh shim: unexpected hostname: $hostname_val" >&2
      exit 64
    fi
    expect_branch=${FAKE_EXPECT_BRANCH:-feat}
    case $endpoint in
      repos/acme/widget/rules/branches/"$expect_branch")
        if [ "${FAKE_GH_FAIL:-}" = "rules" ]; then
          echo "gh shim: forced failure for rules" >&2
          exit 1
        fi
        if [ "$jq_val" != "length" ]; then
          echo "gh shim: unexpected args: api $endpoint --jq $jq_val" >&2
          exit 64
        fi
        printf '%s\n' "${FAKE_RULES:-0}"
        exit 0
        ;;
      repos/acme/widget/branches/"$expect_branch")
        branches_count=1
        if [ -f "$WORK/branches_api.count" ]; then
          branches_count=$(($(cat "$WORK/branches_api.count") + 1))
        fi
        printf '%s\n' "$branches_count" > "$WORK/branches_api.count"

        if [ "${FAKE_GH_FAIL:-}" = "branches" ]; then
          echo "gh shim: forced failure for branches" >&2
          exit 1
        fi
        if [ "$jq_val" != ".protected" ]; then
          echo "gh shim: unexpected args: api $endpoint --jq $jq_val" >&2
          exit 64
        fi
        effective_protected="${FAKE_PROTECTED:-false}"
        if [ "$branches_count" -ge 2 ] && [ "${FAKE_PROTECTED_ON2:-}" = "true" ]; then
          effective_protected="true"
        fi
        printf '%s\n' "$effective_protected"
        exit 0
        ;;
      *)
        echo "gh shim: unexpected api endpoint: $endpoint" >&2
        exit 64
        ;;
    esac
    ;;
esac
echo "gh shim: unexpected call: $CMD $*" >&2
exit 64
SHIM
chmod +x "$FAKE_BIN/gh"

ORIGIN_PATH="$WORK/origin.git"
ORIGIN="$ORIGIN_PATH"
ORIGIN_URL="ssh://git@github.com/acme/widget.git"
CLONE="$WORK/clone"
CLONE2="$WORK/clone2"

cat > "$WORK/fakessh" <<SSH
#!/bin/bash
set -uo pipefail
last_arg="\${@: -1}"
cmd="\${last_arg//\/acme\/widget.git/$ORIGIN_PATH}"
cmd="\${cmd//acme\/widget.git/$ORIGIN_PATH}"
cmd="\${cmd//\/acme\/decoy.git/$WORK/decoy.git}"
cmd="\${cmd//acme\/decoy.git/$WORK/decoy.git}"
exec sh -c "\$cmd"
SSH
chmod +x "$WORK/fakessh"
export GIT_SSH_COMMAND="$WORK/fakessh"

git init -q --bare "$ORIGIN_PATH"
git init -q --bare "$WORK/decoy.git"
git clone -q "$ORIGIN_URL" "$CLONE" 2>/dev/null
git clone -q "$ORIGIN_URL" "$CLONE2" 2>/dev/null

git -C "$CLONE" checkout -q -b main
git -C "$CLONE" config user.email t@example.invalid
git -C "$CLONE" config user.name t
git -C "$CLONE" config commit.gpgsign false
git -C "$CLONE" config tag.gpgsign false

git -C "$CLONE2" config user.email t2@example.invalid
git -C "$CLONE2" config user.name t2
git -C "$CLONE2" config commit.gpgsign false
git -C "$CLONE2" config tag.gpgsign false

printf 'base-line-1\n' > "$CLONE/f1.txt"
printf 'base-line-2\n' > "$CLONE/f2.txt"
printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\n' > "$CLONE/ctx.txt"
git -C "$CLONE" add f1.txt f2.txt ctx.txt
git -C "$CLONE" commit -qm "initial base"
git -C "$CLONE" push -q -u origin main
MAIN_INIT=$(git -C "$CLONE" rev-parse HEAD)

git -C "$CLONE" checkout -q -b feat
printf 'feat1-v1\n' > "$CLONE/f1.txt"
git -C "$CLONE" commit -qam "first feat commit"
printf 'feat2-v1\n' > "$CLONE/f2.txt"
git -C "$CLONE" commit -qam "second feat commit"
printf 'feat1-v2\n' > "$CLONE/f1.txt"
git -C "$CLONE" commit -qam "fixup! first feat commit"
git -C "$CLONE" push -q -u origin feat
FEAT_INIT=$(git -C "$CLONE" rev-parse HEAD)

reset_fixture() {
  unset FAKE_DEFAULT FAKE_PR_STATE FAKE_PR_HEAD FAKE_CROSS FAKE_PROTECTED FAKE_RULES FAKE_GH_FAIL FAKE_HEAD_REPO FAKE_EXPECT_BRANCH FAKE_NWO FAKE_PR_CLOSE_ON FAKE_PR_COUNTER_FILE FAKE_PR_BASE FAKE_PR_BASE_ON2 FAKE_PROTECTED_ON2 FAKE_CHILD_PRS
  rm -f "$CLONE/.git/hooks/pre-push" "$CLONE/.git/hooks/reference-transaction" "$WORK/race.sentinel" "$WORK/pr_counter" "$WORK/pr_view.count" "$WORK/branches_api.count"
  git -C "$CLONE" update-index --no-skip-worktree f1.txt 2>/dev/null || true
  git -C "$CLONE" update-index --no-assume-unchanged f1.txt 2>/dev/null || true
  git -C "$CLONE" remote rename upstream origin 2>/dev/null || true
  git -C "$CLONE" config --unset-all remote.origin.url 2>/dev/null || true
  git -C "$CLONE" config remote.origin.url "$ORIGIN_URL"
  git -C "$CLONE" config --unset-all remote.origin.pushurl 2>/dev/null || true
  git -C "$CLONE" config --unset remote.origin.push 2>/dev/null || true
  git -C "$CLONE" config --unset push.followTags 2>/dev/null || true
  git -C "$CLONE" config --unset rebase.updateRefs 2>/dev/null || true
  git -C "$CLONE" config --unset diff.context 2>/dev/null || true
  git -C "$CLONE" config --unset-all url.ssh://git@github.com/.insteadOf 2>/dev/null || true
  git -C "$CLONE" config --unset-all url.ssh://git@github.com/acme/decoy.git.insteadOf 2>/dev/null || true
  git -C "$CLONE" tag -d feat >/dev/null 2>&1 || true
  git -C "$WORK/decoy.git" branch -D feat >/dev/null 2>&1 || true
  git -C "$CLONE" tag -d v-local >/dev/null 2>&1 || true
  git -C "$ORIGIN" tag -d v-local >/dev/null 2>&1 || true
  git -C "$ORIGIN" branch -D rel >/dev/null 2>&1 || true
  git -C "$ORIGIN" branch -D elsewhere >/dev/null 2>&1 || true
  git -C "$ORIGIN" branch -D "user/feat" >/dev/null 2>&1 || true
  git -C "$CLONE" rebase --abort >/dev/null 2>&1 || true
  git -C "$CLONE" checkout -q -f -B main "$MAIN_INIT"
  git -C "$CLONE" checkout -q -f -B feat "$FEAT_INIT"
  git -C "$CLONE" branch -D rel >/dev/null 2>&1 || true
  git -C "$CLONE" branch -D "user/feat" >/dev/null 2>&1 || true
  git -C "$CLONE" clean -fdq
  git -C "$CLONE" push -q --force origin main feat
  git -C "$CLONE" fetch -q "$ORIGIN_URL" main feat
}

run_fp() {
  (cd "$CLONE" && env PATH="$FAKE_BIN:$PATH" TMPDIR="$WT_TMP" bash "$BIN" "$@")
}

patch_ids_of() {
  local range=$1 c pid list=""
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    pid=$(git -C "$CLONE" -c diff.noprefix=false -c diff.mnemonicPrefix=false -c diff.relative=false show --ignore-submodules=none --no-ext-diff --no-color --no-textconv --no-renames -U3 --binary --full-index --format= "$c" | git patch-id --stable | cut -d' ' -f1)
    list+="${list:+ }$pid"
  done < <(git -C "$CLONE" rev-list --reverse "$range")
  printf '%s\n' "$list"
}

fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

# Helper for refusal cases.
assert_refusal() {
  local label=$1 expected_msg=$2
  shift 2
  local rem_before loc_before out err rc rem_after loc_after
  rem_before=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
  loc_before=$(git -C "$CLONE" rev-parse HEAD)
  out=$("$@" 2>"$WORK/err"); rc=$?
  err=$(cat "$WORK/err")
  rem_after=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
  loc_after=$(git -C "$CLONE" rev-parse HEAD)
  [ "$rc" -eq 1 ] && ok "$label: exit 1" || bad "$label: exit $rc (out: $out err: $err)"
  [ -z "$out" ] && [[ "$err" != *$'\n'* ]] && grep -qF "fixup-push: refused: $expected_msg" <<<"$err" \
    && ok "$label: refusal message on stderr ($expected_msg)" \
    || bad "$label: message (out: [$out] err: [$err])"
  [ "$rem_after" = "$rem_before" ] && [ "$loc_after" = "$loc_before" ] \
    && ok "$label: remote and local unchanged" \
    || bad "$label: refs changed (rem $rem_before -> $rem_after, loc $loc_before -> $loc_after)"
}


# 1. Squash happy path: two commits plus a `fixup! ` of the first, already pushed.
reset_fixture
rem_before=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_before=$(git -C "$CLONE" rev-parse HEAD)
old_tree=$(git -C "$CLONE" rev-parse "HEAD^{tree}")
out=$(run_fp 2>&1); rc=$?
rem_after=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_after=$(git -C "$CLONE" rev-parse HEAD)
rem_tree=$(git -C "$ORIGIN" rev-parse "refs/heads/feat^{tree}")
subj_after=$(git -C "$CLONE" log --format=%s origin/main..HEAD)
wt_lines=$(git -C "$CLONE" worktree list)
wt_count=$(grep -c . <<<"$wt_lines")
SQUASHED_PATCH_IDS=$(patch_ids_of "origin/main..HEAD")
[ "$rc" -eq 0 ] && ok "1. squash happy path: exit 0" || bad "1. squash exit $rc (out: $out)"
grep -qxF "fixup-push: pushed feat ${rem_before:0:7}..${loc_after:0:7} (squash), lease ${rem_before:0:7}; local was ${loc_before:0:7}, 0 local-only commit(s) included" <<<"$out" \
  && ok "1. squash happy path: pushed line" || bad "1. squash pushed line (out: $out)"
[ "$rem_after" = "$loc_after" ] && [ "$rem_after" != "$rem_before" ] \
  && ok "1. squash happy path: remote equals local and moved from $rem_before" \
  || bad "1. squash refs (rem_before=$rem_before rem_after=$rem_after loc_after=$loc_after)"
[ "$rem_tree" = "$old_tree" ] \
  && ok "1. squash happy path: remote tree equals old tree" || bad "1. squash tree mismatch"
! grep -q '^fixup!' <<<"$subj_after" \
  && ok "1. squash happy path: no fixup! subject left" || bad "1. squash subjects: $subj_after"
[ "$wt_count" -eq 1 ] \
  && ok "1. squash happy path: git worktree list shows 1 entry" || bad "1. squash worktrees: $wt_lines"

# 2. --dry-run: exit 0, the "dry run" line, and neither remote nor local ref changed.
reset_fixture
rem_before=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_before=$(git -C "$CLONE" rev-parse HEAD)
out=$(run_fp --dry-run 2>&1); rc=$?
rem_after=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_after=$(git -C "$CLONE" rev-parse HEAD)
[ "$rc" -eq 0 ] && ok "2. --dry-run: exit 0" || bad "2. --dry-run exit $rc (out: $out)"
grep -qE "^fixup-push: dry run: would push feat ${rem_before:0:7}\.\.[0-9a-f]{7} \(squash\), lease ${rem_before:0:7}, 0 local-only commit\(s\) included$" <<<"$out" \
  && ok "2. --dry-run: dry run line" || bad "2. --dry-run line (out: $out)"
[ "$rem_after" = "$rem_before" ] && [ "$loc_after" = "$loc_before" ] \
  && ok "2. --dry-run: remote and local unchanged" \
  || bad "2. --dry-run changed refs (rem=$rem_after loc=$loc_after)"

# 3. FAKE_PROTECTED=true
reset_fixture
export FAKE_PROTECTED=true
assert_refusal "3. FAKE_PROTECTED=true" "branch is protected or protection is unknown" run_fp

# 4. FAKE_RULES=2
reset_fixture
export FAKE_RULES=2
assert_refusal "4. FAKE_RULES=2" "branch is protected or protection is unknown" run_fp

# 5. FAKE_GH_FAIL=api
reset_fixture
export FAKE_GH_FAIL=api
assert_refusal "5. FAKE_GH_FAIL=api" "branch is protected or protection is unknown" run_fp

# 6. On the default branch
reset_fixture
git -C "$CLONE" checkout -q main
assert_refusal "6. on default branch" "default branch" run_fp

# 7. FAKE_PR_STATE=CLOSED
reset_fixture
export FAKE_PR_STATE=CLOSED
assert_refusal "7. FAKE_PR_STATE=CLOSED" "no open PR for feat" run_fp

# 8. FAKE_CROSS=true
reset_fixture
export FAKE_CROSS=true
assert_refusal "8. FAKE_CROSS=true" "PR head is a fork" run_fp

# 9. FAKE_GH_FAIL=repo
reset_fixture
export FAKE_GH_FAIL=repo
assert_refusal "9. FAKE_GH_FAIL=repo" "gh repo view failed" run_fp

# 10. Remote has a commit the local branch lacks.
reset_fixture
printf 'remote-ahead\n' >> "$CLONE/f2.txt"
git -C "$CLONE" commit -qam "remote extra commit"
git -C "$CLONE" push -q origin feat
git -C "$CLONE" reset -q --hard HEAD~1
assert_refusal "10. remote ahead of local" "remote branch has commits not in local" run_fp

# 11. Dirty tracked file.
reset_fixture
printf 'dirty-line\n' >> "$CLONE/f1.txt"
assert_refusal "11. dirty tracked file" "uncommitted changes" run_fp

# 12. No fixups and no --onto-base.
reset_fixture
git -C "$CLONE" reset -q --hard HEAD~1
git -C "$CLONE" push -q --force origin feat
assert_refusal "12. no fixups and no --onto-base" "no fixup! commits to squash" run_fp

# 13. A squash! commit in the range.
reset_fixture
printf 'squash-line\n' >> "$CLONE/f1.txt"
git -C "$CLONE" commit -qam "squash! first feat commit"
assert_refusal "13. squash! commit in range" "squash!/amend! commits need a message edit" run_fp

# 14. --onto-base with main moved by an unrelated file, plus one fixup.
reset_fixture
git -C "$CLONE" checkout -q main
printf 'unrelated-main-change\n' > "$CLONE/unrelated.txt"
git -C "$CLONE" add unrelated.txt
git -C "$CLONE" commit -qm "main unrelated change"
git -C "$CLONE" push -q origin main
new_base=$(git -C "$CLONE" rev-parse HEAD)
git -C "$CLONE" checkout -q feat
rem_before=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_before=$(git -C "$CLONE" rev-parse HEAD)
out=$(run_fp --onto-base 2>&1); rc=$?
rem_after=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_after=$(git -C "$CLONE" rev-parse HEAD)
origin_main=$(git -C "$CLONE" rev-parse refs/remotes/origin/main)
mb_after=$(git -C "$CLONE" merge-base "$rem_after" "$origin_main")
rebased_pids=$(patch_ids_of "$origin_main..$rem_after")
wt_tree=$(git -C "$CLONE" write-tree)
new_tree=$(git -C "$CLONE" rev-parse "$loc_after^{tree}")
[ "$rc" -eq 0 ] && ok "14. --onto-base: exit 0" || bad "14. --onto-base exit $rc (out: $out)"
grep -qxF "fixup-push: pushed feat ${rem_before:0:7}..${loc_after:0:7} (squash+onto-base ${new_base:0:7}), lease ${rem_before:0:7}; local was ${loc_before:0:7}, 0 local-only commit(s) included" <<<"$out" \
  && ok "14. --onto-base: pushed line with squash+onto-base shape" \
  || bad "14. --onto-base pushed line (out: $out)"
[ "$rem_after" = "$loc_after" ] && [ "$rem_after" != "$rem_before" ] \
  && ok "14. --onto-base: remote moved to NEW" || bad "14. --onto-base remote ref"
[ "$mb_after" = "$origin_main" ] && [ "$origin_main" = "$new_base" ] \
  && ok "14. --onto-base: remote merge-base with origin/main equals origin/main" \
  || bad "14. --onto-base merge-base ($mb_after vs $origin_main)"
[ "$rebased_pids" = "$SQUASHED_PATCH_IDS" ] \
  && ok "14. --onto-base: patch-id list equals pre-rebase squashed list" \
  || bad "14. --onto-base patch-ids ($rebased_pids vs $SQUASHED_PATCH_IDS)"
[ "$wt_tree" = "$new_tree" ] && [ -f "$CLONE/unrelated.txt" ] \
  && git -C "$CLONE" diff --ignore-submodules=none --quiet && git -C "$CLONE" diff --ignore-submodules=none --cached --quiet \
  && ok "14. --onto-base: local working tree equals NEW" \
  || bad "14. --onto-base working tree mismatch"

# 15. --onto-base where main changed the same line as feat: refuse "conflicts",
# local unchanged, no leftover worktree, and no $T dir left.
reset_fixture
git -C "$CLONE" checkout -q main
printf 'main-conflicting-line\n' > "$CLONE/f1.txt"
git -C "$CLONE" commit -qam "main conflicting change"
git -C "$CLONE" push -q origin main
git -C "$CLONE" checkout -q feat
assert_refusal "15. --onto-base conflict" "rebase onto main conflicts" run_fp --onto-base
wt_lines=$(git -C "$CLONE" worktree list)
wt_count=$(grep -c . <<<"$wt_lines")
leftover_tmp=$(ls -A "$WT_TMP")
[ "$wt_count" -eq 1 ] && [ -z "$leftover_tmp" ] \
  && ok "15. --onto-base conflict: 1 worktree entry and no \$T dir left" \
  || bad "15. --onto-base cleanup (wt_count=$wt_count leftover=$leftover_tmp)"

# 16. A pre-push hook in the fixture clone that exits 1: exit 3, names old full SHA, remote unchanged.
reset_fixture
cat > "$CLONE/.git/hooks/pre-push" <<'HOOK'
#!/bin/bash
echo "pre-push hook: simulated rejection" >&2
exit 1
HOOK
chmod +x "$CLONE/.git/hooks/pre-push"
rem_before=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_before=$(git -C "$CLONE" rev-parse HEAD)
out=$(run_fp 2>&1); rc=$?
rem_after=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_after=$(git -C "$CLONE" rev-parse HEAD)
[ "$rc" -eq 3 ] && ok "16. pre-push hook failure: exit 3" || bad "16. pre-push exit $rc (out: $out)"
grep -qF "fixup-push: push failed; local feat moved ${loc_before:0:7}..${loc_after:0:7}; remote feat at ${rem_before:0:7}; old head $loc_before" <<<"$out" \
  && ok "16. pre-push hook failure: message names actual remote head and old full SHA" \
  || bad "16. pre-push message (out: $out)"
[ "$rem_after" = "$rem_before" ] && [ "$loc_after" != "$loc_before" ] \
  && ok "16. pre-push hook failure: remote unchanged, local moved" \
  || bad "16. pre-push refs (rem $rem_before -> $rem_after, loc $loc_before -> $loc_after)"

# 17. Detached HEAD: refuse.
reset_fixture
git -C "$CLONE" checkout -q --detach HEAD
assert_refusal "17. detached HEAD" "detached HEAD" run_fp

# 18. Unknown flag: exit 2.
reset_fixture
rem_before=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_before=$(git -C "$CLONE" rev-parse HEAD)
out=$(run_fp --unknown-flag 2>&1); rc=$?
rem_after=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_after=$(git -C "$CLONE" rev-parse HEAD)
[ "$rc" -eq 2 ] && ok "18. unknown flag: exit 2" || bad "18. unknown flag exit $rc (out: $out)"
grep -qF "Usage:" <<<"$out" && ok "18. unknown flag: usage printed" || bad "18. unknown flag usage (out: $out)"
[ "$rem_after" = "$rem_before" ] && [ "$loc_after" = "$loc_before" ] \
  && ok "18. unknown flag: remote and local unchanged" \
  || bad "18. unknown flag changed refs"

# --- Round 1 new cases a-m ---

# a. The PR head name differs (FAKE_PR_HEAD=other): refuse.
reset_fixture
export FAKE_PR_HEAD=other
assert_refusal "a. PR head name differs" "no open PR for feat" run_fp

# b. The PR head repo is another owner (FAKE_HEAD_REPO): refuse "PR head is a fork".
reset_fixture
export FAKE_HEAD_REPO="other/widget"
assert_refusal "b. PR head repo is another owner" "PR head is a fork" run_fp

# c. A merge commit in the range: refuse "merge commits in range".
reset_fixture
git -C "$CLONE" checkout -q -b feat-sub
printf 'sub-content\n' > "$CLONE/sub.txt"
git -C "$CLONE" add sub.txt
git -C "$CLONE" commit -qm "sub commit"
git -C "$CLONE" checkout -q feat
git -C "$CLONE" merge -q --no-ff -m "merge commit in range" feat-sub
assert_refusal "c. merge commit in range" "merge commits in range" run_fp

# d. An amend! commit: refuse. Also a fixup! amend! commit: refuse.
reset_fixture
printf 'amend-content\n' >> "$CLONE/f1.txt"
git -C "$CLONE" commit -qam "amend! first feat commit"
assert_refusal "d1. amend! commit" "squash!/amend! commits need a message edit" run_fp

reset_fixture
printf 'fixup-amend-content\n' >> "$CLONE/f1.txt"
git -C "$CLONE" commit -qam "fixup! amend! first feat commit"
assert_refusal "d2. fixup! amend! commit" "squash!/amend! commits need a message edit" run_fp

# e. --onto-base with no fixups and the base unmoved: refuse "nothing to rewrite".
reset_fixture
git -C "$CLONE" reset -q --hard HEAD~1
git -C "$CLONE" push -q --force origin feat
assert_refusal "e. --onto-base no fixups base unmoved" "nothing to rewrite" run_fp --onto-base

# f. --onto-base with no fixups and the base moved: exit 0, shape onto-base, patch-id preserved.
reset_fixture
git -C "$CLONE" reset -q --hard HEAD~1
git -C "$CLONE" push -q --force origin feat
git -C "$CLONE" checkout -q main
printf 'moved-base\n' > "$CLONE/moved.txt"
git -C "$CLONE" add moved.txt
git -C "$CLONE" commit -qm "move base"
git -C "$CLONE" push -q origin main
new_base=$(git -C "$CLONE" rev-parse HEAD)
git -C "$CLONE" checkout -q feat
rem_before=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_before=$(git -C "$CLONE" rev-parse HEAD)
pre_pids=$(patch_ids_of "origin/main..HEAD")
out=$(run_fp --onto-base 2>&1); rc=$?
rem_after=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_after=$(git -C "$CLONE" rev-parse HEAD)
origin_main=$(git -C "$CLONE" rev-parse refs/remotes/origin/main)
post_pids=$(patch_ids_of "$origin_main..$rem_after")
[ "$rc" -eq 0 ] && ok "f. --onto-base no fixups base moved: exit 0" || bad "f. exit $rc (out: $out)"
grep -qxF "fixup-push: pushed feat ${rem_before:0:7}..${loc_after:0:7} (onto-base ${new_base:0:7}), lease ${rem_before:0:7}; local was ${loc_before:0:7}, 0 local-only commit(s) included" <<<"$out" \
  && ok "f. --onto-base no fixups base moved: pushed line with onto-base shape" \
  || bad "f. pushed line (out: $out)"
[ "$post_pids" = "$pre_pids" ] && [ -n "$post_pids" ] \
  && ok "f. --onto-base no fixups base moved: patch-id list preserved" \
  || bad "f. patch-id mismatch ($post_pids vs $pre_pids)"

# g. Rebase-proof refusal: a feat commit whose exact change was also committed to main.
reset_fixture
git -C "$CLONE" checkout -q main
printf 'duplicate-patch\n' > "$CLONE/f3.txt"
git -C "$CLONE" add f3.txt
git -C "$CLONE" commit -qm "dup patch on main"
git -C "$CLONE" push -q origin main

git -C "$CLONE" checkout -q feat
printf 'duplicate-patch\n' > "$CLONE/f3.txt"
git -C "$CLONE" add f3.txt
git -C "$CLONE" commit -qm "dup patch on feat"
git -C "$CLONE" push -q origin feat
assert_refusal "g. rebase-proof refusal" "rebase proof failed" run_fp --onto-base

# g2. Rebase-proof refusal: same count, different patch.
reset_fixture
printf 'l1\nl2\nl3\nl4\nfeat5\nl6\nl7\n' > "$CLONE/ctx.txt"
git -C "$CLONE" commit -qam "feat ctx line 5"
git -C "$CLONE" push -q origin feat

git -C "$CLONE" checkout -q main
printf 'l1\nmain2\nl3\nl4\nl5\nl6\nl7\n' > "$CLONE/ctx.txt"
git -C "$CLONE" commit -qam "main ctx line 2"
git -C "$CLONE" push -q origin main
git -C "$CLONE" checkout -q feat

# Prove that rev-list counts before and after rebase match and rebase succeeds cleanly:
test_wt="$WORK/test_g2_wt"
git -C "$CLONE" worktree add -q --detach "$test_wt" feat
mb_g2=$(git -C "$CLONE" merge-base feat origin/main)
GIT_EDITOR=true GIT_SEQUENCE_EDITOR=true git -C "$test_wt" rebase -q --autosquash --keep-base "$mb_g2"
count_pre=$(git -C "$test_wt" rev-list --count "$mb_g2..HEAD")
rebase_ok=0
if GIT_EDITOR=true GIT_SEQUENCE_EDITOR=true git -C "$test_wt" rebase -q origin/main; then
  rebase_ok=1
fi
count_post=$(git -C "$test_wt" rev-list --count origin/main..HEAD)
git -C "$CLONE" worktree remove --force "$test_wt"
git -C "$CLONE" worktree prune

[ "$rebase_ok" -eq 1 ] && [ "$count_pre" -eq "$count_post" ] && [ "$count_pre" -gt 0 ] \
  && ok "g2 proof: rebase succeeds cleanly and commit counts match ($count_pre == $count_post)" \
  || bad "g2 proof: rebase failed (ok=$rebase_ok) or counts mismatch ($count_pre vs $count_post)"

assert_refusal "g2. same count, different patch" "rebase proof failed" run_fp --onto-base

# h. Lease race: reference-transaction hook pushes to origin feat from clone2 at step 13 before step 14 push.
reset_fixture
git -C "$CLONE2" fetch -q origin
git -C "$CLONE2" checkout -q -f -B feat origin/feat
touch "$WORK/race.sentinel"
cat > "$CLONE/.git/hooks/reference-transaction" <<HOOK
#!/bin/bash
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
state=\${1:-}
matched=0
if [ "\$state" = "committed" ] && [ -f "$WORK/race.sentinel" ]; then
  while read -r _ _ ref; do
    if [ "\$ref" = "refs/heads/feat" ]; then
      matched=1
    fi
  done
  if [ "\$matched" -eq 1 ]; then
    rm -f "$WORK/race.sentinel"
    printf 'race-commit\n' >> "$CLONE2/f1.txt"
    git -C "$CLONE2" commit -qam "race commit from clone2"
    git -C "$CLONE2" push -q origin feat
  fi
fi
exit 0
HOOK
chmod +x "$CLONE/.git/hooks/reference-transaction"
rem_before=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_before=$(git -C "$CLONE" rev-parse HEAD)
out=$(run_fp 2>&1); rc=$?
rem_after=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_after=$(git -C "$CLONE" rev-parse HEAD)
race_sha=$(git -C "$CLONE2" rev-parse HEAD)
rm -f "$CLONE/.git/hooks/reference-transaction" "$WORK/race.sentinel"
[ "$rc" -eq 3 ] && ok "h. lease race: exit 3" || bad "h. lease race exit $rc (out: $out)"
grep -qF "fixup-push: push failed; local feat moved ${loc_before:0:7}..${loc_after:0:7}; remote feat at ${race_sha:0:7}; old head $loc_before" <<<"$out" \
  && ok "h. lease race: message names actual remote head and old head" \
  || bad "h. lease race message (out: $out)"
[ "$rem_after" = "$race_sha" ] \
  && ok "h. lease race: remote was updated by race commit, local push was rejected" \
  || bad "h. lease race remote ref ($rem_after vs $race_sha)"

# i. A local-only fixup (committed, not pushed) squashed: exit 0, line says 1 local-only commit(s) included.
reset_fixture
git -C "$CLONE" reset -q --hard HEAD~1
git -C "$CLONE" push -q --force origin feat
rem_before=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
printf 'feat1-v2\n' > "$CLONE/f1.txt"
git -C "$CLONE" commit -qam "fixup! first feat commit"
loc_before=$(git -C "$CLONE" rev-parse HEAD)
out=$(run_fp 2>&1); rc=$?
rem_after=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_after=$(git -C "$CLONE" rev-parse HEAD)
[ "$rc" -eq 0 ] && ok "i. local-only fixup: exit 0" || bad "i. local-only fixup exit $rc (out: $out)"
grep -qxF "fixup-push: pushed feat ${rem_before:0:7}..${loc_after:0:7} (squash), lease ${rem_before:0:7}; local was ${loc_before:0:7}, 1 local-only commit(s) included" <<<"$out" \
  && ok "i. local-only fixup: output says 1 local-only commit(s) included" \
  || bad "i. local-only fixup message (out: $out)"

# j. A separate pushurl: refuse "origin push URL differs".
reset_fixture
git -C "$CLONE" remote set-url --push origin "ssh://git@github.com/acme/widget-push.git"
assert_refusal "j. separate pushurl" "origin push URL differs from its fetch URL" run_fp
git -C "$CLONE" remote set-url --push origin "$ORIGIN_URL"

# k. An unsupported branch name (feat#x): refuse "unsupported branch name".
reset_fixture
git -C "$CLONE" checkout -q -b "feat#x"
assert_refusal "k. unsupported branch name" "unsupported branch name" run_fp
git -C "$CLONE" checkout -q feat
git -C "$CLONE" branch -q -D "feat#x"

# l. A skip-worktree file with a local edit: refuse "hidden tracked changes".
reset_fixture
git -C "$CLONE" update-index --skip-worktree f1.txt
printf 'hidden-edit\n' >> "$CLONE/f1.txt"
assert_refusal "l. skip-worktree file" "hidden tracked changes (assume-unchanged/skip-worktree)" run_fp
git -C "$CLONE" update-index --no-skip-worktree f1.txt 2>/dev/null || true
git -C "$CLONE" checkout -q -- f1.txt

# m. --remote origin is now an unknown argument: exit 2.
reset_fixture
rem_before=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_before=$(git -C "$CLONE" rev-parse HEAD)
out=$(run_fp --remote origin 2>&1); rc=$?
rem_after=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_after=$(git -C "$CLONE" rev-parse HEAD)
[ "$rc" -eq 2 ] && ok "m. --remote is unknown: exit 2" || bad "m. --remote exit $rc (out: $out)"
grep -qF "Usage:" <<<"$out" && ok "m. --remote is unknown: usage printed" || bad "m. usage (out: $out)"
[ "$rem_after" = "$rem_before" ] && [ "$loc_after" = "$loc_before" ] \
  && ok "m. --remote is unknown: remote and local unchanged" \
  || bad "m. refs changed"

# --- Round 3 new cases n-z ---

# n. Two remote.origin.url values: refuse "origin must have exactly one URL".
reset_fixture
git -C "$CLONE" config --add remote.origin.url "ssh://git@github.com/acme/extra.git"
assert_refusal "n. two origin URLs" "origin must have exactly one URL" run_fp

# The https URL arm has no hermetic case, because the seam is ssh-only.

# o. A local-path origin: refuse "origin URL is not a supported host URL".
reset_fixture
git -C "$CLONE" remote set-url origin "$ORIGIN_PATH"
assert_refusal "o. local-path origin" "origin URL is not a supported host URL" run_fp

# p. gh reports a different nwo (FAKE_NWO=other/widget): refuse "gh repo does not match origin".
reset_fixture
export FAKE_NWO="other/widget"
assert_refusal "p. gh repo does not match origin" "gh repo does not match origin" run_fp

# q. Only the rules call fails (FAKE_GH_FAIL=rules): refuse "protected or protection is unknown".
reset_fixture
export FAKE_GH_FAIL=rules
assert_refusal "q. rules api fails" "branch is protected or protection is unknown" run_fp

# r. FAKE_PROTECTED=null: refuse "protected or protection is unknown".
reset_fixture
export FAKE_PROTECTED=null
assert_refusal "r. FAKE_PROTECTED=null" "branch is protected or protection is unknown" run_fp

# s. Decoy GIT_DIR passed to bin env only: behaves like case 1 and pushes clone branch.
reset_fixture
DECOY_REPO="$WORK/decoy.git"
git init -q --bare "$DECOY_REPO"
rem_before=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_before=$(git -C "$CLONE" rev-parse HEAD)
old_tree=$(git -C "$CLONE" rev-parse "HEAD^{tree}")
out=$(cd "$CLONE" && env PATH="$FAKE_BIN:$PATH" TMPDIR="$WT_TMP" GIT_DIR="$DECOY_REPO" bash "$BIN" 2>&1); rc=$?
rem_after=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_after=$(git -C "$CLONE" rev-parse HEAD)
rem_tree=$(git -C "$ORIGIN" rev-parse "refs/heads/feat^{tree}")
[ "$rc" -eq 0 ] && ok "s. decoy GIT_DIR: exit 0" || bad "s. decoy GIT_DIR exit $rc (out: $out)"
grep -qxF "fixup-push: pushed feat ${rem_before:0:7}..${loc_after:0:7} (squash), lease ${rem_before:0:7}; local was ${loc_before:0:7}, 0 local-only commit(s) included" <<<"$out" \
  && ok "s. decoy GIT_DIR: pushed line" || bad "s. decoy GIT_DIR line (out: $out)"
[ "$rem_after" = "$loc_after" ] && [ "$rem_after" != "$rem_before" ] \
  && ok "s. decoy GIT_DIR: remote equals local and moved" \
  || bad "s. decoy GIT_DIR refs"
[ "$rem_tree" = "$old_tree" ] \
  && ok "s. decoy GIT_DIR: remote tree equals old tree" || bad "s. decoy GIT_DIR tree mismatch"

# t. rebase.updateRefs=true in clone config with feat-stack branch: squash succeeds, feat-stack unchanged.
reset_fixture
git -C "$CLONE" config rebase.updateRefs true
first_sha=$(git -C "$CLONE" rev-parse HEAD~2)
git -C "$CLONE" branch feat-stack "$first_sha"
stack_before=$(git -C "$CLONE" rev-parse feat-stack)
rem_before=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_before=$(git -C "$CLONE" rev-parse HEAD)
out=$(run_fp 2>&1); rc=$?
rem_after=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_after=$(git -C "$CLONE" rev-parse HEAD)
stack_after=$(git -C "$CLONE" rev-parse feat-stack)
[ "$rc" -eq 0 ] && ok "t. updateRefs config: exit 0" || bad "t. updateRefs exit $rc (out: $out)"
[ "$stack_after" = "$stack_before" ] \
  && ok "t. updateRefs config: feat-stack branch unchanged ($stack_after)" \
  || bad "t. updateRefs config: feat-stack changed ($stack_before -> $stack_after)"
[ "$rem_after" = "$loc_after" ] && [ "$rem_after" != "$rem_before" ] \
  && ok "t. updateRefs config: remote equals local and moved" \
  || bad "t. updateRefs config refs"
git -C "$CLONE" branch -q -D feat-stack
git -C "$CLONE" config --unset rebase.updateRefs

# u. Run from a subdirectory with skip-worktree file at root: refuse "hidden tracked changes".
reset_fixture
mkdir -p "$CLONE/sub"
git -C "$CLONE" update-index --skip-worktree f1.txt
printf 'hidden-edit\n' >> "$CLONE/f1.txt"
rem_before=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_before=$(git -C "$CLONE" rev-parse HEAD)
out=$(cd "$CLONE/sub" && env PATH="$FAKE_BIN:$PATH" TMPDIR="$WT_TMP" bash "$BIN" 2>&1); rc=$?
rem_after=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_after=$(git -C "$CLONE" rev-parse HEAD)
git -C "$CLONE" update-index --no-skip-worktree f1.txt 2>/dev/null || true
git -C "$CLONE" checkout -q -- f1.txt
[ "$rc" -eq 1 ] && ok "u. subdir run: exit 1" || bad "u. subdir run exit $rc (out: $out)"
grep -qF "fixup-push: refused: hidden tracked changes (assume-unchanged/skip-worktree)" <<<"$out" \
  && ok "u. subdir run: refusal message" || bad "u. subdir run message (out: $out)"
[ "$rem_after" = "$rem_before" ] && [ "$loc_after" = "$loc_before" ] \
  && ok "u. subdir run: remote and local unchanged" || bad "u. subdir run refs changed"

# v. An assume-unchanged file: refuse "hidden tracked changes".
reset_fixture
git -C "$CLONE" update-index --assume-unchanged f1.txt
printf 'assume-edit\n' >> "$CLONE/f1.txt"
assert_refusal "v. assume-unchanged file" "hidden tracked changes (assume-unchanged/skip-worktree)" run_fp
git -C "$CLONE" update-index --no-assume-unchanged f1.txt 2>/dev/null || true
git -C "$CLONE" checkout -q -- f1.txt

# w. No origin remote: refuse "origin must have exactly one URL".
reset_fixture
git -C "$CLONE" remote rename origin upstream
assert_refusal "w. no origin remote" "origin must have exactly one URL" run_fp
git -C "$CLONE" remote rename upstream origin

# x. --dry-run --onto-base with base moved: exit 0, squash+onto-base shape, refs unchanged.
reset_fixture
git -C "$CLONE" checkout -q main
printf 'unrelated-main\n' > "$CLONE/unrelated.txt"
git -C "$CLONE" add unrelated.txt
git -C "$CLONE" commit -qm "main advance"
git -C "$CLONE" push -q origin main
new_base=$(git -C "$CLONE" rev-parse HEAD)
git -C "$CLONE" checkout -q feat
rem_before=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_before=$(git -C "$CLONE" rev-parse HEAD)
out=$(run_fp --dry-run --onto-base 2>&1); rc=$?
rem_after=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_after=$(git -C "$CLONE" rev-parse HEAD)
[ "$rc" -eq 0 ] && ok "x. --dry-run --onto-base: exit 0" || bad "x. exit $rc (out: $out)"
grep -qE "^fixup-push: dry run: would push feat ${rem_before:0:7}\.\.[0-9a-f]{7} \(squash\+onto-base ${new_base:0:7}\), lease ${rem_before:0:7}, 0 local-only commit\(s\) included$" <<<"$out" \
  && ok "x. --dry-run --onto-base: dry run line with squash+onto-base" \
  || bad "x. dry run line (out: $out)"
[ "$rem_after" = "$rem_before" ] && [ "$loc_after" = "$loc_before" ] \
  && ok "x. --dry-run --onto-base: remote and local unchanged" \
  || bad "x. changed refs (rem=$rem_after loc=$loc_after)"

# y. PR state flips between gate reads: refuse "no open PR".
reset_fixture
export FAKE_PR_COUNTER_FILE="$WORK/pr_counter"
export FAKE_PR_CLOSE_ON=2
rm -f "$FAKE_PR_COUNTER_FILE"
assert_refusal "y. PR state flips to closed" "no open PR for feat" run_fp
unset FAKE_PR_COUNTER_FILE FAKE_PR_CLOSE_ON

# z. diff.context=0 in clone config: case g2 setup still refuses "rebase proof failed".
reset_fixture
git -C "$CLONE" config diff.context 0
printf 'l1\nl2\nl3\nl4\nfeat5\nl6\nl7\n' > "$CLONE/ctx.txt"
git -C "$CLONE" commit -qam "feat ctx line 5"
git -C "$CLONE" push -q origin feat

git -C "$CLONE" checkout -q main
printf 'l1\nmain2\nl3\nl4\nl5\nl6\nl7\n' > "$CLONE/ctx.txt"
git -C "$CLONE" commit -qam "main ctx line 2"
git -C "$CLONE" push -q origin main
git -C "$CLONE" checkout -q feat

assert_refusal "z. diff.context=0" "rebase proof failed" run_fp --onto-base
git -C "$CLONE" config --unset diff.context

# --- Round 4 new cases aa-ah ---

# aa. push.followTags=true in clone config, annotated tag on local-only fixup: tag not pushed.
reset_fixture
git -C "$CLONE" reset -q --hard HEAD~1
git -C "$CLONE" push -q --force origin feat
printf 'feat1-v2\n' > "$CLONE/f1.txt"
git -C "$CLONE" commit -qam "fixup! first feat commit"
# Tag a commit that stays reachable from the rewritten head (the merge-base); a tag on the squashed-away fixup would never be followed.
git -C "$CLONE" tag -a v-local -m "local tag" "$(git -C "$CLONE" merge-base HEAD refs/remotes/origin/main)"
git -C "$CLONE" config push.followTags true

rem_before=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_before=$(git -C "$CLONE" rev-parse HEAD)
out=$(run_fp 2>&1); rc=$?
rem_after=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_after=$(git -C "$CLONE" rev-parse HEAD)
origin_tag=$(git -C "$ORIGIN" tag -l v-local)

git -C "$CLONE" config --unset push.followTags
git -C "$CLONE" tag -d v-local >/dev/null 2>&1 || true

[ "$rc" -eq 0 ] && ok "aa. followTags=true: exit 0" || bad "aa. followTags exit $rc (out: $out)"
[ -z "$origin_tag" ] \
  && ok "aa. followTags=true: tag v-local was not pushed to origin" \
  || bad "aa. followTags=true: tag v-local was pushed to origin: $origin_tag"
[ "$rem_after" = "$loc_after" ] && [ "$rem_after" != "$rem_before" ] \
  && ok "aa. followTags=true: feat pushed" || bad "aa. followTags refs"

# ab. ssh URL with port: refuse "origin URL is not a supported host URL".
reset_fixture
git -C "$CLONE" remote set-url origin "ssh://git@github.com:2222/acme/widget.git"
assert_refusal "ab. ssh port refused" "origin URL is not a supported host URL" run_fp

# ac. FAKE_CHILD_PRS=1 and FAKE_GH_FAIL=prlist: refuse "another open PR is based on feat".
reset_fixture
export FAKE_CHILD_PRS=1
assert_refusal "ac1. child PR exists" "another open PR is based on feat" run_fp
unset FAKE_CHILD_PRS

reset_fixture
export FAKE_GH_FAIL=prlist
assert_refusal "ac2. prlist fails" "another open PR is based on feat" run_fp
unset FAKE_GH_FAIL

# ad. PR base differs from default: base=rel on origin, onto-base rebase onto rel.
reset_fixture
git -C "$CLONE" checkout -q -b rel origin/main
printf 'rel-commit\n' > "$CLONE/rel.txt"
git -C "$CLONE" add rel.txt
git -C "$CLONE" commit -qm "rel extra commit"
git -C "$CLONE" push -q -u origin rel
rel_sha=$(git -C "$CLONE" rev-parse HEAD)
rel7=${rel_sha:0:7}
git -C "$CLONE" checkout -q feat
rem_before=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_before=$(git -C "$CLONE" rev-parse HEAD)
export FAKE_PR_BASE=rel
export FAKE_DEFAULT=main
out=$(run_fp --onto-base 2>&1); rc=$?
rem_after=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_after=$(git -C "$CLONE" rev-parse HEAD)
origin_rel=$(git -C "$CLONE" rev-parse refs/remotes/origin/rel)
mb_rel=$(git -C "$CLONE" merge-base "$rem_after" "$origin_rel")
unset FAKE_PR_BASE FAKE_DEFAULT
git -C "$CLONE" push -q origin --delete rel >/dev/null 2>&1 || true
git -C "$CLONE" branch -q -D rel >/dev/null 2>&1 || true
[ "$rc" -eq 0 ] && ok "ad. PR base differs from default: exit 0" || bad "ad. exit $rc (out: $out)"
grep -qxF "fixup-push: pushed feat ${rem_before:0:7}..${loc_after:0:7} (squash+onto-base ${rel7}), lease ${rem_before:0:7}; local was ${loc_before:0:7}, 0 local-only commit(s) included" <<<"$out" \
  && ok "ad. PR base differs from default: pushed line with squash+onto-base ${rel7}" \
  || bad "ad. pushed line (out: $out)"
[ "$mb_rel" = "$origin_rel" ] && [ "$origin_rel" = "$rel_sha" ] \
  && ok "ad. PR base differs from default: merge-base with origin/rel equals origin/rel" \
  || bad "ad. merge-base ($mb_rel vs $origin_rel)"

# ae. FAKE_PR_BASE_ON2=other: refuse "PR base changed during the run".
reset_fixture
export FAKE_PR_BASE_ON2="other"
assert_refusal "ae. PR base changed" "PR base changed during the run" run_fp
unset FAKE_PR_BASE_ON2

# af. FAKE_PROTECTED_ON2=true: refuse "branch is protected or protection is unknown".
reset_fixture
export FAKE_PROTECTED_ON2="true"
assert_refusal "af. branch protected on 2nd read" "branch is protected or protection is unknown" run_fp
unset FAKE_PROTECTED_ON2

# ag. scp-like origin and slashed branch name user/feat: squash exits 0.
reset_fixture
git -C "$CLONE" remote set-url origin "git@github.com:acme/widget.git"
git -C "$CLONE" remote set-url --push origin "git@github.com:acme/widget.git"
git -C "$CLONE" checkout -q -b "user/feat" feat
git -C "$CLONE" push -q -u origin "user/feat"
rem_before=$(git -C "$ORIGIN" rev-parse refs/heads/user/feat)
loc_before=$(git -C "$CLONE" rev-parse HEAD)
export FAKE_EXPECT_BRANCH="user/feat"
export FAKE_PR_HEAD="user/feat"
out=$(run_fp 2>&1); rc=$?
rem_after=$(git -C "$ORIGIN" rev-parse refs/heads/user/feat)
loc_after=$(git -C "$CLONE" rev-parse HEAD)
unset FAKE_EXPECT_BRANCH FAKE_PR_HEAD
git -C "$CLONE" checkout -q feat
git -C "$CLONE" push -q origin --delete "user/feat" >/dev/null 2>&1 || true
git -C "$CLONE" branch -q -D "user/feat" >/dev/null 2>&1 || true
[ "$rc" -eq 0 ] && ok "ag. scp-like with slashed branch: exit 0" || bad "ag. exit $rc (out: $out)"
grep -qxF "fixup-push: pushed user/feat ${rem_before:0:7}..${loc_after:0:7} (squash), lease ${rem_before:0:7}; local was ${loc_before:0:7}, 0 local-only commit(s) included" <<<"$out" \
  && ok "ag. scp-like with slashed branch: pushed line" || bad "ag. line (out: $out)"
[ "$rem_after" = "$loc_after" ] && [ "$rem_after" != "$rem_before" ] \
  && ok "ag. scp-like with slashed branch: remote equals local and moved" || bad "ag. refs changed"

# ah. Remote-config redirect: squash exits 0, origin feat updated, no elsewhere branch.
reset_fixture
git -C "$CLONE" config remote.origin.push refs/heads/feat:refs/heads/elsewhere
rem_before=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_before=$(git -C "$CLONE" rev-parse HEAD)
out=$(run_fp 2>&1); rc=$?
rem_after=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_after=$(git -C "$CLONE" rev-parse HEAD)
has_elsewhere=$(git -C "$ORIGIN" rev-parse --verify -q refs/heads/elsewhere 2>/dev/null || true)
git -C "$CLONE" config --unset remote.origin.push
[ "$rc" -eq 0 ] && ok "ah. remote-config redirect: exit 0" || bad "ah. exit $rc (out: $out)"
[ "$rem_after" = "$loc_after" ] && [ "$rem_after" != "$rem_before" ] \
  && ok "ah. remote-config redirect: remote feat updated" || bad "ah. remote feat not updated"
[ -z "$has_elsewhere" ] \
  && ok "ah. remote-config redirect: origin has no elsewhere branch" || bad "ah. elsewhere branch created"

# --- Round 5 new cases ai-ao ---

# ai. The squash subject proof: orphan fixup subject kept by autosquash, refuses "squash proof failed".
reset_fixture
printf 'orphan-fixup\n' > "$CLONE/orphan.txt"
git -C "$CLONE" add orphan.txt
git -C "$CLONE" commit -qm "fixup! no such target"
premise_wt="$WORK/ai_premise_wt"
git -C "$CLONE" worktree add -q --detach "$premise_wt" HEAD
GIT_EDITOR=true GIT_SEQUENCE_EDITOR=true git -C "$premise_wt" rebase -q -i --autosquash --keep-base origin/main
premise_subj=$(git -C "$premise_wt" log -1 --format=%s HEAD)
git -C "$CLONE" worktree remove --force "$premise_wt" >/dev/null 2>&1 || true
[ "$premise_subj" = "fixup! no such target" ] \
  && ok "ai. premise: autosquash kept orphan fixup subject" \
  || bad "ai. premise failed: $premise_subj"
assert_refusal "ai. squash subject proof" "squash proof failed" run_fp

# aj. The squash tree proof, through a git shim: extra commit during rebase refuses "squash proof failed".
reset_fixture
REAL_GIT=$(command -v git)
GIT_WRAPPER_DIR="$WORK/git_wrapper_bin"
mkdir -p "$GIT_WRAPPER_DIR"
cat > "$GIT_WRAPPER_DIR/git" <<EOF
#!/bin/bash
set -uo pipefail
has_rebase=false
has_autosquash=false
c_dir=""
args=()
while [ \$# -gt 0 ]; do
  case "\$1" in
    -C)
      c_dir="\$2"
      args+=("\$1" "\$2")
      shift
      ;;
    -C*)
      c_dir="\${1#-C}"
      args+=("\$1")
      ;;
    rebase)
      has_rebase=true
      args+=("\$1")
      ;;
    --autosquash)
      has_autosquash=true
      args+=("\$1")
      ;;
    *)
      args+=("\$1")
      ;;
  esac
  shift
done

"$REAL_GIT" "\${args[@]}"
rc=\$?
if [ \$rc -eq 0 ] && \$has_rebase && \$has_autosquash; then
  target_dir="\${c_dir:-\$PWD}"
  printf 'mutated-tree\n' > "\$target_dir/mutated.txt"
  "$REAL_GIT" -C "\$target_dir" add mutated.txt
  "$REAL_GIT" -c user.name=t -c user.email=t@example.invalid -C "\$target_dir" commit -qm "extra tree mutation"
fi
exit \$rc
EOF
chmod +x "$GIT_WRAPPER_DIR/git"

run_fp_aj() {
  (cd "$CLONE" && env PATH="$GIT_WRAPPER_DIR:$FAKE_BIN:$PATH" TMPDIR="$WT_TMP" bash "$BIN" "$@")
}
assert_refusal "aj. squash tree proof" "squash proof failed" run_fp_aj
rm -rf "$GIT_WRAPPER_DIR"

# ak. Remote URL changed after the check: push uses verified URL, decoy.git untouched.
reset_fixture
git init -q --bare "$WORK/decoy.git" 2>/dev/null || true
touch "$WORK/race.sentinel"
cat > "$CLONE/.git/hooks/reference-transaction" <<HOOK
#!/bin/bash
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
state=\${1:-}
matched=0
if [ "\$state" = "committed" ] && [ -f "$WORK/race.sentinel" ]; then
  while read -r _ _ ref; do
    if [ "\$ref" = "refs/heads/feat" ]; then
      matched=1
    fi
  done
  if [ "\$matched" -eq 1 ]; then
    rm -f "$WORK/race.sentinel"
    git -C "$CLONE" config remote.origin.url "ssh://git@github.com/acme/decoy.git"
  fi
fi
exit 0
HOOK
chmod +x "$CLONE/.git/hooks/reference-transaction"
rem_before=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_before=$(git -C "$CLONE" rev-parse HEAD)
out=$(run_fp 2>&1); rc=$?
rem_after=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_after=$(git -C "$CLONE" rev-parse HEAD)
rm -f "$CLONE/.git/hooks/reference-transaction" "$WORK/race.sentinel"
git -C "$CLONE" config remote.origin.url "$ORIGIN_URL"
has_decoy_feat=$(git -C "$WORK/decoy.git" rev-parse --verify -q refs/heads/feat 2>/dev/null || true)
[ "$rc" -eq 0 ] && ok "ak. remote URL changed: exit 0" || bad "ak. exit $rc (out: $out)"
[ "$rem_after" = "$loc_after" ] && [ "$rem_after" != "$rem_before" ] \
  && ok "ak. remote URL changed: origin feat moved to local head" \
  || bad "ak. origin feat not moved"
[ -z "$has_decoy_feat" ] \
  && ok "ak. remote URL changed: decoy.git has no feat" \
  || bad "ak. decoy.git has feat: $has_decoy_feat"

# al. An insteadOf chain: refuse "origin URL is rewritten again by url.insteadOf".
reset_fixture
git init -q --bare "$WORK/decoy.git" 2>/dev/null || true
git -C "$CLONE" remote set-url origin "ssh://git@gh-alias.example/acme/widget.git"
git -C "$CLONE" remote set-url --push origin "ssh://git@gh-alias.example/acme/widget.git"
git -C "$CLONE" config url.ssh://git@github.com/.insteadOf "ssh://git@gh-alias.example/"
git -C "$CLONE" config url.ssh://git@github.com/acme/decoy.git.insteadOf "ssh://git@github.com/acme/widget.git"
assert_refusal "al. insteadOf chain" "origin URL is rewritten again by url.insteadOf" run_fp
git -C "$CLONE" config --unset url.ssh://git@github.com/.insteadOf
git -C "$CLONE" config --unset url.ssh://git@github.com/acme/decoy.git.insteadOf
git -C "$CLONE" remote set-url origin "$ORIGIN_URL"
git -C "$CLONE" remote set-url --push origin "$ORIGIN_URL"
has_decoy_feat=$(git -C "$WORK/decoy.git" rev-parse --verify -q refs/heads/feat 2>/dev/null || true)
[ -z "$has_decoy_feat" ] \
  && ok "al. decoy.git untouched" \
  || bad "al. decoy.git has feat: $has_decoy_feat"

# am. Staged-only change: refuse "uncommitted changes".
reset_fixture
printf 'staged-only-edit\n' >> "$CLONE/f1.txt"
git -C "$CLONE" add f1.txt
assert_refusal "am. staged-only change" "uncommitted changes" run_fp
git -C "$CLONE" checkout -q -- f1.txt

# an. GIT_DIFF_OPTS=-u0 in the bin's env, on case g2's setup: refuse "rebase proof failed".
reset_fixture
printf 'l1\nl2\nl3\nl4\nfeat5\nl6\nl7\n' > "$CLONE/ctx.txt"
git -C "$CLONE" commit -qam "feat ctx line 5"
git -C "$CLONE" push -q origin feat

git -C "$CLONE" checkout -q main
printf 'l1\nmain2\nl3\nl4\nl5\nl6\nl7\n' > "$CLONE/ctx.txt"
git -C "$CLONE" commit -qam "main ctx line 2"
git -C "$CLONE" push -q origin main
git -C "$CLONE" checkout -q feat

run_fp_diff_opts() {
  (cd "$CLONE" && env PATH="$FAKE_BIN:$PATH" TMPDIR="$WT_TMP" GIT_DIFF_OPTS="-u0" bash "$BIN" "$@")
}
assert_refusal "an. GIT_DIFF_OPTS=-u0" "rebase proof failed" run_fp_diff_opts --onto-base

# ao. A tag named feat beside the branch feat: squash succeeds and origin feat moved.
reset_fixture
git -C "$CLONE" tag feat HEAD
rem_before=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_before=$(git -C "$CLONE" rev-parse HEAD)
out=$(run_fp 2>&1); rc=$?
rem_after=$(git -C "$ORIGIN" rev-parse refs/heads/feat)
loc_after=$(git -C "$CLONE" rev-parse HEAD)
git -C "$CLONE" tag -d feat >/dev/null 2>&1 || true
[ "$rc" -eq 0 ] && ok "ao. tag named feat: exit 0" || bad "ao. exit $rc (out: $out)"
[ "$rem_after" = "$loc_after" ] && [ "$rem_after" != "$rem_before" ] \
  && ok "ao. tag named feat: origin feat moved to local head" \
  || bad "ao. origin feat not moved"

exit $fail
