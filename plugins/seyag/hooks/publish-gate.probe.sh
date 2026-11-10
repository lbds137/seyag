#!/bin/bash
# Fixture check for publish-gate.sh — run after ANY edit to the hook. Builds
# throwaway fixture git repos with FAKE remote URLs under a mktemp dir
# (removed on exit), then asserts the gate: a gh command that would make a
# repo or gist public blocks (exit 2) unless the session environment carries
# SYG_PUBLISH_CHECKED covering that exact target; every read and every
# non-public write passes (exit 0).
#
# All fixture slugs are neutral placeholders (`example/one`, `other/two`) —
# no real GitHub username or org appears here.
#
# Usage: hooks/publish-gate.probe.sh   (from anywhere)

set -uo pipefail
# Hooks run here directly, not via run.sh: keep bytecode out of hooks/lib.
export PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$SCRIPT_DIR/publish-gate.sh"

TMP=$(mktemp -d) || { echo "FAIL [setup]: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
# Hermetic: git must not find a repo above the fixture.
export GIT_CEILING_DIRECTORIES="$TMP"

# --- fixture repos -----------------------------------------------------------
mk_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
}

FIX="$TMP/fix"          # origin example/one
mk_repo "$FIX"
git -C "$FIX" remote add origin https://github.com/example/one.git

TWO="$TMP/two"          # origin other/two
mk_repo "$TWO"
git -C "$TWO" remote add origin https://github.com/other/two.git

FORKBASE="$TMP/forkbase"  # origin example/one, gh-resolved to upstream other/two
mk_repo "$FORKBASE"
git -C "$FORKBASE" remote add origin https://github.com/example/one.git
git -C "$FORKBASE" remote add upstream https://github.com/other/two.git
git -C "$FORKBASE" config remote.upstream.gh-resolved base

NOTGIT="$TMP/notgit"
mkdir -p "$NOTGIT"

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
    | env -u SYG_PUBLISH_CHECKED "${envs[@]}" \
        timeout 20 "$HOOK" >"$TMP/out" 2>&1
  local actual=$?
  if [ "$actual" -eq "$expected" ]; then
    printf 'PASS  (exit %d)  %s\n' "$actual" "$label"
  else
    printf 'FAIL  (exit %d, expected %d)  %s\n' "$actual" "$expected" "$label"
    sed 's/^/      /' "$TMP/out"
    FAILURES=$((FAILURES + 1))
  fi
}

# assert_out <label> <present|absent|first-line> <fixed string>: checks the
# stdout+stderr of the LAST run.
assert_out() {
  local label="$1" mode="$2" s="$3" ok=1
  case "$mode" in
    present) grep -qF -- "$s" "$TMP/out" || ok=0 ;;
    absent) ! grep -qF -- "$s" "$TMP/out" || ok=0 ;;
    first-line) [ "$(head -n 1 "$TMP/out")" = "$s" ] || ok=0 ;;
  esac
  if [ "$ok" = 1 ]; then
    printf 'PASS  (output)  %s\n' "$label"
  else
    printf 'FAIL  (output)  %s\n' "$label"
    sed 's/^/      /' "$TMP/out"
    FAILURES=$((FAILURES + 1))
  fi
}

# =============================================================================
# Group 1: the four triggers block with the pinned message
# =============================================================================
run 2 "trigger 1: repo edit --visibility=public" "$FIX" -- \
  "gh repo edit -R example/one --visibility=public"
assert_out "pin: repo edit message first line" first-line \
  "blocked: gh repo edit would make example/one public. Run the going-public checklist (seyag:going-public) for it first; on pass set SYG_PUBLISH_CHECKED=example/one (colon-list ok; any non-empty value for a gist) (it is read from the session's environment at start: the owner restarts the session with it exported, or runs the command herself with \`!\`)."
run 2 "trigger 2: repo create --public" "$FIX" -- \
  "gh repo create --public"
assert_out "pin: repo create message first line" first-line \
  "blocked: gh repo create would make example/one public. Run the going-public checklist (seyag:going-public) for it first; on pass set SYG_PUBLISH_CHECKED=example/one (colon-list ok; any non-empty value for a gist) (it is read from the session's environment at start: the owner restarts the session with it exported, or runs the command herself with \`!\`)."
run 2 "trigger 3: gist create -p" "$FIX" -- \
  "gh gist create -p"
assert_out "pin: gist create message first line" first-line \
  "blocked: gh gist create would make a gist public. Run the going-public checklist (seyag:going-public) for it first; on pass set SYG_PUBLISH_CHECKED=<any non-empty value> (colon-list ok; any non-empty value for a gist) (it is read from the session's environment at start: the owner restarts the session with it exported, or runs the command herself with \`!\`)."
run 2 "trigger 4: api PATCH with private=false" "$FIX" -- \
  "gh api repos/example/one -X PATCH -f private=false"
assert_out "pin: api message first line" first-line \
  "blocked: gh api PATCH repos/example/one would make example/one public. Run the going-public checklist (seyag:going-public) for it first; on pass set SYG_PUBLISH_CHECKED=example/one (colon-list ok; any non-empty value for a gist) (it is read from the session's environment at start: the owner restarts the session with it exported, or runs the command herself with \`!\`)."

# =============================================================================
# Group 2: negatives pass
# =============================================================================
run 0 "negative: --visibility private" "$FIX" -- \
  "gh repo edit -R example/one --visibility private"
