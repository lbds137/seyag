#!/bin/bash
# Fixture check for tests/replay-hook.sh — self-contained, uses a synthetic
# projects dir, never touches real session logs.
# Usage: tests/replay-hook.probe.sh   (from anywhere)

set -uo pipefail
# Hooks run here directly, not via run.sh: keep bytecode out of hooks/lib.
export PYTHONDONTWRITEBYTECODE=1

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
grep -qF "gh pr view 1 --json title | head -5" <<<"$out" \
  && ok "blocked command text appears in output" || bad "blocked command text missing"
# 3 original commands + the extra Bash block in the two-tool_use entry = 4,
# plus 2 commands in the subagent transcript = 6; the malformed line, the
# non-Bash (Read) block, and the mined-corpus report entry do not count.
# Of the 6, the top-level "gh pr view 1" and the subagent "gh pr view 2" are
# blocked = 2/6.
_pipe_out=$(tail -1 <<<"$out") && grep -qxF "replay-hook: lossy-pipe-guard: 2/6 commands blocked across 2 files" <<<"$_pipe_out" \
  && ok "summary line: 2/6 blocked across 2 files (subagent transcript replayed, mined-corpus report excluded)" \
  || bad "summary line: $(echo "$out" | tail -1)"
grep -qF "gh pr view 2 --json title | head -5" <<<"$out" \
  && ok "subagent blocked command text appears in output" || bad "subagent blocked command text missing"
_pipe_out=$(grep -A1 -xF "command: gh pr view 2 --json title | head -5" <<<"$out") && grep -qxF "slug: proj-slug (subagent)" <<<"$_pipe_out" \
  && ok "subagent block is labelled slug: proj-slug (subagent)" || bad "subagent (subagent) label missing"
_pipe_out=$(grep -A1 -xF "command: gh pr view 1 --json title | head -5" <<<"$out") && grep -qxF "slug: proj-slug" <<<"$_pipe_out" \
  && ok "top-level block still shows exact slug: proj-slug (no suffix)" || bad "top-level exact slug line missing"
grep -qF "gh pr view 3" <<<"$out" \
  && bad "mined-corpus command leaked into output" || ok "mined-corpus command (gh pr view 3) not replayed"

outall=$("$RH" lossy-pipe-guard --since 1 --projects-dir "$T")
_pipe_out=$(tail -1 <<<"$outall") && grep -qxF "replay-hook: lossy-pipe-guard: 2/6 commands blocked across 2 files" <<<"$_pipe_out" \
  && ok "all-slugs run: 2/6 blocked across 2 files (depth arithmetic holds without --slug)" \
  || bad "all-slugs summary line: $(echo "$outall" | tail -1)"

# Trailing slash on --projects-dir must not break the slug strip.
outslash=$("$RH" lossy-pipe-guard --since 1 --slug proj-slug --projects-dir "$T/")
_pipe_out=$(tail -1 <<<"$outslash") && grep -qxF "replay-hook: lossy-pipe-guard: 2/6 commands blocked across 2 files" <<<"$_pipe_out" \
  && ok "trailing-slash --projects-dir: 2/6 blocked across 2 files" \
  || bad "trailing-slash --projects-dir summary line: $(echo "$outslash" | tail -1)"
_pipe_out=$(grep -A1 -xF "command: gh pr view 2 --json title | head -5" <<<"$outslash") && grep -qxF "slug: proj-slug (subagent)" <<<"$_pipe_out" \
  && ok "trailing-slash --projects-dir: subagent block still labelled slug: proj-slug (subagent)" \
  || bad "trailing-slash --projects-dir: subagent (subagent) label missing"

