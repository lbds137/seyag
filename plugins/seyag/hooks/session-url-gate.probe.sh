#!/bin/bash
# Fixture check for session-url-gate.sh — run after ANY edit to the hook.
# Builds throwaway git repos under a mktemp dir (removed on exit) and asserts:
# a Claude session link in a git commit/tag/notes/gh command, in a body file
# those read, or in the message of a commit about to be pushed, blocks
# (exit 2, id masked in the message); prose naming the bare prefix, commands
# that do not publish, commits already on a remote and an own-prefix bypass
# pass (exit 0).
#
# The fixture id is a fake placeholder; the full link is assembled at run time.
#
# Usage: hooks/session-url-gate.probe.sh   (from anywhere)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$SCRIPT_DIR/session-url-gate.sh"

TMP=$(mktemp -d) || { echo "FAIL [setup]: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export GIT_CEILING_DIRECTORIES="$TMP"
export GIT_AUTHOR_NAME=probe GIT_AUTHOR_EMAIL=probe@example.invalid
export GIT_COMMITTER_NAME=probe GIT_COMMITTER_EMAIL=probe@example.invalid

ID="FIXTUREID0001abcd"
LINK="https://claude.ai/code/session_${ID}"
PREFIX="claude.ai/code/session_"

# --- fixtures ---------------------------------------------------------------
REMOTE="$TMP/remote.git"
git init -q --bare "$REMOTE"
WORK="$TMP/work"
git init -q "$WORK"
git -C "$WORK" remote add origin "$REMOTE"
git -C "$WORK" commit -q --allow-empty -m "base commit"
git -C "$WORK" branch -M main
git -C "$WORK" push -q origin main 2>/dev/null
# A commit carrying a link that IS already on the remote.
git -C "$WORK" commit -q --allow-empty -m "published ${LINK}"
git -C "$WORK" push -q origin main 2>/dev/null
# An unpushed commit with the link on another branch, and a clean one.
git -C "$WORK" checkout -q -b leaky
git -C "$WORK" commit -q --allow-empty -m "subject line" -m "see ${LINK}"
LEAKY_SHA=$(git -C "$WORK" rev-parse --short HEAD)
git -C "$WORK" checkout -q -b clean main
git -C "$WORK" commit -q --allow-empty -m "clean unpushed"
git -C "$WORK" checkout -q leaky

mkdir -p "$TMP/files" "$TMP/plain"
printf 'body with %s\n' "$LINK" >"$TMP/files/leaky.txt"
printf 'body without a link\n' >"$TMP/files/clean.txt"
printf 'prose naming %s `only`\n' "$PREFIX" >"$TMP/files/prefix.txt"

FAILURES=0

# run <expected-exit> <label> <cwd> <extra-env-assigns...> -- <cmd>
run() {
  local expected="$1" label="$2" cwd="$3"
  shift 3
  local envs=()
  while [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  shift
  local cmd="$1"
  printf '%s' "$cmd" \
    | jq -Rsc --arg c "$cwd" '{tool_name:"Bash",tool_input:{command:.},cwd:$c}' \
    | env "${envs[@]}" timeout 30 "$HOOK" >"$TMP/out" 2>&1
  local actual=$?
  if [ "$actual" -eq "$expected" ]; then
    printf 'PASS  (exit %d)  %s\n' "$actual" "$label"
  else
    printf 'FAIL  (exit %d, expected %d)  %s\n' "$actual" "$expected" "$label"
    sed 's/^/      /' "$TMP/out"
    FAILURES=$((FAILURES + 1))
  fi
}

# assert_out <label> <present|absent> <fixed string>: the LAST run's output.
assert_out() {
  local label="$1" mode="$2" s="$3" ok=1
  case "$mode" in
    present) grep -qF -- "$s" "$TMP/out" || ok=0 ;;
    absent) ! grep -qF -- "$s" "$TMP/out" || ok=0 ;;
  esac
  if [ "$ok" = 1 ]; then
    printf 'PASS  (output)  %s\n' "$label"
  else
    printf 'FAIL  (output)  %s\n' "$label"
    sed 's/^/      /' "$TMP/out"
    FAILURES=$((FAILURES + 1))
  fi
}

