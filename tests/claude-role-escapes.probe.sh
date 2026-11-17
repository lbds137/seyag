#!/bin/bash
# Fixture check for bin/claude-role frontmatter value escaping: --set writes status/holds/parked as
# JSON strings (json.dumps escapes backslash, quote, newline, tab), and field() must read every one
# back exactly — a ONE-pass unescape, since sequential gsub calls would turn "\\n" (an escaped
# backslash then n) into a newline. Single-quoted values map YAML's '' to '. Line-oriented callers
# (the board, --list's TSV) flatten a newline to a space; --json keeps the value whole.
# Usage: tests/claude-role-escapes.probe.sh   (from anywhere)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CR="$REPO/plugins/seyag/bin/claude-role"
[ -x "$CR" ] || { echo "FAIL  $CR is not executable (chmod +x it)"; exit 1; }
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; }

unset CLAUDE_PID SYG_ROLE_CONTEXT_LINE SYG_ROLE_PREAMBLE_FILE SYG_NEEDS_OWNER_SECTION SYG_IN_PERSON_SECTION \
      SYG_ROLE_CONTEXT_CMD SYG_ROUTE_SHOW_CMD SYG_ROLE_HEADLESS_ROUTES SYG_ROLE_HEADLESS SYG_ROLE_TASK
export SYG_CONFIG=0

home=$(mktemp -d "${TMPDIR:-/tmp}/claude-role-esc.XXXXXX")
trap 'rm -rf "$home"' EXIT
roles="$home/roles"
mkdir -p "$roles"
export SYG_ROLE_DIR="$roles"

# Round-trip through the real --set (json.dumps on write) and --json (jq --arg on read): each value
# must come back byte-for-byte. 'a\\b' is two literal backslashes; '\n literal' is backslash then n;
# the tab and the last value are the real characters.
role="$roles/esc.md"
printf -- '---\nmetadata:\n  role: "Esc role"\n  status: "start"\n---\n' > "$role"
values=(
    'C:\path\to'
    'say "hi"'
    'a\\b'
    'ends with \'
    "tab"$'\t'"here"
    '\n literal'
    'plain'
    'emoji 🙂 and — dash'
    $'two\nlines'
)
for v in "${values[@]}"; do
    "$CR" --set status="$v" --file "$role" >/dev/null \
        || { bad "--set refused $(printf %q "$v")"; continue; }
    got=$("$CR" --json | jq -r --arg f esc.md '.roles[] | select(.file == $f) | .status')
    [ "$got" = "$v" ] && ok "round-trip $(printf %q "$v")" \
                      || bad "round-trip $(printf %q "$v") -> $(printf %q "$got")"
done
# holds rides the same field() path; one escape-heavy value pins it.
"$CR" --set holds='C:\path\to' --file "$role" >/dev/null
got=$("$CR" --json | jq -r --arg f esc.md '.roles[] | select(.file == $f) | .holds')
[ "$got" = 'C:\path\to' ] && ok "holds round-trips too" || bad "holds: $(printf %q "$got")"

# The board: one block per role, status on a single line (a newline in the value becomes a space).
"$CR" --set status=$'two\nlines' --file "$role" >/dev/null
out=$("$CR" --board)
grep -qxF '    status: two lines' <<< "$out" && ok "--board flattens a newline in status" \
    || bad "--board status line: $(grep 'status:' <<< "$out")"
"$CR" --set status='C:\path\to' --file "$role" >/dev/null
grep -qxF '  status: "C:\\path\\to"' "$role" && ok "--set writes the JSON-escaped form" \
    || bad "on-disk form: $(grep 'status:' "$role")"
out=$("$CR" --board)
grep -qxF '    status: C:\path\to' <<< "$out" && ok "--board shows one backslash, not doubled" \
    || bad "--board backslash: $(grep 'status:' <<< "$out")"
[ "$(grep -c '^Esc role  (esc.md, ' <<< "$out")" = 1 ] && ok "--board keeps one block per role" \
    || bad "--board blocks: $out"

# --list's TSV: newline and tab in a value become spaces, one row per role.
"$CR" --set parked=$'a\nb' --file "$role" >/dev/null
out=$("$CR" --list)
grep -qxF $'esc\tEsc role\ta b\t\t' <<< "$out" && ok "--list flattens a newline parked value" \
    || bad "--list parked: $out"
[ "$(grep -c '' <<< "$out")" = 1 ] && ok "--list stays one row per role" || bad "--list rows: $out"

# Hand-written styles --set never writes: YAML single quotes ('' -> '), and an escape json.dumps
# never emits, kept as both characters.
cat > "$roles/quote.md" <<'EOF'
---
role: "Quote role"
status: 'it''s fine'
---
EOF
cat > "$roles/raw.md" <<'EOF'
---
role: "Raw role"
status: "\q stay"
holds: "a\/b"
---
EOF
got=$("$CR" --json | jq -r --arg f quote.md '.roles[] | select(.file == $f) | .status')
[ "$got" = "it's fine" ] && ok "single-quoted '' reads back as '" || bad "single-quoted: $(printf %q "$got")"
got=$("$CR" --json | jq -r --arg f raw.md '.roles[] | select(.file == $f) | .status')
[ "$got" = '\q stay' ] && ok "unknown escape kept as-is" || bad "unknown escape: $(printf %q "$got")"
got=$("$CR" --json | jq -r --arg f raw.md '.roles[] | select(.file == $f) | .holds')
[ "$got" = 'a/b' ] && ok "\\/ reads back as /" || bad "\\/: $(printf %q "$got")"

echo "claude-role-escapes probe: $pass passed, $fail failed"
[ "$fail" = 0 ]
