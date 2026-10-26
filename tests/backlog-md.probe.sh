#!/bin/bash
# Backlog-md coupling lint: plugins/seyag/skills/backlog-md/SKILL.md must name
# SYG_TRACKING_SURFACE and backlog-md, and plugins/seyag/rules/core.md must
# name SYG_TRACKING_SURFACE so a rename cannot silently break the coupling.
# Usage: tests/backlog-md.probe.sh   (from anywhere)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$REPO/plugins/seyag/skills/backlog-md/SKILL.md"
CORE="$REPO/plugins/seyag/rules/core.md"
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

check_token() {
  local file=$1 token=$2 rel="${1#"$REPO"/}"
  if grep -qF -- "$token" "$file" 2>/dev/null; then
    ok "$rel contains '$token'"
  else
    bad "$rel missing '$token'"
  fi
}

check_token "$SKILL" "SYG_TRACKING_SURFACE"
check_token "$SKILL" "backlog-md"
check_token "$CORE" "SYG_TRACKING_SURFACE"

if [ "$fail" -ne 0 ]; then exit 1; fi
ok "backlog-md coupling: all 3 token checks passed"
