#!/bin/bash
# Fixture check for upstream-submission-guard.sh — run after ANY edit to the
# hook. Builds throwaway fixture git repos with FAKE remote URLs under a
# mktemp dir (removed on exit) and a fixture gh hosts.yml, then asserts the
# exit-code table from the spec: a gh submission that would reach a repo the
# owner doesn't own blocks (exit 2); a submission to her own repo, and every
# read, passes (exit 0).
#
# All fixture owners are neutral placeholders (`me-owner`, `other`, `third`,
# `someorg`) — no real GitHub username or org appears here.
#
# Usage: hooks/upstream-submission-guard.probe.sh   (from anywhere)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$SCRIPT_DIR/upstream-submission-guard.sh"

TMP=$(mktemp -d) || { echo "FAIL [setup]: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
# Hermetic: git must not find a repo above the fixture.
export GIT_CEILING_DIRECTORIES="$TMP"

HOSTS_DIR="$TMP/hosts"
mkdir -p "$HOSTS_DIR"
cat > "$HOSTS_DIR/hosts.yml" <<'EOF'
github.com:
    user: me-owner
    oauth_token: xxxxfaketoken
    git_protocol: https
EOF

# --- fixture repos -----------------------------------------------------------
mk_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
}

OWN="$TMP/own"
mk_repo "$OWN"
git -C "$OWN" remote add origin https://github.com/me-owner/x.git

OTHERORG="$TMP/otherorg"
mk_repo "$OTHERORG"
git -C "$OTHERORG" remote add origin https://github.com/someorg/theirrepo.git

FORK="$TMP/fork"
mk_repo "$FORK"
git -C "$FORK" remote add origin https://github.com/me-owner/x.git
git -C "$FORK" remote add upstream https://github.com/other/x.git

FORK_BASE_ORIGIN="$TMP/fork-base-origin"
mk_repo "$FORK_BASE_ORIGIN"
git -C "$FORK_BASE_ORIGIN" remote add origin https://github.com/me-owner/x.git
git -C "$FORK_BASE_ORIGIN" remote add upstream https://github.com/other/x.git
git -C "$FORK_BASE_ORIGIN" config remote.origin.gh-resolved base

FORK_BASE_UPSTREAM="$TMP/fork-base-upstream"
mk_repo "$FORK_BASE_UPSTREAM"
git -C "$FORK_BASE_UPSTREAM" remote add origin https://github.com/me-owner/x.git
git -C "$FORK_BASE_UPSTREAM" remote add upstream https://github.com/other/x.git
git -C "$FORK_BASE_UPSTREAM" config remote.upstream.gh-resolved base

FOREIGN="$TMP/foreign"
mk_repo "$FOREIGN"
git -C "$FOREIGN" remote add origin https://github.com/me-owner/x.git
git -C "$FOREIGN" remote add other-host https://git.example.org/o/x

NOTGIT="$TMP/notgit"
mkdir -p "$NOTGIT"

ALIAS="$TMP/alias-remote"
mk_repo "$ALIAS"
git -C "$ALIAS" remote add origin https://github.com/me-owner/x.git
git -C "$ALIAS" remote add upstream git@github.com-work:other/x.git

TOKENURL="$TMP/token-url"
mk_repo "$TOKENURL"
git -C "$TOKENURL" remote add origin https://github.com/me-owner/x.git
git -C "$TOKENURL" remote add other https://faketok12345:x-oauth-basic@github.com/other/x.git

SSHPORT="$TMP/ssh-port"
mk_repo "$SSHPORT"
git -C "$SSHPORT" remote add origin https://github.com/me-owner/x.git
git -C "$SSHPORT" remote add upstream ssh://git@ssh.github.com:443/other/x.git

CASEHOST="$TMP/case-host"
mk_repo "$CASEHOST"
git -C "$CASEHOST" remote add origin https://github.com/me-owner/x.git
git -C "$CASEHOST" remote add upstream https://GitHub.com/other/x.git

