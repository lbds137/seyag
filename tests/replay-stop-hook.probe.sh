#!/bin/bash
# Fixture check for tests/replay-stop-hook.sh — self-contained synthetic
# projects dir, never touches real session logs.
# Usage: tests/replay-stop-hook.probe.sh   (from anywhere)

set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RSH="$REPO/tests/replay-stop-hook.sh"
BQ="$REPO/plugins/seyag/hooks/blocking-question-channel-check.sh"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

mkdir -p "$T/proj-slug" "$T/other-slug"

# RECORDED-mode fixture (a stop_hook_summary is present): two bq trips, one
# tesg trip, zero promise-ledger-check trips, one live block, across 5 turn
# ends, PLUS one mid-turn injection (a Skill-directory content block, the
# observed real shape) that a summary-blind rule would wrongly count as a
# 6th turn end.
cat > "$T/proj-slug/session1.jsonl" <<'EOF'
this line is not JSON at all
{"type":"user","message":{"role":"user","content":"start"}}
{"type":"assistant","isSidechain":false,"cwd":"/tmp/fixture-project","message":{"role":"assistant","content":[{"type":"text","text":"Should I proceed with the rename?"}]}}
{"type":"system","subtype":"stop_hook_summary","hookCount":3}
{"type":"user","message":{"role":"user","content":"yes"}}
{"type":"assistant","isSidechain":false,"cwd":"/tmp/fixture-project","message":{"role":"assistant","content":[{"type":"text","text":"Running it."}]}}
{"type":"assistant","isSidechain":false,"cwd":"/tmp/fixture-project","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}
{"type":"user","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill: /x"}]}}
{"type":"system","subtype":"stop_hook_summary","hookCount":3}
{"type":"user","isMeta":true,"message":{"role":"user","content":"Another Claude session sent a message: hi"}}
{"type":"assistant","isSidechain":false,"cwd":"/tmp/fixture-project","message":{"role":"assistant","content":[{"type":"text","text":"Done, nothing else needed."}]}}
{"type":"system","subtype":"stop_hook_summary","hookCount":3}
{"type":"user","message":{"role":"user","content":"one more"}}
{"type":"assistant","isSidechain":false,"cwd":"/tmp/fixture-project","message":{"role":"assistant","content":[{"type":"text","text":"Which branch should I use?"}]}}
{"type":"system","subtype":"stop_hook_summary","hookCount":3}
{"type":"user","isMeta":true,"message":{"role":"user","content":"Stop hook feedback:\n[bash \"/x/run.sh\" blocking-question-channel-check]: BLOCKING QUESTION ..."}}
{"type":"assistant","isSidechain":false,"cwd":"/tmp/fixture-project","message":{"role":"assistant","content":[{"type":"text","text":"Should I stop here?"}]}}
{"type":"system","subtype":"stop_hook_summary","hookCount":3}
EOF

# INFERRED-mode fixture (no stop_hook_summary anywhere, and no feedback/
# "Noted" tail): the same injection now IS a turn end (no summary to require),
# and the cross-session entry right after it is NOT one (no assistant entry
# occurred between them) — the purpose canary for the mode split.
cat > "$T/other-slug/session2.jsonl" <<'EOF'
this line is not JSON at all
{"type":"user","message":{"role":"user","content":"start"}}
{"type":"assistant","isSidechain":false,"cwd":"/tmp/fixture-project","message":{"role":"assistant","content":[{"type":"text","text":"Should I proceed with the rename?"}]}}
{"type":"user","message":{"role":"user","content":"yes"}}
{"type":"assistant","isSidechain":false,"cwd":"/tmp/fixture-project","message":{"role":"assistant","content":[{"type":"text","text":"Running it."}]}}
{"type":"assistant","isSidechain":false,"cwd":"/tmp/fixture-project","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}
{"type":"user","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill: /x"}]}}
{"type":"user","isMeta":true,"message":{"role":"user","content":"Another Claude session sent a message: hi"}}
{"type":"assistant","isSidechain":false,"cwd":"/tmp/fixture-project","message":{"role":"assistant","content":[{"type":"text","text":"Done, nothing else needed."}]}}
{"type":"user","message":{"role":"user","content":"one more"}}
{"type":"assistant","isSidechain":false,"cwd":"/tmp/fixture-project","message":{"role":"assistant","content":[{"type":"text","text":"Which branch should I use?"}]}}
EOF

