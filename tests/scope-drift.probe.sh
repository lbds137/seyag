#!/usr/bin/env bash
# Hermetic probe for plugins/seyag/bin/scope-drift: fresh git init repos under mktemp -d with an
# initial commit as base, each run bounded by timeout. Covers clean/drift verdicts, untracked and
# deleted paths, spec parsing (backticks, ` (` notes, paths with spaces and ` - `, line cites,
# directory prefixes, globs, exact literal `[` and `?`, `## Files` heading variant, non-bullet
# lines, repeatable `--spec`), default base resolution (`origin/HEAD` -> `origin/main` fallback ->
# exit 2 `no base`), dependency manifests and lockfiles (in-scope manifest reporting, `-`/`+`
# lines in diff order, 20-line cap with `... K more`, `SYG_SCOPE_DRIFT_MANIFESTS` extension and
# config-file loading, untracked manifests), usage/error exits (exit 2), and read-only tree/index
# invariance. Also: bash >= 4.4 guard (static check), unborn HEAD, fork-point label, shallow
# warning wording, failed ls-files/numstat/-U0 reads (fake git on PATH), index-deleted and tracked
# nested manifests, the extended manifest and lockfile list, case-insensitive `## files` heading,
# leading `./` entries, the user config file, and the default-base hint.
# Usage: tests/scope-drift.probe.sh   (from anywhere)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SD="$REPO/plugins/seyag/bin/scope-drift"
[ -x "$SD" ] || { echo "FAIL  $SD is not executable (chmod +x it)"; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/scope-drift-probe.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
cd "$tmp" || exit 1

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; }

unset SYG_SCOPE_DRIFT_MANIFESTS SYG_CONFIG
export XDG_CONFIG_HOME="$tmp/xdg-config" CLAUDE_PROJECT_DIR="$tmp/no-project"
mkdir -p "$XDG_CONFIG_HOME"

run() {
  local t=$1; shift
  timeout "$t" "$@" > out 2> err
  rc=$?
}
out() { cat out; }
err() { cat err; }

# Build baseline fixture repo wt with initial commit $base.
wt="$tmp/wt"
git init -q -b main "$wt"
git -C "$wt" config user.email t@t
git -C "$wt" config user.name t
mkdir -p "$wt/src" "$wt/docs" "$wt/lib/x" "$wt/tests"
echo "a1" > wt/src/a.sh
echo "b1" > wt/src/b.sh
echo "readme1" > wt/README.md
echo "task1" > "wt/docs/task-1 - a name.md"
echo "lib1" > wt/lib/x/y.sh
echo "p1" > wt/tests/x.probe.sh
echo "t1" > wt/tests/x.sh
printf '{\n  "name": "demo",\n  "dependencies": {\n    "x": "1.0.0"\n  }\n}\n' > wt/package.json
printf '# lock\nv = 1\n' > wt/Cargo.lock
echo "gem1" > wt/x.gemspec
echo "brack1" > "wt/src/[x].sh"
echo "plainx1" > wt/src/x.sh
echo "*.ignored" > wt/.gitignore
git -C "$wt" add -A
git -C "$wt" commit -qm "initial base"
base=$(git -C "$wt" rev-parse HEAD)
short=$(git -C "$wt" rev-parse --short "$base")

reset_wt() {
  git -C "$wt" reset -q --hard "$base"
  git -C "$wt" clean -q -fdX
  git -C "$wt" clean -q -fd
}

# 1. Nothing changed -> exit 0, scope-drift: clean (0 changed paths...
cat > spec1.md <<'EOF'
# Unit
## Files in scope
- src/a.sh
EOF
run 5 "$SD" --spec "$tmp/spec1.md" --base "$base" --worktree "$wt"
want_clean0="scope-drift: clean (0 changed paths, all in scope; no manifest changes) vs $short"
[ "$rc" = 0 ] && [ "$(out)" = "$want_clean0" ] \
  && ok "case 1: nothing changed exits 0 with clean (0 changed paths)" \
  || bad "case 1: rc=$rc out=$(out) err=$(err)"

# 2 & 19a. In-scope modify of src/a.sh listed as - src/a.sh -> exit 0, exact clean line pinned.
echo "a2" > wt/src/a.sh
run 5 "$SD" --spec "$tmp/spec1.md" --base "$base" --worktree "$wt"
want_clean1="scope-drift: clean (1 changed paths, all in scope; no manifest changes) vs $short"
[ "$rc" = 0 ] && [ "$(out)" = "$want_clean1" ] \
  && ok "case 2 & 19a: in-scope modify of src/a.sh exits 0 with exact clean line" \
  || bad "case 2 & 19a: rc=$rc out=$(out) want=$want_clean1"
reset_wt

# 3 & 19b. Out-of-scope modify of src/b.sh -> exit 1, out of scope (1):, two-space src/b.sh, exact drift trailer.
echo "b2" > wt/src/b.sh
run 5 "$SD" --spec "$tmp/spec1.md" --base "$base" --worktree "$wt"
want_drift3=$(printf '%s\n%s\n%s' \
  "scope-drift: out of scope (1):" \
  "  src/b.sh" \
  "scope-drift: drift vs $short: amend the spec's ## Files in scope, or record a named reviewer sign-off for each entry")
[ "$rc" = 1 ] && [ "$(out)" = "$want_drift3" ] \
  && ok "case 3 & 19b: out-of-scope modify of src/b.sh exits 1 with exact out-of-scope section and drift trailer" \
  || bad "case 3 & 19b: rc=$rc out=$(out)"
reset_wt

# 4. Untracked new file out of scope -> exit 1, listed (ignored file excluded).
echo "new" > wt/src/untracked.sh
echo "ign" > wt/skip.ignored
run 5 "$SD" --spec "$tmp/spec1.md" --base "$base" --worktree "$wt"
[ "$rc" = 1 ] && grep -qxF "scope-drift: out of scope (1):" out \
  && grep -qxF "  src/untracked.sh" out \
  && ! grep -q "skip.ignored" out \
  && ok "case 4: untracked new file out of scope exits 1 and is listed (gitignored excluded)" \
  || bad "case 4: rc=$rc out=$(out)"
reset_wt

# 5. Deleted tracked file out of scope -> exit 1, listed.
rm "$wt/src/b.sh"
run 5 "$SD" --spec "$tmp/spec1.md" --base "$base" --worktree "$wt"
[ "$rc" = 1 ] && grep -qxF "scope-drift: out of scope (1):" out \
  && grep -qxF "  src/b.sh" out \
  && ok "case 5: deleted tracked file out of scope exits 1 and is listed" \
  || bad "case 5: rc=$rc out=$(out)"
reset_wt