GHRESOLVED_LITERAL="$TMP/gh-resolved-literal"
mk_repo "$GHRESOLVED_LITERAL"
git -C "$GHRESOLVED_LITERAL" remote add origin https://github.com/me-owner/x.git
git -C "$GHRESOLVED_LITERAL" config remote.origin.gh-resolved other/x

NIXOS_FIX="$TMP/nixos-fixture"
mk_repo "$NIXOS_FIX"
git -C "$NIXOS_FIX" remote add origin https://github.com/me-owner/x.git
git -C "$NIXOS_FIX" remote add upstream https://github.com/NixOS/nixpkgs.git

BADBYTE="$TMP/bad-byte"
mk_repo "$BADBYTE"
git -C "$BADBYTE" remote add origin https://github.com/me-owner/x.git
git -C "$BADBYTE" remote add bad https://github.com/other/placeholder.git
git -C "$BADBYTE" config remote.bad.url "$(printf 'https://github.com/other/x\xffbadbyte.git')"

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
    | env -u SYG_OWN_OWNERS GH_CONFIG_DIR="$HOSTS_DIR" "${envs[@]}" \
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

# --- own repo: submissions pass ----------------------------------------------
run 0 "own origin: pr create" "$OWN" -- "gh pr create --fill"
run 0 "own origin: issue create" "$OWN" -- "gh issue create -t x -b y"

# --- non-own origin blocks ----------------------------------------------------
run 2 "someorg origin: pr create" "$OTHERORG" -- "gh pr create --fill"

# --- fork (origin own, upstream not) -----------------------------------------
run 2 "fork, no -R: pr create" "$FORK" -- "gh pr create --fill"
run 0 "fork, -R me-owner/x: pr create" "$FORK" -- "gh pr create -R me-owner/x --fill"
run 0 "fork, --repo=me-owner/x: pr create" "$FORK" -- "gh pr create --repo=me-owner/x --fill"
run 0 "fork, gh-resolved=base on origin" "$FORK_BASE_ORIGIN" -- "gh pr create --fill"
run 2 "fork, gh-resolved=base on upstream" "$FORK_BASE_UPSTREAM" -- "gh pr create --fill"

# --- explicit non-own target from an own repo --------------------------------
run 2 "own repo, -R other/x: pr create" "$OWN" -- "gh pr create -R other/x --fill"
run 2 "own repo, GH_REPO=other/x prefix" "$OWN" -- "GH_REPO=other/x gh pr create --fill"
run 2 "own repo, gh -R other/x issue create" "$OWN" -- "gh -R other/x issue create -t a -b b"

# --- bypass -------------------------------------------------------------------
run 0 "bypass matches target" "$OWN" -- \
  "SYG_UPSTREAM_CHECKED=other/x gh pr create -R other/x --fill"
run 2 "bypass value mismatched" "$OWN" -- \
  "SYG_UPSTREAM_CHECKED=nope/nope gh pr create -R other/x --fill"
run 2 "bypass quote-adjacent (does not count)" "$OWN" -- \
  "echo 'SYG_UPSTREAM_CHECKED=other/x' && gh pr create -R other/x --fill"
run 0 "SYG_ bypass matches target" "$OWN" -- \
  "SYG_UPSTREAM_CHECKED=other/x gh pr create -R other/x --fill"

# --- gh api ---------------------------------------------------------------
run 2 "gh api -X POST to other/x/issues" "$OWN" -- \
  "gh api -X POST repos/other/x/issues -f title=a"
run 2 "gh api --method=patch to other/x/issues/3" "$OWN" -- \
  "gh api --method=patch repos/other/x/issues/3 -f state=closed"
run 2 "gh api implicit POST (-f only) to other/x/issues" "$OWN" -- \
  "gh api -f title=a repos/other/x/issues"
run 0 "gh api GET to other/x/issues" "$OWN" -- \
  "gh api repos/other/x/issues"
run 0 "gh api -X POST to own me-owner/x/issues" "$OWN" -- \
  "gh api -X POST repos/me-owner/x/issues -f title=a"
run 2 "gh api {owner}/{repo} placeholder in the fork" "$FORK" -- \
  "gh api repos/{owner}/{repo}/pulls -f title=a"
