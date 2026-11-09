#!/bin/bash
# Hermetic fixture probe for plugins/seyag/bin/security-sweep.
# Stubs gh via SECURITY_SWEEP_GH and isolates cache state in XDG_STATE_HOME;
# never reaches the network or the real gh CLI.
# Usage: tests/security-sweep.probe.sh

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SS="${SECURITY_SWEEP_BIN:-$REPO/plugins/seyag/bin/security-sweep}"
fail=0
ok() { echo "ok:   $1"; }
bad() {
  echo "FAIL: $1"
  [ -n "${2:-}" ] && printf '      got: %s\n' "$2"
  fail=1
  if [ -n "${SECURITY_SWEEP_STOP_AT_FAIL:-}" ]; then
    exit 1
  fi
}

[ -x "$SS" ] || { bad "security-sweep is not executable at $SS"; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/fixtures"

cat > "$T/bin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.log"
printf '%s\n' "\$\$" >> "$T/gh-pids"
if [ -f "$T/gh-hold" ]; then
  _hold="\$(cat "$T/gh-hold")"
  for ((_i = 0; _i < 300; _i++)); do
    [ -e "\$_hold" ] && break
    sleep 0.1
  done
fi
ep=""
for arg in "\$@"; do
  case "\$arg" in
    repos/*/*/alerts*) ep="\$arg" ;;
  esac
done
if [ -z "\$ep" ]; then
  echo "stub gh: unexpected args: \$*" >&2
  exit 9
fi
rest="\${ep#repos/}"
owner="\${rest%%/*}"
rest="\${rest#*/}"
name="\${rest%%/*}"
rest="\${rest#*/}"
surf="\${rest%%/alerts*}"
dir="$T/fixtures/\${owner}_\${name}"
if [ -f "\$dir/\$surf.err" ]; then
  cat "\$dir/\$surf.err" >&2
fi
if [ -f "\$dir/\$surf.out" ]; then
  cat "\$dir/\$surf.out"
else
  printf '[]\n'
fi
rc=0
if [ -f "\$dir/\$surf.rc" ]; then
  rc="\$(cat "\$dir/\$surf.rc")"
fi
exit "\$rc"
EOF
chmod +x "$T/bin/gh"

reset_state() {
  rm -rf "$T/state" "$T/fixtures" "$T/gh.log" "$T/gh-pids" "$T/gh-hold" "$T/lock-ready" "$T/lock-release"
  mkdir -p "$T/state" "$T/fixtures"
  : > "$T/gh.log"
}

run_ss() {
  SECURITY_SWEEP_GH="$T/bin/gh" XDG_STATE_HOME="$T/state" "$SS" "$@" >"$T/out" 2>"$T/err"
  rc=$?
}

# 1. Claim 1 & 2: code-scanning critical+high+medium+null-severity (rule.security_severity_level, not rule.severity)
#    and secret-scanning fixture with plaintext secret filtered out at fetch time.
reset_state
mkdir -p "$T/fixtures/example-org_widget"
cat > "$T/fixtures/example-org_widget/code-scanning.out" <<'EOF'
[
  {"number": 1, "rule": {"id": "py/sql-injection", "security_severity_level": "critical", "severity": "error"}, "tool": {"name": "CodeQL"}},
  {"number": 2, "rule": {"id": "py/path-injection", "security_severity_level": "high", "severity": "warning"}, "tool": {"name": "CodeQL"}},
  {"number": 3, "rule": {"id": "actions/missing-workflow-permissions", "security_severity_level": "medium", "severity": "warning"}, "tool": {"name": "CodeQL"}},
  {"number": 4, "rule": {"id": "py/unused-import", "security_severity_level": null, "severity": "note"}, "tool": {"name": "CodeQL"}}
]
EOF
cat > "$T/fixtures/example-org_widget/dependabot.out" <<'EOF'
[
  {"number": 10, "security_advisory": {"severity": "high"}, "dependency": {"package": {"name": "urllib3"}}},
  {"number": 11, "security_advisory": {"severity": "low"}, "dependency": {"package": {"name": "idna"}}}
]
EOF
cat > "$T/fixtures/example-org_widget/secret-scanning.out" <<'EOF'
[
  {"number": 20, "secret_type_display_name": "Example Token", "secret_type": "example_token", "secret": "FIXTURE-SECRET-VALUE-0001"}
]
EOF

run_ss -R example-org/widget
WANT_LINE="example-org/widget: code-scanning 4 (1 critical: py/sql-injection; 1 high: py/path-injection; 1 medium; 1 none) · dependabot 2 (1 high; 1 low) · secret-scanning 1 (Example Token)"
if [ "$rc" -eq 0 ] && [ "$(cat "$T/out")" = "$WANT_LINE" ] && [ ! -s "$T/err" ]; then
  ok "1a default line lists critical/high rule.ids, severity counts from rule.security_severity_level, dependabot counts, and secret type"
else
  bad "1a default line (rc=$rc)" "$(cat "$T/out" "$T/err")"
fi

# Positive control: fixture has FIXTURE-SECRET-VALUE-0001 and cache file was written.
CACHE_FILE="$T/state/seyag/security-sweep/example-org_widget.json"
if [ -s "$CACHE_FILE" ] && grep -qF "FIXTURE-SECRET-VALUE-0001" "$T/fixtures/example-org_widget/secret-scanning.out"; then
  if grep -rF "FIXTURE-SECRET-VALUE-0001" "$T/out" "$T/err" "$T/state" >/dev/null 2>&1; then
    bad "2 secret value leaked into stdout, stderr, or state cache" "$(grep -rnF "FIXTURE-SECRET-VALUE-0001" "$T/out" "$T/err" "$T/state")"
  else
    ok "2 secret value FIXTURE-SECRET-VALUE-0001 appears in none of stdout, stderr, or cache dir"
  fi
else
  bad "2 cache file missing at $CACHE_FILE"
fi

# JSON output check on the same state
run_ss -R example-org/widget --json
if [ "$rc" -eq 0 ] \
  && jq -e '
    .repos | length == 1 and
    .[0].repo == "example-org/widget" and
    .[0].surfaces["code-scanning"] == {
      "state": "count",
      "count": 4,
      "numbers": [1, 2, 3, 4],
      "by_severity": {"critical": 1, "high": 1, "medium": 1, "none": 1},
      "rules": ["py/sql-injection", "py/path-injection", "actions/missing-workflow-permissions", "py/unused-import"],
      "rules_critical_high": ["py/sql-injection", "py/path-injection"]
    } and
    .[0].surfaces["dependabot"] == {
      "state": "count",
      "count": 2,
      "numbers": [10, 11],
      "by_severity": {"high": 1, "low": 1},
      "packages": ["urllib3", "idna"]
    } and
    .[0].surfaces["secret-scanning"] == {
      "state": "count",
      "count": 1,
      "numbers": [20],
      "types": ["Example Token"]
    } and
    .[0].stale == {}
  ' "$T/out" >/dev/null 2>&1 \
  && ! grep -rF "FIXTURE-SECRET-VALUE-0001" "$T/out" "$T/err" "$T/state" >/dev/null 2>&1; then
  ok "1b --json shape matches spec and contains no secret value"
else
  bad "1b --json shape (rc=$rc)" "$(cat "$T/out" "$T/err")"
fi

# 1c: --json deduplicates rule ids and package names in cache order while keeping all alert numbers
mkdir -p "$T/fixtures/example-org_dup"
cat > "$T/fixtures/example-org_dup/code-scanning.out" <<'EOF'
[
  {"number": 7, "rule": {"id": "py/sql-injection", "security_severity_level": "critical"}, "tool": {"name": "CodeQL"}},
  {"number": 8, "rule": {"id": "py/sql-injection", "security_severity_level": "critical"}, "tool": {"name": "CodeQL"}},
  {"number": 9, "rule": {"id": "py/unused-import", "security_severity_level": "low"}, "tool": {"name": "CodeQL"}}
]
EOF
cat > "$T/fixtures/example-org_dup/dependabot.out" <<'EOF'
[
  {"number": 12, "security_advisory": {"severity": "high"}, "dependency": {"package": {"name": "urllib3"}}},
  {"number": 13, "security_advisory": {"severity": "medium"}, "dependency": {"package": {"name": "urllib3"}}},
  {"number": 14, "security_advisory": {"severity": "low"}, "dependency": {"package": {"name": "idna"}}}
]
EOF
run_ss -R example-org/dup --json
if [ "$rc" -eq 0 ] \
  && jq -e '
    .repos[0].surfaces["code-scanning"].numbers == [7, 8, 9] and
    .repos[0].surfaces["code-scanning"].rules == ["py/sql-injection", "py/unused-import"] and
    .repos[0].surfaces["dependabot"].numbers == [12, 13, 14] and
    .repos[0].surfaces["dependabot"].packages == ["urllib3", "idna"]
  ' "$T/out" >/dev/null 2>&1; then
  ok "1c --json deduplicates rules and packages while preserving alert numbers in cache order"
else
  bad "1c --json dedup identifiers (rc=$rc)" "$(cat "$T/out" "$T/err")"
fi

# 5. Claim 5: Cache freshness, --no-cache, and expiry
: > "$T/gh.log"
run_ss -R example-org/widget
if [ "$rc" -eq 0 ] && [ ! -s "$T/gh.log" ] && [ "$(cat "$T/out")" = "$WANT_LINE" ]; then
  ok "5a second run within 300 s uses cache without invoking gh stub"
else
  bad "5a cache hit (rc=$rc, calls=$(wc -l <"$T/gh.log"))" "$(cat "$T/out" "$T/err")"
fi

: > "$T/gh.log"
run_ss -R example-org/widget --no-cache
if [ "$rc" -eq 0 ] && [ "$(wc -l <"$T/gh.log")" -eq 3 ]; then
  ok "5b --no-cache invokes gh stub across all 3 surfaces"
else
  bad "5b --no-cache (rc=$rc, calls=$(wc -l <"$T/gh.log"))"
fi

python3 - "$CACHE_FILE" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["fetched_at"] -= 400
json.dump(d, open(p, "w"))
PY
: > "$T/gh.log"
run_ss -R example-org/widget
if [ "$rc" -eq 0 ] && [ "$(wc -l <"$T/gh.log")" -eq 3 ]; then
  ok "5c expired cache (age > 300 s) refetches all 3 surfaces"
else
  bad "5c expired cache refetch (rc=$rc, calls=$(wc -l <"$T/gh.log"))"
fi

# 5d, 5e, 5f, 5g: corrupt cache surface entries (count: "x", by_severity: [], alerts: [1], rules_by_severity: {"critical": [1]}) are rejected by is_valid_cached_surface and refetched
python3 - "$CACHE_FILE" <<'PY'
import json, sys, time
p = sys.argv[1]
json.dump({
    "fetched_at": time.time(),
    "surfaces": {
        "code-scanning": {"state": "count", "count": "x"},
        "dependabot": {"state": "off"},
        "secret-scanning": {"state": "off"},
    },
}, open(p, "w"))
PY
: > "$T/gh.log"
run_ss -R example-org/widget
if [ "$rc" -eq 0 ] && [ "$(wc -l <"$T/gh.log")" -eq 3 ] && [ "$(cat "$T/out")" = "$WANT_LINE" ] && [ ! -s "$T/err" ]; then
  ok "5d corrupt cache with count: \"x\" (fresh fetched_at) refetches and prints fixture line"
else
  bad "5d corrupt cache count: \"x\" (rc=$rc, calls=$(wc -l <"$T/gh.log"))" "out=$(cat "$T/out") err=$(cat "$T/err")"
fi

python3 - "$CACHE_FILE" <<'PY'
import json, sys, time
p = sys.argv[1]
json.dump({
    "fetched_at": time.time(),
    "surfaces": {
        "code-scanning": {"state": "count", "count": 1, "by_severity": []},
        "dependabot": {"state": "off"},
        "secret-scanning": {"state": "off"},
    },
}, open(p, "w"))
PY
: > "$T/gh.log"
run_ss -R example-org/widget
if [ "$rc" -eq 0 ] && [ "$(wc -l <"$T/gh.log")" -eq 3 ] && [ "$(cat "$T/out")" = "$WANT_LINE" ] && [ ! -s "$T/err" ]; then
  ok "5e corrupt cache with by_severity: [] (fresh fetched_at) refetches and prints fixture line"