run 0 "negative: --visibility internal" "$FIX" -- \
  "gh repo edit -R example/one --visibility=internal"
run 0 "negative: bare repo create" "$FIX" -- \
  "gh repo create"
run 0 "negative: gh repo view (a read)" "$FIX" -- \
  "gh repo view"
run 0 "negative: gh api GET" "$FIX" -- \
  "gh api repos/example/one"
run 0 "negative: repo create --private" "$FIX" -- \
  "gh repo create x --private"
run 0 "negative: repo edit with no --visibility" "$FIX" -- \
  "gh repo edit -R example/one --description hi"
run 0 "negative: gist create (secret, the default)" "$FIX" -- \
  "gh gist create -"
run 0 "negative: api PATCH with private=true" "$FIX" -- \
  "gh api repos/example/one -X PATCH -f private=true"
run 0 "negative: api PATCH with an unrelated field" "$FIX" -- \
  "gh api repos/example/one -X PATCH -f description=hi"
run 0 "negative: api subpath endpoint is not the repo edit" "$FIX" -- \
  "gh api repos/example/one/branches -X PATCH -f private=false"

# =============================================================================
# Group 3: env unblock for repos
# =============================================================================
run 0 "env exact slug passes trigger 1" "$FIX" \
  SYG_PUBLISH_CHECKED=example/one -- \
  "gh repo edit -R example/one --visibility=public"
run 0 "env colon-list containing the slug passes" "$FIX" \
  SYG_PUBLISH_CHECKED=other/two:example/one -- \
  "gh repo edit -R example/one --visibility=public"
run 2 "env with a different slug still blocks" "$FIX" \
  SYG_PUBLISH_CHECKED=other/two -- \
  "gh repo edit -R example/one --visibility=public"
run 2 "env empty string does not unblock a repo" "$FIX" \
  SYG_PUBLISH_CHECKED= -- \
  "gh repo edit -R example/one --visibility=public"
run 0 "env slug case-insensitive" "$FIX" \
  SYG_PUBLISH_CHECKED=EXAMPLE/ONE -- \
  "gh repo edit -R example/one --visibility=public"
run 0 "env unblocks the api trigger too" "$FIX" \
  SYG_PUBLISH_CHECKED=example/one -- \
  "gh api repos/example/one -X PATCH -f private=false"

# =============================================================================
# Group 4: gist unblock is any non-empty value
# =============================================================================
run 0 "gist: any non-empty env value passes" "$FIX" \
  SYG_PUBLISH_CHECKED=yes -- \
  "gh gist create -p"
run 0 "gist: a repo-shaped value passes too" "$FIX" \
  SYG_PUBLISH_CHECKED=example/one -- \
  "gh gist create --public"
run 2 "gist: env unset blocks" "$FIX" -- \
  "gh gist create -p"

# =============================================================================
# Group 5: placement — wrappers and substitutions
# =============================================================================
run 2 "bash -c wrapper blocks" "$FIX" -- \
  "bash -c 'gh repo edit -R example/one --visibility=public'"
run 2 "command substitution blocks" "$FIX" -- \
  'echo "$(gh gist create -p)"'
run 2 "eval string blocks" "$FIX" -- \
  'eval "gh repo create --public"'
run 2 "backtick capture blocks" "$FIX" -- \
  'x=`gh repo edit -R example/one --visibility=public`'
run 0 "quoted mention does not block" "$FIX" -- \
  'echo "gh repo create --public"'
# A substitution inside nested `bash -c` strings, judged in the dir it cds to
# (TWO; the env covers only FIX's example/one). Two wrappers: walked inline
# below MAX_WRAPPER_DEPTH (control); three: the span sits at the cap and is
# judged through the leftover replay.
run 2 "substitution under two bash -c wrappers blocks (below-cap control)" "$FIX" \
  SYG_PUBLISH_CHECKED=example/one -- \
  'bash -c "bash -c \"echo \\\"\\\$(cd ../two; gh repo edit --visibility=public)\\\"\""'
run 2 "substitution under three bash -c wrappers (at the cap) blocks" "$FIX" \
  SYG_PUBLISH_CHECKED=example/one -- \
  'bash -c "bash -c \"bash -c \\\"echo \\\\\\\"\\\\\\\$(cd ../two; gh repo edit --visibility=public)\\\\\\\"\\\"\""'
assert_out "at-cap substitution judged in the dir it cds to" present \
  "would make other/two public"

# =============================================================================
# Group 6: case-insensitivity of the enum value
# =============================================================================
run 2 "--visibility=PUBLIC (uppercase) blocks" "$FIX" -- \
  "gh repo edit -R example/one --visibility=PUBLIC"
run 2 "--visibility Public (mixed case) blocks" "$FIX" -- \
  "gh repo edit -R example/one --visibility Public"

# =============================================================================
# Flag forms and parsing details
# =============================================================================
run 2 "repo edit --visibility public (separate word)" "$FIX" -- \
  "gh repo edit -R example/one --visibility public"
run 2 "repo new --public (alias)" "$FIX" -- \
  "gh repo new --public"
run 2 "gist new -p (alias)" "$FIX" -- \
  "gh gist new -p"
run 2 "gist create --public (long)" "$FIX" -- \
  "gh gist create --public"
run 0 "gist create -fp: -f takes a value, NOT a -p hit" "$FIX" -- \
  "gh gist create -fp"