run 2 "gh api leading slash, security-advisories" "$OWN" -- \
  "gh api /repos/other/x/security-advisories/reports -f summary=a"

# --- URL operand / reads -------------------------------------------------------
run 2 "gh issue comment on a github.com URL" "$OWN" -- \
  "gh issue comment https://github.com/other/x/issues/5 -b hi"
run 0 "gh pr view -R other/x (a read)" "$OWN" -- \
  "gh pr view 3 -R other/x"
run 0 "gh pr checks in the fork (a read)" "$FORK" -- \
  "gh pr checks 3"

# --- non-GitHub remote only, plus own origin ----------------------------------
run 0 "non-GitHub foreign remote ignored" "$FOREIGN" -- "gh pr create --fill"

# --- cd tracking (compounding) ------------------------------------------------
run 2 "leading cd <fork dir> && gh pr create" "$OWN" -- \
  "cd $FORK && gh pr create --fill"
run 0 "cd ~/nonexistent-literal resolves without crashing" "$OWN" \
  HOME="$TMP/fakehome" -- \
  "cd ~/nonexistent-literal && gh pr create --fill"
run 2 "chained literal cds compound (cd TMP && cd fork)" "$OWN" -- \
  "cd $TMP && cd fork && gh pr create --fill"
# A repo literally named `~other` inside OWN: with no such user bash leaves
# `~other` literal and cd enters OWN/~other, so the gh is judged there, where
# the non-own origin other/x blocks.
TILDE_DIR="$OWN/~other"
mk_repo "$TILDE_DIR"
git -C "$TILDE_DIR" remote add origin https://github.com/other/x.git
run 2 "cd ~other enters a literal OWN/~other repo (bash's fallback)" "$OWN" -- \
  "cd ~other && gh pr create --fill"

# --- own-owners source ----------------------------------------------------------
run 0 "SYG_OWN_OWNERS covers the fork's upstream owner" "$FORK" \
  SYG_OWN_OWNERS="me-owner other" -- "gh pr create --fill"
run 0 "no hosts.yml and no env: fail-open" "$NOTGIT" \
  GH_CONFIG_DIR="$TMP/no-such-dir" -- "gh pr create --fill"

# --- not a real submission shape -------------------------------------------------
run 0 "quoted mention of gh pr create" "$OWN" -- \
  'echo "gh pr create -R other/x"'
run 2 "sudo runner prefix before a blocked gh" "$OWN" -- \
  "sudo gh pr create -R other/x --fill"
run 2 "timeout 5 runner prefix before a blocked gh" "$OWN" -- \
  "timeout 5 gh pr create -R other/x --fill"

# --- fd-3 transport: a > 128 KiB heredoc in front of the gh call -------------
BIG_HEREDOC=$(printf 'x%.0s' $(seq 1 140000))
run 2 "128 KiB heredoc ahead of a blocked gh call (fd-3 transport)" "$OWN" -- \
  "cat <<'BIGEOF'
$BIG_HEREDOC
BIGEOF
gh pr create -R other/x --fill"

# =============================================================================
# Review round 1 additions
# =============================================================================

# --- item 1: -f/-F mean --fill/--body-file for pr/issue, not field flags ----
run 2 "pr create -f -R other/x: -f is --fill, not a field flag" "$OWN" -- \
  "gh pr create -f -R other/x"

# --- item 2: attached -R/-X forms --------------------------------------------
run 2 "attached -Rother/x" "$OWN" -- "gh pr create -Rother/x --fill"
run 2 "attached -R=other/x" "$OWN" -- "gh pr create -R=other/x --fill"
run 2 "gh -Rother/x issue create" "$OWN" -- "gh -Rother/x issue create -t a -b b"
run 2 "gh api --field=k=v implicit POST" "$OWN" -- \
  "gh api repos/other/x/issues --field=k=v"
run 2 "gh api --raw-field=k=v implicit POST" "$OWN" -- \
  "gh api repos/other/x/issues --raw-field=k=v"
run 2 "gh api -ftitle=a implicit POST (attached)" "$OWN" -- \
  "gh api repos/other/x/issues -ftitle=a"
run 2 "gh api --input=file implicit POST" "$OWN" -- \
  "gh api repos/other/x/issues --input=file"
