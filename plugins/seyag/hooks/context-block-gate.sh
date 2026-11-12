#!/bin/bash
# Context block gate (PreToolUse, wired matcher-less: sees every tool call).
#
# The soft context-size reminder demonstrably does not self-execute at long
# context (the reminder's own header says why it exists), so a session that
# crosses the hard tier (SYG_CONTEXT_BLOCK) gets a mandatory handoff instead
# of a nag: context-size-reminder.sh (UserPromptSubmit) arms this gate by
# writing a state marker, and while armed-and-uncleared every tool call that
# is not the handoff write itself — and not an unambiguous reader — is blocked
# here until ONE handoff write lands: a Bash command starting with a
# SYG_CONTEXT_BLOCK_CMDS prefix, or a Write/Edit/NotebookEdit whose file_path
# matches a SYG_CONTEXT_BLOCK_PATHS glob. That write creates the done marker
# (context-block-done-<session>, newer than the armed marker) and the session
# runs free for the rest of its length. The arm side lives in
# context-size-reminder.sh; this hook only enforces what it armed.
#
# Hot path: this runs on every tool call of every session on the machine, and
# two early exits keep it cheap. Tier off (SYG_CONTEXT_BLOCK unset or
# non-numeric, or both clear lists empty) exits before any fork — the whole
# gate is one bash process, which is also the never-opted-in case. Tier on but
# nobody armed: one builtin glob over the state dir, no jq, no forks. Note the
# glob matches done and note markers too (same context-block-* prefix), so the
# jq path stays live until session-start prunes the family even after every
# session cleared; that documented steady state is the price of the prefix.
#
# Bash policy while armed is deliberately conservative (the friction window
# ends at the first handoff write; there is no shell parser here):
# - Read, Grep and Glob pass.
# - A Bash command passes only as a SINGLE command whose first word is cat,
#   ls, pwd, date, wc, head, tail, grep, rg or find (find only without its
#   acting flags), or git with only status, log, diff, show, branch (bare or
#   listing flags only, the same read-only forms cwd-drift-guard allows),
#   stash list or worktree list. A command string containing any of
#   | & ; > < $( or a backtick or newline — compound commands included — is
#   blocked even when both halves are readers and even inside quotes.
# - SYG_CONTEXT_BLOCK_PATHS globs are matched literally with bash [[ == ]],
#   extglob off: one glob pattern per colon-separated entry, no ~ or $HOME
#   expansion, so machine config writes absolute patterns. A file_path
#   containing /../ is refused before matching: a glob's * crosses /, so
#   /x/handoffs/* would otherwise clear on a write to
#   /x/handoffs/../../elsewhere.
# - The SYG_CONTEXT_BLOCK_CMDS match is a literal prefix with no word
#   boundary, and a matching compound command clears AND runs whole —
#   operator-config trust, deliberate: the machine sets its own prefixes.
# - The clear fires on the ATTEMPTED write: PreToolUse runs before the
#   permission decision, so a handoff write that is itself denied still
#   clears (accepted fail-open; a landed-write promotion would be a
#   PostToolUse follow-up).
# - Every other tool_name, including unknown ones, is blocked.
#
# Known bound: the armed/cleared decision compares marker mtimes, so on a
# filesystem with 1-second mtime granularity a done marker written within the
# same second as the armed marker can read as not-newer (ns-granularity
# timestamps on modern Linux tmpfs/ext4, the real environment, do not).
#
# Fail-open everywhere: no jq, no session_id or tool_name in the payload, a
# state dir that is not this user's, an unparsable payload — exit 0. A gate
# that cannot decide must not block.

set -uo pipefail

# Drain stdin before any early exit: a caller writing a large payload down the
# pipe (>64KiB pipe buffer) gets SIGPIPE — and, under the caller's pipefail, a
# nonzero exit that reads as a block — if this hook exits without consuming it.
# run.sh's own skip paths drain the same way. `read -d ''` is a builtin, so
# this stays fork-free on the every-tool-call path.
IFS= read -r -d '' INPUT || true

