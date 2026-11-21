#!/bin/bash
# PreToolUse hook (matcher: Edit|Write|MultiEdit|NotebookEdit). Write-time memory
# routing: blocks a Write that creates a new memory file until its frontmatter says
# why no rule, skill or doc fits, so routing happens when the fact is written instead
# of in a later audit.
#
# Gated, only when ALL hold:
#   - the tool is Write (Edit, MultiEdit and NotebookEdit are never gated);
#   - the target file does not exist yet (an update is never gated);
#   - its basename ends in .md and is not MEMORY.md;
#   - its parent directory is a memory directory (direct children only: a
#     subdirectory such as roles/ is never gated). A relative file_path resolves
#     against the event cwd.
#
# Memory directories (either counts), as plugins/seyag/bin/context-audit finds them:
#   a. autoMemoryDirectory from the first of <cwd>/.claude/settings.local.json,
#      <cwd>/.claude/settings.json, ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json
#      that sets it non-empty; a leading ~/ expands to $HOME; trailing slashes are
#      ignored;
#   b. the default per-project dir: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/<one
#      path segment>/memory.
#
# Pass: the content opens with a --- frontmatter block (first line exactly ---, closed
# by a later line exactly ---) holding a line `why-memory: <value>` (top level or
# indented, e.g. under metadata:) whose value, trimmed and with one pair of matching
# quotes removed, has at least three whitespace-separated words.
#
# Block: exit 2 with the routing table on stderr.
#
# FAIL-OPEN: no jq, unparsable JSON, a tool other than Write, no file_path, or an
# unresolvable HOME/config dir: exit 0.
#
# KNOWN GAPS (documented, not fixed):
#   - Bash writes (printf >, tee, cp) do not go through Write.
#   - Only the shape of the line is checked, not whether the reason is true.
#   - A symlinked memory dir is matched through realpath -m when it exists, else
#     lexically.

set -uo pipefail

# The payload is read in full first, so no exit below leaves a writer with SIGPIPE.
PAYLOAD=$(cat) || PAYLOAD=""

command -v jq >/dev/null 2>&1 || exit 0
jq -e . >/dev/null 2>&1 <<<"$PAYLOAD" || exit 0

TOOL=$(jq -r '.tool_name // empty' <<<"$PAYLOAD" 2>/dev/null) || exit 0
[ "$TOOL" = Write ] || exit 0

FILE=$(jq -r '.tool_input.file_path // empty' <<<"$PAYLOAD" 2>/dev/null) || exit 0
[ -n "$FILE" ] || exit 0
CWD=$(jq -r '.cwd // empty' <<<"$PAYLOAD" 2>/dev/null) || CWD=""
[ -n "$CWD" ] || CWD=$PWD

case "$FILE" in
  /*) ;;
  *) FILE="$CWD/$FILE" ;;
esac

BASE=${FILE##*/}
case "$BASE" in
  MEMORY.md) exit 0 ;;
  *.md) ;;
  *) exit 0 ;;
esac
[ -e "$FILE" ] && exit 0

# norm PATH: absolute, no trailing slash, dot segments resolved where realpath exists.
norm() {
  local p=$1 r
  if r=$(realpath -m -- "$p" 2>/dev/null) && [ -n "$r" ]; then
    p=$r
  fi
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p=${p%/}; done
  printf '%s' "$p"
}

PARENT=$(norm "$(dirname -- "$FILE")")

HOME_DIR=${HOME:-}
CONF=${CLAUDE_CONFIG_DIR:-${HOME_DIR:+$HOME_DIR/.claude}}

# Memory directory a: autoMemoryDirectory from the first settings file that sets it.
AUTO=""
for f in "$CWD/.claude/settings.local.json" "$CWD/.claude/settings.json" ${CONF:+"$CONF/settings.json"}; do
  [ -r "$f" ] || continue
  v=$(jq -r 'if (.autoMemoryDirectory | type) == "string" then .autoMemoryDirectory else empty end' "$f" 2>/dev/null) || continue
  if [ -n "$v" ]; then
    AUTO=$v
    break
  fi
done

in_memory_dir=0
if [ -n "$AUTO" ]; then
  case "$AUTO" in
    \~) AUTO=$HOME_DIR ;;
    \~/*) AUTO="$HOME_DIR/${AUTO#\~/}" ;;
  esac
  case "$AUTO" in
    /*) [ "$(norm "$AUTO")" = "$PARENT" ] && in_memory_dir=1 ;;
  esac
fi

# Memory directory b: <config>/projects/<one segment>/memory.
if [ "$in_memory_dir" = 0 ] && [ -n "$CONF" ]; then
  PROJ=$(norm "$CONF/projects")
  case "$PARENT" in
    "$PROJ"/*/memory)
      seg=${PARENT#"$PROJ"/}
      seg=${seg%/memory}
      case "$seg" in
        "" | */*) ;;
        *) in_memory_dir=1 ;;
      esac
      ;;
  esac
fi
[ "$in_memory_dir" = 1 ] || exit 0

# Frontmatter check on the content being written.
CONTENT=$(jq -r '.tool_input.content // empty' <<<"$PAYLOAD" 2>/dev/null) || exit 0

# A here-string, not a pipe: awk stops at the closing ---, and under pipefail a
# writer still feeding a large body would take SIGPIPE and fail a valid block.
# CRLF line ends are accepted.
FM=$(awk '
  { sub(/\r$/, "") }
  NR == 1 { if ($0 != "---") exit 1; next }
  $0 == "---" { closed = 1; exit 0 }
  { print }
  END { if (!closed) exit 1 }
' <<<"$CONTENT") && FM_OK=1 || FM_OK=0

if [ "$FM_OK" = 1 ]; then
  while IFS= read -r line; do
    if [[ $line =~ ^[[:space:]]*why-memory:[[:space:]]*(.*)$ ]]; then
      val=${BASH_REMATCH[1]}
      # trim surrounding whitespace
      val="${val#"${val%%[![:space:]]*}"}"
      val="${val%"${val##*[![:space:]]}"}"
      # strip one pair of matching quotes
      if [ "${#val}" -ge 2 ]; then
        first=${val:0:1}
        last=${val: -1}
        if { [ "$first" = '"' ] || [ "$first" = "'" ]; } && [ "$first" = "$last" ]; then
          val=${val:1:${#val}-2}
        fi
      fi
      # Count words without glob expansion (a value like `* * *` must not match files).
      read -r -a words <<<"$val"
      [ "${#words[@]}" -ge 3 ] && exit 0
    fi
  done <<<"$FM"
fi

cat >&2 <<EOF
MEMORY ROUTE GATE: new memory file $FILE has no frontmatter \`why-memory:\` line of three or more words.
Memory is the last resort; route the fact where it loads when needed:
  - "always do X" for every session -> a plugin or user rule; for one project -> that project's rule
  - a multi-step procedure -> a skill step
  - a fact someone looks up on purpose -> a doc (env doc, project CLAUDE.md, README)
  - session state or a handoff -> the session's own status/role file
  - per-person context, a preference that doesn't generalize, a pointer to an external resource -> memory
If memory is right, add to the frontmatter one line saying why none of the others fits:
  why-memory: <at least three words>
(seyag core rules § Fix recurring failures structurally; doc-audit skill's verdict table.)
EOF
exit 2
