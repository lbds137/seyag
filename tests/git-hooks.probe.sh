#!/bin/bash
# Fixture check for plugins/seyag/git-hooks (the pre-push and the passthrough
# stubs), end to end: scratch repos with scratch bare remotes, the hooks dir
# as core.hooksPath through a scratch GIT_CONFIG_GLOBAL (never the real one).
#
# Purpose canary: each shape below really runs, then `git push` runs. Without
# the hook (base) every push succeeds; with it every push of a public repo is
# refused. Then: the chain to the repo's own pre-push (exit status, same
# stdin), the passthrough stubs (a repo pre-commit still runs; push-to-checkout
# keeps git's updateInstead default), fail modes, and what passes.
#
# The term is an invented word. Usage: tests/git-hooks.probe.sh (from anywhere)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS="$REPO/plugins/seyag/git-hooks"
export PYTHONDONTWRITEBYTECODE=1
PYC_BEFORE=absent
[ -e "$REPO/plugins/seyag/hooks/lib/__pycache__" ] && PYC_BEFORE=present

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" GIT_CEILING_DIRECTORIES="$TMP" GIT_CONFIG_SYSTEM=/dev/null
mkdir -p "$HOME"
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_EDITOR
printf '[user]\n\tname = probe\n\temail = probe@example.invalid\n' >"$TMP/gbase"
cp "$TMP/gbase" "$TMP/ghook"
printf '[core]\n\thooksPath = %s\n' "$HOOKS" >>"$TMP/ghook"
export GIT_CONFIG_GLOBAL="$TMP/gbase"   # fixtures; each push names its own
printf '%s\n' '# probe terms' 'zorbleflux' >"$TMP/terms"
export SYG_PRIVATE_TERMS_FILE="$TMP/terms"
ID=FIXTUREID0001  # spliced in, so this file never holds a literal link
LINK="https://claude.ai/code/session_${ID}"

fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

n=0
fresh() { # fresh [public|private] -> $R: a repo with one pushed base commit
  n=$((n + 1))
  R="$TMP/r$n"
  git init -q --bare "$R.git"
  git init -q -b main "$R"
  git -C "$R" remote add origin "$R.git"
  git -C "$R" commit -q --allow-empty -m base
  git -C "$R" push -q origin main 2>/dev/null
  [ "${1:-public}" = public ] && git -C "$R" config seyag.publicRepo true
  return 0
}

# shape <label> <push refspec> <shell body run in the repo>
# Runs the shape and its push twice: base config (expect the push to pass)
# and with the hooks dir (expect a refusal naming the block).
base_ok=0 hook_refused=0 shapes=0
shape() {
  local label=$1 ref=$2 body=$3 rc
  shapes=$((shapes + 1))
  fresh public
  (cd "$R" && GIT_CONFIG_GLOBAL="$TMP/gbase" bash -c "$body") >"$TMP/sh.out" 2>&1 \
    || { bad "[$label] base: the shape itself failed: $(tail -2 "$TMP/sh.out")"; return; }
  GIT_CONFIG_GLOBAL="$TMP/gbase" git -C "$R" push -q origin "$ref" >"$TMP/out" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then base_ok=$((base_ok + 1)); else bad "[$label] base: push rc=$rc"; fi
  fresh public
  (cd "$R" && GIT_CONFIG_GLOBAL="$TMP/ghook" bash -c "$body") >"$TMP/sh.out" 2>&1 \
    || { bad "[$label] hook: the shape itself failed: $(tail -2 "$TMP/sh.out")"; return; }
  GIT_CONFIG_GLOBAL="$TMP/ghook" git -C "$R" push -q origin "$ref" >"$TMP/out" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ] && grep -qF "seyag pre-push: blocked" "$TMP/out"; then
    hook_refused=$((hook_refused + 1))
    if grep -qF zorbleflux "$TMP/out" || grep -qF FIXTUREID "$TMP/out"; then
      bad "[$label] the refusal echoes the term or the link id"
    elif ! grep -qF "  ${WANT:-?} " "$TMP/out"; then
      bad "[$label] the refusal does not name '${WANT:-?}': $(cat "$TMP/out")"
    else
      ok "[$label] refused with the hook ($WANT), pushed without it; masked"
    fi
  else
    bad "[$label] hook: push rc=$rc: $(cat "$TMP/out")"
  fi
}

# --- purpose canary --------------------------------------------------------------
# WANT (a prefix assignment) is the kind the refusal must name.
WANT="message of" shape "commit -m TERM" main 'git commit -q --allow-empty -m "add zorbleflux"'
WANT="message of" shape "commit -F file holding TERM" main \
  'printf "zorbleflux\n" >../msg$$; git commit -q --allow-empty -F ../msg$$'
