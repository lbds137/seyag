#!/bin/bash
# Fixture check for python-heredoc-edit-guard.sh — run after ANY edit to the
# hook. This hook reads no repo state — it decides purely from the command
# text — so the probe needs no fixture repo, only the JSON payload shape
# the PreToolUse hook receives on stdin.
#
# Usage: hooks/python-heredoc-edit-guard.probe.sh   (from anywhere)

set -uo pipefail
# Hooks run here directly, not via run.sh: keep bytecode out of hooks/lib.
export PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$SCRIPT_DIR/python-heredoc-edit-guard.sh"

FAILURES=0

# run <expected-exit> <label> <tool_name> <command>
run() {
  local expected="$1" label="$2" tool="$3" cmd="$4"
  printf '%s' "$cmd" | jq -Rsc --arg t "$tool" '{tool_name:$t,tool_input:{command:.}}' \
    | timeout "${RUN_TIMEOUT:-20}" "$HOOK" >/dev/null 2>&1
  local actual=$?
  if [ "$actual" -eq "$expected" ]; then
    printf 'PASS  (exit %d)  %s\n' "$actual" "$label"
  else
    printf 'FAIL  (exit %d, expected %d)  %s\n' "$actual" "$expected" "$label"
    FAILURES=$((FAILURES + 1))
  fi
}

# --- case 1: python heredoc that edits a file (read, replace, write) → blocks -
CMD1=$(cat <<'CMDEOF'
python3 - <<'EOF'
p = "x.txt"
s = open(p).read()
open(p,'w').write(s.replace("a", "b"))
EOF
CMDEOF
)
run 2 "python heredoc editing a file" "Bash" "$CMD1"

# --- case 1a: writing a NEW file with no read of it → passes -----------------
CMD1A=$(cat <<'CMDEOF'
python3 - <<'EOF'
p = "x.txt"
s = "hello"
open(p,'w').write(s)
EOF
CMDEOF
)
run 0 "python heredoc writing a file it never reads" "Bash" "$CMD1A"

# --- case 1b: reads one file, writes a DIFFERENT derived output → passes -----
# The generation shape seen in real transcripts: input JSON/CSV/source in,
# a /tmp dump or staged copy out.
CMD1B=$(cat <<'CMDEOF'
python3 - "$f" <<'EOF'
import sys
f=sys.argv[1]; t=open(f).read()
t2=t.replace("fee: 1", "fee: 2")
open('/tmp/dec_new.md','w').write(t2); print("staged")
EOF
CMDEOF
)
run 0 "read one file, write a different one" "Bash" "$CMD1B"

# --- case 1c: the sub(p, old, new) helper edit → blocks ----------------------
CMD1C=$(cat <<'CMDEOF'
cd ~/Documents/dev-docs && python3 - <<'EOF'
def sub(p, old, new):
    s = open(p).read(); assert s.count(old) == 1, (p, old[:60]); open(p, 'w').write(s.replace(old, new))
sub('QUICK_REFERENCE.md', 'a', 'b')
EOF
CMDEOF
)
run 2 "sub(p, old, new) helper edit" "Bash" "$CMD1C"

# --- case 1d: Path variable, read_text then write_text → blocks --------------
CMD1D=$(cat <<'CMDEOF'
python3 - <<'EOF'
from pathlib import Path
f=Path("src/extract.py"); t=f.read_text()
t=t.replace("a","b",1); f.write_text(t)
EOF
CMDEOF
)
run 2 "Path var read_text + write_text" "Bash" "$CMD1D"

# --- case 1e: argv target, with-open read then with-open write → blocks ------
CMD1E=$(cat <<'CMDEOF'
python3 - "$F" <<'EOF'
import sys
p = sys.argv[1]
with open(p, encoding='utf-8') as fh:
    s = fh.read()
with open(p, 'w', encoding='utf-8') as fh:
    fh.write(s + "x")
EOF
CMDEOF
)
run 2 "with-open read then write of an argv path" "Bash" "$CMD1E"

