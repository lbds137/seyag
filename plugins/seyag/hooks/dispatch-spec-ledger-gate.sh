#!/bin/bash
# PreToolUse hook (matcher: Agent) — requires a dispatched implementation spec
# to carry a checkable `## Premise ledger` section (see the seyag `delegation`
# skill, § The spec template).
#
# Three checks:
#   1. Named spec file: extracts the FIRST path in `tool_input.prompt` matching
#      `SYG_DISPATCH_SPEC_RE` (if set and non-empty, an extended regex used with
#      `grep -oE`) or the built-in default
#      `[A-Za-z0-9._~/-]*\.claude/dispatch/[A-Za-z0-9._-]+\.md` (a leading `~/`
#      expands to `$HOME/`). Only the first
#      match is checked; a first match that does not resolve to a real file
#      (absolute as-is; relative against `${CLAUDE_PROJECT_DIR:-.}`) ends the
#      file-path branch (later named paths are never checked — they are treated
#      as narrative mentions or superseded specs). When that first match
#      resolves, greps it for `^##+ *Premise ledger[[:space:]#]*$`
#      (case-insensitive). Absent (grep exit 1) blocks; grep exit >= 2 fails
#      open with a stderr note.
#   2. Inline prompt (opt-in via `SYG_DISPATCH_SPEC_INLINE=1` — a broad trigger
#      opts in, matching `dispatch-posture-gate`'s precedent so research agents
#      and non-adopting projects are never blocked on their prompts): when no
#      extracted path resolves, `SYG_DISPATCH_SPEC_INLINE=1`, and
#      `tool_input.isolation == "worktree"`, the prompt itself is the spec
#      text; greps the prompt for the same heading. Absent blocks with the
#      inline variant. Calls without the opt-in, or with any other (or absent)
#      isolation, exit 0.
#   3. Cite check: within the `## Premise ledger` section (the heading line
#      through the line before the next `^##` heading), every logical `- `
#      bullet row (the `- ` line plus its immediately following indented
#      continuation lines) must contain either a backtick span (`` `...` ``) or
#      a slash-bearing path token (`path/to/file.ext` with optional `:LINE`).
#      Nested `- ` sub-bullets are rows too and must cite; an explanatory note
#      gets backticks or a `path/to/file.ext[:line]`. Zero bullet rows or any
#      uncited bullet row blocks.
#
# Fixture check: run plugins/seyag/hooks/dispatch-spec-ledger-gate.probe.sh
# after ANY edit to this hook.

set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "dispatch-spec-ledger-gate: jq unavailable — failing open" >&2
  exit 0
fi

INPUT=$(cat 2>/dev/null) || exit 0
[ -n "$INPUT" ] || exit 0

