#!/bin/bash
# Fixture check for bin/seyag-git-hooks: status, install --global and relink
# against a scratch HOME, XDG_DATA_HOME and GIT_CONFIG_GLOBAL (never the real
# global config), the dispatcher dir it writes, and the CLI contract (help
# before any side effect, unknown argument -> exit 2).
# Usage: tests/seyag-git-hooks.probe.sh   (from anywhere)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO/plugins/seyag/bin/seyag-git-hooks"
HOOKS=$(cd "$REPO/plugins/seyag/git-hooks" && pwd -P)
ROOT=$(dirname "$HOOKS")
export PYTHONDONTWRITEBYTECODE=1

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" GIT_CEILING_DIRECTORIES="$TMP" GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" XDG_DATA_HOME="$TMP/xdg"
unset SYG_PRIVATE_TERMS_FILE
STABLE="$TMP/xdg/seyag/git-hooks"
mkdir -p "$HOME"
: >"$GIT_CONFIG_GLOBAL"

fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }
has() { grep -qF -- "$2" "$TMP/out" && ok "$1" || { bad "$1 (wanted '$2')"; sed 's/^/      /' "$TMP/out"; }; }

git init -q "$TMP/acme"
git init -q "$TMP/husky"
git -C "$TMP/husky" config core.hooksPath .husky/_

# --- CLI contract ----------------------------------------------------------------
"$BIN" --help >"$TMP/out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && has "--help prints usage" "Usage:" || bad "--help rc=$rc"
"$BIN" install --global -h >"$TMP/out" 2>&1
[ -z "$(git config --global --get core.hooksPath)" ] && [ ! -e "$STABLE" ] \
  && ok "-h after install --global: no side effect" || bad "-h after install --global installed"
"$BIN" bogus 2>"$TMP/out" >/dev/null; rc=$?
[ "$rc" -eq 2 ] && has "unknown argument: usage on stderr" "Usage:" || bad "unknown argument rc=$rc"
"$BIN" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "no argument -> exit 2" || bad "no argument rc=$rc"
"$BIN" install >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && [ -z "$(git config --global --get core.hooksPath)" ] \
  && ok "install without --global -> exit 2, nothing set" || bad "install without --global rc=$rc"
"$BIN" status "$TMP/acme" extra >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "status with two operands -> exit 2" || bad "status extra operand rc=$rc"

# --- status before install -----------------------------------------------------------
(cd "$TMP/acme" && "$BIN" status) >"$TMP/out" 2>&1
has "status names the hooks dir" "hooks dir: $HOOKS"
has "status: no dispatcher dir" "dispatcher dir: $STABLE (absent)"
has "status: not installed" "global core.hooksPath: (unset) -> not installed"
has "status: default repo is the cwd, not active" "seyag pre-push ACTIVE: no"
has "status: no terms source" "terms file: none"
"$BIN" relink >"$TMP/out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$TMP/out" ] && [ ! -e "$STABLE" ] \
  && ok "relink when not installed: silent no-op" || bad "relink, not installed: rc=$rc $(cat "$TMP/out")"
XDG_DATA_HOME=relative/dir "$BIN" status "$TMP/acme" >"$TMP/out" 2>&1
has "a relative XDG_DATA_HOME falls back to ~/.local/share" "dispatcher dir: $HOME/.local/share/seyag/git-hooks"

# --- install ------------------------------------------------------------------------
mkdir -p "$STABLE" && printf 'hand-made\n' >"$STABLE/pre-push"
"$BIN" install --global >"$TMP/out" 2>&1; rc=$?
[ "$rc" -eq 1 ] && [ -z "$(git config --global --get core.hooksPath)" ] \
  && has "install refuses a dir it did not write" "is not a dispatcher dir" \
  || bad "install over a hand-made dir rc=$rc"