else
  bad "5e corrupt cache by_severity: [] (rc=$rc, calls=$(wc -l <"$T/gh.log"))" "out=$(cat "$T/out") err=$(cat "$T/err")"
fi

python3 - "$CACHE_FILE" <<'PY'
import json, sys, time
p = sys.argv[1]
json.dump({
    "fetched_at": time.time(),
    "surfaces": {
        "code-scanning": {"state": "count", "count": 1, "alerts": [1]},
        "dependabot": {"state": "off"},
        "secret-scanning": {"state": "off"},
    },
}, open(p, "w"))
PY
: > "$T/gh.log"
run_ss -R example-org/widget
if [ "$rc" -eq 0 ] && [ "$(wc -l <"$T/gh.log")" -eq 3 ] && [ "$(cat "$T/out")" = "$WANT_LINE" ] && [ ! -s "$T/err" ]; then
  ok "5f corrupt cache with alerts: [1] (fresh fetched_at) refetches and prints fixture line"
else
  bad "5f corrupt cache alerts: [1] (rc=$rc, calls=$(wc -l <"$T/gh.log"))" "out=$(cat "$T/out") err=$(cat "$T/err")"
fi

python3 - "$CACHE_FILE" <<'PY'
import json, sys, time
p = sys.argv[1]
json.dump({
    "fetched_at": time.time(),
    "surfaces": {
        "code-scanning": {"state": "count", "count": 1, "by_severity": {"critical": 1}, "rules_by_severity": {"critical": [1]}},
        "dependabot": {"state": "off"},
        "secret-scanning": {"state": "off"},
    },
}, open(p, "w"))
PY
: > "$T/gh.log"
run_ss -R example-org/widget
if [ "$rc" -eq 0 ] && [ "$(wc -l <"$T/gh.log")" -eq 3 ] && [ "$(cat "$T/out")" = "$WANT_LINE" ] && [ ! -s "$T/err" ]; then
  ok "5g corrupt cache with rules_by_severity: {\"critical\": [1]} (fresh fetched_at) refetches and prints fixture line"
else
  bad "5g corrupt cache rules_by_severity: {\"critical\": [1]} (rc=$rc, calls=$(wc -l <"$T/gh.log"))" "out=$(cat "$T/out") err=$(cat "$T/err")"
fi

# 3. Claim 3: off vs error states (code-scanning not enabled -> off; secret-scanning disabled -> off; Not Found -> error)
reset_state
mkdir -p "$T/fixtures/example-org_widget"
printf '{"message":"Code scanning is not enabled for this repository. Please enable code scanning in the repository settings."}\n' > "$T/fixtures/example-org_widget/code-scanning.out"
printf 'gh: Code scanning is not enabled for this repository. Please enable code scanning in the repository settings. (HTTP 403)\n' > "$T/fixtures/example-org_widget/code-scanning.err"
printf '1\n' > "$T/fixtures/example-org_widget/code-scanning.rc"
printf '[]\n' > "$T/fixtures/example-org_widget/dependabot.out"
printf '{"message":"Secret scanning is disabled on this repository."}\n' > "$T/fixtures/example-org_widget/secret-scanning.out"
printf 'gh: Secret scanning is disabled on this repository. (HTTP 404)\n' > "$T/fixtures/example-org_widget/secret-scanning.err"
printf '1\n' > "$T/fixtures/example-org_widget/secret-scanning.rc"

run_ss -R example-org/widget
if [ "$rc" -eq 0 ] && [ "$(cat "$T/out")" = "example-org/widget: clean (off: code-scanning, secret-scanning)" ] && [ ! -s "$T/err" ]; then
  ok "3a code-scanning not enabled and secret-scanning disabled map to off; clean repo prints (off: ...)"
else
  bad "3a clean with off surfaces (rc=$rc)" "$(cat "$T/out" "$T/err")"
fi

# All three surfaces at 0 -> clean without (off: ...)
reset_state
mkdir -p "$T/fixtures/example-org_widget"
run_ss -R example-org/widget
if [ "$rc" -eq 0 ] && [ "$(cat "$T/out")" = "example-org/widget: clean" ] && [ ! -s "$T/err" ]; then
  ok "3b repo with all three surfaces at 0 prints 'owner/name: clean'"
else
  bad "3b all-zero clean (rc=$rc)" "$(cat "$T/out" "$T/err")"
fi

# Not Found -> error (never off), stderr has fixed message without gh output text
reset_state
mkdir -p "$T/fixtures/example-org_widget"
printf '{"message":"Code scanning is not enabled for this repository."}\n' > "$T/fixtures/example-org_widget/code-scanning.out"
printf '1\n' > "$T/fixtures/example-org_widget/code-scanning.rc"
printf '{"message":"Not Found"}\n' > "$T/fixtures/example-org_widget/dependabot.out"
printf 'gh: Not Found (HTTP 404) https://someone:FIXTURE-TOKEN-0003@github.com/example-org/widget\n' > "$T/fixtures/example-org_widget/dependabot.err"
printf '1\n' > "$T/fixtures/example-org_widget/dependabot.rc"
printf '{"message":"Secret scanning is disabled on this repository."}\n' > "$T/fixtures/example-org_widget/secret-scanning.out"
printf '1\n' > "$T/fixtures/example-org_widget/secret-scanning.rc"

run_ss -R example-org/widget
if [ "$rc" -eq 0 ] \
  && [ "$(cat "$T/out")" = "example-org/widget: code-scanning off · dependabot error · secret-scanning off" ] \
  && [ "$(cat "$T/err")" = "security-sweep: example-org/widget dependabot: fetch failed (gh exit 1)" ] \
  && ! grep -qF "FIXTURE-TOKEN-0003" "$T/out" "$T/err"; then
  ok "3c Not Found maps to error (not off), prints fixed stderr line, and echoes no gh output text"
else
  bad "3c Not Found error mapping (rc=$rc)" "out=$(cat "$T/out") err=$(cat "$T/err")"
fi

run_ss -R example-org/widget --no-cache --json
if [ "$rc" -eq 0 ] \
  && jq -e '
    .repos[0].surfaces["code-scanning"] == {"state": "off"} and
    .repos[0].surfaces["dependabot"] == {"state": "error"} and
    .repos[0].surfaces["secret-scanning"] == {"state": "off"}
  ' "$T/out" >/dev/null 2>&1; then
  ok "3d --json omits count/by_severity when state is off or error"
else
  bad "3d --json off/error shape (rc=$rc)" "$(cat "$T/out")"
fi

# 3e: gh timeout via SECURITY_SWEEP_GH_TIMEOUT=1 with stub gh held on a release marker
reset_state
mkdir -p "$T/fixtures/example-org_widget"
rm -f "$T/gh-release-3e"
printf '%s\n' "$T/gh-release-3e" > "$T/gh-hold"
SECURITY_SWEEP_GH_TIMEOUT=1 SECURITY_SWEEP_GH="$T/bin/gh" XDG_STATE_HOME="$T/state" "$SS" -R example-org/widget >"$T/out" 2>"$T/err"
rc=$?
: > "$T/gh-release-3e"
if [ "$rc" -eq 0 ] \
  && [ "$(cat "$T/out")" = "example-org/widget: code-scanning error · dependabot error · secret-scanning error" ] \
  && grep -qF "fetch failed (gh exit 124)" "$T/err"; then
  ok "3e SECURITY_SWEEP_GH_TIMEOUT=1 with held gh maps surface to error, exits 0, and prints fetch failed (gh exit 124)"
else
  bad "3e gh timeout (rc=$rc)" "out=$(cat "$T/out") err=$(cat "$T/err")"
fi

# 3f: every OFF_MARKERS entry maps its surface to off on the default line, and --strict with only off surfaces exits 0
check_off_marker() {
  local label="$1" surf="$2" msg="$3"
  reset_state
  mkdir -p "$T/fixtures/example-org_widget"
  printf '{"message":"%s"}\n' "$msg" > "$T/fixtures/example-org_widget/$surf.out"
  printf 'gh: %s (HTTP 403)\n' "$msg" > "$T/fixtures/example-org_widget/$surf.err"
  printf '1\n' > "$T/fixtures/example-org_widget/$surf.rc"
  run_ss -R example-org/widget
  if [ "$rc" -eq 0 ] && [ "$(cat "$T/out")" = "example-org/widget: clean (off: $surf)" ] && [ ! -s "$T/err" ]; then
    ok "$label off marker '$msg' maps $surf to off"
  else
    bad "$label off marker '$msg' (rc=$rc)" "out=$(cat "$T/out") err=$(cat "$T/err")"
  fi
}

check_off_marker "3f-1" "code-scanning" "Code scanning is not enabled"
check_off_marker "3f-2" "code-scanning" "no analysis found"
check_off_marker "3f-3" "code-scanning" "Advanced Security must be enabled"
check_off_marker "3f-4" "secret-scanning" "Secret scanning is disabled"
check_off_marker "3f-5" "dependabot" "Dependabot alerts are disabled"
check_off_marker "3f-6" "dependabot" "Dependabot alerts are not available for archived repositories"

reset_state
mkdir -p "$T/fixtures/example-org_widget"
printf '{"message":"no analysis found"}\n' > "$T/fixtures/example-org_widget/code-scanning.out"
printf '1\n' > "$T/fixtures/example-org_widget/code-scanning.rc"
printf '{"message":"Dependabot alerts are disabled"}\n' > "$T/fixtures/example-org_widget/dependabot.out"
printf '1\n' > "$T/fixtures/example-org_widget/dependabot.rc"
printf '{"message":"Secret scanning is disabled"}\n' > "$T/fixtures/example-org_widget/secret-scanning.out"
printf '1\n' > "$T/fixtures/example-org_widget/secret-scanning.rc"
run_ss -R example-org/widget --strict
if [ "$rc" -eq 0 ] && [ "$(cat "$T/out")" = "example-org/widget: clean (off: code-scanning, dependabot, secret-scanning)" ] && [ ! -s "$T/err" ]; then
  ok "3f-strict --strict with only off surfaces exits 0"
else
  bad "3f-strict --strict with only off surfaces (rc=$rc)" "out=$(cat "$T/out") err=$(cat "$T/err")"
fi

# 4. Claim 4: --strict exit codes and stale cache fallback on error
# 4a: critical code-scanning -> exit 1
reset_state
mkdir -p "$T/fixtures/example-org_widget"
printf '[{"number":1,"rule":{"id":"r1","security_severity_level":"critical"},"tool":{"name":"CodeQL"}}]\n' > "$T/fixtures/example-org_widget/code-scanning.out"
run_ss -R example-org/widget --strict
[ "$rc" -eq 1 ] && ok "4a --strict with critical code-scanning exits 1" || bad "4a --strict critical (rc=$rc)"

# 4b: open secret-scanning -> exit 1
reset_state
mkdir -p "$T/fixtures/example-org_widget"
printf '[{"number":1,"secret_type_display_name":"Example Token","secret":"FIXTURE-SECRET-VALUE-0002"}]\n' > "$T/fixtures/example-org_widget/secret-scanning.out"
run_ss -R example-org/widget --strict
[ "$rc" -eq 1 ] && ok "4b --strict with open secret-scanning exits 1" || bad "4b --strict secret (rc=$rc)"

# 4c: only medium code-scanning -> exit 0
reset_state
mkdir -p "$T/fixtures/example-org_widget"
printf '[{"number":1,"rule":{"id":"r-med","security_severity_level":"medium"},"tool":{"name":"CodeQL"}}]\n' > "$T/fixtures/example-org_widget/code-scanning.out"
run_ss -R example-org/widget --strict
[ "$rc" -eq 0 ] && ok "4c --strict with only medium code-scanning exits 0" || bad "4c --strict medium (rc=$rc)"

