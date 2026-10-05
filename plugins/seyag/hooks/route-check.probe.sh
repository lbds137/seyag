#!/bin/bash
# Fixture check for route-check.sh. Hermetic: temp project dirs, stub commands as
# temp scripts, every case runs under `env -i` so the caller's SYG_ROUTE_* (or any
# other variable) cannot leak in.
#
# Usage: hooks/route-check.probe.sh   (from anywhere)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$SCRIPT_DIR/route-check.sh"
BASH_BIN=$(command -v bash)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/stubs" "$TMP/home" "$TMP/projA" "$TMP/projB" "$TMP/markers"

stub() { # $1 name, $2.. script body lines
  local n=$1; shift
  { echo '#!/bin/bash'; printf '%s\n' "$@"; } >"$TMP/stubs/$n"
  chmod +x "$TMP/stubs/$n"
}
stub ok.sh "printf 'ok\\tfine\\n'"
stub touch.sh "touch '$TMP/ran'" "printf 'ok\\n'"
stub exit3.sh "exit 3"
stub empty.sh "exit 0"
stub okay.sh "echo okay"
stub sleep.sh "exec sleep 20"
stub cwd.sh "[ \"\$(pwd -P)\" = '$(cd "$TMP/projA" && pwd -P)' ] && echo ok"

fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; [ -n "${2:-}" ] && printf '      got: %s\n' "$2"; fail=1; }

# run [NAME=value ...] → OUT, RC. SRC picks the SessionStart source; the event cwd
# is projA unless CLAUDE_PROJECT_DIR is passed.
run() {
  OUT=$(printf '{"session_id":"probe","source":"%s","cwd":"%s"}' "${SRC:-startup}" "$TMP/projA" \
    | env -i PATH="$PATH" HOME="$TMP/home" "$@" "$BASH_BIN" "$HOOK" 2>/dev/null)
  RC=$?
}
silent() { [ "$RC" = 0 ] && [ -z "$OUT" ]; }
banner() { # $1 reason substring
  [ "$RC" = 0 ] && jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' <<<"$OUT" >/dev/null 2>&1 \
    && jq -r '.hookSpecificOutput.additionalContext' <<<"$OUT" | grep -qF -- "$1"
}
expect_silent() { run "${@:2}"; silent && ok "$1" || bad "$1: expected silence" "$OUT"; }
expect_banner() { # $1 label, $2 reason substring, $3.. env
  local label=$1 want=$2; shift 2
  run "$@"; banner "$want" && ok "$label" || bad "$label: expected a banner naming '$want'" "$OUT"
}

PASSING=(SYG_ROUTE_CHECK_CMD="$TMP/stubs/ok.sh" SYG_ROUTE_CHECK_OK=ok)
FAILING=(SYG_ROUTE_CHECK_CMD="$TMP/stubs/exit3.sh" SYG_ROUTE_CHECK_OK=ok)

# --- not required -----------------------------------------------------------
rm -f "$TMP/ran"
run SYG_ROUTE_CHECK_CMD="$TMP/stubs/touch.sh" SYG_ROUTE_CHECK_OK=ok
silent && [ ! -e "$TMP/ran" ] && ok "not required: silent and the command is never run" || bad "not required: expected silence and no command run" "$OUT"

# --- required by SYG_ROUTE_REQUIRED=1 ---------------------------------------
expect_silent "REQUIRED=1 + passing stub (ok<TAB>reason): silent" SYG_ROUTE_REQUIRED=1 "${PASSING[@]}"
expect_banner "REQUIRED=1 + failing stub: banner" "exited 3" SYG_ROUTE_REQUIRED=1 "${FAILING[@]}"
expect_silent "command runs with the project dir as cwd" SYG_ROUTE_REQUIRED=1 SYG_ROUTE_CHECK_CMD="$TMP/stubs/cwd.sh" SYG_ROUTE_CHECK_OK=ok
# SYG_ROUTE_REQUIRED values: 1|true|yes|on (any case) require; unset/empty/0|false|no|off do not;
# anything else is a misconfiguration.
expect_banner "REQUIRED=true: required" "exited 3" SYG_ROUTE_REQUIRED=true "${FAILING[@]}"
expect_banner "REQUIRED=On (mixed case): required" "exited 3" SYG_ROUTE_REQUIRED=On "${FAILING[@]}"
expect_silent "REQUIRED=off: not required" SYG_ROUTE_REQUIRED=off "${FAILING[@]}"
expect_silent "REQUIRED=0: not required" SYG_ROUTE_REQUIRED=0 "${FAILING[@]}"
expect_silent "REQUIRED empty: not required" SYG_ROUTE_REQUIRED= "${FAILING[@]}"
expect_banner "REQUIRED=2: misconfig banner" "SYG_ROUTE_REQUIRED=2 is not a recognized value" SYG_ROUTE_REQUIRED=2 "${FAILING[@]}"

