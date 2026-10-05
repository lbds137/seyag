#!/bin/bash
# SessionStart hook (seyag plugin) — fail-closed approved-route check.
#
# TRIGGER: every SessionStart source (startup, clear, resume, compact; compaction
# drops earlier context, so the banner is re-asserted). A session that must only
# run on an approved model route (provider / endpoint) is told to stop when the
# live route is not approved. Not required -> silent exit 0, the command never runs.
#
# CONFIG (all env, read from the hook's own environment, which is the session's):
#   SYG_ROUTE_REQUIRED            1|true|yes|on (any case): this session requires an
#                                 approved route. Unset, empty, 0|false|no|off: not
#                                 by this rule. Anything else is a misconfiguration.
#   SYG_ROUTE_MARKER_FILE         path template; `{project}` becomes the basename of
#                                 the project dir (CLAUDE_PROJECT_DIR, else the
#                                 event's cwd, else $PWD); a leading `~/` is $HOME.
#   SYG_ROUTE_MARKER_FIELD        field name (^[A-Za-z0-9_-]+$). The session requires
#                                 a route when the file exists and its leading YAML
#                                 frontmatter (first line exactly `---`, up to the
#                                 next line exactly `---`) has a line
#                                 `<indent><FIELD>: <value>` whose value (trimmed,
#                                 one pair of matching quotes removed) is non-empty.
#                                 Any indentation counts, so a nested field matches.
#                                 A missing file, or a field only below the closing
#                                 `---`, is not required.
#   SYG_ROUTE_CHECK_CMD           run as `bash -c "$CMD"`: stdin /dev/null, cwd the
#                                 project dir, environment inherited unchanged,
#                                 under `timeout` when it exists.
#   SYG_ROUTE_CHECK_OK            the word the command's first stdout line must
#                                 start with.
#   SYG_ROUTE_CHECK_TIMEOUT       seconds (digits only, else 10; 0 is read as 10).
#                                 Meant for the probe.
# The configured command must judge the environment it inherits (the session's),
# not a settings file that may have changed since the session started.
#
# PASS: exit 0 AND the first whitespace-delimited word of the first stdout line
# equals SYG_ROUTE_CHECK_OK exactly (`ok<TAB>reason` passes for OK=ok; `okay`
# does not). Silent exit 0.
#
# FAIL (exit 0 with a JSON systemMessage for the person and an additionalContext
# banner telling the session to stop and tell the owner; each case names its own
# reason): command unset or empty; OK word unset or empty; command not found
# (127); timed out (124); other non-zero exit; empty stdout; word mismatch.
#
# FAIL-CLOSED: misconfiguration counts as required AND failed, and the banner names
# it (the command is not run): an unrecognized SYG_ROUTE_REQUIRED value, exactly
# one of MARKER_FILE / MARKER_FIELD set, a FIELD that does not match
# ^[A-Za-z0-9_-]+$, a `~/` template with HOME unset, or a marker file that exists
# but cannot be read. A project dir that does not exist also fails (the command
# is not run). No jq, or a jq failure, and a failure: the banner goes out as plain
# stdout (SessionStart adds plain stdout to context); never a silent pass.
#
# NOT COVERED, by the shared dispatcher's design: run.sh fails open on a hook with
# a syntax error, and yields to a project-local .claude/hooks/route-check.sh; both
# disable this check.
#
# Fixture check: run hooks/route-check.probe.sh after ANY edit here.

set -uo pipefail

INPUT=""
if command -v jq >/dev/null 2>&1; then
  INPUT=$(cat)
fi

project_dir() {
  local p="${CLAUDE_PROJECT_DIR:-}"
  if [ -z "$p" ] && [ -n "$INPUT" ]; then
    p=$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null || echo "")
  fi
  printf '%s' "${p:-$PWD}"
}
PROJ=$(project_dir)

REASON=""   # non-empty once the check has failed
REQUIRED=0

# Misconfiguration: required AND failed; the first reason found is kept.
misconfig() { REQUIRED=1; [ -n "$REASON" ] || REASON="$1"; }

RV="${SYG_ROUTE_REQUIRED:-}"
case "${RV,,}" in
  1 | true | yes | on) REQUIRED=1 ;;
  '' | 0 | false | no | off) ;;
  *) misconfig "misconfigured: SYG_ROUTE_REQUIRED=${RV:0:20} is not a recognized value" ;;
esac

