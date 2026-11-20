#!/bin/bash
# Fixture check for CHANGELOG.md's format contract: the format line still carries
# the `(#PR)` placeholder (a cite-fill replace_all clobbered it once, #313), and the
# newest `## ` heading is `## <version> - <YYYY-MM-DD>` with the version equal to
# plugins/seyag/.claude-plugin/plugin.json's version. Each check runs on the real
# file, then its matcher runs on a mutated copy that must report bad.
# Usage: tests/changelog-format.probe.sh   (from anywhere)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHANGELOG="$REPO/CHANGELOG.md"
PLUGIN_JSON="$REPO/plugins/seyag/.claude-plugin/plugin.json"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

PLACEHOLDER='`- **scope:** description (#PR)`'

# format_ok FILE: the format line (starts "All notable changes") holds the placeholder.
format_ok() {
  local line
  line=$(grep -m1 '^All notable changes' "$1") || return 1
  grep -qF -- "$PLACEHOLDER" <<< "$line"
}

# heading_ok FILE VERSION: the first `## ` heading is `## VERSION - YYYY-MM-DD`.
heading_ok() {
  local head
  head=$(grep -m1 '^## ' "$1") || return 1
  [[ "$head" =~ ^'## '([0-9]+\.[0-9]+\.[0-9]+)' - '[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  [ "${BASH_REMATCH[1]}" = "$2" ]
}

VERSION=$(jq -r '.version // empty' "$PLUGIN_JSON" 2>/dev/null)

if format_ok "$CHANGELOG"; then
  ok "format line carries the (#PR) placeholder"
else
  bad "format line lacks the literal $PLACEHOLDER"
fi

if [ -n "$VERSION" ] && heading_ok "$CHANGELOG" "$VERSION"; then
  ok "first ## heading is ## $VERSION - YYYY-MM-DD (plugin.json version)"
else
  bad "first ## heading is not ## ${VERSION:-<no plugin.json version>} - YYYY-MM-DD"
fi

# Positive control: mutated copy (format line cites #330; first heading has 0.0.1).
# The mutation is GNU sed (`0,/re/`). A sed that rejects it leaves the copy empty,
# and an empty copy makes both matchers report bad, so the controls would pass
# without testing anything: a sed failure is a FAIL here, and the controls are skipped.
MUT="$T/CHANGELOG.md"
mut_err=$(sed -e '/^All notable changes/s/(#PR)/(#330)/' -e '0,/^## /s/^## [^ ]*/## 0.0.1/' "$CHANGELOG" 2>&1 >"$MUT")
mut_rc=$?
if [ "$mut_rc" -ne 0 ] || [ ! -s "$MUT" ]; then
  bad "positive control: the mutation sed failed (rc=$mut_rc, GNU sed needed for 0,/re/): ${mut_err:-empty output}"
else
  if ! format_ok "$MUT"; then
    ok "positive control: format matcher flags a (#330) format line"
  else
    bad "positive control: format matcher passed a (#330) format line"
  fi
  if ! heading_ok "$MUT" "$VERSION"; then
    ok "positive control: heading matcher flags a 0.0.1 heading"
  else
    bad "positive control: heading matcher passed a 0.0.1 heading"
  fi
fi

# Shim case: a sed that rejects `0,/re/` must FAIL this probe, not pass its controls vacuously.
# The nested run is marked so it does not repeat this case.
if [ -z "${CHANGELOG_PROBE_NESTED:-}" ]; then
  mkdir -p "$T/nogsed"
  printf '#!/bin/sh\ncase "$*" in *0,/*) echo "sed: invalid usage of line address 0" >&2; exit 1 ;; esac\nexec "%s" "$@"\n' \
    "$(command -v sed)" >"$T/nogsed/sed"
  chmod +x "$T/nogsed/sed"
  shim_out=$(CHANGELOG_PROBE_NESTED=1 PATH="$T/nogsed:$PATH" bash "${BASH_SOURCE[0]}" 2>&1); shim_rc=$?
  if [ "$shim_rc" -ne 0 ] && grep -q "positive control: the mutation sed failed" <<< "$shim_out"; then
    ok "a sed that rejects 0,/re/ fails the probe (controls not reported as passing)"
  else
    bad "a sed that rejects 0,/re/ did not fail the probe (rc=$shim_rc): $shim_out"
  fi
fi

exit "$fail"
