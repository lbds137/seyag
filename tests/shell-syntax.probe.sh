#!/bin/bash
# Every shell file parses (bash -n) and every Python file parses (ast), over the
# file sets tests/shell-files.sh enumerates. Positive controls prove a syntax
# error of each kind is reported.
# Usage: tests/shell-syntax.probe.sh   (from anywhere)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PYTHONDONTWRITEBYTECODE=1
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

check_shell() { bash -n "$1" 2>&1; }
check_python() { python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "$1" 2>&1; }

cd "$REPO" || exit 1
n=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  n=$((n + 1))
  out=$(check_shell "$f") || bad "bash -n $f: $out"
done < <(bash tests/shell-files.sh)
[ "$n" -gt 0 ] || bad "no shell files enumerated"
p=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  p=$((p + 1))
  out=$(check_python "$f") || bad "python parse $f: $out"
done < <(bash tests/shell-files.sh --python)
[ "$p" -gt 0 ] || bad "no python files enumerated"
[ "$fail" -eq 0 ] && ok "$n shell files and $p python files parse"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
printf '#!/bin/bash\nif true; then\n  echo x\n' > "$TMP/broken.sh"
printf 'def f(:\n  pass\n' > "$TMP/broken.py"
if check_shell "$TMP/broken.sh" >/dev/null; then bad "control: broken shell file passed bash -n"; else ok "control: broken shell file reported"; fi
if check_python "$TMP/broken.py" >/dev/null; then bad "control: broken python file passed ast.parse"; else ok "control: broken python file reported"; fi

# The enumeration must pick up shebang-detected files in bin/ for both kinds.
mkdir -p "$TMP/root/plugins/seyag/bin" "$TMP/root/plugins/seyag/hooks" "$TMP/root/tests"
printf '#!/bin/bash\nfi\n' > "$TMP/root/plugins/seyag/bin/shtool"
printf '#!/usr/bin/env python3\ndef f(:\n' > "$TMP/root/plugins/seyag/bin/pytool"
ROOT="$TMP/root" bash "$REPO/tests/shell-files.sh" | grep -qx 'plugins/seyag/bin/shtool' \
  && ok "control: shell-shebang bin file enumerated" || bad "control: shell-shebang bin file not enumerated"
ROOT="$TMP/root" bash "$REPO/tests/shell-files.sh" --python | grep -qx 'plugins/seyag/bin/pytool' \
  && ok "control: python-shebang bin file enumerated" || bad "control: python-shebang bin file not enumerated"

[ "$fail" -eq 0 ]
