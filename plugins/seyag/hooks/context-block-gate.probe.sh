#!/bin/bash
# Fixture check for context-block-gate.sh — run after ANY edit to the hook.
#
# The gate decides from three inputs: the armed/done marker pair for the
# payload's session (created by context-size-reminder.sh's hard tier), the
# SYG_CONTEXT_BLOCK_CMDS / SYG_CONTEXT_BLOCK_PATHS clear lists, and the
# tool_name + tool_input of the PreToolUse payload. Each case plants a marker
# pair, invokes the hook with a crafted payload, and asserts allow / block /
# fail-open. Every allow case has a paired blocked control proving the same
# fixture CAN block, so a green allow is never a probe that cannot fail.
#
# The arm side (what writes the markers) is pinned by
# tests/context-block.probe.sh; this file pins the gate alone.
#
# Usage: hooks/context-block-gate.probe.sh   (from repo root)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GATE="$SCRIPT_DIR/context-block-gate.sh"

# The defaults are pinned below; an ambient override must not skew them.
unset SYG_CONTEXT_BLOCK SYG_CONTEXT_BLOCK_CMDS SYG_CONTEXT_BLOCK_PATHS

command -v jq >/dev/null 2>&1 || {
    echo "FATAL: jq is required — the hook parses its stdin payload with it" >&2
    exit 1
}

TMPDIR_PROBE=$(mktemp -d)
STATE_DIR="/tmp/claude-$(id -u)"
SESSION_PREFIX="probe-cbg-$$"

cleanup() {
    rm -rf "$TMPDIR_PROBE"
    rm -f "$STATE_DIR/context-block-$SESSION_PREFIX"-* 2>/dev/null
    rm -f "$STATE_DIR/context-block-done-$SESSION_PREFIX"-* 2>/dev/null
}
trap cleanup EXIT

fail=0
OUT=""
ERR=""
RC=0

armed_file() { # $1 = session suffix
    printf '%s/context-block-%s-%s' "$STATE_DIR" "$SESSION_PREFIX" "$1"
}

done_file() { # $1 = session suffix
    printf '%s/context-block-done-%s-%s' "$STATE_DIR" "$SESSION_PREFIX" "$1"
}

# Plant the marker pair the reminder's hard tier would write. $1 = suffix.
arm() {
    printf '999999 %s\n' "$(date +%s)" >"$(armed_file "$1")"
    rm -f "$(done_file "$1")"
}

disarm() { # $1 = session suffix
    rm -f "$(armed_file "$1")" "$(done_file "$1")"
}

# Run the gate. $1 = session suffix ("" omits session_id), $2 = tool_name,
# $3 = tool_input JSON. Env for the run must be set by the caller as a prefix.
run_gate() {
    local session="$SESSION_PREFIX-$1" json
    if [ -z "$1" ]; then
        json=$(jq -nc --arg t "$2" --argjson in "$3" \
            '{hook_event_name: "PreToolUse", tool_name: $t, tool_input: $in}')
    else
        json=$(jq -nc --arg s "$session" --arg t "$2" --argjson in "$3" \
            '{hook_event_name: "PreToolUse", session_id: $s, tool_name: $t, tool_input: $in}')
    fi
    OUT=$(printf '%s' "$json" | "$GATE" 2>"$TMPDIR_PROBE/err")
    RC=$?
    ERR=$(cat "$TMPDIR_PROBE/err")
}

block_text() { # $1 = tool_name → the pinned stderr line
    printf 'context-block-gate: blocked %s until the context handoff is written (SYG_CONTEXT_BLOCK active; one write to a SYG_CONTEXT_BLOCK_PATHS path or a SYG_CONTEXT_BLOCK_CMDS command lifts it)' "$1"
}

assert_allow() { # $1 = label
    if [ "$RC" != 0 ]; then
        echo "FAIL [exit=$RC want=0]: $1"
        [ -n "$ERR" ] && printf '     stderr: %s\n' "$ERR"
        fail=1
    else
        echo "ok: $1"
    fi
}

assert_blocked() { # $1 = label, $2 = tool_name for the pinned text
    local want
    want=$(block_text "$2")
    if [ "$RC" != 2 ] || [ "$ERR" != "$want" ]; then
        echo "FAIL [exit=$RC want=2 | stderr match=$([ "$ERR" = "$want" ] && echo yes || echo no)]: $1"
        [ -n "$ERR" ] && printf '     stderr: %s\n' "$ERR"
        fail=1
    else
        echo "ok: $1"
    fi
}

assert_no_done() { # $1 = label, $2 = session suffix
    if [ -e "$(done_file "$2")" ]; then
        echo "FAIL: $1 wrote a done marker anyway"
        fail=1
    else
        echo "ok: $1 wrote no done marker"
    fi
}

RMJSON='{"command": "rm -rf /tmp/probe-fixture"}'

