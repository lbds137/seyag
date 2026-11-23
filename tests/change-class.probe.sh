#!/bin/bash
# Hermetic fixture check for plugins/seyag/bin/change-class: builds a temp git
# repository and tests classify (exempt report/enforce, multi-class, root vs
# nested globs, unclassed, renames, deletes with/without allow_delete,
# symlinks, exec bits, gitlinks, hard-deny and policy-deny globs, binary files,
# non-UTF-8 paths, file/line limits, empty diff, unknown base, policy errors,
# --policy-ref vs working tree, policy blob SHA, --json output, exit codes),
# replay TSV + stderr summary, and --help.
# Usage: tests/change-class.probe.sh   (writes only in a temp dir)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CC="$REPO/plugins/seyag/bin/change-class"
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

FX="$tmp/repo"
mkdir -p "$FX"
g() { git -C "$FX" -c core.hooksPath=/dev/null -c commit.gpgsign=false "$@"; }

g init -q
g config user.name "Fixture User"
g config user.email "fixture@example.invalid"
g config commit.gpgsign false
g config core.hooksPath /dev/null

POL="$tmp/policy.toml"
cat >"$POL" <<'EOF'
version = 1
mode = "report"
deny = ["docs/private/**"]

[limits]
max_files = 5
max_lines = 100
max_file_lines = 40

[class.docs]
paths = ["docs/**", "*.md"]

[class.ledger]
paths = ["backlog/**"]
allow_delete = true
EOF

POL_ENFORCE="$tmp/policy-enforce.toml"
sed 's/mode = "report"/mode = "enforce"/' "$POL" >"$POL_ENFORCE"

# Base commit: holds backlog/item.md so backlog renames can run from BASE.
mkdir -p "$FX/backlog"
printf 'initial item\n' >"$FX/backlog/item.md"
g add backlog/item.md
g commit -q -m "base"
BASE=$(g rev-parse HEAD)

# Helper: extract key=value field from classify output.
field() {
  local out=$1 key=$2
  awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' <<<"$out"
}

# 1. exempt: add docs/a.md -> exempt, classes=docs, skip=false (mode report); enforce -> skip=true
mkdir -p "$FX/docs"
printf 'hello docs\n' >"$FX/docs/a.md"
g add docs/a.md
g commit -q -m "add docs/a.md"
C_DOC_A=$(g rev-parse HEAD)

out=$("$CC" classify --repo "$FX" --base "$BASE" --head "$C_DOC_A" --policy "$POL"); rc=$?
[ "$rc" = 0 ] && [ "$(field "$out" verdict)" = "exempt" ] \
  && [ "$(field "$out" classes)" = "docs" ] \
  && [ "$(field "$out" skip)" = "false" ] \
  && [ "$(field "$out" mode)" = "report" ] \
  && [[ "$(field "$out" reason)" == exempt* ]] \
  && ok "exempt add docs/a.md: verdict=exempt classes=docs skip=false mode=report" \
  || bad "exempt add docs/a.md (rc=$rc): $out"

out_enf=$("$CC" classify --repo "$FX" --base "$BASE" --head "$C_DOC_A" --policy "$POL_ENFORCE"); rc=$?
[ "$rc" = 0 ] && [ "$(field "$out_enf" verdict)" = "exempt" ] \
  && [ "$(field "$out_enf" classes)" = "docs" ] \
  && [ "$(field "$out_enf" skip)" = "true" ] \
  && [ "$(field "$out_enf" mode)" = "enforce" ] \
  && ok "exempt with enforce policy: skip=true mode=enforce" \
  || bad "exempt enforce (rc=$rc): $out_enf"

# policy= equals git hash-object of the policy file
want_sha=$(g hash-object "$POL")
[ "$(field "$out" policy)" = "$want_sha" ] \
  && ok "policy= equals git hash-object of policy file" \
  || bad "policy sha: got $(field "$out" policy), want $want_sha"

# Helper to build a single-commit case on top of a given base ref ($1=base, $2=branch).
start_case() {
  g checkout -q -B "$2" "$1"
}

