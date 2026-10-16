#!/bin/bash
# Fixture check for bin/whitespace-only-diff against canned diffs and a throwaway git repo.
# Usage: tests/whitespace-only-diff.probe.sh   (from anywhere)
# Keep this probe under ~175 lines; grow it only to pin a behavior nothing else pins.

set -uo pipefail
BS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/plugins/seyag/bin/whitespace-only-diff"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

# 1. Reindent canned diff (two -/+ pairs differing only in leading spaces) -> exit 0
c1=$(cat <<'EOF'
diff --git a/a.py b/a.py
--- a/a.py
+++ b/a.py
@@ -1,2 +1,2 @@
-def f():
-  return 1
+  def f():
+    return 1
EOF
)
out=$(printf '%s\n' "$c1" | "$BS"); rc=$?
[ $rc = 0 ] && grep -qE '^whitespace-only: 2 pair\(s\) matched, 0 real changed line\(s\), 1 hunk\(s\)$' <<< "$out" \
  && ok "case 1: reindent canned diff exits 0 with exact summary" || bad "case 1 (rc $rc; out: $out)"

# 2. Internal-whitespace change (space -> tab, single -> double space, delete-all -foobar/+foo bar) -> exit 0
out=$(printf '@@ -1,3 +1,3 @@\n-foo bar\n-baz qux\n-foobar\n+foo\tbar\n+baz  qux\n+foo bar\n' | "$BS"); rc=$?
[ $rc = 0 ] && grep -qF "whitespace-only: 3 pair(s) matched, 0 real changed line(s), 1 hunk(s)" <<< "$out" \
  && ok "case 2: internal whitespace (tab, double space, delete-all -foobar/+foo bar) exits 0 (3 pairs)" || bad "case 2 (delete-all internal whitespace; rc $rc; out: $out)"

# 3. Blank-line insertion only (one bare +) -> exit 1
out=$(printf '@@ -1,0 +1,1 @@\n+\n' | "$BS"); rc=$?
[ $rc = 1 ] && grep -qF "real changes: 0 pair(s) matched, 1 real changed line(s), 1 hunk(s)" <<< "$out" \
  && ok "case 3: bare blank-line insertion exits 1" || bad "case 3 (rc $rc; out: $out)"

# 4. Content change foo -> bar -> exit 1, 0 pair(s) matched, 2 real changed line(s)
out=$(printf '@@ -1 +1 @@\n-foo\n+bar\n' | "$BS"); rc=$?
[ $rc = 1 ] && grep -qE '^real changes: 0 pair\(s\) matched, 2 real changed line\(s\), 1 hunk\(s\)$' <<< "$out" \
  && ok "case 4: content change foo -> bar exits 1 (0 pairs, 2 real)" || bad "case 4 (rc $rc; out: $out)"

# 5. Mixed: one equal pair + one unequal pair in one hunk -> exit 1
out=$(printf '@@ -1,2 +1,2 @@\n-  alpha\n-beta\n+alpha\n+gamma\n' | "$BS"); rc=$?
[ $rc = 1 ] && grep -qE '^real changes: 1 pair\(s\) matched, 2 real changed line\(s\), 1 hunk\(s\)$' <<< "$out" \
  && ok "case 5: mixed equal + unequal pair exits 1 (1 pair, 2 real, 1 hunk)" || bad "case 5 (rc $rc; out: $out)"

# 6. Removed blank line vs added blank line -> exit 0 (empty strings pair)
out=$(printf '@@ -1 +1 @@\n-\n+   \n' | "$BS"); rc=$?
[ $rc = 0 ] && grep -qF "whitespace-only: 1 pair(s) matched, 0 real changed line(s), 1 hunk(s)" <<< "$out" \
  && ok "case 6: removed blank line vs added blank line exits 0" || bad "case 6 (rc $rc; out: $out)"