# 4d: error surface with no cache -> exit 2
reset_state
mkdir -p "$T/fixtures/example-org_widget"
printf 'gh: Not Found (HTTP 404)\n' > "$T/fixtures/example-org_widget/dependabot.err"
printf '1\n' > "$T/fixtures/example-org_widget/dependabot.rc"
run_ss -R example-org/widget --strict
[ "$rc" -eq 2 ] && ok "4d --strict with an error surface and no cache exits 2" || bad "4d --strict error no cache (rc=$rc)"
if [ "$rc" -eq 2 ] && grep -qF "fetch failed (gh exit 1)" "$T/err"; then
  ok "4g --strict with an error surface and no cache prints fetch failed (gh exit N) to stderr"
else
  bad "4g --strict error stderr (rc=$rc)" "err=$(cat "$T/err")"
fi

# 4e: same error with a cache holding a non-error value -> uses cache, marked stale age=Nm, no exit 2
reset_state
mkdir -p "$T/fixtures/example-org_widget"
printf '[{"number":1,"rule":{"id":"r-med","security_severity_level":"medium"},"tool":{"name":"CodeQL"}}]\n' > "$T/fixtures/example-org_widget/code-scanning.out"
printf '[{"number":2,"security_advisory":{"severity":"medium"},"dependency":{"package":{"name":"pkg-m"}}}]\n' > "$T/fixtures/example-org_widget/dependabot.out"
run_ss -R example-org/widget --strict
# Age the cache to 6 minutes ago so the next run fetches fresh, then make dependabot fail
python3 - "$CACHE_FILE" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["fetched_at"] -= 360
json.dump(d, open(p, "w"))
PY
rm -f "$T/fixtures/example-org_widget/dependabot.out"
printf 'gh: HTTP 502 Bad Gateway\n' > "$T/fixtures/example-org_widget/dependabot.err"
printf '1\n' > "$T/fixtures/example-org_widget/dependabot.rc"
run_ss -R example-org/widget --strict
if [ "$rc" -eq 0 ] && grep -qF "dependabot 1 (1 medium) stale age=6m" "$T/out"; then
  ok "4e --strict with fetch error falls back to cached value, marks stale age=6m, and exits 0"
else
  bad "4e --strict stale fallback (rc=$rc)" "$(cat "$T/out" "$T/err")"
fi

run_ss -R example-org/widget --strict --json
if [ "$rc" -eq 0 ] && jq -e '.repos[0].stale == {"dependabot": 6} and .repos[0].surfaces["dependabot"].count == 1' "$T/out" >/dev/null 2>&1; then
  ok "4f --json records stale surface age in minutes"
else
  bad "4f --json stale age (rc=$rc)" "$(cat "$T/out")"
fi

# 6. Claim 6: Origin remote parsing (https with embedded token, ssh, and non-github remote)
reset_state
mkdir -p "$T/fixtures/example-org_widget" "$T/fixtures/example-org_gadget"
git init -q "$T/repo-https"
git -C "$T/repo-https" remote add origin "https://someone:FIXTURE-TOKEN-0001@github.com/example-org/widget.git"
(cd "$T/repo-https" && SECURITY_SWEEP_GH="$T/bin/gh" XDG_STATE_HOME="$T/state" "$SS") >"$T/out" 2>"$T/err"
rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$T/out")" = "example-org/widget: clean" ] \
  && ! grep -rF "FIXTURE-TOKEN-0001" "$T/out" "$T/err" "$T/state" >/dev/null 2>&1; then
  ok "6a https origin with embedded token parses owner/name and never writes token to stdout/stderr/cache"
else
  bad "6a https origin (rc=$rc)" "$(cat "$T/out" "$T/err")"
fi

git init -q "$T/repo-ssh"
git -C "$T/repo-ssh" remote add origin "git@github.com:example-org/gadget.git"
(cd "$T/repo-ssh" && SECURITY_SWEEP_GH="$T/bin/gh" XDG_STATE_HOME="$T/state" "$SS") >"$T/out" 2>"$T/err"
rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$T/out")" = "example-org/gadget: clean" ]; then
  ok "6b ssh origin git@github.com:OWNER/NAME.git parses owner/name"
else
  bad "6b ssh origin (rc=$rc)" "$(cat "$T/out" "$T/err")"
fi

git init -q "$T/repo-bad"
git -C "$T/repo-bad" remote add origin "https://someone:FIXTURE-TOKEN-0002@gitlab.example.com/example-org/widget.git"
(cd "$T/repo-bad" && SECURITY_SWEEP_GH="$T/bin/gh" XDG_STATE_HOME="$T/state" "$SS") >"$T/out" 2>"$T/err"
rc0=$?
err0=$(cat "$T/err")
(cd "$T/repo-bad" && SECURITY_SWEEP_GH="$T/bin/gh" XDG_STATE_HOME="$T/state" "$SS" --strict) >"$T/out" 2>"$T/err"
rc_strict=$?
if [ "$rc0" -eq 0 ] && [ "$rc_strict" -eq 2 ] \
  && [ "$err0" = "security-sweep: origin is not a github.com repo" ] \
  && ! grep -rF "FIXTURE-TOKEN-0002" "$T/out" "$T/err" "$T/state" >/dev/null 2>&1; then
  ok "6c non-github origin prints fixed stderr line without URL/token, exits 0 (2 under --strict)"
else
  bad "6c non-github origin (rc0=$rc0, rc_strict=$rc_strict, err=$err0)"
fi

# 6d & 6e: invalid repo token exits 0 normally and 2 under --strict, with stderr message
reset_state
run_ss -R not-a-repo
if [ "$rc" -eq 0 ] && [ ! -s "$T/out" ] && [ "$(cat "$T/err")" = "security-sweep: invalid repo 'not-a-repo' (expected owner/name), skipped" ]; then
  ok "6d -R not-a-repo exits 0 with invalid repo stderr message"
else
  bad "6d -R not-a-repo (rc=$rc)" "out=$(cat "$T/out") err=$(cat "$T/err")"
fi

run_ss -R not-a-repo --strict
if [ "$rc" -eq 2 ] && [ ! -s "$T/out" ] && [ "$(cat "$T/err")" = "security-sweep: invalid repo 'not-a-repo' (expected owner/name), skipped" ]; then
  ok "6e -R not-a-repo --strict exits 2 with invalid repo stderr message"
else
  bad "6e -R not-a-repo --strict (rc=$rc)" "out=$(cat "$T/out") err=$(cat "$T/err")"
fi

# 6f, 6g, 6h: invalid repo token is skipped and remaining valid repos are swept; under --strict exit is >=2 (1 wins on alert)
reset_state
mkdir -p "$T/fixtures/example-org_widget"
run_ss -R bad -R example-org/widget
if [ "$rc" -eq 0 ] && [ "$(cat "$T/out")" = "example-org/widget: clean" ] \
  && [ "$(cat "$T/err")" = "security-sweep: invalid repo 'bad' (expected owner/name), skipped" ]; then
  ok "6f -R bad -R example-org/widget skips bad token, sweeps widget, and names skip on stderr"
else
  bad "6f skip invalid repo (rc=$rc)" "out=$(cat "$T/out") err=$(cat "$T/err")"
fi

run_ss -R bad -R example-org/widget --no-cache --strict
if [ "$rc" -eq 2 ] && [ "$(cat "$T/out")" = "example-org/widget: clean" ] \
  && [ "$(cat "$T/err")" = "security-sweep: invalid repo 'bad' (expected owner/name), skipped" ]; then
  ok "6g -R bad -R example-org/widget --strict exits 2 when swept repo is clean"
else
  bad "6g skip invalid repo --strict clean (rc=$rc)" "out=$(cat "$T/out") err=$(cat "$T/err")"
fi

printf '[{"number":1,"rule":{"id":"r1","security_severity_level":"critical"},"tool":{"name":"CodeQL"}}]\n' > "$T/fixtures/example-org_widget/code-scanning.out"
run_ss -R bad -R example-org/widget --no-cache --strict
if [ "$rc" -eq 1 ] && grep -qF "code-scanning 1" "$T/out" \
  && [ "$(cat "$T/err")" = "security-sweep: invalid repo 'bad' (expected owner/name), skipped" ]; then
  ok "6h -R bad -R example-org/widget --strict exits 1 when swept repo trips alert threshold"
else
  bad "6h skip invalid repo --strict alert wins (rc=$rc)" "out=$(cat "$T/out") err=$(cat "$T/err")"
fi

# 7. Claim 7: --all-repos-from file with comments and two repos -> two lines
reset_state
mkdir -p "$T/fixtures/example-org_widget" "$T/fixtures/example-org_gadget"
cat > "$T/repos.txt" <<'EOF'
# Tracked repositories
example-org/widget   # first repo
  # indented comment
example-org/gadget
EOF
run_ss --all-repos-from "$T/repos.txt"
if [ "$rc" -eq 0 ] && [ "$(cat "$T/out")" = "$(printf 'example-org/widget: clean\nexample-org/gadget: clean')" ]; then
  ok "7 --all-repos-from ignores comments and sweeps both repos in order"
else
  bad "7 --all-repos-from (rc=$rc)" "$(cat "$T/out" "$T/err")"
fi

# 7b: non-UTF-8 --all-repos-from file -> --strict exits 2 (0 without --strict) and prints cannot read on stderr
printf '\xff\xfe\n' > "$T/bad-utf8.txt"
run_ss --all-repos-from "$T/bad-utf8.txt" --strict
if [ "$rc" -eq 2 ] && [ ! -s "$T/out" ] && grep -qF "security-sweep: cannot read $T/bad-utf8.txt:" "$T/err"; then
  ok "7b non-UTF-8 --all-repos-from file under --strict exits 2 with cannot read stderr message"
else
  bad "7b non-UTF-8 --all-repos-from --strict (rc=$rc)" "out=$(cat "$T/out") err=$(cat "$T/err")"
fi
run_ss --all-repos-from "$T/bad-utf8.txt"
if [ "$rc" -eq 0 ] && [ ! -s "$T/out" ] && grep -qF "security-sweep: cannot read $T/bad-utf8.txt:" "$T/err"; then
  ok "7c non-UTF-8 --all-repos-from file without --strict exits 0 with cannot read stderr message"
else
  bad "7c non-UTF-8 --all-repos-from default (rc=$rc)" "out=$(cat "$T/out") err=$(cat "$T/err")"
fi

# 8. Claim 8: Paginated output ([..][..] concatenated) counts both pages
reset_state
mkdir -p "$T/fixtures/example-org_widget"
printf '[{"number":1,"security_advisory":{"severity":"high"},"dependency":{"package":{"name":"pkg-a"}}}][{"number":2,"security_advisory":{"severity":"low"},"dependency":{"package":{"name":"pkg-b"}}}]' \
  > "$T/fixtures/example-org_widget/dependabot.out"
run_ss -R example-org/widget
if [ "$rc" -eq 0 ] && [ "$(cat "$T/out")" = "example-org/widget: code-scanning 0 · dependabot 2 (1 high; 1 low) · secret-scanning 0" ]; then
  ok "8 paginated [..][..] output decodes and concatenates both pages"
else
  bad "8 paginated output (rc=$rc)" "$(cat "$T/out" "$T/err")"
fi

# 9. Claim 9: --session-line
# 9a: all clean / off / error -> empty stdout and empty stderr
reset_state
mkdir -p "$T/fixtures/example-org_widget"
printf 'gh: Not Found (HTTP 404)\n' > "$T/fixtures/example-org_widget/dependabot.err"
printf '1\n' > "$T/fixtures/example-org_widget/dependabot.rc"
printf '{"message":"Secret scanning is disabled on this repository."}\n' > "$T/fixtures/example-org_widget/secret-scanning.out"
printf '1\n' > "$T/fixtures/example-org_widget/secret-scanning.rc"
run_ss -R example-org/widget --session-line
if [ "$rc" -eq 0 ] && [ ! -s "$T/out" ] && [ ! -s "$T/err" ]; then
  ok "9a --session-line with clean/off/error surfaces outputs nothing on stdout or stderr"
else
  bad "9a --session-line clean/off/error (rc=$rc)" "out=$(cat "$T/out") err=$(cat "$T/err")"
fi