# --- marker file ------------------------------------------------------------
printf -- '---\nname: x\nsettings:\n  route: "approved"\n---\nbody\n' >"$TMP/markers/nested.md"
printf -- '---\nroute: ""\n---\n' >"$TMP/markers/emptyq.md"
printf -- '---\nroute:   \n---\n' >"$TMP/markers/emptyb.md"
printf -- "---\nroute: ''\n---\n" >"$TMP/markers/emptys.md"
printf -- '---\nother: 1\n---\nbody\n' >"$TMP/markers/absent.md"
printf -- '---\nname: x\n---\nroute: approved\n' >"$TMP/markers/below.md"
printf -- 'route: approved\n---\n' >"$TMP/markers/nofm.md"
printf -- '---\nroute: bare\n' >"$TMP/markers/unclosed.md"

M() { echo "SYG_ROUTE_MARKER_FILE=$TMP/markers/$1"; }
expect_banner "marker file with a nested non-empty field: required" "exited 3" "$(M nested.md)" SYG_ROUTE_MARKER_FIELD=route "${FAILING[@]}"
expect_banner "marker unclosed frontmatter still reads its fields: required" "exited 3" "$(M unclosed.md)" SYG_ROUTE_MARKER_FIELD=route "${FAILING[@]}"
expect_silent "marker field \"\": not required" "$(M emptyq.md)" SYG_ROUTE_MARKER_FIELD=route "${FAILING[@]}"
expect_silent "marker field '': not required" "$(M emptys.md)" SYG_ROUTE_MARKER_FIELD=route "${FAILING[@]}"
expect_silent "marker field blank: not required" "$(M emptyb.md)" SYG_ROUTE_MARKER_FIELD=route "${FAILING[@]}"
expect_silent "marker field absent: not required" "$(M absent.md)" SYG_ROUTE_MARKER_FIELD=route "${FAILING[@]}"
expect_silent "marker file absent: not required" "$(M missing.md)" SYG_ROUTE_MARKER_FIELD=route "${FAILING[@]}"
expect_silent "field only BELOW the closing ---: not required" "$(M below.md)" SYG_ROUTE_MARKER_FIELD=route "${FAILING[@]}"
expect_silent "no leading --- line: no frontmatter, not required" "$(M nofm.md)" SYG_ROUTE_MARKER_FIELD=route "${FAILING[@]}"
expect_silent "marker found + passing stub: silent" "$(M nested.md)" SYG_ROUTE_MARKER_FIELD=route "${PASSING[@]}"

# {project} substitution: two project dirs, only projB has a marker file.
printf -- '---\nroute: yes\n---\n' >"$TMP/markers/projB.md"
TPL="SYG_ROUTE_MARKER_FILE=$TMP/markers/{project}.md"
expect_banner "{project} = basename of CLAUDE_PROJECT_DIR (projB has a marker): required" "exited 3" "$TPL" SYG_ROUTE_MARKER_FIELD=route CLAUDE_PROJECT_DIR="$TMP/projB" "${FAILING[@]}"
expect_silent "{project} = projA (no marker file): not required" "$TPL" SYG_ROUTE_MARKER_FIELD=route CLAUDE_PROJECT_DIR="$TMP/projA" "${FAILING[@]}"
expect_silent "{project} falls back to the event cwd (projA): not required" "$TPL" SYG_ROUTE_MARKER_FIELD=route "${FAILING[@]}"
expect_banner "{project} tolerates a trailing slash" "exited 3" "$TPL" SYG_ROUTE_MARKER_FIELD=route CLAUDE_PROJECT_DIR="$TMP/projB/" "${FAILING[@]}"
mkdir -p "$TMP/home/markers"; printf -- '---\nroute: tilde\n---\n' >"$TMP/home/markers/t.md"
expect_banner "leading ~/ expands to HOME" "exited 3" "SYG_ROUTE_MARKER_FILE=~/markers/t.md" SYG_ROUTE_MARKER_FIELD=route "${FAILING[@]}"

# --- marker file exists but cannot be read: fail closed ---------------------
mkdir -p "$TMP/markers/adir.md"
expect_banner "marker path is a directory: fail closed" "exists but cannot be read" "$(M adir.md)" SYG_ROUTE_MARKER_FIELD=route "${PASSING[@]}"
if [ "$(id -u)" != 0 ]; then
  printf -- '---\nroute: x\n---\n' >"$TMP/markers/locked.md"; chmod 000 "$TMP/markers/locked.md"
  expect_banner "marker file chmod 000: fail closed" "exists but cannot be read" "$(M locked.md)" SYG_ROUTE_MARKER_FIELD=route "${PASSING[@]}"
