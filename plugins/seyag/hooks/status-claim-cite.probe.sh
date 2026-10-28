#!/usr/bin/env bash
# Probe for status-claim-cite.sh.
# Exercises SendMessage, PushNotification, and AskUserQuestion extraction,
# marker-no-cite advisory firing, citation suppression (backtick, hex sha,
# path:line), no-marker silence, SYG_STATUS_CLAIM_MARKERS extension without
# dropping defaults, and malformed-JSON fail-open.

set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/status-claim-cite.sh"
EXPECTED_CTX='STATUS-CLAIM CITE: this message asserts completion or causality without a citation. Cite the evidence (a backticked command, a sha, or path:line) or hedge the claim.'

pass=0
fail=0

run_hook() {
  local payload="$1" extra_markers="${2:-}"
  if [ -n "$extra_markers" ]; then
    printf '%s' "$payload" | env -i PATH="$PATH" HOME="$HOME" SYG_STATUS_CLAIM_MARKERS="$extra_markers" bash "$HOOK" 2>&1
  else
    printf '%s' "$payload" | env -i PATH="$PATH" HOME="$HOME" bash "$HOOK" 2>&1
  fi
}

expect_silent() {
  local label="$1" payload="$2" extra="${3:-}" out rc
  out=$(run_hook "$payload" "$extra")
  rc=$?
  if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass=$((pass + 1))
  else
    echo "FAIL [$label]: expected exit 0 + silent, got rc=$rc out=$out" >&2
    fail=$((fail + 1))
  fi
}

expect_warn() {
  local label="$1" payload="$2" extra="${3:-}" out rc ctx dec event
  out=$(run_hook "$payload" "$extra")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL [$label]: expected exit 0, got rc=$rc" >&2
    fail=$((fail + 1))
    return
  fi
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
  dec=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
  event=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName // empty' 2>/dev/null)
  if [ "$ctx" = "$EXPECTED_CTX" ] && [ -z "$dec" ] && [ "$event" = "PreToolUse" ]; then
    pass=$((pass + 1))
  else
    echo "FAIL [$label]: expected exact additionalContext ($EXPECTED_CTX) and no permissionDecision, got: $out" >&2
    fail=$((fail + 1))
  fi
}

# --- Tool shapes: marker without citation fires ---
expect_warn "SendMessage message marker no cite" \
  '{"tool_name":"SendMessage","tool_input":{"message":"The patch is fixed and ready.","summary":"status update"}}'

expect_warn "SendMessage summary marker no cite" \
  '{"tool_name":"SendMessage","tool_input":{"message":"See update.","summary":"All checks green"}}'

expect_warn "PushNotification message marker no cite" \
  '{"tool_name":"PushNotification","tool_input":{"message":"Build deployed and verified."}}'

expect_warn "AskUserQuestion question marker no cite" \
  '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"We found it in the parser; how should we proceed?","options":[{"label":"Patch now","description":"Apply fix"}]}]}}'

expect_silent "AskUserQuestion option label marker ignored" \
  '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Next step?","options":[{"label":"Safe to merge","description":"Proceed with merge"}]}]}}'

expect_silent "AskUserQuestion option description marker ignored" \
  '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Next step?","options":[{"label":"Continue","description":"Root cause identified in handler"}]}]}}'

expect_warn "Multi-word marker all tests pass" \
  '{"tool_name":"PushNotification","tool_input":{"message":"All tests pass on the branch."}}'

expect_warn "Case-insensitive marker FIXED" \
  '{"tool_name":"PushNotification","tool_input":{"message":"Issue FIXED in latest run."}}'

expect_warn "Large payload early marker fires" \
  "$(jq -nc --arg m "$(printf 'fixed x%.0s' {1..12000})" '{tool_name:"PushNotification",tool_input:{message:$m}}')"

# --- Marker + citation stays silent (backtick, hex sha, path:line) ---
expect_silent "SendMessage marker + backtick cite" \
  '{"tool_name":"SendMessage","tool_input":{"message":"All tests pass after running `pytest -q`.","summary":"status"}}'

expect_silent "SendMessage marker in message + cite in summary" \
  '{"tool_name":"SendMessage","tool_input":{"message":"The bug is fixed.","summary":"landed in a1b2c3d"}}'

expect_silent "PushNotification marker + 7-char sha cite" \
  '{"tool_name":"PushNotification","tool_input":{"message":"shipped abc1234"}}'

expect_silent "PushNotification marker + 10-char sha cite" \
  '{"tool_name":"PushNotification","tool_input":{"message":"shipped deadbeef01"}}'