# 9b: one repo with open alerts -> one line starting 'security: example-org/widget: ' and ending '— dispositions per skill seyag:security-sweep'
reset_state
mkdir -p "$T/fixtures/example-org_widget" "$T/fixtures/example-org_gadget"
cat > "$T/fixtures/example-org_widget/code-scanning.out" <<'EOF'
[
  {"number": 1, "rule": {"id": "r1", "security_severity_level": "critical"}, "tool": {"name": "CodeQL"}},
  {"number": 2, "rule": {"id": "r2", "security_severity_level": "high"}, "tool": {"name": "CodeQL"}},
  {"number": 3, "rule": {"id": "r3", "security_severity_level": "medium"}, "tool": {"name": "CodeQL"}}
]
EOF
cat > "$T/fixtures/example-org_widget/dependabot.out" <<'EOF'
[
  {"number": 10, "security_advisory": {"severity": "high"}, "dependency": {"package": {"name": "pkg-a"}}}
]
EOF
run_ss -R example-org/widget -R example-org/gadget --session-line
WANT_SESSION="security: example-org/widget: 3 code-scanning (1 critical, 1 high), 1 dependabot — dispositions per skill seyag:security-sweep"
if [ "$rc" -eq 0 ] && [ "$(cat "$T/out")" = "$WANT_SESSION" ] && [ ! -s "$T/err" ]; then
  ok "9b --session-line formats nonzero surfaces and nonzero critical/high counts in one line"
else
  bad "9b --session-line one repo (rc=$rc)" "out=$(cat "$T/out") err=$(cat "$T/err")"
fi

# 9c: two repos with alerts joined by '; ', medium-only code-scanning omits parenthetical
cat > "$T/fixtures/example-org_gadget/code-scanning.out" <<'EOF'
[
  {"number": 5, "rule": {"id": "r5", "security_severity_level": "medium"}, "tool": {"name": "CodeQL"}}
]
EOF
cat > "$T/fixtures/example-org_gadget/secret-scanning.out" <<'EOF'
[
  {"number": 6, "secret_type_display_name": "Example Token", "secret": "FIXTURE-SECRET-VALUE-0003"}
]
EOF
run_ss -R example-org/widget -R example-org/gadget --no-cache --session-line
WANT_SESSION_2="security: example-org/widget: 3 code-scanning (1 critical, 1 high), 1 dependabot; example-org/gadget: 1 code-scanning, 1 secret-scanning — dispositions per skill seyag:security-sweep"
if [ "$rc" -eq 0 ] && [ "$(cat "$T/out")" = "$WANT_SESSION_2" ] && [ ! -s "$T/err" ]; then
  ok "9c --session-line joins multiple alert repos with '; ' and omits empty critical/high parens"
else
  bad "9c --session-line two repos (rc=$rc)" "out=$(cat "$T/out") err=$(cat "$T/err")"
fi

# 9d: --session-line with an unexpected Exception inside main exits 0 with empty stderr
reset_state
mkdir -p "$T/state/seyag/security-sweep"
python3 - "$CACHE_FILE" <<'PY'
import json, sys
json.dump({
    "fetched_at": 10**400,
    "surfaces": {
        "code-scanning": {"state": "off"},
        "dependabot": {"state": "off"},
        "secret-scanning": {"state": "off"},
    },
}, open(sys.argv[1], "w"))
PY
run_ss -R example-org/widget --session-line
if [ "$rc" -eq 0 ] && [ ! -s "$T/out" ] && [ ! -s "$T/err" ]; then
  ok "9d --session-line with wrong-typed cache data exits 0 and writes nothing to stderr"
else
  bad "9d --session-line exception suppression (rc=$rc)" "out=$(cat "$T/out") err=$(cat "$T/err")"
fi

# 9e & 9f: outside --session-line, an unexpected Exception from main (TypeError when alerts[].rule.id is an int in format_code_scanning_detail) prints class name only and exits 1 (2 under --strict)
python3 - "$CACHE_FILE" <<'PY'
import json, sys, time
json.dump({
    "fetched_at": time.time(),
    "surfaces": {
        "code-scanning": {"state": "count", "count": 1, "by_severity": {"critical": 1}, "alerts": [{"rule": {"security_severity_level": "critical", "id": 1}}]},
        "dependabot": {"state": "off"},
        "secret-scanning": {"state": "off"},
    },
}, open(sys.argv[1], "w"))
PY
run_ss -R example-org/widget
if [ "$rc" -eq 1 ] && [ ! -s "$T/out" ] && [ "$(cat "$T/err")" = "security-sweep: internal error: TypeError" ]; then
  ok "9e unexpected Exception outside --session-line prints class name only and exits 1"
else
  bad "9e internal error default exit (rc=$rc)" "out=$(cat "$T/out") err=$(cat "$T/err")"
fi
run_ss -R example-org/widget --strict
if [ "$rc" -eq 2 ] && [ ! -s "$T/out" ] && [ "$(cat "$T/err")" = "security-sweep: internal error: TypeError" ]; then
  ok "9f unexpected Exception under --strict prints class name only and exits 2"
else
  bad "9f internal error --strict exit (rc=$rc)" "out=$(cat "$T/out") err=$(cat "$T/err")"
fi

# 9g: --session-line -R -foo/bar (leading-dash token after -R) exits 0 with empty stdout and stderr
reset_state
run_ss --session-line -R -foo/bar
if [ "$rc" -eq 0 ] && [ ! -s "$T/out" ] && [ ! -s "$T/err" ]; then
  ok "9g --session-line -R -foo/bar exits 0 with empty stdout and stderr"
else
  bad "9g --session-line -R -foo/bar (rc=$rc)" "out=$(cat "$T/out") err=$(cat "$T/err")"
fi

# 9h: --session-line --repo=-foo/bar -R example-org/widget sweeps widget and prints its alert line
reset_state
mkdir -p "$T/fixtures/example-org_widget"
printf '[{"number":1,"rule":{"id":"r1","security_severity_level":"critical"},"tool":{"name":"CodeQL"}}]\n' > "$T/fixtures/example-org_widget/code-scanning.out"
run_ss --session-line --repo=-foo/bar -R example-org/widget
WANT_9H="security: example-org/widget: 1 code-scanning (1 critical) — dispositions per skill seyag:security-sweep"
if [ "$rc" -eq 0 ] && [ "$(cat "$T/out")" = "$WANT_9H" ] && [ ! -s "$T/err" ]; then
  ok "9h --session-line --repo=-foo/bar -R example-org/widget prints widget alert line and exits 0"
else
  bad "9h --session-line --repo=-foo/bar -R example-org/widget (rc=$rc)" "out=$(cat "$T/out") err=$(cat "$T/err")"
fi

# 9i: --session-line --cap 1 with held gh exits 124 before the hold ends
reset_state
mkdir -p "$T/fixtures/example-org_widget"
rm -f "$T/gh-release-9i"
printf '%s\n' "$T/gh-release-9i" > "$T/gh-hold"
t0=$SECONDS
run_ss --session-line --cap 1 -R example-org/widget
elapsed=$((SECONDS - t0))
: > "$T/gh-release-9i"
if [ "$rc" -eq 124 ] && [ "$elapsed" -le 8 ] && [ ! -s "$T/out" ] && [ ! -s "$T/err" ]; then
  ok "9i --session-line --cap 1 with held gh exits 124 before hold ends (${elapsed}s <= 8s)"
else
  bad "9i --session-line --cap 1 (rc=$rc, elapsed=${elapsed}s)" "out=$(cat "$T/out") err=$(cat "$T/err")"
fi