run 2 "gh api -XPOST attached method" "$OWN" -- \
  "gh api -XPOST repos/other/x/issues"

# --- item 3: gh api value flags that must skip their value word -------------
run 2 "gh api -q .id (value flag) then -f title=a" "$OWN" -- \
  "gh api -q .id repos/other/x/issues -f title=a"

# --- item 4: pr new / issue new aliases --------------------------------------
run 2 "gh pr new === create" "$OWN" -- "gh pr new -R other/x --fill"
run 2 "gh issue new === create" "$OWN" -- "gh issue new -R other/x -t a -b b"

# --- item 5: pr/issue close WITH a comment is a submission; api commits/comments
run 2 "gh pr close -c is a submission" "$OWN" -- \
  "gh pr close 3 -c done -R other/x"
run 2 "gh issue close --comment is a submission" "$OWN" -- \
  "gh issue close 3 --comment done -R other/x"
run 0 "gh pr close (bare, no comment) in the fork" "$FORK" -- "gh pr close 3"
run 2 "gh api commits/SHA/comments endpoint" "$OWN" -- \
  "gh api -X POST repos/other/x/commits/abc123/comments -f body=hi"

# --- item 6: gh api literal endpoint wins over GH_REPO -----------------------
run 2 "gh api literal endpoint beats GH_REPO" "$OWN" -- \
  "GH_REPO=me-owner/x gh api -X POST repos/other/x/issues -f a=b"

# --- item 7: URL scan across every operand; -R/GH_REPO and URL both targets -
run 2 "pr edit --add-label bug <url> (url anywhere in operands)" "$OWN" -- \
  "gh pr edit --add-label bug https://github.com/other/x/pull/5"
run 2 "pr comment <url> -R me-owner/x: BOTH are targets, url is non-own" "$OWN" -- \
  "gh pr comment https://github.com/other/x/pull/5 -R me-owner/x -b hi"

# --- item 8: export GH_REPO earlier in the same command text ----------------
run 2 "export GH_REPO=other/x && gh pr create in own repo" "$OWN" -- \
  "export GH_REPO=other/x && gh pr create --fill"

# --- item 9: chained cds compound (own case above); already added above -----

# --- item 10: remote parsing robustness --------------------------------------
run 2 "alias remote (git@github.com-work:o/r)" "$ALIAS" -- "gh pr create --fill"
run 2 "userinfo/token stripped from a remote URL" "$TOKENURL" -- "gh pr create --fill"
run 2 "ssh port form (ssh://git@ssh.github.com:443/...)" "$SSHPORT" -- "gh pr create --fill"
run 2 "GitHub.com host (case-insensitive)" "$CASEHOST" -- "gh pr create --fill"
run 2 "gh-resolved=other/x literal (not base) on origin" "$GHRESOLVED_LITERAL" -- \
  "gh pr create --fill"

# --- item 11: SYG_OWN_OWNERS unions with hosts.yml; case-insensitive both
run 0 "case-insensitive bypass matches mixed-case remote owner" "$NIXOS_FIX" -- \
  "SYG_UPSTREAM_CHECKED=NixOS/nixpkgs gh pr create --fill"
run 2 "SYG_OWN_OWNERS=\",\" parses empty, falls back to hosts.yml" "$FORK" \
  SYG_OWN_OWNERS="," -- "gh pr create --fill"

# --- item 12: bypass read ONLY from the gh command's own prefix --------------
run 0 "bypass value as a quoted argv word" "$OWN" -- \
  'SYG_UPSTREAM_CHECKED="other/x" gh pr create -R other/x'
run 2 "mention via echo, then ; gh — does not bypass" "$OWN" -- \
  'echo " SYG_UPSTREAM_CHECKED=other/x "; gh pr create -R other/x'
run 2 "assignment prefixes a DIFFERENT command (true), not gh" "$OWN" -- \
  "SYG_UPSTREAM_CHECKED=other/x true; gh pr create -R other/x"
run 2 "bypass mention inside a heredoc body does not count" "$OWN" -- \
  "cat <<'HDEOF'