run 0 "gist create -w -d x: booleans, no -p" "$FIX" -- \
  "gh gist create -w -d x"
run 2 "gist cluster -pw: -p inside the cluster" "$FIX" -- \
  "gh gist create -pw"
run 2 "api --field=private=false (=joined)" "$FIX" -- \
  "gh api repos/example/one --field=private=false"
run 2 "api --raw-field visibility=public" "$FIX" -- \
  "gh api repos/example/one --raw-field visibility=public"
run 2 "api -F typed field private=false" "$FIX" -- \
  "gh api repos/example/one -F private=false"
run 2 "api -fprivate=false (attached)" "$FIX" -- \
  "gh api repos/example/one -fprivate=false"
run 2 "api implicit POST via -f visibility=public" "$FIX" -- \
  "gh api repos/example/one -f visibility=public"
run 2 "api --input counts as a write; separate -f decides" "$FIX" -- \
  "gh api repos/example/one --input=body.json -f private=false"
# An --input body on stdin is in the command text: the whole text is scanned.
run 2 "api --input - here-string body private:false" "$FIX" -- \
  "gh api repos/example/one -X PATCH --input - <<< '{\"private\":false}'"
run 2 "api --input - heredoc body visibility:public" "$FIX" -- \
  "gh api repos/example/one -X PATCH --input - <<'EOF'
{\"visibility\": \"public\"}
EOF"
run 2 "api --input - echo-pipe body (spaced, uppercase False)" "$FIX" -- \
  "echo '{\"private\" : False}' | gh api repos/example/one -X PATCH --input -"
assert_out "pin: --input body block names the api target" first-line \
  "blocked: gh api PATCH repos/example/one would make example/one public. Run the going-public checklist (seyag:going-public) for it first; on pass set SYG_PUBLISH_CHECKED=example/one (colon-list ok; any non-empty value for a gist) (it is read from the session's environment at start: the owner restarts the session with it exported, or runs the command herself with \`!\`)."
run 2 "api --input - body with backslash-escaped quotes (echo \"{\\\"private\\\": false}\")" "$FIX" -- \
  "echo \"{\\\"private\\\": false}\" | gh api repos/example/one -X PATCH --input -"
run 2 "api --input - body with escaped visibility:public" "$FIX" -- \
  "echo \"{\\\"visibility\\\": \\\"public\\\"}\" | gh api repos/example/one -X PATCH --input -"
run 2 "api --input - body from a jq object literal with an unquoted key" "$FIX" -- \
  "jq -n '{private:false}' | gh api repos/example/one -X PATCH --input -"
run 0 "negative: api --input - with private:true" "$FIX" -- \
  "gh api repos/example/one -X PATCH --input - <<< '{\"private\": true}'"
run 0 "negative: escaped private:true still allowed" "$FIX" -- \
  "echo \"{\\\"private\\\": true}\" | gh api repos/example/one -X PATCH --input -"
run 0 "negative: JSON flip text without any --input" "$FIX" -- \
  "gh api repos/example/one -X PATCH -f description='{\"private\":false}'"
run 2 "api -X PUT with private=false" "$FIX" -- \
  "gh api repos/example/one -X PUT -f private=false"
run 2 "api attached -XPATCH method" "$FIX" -- \
  "gh api -XPATCH repos/example/one -f private=false"
run 2 "api -X after the endpoint" "$FIX" -- \
  "gh api repos/example/one -f private=false -X PATCH"
run 2 "api leading slash endpoint" "$FIX" -- \
  "gh api /repos/example/one -X PATCH -f private=false"
run 2 "api endpoint with a query string" "$FIX" -- \
  "gh api 'repos/example/one?foo=1' -X PATCH -f private=false"
run 0 "api value flags consume their values (-q then -f)" "$FIX" -- \
  "gh api -q .id repos/example/one -f description=hi"
run 0 "api -p is --preview (a value flag), not a publish" "$FIX" -- \
  "gh api repos/example/one -p merge -f description=hi"

# Explicit POST is a write like the implicit one (gh defaults to POST).
run 2 "api explicit -X POST with private=false" "$FIX" -- \
  "gh api repos/example/one -X POST -f private=false"
assert_out "pin: explicit POST message first line" first-line \
  "blocked: gh api POST repos/example/one would make example/one public. Run the going-public checklist (seyag:going-public) for it first; on pass set SYG_PUBLISH_CHECKED=example/one (colon-list ok; any non-empty value for a gist) (it is read from the session's environment at start: the owner restarts the session with it exported, or runs the command herself with \`!\`)."
run 2 "api --method=POST with visibility=public" "$FIX" -- \
  "gh api repos/example/one --method=POST -f visibility=public"
assert_out "pin: --method=POST message first line" first-line \
  "blocked: gh api POST repos/example/one would make example/one public. Run the going-public checklist (seyag:going-public) for it first; on pass set SYG_PUBLISH_CHECKED=example/one (colon-list ok; any non-empty value for a gist) (it is read from the session's environment at start: the owner restarts the session with it exported, or runs the command herself with \`!\`)."
run 0 "api explicit -X POST with a benign field" "$FIX" -- \
  "gh api repos/example/one -X POST -f description=hi"
run 0 "api explicit -X POST with no fields" "$FIX" -- \
  "gh api repos/example/one -X POST"
run 0 "api explicit -X GET stays read-only" "$FIX" -- \
  "gh api repos/example/one -X GET -f private=false"

# =============================================================================
# Repo creates through gh api: REST defaults `private` to false on all three
# endpoints, so a create with no private field is a publish
# =============================================================================
run 2 "create: user/repos with a name, no private field, is unresolvable" "$FIX" -- \
  "gh api user/repos -f name=x"
assert_out "create: user/repos names an unresolvable target" present \
  "blocked: gh api POST user/repos would make an unresolvable target"
run 0 "create: user/repos with private=true" "$FIX" -- \
  "gh api user/repos -f name=x -f private=true"
run 0 "create: user/repos with -F private=true" "$FIX" -- \
  "gh api user/repos -F private=true"
run 2 "create: orgs/o/repos with a literal name blocks naming o/x" "$FIX" -- \
  "gh api orgs/o/repos -f name=x"
assert_out "create: orgs/o/repos names o/x" present "would make o/x public"
run 0 "create: orgs/o/repos with visibility=private" "$FIX" -- \
  "gh api orgs/o/repos -f name=x -f visibility=private"
run 0 "create: orgs/o/repos with visibility=internal" "$FIX" -- \
  "gh api orgs/o/repos -f name=x -f visibility=internal"
run 2 "create: private=true with visibility=public blocks (public wins)" "$FIX" -- \
  "gh api orgs/o/repos -f private=true -f visibility=public"
run 2 "create: orgs/o/repos with visibility=public blocks naming o/x" "$FIX" -- \
  "gh api orgs/o/repos -f name=x -f visibility=public"
assert_out "create: visibility=public names o/x" present "would make o/x public"
run 2 "create: repos/o/tpl/generate with owner and name blocks naming o2/x" "$FIX" -- \
  "gh api repos/o/tpl/generate -f owner=o2 -f name=x"
assert_out "create: generate names the owner given in the body" present "would make o2/x public"
run 2 "create: generate with no owner field is unresolvable" "$FIX" -- \
  "gh api repos/o/tpl/generate -f name=x"
run 2 "create: a placeholder in the create path is unresolvable" "$FIX" -- \
  "gh api orgs/{org}/repos -f name=x"
run 2 "create: explicit POST with no fields is a publish" "$FIX" -- \
  "gh api -X POST orgs/o/repos"
run 0 "create: --input - with a here-string holding private true" "$FIX" -- \
  "gh api user/repos --input - <<< '{\"name\":\"x\",\"private\":true}'"
run 2 "create: --input - with a here-string holding private false" "$FIX" -- \
  "gh api user/repos --input - <<< '{\"name\":\"x\",\"private\":false}'"
run 2 "create: --input body.json (body not visible) blocks" "$FIX" -- \
  "gh api user/repos --input body.json"
run 0 "create: gh api user/repos (GET) stays read-only" "$FIX" -- \
  "gh api user/repos"
run 0 "create: gh api -X GET orgs/o/repos -f per_page=5 stays read-only" "$FIX" -- \
  "gh api -X GET orgs/o/repos -f per_page=5"
run 0 "create: PATCH on a create endpoint is not a create" "$FIX" -- \
  "gh api -X PATCH orgs/o/repos -f name=x"
run 0 "create: PUT on a create endpoint is not a create" "$FIX" -- \
  "gh api -X PUT user/repos -f name=x"
run 2 "create: https://api.github.com/user/repos form blocks" "$FIX" -- \
  "gh api https://api.github.com/user/repos -f name=x"

# --input: gh sends the file as the body; field flags go to the query string. A
# named file is never visible, so it is never kept, and a create with --input
# has no target.
run 2 "create --input: a private word in the text does not vouch for a named file" "$FIX" -- \
  "echo '\"private\": true'; gh api user/repos --input body.json"
run 2 "create --input: a private word in a comment does not vouch for a named file" "$FIX" -- \
  "gh api user/repos --input body.json # \"private\": true"
run 2 "create --input: a -f private=true does not reach the body" "$FIX" -- \
  "gh api user/repos -f private=true -f name=x --input b.json"
run 2 "create --input: a named file with a literal org blocks as unresolvable" "$FIX" -- \
  "gh api orgs/o/repos -f name=x --input b.json"
run 2 "create --input: SYG_PUBLISH_CHECKED cannot unblock a named file" "$FIX" \
  SYG_PUBLISH_CHECKED=o/x -- "gh api orgs/o/repos -f name=x --input b.json"
run 2 "create --input=: the = form of a named file blocks" "$FIX" -- \
  "gh api user/repos --input=body.json"

# visibility keeps a repo private only on the org endpoint (REST lists it on
# POST orgs/O/repos only); private=true keeps it on all three.
run 2 "create: user/repos with visibility=private is public (ignored there)" "$FIX" -- \
  "gh api user/repos -f name=x -f visibility=private"
run 2 "create: generate with visibility=private is public, naming o2/x" "$FIX" -- \
  "gh api repos/o/t/generate -f owner=o2 -f name=x -f visibility=private"
assert_out "create: generate visibility=private names o2/x" present "would make o2/x public"
run 2 "create --input -: visibility=private in the body is ignored on user/repos" "$FIX" -- \
  "gh api user/repos --input - <<< '{\"name\":\"x\",\"visibility\":\"private\"}'"
run 0 "create --input -: visibility=private in the body keeps an org create private" "$FIX" -- \
  "gh api orgs/o/repos --input - <<< '{\"name\":\"x\",\"visibility\":\"private\"}'"

# A literal name holding braces is not a literal: unresolvable.
run 2 "create: a braces value in name= is unresolvable" "$FIX" -- \
  "gh api orgs/o/repos -f name={repo}"
assert_out "create: braces name names an unresolvable target" present "an unresolvable target"

# A create-only unresolvable block says so, and not the non-create paragraph.
run 2 "create: user/repos with a name is unresolvable (create paragraph)" "$FIX" -- \
  "gh api user/repos -f name=x"
assert_out "create: unresolvable paragraph names the create forms" present \
  "A create through gh api names no target here, and SYG_PUBLISH_CHECKED cannot unblock it"
assert_out "create: unresolvable display is 'an unresolvable target'" present \
  "would make an unresolvable target public"
assert_out "create: no 'literal owner/repo' wording on a create-only block" absent \
  "literal owner/repo"
assert_out "create: a create-only block has no SYG_PUBLISH_CHECKED clause" absent \
  "on pass set SYG_PUBLISH_CHECKED"
run 2 "mixed: a create and a repo edit keep the SYG_PUBLISH_CHECKED clause" "$FIX" -- \
  "gh api user/repos -f name=x; gh repo edit other/two --visibility=public"
assert_out "mixed block keeps the clause" present "on pass set SYG_PUBLISH_CHECKED"

# A keep must be spelled exactly: a space around the key or value is not one.
run 2 "create: 'private= true' (a space in the value) is not a keep" "$FIX" -- \
  "gh api user/repos -f 'private= true' -f name=x"
run 0 "create: generate with owner, name and private=true keeps private" "$FIX" -- \
  "gh api repos/o/t/generate -f owner=o2 -f name=x -f private=true"
run 0 "create: orgs/o/repos with name and private=true keeps private" "$FIX" -- \
  "gh api orgs/o/repos -f name=x -f private=true"

# =============================================================================
# Target resolution
# =============================================================================
run 2 "remotes resolve the target (no -R)" "$FIX" -- \
  "gh repo edit --visibility=public"
run 2 "r1: positional operand names the target" "$FIX" -- \
  "gh repo edit other/two --visibility=public"
assert_out "r1: positional target in the pinned first line" first-line \
  "blocked: gh repo edit would make other/two public. Run the going-public checklist (seyag:going-public) for it first; on pass set SYG_PUBLISH_CHECKED=other/two (colon-list ok; any non-empty value for a gist) (it is read from the session's environment at start: the owner restarts the session with it exported, or runs the command herself with \`!\`)."
run 2 "r1: wrong-slug env does NOT unblock a positional target" "$FIX" \
  SYG_PUBLISH_CHECKED=example/one -- \
  "gh repo edit other/two --visibility=public"
run 2 "r1: create with OWNER/NAME positional" "$FIX" -- \
  "gh repo create example/three --public"
assert_out "r1: create positional target named" first-line \
  "blocked: gh repo create would make example/three public. Run the going-public checklist (seyag:going-public) for it first; on pass set SYG_PUBLISH_CHECKED=example/three (colon-list ok; any non-empty value for a gist) (it is read from the session's environment at start: the owner restarts the session with it exported, or runs the command herself with \`!\`)."
run 2 "r1: create with a BARE name is unresolvable" "$FIX" -- \
  "gh repo create three --public"
assert_out "r1: bare-name advice line" present \
  "owner/repo so it can be judged (the env unblock then works)."
run 2 "r1: positional \"\$r\" is unresolvable" "$FIX" -- \
  'gh repo edit "$r" --visibility=public'
assert_out "r1: unresolvable positional advice line" present \
  "owner/repo so it can be judged (the env unblock then works)."
run 2 "r1: positional URL form parses" "$FIX" -- \
  "gh repo edit https://github.com/example/three.git --visibility=public"
assert_out "r1: URL positional target named" first-line \
  "blocked: gh repo edit would make example/three public. Run the going-public checklist (seyag:going-public) for it first; on pass set SYG_PUBLISH_CHECKED=example/three (colon-list ok; any non-empty value for a gist) (it is read from the session's environment at start: the owner restarts the session with it exported, or runs the command herself with \`!\`)."
run 0 "r1: positional with a private visibility passes" "$FIX" -- \
  "gh repo edit other/two --visibility private"
run 0 "r1: correct-slug env unblocks a positional target" "$FIX" \
  SYG_PUBLISH_CHECKED=other/two -- \
  "gh repo edit other/two --visibility=public"
run 0 "remotes resolve; env covers that slug" "$FIX" \
  SYG_PUBLISH_CHECKED=example/one -- \
  "gh repo edit --visibility=public"
run 2 "gh-resolved base names the upstream" "$FORKBASE" -- \
  "gh repo create --public"
run 2 "GH_REPO prefix names the target" "$FIX" -- \
  "GH_REPO=example/one gh repo edit --visibility=public"
run 2 "export GH_REPO earlier in the text" "$FIX" -- \
  "export GH_REPO=example/one; gh repo create --public"
run 2 "cd into the fixture then publish" "$NOTGIT" -- \
  "cd $FIX && gh repo edit --visibility=public"
# A repo literally named `~other` inside FIX: with no such user bash leaves
# `~other` literal and cd enters FIX/~other, so the gh is judged there, where
# other/two blocks (example/one, the payload cwd's target, is checked).
TILDE_DIR="$FIX/~other"
mk_repo "$TILDE_DIR"
git -C "$TILDE_DIR" remote add origin https://github.com/other/two.git
run 2 "cd ~other enters a literal FIX/~other repo (bash's fallback)" "$FIX" \
  SYG_PUBLISH_CHECKED=example/one -- \
  "cd ~other && gh repo edit --visibility=public"
run 2 "unresolvable -R \"\$r\" blocks, never bypassable" "$FIX" -- \
  'gh repo edit -R "$r" --visibility=public'
assert_out "unresolvable line names the fix" present \
  "owner/repo so it can be judged (the env unblock then works)."
run 2 "repo create outside any repo: nothing to resolve, blocks" "$NOTGIT" -- \
  "gh repo create --public"
run 2 "empty -R \"\" falls back to the remotes (example/one), which blocks" "$FIX" -- \
  'gh repo edit -R "" --visibility public'
run 2 "-R HOST/OWNER/REPO form" "$FIX" -- \
  "gh repo edit -R github.com/example/one --visibility=public"
run 2 "api {owner}/{repo} placeholders from remotes" "$FIX" -- \
  "gh api repos/{owner}/{repo} -X PATCH -f private=false"

# --- state machine (mirrors the sibling probe's cd/pushd/GIT_DIR shapes) ------
run 2 "r2: pushd swap lands in FIX" "$TWO" -- \
  "pushd ../fix && gh repo edit --visibility=public"
assert_out "r2: pushd swap resolved example/one" first-line \
  "blocked: gh repo edit would make example/one public. Run the going-public checklist (seyag:going-public) for it first; on pass set SYG_PUBLISH_CHECKED=example/one (colon-list ok; any non-empty value for a gist) (it is read from the session's environment at start: the owner restarts the session with it exported, or runs the command herself with \`!\`)."
run 2 "r2: pushd then popd is back in TWO" "$TWO" -- \
  "pushd ../fix && popd && gh repo edit --visibility=public"
assert_out "r2: popd restored other/two" first-line \
  "blocked: gh repo edit would make other/two public. Run the going-public checklist (seyag:going-public) for it first; on pass set SYG_PUBLISH_CHECKED=other/two (colon-list ok; any non-empty value for a gist) (it is read from the session's environment at start: the owner restarts the session with it exported, or runs the command herself with \`!\`)."
run 2 "r2: GIT_DIR prefix reads the other fixture" "$FIX" -- \
  "GIT_DIR=../two/.git gh repo edit --visibility=public"
assert_out "r2: GIT_DIR resolved other/two" first-line \
  "blocked: gh repo edit would make other/two public. Run the going-public checklist (seyag:going-public) for it first; on pass set SYG_PUBLISH_CHECKED=other/two (colon-list ok; any non-empty value for a gist) (it is read from the session's environment at start: the owner restarts the session with it exported, or runs the command herself with \`!\`)."
run 2 "r2: GIT_WORK_TREE prefix alone still blocks" "$FIX" -- \
  "GIT_WORK_TREE=../two gh repo edit --visibility=public"
run 2 "r2: export GH_REPO then unset falls back to remotes" "$FIX" -- \
  "export GH_REPO=other/two; unset GH_REPO; gh repo edit --visibility=public"
assert_out "r2: unset GH_REPO restored example/one" first-line \
  "blocked: gh repo edit would make example/one public. Run the going-public checklist (seyag:going-public) for it first; on pass set SYG_PUBLISH_CHECKED=example/one (colon-list ok; any non-empty value for a gist) (it is read from the session's environment at start: the owner restarts the session with it exported, or runs the command herself with \`!\`)."

CHK="$TMP/chk"
mk_repo "$CHK"
git -C "$CHK" remote add origin https://github.com/other/two.git
run 2 "r2: false && cd ../chk; gh repo edit --visibility public" "$FIX" \
  SYG_PUBLISH_CHECKED=other/two -- \
  "false && cd ../chk; gh repo edit --visibility public"
run 2 "r2: cd ../chk & gh repo edit --visibility public" "$FIX" \
  SYG_PUBLISH_CHECKED=other/two -- \
  "cd ../chk & gh repo edit --visibility public"
run 2 "r2: if false; then cd ../chk; fi; gh repo edit --visibility public" "$FIX" \
  SYG_PUBLISH_CHECKED=other/two -- \
  "if false; then cd ../chk; fi; gh repo edit --visibility public"
run 0 "r2: cd ../chk && gh repo edit --visibility public (regression canary)" "$FIX" \
  SYG_PUBLISH_CHECKED=other/two -- \
  "cd ../chk && gh repo edit --visibility public"
run 0 "r2: cd ../chk; gh repo edit --visibility public when ../chk exists" "$FIX" \
  SYG_PUBLISH_CHECKED=other/two -- \
  "cd ../chk; gh repo edit --visibility public"
run 0 "r2: cd ../chk || exit 1; gh repo edit --visibility public" "$FIX" \
  SYG_PUBLISH_CHECKED=other/two -- \
  "cd ../chk || exit 1; gh repo edit --visibility public"

# --- r5: cheap pins for code-read behavior -----------------------------------
run 2 "r5: api.github.com-prefixed endpoint blocks" "$FIX" -- \
  "gh api https://api.github.com/repos/example/one -X PATCH -f private=false"
run 2 "r5: --method=PATCH (=joined) blocks" "$FIX" -- \
  "gh api repos/example/one --method=PATCH -f private=false"
run 2 "r5: env GH_REPO fills {owner}/{repo}" "$FIX" \
  GH_REPO=example/one -- \
  "gh api repos/{owner}/{repo} -X PATCH -f private=false"
assert_out "r5: GH_REPO placeholder target named" first-line \
  "blocked: gh api PATCH repos/{owner}/{repo} would make example/one public. Run the going-public checklist (seyag:going-public) for it first; on pass set SYG_PUBLISH_CHECKED=example/one (colon-list ok; any non-empty value for a gist) (it is read from the session's environment at start: the owner restarts the session with it exported, or runs the command herself with \`!\`)."
run 2 "r5: literal endpoint beats GH_REPO" "$FIX" \
  GH_REPO=other/two -- \
  "gh api repos/example/one -X PATCH -f private=false"
assert_out "r5: literal endpoint target named" first-line \
  "blocked: gh api PATCH repos/example/one would make example/one public. Run the going-public checklist (seyag:going-public) for it first; on pass set SYG_PUBLISH_CHECKED=example/one (colon-list ok; any non-empty value for a gist) (it is read from the session's environment at start: the owner restarts the session with it exported, or runs the command herself with \`!\`)."

# =============================================================================
# Redirections next to a gh publish never degrade target resolution: a
# redirection word (`2>&1`, `2>/dev/null`, `>out.txt`, …) is stripped before
# arg parsing, so it can't ride in as a positional operand.
# =============================================================================
run 2 "redir: trailing 2>&1 in a pipe still names example/one" "$FIX" -- \
  "gh repo edit -R example/one --visibility=public 2>&1 | head -3"
assert_out "redir: -R target named despite 2>&1" first-line \
  "blocked: gh repo edit would make example/one public. Run the going-public checklist (seyag:going-public) for it first; on pass set SYG_PUBLISH_CHECKED=example/one (colon-list ok; any non-empty value for a gist) (it is read from the session's environment at start: the owner restarts the session with it exported, or runs the command herself with \`!\`)."
run 2 "redir: 2>&1 after a pipe, rc echo after" "$FIX" -- \
  'gh repo edit -R example/one --visibility=public 2>&1 | head -3; echo "rc=$?"'
assert_out "redir: -R target named with rc echo" first-line \
  "blocked: gh repo edit would make example/one public. Run the going-public checklist (seyag:going-public) for it first; on pass set SYG_PUBLISH_CHECKED=example/one (colon-list ok; any non-empty value for a gist) (it is read from the session's environment at start: the owner restarts the session with it exported, or runs the command herself with \`!\`)."
run 2 "redir: positional plus 2>/dev/null" "$FIX" -- \
  "gh repo edit other/two --visibility=public 2>/dev/null"
assert_out "redir: positional target named despite 2>/dev/null" first-line \
  "blocked: gh repo edit would make other/two public. Run the going-public checklist (seyag:going-public) for it first; on pass set SYG_PUBLISH_CHECKED=other/two (colon-list ok; any non-empty value for a gist) (it is read from the session's environment at start: the owner restarts the session with it exported, or runs the command herself with \`!\`)."
run 2 "redir: gist create with 2>&1" "$FIX" -- \
  "gh gist create -p 2>&1"
assert_out "redir: gist pinned message" first-line \
  "blocked: gh gist create would make a gist public. Run the going-public checklist (seyag:going-public) for it first; on pass set SYG_PUBLISH_CHECKED=<any non-empty value> (colon-list ok; any non-empty value for a gist) (it is read from the session's environment at start: the owner restarts the session with it exported, or runs the command herself with \`!\`)."
run 2 "redir: bare-name create with >out.txt 2>&1 stays unresolvable" "$FIX" -- \
  "gh repo create three --public >out.txt 2>&1"
assert_out "redir: bare-name advice line survives the redirection" present \
  "owner/repo so it can be judged (the env unblock then works)."
run 2 "redir: api PATCH with 2>&1 | head" "$FIX" -- \
  "gh api repos/example/one -X PATCH -f private=false 2>&1 | head -1"
assert_out "redir: api endpoint target named despite 2>&1" first-line \
  "blocked: gh api PATCH repos/example/one would make example/one public. Run the going-public checklist (seyag:going-public) for it first; on pass set SYG_PUBLISH_CHECKED=example/one (colon-list ok; any non-empty value for a gist) (it is read from the session's environment at start: the owner restarts the session with it exported, or runs the command herself with \`!\`)."
run 2 "redir: append redirect 2>>log" "$FIX" -- \
  "gh repo edit -R example/one --visibility public 2>>log"
assert_out "redir: 2>> target named" first-line \
  "blocked: gh repo edit would make example/one public. Run the going-public checklist (seyag:going-public) for it first; on pass set SYG_PUBLISH_CHECKED=example/one (colon-list ok; any non-empty value for a gist) (it is read from the session's environment at start: the owner restarts the session with it exported, or runs the command herself with \`!\`)."
run 2 "redir: stdin redirect <in.txt" "$FIX" -- \
  "gh repo edit -R example/one --visibility=public <in.txt"
assert_out "redir: <in.txt target named" first-line \
  "blocked: gh repo edit would make example/one public. Run the going-public checklist (seyag:going-public) for it first; on pass set SYG_PUBLISH_CHECKED=example/one (colon-list ok; any non-empty value for a gist) (it is read from the session's environment at start: the owner restarts the session with it exported, or runs the command herself with \`!\`)."
run 2 "redir: split operator form > /dev/null" "$FIX" -- \
  "gh repo edit -R example/one --visibility=public > /dev/null"
assert_out "redir: > /dev/null target named" first-line \
  "blocked: gh repo edit would make example/one public. Run the going-public checklist (seyag:going-public) for it first; on pass set SYG_PUBLISH_CHECKED=example/one (colon-list ok; any non-empty value for a gist) (it is read from the session's environment at start: the owner restarts the session with it exported, or runs the command herself with \`!\`)."

# =============================================================================
# Unblock contract boundaries
# =============================================================================
run 2 "command-prefix assignment does NOT bypass (session env only)" "$FIX" -- \
  "SYG_PUBLISH_CHECKED=example/one gh repo edit -R example/one --visibility=public"
run 2 "env mention via echo does not bypass" "$FIX" -- \
  'echo "SYG_PUBLISH_CHECKED=example/one"; gh repo create --public'
run 0 "env export via the hook environment passes" "$FIX" \
  SYG_PUBLISH_CHECKED=example/one -- \
  "gh repo edit -R example/one --visibility=public"
run 2 "two targets, env covers only one" "$FIX" \
  SYG_PUBLISH_CHECKED=example/one -- \
  "gh repo edit -R example/one --visibility=public; gh repo edit -R other/two --visibility=public"
run 0 "two targets, env covers both (colon list)" "$FIX" \
  SYG_PUBLISH_CHECKED=example/one:other/two -- \
  "gh repo edit -R example/one --visibility=public; gh repo edit -R other/two --visibility=public"

# =============================================================================
# Reads and unrelated gh traffic pass; fd-3 transport
# =============================================================================
run 0 "gh pr view -R example/one (a read)" "$FIX" -- \
  "gh pr view 3 -R example/one"
run 0 "gh repo edit --visibility private in a notgit dir" "$NOTGIT" -- \
  "gh repo edit -R example/one --visibility private"
run 0 "word-bounded prefilter: night does not spawn python" "$FIX" -- \
  "echo night highlight"
BIG_HEREDOC=$(printf 'x%.0s' $(seq 1 140000))
run 2 "128 KiB heredoc ahead of a blocked gh call (fd-3 transport)" "$FIX" -- \
  "cat <<'BIGEOF'
$BIG_HEREDOC
BIGEOF
gh repo create --public"

# =============================================================================
# Remote lookups are memoized per hook process: many worlds in one directory
# spawn `git remote` once. A git shim on PATH logs each call whose last word
# is `remote` (the bare listing; get-url and config do not end in it). Each
# `false && X<i>=1 ;` leaves a conditional that splits the walk; the 8 of them
# give 64 worlds (the walker's cap) all in $FIX.
# =============================================================================
SHIM="$TMP/shim"; mkdir -p "$SHIM"
PROBE_REAL_GIT=$(command -v git)
export PROBE_REAL_GIT
export PROBE_REMOTE_LOG="$TMP/remote-calls.log"
cat >"$SHIM/git" <<'SHIMEOF'
#!/bin/bash
[ "$#" -gt 0 ] && [ "${!#}" = remote ] && echo remote >>"$PROBE_REMOTE_LOG"
exec "$PROBE_REAL_GIT" "$@"
SHIMEOF
chmod +x "$SHIM/git"

# many_worlds <label> <cwd> <cmd> [calls]: exit 2 and `git remote` run `calls`
# times (default 1).
many_worlds() {
  local label="$1" cwd="$2" cmd="$3" want="${4:-1}" actual calls
  : >"$PROBE_REMOTE_LOG"
  printf '%s' "$cmd" \
    | jq -Rsc --arg c "$cwd" '{tool_name:"Bash",tool_input:{command:.},cwd:$c}' \
    | env -u SYG_PUBLISH_CHECKED PATH="$SHIM:$PATH" timeout 20 "$HOOK" >"$TMP/out" 2>&1
  actual=$?
  calls=$(wc -l <"$PROBE_REMOTE_LOG" | tr -d ' ')
  if [ "$actual" -eq 2 ] && [ "$calls" -eq "$want" ]; then
    printf 'PASS  (exit 2, git remote x%s)  %s\n' "$calls" "$label"
  else
    printf 'FAIL  (exit %s, expected 2; git remote x%s, expected x%s)  %s\n' "$actual" "$calls" "$want" "$label"
    sed 's/^/      /' "$TMP/out"
    FAILURES=$((FAILURES + 1))
  fi
}
MANY=""
for i in 1 2 3 4 5 6 7 8; do MANY="${MANY}false && X$i=1 ; "; done
many_worlds "many worlds in one directory: one git remote lookup (repo edit)" "$FIX" \
  "${MANY}gh repo edit --visibility=public"
# Negative controls: the memo must not merge lookups that differ. Two
# directories in one command look up each: two calls. The same directory with
# another repo's GIT_DIR on the trigger reads a different remote list: two calls.
many_worlds "negative: two directories in one command, one lookup each" "$FIX" \
  "cd $FIX && gh repo edit --visibility=public; cd $TWO && gh repo edit --visibility=public" 2
many_worlds "negative: same directory, GIT_DIR of another repo: a second lookup" "$FIX" \
  "gh repo edit --visibility=public; GIT_DIR=$TWO/.git gh repo edit --visibility=public" 2

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "all publish-gate cases passed"
else
  echo "$FAILURES publish-gate case(s) failed"
fi

[ "$FAILURES" -eq 0 ]