"$BIN" relink >"$TMP/out" 2>&1
[ "$(cat "$STABLE/pre-push")" = hand-made ] && [ ! -s "$TMP/out" ] \
  && ok "relink leaves a hand-made dir alone" || bad "relink touched a hand-made dir"
rm "$STABLE/pre-push" && rmdir "$STABLE"
SYG_PRIVATE_TERMS_FILE="$TMP/terms.txt" "$BIN" install --global >"$TMP/out" 2>&1 \
  || bad "install --global failed: $(cat "$TMP/out")"
[ "$(git config --global --get core.hooksPath)" = "$STABLE" ] \
  && ok "install --global sets core.hooksPath to the dispatcher dir" || bad "install did not set the dir"
[ -f "$STABLE/.seyag-git-hooks" ] && [ "$(cat "$STABLE/plugin-root")" = "$ROOT" ] \
  && ok "the dispatcher dir holds the marker and plugin-root" || bad "dispatcher dir contents"
n=0; for f in "$HOOKS"/*; do
  name=${f##*/}; [ "$name" = passthrough ] && continue
  [ -x "$STABLE/$name" ] && [ ! -L "$STABLE/$name" ] && n=$((n + 1)) || bad "no stub for $name"
done
[ "$n" -eq 23 ] && ok "one executable stub per hook name (23), no symlinks" || bad "stub count $n"
for name in pre-receive update post-receive post-update proc-receive; do
  [ -x "$STABLE/$name" ] || bad "no server-side stub for $name"
done
ok "server-side stubs: pre-receive, update, post-receive, post-update, proc-receive"
for f in "$STABLE"/*; do
  [ "${f##*/}" = plugin-root ] && continue
  head -1 "$f" | grep -qx '#!/bin/sh' && sh -n "$f" || bad "stub ${f##*/}: not a parseable /bin/sh script"
done
ok "every stub is #!/bin/sh and passes sh -n"
[ -f "$STABLE/.stamp" ] && ok "install writes the stamp" || bad "no stamp"
[ "$(git config --global --get seyag.privateTermsFile)" = "$TMP/terms.txt" ] \
  && ok "install records SYG_PRIVATE_TERMS_FILE as the global seyag.privateTermsFile" || bad "terms path not recorded"
"$BIN" install --global >"$TMP/out" 2>&1 && has "install again: a no-op" "already points at"
"$BIN" status "$TMP/acme" >"$TMP/out" 2>&1
has "status: installed" "-> points at the seyag dispatcher dir"
has "status: the dispatcher dir and its root" "dispatcher dir: $STABLE (plugin root $ROOT)"
has "status: terms from the global config" "terms file: $TMP/terms.txt (from the global git config seyag.privateTermsFile)"
has "status: active in a plain repo (through the dispatcher)" "seyag pre-push ACTIVE: yes"
git -C "$TMP/acme" config seyag.privateTermsFile /tmp/empty
"$BIN" status "$TMP/acme" >"$TMP/out" 2>&1
has "status warns about a repo-local terms path" "warning: the repo-local seyag.privateTermsFile (/tmp/empty) is ignored"
has "status still uses the global terms path" "terms file: $TMP/terms.txt (from the global"
git -C "$TMP/acme" config --unset seyag.privateTermsFile
SYG_PRIVATE_TERMS_FILE=/x/env-terms "$BIN" status "$TMP/acme" >"$TMP/out" 2>&1
has "status: the env var wins over git config" "terms file: /x/env-terms (from SYG_PRIVATE_TERMS_FILE)"
"$BIN" status "$TMP/acme" >"$TMP/out" 2>&1
has "status: not public" "marked public (seyag.publicRepo): no"
has "status: active but not enforcing in a repo not marked public" "pre-push ENFORCES here: no"
git -C "$TMP/acme" config seyag.publicRepo true
"$BIN" status "$TMP/acme" >"$TMP/out" 2>&1
has "status: enforcing in a public repo" "pre-push ENFORCES here: yes"
for value in 'push --no-verify' '!HOME=/tmp/x git push' '!env -i git push' '-c core.hooksPath=/x push' \
  '!GIT_CONFIG_GLOBAL=/x git push'; do
  git -C "$TMP/acme" config alias.yeet "$value"
  "$BIN" status "$TMP/acme" >"$TMP/out" 2>&1
  if grep -qF "alias that skips the hook: alias.yeet" "$TMP/out" && grep -qF "ENFORCES here: no" "$TMP/out"; then
    ok "status: an alias '$value' skips the hook, not enforcing"
  else
    bad "alias '$value' not flagged"; sed 's/^/      /' "$TMP/out"
  fi