# The --slug mode above inserts its own "/$SLUG" onto PROJECTS_DIR, so a
# trailing slash there happens to cancel out in the rel-strip regardless of
# normalization. All-slugs mode uses SEARCH_ROOT=$PROJECTS_DIR directly, so
# it is the case that actually exercises PROJECTS_DIR=${PROJECTS_DIR%/}.
outallslash=$("$RH" lossy-pipe-guard --since 1 --projects-dir "$T/")
_pipe_out=$(tail -1 <<<"$outallslash") && grep -qxF "replay-hook: lossy-pipe-guard: 2/6 commands blocked across 2 files" <<<"$_pipe_out" \
  && ok "all-slugs trailing-slash --projects-dir: 2/6 blocked across 2 files" \
  || bad "all-slugs trailing-slash --projects-dir summary line: $(echo "$outallslash" | tail -1)"
_pipe_out=$(grep -A1 -xF "command: gh pr view 1 --json title | head -5" <<<"$outallslash") && grep -qxF "slug: proj-slug" <<<"$_pipe_out" \
  && ok "all-slugs trailing-slash --projects-dir: top-level block still labelled slug: proj-slug" \
  || bad "all-slugs trailing-slash --projects-dir: top-level slug label missing/empty"

"$RH" no-such-hook >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "unknown hook name exits 2" || bad "unknown hook name exit=$rc"

out0=$("$RH" lossy-pipe-guard --since 0 --slug proj-slug --projects-dir "$T")
_pipe_out=$(tail -1 <<<"$out0") && grep -qxF "replay-hook: lossy-pipe-guard: 0/0 commands blocked across 0 files" <<<"$_pipe_out" \
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
_pipe_out=$(head -1 <<<"$out_unset") && grep -qxF "replay-hook: warning: fixture-armed is inert without FIXTURE_ARM_VAR (unset or empty here); export it for this run" <<<"$_pipe_out" \
  && ok "unarmed run: warning printed before the replay" || bad "unarmed run: first line is $(echo "$out_unset" | head -1)"
_pipe_out=$(tail -1 <<<"$out_unset") && grep -qF " (INERT: FIXTURE_ARM_VAR unset or empty)" <<<"$_pipe_out" \
  && ok "unarmed run: summary line carries (INERT: FIXTURE_ARM_VAR unset or empty)" || bad "unarmed run: summary $(echo "$out_unset" | tail -1)"

out_set=$(FIXTURE_ARM_VAR=1 "$ARM_RH" fixture-armed --since 1 --slug proj-slug --projects-dir "$T" 2>&1)
grep -qF "replay-hook: warning:" <<<"$out_set" \
  && bad "armed run: warning printed although the variable is set" || ok "armed run: no warning"
grep -qF "(INERT:" <<<"$out_set" \
  && bad "armed run: summary marked INERT although the variable is set" || ok "armed run: summary not marked INERT"
_pipe_out=$(tail -1 <<<"$out_set") && grep -qxF "replay-hook: fixture-armed: 6/6 commands blocked across 2 files" <<<"$_pipe_out" \
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
grep -qxF "replay-hook: warning: fixture-two is inert without FIXTURE_ARM_VAR (unset or empty here); export it for this run" <<<"$out_two" \
  && ok "two-var field: the unset variable is named" || bad "two-var field: $(echo "$out_two" | head -1)"
grep -qF "FIXTURE_SET_VAR" <<<"$out_two" \
  && bad "two-var field: the set variable was named" || ok "two-var field: the set variable is not named"
grep -qF "9-not-a-name" <<<"$out_two" \
  && bad "non-identifier token was named" || ok "non-identifier token is skipped"
_pipe_out=$(tail -1 <<<"$out_two") && grep -qxF "replay-hook: fixture-two: 0/6 commands blocked across 2 files (INERT: FIXTURE_ARM_VAR unset or empty)" <<<"$_pipe_out" \
  && ok "two-var field: summary carries exactly one INERT suffix" || bad "two-var field summary: $(echo "$out_two" | tail -1)"