# Tier-off fails open BEFORE any marker work: an operator unsetting
# SYG_CONTEXT_BLOCK — or emptying both clear lists, the same condition the
# reminder refuses to arm under — must release an armed session at once; the
# gate would otherwise keep blocking on stale markers until the prune, and rm
# itself is blocked. Same non-numeric rule and empty-list idiom as the
# reminder.
BLOCK_THRESHOLD=${SYG_CONTEXT_BLOCK:-}
case "$BLOCK_THRESHOLD" in '' | *[!0-9]*) exit 0 ;; esac
BLOCK_CMDS=${SYG_CONTEXT_BLOCK_CMDS:-}
BLOCK_PATHS=${SYG_CONTEXT_BLOCK_PATHS:-}
if [ -z "${BLOCK_CMDS//:/}" ] && [ -z "${BLOCK_PATHS//:/}" ]; then
    exit 0
fi

# SYG_STATE_DIR relocates the marker family (session-start prunes it there);
# $UID instead of $(id -u) keeps even the armed path fork-free here.
STATE_DIR="${SYG_STATE_DIR:-/tmp/claude-$UID}"

# O(1) absent path: with nullglob off, an unmatched glob stays literal and the
# -e test fails, so a machine where no session ever armed costs one builtin
# and nothing else. A done marker alone never exists without an armed one.
set -- "$STATE_DIR"/context-block-*
[ -e "$1" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

# One jq for both fields (was two jq forks plus a tr): the session id is
# folded to the safe set inside jq — it reaches a filesystem path, so anything
# outside it becomes `_` (same fold as context-size-reminder.sh) — and the
# tool name needs no folding.
ROW=$(jq -r '[(.session_id // "" | gsub("[^A-Za-z0-9._-]"; "_")), (.tool_name // "")] | @tsv' <<<"$INPUT" 2>/dev/null) || ROW=""
IFS=$'\t' read -r SAFE_SESSION TOOL <<<"$ROW"
[ -n "$SAFE_SESSION" ] && [ -n "$TOOL" ] || exit 0

ARMED="$STATE_DIR/context-block-$SAFE_SESSION"
DONE="$STATE_DIR/context-block-done-$SAFE_SESSION"

[ -f "$ARMED" ] || exit 0
# The state dir path is predictable on a shared /tmp; trust markers only
# inside a directory this user owns, and only write through a non-symlink
# done marker (the same squat/symlink-plant hardening the reminder applies).
[ ! -L "$STATE_DIR" ] || exit 0
[ -O "$STATE_DIR" ] || exit 0
[ ! -L "$DONE" ] || exit 0
if [ -f "$DONE" ] && [ "$DONE" -nt "$ARMED" ]; then
    exit 0
fi

block() {
    echo "context-block-gate: blocked $TOOL until the context handoff is written (SYG_CONTEXT_BLOCK active; one write to a SYG_CONTEXT_BLOCK_PATHS path or a SYG_CONTEXT_BLOCK_CMDS command lifts it)" >&2
    exit 2
}

# One handoff write lifts the block for the rest of the session.
clear_and_allow() {
    printf '%s\n' "$(date +%s)" >"$DONE" 2>/dev/null || true
    exit 0
}

# match_paths PATH: 0 when PATH matches any SYG_CONTEXT_BLOCK_PATHS glob.
# `read -a` splits on colons without pathname expansion, so a pattern entry
# like * is never globbed against the cwd; empty entries are skipped. The
# `${arr[@]+"${arr[@]}"}` guards keep an empty list from reading as an unbound
# variable under `set -u` on bash < 4.4 (run.sh uses the same idiom).
match_paths() {
    local path=$1 pat
    local IFS=:
    read -r -a PATS <<<"${SYG_CONTEXT_BLOCK_PATHS:-}"
    for pat in "${PATS[@]+"${PATS[@]}"}"; do
        [ -n "$pat" ] || continue
        # shellcheck disable=SC2053 # the entry IS the glob pattern, unquoted by design
        [[ $path == $pat ]] && return 0
    done
    return 1
}

# match_cmds COMMAND: 0 when COMMAND starts with any SYG_CONTEXT_BLOCK_CMDS
# prefix (literal prefix match; the prefix is quoted, so no pattern reading).
match_cmds() {
    local cmd=$1 pref
    local IFS=:
    read -r -a PREFS <<<"${SYG_CONTEXT_BLOCK_CMDS:-}"
    for pref in "${PREFS[@]+"${PREFS[@]}"}"; do
        [ -n "$pref" ] || continue
        [[ $cmd == "$pref"* ]] && return 0
    done
    return 1
}

# branch_read_only REST: 0 when every word after `git branch` is a read-only
# listing flag (or REST is empty — a bare `git branch`); combined short flags
# and value-taking forms (-D, -m, --contains X, --edit-description …) fail.
# Same list as cwd-drift-guard's BRANCH_LIST_FLAGS.
branch_read_only() {
    local w bad=0
    read -r -a BWORDS <<<"$1"
    for w in "${BWORDS[@]+"${BWORDS[@]}"}"; do
        case "$w" in
            -a | --all | -r | --remotes | -l | --list | --show-current | -v | -vv | --verbose) ;;
            *) bad=1 ;;
        esac
    done
    [ "$bad" = 0 ]
}