done
for value in '!env -u HOME git push' '!env --unset=HOME git push' '!env --ignore-environment git push' \
  '!env - git push' '!env --unset HOME git push' $'!env\t-u HOME git push' '!env --uns=HOME git push'; do
  git -C "$TMP/acme" config alias.yeet "$value"
  "$BIN" status "$TMP/acme" >"$TMP/out" 2>&1
  if grep -qF "alias that skips the hook: alias.yeet" "$TMP/out" && grep -qF "ENFORCES here: no" "$TMP/out"; then
    ok "status: an alias '${value//$'\t'/<TAB>}' (an env shape the guards block on a push) skips the hook, not enforcing"
  else
    bad "alias '$value' not flagged"; sed 's/^/      /' "$TMP/out"
  fi
done
git -C "$TMP/acme" config alias.yeet '!XDG_CONFIG_HOME=/x git push'
"$BIN" status "$TMP/acme" >"$TMP/out" 2>&1
if grep -qF "alias that skips the hook: alias.yeet" "$TMP/out" && grep -qF "ENFORCES here: no" "$TMP/out"; then
  ok "status: an alias '!XDG_CONFIG_HOME=/x git push' skips the hook (pins existing behaviour: matched by 'home=')"
else
  bad "alias '!XDG_CONFIG_HOME=/x git push' not flagged"; sed 's/^/      /' "$TMP/out"
fi
git -C "$TMP/acme" config seyag.publicRepo yesplz
"$BIN" status "$TMP/acme" >"$TMP/out" 2>&1
has "status: an invalid seyag.publicRepo counts as public (fail closed)" "marked public (seyag.publicRepo): yes"
git -C "$TMP/acme" config seyag.publicRepo true
git -C "$TMP/acme" config alias.yeet 'log --oneline'
"$BIN" status "$TMP/acme" >"$TMP/out" 2>&1
has "status: a harmless alias leaves it enforcing" "pre-push ENFORCES here: yes"
git -C "$TMP/acme" config --unset alias.yeet
"$BIN" status "$TMP/husky" >"$TMP/out" 2>&1
has "status: a repo-local hooksPath shows its scope" "core.hooksPath .husky/_ (local)"
has "status: a repo-local hooksPath overrides the global install" "seyag pre-push ACTIVE: no"
"$BIN" status "$TMP" >"$TMP/out" 2>&1
has "status of a non-repo" "not a git repository"
printf 'repos: []\n' >"$TMP/acme/.pre-commit-config.yaml"
printf '*.bin filter=lfs diff=lfs merge=lfs -text\n' >"$TMP/acme/.gitattributes"
"$BIN" status "$TMP/acme" >"$TMP/out" 2>&1
has "status warns about the pre-commit framework" "uses the pre-commit framework"
has "status warns about git-lfs" "uses git-lfs"
rm "$TMP/acme/.pre-commit-config.yaml" "$TMP/acme/.gitattributes"
"$BIN" status "$TMP/acme" >"$TMP/out" 2>&1
grep -q "^warning: this repo uses" "$TMP/out" && bad "warnings without the files" || ok "no tool warnings without the files"