FILE_T="${SYG_ROUTE_MARKER_FILE:-}"
FIELD="${SYG_ROUTE_MARKER_FIELD:-}"
if [ -n "$FILE_T" ] || [ -n "$FIELD" ]; then
  if [ -z "$FILE_T" ] || [ -z "$FIELD" ]; then
    misconfig "misconfigured: SYG_ROUTE_MARKER_FILE and SYG_ROUTE_MARKER_FIELD must be set together"
  elif ! [[ "$FIELD" =~ ^[A-Za-z0-9_-]+$ ]]; then
    misconfig "misconfigured: SYG_ROUTE_MARKER_FIELD must match [A-Za-z0-9_-]+"
  elif [[ "$FILE_T" == \~/* ]] && [ -z "${HOME:-}" ]; then
    misconfig "misconfigured: SYG_ROUTE_MARKER_FILE starts with ~/ but HOME is not set"
  else
    P="${PROJ%/}"
    # Quoted replacement: bash 5.2 turns a bare & in it into the match.
    name="${P##*/}"
    FILE="${FILE_T//\{project\}/"$name"}"
    case "$FILE" in \~/*) FILE="$HOME/${FILE#\~/}" ;; esac
    if [ -e "$FILE" ] && { [ -d "$FILE" ] || ! ( : <"$FILE" ) 2>/dev/null; }; then
      misconfig "the marker file $FILE exists but cannot be read"
    elif [ -f "$FILE" ]; then
      first=1
      while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        if [ "$first" = 1 ]; then
          first=0
          [ "$line" = '---' ] || break
          continue
        fi
        [ "$line" = '---' ] && break
        if [[ "$line" =~ ^[[:space:]]*${FIELD}:[[:space:]]*(.*)$ ]]; then
          v="${BASH_REMATCH[1]}"
          v="${v#"${v%%[![:space:]]*}"}"
          v="${v%"${v##*[![:space:]]}"}"
          if [ "${#v}" -ge 2 ]; then
            case "$v" in
              \"*\" | \'*\') [ "${v:0:1}" = "${v: -1}" ] && v="${v:1:${#v}-2}" ;;
            esac
          fi
          if [ -n "$v" ]; then REQUIRED=1; break; fi
        fi
      done <"$FILE"
    fi
  fi
fi

[ "$REQUIRED" = 1 ] || exit 0

if [ -z "$REASON" ]; then
  CMD="${SYG_ROUTE_CHECK_CMD:-}"
  OKW="${SYG_ROUTE_CHECK_OK:-}"
  T="${SYG_ROUTE_CHECK_TIMEOUT:-10}"
  case "$T" in '' | *[!0-9]*) T=10 ;; esac
  [ "$T" -gt 0 ] || T=10
  if [ -z "$CMD" ]; then
    REASON="SYG_ROUTE_CHECK_CMD is not set"
  elif [ -z "$OKW" ]; then
    REASON="SYG_ROUTE_CHECK_OK is not set"
  elif [ ! -d "$PROJ" ]; then
    REASON="the project dir $PROJ does not exist"
  else
    TO=()
    # -k: a command that ignores TERM is killed 2s later, so it cannot stall the hook.
    command -v timeout >/dev/null 2>&1 && TO=(timeout -k 2 "$T")
    OUT=$(cd "$PROJ" 2>/dev/null && "${TO[@]+"${TO[@]}"}" bash -c "$CMD" </dev/null 2>/dev/null)
    RC=$?
    if [ "$RC" = 127 ]; then
      REASON="the route check command was not found (exit 127)"
    elif { [ "$RC" = 124 ] || [ "$RC" = 137 ]; } && [ "${#TO[@]}" -gt 0 ]; then
      REASON="the route check command timed out after ${T}s"
    elif [ "$RC" != 0 ]; then
      REASON="the route check command exited $RC"
    elif [ -z "$OUT" ]; then
      REASON="the route check command printed nothing"
    else
      LINE="${OUT%%$'\n'*}"
      read -r WORD _ <<<"$LINE"
      if [ "${WORD:-}" != "$OKW" ]; then
        REASON="the route check command's first word was '${WORD:0:80}', not '${OKW:0:80}'"
      fi
    fi
  fi
fi

[ -n "$REASON" ] || exit 0

BANNER="ROUTE CHECK FAILED — do not start work in this session.
$REASON
Tell the owner now through the formal channel (AskUserQuestion or PushNotification) and do nothing else until they rule. The check judges this session's own environment; fixing the route needs a session restart."

if command -v jq >/dev/null 2>&1; then
  jq -n --arg msg "Route check failed: $REASON. This session should not work until the route is fixed." --arg ctx "$BANNER" \
    '{systemMessage: $msg, hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}' \
    || printf '%s\n' "$BANNER"
else
  printf '%s\n' "$BANNER"
fi
exit 0