# An empty REPLAY-ARMED-BY line names nothing: no crash under set -u, no warning.
cat > "$ARM/plugins/seyag/hooks/fixture-empty.sh" <<'EOF'
#!/bin/bash
# REPLAY-ARMED-BY:
exit 0
EOF
out_empty=$("$ARM_RH" fixture-empty --since 1 --slug proj-slug --projects-dir "$T" 2>&1); rc=$?
[ "$rc" -eq 0 ] && _pipe_out=$(tail -1 <<<"$out_empty") && grep -qxF "replay-hook: fixture-empty: 0/6 commands blocked across 2 files" <<<"$_pipe_out" \
  && ok "empty REPLAY-ARMED-BY line: runs clean, no warning" || bad "empty REPLAY-ARMED-BY line: rc=$rc $(echo "$out_empty" | tail -1)"
rm -rf "$ARM"

# The real hook carries the field, and the real replay names the unset switch.
/usr/bin/grep -qxF '# REPLAY-ARMED-BY: SYG_PRIVATE_TERMS_FILE' "$REPO/plugins/seyag/hooks/private-term-guard.sh" \
  && ok "private-term-guard.sh carries the REPLAY-ARMED-BY field" || bad "private-term-guard.sh lacks the REPLAY-ARMED-BY field"
out_ptg=$(env -u SYG_PRIVATE_TERMS_FILE "$RH" private-term-guard --since 1 --slug proj-slug --projects-dir "$T" 2>&1)
grep -qxF "replay-hook: warning: private-term-guard is inert without SYG_PRIVATE_TERMS_FILE (unset or empty here); export it for this run" <<<"$out_ptg" \
  && ok "real private-term-guard replay with the switch unset: warning printed" || bad "real private-term-guard replay: no warning"

# Replay state isolation: a hook that keeps state under XDG_STATE_HOME or
# XDG_RUNTIME_DIR must never touch the caller's own state, and each file
# starts with empty state that its commands share (a file's second command
# sees its first); the next file starts empty.
ST=$(mktemp -d)
mkdir -p "$ST/tests" "$ST/plugins/seyag/hooks"
cp "$RH" "$ST/tests/replay-hook.sh"
ST_RH="$ST/tests/replay-hook.sh"
cat > "$ST/plugins/seyag/hooks/fixture-state.sh" <<'EOF'
#!/bin/bash
# Keeps a hit file under XDG_STATE_HOME; blocks from the second call on.
d="${XDG_STATE_HOME:-$HOME/.local/state}/seyag/fixture-state"
mkdir -p "$d"
had=0
[ -s "$d/hits" ] && had=1
echo hit >>"$d/hits"
if [ "$had" -eq 1 ]; then
  echo "XDG_STATE_HOME=${XDG_STATE_HOME:-}"
  exit 2
fi
exit 0
EOF
cat > "$ST/plugins/seyag/hooks/fixture-runtime.sh" <<'EOF'
#!/bin/bash
# Writes a marker under XDG_RUNTIME_DIR; always passes.
if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
  mkdir -p "$XDG_RUNTIME_DIR" && echo x >"$XDG_RUNTIME_DIR/x"
fi
exit 0
EOF
out_st1=$(XDG_STATE_HOME="$T/caller-state" "$ST_RH" fixture-state --since 1 --slug proj-slug --projects-dir "$T" 2>&1)
[ -z "$(ls -A "$T/caller-state" 2>/dev/null)" ] \
  && ok "state fixture: the caller's XDG_STATE_HOME is untouched" \
  || bad "state fixture wrote the caller's XDG_STATE_HOME: $(ls -A "$T/caller-state")"
_pipe_out=$(tail -1 <<<"$out_st1") && grep -qxF "replay-hook: fixture-state: 4/6 commands blocked across 2 files" <<<"$_pipe_out" \
  && ok "state fixture: state persists within a file (each file's first command passes, the other commands block)" \
  || bad "state fixture within-file count: $(echo "$out_st1" | tail -1)"
out_st2=$(XDG_STATE_HOME="$T/caller-state" "$ST_RH" fixture-state --since 1 --slug proj-slug --projects-dir "$T" 2>&1)
[ "$(echo "$out_st1" | tail -1)" = "$(echo "$out_st2" | tail -1)" ] \
  && ok "state fixture: a second replay gives the same summary (each run starts empty)" \
  || bad "state fixture: second replay differs: $(echo "$out_st2" | tail -1)"