WANT="message of" shape "GIT_EDITOR sed inserts TERM" main \
  'export GIT_EDITOR="sed -i 1s/^/zorbleflux/"; git commit -q --allow-empty'
WANT="author of" shape "git -c user.name=TERM (author)" main \
  'git -c user.name=zorbleflux commit -q --allow-empty -m ok'
WANT="message of" shape "commit --template=file holding TERM, GIT_EDITOR=true" main \
  'printf "zorbleflux\n" >../tpl$$; GIT_EDITOR=true git commit -q --allow-empty --allow-empty-message --template=../tpl$$'
WANT="path of" shape "a path holding TERM" main \
  'mkdir zorbleflux && touch zorbleflux/f && git add -A && git commit -q -m ok'
WANT="added line of" shape "an added line holding TERM" main \
  'printf "plain\nsee zorbleflux\n" >doc && git add doc && git commit -q -m ok'
WANT="added line of" shape "an added line in a file whose name git C-quotes" main \
  "printf 'see zorbleflux\n' >'qu\"ote.md' && git add -A && git commit -q -m ok"
WANT="tag of" shape "annotated tag -m TERM" v1 'git tag -a v1 -m zorbleflux'
WANT="note of" shape "git notes add -m TERM" 'refs/notes/*' 'git notes add -m zorbleflux'
WANT="message of" shape "session link in a message" main "git commit -q --allow-empty -m 'see $LINK'"
WANT="committer of" shape "committer identity holding TERM" main \
  'GIT_COMMITTER_NAME=zorbleflux git commit -q --allow-empty -m ok'
WANT="added line of" shape "merge adds a TERM line of its own" main \
  'git checkout -q -b side && git commit -q --allow-empty -m s && git checkout -q main &&
   git commit -q --allow-empty -m m && git merge -q --no-commit side &&
   printf "zorbleflux\n" >evil && git add evil && git commit -q -m merge'
echo "canary: $shapes shapes; base pushed $base_ok/$shapes; hook refused $hook_refused/$shapes"
[ "$base_ok" -eq "$shapes" ] && [ "$hook_refused" -eq "$shapes" ] \
  && ok "canary counts" || bad "canary counts"

export GIT_CONFIG_GLOBAL="$TMP/ghook"

# --- what passes -------------------------------------------------------------------
fresh public
git -C "$R" commit -q --allow-empty -m "clean work"
git -C "$R" push -q origin main >"$TMP/out" 2>&1 && ok "clean push passes" || bad "clean push: $(cat "$TMP/out")"
fresh private
git -C "$R" commit -q --allow-empty -m "add zorbleflux"
git -C "$R" push -q origin main >"$TMP/out" 2>&1 && ok "a repo not marked public is not checked" \
  || bad "private repo push: $(cat "$TMP/out")"
fresh public
GIT_CONFIG_GLOBAL="$TMP/gbase" git -C "$R" commit -q --allow-empty -m "old zorbleflux"
GIT_CONFIG_GLOBAL="$TMP/gbase" git -C "$R" push -q origin main 2>/dev/null
git -C "$R" commit -q --allow-empty -m "new clean"
git -C "$R" push -q origin main >"$TMP/out" 2>&1 && ok "a commit already on the remote is not rescanned" \
  || bad "already-pushed history: $(cat "$TMP/out")"
git -C "$R" push -q origin main:refs/heads/gone 2>/dev/null
git -C "$R" push -q origin :gone >"$TMP/out" 2>&1 && ok "a delete push passes" || bad "delete push: $(cat "$TMP/out")"

git init -q --bare "$TMP/first.git"
git init -q -b main "$TMP/first"
git -C "$TMP/first" config seyag.publicRepo true
printf 'zorbleflux root\n' >"$TMP/first/root.txt"
git -C "$TMP/first" add root.txt && git -C "$TMP/first" commit -q -m root
git -C "$TMP/first" push -q "$TMP/first.git" main >"$TMP/out" 2>&1
[ $? -ne 0 ] && grep -qF "added line of" "$TMP/out" \
  && ok "first push to a URL (no remote-tracking refs): the root commit's lines are scanned" \
  || bad "first push: $(cat "$TMP/out")"