# 6. Backticked entry - `src/a.sh` (and * bullet variant) matches.
cat > spec6.md <<'EOF'
## Files in scope
- `src/a.sh` (edited)
* `src/b.sh`
EOF
echo "a2" > wt/src/a.sh
echo "b2" > wt/src/b.sh
run 5 "$SD" --spec "$tmp/spec6.md" --base "$base" --worktree "$wt"
[ "$rc" = 0 ] && grep -q "clean (2 changed paths" out \
  && ok "case 6: backticked entry - \`src/a.sh\` and * bullet match" \
  || bad "case 6: rc=$rc out=$(out)"
reset_wt

# 7. Entry with a note - README.md (line 34 only) matches README.md.
cat > spec7.md <<'EOF'
## Files in scope
- README.md (line 34 only)
EOF
echo "readme2" > wt/README.md
run 5 "$SD" --spec "$tmp/spec7.md" --base "$base" --worktree "$wt"
[ "$rc" = 0 ] && [ "$(out)" = "$want_clean1" ] \
  && ok "case 7: entry with note '- README.md (line 34 only)' matches README.md" \
  || bad "case 7: rc=$rc out=$(out)"
reset_wt

# 8. Path with spaces and ` - ` inside: - docs/task-1 - a name.md (new) matches docs/task-1 - a name.md.
cat > spec8.md <<'EOF'
## Files in scope
- docs/task-1 - a name.md (new)
EOF
echo "task2" > "wt/docs/task-1 - a name.md"
run 5 "$SD" --spec "$tmp/spec8.md" --base "$base" --worktree "$wt"
[ "$rc" = 0 ] && [ "$(out)" = "$want_clean1" ] \
  && ok "case 8: path with spaces and ' - ' inside matches" \
  || bad "case 8: rc=$rc out=$(out)"
reset_wt

# 9. Line cite - src/a.sh:12 and - src/b.sh:12-30 match src/a.sh and src/b.sh.
cat > spec9.md <<'EOF'
## Files in scope
- src/a.sh:12
- src/b.sh:12-30 (range)
EOF
echo "a2" > wt/src/a.sh
echo "b2" > wt/src/b.sh
run 5 "$SD" --spec "$tmp/spec9.md" --base "$base" --worktree "$wt"
[ "$rc" = 0 ] && grep -q "clean (2 changed paths" out \
  && ok "case 9: line cites :12 and :12-30 stripped and matched" \
  || bad "case 9: rc=$rc out=$(out)"
reset_wt