# Positive controls: blocking-question-channel-check.sh trips directly on a
# 2-line transcript ending in a question, and is silenced by stop_hook_active.
printf '%s\n%s\n' \
  '{"type":"user","message":{"role":"user","content":"start"}}' \
  '{"type":"assistant","isSidechain":false,"cwd":"/tmp/fixture-project","message":{"role":"assistant","content":[{"type":"text","text":"Should I proceed with the rename?"}]}}' \
  > "$T/two-line.jsonl"

jq -n --arg tp "$T/two-line.jsonl" '{session_id:"x",transcript_path:$tp,cwd:"/tmp/fixture-project",hook_event_name:"Stop",stop_hook_active:false}' \
  | env -u CLAUDE_PROJECT_DIR bash "$BQ" >/dev/null 2>&1
[ $? -ne 0 ] && ok "positive control: bq trips on the 2-line fixture with stop_hook_active:false" \
  || bad "positive control: bq did not trip with stop_hook_active:false"

jq -n --arg tp "$T/two-line.jsonl" '{session_id:"x",transcript_path:$tp,cwd:"/tmp/fixture-project",hook_event_name:"Stop",stop_hook_active:true}' \
  | env -u CLAUDE_PROJECT_DIR bash "$BQ" >/dev/null 2>&1
[ $? -eq 0 ] && ok "positive control: bq is silenced by stop_hook_active:true" \
  || bad "positive control: bq did not exit 0 with stop_hook_active:true"

# The three Stop hooks against the RECORDED fixture (5 turn ends: A-E; A and D
# trip bq, B trips tesg, none trip promise-ledger-check; the injection at
# line 9 is skipped, not a 6th turn end).
out=$("$RSH" blocking-question-channel-check --since 1 --slug proj-slug --projects-dir "$T")
_pipe_out=$(tail -1 <<<"$out") && grep -qxF "replay-stop-hook: blocking-question-channel-check: 2/5 turn ends tripped across 1 files (0/0 inferred in 0 files without Stop records); 1 live blocks in the logs" <<<"$_pipe_out" \
  && ok "bq summary: 2/5 tripped across 1 files, 0 inferred; 1 live block" || bad "bq summary: $(echo "$out" | tail -1)"
grep -qF "text: Should I proceed with the rename?" <<<"$out" \
  && ok "bq tripped section carries the closing question text" || bad "bq tripped text missing"
grep -qxF "entry: proj-slug/session1.jsonl:5" <<<"$out" \
  && ok "bq tripped section carries the cut entry's slug/file:line" || bad "bq tripped entry line missing"
grep -qF "mode: recorded" <<<"$out" \
  && ok "bq tripped section names its mode" || bad "bq tripped section missing mode: line"
# E's closing text now ends on "?" too (a stop_hook_active mirroring check: E
# is silenced because D's ending entry was a "Stop hook feedback:" entry) —
# still 2/5, and no tripped section at EOF.
_pipe_out=$(tail -1 <<<"$out") && grep -qxF "replay-stop-hook: blocking-question-channel-check: 2/5 turn ends tripped across 1 files (0/0 inferred in 0 files without Stop records); 1 live blocks in the logs" <<<"$_pipe_out" \
  && ok "bq stays 2/5 with E's closing text also ending in '?'" || bad "bq summary changed: $(echo "$out" | tail -1)"
grep -qxF "entry: proj-slug/session1.jsonl:EOF" <<<"$out" \
  && bad "bq tripped at EOF — stop_hook_active mirroring is not suppressing E" \
  || ok "no EOF tripped section — stop_hook_active mirroring silences E"

out=$("$RSH" turn-end-shape-gate --since 1 --slug proj-slug --projects-dir "$T")
_pipe_out=$(tail -1 <<<"$out") && grep -qxF "replay-stop-hook: turn-end-shape-gate: 1/5 turn ends tripped across 1 files (0/0 inferred in 0 files without Stop records); 0 live blocks in the logs" <<<"$_pipe_out" \
  && ok "tesg summary: 1/5 tripped across 1 files, 0 inferred; 0 live blocks" || bad "tesg summary: $(echo "$out" | tail -1)"