# 7. Empty stdin -> exit 2, stdout "no changes: empty diff"
out=$("$BS" < /dev/null); rc=$?
[ $rc = 2 ] && [ "$out" = "no changes: empty diff" ] \
  && ok "case 7: empty stdin exits 2 with no changes: empty diff" || bad "case 7 (rc $rc; out: $out)"

# 8. Garbage text (not a diff) -> exit 2, stdout empty, stderr exact message
out=$(printf 'just some random prose\nnot a diff\n' | "$BS" 2>"$T/err"); rc=$?
err=$(cat "$T/err")
[ $rc = 2 ] && [ -z "$out" ] && [ "$err" = "whitespace-only-diff: input is not a unified diff" ] \
  && ok "case 8: garbage text exits 2, stdout empty, stderr exact not-a-unified-diff message" || bad "case 8 (rc $rc; out: $out; err: $err)"

# 9. Mode-change-only in a real git repo -> exit 1, no-line-hunks message
R="$T/repo"; mkdir -p "$R"
git -C "$R" init -q -b main
echo 'echo hi' > "$R/run.sh" && git -C "$R" add run.sh
git -C "$R" -c user.email=t@t -c user.name=t commit -qm init
chmod +x "$R/run.sh" && git -C "$R" add run.sh
out=$(git -C "$R" diff --cached -U0 | "$BS"); rc=$?
[ $rc = 1 ] && [ "$out" = "real changes: no line hunks (mode, binary or rename change)" ] \
  && ok "case 9: mode-change-only git diff exits 1 with no-line-hunks message" || bad "case 9 (rc $rc; out: $out)"

# 10. End-to-end git: second commit only reindents -> exit 0; amend with content change -> exit 1
git -C "$R" reset -q --hard HEAD
printf 'def g():\n  return 42\n' > "$R/f.py" && git -C "$R" add f.py
git -C "$R" -c user.email=t@t -c user.name=t commit -qm c1
printf 'def g():\n    return 42\n' > "$R/f.py"
git -C "$R" -c user.email=t@t -c user.name=t commit -qam c2
out=$(git -C "$R" diff -U0 HEAD~1 | "$BS"); rc=$?
[ $rc = 0 ] && grep -qF "whitespace-only: 1 pair(s) matched, 0 real changed line(s), 1 hunk(s)" <<< "$out" \
  && ok "case 10a: git diff -U0 HEAD~1 on reindent commit exits 0" || bad "case 10a (rc $rc; out: $out)"
printf 'def g():\n    return 43\n' > "$R/f.py"
git -C "$R" -c user.email=t@t -c user.name=t commit -qam c2-amended --amend
out=$(git -C "$R" diff -U0 HEAD~1 | "$BS"); rc=$?
[ $rc = 1 ] && grep -qF "real changes: 0 pair(s) matched, 2 real changed line(s), 1 hunk(s)" <<< "$out" \
  && ok "case 10b: amended content change exits 1" || bad "case 10b (rc $rc; out: $out)"

# 11. --json on case 1 and on empty stdin
j1=$(printf '%s\n' "$c1" | "$BS" --json); rc1=$?
if [ $rc1 = 0 ] && echo "$j1" | python3 -c '
import json, sys
o = json.load(sys.stdin)
assert o == {"verdict": "whitespace-only", "pairs": 2, "real": 0, "hunks": 1}, o
'; then ok "case 11a: --json on case 1 emits whitespace-only JSON object (exit 0)"
else bad "case 11a (rc $rc1; out: $j1)"; fi

j2=$("$BS" --json < /dev/null); rc2=$?
if [ $rc2 = 2 ] && echo "$j2" | python3 -c '
import json, sys
o = json.load(sys.stdin)
assert o == {"verdict": "no-changes", "pairs": 0, "real": 0, "hunks": 0}, o
'; then ok "case 11b: --json on empty stdin emits no-changes JSON object (exit 2)"
else bad "case 11b (rc $rc2; out: $j2)"; fi

