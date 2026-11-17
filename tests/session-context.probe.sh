#!/bin/bash
# Fixture check for plugins/seyag/bin/session-context (context size per running session, flags over the
# threshold, extra harness rows from SYG_SESSION_CONTEXT_EXTRA_CMD). Stub `claude` first on PATH.
# Usage: tests/session-context.probe.sh   (from anywhere)

set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/plugins/seyag/bin"
[ -x "$BIN/session-context" ] || { echo "FAIL: $BIN/session-context is not executable (chmod +x it)"; exit 1; }
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

TMP=$(mktemp -d)

trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stub" "$TMP/cfg/projects/p1" "$TMP/cfg/projects/p2"
export CLAUDE_CONFIG_DIR="$TMP/cfg"
export PATH="$TMP/stub:$PATH"
unset SYG_CONTEXT_THRESHOLD SYG_CONTEXT_THRESHOLD_FABLE SYG_SESSION_CONTEXT_THRESHOLD SYG_SESSION_CONTEXT_THRESHOLD_FABLE CLAUDE_PROJECTS_DIR SYG_SESSION_CONTEXT_EXTRA_CMD SYG_SESSION_CONTEXT_EXTRA_MODEL SYG_SESSION_CONTEXT_EXTRA_THRESHOLD
export SYG_CONFIG=0

reply() {   # reply <model> <input> <cache_read> <cache_write>: one assistant transcript line
    jq -cn --arg m "$1" --argjson i "$2" --argjson r "$3" --argjson w "$4" \
        '{type: "assistant", message: {model: $m, usage: {input_tokens: $i, cache_read_input_tokens: $r,
          cache_creation_input_tokens: $w}}}'
}
# big: Opus, newest real reply 600k (an older, smaller reply must not count); after it, a subagent
# sidechain line with a huge context, which isn't the session's. ~5 MB of older replies make it
# real-sized: tac then dies of SIGPIPE when jq stops early, which must not lose the answer.
{ old=$(reply claude-opus-5-5 10 100000 0); for _ in $(seq 40000); do echo "$old"; done
  echo '{"type":"user"}'; reply claude-opus-5-5 1000 590000 9000
  reply claude-sonnet-5-5 0 900000 0 | jq -c '.isSidechain = true'; } > "$TMP/cfg/projects/p1/s-big.jsonl"
# fable: 250k, over its 200k limit; its newest line is a synthetic error entry with no usage,
# then a malformed line, both skipped.
{ reply claude-fable-5-1 0 250000 0; echo '{"type":"assistant","message":{"model":"<synthetic>"}}'
  echo '{"type":"assistant", broken'; } > "$TMP/cfg/projects/p2/s-fable.jsonl"
# small: Opus 120k, then lines whose .message / .usage have an unexpected shape. none: no transcript.
{ reply claude-opus-5-5 0 120000 0; echo '{"type":"assistant","message":"oops"}'
  echo '{"type":"assistant","message":{"model":"x","usage":"n/a"}}'; } > "$TMP/cfg/projects/p2/s-small.jsonl"
# twin: a second session in big's folder, from a real agent worktree of a repo named big-repo.
reply claude-opus-5-5 0 50000 0 > "$TMP/cfg/projects/p2/s-twin.jsonl"
git init -q "$TMP/repos/big-repo" && git -C "$TMP/repos/big-repo" -c user.name=probe -c user.email=probe@example.invalid commit -q --allow-empty -m init \
    && git -C "$TMP/repos/big-repo" worktree add -q "$TMP/wt/agent-x" 2>/dev/null \
    || bad "fixture: couldn't make the worktree"

cat > "$TMP/stub/claude" <<EOF
#!/bin/sh
[ "\$1" = agents ] || exit 9
[ -f "$TMP/agents-fail" ] && exit 1
cat "$TMP/agents.json"
EOF
chmod +x "$TMP/stub/claude"
four='[{"name":"Big","cwd":"/nowhere/Projects/big-repo","sessionId":"s-big","status":"busy"},
 {"name":"Fab","cwd":"/nowhere/Projects/chats","sessionId":"s-fable","status":"idle"},
 {"name":"Small","cwd":"/nowhere/Projects/small","sessionId":"s-small","status":"busy"},
 {"name":"New","cwd":"/nowhere/Projects/fresh","sessionId":"s-none","status":"idle"}]'
echo "$four" > "$TMP/agents.json"

