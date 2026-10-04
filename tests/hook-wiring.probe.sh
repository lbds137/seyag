#!/bin/bash
# Wiring parity: every hook has a probe and a hooks.json entry, every probe and
# hooks.json entry has a hook script, and every executable bin tool has a
# tests/<tool>.probe.sh. The checker takes a root dir so the probe can prove it
# fails on mutated copies of the tree.
# Usage: tests/hook-wiring.probe.sh   (from anywhere)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Exemptions: "<kind>:<name>  reason", one per entry. Kinds: hook-probe,
# hook-wired, bin-probe. None are needed today; an entry needs a reason.
EXEMPT=()

fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

exempt() {
  local e
  for e in "${EXEMPT[@]+"${EXEMPT[@]}"}"; do
    [ "${e%% *}" = "$1" ] && return 0
  done
  return 1
}

# check_root ROOT: print one line per offender; exit 1 if any.
check_root() {
  local root=$1 hooks bad_n=0 f name wired
  hooks="$root/plugins/seyag/hooks"
  report() { echo "$1"; bad_n=$((bad_n + 1)); }

  if ! wired=$(jq -r '.. | .command? // empty' "$hooks/hooks.json" 2>&1 \
      | sed -n 's/.*hooks\/run\.sh" *\([A-Za-z0-9._-][A-Za-z0-9._-]*\).*/\1/p'); then
    echo "hooks.json unreadable"; return 1
  fi
  [ -n "$wired" ] || report "hooks.json names no hooks (command strings not parsed)"

  for f in "$hooks"/*.sh; do
    [ -e "$f" ] || continue
    name=$(basename "$f" .sh)
    case "$name" in *.probe) continue ;; esac
    [ -e "$hooks/$name.probe.sh" ] || exempt "hook-probe:$name" \
      || report "hook $name has no $name.probe.sh"
    [ "$name" = run ] && continue
    grep -qxF "$name" <<<"$wired" || exempt "hook-wired:$name" \
      || report "hook $name is not wired in hooks.json"
  done
  for f in "$hooks"/*.probe.sh; do
    [ -e "$f" ] || continue
    name=$(basename "$f" .probe.sh)
    [ -e "$hooks/$name.sh" ] || report "probe $name.probe.sh has no $name.sh"
  done
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ -e "$hooks/$name.sh" ] || report "hooks.json names $name but $name.sh is missing"
  done <<<"$wired"
  for f in "$root"/plugins/seyag/bin/*; do
    [ -f "$f" ] && [ -x "$f" ] || continue
    name=$(basename "$f")
    [ -e "$root/tests/$name.probe.sh" ] || exempt "bin-probe:$name" \
      || report "bin tool $name has no tests/$name.probe.sh"
  done
  [ "$bad_n" -eq 0 ]
}

out=$(check_root "$REPO")
if [ $? -eq 0 ]; then
  ok "every hook and bin tool is probed and wired"
else
  while IFS= read -r l; do bad "$l"; done <<<"$out"
fi

# Positive controls: each mutation of a temp copy must be reported.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mutant() { # mutant NAME -> fresh copy at $TMP/NAME
  mkdir -p "$TMP/$1/plugins/seyag" "$TMP/$1/tests"
  cp -R "$REPO/plugins/seyag/hooks" "$REPO/plugins/seyag/bin" "$TMP/$1/plugins/seyag/"
  cp "$REPO"/tests/*.probe.sh "$TMP/$1/tests/"
}
expect() { # expect NAME NEEDLE
  local o
  o=$(check_root "$TMP/$1"); local rc=$?
  if [ "$rc" -ne 0 ] && grep -qF -- "$2" <<<"$o"; then
    ok "control $1: reported ($2)"
  else
    bad "control $1: not reported (rc=$rc, wanted '$2'): $o"
  fi
}

mutant no-hook-probe;  rm "$TMP/no-hook-probe/plugins/seyag/hooks/publish-gate.probe.sh"
expect no-hook-probe "hook publish-gate has no publish-gate.probe.sh"

mutant orphan-probe;   echo : > "$TMP/orphan-probe/plugins/seyag/hooks/ghost.probe.sh"
expect orphan-probe "probe ghost.probe.sh has no ghost.sh"

mutant unwired
jq 'del(.. | select(type == "object" and ((.command? // "") | tostring | endswith("run.sh\" publish-gate"))))' \
  "$REPO/plugins/seyag/hooks/hooks.json" > "$TMP/unwired/plugins/seyag/hooks/hooks.json"
expect unwired "hook publish-gate is not wired in hooks.json"

mutant no-bin-probe;   rm "$TMP/no-bin-probe/tests/safe-clean.probe.sh"
expect no-bin-probe "bin tool safe-clean has no tests/safe-clean.probe.sh"

mutant missing-script; rm "$TMP/missing-script/plugins/seyag/hooks/publish-gate.sh" "$TMP/missing-script/plugins/seyag/hooks/publish-gate.probe.sh"
expect missing-script "hooks.json names publish-gate but publish-gate.sh is missing"

[ "$fail" -eq 0 ]