SYG_UPSTREAM_CHECKED=other/x
HDEOF
gh pr create -R other/x --fill"
run 0 "two different non-own targets, two bypass assignments" "$OWN" -- \
  "SYG_UPSTREAM_CHECKED=other/x SYG_UPSTREAM_CHECKED=third/z gh pr comment https://github.com/third/z/pull/1 -R other/x -b hi"
run 2 "two different non-own targets, only one bypassed" "$OWN" -- \
  "SYG_UPSTREAM_CHECKED=other/x gh pr comment https://github.com/third/z/pull/1 -R other/x -b hi"

# --- item 13: robustness on a non-UTF-8 byte in a remote URL -----------------
# The byte decodes (via errors="replace") to a garbled but still non-own repo
# name ("other/x<U+FFFD>badbyte"), so this correctly still BLOCKS — the
# behavior under test is "no crash, no traceback", asserted separately below.
run 2 "non-UTF-8 byte in a remote URL: decodes without crashing" \
  "$BADBYTE" -- "gh pr create --fill"

# --- item 14: word-bounded prefilter -----------------------------------------
run 0 "ls ~/Projects/the-night-house does not spawn python" "$OWN" -- \
  "ls ~/Projects/the-night-house"

# =============================================================================
# Review round 2 additions: per-subcommand flag tables, reopen -c, attached
# -c, api query strings
# =============================================================================
U2=https://github.com/other/x/pull/3
run 2 "pr review -a is a boolean (--approve), URL still scanned" "$OWN" -- \
  "gh pr review -a $U2"
run 2 "pr review -r is a boolean (--request-changes)" "$OWN" -- \
  "gh pr review -r $U2 -b no"
run 2 "pr review -c is a boolean (--comment)" "$OWN" -- \
  "gh pr review -c $U2 -b hi"
run 2 "issue close attached -cbye" "$OWN" -- \
  "gh issue close https://github.com/other/x/issues/5 -cbye"
run 2 "pr close attached -c=bye" "$OWN" -- \
  "gh pr close $U2 -c=bye"
run 2 "issue reopen -c posts a comment" "$OWN" -- \
  "gh issue reopen https://github.com/other/x/issues/5 -c back"
run 2 "pr reopen --comment posts a comment" "$OWN" -- \
  "gh pr reopen $U2 --comment back"
run 2 "gh api endpoint with a query string" "$OWN" -- \
  "gh api -X POST 'repos/other/x/issues?foo=1' -f title=a"
run 0 "control: pr review 3 -a in an own repo" "$OWN" -- \
  "gh pr review 3 -a"
run 0 "control: pr create -a/-r still consume values in an own repo" "$OWN" -- \
  "gh pr create -a someone -r other --fill"
run 0 "control: bare issue reopen (no comment)" "$OWN" -- \
  "gh issue reopen https://github.com/other/x/issues/5"

# =============================================================================
# Review round 3 additions: every review-c/cases4.sh shape (owner names
# swapped for the fixture's), plus message pins
# =============================================================================
mkdir -p "$FORK/sub"
NL=$'\n'

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

# --- substitution / capture shapes -------------------------------------------
run 2 "r3: heredoc body in quoted subst" "$OWN" -- \
  "gh pr create -R other/x --title t --body \"\$(cat <<'EOF'${NL}Body line${NL}EOF${NL})\""
run 2 "r3: heredoc body, fork, no -R" "$FORK" -- \
  "gh pr create --title t --body \"\$(cat <<'EOF'${NL}Body${NL}EOF${NL})\""
run 0 "r3: heredoc body, own" "$OWN" -- \
  "gh pr create --title t --body \"\$(cat <<'EOF'${NL}Body${NL}EOF${NL})\""
# A heredoc body is data unless a shell runs it (a script written to disk).
run 0 "r4: script written via heredoc, unverifiable -R in body" "$OWN" -- \
  "cat > x.sh <<'EOF'${NL}url=\$(gh pr create -R \"\$R\" --fill)${NL}EOF"
run 0 "r4: script written via heredoc, non-own -R in body" "$OWN" -- \
  "cat > x.sh <<'EOF'${NL}url=\$(gh pr create -R other/x --fill)${NL}EOF"
