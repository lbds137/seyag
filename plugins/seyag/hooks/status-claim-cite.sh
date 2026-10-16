#!/usr/bin/env bash
# status-claim-cite.sh — PreToolUse advisory hook for SendMessage,
# PushNotification, and AskUserQuestion.
#
# When an outbound status or question message asserts completion or causality
# (done, fixed, passing, root cause, safe to merge, etc.) without citing any
# concrete artifact (a backticked command/token, a 7..40-char hex sha, or a
# path:line reference), injects additionalContext nudging the caller to cite
# evidence or hedge the claim.
#
# Fire status: PreToolUse is runtime-confirmed for PushNotification and
# absent-toolset for AskUserQuestion in headless runs; SendMessage and
# AskUserQuestion fire behavior in interactive sessions is unverified — the
# matcher ships anyway, inert if the event does not fire:
# verified by a driver-side live probe of the harness events.
#
# Extending markers: SYG_STATUS_CLAIM_MARKERS appends |-separated alternatives
# to the default marker alternation without removing defaults.
#
# Advisory only: never emits permissionDecision, never blocks, exits 0 on all
# paths, fails open on missing jq or malformed input.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null) || exit 0
[ -n "$INPUT" ] || exit 0

TEXT=$(printf '%s' "$INPUT" | jq -r '
  if .tool_name == "SendMessage" then
    [(.tool_input.message // empty), (.tool_input.summary // empty)]
    | map(select(type == "string" and length > 0))
    | join(" ") | gsub("[[:space:]]+"; " ")
  elif .tool_name == "PushNotification" then
    (.tool_input.message // empty) | select(type == "string") | gsub("[[:space:]]+"; " ")
  elif .tool_name == "AskUserQuestion" then
    [(.tool_input.questions[]? | (.question // empty))]
    | map(select(type == "string" and length > 0))
    | join(" ") | gsub("[[:space:]]+"; " ")
  else
    empty
  end
' 2>/dev/null) || exit 0

[ -n "$TEXT" ] || exit 0

DEFAULT_MARKERS='done|landed|shipped|fixed|merged|pushed|deployed|green|passing|verified|confirmed|found it|root cause|works now|safe to (merge|push|ship|delete|remove)|all (tests|checks) (pass|green)'
DEFAULT_RE="\\b(${DEFAULT_MARKERS})\\b"
EXTRA_MARKERS=""
if [ -n "${SYG_STATUS_CLAIM_MARKERS:-}" ]; then
  IFS='|' read -r -a _raw_parts <<< "${SYG_STATUS_CLAIM_MARKERS}"
  for _part in "${_raw_parts[@]}"; do
    if [ -n "$_part" ]; then
      if [ -n "$EXTRA_MARKERS" ]; then
        EXTRA_MARKERS="${EXTRA_MARKERS}|${_part}"
      else
        EXTRA_MARKERS="$_part"
      fi
    fi
  done
fi
if [ -n "$EXTRA_MARKERS" ]; then
  MARKERS="\\b(${DEFAULT_MARKERS}|${EXTRA_MARKERS})\\b"
else
  MARKERS="$DEFAULT_RE"
fi

printf '%s\n' "$TEXT" | grep -iqE "$MARKERS" 2>/dev/null
rc=$?
if [ "$rc" -eq 2 ]; then
  printf '%s\n' "$TEXT" | grep -iqE "$DEFAULT_RE" 2>/dev/null || exit 0
elif [ "$rc" -ne 0 ]; then
  exit 0
fi

# shellcheck disable=SC2016
CITE_RE='(`[^`]+`|\b([A-Za-z0-9_./~-]+[./][A-Za-z0-9_./~-]*):[0-9]+)'
if printf '%s\n' "$TEXT" | grep -qE "$CITE_RE" 2>/dev/null; then
  exit 0
fi

if printf '%s\n' "$TEXT" \
  | grep -oE '\b[0-9a-f]{7,40}\b' 2>/dev/null \
  | grep -E '[a-f]' 2>/dev/null \
  | grep -qE '[0-9]' 2>/dev/null; then
  exit 0
fi

MSG='STATUS-CLAIM CITE: this message asserts completion or causality without a citation. Cite the evidence (a backticked command, a sha, or path:line) or hedge the claim.'

jq -nc --arg ctx "$MSG" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: $ctx
  }
}' 2>/dev/null || true

exit 0