grep -qxF "entry: proj-slug/session1.jsonl:11" <<<"$out" \
  && ok "tesg trip's entry: line is the cross-session entry, not the injection" || bad "tesg tripped entry line missing/wrong"

out=$("$RSH" promise-ledger-check --since 1 --slug proj-slug --projects-dir "$T")
_pipe_out=$(tail -1 <<<"$out") && grep -qxF "replay-stop-hook: promise-ledger-check: 0/5 turn ends tripped across 1 files (0/0 inferred in 0 files without Stop records); 0 live blocks in the logs" <<<"$_pipe_out" \
  && ok "promise-ledger-check summary: 0/5 tripped across 1 files, 0 inferred; 0 live blocks" || bad "promise-ledger-check summary: $(echo "$out" | tail -1)"

# Purpose canary: other-slug is INFERRED (no stop_hook_summary anywhere) — the
# injection now IS a turn end, the cross-session entry right after it is not
# (no assistant entry between them), and no feedback entry means 0 live blocks.
out=$("$RSH" blocking-question-channel-check --since 1 --slug other-slug --projects-dir "$T")
_pipe_out=$(tail -1 <<<"$out") && grep -qxF "replay-stop-hook: blocking-question-channel-check: 2/4 turn ends tripped across 1 files (2/4 inferred in 1 files without Stop records); 0 live blocks in the logs" <<<"$_pipe_out" \
  && ok "purpose canary: other-slug (INFERRED, no summaries) — 2/4 tripped across 1 files, all 4 inferred; 0 live blocks" \
  || bad "purpose canary: $(echo "$out" | tail -1)"

# Argument handling, mirroring replay-hook.probe.sh's exit-code checks.
"$RSH" lossy-pipe-guard --slug proj-slug --projects-dir "$T" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "a PreToolUse hook name (lossy-pipe-guard) is refused, exit 2" || bad "lossy-pipe-guard exit=$rc"

"$RSH" no-such-hook --slug proj-slug --projects-dir "$T" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "unknown hook name exits 2" || bad "unknown hook name exit=$rc"

out0=$("$RSH" blocking-question-channel-check --since 0 --slug proj-slug --projects-dir "$T")
_pipe_out=$(tail -1 <<<"$out0") && grep -qxF "replay-stop-hook: blocking-question-channel-check: 0/0 turn ends tripped across 0 files (0/0 inferred in 0 files without Stop records); 0 live blocks in the logs" <<<"$_pipe_out" \
  && ok "--since 0 (impossible window) yields 0/0 across 0 files; 0 live blocks" || bad "--since 0: $(echo "$out0" | tail -1)"

"$RSH" blocking-question-channel-check --slug nope --projects-dir "$T" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "--slug nope (nonexistent dir) exits 2" || bad "--slug nope exit=$rc"

# Crash safety: a per-file replay failure (here, permission denied) must fail
# loudly — exit 1, a stderr line naming the file, and NO summary line, so a
# partial count is never mistaken for a total.
mkdir -p "$T/crash-slug"
BLOCKED="$T/crash-slug/blocked.jsonl"
echo '{"type":"user","message":{"role":"user","content":"start"}}' > "$BLOCKED"
chmod 000 "$BLOCKED"
CRASH_ERR="$T/crash.err"
crash_out=$("$RSH" blocking-question-channel-check --since 1 --slug crash-slug --projects-dir "$T" 2>"$CRASH_ERR")
crash_rc=$?
chmod 644 "$BLOCKED"
[ "$crash_rc" -eq 1 ] && ok "crash safety: exit 1 on a permission-denied file" || bad "crash safety exit=$crash_rc"
grep -q "turn ends tripped" <<<"$crash_out" \
  && bad "crash safety: a summary line printed on stdout despite the crash" \
  || ok "crash safety: no summary line printed on stdout"
grep -qE '^replay-stop-hook: replay failed on .*/crash-slug/blocked\.jsonl \(python exit [0-9]+\)$' "$CRASH_ERR" \
  && ok "crash safety: stderr names the failing file and python's exit code" \
  || bad "crash safety: stderr missing/wrong: $(cat "$CRASH_ERR")"