run 0 "r4: backtick mention in a commit-message heredoc" "$OWN" -- \
  "git commit -m \"\$(cat <<'EOF'${NL}\`gh pr comment https://github.com/other/x/pull/3\`${NL}EOF${NL})\""
run 0 "r4: \$(gh …) mention in a PR-body heredoc" "$OWN" -- \
  "gh pr create -R me-owner/x --body \"\$(cat <<'EOF'${NL}Mentions \$(gh pr create -R other/x) here${NL}EOF${NL})\""
run 2 "r4: heredoc piped into bash runs" "$OWN" -- \
  "cat <<'EOF' | bash${NL}url=\$(gh pr create -R other/x --fill)${NL}EOF"
run 2 "r4: bash reading a heredoc runs" "$OWN" -- \
  "bash <<'EOF'${NL}gh pr create -R other/x --fill${NL}EOF"
run 2 "r4: real substitution after a heredoc still blocks" "$OWN" -- \
  "cat > x.sh <<'EOF'${NL}inert${NL}EOF${NL}url=\"\$(gh pr create -R other/x --fill)\""
run 2 "r3: unquoted assign capture" "$OWN" -- 'PR=$(gh pr create -R other/x --fill)'
run 2 "r3: quoted assign capture" "$OWN" -- 'url="$(gh pr create -R other/x --fill)"'
run 2 "r3: backtick capture" "$OWN" -- 'x=`gh pr create -R other/x --fill`'
run 2 "r3: echo quoted subst" "$OWN" -- 'echo "$(gh pr create -R other/x --fill)"'
run 2 "r3: eval string" "$OWN" -- 'eval "gh pr create -R other/x --fill"'
run 0 "r3: unquoted capture, then cd into the fork (in order)" "$OWN" -- \
  'PR=$(gh pr create --fill); cd ../fork'
run 2 "r3: cd inside a quoted substitution applies within it" "$OWN" -- \
  'echo "$(cd ../fork && gh pr create --fill)"'
run 0 "r3: cd inside a substitution doesn't leak out" "$OWN" -- \
  'echo "$(cd ../fork)"; gh pr create --fill'
# A substitution inside nested `bash -c` strings: two wrappers walk it inline
# below MAX_WRAPPER_DEPTH (control); three put it at the cap, where it is
# judged through the leftover replay.
run 2 "substitution under two bash -c wrappers, cd fork (below-cap control)" "$OWN" -- \
  'bash -c "bash -c \"echo \\\"\\\$(cd ../fork; gh pr create --fill)\\\"\""'
run 2 "substitution under three bash -c wrappers (at the cap), cd fork" "$OWN" -- \
  'bash -c "bash -c \"bash -c \\\"echo \\\\\\\"\\\\\\\$(cd ../fork; gh pr create --fill)\\\\\\\"\\\"\""'

# --- URL operand spellings gh accepts ----------------------------------------
run 2 "r3: http://www. URL" "$OWN" -- "gh pr comment http://www.github.com/other/x/pull/3 -b hi"
run 2 "r3: GitHub.com URL" "$OWN" -- "gh pr comment https://GitHub.com/other/x/pull/3 -b hi"
run 2 "r3: www issue URL" "$OWN" -- "gh issue comment https://www.github.com/other/x/issues/5 -b hi"

# --- -R spellings gh accepts, and unverifiable values ------------------------
run 2 "r3: -R ssh:// URL" "$OWN" -- "gh pr create -R ssh://git@github.com/other/x --fill"
run 0 "r3: -R scp form own" "$OWN" -- "gh pr create -R git@github.com:me-owner/x.git --fill"
run 2 "r3: -R scp form other" "$OWN" -- "gh pr create -R git@github.com:other/x.git --fill"
run 0 "r3: -R HOST/OWNER/REPO own" "$OWN" -- "gh pr create -R github.com/me-owner/x --fill"
run 2 "r3: -R \"\$REPO\" is unverifiable (no fallback to own remotes)" "$OWN" -- \
  'gh pr create -R "$REPO" --fill'
