#!/bin/bash
# Hermetic fixture check for plugins/seyag/bin/plugin-release-check:
# purpose canary first, then the 11 claim canaries (with mutation red-tail
# controls for the 8 branch/filter claims), the inclusive >= boundary,
# multi-file transcript aggregation, malformed session rows, and exit-2 errors.
# Usage: tests/plugin-release-check.probe.sh   (from anywhere; never touches real claude or ~/.claude)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRC=${PLUGIN_RELEASE_CHECK_BIN:-"$REPO/plugins/seyag/bin/plugin-release-check"}
[ -x "$PRC" ] || chmod +x "$PRC" 2>/dev/null || true

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
if [ ! -x "$PRC" ]; then
  cp "$PRC" "$T/plugin-release-check"
  chmod +x "$T/plugin-release-check"
  PRC="$T/plugin-release-check"
fi

fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

# Hermetic environment: strip any ambient override and place a poison `claude`
# binary first on PATH so any un-overridden invocation fails loudly.
unset PLUGIN_RELEASE_AGENTS_CMD PLUGIN_RELEASE_PROJECTS
FAKEBIN="$T/fakebin"
mkdir -p "$FAKEBIN" "$T/home/.claude/projects" "$T/projects/proj-a" "$T/projects/proj-b"
cat > "$FAKEBIN/claude" <<'EOF'
#!/bin/sh
echo "poison-claude: real claude binary must never be called" >&2
exit 99
EOF
chmod +x "$FAKEBIN/claude"
export PATH="$FAKEBIN:$PATH"
export HOME="$T/home"

ms_of() {
  local s
  s=$(date -u -d "$1" +%s)
  echo "$((s * 1000))"
}

# Fixture git repository with deterministic commit timestamps.
R="$T/repo"
PDIR="$R/plugins/demo/.claude-plugin"
PJSON="$PDIR/plugin.json"
mkdir -p "$PDIR"
git -C "$R" init -q -b main

cat > "$PJSON" <<'EOF'
{"name": "demo-plugin", "version": "0.4.0"}
EOF
git -C "$R" add plugins/demo/.claude-plugin/plugin.json
GIT_AUTHOR_DATE="2026-10-26T10:00:00Z" GIT_COMMITTER_DATE="2026-10-26T10:00:00Z" \
  git -C "$R" -c user.name=probe -c user.email=probe@example.invalid commit -qm "release 0.4.0"

# Release 0.4.1's commit time is the GIT_*_DATE value on the commit below.
cat > "$PJSON" <<'EOF'
{"name": "demo-plugin", "version": "0.4.1"}
EOF
git -C "$R" add plugins/demo/.claude-plugin/plugin.json
GIT_AUTHOR_DATE="2026-10-26T12:00:00Z" GIT_COMMITTER_DATE="2026-10-26T12:00:00Z" \
  git -C "$R" -c user.name=probe -c user.email=probe@example.invalid commit -qm "release 0.4.1"; SHA_041=$(git -C "$R" rev-parse HEAD)

# Later commit touching plugin.json with bare 0.4.1 in prose (not `"0.4.1"` count change):
# pins that `-S'"0.4.1"'` keeps the bump commit rather than matching the later prose-only touch.
cat > "$PJSON" <<'EOF'
{"name": "demo-plugin", "version": "0.4.1", "description": "notes on 0.4.1 release"}
EOF
git -C "$R" add plugins/demo/.claude-plugin/plugin.json
GIT_AUTHOR_DATE="2026-10-26T13:00:00Z" GIT_COMMITTER_DATE="2026-10-26T13:00:00Z" \
  git -C "$R" -c user.name=probe -c user.email=probe@example.invalid commit -qm "docs note on 0.4.1"; SHA_DOCS=$(git -C "$R" rev-parse HEAD)

PRE_MS=$(ms_of "2026-10-26T11:00:00Z")
BOUND_MS=$(ms_of "2026-10-26T12:00:00Z")
POST_MS=$(ms_of "2026-10-26T12:10:00Z")

run_prc() {
  PLUGIN_RELEASE_AGENTS_CMD="$1" PLUGIN_RELEASE_PROJECTS="$2" "$PRC" "${@:3}"
}