# --- objects the scan must not be fooled by -------------------------------------------
fresh public
git -C "$R" commit -q --allow-empty -m "add zorbleflux"
BADC=$(git -C "$R" rev-parse HEAD)
CLEANC=$(git -C "$R" commit-tree "$(git -C "$R" rev-parse 'HEAD^{tree}')" -p HEAD~1 -m clean </dev/null)
git -C "$R" replace "$BADC" "$CLEANC"
[ "$(git -C "$R" log -1 --format=%s)" = clean ] || bad "replace control: git log does not show the stand-in"
git -C "$R" push -q origin main >"$TMP/out" 2>&1
[ $? -ne 0 ] && grep -qF "message of" "$TMP/out" \
  && ok "a replace ref's clean stand-in does not hide the real commit" || bad "replace ref: $(cat "$TMP/out")"

fresh public
printf '* -diff\n' >"$R/.gitattributes"
printf 'see zorbleflux\n' >"$R/data.txt"
git -C "$R" add -A && git -C "$R" commit -q -m ok
git -C "$R" show HEAD -- data.txt | grep -q "^Binary files" || bad "-diff control: git does not call the file binary"
git -C "$R" push -q origin main >"$TMP/out" 2>&1
[ $? -ne 0 ] && grep -qF "added line of" "$TMP/out" \
  && ok "a file marked -diff (binary) is still read as text" || bad "-diff attribute: $(cat "$TMP/out")"

fresh public
BLOB=$(printf 'zorbleflux\n' | git -C "$R" hash-object -w --stdin)
git -C "$R" push -q origin "$BLOB:refs/heads/blobref" >"$TMP/out" 2>&1
[ $? -ne 0 ] && grep -qF "pushing a tree/blob directly is not scanned" "$TMP/out" \
  && ok "pushing a blob directly is refused" || bad "blob push: $(cat "$TMP/out")"
TREE=$(git -C "$R" rev-parse 'HEAD^{tree}')
git -C "$R" push -q origin "$TREE:refs/heads/treeref" >"$TMP/out" 2>&1
[ $? -ne 0 ] && grep -qF "is a tree" "$TMP/out" \
  && ok "pushing a tree directly is refused" || bad "tree push: $(cat "$TMP/out")"

# --- terms from git config (a push from a terminal without the env var) ---------------
fresh public
git -C "$R" commit -q --allow-empty -m "add zorbleflux"
cp "$TMP/ghook" "$TMP/gterms"
printf '[seyag]\n\tprivateTermsFile = %s\n' "$TMP/terms" >>"$TMP/gterms"
GIT_CONFIG_GLOBAL="$TMP/gterms" env -u SYG_PRIVATE_TERMS_FILE git -C "$R" push -q origin main >"$TMP/out" 2>&1
[ $? -ne 0 ] && grep -qF "private term" "$TMP/out" \
  && ok "no SYG_PRIVATE_TERMS_FILE: the terms come from the global seyag.privateTermsFile" \
  || bad "terms from git config: $(cat "$TMP/out")"
printf '# empty\n' >"$TMP/empty-terms"
git -C "$R" config seyag.privateTermsFile "$TMP/empty-terms"
GIT_CONFIG_GLOBAL="$TMP/gterms" env -u SYG_PRIVATE_TERMS_FILE git -C "$R" push -q origin main >"$TMP/out" 2>&1
[ $? -ne 0 ] && grep -qF "private term" "$TMP/out" \
  && ok "a repo-local empty terms path cannot override the global one" || bad "local override: $(cat "$TMP/out")"
git -C "$R" config seyag.privateTermsFile "$TMP/terms"
env -u SYG_PRIVATE_TERMS_FILE git -C "$R" push -q origin main >"$TMP/out" 2>&1 \
  && ok "a repo-local seyag.privateTermsFile is ignored (no global value: no term check)" \
  || bad "repo-local terms path was used: $(cat "$TMP/out")"
git -C "$R" config --unset seyag.privateTermsFile
git -C "$R" commit -q --allow-empty -m "more zorbleflux"
env -u SYG_PRIVATE_TERMS_FILE git -C "$R" push -q origin main >"$TMP/out" 2>&1 \
  && ok "control: with neither source, no term check" || bad "no terms source: $(cat "$TMP/out")"

# --- fail modes ----------------------------------------------------------------------
fresh public
git -C "$R" commit -q --allow-empty -m "add zorbleflux"
SYG_PRIVATE_TERMS_FILE="$TMP/missing" git -C "$R" push -q origin main >"$TMP/out" 2>&1 \
  && ok "missing terms file: no term check" || bad "missing terms file: $(cat "$TMP/out")"