# 10. Directory entry - lib/ and - lib/** cover lib/x/y.sh; glob - tests/*.probe.sh covers tests/x.probe.sh and not tests/x.sh.
cat > spec10a.md <<'EOF'
## Files in scope
- lib/
- tests/*.probe.sh
EOF
cat > spec10b.md <<'EOF'
## Files in scope
- lib/**
EOF
echo "lib2" > wt/lib/x/y.sh
echo "p2" > wt/tests/x.probe.sh
run 5 "$SD" --spec "$tmp/spec10a.md" --base "$base" --worktree "$wt"
rc10a=$rc
run 5 "$SD" --spec "$tmp/spec10b.md" --base "$base" --worktree "$wt"
rc10b=$rc
out10b=$(out)
echo "t2" > wt/tests/x.sh
run 5 "$SD" --spec "$tmp/spec10a.md" --base "$base" --worktree "$wt"
rc10c=$rc
out10c=$(out)
if [ "$rc10a" = 0 ] && [ "$rc10b" = 1 ] && grep -qxF "  tests/x.probe.sh" <<<"$out10b" \
  && ! grep -q "lib/x/y.sh" <<<"$out10b" \
  && [ "$rc10c" = 1 ] && grep -qxF "  tests/x.sh" <<<"$out10c" && ! grep -q "tests/x.probe.sh" <<<"$out10c"; then
  ok "case 10: - lib/ and - lib/** cover lib/x/y.sh; - tests/*.probe.sh covers tests/x.probe.sh and not tests/x.sh"
else
  bad "case 10: rc10a=$rc10a rc10b=$rc10b out10b=$out10b rc10c=$rc10c out10c=$out10c"
fi
reset_wt

# 11. ## Files heading (no "in scope") accepted; non-bullet Enumerated by: `foo` is not an entry;
# empty scope section is allowed and treats every changed path as out of scope.
cat > spec11.md <<'EOF'
## Files
- src/a.sh
Enumerated by: `foo`
## Other section
- foo
EOF
echo "a2" > wt/src/a.sh
run 5 "$SD" --spec "$tmp/spec11.md" --base "$base" --worktree "$wt"
rc11_clean=$rc
echo "f" > wt/foo
run 5 "$SD" --spec "$tmp/spec11.md" --base "$base" --worktree "$wt"
rc11_drift=$rc
out11_drift=$(out)
cat > spec11_empty.md <<'EOF'
## Files in scope
Enumerated by: `src/a.sh`
EOF
run 5 "$SD" --spec "$tmp/spec11_empty.md" --base "$base" --worktree "$wt"
rc11_empty=$rc
out11_empty=$(out)
if [ "$rc11_clean" = 0 ] && [ "$rc11_drift" = 1 ] && grep -qxF "scope-drift: out of scope (1):" <<<"$out11_drift" \
  && grep -qxF "  foo" <<<"$out11_drift" \
  && [ "$rc11_empty" = 1 ] && grep -qxF "scope-drift: out of scope (2):" <<<"$out11_empty"; then
  ok "case 11: '## Files' accepted, non-bullet 'Enumerated by: \`foo\`' and later sections ignored, empty scope set allowed"
else
  bad "case 11: clean=$rc11_clean drift=$rc11_drift ($out11_drift) empty=$rc11_empty ($out11_empty)"
fi
reset_wt

# 12. Default base: bare origin remote with main; origin/HEAD set -> resolves; origin/HEAD unset ->
# falls back to origin/main merge-base; repo with no remote -> exit 2 'no base'.
run 5 "$SD" --spec "$tmp/spec1.md" --worktree "$wt"
rc12_noremote=$rc
err12_noremote=$(err)

bare="$tmp/origin.git"
git init -q --bare -b main "$bare"
git -C "$wt" remote add origin "$bare"
git -C "$wt" push -q origin main
git -C "$wt" remote set-head origin main
run 5 "$SD" --spec "$tmp/spec1.md" --worktree "$wt"
rc12_head=$rc
out12_head=$(out)

git -C "$wt" remote set-head origin -d
run 5 "$SD" --spec "$tmp/spec1.md" --worktree "$wt"
rc12_fallback=$rc
out12_fallback=$(out)
git -C "$wt" remote remove origin

if [ "$rc12_noremote" = 2 ] && grep -qF "scope-drift: no base: pass --base REF" <<<"$err12_noremote" \
  && [ "$rc12_head" = 0 ] && [ "$out12_head" = "$want_clean0" ] \
  && [ "$rc12_fallback" = 0 ] && [ "$out12_fallback" = "$want_clean0" ]; then
  ok "case 12: default base resolves origin/HEAD, falls back to origin/main when origin/HEAD unset, exits 2 with no remote"
else
  bad "case 12: noremote=($rc12_noremote/$err12_noremote) head=($rc12_head/$out12_head) fallback=($rc12_fallback/$out12_fallback)"
fi

# 13. Manifest in scope still reported: package.json listed in scope gains a "left-pad": "1.0.0" line
# -> exit 1, manifests changed (1):, package.json (+1 -0), and + line containing left-pad; no out of scope section.
cat > spec13.md <<'EOF'
## Files in scope
- package.json
EOF
printf '{\n  "name": "demo",\n  "left-pad": "1.0.0",\n  "dependencies": {\n    "x": "1.0.0"\n  }\n}\n' > wt/package.json
run 5 "$SD" --spec "$tmp/spec13.md" --base "$base" --worktree "$wt"
if [ "$rc" = 1 ] \
  && ! grep -q "out of scope" out \
  && grep -qxF "scope-drift: manifests changed (1):" out \
  && grep -qxF "  package.json (+1 -0)" out \
  && grep -qE '^    \+ .*"left-pad": "1\.0\.0"' out; then
  ok "case 13: in-scope package.json addition exits 1 with manifests changed (1), (+1 -0) and + left-pad line"
else
  bad "case 13: rc=$rc out=$(out)"
fi
reset_wt

# 14. Lockfile shows counts only: Cargo.lock changed -> listed with (+A -D) and no + or - content lines under it.
cat > spec14.md <<'EOF'
## Files in scope
- Cargo.lock
EOF
printf '# lock\nv = 2\nextra = 3\n' > wt/Cargo.lock
run 5 "$SD" --spec "$tmp/spec14.md" --base "$base" --worktree "$wt"
if [ "$rc" = 1 ] \
  && ! grep -q "out of scope" out \
  && grep -qxF "scope-drift: manifests changed (1):" out \
  && grep -qxF "  Cargo.lock (+2 -1)" out \
  && ! grep -qE '^    [+-] ' out; then
  ok "case 14: lockfile Cargo.lock shows (+2 -1) counts only with no content lines"
else
  bad "case 14: rc=$rc out=$(out)"
fi
reset_wt

# 15. SYG_SCOPE_DRIFT_MANIFESTS='*.gemspec' makes x.gemspec a manifest; without it, x.gemspec in scope is clean.
cat > spec15.md <<'EOF'
## Files in scope
- x.gemspec
EOF
echo "gem2" > wt/x.gemspec
run 5 "$SD" --spec "$tmp/spec15.md" --base "$base" --worktree "$wt"
rc15_without=$rc
run 5 env SYG_SCOPE_DRIFT_MANIFESTS='*.gemspec' "$SD" --spec "$tmp/spec15.md" --base "$base" --worktree "$wt"
rc15_with=$rc
out15_with=$(out)
if [ "$rc15_without" = 0 ] && [ "$rc15_with" = 1 ] \
  && grep -qxF "scope-drift: manifests changed (1):" <<<"$out15_with" \
  && grep -qxF "  x.gemspec (+1 -1)" <<<"$out15_with" \
  && grep -qE '^    \+ gem2$' <<<"$out15_with"; then
  ok "case 15: SYG_SCOPE_DRIFT_MANIFESTS='*.gemspec' reports x.gemspec; unset leaves it clean"
else
  bad "case 15: without=$rc15_without with=$rc15_with out=$out15_with"
fi
reset_wt

# 16. Untracked requirements-dev.txt out of scope -> listed in both sections, untracked count (+L -0),
# and >20 changed lines cap shows '... K more'.
for i in $(seq 1 25); do echo "pkg-$i==1.0"; done > wt/requirements-dev.txt
run 5 "$SD" --spec "$tmp/spec1.md" --base "$base" --worktree "$wt"
if [ "$rc" = 1 ] \
  && grep -qxF "scope-drift: out of scope (1):" out \
  && grep -qxF "  requirements-dev.txt" out \
  && grep -qxF "scope-drift: manifests changed (1):" out \
  && grep -qxF "  requirements-dev.txt (+25 -0)" out \
  && grep -qxF "    + pkg-1==1.0" out \
  && grep -qxF "    + pkg-20==1.0" out \
  && ! grep -q "pkg-21==1.0" out \
  && grep -qxF "      ... 5 more" out; then
  ok "case 16: untracked requirements-dev.txt listed in both sections with (+25 -0), 20 + lines, and '... 5 more'"
else
  bad "case 16: rc=$rc out=$(out)"
fi
reset_wt

# 17. Errors -> exit 2: missing spec file; spec without the heading; --worktree outside a git tree;
# --base nosuchref; unknown option; missing --spec. --help -> exit 0 and mentions --spec.
run 5 "$SD" --help
[ "$rc" = 0 ] && grep -q -- "--spec" out && grep -q "widen a diff silently" out \
  && ok "case 17a: --help exits 0 and mentions --spec and rationale" \
  || bad "case 17a: rc=$rc out=$(out)"

run 5 "$SD" --spec "$tmp/no-such-spec.md" --base "$base" --worktree "$wt"
[ "$rc" = 2 ] && grep -q "^scope-drift:" err \
  && ok "case 17b: missing spec file exits 2" \
  || bad "case 17b: rc=$rc err=$(err)"

echo "# No files section here" > no-heading.md
run 5 "$SD" --spec "$tmp/no-heading.md" --base "$base" --worktree "$wt"
[ "$rc" = 2 ] && grep -qF "scope-drift: $tmp/no-heading.md has no \"## Files in scope\" section" err \
  && ok "case 17c: spec without heading exits 2 with exact message" \
  || bad "case 17c: rc=$rc err=$(err)"

mkdir -p "$tmp/not-a-repo"
run 5 "$SD" --spec "$tmp/spec1.md" --base "$base" --worktree "$tmp/not-a-repo"
[ "$rc" = 2 ] && grep -q "^scope-drift:" err \
  && ok "case 17d: --worktree outside a git tree exits 2" \
  || bad "case 17d: rc=$rc err=$(err)"

run 5 "$SD" --spec "$tmp/spec1.md" --base nosuchref --worktree "$wt"
[ "$rc" = 2 ] && grep -q "^scope-drift:" err \
  && ok "case 17e: --base nosuchref exits 2" \
  || bad "case 17e: rc=$rc err=$(err)"

for bad_args in "--bogus" "" "--spec" "--base" "--worktree"; do
  # shellcheck disable=SC2086
  run 5 "$SD" $bad_args
  [ "$rc" = 2 ] && grep -q "^scope-drift:" err \
    && ok "case 17f: '$bad_args' exits 2" \
    || bad "case 17f: '$bad_args' rc=$rc err=$(err)"
done

# 18. Read-only: after a drift run, git status --porcelain and git diff --cached --name-only are byte-identical.
echo "a2" > wt/src/a.sh
git -C "$wt" add src/a.sh
echo "b2" > wt/src/b.sh
echo "u1" > wt/src/untracked.sh
st_before=$(git -C "$wt" status --porcelain)
ca_before=$(git -C "$wt" diff --cached --name-only)
run 5 "$SD" --spec "$tmp/spec1.md" --base "$base" --worktree "$wt"
st_after=$(git -C "$wt" status --porcelain)
ca_after=$(git -C "$wt" diff --cached --name-only)
if [ "$rc" = 1 ] && [ "$st_before" = "$st_after" ] && [ "$ca_before" = "$ca_after" ]; then
  ok "case 18: drift run leaves git status --porcelain and git diff --cached --name-only byte-identical"
else
  bad "case 18: rc=$rc st_diff=($st_before vs $st_after) ca_diff=($ca_before vs $ca_after)"
fi
reset_wt

# 20. Upgrade "x": "1.0.0" -> "x": "2.0.0" in package.json shows a - line with 1.0.0 and a + line with 2.0.0, (+1 -1).
printf '{\n  "name": "demo",\n  "dependencies": {\n    "x": "2.0.0"\n  }\n}\n' > wt/package.json
run 5 "$SD" --spec "$tmp/spec13.md" --base "$base" --worktree "$wt"
if [ "$rc" = 1 ] \
  && grep -qxF "  package.json (+1 -1)" out \
  && grep -qE '^    - .*"x": "1\.0\.0"' out \
  && grep -qE '^    \+ .*"x": "2\.0\.0"' out \
  && ! grep -qE '^(---|\+\+\+|@@)' out; then
  ok "case 20: upgrade in package.json shows (+1 -1), - line with 1.0.0, and + line with 2.0.0"
else
  bad "case 20: rc=$rc out=$(out)"
fi
reset_wt

# 21. --spec a.md --spec b.md (a lists src/a.sh, b lists src/b.sh, both changed) -> exit 0;
# --spec b.md alone -> exit 1 naming src/a.sh.
cat > spec21b.md <<'EOF'
## Files in scope
- src/b.sh
EOF
echo "a2" > wt/src/a.sh
echo "b2" > wt/src/b.sh
run 5 "$SD" --spec "$tmp/spec1.md" --spec "$tmp/spec21b.md" --base "$base" --worktree "$wt"
rc21_both=$rc
run 5 "$SD" --spec "$tmp/spec21b.md" --base "$base" --worktree "$wt"
rc21_one=$rc
out21_one=$(out)
if [ "$rc21_both" = 0 ] && [ "$rc21_one" = 1 ] \
  && grep -qxF "scope-drift: out of scope (1):" <<<"$out21_one" \
  && grep -qxF "  src/a.sh" <<<"$out21_one"; then
  ok "case 21: repeatable --spec unions both files (exit 0); single --spec exits 1 naming src/a.sh"
else
  bad "case 21: both=$rc21_both one=$rc21_one out=$out21_one"
fi
reset_wt

# 22. Entry - src/[x].sh matches the file src/[x].sh, and with src/x.sh also changed, src/x.sh is out of scope.
cat > spec22.md <<'EOF'
## Files in scope
- src/[x].sh
EOF
echo "brack2" > "wt/src/[x].sh"
echo "plainx2" > wt/src/x.sh
run 5 "$SD" --spec "$tmp/spec22.md" --base "$base" --worktree "$wt"
if [ "$rc" = 1 ] \
  && grep -qxF "scope-drift: out of scope (1):" out \
  && grep -qxF "  src/x.sh" out \
  && ! grep -qF "src/[x].sh" out; then
  ok "case 22: exact entry '- src/[x].sh' matches literally and leaves src/x.sh out of scope"
else
  bad "case 22: rc=$rc out=$(out)"
fi
reset_wt

# 23. --worktree a subdirectory: manifest counts and lines still resolve from the repo top.
cat > spec23.md <<'EOF'
## Files in scope
- package.json
EOF
sed -i 's/"x": "1.0.0"/"x": "2.0.0"/' wt/package.json
run 5 "$SD" --spec "$tmp/spec23.md" --base "$base" --worktree "$wt/src"
if [ "$rc" = 1 ] \
  && grep -qxF "  package.json (+1 -1)" out \
  && grep -qE '^    - .*1\.0\.0' out \
  && grep -qE '^    \+ .*2\.0\.0' out; then
  ok "case 23: --worktree subdirectory still reports package.json (+1 -1) with its -/+ lines"
else
  bad "case 23: rc=$rc out=$(out)"
fi
reset_wt

# 24. --worktree "$wt/src" with an untracked top-level x.sh (out of scope) and untracked top-level requirements.txt
# -> exit 1, both listed under out of scope, requirements.txt also under manifests changed.
echo "topx" > wt/x.sh
echo "flask==2.0" > wt/requirements.txt
run 5 "$SD" --spec "$tmp/spec1.md" --base "$base" --worktree "$wt/src"
if [ "$rc" = 1 ] \
  && grep -qxF "scope-drift: out of scope (2):" out \
  && grep -qxF "  requirements.txt" out \
  && grep -qxF "  x.sh" out \
  && grep -qxF "scope-drift: manifests changed (1):" out \
  && grep -qxF "  requirements.txt (+1 -0)" out \
  && grep -qxF "    + flask==2.0" out; then
  ok "case 24: --worktree subdir lists untracked top-level x.sh and requirements.txt"
else
  bad "case 24: rc=$rc out=$(out) err=$(err)"
fi
reset_wt

# 25. Corrupt index (printf 'garbage' > "$wt/.git/index") -> exit 2 and stderr names failed; restore after.
printf 'garbage' > "$wt/.git/index"
run 5 "$SD" --spec "$tmp/spec1.md" --base "$base" --worktree "$wt"
rc25=$rc
err25=$(err)
rm -f "$wt/.git/index"
git -C "$wt" read-tree "$base"
reset_wt
if [ "$rc25" = 2 ] && grep -qF "git diff failed" <<<"$err25"; then
  ok "case 25: corrupt .git/index exits 2 and stderr names git diff failed"
else
  bad "case 25: rc=$rc25 err=$err25"
fi

# 26. A COMMITTED out-of-scope change (commit src/b.sh after base) plus a STAGED-only out-of-scope new file
# -> exit 1, both listed.
echo "b2" > wt/src/b.sh
git -C "$wt" add src/b.sh
git -C "$wt" commit -qm "commit out-of-scope b"
echo "staged1" > wt/src/staged.sh
git -C "$wt" add src/staged.sh
run 5 "$SD" --spec "$tmp/spec1.md" --base "$base" --worktree "$wt"
if [ "$rc" = 1 ] \
  && grep -qxF "scope-drift: out of scope (2):" out \
  && grep -qxF "  src/b.sh" out \
  && grep -qxF "  src/staged.sh" out; then
  ok "case 26: committed and staged-only out-of-scope changes vs base are both listed"
else
  bad "case 26: rc=$rc out=$(out)"
fi
reset_wt

# 27. Nested manifests: sub/dir/package.json and sub/Cargo.lock changed, both in scope
# -> both under manifests changed; the Cargo.lock line shows counts only.
cat > spec27.md <<'EOF'
## Files in scope
- sub/
EOF
mkdir -p "$wt/sub/dir"
printf '{\n  "name": "subpkg"\n}\n' > wt/sub/dir/package.json
printf '# sub lock\nv = 1\n' > wt/sub/Cargo.lock
run 5 "$SD" --spec "$tmp/spec27.md" --base "$base" --worktree "$wt"
if [ "$rc" = 1 ] \
  && ! grep -q "out of scope" out \
  && grep -qxF "scope-drift: manifests changed (2):" out \
  && grep -qxF "  sub/Cargo.lock (+2 -0)" out \
  && grep -qxF "  sub/dir/package.json (+3 -0)" out \
  && grep -qxF '    +   "name": "subpkg"' out \
  && ! grep -q "sub lock" out; then
  ok "case 27: nested sub/dir/package.json and sub/Cargo.lock both reported; Cargo.lock shows counts only"
else
  bad "case 27: rc=$rc out=$(out)"
fi
reset_wt

# 28. Lockfile list: go.sum, app-lock.json, npm-shrinkwrap.json each changed -> each listed with counts only and no content lines.
cat > spec28.md <<'EOF'
## Files in scope
- go.sum
- app-lock.json
- npm-shrinkwrap.json
EOF
echo "mod v1.0.0 h1:abc=" > wt/go.sum
echo '{"lockfileVersion":1}' > wt/app-lock.json
echo '{"lockfileVersion":2}' > wt/npm-shrinkwrap.json
run 5 env SYG_SCOPE_DRIFT_MANIFESTS='*-lock.json' "$SD" --spec "$tmp/spec28.md" --base "$base" --worktree "$wt"
if [ "$rc" = 1 ] \
  && ! grep -q "out of scope" out \
  && grep -qxF "scope-drift: manifests changed (3):" out \
  && grep -qxF "  app-lock.json (+1 -0)" out \
  && grep -qxF "  go.sum (+1 -0)" out \
  && grep -qxF "  npm-shrinkwrap.json (+1 -0)" out \
  && ! grep -qE '^    [+-] ' out; then
  ok "case 28: go.sum, app-lock.json, npm-shrinkwrap.json show counts only with no content lines"
else
  bad "case 28: rc=$rc out=$(out)"
fi
reset_wt

# 29. Tracked 20-line cap: a tracked package.json rewritten so the diff has more than 20 -/+ lines
# -> exactly 20 content lines, then '      ... K more' with the right K (- and + both counted).
for i in $(seq 1 22); do echo "line-$i"; done > wt/package.json
run 5 "$SD" --spec "$tmp/spec13.md" --base "$base" --worktree "$wt"
c29_lines=$(grep -cE '^    [+-] ' out)
if [ "$rc" = 1 ] \
  && grep -qxF "  package.json (+22 -6)" out \
  && [ "$c29_lines" = 20 ] \
  && grep -qxF "      ... 8 more" out; then
  ok "case 29: tracked package.json rewrite caps at 20 -/+ lines and prints '      ... 8 more'"
else
  bad "case 29: rc=$rc c29_lines=$c29_lines out=$(out)"
fi
reset_wt

# 30. A spec file with CRLF line endings and a '## Files in scope   ' heading with trailing spaces still parses.
printf '## Files in scope   \r\n- src/a.sh\r\n' > spec30.md
echo "a2" > wt/src/a.sh
run 5 "$SD" --spec "$tmp/spec30.md" --base "$base" --worktree "$wt"
if [ "$rc" = 0 ] && [ "$(out)" = "$want_clean1" ]; then
  ok "case 30: spec with CRLF and trailing spaces on '## Files in scope   ' parses cleanly"
else
  bad "case 30: rc=$rc out=$(out) err=$(err)"
fi
reset_wt

# 31. --spec good.md --spec nosection.md -> exit 2 naming nosection.md.
echo "# No files section" > nosection.md
run 5 "$SD" --spec "$tmp/spec1.md" --spec "$tmp/nosection.md" --base "$base" --worktree "$wt"
if [ "$rc" = 2 ] && grep -qF "nosection.md" err; then
  ok "case 31: --spec good.md --spec nosection.md exits 2 naming nosection.md"
else
  bad "case 31: rc=$rc err=$(err)"
fi

# 32. -h -> exit 0, same text as --help.
run 5 "$SD" --help
help_full=$(out)
run 5 "$SD" -h
if [ "$rc" = 0 ] && [ "$(out)" = "$help_full" ]; then
  ok "case 32: -h exits 0 with the same text as --help"
else
  bad "case 32: rc=$rc"
fi

# 33. diff.relative true in the fixture repo with --worktree "$wt/src" and an out-of-scope change at top level -> still listed. This pins "git runs from the repo top"; from the top, diff.relative filters nothing, so it does not pin --no-relative (defence in depth only).
git -C "$wt" config diff.relative true
echo "readme2" > wt/README.md
run 5 "$SD" --spec "$tmp/spec1.md" --base "$base" --worktree "$wt/src"
rc33=$rc
out33=$(out)
git -C "$wt" config --unset diff.relative
reset_wt
if [ "$rc33" = 1 ] \
  && grep -qxF "scope-drift: out of scope (1):" <<<"$out33" \
  && grep -qxF "  README.md" <<<"$out33"; then
  ok "case 33: diff.relative=true with --worktree subdir still lists top-level out-of-scope change"
else
  bad "case 33: rc=$rc33 out=$out33"
fi

# 34. Moved base: branch side forks from $base with an in-scope src/a.sh commit while main moves on
# with an out-of-scope lib/x/y.sh commit; on side, --base main resolves to the fork point ($short).
git -C "$wt" checkout -q -b side "$base"
echo "a2" > "$wt/src/a.sh"
git -C "$wt" add src/a.sh
git -C "$wt" commit -qm "side in-scope a"
git -C "$wt" checkout -q main
echo "lib2" > "$wt/lib/x/y.sh"
git -C "$wt" add lib/x/y.sh
git -C "$wt" commit -qm "main moved on"
main_short=$(git -C "$wt" rev-parse --short main)
git -C "$wt" checkout -q side
run 5 "$SD" --spec "$tmp/spec1.md" --base main --worktree "$wt"
rc34=$rc
out34=$(out)
git -C "$wt" checkout -q main
reset_wt
git -C "$wt" branch -q -D side
want34="scope-drift: clean (1 changed paths, all in scope; no manifest changes) vs $short (fork point of main)"
if [ "$rc34" = 0 ] && [ "$out34" = "$want34" ] && [ "$main_short" != "$short" ]; then
  ok "case 34: moved --base main resolves to fork point ($short, labelled), not main tip ($main_short)"
else
  bad "case 34: rc=$rc34 out=$out34 want=$want34 main_short=$main_short"
fi

# 35. Unrelated history: --base names an orphan commit with no shared history with HEAD -> exit 2,
# stderr contains 'shares no history', and stdout is empty.
empty_tree=$(git -C "$wt" hash-object -w -t tree /dev/null)
orphan=$(git -C "$wt" commit-tree "$empty_tree" -m "orphan")
run 5 "$SD" --spec "$tmp/spec1.md" --base "$orphan" --worktree "$wt"
if [ "$rc" = 2 ] && [ ! -s out ] && grep -qF "scope-drift: base '$orphan' shares no history with HEAD" err; then
  ok "case 35: unrelated history --base orphan commit exits 2 with 'shares no history'"
else
  bad "case 35: rc=$rc out=$(out) err=$(err)"
fi

# 36. Shallow fallback: depth-1 clone where merge-base origin/main HEAD fails falls back to REF as given.
git -C "$wt" checkout -q -b side "$base"
echo "a2" > "$wt/src/a.sh"
git -C "$wt" add src/a.sh
git -C "$wt" commit -qm "side in-scope a"
git -C "$wt" checkout -q main
echo "lib2" > "$wt/lib/x/y.sh"
git -C "$wt" add lib/x/y.sh
git -C "$wt" commit -qm "main moved on"
git clone -q --depth 1 --no-single-branch "file://$wt" "$tmp/shallow"
git -C "$tmp/shallow" checkout -q side
if git -C "$tmp/shallow" merge-base origin/main HEAD >/dev/null 2>&1; then
  git -C "$wt" checkout -q main
  reset_wt
  git -C "$wt" branch -q -D side
  rm -rf "$tmp/shallow"
  bad "case 36: git merge-base origin/main HEAD unexpectedly succeeded in shallow clone"
else
  run 5 "$SD" --spec "$tmp/spec1.md" --base origin/main --worktree "$tmp/shallow"
  rc36=$rc
  out36=$(out)
  err36=$(err)
  git -C "$wt" checkout -q main
  reset_wt
  git -C "$wt" branch -q -D side
  rm -rf "$tmp/shallow"
  if [ "$rc36" = 1 ] \
    && grep -qxF "scope-drift: out of scope (1):" <<<"$out36" \
    && grep -qxF "  lib/x/y.sh" <<<"$out36" \
    && grep -qF "shallow clone: no merge-base" <<<"$err36" \
    && grep -qF "(shallow clone, or unrelated history)" <<<"$err36" \
    && ! grep -qF "shares no history" <<<"$err36"; then
    ok "case 36: shallow clone with no merge-base falls back to --base ref as given with warning"
  else
    bad "case 36: rc=$rc36 out=$out36 err=$err36"
  fi
fi

# 37. Base ahead of HEAD: branch ahead is at $base + 1 commit, HEAD on main at $base, no working changes.
git -C "$wt" checkout -q -b ahead "$base"
echo "lib2" > "$wt/lib/x/y.sh"
git -C "$wt" add lib/x/y.sh
git -C "$wt" commit -qm "ahead commit"
git -C "$wt" checkout -q main
run 5 "$SD" --spec "$tmp/spec1.md" --base ahead --worktree "$wt"
rc37=$rc
out37=$(out)
err37=$(err)
reset_wt
git -C "$wt" branch -q -D ahead
want37="scope-drift: clean (0 changed paths, all in scope; no manifest changes) vs $short (fork point of ahead)"
if [ "$rc37" = 0 ] && [ "$out37" = "$want37" ] && grep -qF "is ahead of HEAD" <<<"$err37"; then
  ok "case 37: --base ahead of HEAD exits 0 with fork-point label and warns on stderr"
else
  bad "case 37: rc=$rc37 out=$out37 want=$want37 err=$err37"
fi

# 38. Project config .claude/seyag.toml loads syg_scope_drift_manifests when env is unset;
# 38b. SYG_SCOPE_DRIFT_MANIFESTS='' in env overrides config even when empty.
mkdir -p "$tmp/proj38/.claude"
printf 'syg_scope_drift_manifests = "*.gemspec"\n' > "$tmp/proj38/.claude/seyag.toml"
echo "gem2" > wt/x.gemspec
run 5 env -u SYG_SCOPE_DRIFT_MANIFESTS CLAUDE_PROJECT_DIR="$tmp/proj38" "$SD" --spec "$tmp/spec15.md" --base "$base" --worktree "$wt"
if [ "$rc" = 1 ] && grep -qxF "  x.gemspec (+1 -1)" out; then
  ok "case 38: project .claude/seyag.toml syg_scope_drift_manifests loads when env is unset"
else
  bad "case 38: rc=$rc out=$(out) err=$(err)"
fi
run 5 env SYG_SCOPE_DRIFT_MANIFESTS='' CLAUDE_PROJECT_DIR="$tmp/proj38" "$SD" --spec "$tmp/spec15.md" --base "$base" --worktree "$wt"
if [ "$rc" = 0 ] && [ "$(out)" = "$want_clean1" ]; then
  ok "case 38b: empty SYG_SCOPE_DRIFT_MANIFESTS='' in env overrides config file and exits 0"
else
  bad "case 38b: rc=$rc out=$(out) err=$(err)"
fi
reset_wt

# 39. Bash floor (STATIC check: the guard text is not run under an old bash). The
# 'needs bash >= 4.4' guard must sit before the first mapfile line.
guard_ln=$(awk 'index($0, "needs bash >= 4.4") { print NR; exit }' "$SD")
mapfile_ln=$(awk '/^mapfile/ { print NR; exit }' "$SD")
if [ -n "$guard_ln" ] && [ -n "$mapfile_ln" ] && [ "$guard_ln" -lt "$mapfile_ln" ]; then
  ok "case 39: bash >= 4.4 guard (line $guard_ln) precedes the first mapfile (line $mapfile_ln) [static check]"
else
  bad "case 39: guard_ln=$guard_ln mapfile_ln=$mapfile_ln"
fi

# 40. Unborn HEAD: a repo with no commits exits 2 'HEAD has no commits yet', with --base HEAD and
# without --base; stdout empty.
git init -q -b main "$tmp/unborn"
echo "x" > "$tmp/unborn/untracked.txt"
run 5 "$SD" --spec "$tmp/spec1.md" --base HEAD --worktree "$tmp/unborn"
rc40a=$rc
err40a=$(err)
out40a=$(out)
run 5 "$SD" --spec "$tmp/spec1.md" --worktree "$tmp/unborn"
rc40b=$rc
err40b=$(err)
out40b=$(out)
if [ "$rc40a" = 2 ] && [ "$rc40b" = 2 ] \
  && grep -qF "HEAD has no commits yet" <<<"$err40a" && grep -qF "HEAD has no commits yet" <<<"$err40b" \
  && [ -z "$out40a" ] && [ -z "$out40b" ]; then
  ok "case 40: unborn HEAD exits 2 with 'HEAD has no commits yet' with and without --base; stdout empty"
else
  bad "case 40: a=($rc40a/$err40a) b=($rc40b/$err40b) out=($out40a|$out40b)"
fi

# 41. --base HEAD and --base $base on a clean worktree (HEAD == $base): exit 0, exact want_clean0
# (no fork-point label because the base is not reduced), stderr empty (no ahead note).
run 5 "$SD" --spec "$tmp/spec1.md" --base HEAD --worktree "$wt"
rc41a=$rc
out41a=$(out)
err41a=$(err)
run 5 "$SD" --spec "$tmp/spec1.md" --base "$base" --worktree "$wt"
rc41b=$rc
out41b=$(out)
err41b=$(err)
if [ "$rc41a" = 0 ] && [ "$out41a" = "$want_clean0" ] && [ -z "$err41a" ] \
  && [ "$rc41b" = 0 ] && [ "$out41b" = "$want_clean0" ] && [ -z "$err41b" ]; then
  ok "case 41: --base HEAD and --base \$base on a clean tree exit 0 with plain label and empty stderr"
else
  bad "case 41: a=($rc41a/$out41a/$err41a) b=($rc41b/$out41b/$err41b)"
fi

# Fake git for cases 42-43: a wrapper on PATH that exits 128 for any call whose argv contains the
# exact word in $FAKE_GIT_FAIL, and execs the real git (path captured before PATH is changed).
REAL_GIT=$(command -v git)
mkdir -p "$tmp/gitbin"
cat > "$tmp/gitbin/git" <<EOF
#!/bin/bash
for a in "\$@"; do
  if [ "\$a" = "\${FAKE_GIT_FAIL:-__none__}" ]; then
    echo "fake git: forced failure for \$a" >&2
    exit 128
  fi
done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$tmp/gitbin/git"

# 42. Only ls-files fails (fake git, FAKE_GIT_FAIL=ls-files) -> exit 2 naming 'git ls-files failed'.
run 5 env PATH="$tmp/gitbin:$PATH" FAKE_GIT_FAIL=ls-files "$SD" --spec "$tmp/spec1.md" --base "$base" --worktree "$wt"
rc42=$rc
if [ "$rc42" = 2 ] && grep -qF "git ls-files failed" err; then
  ok "case 42: fake git failing only ls-files exits 2 with 'git ls-files failed'"
else
  bad "case 42: rc=$rc42 out=$(out) err=$(err)"
fi

# 43. A listed tracked manifest with only the --numstat read failing -> '  package.json (+? -?)' with
# its -/+ lines still shown; only the -U0 read failing -> '    (git diff failed; lines not shown)'.
printf '{\n  "name": "demo2",\n  "dependencies": {\n    "x": "1.0.0"\n  }\n}\n' > wt/package.json
run 5 env PATH="$tmp/gitbin:$PATH" FAKE_GIT_FAIL=--numstat "$SD" --spec "$tmp/spec13.md" --base "$base" --worktree "$wt"
rc43a=$rc
out43a=$(out)
run 5 env PATH="$tmp/gitbin:$PATH" FAKE_GIT_FAIL=-U0 "$SD" --spec "$tmp/spec13.md" --base "$base" --worktree "$wt"
rc43b=$rc
out43b=$(out)
if [ "$rc43a" = 1 ] && grep -qxF "  package.json (+? -?)" <<<"$out43a" \
  && grep -qE '^    [-+] ' <<<"$out43a" \
  && [ "$rc43b" = 1 ] && grep -qxF "  package.json (+1 -1)" <<<"$out43b" \
  && grep -qxF "    (git diff failed; lines not shown)" <<<"$out43b" \
  && ! grep -qE '^    [-+] ' <<<"$out43b"; then
  ok "case 43: failed --numstat prints (+? -?) with lines; failed -U0 prints '(git diff failed; lines not shown)'"
else
  bad "case 43: a=($rc43a) out=$out43a | b=($rc43b) out=$out43b"
fi
reset_wt

# 44. TRACKED nested manifest sub/dir/package.json, committed at base44 then modified in the tree;
# spec27 ('- sub/') -> exit 1 with its (+1 -1) header and -/+ lines via the :(top,literal) pathspec.
mkdir -p "$wt/sub/dir"
printf '{\n  "name": "nested1"\n}\n' > "$wt/sub/dir/package.json"
git -C "$wt" add sub/dir/package.json
git -C "$wt" commit -qm "add tracked nested manifest"
base44=$(git -C "$wt" rev-parse HEAD)
printf '{\n  "name": "nested2"\n}\n' > "$wt/sub/dir/package.json"
run 5 "$SD" --spec "$tmp/spec27.md" --base "$base44" --worktree "$wt"
rc44=$rc
out44=$(out)
reset_wt
if [ "$rc44" = 1 ] && grep -qxF "  sub/dir/package.json (+1 -1)" <<<"$out44" \
  && grep -qxF '    -   "name": "nested1"' <<<"$out44" \
  && grep -qxF '    +   "name": "nested2"' <<<"$out44" \
  && ! grep -q "out of scope" <<<"$out44"; then
  ok "case 44: tracked nested sub/dir/package.json reports (+1 -1) with its -/+ lines"
else
  bad "case 44: rc=$rc44 out=$out44"
fi

# 45. Index-deleted manifest (git rm --cached, file still on disk) -> listed once with the git
# deletion counts and the '[untracked copy on disk]' tag, not as an all-added file.
git -C "$wt" rm -q --cached package.json
run 5 "$SD" --spec "$tmp/spec13.md" --base "$base" --worktree "$wt"
rc45=$rc
out45=$(out)
reset_wt
if [ "$rc45" = 1 ] && grep -qxF "  package.json (+0 -6) [untracked copy on disk]" <<<"$out45" \
  && ! grep -qE '^    \+ ' <<<"$out45"; then
  ok "case 45: index-deleted manifest on disk shows (+0 -6) [untracked copy on disk], not all-added"
else
  bad "case 45: rc=$rc45 out=$out45"
fi

# 46. Leading './' in a scope entry is stripped: '- ./src/a.sh' matches src/a.sh.
cat > spec46.md <<'EOF'
## Files in scope
- ./src/a.sh
EOF
echo "a2" > wt/src/a.sh
run 5 "$SD" --spec "$tmp/spec46.md" --base "$base" --worktree "$wt"
if [ "$rc" = 0 ] && [ "$(out)" = "$want_clean1" ]; then
  ok "case 46: scope entry '- ./src/a.sh' matches src/a.sh"
else
  bad "case 46: rc=$rc out=$(out) err=$(err)"
fi
reset_wt

# 47. Heading match is case-insensitive: '## files in scope' and '## FILES' open the section;
# '## Filesystem' and '## Files (out of scope)' do not (exit 2, no section).
printf '## files in scope\n- src/a.sh\n' > spec47a.md
printf '## FILES\n- src/a.sh\n' > spec47b.md
printf '## Filesystem\n- src/a.sh\n' > spec47c.md
printf '## Files (out of scope)\n- src/a.sh\n' > spec47d.md
echo "a2" > wt/src/a.sh
run 5 "$SD" --spec "$tmp/spec47a.md" --base "$base" --worktree "$wt"
rc47a=$rc
out47a=$(out)
run 5 "$SD" --spec "$tmp/spec47b.md" --base "$base" --worktree "$wt"
rc47b=$rc
out47b=$(out)
run 5 "$SD" --spec "$tmp/spec47c.md" --base "$base" --worktree "$wt"
rc47c=$rc
run 5 "$SD" --spec "$tmp/spec47d.md" --base "$base" --worktree "$wt"
rc47d=$rc
if [ "$rc47a" = 0 ] && [ "$out47a" = "$want_clean1" ] \
  && [ "$rc47b" = 0 ] && [ "$out47b" = "$want_clean1" ] \
  && [ "$rc47c" = 2 ] && [ "$rc47d" = 2 ]; then
  ok "case 47: '## files in scope' and '## FILES' open the section; '## Filesystem' and '## Files (out of scope)' do not"
else
  bad "case 47: a=$rc47a/$out47a b=$rc47b/$out47b c=$rc47c d=$rc47d"
fi
reset_wt

# 48. Extended manifest list: untracked pom.xml, deno.lock, gradle.lockfile and flake.lock, all in
# scope -> exit 1 with four manifests; pom.xml shows its + line, the three lockfiles counts only.
printf '<project/>\n' > wt/pom.xml
printf '{"version":1}\n' > wt/deno.lock
printf 'lockv = 1\n' > wt/gradle.lockfile
printf '{"nodes":{}}\n' > wt/flake.lock
cat > spec48.md <<'EOF'
## Files in scope
- pom.xml
- deno.lock
- gradle.lockfile
- flake.lock
EOF
run 5 "$SD" --spec "$tmp/spec48.md" --base "$base" --worktree "$wt"
rc48=$rc
out48=$(out)
if [ "$rc48" = 1 ] && grep -qxF "scope-drift: manifests changed (4):" <<<"$out48" \
  && grep -qxF "  pom.xml (+1 -0)" <<<"$out48" \
  && grep -qxF "    + <project/>" <<<"$out48" \
  && grep -qxF "  deno.lock (+1 -0)" <<<"$out48" \
  && grep -qxF "  gradle.lockfile (+1 -0)" <<<"$out48" \
  && grep -qxF "  flake.lock (+1 -0)" <<<"$out48" \
  && [ "$(grep -cE '^    [+-] ' <<<"$out48")" = 1 ]; then
  ok "case 48: pom.xml, deno.lock, gradle.lockfile and flake.lock are manifests; only pom.xml shows lines"
else
  bad "case 48: rc=$rc48 out=$out48"
fi
reset_wt

# 49. User config file: $XDG_CONFIG_HOME/seyag/config.toml syg_scope_drift_manifests = "*.gemspec"
# makes x.gemspec a manifest with the environment unset. The file is removed afterwards.
mkdir -p "$XDG_CONFIG_HOME/seyag"
printf 'syg_scope_drift_manifests = "*.gemspec"\n' > "$XDG_CONFIG_HOME/seyag/config.toml"
echo "gem2" > wt/x.gemspec
run 5 env -u SYG_SCOPE_DRIFT_MANIFESTS "$SD" --spec "$tmp/spec15.md" --base "$base" --worktree "$wt"
rc49=$rc
out49=$(out)
rm -f "$XDG_CONFIG_HOME/seyag/config.toml"
reset_wt
if [ "$rc49" = 1 ] && grep -qxF "  x.gemspec (+1 -1)" <<<"$out49"; then
  ok "case 49: user config file syg_scope_drift_manifests loads with the environment unset"
else
  bad "case 49: rc=$rc49 out=$out49"
fi

# 50. Default base with no remote: the error carries the shallow-clone / missing-remote hint.
run 5 "$SD" --spec "$tmp/spec1.md" --worktree "$wt"
rc50=$rc
err50=$(err)
if [ "$rc50" = 2 ] && grep -qF "a missing remote or a shallow clone can cause this" <<<"$err50"; then
  ok "case 50: no-base error names a missing remote or a shallow clone as a cause"
else
  bad "case 50: rc=$rc50 err=$err50"
fi

# 51. Binary manifests print '(binary)', never '(+0 -0)': a tracked bun.lockb (committed at base51,
# then rewritten) and an untracked new sub/bun.lockb, both in scope.
printf 'bun\000v1\n' > "$wt/bun.lockb"
git -C "$wt" add bun.lockb
git -C "$wt" commit -qm "add binary lockfile"
base51=$(git -C "$wt" rev-parse HEAD)
printf 'bun\000v2\n' > "$wt/bun.lockb"
mkdir -p "$wt/sub"
printf 'app\000v1\n' > "$wt/sub/bun.lockb"
printf '## Files in scope\n- bun.lockb\n- sub/bun.lockb\n' > spec51.md
run 5 "$SD" --spec "$tmp/spec51.md" --base "$base51" --worktree "$wt"
rc51=$rc
out51=$(out)
reset_wt
if [ "$rc51" = 1 ] && grep -qxF "  bun.lockb (binary)" <<<"$out51" \
  && grep -qxF "  sub/bun.lockb (binary)" <<<"$out51" \
  && ! grep -qF "(+0 -0)" <<<"$out51"; then
  ok "case 51: tracked and untracked binary lockfiles print (binary), not (+0 -0)"
else
  bad "case 51: rc=$rc51 out=$out51"
fi

echo "scope-drift probe: $pass passed, $fail failed"
[ "$fail" = 0 ]
