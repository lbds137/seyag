#!/bin/bash
# Fixture check for dispatch-spec-ledger-gate.sh — run after ANY edit to the hook.
#
# Builds a throwaway CLAUDE_PROJECT_DIR fixture and exercises all three checks:
#   1. Named spec file presence (default .claude/dispatch/*.md scope + SYG_DISPATCH_SPEC_RE)
#   2. Inline prompt presence when no path resolves and isolation == "worktree"
#   3. Premise ledger citation check (non-empty bullet rows, backtick or slash-path cite)
#
# Usage: bash plugins/seyag/hooks/dispatch-spec-ledger-gate.probe.sh   (from anywhere)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$SCRIPT_DIR/dispatch-spec-ledger-gate.sh"

# Hermetic: ignore any ambient SYG_DISPATCH_SPEC_* or HOME from the caller's environment.
unset SYG_DISPATCH_SPEC_RE SYG_DISPATCH_SPEC_INLINE HOME

TMPDIR_PROBE=$(mktemp -d)
cleanup() {
  chmod -R u+rwX "$TMPDIR_PROBE" 2>/dev/null || true
  rm -rf "$TMPDIR_PROBE"
}
trap cleanup EXIT

FIXTURE="$TMPDIR_PROBE/fixture"
ELSEWHERE="$TMPDIR_PROBE/elsewhere"
mkdir -p "$FIXTURE/.claude/dispatch" "$FIXTURE/specs" "$ELSEWHERE" "$TMPDIR_PROBE/home/.claude/dispatch"

# Pinned headlines
# shellcheck disable=SC2016
HEADLINE_MISSING='DISPATCH SPEC — no `## Premise ledger` section'
# shellcheck disable=SC2016
HEADLINE_MISSING_INLINE='DISPATCH SPEC — no `## Premise ledger` section (inline prompt)'
# shellcheck disable=SC2016
HEADLINE_EMPTY='DISPATCH SPEC — premise ledger section has no `- ` bullet rows'
HEADLINE_UNCITED='DISPATCH SPEC — premise row without a citation'

FAILURES=0
ERR=""

# agent_payload <prompt> [isolation] [tool_name]
agent_payload() {
  local prompt="$1" iso="${2:-}" tool="${3:-Agent}"
  if [ -n "$iso" ]; then
    jq -cn --arg t "$tool" --arg p "$prompt" --arg i "$iso" \
      '{tool_name:$t,tool_input:{prompt:$p,isolation:$i}}'
  else
    jq -cn --arg t "$tool" --arg p "$prompt" \
      '{tool_name:$t,tool_input:{prompt:$p}}'
  fi
}

# run <expected-exit> <label> <payload-json> [project_dir] [spec_re] [expected_stderr_substring] [inline_opt] [home_opt]
# spec_re: `-` means unset SYG_DISPATCH_SPEC_RE; any other string sets SYG_DISPATCH_SPEC_RE.
# inline_opt: `-` (default) means unset SYG_DISPATCH_SPEC_INLINE; any other string sets SYG_DISPATCH_SPEC_INLINE.
# home_opt: `-` (default) means unset HOME; any other string sets HOME.
run() {
  local expected="$1" label="$2" payload="$3" project="${4:-$FIXTURE}" re="${5--}" needle="${6:-}" inline_opt="${7--}" home_opt="${8--}"
  local env_args=(-u SYG_DISPATCH_SPEC_RE -u SYG_DISPATCH_SPEC_INLINE -u HOME "CLAUDE_PROJECT_DIR=$project")
  if [ "$re" != "-" ]; then
    env_args+=("SYG_DISPATCH_SPEC_RE=$re")
  fi
  if [ "$inline_opt" != "-" ]; then
    env_args+=("SYG_DISPATCH_SPEC_INLINE=$inline_opt")
  fi
  if [ "$home_opt" != "-" ]; then
    env_args+=("HOME=$home_opt")
  fi
  ERR=$(printf '%s' "$payload" \
    | env "${env_args[@]}" bash "$HOOK" 2>&1 >/dev/null)
  local actual=$?
  if [ "$actual" -ne "$expected" ]; then
    printf 'FAIL  (exit %d, expected %d)  %s\n  stderr: %s\n' "$actual" "$expected" "$label" "$ERR"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if [ -n "$needle" ] && ! grep -qF -- "$needle" <<<"$ERR"; then
    printf 'FAIL  (missing stderr %s)  %s\n  stderr: %s\n' "$needle" "$label" "$ERR"
    FAILURES=$((FAILURES + 1))
    return
  fi
  printf 'PASS  (exit %d)  %s\n' "$actual" "$label"
}

