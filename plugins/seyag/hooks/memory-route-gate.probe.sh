#!/usr/bin/env bash
# Probe for memory-route-gate.sh (PreToolUse Write).
# Every row runs under env -i with an invented HOME and CLAUDE_CONFIG_DIR under
# mktemp, so the real settings and memory are never read. The hook sits next to this
# file; a copy of this probe beside a stub hook that always allows exercises the
# purpose canary (the probe must FAIL against it).

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="${MRG_PROBE_HOOK:-$HERE/memory-route-gate.sh}"
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
OUT=""
RC=0

ok() { pass=$((pass + 1)); }
bad() {
  fail=$((fail + 1))
  echo "FAIL [$1]: $2" >&2
}

HOME_D="$TMP/home"
CONF="$TMP/conf"
CWD="$TMP/work"
MEM="$CONF/projects/-invented-proj/memory"
mkdir -p "$HOME_D/mem" "$CONF" "$CWD" "$MEM/roles" "$TMP/elsewhere"

MSG='MEMORY ROUTE GATE: new memory file'

# run_hook PAYLOAD [VAR=VALUE ...]: sets OUT and RC.
run_hook() {
  local payload=$1
  shift
  OUT=$(printf '%s' "$payload" | env -i PATH="$PATH" HOME="$HOME_D" CLAUDE_CONFIG_DIR="$CONF" "$@" \
    bash "$HOOK" 2>&1)
  RC=$?
}

# block_case LABEL PAYLOAD [VAR=VALUE ...]: exit 2 with the gate message.
block_case() {
  local label=$1
  shift
  run_hook "$@"
  if [ "$RC" = 2 ] && grep -qF -- "$MSG" <<<"$OUT" && grep -qF -- 'why-memory: <at least three words>' <<<"$OUT"; then
    ok
  else
    bad "$label" "expected block (exit 2) with the gate message, got rc=$RC out=$OUT"
  fi
}

# pass_case LABEL PAYLOAD [VAR=VALUE ...]: exit 0, silent.
pass_case() {
  local label=$1
  shift
  run_hook "$@"
  if [ "$RC" = 0 ] && [ -z "$OUT" ]; then
    ok
  else
    bad "$label" "expected pass (exit 0, silent), got rc=$RC out=$OUT"
  fi
}

jq_write() { # FILE CONTENT [CWD]
  jq -cn --arg f "$1" --arg n "$2" --arg c "${3:-$CWD}" \
    '{tool_name: "Write", cwd: $c, tool_input: {file_path: $f, content: $n}}'
}

PLAIN=$'# Note\n\nbody\n'
FM_OK=$'---\nname: x\nwhy-memory: a pointer to an external dashboard\n---\nbody\n'
FM_NESTED=$'---\nname: x\nmetadata:\n  type: reference\n  why-memory: a pointer to an external dashboard\n---\nbody\n'
FM_EMPTY=$'---\nname: x\nwhy-memory: ""\n---\nbody\n'
FM_SHORT=$'---\nname: x\nwhy-memory: too short\n---\nbody\n'
FM_QUOTED=$'---\nname: x\nwhy-memory: \'a pointer elsewhere\'\n---\nbody\n'
FM_UNCLOSED=$'---\nname: x\nwhy-memory: a pointer to an external dashboard\nbody\n'
FM_OUTSIDE=$'---\nname: x\n---\nwhy-memory: a pointer to an external dashboard\n'

# --- 1-4. Default per-project memory dir --------------------------------------------
block_case "1: new file, no frontmatter" "$(jq_write "$MEM/a.md" "$PLAIN")"
pass_case "2: top-level why-memory, 3+ words" "$(jq_write "$MEM/a.md" "$FM_OK")"
pass_case "3: why-memory indented under metadata:" "$(jq_write "$MEM/a.md" "$FM_NESTED")"
block_case "4a: why-memory empty string" "$(jq_write "$MEM/a.md" "$FM_EMPTY")"
block_case "4b: why-memory with two words" "$(jq_write "$MEM/a.md" "$FM_SHORT")"
pass_case "4c: one pair of quotes is stripped, 3 words remain" "$(jq_write "$MEM/a.md" "$FM_QUOTED")"
block_case "4d: frontmatter never closed" "$(jq_write "$MEM/a.md" "$FM_UNCLOSED")"
block_case "4e: why-memory sits after the frontmatter, not in it" "$(jq_write "$MEM/a.md" "$FM_OUTSIDE")"
# A glob value must not expand against the hook's working directory into 3+ "words".
mkdir -p "$TMP/globdir" && touch "$TMP/globdir/f1" "$TMP/globdir/f2" "$TMP/globdir/f3"
cd "$TMP/globdir" || exit 1
block_case "4f: why-memory: * is one word, not a glob" "$(jq_write "$MEM/a.md" $'---\nwhy-memory: *\n---\n')"
cd "$HERE" || exit 1
# A large body after a valid block must not change the verdict (no SIGPIPE under pipefail).
{ printf '%s' "$FM_OK"; head -c 3000000 /dev/zero | tr '\0' 'x'; } >"$TMP/big.md"
BIG_PAYLOAD=$(jq -cn --arg f "$MEM/a.md" --rawfile n "$TMP/big.md" --arg c "$CWD" \
  '{tool_name: "Write", cwd: $c, tool_input: {file_path: $f, content: $n}}')
[ "${#BIG_PAYLOAD}" -gt 3000000 ] || bad "4g" "fixture payload not built (${#BIG_PAYLOAD} bytes)"
pass_case "4g: valid frontmatter, 3 MB body" "$BIG_PAYLOAD"
pass_case "4h: CRLF line ends" "$(jq_write "$MEM/a.md" $'---\r\nwhy-memory: a pointer to elsewhere\r\n---\r\nbody\r\n')"

