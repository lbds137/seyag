#!/bin/bash
# Executing-span survival probe for plugins/seyag/hooks/lib/shell_quotes.py:
# runs scanner_parity_test.py (heredoc-to-shell in both delimiter forms,
# `$()`/backtick runtime construction, here-strings, eval-joined tails) against
# the scanner. The strip mechanics are pinned by tests/shell_quotes.probe.sh;
# this is the survival angle on top.
# Usage: tests/scanner-parity.probe.sh   (from anywhere)

set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LIB="$REPO/plugins/seyag/hooks/lib"
TESTS="$REPO/tests"

fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'; fail=1; }

cd "$TESTS" || { bad "cannot enter $TESTS"; exit 1; }

out=$(PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$LIB" python3 -m unittest scanner_parity_test 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  ok "scanner_parity_test: $(printf '%s\n' "$out" | grep -E '^Ran ' | head -n 1)"
else
  bad "scanner_parity_test (rc=$rc)" "$out"
fi

exit "$fail"