# 9n: --cap 1 expiry stops the held gh children
reset_state
mkdir -p "$T/fixtures/example-org_widget"
rm -f "$T/gh-release-9n"
printf '%s\n' "$T/gh-release-9n" > "$T/gh-hold"
run_ss --session-line --cap 1 -R example-org/widget
live_pids=""
if [ -s "$T/gh-pids" ]; then
  for _ in $(seq 1 30); do
    live_pids=""
    while IFS= read -r _pid; do
      [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null && live_pids="${live_pids:+$live_pids }$_pid"
    done < "$T/gh-pids"
    [ -z "$live_pids" ] && break
    sleep 0.1
  done
fi
: > "$T/gh-release-9n"
if [ "$rc" -eq 124 ] && [ -s "$T/gh-pids" ] && [ -z "$live_pids" ]; then
  ok "9n --cap 1 expiry stops the held gh children ($(wc -l <"$T/gh-pids") pids gone)"
else
  bad "9n --cap 1 expiry stops the held gh children (rc=$rc, live=$live_pids)"
fi

# 9o: --cap firing mid-write finishes the cache write and exits 124 with no .tmp file left behind
rm -rf "$T/state9o"
python3 - "$SS" "$T/state9o" >"$T/out" 2>"$T/err" <<'PY'
import importlib.machinery, importlib.util, os, signal, sys
path, state = sys.argv[1], sys.argv[2]
os.environ["XDG_STATE_HOME"] = state
loader = importlib.machinery.SourceFileLoader("ss", path)
spec = importlib.util.spec_from_loader("ss", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
mod._install_cap(3600)
real_dump = mod.json.dump
def wrapped_dump(*a, **kw):
    os.kill(os.getpid(), signal.SIGALRM)
    return real_dump(*a, **kw)
mod.json.dump = wrapped_dump
mod.write_cache(
    "example-org/widget",
    1,
    {
        "code-scanning": {"state": "off"},
        "dependabot": {"state": "off"},
        "secret-scanning": {"state": "off"},
    },
)
print("returned")
sys.exit(0)
PY
rc9o=$?
CACHE_9O="$T/state9o/seyag/security-sweep/example-org_widget.json"
if [ "$rc9o" -eq 124 ] \
  && [ -f "$CACHE_9O" ] \
  && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CACHE_9O" >/dev/null 2>&1 \
  && [ -z "$(find "$T/state9o" -name '*.tmp' 2>/dev/null)" ]; then
  ok "9o --cap firing during write_cache finishes cache write and exits 124 with no .tmp file"
else
  bad "9o --cap mid-write (rc=$rc9o)" "out=$(cat "$T/out") err=$(cat "$T/err") files=$(find "$T/state9o" 2>/dev/null)"
fi

# 9p: _cap_pending set before write_cache skips the write and exits 124 with no cache or .tmp file
rm -rf "$T/state9p"
python3 - "$SS" "$T/state9p" >"$T/out" 2>"$T/err" <<'PY'
import importlib.machinery, importlib.util, os, sys
path, state = sys.argv[1], sys.argv[2]
os.environ["XDG_STATE_HOME"] = state
loader = importlib.machinery.SourceFileLoader("ss", path)
spec = importlib.util.spec_from_loader("ss", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
mod._cap_pending = True
mod.write_cache(
    "example-org/widget",
    1,
    {
        "code-scanning": {"state": "off"},
        "dependabot": {"state": "off"},
        "secret-scanning": {"state": "off"},
    },
)
print("returned")
sys.exit(0)
PY
rc9p=$?
CACHE_9P="$T/state9p/seyag/security-sweep/example-org_widget.json"
if [ "$rc9p" -eq 124 ] \
  && [ ! -e "$CACHE_9P" ] \
  && [ -z "$(find "$T/state9p" -name '*.tmp' 2>/dev/null)" ]; then
  ok "9p _cap_pending before write_cache skips write and exits 124 with no .tmp file"
else
  bad "9p _cap_pending before write_cache (rc=$rc9p)" "out=$(cat "$T/out") err=$(cat "$T/err") files=$(find "$T/state9p" 2>/dev/null)"
fi

# 9q: --cap firing during a worker-thread write_cache finishes the write and exits 124
rm -rf "$T/state9q"
python3 - "$SS" "$T/state9q" >"$T/out" 2>"$T/err" <<'PY'
import importlib.machinery, importlib.util, os, signal, sys, threading, time
path, state = sys.argv[1], sys.argv[2]
os.environ["XDG_STATE_HOME"] = state
loader = importlib.machinery.SourceFileLoader("ss", path)
spec = importlib.util.spec_from_loader("ss", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
mod._install_cap(3600)
real_dump = mod.json.dump
def wrapped_dump(*a, **kw):
    os.kill(os.getpid(), signal.SIGALRM)
    # Wait for the main-thread handler to set _cap_pending while _cap_writes == 1 so the exit comes from the worker thread.
    deadline = time.monotonic() + 5
    while not mod._cap_pending and time.monotonic() < deadline:
        time.sleep(0.005)
    return real_dump(*a, **kw)
mod.json.dump = wrapped_dump
t = threading.Thread(
    target=mod.write_cache,
    args=(
        "example-org/widget",
        1,
        {
            "code-scanning": {"state": "off"},
            "dependabot": {"state": "off"},
            "secret-scanning": {"state": "off"},
        },
    ),
)
t.start()
while t.is_alive():
    t.join(0.05)
print("returned")
sys.exit(0)
PY
rc9q=$?
CACHE_9Q="$T/state9q/seyag/security-sweep/example-org_widget.json"
if [ "$rc9q" -eq 124 ] \
  && [ -f "$CACHE_9Q" ] \
  && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CACHE_9Q" >/dev/null 2>&1 \
  && [ -z "$(find "$T/state9q" -name '*.tmp' 2>/dev/null)" ]; then
  ok "9q --cap firing during a worker-thread write_cache finishes the write and exits 124"
else
  bad "9q --cap worker-thread mid-write (rc=$rc9q)" "out=$(cat "$T/out") err=$(cat "$T/err") files=$(find "$T/state9q" 2>/dev/null)"
fi

# 9r: external SIGTERM during a main-thread write_cache finishes the write and exits 124
rm -rf "$T/state9r"
python3 - "$SS" "$T/state9r" >"$T/out" 2>"$T/err" <<'PY'
import importlib.machinery, importlib.util, os, signal, sys
path, state = sys.argv[1], sys.argv[2]
os.environ["XDG_STATE_HOME"] = state
loader = importlib.machinery.SourceFileLoader("ss", path)
spec = importlib.util.spec_from_loader("ss", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
mod._install_cap(3600)
real_dump = mod.json.dump
def wrapped_dump(*a, **kw):
    os.kill(os.getpid(), signal.SIGTERM)
    return real_dump(*a, **kw)
mod.json.dump = wrapped_dump
mod.write_cache(
    "example-org/widget",
    1,
    {
        "code-scanning": {"state": "off"},
        "dependabot": {"state": "off"},
        "secret-scanning": {"state": "off"},
    },
)
print("returned")
sys.exit(0)
PY
rc9r=$?
CACHE_9R="$T/state9r/seyag/security-sweep/example-org_widget.json"
if [ "$rc9r" -eq 124 ] \
  && [ -f "$CACHE_9R" ] \
  && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CACHE_9R" >/dev/null 2>&1 \
  && [ -z "$(find "$T/state9r" -name '*.tmp' 2>/dev/null)" ]; then
  ok "9r external SIGTERM during write_cache finishes the write and exits 124"
else
  bad "9r external SIGTERM mid-write (rc=$rc9r)" "out=$(cat "$T/out") err=$(cat "$T/err") files=$(find "$T/state9r" 2>/dev/null)"
fi

# 9s: external SIGTERM during a worker-thread write_cache finishes the write and exits 124
rm -rf "$T/state9s"
python3 - "$SS" "$T/state9s" >"$T/out" 2>"$T/err" <<'PY'
import importlib.machinery, importlib.util, os, signal, sys, threading, time
path, state = sys.argv[1], sys.argv[2]
os.environ["XDG_STATE_HOME"] = state
loader = importlib.machinery.SourceFileLoader("ss", path)
spec = importlib.util.spec_from_loader("ss", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
mod._install_cap(3600)
real_dump = mod.json.dump
def wrapped_dump(*a, **kw):
    os.kill(os.getpid(), signal.SIGTERM)
    # Wait for the main-thread handler to set _cap_pending while _cap_writes == 1 so the exit comes from the worker thread.
    deadline = time.monotonic() + 5
    while not mod._cap_pending and time.monotonic() < deadline:
        time.sleep(0.005)
    return real_dump(*a, **kw)
mod.json.dump = wrapped_dump
t = threading.Thread(
    target=mod.write_cache,
    args=(
        "example-org/widget",
        1,
        {
            "code-scanning": {"state": "off"},
            "dependabot": {"state": "off"},
            "secret-scanning": {"state": "off"},
        },
    ),
)
t.start()
while t.is_alive():
    t.join(0.05)
print("returned")
sys.exit(0)
PY
rc9s=$?
CACHE_9S="$T/state9s/seyag/security-sweep/example-org_widget.json"
if [ "$rc9s" -eq 124 ] \
  && [ -f "$CACHE_9S" ] \
  && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CACHE_9S" >/dev/null 2>&1 \
  && [ -z "$(find "$T/state9s" -name '*.tmp' 2>/dev/null)" ]; then
  ok "9s external SIGTERM during a worker-thread write_cache finishes the write and exits 124"
else
  bad "9s external SIGTERM worker-thread mid-write (rc=$rc9s)" "out=$(cat "$T/out") err=$(cat "$T/err") files=$(find "$T/state9s" 2>/dev/null)"
fi

# 9t: --cap under stty tostop prints and exits instead of stopping on SIGTTOU
if ! command -v script >/dev/null 2>&1; then
  ok "9t skipped: script(1) not available"
else
  reset_state
  mkdir -p "$T/fixtures/example-org_widget"
  SECURITY_SWEEP_GH="$T/bin/gh" XDG_STATE_HOME="$T/state" \
    timeout 20 script -qfec "stty tostop; \"$SS\" --cap 8 --no-cache -R example-org/widget; echo rc=\$?" /dev/null >"$T/out" 2>"$T/err"
  rc9t=$?
  # script -e returns the inner shell's last command (echo), so rc9t only shows timeout(1) did not fire; the grep for rc=0 checks the sweep's own exit code.
  if [ "$rc9t" -eq 0 ] \
    && grep -qF "example-org/widget: clean" "$T/out" \
    && grep -qF "rc=0" "$T/out"; then
    ok "9t --cap under stty tostop prints and exits instead of stopping on SIGTTOU"
  else
    bad "9t --cap under tostop (rc=$rc9t)" "out=$(cat "$T/out") err=$(cat "$T/err")"
  fi
fi

# 9u: a racing second entry still signals the group
rm -f "$T/9u.pid"
python3 - "$SS" "$T/9u.pid" >"$T/out" 2>"$T/err" <<'PY'
import importlib.machinery, importlib.util, os, signal, subprocess, sys
path, pid_file = sys.argv[1], sys.argv[2]
loader = importlib.machinery.SourceFileLoader("ss", path)
spec = importlib.util.spec_from_loader("ss", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
mod._install_cap(3600)
proc = subprocess.Popen(["sleep", "30"])
with open(pid_file, "w", encoding="utf-8") as f:
    f.write(f"{proc.pid}\n")
mod._cap_exits = 1
mod._cap_fire(signal.SIGALRM, None)
print("returned")
sys.exit(0)
PY
rc9u=$?
pid9u=""
[ -s "$T/9u.pid" ] && pid9u=$(cat "$T/9u.pid")
alive9u=1
if [ -n "$pid9u" ]; then
  for _ in $(seq 1 30); do
    if ! kill -0 "$pid9u" 2>/dev/null; then
      alive9u=0
      break
    fi
    sleep 0.1
  done
  if [ "$alive9u" -eq 1 ]; then
    kill "$pid9u" 2>/dev/null || true
  fi
fi
if [ "$rc9u" -eq 124 ] \
  && [ -n "$pid9u" ] \
  && [ "$alive9u" -eq 0 ] \
  && ! grep -qF "returned" "$T/out"; then
  ok "9u a racing second _cap_exit entry still signals the group"
else
  bad "9u racing second entry (rc=$rc9u)" "alive=$alive9u out=$(cat "$T/out") err=$(cat "$T/err")"
fi

# 9v: a second SIGTERM escalates past an in-flight write
rm -rf "$T/state9v"
python3 - "$SS" "$T/state9v" >"$T/out" 2>"$T/err" <<'PY'
import importlib.machinery, importlib.util, os, signal, sys, time
path, state = sys.argv[1], sys.argv[2]
os.environ["XDG_STATE_HOME"] = state
loader = importlib.machinery.SourceFileLoader("ss", path)
spec = importlib.util.spec_from_loader("ss", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
mod._install_cap(3600)
real_dump = mod.json.dump
def wrapped_dump(*a, **kw):
    os.kill(os.getpid(), signal.SIGTERM)
    deadline = time.monotonic() + 5
    while mod._cap_terms < 1 and time.monotonic() < deadline:
        time.sleep(0.005)
    os.kill(os.getpid(), signal.SIGTERM)
    time.sleep(5)
    return real_dump(*a, **kw)
mod.json.dump = wrapped_dump
mod.write_cache(
    "example-org/widget",
    1,
    {
        "code-scanning": {"state": "off"},
        "dependabot": {"state": "off"},
        "secret-scanning": {"state": "off"},
    },
)
print("returned")
sys.exit(0)
PY
rc9v=$?
CACHE_9V="$T/state9v/seyag/security-sweep/example-org_widget.json"
if [ "$rc9v" -eq 124 ] \
  && [ ! -e "$CACHE_9V" ] \
  && ! grep -qF "returned" "$T/out"; then
  ok "9v a second SIGTERM exits mid-write instead of waiting for it"
else
  bad "9v second SIGTERM mid-write (rc=$rc9v)" "out=$(cat "$T/out") err=$(cat "$T/err") files=$(find "$T/state9v" 2>/dev/null)"
fi

# Shared harness for 9w (mode alarm) and 9x (mode term-alarm); the mode picks the signal sequence sent mid-write.
# SIGALRM is masked on the main thread (pool threads inherit the mask) and unmasked only by the writing worker,
# so every SIGALRM (the cap's and the grace re-arm's) lands on that worker: main must still run the handler while the write stalls.
cat >"$T/cap_mid_write.py" <<'PY'
import importlib.machinery, importlib.util, os, signal, sys, time
path, state, mode = sys.argv[1], sys.argv[2], sys.argv[3]
if mode not in ("alarm", "term-alarm"):
    sys.exit("cap_mid_write: unknown mode " + mode)
os.environ["XDG_STATE_HOME"] = state
loader = importlib.machinery.SourceFileLoader("ss", path)
spec = importlib.util.spec_from_loader("ss", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
real_dump = mod.json.dump
def wrapped_dump(*a, **kw):
    signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGALRM})
    if mode == "alarm":
        os.kill(os.getpid(), signal.SIGALRM)
        deadline = time.monotonic() + 5
        while not mod._cap_pending and time.monotonic() < deadline:
            time.sleep(0.005)
    elif mode == "term-alarm":
        os.kill(os.getpid(), signal.SIGTERM)
        deadline = time.monotonic() + 5
        while mod._cap_terms < 1 and time.monotonic() < deadline:
            time.sleep(0.005)
        os.kill(os.getpid(), signal.SIGALRM)
        deadline = time.monotonic() + 5
        while mod._cap_alarms < 1 and time.monotonic() < deadline:
            time.sleep(0.005)
    time.sleep(8)
    return real_dump(*a, **kw)
mod.json.dump = wrapped_dump
signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGALRM})
rc = mod.main(["--cap", "3600", "--no-cache", "-R", "example-org/widget"])
print("returned", rc)
sys.exit(0)
PY

# 9w: --cap expiry during a stalled worker-thread write exits after the grace instead of waiting for the write
reset_state
mkdir -p "$T/fixtures/example-org_widget"
rm -rf "$T/state9w"
t0=$SECONDS
SECURITY_SWEEP_GH="$T/bin/gh" python3 "$T/cap_mid_write.py" "$SS" "$T/state9w" alarm >"$T/out" 2>"$T/err"
rc9w=$?
elapsed9w=$((SECONDS - t0))
CACHE_9W="$T/state9w/seyag/security-sweep/example-org_widget.json"
if [ "$rc9w" -eq 124 ] \
  && [ ! -e "$CACHE_9W" ] \
  && ! grep -qF "returned" "$T/out" \
  && [ "$elapsed9w" -le 4 ]; then
  ok "9w --cap expiry during a stalled write exits after the grace (${elapsed9w}s <= 4s)"
else
  bad "9w --cap grace mid-write (rc=$rc9w, elapsed=${elapsed9w}s)" "out=$(cat "$T/out") err=$(cat "$T/err") files=$(find "$T/state9w" 2>/dev/null)"
fi

# 9x: a SIGTERM then the cap alarm during a stalled write still exits after the grace (the re-arm does not depend on _cap_terms)
reset_state
mkdir -p "$T/fixtures/example-org_widget"
rm -rf "$T/state9x"
t0=$SECONDS
SECURITY_SWEEP_GH="$T/bin/gh" python3 "$T/cap_mid_write.py" "$SS" "$T/state9x" term-alarm >"$T/out" 2>"$T/err"
rc9x=$?
elapsed9x=$((SECONDS - t0))
CACHE_9X="$T/state9x/seyag/security-sweep/example-org_widget.json"
if [ "$rc9x" -eq 124 ] \
  && [ ! -e "$CACHE_9X" ] \
  && ! grep -qF "returned" "$T/out" \
  && [ "$elapsed9x" -le 4 ]; then
  ok "9x SIGTERM then cap alarm during a stalled write exits after the grace (${elapsed9x}s <= 4s)"
else
  bad "9x SIGTERM then cap alarm mid-write (rc=$rc9x, elapsed=${elapsed9x}s)" "out=$(cat "$T/out") err=$(cat "$T/err") files=$(find "$T/state9x" 2>/dev/null)"
fi

# 9j & 9k: --warm-cache deduplicates via non-blocking flock and populates cache when unheld
reset_state
mkdir -p "$T/fixtures/example-org_widget"
printf '[{"number":1,"rule":{"id":"r1","security_severity_level":"critical"},"tool":{"name":"CodeQL"}}]\n' > "$T/fixtures/example-org_widget/code-scanning.out"
python3 - "$T/state" "$T/lock-ready" "$T/lock-release" <<'PY' &
import fcntl, hashlib, os, sys, time
d = os.path.join(sys.argv[1], "seyag", "security-sweep")
os.makedirs(d, exist_ok=True)
h = hashlib.sha1(b"example-org/widget").hexdigest()[:12]
fd = os.open(os.path.join(d, f".warm-{h}.lock"), os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
open(sys.argv[2], "w").close()
for _ in range(300):
    if os.path.exists(sys.argv[3]):
        break
    time.sleep(0.1)
PY
LOCK_PID=$!
for _ in $(seq 1 100); do
  [ -e "$T/lock-ready" ] && break
  sleep 0.05
done
run_ss --warm-cache -R example-org/widget
rc_held=$rc
calls_held=$(wc -l <"$T/gh.log")
out_held=$(cat "$T/out")
err_held=$(cat "$T/err")
: > "$T/lock-release"
wait "$LOCK_PID" 2>/dev/null || true
if [ "$rc_held" -eq 0 ] && [ "$calls_held" -eq 0 ] && [ -z "$out_held" ] && [ -z "$err_held" ] && [ ! -s "$CACHE_FILE" ]; then
  ok "9j --warm-cache with lock held exits 0 immediately without invoking gh"
else
  bad "9j --warm-cache held lock (rc=$rc_held, calls=$calls_held)" "out=$out_held err=$err_held"
fi

run_ss --warm-cache -R example-org/widget
if [ "$rc" -eq 0 ] && [ -s "$CACHE_FILE" ] && [ ! -s "$T/out" ] && [ ! -s "$T/err" ]; then
  ok "9k --warm-cache without lock hold populates cache file with empty stdout and stderr"
else
  bad "9k --warm-cache unheld (rc=$rc)" "out=$(cat "$T/out") err=$(cat "$T/err")"
fi

# 9l: --session --repo=-foo/bar (abbreviated flag) is refused with exit 2 and unrecognized arguments on stderr
reset_state
run_ss --session --repo=-foo/bar
if [ "$rc" -eq 2 ] && [ ! -s "$T/out" ] && grep -qF "unrecognized arguments: --session" "$T/err"; then
  ok "9l --session --repo=-foo/bar is refused as an abbreviated flag (rc=2, stderr names --session)"
else
  bad "9l abbreviated --session flag (rc=$rc)" "out=$(cat "$T/out") err=$(cat "$T/err")"
fi

# 9m: --warm-cache lock digest sorts the repo set so reverse-order -R flags share the same lock
reset_state
mkdir -p "$T/fixtures/example-org_a" "$T/fixtures/example-org_widget"
python3 - "$T/state" "$T/lock-ready" "$T/lock-release" <<'PY' &
import fcntl, hashlib, os, sys, time
d = os.path.join(sys.argv[1], "seyag", "security-sweep")
os.makedirs(d, exist_ok=True)
h = hashlib.sha1(" ".join(sorted(["example-org/a", "example-org/widget"])).encode("utf-8")).hexdigest()[:12]
fd = os.open(os.path.join(d, f".warm-{h}.lock"), os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
open(sys.argv[2], "w").close()
for _ in range(300):
    if os.path.exists(sys.argv[3]):
        break
    time.sleep(0.1)
PY
LOCK_PID=$!
for _ in $(seq 1 100); do
  [ -e "$T/lock-ready" ] && break
  sleep 0.05
done
run_ss --warm-cache -R example-org/widget -R example-org/a
rc_held=$rc
calls_held=$(wc -l <"$T/gh.log")
out_held=$(cat "$T/out")
err_held=$(cat "$T/err")
: > "$T/lock-release"
wait "$LOCK_PID" 2>/dev/null || true
if [ "$rc_held" -eq 0 ] && [ "$calls_held" -eq 0 ] && [ -z "$out_held" ] && [ -z "$err_held" ]; then
  ok "9m --warm-cache with reverse-order -R flags hits sorted repo-set lock without invoking gh"
else
  bad "9m --warm-cache sorted repo-set lock (rc=$rc_held, calls=$calls_held)" "out=$out_held err=$err_held"
fi

# --help check
"$SS" --help >"$T/help" 2>&1; hrc=$?
if [ "$hrc" -eq 0 ] && grep -qF "SECURITY_SWEEP_GH" "$T/help" && grep -qF -- "--session-line" "$T/help"; then
  ok "10 --help exits 0 and documents options and SECURITY_SWEEP_GH"
else
  bad "10 --help (rc=$hrc)" "$(cat "$T/help")"
fi
if [ "$hrc" -eq 0 ] && grep -qF "SECURITY_SWEEP_GH_TIMEOUT" "$T/help"; then
  ok "10b --help documents SECURITY_SWEEP_GH_TIMEOUT"
else
  bad "10b --help SECURITY_SWEEP_GH_TIMEOUT (rc=$hrc)" "$(cat "$T/help")"
fi

if [ -z "${SECURITY_SWEEP_SKIP_NONEXEC:-}" ]; then
  # 11: probe must not chmod +x a non-executable target bin; it must fail the [ -x ] assertion instead
  cp "$SS" "$T/nonexec-ss" && chmod 644 "$T/nonexec-ss"
  nonexec_out=$(SECURITY_SWEEP_BIN="$T/nonexec-ss" SECURITY_SWEEP_SKIP_NONEXEC=1 SECURITY_SWEEP_SKIP_CANARIES=1 bash "${BASH_SOURCE[0]}" 2>&1); nonexec_rc=$?
  if [ "$nonexec_rc" -ne 0 ] && [ ! -x "$T/nonexec-ss" ] && grep -qF "FAIL: security-sweep is not executable" <<<"$nonexec_out"; then
    ok "11 non-executable SECURITY_SWEEP_BIN fails [ -x ] check without chmodding the file"
  else
    bad "11 non-executable SECURITY_SWEEP_BIN check (rc=$nonexec_rc, x=$([ -x "$T/nonexec-ss" ] && echo 1 || echo 0))" "$(head -n 3 <<<"$nonexec_out")"
  fi
fi

# Positive controls / canaries on mutated copies of security-sweep (skipped during recursive self-calls or when a base row failed)
if [ -z "${SECURITY_SWEEP_SKIP_CANARIES:-}" ] && [ "$fail" -eq 0 ]; then
  canary_running=0
  launch_canary() {
    local id="$1" bin="$2" stop_flag="$3" probe="${4:-${BASH_SOURCE[0]}}"
    (
      if [ "$stop_flag" -eq 1 ]; then
        SECURITY_SWEEP_BIN="$bin" SECURITY_SWEEP_SKIP_CANARIES=1 SECURITY_SWEEP_STOP_AT_FAIL=1 bash "$probe" >"$T/canary-$id.out" 2>&1
      else
        SECURITY_SWEEP_BIN="$bin" SECURITY_SWEEP_SKIP_CANARIES=1 bash "$probe" >"$T/canary-$id.out" 2>&1
      fi
      echo $? >"$T/canary-$id.rc"
    ) &
    canary_running=$((canary_running + 1))
    if [ "$canary_running" -ge 4 ]; then
      wait -n 2>/dev/null || true
      canary_running=$((canary_running - 1))
    fi
  }
  load_canary() {
    local id="$1"
    mut_out=$(cat "$T/canary-$id.out")
    mut_rc=$(cat "$T/canary-$id.rc")
    mut_first_fail=$(grep -m1 '^FAIL:' <<<"$mut_out")
  }
  canary_bad() { bad "$1; first FAIL: ${mut_first_fail:-none}" "$2"; }

  # Phase 1: build every mutant (sed, cmp guard, chmod), then launch canary re-runs
  # concurrently (at most 4 at a time), longest-running first so hold/timeout waits overlap.
  sed 's/security_severity_level/severity/g' "$SS" > "$T/mut-1a" && chmod +x "$T/mut-1a"
  sed '/"rules_critical_high":/d' "$SS" > "$T/mut-1b" && chmod +x "$T/mut-1b"
  sed 's/"secret_type_display_name": t/"secret_type_display_name": t, "secret": a.get("secret")/' "$SS" > "$T/mut-2" && chmod +x "$T/mut-2"
  sed 's/return {"state": "error"}, p.returncode/return {"state": "off"}, None/' "$SS" > "$T/mut-3" && chmod +x "$T/mut-3"
  sed 's/def format_session_line(results):/def format_session_line(results):\n    return ""/' "$SS" > "$T/mut-purpose" && chmod +x "$T/mut-purpose"
  sed 's/^    if not args.session_line:/    if not args.strict and not args.session_line:/' "$SS" > "$T/mut-r1-1" && chmod +x "$T/mut-r1-1"
  sed '/if not repos:/{n;s/return 2 if args.strict else 0/return 2/;}' "$SS" > "$T/mut-r1-2" && chmod +x "$T/mut-r1-2"
  sed '/timeout=gh_timeout_s(),/d' "$SS" > "$T/mut-r1-3" && chmod +x "$T/mut-r1-3"
  sed 's/if "--session-line" in sys.argv\[1:\] or "--warm-cache" in sys.argv\[1:\]:/if False:/' "$SS" > "$T/mut-r1-4" && chmod +x "$T/mut-r1-4"
  cmp -s "$SS" "$T/mut-r1-4" && bad "canary r1-4: mutation did not apply (pattern drifted from the bin)"
  sed 's/if any(m in combined for m in OFF_MARKERS):/if "Code scanning is not enabled" in combined or "Secret scanning is disabled" in combined:/' "$SS" > "$T/mut-r2-1" && chmod +x "$T/mut-r2-1"
  sed -e 's/except (OSError, UnicodeDecodeError) as e:/except OSError as e:/' -e 's/except Exception as e:/except SystemExit:/' "$SS" > "$T/mut-r2-3" && chmod +x "$T/mut-r2-3"
  sed -e 's/, skipped//' -e 's/had_invalid_repo = True/return 2 if args.strict else 0/' "$SS" > "$T/mut-r2-4" && chmod +x "$T/mut-r2-4"
  sed -e '/"numbers":/d' -e '/"rules":/d' -e '/"packages":/d' "$SS" > "$T/mut-r2-5" && chmod +x "$T/mut-r2-5"
  sed 's@^\[ -x "\$SS" \]@chmod +x "\$SS" 2>/dev/null || true\n[ -x "\$SS" ]@' "${BASH_SOURCE[0]}" > "$T/mut-probe-r2-6.sh"
  sed 's/if self.quiet:/if False:/' "$SS" > "$T/mut-r3-1" && chmod +x "$T/mut-r3-1"
  sed '/signal\.setitimer(signal\.ITIMER_REAL, seconds)/d' "$SS" > "$T/mut-r3-2" && chmod +x "$T/mut-r3-2"
  cmp -s "$SS" "$T/mut-r3-2" && bad "canary r3-2: mutation did not apply (pattern drifted from the bin)"
  sed 's/fcntl\.flock(warm_lock_fd, fcntl\.LOCK_EX | fcntl\.LOCK_NB)/pass/' "$SS" > "$T/mut-r3-3" && chmod +x "$T/mut-r3-3"
  sed 's/def is_valid_cached_surface(sdata):/def is_valid_cached_surface(sdata):\n    return isinstance(sdata, dict) and sdata.get("state") in ("count", "off")/' "$SS" > "$T/mut-r3-6" && chmod +x "$T/mut-r3-6"
  sed 's/sorted(repos)/repos/' "$SS" > "$T/mut-r3-7" && chmod +x "$T/mut-r3-7"
  sed 's/    if _cap_writes == 0 or _cap_terms >= 2:/    if True:/' "$SS" > "$T/mut-r4-1" && chmod +x "$T/mut-r4-1"
  cmp -s "$SS" "$T/mut-r4-1" && bad "canary r4-1: mutation did not apply (pattern drifted from the bin)"
  sed 's/os.killpg(os.getpgrp(), signal.SIGTERM)/pass/' "$SS" > "$T/mut-r4-2" && chmod +x "$T/mut-r4-2"
  cmp -s "$SS" "$T/mut-r4-2" && bad "canary r4-2: mutation did not apply (pattern drifted from the bin)"
  sed 's/        if not skip:/        if True:/' "$SS" > "$T/mut-r4-3" && chmod +x "$T/mut-r4-3"
  cmp -s "$SS" "$T/mut-r4-3" && bad "canary r4-3: mutation did not apply (pattern drifted from the bin)"
  sed 's/^def _cap_exit():$/def _cap_exit():\n    signal.signal(signal.SIGTERM, signal.SIG_IGN)/' "$SS" > "$T/mut-r4-4" && chmod +x "$T/mut-r4-4"
  cmp -s "$SS" "$T/mut-r4-4" && bad "canary r4-4: mutation did not apply (pattern drifted from the bin)"
  sed 's/    signal\.signal(signal\.SIGTERM, _cap_fire)/    signal.signal(signal.SIGTERM, lambda *_: os._exit(124))/' "$SS" > "$T/mut-r5-1" && chmod +x "$T/mut-r5-1"
  cmp -s "$SS" "$T/mut-r5-1" && bad "canary r5-1: mutation did not apply (pattern drifted from the bin)"
  sed 's/    if _cap_exits > 2:/    if False:/' "$SS" > "$T/mut-r5-2" && chmod +x "$T/mut-r5-2"
  cmp -s "$SS" "$T/mut-r5-2" && bad "canary r5-2: mutation did not apply (pattern drifted from the bin)"
  if command -v script >/dev/null 2>&1; then
    sed '/signal\.signal(signal\.SIGTTOU, signal\.SIG_IGN)/d' "$SS" > "$T/mut-r5-3" && chmod +x "$T/mut-r5-3"
    cmp -s "$SS" "$T/mut-r5-3" && bad "canary r5-3: mutation did not apply (pattern drifted from the bin)"
  fi
  sed 's/    if _cap_exits > 2:/    if _cap_exits > 1:/' "$SS" > "$T/mut-r6-1" && chmod +x "$T/mut-r6-1"
  cmp -s "$SS" "$T/mut-r6-1" && bad "canary r6-1: mutation did not apply (pattern drifted from the bin)"
  sed 's/_cap_terms >= 2/_cap_terms >= 99/' "$SS" > "$T/mut-r6-2" && chmod +x "$T/mut-r6-2"
  cmp -s "$SS" "$T/mut-r6-2" && bad "canary r6-2: mutation did not apply (pattern drifted from the bin)"
  sed 's/    if _cap_alarms >= 2:/    if False:/' "$SS" > "$T/mut-r7-1" && chmod +x "$T/mut-r7-1"
  cmp -s "$SS" "$T/mut-r7-1" && bad "canary r7-1: mutation did not apply (pattern drifted from the bin)"
  sed 's/_, pending = wait_futures(pending, timeout=_MAIN_WAIT_S)/_, pending = wait_futures(pending)/' "$SS" > "$T/mut-r8-1" && chmod +x "$T/mut-r8-1"
  cmp -s "$SS" "$T/mut-r8-1" && bad "canary r8-1: mutation did not apply (pattern drifted from the bin)"
  sed 's/    if _cap_alarms == 1 and signum == signal.SIGALRM:/    if _cap_alarms == 1 and signum == signal.SIGALRM and _cap_terms == 0:/' "$SS" > "$T/mut-r7-2" && chmod +x "$T/mut-r7-2"
  cmp -s "$SS" "$T/mut-r7-2" && bad "canary r7-2: mutation did not apply (pattern drifted from the bin)"

  # Space out the hold/timeout-bound canaries (r5-3, r1-3, r7-1, r3-2, r8-1, r7-2) across the full-run
  # canaries so at most ~1 slot is sleeping at a time while the other 3 run CPU work,
  # and finish with the shortest stop-at-fail canaries to avoid tail latency.
  if command -v script >/dev/null 2>&1; then
    launch_canary "r5-3" "$T/mut-r5-3" 1
  fi
  launch_canary "1a" "$T/mut-1a" 0
  launch_canary "purpose" "$T/mut-purpose" 0
  launch_canary "r2-1" "$T/mut-r2-1" 0
  launch_canary "r1-3" "$T/mut-r1-3" 1
  launch_canary "r2-3" "$T/mut-r2-3" 0
  launch_canary "r2-4" "$T/mut-r2-4" 0
  launch_canary "r7-1" "$T/mut-r7-1" 1
  launch_canary "r2-5" "$T/mut-r2-5" 0
  launch_canary "r3-6" "$T/mut-r3-6" 0
  launch_canary "r3-2" "$T/mut-r3-2" 1
  launch_canary "r5-1" "$T/mut-r5-1" 0
  launch_canary "r5-2" "$T/mut-r5-2" 0
  launch_canary "r8-1" "$T/mut-r8-1" 1
  launch_canary "r6-2" "$T/mut-r6-2" 1
  launch_canary "r6-1" "$T/mut-r6-1" 1
  launch_canary "r7-2" "$T/mut-r7-2" 0
  launch_canary "r2-6" "$SS" 1 "$T/mut-probe-r2-6.sh"
  launch_canary "r3-7" "$T/mut-r3-7" 1
  launch_canary "r3-3" "$T/mut-r3-3" 1
  launch_canary "r4-4" "$T/mut-r4-4" 1
  launch_canary "r4-3" "$T/mut-r4-3" 1
  launch_canary "r4-1" "$T/mut-r4-1" 1
  launch_canary "r4-2" "$T/mut-r4-2" 0
  launch_canary "r3-1" "$T/mut-r3-1" 1
  launch_canary "r1-4" "$T/mut-r1-4" 1
  launch_canary "r1-2" "$T/mut-r1-2" 1
  launch_canary "r1-1" "$T/mut-r1-1" 0
  launch_canary "3" "$T/mut-3" 1
  launch_canary "1b" "$T/mut-1b" 1
  launch_canary "2" "$T/mut-2" 1

  while [ "$canary_running" -gt 0 ]; do
    wait -n 2>/dev/null || true
    canary_running=$((canary_running - 1))
  done
  wait

  # Phase 2: evaluate each canary in order from its captured output and exit code.
  # Canary 1a: mutating rule.security_severity_level to rule.severity fails 1a and 1b
  load_canary "1a"
  if [ "$mut_rc" -ne 0 ] && grep -qF "FAIL: 1a default line" <<<"$mut_out" && grep -qF "FAIL: 1b --json shape" <<<"$mut_out"; then
    ok "canary 1a: mutating rule.security_severity_level -> rule.severity fails 1a and 1b"
  else
    canary_bad "canary 1a did not fail as expected (rc=$mut_rc)" "$mut_out"
  fi

  # Canary 1b: omitting rules_critical_high fails 1b
  load_canary "1b"
  if [ "$mut_rc" -ne 0 ] && grep -qF "FAIL: 1b --json shape" <<<"$mut_out"; then
    ok "canary 1b: omitting rules_critical_high fails 1b"
  else
    canary_bad "canary 1b did not fail as expected (rc=$mut_rc)" "$mut_out"
  fi

  # Canary 2: removing secret-scanning field filter fails 2 (secret value leak check)
  load_canary "2"
  if [ "$mut_rc" -ne 0 ] && grep -qF "FAIL: 2 secret value leaked into stdout, stderr, or state cache" <<<"$mut_out"; then
    ok "canary 2: removing secret-scanning field filter fails secret leak check"
  else
    canary_bad "canary 2 did not fail as expected (rc=$mut_rc)" "$mut_out"
  fi

  # Canary 3: treating every nonzero gh exit as off fails 3c Not Found row
  load_canary "3"
  if [ "$mut_rc" -ne 0 ] && grep -qF "FAIL: 3c Not Found error mapping" <<<"$mut_out"; then
    ok "canary 3: treating every nonzero gh exit as off fails 3c Not Found row"
  else
    canary_bad "canary 3 did not fail as expected (rc=$mut_rc)" "$mut_out"
  fi

  # Purpose canary: --session-line returning empty unconditionally fails 2 assertions here (9b, 9c)
  load_canary "purpose"
  fail_n=$(grep -c '^FAIL:' <<<"$mut_out")
  if [ "$mut_rc" -ne 0 ] && [ "$fail_n" -ge 2 ] \
    && grep -qF "FAIL: 9b --session-line one repo" <<<"$mut_out" \
    && grep -qF "FAIL: 9c --session-line two repos" <<<"$mut_out"; then
    ok "purpose canary: empty --session-line fails $fail_n assertions (9b and 9c)"
  else
    canary_bad "purpose canary did not fail >=2 assertions (rc=$mut_rc, fail_n=$fail_n)" "$mut_out"
  fi

  # Canary r1-1 (strict stderr purpose canary): reverting fix 1 fails 4g (1 assertion)
  load_canary "r1-1"
  fail_n=$(grep -c '^FAIL:' <<<"$mut_out")
  if [ "$mut_rc" -ne 0 ] && [ "$fail_n" -eq 1 ] && grep -qF "FAIL: 4g --strict error stderr" <<<"$mut_out"; then
    ok "canary r1-1 (strict stderr purpose canary): reverting fix 1 fails $fail_n assertion (4g)"
  else
    canary_bad "canary r1-1 did not fail 4g as expected (rc=$mut_rc, fail_n=$fail_n)" "$mut_out"
  fi

  # Canary r1-2: reverting invalid-repo exit code to unconditional 2 fails 6d
  load_canary "r1-2"
  if [ "$mut_rc" -ne 0 ] && grep -qF "FAIL: 6d -R not-a-repo" <<<"$mut_out"; then
    ok "canary r1-2: reverting invalid-repo exit code to unconditional 2 fails 6d"
  else
    canary_bad "canary r1-2 did not fail 6d as expected (rc=$mut_rc)" "$mut_out"
  fi

  # Canary r1-3: removing gh subprocess timeout fails 3e
  load_canary "r1-3"
  if [ "$mut_rc" -ne 0 ] && grep -qF "FAIL: 3e gh timeout" <<<"$mut_out"; then
    ok "canary r1-3: removing gh subprocess timeout fails 3e"
  else
    canary_bad "canary r1-3 did not fail 3e as expected (rc=$mut_rc)" "$mut_out"
  fi

  # Canary r1-4: removing --session-line exception guard fails 9d
  load_canary "r1-4"
  if [ "$mut_rc" -ne 0 ] && grep -qF "FAIL: 9d --session-line exception suppression" <<<"$mut_out"; then
    ok "canary r1-4: removing --session-line exception guard fails 9d"
  else
    canary_bad "canary r1-4 did not fail 9d as expected (rc=$mut_rc)" "$mut_out"
  fi

  # Canary r2-1 (purpose canary): reverting OFF_MARKERS check to two strings fails 'no analysis found' row (3f-2) and 4 others (5 total)
  load_canary "r2-1"
  fail_n=$(grep -c '^FAIL:' <<<"$mut_out")
  if [ "$mut_rc" -ne 0 ] && [ "$fail_n" -eq 5 ] \
    && grep -qF "FAIL: 3f-2 off marker 'no analysis found'" <<<"$mut_out" \
    && grep -qF "FAIL: 3f-strict --strict with only off surfaces" <<<"$mut_out"; then
    ok "canary r2-1 (purpose canary): reverting fix 1 fails $fail_n assertions including 'no analysis found' (3f-2, 3f-3, 3f-5, 3f-6, 3f-strict)"
  else
    canary_bad "canary r2-1 did not fail expected off-marker rows (rc=$mut_rc, fail_n=$fail_n)" "$mut_out"
  fi

  # Canary r2-3: reverting UnicodeDecodeError and __main__ Exception catch fails 7b, 7c, 9e, 9f
  load_canary "r2-3"
  if [ "$mut_rc" -ne 0 ] \
    && grep -qF "FAIL: 7b non-UTF-8 --all-repos-from --strict" <<<"$mut_out" \
    && grep -qF "FAIL: 9e internal error default exit" <<<"$mut_out" \
    && grep -qF "FAIL: 9f internal error --strict exit" <<<"$mut_out"; then
    ok "canary r2-3: reverting fix 3 fails 7b, 9e, and 9f"
  else
    canary_bad "canary r2-3 did not fail 7b/9e/9f as expected (rc=$mut_rc)" "$mut_out"
  fi

  # Canary r2-4: reverting invalid-repo skip to immediate return fails 6d, 6e, 6f, 6g, 6h
  load_canary "r2-4"
  if [ "$mut_rc" -ne 0 ] \
    && grep -qF "FAIL: 6f skip invalid repo" <<<"$mut_out" \
    && grep -qF "FAIL: 6g skip invalid repo --strict clean" <<<"$mut_out" \
    && grep -qF "FAIL: 6h skip invalid repo --strict alert wins" <<<"$mut_out"; then
    ok "canary r2-4: reverting fix 4 fails 6f, 6g, and 6h"
  else
    canary_bad "canary r2-4 did not fail 6f/6g/6h as expected (rc=$mut_rc)" "$mut_out"
  fi

  # Canary r2-5: omitting numbers/rules/packages from json_surface fails 1b and 1c
  load_canary "r2-5"
  if [ "$mut_rc" -ne 0 ] \
    && grep -qF "FAIL: 1b --json shape" <<<"$mut_out" \
    && grep -qF "FAIL: 1c --json dedup identifiers" <<<"$mut_out"; then
    ok "canary r2-5: reverting fix 5 fails 1b and 1c"
  else
    canary_bad "canary r2-5 did not fail 1b/1c as expected (rc=$mut_rc)" "$mut_out"
  fi

  # Canary r2-6: re-inserting chmod +x "$SS" in a temp copy of this probe fails 11
  load_canary "r2-6"
  if [ "$mut_rc" -ne 0 ] && grep -qF "FAIL: 11 non-executable SECURITY_SWEEP_BIN check (rc=0, x=1)" <<<"$mut_out"; then
    ok "canary r2-6: re-inserting chmod +x on target bin fails 11"
  else
    canary_bad "canary r2-6 did not fail 11 as expected (rc=$mut_rc)" "$mut_out"
  fi

  # Canary r3-1: removing quiet parser suppression fails 9g on stderr
  load_canary "r3-1"
  if [ "$mut_rc" -ne 0 ] && grep -qF "FAIL: 9g --session-line -R -foo/bar" <<<"$mut_out"; then
    ok "canary r3-1: removing quiet parser suppression fails 9g"
  else
    canary_bad "canary r3-1 did not fail 9g as expected (rc=$mut_rc)" "$mut_out"
  fi

  # Canary r3-2: deleting signal.setitimer call fails 9i
  load_canary "r3-2"
  if [ "$mut_rc" -ne 0 ] && grep -qF "FAIL: 9i --session-line --cap 1" <<<"$mut_out"; then
    ok "canary r3-2: deleting setitimer call fails 9i"
  else
    canary_bad "canary r3-2 did not fail 9i as expected (rc=$mut_rc)" "$mut_out"
  fi

  # Canary r3-3: making warm-cache flock acquisition a no-op fails 9j
  load_canary "r3-3"
  if [ "$mut_rc" -ne 0 ] && grep -qF "FAIL: 9j --warm-cache held lock" <<<"$mut_out"; then
    ok "canary r3-3: making warm-cache flock acquisition a no-op fails 9j"
  else
    canary_bad "canary r3-3 did not fail 9j as expected (rc=$mut_rc)" "$mut_out"
  fi

  # Canary r3-6: reverting is_valid_cached_surface to the base check fails 5d, 5e, 5f, and 5g
  load_canary "r3-6"
  if [ "$mut_rc" -ne 0 ] \
    && grep -qF "FAIL: 5d corrupt cache count: \"x\"" <<<"$mut_out" \
    && grep -qF "FAIL: 5e corrupt cache by_severity: []" <<<"$mut_out" \
    && grep -qF "FAIL: 5f corrupt cache alerts: [1]" <<<"$mut_out" \
    && grep -qF "FAIL: 5g corrupt cache rules_by_severity: {\"critical\": [1]}" <<<"$mut_out"; then
    ok "canary r3-6: reverting is_valid_cached_surface to base version fails 5d, 5e, 5f, and 5g"
  else
    canary_bad "canary r3-6 did not fail 5d, 5e, 5f, and 5g as expected (rc=$mut_rc)" "$mut_out"
  fi

  # Canary r3-7: dropping sorted( in warm-cache lock digest fails 9m
  load_canary "r3-7"
  if [ "$mut_rc" -ne 0 ] && grep -qF "FAIL: 9m --warm-cache sorted repo-set lock" <<<"$mut_out"; then
    ok "canary r3-7: dropping sorted( in warm-cache lock digest fails 9m"
  else
    canary_bad "canary r3-7 did not fail 9m as expected (rc=$mut_rc)" "$mut_out"
  fi

  # Canary r4-1: firing _cap_exit immediately during write_cache fails 9o
  load_canary "r4-1"
  if [ "$mut_rc" -ne 0 ] && grep -qF "FAIL: 9o --cap mid-write" <<<"$mut_out"; then
    ok "canary r4-1: ignoring _cap_writes in _cap_fire fails 9o"
  else
    canary_bad "canary r4-1 did not fail 9o as expected (rc=$mut_rc)" "$mut_out"
  fi

  # Canary r4-2 (purpose canary): replacing os.killpg with pass fails 9n
  load_canary "r4-2"
  fail_n=$(grep -c '^FAIL:' <<<"$mut_out")
  if [ "$mut_rc" -ne 0 ] && grep -qF "FAIL: 9n --cap 1 expiry stops the held gh children" <<<"$mut_out"; then
    ok "canary r4-2 (purpose canary): replacing os.killpg with pass fails $fail_n assertion (9n)"
  else
    canary_bad "canary r4-2 did not fail 9n as expected (rc=$mut_rc, fail_n=$fail_n)" "$mut_out"
  fi

  # Canary r4-3: ignoring skip in write_cache fails 9p
  load_canary "r4-3"
  if [ "$mut_rc" -ne 0 ] && grep -qF "FAIL: 9p _cap_pending before write_cache" <<<"$mut_out"; then
    ok "canary r4-3: ignoring skip in write_cache fails 9p"
  else
    canary_bad "canary r4-3 did not fail 9p as expected (rc=$mut_rc)" "$mut_out"
  fi

  # Canary r4-4: calling signal.signal in _cap_exit fails 9q
  load_canary "r4-4"
  if [ "$mut_rc" -ne 0 ] && grep -qF "FAIL: 9q --cap worker-thread mid-write" <<<"$mut_out"; then
    ok "canary r4-4: calling signal.signal in _cap_exit fails 9q"
  else
    canary_bad "canary r4-4 did not fail 9q as expected (rc=$mut_rc)" "$mut_out"
  fi

  # Canary r5-1 (purpose canary): reverting SIGTERM handler to os._exit(124) fails 9r
  load_canary "r5-1"
  fail_n=$(grep -c '^FAIL:' <<<"$mut_out")
  if [ "$mut_rc" -ne 0 ] && grep -qF "FAIL: 9r external SIGTERM mid-write" <<<"$mut_out" \
    && grep -qF "FAIL: 9s external SIGTERM worker-thread mid-write" <<<"$mut_out"; then
    ok "canary r5-1 (purpose canary): reverting SIGTERM handler to os._exit(124) fails $fail_n assertions (9r and 9s)"
  else
    canary_bad "canary r5-1 did not fail 9r as expected (rc=$mut_rc, fail_n=$fail_n)" "$mut_out"
  fi

  # Canary r5-2: disabling the _cap_exits recursion bound in _cap_exit fails 9r with RecursionError
  load_canary "r5-2"
  if [ "$mut_rc" -ne 0 ] && grep -qF "FAIL: 9r" <<<"$mut_out"; then
    ok "canary r5-2: disabling the _cap_exits recursion bound fails 9r (RecursionError)"
  else
    canary_bad "canary r5-2 did not fail 9r as expected (rc=$mut_rc)" "$mut_out"
  fi

  # Canary r5-3: removing SIGTTOU ignore fails 9t
  if ! command -v script >/dev/null 2>&1; then
    ok "canary r5-3 skipped: script(1) not available"
  else
    load_canary "r5-3"
    if [ "$mut_rc" -ne 0 ] && grep -qF "FAIL: 9t" <<<"$mut_out"; then
      ok "canary r5-3: removing SIGTTOU ignore fails 9t"
    else
      canary_bad "canary r5-3 did not fail 9t as expected (rc=$mut_rc)" "$mut_out"
    fi
  fi

  # Canary r6-1: exiting on the second _cap_exit entry without killpg fails 9u
  load_canary "r6-1"
  if [ "$mut_rc" -ne 0 ] && grep -qF "FAIL: 9u" <<<"$mut_out"; then
    ok "canary r6-1: exiting on the second _cap_exit entry without killpg fails 9u"
  else
    canary_bad "canary r6-1 did not fail 9u as expected (rc=$mut_rc)" "$mut_out"
  fi

  # Canary r6-2: never escalating a repeated SIGTERM fails 9v
  load_canary "r6-2"
  if [ "$mut_rc" -ne 0 ] && grep -qF "FAIL: 9v" <<<"$mut_out"; then
    ok "canary r6-2: never escalating a repeated SIGTERM fails 9v"
  else
    canary_bad "canary r6-2 did not fail 9v as expected (rc=$mut_rc)" "$mut_out"
  fi

  # Canary r7-1: never escalating a second cap alarm fails 9w
  load_canary "r7-1"
  if [ "$mut_rc" -ne 0 ] && grep -qF "FAIL: 9w" <<<"$mut_out"; then
    ok "canary r7-1: never escalating a second cap alarm fails 9w"
  else
    canary_bad "canary r7-1 did not fail 9w as expected (rc=$mut_rc)" "$mut_out"
  fi

  # Canary r8-1: a blocking main-thread wait fails 9w
  load_canary "r8-1"
  if [ "$mut_rc" -ne 0 ] && grep -qF "FAIL: 9w" <<<"$mut_out"; then
    ok "canary r8-1: a blocking main-thread wait fails 9w"
  else
    canary_bad "canary r8-1 did not fail 9w as expected (rc=$mut_rc)" "$mut_out"
  fi

  # Canary r7-2: a grace re-arm that requires no prior SIGTERM fails 9x only
  load_canary "r7-2"
  fail_n=$(grep -c '^FAIL:' <<<"$mut_out")
  if [ "$mut_rc" -ne 0 ] && [ "$fail_n" -eq 1 ] && grep -qF "FAIL: 9x" <<<"$mut_out"; then
    ok "canary r7-2: a grace re-arm that requires no prior SIGTERM fails $fail_n assertion (9x)"
  else
    canary_bad "canary r7-2 did not fail 9x only (rc=$mut_rc, fail_n=$fail_n)" "$mut_out"
  fi
fi

exit "$fail"