fresh public
git -C "$R" commit -q --allow-empty -m "see $LINK"
SYG_PRIVATE_TERMS_FILE="$TMP/missing" git -C "$R" push -q origin main >"$TMP/out" 2>&1
[ $? -ne 0 ] && grep -qF "session link" "$TMP/out" && ok "missing terms file: the link check still runs" \
  || bad "missing terms file, link: $(cat "$TMP/out")"
printf '(unclosed[\n' >"$TMP/badterms"
fresh public
git -C "$R" commit -q --allow-empty -m clean
SYG_PRIVATE_TERMS_FILE="$TMP/badterms" git -C "$R" push -q origin main >"$TMP/out" 2>&1
[ $? -ne 0 ] && grep -qF "internal error" "$TMP/out" && grep -qF "line 1 is not a valid regex" "$TMP/out" \
  && ok "public repo: an internal error (invalid term line) fails closed" || bad "fail closed: $(cat "$TMP/out")"
fresh private
git -C "$R" commit -q --allow-empty -m clean
SYG_PRIVATE_TERMS_FILE="$TMP/badterms" git -C "$R" push -q origin main >"$TMP/out" 2>&1 \
  && ok "private repo: the same error does not stop the push" || bad "fail open: $(cat "$TMP/out")"

# --- chain to the repo's own pre-push -----------------------------------------------
for kind in public private; do
  fresh "$kind"
  printf '#!/bin/sh\necho own-pre-push-refuses >&2\nexit 1\n' >"$R/.git/hooks/pre-push"
  chmod +x "$R/.git/hooks/pre-push"
  git -C "$R" commit -q --allow-empty -m clean
  git -C "$R" push -q origin main >"$TMP/out" 2>&1
  [ $? -ne 0 ] && grep -qF own-pre-push-refuses "$TMP/out" \
    && ok "$kind: the repo's own failing pre-push still blocks a clean push" \
    || bad "$kind chain status: $(cat "$TMP/out")"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >"%s/args.%s"\ncat >"%s/stdin.%s"\n' \
    "$TMP" "$kind" "$TMP" "$kind" >"$R/.git/hooks/pre-push"
  old=$(git -C "$R" rev-parse origin/main)
  new=$(git -C "$R" rev-parse main)
  printf 'refs/heads/main %s refs/heads/main %s\n' "$new" "$old" >"$TMP/stdin.want"
  printf 'origin %s\n' "$R.git" >"$TMP/args.want"
  git -C "$R" push -q origin main >"$TMP/out" 2>&1 || bad "$kind: push with a recording hook failed"
  if cmp -s "$TMP/stdin.$kind" "$TMP/stdin.want" && cmp -s "$TMP/args.$kind" "$TMP/args.want"; then
    ok "$kind: the repo's own pre-push gets the same args and stdin bytes git sent"
  else
    bad "$kind: chained stdin/args differ: $(cat "$TMP/stdin.$kind" "$TMP/args.$kind")"
  fi
done

# --- the dispatcher dir install (bin/seyag-git-hooks) ------------------------------------
# The real install: a dispatcher dir as the global hooksPath. A missing plugin
# root must never silence a repo's own hooks, and must refuse public pushes.
cp "$TMP/gbase" "$TMP/gdisp"
DISP="$TMP/xdg/seyag/git-hooks"
GIT_CONFIG_GLOBAL="$TMP/gdisp" XDG_DATA_HOME="$TMP/xdg" \
  "$REPO/plugins/seyag/bin/seyag-git-hooks" install --global >"$TMP/out" 2>&1 \
  || bad "dispatcher install: $(cat "$TMP/out")"
fresh public
git -C "$R" commit -q --allow-empty -m "add zorbleflux"
GIT_CONFIG_GLOBAL="$TMP/gdisp" git -C "$R" push -q origin main >"$TMP/out" 2>&1
[ $? -ne 0 ] && grep -qF "seyag pre-push: blocked" "$TMP/out" \
  && ok "dispatcher: the plugin's pre-push runs through the stub" || bad "dispatcher pre-push: $(cat "$TMP/out")"
DPUB=$R
fresh private
DPRIV=$R
for r in "$DPUB" "$DPRIV"; do
  printf '#!/bin/sh\ntouch "%s/own-pre-commit.ran"\n' "$r" >"$r/.git/hooks/pre-commit"
  printf '#!/bin/sh\ntouch "%s/own-pre-push.ran"\n' "$r" >"$r/.git/hooks/pre-push"
  chmod +x "$r/.git/hooks/pre-commit" "$r/.git/hooks/pre-push"