NOENV=(SYG_PROBE_NOOP=1)

# =============================================================================
# Group 1: command text (rule 1), each block paired with a near-miss
# =============================================================================
run 2 "git commit -m with a link" "$WORK" "${NOENV[@]}" -- \
  "git commit -m \"fix thing ${LINK}\""
assert_out "message names the command text" present "the command text"
assert_out "message masks the id" present "claude.ai/code/session_…"
assert_out "full id never echoed (positive control: the id IS in the command)" absent "$ID"
run 0 "near-miss: git commit -m with no link" "$WORK" "${NOENV[@]}" -- \
  "git commit -m \"fix thing\""
run 0 "near-miss: bare prefix in prose (space follows)" "$WORK" "${NOENV[@]}" -- \
  "git commit -m \"never paste ${PREFIX} links\""
run 0 "near-miss: bare prefix in backticks" "$WORK" "${NOENV[@]}" -- \
  "git commit -m \"the \`${PREFIX}\` form\""

run 2 "git commit heredoc body" "$WORK" "${NOENV[@]}" -- \
  "git commit -F - <<'EOF'
subject

see ${LINK}
EOF"
run 0 "near-miss: heredoc body without a link" "$WORK" "${NOENV[@]}" -- \
  "git commit -F - <<'EOF'
subject

body
EOF"
run 2 "git commit via \$(cat <<EOF) body" "$WORK" "${NOENV[@]}" -- \
  "git commit -m \"\$(cat <<'EOF'
subject ${LINK}
EOF
)\""

run 2 "git tag -m with a link" "$WORK" "${NOENV[@]}" -- \
  "git tag -a v1 -m \"rel ${LINK}\""
run 2 "git notes add -m with a link" "$WORK" "${NOENV[@]}" -- \
  "git notes add -m \"n ${LINK}\""
run 2 "git global options before the subcommand" "$WORK" "${NOENV[@]}" -- \
  "git --no-pager -c user.name=x commit -m \"x ${LINK}\""
run 2 "git -C dir commit -m" "$TMP/plain" "${NOENV[@]}" -- \
  "git -C $WORK commit -m \"x ${LINK}\""
run 0 "near-miss: git -C dir commit -m clean" "$TMP/plain" "${NOENV[@]}" -- \
  "git -C $WORK commit -m \"x\""

run 2 "gh pr create --body" "$WORK" "${NOENV[@]}" -- \
  "gh pr create --title t --body \"see ${LINK}\""
run 2 "gh pr create --title" "$WORK" "${NOENV[@]}" -- \
  "gh pr create --title \"${LINK}\" --body b"
run 0 "near-miss: gh pr create --body clean" "$WORK" "${NOENV[@]}" -- \
  "gh pr create --title t --body \"see the notes\""
run 2 "gh api -f body=" "$WORK" "${NOENV[@]}" -- \
  "gh api repos/example/one/issues -f title=t -f body=\"${LINK}\""
run 2 "gh issue comment inside bash -c" "$WORK" "${NOENV[@]}" -- \
  "bash -c 'gh issue comment 1 --body \"${LINK}\"'"

run 0 "unrelated command with a link: echo" "$WORK" "${NOENV[@]}" -- \
  "echo ${LINK}"
run 0 "unrelated command with a link: cat" "$WORK" "${NOENV[@]}" -- \
  "cat <<'EOF'
${LINK}
EOF"
run 0 "unrelated git subcommand with a link: git log --grep" "$WORK" "${NOENV[@]}" -- \
  "git log --grep=${LINK}"