expect_silent "PushNotification marker + 40-char sha cite" \
  '{"tool_name":"PushNotification","tool_input":{"message":"Merged 0123456789abcdef0123456789abcdef01234567."}}'

expect_silent "AskUserQuestion marker + file:line cite" \
  '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Root cause is in src/app/handler.py:42; should we refactor?","options":[{"label":"Yes","description":"Clean up"}]}]}}'

expect_silent "PushNotification marker + handler.py:42 cite" \
  '{"tool_name":"PushNotification","tool_input":{"message":"Fixed in handler.py:42"}}'

expect_warn "Clock time 10:30 is not a path:line citation" \
  '{"tool_name":"PushNotification","tool_input":{"message":"deployed at 10:30"}}'

expect_warn "Pure-letter hex word acceded is not a sha citation" \
  '{"tool_name":"PushNotification","tool_input":{"message":"shipped acceded"}}'

expect_warn "Plain digit run 12345678 is not a sha citation" \
  '{"tool_name":"PushNotification","tool_input":{"message":"run 12345678 is green"}}'

# --- No marker stays silent ---
expect_silent "SendMessage no marker" \
  '{"tool_name":"SendMessage","tool_input":{"message":"Still investigating the failure mode.","summary":"in progress"}}'

expect_silent "PushNotification no marker" \
  '{"tool_name":"PushNotification","tool_input":{"message":"Starting the test suite now."}}'

expect_silent "AskUserQuestion no marker" \
  '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which config file should we read first?","options":[{"label":"config.yaml","description":"Main config"}]}]}}'

expect_silent "Unrelated tool ignored" \
  '{"tool_name":"Bash","tool_input":{"command":"echo done"}}'

# --- SYG_STATUS_CLAIM_MARKERS extends default set without removing defaults ---
expect_warn "Custom marker fires when SYG_STATUS_CLAIM_MARKERS set" \
  '{"tool_name":"PushNotification","tool_input":{"message":"Canary stabilized across regions."}}' \
  'stabilized|cutover complete'

expect_warn "Second custom marker alternative fires when SYG_STATUS_CLAIM_MARKERS set" \
  '{"tool_name":"PushNotification","tool_input":{"message":"Ready for cutover complete window."}}' \
  'stabilized|cutover complete'

expect_warn "Default marker still fires when SYG_STATUS_CLAIM_MARKERS set" \
  '{"tool_name":"PushNotification","tool_input":{"message":"Everything works now."}}' \
  'stabilized|cutover complete'

expect_silent "Custom marker with citation stays silent" \
  '{"tool_name":"PushNotification","tool_input":{"message":"Canary stabilized atops/rollout.sh:88."}}' \
  'stabilized|cutover complete'

expect_warn "Invalid SYG_STATUS_CLAIM_MARKERS falls back to default markers" \
  '{"tool_name":"PushNotification","tool_input":{"message":"Everything works now."}}' \
  'foo|['

expect_warn "Invalid marker extension with large payload still fires" \
  "$(jq -nc --arg m "$(printf 'fixed x%.0s' {1..12000})" '{tool_name:"PushNotification",tool_input:{message:$m}}')" \
  'foo|['

expect_warn "Empty-only SYG_STATUS_CLAIM_MARKERS='|' fires on default marker" \
  '{"tool_name":"PushNotification","tool_input":{"message":"Everything works now."}}' \
  '|'

expect_silent "Empty-only SYG_STATUS_CLAIM_MARKERS='|' stays silent on non-marker" \
  '{"tool_name":"PushNotification","tool_input":{"message":"Starting the test suite now."}}' \
  '|'

expect_warn "Trailing-pipe SYG_STATUS_CLAIM_MARKERS='ready|' fires on custom ready" \
  '{"tool_name":"PushNotification","tool_input":{"message":"Ready to merge."}}' \
  'ready|'

expect_silent "Trailing-pipe SYG_STATUS_CLAIM_MARKERS='ready|' stays silent on non-marker" \
  '{"tool_name":"PushNotification","tool_input":{"message":"Starting the test suite now."}}' \
  'ready|'

# --- Fail-open on malformed or empty input ---
expect_silent "Malformed JSON silent" 'not json {'
expect_silent "Empty input silent" ''
expect_silent "Null tool_input silent" '{"tool_name":"PushNotification","tool_input":null}'

[ "$fail" -eq 0 ] || exit 1
echo "PASS: status-claim-cite ($pass cases)"