# --- case 1f: a heredoc piped to cat that merely MENTIONS open(...) → passes -
# A PR body quoting code: checks 1 and 2 can match on prose, check 3 finds no
# read of the same target.
CMD1F=$(cat <<'CMDEOF'
gh pr edit 1 --body "$(cat <<'EOF'
Replaces the python3 - <<EOF rewrite that did open(out,'w').write(body).
EOF
)"
CMDEOF
)
run 0 "prose mention of an inline write passes" "Bash" "$CMD1F"

# --- case 2: python heredoc, read-only → passes -------------------------------
CMD2=$(cat <<'CMDEOF'
python3 - <<'EOF'
p = "x.txt"
print(open(p).read())
EOF
CMDEOF
)
run 0 "python heredoc read-only" "Bash" "$CMD2"

# --- case 3: node -e editing a file → blocks; writing a new one passes -------
run 2 "node -e readFileSync + writeFileSync edit" "Bash" \
  "node -e \"const fs=require('fs'); fs.writeFileSync('x', fs.readFileSync('x','utf8').replace('a','b'))\""
run 0 "node -e writeFileSync of a new file" "Bash" "node -e \"require('fs').writeFileSync('x','y')\""

# --- case 4: bypass env var → passes despite write shape ----------------------
CMD4=$(cat <<'CMDEOF'
SYG_ALLOW_HEREDOC_EDIT=1 python3 - <<'EOF'
s = open("x.txt").read()
open("x.txt",'w').write(s + "hello")
EOF
CMDEOF
)
run 0 "SYG_ALLOW_HEREDOC_EDIT=1 bypasses" "Bash" "$CMD4"

# --- case 4a: legacy TZUROT_ALLOW_HEREDOC_EDIT=1 still bypasses (transition) --
run 0 "legacy TZUROT_ALLOW_HEREDOC_EDIT=1 bypasses" "Bash" "${CMD4/SYG_/TZUROT_}"

# --- case 4b: quote-adjacent mention of the bypass literal does NOT bypass -----
# The anchor requires whitespace after `=1`, so a mention hugged by quotes or
# punctuation cannot bypass. (A prose mention with spaces on both sides still
# would — inherent to flat-string matching; the anchor narrows, not perfects.)
CMD4B=$(cat <<'CMDEOF'
python3 - <<'EOF'
s = open("x.txt").read()
open("x.txt",'w').write(s + "prefix with 'SYG_ALLOW_HEREDOC_EDIT=1'.")
EOF
CMDEOF
)
run 2 "quote-adjacent bypass literal still blocks" "Bash" "$CMD4B"

# --- case 5: plain shell redirect → passes (not this hook's business) --------
run 0 "echo > file redirect passes" "Bash" "echo hi > /tmp/x"

# --- case 6: python -c, read-only → passes ------------------------------------
run 0 "python3 -c read-only" "Bash" "python3 -c \"print(open('a').read())\""

# --- case 7: tool_name = Edit → passes (not Bash) -----------------------------
run 0 "tool_name=Edit passes" "Edit" "python3 - <<'EOF'\nopen('x','w')\nEOF"

# --- case 8: Path(...).open('w') after Path(...).read_text() → blocks ---------
CMD8=$(cat <<'CMDEOF'
python3 - <<'EOF'
from pathlib import Path
s = Path("x.txt").read_text()
Path("x.txt").open('w').write(s + "hello")
EOF
CMDEOF
)
run 2 "Path(...).open('w') edit blocks" "Bash" "$CMD8"

# --- case 9: keyword-arg open(path, mode='w') after a read → blocks ------------
CMD9=$(cat <<'CMDEOF'
python3 - <<'EOF'
s = open("x.txt").read()
f = open("x.txt", mode='w')
f.write(s + "hello")
EOF
CMDEOF
)
run 2 "open(path, mode='w') edit blocks" "Bash" "$CMD9"

