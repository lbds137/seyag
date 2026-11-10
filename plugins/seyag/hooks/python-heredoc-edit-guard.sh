#!/bin/bash
# PreToolUse hook (matcher: Bash) — blocks an inline interpreter script (a
# `python3 -c`/heredoc invocation, or `node -e`/`--eval`) that EDITS a file,
# in favor of the Edit tool or a dispatched worker
# (the seyag rules, rules/core.md).
#
# A fresh rewrite-script pays its whole body as output tokens on every edit
# and bypasses edit tracking, unlike the Edit tool's diff-only cost. Plain
# shell redirects (`echo > file`) are explicitly NOT this hook's business —
# only an interpreter invocation whose own body edits a file blocks.
#
# Three checks must ALL match for a block:
#   1. an interpreter-script invocation shape (python -c/-, a heredoc into
#      python, or node -e/--eval)
#   2. a file-write call shape inside the command text (open(...,'w'/'a'),
#      write_text/write_bytes, writeFileSync/appendFileSync)
#   3. some write target is also READ in the script, compared as the
#      whitespace-stripped target expression (`open(p)` … `open(p,'w')`,
#      `f.read_text()` … `f.write_text(`). That read-modify-write shape is
#      what an edit looks like; a script that reads inputs and writes a
#      DIFFERENT output is generation and passes. Measured on this machine's
#      transcripts (2026-09-25): of 944 commands that matched checks 1 and 2,
#      798 were read-modify-write edits and 144 wrote derived output (/tmp
#      dumps, staged copies, generated docs). An edit that reaches the same
#      file through two different expressions is a known accepted miss.
#
# Checks 1 and 2 are `grep -P` (PCRE), so the common case never spawns python;
# check 3 runs python only when both match. Fail-open on any internal error
# (grep -P or python3 unavailable, empty input, etc.) — a broken gate must not
# block real work. Checks 1 and 3 are linear-time (a 200 KB command costs
# milliseconds; before, a long space, dotted or other whitespace run stalled it).
#
# Bypass for deliberate bulk generation:
#
#   SYG_ALLOW_HEREDOC_EDIT=1 <command>
#
# The older legacy name TZUROT_ALLOW_HEREDOC_EDIT=1 is still accepted
# (Tzurot compatibility).
#
# Fixture check: run hooks/python-heredoc-edit-guard.probe.sh after
# ANY edit to this hook.

set -uo pipefail

INPUT=$(cat)

TOOL_NAME=$(jq -r '.tool_name // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ "$TOOL_NAME" != "Bash" ] && exit 0

GUARD_CMD=$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ -z "$GUARD_CMD" ] && exit 0

# Anchored to an assignment position (start of string, or after whitespace,
# `;`, `&`, `|`) and followed by whitespace — a quote- or punctuation-adjacent
# mention of the literal cannot bypass. A prose mention with whitespace on both
# sides still can; flat-string matching cannot close that, only narrow it.
BYPASS_RE='(^|[[:space:];&|])(SYG|TZUROT)_ALLOW_HEREDOC_EDIT=1[[:space:]]'
if [[ "$GUARD_CMD" =~ $BYPASS_RE ]]; then
  exit 0
fi

# `grep -P` failing for a reason OTHER than "no match" (e.g. PCRE support
# missing) must not be mistaken for "no match" — capture the exit status
# rather than relying on `&&`/`||` short-circuiting alone.
INTERP_RE='python3?\s+(-c\b|-\s|-$)|python3?\s*(?:-\s*)?<<|node\s+(-e|--eval)\b'
WRITE_RE="open\([^)]*,\s*['\"][wa]|\.open\(\s*['\"][wa]|mode\s*=\s*['\"][wa]|write_text\(|write_bytes\(|writeFileSync\(|appendFileSync\("

grep -Pq "$INTERP_RE" <<<"$GUARD_CMD" 2>/dev/null
INTERP_RC=$?
grep -Pq "$WRITE_RE" <<<"$GUARD_CMD" 2>/dev/null
WRITE_RC=$?

# grep exit codes: 0 = match, 1 = no match, 2 = error (bad pattern, no PCRE
# support). Only a clean double-match (both 0) blocks; anything else,
# including a grep error on either side, falls through to allow.
if [ "$INTERP_RC" -ne 0 ] || [ "$WRITE_RC" -ne 0 ]; then
  exit 0
fi

# Check 3. Prints the edited target(s) on a read-modify-write, nothing
# otherwise; any python failure leaves EDITED empty, which allows.
# The command goes to python on fd 3, never through the environment: Linux
# caps one env string at 128 KiB (MAX_ARG_STRLEN), and python failing to
# exec would fail open.
EDITED=$(python3 - 3<<<"$GUARD_CMD" 2>/dev/null <<'PYEOF'
import os, re

cmd = os.fsdecode(open(3, "rb").read()).removesuffix("\n")
# First call argument, allowing one level of nested parentheses (Path("x"),
# os.path.join(a, b)); OBJ is the receiver of a method call (p, Path("x")).
# ARG is atomic (lookahead+backreference, portable below 3.11), so a consumed
# argument is never re-split, and it absorbs surrounding whitespace, which
# the target comparison strips anyway. OBJ starts only at the start of a
# [\w.] run, scanning a long run once instead of from every position; results
# match the un-anchored form except after a match ending mid-run (degenerate,
# not valid Python).
ARG = r"(?=((?:[^(),]|\([^()]*\))+))\1"
OBJ = r"(?<![\w.])([\w.]+(?:\([^()]*\))?)"
WRITES = [
    r"\bopen\(" + ARG + r"""\s*,\s*(?:mode\s*=\s*)?[rbu]?['"][wa]""",
    OBJ + r"\.write_(?:text|bytes)\(",
    OBJ + r"""\.open\(\s*(?:mode\s*=\s*)?['"][wa]""",
    r"\b(?:writeFileSync|appendFileSync)\(" + ARG + r"\s*,",
]
READS = [
    r"\bopen\(" + ARG + r"""\s*(?:\)|,\s*(?:encoding|errors|newline)\b|,\s*(?:mode\s*=\s*)?[rbu]?['"]r)""",
    OBJ + r"\.read_(?:text|bytes)\(",
    OBJ + r"""\.open\(\s*(?:\)|(?:mode\s*=\s*)?['"]r)""",
    r"\breadFileSync\(" + ARG + r"\s*[,)]",
]

def targets(patterns):
    return {re.sub(r"\s+", "", m.group(1)) for p in patterns for m in re.finditer(p, cmd)}

print("\n".join(sorted(targets(WRITES) & targets(READS))))
PYEOF
)

[ -n "$EDITED" ] || exit 0

cat >&2 <<'EOF'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PYTHON-HEREDOC EDIT GUARD — inline script rewrites a file it reads
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
A fresh rewrite-script pays its whole body as output tokens every
time (measured ~7x the Edit tool per edit) and bypasses edit
tracking. Use the Edit tool (Read the file first: Edit refuses one
this conversation hasn't Read), or dispatch the unit to a worker.

Deliberate bulk generation: prefix the command with
SYG_ALLOW_HEREDOC_EDIT=1 to pass this gate.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
exit 2