case "$TOOL" in
    Read | Grep | Glob)
        exit 0
        ;;
    Write | Edit | MultiEdit | NotebookEdit)
        # NotebookEdit carries its target as notebook_path, not file_path.
        FILE=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$INPUT" 2>/dev/null) || FILE=""
        if [ -n "$FILE" ]; then
            case "$FILE" in
                *'/../'*) ;; # a dotdot walk must never clear, glob or no glob
                *)
                    match_paths "$FILE" && clear_and_allow
                    ;;
            esac
        fi
        block
        ;;
    Bash)
        CMD=$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null) || CMD=""
        [ -n "$CMD" ] || exit 0 # a Bash payload without a command is malformed
        if match_cmds "$CMD"; then
            clear_and_allow
        fi
        # Compound shapes first, before any allowlist: one of these characters
        # anywhere in the string (quotes included — there is no parser) means
        # the command is not a single verb.
        case "$CMD" in
            *'|'* | *'&'* | *';'* | *'>'* | *'<'* | *'$('* | *'`'* | *'
'*) block ;;
        esac
        read -r W1 W2 REST <<<"$CMD"
        case "$W1" in
            cat | ls | pwd | date | wc | head | tail | grep)
                exit 0
                ;;
            rg)
                # rg's --pre* flags run a pre-processor command; the reader
                # is only a reader without them. W2 joins the scan: the
                # first flag lands there, not in REST.
                read -r -a RGWORDS <<<"$W2 $REST"
                for W in "${RGWORDS[@]+"${RGWORDS[@]}"}"; do
                    case "$W" in
                        --pre*) block ;;
                    esac
                done
                exit 0
                ;;
            find)
                # find is a reader except for its acting flags — the same
                # "arguments must not change the verb" rule as git below.
                # `read -a` splits without pathname expansion, so a `*`
                # word stays a literal word (an unquoted for-split would
                # glob it against the cwd).
                read -r -a FWORDS <<<"$CMD"
                for W in "${FWORDS[@]+"${FWORDS[@]}"}"; do
                    case "$W" in
                        -delete | -exec | -execdir | -ok | -okdir | -fls | -fprint | -fprint0 | -fprintf) block ;;
                    esac
                done
                exit 0
                ;;
            git)
                case "$W2" in
                    status | log | diff | show)
                        # --output* turns the reader into a writer.
                        read -r -a GWORDS <<<"$REST"
                        for W in "${GWORDS[@]+"${GWORDS[@]}"}"; do
                            case "$W" in
                                --output*) block ;;
                            esac
                        done
                        exit 0
                        ;;
                    # Read-only forms of a writing verb: bare or listing
                    # flags only (BRANCH_LIST_FLAGS above).
                    branch)
                        branch_read_only "$REST" && exit 0
                        block
                        ;;
                esac
                case "$W2 ${REST%% *}" in
                    'stash list' | 'worktree list') exit 0 ;;
                esac
                block
                ;;
        esac
        block
        ;;
    *)
        block
        ;;
esac