# --- case 10: append to a log it never reads → passes ------------------------
CMD10=$(cat <<'CMDEOF'
python3 - <<'EOF'
open("run.log", "a").write("done\n")
EOF
CMDEOF
)
run 0 "append-only log write passes" "Bash" "$CMD10"

# --- cases 11-13: bodies past Linux's 128 KiB env-string cap, shaped to hit --
# the three formerly super-linear regex paths (must block fast, not stall).
DOTRUN=$(printf 'abc.%.0s' $(seq 1 50000))
CMD11=$(cat <<CMDEOF
python3 - <<'EOF'
$DOTRUN
p="x.txt"; s=open(p).read(); open(p,"w").write(s)
EOF
CMDEOF
)
run 2 "200 KB dotted run blocks fast" "Bash" "$CMD11"

SPACES150K=$(printf '%*s' 150000 '')
CMD12=$(cat <<CMDEOF
python3 - <<'EOF'
open(${SPACES150K}x
p="x.txt"; s=open(p).read(); open(p,"w").write(s)
EOF
CMDEOF
)
run 2 "whitespace run after open( blocks fast" "Bash" "$CMD12"

CMD13=$(cat <<CMDEOF
python3 - <<'EOF'
open(a${SPACES150K}x
p="x.txt"; s=open(p).read(); open(p,"w").write(s)
EOF
CMDEOF
)
run 2 "whitespace run after an open( argument blocks fast" "Bash" "$CMD13"

CMD14="echo \"python${SPACES150K}x\""
run 0 "long space run after python passes fast" "Bash" "$CMD14"

# --- cases 15-: interpreter options between the name and the inline marker ----
# BODY is a read-modify-write of f.txt; each row must reach check 3 (the same
# target is read and written), so an exit 2 proves the option form was caught.
BODY="p=open('f.txt').read(); open('f.txt','w').write(p)"
run 2 "python3 -I - heredoc (option before stdin dash)" "Bash" "$(printf "python3 -I - <<'E'\n%s\nE" "$BODY")"
run 2 "python3 -I -c inline body" "Bash" "python3 -I -c \"$BODY\""
run 2 "python3 -B -c inline body" "Bash" "python3 -B -c \"$BODY\""
run 2 "python3 -I stdin heredoc with no dash" "Bash" "$(printf "python3 -I <<'E'\n%s\nE" "$BODY")"
run 2 "python3 -IB -c (combined short options)" "Bash" "python3 -IB -c \"$BODY\""
run 2 "python3 -Ic (option cluster ending in c)" "Bash" "python3 -Ic \"$BODY\""
run 2 "python3 -X utf8 -I -c (-X takes a value)" "Bash" "python3 -X utf8 -I -c \"$BODY\""
run 2 "python3 -Xpycache_prefix=/x -c (-X joined value)" "Bash" "python3 -Xpycache_prefix=/x -c \"$BODY\""
run 2 "python3.12 -c (versioned name)" "Bash" "python3.12 -c \"$BODY\""
run 2 "/usr/bin/python3 -I -c (path-prefixed name)" "Bash" "/usr/bin/python3 -I -c \"$BODY\""
run 2 "python -W ignore -c (bare name, -W takes a value)" "Bash" "python -W ignore -c \"$BODY\""
run 2 "node --no-warnings -e readFileSync+writeFileSync edit" "Bash" \
  "node --no-warnings -e \"const fs=require('fs'); fs.writeFileSync('f.txt', fs.readFileSync('f.txt','utf8'))\""
run 2 "node -r x -e readFileSync+writeFileSync edit" "Bash" \
  "node -r x -e \"const fs=require('fs'); fs.writeFileSync('f.txt', fs.readFileSync('f.txt','utf8'))\""
run 2 "node -p readFileSync+writeFileSync edit (-p counts like -e)" "Bash" \
  "node -p \"const fs=require('fs'); fs.writeFileSync('f.txt', fs.readFileSync('f.txt','utf8'))\""
run 2 "node -pe readFileSync+writeFileSync edit (-pe is an eval)" "Bash" \
  "node -pe \"const fs=require('fs'); fs.writeFileSync('f.txt', fs.readFileSync('f.txt','utf8'))\""
run 2 "node --max-old-space-size 4096 -e edit (numeric-valued option)" "Bash" \
  "node --max-old-space-size 4096 -e \"const fs=require('fs'); fs.writeFileSync('f.txt', fs.readFileSync('f.txt','utf8'))\""
run 2 "node --eval=BODY readFileSync+writeFileSync edit (--eval= joined value)" "Bash" \
  "node --eval=\"const fs=require('fs'); fs.writeFileSync('f.txt', fs.readFileSync('f.txt','utf8'))\""
run 2 "node --print=BODY readFileSync+writeFileSync edit (--print= joined value)" "Bash" \
  "node --print=\"const fs=require('fs'); fs.writeFileSync('f.txt', fs.readFileSync('f.txt','utf8'))\""
run 2 "python3 -I<<'E' heredoc edit (no space before <<)" "Bash" "$(printf "python3 -I<<'E'\n%s\nE" "$BODY")"
run 2 "python3.12t -c edit (free-threaded name)" "Bash" "python3.12t -c \"$BODY\""
# -X/-W value joined to the heredoc opener: the value must end at <<, not swallow it.
run 2 "python3 -X utf8<<'E' heredoc edit (unspaced -X value)" "Bash" "$(printf "python3 -X utf8<<'E'\n%s\nE" "$BODY")"
run 2 "python3 -W ignore<<'E' heredoc edit (unspaced -W value)" "Bash" "$(printf "python3 -W ignore<<'E'\n%s\nE" "$BODY")"
run 2 "python3 -X utf8 <<'E' heredoc edit (spaced control)" "Bash" "$(printf "python3 -X utf8 <<'E'\n%s\nE" "$BODY")"

# Exit 0: the option-shaped text is not an inline script, or the write is not
# in the interpreter's own body.
run 0 "python3 -m mod -c cfg; echo body (-m is a module, not an option)" "Bash" \
  "python3 -m tool -c cfg; echo \"$BODY\""
run 0 "python3 -I script.py; echo body (script file, not inline)" "Bash" \
  "python3 -I script.py; echo \"$BODY\""
run 0 "node script.js -e; echo body (script file, not inline)" "Bash" \
  "node script.js -e; echo \"fs.writeFileSync('f.txt', fs.readFileSync('f.txt','utf8'))\""

# Fast rows: a long option run or a long -X value must not backtrack past the
# 20 s timeout (exit 0 = allowed, finished in time).
DASHI=$(printf -- '-I %.0s' $(seq 1 20000))
A200K=$(head -c 200000 /dev/zero | tr '\0' 'a')
run 0 "python3 followed by 20000 repetitions of -I then x: fast" "Bash" "python3 ${DASHI}x"
run 0 "python3 -X then 200 KB value then q: fast" "Bash" "python3 -X ${A200K} q"
# Chain rows: 200 KB of interpreter names with value-taking options. Each name
# restarts a grep match, so an unbounded option run goes quadratic here. Bounded,
# the hook takes ~0.1 s on each; unbounded, 10-16 s (measured 11-17), so these
# rows get a 5 s timeout: the default 20 s would pass the quadratic form too.
CHAIN_PY=$(printf 'python -X %.0s' $(seq 1 20000))
CHAIN_NODE=$(printf 'node -r %.0s' $(seq 1 25000))
RUN_TIMEOUT=5 run 0 "chain row: 200 KB of 'python -X ' then x: fast" "Bash" "${CHAIN_PY}x"
RUN_TIMEOUT=5 run 0 "chain row: 200 KB of 'node -r ' then x: fast" "Bash" "${CHAIN_NODE}x"

exit $FAILURES
