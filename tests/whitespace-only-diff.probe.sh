#!/bin/bash
# Fixture check for bin/whitespace-only-diff against canned diffs and a throwaway git repo.
# Usage: tests/whitespace-only-diff.probe.sh   (from anywhere)
# Keep this probe under ~400 lines; grow it only to pin a behavior nothing else pins.

set -uo pipefail
BS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/plugins/seyag/bin/whitespace-only-diff"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

# 1. Reindent canned diff (two -/+ pairs differing only in leading spaces) -> exit 0
c1=$(cat <<'EOF'
diff --git a/a.c b/a.c
--- a/a.c
+++ b/a.c
@@ -1,2 +1,2 @@
-int f() {
-  return 1;
+  int f() {
+    return 1;
EOF
)
out=$(printf '%s\n' "$c1" | "$BS"); rc=$?
[ $rc = 0 ] && grep -qE '^whitespace-only: 2 pair\(s\) matched, 0 real changed line\(s\), 1 hunk\(s\)$' <<< "$out" \
  && ok "case 1: reindent canned diff exits 0 with exact summary" || bad "case 1 (rc $rc; out: $out)"

# 2. Internal-whitespace run change (space -> tab, single -> double space) -> exit 0; token split (-foobar/+foo bar) -> exit 1
out=$(printf '@@ -1,2 +1,2 @@\n-foo bar\n-baz qux\n+foo\tbar\n+baz  qux\n' | "$BS" --lenient); rc=$?
[ $rc = 0 ] && grep -qF "whitespace-only: 2 pair(s) matched, 0 real changed line(s), 1 hunk(s)" <<< "$out" \
  && ok "case 2a: internal whitespace (tab, double space) exits 0 (2 pairs)" || bad "case 2a (rc $rc; out: $out)"
out=$(printf '@@ -1 +1 @@\n-foobar\n+foo bar\n' | "$BS"); rc=$?
[ $rc = 1 ] && [ "$out" = "real changes: 0 pair(s) matched, 2 real changed line(s), 1 hunk(s)" ] \
  && ok "case 2b: token split (-foobar/+foo bar) exits 1 (0 pairs, 2 real)" || bad "case 2b (rc $rc; out: $out)"

# 3. Blank-line insertion only (one bare +) -> exit 1
out=$(printf '@@ -1,0 +1,1 @@\n+\n' | "$BS"); rc=$?
[ $rc = 1 ] && grep -qF "real changes: 0 pair(s) matched, 1 real changed line(s), 1 hunk(s)" <<< "$out" \
  && ok "case 3: bare blank-line insertion exits 1" || bad "case 3 (rc $rc; out: $out)"

# 4. Content change foo -> bar -> exit 1, 0 pair(s) matched, 2 real changed line(s)
out=$(printf '@@ -1 +1 @@\n-foo\n+bar\n' | "$BS"); rc=$?
[ $rc = 1 ] && grep -qE '^real changes: 0 pair\(s\) matched, 2 real changed line\(s\), 1 hunk\(s\)$' <<< "$out" \
  && ok "case 4: content change foo -> bar exits 1 (0 pairs, 2 real)" || bad "case 4 (rc $rc; out: $out)"

# 5. Mixed: one equal pair + one unequal pair in one hunk -> exit 1
out=$(printf '@@ -1,2 +1,2 @@\n-  alpha\n-beta\n+alpha\n+gamma\n' | "$BS" --lenient); rc=$?
[ $rc = 1 ] && grep -qE '^real changes: 1 pair\(s\) matched, 2 real changed line\(s\), 1 hunk\(s\)$' <<< "$out" \
  && ok "case 5: mixed equal + unequal pair exits 1 (1 pair, 2 real, 1 hunk)" || bad "case 5 (rc $rc; out: $out)"

# 6. Removed blank line vs added blank line -> exit 0 (empty strings pair in lenient mode)
out=$(printf '@@ -1 +1 @@\n-\n+   \n' | "$BS" --lenient); rc=$?
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
printf 'int g() {\n  return 42;\n}\n' > "$R/f.c" && git -C "$R" add f.c
git -C "$R" -c user.email=t@t -c user.name=t commit -qm c1
printf 'int g() {\n    return 42;\n}\n' > "$R/f.c"
git -C "$R" -c user.email=t@t -c user.name=t commit -qam c2
out=$(git -C "$R" diff -U0 HEAD~1 | "$BS"); rc=$?
[ $rc = 0 ] && grep -qF "whitespace-only: 1 pair(s) matched, 0 real changed line(s), 1 hunk(s)" <<< "$out" \
  && ok "case 10a: git diff -U0 HEAD~1 on reindent commit exits 0" || bad "case 10a (rc $rc; out: $out)"
printf 'int g() {\n    return 43;\n}\n' > "$R/f.c"
git -C "$R" -c user.email=t@t -c user.name=t commit -qam c2-amended --amend
out=$(git -C "$R" diff -U0 HEAD~1 | "$BS"); rc=$?
[ $rc = 1 ] && grep -qF "real changes: 0 pair(s) matched, 2 real changed line(s), 1 hunk(s)" <<< "$out" \
  && ok "case 10b: amended content change exits 1" || bad "case 10b (rc $rc; out: $out)"

# 11. --json on case 1 and on empty stdin
j1=$(printf '%s\n' "$c1" | "$BS" --json); rc1=$?
if [ $rc1 = 0 ] && echo "$j1" | python3 -c '
import json, sys
o = json.load(sys.stdin)
assert o == {"verdict": "whitespace-only", "pairs": 2, "real": 0, "hunks": 1, "meta": 0}, o
'; then ok "case 11a: --json on case 1 emits whitespace-only JSON object (exit 0)"
else bad "case 11a (rc $rc1; out: $j1)"; fi

j2=$("$BS" --json < /dev/null); rc2=$?
if [ $rc2 = 2 ] && echo "$j2" | python3 -c '
import json, sys
o = json.load(sys.stdin)
assert o == {"verdict": "no-changes", "pairs": 0, "real": 0, "hunks": 0, "meta": 0}, o
'; then ok "case 11b: --json on empty stdin emits no-changes JSON object (exit 2)"
else bad "case 11b (rc $rc2; out: $j2)"; fi

# 12. "\ No newline at end of file" marker after a pair -> verdict unaffected (exit 0)
c12=$(cat <<'EOF'
diff --git a/t.c b/t.c
--- a/t.c
+++ b/t.c
@@ -1 +1 @@
-hello world
\ No newline at end of file
+hello   world
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
  'diff --git a/one.c b/one.c' '--- a/one.c' '+++ b/one.c' \
  '@@ -1 +1 @@' '-void  a() {}' '+void a() {}' \
  'diff --git a/two.js b/two.js' '--- a/two.js' '+++ b/two.js' \
  '@@ -1 +1 @@' '-  z = 1' '+z = 1' \
  '@@ -5 +5 @@' '- q' '+q   ')
out=$(printf '%s\n' "$c16" | "$BS"); rc=$?
[ $rc = 0 ] && [ "$out" = "whitespace-only: 3 pair(s) matched, 0 real changed line(s), 3 hunk(s)" ] \
  && ok "case 16: multi-file, multi-hunk exits 0 (3 pairs, 0 real, 3 hunks)" || bad "case 16 (rc $rc; out: $out)"

# 17. Leading-dash content lines inside a hunk (deletion ---tick vs addition +---tick) -> exit 1 (pins line[1:] over lstrip)
out=$(printf '@@ -1 +1 @@\n---tick\n+---tick\n' | "$BS"); rc=$?
[ $rc = 1 ] && [ "$out" = "real changes: 0 pair(s) matched, 2 real changed line(s), 1 hunk(s)" ] \
  && ok "case 17: leading-dash content lines (---tick / +---tick) exit 1, pinning line[1:] over lstrip" || bad "case 17 (rc $rc; out: $out)"

# 18. F1 mixed: whitespace-only hunk in a.c plus mode-only block in run.sh -> exit 1 with 1 metadata change(s)
c18=$(printf '%s\n' \
  'diff --git a/a.c b/a.c' '--- a/a.c' '+++ b/a.c' \
  '@@ -1 +1 @@' '-int x = 1;' '+  int x = 1;' \
  'diff --git a/run.sh b/run.sh' 'old mode 100644' 'new mode 100755')
out=$(printf '%s\n' "$c18" | "$BS"); rc=$?
[ $rc = 1 ] && [ "$out" = "real changes: 1 pair(s) matched, 0 real changed line(s), 1 hunk(s), 1 metadata change(s)" ] \
  && ok "case 18: F1 whitespace-only hunk + mode-only block exits 1 with 1 metadata change(s)" || bad "case 18 (rc $rc; out: $out)"

# 19. F1 rename+hunk: rename headers + whitespace-only hunk in one block -> exit 1 with 1 metadata change(s)
c19=$(printf '%s\n' \
  'diff --git a/x.c b/y.c' 'similarity index 90%' 'rename from x.c' 'rename to y.c' \
  '--- a/x.c' '+++ b/y.c' '@@ -1 +1 @@' '-int x = 1;' '+  int x = 1;')
out=$(printf '%s\n' "$c19" | "$BS"); rc=$?
[ $rc = 1 ] && [ "$out" = "real changes: 1 pair(s) matched, 0 real changed line(s), 1 hunk(s), 1 metadata change(s)" ] \
  && ok "case 19: F1 rename + whitespace-only hunk exits 1 with 1 metadata change(s)" || bad "case 19 (rc $rc; out: $out)"

# 20. F2 token join: string literal space deletion and keyword/identifier join -> exit 1
out=$(printf '@@ -1 +1 @@\n-s = "a b"\n+s = "ab"\n' | "$BS"); rc=$?
[ $rc = 1 ] && [ "$out" = "real changes: 0 pair(s) matched, 2 real changed line(s), 1 hunk(s)" ] \
  && ok "case 20a: F2 string space deletion (-s = \"a b\" / +s = \"ab\") exits 1" || bad "case 20a (rc $rc; out: $out)"
out=$(printf '@@ -1 +1 @@\n-return x\n+returnx\n' | "$BS"); rc=$?
[ $rc = 1 ] && [ "$out" = "real changes: 0 pair(s) matched, 2 real changed line(s), 1 hunk(s)" ] \
  && ok "case 20b: F2 token join (-return x / +returnx) exits 1" || bad "case 20b (rc $rc; out: $out)"

# 21. F3 Python reindent: a.py exits 1 (strict); same diff as a.c exits 0
c21=$(printf '%s\n' \
  'diff --git a/a.py b/a.py' '--- a/a.py' '+++ b/a.py' \
  '@@ -1,2 +1,2 @@' '-if x:' '-    y()' '+if x:' '+y()')
out=$(printf '%s\n' "$c21" | "$BS"); rc=$?
[ $rc = 1 ] && [ "$out" = "real changes: 1 pair(s) matched, 2 real changed line(s), 1 hunk(s)" ] \
  && ok "case 21a: F3 Python reindent (a.py) exits 1" || bad "case 21a (rc $rc; out: $out)"
out=$(printf '%s\n' "${c21//a.py/a.c}" | "$BS"); rc=$?
[ $rc = 0 ] && [ "$out" = "whitespace-only: 2 pair(s) matched, 0 real changed line(s), 1 hunk(s)" ] \
  && ok "case 21b: same reindent under a.c exits 0" || bad "case 21b (rc $rc; out: $out)"

# 22. --strict-indent on case 1's a.c reindent -> exit 1
out=$(printf '%s\n' "$c1" | "$BS" --strict-indent); rc=$?
[ $rc = 1 ] && [ "$out" = "real changes: 0 pair(s) matched, 4 real changed line(s), 1 hunk(s)" ] \
  && ok "case 22: --strict-indent on a.c reindent exits 1" || bad "case 22 (rc $rc; out: $out)"

# 23. --json on case 18 -> real-changes JSON object with meta: 1
j23=$(printf '%s\n' "$c18" | "$BS" --json); rc23=$?
if [ $rc23 = 1 ] && echo "$j23" | python3 -c '
import json, sys
o = json.load(sys.stdin)
assert o == {"verdict": "real-changes", "pairs": 1, "real": 0, "hunks": 1, "meta": 1}, o
'; then ok "case 23: --json on case 18 emits real-changes with meta: 1 (exit 1)"
else bad "case 23 (rc $rc23; out: $j23)"; fi

# 24. Blank line gaining spaces in strict a.py -> exit 1
out=$(printf 'diff --git a/a.py b/a.py\n--- a/a.py\n+++ b/a.py\n@@ -1 +1 @@\n-\n+    \n' | "$BS"); rc=$?
[ $rc = 1 ] && ok "case 24: blank line indented in a.py exits 1" || bad "case 24 (rc $rc; out: $out)"

DED=$'@@ -1,2 +1,2 @@\n-if x:\n-    y()\n+if x:\n+y()'

# 25. --no-prefix header .py -> exit 1
out=$(printf 'diff --git x.py x.py\n--- x.py\n+++ x.py\n%s\n' "$DED" | "$BS"); rc=$?
[ $rc = 1 ] && ok "case 25: --no-prefix .py dedent exits 1" || bad "case 25 (rc $rc; out: $out)"

# 26. diff.mnemonicPrefix (i/ w/) .py -> exit 1
out=$(printf 'diff --git i/x.py w/x.py\n--- i/x.py\n+++ w/x.py\n%s\n' "$DED" | "$BS"); rc=$?
[ $rc = 1 ] && ok "case 26: mnemonic i/ w/ .py dedent exits 1" || bad "case 26 (rc $rc; out: $out)"

# 27. Plain diff -u (--- a/x.py / +++ b/x.py, no diff --git) -> exit 1
out=$(printf -- '--- a/x.py\n+++ b/x.py\n%s\n' "$DED" | "$BS"); rc=$?
[ $rc = 1 ] && ok "case 27: plain --- a/x.py / +++ b/x.py dedent exits 1" || bad "case 27 (rc $rc; out: $out)"

# 28. Same diff with CRLF line endings -> exit 1
out=$(printf -- '--- a/x.py\r\n+++ b/x.py\r\n@@ -1,2 +1,2 @@\r\n-if x:\r\n-    y()\r\n+if x:\r\n+y()\r\n' | "$BS"); rc=$?
[ $rc = 1 ] && ok "case 28: CRLF plain .py dedent exits 1" || bad "case 28 (rc $rc; out: $out)"

# 29. +++ line with trailing tab timestamp -> exit 1
out=$(printf -- '--- a/x y.py\t2026-10-18 10:00:00\n+++ b/x y.py\t2026-10-18 10:00:00\n%s\n' "$DED" | "$BS"); rc=$?
[ $rc = 1 ] && ok "case 29: +++ b/x y.py with tab timestamp exits 1" || bad "case 29 (rc $rc; out: $out)"

# 30. Two-file plain diff -u -> exit 0 (headers after finished hunk are not content)
c30=$(printf '%s\n' \
  '--- a/a.c' '+++ b/a.c' '@@ -1 +1 @@' '-int a = 1;' '+  int a = 1;' \
  '--- a/b.c' '+++ b/b.c' '@@ -1 +1 @@' '-int b = 2;' '+  int b = 2;')
out=$(printf '%s\n' "$c30" | "$BS"); rc=$?
[ $rc = 0 ] && [ "$out" = "whitespace-only: 2 pair(s) matched, 0 real changed line(s), 2 hunk(s)" ] \
  && ok "case 30: two-file plain diff -u exits 0 (2 pairs, 0 real, 2 hunks)" || bad "case 30 (rc $rc; out: $out)"

# 31. Stray -x line after a finished @@ -1 +1 @@ hunk -> exit 1
out=$(printf '@@ -1 +1 @@\n-foo\n+  foo\n-x\n' | "$BS" --lenient); rc=$?
[ $rc = 1 ] && ok "case 31: stray -x after finished hunk exits 1" || bad "case 31 (rc $rc; out: $out)"

# 32. Makefile.am tab -> 4 spaces on a recipe line -> exit 1
out=$(printf -- '--- a/Makefile.am\n+++ b/Makefile.am\n@@ -1 +1 @@\n-\techo hi\n+    echo hi\n' | "$BS"); rc=$?
[ $rc = 1 ] && ok "case 32: Makefile.am recipe tab to spaces exits 1" || bad "case 32 (rc $rc; out: $out)"

# 33. Markdown trailing spaces (-line   / +line) -> exit 1 in a.md, exit 0 in a.c
out=$(printf -- '--- a/a.md\n+++ b/a.md\n@@ -1 +1 @@\n-line  \n+line\n' | "$BS"); rc=$?
[ $rc = 1 ] && ok "case 33a: trailing spaces in a.md exit 1" || bad "case 33a (rc $rc; out: $out)"
out=$(printf -- '--- a/a.c\n+++ b/a.c\n@@ -1 +1 @@\n-line  \n+line\n' | "$BS"); rc=$?
[ $rc = 0 ] && ok "case 33b: trailing spaces in a.c exit 0" || bad "case 33b (rc $rc; out: $out)"

# 34. diff --git header with unparseable path (single token, no ---/+++) on dedent -> exit 1
out=$(printf 'diff --git single\n%s\n' "$DED" | "$BS"); rc=$?
[ $rc = 1 ] && ok "case 34: unparseable diff --git path uses strict rule and exits 1" || bad "case 34 (rc $rc; out: $out)"

# 35. A blank context line stripped of its space still counts as context: the next file's ---/+++ are headers
out=$(printf -- '--- a/a.c\n+++ b/a.c\n@@ -1,2 +1,2 @@\n\n-int x;\n+ int x;\n--- a/b.c\n+++ b/b.c\n@@ -1 +1 @@\n-int y;\n+int  y;\n' | "$BS"); rc=$?
[ $rc = 0 ] && [ "$out" = "whitespace-only: 2 pair(s) matched, 0 real changed line(s), 2 hunk(s)" ] \
  && ok "case 35: space-stripped blank context line keeps hunk counts" || bad "case 35 (rc $rc; out: $out)"

# 36. Reviewer repro A: Binary files and Only in outside diff --git block -> exit 1
out=$(printf -- '--- a/x.c\n+++ b/x.c\n@@ -1 +1 @@\n-a b\n+a  b\nBinary files a/y.bin and b/y.bin differ\nOnly in b: new.py\n' | "$BS"); rc=$?
[ $rc = 1 ] && [ "$out" = "real changes: 1 pair(s) matched, 0 real changed line(s), 1 hunk(s), 2 metadata change(s)" ] \
  && ok "case 36: Binary files + Only in outside diff --git block exits 1 (2 meta)" || bad "case 36 (rc $rc; out: $out)"

# 37. diff -ru headers + whitespace pair, then diff -ru + Binary files -> exit 1
out=$(printf -- 'diff -ru a/x.c b/x.c\n--- a/x.c\n+++ b/x.c\n@@ -1 +1 @@\n-a b\n+a  b\ndiff -ru a/y b/y\nBinary files a/y and b/y differ\n' | "$BS"); rc=$?
[ $rc = 1 ] && [ "$out" = "real changes: 1 pair(s) matched, 0 real changed line(s), 1 hunk(s), 1 metadata change(s)" ] \
  && ok "case 37: diff -ru whitespace hunk + binary block exits 1 (1 meta)" || bad "case 37 (rc $rc; out: $out)"

# 38. Moved line across context lines inside one hunk -> exit 1
out=$(printf -- '--- a/x.c\n+++ b/x.c\n@@ -1,5 +1,5 @@\n-  return 1;\n int a;\n int b;\n int c;\n+return 1;\n' | "$BS"); rc=$?
[ $rc = 1 ] && ok "case 38: moved line across context in x.c exits 1" || bad "case 38 (rc $rc; out: $out)"

# 39. Whitespace-only changes on both sides of a context line in x.c -> exit 0 with 2 pair(s) matched
out=$(printf -- '--- a/x.c\n+++ b/x.c\n@@ -1,3 +1,3 @@\n-a  b\n+a b\n ctx\n-c  d\n+c d\n' | "$BS"); rc=$?
[ $rc = 0 ] && grep -qF "2 pair(s) matched" <<< "$out" \
  && ok "case 39: whitespace-only runs separated by context exit 0 with 2 pair(s) matched" || bad "case 39 (rc $rc; out: $out)"

# 40. Trailing whitespace after backslash continuation in x.sh -> exit 1
out=$(printf '%s\n' '--- a/x.sh' '+++ b/x.sh' '@@ -1 +1 @@' '-echo a \' '+echo a \ ' | "$BS"); rc=$?
[ $rc = 1 ] && ok "case 40: trailing space after final backslash in x.sh exits 1" || bad "case 40 (rc $rc; out: $out)"

# 41. .hs indent change -> exit 1
out=$(printf -- '--- a/x.hs\n+++ b/x.hs\n@@ -1 +1 @@\n-  f x\n+    f x\n' | "$BS"); rc=$?
[ $rc = 1 ] && ok "case 41: .hs indent change exits 1" || bad "case 41 (rc $rc; out: $out)"

# 42. Default strict exits 1 on .foo and Tiltfile reindent; SYG_WSDIFF_LENIENT_NAMES (.foo suffix or Tiltfile basename) exits 0
out1=$(printf -- '--- a/x.foo\n+++ b/x.foo\n@@ -1 +1 @@\n-  x\n+    x\n' | SYG_WSDIFF_LENIENT_NAMES=.foo "$BS"); rc1=$?
out2=$(printf -- '--- a/x.foo\n+++ b/x.foo\n@@ -1 +1 @@\n-  x\n+    x\n' | env -u SYG_WSDIFF_LENIENT_NAMES "$BS"); rc2=$?
out3=$(printf -- '--- a/Tiltfile\n+++ b/Tiltfile\n@@ -1 +1 @@\n-  x = 1\n+x = 1\n' | SYG_WSDIFF_LENIENT_NAMES=Tiltfile "$BS"); rc3=$?
out4=$(printf -- '--- a/Tiltfile\n+++ b/Tiltfile\n@@ -1 +1 @@\n-  x = 1\n+x = 1\n' | env -u SYG_WSDIFF_LENIENT_NAMES "$BS"); rc4=$?
[ $rc1 = 0 ] && [ $rc2 = 1 ] && [ $rc3 = 0 ] && [ $rc4 = 1 ] \
  && ok "case 42: SYG_WSDIFF_LENIENT_NAMES (.foo suffix, Tiltfile basename) exits 0; default strict exits 1" \
  || bad "case 42 (rc1 $rc1: $out1; rc2 $rc2: $out2; rc3 $rc3: $out3; rc4 $rc4: $out4)"

# 43. Asymmetric "\ No newline at end of file" in one change run -> exit 1
out=$(printf '%s\n' '--- a/x.txt' '+++ b/x.txt' '@@ -1 +1 @@' '-a' '\ No newline at end of file' '+a' | "$BS"); rc=$?
[ $rc = 1 ] && ok "case 43: asymmetric no-newline marker exits 1" || bad "case 43 (rc $rc; out: $out)"

# 44. CR difference on one side of a pair in x.sh -> exit 1
out=$(printf -- '--- a/x.sh\n+++ b/x.sh\n@@ -1 +1 @@\n-#!/bin/sh\n+#!/bin/sh\r\n' | "$BS"); rc=$?
[ $rc = 1 ] && ok "case 44: CR on only one side of pair in x.sh exits 1" || bad "case 44 (rc $rc; out: $out)"

# 45. Extensionless bin/tool indent change -> exit 1
out=$(printf 'diff --git a/bin/tool b/bin/tool\n--- a/bin/tool\n+++ b/bin/tool\n@@ -1 +1 @@\n-    return 1\n+return 1\n' | "$BS"); rc=$?
[ $rc = 1 ] && ok "case 45: extensionless bin/tool indent change exits 1" || bad "case 45 (rc $rc; out: $out)"

# 46. setup.cfg continuation dedent -> exit 1
out=$(printf -- '--- a/setup.cfg\n+++ b/setup.cfg\n@@ -1,2 +1,2 @@\n-deps =\n-    pytest\n+deps =\n+pytest\n' | "$BS"); rc=$?
[ $rc = 1 ] && ok "case 46: setup.cfg dedent exits 1" || bad "case 46 (rc $rc; out: $out)"

# 47. x.sh trailing-space removal -> exit 1
out=$(printf -- '--- a/x.sh\n+++ b/x.sh\n@@ -1 +1 @@\n-echo hi  \n+echo hi\n' | "$BS"); rc=$?
[ $rc = 1 ] && ok "case 47: x.sh trailing-space removal exits 1" || bad "case 47 (rc $rc; out: $out)"

# 48. Multi-suffix c.yaml.j2 dedent -> exit 1
out=$(printf -- '--- a/c.yaml.j2\n+++ b/c.yaml.j2\n@@ -1 +1 @@\n-  key: val\n+key: val\n' | "$BS"); rc=$?
[ $rc = 1 ] && ok "case 48: c.yaml.j2 dedent exits 1" || bad "case 48 (rc $rc; out: $out)"

# 49. x.c NBSP vs ASCII space -> exit 1
out=$(printf -- '--- a/x.c\n+++ b/x.c\n@@ -1 +1 @@\n-int x = 1;\n+int x =\xc2\xa01;\n' | "$BS"); rc=$?
[ $rc = 1 ] && [[ "$out" == "real changes: 0 pair(s)"* ]] && ok "case 49: x.c with NBSP exits 1" || bad "case 49 (rc $rc; out: $out)"

# 50. Symlink mode 120000 block -> exit 1 with metadata change(s)
out=$(printf '%s\n' 'diff --git a/lnk b/lnk' 'index 1111111..2222222 120000' '--- a/lnk' '+++ b/lnk' '@@ -1 +1 @@' '-target ' '\ No newline at end of file' '+target' '\ No newline at end of file' | "$BS"); rc=$?
[ $rc = 1 ] && grep -qF "metadata change(s)" <<< "$out" && ok "case 50: symlink 120000 block exits 1 with metadata change(s)" || bad "case 50 (rc $rc; out: $out)"

# 51. Lenient .js file with tabs->spaces and trailing-space removal -> exit 0
out=$(printf -- '--- a/app.js\n+++ b/app.js\n@@ -1 +1 @@\n-\tconst x = 1;   \n+  const x = 1;\n' | "$BS"); rc=$?
[ $rc = 0 ] && ok "case 51: lenient .js tabs->spaces and trailing-space removal exits 0" || bad "case 51 (rc $rc; out: $out)"

# 52. Strict internal whitespace (data.tsv tab->space, notes.txt double->single space) -> exit 1; lenient x.c -> exit 0
out=$(printf -- '--- a/data.tsv\n+++ b/data.tsv\n@@ -1 +1 @@\n-a\tb\n+a b\n' | "$BS"); rc1=$?
out2=$(printf -- '--- a/notes.txt\n+++ b/notes.txt\n@@ -1 +1 @@\n-a  b\n+a b\n' | "$BS"); rc2=$?
out3=$(printf -- '--- a/x.c\n+++ b/x.c\n@@ -1 +1 @@\n-a  b\n+a b\n' | "$BS"); rc3=$?
[ $rc1 = 1 ] && [ $rc2 = 1 ] && [ $rc3 = 0 ] && ok "case 52: strict data.tsv/notes.txt internal whitespace exits 1, lenient x.c exits 0" || bad "case 52 (rc1 $rc1: $out; rc2 $rc2: $out2; rc3 $rc3: $out3)"

# 53. diff -r File type-mismatch and Symbolic links differ lines -> exit 1 with 1 metadata change(s)
out=$(printf -- 'diff -ru a/x.c b/x.c\n--- a/x.c\n+++ b/x.c\n@@ -1 +1 @@\n-a  b\n+a b\nFile a/x is a regular file while file b/x is a directory\n' | "$BS"); rc1=$?
out2=$(printf -- 'diff -ru a/x.c b/x.c\n--- a/x.c\n+++ b/x.c\n@@ -1 +1 @@\n-a  b\n+a b\nSymbolic links a/l and b/l differ\n' | "$BS"); rc2=$?
[ $rc1 = 1 ] && grep -qF "1 metadata change(s)" <<< "$out" && [ $rc2 = 1 ] && grep -qF "1 metadata change(s)" <<< "$out2" \
  && ok "case 53: diff -r File/Symbolic links lines exit 1 with 1 metadata change(s)" || bad "case 53 (rc1 $rc1: $out; rc2 $rc2: $out2)"

# 54. Bare hunk dedent (-    y() / +y()) -> exit 1 without --lenient, exit 0 with --lenient
out=$(printf '@@ -1 +1 @@\n-    y()\n+y()\n' | "$BS"); rc1=$?
out2=$(printf '@@ -1 +1 @@\n-    y()\n+y()\n' | "$BS" --lenient); rc2=$?
[ $rc1 = 1 ] && [ $rc2 = 0 ] && ok "case 54: bare hunk dedent exits 1 by default, 0 with --lenient" || bad "case 54 (rc1 $rc1: $out; rc2 $rc2: $out2)"

# 55. Strict x.yaml internal space, Makefile trailing space, x.pug internal space, x.py trailing space -> exit 1
out1=$(printf -- '--- a/x.yaml\n+++ b/x.yaml\n@@ -1 +1 @@\n-name: foo  bar\n+name: foo bar\n' | "$BS"); rc1=$?
out2=$(printf -- '--- a/Makefile\n+++ b/Makefile\n@@ -1 +1 @@\n-DIR = out \n+DIR = out\n' | "$BS"); rc2=$?
out3=$(printf -- '--- a/x.pug\n+++ b/x.pug\n@@ -1 +1 @@\n-pre a  b\n+pre a b\n' | "$BS"); rc3=$?
out4=$(printf -- '--- a/x.py\n+++ b/x.py\n@@ -1 +1 @@\n-x = 1   \n+x = 1\n' | "$BS"); rc4=$?
[ $rc1 = 1 ] && [ $rc2 = 1 ] && [ $rc3 = 1 ] && [ $rc4 = 1 ] \
  && ok "case 55: x.yaml/Makefile/x.pug/x.py internal or trailing whitespace exits 1" \
  || bad "case 55 (rc1 $rc1: $out1; rc2 $rc2: $out2; rc3 $rc3: $out3; rc4 $rc4: $out4)"

# 56. .hs internal alignment change -> exit 1
out=$(printf -- '--- a/x.hs\n+++ b/x.hs\n@@ -1 +1 @@\n-f x  = 1\n+f x = 1\n' | "$BS"); rc=$?
[ $rc = 1 ] && ok "case 56: .hs internal alignment change exits 1" || bad "case 56 (rc $rc; out: $out)"

# 57. Strict .tsv blank-vs-spaces line -> exit 1; lenient .c blank-vs-spaces line -> exit 0
out1=$(printf -- '--- a/x.tsv\n+++ b/x.tsv\n@@ -1 +1 @@\n-\n+   \n' | "$BS"); rc1=$?
out2=$(printf -- '--- a/x.c\n+++ b/x.c\n@@ -1 +1 @@\n-\n+   \n' | "$BS"); rc2=$?
[ $rc1 = 1 ] && [ $rc2 = 0 ] \
  && ok "case 57: .tsv blank-vs-spaces line exits 1, lenient .c blank-vs-spaces line exits 0" \
  || bad "case 57 (rc1 $rc1: $out1; rc2 $rc2: $out2)"

# 58. Lenient .c line after backslash continuation (context or same-side change) compares leading whitespace -> exit 1
out1=$(printf '%s\n' '--- a/x.c' '+++ b/x.c' '@@ -1,2 +1,2 @@' ' #define X a \' '-  b' '+b' | "$BS"); rc1=$?
out2=$(printf '%s\n' '--- a/x.c' '+++ b/x.c' '@@ -1,2 +1,2 @@' '-#define X a \' '-  b' '+#define X a \' '+b' | "$BS"); rc2=$?
out3=$(printf '%s\n' '--- a/x.c' '+++ b/x.c' '@@ -1,2 +1,2 @@' ' #define X a \' '-  b  c' '+  b c' | "$BS"); rc3=$?
[ $rc1 = 1 ] && [ $rc2 = 1 ] && [ $rc3 = 0 ] \
  && ok "case 58: lenient .c leading whitespace after backslash continuation exits 1 (internal-only exits 0)" \
  || bad "case 58 (rc1 $rc1: $out1; rc2 $rc2: $out2; rc3 $rc3: $out3)"

# 59. Metadata blocks: copy from/to with whitespace-only hunk (1 meta), deleted file mode, new file mode + line, GIT binary patch -> exit 1
out1=$(printf '%s\n' 'diff --git a/x.c b/y.c' 'copy from x.c' 'copy to y.c' '--- a/x.c' '+++ b/y.c' '@@ -1 +1 @@' '-int x = 1;' '+  int x = 1;' | "$BS"); rc1=$?
out2=$(printf '%s\n' 'diff --git a/x.c b/x.c' 'deleted file mode 100644' | "$BS"); rc2=$?
out3=$(printf '%s\n' 'diff --git a/x.c b/x.c' 'new file mode 100644' '--- /dev/null' '+++ b/x.c' '@@ -0,0 +1 @@' '+int x;' | "$BS"); rc3=$?
out4=$(printf '%s\n' 'diff --git a/x.bin b/x.bin' 'index 1111111..2222222 100644' 'GIT binary patch' 'literal 0' 'HcmV?d00001' | "$BS"); rc4=$?
[ $rc1 = 1 ] && grep -qF "1 metadata change(s)" <<< "$out1" && [ $rc2 = 1 ] && [ $rc3 = 1 ] && [ $rc4 = 1 ] \
  && ok "case 59: copy from/to (1 meta), deleted file mode, new file mode, and GIT binary patch exit 1" \
  || bad "case 59 (rc1 $rc1: $out1; rc2 $rc2: $out2; rc3 $rc3: $out3; rc4 $rc4: $out4)"

# 60. Quoted diff --git "a/x y.py" "b/x y.py" header with no +++ line and a dedent -> exit 1 (strict via quoted "b/..." branch)
out=$(printf 'diff --git "a/x y.py" "b/x y.py"\n%s\n' "$DED" | "$BS"); rc=$?
[ $rc = 1 ] && ok "case 60: quoted diff --git \"a/x y.py\" \"b/x y.py\" without +++ exits 1 on dedent" || bad "case 60 (rc $rc; out: $out)"

# 61. Pruned suffixes (.scala, .php, .rb) reindent, .c continuation with trailing spaces, and stray garbage line in hunk -> exit 1
out1=$(printf -- '--- a/x.scala\n+++ b/x.scala\n@@ -1 +1 @@\n-  x\n+    x\n' | "$BS"); rc1=$?
out2=$(printf -- '--- a/x.php\n+++ b/x.php\n@@ -1 +1 @@\n-  $x = 1;\n+$x = 1;\n' | "$BS"); rc2=$?
out3=$(printf -- '--- a/x.rb\n+++ b/x.rb\n@@ -1 +1 @@\n-  x = 1\n+x = 1\n' | "$BS"); rc3=$?
out4=$(printf '%s\n' '--- a/x.c' '+++ b/x.c' '@@ -1,2 +1,2 @@' ' #define X a \  ' '-  b' '+b' | "$BS"); rc4=$?
out5=$(printf '%s\n' '--- a/x.c' '+++ b/x.c' '@@ -1,2 +1,2 @@' '-a' '+a ' 'garbage' '-a' '+a ' | "$BS"); rc5=$?
[ $rc1 = 1 ] && [ $rc2 = 1 ] && [ $rc3 = 1 ] && [ $rc4 = 1 ] && [ $rc5 = 1 ] \
  && ok "case 61: .scala/.php/.rb reindent, .c trailing-space continuation, and stray garbage hunk line exit 1" \
  || bad "case 61 (rc1 $rc1: $out1; rc2 $rc2: $out2; rc3 $rc3: $out3; rc4 $rc4: $out4; rc5 $rc5: $out5)"

exit $fail