XDG_RUNTIME_DIR="$T/caller-run" "$ST_RH" fixture-runtime --since 1 --slug proj-slug --projects-dir "$T" >/dev/null 2>&1
[ -z "$(ls -A "$T/caller-run" 2>/dev/null)" ] \
  && ok "runtime fixture: the caller's XDG_RUNTIME_DIR is untouched" \
  || bad "runtime fixture wrote the caller's XDG_RUNTIME_DIR: $(ls -A "$T/caller-run")"
rm -rf "$ST"

# Ack-shaped masking fixture: a hook that blocks once and then acks itself in
# state (the pr-body-ack shape). Two JSONL sessions in ONE run replay the same
# command: with state fresh per file both block; a run that let session 1's
# ack mask session 2 would block only the first (1/2).
AK=$(mktemp -d)
mkdir -p "$AK/tests" "$AK/plugins/seyag/hooks"
cp "$RH" "$AK/tests/replay-hook.sh"
AK_RH="$AK/tests/replay-hook.sh"
cat > "$AK/plugins/seyag/hooks/fixture-ack.sh" <<'EOF'
#!/bin/bash
# pr-body-ack shape: the first call blocks and writes the ack line; a later
# call that finds the line passes.
d="${XDG_STATE_HOME:-$HOME/.local/state}/seyag/fixture-ack"
mkdir -p "$d"
if [ -s "$d/hits" ]; then
  exit 0
fi
echo hit >>"$d/hits"
exit 2
EOF
mkdir -p "$AK/proj-slug"
printf '%s\n' '{"type":"assistant","cwd":"/tmp/fixture-project","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo same"}}]}}' \
  > "$AK/proj-slug/sess-a.jsonl"
cp "$AK/proj-slug/sess-a.jsonl" "$AK/proj-slug/sess-b.jsonl"
out_ak=$(XDG_STATE_HOME="$T/caller-state" "$AK_RH" fixture-ack --since 1 --slug proj-slug --projects-dir "$AK" 2>&1)
_pipe_out=$(tail -1 <<<"$out_ak") && grep -qxF "replay-hook: fixture-ack: 2/2 commands blocked across 2 files" <<<"$_pipe_out" \
  && ok "ack fixture: both sessions block (session 2 does not see session 1's ack)" \
  || bad "ack fixture masking summary: $(echo "$out_ak" | tail -1)"
[ -z "$(ls -A "$T/caller-state" 2>/dev/null)" ] \
  && ok "ack fixture: the caller's XDG_STATE_HOME is untouched" \
  || bad "ack fixture wrote the caller's XDG_STATE_HOME: $(ls -A "$T/caller-state")"
rm -rf "$AK"

# Review round 1: the caller's own overrides must not reach a hook. Each one the
# hooks honour points into $T; the fixture writes through it, or through its
# fallback when unset. XDG_STATE_HOME is set too, so no fallback reaches HOME.
ST2=$(mktemp -d)
mkdir -p "$ST2/tests" "$ST2/plugins/seyag/hooks"
cp "$RH" "$ST2/tests/replay-hook.sh"
ST2_RH="$ST2/tests/replay-hook.sh"
cat > "$ST2/plugins/seyag/hooks/fixture-files.sh" <<'EOF'
#!/bin/bash
# Writes one marker through each override a hook honours, else its fallback.
fb="${XDG_STATE_HOME:-$HOME/.local/state}/fallback"
mkdir -p "$fb"
echo x >>"${SYG_PR_MONITOR_SEEN_FILE:-$fb/seen}"
echo x >>"${SYG_PR_BODY_ACK_FILE:-$fb/ack}"
d="${SYG_STATE_DIR:-$fb}"
mkdir -p "$d"
echo x >>"$d/marker"
# Persist-path overrides (review round 2): a ledger file, a dispatch ack file
# and a launch-record dir, each written through when set, else to its fallback.
echo x >>"${SYG_CREDIT_LEDGER:-$fb/credit}"
echo x >>"${SYG_CLASSIFIER_LEDGER:-$fb/classifier}"
echo x >>"${SYG_DISPATCH_ACK_FILE:-$fb/dispatch-ack}"
rd="${SYG_LAUNCH_RECORD_DIR:-$fb/launch}"
mkdir -p "$rd"
echo x >>"$rd/record"
exit 0
EOF
SYG_PR_MONITOR_SEEN_FILE="$T/caller-seen" SYG_PR_BODY_ACK_FILE="$T/caller-ack" SYG_STATE_DIR="$T/caller-syg" \
  SYG_LAUNCH_RECORD_DIR="$T/caller-launch" SYG_CREDIT_LEDGER="$T/caller-credit" \
  SYG_CLASSIFIER_LEDGER="$T/caller-classifier" SYG_DISPATCH_ACK_FILE="$T/caller-dispatch-ack" \
  XDG_STATE_HOME="$T/caller-state2" "$ST2_RH" fixture-files --since 1 --slug proj-slug --projects-dir "$T" >/dev/null 2>&1