done
printf '%s\n' "$TMP/moved-plugin" >"$DISP/plugin-root"   # the plugin root went away
GIT_CONFIG_GLOBAL="$TMP/gdisp" git -C "$DPRIV" commit -q --allow-empty -m clean
[ -e "$DPRIV/own-pre-commit.ran" ] && ok "plugin root missing: a repo's own pre-commit still runs" \
  || bad "plugin root missing: own pre-commit did not run"
GIT_CONFIG_GLOBAL="$TMP/gdisp" git -C "$DPRIV" push -q origin main >"$TMP/out" 2>&1
[ $? -eq 0 ] && [ -e "$DPRIV/own-pre-push.ran" ] \
  && ok "plugin root missing, private repo: its own pre-push runs, the push goes" \
  || bad "plugin root missing, private push: $(cat "$TMP/out")"
git -C "$DPUB" reset -q --hard origin/main
GIT_CONFIG_GLOBAL="$TMP/gdisp" git -C "$DPUB" commit -q --allow-empty -m clean
GIT_CONFIG_GLOBAL="$TMP/gdisp" git -C "$DPUB" push -q origin main >"$TMP/out" 2>&1
[ $? -ne 0 ] && grep -qF "the seyag pre-push hook is missing at $TMP/moved-plugin/git-hooks/pre-push; run seyag-git-hooks relink" "$TMP/out" \
  && ok "plugin root missing, public repo: the pre-push refuses, naming relink" \
  || bad "plugin root missing, public push: $(cat "$TMP/out")"
GIT_CONFIG_GLOBAL="$TMP/gdisp" XDG_DATA_HOME="$TMP/xdg" \
  "$REPO/plugins/seyag/bin/seyag-git-hooks" relink >/dev/null 2>&1
GIT_CONFIG_GLOBAL="$TMP/gdisp" git -C "$DPUB" push -q origin main >"$TMP/out" 2>&1 \
  && [ -e "$DPUB/own-pre-push.ran" ] && ok "after relink: the clean public push goes, its own pre-push ran" \
  || bad "after relink: $(cat "$TMP/out")"
# Repo hooks through the dispatcher dir (the installed path), one by one.
G=(env GIT_CONFIG_GLOBAL="$TMP/gdisp")
fresh private; DR=$R
printf '#!/bin/sh\ngrep -q fixme "$1" && exit 1; exit 0\n' >"$DR/.git/hooks/commit-msg"
chmod +x "$DR/.git/hooks/commit-msg"
"${G[@]}" git -C "$DR" commit -q --allow-empty -m fixme 2>/dev/null \
  && bad "dispatcher: commit-msg did not get its argument" || ok "dispatcher: a repo commit-msg gets its argument"
"${G[@]}" git -C "$DR" commit -q --allow-empty -m fine || bad "dispatcher: a clean message was refused"
rm "$DR/.git/hooks/commit-msg"
printf '#!/bin/sh\nexit 1\n' >"$DR/.git/hooks/pre-commit"; chmod +x "$DR/.git/hooks/pre-commit"
"${G[@]}" git -C "$DR" commit -q --allow-empty -m y 2>/dev/null \
  && bad "dispatcher: a failing pre-commit did not stop the commit" || ok "dispatcher: a failing pre-commit stops the commit"
chmod -x "$DR/.git/hooks/pre-commit"
"${G[@]}" git -C "$DR" commit -q --allow-empty -m z 2>/dev/null \
  && ok "dispatcher: a non-executable repo hook is skipped" || bad "dispatcher: a non-executable hook ran"
rm "$DR/.git/hooks/pre-commit"
printf '#!/bin/sh\necho "$#" >"%s/postco.args"\n' "$TMP" >"$DR/.git/hooks/post-checkout"
chmod +x "$DR/.git/hooks/post-checkout"
"${G[@]}" git -C "$DR" checkout -q -b other
[ "$(cat "$TMP/postco.args" 2>/dev/null)" = 3 ] && ok "dispatcher: post-checkout gets its 3 arguments" \
  || bad "dispatcher: post-checkout args: $(cat "$TMP/postco.args" 2>/dev/null)"
printf '#!/bin/sh\nexit 1\n' >"$DR/.git/hooks/reference-transaction"
chmod +x "$DR/.git/hooks/reference-transaction"
"${G[@]}" git -C "$DR" update-ref refs/heads/blocked HEAD 2>/dev/null \
  && bad "dispatcher: a failing reference-transaction did not abort update-ref" \
  || ok "dispatcher: a reference-transaction exiting 1 aborts git update-ref"