# 2. exempt multi-class: docs/b.md + backlog/t.md -> classes=docs,ledger
start_case "$BASE" c-multi
mkdir -p "$FX/docs" "$FX/backlog"
printf 'doc b\n' >"$FX/docs/b.md"
printf 'task t\n' >"$FX/backlog/t.md"
g add docs/b.md backlog/t.md
g commit -q -m "multi-class"
C_MULTI=$(g rev-parse HEAD)
out=$("$CC" classify --repo "$FX" --base "$BASE" --head "$C_MULTI" --policy "$POL")
[ "$(field "$out" verdict)" = "exempt" ] && [ "$(field "$out" classes)" = "docs,ledger" ] \
  && ok "exempt multi-class: classes=docs,ledger" \
  || bad "multi-class: $out"

# --json parses and paths list has one entry per changed path for multi-class case
jout=$("$CC" classify --repo "$FX" --base "$BASE" --head "$C_MULTI" --policy "$POL" --json)
jcheck=$(python3 -I -B -c '
import json, sys
d = json.load(sys.stdin)
assert d["verdict"] == "exempt"
assert d["classes"] == "docs,ledger"
assert d["skip"] is False
assert len(d["paths"]) == 2
print("ok")
' <<<"$jout" 2>&1)
[ "$jcheck" = "ok" ] && ok "--json parses and lists 2 path entries for multi-class diff" || bad "--json: $jcheck / $jout"

# 3. root-level glob: README.md exempt; sub/README.md -> unclassed
start_case "$BASE" c-root-md
printf 'root readme\n' >"$FX/README.md"
g add README.md
g commit -q -m "root readme"
out=$("$CC" classify --repo "$FX" --base "$BASE" --head HEAD --policy "$POL")
[ "$(field "$out" verdict)" = "exempt" ] && [ "$(field "$out" classes)" = "docs" ] \
  && ok "root-level *.md: README.md is exempt" \
  || bad "root README.md: $out"

start_case "$BASE" c-sub-md
mkdir -p "$FX/sub"
printf 'sub readme\n' >"$FX/sub/README.md"
g add sub/README.md
g commit -q -m "sub readme"
out=$("$CC" classify --repo "$FX" --base "$BASE" --head HEAD --policy "$POL"); rc=$?
[ "$rc" = 0 ] && [ "$(field "$out" verdict)" = "full" ] && [[ "$(field "$out" reason)" == unclassed:* ]] \
  && ok "root-level *.md does not match sub/README.md (unclassed, exit 0)" \
  || bad "sub/README.md (rc=$rc): $out"

# 4. src/x.py -> unclassed
start_case "$BASE" c-src
mkdir -p "$FX/src"
printf 'print(1)\n' >"$FX/src/x.py"
g add src/x.py
g commit -q -m "src/x.py"
C_SRC=$(g rev-parse HEAD)
out=$("$CC" classify --repo "$FX" --base "$BASE" --head "$C_SRC" --policy "$POL")
[ "$(field "$out" verdict)" = "full" ] && [[ "$(field "$out" reason)" == unclassed:* ]] \
  && ok "src/x.py -> full (unclassed)" \
  || bad "src/x.py: $out"

# 5. rename docs/a.md -> src/a.md -> full (unclassed or mode for the delete side)
start_case "$C_DOC_A" c-ren-out
mkdir -p "$FX/src"
g mv docs/a.md src/a.md
g commit -q -m "rename docs/a.md to src/a.md"
out=$("$CC" classify --repo "$FX" --base "$C_DOC_A" --head HEAD --policy "$POL")
r_ren=$(field "$out" reason)
[ "$(field "$out" verdict)" = "full" ] && { [[ "$r_ren" == mode:* ]] || [[ "$r_ren" == unclassed:* ]]; } \
  && ok "rename docs/a.md -> src/a.md -> full ($r_ren)" \
  || bad "rename docs/a.md -> src/a.md: $out"

# 6. rename within backlog/ -> exempt (allow_delete); delete of docs/a.md -> mode
start_case "$BASE" c-ren-backlog
g mv backlog/item.md backlog/renamed.md
g commit -q -m "rename within backlog"
out=$("$CC" classify --repo "$FX" --base "$BASE" --head HEAD --policy "$POL")
[ "$(field "$out" verdict)" = "exempt" ] && [ "$(field "$out" classes)" = "ledger" ] \
  && ok "rename within backlog/ -> exempt (allow_delete=true)" \
  || bad "rename within backlog/: $out"

start_case "$C_DOC_A" c-del-doc
g rm -q docs/a.md
g commit -q -m "delete docs/a.md"
out=$("$CC" classify --repo "$FX" --base "$C_DOC_A" --head HEAD --policy "$POL")
[ "$(field "$out" verdict)" = "full" ] && [[ "$(field "$out" reason)" == mode:* ]] \
  && ok "delete of docs/a.md -> full (mode: docs has no allow_delete)" \
  || bad "delete docs/a.md: $out"

# 7. symlink added under docs/ -> mode; chmod +x docs/a.md -> mode; new exec file -> mode; gitlink -> mode
start_case "$C_DOC_A" c-symlink
ln -s a.md "$FX/docs/link.md"
g add docs/link.md
g commit -q -m "add symlink"
out=$("$CC" classify --repo "$FX" --base "$C_DOC_A" --head HEAD --policy "$POL")
[ "$(field "$out" verdict)" = "full" ] && [[ "$(field "$out" reason)" == mode:* ]] \
  && ok "symlink under docs/ -> full (mode)" \
  || bad "symlink: $out"

start_case "$C_DOC_A" c-chmod
chmod +x "$FX/docs/a.md"
g add docs/a.md
g commit -q -m "chmod +x docs/a.md"
out=$("$CC" classify --repo "$FX" --base "$C_DOC_A" --head HEAD --policy "$POL")
[ "$(field "$out" verdict)" = "full" ] && [[ "$(field "$out" reason)" == mode:* ]] \
  && ok "chmod +x docs/a.md -> full (mode)" \
  || bad "chmod +x: $out"

start_case "$BASE" c-new-exec
mkdir -p "$FX/docs"
printf '#!/bin/sh\n' >"$FX/docs/run.sh"
chmod +x "$FX/docs/run.sh"
g add docs/run.sh
g commit -q -m "new exec file"
out=$("$CC" classify --repo "$FX" --base "$BASE" --head HEAD --policy "$POL")
[ "$(field "$out" verdict)" = "full" ] && [[ "$(field "$out" reason)" == mode:* ]] \
  && ok "new exec file under docs/ -> full (mode)" \
  || bad "new exec file: $out"

start_case "$BASE" c-gitlink
g update-index --add --cacheinfo "160000,$BASE,docs/sub"
g commit -q -m "add gitlink"
out=$("$CC" classify --repo "$FX" --base "$BASE" --head HEAD --policy "$POL")
[ "$(field "$out" verdict)" = "full" ] && [[ "$(field "$out" reason)" == mode:* ]] \
  && ok "gitlink (160000) under docs/ -> full (mode)" \
  || bad "gitlink: $out"

# 8. Hard-deny and policy-deny paths -> denied
for dpath in \
  "docs/.gitattributes" \
  "docs/CLAUDE.md" \
  "docs/Claude.MD" \
  ".github/workflows/x.yml" \
  "docs/CODEOWNERS" \
  "docs/private/x.md"; do
  start_case "$BASE" "c-deny-$(tr '/.' '__' <<<"$dpath")"
  mkdir -p "$FX/$(dirname "$dpath")"
  printf 'content\n' >"$FX/$dpath"
  g add "$dpath"
  g commit -q -m "add $dpath"
  out=$("$CC" classify --repo "$FX" --base "$BASE" --head HEAD --policy "$POL")
  if [ "$(field "$out" verdict)" = "full" ] && [[ "$(field "$out" reason)" == denied:* ]]; then
    ok "denied path: $dpath -> full (denied)"
  else
    bad "denied path $dpath: $out"
  fi
done

# 9. binary file docs/img.png (bytes with NUL) -> binary
start_case "$BASE" c-binary
mkdir -p "$FX/docs"
printf '\211PNG\r\n\032\n\000\001\002' >"$FX/docs/img.png"
g add docs/img.png
g commit -q -m "add binary"
out=$("$CC" classify --repo "$FX" --base "$BASE" --head HEAD --policy "$POL")
[ "$(field "$out" verdict)" = "full" ] && [[ "$(field "$out" reason)" == binary:* ]] \
  && ok "binary file docs/img.png -> full (binary)" \
  || bad "binary file: $out"

# 10. non-UTF-8 path -> path-encoding
start_case "$BASE" c-nonutf8
mkdir -p "$FX/docs"
bad_byte=$(printf '\377')
printf 'non-utf8 path\n' >"$FX/docs/${bad_byte}.md"
g add docs/
g commit -q -m "add non-utf8 path"
out=$("$CC" classify --repo "$FX" --base "$BASE" --head HEAD --policy "$POL")
[ "$(field "$out" verdict)" = "full" ] && [[ "$(field "$out" reason)" == path-encoding:* ]] \
  && ok "non-UTF-8 path -> full (path-encoding)" \
  || bad "non-UTF-8 path: $out"

# 11. Size limits: 6 files -> too-many-files; 1 file of 50 lines -> file-too-large; 3 files of 39 lines (117) -> too-many-lines
start_case "$BASE" c-many-files
mkdir -p "$FX/docs"
for i in 1 2 3 4 5 6; do
  printf 'line\n' >"$FX/docs/f$i.md"
done
g add docs/
g commit -q -m "6 files"
out=$("$CC" classify --repo "$FX" --base "$BASE" --head HEAD --policy "$POL")
[ "$(field "$out" verdict)" = "full" ] && [[ "$(field "$out" reason)" == too-many-files:* ]] \
  && ok "6 files (> max_files=5) -> full (too-many-files)" \
  || bad "too-many-files: $out"

start_case "$BASE" c-large-file
mkdir -p "$FX/docs"
for i in $(seq 1 50); do echo "line $i"; done >"$FX/docs/big.md"
g add docs/big.md
g commit -q -m "50-line file"
out=$("$CC" classify --repo "$FX" --base "$BASE" --head HEAD --policy "$POL")
[ "$(field "$out" verdict)" = "full" ] && [[ "$(field "$out" reason)" == file-too-large:* ]] \
  && ok "1 file of 50 lines (> max_file_lines=40) -> full (file-too-large)" \
  || bad "file-too-large: $out"

start_case "$BASE" c-many-lines
mkdir -p "$FX/docs"
for f in 1 2 3; do
  for i in $(seq 1 39); do echo "line $i"; done >"$FX/docs/m$f.md"
done
g add docs/
g commit -q -m "3x39 lines (117)"
out=$("$CC" classify --repo "$FX" --base "$BASE" --head HEAD --policy "$POL")
[ "$(field "$out" verdict)" = "full" ] && [[ "$(field "$out" reason)" == too-many-lines:* ]] \
  && ok "3 files of 39 lines (117 > max_lines=100) -> full (too-many-lines)" \
  || bad "too-many-lines: $out"

# 12. empty diff (--base X --head X) -> empty-diff
out=$("$CC" classify --repo "$FX" --base "$BASE" --head "$BASE" --policy "$POL")
[ "$(field "$out" verdict)" = "full" ] && [[ "$(field "$out" reason)" == empty-diff:* ]] \
  && ok "empty diff (--base X --head X) -> full (empty-diff)" \
  || bad "empty-diff: $out"

# 13. unknown base sha -> unknown-base
UNK_SHA=$(printf '1%.0s' {1..40})
out=$("$CC" classify --repo "$FX" --base "$UNK_SHA" --head "$C_DOC_A" --policy "$POL")
[ "$(field "$out" verdict)" = "full" ] && [[ "$(field "$out" reason)" == unknown-base:* ]] \
  && ok "unknown base sha -> full (unknown-base)" \
  || bad "unknown-base: $out"

# 14. policy errors: missing file, invalid TOML, version=2, unknown key, bad mode, class with paths=[]
out=$("$CC" classify --repo "$FX" --base "$BASE" --head "$C_DOC_A" --policy "$tmp/no-such-policy.toml")
[ "$(field "$out" verdict)" = "full" ] \
  && [[ "$(field "$out" reason)" == policy-missing:* ]] \
  && [ "$(field "$out" mode)" = "none" ] \
  && [ "$(field "$out" policy)" = "none" ] \
  && ok "--policy missing file -> policy-missing, mode=none, policy=none" \
  || bad "policy-missing: $out"

check_bad_policy() {
  local label=$1 content=$2 pfile="$tmp/bad-pol.toml"
  printf '%s\n' "$content" >"$pfile"
  local pout
  pout=$("$CC" classify --repo "$FX" --base "$BASE" --head "$C_DOC_A" --policy "$pfile")
  if [ "$(field "$pout" verdict)" = "full" ] \
    && [[ "$(field "$pout" reason)" == policy-invalid:* ]] \
    && [ "$(field "$pout" mode)" = "none" ]; then
    ok "policy-invalid ($label): mode=none"
  else
    bad "policy-invalid ($label): $pout"
  fi
}

check_bad_policy "invalid TOML" "version = [unclosed"
check_bad_policy "version = 2" "version = 2"
check_bad_policy "unknown key" "$(printf 'version = 1\nextra = true')"
check_bad_policy "bad mode" "$(printf 'version = 1\nmode = "turbo"')"
check_bad_policy "empty paths" "$(printf 'version = 1\n[class.docs]\npaths = []')"

# 15. --policy-ref: reads policy A committed at ref, ignores working tree policy B; missing at ref -> policy-missing
start_case "$BASE" c-polref
mkdir -p "$FX/.github"
cp "$POL" "$FX/.github/change-class.toml"
g add .github/change-class.toml
g commit -q -m "commit policy A"
C_POL_A=$(g rev-parse HEAD)

# Overwrite working-tree policy with policy B (no docs class)
cat >"$FX/.github/change-class.toml" <<'EOF'
version = 1
mode = "report"

[class.ledger]
paths = ["backlog/**"]
EOF

out=$("$CC" classify --repo "$FX" --base "$BASE" --head "$C_DOC_A" --policy-ref "$C_POL_A")
[ "$(field "$out" verdict)" = "exempt" ] && [ "$(field "$out" classes)" = "docs" ] \
  && ok "--policy-ref reads committed policy A at ref, ignoring working tree policy B" \
  || bad "--policy-ref working tree isolation: $out"
g checkout -q -- .github/change-class.toml

out=$("$CC" classify --repo "$FX" --base "$BASE" --head "$C_DOC_A" --policy-ref "$BASE")
[ "$(field "$out" verdict)" = "full" ] \
  && [[ "$(field "$out" reason)" == policy-missing:* ]] \
  && [ "$(field "$out" mode)" = "none" ] \
  && [ "$(field "$out" policy)" = "none" ] \
  && ok "--policy-ref with no file at path -> policy-missing, mode=none, policy=none" \
  || bad "--policy-ref missing: $out"

# 16. Usage errors exit 2
"$CC" classify --repo "$FX" --head "$C_DOC_A" --policy "$POL" >/dev/null 2>&1
[ $? = 2 ] && ok "classify without --base exits 2" || bad "classify without --base rc"

"$CC" classify --repo "$FX" --base "$BASE" --head "$C_DOC_A" --policy "$POL" --policy-ref "$C_POL_A" >/dev/null 2>&1
[ $? = 2 ] && ok "classify with both --policy and --policy-ref exits 2" || bad "both --policy and --policy-ref rc"

# 17. replay: 3 pairs (one exempt, one full, one malformed line) -> 3 rows, stderr summary
replay_in=$(printf 'p1\t%s\t%s\np2\t%s\t%s\nbad_only_one_col\n' "$BASE" "$C_DOC_A" "$BASE" "$C_SRC")
replay_out=$("$CC" replay --repo "$FX" --policy "$POL" <<<"$replay_in" 2>"$tmp/replay.err"); rc=$?
replay_err=$(cat "$tmp/replay.err")
want_r1=$(printf 'p1\texempt\tdocs\t1\t1\texempt')
want_r2=$(printf 'p2\tfull\t\t1\t1\tunclassed:')
want_r3=$(printf 'bad_only_one_col\tfull\t\t-\t-\tbad-line')
[ "$rc" = 0 ] && [ "$(grep -c . <<<"$replay_out")" = 3 ] \
  && grep -qxF "$want_r1" <<<"$replay_out" \
  && [[ $'\n'"$replay_out" == *$'\n'"$want_r2"* ]] \
  && grep -qxF "$want_r3" <<<"$replay_out" \
  && grep -qF "3 pairs, 1 exempt, 2 full" <<<"$replay_err" \
  && ok "replay: 3 rows with expected columns and stderr summary '3 pairs, 1 exempt, 2 full'" \
  || bad "replay (rc=$rc): out=[$replay_out] err=[$replay_err]"

# 17b. unknown head -> unknown-head; a full verdict under an enforce policy prints skip=false
out=$("$CC" classify --repo "$FX" --base "$BASE" --head "$UNK_SHA" --policy "$POL"); rc=$?
[ "$rc" = 0 ] && [ "$(field "$out" verdict)" = "full" ] && [[ "$(field "$out" reason)" == unknown-head:* ]] \
  && ok "unknown head sha -> full (unknown-head)" \
  || bad "unknown-head (rc=$rc): $out"

out=$("$CC" classify --repo "$FX" --base "$BASE" --head "$C_SRC" --policy "$POL_ENFORCE"); rc=$?
[ "$rc" = 0 ] && [ "$(field "$out" verdict)" = "full" ] && [ "$(field "$out" skip)" = "false" ] \
  && [ "$(field "$out" mode)" = "enforce" ] \
  && ok "full verdict under enforce policy: skip=false mode=enforce" \
  || bad "enforce full skip (rc=$rc): $out"

# 17c. submodule pointer bump must not hide behind ignore=all / diff.ignoreSubmodules
start_case "$BASE" c-sub-base
printf '[submodule "s"]\n\tpath = s\n\turl = ./s\n\tignore = all\n' >"$FX/.gitmodules"
g add .gitmodules
g update-index --add --cacheinfo "160000,$BASE,s"
g commit -q -m "base with gitlink s"
C_SUB_BASE=$(g rev-parse HEAD)
start_case "$C_SUB_BASE" c-sub-head
g update-index --cacheinfo "160000,$C_DOC_A,s"
mkdir -p "$FX/docs"
printf 'zed\n' >"$FX/docs/z.md"
g add docs/z.md
g commit -q -m "bump gitlink s and add docs/z.md"
C_SUB_HEAD=$(g rev-parse HEAD)
sub_changed=$(g diff-tree -r --name-only "$C_SUB_BASE" "$C_SUB_HEAD" | tr '\n' ' ')
[[ "$sub_changed" != *.gitmodules* ]] || bad "submodule fixture: .gitmodules is in the head diff ($sub_changed)"

out=$("$CC" classify --repo "$FX" --base "$C_SUB_BASE" --head "$C_SUB_HEAD" --policy "$POL"); rc=$?
[ "$rc" = 0 ] && [ "$(field "$out" verdict)" = "full" ] && [[ "$(field "$out" reason)" == mode:* ]] \
  && ok "gitlink bump + docs/z.md with .gitmodules ignore=all -> full (mode)" \
  || bad "submodule ignore=all (rc=$rc): $out"

g config diff.ignoreSubmodules all
out=$("$CC" classify --repo "$FX" --base "$C_SUB_BASE" --head "$C_SUB_HEAD" --policy "$POL"); rc=$?
[ "$rc" = 0 ] && [ "$(field "$out" verdict)" = "full" ] && [[ "$(field "$out" reason)" == mode:* ]] \
  && ok "gitlink bump + docs/z.md with diff.ignoreSubmodules=all -> full (mode)" \
  || bad "submodule diff.ignoreSubmodules (rc=$rc): $out"
g config --unset diff.ignoreSubmodules

# 17d. trailing newline in a path must not match *.md
start_case "$BASE" c-newline-name
nl_name=$(printf 'n.md\nx'); nl_name=${nl_name%x}
printf 'newline name\n' >"$FX/$nl_name"
g add -- "$nl_name"
g commit -q -m "add n.md with trailing newline in the name"
out=$("$CC" classify --repo "$FX" --base "$BASE" --head HEAD --policy "$POL"); rc=$?
[ "$rc" = 0 ] && [ "$(field "$out" verdict)" = "full" ] \
  && ok "path 'n.md<newline>' is not exempt under *.md" \
  || bad "trailing-newline path (rc=$rc): $out"

# 17e. pathological policy and timeout inputs still yield a verdict with exit 0
python3 -I -B -c 'import sys; sys.stdout.write("a = " + "[" * 5000 + "\n")' >"$tmp/deep.toml"
out=$("$CC" classify --repo "$FX" --base "$BASE" --head "$C_DOC_A" --policy "$tmp/deep.toml" 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(field "$out" verdict)" = "full" ] && [[ "$(field "$out" reason)" == policy-invalid:* ]] \
  && ok "5000-deep nested TOML -> full (policy-invalid), exit 0" \
  || bad "deep TOML (rc=$rc): $out"

out=$("$CC" classify --repo "$FX" --base "$BASE" --head "$C_DOC_A" --policy "$POL" --timeout 1e300 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(field "$out" verdict)" = "exempt" ] \
  && ok "--timeout 1e300 is clamped: normal verdict, exit 0" \
  || bad "--timeout 1e300 (rc=$rc): $out"

# 17f. glob edges with a dedicated policy
POL_GLOB="$tmp/policy-glob.toml"
cat >"$POL_GLOB" <<'EOF'
version = 1

[class.g]
paths = ["a/**/b.md", "?.md"]
EOF
glob_case() {
  local file=$1 want=$2 gout grc
  start_case "$BASE" "c-glob-$(tr '/.' '__' <<<"$file")"
  mkdir -p "$FX/$(dirname "$file")"
  printf 'g\n' >"$FX/$file"
  g add -- "$file"
  g commit -q -m "glob $file"
  gout=$("$CC" classify --repo "$FX" --base "$BASE" --head HEAD --policy "$POL_GLOB"); grc=$?
  if [ "$grc" = 0 ] && [ "$(field "$gout" verdict)" = "$want" ]; then
    ok "glob edge: $file -> $want"
  else
    bad "glob edge $file (rc=$grc, want $want): $gout"
  fi
}
glob_case "a/b.md" exempt
glob_case "a/x/y/b.md" exempt
glob_case "a/xb.md" full
glob_case "x.md" exempt
glob_case "xy.md" full

# 17g. replay survives a non-UTF-8 byte in an ID line
replay_bad=$(printf 'p\377q\t%s\t%s\n' "$BASE" "$C_DOC_A" | "$CC" replay --repo "$FX" --policy "$POL" 2>"$tmp/replay-bad.err"); rc=$?
[ "$rc" = 0 ] && [ "$(grep -c . <<<"$replay_bad")" = 1 ] \
  && ok "replay: non-UTF-8 byte in an ID line does not crash (exit 0, one row)" \
  || bad "replay non-UTF-8 (rc=$rc): out=[$replay_bad] err=[$(cat "$tmp/replay-bad.err")]"

# 17h. --help is only honoured as argv[0] or first after the subcommand
help_val=$("$CC" classify --base --help --head "$C_DOC_A" --policy "$POL" 2>/dev/null); rc=$?
if ! grep -qF "classify a git tree diff" <<<"$help_val"; then
  ok "classify --base --help ...: --help is a value, no docstring printed (rc=$rc)"
else
  bad "classify --base --help printed help: $help_val"
fi

# 18. --help exits 0 and contains change-class
help_out=$("$CC" --help); rc=$?
[ "$rc" = 0 ] && grep -qF "change-class" <<<"$help_out" \
  && ok "--help exits 0 and contains change-class" \
  || bad "--help (rc=$rc): $help_out"

exit "$fail"