json=$("$BIN/session-context" --json); rc=$?
[ $rc = 0 ] && ok "--json exits 0" || bad "--json exits 0 (rc $rc)"
get() { jq -c --arg n "$1" ".[] | select(.name == \$n) | $2" <<< "$json"; }
[ "$(get Big .tokens)" = 600000 ] && ok "newest reply's input + cache read + cache write; sidechain skipped" || bad "Big tokens: $(get Big .tokens)"
[ "$(get Big .flagged)" = true ] && ok "Opus over 500k flagged" || bad "Big flagged: $(get Big .flagged)"
[ "$(get Big .folder)" = '"big-repo"' ] && ok "folder = cwd basename outside git" || bad "Big folder: $(get Big .folder)"
[ "$(get Fab .tokens)" = 250000 ] && ok "synthetic + malformed newest lines skipped" || bad "Fab tokens: $(get Fab .tokens)"
[ "$(get Fab '[.flag_at, .flagged]')" = '[200000,true]' ] && ok "Fable flag threshold 200k, flagged at 250k" || bad "Fab: $(get Fab '[.flag_at,.flagged]')"
[ "$(get Fab 'has("limit")')" = false ] && ok "no capacity-looking limit key (a flag threshold is not the window)" || bad "Fab still has a limit key"
[ "$(get Small '[.tokens, .flagged]')" = '[120000,false]' ] && ok "odd-shaped newest lines skipped, row kept" || bad "Small: $(get Small '[.tokens,.flagged]')"
[ "$(get New '[.tokens, .model, .flagged]')" = '[0,"",false]' ] && ok "no transcript: 0 tokens, not flagged" || bad "New: $(get New '[.tokens,.model,.flagged]')"
[ "$(jq -r 'map(.name) | join(",")' <<< "$json")" = "Big,Fab,Small,New" ] && ok "sorted largest first" || bad "order: $json"

out=$("$BIN/session-context" --flagged)
[ "$(wc -l <<< "$out")" = 2 ] && grep -q Big <<< "$out" && grep -q Fab <<< "$out" \
    && ok "--flagged lists only the 2 flagged" || bad "--flagged: $out"
out=$("$BIN/session-context")
grep -qE '^ +Small +small +opus-5-5 +120k +flag@500k +busy' <<< "$out" && ok "table row format" || bad "table: $out"

json=$(SYG_SESSION_CONTEXT_THRESHOLD=100000 SYG_SESSION_CONTEXT_THRESHOLD_FABLE=300000 "$BIN/session-context" --json)
[ "$(jq -c '[.[] | .flagged]' <<< "$json")" = '[true,false,true,false]' ] && ok "limits overridable by SYG_SESSION_CONTEXT_THRESHOLD(_FABLE)" || bad "env limits: $json"

"$BIN/session-context" --bogus >/dev/null 2>&1; rc=$?
[ $rc = 2 ] && ok "unknown argument exits 2" || bad "unknown argument rc $rc"
touch "$TMP/agents-fail"
err=$("$BIN/session-context" 2>&1 >/dev/null); rc=$?
[ $rc = 1 ] && grep -q "claude agents --json failed" <<< "$err" && ok "agents failure exits 1 and says so" || bad "agents failure: rc $rc, $err"
rm "$TMP/agents-fail"
echo '{"agents": []}' > "$TMP/agents.json"
err=$("$BIN/session-context" 2>&1 >/dev/null); rc=$?
[ $rc = 1 ] && grep -q "didn't return a list" <<< "$err" && ok "a non-list agents reply exits 1, not an empty table" || bad "non-list agents: rc $rc, $err"
echo '[{"name":"Bad","cwd":"/nowhere","sessionId":"s-big","status":["not","text"]}]' > "$TMP/agents.json"
err=$("$BIN/session-context" 2>&1 >/dev/null); rc=$?
[ $rc = 1 ] && grep -q "built 0 rows for 1 sessions" <<< "$err" && ok "a dropped row exits 1" || bad "dropped row: rc $rc, $err"

# Two sessions in one folder, one of them in an agent worktree (named after the main checkout).
jq -c --arg wt "$TMP/wt/agent-x" '. + [{name: "Twin", cwd: $wt, sessionId: "s-twin", status: "busy"}]' \
    <<< "$four" > "$TMP/agents.json"
json=$("$BIN/session-context" --json)
[ "$(get Twin .folder)" = '"big-repo"' ] && ok "worktree cwd counts as its main checkout" || bad "Twin folder: $(get Twin .folder)"