[ ! -e "$T/caller-seen" ] && [ ! -e "$T/caller-ack" ] && [ ! -e "$T/caller-syg" ] \
  && ok "caller overrides (SEEN, ACK, SYG_STATE_DIR) never reach a replayed hook" \
  || bad "a caller override reached the hook: $(ls -A "$T" | tr '\n' ' ')"
[ ! -e "$T/caller-launch" ] && [ ! -e "$T/caller-credit" ] && [ ! -e "$T/caller-classifier" ] && [ ! -e "$T/caller-dispatch-ack" ] \
  && ok "caller persist-path overrides (LAUNCH_RECORD_DIR, CREDIT_LEDGER, CLASSIFIER_LEDGER, DISPATCH_ACK_FILE) never reach a replayed hook" \
  || bad "caller persist-path overrides (LAUNCH_RECORD_DIR, CREDIT_LEDGER, CLASSIFIER_LEDGER, DISPATCH_ACK_FILE) never reach a replayed hook: $(ls -A "$T" | tr '\n' ' ')"
rm -rf "$ST2"

# Session-gated hook in replay (TASK-25): cwd-drift-guard warns once per session
# and linked worktree, so its first bare `git commit` from a linked worktree
# blocks and the repeat in the same session passes. The gate keys on the
# payload's session_id (cwd-drift-guard.sh:236-247, 447-452, 559, 586): without
# one it fails open and blocks nothing, so this case is red until the replay
# payload carries the id. Each file is one session, so each file blocks once
# (2/4 across 2 files) and the repeat in each file passes.
mkdir -p "$T/wt-main"
git -C "$T/wt-main" init -q -b main
git -C "$T/wt-main" -c user.email=fixture@example.invalid -c user.name=fixture commit -q --allow-empty -m init
git -C "$T/wt-main" worktree add -q -b fixture-wt "$T/wt-linked" 2>/dev/null
mkdir -p "$T/wt-slug"
for n in 1 2; do
  printf '%s\n' \
    "{\"type\":\"assistant\",\"cwd\":\"$T/wt-linked\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"git commit -m one\"}}]}}" \
    "{\"type\":\"assistant\",\"cwd\":\"$T/wt-linked\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"git commit -m two\"}}]}}" \
    > "$T/wt-slug/replay-fixture-$n.jsonl"
done
out_wt=$("$RH" cwd-drift-guard --since 1 --slug wt-slug --projects-dir "$T" 2>&1)
_pipe_out=$(tail -1 <<<"$out_wt") && grep -qxF "replay-hook: cwd-drift-guard: 2/4 commands blocked across 2 files" <<<"$_pipe_out" \
  && ok "linked-worktree session gate: each file blocks its first git commit and passes the repeat (2/4 across 2 files)" \
  || bad "linked-worktree session gate: $(echo "$out_wt" | tail -1)"
