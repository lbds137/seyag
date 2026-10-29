#!/bin/bash
# Rule-table probe for plugins/seyag/hooks/lib/branch_switch.py: runs
# tests/branch_switch_test.py (the WHERE rule table plus the three-line output
# contract) against seyag's own shell_quotes.py.
# Usage: tests/branch-switch.probe.sh   (from anywhere)

set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LIB="$REPO/plugins/seyag/hooks/lib"
TESTS="$REPO/tests"

fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'; fail=1; }

cd "$TESTS" || { bad "cannot enter $TESTS"; exit 1; }

out=$(PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$LIB" python3 -m unittest branch_switch_test 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  ok "branch_switch_test: $(printf '%s\n' "$out" | grep -E '^Ran ' | head -n 1)"
else
  bad "branch_switch_test (rc=$rc)" "$out"
fi

exit "$fail"