else
  echo "skip: running as root, chmod 000 does not block reads"
fi
ln -s "$TMP/markers/no-such-target.md" "$TMP/markers/dangling.md"
expect_silent "dangling symlink marker counts as absent" "$(M dangling.md)" SYG_ROUTE_MARKER_FIELD=route "${FAILING[@]}"

# --- {project} with an ampersand in the dir name (bash 5.2 patsub) ----------
mkdir -p "$TMP/a&b"; printf -- '---\nroute: yes\n---\n' >"$TMP/markers/a&b.md"
expect_banner "{project} with & in the dir name" "exited 3" "$TPL" SYG_ROUTE_MARKER_FIELD=route CLAUDE_PROJECT_DIR="$TMP/a&b" "${FAILING[@]}"

# --- HOME unset with a ~/ template ------------------------------------------
OUT=$(printf '{}' | env -i PATH="$PATH" SYG_ROUTE_MARKER_FILE="~/markers/t.md" SYG_ROUTE_MARKER_FIELD=route "${FAILING[@]}" "$BASH_BIN" "$HOOK" 2>/dev/null)
RC=$?
banner "HOME is not set" && ok "tilde-slash template with HOME unset: misconfig banner" || bad "HOME unset: expected a misconfig banner" "$OUT"
OUT=$(printf '{}' | env -i PATH="$PATH" HOME= SYG_ROUTE_MARKER_FILE="~/markers/t.md" SYG_ROUTE_MARKER_FIELD=route "${FAILING[@]}" "$BASH_BIN" "$HOOK" 2>/dev/null)
RC=$?
banner "HOME is not set" && ok "tilde-slash template with HOME empty: misconfig banner" || bad "HOME empty: expected a misconfig banner" "$OUT"

# --- project dir missing: fail closed, command not run ----------------------
rm -f "$TMP/ran"
expect_banner "project dir does not exist" "project dir $TMP/gone does not exist" SYG_ROUTE_REQUIRED=1 CLAUDE_PROJECT_DIR="$TMP/gone" SYG_ROUTE_CHECK_CMD="$TMP/stubs/touch.sh" SYG_ROUTE_CHECK_OK=ok
[ ! -e "$TMP/ran" ] && ok "missing project dir: the command was not run" || bad "command ran despite a missing project dir"


# --- misconfiguration fails closed ------------------------------------------
expect_banner "only MARKER_FILE set: banner naming the misconfig" "misconfigured" "$(M nested.md)" "${PASSING[@]}"
expect_banner "only MARKER_FIELD set: banner naming the misconfig" "misconfigured" SYG_ROUTE_MARKER_FIELD=route "${PASSING[@]}"
expect_banner "invalid FIELD (regex chars): banner naming the misconfig" "misconfigured" "$(M nested.md)" "SYG_ROUTE_MARKER_FIELD=ro.te" "${PASSING[@]}"
expect_banner "invalid FIELD (space): banner naming the misconfig" "misconfigured" "$(M nested.md)" "SYG_ROUTE_MARKER_FIELD=a b" "${PASSING[@]}"

# --- fail cases (each with its own reason) ----------------------------------
expect_banner "CMD unset" "SYG_ROUTE_CHECK_CMD is not set" SYG_ROUTE_REQUIRED=1 SYG_ROUTE_CHECK_OK=ok
expect_banner "OK unset" "SYG_ROUTE_CHECK_OK is not set" SYG_ROUTE_REQUIRED=1 SYG_ROUTE_CHECK_CMD="$TMP/stubs/ok.sh"
expect_banner "command not found" "not found (exit 127)" SYG_ROUTE_REQUIRED=1 SYG_ROUTE_CHECK_CMD="$TMP/stubs/no-such-stub" SYG_ROUTE_CHECK_OK=ok
expect_banner "non-zero exit" "exited 3" SYG_ROUTE_REQUIRED=1 "${FAILING[@]}"
expect_banner "empty output" "printed nothing" SYG_ROUTE_REQUIRED=1 SYG_ROUTE_CHECK_CMD="$TMP/stubs/empty.sh" SYG_ROUTE_CHECK_OK=ok
expect_banner "word mismatch (okay vs ok) names the word seen" "first word was 'okay'" SYG_ROUTE_REQUIRED=1 SYG_ROUTE_CHECK_CMD="$TMP/stubs/okay.sh" SYG_ROUTE_CHECK_OK=ok
if command -v timeout >/dev/null 2>&1; then
  start=$SECONDS
  expect_banner "timeout (stub sleeps 20, timeout 1)" "timed out after 1s" SYG_ROUTE_REQUIRED=1 SYG_ROUTE_CHECK_CMD="$TMP/stubs/sleep.sh" SYG_ROUTE_CHECK_OK=ok SYG_ROUTE_CHECK_TIMEOUT=1
  [ $((SECONDS - start)) -lt 10 ] && ok "timeout returned well before the stub's 20s" || bad "timeout took $((SECONDS - start))s"
  stub termtrap.sh 'trap "" TERM' "sleep 20" "echo ok"
  start=$SECONDS
  expect_banner "TERM-ignoring command is killed after the grace (timeout 1)" "timed out after 1s" SYG_ROUTE_REQUIRED=1 SYG_ROUTE_CHECK_CMD="$TMP/stubs/termtrap.sh" SYG_ROUTE_CHECK_OK=ok SYG_ROUTE_CHECK_TIMEOUT=1
  [ $((SECONDS - start)) -lt 6 ] && ok "TERM-ignoring stub returned in under 6s" || bad "TERM-ignoring stub stalled the hook for $((SECONDS - start))s"
