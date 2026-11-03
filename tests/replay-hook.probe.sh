#!/bin/bash
# Fixture check for tests/replay-hook.sh — self-contained, uses a synthetic
# projects dir, never touches real session logs.
# Usage: tests/replay-hook.probe.sh   (from anywhere)

set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RH="$REPO/tests/replay-hook.sh"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

mkdir -p "$T/proj-slug"
cat > "$T/proj-slug/session1.jsonl" <<'EOF'
this line is not JSON at all
{"type":"assistant","cwd":"/tmp/fixture-project","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"gh pr view 1 --json title | head -5"}}]}}
{"type":"assistant","cwd":"/tmp/fixture-project","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls -la"}}]}}
{"type":"assistant","cwd":"/tmp/fixture-project","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git status --short"}}]}}
{"type":"assistant","cwd":"/tmp/fixture-project","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}},{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/x"}}]}}
EOF

mkdir -p "$T/proj-slug/sess-uuid/subagents"
cat > "$T/proj-slug/sess-uuid/subagents/agent-a1.jsonl" <<'EOF'
{"type":"assistant","cwd":"/tmp/fixture-project","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"gh pr view 2 --json title | head -5"}}]}}
{"type":"assistant","cwd":"/tmp/fixture-project","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}
EOF

mkdir -p "$T/proj-slug/mined-corpus/reports"
cat > "$T/proj-slug/mined-corpus/reports/r.jsonl" <<'EOF'
{"type":"assistant","cwd":"/tmp/fixture-project","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"gh pr view 3 --json title | head -5"}}]}}
EOF

# Positive control: lossy-pipe-guard blocks this exact shape directly.
jq -n '{tool_name:"Bash",tool_input:{command:"gh pr view 1 --json title | head -5"}}' \
  | env -u CLAUDE_PROJECT_DIR bash "$REPO/plugins/seyag/hooks/lossy-pipe-guard.sh" >/dev/null 2>&1
[ $? -ne 0 ] && ok "positive control: lossy-pipe-guard blocks the fixture's gh|head command directly" \
  || bad "positive control: lossy-pipe-guard did not block the fixture command"

out=$("$RH" lossy-pipe-guard --since 1 --slug proj-slug --projects-dir "$T")
echo "$out" | grep -qF "gh pr view 1 --json title | head -5" \
  && ok "blocked command text appears in output" || bad "blocked command text missing"
# 3 original commands + the extra Bash block in the two-tool_use entry = 4,
# plus 2 commands in the subagent transcript = 6; the malformed line, the
# non-Bash (Read) block, and the mined-corpus report entry do not count.
# Of the 6, the top-level "gh pr view 1" and the subagent "gh pr view 2" are
# blocked = 2/6.
echo "$out" | tail -1 | grep -qxF "replay-hook: lossy-pipe-guard: 2/6 commands blocked across 2 files" \
  && ok "summary line: 2/6 blocked across 2 files (subagent transcript replayed, mined-corpus report excluded)" \
  || bad "summary line: $(echo "$out" | tail -1)"
echo "$out" | grep -qF "gh pr view 2 --json title | head -5" \
  && ok "subagent blocked command text appears in output" || bad "subagent blocked command text missing"
echo "$out" | grep -A1 -xF "command: gh pr view 2 --json title | head -5" | grep -qxF "slug: proj-slug (subagent)" \
  && ok "subagent block is labelled slug: proj-slug (subagent)" || bad "subagent (subagent) label missing"
echo "$out" | grep -A1 -xF "command: gh pr view 1 --json title | head -5" | grep -qxF "slug: proj-slug" \
  && ok "top-level block still shows exact slug: proj-slug (no suffix)" || bad "top-level exact slug line missing"
echo "$out" | grep -qF "gh pr view 3" \
  && bad "mined-corpus command leaked into output" || ok "mined-corpus command (gh pr view 3) not replayed"

outall=$("$RH" lossy-pipe-guard --since 1 --projects-dir "$T")
echo "$outall" | tail -1 | grep -qxF "replay-hook: lossy-pipe-guard: 2/6 commands blocked across 2 files" \
  && ok "all-slugs run: 2/6 blocked across 2 files (depth arithmetic holds without --slug)" \
  || bad "all-slugs summary line: $(echo "$outall" | tail -1)"

# Trailing slash on --projects-dir must not break the slug strip.
outslash=$("$RH" lossy-pipe-guard --since 1 --slug proj-slug --projects-dir "$T/")
echo "$outslash" | tail -1 | grep -qxF "replay-hook: lossy-pipe-guard: 2/6 commands blocked across 2 files" \
  && ok "trailing-slash --projects-dir: 2/6 blocked across 2 files" \
  || bad "trailing-slash --projects-dir summary line: $(echo "$outslash" | tail -1)"
echo "$outslash" | grep -A1 -xF "command: gh pr view 2 --json title | head -5" | grep -qxF "slug: proj-slug (subagent)" \
  && ok "trailing-slash --projects-dir: subagent block still labelled slug: proj-slug (subagent)" \
  || bad "trailing-slash --projects-dir: subagent (subagent) label missing"

# The --slug mode above inserts its own "/$SLUG" onto PROJECTS_DIR, so a
# trailing slash there happens to cancel out in the rel-strip regardless of
# normalization. All-slugs mode uses SEARCH_ROOT=$PROJECTS_DIR directly, so
# it is the case that actually exercises PROJECTS_DIR=${PROJECTS_DIR%/}.
outallslash=$("$RH" lossy-pipe-guard --since 1 --projects-dir "$T/")
echo "$outallslash" | tail -1 | grep -qxF "replay-hook: lossy-pipe-guard: 2/6 commands blocked across 2 files" \
  && ok "all-slugs trailing-slash --projects-dir: 2/6 blocked across 2 files" \
  || bad "all-slugs trailing-slash --projects-dir summary line: $(echo "$outallslash" | tail -1)"
echo "$outallslash" | grep -A1 -xF "command: gh pr view 1 --json title | head -5" | grep -qxF "slug: proj-slug" \
  && ok "all-slugs trailing-slash --projects-dir: top-level block still labelled slug: proj-slug" \
  || bad "all-slugs trailing-slash --projects-dir: top-level slug label missing/empty"

"$RH" no-such-hook >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "unknown hook name exits 2" || bad "unknown hook name exit=$rc"

out0=$("$RH" lossy-pipe-guard --since 0 --slug proj-slug --projects-dir "$T")
echo "$out0" | tail -1 | grep -qxF "replay-hook: lossy-pipe-guard: 0/0 commands blocked across 0 files" \
  && ok "--since 0 (impossible window) yields 0/0 across 0 files" || bad "--since 0: $(echo "$out0" | tail -1)"

"$RH" lossy-pipe-guard --slug nope --projects-dir "$T" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "--slug nope (nonexistent dir) exits 2" || bad "--slug nope exit=$rc"

# REPLAY-ARMED-BY: a hook that is inert without a variable must say so. The
# fixture hook lives in a copy of the tree (the script derives its hooks dir
# from its own location), so the real plugins/ dir gains nothing.
ARM=$(mktemp -d)
mkdir -p "$ARM/tests" "$ARM/plugins/seyag/hooks"
cp "$RH" "$ARM/tests/replay-hook.sh"
cat > "$ARM/plugins/seyag/hooks/fixture-armed.sh" <<'EOF'
#!/bin/bash
# REPLAY-ARMED-BY: FIXTURE_ARM_VAR
[ -n "${FIXTURE_ARM_VAR:-}" ] || exit 0
exit 2
EOF
ARM_RH="$ARM/tests/replay-hook.sh"

out_unset=$(env -u FIXTURE_ARM_VAR "$ARM_RH" fixture-armed --since 1 --slug proj-slug --projects-dir "$T" 2>&1)
echo "$out_unset" | head -1 | grep -qxF "replay-hook: warning: fixture-armed is inert without FIXTURE_ARM_VAR (unset here); export it for this run" \
  && ok "unarmed run: warning printed before the replay" || bad "unarmed run: first line is $(echo "$out_unset" | head -1)"
echo "$out_unset" | tail -1 | grep -qF " (INERT: FIXTURE_ARM_VAR unset)" \
  && ok "unarmed run: summary line carries (INERT: FIXTURE_ARM_VAR unset)" || bad "unarmed run: summary $(echo "$out_unset" | tail -1)"

out_set=$(FIXTURE_ARM_VAR=1 "$ARM_RH" fixture-armed --since 1 --slug proj-slug --projects-dir "$T" 2>&1)
echo "$out_set" | grep -qF "replay-hook: warning:" \
  && bad "armed run: warning printed although the variable is set" || ok "armed run: no warning"
echo "$out_set" | grep -qF "(INERT:" \
  && bad "armed run: summary marked INERT although the variable is set" || ok "armed run: summary not marked INERT"
echo "$out_set" | tail -1 | grep -qxF "replay-hook: fixture-armed: 6/6 commands blocked across 2 files" \
  && ok "armed run: the fixture hook blocks every replayed command (6/6)" || bad "armed run: $(echo "$out_set" | tail -1)"
# Two named variables, one set and one unset: only the unset one is named, and
# a token that is not a shell identifier is skipped.
mkdir -p "$ARM/plugins/seyag/hooks"
cat > "$ARM/plugins/seyag/hooks/fixture-two.sh" <<'EOF'
#!/bin/bash
# REPLAY-ARMED-BY: FIXTURE_SET_VAR FIXTURE_ARM_VAR 9-not-a-name
[ -n "${FIXTURE_ARM_VAR:-}" ] || exit 0
exit 2
EOF
out_two=$(FIXTURE_SET_VAR=1 env -u FIXTURE_ARM_VAR "$ARM_RH" fixture-two --since 1 --slug proj-slug --projects-dir "$T" 2>&1)
echo "$out_two" | grep -qxF "replay-hook: warning: fixture-two is inert without FIXTURE_ARM_VAR (unset here); export it for this run" \
  && ok "two-var field: the unset variable is named" || bad "two-var field: $(echo "$out_two" | head -1)"
echo "$out_two" | grep -qF "FIXTURE_SET_VAR" \
  && bad "two-var field: the set variable was named" || ok "two-var field: the set variable is not named"
echo "$out_two" | grep -qF "9-not-a-name" \
  && bad "non-identifier token was named" || ok "non-identifier token is skipped"
echo "$out_two" | tail -1 | grep -qxF "replay-hook: fixture-two: 0/6 commands blocked across 2 files (INERT: FIXTURE_ARM_VAR unset)" \
  && ok "two-var field: summary carries exactly one INERT suffix" || bad "two-var field summary: $(echo "$out_two" | tail -1)"
# An empty REPLAY-ARMED-BY line names nothing: no crash under set -u, no warning.
cat > "$ARM/plugins/seyag/hooks/fixture-empty.sh" <<'EOF'
#!/bin/bash
# REPLAY-ARMED-BY:
exit 0
EOF
out_empty=$("$ARM_RH" fixture-empty --since 1 --slug proj-slug --projects-dir "$T" 2>&1); rc=$?
[ "$rc" -eq 0 ] && echo "$out_empty" | tail -1 | grep -qxF "replay-hook: fixture-empty: 0/6 commands blocked across 2 files" \
  && ok "empty REPLAY-ARMED-BY line: runs clean, no warning" || bad "empty REPLAY-ARMED-BY line: rc=$rc $(echo "$out_empty" | tail -1)"
rm -rf "$ARM"

# The real hook carries the field, and the real replay names the unset switch.
/usr/bin/grep -qxF '# REPLAY-ARMED-BY: SYG_PRIVATE_TERMS_FILE' "$REPO/plugins/seyag/hooks/private-term-guard.sh" \
  && ok "private-term-guard.sh carries the REPLAY-ARMED-BY field" || bad "private-term-guard.sh lacks the REPLAY-ARMED-BY field"
out_ptg=$(env -u SYG_PRIVATE_TERMS_FILE "$RH" private-term-guard --since 1 --slug proj-slug --projects-dir "$T" 2>&1)
echo "$out_ptg" | grep -qxF "replay-hook: warning: private-term-guard is inert without SYG_PRIVATE_TERMS_FILE (unset here); export it for this run" \
  && ok "real private-term-guard replay with the switch unset: warning printed" || bad "real private-term-guard replay: no warning"

exit $fail