# Extra harness rows: SYG_SESSION_CONTEXT_EXTRA_CMD prints a JSON array; its rows get the
# EXTRA_MODEL label and the EXTRA_THRESHOLD flag line (defaults "other" and 150000).
echo '[{"name":"Small","cwd":"/nowhere/Projects/small","sessionId":"s-small","status":"busy"}]' > "$TMP/agents.json"
json=$("$BIN/session-context" --json)
[ "$(jq -c 'map(.name)' <<< "$json")" = '["Small"]' ] && ok "EXTRA_CMD unset: only the Claude rows" || bad "extra unset: $json"
cat > "$TMP/extra-ok.sh" <<'SH'
#!/bin/sh
printf '[{"name":"Xa","folder":"acme","sessionId":"x-1","status":"busy","tokens":170000},{"sessionId":"x-2","tokens":10000}]\n'
SH
chmod +x "$TMP/extra-ok.sh"
err=$(SYG_SESSION_CONTEXT_EXTRA_CMD="$TMP/extra-ok.sh" "$BIN/session-context" --json 2>&1 >"$TMP/out.json"); rc=$?
json=$(cat "$TMP/out.json")
[ $rc = 0 ] && [ -z "$err" ] && ok "EXTRA_CMD ok: exit 0, nothing on stderr" || bad "extra ok: rc $rc, $err"
jq -e '(.[] | select(.sessionId == "x-1")) | (.name == "Xa" and .folder == "acme" and .model == "other" and .tokens == 170000 and .flag_at == 150000 and .flagged == true and .status == "busy")' <<< "$json" >/dev/null \
    && ok "extra row: default model other, default flag line 150k, flagged over it" || bad "extra row: $json"
jq -e '(.[] | select(.sessionId == "x-2")) | (.name == "extra" and .status == "idle" and .folder == "" and .flagged == false)' <<< "$json" >/dev/null \
    && ok "extra row with missing fields gets defaults, under the line" || bad "extra defaults: $json"
[ "$(jq -c 'map(.sessionId)' <<< "$json")" = '["x-1","s-small","x-2"]' ] && ok "extra rows sort in with the Claude rows by tokens" || bad "extra order: $json"
json=$(SYG_SESSION_CONTEXT_EXTRA_CMD="$TMP/extra-ok.sh" SYG_SESSION_CONTEXT_EXTRA_MODEL=harness-b SYG_SESSION_CONTEXT_EXTRA_THRESHOLD=5000 "$BIN/session-context" --json)
jq -e '(.[] | select(.sessionId == "x-2")) | (.model == "harness-b" and .flag_at == 5000 and .flagged == true)' <<< "$json" >/dev/null \
    && ok "EXTRA_MODEL and EXTRA_THRESHOLD override the label and the flag line" || bad "extra overrides: $json"
out=$(SYG_SESSION_CONTEXT_EXTRA_CMD="$TMP/extra-ok.sh" "$BIN/session-context" --flagged)
[ "$(wc -l <<< "$out")" = 1 ] && grep -q "^! *Xa" <<< "$out" && ok "--flagged carries a flagged extra row" || bad "extra --flagged: $out"
# the command runs with stdin closed
cat > "$TMP/extra-stdin.sh" <<'SH'
#!/bin/sh
if read -r _l; then echo '[{"name":"HadStdin","tokens":1}]'; else echo '[]'; fi
SH
chmod +x "$TMP/extra-stdin.sh"
printf 'y\ny\n' > "$TMP/stdin-feed"   # a file, not `yes`: its broken-pipe error would land in the capture
json=$(SYG_SESSION_CONTEXT_EXTRA_CMD="$TMP/extra-stdin.sh" "$BIN/session-context" --json 2>&1 < "$TMP/stdin-feed")
jq -e 'all(.name != "HadStdin")' <<< "$json" >/dev/null && ok "EXTRA_CMD stdin is /dev/null" || bad "extra stdin: $json"
# Set but failing: loud on stderr, Claude rows still printed, exit 0.
msg="session-context: SYG_SESSION_CONTEXT_EXTRA_CMD failed; its sessions are missing"
printf '#!/bin/sh\nexit 1\n' > "$TMP/extra-fail.sh"
printf '#!/bin/sh\necho "{}"\n' > "$TMP/extra-obj.sh"
printf '#!/bin/sh\necho "not json"\n' > "$TMP/extra-junk.sh"
printf '#!/bin/sh\necho "[1,2]"\n' > "$TMP/extra-scalars.sh"
chmod +x "$TMP"/extra-*.sh
for c in fail obj junk scalars; do
    err=$(SYG_SESSION_CONTEXT_EXTRA_CMD="$TMP/extra-$c.sh" "$BIN/session-context" --json 2>&1 >"$TMP/out.json"); rc=$?
    [ $rc = 0 ] && [ "$err" = "$msg" ] && [ "$(jq -c 'map(.name)' "$TMP/out.json")" = '["Small"]' ] \
        && ok "EXTRA_CMD '$c': stderr names the knob, Claude rows kept, exit 0" || bad "extra $c: rc $rc, err '$err', out $(cat "$TMP/out.json")"