TOOL_NAME=$(jq -r '.tool_name // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ "$TOOL_NAME" = "Agent" ] || exit 0

PROMPT=$(jq -r '.tool_input.prompt // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ -n "$PROMPT" ] || exit 0

ISOLATION=$(jq -r '.tool_input.isolation // empty' <<<"$INPUT" 2>/dev/null || echo "")

DEFAULT_SPEC_RE='[A-Za-z0-9._~/-]*\.claude/dispatch/[A-Za-z0-9._-]+\.md'
SPEC_RE="${SYG_DISPATCH_SPEC_RE:-$DEFAULT_SPEC_RE}"

RULE='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'

block_missing_section() {
  local suffix="$1" target="$2" near_miss="${3:-}"
  near_miss="${near_miss%$'\r'}"
  # shellcheck disable=SC2016
  printf '%s\nDISPATCH SPEC — no `## Premise ledger` section%s\n%s\n  %s\n' \
    "$RULE" "$suffix" "$RULE" "$target" >&2
  if [ -n "$near_miss" ]; then
    printf '  Found heading:    %s\n' "$near_miss" >&2
  fi
  printf '  Expected heading: ## Premise ledger\n\n' >&2
  cat >&2 <<'EOF'
Every dispatched implementation spec must carry a `## Premise ledger`
section: one `- ` bullet row per runtime premise the spec asserts, naming
the read or probe that established it (a backticked command/token or a
slash-bearing `path/to/file.ext[:line]` reference). An inline prompt
(`isolation: "worktree"`) is a spec too, when `SYG_DISPATCH_SPEC_INLINE=1`.
See the seyag `delegation` skill (`## Premise ledger`).

EOF
  printf '%s\n' "$RULE" >&2
  exit 2
}

block_empty_ledger() {
  local target="$1"
  cat >&2 <<EOF
$RULE
DISPATCH SPEC — premise ledger section has no \`- \` bullet rows
$RULE
  $target

An empty \`## Premise ledger\` section is not a ledger. Include at least one
\`- \` bullet row naming a runtime premise the spec asserts and citing the
read or probe that established it (a backtick span or a slash-bearing
\`path/to/file.ext[:line]\` token).
See the seyag \`delegation\` skill (\`## Premise ledger\`).

$RULE
EOF
  exit 2
}

block_uncited_row() {
  local target="$1" row="$2"
  printf '%s\nDISPATCH SPEC — premise row without a citation\n%s\n  %s\n\nFirst offending row:\n  %s\n\n' \
    "$RULE" "$RULE" "$target" "$row" >&2
  cat >&2 <<'EOF'
Every `- ` bullet row in `## Premise ledger` must cite the read or probe
that established the premise: include a `` `backtick` `` span or a
slash-bearing `path/to/file.ext[:line]` token.
See the seyag `delegation` skill (`## Premise ledger`).

EOF
  printf '%s\n' "$RULE" >&2
  exit 2
}

HITS=$(grep -oE -- "$SPEC_RE" <<<"$PROMPT" 2>/dev/null)
GREP_RC=$?
if [ "$GREP_RC" -ge 2 ]; then
  echo "dispatch-spec-ledger-gate: could not scan the prompt for a spec path (grep exit $GREP_RC) — failing open" >&2
  exit 0
fi
SPEC_PATH=$(head -n 1 <<<"$HITS")
SPEC_PATH="${SPEC_PATH/#\~\//${HOME:-~}/}"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
RESOLVED_PATH=""
if [ -n "$SPEC_PATH" ]; then
  case "$SPEC_PATH" in
    /*) CANDIDATE="$SPEC_PATH" ;;
    *) CANDIDATE="${PROJECT_DIR%/}/$SPEC_PATH" ;;
  esac
  if [ -f "$CANDIDATE" ]; then
    RESOLVED_PATH="$CANDIDATE"
  fi
fi

CHECK_TEXT=""
TARGET_LABEL=""

if [ -n "$RESOLVED_PATH" ]; then
  grep -qiE '^##+ *Premise ledger[[:space:]#]*$' "$RESOLVED_PATH" 2>/dev/null
  GREP_RC=$?
  if [ "$GREP_RC" -ge 2 ]; then
    echo "dispatch-spec-ledger-gate: could not read $RESOLVED_PATH (grep exit $GREP_RC) — failing open" >&2
    exit 0
  fi
  if [ "$GREP_RC" -eq 1 ]; then
    NEAR_MISS=$(grep -iE '^[[:space:]]*#.*premise[[:space:]]+ledger' "$RESOLVED_PATH" 2>/dev/null | head -n 1 || true)
    block_missing_section "" "$RESOLVED_PATH" "$NEAR_MISS"
  fi
  CHECK_TEXT=$(cat "$RESOLVED_PATH" 2>/dev/null || echo "")
  if [ -z "$CHECK_TEXT" ]; then
    echo "dispatch-spec-ledger-gate: could not re-read $RESOLVED_PATH — failing open" >&2
    exit 0
  fi
  TARGET_LABEL="$RESOLVED_PATH"
else
  if [ "${SYG_DISPATCH_SPEC_INLINE:-0}" != "1" ] || [ "$ISOLATION" != "worktree" ]; then
    exit 0
  fi
  grep -qiE '^##+ *Premise ledger[[:space:]#]*$' <<<"$PROMPT" 2>/dev/null
  GREP_RC=$?
  if [ "$GREP_RC" -ge 2 ]; then
    echo "dispatch-spec-ledger-gate: could not scan the inline prompt (grep exit $GREP_RC) — failing open" >&2
    exit 0
  fi
  if [ "$GREP_RC" -eq 1 ]; then
    NEAR_MISS=$(grep -iE '^[[:space:]]*#.*premise[[:space:]]+ledger' <<<"$PROMPT" 2>/dev/null | head -n 1 || true)
    block_missing_section " (inline prompt)" "(inline prompt, isolation: worktree)" "$NEAR_MISS"
  fi
  CHECK_TEXT="$PROMPT"
  TARGET_LABEL="(inline prompt, isolation: worktree)"
fi

HEADING_RE='^##+ *[Pp][Rr][Ee][Mm][Ii][Ss][Ee] [Ll][Ee][Dd][Gg][Ee][Rr][[:space:]#]*$'
# The section ends at the next ^## line — a single-# heading or a ## inside a
# fenced block does not end it (rows after either are still checked); accepted
# edge, real specs rarely hit it.
NEXT_SEC_RE='^##'
ROW_RE='^[[:space:]]*- '
BLANK_RE='^[[:space:]]*$'
CONT_RE='^[[:space:]]+'
# The cite test is a presence floor, not proof of a read: any backticked span or any
# `dir/file.ext` token counts, so a row like "- uses `x`" passes; the gate nudges, review judges.
# shellcheck disable=SC2016
CITE_RE='(`[^`]+`|[A-Za-z0-9._~-]+(/[A-Za-z0-9._~-]+)+\.[A-Za-z0-9]{1,7}(:[0-9]+)?)'

IN_SECTION=0
IN_ROW=0
ROW_COUNT=0
ROW_OPENING=""
ROW_TEXT=""
BAD_ROW=""

flush_row() {
  [ "$IN_ROW" -eq 1 ] || return 0
  IN_ROW=0
  grep -qE -- "$CITE_RE" <<<"$ROW_TEXT" 2>/dev/null
  local rc=$?
  if [ "$rc" -eq 1 ]; then
    BAD_ROW="$ROW_OPENING"
    return 1
  fi
  return 0
}

while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"
  if [ "$IN_SECTION" -eq 0 ]; then
    if [[ "$line" =~ $HEADING_RE ]]; then
      IN_SECTION=1
    fi
    continue
  fi
  if [[ "$line" =~ $NEXT_SEC_RE ]]; then
    flush_row || break
    break
  fi
  if [[ "$line" =~ $BLANK_RE ]]; then
    flush_row || break
    continue
  fi
  if [[ "$line" =~ $ROW_RE ]]; then
    flush_row || break
    IN_ROW=1
    ROW_COUNT=$((ROW_COUNT + 1))
    ROW_OPENING="${line#"${line%%[![:space:]]*}"}"
    ROW_TEXT="$line"
    continue
  fi
  if [ "$IN_ROW" -eq 1 ] && [[ "$line" =~ $CONT_RE ]]; then
    ROW_TEXT="$ROW_TEXT $line"
    continue
  fi
  flush_row || break
done <<<"$CHECK_TEXT"

if [ -z "$BAD_ROW" ]; then
  flush_row || true
fi

if [ -n "$BAD_ROW" ]; then
  if [ "${#BAD_ROW}" -gt 160 ]; then
    BAD_ROW="${BAD_ROW:0:160}..."
  fi
  block_uncited_row "$TARGET_LABEL" "$BAD_ROW"
fi

if [ "$ROW_COUNT" -eq 0 ]; then
  block_empty_ledger "$TARGET_LABEL"
fi

exit 0