# =============================================================================
# Group 2: bypass
# =============================================================================
run 0 "bypass: assignment in the command's own prefix" "$WORK" "${NOENV[@]}" -- \
  "SYG_ALLOW_SESSION_URL=1 git commit -m \"x ${LINK}\""
run 0 "bypass: env prefix on gh" "$WORK" "${NOENV[@]}" -- \
  "env SYG_ALLOW_SESSION_URL=1 gh pr create --body \"${LINK}\""
run 2 "bypass mentioned elsewhere does not count" "$WORK" "${NOENV[@]}" -- \
  "echo SYG_ALLOW_SESSION_URL=1; git commit -m \"x ${LINK}\""
run 2 "bypass inside the message does not count" "$WORK" "${NOENV[@]}" -- \
  "git commit -m \"SYG_ALLOW_SESSION_URL=1 ${LINK}\""
run 2 "bypass in the session environment does not count" "$WORK" SYG_ALLOW_SESSION_URL=1 -- \
  "git commit -m \"x ${LINK}\""

# =============================================================================
# Group 3: body from a file (rule 2)
# =============================================================================
run 2 "git commit -F file with a link" "$WORK" "${NOENV[@]}" -- \
  "git commit -F $TMP/files/leaky.txt"
assert_out "message names the file" present "file $TMP/files/leaky.txt"
run 0 "near-miss: git commit -F clean file" "$WORK" "${NOENV[@]}" -- \
  "git commit -F $TMP/files/clean.txt"
run 0 "near-miss: git commit -F file with the bare prefix" "$WORK" "${NOENV[@]}" -- \
  "git commit -F $TMP/files/prefix.txt"
run 2 "git commit --file file" "$WORK" "${NOENV[@]}" -- \
  "git commit --file $TMP/files/leaky.txt"
run 2 "git commit --file=file" "$WORK" "${NOENV[@]}" -- \
  "git commit --file=$TMP/files/leaky.txt"
run 2 "git commit -aF cluster" "$WORK" "${NOENV[@]}" -- \
  "git commit -aF $TMP/files/leaky.txt"
run 2 "git commit -F relative path from the event cwd" "$TMP/files" "${NOENV[@]}" -- \
  "git commit -F leaky.txt"
run 2 "git commit -F relative path after cd" "$TMP/plain" "${NOENV[@]}" -- \
  "cd $TMP/files && git commit -F leaky.txt"
run 2 "git commit -F relative path resolved against -C" "$TMP/plain" "${NOENV[@]}" -- \
  "git -C $TMP/files commit -F leaky.txt"
run 0 "near-miss: relative path misses when cwd differs" "$TMP/plain" "${NOENV[@]}" -- \
  "git commit -F leaky.txt"
run 0 "unreadable file is not a block" "$WORK" "${NOENV[@]}" -- \
  "git commit -F $TMP/files/missing.txt"
run 0 "git commit -F - with no link in the text" "$WORK" "${NOENV[@]}" -- \
  "echo hi | git commit -F -"
run 2 "gh pr create --body-file" "$WORK" "${NOENV[@]}" -- \
  "gh pr create --title t --body-file $TMP/files/leaky.txt"
run 0 "near-miss: gh pr create --body-file clean" "$WORK" "${NOENV[@]}" -- \
  "gh pr create --title t --body-file $TMP/files/clean.txt"
run 2 "gh issue create -F" "$WORK" "${NOENV[@]}" -- \
  "gh issue create --title t -F $TMP/files/leaky.txt"
run 2 "gh release create --notes-file=" "$WORK" "${NOENV[@]}" -- \
  "gh release create v1 --notes-file=$TMP/files/leaky.txt"
run 2 "gh api -F body=@file" "$WORK" "${NOENV[@]}" -- \
  "gh api repos/example/one/issues -F body=@$TMP/files/leaky.txt"
run 0 "near-miss: gh api -F body=@clean file" "$WORK" "${NOENV[@]}" -- \
  "gh api repos/example/one/issues -F body=@$TMP/files/clean.txt"