# REPLAY-ARMED-BY for Stop hooks: the script reads its Stop list from hooks.json,
# so the fixture is a copy of the tree with a one-entry hooks.json naming the
# fixture hook (the real plugins/ dir gains nothing).
ARM=$(mktemp -d)
mkdir -p "$ARM/tests" "$ARM/plugins/seyag/hooks"
cp "$RSH" "$ARM/tests/replay-stop-hook.sh"
cat > "$ARM/plugins/seyag/hooks/fixture-armed.sh" <<'EOF'
#!/bin/bash
# REPLAY-ARMED-BY: FIXTURE_ARM_VAR
[ -n "${FIXTURE_ARM_VAR:-}" ] || exit 0
exit 2
EOF
cat > "$ARM/plugins/seyag/hooks/hooks.json" <<'EOF'
{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"bash \"${CLAUDE_PLUGIN_ROOT}/hooks/run.sh\" fixture-armed"}]}]}}
EOF
ARM_RSH="$ARM/tests/replay-stop-hook.sh"

stop_unset=$(env -u FIXTURE_ARM_VAR "$ARM_RSH" fixture-armed --since 1 --slug proj-slug --projects-dir "$T" 2>&1)
_pipe_out=$(head -1 <<<"$stop_unset") && grep -qxF "replay-stop-hook: warning: fixture-armed is inert without FIXTURE_ARM_VAR (unset or empty here); export it for this run" <<<"$_pipe_out" \
  && ok "unarmed stop replay: warning printed before the replay" || bad "unarmed stop replay: first line is $(echo "$stop_unset" | head -1)"
_pipe_out=$(tail -1 <<<"$stop_unset") && grep -qF " (INERT: FIXTURE_ARM_VAR unset or empty)" <<<"$_pipe_out" \
  && ok "unarmed stop replay: summary line carries (INERT: FIXTURE_ARM_VAR unset or empty)" || bad "unarmed stop replay: summary $(echo "$stop_unset" | tail -1)"

stop_set=$(FIXTURE_ARM_VAR=1 "$ARM_RSH" fixture-armed --since 1 --slug proj-slug --projects-dir "$T" 2>&1)
grep -qF "replay-stop-hook: warning:" <<<"$stop_set" \
  && bad "armed stop replay: warning printed although the variable is set" || ok "armed stop replay: no warning"
grep -qF "(INERT:" <<<"$stop_set" \
  && bad "armed stop replay: summary marked INERT although the variable is set" || ok "armed stop replay: summary not marked INERT"
_pipe_out=$(tail -1 <<<"$stop_set") && grep -qE ': [1-9][0-9]*/[0-9]+ turn ends tripped across ' <<<"$_pipe_out" \
  && ok "armed stop replay: the fixture hook trips turn ends" || bad "armed stop replay: $(echo "$stop_set" | tail -1)"
rm -rf "$ARM"

# api-credit-ledger.sh carries no field: it writes the ledger, and the field is
# for gates only (a replay must not run a side-effect hook with the switch set).
ACL="$REPO/plugins/seyag/hooks/api-credit-ledger.sh"
[ -f "$ACL" ] && ! /usr/bin/grep -qxF '# REPLAY-ARMED-BY: SYG_CREDIT_LEDGER' "$ACL" \
  && ok "api-credit-ledger.sh exists and carries no REPLAY-ARMED-BY field" \
  || bad "api-credit-ledger.sh is missing, or carries the REPLAY-ARMED-BY field (it writes the ledger)"

# An empty REPLAY-ARMED-BY line names nothing: no crash under set -u.
ARM0=$(mktemp -d)
mkdir -p "$ARM0/tests" "$ARM0/plugins/seyag/hooks"
cp "$RSH" "$ARM0/tests/replay-stop-hook.sh"
printf '#!/bin/bash\n# REPLAY-ARMED-BY:\nexit 0\n' > "$ARM0/plugins/seyag/hooks/fixture-empty.sh"
printf '%s\n' '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"bash run.sh fixture-empty"}]}]}}' > "$ARM0/plugins/seyag/hooks/hooks.json"
out_e=$("$ARM0/tests/replay-stop-hook.sh" fixture-empty --since 1 --slug proj-slug --projects-dir "$T" 2>&1); rc=$?
[ "$rc" -eq 0 ] && _pipe_out=$(tail -1 <<<"$out_e") && grep -qF "replay-stop-hook: fixture-empty: " <<<"$_pipe_out" \
  && ok "empty REPLAY-ARMED-BY line (stop): runs clean, no crash" || bad "empty REPLAY-ARMED-BY line (stop): rc=$rc $(echo "$out_e" | tail -1)"