# ==============================================================================
# 0. PURPOSE CANARY (run first; track failure count)
# ==============================================================================
purpose_fail_before=$fail
SID_PURPOSE="00000000-0000-4000-8000-000000000000"
AGENTS_PURPOSE="[{\"pid\":100,\"name\":\"sess-purpose\",\"sessionId\":\"$SID_PURPOSE\",\"startedAt\":$PRE_MS}]"
TF_PURPOSE="$T/projects/proj-a/$SID_PURPOSE.jsonl"

cat > "$TF_PURPOSE" <<'EOF'
{"type":"user","timestamp":"2026-10-26T11:59:00Z","message":{"content":"<command-name>/reload-plugins</command-name>\n<command-message>reload-plugins</command-message>"}}
EOF
out=$(run_prc "printf '%s' '$AGENTS_PURPOSE'" "$T/projects" --plugin-json "$PJSON" 2>&1); rc=$?
if [ "$rc" -eq 1 ] \
  && grep -qxF "plugin-release-check: demo-plugin 0.4.1 (release 2026-10-26T12:00Z)" <<<"$out" \
  && grep -qxF "sess-purpose stale started 2026-10-26T11:00Z, last refresh 2026-10-26T11:59Z < release 2026-10-26T12:00Z" <<<"$out"; then
  ok "purpose canary (1m before release): reports stale and exits 1"
else
  bad "purpose canary (1m before release): rc=$rc out=[$(tr '\n' '|' <<<"$out")]"
fi

cat > "$TF_PURPOSE" <<'EOF'
{"type":"user","timestamp":"2026-10-26T12:01:00Z","message":{"content":"<command-name>/reload-plugins</command-name>\n<command-message>reload-plugins</command-message>"}}
EOF
out=$(run_prc "printf '%s' '$AGENTS_PURPOSE'" "$T/projects" --plugin-json "$PJSON" 2>&1); rc=$?
if [ "$rc" -eq 0 ] \
  && grep -qxF "sess-purpose current started 2026-10-26T11:00Z, refreshed 2026-10-26T12:01Z >= release 2026-10-26T12:00Z" <<<"$out"; then
  ok "purpose canary (1m after release): flips row to current and exits 0"
else
  bad "purpose canary (1m after release): rc=$rc out=[$(tr '\n' '|' <<<"$out")]"
fi
rm -f "$TF_PURPOSE"
purpose_failures=$((fail - purpose_fail_before))
[ "$purpose_failures" -eq 0 ] \
  && ok "purpose canary failure count: $purpose_failures" \
  || bad "purpose canary failure count: $purpose_failures"

# ==============================================================================
# 1..11. CLAIM CANARIES
# ==============================================================================

# Canary 1: A reload after the release makes a pre-release session current.
canary_1() {
  local sid="00000000-0000-4000-8000-000000000001"
  local tf="$T/projects/proj-a/$sid.jsonl"
  local acmd="printf '%s' '[{\"pid\":101,\"name\":\"c1-reloaded\",\"sessionId\":\"$sid\",\"startedAt\":$PRE_MS}]'"
  cat > "$tf" <<'EOF'
{"type":"user","timestamp":"2026-10-26T12:15:00Z","message":{"content":"<command-name>/reload-plugins</command-name>\n<command-message>reload-plugins</command-message>"}}
EOF
  local out rc
  out=$(run_prc "$acmd" "$T/projects" --plugin-json "$PJSON" 2>&1); rc=$?
  rm -f "$tf"
  if [ "$rc" -eq 0 ] && grep -qxF "c1-reloaded current started 2026-10-26T11:00Z, refreshed 2026-10-26T12:15Z >= release 2026-10-26T12:00Z" <<<"$out"; then
    ok "canary 1: reload after release makes pre-release session current"
  else
    bad "canary 1: reload after release makes pre-release session current (rc=$rc out=$(tr '\n' '|' <<<"$out"))"
  fi
}