# --- 5-7. Existing files, MEMORY.md, subdirectories ---------------------------------
printf 'old\n' >"$MEM/existing.md"
pass_case "5: existing file (the update path)" "$(jq_write "$MEM/existing.md" "$PLAIN")"
pass_case "6: new MEMORY.md" "$(jq_write "$MEM/MEMORY.md" "$PLAIN")"
pass_case "7: new file in a subdirectory (roles/)" "$(jq_write "$MEM/roles/x.md" "$PLAIN")"

# --- 8. autoMemoryDirectory ---------------------------------------------------------
printf '{"autoMemoryDirectory": "~/mem"}\n' >"$CONF/settings.json"
block_case "8a: user settings autoMemoryDirectory ~/mem, new file without why" \
  "$(jq_write "$HOME_D/mem/x.md" "$PLAIN")"
pass_case "8b: same dir, why-memory present" "$(jq_write "$HOME_D/mem/x.md" "$FM_OK")"
block_case "8c: the per-project default still gates when a user setting is also set" \
  "$(jq_write "$MEM/b.md" "$PLAIN")"
mkdir -p "$CWD/.claude" "$TMP/projmem"
printf '{"autoMemoryDirectory": "%s/"}\n' "$TMP/projmem" >"$CWD/.claude/settings.json"
block_case "8d: project settings override (trailing slash) is honoured" \
  "$(jq_write "$TMP/projmem/y.md" "$PLAIN")"
pass_case "8e: the overridden user dir is no longer a memory dir" \
  "$(jq_write "$HOME_D/mem/z.md" "$PLAIN")"
rm -f "$CWD/.claude/settings.json"
printf '{"autoMemoryDirectory": "%s"}\n' "$TMP/localmem" >"$CWD/.claude/settings.local.json"
mkdir -p "$TMP/localmem"
block_case "8f: settings.local.json override is honoured" \
  "$(jq_write "$TMP/localmem/l.md" "$PLAIN")"
rm -f "$CWD/.claude/settings.local.json" "$CONF/settings.json"

# --- 9-11. Out-of-scope files and tools ---------------------------------------------
pass_case "9: non-.md file in the memory dir" "$(jq_write "$MEM/data.txt" "$PLAIN")"
pass_case "10: Edit tool on a new path" \
  "$(jq -cn --arg f "$MEM/e.md" --arg c "$CWD" '{tool_name:"Edit",cwd:$c,tool_input:{file_path:$f,old_string:"",new_string:"x"}}')"
pass_case "10b: MultiEdit tool on a new path" \
  "$(jq -cn --arg f "$MEM/e.md" --arg c "$CWD" '{tool_name:"MultiEdit",cwd:$c,tool_input:{file_path:$f,edits:[]}}')"
pass_case "11: path outside any memory dir" "$(jq_write "$TMP/elsewhere/n.md" "$PLAIN")"
pass_case "11b: projects/<seg>/notes is not the memory dir" \
  "$(jq_write "$CONF/projects/-invented-proj/notes/n.md" "$PLAIN")"
pass_case "11c: projects/<a>/<b>/memory is two segments deep" \
  "$(jq_write "$CONF/projects/a/b/memory/n.md" "$PLAIN")"

# --- 12. Relative path --------------------------------------------------------------
block_case "12: relative file_path resolved against cwd lands in the memory dir" \
  "$(jq -cn --arg c "$MEM" '{tool_name:"Write",cwd:$c,tool_input:{file_path:"rel.md",content:"body"}}')"
pass_case "12b: relative file_path landing outside" \
  "$(jq -cn --arg c "$TMP/elsewhere" '{tool_name:"Write",cwd:$c,tool_input:{file_path:"rel.md",content:"body"}}')"

# --- 13. Fail open ------------------------------------------------------------------
pass_case "13: malformed JSON" 'not json {'
pass_case "13b: Write without file_path" '{"tool_name":"Write","tool_input":{"content":"x"}}'
pass_case "13c: tool Bash" '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}'

# --- 15. Large payload drains stdin on an early exit ---------------------------------
BIG=$(head -c 70000 /dev/zero | tr '\0' a)
BIGPAYLOAD='{"tool_name":"Bash","tool_input":{"command":"'"$BIG"'"}}'
big_ok=1
for _ in 1 2 3; do
  printf '%s' "$BIGPAYLOAD" | env -i PATH="$PATH" HOME="$HOME_D" bash "$HOOK" >/dev/null 2>&1
  pst=("${PIPESTATUS[@]}")
  if [ "${pst[0]}" = 141 ] || [ "${pst[1]}" != 0 ]; then big_ok=0; fi
done
if [ "$big_ok" = 1 ]; then ok; else bad "15: large payload" "writer=${pst[0]} hook=${pst[1]} (141 is SIGPIPE)"; fi

# --- 14. Purpose canary: a hook that always allows must fail this probe ---------------
if [ -z "${MRG_PROBE_HOOK:-}" ]; then
  mkdir -p "$TMP/stub"
  printf '#!/bin/bash\ncat >/dev/null\nexit 0\n' >"$TMP/stub/memory-route-gate.sh"
  if MRG_PROBE_HOOK="$TMP/stub/memory-route-gate.sh" bash "$0" >/dev/null 2>&1; then
    bad "14: purpose canary" "an always-allow stub hook passed this probe"
  else
    ok
  fi
fi

[ "$fail" -eq 0 ] || { echo "FAIL: memory-route-gate ($fail failed, $pass passed)"; exit 1; }
echo "PASS: memory-route-gate ($pass cases)"