run 2 "gh api --field body=@file" "$WORK" "${NOENV[@]}" -- \
  "gh api repos/example/one/issues --field body=@$TMP/files/leaky.txt"
run 2 "gh api --input file" "$WORK" "${NOENV[@]}" -- \
  "gh api repos/example/one/issues --input $TMP/files/leaky.txt"
run 0 "near-miss: gh api -F n=5 (no file)" "$WORK" "${NOENV[@]}" -- \
  "gh api repos/example/one/issues -F n=5"

# =============================================================================
# Group 4: git push scans the commits being pushed (rule 3)
# =============================================================================
run 2 "push with an offending unpushed commit (HEAD)" "$WORK" "${NOENV[@]}" -- \
  "git push origin"
assert_out "message names the short sha" present "commit $LEAKY_SHA subject line"
assert_out "push message masks the id" absent "$ID"
run 2 "push refspec source: branch name" "$WORK" "${NOENV[@]}" -- \
  "git push origin leaky"
run 2 "push refspec HEAD:refs/heads/x" "$WORK" "${NOENV[@]}" -- \
  "git push origin HEAD:refs/heads/x"
run 2 "push -u with +force refspec" "$WORK" "${NOENV[@]}" -- \
  "git push -u origin +leaky:leaky"
run 2 "push via git -C" "$TMP/plain" "${NOENV[@]}" -- \
  "git -C $WORK push origin leaky"
run 0 "near-miss: push a clean unpushed branch by name" "$WORK" "${NOENV[@]}" -- \
  "git push origin clean"
run 0 "near-miss: push main (link commit already on the remote)" "$WORK" "${NOENV[@]}" -- \
  "git push origin main"
run 0 "near-miss: push a delete refspec" "$WORK" "${NOENV[@]}" -- \
  "git push origin :stale"
run 0 "bypass: push with the own-prefix token" "$WORK" "${NOENV[@]}" -- \
  "SYG_ALLOW_SESSION_URL=1 git push origin leaky"
run 0 "push from a non-repo directory fails open" "$TMP/plain" "${NOENV[@]}" -- \
  "git push origin leaky"

# =============================================================================
# Group 5: gh gist positional files, gh repo create --push, cd ~
# =============================================================================
run 2 "gh gist create <leaky file>" "$WORK" "${NOENV[@]}" -- \
  "gh gist create $TMP/files/leaky.txt"
assert_out "message names the gist file" present "file $TMP/files/leaky.txt"
run 0 "near-miss: gh gist create <clean file>" "$WORK" "${NOENV[@]}" -- \
  "gh gist create $TMP/files/clean.txt"
run 2 "gh gist create with flags before the file" "$WORK" "${NOENV[@]}" -- \
  "gh gist create -d 'a desc' --public $TMP/files/leaky.txt"
run 2 "gh gist create relative file from the event cwd" "$TMP/files" "${NOENV[@]}" -- \
  "gh gist create leaky.txt"
run 0 "near-miss: gh gist create, value of -d is not read as a file" "$WORK" "${NOENV[@]}" -- \
  "gh gist create -d $TMP/files/leaky.txt $TMP/files/clean.txt"
run 2 "gh gist edit --add <leaky file>" "$WORK" "${NOENV[@]}" -- \
  "gh gist edit abc123 --add $TMP/files/leaky.txt"
run 0 "near-miss: gh gist edit --add <clean file>" "$WORK" "${NOENV[@]}" -- \
  "gh gist edit abc123 --add $TMP/files/clean.txt"

CLEAN_REPO="$TMP/clean_repo"
git init -q "$CLEAN_REPO"
git -C "$CLEAN_REPO" commit -q --allow-empty -m "clean only"
run 2 "gh repo create --source <repo> --push, offending unpushed commit" "$TMP/plain" "${NOENV[@]}" -- \
  "gh repo create me/x --private --source $WORK --push"