grep -qxF "command: git commit -m one" <<<"$out_wt" \
  && ! grep -qxF "command: git commit -m two" <<<"$out_wt" \
  && ok "linked-worktree session gate: the blocked command is the first git commit, and the repeat is not blocked" \
  || bad "linked-worktree session gate: blocked command text missing, or the repeat was blocked"

# Subagent transcript under the same gate (TASK-25 review round 1). Its payload
# carries no agent_id, so the gate key is the parent session's id: the first
# bare git commit blocks and the repeat passes. An empty or dropped id reads
# as ungated (0/2).
mkdir -p "$T/wt-sub/replay-fixture-parent/subagents"
printf '%s\n' \
  "{\"type\":\"assistant\",\"cwd\":\"$T/wt-linked\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"git commit -m one\"}}]}}" \
  "{\"type\":\"assistant\",\"cwd\":\"$T/wt-linked\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"git commit -m two\"}}]}}" \
  > "$T/wt-sub/replay-fixture-parent/subagents/replay-fixture-agent-1.jsonl"
out_sub=$("$RH" cwd-drift-guard --since 1 --slug wt-sub --projects-dir "$T" 2>&1)
_pipe_out=$(tail -1 <<<"$out_sub") && grep -qxF "replay-hook: cwd-drift-guard: 1/2 commands blocked across 1 files" <<<"$_pipe_out" \
  && grep -qxF "command: git commit -m one" <<<"$out_sub" \
  && ok "subagent session gate: the subagent's first git commit blocks and its repeat passes (1/2 across 1 file)" \
  || bad "subagent session gate: $(echo "$out_sub" | tail -1)"

# Derived session_id, pinned by value (TASK-25 review round 1). A fixture hook
# blocks every call and echoes the session_id it was handed, so these lines pin
# the derivation: a top-level transcript passes its filename stem, a subagent
# transcript passes its parent session's directory name.
SIDT=$(mktemp -d)
mkdir -p "$SIDT/tests" "$SIDT/plugins/seyag/hooks" "$SIDT/sid-slug/replay-fixture-parent/subagents"
cp "$RH" "$SIDT/tests/replay-hook.sh"
SIDT_RH="$SIDT/tests/replay-hook.sh"
cat > "$SIDT/plugins/seyag/hooks/fixture-sid.sh" <<'EOF'
#!/bin/bash
# Blocks every call and echoes the session_id it was handed.
echo "sid=$(jq -r '.session_id // ""')"
exit 2
EOF
printf '%s\n' '{"type":"assistant","cwd":"/tmp/fixture-project","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}' \
  > "$SIDT/sid-slug/replay-fixture-1.jsonl"
printf '%s\n' '{"type":"assistant","cwd":"/tmp/fixture-project","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}' \
  > "$SIDT/sid-slug/replay-fixture-parent/subagents/replay-fixture-agent-1.jsonl"
out_sid=$("$SIDT_RH" fixture-sid --since 1 --slug sid-slug --projects-dir "$SIDT" 2>&1)
grep -qxF "sid=replay-fixture-1" <<<"$out_sid" \
  && ok "derived session_id: a top-level transcript passes its filename stem (replay-fixture-1)" \
  || bad "derived session_id: top-level stem not received: $(echo "$out_sid" | head -3 | tr '\n' ' ')"
grep -qxF "sid=replay-fixture-parent" <<<"$out_sid" \
  && ok "derived session_id: a subagent transcript passes its parent directory name (replay-fixture-parent)" \
  || bad "derived session_id: subagent parent id not received: $(echo "$out_sid" | head -3 | tr '\n' ' ')"
_pipe_out=$(tail -1 <<<"$out_sid") && grep -qxF "replay-hook: fixture-sid: 2/2 commands blocked across 2 files" <<<"$_pipe_out" \
  && ok "derived session_id: both fixture transcripts replayed (2/2 across 2 files)" \
  || bad "derived session_id: summary $(echo "$out_sid" | tail -1)"
rm -rf "$SIDT"