assert_err_contains() {
  local label="$1" needle="$2"
  if grep -qF -- "$needle" <<<"$ERR"; then
    printf 'PASS  (stderr)  %s\n' "$label"
  else
    printf 'FAIL  (stderr missing %s)  %s\n  stderr: %s\n' "$needle" "$label" "$ERR"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_err_lacks() {
  local label="$1" needle="$2"
  if ! grep -qF -- "$needle" <<<"$ERR"; then
    printf 'PASS  (stderr lacks)  %s\n' "$label"
  else
    printf 'FAIL  (stderr unexpectedly contained %s)  %s\n  stderr: %s\n' "$needle" "$label" "$ERR"
    FAILURES=$((FAILURES + 1))
  fi
}

# --- Fixture files ------------------------------------------------------------

cat >"$FIXTURE/.claude/dispatch/good.md" <<'EOF'
# Unit: good spec

## Task
Implement the widget.

## Premise ledger

- hooks.json PreToolUse array has no Agent matcher — `jq '.hooks.PreToolUse' plugins/seyag/hooks/hooks.json`
  continuation line without its own cite does not count as a separate row
# comment line inside ledger section is ignored
- run.sh resolves a hook via syg_enabled — cite: plugins/seyag/hooks/run.sh:50

## Files in scope
- uncited bullet outside the ledger section is ignored
EOF

cat >"$FIXTURE/.claude/dispatch/no-ledger.md" <<'EOF'
# Unit: missing ledger

## Task
Implement the widget without a premise ledger section.
EOF

cat >"$FIXTURE/.claude/dispatch/empty-ledger.md" <<'EOF'
# Unit: empty ledger

## Premise ledger

# only a comment and blank lines, no bullet rows

## Files in scope
- plugins/seyag/hooks/run.sh:1
EOF

OFFENDING_ROW="- runtime premise asserted from memory with neither backticks nor a slash path"
cat >"$FIXTURE/.claude/dispatch/uncited-row.md" <<EOF
# Unit: uncited row

## Premise ledger
- first row has a valid cite in \`hooks.json\`
$OFFENDING_ROW
- third row has plugins/seyag/hooks/run.sh:10
EOF

cp "$FIXTURE/.claude/dispatch/good.md" "$FIXTURE/specs/custom-good.md"
cp "$FIXTURE/.claude/dispatch/no-ledger.md" "$FIXTURE/specs/custom-bad.md"

cat >"$FIXTURE/.claude/dispatch/unreadable.md" <<'EOF'
# Unit: unreadable
EOF
chmod 000 "$FIXTURE/.claude/dispatch/unreadable.md"

INLINE_GOOD=$(cat "$FIXTURE/.claude/dispatch/good.md")
INLINE_BAD=$(cat "$FIXTURE/.claude/dispatch/no-ledger.md")
INLINE_EMPTY=$(cat "$FIXTURE/.claude/dispatch/empty-ledger.md")
INLINE_UNCITED=$(cat "$FIXTURE/.claude/dispatch/uncited-row.md")

# --- Case 1: resolving spec file WITH a good ledger → 0 -----------------------
run 0 "case 1: resolving spec file with a good ledger (backticks + path:line) passes" \
  "$(agent_payload "Execute the spec at .claude/dispatch/good.md" "worktree")"

# --- Case 1b (F4.1): rows citing by slash-path WITHOUT :line and by backtick span only → 0
INLINE_CITE_SHAPES=$(cat <<'EOF'
# Unit: cite shapes

## Premise ledger
- verified in plugins/seyag/hooks/run.sh before editing
- checked with `git status`
EOF
)
run 0 "case 1b: rows citing by slash-path without :line and by backtick span only pass" \
  "$(agent_payload "$INLINE_CITE_SHAPES" "worktree")" "$FIXTURE" "-" "" "1"

# --- Case 2: resolving spec file withOUT the section → 2, headline 1 pinned ---
run 2 "case 2: resolving spec file without ## Premise ledger blocks" \
  "$(agent_payload "Execute the spec at .claude/dispatch/no-ledger.md")" \
  "$FIXTURE" "-" "$HEADLINE_MISSING"
assert_err_contains "case 2: block names resolved spec path" "$FIXTURE/.claude/dispatch/no-ledger.md"

# --- Case 3: resolving spec file, section present, zero rows → 2 --------------
run 2 "case 3: resolving spec file with empty ## Premise ledger section blocks" \
  "$(agent_payload "Execute the spec at .claude/dispatch/empty-ledger.md")" \
  "$FIXTURE" "-" "$HEADLINE_EMPTY"
assert_err_contains "case 3: block names resolved spec path" "$FIXTURE/.claude/dispatch/empty-ledger.md"

# --- Case 3b (F4.6): inline worktree prompt whose ledger section is empty → 2 -
run 2 "case 3b: inline worktree prompt with empty ## Premise ledger section blocks" \
  "$(agent_payload "$INLINE_EMPTY" "worktree")" \
  "$FIXTURE" "-" "$HEADLINE_EMPTY" "1"
assert_err_contains "case 3b: inline empty ledger block names (inline prompt, isolation: worktree)" \
  "(inline prompt, isolation: worktree)"

# --- Case 4: section with a row lacking both citation shapes → 2 --------------
run 2 "case 4: premise row without backtick or slash-path citation blocks" \
  "$(agent_payload "Execute the spec at .claude/dispatch/uncited-row.md")" \
  "$FIXTURE" "-" "$HEADLINE_UNCITED"
assert_err_contains "case 4: block quotes the first offending row" "$OFFENDING_ROW"

# --- Case 4b: inline prompt with uncited row in ledger → 2 --------------------
run 2 "case 4b: inline worktree prompt with uncited premise row blocks" \
  "$(agent_payload "$INLINE_UNCITED" "worktree")" \
  "$FIXTURE" "-" "$HEADLINE_UNCITED" "1"
assert_err_contains "case 4b: inline cite block quotes offending row" "$OFFENDING_ROW"

# --- Case 4c..4e (F4.2): non-qualifying cite shapes each block ----------------
# shellcheck disable=SC2016
ROW_EMPTY_TICKS='- premise with empty `` backticks only'
run 2 "case 4c: empty backticks do not count as a citation" \
  "$(agent_payload $'## Premise ledger\n'"$ROW_EMPTY_TICKS" "worktree")" \
  "$FIXTURE" "-" "$HEADLINE_UNCITED" "1"
assert_err_contains "case 4c: quotes empty-backticks row" "$ROW_EMPTY_TICKS"

ROW_SLASHLESS='- premise citing file.ext:10 without a slash'
run 2 "case 4d: slashless file.ext:10 does not count as a citation" \
  "$(agent_payload $'## Premise ledger\n'"$ROW_SLASHLESS" "worktree")" \
  "$FIXTURE" "-" "$HEADLINE_UNCITED" "1"
assert_err_contains "case 4d: quotes slashless row" "$ROW_SLASHLESS"

ROW_NO_EXT='- premise citing plugins/seyag/bin/safe-clean without extension'
run 2 "case 4e: extensionless slash path does not count as a citation" \
  "$(agent_payload $'## Premise ledger\n'"$ROW_NO_EXT" "worktree")" \
  "$FIXTURE" "-" "$HEADLINE_UNCITED" "1"
assert_err_contains "case 4e: quotes extensionless-path row" "$ROW_NO_EXT"

# --- Case 4f (F4.3): offending logical row > 160 chars is truncated -----------
LONG_TAIL="TAIL_BEYOND_160_MARKER"
LONG_ROW="- uncited premise row padded past one hundred and sixty characters to verify that the block message truncates the quoted row at exactly 160 characters and drops $LONG_TAIL"
LONG_PREFIX="${LONG_ROW:0:160}"
run 2 "case 4f: offending row > 160 chars blocks with truncated quote" \
  "$(agent_payload $'## Premise ledger\n'"$LONG_ROW" "worktree")" \
  "$FIXTURE" "-" "$HEADLINE_UNCITED" "1"
assert_err_contains "case 4f: stderr contains 160-char prefix + ellipsis" "${LONG_PREFIX}..."
assert_err_lacks "case 4f: stderr omits tail past 160 chars" "$LONG_TAIL"

# --- Case 5: named path does NOT resolve, inline prompt WITH ledger, isolation=worktree → 0
run 0 "case 5: non-resolving named path falls through to inline prompt with ledger (passes)" \
  "$(agent_payload "Prior spec was .claude/dispatch/missing.md"$'\n\n'"$INLINE_GOOD" "worktree")" \
  "$FIXTURE" "-" "" "1"

# --- Case 6: no spec path, inline prompt withOUT ledger, isolation=worktree → 2 (when opted in)
run 2 "case 6: inline prompt without ledger and isolation=worktree blocks when SYG_DISPATCH_SPEC_INLINE=1" \
  "$(agent_payload "$INLINE_BAD" "worktree")" \
  "$FIXTURE" "-" "$HEADLINE_MISSING_INLINE" "1"
assert_err_contains "case 6: block names (inline prompt, isolation: worktree)" \
  "(inline prompt, isolation: worktree)"

# --- Case 6b (F2): inline + isolation=worktree + no ledger + env UNSET → 0 ----
run 0 "case 6b: inline prompt without ledger and isolation=worktree passes when SYG_DISPATCH_SPEC_INLINE is unset" \
  "$(agent_payload "$INLINE_BAD" "worktree")"
run 0 "case 6c: inline prompt without ledger and isolation=worktree passes when SYG_DISPATCH_SPEC_INLINE=0" \
  "$(agent_payload "$INLINE_BAD" "worktree")" "$FIXTURE" "-" "" "0"

# --- Case 7: no spec path, inline prompt withOUT ledger, isolation absent/other → 0
run 0 "case 7a: inline prompt without ledger and isolation absent passes (research agent)" \
  "$(agent_payload "$INLINE_BAD")" "$FIXTURE" "-" "" "1"
run 0 "case 7b: inline prompt without ledger and isolation!=worktree passes" \
  "$(agent_payload "$INLINE_BAD" "none")" "$FIXTURE" "-" "" "1"

# --- Case 8: non-Agent tool_name → 0 (early exit) -----------------------------
run 0 "case 8: non-Agent tool_name exits 0" \
  "$(agent_payload "Execute .claude/dispatch/no-ledger.md" "worktree" "Bash")"

# --- Case 9: empty prompt → 0 -------------------------------------------------
run 0 "case 9a: empty prompt exits 0" \
  "$(agent_payload "" "worktree")"
run 0 "case 9b: missing prompt field exits 0" \
  '{"tool_name":"Agent","tool_input":{"isolation":"worktree"}}'

# --- Case 10: SYG_DISPATCH_SPEC_RE override + malformed regex fail-open (F4.8)
CUSTOM_RE='[A-Za-z0-9._/-]*specs/[A-Za-z0-9._-]+\.md'
# Default regex misses specs/custom-bad.md (and no isolation=worktree) -> passes
run 0 "case 10a: default regex ignores specs/custom-bad.md outside .claude/dispatch/" \
  "$(agent_payload "Execute specs/custom-bad.md")"
# Override regex matches specs/custom-bad.md -> blocks with headline 1
run 2 "case 10b: SYG_DISPATCH_SPEC_RE override matches specs/custom-bad.md and blocks" \
  "$(agent_payload "Execute specs/custom-bad.md")" \
  "$FIXTURE" "$CUSTOM_RE" "$HEADLINE_MISSING"
# Override regex matches specs/custom-good.md -> passes
run 0 "case 10c: SYG_DISPATCH_SPEC_RE override matches specs/custom-good.md and passes" \
  "$(agent_payload "Execute specs/custom-good.md")" \
  "$FIXTURE" "$CUSTOM_RE"
# Malformed SYG_DISPATCH_SPEC_RE (grep exit >= 2) fails open with stderr note
run 0 "case 10d: malformed SYG_DISPATCH_SPEC_RE='[unclosed' fails open with exit 0" \
  "$(agent_payload "Execute .claude/dispatch/good.md" "worktree")" \
  "$FIXTURE" "[unclosed" \
  "dispatch-spec-ledger-gate: could not scan the prompt for a spec path (grep exit " "1"
assert_err_contains "case 10d: malformed regex stderr ends with failing open" ") — failing open"

# --- Case 11: unreadable spec file (chmod 000) → 0 with fail-open stderr ------
# Note (F4.10 + CI F4): three defensive fail-open branches in the hook have no
# probe case because they are not fixture-able without mutating PATH or inducing
# kernel/process races:
#   - `jq unavailable` (requires hiding `jq` from PATH),
#   - `could not re-read` (when `cat "$RESOLVED_PATH"` yields empty right after
#     `grep -qiE` matched on the same path — reachable only via a truncation or
#     unmount race between `grep` and `cat`; a FIFO can hang `grep`),
#   - `could not scan the inline prompt` (grep exit >= 2 on a fixed valid ERE
#     over an in-memory here-string).
if [ ! -r "$FIXTURE/.claude/dispatch/unreadable.md" ]; then
  run 0 "case 11: unreadable spec file fails open with exit 0" \
    "$(agent_payload "Execute .claude/dispatch/unreadable.md")" \
    "$FIXTURE" "-" \
    "dispatch-spec-ledger-gate: could not read $FIXTURE/.claude/dispatch/unreadable.md (grep exit "
  assert_err_contains "case 11: stderr ends with failing open" ") — failing open"
fi
chmod 600 "$FIXTURE/.claude/dispatch/unreadable.md"

# --- Case 12: default scope absorbs absolute prefix ---------------------------
run 0 "case 12a: absolute-prefix .claude/dispatch path resolves and passes with good ledger" \
  "$(agent_payload "Read $FIXTURE/.claude/dispatch/good.md and execute" "worktree")" \
  "$ELSEWHERE"
run 2 "case 12b: absolute-prefix .claude/dispatch path without ledger resolves and blocks" \
  "$(agent_payload "Read $FIXTURE/.claude/dispatch/no-ledger.md and execute")" \
  "$ELSEWHERE" "-" "$HEADLINE_MISSING"

# --- Case 13 (F4.4): heading variants (nested ### and uppercase) --------------
# shellcheck disable=SC2016
run 0 "case 13a: nested '### premise ledger' heading counts as the section and passes" \
  "$(agent_payload $'### premise ledger\n- cited via `git status`' "worktree")" \
  "$FIXTURE" "-" "" "1"
run 0 "case 13b: uppercase '## PREMISE LEDGER' heading counts as the section and passes" \
  "$(agent_payload $'## PREMISE LEDGER\n- cited via plugins/seyag/hooks/run.sh:1' "worktree")" \
  "$FIXTURE" "-" "" "1"

# --- Case 14 (F4.5): suffixed headings are NOT the section --------------------
SUFFIXED_THEN_REAL=$(cat <<'EOF'
# Unit: suffixed heading above real section

## Premise ledger gate
- uncited note under a suffixed heading is outside the real ledger section

## Premise ledger
- real section row cited via `git status`
EOF
)
run 0 "case 14a: '## Premise ledger gate' above real '## Premise ledger' passes via real section" \
  "$(agent_payload "$SUFFIXED_THEN_REAL" "worktree")" "$FIXTURE" "-" "" "1"

cat >"$FIXTURE/.claude/dispatch/suffixed-only.md" <<'EOF'
# Unit: suffixed heading only

## Premise ledger follow-up
- row with a valid cite in plugins/seyag/hooks/run.sh:1
EOF
run 2 "case 14b: '## Premise ledger follow-up' with no real ledger section blocks as missing" \
  "$(agent_payload "Execute .claude/dispatch/suffixed-only.md")" \
  "$FIXTURE" "-" "$HEADLINE_MISSING"

# --- Case 15 (F4.7 + CI F3): two spec paths in prompt — first named path wins -
run 2 "case 15a: two spec paths (first bad, second good) -> first path wins and blocks" \
  "$(agent_payload "Compare .claude/dispatch/no-ledger.md against .claude/dispatch/good.md")" \
  "$FIXTURE" "-" "$HEADLINE_MISSING"
assert_err_contains "case 15a: block names the first path (no-ledger.md)" \
  "$FIXTURE/.claude/dispatch/no-ledger.md"
run 0 "case 15b: two spec paths (first good, second bad) -> first path wins and passes" \
  "$(agent_payload "Compare .claude/dispatch/good.md against .claude/dispatch/no-ledger.md")"
# F3: only the first matching path is checked; when the first match does not
# resolve (.claude/dispatch/gone.md), later named paths in the prompt are NOT
# checked (narrative mention / superseded spec) and with no isolation it exits 0.
run 0 "case 15c: first path unresolvable (.claude/dispatch/gone.md) then resolving good.md, no isolation -> exits 0" \
  "$(agent_payload "Superseded .claude/dispatch/gone.md; see .claude/dispatch/good.md")"

# --- Case 16 (F4.9): wrapped bullet row with continuation line (F3) -----------
WRAPPED_GOOD=$(cat <<'EOF'
## Premise ledger
- runtime premise whose first line wraps at column eighty before naming the
  establishing read at plugins/seyag/hooks/run.sh:50
EOF
)
run 0 "case 16a: wrapped '- ' row with citation on indented continuation line passes" \
  "$(agent_payload "$WRAPPED_GOOD" "worktree")" "$FIXTURE" "-" "" "1"

WRAPPED_BAD_OPENING="- runtime premise whose opening line wraps onto an indented continuation"
WRAPPED_BAD_CONT="  without any citation on the continuation line either"
run 2 "case 16b: wrapped '- ' row with no citation anywhere in the logical row blocks" \
  "$(agent_payload $'## Premise ledger\n'"$WRAPPED_BAD_OPENING"$'\n'"$WRAPPED_BAD_CONT" "worktree")" \
  "$FIXTURE" "-" "$HEADLINE_UNCITED" "1"
assert_err_contains "case 16b: block quotes the opening line of the offending logical row" \
  "$WRAPPED_BAD_OPENING"
assert_err_lacks "case 16b: block does not quote the continuation line" \
  "$WRAPPED_BAD_CONT"

# --- Case 17 (CI F1): delegation skill template verbatim vs filled ------------
# Copies the skill template's `## Premise ledger` section verbatim as
# restructured (blockquote guidance + three placeholder `- ` rows): the
# blockquote is not a `- ` row, while the unfilled `<...>` placeholder row
# lacks a citation and blocks with HEADLINE_UNCITED. Replacing the `<...>`
# slots with cited rows passes.
TEMPLATE_VERBATIM=$(cat <<'EOF'
## Premise ledger
> A premise about a value's form or state at a pipeline stage cites the producer line that establishes it AT that stage, never a similar-looking site elsewhere — the form at the stage is exactly what the spec's next step consumes.
- <each runtime premise the spec asserts> — <the read or probe that established it>
- Already built? `<grep for the fix's own name>` → <result>
- Already covered? `<grep/search for an existing task, PR or branch>` → <result>
EOF
)
run 2 "case 17a: unfilled skill template Premise ledger section blocks on placeholder row" \
  "$(agent_payload "$TEMPLATE_VERBATIM" "worktree")" \
  "$FIXTURE" "-" "$HEADLINE_UNCITED" "1"
assert_err_contains "case 17a: quotes the unfilled placeholder row, not the blockquote guidance" \
  "- <each runtime premise the spec asserts> — <the read or probe that established it>"

TEMPLATE_FILLED=$(cat <<'EOF'
## Premise ledger
> A premise about a value's form or state at a pipeline stage cites the producer line that establishes it AT that stage, never a similar-looking site elsewhere — the form at the stage is exactly what the spec's next step consumes.
- hooks.json PreToolUse array has no Agent matcher — plugins/seyag/hooks/hooks.json:120
- Already built? `grep -rn "Premise ledger" plugins/` → only SKILL.md:49
- Already covered? `git log --all --grep=ledger-gate` → empty
EOF
)
run 0 "case 17b: filled skill template Premise ledger section (keeping blockquote guidance) passes" \
  "$(agent_payload "$TEMPLATE_FILLED" "worktree")" "$FIXTURE" "-" "" "1"

# --- Case 18 (CI2 F4): indented '- ' sub-bullets are rows too and must cite ---
# shellcheck disable=SC2016
SUB_PARENT_ROW='- parent premise cited via `git status`'
SUB_UNCITED_ROW="- uncited sub-bullet note under a cited parent"
run 2 "case 18a: cited parent row with uncited indented '- ' sub-bullet blocks" \
  "$(agent_payload $'## Premise ledger\n'"$SUB_PARENT_ROW"$'\n  '"$SUB_UNCITED_ROW" "worktree")" \
  "$FIXTURE" "-" "$HEADLINE_UNCITED" "1"
assert_err_contains "case 18a: block quotes the uncited sub-bullet line" \
  "$SUB_UNCITED_ROW"
assert_err_lacks "case 18a: block does not quote the cited parent row" \
  "$SUB_PARENT_ROW"

# shellcheck disable=SC2016
SUB_CITED_ROW='- explanatory sub-bullet cited via `jq`'
run 0 "case 18b: cited parent row with backtick-cited indented '- ' sub-bullet passes" \
  "$(agent_payload $'## Premise ledger\n'"$SUB_PARENT_ROW"$'\n  '"$SUB_CITED_ROW" "worktree")" \
  "$FIXTURE" "-" "" "1"

# --- Case 19 (CI2 F5): leading ~/ expands to $HOME/ ---------------------------
cp "$FIXTURE/.claude/dispatch/good.md" "$TMPDIR_PROBE/home/.claude/dispatch/good.md"
cp "$FIXTURE/.claude/dispatch/no-ledger.md" "$TMPDIR_PROBE/home/.claude/dispatch/no-ledger.md"

run 0 "case 19a: ~/.claude/dispatch/good.md expands ~/ to HOME and passes" \
  "$(agent_payload "Execute ~/.claude/dispatch/good.md")" \
  "$ELSEWHERE" "-" "" "-" "$TMPDIR_PROBE/home"

run 2 "case 19b: ~/.claude/dispatch/no-ledger.md expands ~/ to HOME and blocks naming expanded path" \
  "$(agent_payload "Execute ~/.claude/dispatch/no-ledger.md")" \
  "$ELSEWHERE" "-" "$HEADLINE_MISSING" "-" "$TMPDIR_PROBE/home"
assert_err_contains "case 19b: block names the expanded HOME path" \
  "$TMPDIR_PROBE/home/.claude/dispatch/no-ledger.md"

# --- Case 20: doubled '## ## Premise ledger' heading blocks and quotes expected heading
cat >"$FIXTURE/.claude/dispatch/doubled-heading.md" <<'EOF'
# Unit: doubled heading typo

## Task
Implement the widget.

## ## Premise ledger
- row with a valid cite in `hooks.json`
EOF

run 2 "case 20a: doubled '## ## Premise ledger' heading in spec file blocks" \
  "$(agent_payload "Execute .claude/dispatch/doubled-heading.md")" \
  "$FIXTURE" "-" "$HEADLINE_MISSING"
assert_err_contains "case 20a: error prints literal expected heading 'Expected heading: ## Premise ledger'" \
  "Expected heading: ## Premise ledger"
assert_err_contains "case 20a: error quotes the near-miss heading 'Found heading:    ## ## Premise ledger'" \
  "Found heading:    ## ## Premise ledger"

run 2 "case 20b: doubled '## ## Premise ledger' heading in inline worktree prompt blocks" \
  "$(agent_payload "$(cat "$FIXTURE/.claude/dispatch/doubled-heading.md")" "worktree")" \
  "$FIXTURE" "-" "$HEADLINE_MISSING_INLINE" "1"
assert_err_contains "case 20b: inline error prints literal expected heading 'Expected heading: ## Premise ledger'" \
  "Expected heading: ## Premise ledger"
assert_err_contains "case 20b: inline error quotes the near-miss heading 'Found heading:    ## ## Premise ledger'" \
  "Found heading:    ## ## Premise ledger"

echo "failures: $FAILURES"
exit "$FAILURES"