# 12. "\ No newline at end of file" marker after a pair -> verdict unaffected (exit 0)
c12=$(cat <<'EOF'
diff --git a/t.txt b/t.txt
--- a/t.txt
+++ b/t.txt
@@ -1 +1 @@
-hello world
\ No newline at end of file
+  hello   world
\ No newline at end of file
EOF
)
out=$(printf '%s\n' "$c12" | "$BS"); rc=$?
[ $rc = 0 ] && grep -qF "whitespace-only: 1 pair(s) matched, 0 real changed line(s), 1 hunk(s)" <<< "$out" \
  && ok "case 12: no-newline marker ignored, pair still exits 0" || bad "case 12 (rc $rc; out: $out)"

# 13. File-argument input form: case 4's diff in a file -> exit 1, same message as case 4
printf '@@ -1 +1 @@\n-foo\n+bar\n' > "$T/d.patch"
out=$("$BS" "$T/d.patch"); rc=$?
[ $rc = 1 ] && [ "$out" = "real changes: 0 pair(s) matched, 2 real changed line(s), 1 hunk(s)" ] \
  && ok "case 13: file-argument input form exits 1 with case 4 message" || bad "case 13 (rc $rc; out: $out)"

# 14. Unknown flag: --nope -> exit 2, stdout empty, stderr non-empty and mentioning --help
out=$("$BS" --nope </dev/null 2>"$T/err14"); rc=$?
err=$(cat "$T/err14")
[ $rc = 2 ] && [ -z "$out" ] && grep -qF -- "--help" <<< "$err" \
  && ok "case 14: unknown flag exits 2, stdout empty, stderr mentions --help" || bad "case 14 (rc $rc; out: $out; err: $err)"

# 15. Non-UTF-8 stdin -> exit 2, stdout empty, stderr says not a unified diff
out=$(printf 'foo\xffbar\n' | "$BS" 2>"$T/err15"); rc=$?
err=$(cat "$T/err15")
[ $rc = 2 ] && [ -z "$out" ] && grep -qF "not a unified diff" <<< "$err" \
  && ok "case 15: non-UTF-8 stdin exits 2, stdout empty, stderr says not a unified diff" || bad "case 15 (rc $rc; out: $out; err: $err)"

# 16. Multi-file, multi-hunk -> exit 0 (pins per-hunk flush isolation and diff --git ending hunk before next ---/+++)
c16=$(printf '%s\n' \
  'diff --git a/one.py b/one.py' '--- a/one.py' '+++ b/one.py' \
  '@@ -1 +1 @@' '-def  a():' '+def a():' \
  'diff --git a/two.py b/two.py' '--- a/two.py' '+++ b/two.py' \
  '@@ -1 +1 @@' '-  z = 1' '+z = 1' \
  '@@ -5 +5 @@' '- q' '+q   ')
out=$(printf '%s\n' "$c16" | "$BS"); rc=$?
[ $rc = 0 ] && [ "$out" = "whitespace-only: 3 pair(s) matched, 0 real changed line(s), 3 hunk(s)" ] \
  && ok "case 16: multi-file, multi-hunk exits 0 (3 pairs, 0 real, 3 hunks)" || bad "case 16 (rc $rc; out: $out)"

# 17. Leading-dash content lines inside a hunk (deletion ---tick vs addition +---tick) -> exit 1 (pins line[1:] over lstrip)
out=$(printf '@@ -1 +1 @@\n---tick\n+---tick\n' | "$BS"); rc=$?
[ $rc = 1 ] && [ "$out" = "real changes: 0 pair(s) matched, 2 real changed line(s), 1 hunk(s)" ] \
  && ok "case 17: leading-dash content lines (---tick / +---tick) exit 1, pinning line[1:] over lstrip" || bad "case 17 (rc $rc; out: $out)"

exit $fail