done
err=$(SYG_SESSION_CONTEXT_EXTRA_CMD="$TMP/no-such-command" "$BIN/session-context" 2>&1 >/dev/null); rc=$?
[ $rc = 0 ] && grep -qF "$msg" <<< "$err" && ok "EXTRA_CMD naming a missing command fails loudly too" || bad "extra missing: rc $rc, $err"

# A row whose tokens is present but not a number takes the failure path (null counts as 0).
for tk in '"170000"' 'true' '{"n":1}' '[5]'; do
    printf '#!/bin/sh\necho '"'"'[{"name":"Xs","sessionId":"x-s","tokens":%s}]'"'"'\n' "$tk" > "$TMP/extra-tok.sh"; chmod +x "$TMP/extra-tok.sh"
    err=$(SYG_SESSION_CONTEXT_EXTRA_CMD="$TMP/extra-tok.sh" "$BIN/session-context" --json 2>&1 >"$TMP/out.json"); rc=$?
    [ $rc = 0 ] && [ "$err" = "$msg" ] && [ "$(jq -c 'map(.name)' "$TMP/out.json")" = '["Small"]' ] \
        && ok "extra row with tokens $tk: failure line, Claude rows kept, exit 0" || bad "extra tokens $tk: rc $rc, err '$err', out $(cat "$TMP/out.json")"
done
printf '#!/bin/sh\necho '"'"'[{"name":"Xn","sessionId":"x-n","tokens":null}]'"'"'\n' > "$TMP/extra-tok.sh"
err=$(SYG_SESSION_CONTEXT_EXTRA_CMD="$TMP/extra-tok.sh" "$BIN/session-context" --json 2>&1 >"$TMP/out.json"); rc=$?
[ $rc = 0 ] && [ -z "$err" ] && jq -e '.[] | select(.sessionId == "x-n") | .tokens == 0' "$TMP/out.json" >/dev/null \
    && ok "extra row with null tokens counts as 0" || bad "extra null tokens: rc $rc, $err"

# Thresholds must be whole numbers: a bad one exits 2 with a message, never an empty table.
for knob in SYG_SESSION_CONTEXT_THRESHOLD SYG_SESSION_CONTEXT_THRESHOLD_FABLE SYG_SESSION_CONTEXT_EXTRA_THRESHOLD; do
    for v in 12k -1 5e5 1.5; do
        out=$(env "$knob=$v" "$BIN/session-context" --json 2>"$TMP/err"); rc=$?
        [ $rc = 2 ] && [ -z "$out" ] && [ "$(cat "$TMP/err")" = "session-context: $knob must be a whole number, got '$v'" ] \
            && ok "$knob=$v exits 2 with the message" || bad "$knob=$v: rc $rc, out '$out', err $(cat "$TMP/err")"
    done
done
# the in-session reminder's thresholds are a different policy: not read here
json=$(SYG_CONTEXT_THRESHOLD=1000 SYG_CONTEXT_THRESHOLD_FABLE=1000 "$BIN/session-context" --json)
[ "$(jq -c '[.[] | .flag_at]' <<< "$json")" = '[500000]' ] && ok "SYG_CONTEXT_THRESHOLD(_FABLE) are not read (flag_at stays 500000)" || bad "reminder thresholds read: $json"
echo '[{"name":"Fab","cwd":"/nowhere/Projects/chats","sessionId":"s-fable","status":"idle"}]' > "$TMP/agents.json"
json=$(SYG_CONTEXT_THRESHOLD=1000 SYG_CONTEXT_THRESHOLD_FABLE=1000 "$BIN/session-context" --json)
[ "$(jq -c '[.[] | .flag_at]' <<< "$json")" = '[200000]' ] && ok "SYG_CONTEXT_THRESHOLD_FABLE is not read (flag_at stays 200000)" || bad "reminder fable threshold read: $json"
echo '[{"name":"Small","cwd":"/nowhere/Projects/small","sessionId":"s-small","status":"busy"}]' > "$TMP/agents.json"