rm "$DR/.git/hooks/reference-transaction"
printf '#!/bin/sh\ncat >"%s/disp-stdin"\n' "$TMP" >"$DR/.git/hooks/pre-push"; chmod +x "$DR/.git/hooks/pre-push"
"${G[@]}" git -C "$DR" checkout -q main
"${G[@]}" git -C "$DR" commit -q --allow-empty -m pushme
printf 'refs/heads/main %s refs/heads/main %s\n' "$(git -C "$DR" rev-parse main)" \
  "$(git -C "$DR" rev-parse origin/main)" >"$TMP/disp-stdin.want"
"${G[@]}" git -C "$DR" push -q origin main 2>/dev/null
cmp -s "$TMP/disp-stdin" "$TMP/disp-stdin.want" \
  && ok "dispatcher: a private repo's own pre-push gets the pre-push stdin bytes" \
  || bad "dispatcher: pre-push stdin: $(cat "$TMP/disp-stdin" 2>/dev/null)"
# A linked worktree: its hooks live in the common dir.
printf '#!/bin/sh\ntouch "%s/wt-precommit.ran"\n' "$TMP" >"$DR/.git/hooks/pre-commit"
chmod +x "$DR/.git/hooks/pre-commit"
"${G[@]}" git -C "$DR" worktree add -q "$TMP/linked" -b linked 2>/dev/null
"${G[@]}" git -C "$TMP/linked" commit -q --allow-empty -m in-worktree
[ -e "$TMP/wt-precommit.ran" ] && ok "dispatcher: a linked worktree's commit runs the common dir's pre-commit" \
  || bad "dispatcher: linked worktree pre-commit did not run"
# A bare repo receiving a push keeps its own server-side hooks.
BARE="$TMP/served.git"; git init -q --bare "$BARE"
for h in pre-receive update post-receive; do
  printf '#!/bin/sh\ncat >/dev/null\ntouch "%s/served.%s"\n' "$TMP" "$h" >"$BARE/hooks/$h"
  chmod +x "$BARE/hooks/$h"
done
"${G[@]}" git -C "$DR" push -q "$BARE" main 2>/dev/null
[ -e "$TMP/served.pre-receive" ] && [ -e "$TMP/served.update" ] && [ -e "$TMP/served.post-receive" ] \
  && ok "dispatcher: a bare repo receiving a push runs its own pre-receive, update and post-receive" \
  || bad "dispatcher: bare repo server-side hooks: $(find "$TMP" -maxdepth 1 -name 'served.*' | wc -l) of 3 ran"
# push-to-checkout with the plugin root missing: the stub itself does updateInstead.
DEP2="$TMP/deploy2"; git init -q -b main "$DEP2"
"${G[@]}" git -C "$DEP2" commit -q --allow-empty -m base
git -C "$DEP2" config receive.denyCurrentBranch updateInstead
"${G[@]}" git clone -q "$DEP2" "$TMP/dev2" 2>/dev/null
printf 'v1\n' >"$TMP/dev2/site.txt"
"${G[@]}" git -C "$TMP/dev2" add site.txt && "${G[@]}" git -C "$TMP/dev2" commit -q -m site
cp "$DISP/plugin-root" "$TMP/plugin-root.keep"
printf '%s\n' "$TMP/moved-plugin" >"$DISP/plugin-root"
"${G[@]}" git -C "$TMP/dev2" push -q origin main >"$TMP/out" 2>&1
[ "$(cat "$DEP2/site.txt" 2>/dev/null)" = v1 ] \
  && ok "dispatcher: push-to-checkout updateInstead works with the plugin root missing" \
  || bad "dispatcher updateInstead: $(cat "$TMP/out")"
cp "$TMP/plugin-root.keep" "$DISP/plugin-root"
# An invalid seyag.publicRepo counts as public for the pre-push (fail closed).
fresh private
git -C "$R" config seyag.publicRepo maybe
"${G[@]}" git -C "$R" commit -q --allow-empty -m "add zorbleflux"
"${G[@]}" git -C "$R" push -q origin main >"$TMP/out" 2>&1
[ $? -ne 0 ] && grep -qF "seyag.publicRepo is 'maybe', not a boolean; treating the repo as public" "$TMP/out" \
  && grep -qF "seyag pre-push: blocked" "$TMP/out" \
  && ok "an invalid seyag.publicRepo counts as public, named in the message" \
  || bad "invalid publicRepo: $(cat "$TMP/out")"