# --- the dir the global config names wins over XDG_DATA_HOME (install only) ------------
XDG_DATA_HOME="$TMP/elsewhere" "$BIN" status "$TMP/acme" >"$TMP/out" 2>&1
has "status uses the dir the global core.hooksPath names" "dispatcher dir: $STABLE (plugin root"
printf '%s\n' "$TMP/old-plugin" >"$STABLE/plugin-root"
XDG_DATA_HOME="$TMP/elsewhere" "$BIN" relink >"$TMP/out" 2>&1
[ "$(cat "$STABLE/plugin-root")" = "$ROOT" ] && [ ! -e "$TMP/elsewhere" ] \
  && ok "relink acts on the dir the global config names, not XDG_DATA_HOME" || bad "relink E8: $(cat "$TMP/out")"

# --- relink recreates the install path the global config still names -------------------
mv "$STABLE" "$TMP/stable-moved"
"$BIN" relink >"$TMP/out" 2>&1
[ -x "$STABLE/pre-push" ] && [ -f "$STABLE/.seyag-git-hooks" ] && has "relink recreates a deleted dispatcher dir" "relinked $STABLE" \
  || bad "relink after rm: $(cat "$TMP/out")"

# --- relink after a plugin update, and a broken plugin root ----------------------------
printf '%s\n' "$TMP/old-plugin" >"$STABLE/plugin-root"
"$BIN" relink >"$TMP/out" 2>&1
[ "$(cat "$STABLE/plugin-root")" = "$ROOT" ] && has "relink re-points an old plugin root, naming both" \
  "relinked $STABLE: plugin root $TMP/old-plugin -> $ROOT" || bad "relink: $(cat "$TMP/out")"
"$BIN" relink >"$TMP/out" 2>&1
[ ! -s "$TMP/out" ] && ok "relink again: silent (already current)" || bad "relink not idempotent: $(cat "$TMP/out")"
printf 'stale\n' >"$STABLE/post-commit"
"$BIN" relink >"$TMP/out" 2>&1
[ ! -s "$TMP/out" ] && [ "$(cat "$STABLE/post-commit")" = stale ] \
  && ok "relink fast path: a current stamp returns at once (a hand-edited stub is not checked)" \
  || bad "relink fast path: $(cat "$TMP/out")"
printf '0\n%s\n' "$ROOT" >"$STABLE/.stamp"   # an older STUB_VERSION
"$BIN" relink >"$TMP/out" 2>&1
has "relink after a stub-version change rewrites the changed stub" "rewrote 1 hook stubs"
[ "$(head -1 "$STABLE/.stamp")" != 0 ] && ok "relink writes the new stamp" || bad "stamp not rewritten"
printf '%s\n' "$TMP/gone" >"$STABLE/plugin-root"
"$BIN" status "$TMP/acme" >"$TMP/out" 2>&1
has "status: a missing plugin root is BROKEN" "BROKEN: the plugin root's git-hooks dir is missing ($TMP/gone/git-hooks)"
"$BIN" relink >/dev/null 2>&1
[ "$(cat "$STABLE/plugin-root")" = "$ROOT" ] && ok "relink repairs it" || bad "relink did not repair"
leftover=$(find "$STABLE" -maxdepth 1 -name '.tmp.*' | head -1)
[ -z "$leftover" ] && ok "no temp file left in the dispatcher dir" || bad "relink left a temp file: $leftover"

# --- relink heals an interrupted install (the stamp is written last) -------------------
cp -a "$STABLE" "$TMP/stable-snap"
rm "$STABLE/.stamp"
"$BIN" relink >"$TMP/out" 2>&1
diff -r "$TMP/stable-snap" "$STABLE" >"$TMP/diff" 2>&1 \
  && ok "relink after a lost stamp restores the dir byte-identical" \
  || { bad "relink, lost stamp: $(cat "$TMP/out")"; sed 's/^/      /' "$TMP/diff"; }