assert_out "repo create message names the short sha" present "commit $LEAKY_SHA subject line"
run 2 "gh repo create --source . --push from the repo cwd" "$WORK" "${NOENV[@]}" -- \
  "gh repo create me/x --private --source . --push"
run 2 "gh repo create --push with no --source scans the cwd" "$WORK" "${NOENV[@]}" -- \
  "gh repo create me/x --private --push"
run 2 "gh repo create --source=<repo> --push" "$TMP/plain" "${NOENV[@]}" -- \
  "gh repo create me/x --source=$WORK --push"
run 0 "near-miss: gh repo create --source <clean repo> --push" "$TMP/plain" "${NOENV[@]}" -- \
  "gh repo create me/x --private --source $CLEAN_REPO --push"
run 0 "near-miss: gh repo create <offending repo> without --push" "$TMP/plain" "${NOENV[@]}" -- \
  "gh repo create me/x --private --source $WORK"
run 0 "bypass: gh repo create --push with the own-prefix token" "$TMP/plain" "${NOENV[@]}" -- \
  "SYG_ALLOW_SESSION_URL=1 gh repo create me/x --source $WORK --push"

run 2 "cd ~/dir then relative -F (HOME from the environment)" "$TMP/plain" HOME="$TMP" -- \
  "cd ~/files && git commit -F leaky.txt"
run 2 "cd ~ then relative -F" "$TMP/plain" HOME="$TMP/files" -- \
  "cd ~ && git commit -F leaky.txt"
run 0 "near-miss: cd ~/other-dir then relative -F" "$TMP/plain" HOME="$TMP" -- \
  "cd ~/plain && git commit -F leaky.txt"
run 0 "near-miss: cd \$VAR is still not followed" "$TMP/plain" HOME="$TMP" -- \
  'cd $HOME/files && git commit -F leaky.txt'

# =============================================================================
# Group 6: pass-through and the prefilter
# =============================================================================
run 0 "no git or gh word at all" "$WORK" "${NOENV[@]}" -- "ls -la"
run 0 "git status" "$WORK" "${NOENV[@]}" -- "git status"

# A python3 shim records each spawn; it is the only way to tell "prefilter
# skipped" from "python ran and allowed".
SHIM="$TMP/shim"
mkdir -p "$SHIM"
REAL_PY=$(command -v python3)
printf '#!/bin/bash\n: >"%s/spawned"\nexec "%s" "$@"\n' "$TMP" "$REAL_PY" >"$SHIM/python3"
chmod +x "$SHIM/python3"

spawn_check() { # spawn_check <expect spawned|skipped> <label>
  local got=skipped
  [ -e "$TMP/spawned" ] && got=spawned
  if [ "$got" = "$1" ]; then
    printf 'PASS  (shim)  %s\n' "$2"
  else
    printf 'FAIL  (shim, %s, expected %s)  %s\n' "$got" "$1" "$2"
    FAILURES=$((FAILURES + 1))
  fi
}
rm -f "$TMP/spawned"
run 0 "prefilter: git status with a link in the text passes" "$WORK" PATH="$SHIM:$PATH" -- \
  "git status # ${LINK}"
spawn_check skipped "git status never spawned python"
rm -f "$TMP/spawned"
run 0 "prefilter positive control: git commit runs python" "$WORK" PATH="$SHIM:$PATH" -- \
  "git commit -m clean"
spawn_check spawned "git commit spawned python (the shim sees spawns)"
rm -f "$TMP/spawned"
run 0 "prefilter positive control: any gh word runs python" "$WORK" PATH="$SHIM:$PATH" -- \
  "gh pr list"
spawn_check spawned "gh pr list spawned python"

if [ "$FAILURES" -ne 0 ]; then
  printf '\n%d probe case(s) FAILED\n' "$FAILURES"
  exit 1
fi
printf '\nall session-url-gate probe cases passed\n'