# ---- Case 1: not armed → exit 0 even for a would-be-blocked payload --------
disarm idle
run_gate idle Bash "$RMJSON"
assert_allow "no armed marker anywhere for this session: rm passes untouched"

# ---- Case 2: armed → the same payload is blocked (positive control) ---------
arm idle
run_gate idle Bash "$RMJSON"
assert_blocked "armed, uncleared: rm blocked with the pinned text" "Bash"

# ---- Case 3: Read, Grep, Glob pass ------------------------------------------
run_gate idle Read '{"file_path": "/tmp/probe-fixture/x"}'
assert_allow "armed: Read passes"
run_gate idle Grep '{"pattern": "x", "path": "/tmp"}'
assert_allow "armed: Grep passes"
run_gate idle Glob '{"pattern": "*.sh"}'
assert_allow "armed: Glob passes"
run_gate idle WebFetch '{"url": "https://example.invalid/"}'
assert_blocked "unknown tool_name is blocked" "WebFetch"

# ---- Case 4: single-command reader allowlist --------------------------------
for cmd in 'cat /tmp/probe-fixture' 'ls -la' 'pwd' 'date' 'wc -l /tmp/x' \
    'head -n 5 /tmp/x' 'tail /tmp/x' 'grep foo /tmp/x' 'rg foo' \
    'find . -name "*.md"'; do
    run_gate idle Bash "$(jq -nc --arg c "$cmd" '{command: $c}')"
    assert_allow "armed: allowlisted reader passes: $cmd"
done
run_gate idle Bash '{"command": "cat /tmp/a | head -1"}'
assert_blocked "compound Bash (pipe) blocked even with reader halves" "Bash"
run_gate idle Bash "$(jq -nc --arg c "rg 'a|b' /tmp/x" '{command: $c}')"
assert_blocked "pipe character inside quotes still blocks (no shell parser)" "Bash"
run_gate idle Bash '{"command": "sudo cat /tmp/x"}'
assert_blocked "unknown first word (sudo) blocked" "Bash"
# Every compound shape, one case each: deleting a pattern from the gate's
# compound test must redden exactly its own line here.
for shape in 'cat /tmp/a | head -1' 'cat /tmp/a && head -1' 'cat /tmp/a || head -1' \
    'cat /tmp/a; head -1' 'cat /tmp/a > /tmp/y' 'cat /tmp/a < /tmp/y' \
    'cat $(which cat)' 'cat `which cat`' 'cat /tmp/a'$'\n''head -1'; do
    run_gate idle Bash "$(jq -nc --arg c "$shape" '{command: $c}')"
    assert_blocked "compound shape blocked: $(printf '%q' "$shape")" "Bash"
done

# ---- Case 5: git subcommands -------------------------------------------------
for cmd in 'git status' 'git log --oneline -5' 'git diff' 'git show HEAD' \
    'git branch' 'git branch -a' 'git branch -vv' 'git stash list' \
    'git worktree list'; do
    run_gate idle Bash "$(jq -nc --arg c "$cmd" '{command: $c}')"
    assert_allow "armed: allowlisted git passes: $cmd"
done
run_gate idle Bash '{"command": "git push"}'
assert_blocked "git push blocked (arguments changed the verb)" "Bash"
run_gate idle Bash '{"command": "git branch -D x"}'
assert_blocked "git branch -D blocked (writing verb)" "Bash"
run_gate idle Bash '{"command": "git branch -m old new"}'
assert_blocked "git branch -m blocked (writing verb)" "Bash"
run_gate idle Bash '{"command": "git branch --edit-description"}'
assert_blocked "git branch --edit-description blocked (writing verb)" "Bash"
run_gate idle Bash '{"command": "git branch --contains x"}'
assert_blocked "git branch --contains blocked (value-taking flag)" "Bash"
run_gate idle Bash '{"command": "git stash push"}'
assert_blocked "git stash push blocked" "Bash"
run_gate idle Bash '{"command": "git status; rm /tmp/x"}'
assert_blocked "compound git blocked" "Bash"

# ---- Case 6: find acting flags change the verb -------------------------------
for flag in -delete -exec -execdir -ok -okdir -fls -fprint -fprint0 -fprintf; do
    run_gate idle Bash "$(jq -nc --arg c "find . $flag /tmp/out" '{command: $c}')"
    assert_blocked "find $flag blocked (acting flag)" "Bash"
done
run_gate idle Bash '{"command": "find . -name x -exec rm {} +"}'
assert_blocked "find -exec blocked" "Bash"

# ---- Case 7: clear-and-allow via SYG_CONTEXT_BLOCK_CMDS prefix ---------------
arm cmds
SYG_CONTEXT_BLOCK_CMDS='handoff-write --note' \
    run_gate cmds Bash "$(jq -nc --arg c 'handoff-write --note did the handoff' '{command: $c}')"