else
  echo "skip: no timeout binary; timeout case not run"
fi

# --- output shape -----------------------------------------------------------
run SYG_ROUTE_REQUIRED=1 "${FAILING[@]}"
jq -e '(.systemMessage | type == "string" and startswith("Route check failed: ")) and (.hookSpecificOutput.additionalContext | type == "string")' <<<"$OUT" >/dev/null 2>&1 \
  && ok "fail output is valid JSON with systemMessage and additionalContext" || bad "fail output shape" "$OUT"
CTX=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$OUT")
[ "$(head -1 <<<"$CTX")" = "ROUTE CHECK FAILED — do not start work in this session." ] && ok "banner first line" || bad "banner first line" "$CTX"
grep -q 'formal channel' <<<"$CTX" && grep -q 'session restart' <<<"$CTX" && ok "banner carries the escalation and restart lines" || bad "banner body" "$CTX"
[ "${#OUT}" -lt 1024 ] && ok "fail output is ${#OUT} bytes (< 1 KB)" || bad "fail output too large: ${#OUT} bytes"
run SYG_ROUTE_REQUIRED=1 SYG_ROUTE_CHECK_CMD="$TMP/stubs/okay.sh" "SYG_ROUTE_CHECK_OK=$(printf 'w%.0s' {1..200})"
[ "${#OUT}" -lt 1024 ] && ok "long word is truncated: output ${#OUT} bytes (< 1 KB)" || bad "long word blew the size ceiling: ${#OUT} bytes"

# --- every source -----------------------------------------------------------
for s in startup clear resume compact; do
  SRC=$s run SYG_ROUTE_REQUIRED=1 "${FAILING[@]}"
  banner "exited 3" && ok "source $s: banner" || bad "source $s: expected a banner" "$OUT"
done
SRC=compact run SYG_ROUTE_REQUIRED=1 "${PASSING[@]}"
silent && ok "source compact + passing route: silent" || bad "compact pass: expected silence" "$OUT"

# --- no jq: plain banner, never a silent pass -------------------------------
J="$TMP/nojq-bin"; mkdir -p "$J"
for t in bash timeout; do
  p=$(command -v "$t") && ln -s "$p" "$J/$t"
done
OUT=$(printf '{"session_id":"probe","source":"startup"}' \
  | env -i PATH="$J" HOME="$TMP/home" SYG_ROUTE_REQUIRED=1 SYG_ROUTE_CHECK_CMD="$TMP/stubs/exit3.sh" SYG_ROUTE_CHECK_OK=ok \
    "$BASH_BIN" "$HOOK" 2>/dev/null)
RC=$?
[ "$RC" = 0 ] && [ "$(head -1 <<<"$OUT")" = "ROUTE CHECK FAILED — do not start work in this session." ] && ! grep -q '^{' <<<"$OUT" \
  && ok "no jq + failing route: plain banner on stdout" || bad "no jq: expected a plain banner" "$OUT"
OUT=$(printf '{}' | env -i PATH="$J" HOME="$TMP/home" SYG_ROUTE_REQUIRED=1 SYG_ROUTE_CHECK_CMD="$TMP/stubs/ok.sh" SYG_ROUTE_CHECK_OK=ok "$BASH_BIN" "$HOOK" 2>/dev/null)
RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok "no jq + passing route: silent" || bad "no jq pass: expected silence" "$OUT"
OUT=$(printf '{}' | env -i PATH="$J" HOME="$TMP/home" "$BASH_BIN" "$HOOK" 2>/dev/null)
RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok "no jq + not required: silent" || bad "no jq not-required: expected silence" "$OUT"

exit $fail