# relink recreates a deleted dispatcher dir the global config still names.
mv "$DISP" "$TMP/disp-moved"
GIT_CONFIG_GLOBAL="$TMP/gdisp" XDG_DATA_HOME="$TMP/xdg" \
  "$REPO/plugins/seyag/bin/seyag-git-hooks" relink >"$TMP/out" 2>&1
fresh private
printf '#!/bin/sh\ntouch "%s/recreated.ran"\n' "$TMP" >"$R/.git/hooks/pre-commit"; chmod +x "$R/.git/hooks/pre-commit"
"${G[@]}" git -C "$R" commit -q --allow-empty -m after-recreate
[ -x "$DISP/pre-push" ] && [ -e "$TMP/recreated.ran" ] \
  && ok "relink recreates a deleted dispatcher dir, and hooks run again" \
  || bad "relink after rm: $(cat "$TMP/out")"
# Cheap path: a stub for a hook the repo lacks exits 0 at once (here every
# commit runs reference-transaction and post-commit).
fresh private
start=$(date +%s%N)
for i in 1 2 3 4 5; do GIT_CONFIG_GLOBAL="$TMP/gdisp" git -C "$R" commit -q --allow-empty -m "c$i" || bad "commit $i"; done
ms=$(( ($(date +%s%N) - start) / 1000000 ))
ok "dispatcher: 5 commits with no repo hooks ran ($ms ms; informational)"

# --- passthrough stubs ----------------------------------------------------------------
fresh public
printf '#!/bin/sh\necho "$0" >"%s/precommit.ran"\nexit 0\n' "$TMP" >"$R/.git/hooks/pre-commit"
chmod +x "$R/.git/hooks/pre-commit"
git -C "$R" commit -q --allow-empty -m x
[ -s "$TMP/precommit.ran" ] && ok "a repo's own pre-commit still runs" || bad "pre-commit did not run"
printf '#!/bin/sh\nexit 1\n' >"$R/.git/hooks/pre-commit"
git -C "$R" commit -q --allow-empty -m y 2>/dev/null \
  && bad "a failing repo pre-commit did not stop the commit" || ok "a failing repo pre-commit still stops the commit"
printf '#!/bin/sh\ngrep -q fixme "$1" && exit 1; exit 0\n' >"$R/.git/hooks/commit-msg"
chmod +x "$R/.git/hooks/commit-msg" && rm "$R/.git/hooks/pre-commit"
git -C "$R" commit -q --allow-empty -m fixme 2>/dev/null \
  && bad "commit-msg did not get its argument" || ok "a repo commit-msg gets its argument"

DEPLOY="$TMP/deploy"
git init -q -b main "$DEPLOY"
git -C "$DEPLOY" commit -q --allow-empty -m base
git -C "$DEPLOY" config receive.denyCurrentBranch updateInstead
git clone -q "$DEPLOY" "$TMP/dev" 2>/dev/null
printf 'shipped\n' >"$TMP/dev/site.txt"
git -C "$TMP/dev" add site.txt && git -C "$TMP/dev" commit -q -m site
git -C "$TMP/dev" push -q origin main >"$TMP/out" 2>&1
[ "$(cat "$DEPLOY/site.txt" 2>/dev/null)" = shipped ] \
  && ok "push-to-checkout stub keeps git's updateInstead default" || bad "updateInstead: $(cat "$TMP/out")"
# Control: a no-op push-to-checkout (what a plain exit-0 stub would be) leaves
# the deployed tree stale, so the check above can tell the two apart.
cp -R "$HOOKS" "$TMP/noop-hooks"
rm "$TMP/noop-hooks/push-to-checkout" && printf '#!/bin/sh\nexit 0\n' >"$TMP/noop-hooks/push-to-checkout"
chmod +x "$TMP/noop-hooks/push-to-checkout"
printf 'v2\n' >"$TMP/dev/site.txt" && git -C "$TMP/dev" commit -q -am v2
cp "$TMP/gbase" "$TMP/gnoop" && printf '[core]\n\thooksPath = %s\n' "$TMP/noop-hooks" >>"$TMP/gnoop"
GIT_CONFIG_GLOBAL="$TMP/gnoop" git -C "$TMP/dev" push -q origin main >/dev/null 2>&1
[ "$(cat "$DEPLOY/site.txt")" = shipped ] && ok "control: a no-op push-to-checkout leaves the tree stale" \
  || bad "control: the no-op push-to-checkout updated the tree"