# Transcript root: CLAUDE_PROJECTS_DIR wins over CLAUDE_CONFIG_DIR/projects (the latter is the default, used above).
mkdir -p "$TMP/alt/p9"
reply claude-opus-5-5 0 777000 0 > "$TMP/alt/p9/s-small.jsonl"
json=$(CLAUDE_PROJECTS_DIR="$TMP/alt" "$BIN/session-context" --json)
[ "$(jq -c '[.[] | .tokens]' <<< "$json")" = '[777000]' ] && ok "CLAUDE_PROJECTS_DIR wins over CLAUDE_CONFIG_DIR/projects" || bad "projects dir: $json"
json=$(CLAUDE_PROJECTS_DIR="" "$BIN/session-context" --json)
[ "$(jq -c '[.[] | .tokens]' <<< "$json")" = '[120000]' ] && ok "an empty CLAUDE_PROJECTS_DIR falls back to CLAUDE_CONFIG_DIR/projects" || bad "empty projects dir: $json"

# Wrong JSON types in a reply: a string token count skips that reply (an older reply counts; a silent 0 would hide a flagged session),
# and a numeric model leaves the model blank rather than failing the scan.
mkdir -p "$TMP/cfg/projects/p3"
{ reply claude-opus-5-5 0 120000 0; echo '{"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":"700000","cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}'; } > "$TMP/cfg/projects/p3/s-strtok.jsonl"
echo '{"type":"assistant","message":{"model":7,"usage":{"input_tokens":900000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' > "$TMP/cfg/projects/p3/s-nummodel.jsonl"
echo '[{"name":"Str","cwd":"/nowhere/Projects/str","sessionId":"s-strtok","status":"busy"},{"name":"Num","cwd":"/nowhere/Projects/num","sessionId":"s-nummodel","status":"busy"}]' > "$TMP/agents.json"
err=$("$BIN/session-context" --json 2>&1 >"$TMP/out.json"); rc=$?
json=$(cat "$TMP/out.json")
[ $rc = 0 ] && [ -z "$err" ] && [ "$(jq -c '[.[] | select(.name == "Str") | .tokens]' <<< "$json")" = '[120000]' ] \
    && ok "a string token count skips that reply; the older reply counts" || bad "string tokens: rc $rc, err '$err', $json"
[ "$(jq -c '[.[] | select(.name == "Num") | [.tokens, .model, .flagged]]' <<< "$json")" = '[[900000,"",true]]' ] \
    && ok "a numeric model is left blank; the row keeps its tokens and flag" || bad "numeric model: $json"
echo '[{"name":"Small","cwd":"/nowhere/Projects/small","sessionId":"s-small","status":"busy"}]' > "$TMP/agents.json"

# --help prints the whole header comment, through the extra-knob block
out=$("$BIN/session-context" --help)
grep -q 'SYG_SESSION_CONTEXT_EXTRA_CMD' <<< "$out" && [ "${out##*$'\n'}" = "says so and the Claude rows still print." ] \
    && ok "--help runs through the extra-knob block's last line" || bad "--help tail: ${out##*$'\n'}"
# --help starts with the tool's own name, and the usage error names it
case "$out" in "session-context "*) ok "--help starts with session-context" ;; *) bad "--help first line: ${out%%$'\n'*}" ;; esac
err=$("$BIN/session-context" --bogus 2>&1 >/dev/null)
[ "$err" = "session-context: unknown argument '--bogus' (try --help)" ] && ok "usage error names session-context" || bad "usage error: $err"

# More than one argument is a usage error.
for args in "--json --flagged" "--flagged --json" "--json extra"; do
    err=$("$BIN/session-context" $args 2>&1 >/dev/null); rc=$?
    [ $rc = 2 ] && [ "$err" = "session-context: one mode at most (try --help)" ] && ok "'$args' exits 2: one mode at most" || bad "'$args': rc $rc, $err"
done

[ $fail = 0 ] && echo "all ok" || echo "FAILURES above"
exit $fail