rm -rf "$ARM0"

# Replay state isolation for Stop hooks: the hook keeps state under
# XDG_STATE_HOME and must never touch the caller's; each file starts empty and
# its turn ends share the state (the first passes, the other four trip).
ST=$(mktemp -d)
mkdir -p "$ST/tests" "$ST/plugins/seyag/hooks"
cp "$RSH" "$ST/tests/replay-stop-hook.sh"
cat > "$ST/plugins/seyag/hooks/fixture-state.sh" <<'EOF'
#!/bin/bash
# Keeps a hit file under XDG_STATE_HOME; trips from the second call on.
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
printf '%s\n' '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"bash \"${CLAUDE_PLUGIN_ROOT}/hooks/run.sh\" fixture-state"}]}]}}' > "$ST/plugins/seyag/hooks/hooks.json"
ST_RSH="$ST/tests/replay-stop-hook.sh"
out_st1=$(XDG_STATE_HOME="$T/stop-caller-state" "$ST_RSH" fixture-state --since 1 --slug proj-slug --projects-dir "$T" 2>&1)
[ -z "$(ls -A "$T/stop-caller-state" 2>/dev/null)" ] \
  && ok "stop state fixture: the caller's XDG_STATE_HOME is untouched" \
  || bad "stop state fixture wrote the caller's XDG_STATE_HOME: $(ls -A "$T/stop-caller-state")"
_pipe_out=$(tail -1 <<<"$out_st1") && grep -qF "replay-stop-hook: fixture-state: 4/5 turn ends tripped across 1 files " <<<"$_pipe_out" \
  && ok "stop state fixture: state persists within a file (4/5 tripped)" \
  || bad "stop state fixture within-file count: $(echo "$out_st1" | tail -1)"
out_st2=$(XDG_STATE_HOME="$T/stop-caller-state" "$ST_RSH" fixture-state --since 1 --slug proj-slug --projects-dir "$T" 2>&1)
[ "$(echo "$out_st1" | tail -1)" = "$(echo "$out_st2" | tail -1)" ] \
  && ok "stop state fixture: a second replay gives the same summary (each run starts empty)" \
  || bad "stop state fixture: second replay differs: $(echo "$out_st2" | tail -1)"
rm -rf "$ST"

# Review round 1: the caller's own overrides must not reach a Stop hook either.
ST2=$(mktemp -d)
mkdir -p "$ST2/tests" "$ST2/plugins/seyag/hooks"
cp "$RSH" "$ST2/tests/replay-stop-hook.sh"
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
exit 0
EOF
printf '%s\n' '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"bash \"${CLAUDE_PLUGIN_ROOT}/hooks/run.sh\" fixture-files"}]}]}}' > "$ST2/plugins/seyag/hooks/hooks.json"
SYG_PR_MONITOR_SEEN_FILE="$T/stop-caller-seen" SYG_PR_BODY_ACK_FILE="$T/stop-caller-ack" SYG_STATE_DIR="$T/stop-caller-syg" \
  XDG_STATE_HOME="$T/stop-caller-state2" "$ST2/tests/replay-stop-hook.sh" fixture-files --since 1 --slug proj-slug --projects-dir "$T" >/dev/null 2>&1
[ ! -e "$T/stop-caller-seen" ] && [ ! -e "$T/stop-caller-ack" ] && [ ! -e "$T/stop-caller-syg" ] \
  && ok "stop: caller overrides (SEEN, ACK, SYG_STATE_DIR) never reach a replayed hook" \
  || bad "stop: a caller override reached the hook: $(ls -A "$T" | tr '\n' ' ')"
rm -rf "$ST2"

exit $fail