for h in applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit \
  prepare-commit-msg commit-msg post-commit pre-rebase post-checkout post-merge post-rewrite \
  pre-auto-gc reference-transaction push-to-checkout sendemail-validate post-index-change \
  fsmonitor-watchman p4-changelist p4-prepare-changelist p4-post-changelist p4-pre-submit; do
  if [ -x "$HOOKS/$h" ] && [ "$(readlink -f "$HOOKS/$h")" = "$(readlink -f "$HOOKS/passthrough")" ]; then
    stubs=$((${stubs:-0} + 1))
  else
    bad "hook $h is not a passthrough stub"
  fi
done
[ "${stubs:-0}" -eq 22 ] && ok "all 22 standard client hook names but pre-push are passthrough stubs"
[ -e "$HOOKS/pre-receive" ] && bad "pre-receive (server-side) has a stub" || ok "no server-side stub"

# --- more scanned shapes and fail modes ----------------------------------------------
# A rename to a path holding the term: the content is unchanged, so only the
# path scan (--diff-filter=AR -M) can see it.
fresh public
printf 'clean\n' >"$R/clean.txt"
git -C "$R" add clean.txt && git -C "$R" commit -q -m clean && git -C "$R" push -q origin main 2>/dev/null
git -C "$R" mv clean.txt zorbleflux.txt && git -C "$R" commit -q -m ok
git -C "$R" push -q origin main >"$TMP/out" 2>&1
[ $? -ne 0 ] && grep -qF "  path of" "$TMP/out" && ! grep -qF zorbleflux "$TMP/out" \
  && ok "a rename to a path holding the term is refused (path, masked)" || bad "rename: $(cat "$TMP/out")"
# An extra commit header (encoding) holding the term.
fresh public
git -C "$R" -c i18n.commitEncoding=zorbleflux commit -q --allow-empty -m ok
git -C "$R" cat-file -p HEAD | grep -qx "encoding zorbleflux" || bad "encoding control: no encoding header"
git -C "$R" push -q origin main >"$TMP/out" 2>&1
[ $? -ne 0 ] && grep -qF "  message of" "$TMP/out" && ! grep -qF zorbleflux "$TMP/out" \
  && ok "an encoding header holding the term is refused (scanned with the message)" \
  || bad "encoding header: $(cat "$TMP/out")"
# A catastrophic term against an added line: the 5 s time box refuses.
printf '%s\n' '(a+)+$' >"$TMP/redos"
fresh public
printf 'x\n%sb\n' "$(printf 'a%.0s' {1..40})" >"$R/doc"
git -C "$R" add doc && git -C "$R" commit -q -m ok
start=$(date +%s)
SYG_PRIVATE_TERMS_FILE="$TMP/redos" timeout 60 git -C "$R" push -q origin main >"$TMP/out" 2>&1; rc=$?
secs=$(( $(date +%s) - start ))
[ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && [ "$secs" -lt 30 ] \
  && grep -qF "matching the terms took over 5 s; simplify the patterns in $TMP/redos" "$TMP/out" \
  && ok "a catastrophic term on an added line refuses with the time-box message (${secs} s)" \
  || bad "time box: rc=$rc ${secs}s $(cat "$TMP/out")"
# No python3 on PATH in a public repo: the pre-push refuses.
NOPY="$TMP/nopy"; mkdir -p "$NOPY"
for t in git readlink dirname basename mktemp cat rm; do ln -s "$(command -v "$t")" "$NOPY/$t"; done
GIT_BIN=$(command -v git)
fresh public
git -C "$R" commit -q --allow-empty -m clean
PATH="$NOPY" "$GIT_BIN" -C "$R" push -q origin main >"$TMP/out" 2>&1; rc=$?
[ "$rc" -ne 0 ] && grep -qF "python3 not found, so the private-term check cannot run; refusing the push to a public repo" "$TMP/out" \
  && ok "no python3 on PATH: a public repo's push is refused" || bad "no python3: rc=$rc $(cat "$TMP/out")"
PATH="$NOPY" "$GIT_BIN" -C "$R" -c seyag.publicRepo=false push -q origin main >"$TMP/out" 2>&1 \
  && ok "control: the same PATH pushes from a repo not marked public" || bad "no python3 control: $(cat "$TMP/out")"
# python3 -I ignores PYTHONDONTWRITEBYTECODE, so the hook must pass -B itself.
if [ "$PYC_BEFORE" = absent ] && [ -e "$REPO/plugins/seyag/hooks/lib/__pycache__" ]; then
  bad "the pre-push left a __pycache__ beside hooks/lib"
else
  ok "no __pycache__ left beside hooks/lib (was $PYC_BEFORE before the run)"
fi

[ "$fail" -eq 0 ]