assert_out "r3: unverifiable -R names the fix" present \
  "re-run with the literal owner/repo so it can be judged"
run 2 "r3: -R \"\$OWNER/x\" is unverifiable, not owner \$OWNER" "$OWN" -- \
  'gh pr create -R "$OWNER/x" --fill'
assert_out "r3: unverifiable -R never displays \$OWNER as an owner" absent '$OWNER'
run 2 "r3: -R that doesn't parse is unverifiable" "$OWN" -- "gh pr create -R a/b/c/d --fill"
run 2 "r3: GH_REPO=\$(…) prefix is unverifiable" "$OWN" -- \
  'GH_REPO="$(cat f)" gh pr create --fill'
run 0 "r3: empty -R \"\" is unset (own remotes)" "$OWN" -- 'gh pr create -R "" --fill'

# --- api -----------------------------------------------------------------------
run 2 "r3: mixed placeholder repos/other/{repo}" "$OWN" -- \
  "gh api -X POST 'repos/other/{repo}/issues' -f title=a"
run 2 "r3: commit comment edit repos/o/r/comments/ID" "$OWN" -- \
  "gh api -X PATCH repos/other/x/comments/9 -f body=a"
run 2 "r3: api -X after endpoint" "$OWN" -- "gh api repos/other/x/issues -X POST"
run 2 "r3: api query + implicit POST" "$OWN" -- "gh api 'repos/other/x/issues?a=b' -f x=y"
run 0 "r3: api GET with -H value -f" "$OWN" -- "gh api repos/other/x/issues -H 'X: -f'"
run 2 "r3: api --input=-" "$OWN" -- "gh api repos/other/x/issues --input=- <<<'{}'"

# --- cd / dir forms --------------------------------------------------------------
run 0 "r3: bash -c gh then outer cd, cwd own (control)" "$OWN" -- \
  "bash -c 'gh pr create --fill'; cd ../fork"
run 2 "r3: bash -c gh then outer cd, cwd fork" "$FORK" -- \
  "bash -c 'gh pr create --fill'; cd ../own"
run 2 "r3: pushd fork" "$OWN" -- "pushd ../fork && gh pr create --fill"
run 0 "r3: pushd fork, popd back" "$OWN" -- "pushd ../fork && popd && gh pr create --fill"
run 0 "r3: cd -, back to the first dir" "$OWN" -- "cd ../fork && cd - && gh pr create --fill"
run 2 "r3: bare cd goes to HOME" "$OWN" HOME="$FORK" -- "cd && gh pr create --fill"
run 2 "r3: cd -P fork" "$OWN" -- "cd -P ../fork && gh pr create --fill"
run 2 "r3: cd -- fork" "$OWN" -- "cd -- ../fork && gh pr create --fill"
run 2 "r3: builtin cd fork" "$OWN" -- "builtin cd ../fork && gh pr create --fill"
run 2 "r3: cwd subdir of fork" "$FORK/sub" -- "gh pr create --fill"
run 2 "r3: cd fork newline" "$OWN" -- "cd ../fork${NL}gh pr create --fill"
run 0 "r3: gh then cd fork" "$OWN" -- "gh pr create --fill; cd ../fork"
run 2 "r3: GIT_DIR prefix" "$OWN" -- "GIT_DIR=../fork/.git gh pr create --fill"
run 2 "r3: exported GIT_DIR" "$OWN" -- "export GIT_DIR=../fork/.git; gh pr create --fill"

# --- env / GH_REPO ---------------------------------------------------------------
run 2 "r3: declare -x GH_REPO" "$OWN" -- "declare -x GH_REPO=other/x; gh pr create --fill"
run 2 "r3: typeset -x GH_REPO" "$OWN" -- "typeset -x GH_REPO=other/x; gh pr create --fill"
run 0 "r3: export then unset GH_REPO" "$OWN" -- \
  "export GH_REPO=other/x; unset GH_REPO; gh pr create --fill"
run 0 "r3: export then unset -v GH_REPO" "$OWN" -- \
  "export GH_REPO=other/x; unset -v GH_REPO; gh pr create --fill"
