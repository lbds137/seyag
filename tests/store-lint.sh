#!/usr/bin/env bash
# Store lint named by the backlog-only direct path in CLAUDE.md (TASK-265): runs
# plugins/seyag/bin/backlog-lint (priority check) and tests/coupling-lint.probe.sh
# (machine-coupling check) against this repo. Both always run, so one invocation
# reports every finding.
# Exit 0 with no output = pass. Exit 1 = a check failed: each failing check's
# output follows a "store-lint: <check> failed (rc N)" line.
# Usage: tests/store-lint.sh   (from anywhere)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail=0
report() {
  local name=$1 rc=$2 out=$3
  [ "$rc" -eq 0 ] && return 0
  fail=1
  printf 'store-lint: %s failed (rc %s)\n%s\n' "$name" "$rc" "$out"
}

out=$("$REPO/plugins/seyag/bin/backlog-lint" --store "$REPO" 2>&1); rc=$?
report backlog-lint "$rc" "$out"

out=$(bash "$REPO/tests/coupling-lint.probe.sh" 2>&1); rc=$?
report coupling-lint "$rc" "$out"

exit "$fail"