# Canary 2: A process started after the release is current without any reload.
canary_2() {
  local sid="00000000-0000-4000-8000-000000000002"
  local acmd="printf '%s' '[{\"pid\":102,\"name\":\"c2-poststart\",\"sessionId\":\"$sid\",\"startedAt\":$POST_MS}]'"
  local out rc
  out=$(run_prc "$acmd" "$T/projects" --plugin-json "$PJSON" 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && grep -qxF "c2-poststart current started 2026-10-26T12:10Z >= release 2026-10-26T12:00Z" <<<"$out"; then
    ok "canary 2: process started after release is current without any reload"
  else
    bad "canary 2: process started after release is current without any reload (rc=$rc out=$(tr '\n' '|' <<<"$out"))"
  fi
}

# Canary 3: Any stale row forces exit 1.
canary_3() {
  local sid_ok="00000000-0000-4000-8000-000000000002"
  local sid_st="00000000-0000-4000-8000-000000000003"
  local tf="$T/projects/proj-a/$sid_st.jsonl"
  cat > "$tf" <<'EOF'
{"type":"user","timestamp":"2026-10-26T11:30:00Z","message":{"content":"<command-name>/reload-plugins</command-name>"}}
EOF
  local acmd="printf '%s' '[{\"pid\":102,\"name\":\"c3-cur\",\"sessionId\":\"$sid_ok\",\"startedAt\":$POST_MS},{\"pid\":103,\"name\":\"c3-stale\",\"sessionId\":\"$sid_st\",\"startedAt\":$PRE_MS}]'"
  local out rc
  out=$(run_prc "$acmd" "$T/projects" --plugin-json "$PJSON" 2>&1); rc=$?
  rm -f "$tf"
  if [ "$rc" -eq 1 ] && grep -qxF "c3-stale stale started 2026-10-26T11:00Z, last refresh 2026-10-26T11:30Z < release 2026-10-26T12:00Z" <<<"$out"; then
    ok "canary 3: any stale row forces exit 1"
  else
    bad "canary 3: any stale row forces exit 1 (rc=$rc out=$(tr '\n' '|' <<<"$out"))"
  fi
}

# Canary 4: PLUGIN_RELEASE_AGENTS_CMD is honored.
canary_4() {
  local sid="00000000-0000-4000-8000-000000000004"
  local acmd="printf '%s' '[{\"pid\":104,\"name\":\"c4-shim-agent\",\"sessionId\":\"$sid\",\"startedAt\":$POST_MS}]'"
  local out rc
  out=$(run_prc "$acmd" "$T/projects" --plugin-json "$PJSON" 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && grep -qxF "c4-shim-agent current started 2026-10-26T12:10Z >= release 2026-10-26T12:00Z" <<<"$out"; then
    ok "canary 4: PLUGIN_RELEASE_AGENTS_CMD is honored"
  else
    bad "canary 4: PLUGIN_RELEASE_AGENTS_CMD is honored (rc=$rc out=$(tr '\n' '|' <<<"$out"))"
  fi
}

# Canary 5: PLUGIN_RELEASE_PROJECTS is honored.
canary_5() {
  local sid="00000000-0000-4000-8000-000000000005"
  local alt="$T/alt-projects"
  mkdir -p "$alt/slug-x"
  cat > "$alt/slug-x/$sid.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-10-26T12:18:00Z","message":{"content":"<command-name>/reload-plugins</command-name>"}}
EOF
  local acmd="printf '%s' '[{\"pid\":105,\"name\":\"c5-altproj\",\"sessionId\":\"$sid\",\"startedAt\":$PRE_MS}]'"
  local out rc
  out=$(run_prc "$acmd" "$alt" --plugin-json "$PJSON" 2>&1); rc=$?
  rm -rf "$alt"
  if [ "$rc" -eq 0 ] && grep -qxF "c5-altproj current started 2026-10-26T11:00Z, refreshed 2026-10-26T12:18Z >= release 2026-10-26T12:00Z" <<<"$out"; then
    ok "canary 5: PLUGIN_RELEASE_PROJECTS is honored"
  else
    bad "canary 5: PLUGIN_RELEASE_PROJECTS is honored (rc=$rc out=$(tr '\n' '|' <<<"$out"))"
  fi
}

# Canary 6: Version is read from plugin.json when --version is absent.
canary_6() {
  local sid="00000000-0000-4000-8000-000000000006"
  local acmd="printf '%s' '[{\"pid\":106,\"name\":\"c6-autover\",\"sessionId\":\"$sid\",\"startedAt\":$POST_MS}]'"
  local out rc
  out=$(run_prc "$acmd" "$T/projects" --plugin-json "$PJSON" 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && grep -qxF "plugin-release-check: demo-plugin 0.4.1 (release 2026-10-26T12:00Z)" <<<"$out"; then
    ok "canary 6: version is read from plugin.json when --version is absent"
  else
    bad "canary 6: version is read from plugin.json when --version is absent (rc=$rc out=$(tr '\n' '|' <<<"$out"))"
  fi
}

# Canary 7: A pre-release session with no transcript reports stale, why names the missing transcript.
canary_7() {
  local sid="00000000-0000-4000-8000-000000000007"
  local acmd="printf '%s' '[{\"pid\":107,\"name\":\"c7-notranscript\",\"sessionId\":\"$sid\",\"startedAt\":$PRE_MS}]'"
  local out rc
  out=$(run_prc "$acmd" "$T/projects" --plugin-json "$PJSON" 2>&1); rc=$?
  if [ "$rc" -eq 1 ] && grep -qxF "c7-notranscript stale started 2026-10-26T11:00Z < release 2026-10-26T12:00Z (no transcript file found)" <<<"$out"; then
    ok "canary 7: pre-release session with no transcript reports stale (no transcript file found)"
  else
    bad "canary 7: pre-release session with no transcript (rc=$rc out=$(tr '\n' '|' <<<"$out"))"
  fi
}

# Canary 8: Exit 2 when the version has no release commit.
canary_8() {
  local sid="00000000-0000-4000-8000-000000000008"
  local acmd="printf '%s' '[{\"pid\":108,\"name\":\"c8-nocommit\",\"sessionId\":\"$sid\",\"startedAt\":$POST_MS}]'"
  local out rc
  out=$(run_prc "$acmd" "$T/projects" --plugin-json "$PJSON" --version 9.9.9 2>&1); rc=$?
  if [ "$rc" -eq 2 ] && grep -qF 'no release commit found for version "9.9.9"' <<<"$out"; then
    ok "canary 8: exit 2 when the version has no release commit"
  else
    bad "canary 8: exit 2 when the version has no release commit (rc=$rc out=$(tr '\n' '|' <<<"$out"))"
  fi
}

# Canary 9: Quoted copies are not currency evidence.
canary_9() {
  local sid="00000000-0000-4000-8000-000000000009"
  local tf="$T/projects/proj-a/$sid.jsonl"
  cat > "$tf" <<'EOF'
{"type":"user","timestamp":"2026-10-26T12:20:00Z","message":{"content":[{"type":"tool_result","tool_use_id":"tu1","content":"<command-name>/reload-plugins</command-name>\n<command-name>/clear</command-name>"}]}}
{"type":"assistant","timestamp":"2026-10-26T12:21:00Z","message":{"content":"<command-name>/reload-plugins</command-name>"}}
EOF
  local acmd="printf '%s' '[{\"pid\":109,\"name\":\"c9-quoted\",\"sessionId\":\"$sid\",\"startedAt\":$PRE_MS}]'"
  local out rc
  out=$(run_prc "$acmd" "$T/projects" --plugin-json "$PJSON" 2>&1); rc=$?
  rm -f "$tf"
  if [ "$rc" -eq 1 ] && grep -qxF "c9-quoted stale started 2026-10-26T11:00Z < release 2026-10-26T12:00Z (transcript found, no refresh line)" <<<"$out"; then
    ok "canary 9: quoted copies are not currency evidence"
  else
    bad "canary 9: quoted copies are not currency evidence (rc=$rc out=$(tr '\n' '|' <<<"$out"))"
  fi
}

# Canary 10: A real /clear after the release makes a pre-release session current.
canary_10() {
  local sid="00000000-0000-4000-8000-000000000010"
  local tf="$T/projects/proj-a/$sid.jsonl"
  cat > "$tf" <<'EOF'
{"type":"user","timestamp":"2026-10-26T12:25:00Z","message":{"content":"<command-name>/clear</command-name>\n<command-message>clear</command-message>"}}
EOF
  local acmd="printf '%s' '[{\"pid\":110,\"name\":\"c10-cleared\",\"sessionId\":\"$sid\",\"startedAt\":$PRE_MS}]'"
  local out rc
  out=$(run_prc "$acmd" "$T/projects" --plugin-json "$PJSON" 2>&1); rc=$?
  rm -f "$tf"
  if [ "$rc" -eq 0 ] && grep -qxF "c10-cleared current started 2026-10-26T11:00Z, refreshed 2026-10-26T12:25Z >= release 2026-10-26T12:00Z" <<<"$out"; then
    ok "canary 10: real /clear after release makes pre-release session current"
  else
    bad "canary 10: real /clear after release makes pre-release session current (rc=$rc out=$(tr '\n' '|' <<<"$out"))"
  fi
}

# Canary 11: A real /compact does NOT make a pre-release session current.
canary_11() {
  local sid="00000000-0000-4000-8000-000000000011"
  local tf="$T/projects/proj-a/$sid.jsonl"
  cat > "$tf" <<'EOF'
{"type":"user","timestamp":"2026-10-26T12:30:00Z","message":{"content":"<command-name>/compact</command-name>\n<command-message>compact</command-message>"}}
EOF
  local acmd="printf '%s' '[{\"pid\":111,\"name\":\"c11-compacted\",\"sessionId\":\"$sid\",\"startedAt\":$PRE_MS}]'"
  local out rc
  out=$(run_prc "$acmd" "$T/projects" --plugin-json "$PJSON" 2>&1); rc=$?
  rm -f "$tf"
  if [ "$rc" -eq 1 ] && grep -qxF "c11-compacted stale started 2026-10-26T11:00Z < release 2026-10-26T12:00Z (transcript found, no refresh line)" <<<"$out"; then
    ok "canary 11: real /compact does not make pre-release session current"
  else
    bad "canary 11: real /compact does not make pre-release session current (rc=$rc out=$(tr '\n' '|' <<<"$out"))"
  fi
}

canary_12() {
  local sid="00000000-0000-4000-8000-000000000012" tf="$T/projects/proj-a/00000000-0000-4000-8000-000000000012.jsonl" acmd out1 rc1 out2 rc2 out3 rc3
  acmd="printf '%s' '[{\"pid\":112,\"name\":\"c12-gap\",\"sessionId\":\"$sid\",\"startedAt\":$PRE_MS}]'"
  git -C "$R" reflog expire --expire=all --all; GIT_AUTHOR_DATE="2026-10-26T12:40:00Z" GIT_COMMITTER_DATE="2026-10-26T12:40:00Z" git -C "$R" reset --hard "$SHA_041" >/dev/null
  printf '{"type":"user","timestamp":"2026-10-26T12:20:00Z","message":{"content":"<command-name>/reload-plugins</command-name>"}}\n' > "$tf"; out1=$(run_prc "$acmd" "$T/projects" --plugin-json "$PJSON" 2>&1); rc1=$?
  printf '{"type":"user","timestamp":"2026-10-26T12:50:00Z","message":{"content":"<command-name>/reload-plugins</command-name>"}}\n' > "$tf"; out2=$(run_prc "$acmd" "$T/projects" --plugin-json "$PJSON" 2>&1); rc2=$?
  printf '{"type":"user","timestamp":"2026-10-26T12:20:00Z","message":{"content":"<command-name>/reload-plugins</command-name>"}}\n' > "$tf"; out3=$(run_prc "$acmd" "$T/projects" --plugin-json "$PJSON" 2>&1); rc3=$?
  rm -f "$tf"; git -C "$R" reflog expire --expire=all --all; GIT_AUTHOR_DATE="2026-10-26T12:00:00Z" GIT_COMMITTER_DATE="2026-10-26T12:00:00Z" git -C "$R" reset --hard "$SHA_DOCS" >/dev/null
  [ "$rc1" -eq 1 ] && [ "$rc2" -eq 0 ] && [ "$rc3" -eq 1 ] && grep -qxF "c12-gap stale started 2026-10-26T11:00Z, last refresh 2026-10-26T12:20Z < release 2026-10-26T12:40Z" <<<"$out1" \
    && grep -qxF "c12-gap current started 2026-10-26T11:00Z, refreshed 2026-10-26T12:50Z >= release 2026-10-26T12:40Z" <<<"$out2" && grep -qxF "c12-gap stale started 2026-10-26T11:00Z, last refresh 2026-10-26T12:20Z < release 2026-10-26T12:40Z" <<<"$out3" \
    && ok "canary 12: reload at 12:20Z before 12:40Z checkout pull is stale (12:50Z flips current, 12:20Z reverts stale)" || bad "canary 12: merge->pull gap (rc1=$rc1 rc2=$rc2 rc3=$rc3 out1=$(tr '\n' '|' <<<"$out1"))"
}
canary_13() {
  local out rc; out=$(run_prc "echo '[]'" "$T/projects" --plugin-json "$PJSON" --version 0.4.0 2>&1); rc=$?
  [ "$rc" -eq 2 ] && grep -qF 'no release commit found for version "0.4.0"' <<<"$out" && ok "canary 13: superseded --version 0.4.0 exits 2 instead of reporting removal commit" || bad "canary 13: superseded --version 0.4.0 (rc=$rc out=$(tr '\n' '|' <<<"$out"))"
}
canary_14() {
  local sid="00000000-0000-4000-8000-000000000014" tf="$T/projects/proj-a/00000000-0000-4000-8000-000000000014.jsonl" out rc
  printf '{"type":"user","timestamp":"2026-10-26T12:22:00Z","message":{"content":"<command-message>reload-plugins</command-message>\\n<command-name>/reload-plugins</command-name>"}}\n' > "$tf"
  out=$(run_prc "printf '%s' '[{\"pid\":114,\"name\":\"c14-msgfirst\",\"sessionId\":\"$sid\",\"startedAt\":$PRE_MS}]'" "$T/projects" --plugin-json "$PJSON" 2>&1); rc=$?; rm -f "$tf"
  [ "$rc" -eq 0 ] && grep -qxF "c14-msgfirst current started 2026-10-26T11:00Z, refreshed 2026-10-26T12:22Z >= release 2026-10-26T12:00Z" <<<"$out" && ok "canary 14: command-message-first /reload-plugins line makes pre-release session current" || bad "canary 14: command-message-first /reload-plugins (rc=$rc out=$(tr '\n' '|' <<<"$out"))"
}

canary_1
canary_2
canary_3
canary_4
canary_5
canary_6
canary_7
canary_8
canary_9
canary_10
canary_11
canary_12; canary_13; canary_14

# ==============================================================================
# BOUNDARY, MULTI-FILE, MALFORMED ROW, AND ERROR CASES
# ==============================================================================

# Boundary `>=`: startedAt and refresh in the exact release second both count current.
SID_B1="00000000-0000-4000-8000-000000000021"
SID_B2="00000000-0000-4000-8000-000000000022"
TF_B2="$T/projects/proj-a/$SID_B2.jsonl"
cat > "$TF_B2" <<'EOF'
{"type":"user","timestamp":"2026-10-26T12:00:00Z","message":{"content":"<command-name>/reload-plugins</command-name>"}}
EOF
ACMD_B="printf '%s' '[{\"pid\":121,\"name\":\"bound-start\",\"sessionId\":\"$SID_B1\",\"startedAt\":$BOUND_MS},{\"pid\":122,\"name\":\"bound-reload\",\"sessionId\":\"$SID_B2\",\"startedAt\":$PRE_MS}]'"
out=$(run_prc "$ACMD_B" "$T/projects" --plugin-json "$PJSON" 2>&1); rc=$?
rm -f "$TF_B2"
if [ "$rc" -eq 0 ] \
  && grep -qxF "bound-start current started 2026-10-26T12:00Z >= release 2026-10-26T12:00Z" <<<"$out" \
  && grep -qxF "bound-reload current started 2026-10-26T11:00Z, refreshed 2026-10-26T12:00Z >= release 2026-10-26T12:00Z" <<<"$out"; then
  ok "boundary >=: exact release-second startedAt and reload both report current"
else
  bad "boundary >=: rc=$rc out=[$(tr '\n' '|' <<<"$out")]"
fi

# Multiple matching transcript files across project folders: max refresh timestamp wins.
SID_M="00000000-0000-4000-8000-000000000023"
cat > "$T/projects/proj-a/$SID_M.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-10-26T11:15:00Z","message":{"content":"<command-name>/reload-plugins</command-name>"}}
EOF
cat > "$T/projects/proj-b/$SID_M.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-10-26T12:40:00Z","message":{"content":"<command-name>/clear</command-name>"}}
EOF
ACMD_M="printf '%s' '[{\"pid\":123,\"name\":\"multi-file\",\"sessionId\":\"$SID_M\",\"startedAt\":$PRE_MS}]'"
out=$(run_prc "$ACMD_M" "$T/projects" --plugin-json "$PJSON" 2>&1); rc=$?
rm -f "$T/projects/proj-a/$SID_M.jsonl" "$T/projects/proj-b/$SID_M.jsonl"
if [ "$rc" -eq 0 ] && grep -qxF "multi-file current started 2026-10-26T11:00Z, refreshed 2026-10-26T12:40Z >= release 2026-10-26T12:00Z" <<<"$out"; then
  ok "multiple transcripts: takes maximum refresh timestamp across project folders"