# AskUserQuestion replay support (TASK-65):
# - PreToolUse prefix is cut BEFORE the first line whose record carries the
#   ask's message.id, so same-message pre-ask text (line 2, msg-ask-1) is not
#   in the prefix handed to ask-pretext-guard (ask 1 passes; ask 2 blocks on its
#   pointer phrase -> 1/2 asks blocked).
# - PostToolUse prefix is cut UP TO AND INCLUDING the line holding the ask's
#   tool_use (line 3, msg-ask-1), so same-message pre-ask text (line 2) IS in
#   the prefix handed to ask-pretext-reminder (ask 1 fires on stdout -> 1/2
#   asks blocked; ask 2 has no pre-ask text and stays silent).
mkdir -p "$T/ask-slug"
cat > "$T/ask-slug/ask-session.jsonl" <<'EOF'
{"type":"user","uuid":"u-ask-1","isMeta":null,"message":{"content":"start turn 1"}}
{"type":"assistant","cwd":"/tmp/fixture-project","message":{"id":"msg-ask-1","content":[{"type":"text","text":"Same-message pre-ask command: ! echo same-msg-only"}]}}
{"type":"assistant","cwd":"/tmp/fixture-project","message":{"id":"msg-ask-1","content":[{"type":"tool_use","id":"tu-ask-1","name":"AskUserQuestion","input":{"questions":[{"question":"Proceed with turn 1?","options":[]}]}}]}}
{"type":"user","uuid":"u-ask-2","isMeta":null,"message":{"content":"start turn 2"}}
{"type":"assistant","cwd":"/tmp/fixture-project","message":{"id":"msg-ask-2","content":[{"type":"tool_use","id":"tu-ask-2","name":"AskUserQuestion","input":{"questions":[{"question":"Run the step in my message above?","options":[]}]}}]}}
EOF

out_ask_pre=$("$RH" ask-pretext-guard --tool AskUserQuestion --event PreToolUse --since 1 --slug ask-slug --projects-dir "$T" 2>&1)
_pipe_out=$(tail -1 <<<"$out_ask_pre") && grep -qxF "replay-hook: ask-pretext-guard: 1/2 asks blocked across 1 files" <<<"$_pipe_out" \
  && ok "AskUserQuestion PreToolUse replay: prefix excludes same-message text (1/2 asks blocked)" \
  || bad "AskUserQuestion PreToolUse replay summary: $(echo "$out_ask_pre" | tail -1)"
grep -qxF "ask: Run the step in my message above?" <<<"$out_ask_pre" \
  && ! grep -qxF "ask: Proceed with turn 1?" <<<"$out_ask_pre" \
  && ok "AskUserQuestion PreToolUse replay: pointer ask blocked, same-message command ask passed" \
  || bad "AskUserQuestion PreToolUse replay blocked set wrong: $out_ask_pre"

out_ask_post=$("$RH" ask-pretext-reminder --tool AskUserQuestion --event PostToolUse --since 1 --slug ask-slug --projects-dir "$T" 2>&1)
_pipe_out=$(tail -1 <<<"$out_ask_post") && grep -qxF "replay-hook: ask-pretext-reminder: 1/2 asks blocked across 1 files" <<<"$_pipe_out" \
  && ok "AskUserQuestion PostToolUse replay: prefix includes same-message text and non-empty stdout counts as hit (1/2 asks blocked)" \
  || bad "AskUserQuestion PostToolUse replay summary: $(echo "$out_ask_post" | tail -1)"
grep -qxF "ask: Proceed with turn 1?" <<<"$out_ask_post" \
  && grep -qF "ask-pretext-reminder: you wrote" <<<"$out_ask_post" \
  && ! grep -qxF "ask: Run the step in my message above?" <<<"$out_ask_post" \
  && ok "AskUserQuestion PostToolUse replay: same-message command ask triggered reminder, pointer-only ask stayed silent" \
  || bad "AskUserQuestion PostToolUse replay hit set wrong: $out_ask_post"

exit $fail