assert_allow "Bash starting with a CMDS prefix clears and allows"
[ -f "$(done_file cmds)" ] && echo "ok: CMDS clear wrote the done marker" || {
    echo "FAIL: CMDS clear did not write the done marker"
    fail=1
}
arm cmds2
SYG_CONTEXT_BLOCK_CMDS='handoff-write --set:handoff-write --note' \
    run_gate cmds2 Bash '{"command": "xhandoff-write --note nope"}'
assert_blocked "prefix must sit at the start of the command" "Bash"
assert_no_done "non-matching command" "cmds2"
SYG_CONTEXT_BLOCK_CMDS='handoff-write --set:handoff-write --note' \
    run_gate cmds2 Bash '{"command": "echo handoff-write --note nope"}'
assert_blocked "prefix inside the command is not the first word" "Bash"
assert_no_done "echo-wrapped command" "cmds2"

# ---- Case 8: clear-and-allow via SYG_CONTEXT_BLOCK_PATHS glob ----------------
arm paths
SYG_CONTEXT_BLOCK_PATHS='*/handoff-notes/*' \
    run_gate paths Write '{"file_path": "/tmp/probe-fixture/handoff-notes/role.md"}'
assert_allow "Write file_path matching a PATHS glob clears and allows"
[ -f "$(done_file paths)" ] && echo "ok: PATHS clear wrote the done marker" || {
    echo "FAIL: PATHS clear did not write the done marker"
    fail=1
}
arm paths2
SYG_CONTEXT_BLOCK_PATHS='*/handoff-notes/*' \
    run_gate paths2 Edit '{"file_path": "/tmp/probe-fixture/other/role.md"}'
assert_blocked "Edit to a non-matching path blocked" "Edit"
assert_no_done "non-matching Edit" "paths2"
SYG_CONTEXT_BLOCK_PATHS='*/handoff-notes/*' \
    run_gate paths2 NotebookEdit '{"notebook_path": "/tmp/probe-fixture/handoff-notes/role.md"}'
assert_allow "NotebookEdit matching notebook_path clears and allows"
arm me1
SYG_CONTEXT_BLOCK_PATHS='*/handoff-notes/*' \
    run_gate me1 MultiEdit '{"file_path": "/tmp/probe-fixture/handoff-notes/role.md"}'
assert_allow "MultiEdit matching file_path clears and allows"
arm me2
SYG_CONTEXT_BLOCK_PATHS='*/handoff-notes/*' \
    run_gate me2 MultiEdit '{"file_path": "/tmp/probe-fixture/other/role.md"}'
assert_blocked "MultiEdit to a non-matching path blocked" "MultiEdit"
assert_no_done "non-matching MultiEdit" "me2"
arm paths3
# shellcheck disable=SC2088 # the tilde must stay literal: this case pins that it is not expanded
SYG_CONTEXT_BLOCK_PATHS='~/handoff-notes/*' \
    run_gate paths3 Write "$(jq -nc --arg p "$HOME/handoff-notes/role.md" '{file_path: $p}')"
assert_blocked "a tilde in the pattern is NOT expanded (literal glob match)" "Write"
assert_no_done "tilde-pattern write" "paths3"

# ---- Case 9: done marker newer than armed lifts the gate ----------------------
arm cleared
arm cleared2 && touch "$(done_file cleared2)"
run_gate cleared2 Bash "$RMJSON"
assert_allow "done marker newer than armed: gate lifted"

# ---- Case 10: re-arm after clear (armed rewritten newer) re-blocks ------------
touch -d '1 hour ago' "$(done_file cleared2)" 2>/dev/null
run_gate cleared2 Bash "$RMJSON"
assert_blocked "stale done marker older than a re-armed marker blocks again" "Bash"

# ---- Case 11: fail-open shapes ------------------------------------------------
arm fo1
mkdir -p "$TMPDIR_PROBE/nobin"
json=$(jq -nc --arg s "$SESSION_PREFIX-fo1" '{session_id: $s, tool_name: "Bash", tool_input: {command: "rm -rf /tmp/x"}}')
# shellcheck disable=SC2034 # captured only to keep the assertion helpers' shape; fail-open asserts the exit code
OUT=$(printf '%s' "$json" | PATH="$TMPDIR_PROBE/nobin" "$GATE" 2>"$TMPDIR_PROBE/err")
RC=$?
assert_allow "no jq on PATH: fail open, exit 0"
arm fo2
run_gate "" Bash "$RMJSON"
assert_allow "payload without session_id: fail open"
# shellcheck disable=SC2034 # as above: the exit code is the assertion
OUT=$(printf 'this is not json' | "$GATE" 2>"$TMPDIR_PROBE/err")
RC=$?
ERR=$(cat "$TMPDIR_PROBE/err")
assert_allow "unparseable payload: fail open"
run_gate fo2 Bash '{}'
assert_allow "Bash payload without a command: fail open"

# The Case-1 fixture is armed now (reused); leave the trap to clean up.
exit $fail