else
  bad "multiple transcripts: rc=$rc out=[$(tr '\n' '|' <<<"$out")]"
fi

# Malformed session rows report stale and do not crash; pid:null rows are ignored.
ACMD_MAL="printf '%s' '[{\"pid\":null,\"name\":\"dead-row\"},{\"pid\":124,\"name\":\"no-sid\",\"startedAt\":$POST_MS},{\"pid\":125,\"name\":\"no-start\",\"sessionId\":\"00000000-0000-4000-8000-000000000025\"}]'"
out=$(run_prc "$ACMD_MAL" "$T/projects" --plugin-json "$PJSON" 2>&1); rc=$?
if [ "$rc" -eq 1 ] \
  && ! grep -qF "dead-row" <<<"$out" \
  && grep -qxF "no-sid stale malformed session row (missing sessionId or startedAt; release 2026-10-26T12:00Z)" <<<"$out" \
  && grep -qxF "no-start stale malformed session row (missing sessionId or startedAt; release 2026-10-26T12:00Z)" <<<"$out"; then
  ok "malformed rows report stale without crashing and pid:null rows are skipped"
else
  bad "malformed rows: rc=$rc out=[$(tr '\n' '|' <<<"$out")]"
fi

# Exit-2 usage and data errors; --plugin-json= and --version= forms also work.
out=$(run_prc "echo '[]'" "$T/projects" "--plugin-json=$PJSON" "--version=0.4.1" 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -qxF "plugin-release-check: demo-plugin 0.4.1 (release 2026-10-26T12:00Z)" <<<"$out" \
  && ok "--plugin-json= and --version= forms select the 0.4.1 release time" \
  || bad "= flag forms: rc=$rc out=[$out]"

err_ok=1
run_prc "echo '[]'" "$T/projects" >/dev/null 2>&1; [ $? -eq 2 ] || err_ok=0
run_prc "echo '[]'" "$T/projects" --plugin-json "$T/missing.json" >/dev/null 2>&1; [ $? -eq 2 ] || err_ok=0
echo "not-json" > "$T/bad.json"
run_prc "echo '[]'" "$T/projects" --plugin-json "$T/bad.json" >/dev/null 2>&1; [ $? -eq 2 ] || err_ok=0
echo '{"name":"x"}' > "$PDIR/nover.json"
run_prc "echo '[]'" "$T/projects" --plugin-json "$PDIR/nover.json" >/dev/null 2>&1; [ $? -eq 2 ] || err_ok=0
rm -f "$PDIR/nover.json"
run_prc "exit 7" "$T/projects" --plugin-json "$PJSON" >/dev/null 2>&1; [ $? -eq 2 ] || err_ok=0
run_prc "echo '{}'" "$T/projects" --plugin-json "$PJSON" >/dev/null 2>&1; [ $? -eq 2 ] || err_ok=0
[ "$err_ok" -eq 1 ] && ok "usage and data errors (missing/unreadable/invalid plugin.json, no version, failed/non-array agents cmd) exit 2" \
  || bad "one or more error cases did not exit 2"

# Extreme startedAt magnitudes (bash arithmetic wraps above 2^63) land in the
# malformed-row path: the validity check bounds startedAt below year 2100 in ms.
ACMD_BIG="printf '%s' '[{\"pid\":126,\"name\":\"big-start\",\"sessionId\":\"00000000-0000-4000-8000-000000000026\",\"startedAt\":99999999999999999999}]'"
out=$(run_prc "$ACMD_BIG" "$T/projects" --plugin-json "$PJSON" 2>&1); rc=$?
[ "$rc" -eq 1 ] && grep -qF "big-start stale malformed session row" <<<"$out" \
  && ok "absurd startedAt (bash-wrap range) reports stale malformed, no wrap" \
  || bad "huge startedAt: rc=$rc out=[$out]"

# With the agents-command override unset, the default `claude agents --json` runs:
# the poison binary fires and the bin dies exit 2 naming the command.
out=$(env -u PLUGIN_RELEASE_AGENTS_CMD PLUGIN_RELEASE_PROJECTS="$T/projects" "$PRC" --plugin-json "$PJSON" 2>&1); rc=$?
[ "$rc" -eq 2 ] && grep -qF "agents command failed" <<<"$out" \
  && ok "default agents command path runs claude (poison fires) and dies exit 2" \
  || bad "default agents cmd: rc=$rc out=[$out]"

# ==============================================================================
# CLAIM CANARY MUTATION RED-TAIL CONTROLS (1, 2, 3, 4, 5, 6, 9, 10)
# ==============================================================================
check_mutant() {
  local num=$1 sed_expr=$2
  local mbin="$T/mutant-$num"
  sed "$sed_expr" "$PRC" > "$mbin"
  chmod +x "$mbin"
  if cmp -s "$PRC" "$mbin"; then
    bad "canary $num mutation did not change binary"
    return
  fi
  local mout mrc
  mout=$(
    PRC="$mbin"
    fail=0
    "canary_$num"
    exit "$fail"
  )
  mrc=$?
  if [ "$mrc" -eq 1 ] && grep -q '^FAIL: canary '"$num"':' <<<"$mout"; then
    ok "canary $num mutation reddens -> $(tail -n 1 <<<"$mout")"
  else
    bad "canary $num mutation failed to redden (mrc=$mrc mout=$mout)"
  fi
}

# 1. Drop the reload branch.
check_mutant 1 's/elif \[ "\$max_refresh_sec" -ge "\$release_sec" \]; then/elif false; then/'
# 2. Drop the startedAt branch.
check_mutant 2 's/if \[ "\$started_sec" -ge "\$release_sec" \]; then/if false; then/'
# 3. Hardcode exit 0.
check_mutant 3 's/^exit "\$any_stale"$/exit 0/'
# 4. Hardcode `claude agents --json` (ignoring PLUGIN_RELEASE_AGENTS_CMD).
check_mutant 4 's/agents_cmd=\${PLUGIN_RELEASE_AGENTS_CMD:-claude agents --json}/agents_cmd="claude agents --json"/'
# 5. Hardcode default projects path (ignoring PLUGIN_RELEASE_PROJECTS).
check_mutant 5 's/projects_dir=\${PLUGIN_RELEASE_PROJECTS:-\$HOME\/\.claude\/projects}/projects_dir="\$HOME\/.claude\/projects"/'
# 6. Require --version flag (drop plugin.json version fallback).
check_mutant 6 's/if \[ -z "\$version" \]; then/if false; then/'
# 9. Drop the string-content filter on .message.content.
check_mutant 9 's/and (\.message\.content | type) == "string"/and true/; s/(\.message\.content | test(".*"))/((.message.content | tostring) | contains("reload-plugins<\/command-name>"))/'
# 10. Remove `/clear` from the refresh pattern set.
check_mutant 10 's/(reload-plugins|clear)/(reload-plugins)/'
check_mutant 12 's/release_sec=\$received_sec/release_sec=\$commit_sec/'
check_mutant 13 's/\[ "\$commit_ver" = "\$version" \]/true/'
check_mutant 14 's/test(".*")/startswith("<command-name>\/reload-plugins<\/command-name>")/'

exit "$fail"