: >"$STABLE/pre-commit"
rm "$STABLE/.stamp"
"$BIN" relink >"$TMP/out" 2>&1
diff -r "$TMP/stable-snap" "$STABLE" >"$TMP/diff" 2>&1 \
  && has "relink after a truncated stub and no stamp restores it byte-identical" "rewrote 1 hook stubs" \
  || { bad "relink, truncated stub: $(cat "$TMP/out")"; sed 's/^/      /' "$TMP/diff"; }

# --- refuse another global hooksPath ----------------------------------------------------
git config --global core.hooksPath "$TMP/missing-hooks"
"$BIN" status "$TMP/acme" >"$TMP/out" 2>&1
has "status: a global hooksPath dir that does not exist is BROKEN" "BROKEN: git runs no hooks"
mkdir -p "$TMP/other-hooks"
git config --global core.hooksPath "$TMP/other-hooks"
"$BIN" install --global >"$TMP/out" 2>&1; rc=$?
[ "$rc" -eq 1 ] && [ "$(git config --global --get core.hooksPath)" = "$TMP/other-hooks" ] \
  && has "install refuses another global hooksPath" "refusing to replace it" \
  || bad "install over another hooksPath rc=$rc"
"$BIN" status "$TMP/acme" >"$TMP/out" 2>&1
has "status: global points elsewhere" "-> points ELSEWHERE"
# A relative global hooksPath: git resolves it per repo, so the cwd that
# happens to make it name the dispatcher dir (or the hooks dir) counts for
# nothing.
git config --global core.hooksPath git-hooks
(cd "$TMP/xdg/seyag" && "$BIN" status "$TMP/acme") >"$TMP/out" 2>&1
has "status: a relative global hooksPath is RELATIVE, not ours (even where the cwd resolves it to the dispatcher dir)" \
  "global core.hooksPath: git-hooks -> RELATIVE"
has "status: a relative global hooksPath gets a warning" \
  "warning: the global core.hooksPath (git-hooks) is relative; set an absolute path"
(cd "$ROOT" && "$BIN" install --global) >"$TMP/out" 2>&1; rc=$?
[ "$rc" -eq 1 ] && [ "$(git config --global --get core.hooksPath)" = git-hooks ] \
  && has "install refuses a relative global hooksPath (even where the cwd resolves it to the hooks dir)" "refusing to replace it" \
  || bad "install over a relative hooksPath rc=$rc: $(cat "$TMP/out")"
git config --global core.hooksPath "$HOOKS"
"$BIN" install --global >"$TMP/out" 2>&1
[ "$(git config --global --get core.hooksPath)" = "$STABLE" ] \
  && ok "install moves a global hooksPath at the plugin dir itself to the dispatcher dir" \
  || bad "direct-dir migration: $(cat "$TMP/out")"

# --- uninstall ------------------------------------------------------------------------
"$BIN" uninstall >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "uninstall without --global -> exit 2" || bad "uninstall without --global rc=$rc"
"$BIN" uninstall --global >"$TMP/out" 2>&1 || bad "uninstall failed: $(cat "$TMP/out")"
[ -z "$(git config --global --get core.hooksPath)" ] && [ ! -e "$STABLE" ] \
  && has "uninstall unsets the global hooksPath and removes the dir" "removed the dispatcher dir $STABLE (28 stubs)" \
  || bad "uninstall: $(cat "$TMP/out")"
"$BIN" uninstall --global >"$TMP/out" 2>&1
has "uninstall again: nothing to do" "no seyag dispatcher dir at $STABLE; nothing removed"
mkdir -p "$TMP/other-hooks"; git config --global core.hooksPath "$TMP/other-hooks"
"$BIN" uninstall --global >"$TMP/out" 2>&1
[ "$(git config --global --get core.hooksPath)" = "$TMP/other-hooks" ] \
  && has "uninstall leaves another global hooksPath alone" "left the global core.hooksPath alone" \
  || bad "uninstall touched another hooksPath"

[ "$fail" -eq 0 ]