run 2 "r3: -R twice, last other" "$OWN" -- "gh pr create --repo=me-owner/x -R other/x --fill"
run 0 "r3: -R twice, last own" "$OWN" -- "gh pr create -R other/x --repo=me-owner/x --fill"

# --- over-block controls (own repo traffic) --------------------------------------
run 0 "r3: comment body with foreign URL" "$OWN" -- \
  "gh pr comment 3 -b 'see https://github.com/other/x/pull/5'"
run 0 "r3: comment --body= foreign URL" "$OWN" -- \
  "gh pr comment 3 --body=https://github.com/other/x/pull/5"
run 0 "r3: close -c foreign URL" "$OWN" -- \
  "gh issue close 5 -c 'dup of https://github.com/other/x/issues/2'"
run 0 "r3: review -b foreign URL" "$OWN" -- \
  "gh pr review 3 --approve -b 'like https://github.com/other/x/pull/9'"
run 0 "r3: create -b foreign URL" "$OWN" -- \
  "gh pr create --fill -b 'Fixes https://github.com/other/x/issues/1'"
run 0 "r3: issue create title mentions gh" "$OWN" -- \
  "gh issue create --title 'gh pr create -R other/x' -b b"
run 0 "r3: pr create -H other:branch" "$OWN" -- "gh pr create -H other:branch --fill"
run 0 "r3: echo mention" "$OWN" -- "echo gh pr create -R other/x"
run 0 "r3: single-quoted \$(gh …) mention is inert" "$OWN" -- \
  "gh pr create --fill --body 'Mentions \$(gh pr create -R other/x) here'"

# --- wrappers --------------------------------------------------------------------
run 2 "r3: if gh" "$OWN" -- "if gh pr create -R other/x --fill; then echo ok; fi"
run 2 "r3: nohup &" "$OWN" -- "nohup gh pr create -R other/x --fill &"
run 2 "r3: env -i" "$OWN" -- "env -i PATH=/usr/bin gh pr create -R other/x --fill"
run 2 "r3: command gh" "$OWN" -- "command gh pr create -R other/x --fill"
run 2 "r3: quoted program" "$OWN" -- '"gh" pr create -R other/x --fill'
run 2 "r3: for loop var -R" "$OWN" -- \
  'for r in other/x; do gh pr create -R "$r" --fill; done'
run 2 "r3: sh -c nested bash -c" "$OWN" -- \
  "sh -c \"bash -c 'gh pr create -R other/x --fill'\""

# --- token and message pins --------------------------------------------------------
run 2 "r3: token remote blocks" "$TOKENURL" -- "gh pr create --fill"
assert_out "r3: remote token appears nowhere in the output" absent "faketok12345"
run 2 "r3: banner pin case" "$OWN" -- "gh pr create -R other/x --fill"
assert_out "r3: banner first line" first-line \
  "UPSTREAM SUBMISSION GUARD — gh pr create would reach a repo the owner doesn't own: other/x"
assert_out "r3: bypass line" present "    SYG_UPSTREAM_CHECKED=other/x gh …"
assert_out "r3: AI-stance line" present \
  "- Hostile to AI contributions: don't submit. Tell the owner it was skipped"
assert_out "r3: fork hint" present "-R <your-owner>/<repo> (or run \`gh repo set-default\`)"

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "all upstream-submission-guard cases passed"
else
  echo "$FAILURES upstream-submission-guard case(s) failed"
fi

# --- traceback check on the non-UTF-8 byte case (item 13) -------------------
printf '%s' "gh pr create --fill" \
  | jq -Rsc --arg c "$BADBYTE" '{tool_name:"Bash",tool_input:{command:.},cwd:$c}' \
  | env -u SYG_OWN_OWNERS GH_CONFIG_DIR="$HOSTS_DIR" timeout 20 "$HOOK" \
    >"$TMP/out" 2>&1
if grep -q "Traceback" "$TMP/out"; then
  echo "FAIL  non-UTF-8 byte case leaked a python traceback"
  sed 's/^/      /' "$TMP/out"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS  non-UTF-8 byte case: no traceback in output"
fi

[ "$FAILURES" -eq 0 ]
