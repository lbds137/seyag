#!/bin/bash
# Fixture check for run.sh (the seyag hook dispatcher).
#   1. a project-local .claude/hooks/<name>.sh exists → silent exit 0 (yield)
#   2. no project copy → the plugin hook runs; exit 2 + stderr pass through
#   3. stdin reaches the hook; stdout passes through
#   4. PYTHONDONTWRITEBYTECODE is exported to the hook
#   5. sdk-* entrypoints skip the turn-shape hooks; a background session a person
#      drives (entrypoint cli, SESSION_ATTENDED=0) keeps them
#   6. GIT_OPTIONAL_LOCKS=0 reaches every git call a hook makes
#   7. components: SYG_PROFILE / SYG_ENABLE / SYG_DISABLE pick which hooks run;
#      a missing registry, an unknown profile or a broken resolver fails toward on
#   8. event mode (run.sh --event <Event>): matcher selection, parallel runs, and
#      the merge of blocks, context, systemMessage and stderr in hooks.json order
# Uses throwaway fake hooks placed next to run.sh in temp copies, so the real
# hooks are never involved (except the one real SessionStart case in 8).
#
# Usage: hooks/run.probe.sh   (from anywhere)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/plugin/hooks" "$TMP/proj-with/.claude/hooks" "$TMP/proj-without"
cp "$SCRIPT_DIR/run.sh" "$TMP/plugin/hooks/run.sh"
# The component registry and its resolver sit next to run.sh, as in the plugin.
mkdir -p "$TMP/plugin/hooks/lib"
cp "$SCRIPT_DIR/components.tsv" "$TMP/plugin/hooks/components.tsv"
cp "$SCRIPT_DIR/lib/components.sh" "$TMP/plugin/hooks/lib/components.sh"
RUN="$TMP/plugin/hooks/run.sh"
# Every run.sh call starts without the caller's entrypoint/attended env, so a probe
# run inside an sdk-* or background session cannot flip the cases below. A case
# sets them itself with leading NAME=value arguments.
runsh() {
  local -a set=()
  while [[ "${1:-}" == *=* ]]; do set+=("$1"); shift; done
  env -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ATTENDED -u SYG_PROFILE -u SYG_ENABLE -u SYG_DISABLE \
    "${set[@]+"${set[@]}"}" bash "$RUN" "$@"
}

cat > "$TMP/plugin/hooks/fake-guard.sh" <<'EOF'
#!/bin/bash
IN=$(cat)
echo "stdout:$IN:${PYTHONDONTWRITEBYTECODE:-unset}"
echo "BLOCKED by fake-guard" >&2
exit 2
EOF
echo '#!/bin/bash' > "$TMP/proj-with/.claude/hooks/fake-guard.sh"

fail=0
check() { # $1 label, $2 want-rc, $3 got-rc, $4 want-stdout, $5 got-stdout, $6 want-stderr, $7 got-stderr
  if [ "$3" = "$2" ] && [ "$5" = "$4" ] && [ "$7" = "$6" ]; then
    echo "ok   [$3]: $1"
  else
    echo "FAIL [rc $3 want $2 | stdout '$5' want '$4' | stderr '$7' want '$6']: $1"
    fail=1
  fi
}

# --- 1. project copy exists → yield silently ----------------------------------
OUT=$(printf 'payload' | CLAUDE_PROJECT_DIR="$TMP/proj-with" runsh fake-guard 2>"$TMP/err")
RC=$?
check "project copy present → silent exit 0" 0 "$RC" "" "$OUT" "" "$(cat "$TMP/err")"

# --- 1b. CLAUDE_PROJECT_DIR unset → falls back to PWD --------------------------
OUT=$(cd "$TMP/proj-with" && printf 'payload' | (unset CLAUDE_PROJECT_DIR; runsh fake-guard) 2>"$TMP/err")
RC=$?
check "no CLAUDE_PROJECT_DIR, project copy in PWD → yield" 0 "$RC" "" "$OUT" "" "$(cat "$TMP/err")"

# --- 2. no project copy → passthrough of rc 2, stdout, stderr ------------------
OUT=$(printf 'payload' | CLAUDE_PROJECT_DIR="$TMP/proj-without" PYTHONDONTWRITEBYTECODE='' runsh fake-guard 2>"$TMP/err")
RC=$?
check "no project copy → exit 2, stdin/stdout/stderr pass through, PYTHONDONTWRITEBYTECODE=1" \
  2 "$RC" "stdout:payload:1" "$OUT" "BLOCKED by fake-guard" "$(cat "$TMP/err")"

# --- 3. unknown / unsafe hook names fail open ----------------------------------
printf '' | CLAUDE_PROJECT_DIR="$TMP/proj-without" runsh no-such-hook >/dev/null 2>&1
RC=$?
[ "$RC" = 0 ] && echo "ok   [0]: unknown hook name fails open" || { echo "FAIL [$RC]: unknown hook name"; fail=1; }
printf '' | CLAUDE_PROJECT_DIR="$TMP/proj-without" runsh ../fake-guard >/dev/null 2>&1
RC=$?
[ "$RC" = 0 ] && echo "ok   [0]: path-traversal name refused" || { echo "FAIL [$RC]: path-traversal name"; fail=1; }

# --- 4. a hook with a syntax error fails open instead of exiting 2 -------------
printf '#!/bin/bash\nif then fi (\n' > "$TMP/plugin/hooks/broken-guard.sh"
printf '' | CLAUDE_PROJECT_DIR="$TMP/proj-without" runsh broken-guard >/dev/null 2>"$TMP/err"
RC=$?
[ "$RC" = 0 ] && grep -q "syntax error" "$TMP/err" && echo "ok   [0]: syntax error fails open with a note" \
  || { echo "FAIL [$RC]: syntax error should fail open"; fail=1; }

# --- 5. headless (sdk-*) runs skip turn-shape hooks but keep shell guards -------
# Leading NAME=value args to runsh are set after the base unset, so each case
# controls the entrypoint/attended env itself.
cp "$TMP/plugin/hooks/fake-guard.sh" "$TMP/plugin/hooks/turn-end-shape-gate.sh"
cp "$TMP/plugin/hooks/fake-guard.sh" "$TMP/plugin/hooks/promise-ledger-check.sh"
printf 'x' | CLAUDE_PROJECT_DIR="$TMP/proj-without" runsh CLAUDE_CODE_ENTRYPOINT=sdk-cli turn-end-shape-gate >/dev/null 2>&1
RC=$?
[ "$RC" = 0 ] && echo "ok   [0]: sdk-cli run skips a turn-shape hook" || { echo "FAIL [$RC]: sdk-cli turn-shape hook should be skipped"; fail=1; }
printf 'x' | CLAUDE_PROJECT_DIR="$TMP/proj-without" runsh CLAUDE_CODE_ENTRYPOINT=sdk-cli promise-ledger-check >/dev/null 2>&1
RC=$?
[ "$RC" = 0 ] && echo "ok   [0]: sdk-cli run skips promise-ledger-check" || { echo "FAIL [$RC]: sdk-cli promise-ledger-check should be skipped"; fail=1; }
printf 'x' | CLAUDE_PROJECT_DIR="$TMP/proj-without" runsh CLAUDE_CODE_ENTRYPOINT=sdk-cli fake-guard >/dev/null 2>&1
RC=$?
[ "$RC" = 2 ] && echo "ok   [2]: sdk-cli run still runs a shell guard" || { echo "FAIL [$RC]: sdk-cli shell guard should still run"; fail=1; }
printf 'x' | CLAUDE_PROJECT_DIR="$TMP/proj-without" runsh CLAUDE_CODE_ENTRYPOINT=sdk-ts turn-end-shape-gate >/dev/null 2>&1
RC=$?
[ "$RC" = 0 ] && echo "ok   [0]: sdk-ts run skips a turn-shape hook" || { echo "FAIL [$RC]: sdk-ts turn-shape hook should be skipped"; fail=1; }
printf 'x' | CLAUDE_PROJECT_DIR="$TMP/proj-without" runsh CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CODE_SESSION_ATTENDED=0 turn-end-shape-gate >/dev/null 2>&1
RC=$?
[ "$RC" = 2 ] && echo "ok   [2]: background session a person drives (cli, ATTENDED=0) keeps turn-shape hooks" || { echo "FAIL [$RC]: background session (cli, ATTENDED=0) turn-shape hook should run"; fail=1; }
printf 'x' | CLAUDE_PROJECT_DIR="$TMP/proj-without" runsh turn-end-shape-gate >/dev/null 2>&1
RC=$?
[ "$RC" = 2 ] && echo "ok   [2]: entrypoint unset keeps turn-shape hooks" || { echo "FAIL [$RC]: unset entrypoint turn-shape hook should run"; fail=1; }

cp "$TMP/plugin/hooks/fake-guard.sh" "$TMP/plugin/hooks/route-check.sh"
printf 'x' | CLAUDE_PROJECT_DIR="$TMP/proj-without" runsh CLAUDE_CODE_ENTRYPOINT=sdk-cli route-check >/dev/null 2>&1
RC=$?
[ "$RC" = 2 ] && echo "ok   [2]: route-check is not on the sdk skip list (a headless run on the wrong route is still wrong)" || { echo "FAIL [$RC]: route-check must run under sdk-cli"; fail=1; }

# --- 6. GIT_OPTIONAL_LOCKS=0 reaches every git call a hook makes ---------------
# A fake git first on PATH records the variable per call. The real
# temporal-marker-guard runs (a worktree `git diff` on git add / commit), via the
# real run.sh next to this probe.
mkdir -p "$TMP/fakebin" "$TMP/scratch-repo"
cat > "$TMP/fakebin/git" <<'EOF'
#!/bin/bash
echo "${GIT_OPTIONAL_LOCKS-unset}" >> "$GIT_LOCKS_LOG"
exit 0
EOF
chmod +x "$TMP/fakebin/git"
: > "$TMP/git-locks.log"
EV=$(jq -n --arg d "$TMP/scratch-repo" '{tool_name:"Bash",tool_input:{command:"git add f && git commit -m x"},cwd:$d}')
printf '%s' "$EV" | env -u GIT_OPTIONAL_LOCKS -u SYG_PROFILE -u SYG_ENABLE -u SYG_DISABLE -u CLAUDE_CODE_ENTRYPOINT GIT_LOCKS_LOG="$TMP/git-locks.log" PATH="$TMP/fakebin:$PATH" \
  CLAUDE_PROJECT_DIR="$TMP/proj-without" bash "$SCRIPT_DIR/run.sh" temporal-marker-guard >/dev/null 2>&1
calls=$(wc -l < "$TMP/git-locks.log")
nonzero=$(grep -vxc '0' "$TMP/git-locks.log")
if [ "$calls" -ge 1 ] && [ "$nonzero" = 0 ]; then
  echo "ok   [0]: hook git calls all see GIT_OPTIONAL_LOCKS=0 ($calls recorded)"
else
  echo "FAIL [calls $calls, non-zero values $nonzero: $(tr '\n' ' ' < "$TMP/git-locks.log")]: hook git calls must see GIT_OPTIONAL_LOCKS=0"
  fail=1
fi

# --- 7. components: profiles, SYG_ENABLE, SYG_DISABLE -------------------------
# Every stub below exits 2 when it runs, so rc 2 = the hook ran, rc 0 = skipped.
for h in turn-end-shape-gate recursive-rm-guard context-size-reminder lossy-pipe-guard \
  publish-gate temporal-marker-guard session-start; do
  cp "$TMP/plugin/hooks/fake-guard.sh" "$TMP/plugin/hooks/$h.sh"
done
comp() { # $1 want (ran|skipped), $2 label, then runsh args: NAME=value ... hook
  local want=$1 label=$2 rc wantrc
  shift 2
  printf 'x' | CLAUDE_PROJECT_DIR="$TMP/proj-without" runsh "$@" >/dev/null 2>&1
  rc=$?
  if [ "$want" = ran ]; then wantrc=2; else wantrc=0; fi
  if [ "$rc" = "$wantrc" ]; then echo "ok   [$rc]: $label"; else echo "FAIL [rc $rc, want $wantrc ($want)]: $label"; fail=1; fi
}

comp ran     "default: turn-end-shape-gate runs"                          turn-end-shape-gate
comp ran     "default: recursive-rm-guard runs"                           recursive-rm-guard
comp skipped "profile guards: turn-end-shape-gate skipped"                SYG_PROFILE=guards turn-end-shape-gate
comp ran     "profile guards: recursive-rm-guard runs"                    SYG_PROFILE=guards recursive-rm-guard
comp ran     "profile guards: context-size-reminder runs"                 SYG_PROFILE=guards context-size-reminder
comp skipped "profile none: recursive-rm-guard skipped"                   SYG_PROFILE=none recursive-rm-guard
comp ran     "profile none: session-start runs"                           SYG_PROFILE=none session-start
comp ran     "profile bogus behaves as full: turn-end-shape-gate runs"    SYG_PROFILE=bogus turn-end-shape-gate
comp ran     "profile bogus behaves as full: recursive-rm-guard runs"     SYG_PROFILE=bogus recursive-rm-guard
comp ran     "empty profile behaves as full"                              SYG_PROFILE= turn-end-shape-gate
comp skipped "disable guards-shell: lossy-pipe-guard skipped"             SYG_DISABLE=guards-shell lossy-pipe-guard
comp ran     "disable guards-shell: publish-gate runs"                    SYG_DISABLE=guards-shell publish-gate
comp skipped "disable one hook: that hook skipped"                        SYG_DISABLE=lossy-pipe-guard lossy-pipe-guard
comp ran     "disable one hook: a sibling in its component runs"          SYG_DISABLE=lossy-pipe-guard recursive-rm-guard
comp ran     "profile none + enable guards-commit: temporal-marker-guard runs"  SYG_PROFILE=none SYG_ENABLE=guards-commit temporal-marker-guard
comp skipped "profile none + enable guards-commit: other components stay off"   SYG_PROFILE=none SYG_ENABLE=guards-commit recursive-rm-guard
comp ran     "profile none + enable one hook name: that hook runs"        SYG_PROFILE=none SYG_ENABLE=lossy-pipe-guard lossy-pipe-guard
comp skipped "enable and disable the same name: disabled"                 SYG_PROFILE=none SYG_ENABLE=lossy-pipe-guard SYG_DISABLE=lossy-pipe-guard lossy-pipe-guard
comp skipped "enable and disable the same component: disabled"            SYG_ENABLE=guards-shell SYG_DISABLE=guards-shell recursive-rm-guard
comp ran     "disable session: session-start still runs"                  SYG_DISABLE=session session-start
comp ran     "profile none + disable session: session-start still runs"   SYG_PROFILE=none SYG_DISABLE=session session-start
comp skipped "sdk-cli + enable turn-shape: turn-end-shape-gate still skipped"  CLAUDE_CODE_ENTRYPOINT=sdk-cli SYG_ENABLE=turn-shape turn-end-shape-gate
comp skipped "sdk-cli + enable the hook by name: still skipped"           CLAUDE_CODE_ENTRYPOINT=sdk-cli SYG_ENABLE=turn-end-shape-gate turn-end-shape-gate
comp skipped "sdk-cli: context-size-reminder skipped (context component)" CLAUDE_CODE_ENTRYPOINT=sdk-cli context-size-reminder
comp ran     "sdk-cli: recursive-rm-guard still runs"                     CLAUDE_CODE_ENTRYPOINT=sdk-cli recursive-rm-guard
comp skipped "separators: commas"                                         SYG_DISABLE=lossy-pipe-guard,publish-gate lossy-pipe-guard
comp skipped "separators: commas (second item)"                           SYG_DISABLE=lossy-pipe-guard,publish-gate publish-gate
comp skipped "separators: spaces"                                         "SYG_DISABLE=lossy-pipe-guard publish-gate" publish-gate
comp skipped "separators: comma plus space"                               "SYG_DISABLE=lossy-pipe-guard, publish-gate" publish-gate
comp skipped "separators: tab"                                            "SYG_DISABLE=lossy-pipe-guard	publish-gate" publish-gate
comp ran     "unknown names in the lists are ignored"                     "SYG_DISABLE=nope,still-nope" SYG_ENABLE=nada recursive-rm-guard

# A temp hooks dir with no components.tsv: every hook runs (fail toward guards on).
mkdir -p "$TMP/plugin2/hooks/lib"
cp "$SCRIPT_DIR/run.sh" "$TMP/plugin2/hooks/run.sh"
cp "$SCRIPT_DIR/lib/components.sh" "$TMP/plugin2/hooks/lib/components.sh"
for h in turn-end-shape-gate recursive-rm-guard; do cp "$TMP/plugin/hooks/fake-guard.sh" "$TMP/plugin2/hooks/$h.sh"; done
for set in "" SYG_PROFILE=none "SYG_DISABLE=guards-shell"; do
  printf 'x' | CLAUDE_PROJECT_DIR="$TMP/proj-without" env -u CLAUDE_CODE_ENTRYPOINT -u SYG_PROFILE -u SYG_ENABLE -u SYG_DISABLE \
    ${set:+"$set"} bash "$TMP/plugin2/hooks/run.sh" recursive-rm-guard >/dev/null 2>&1
  RC=$?
  [ "$RC" = 2 ] && echo "ok   [2]: components.tsv missing (env '${set:-none}'): recursive-rm-guard runs" \
    || { echo "FAIL [$RC]: components.tsv missing (env '${set:-none}'): recursive-rm-guard should run"; fail=1; }
done

# Variants of the plugin dir: run.sh and the lib are the real ones; the registry is
# replaced per case. mkplug NAME → $TMP/NAME/hooks with stubs for three hooks.
mkplug() {
  mkdir -p "$TMP/$1/hooks/lib"
  cp "$SCRIPT_DIR/run.sh" "$TMP/$1/hooks/run.sh"
  cp "$SCRIPT_DIR/lib/components.sh" "$TMP/$1/hooks/lib/components.sh"
  for h in turn-end-shape-gate recursive-rm-guard context-size-reminder; do
    cp "$TMP/plugin/hooks/fake-guard.sh" "$TMP/$1/hooks/$h.sh"
  done
}
variant() { # $1 want (ran|skipped), $2 label, $3 plugin variant, then runsh-style NAME=value ... hook
  local want=$1 label=$2 pl=$3 rc wantrc
  shift 3
  local -a set=()
  while [[ "${1:-}" == *=* ]]; do set+=("$1"); shift; done
  printf 'x' | CLAUDE_PROJECT_DIR="$TMP/proj-without" env -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ATTENDED \
    -u SYG_PROFILE -u SYG_ENABLE -u SYG_DISABLE "${set[@]+"${set[@]}"}" bash "$TMP/$pl/hooks/run.sh" "$@" >/dev/null 2>&1
  rc=$?
  if [ "$want" = ran ]; then wantrc=2; else wantrc=0; fi
  if [ "$rc" = "$wantrc" ]; then echo "ok   [$rc]: $label"; else echo "FAIL [rc $rc, want $wantrc ($want)]: $label"; fail=1; fi
}

# Profiles the guards bundle keeps or drops, for the hooks outside the shell guards.
for h in route-check dispatch-posture-gate pr-monitor-reminder; do cp "$TMP/plugin/hooks/fake-guard.sh" "$TMP/plugin/hooks/$h.sh"; done
comp ran     "profile guards: route-check runs"                           SYG_PROFILE=guards route-check
comp ran     "profile guards: dispatch-posture-gate runs"                 SYG_PROFILE=guards dispatch-posture-gate
comp skipped "profile guards: pr-monitor-reminder skipped"                SYG_PROFILE=guards pr-monitor-reminder
comp ran     "default: pr-monitor-reminder runs"                          pr-monitor-reminder
comp ran     "SYG_PROFILE with surrounding whitespace is trimmed (guards)" "SYG_PROFILE=  guards " recursive-rm-guard
comp skipped "SYG_PROFILE with surrounding whitespace is trimmed (skips turn-shape)" "SYG_PROFILE=  guards " turn-end-shape-gate

# A CRLF registry parses like an LF one: the profile still applies.
mkplug plugin-crlf
sed 's/$/\r/' "$SCRIPT_DIR/components.tsv" > "$TMP/plugin-crlf/hooks/components.tsv"
variant ran     "CRLF registry, default profile: recursive-rm-guard runs"      plugin-crlf recursive-rm-guard
variant skipped "CRLF registry, profile guards: turn-end-shape-gate skipped"   plugin-crlf SYG_PROFILE=guards turn-end-shape-gate
variant ran     "CRLF registry, profile guards: recursive-rm-guard runs"       plugin-crlf SYG_PROFILE=guards recursive-rm-guard

# `full` defines the universe: a hook whose component it does not list is enabled.
mkplug plugin-universe
printf 'recursive-rm-guard\tmystery\nturn-end-shape-gate\tturn-shape\n@profile\tfull\tsession turn-shape\n@profile\tnone\tsession\n' \
  > "$TMP/plugin-universe/hooks/components.tsv"
variant ran     "component outside the full profile: hook enabled even under profile none" plugin-universe SYG_PROFILE=none recursive-rm-guard
variant skipped "a listed component under profile none is still off (control)"             plugin-universe SYG_PROFILE=none turn-end-shape-gate

# Registry unusable + headless: the turn-shape and context hooks stay off (as before components existed).
mkplug plugin-notsv
variant skipped "no registry, sdk-cli: turn-end-shape-gate skipped"      plugin-notsv CLAUDE_CODE_ENTRYPOINT=sdk-cli turn-end-shape-gate
variant skipped "no registry, sdk-cli: context-size-reminder skipped"    plugin-notsv CLAUDE_CODE_ENTRYPOINT=sdk-cli context-size-reminder
variant ran     "no registry, sdk-cli: recursive-rm-guard still runs"    plugin-notsv CLAUDE_CODE_ENTRYPOINT=sdk-cli recursive-rm-guard
variant ran     "no registry, interactive: turn-end-shape-gate runs"     plugin-notsv turn-end-shape-gate
mkplug plugin-nofull
printf 'recursive-rm-guard\tguards-shell\nturn-end-shape-gate\tturn-shape\n@profile\tnone\tsession\n' > "$TMP/plugin-nofull/hooks/components.tsv"
variant skipped "no full line, sdk-cli: turn-end-shape-gate skipped"     plugin-nofull CLAUDE_CODE_ENTRYPOINT=sdk-cli turn-end-shape-gate
variant ran     "no full line: everything else runs"                     plugin-nofull SYG_PROFILE=none recursive-rm-guard

# A broken resolver must not block tools: run.sh treats everything as enabled.
mkdir -p "$TMP/plugin3/hooks/lib"
cp "$SCRIPT_DIR/run.sh" "$TMP/plugin3/hooks/run.sh"
cp "$SCRIPT_DIR/components.tsv" "$TMP/plugin3/hooks/components.tsv"
printf 'syg_enabled() {\nif then fi (\n' > "$TMP/plugin3/hooks/lib/components.sh"
cp "$TMP/plugin/hooks/fake-guard.sh" "$TMP/plugin3/hooks/recursive-rm-guard.sh"
printf 'x' | CLAUDE_PROJECT_DIR="$TMP/proj-without" env -u CLAUDE_CODE_ENTRYPOINT -u SYG_ENABLE -u SYG_DISABLE SYG_PROFILE=none bash "$TMP/plugin3/hooks/run.sh" recursive-rm-guard >/dev/null 2>&1
RC=$?
[ "$RC" = 2 ] && echo "ok   [2]: resolver with a syntax error fails open (hook runs)" || { echo "FAIL [$RC]: broken resolver should leave every hook enabled"; fail=1; }

# --- 8. event mode: run.sh --event <Event> -------------------------------------
# Stub hooks, all in one component `stubs` that the `none` profile drops. Each
# stub drains stdin unless it reads it itself.
mkdir -p "$TMP/ev-stubs" "$TMP/ev-proj-ovr/.claude/hooks"
evstub() { printf '#!/bin/bash\ncat >/dev/null\n%s\n' "$2" > "$TMP/ev-stubs/$1.sh"; }
evstub quiet-one    'exit 0'
evstub quiet-two    'exit 0'
evstub block-a      'echo BLOCK-A >&2; exit 2'
evstub block-a-slow 'sleep 0.3; echo BLOCK-A >&2; exit 2'
evstub block-b      'echo BLOCK-B >&2; exit 2'
evstub block-edit   'echo BLOCK-EDIT >&2; exit 2'
evstub warn-json    "echo '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"additionalContext\":\"WARN-JSON\"}}'"
evstub warn-json-two "echo '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"additionalContext\":\"WARN-JSON-TWO\"}}'"
evstub warn-plain   'echo WARN-PLAIN'
evstub block-with-out 'echo OUT-IGNORED; echo BLOCK-C >&2; exit 2'
evstub hang         'exec sleep 30'
evstub ask-json     "echo '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\",\"permissionDecisionReason\":\"ASK-WHY\"}}'"
evstub allow-json   "echo '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"allow\"}}'"
evstub approve-json "echo '{\"decision\":\"approve\"}'"
evstub ctx-nonstring "echo '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"additionalContext\":5}}'"
evstub sys-nonstring "echo '{\"systemMessage\":{}}'"
evstub deny-json    "echo '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"DENY-JSON\"}}'"
evstub stop-block   "echo '{\"decision\":\"block\",\"reason\":\"STOP-BLOCK\"}'"
evstub route-shaped "echo '{\"systemMessage\":\"SYS-MSG\",\"hookSpecificOutput\":{\"hookEventName\":\"SessionStart\",\"additionalContext\":\"ROUTE-CTX\"}}'"
evstub sys-only     "echo '{\"systemMessage\":\"SYS-ONLY\"}'"
evstub odd-key      "echo '{\"continue\":false,\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"additionalContext\":\"ODD-CTX\"}}'"
evstub odd-nested   "echo '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"updatedInput\":{}}}'"
evstub exit-one     'echo OUT-ONE; echo ERR-ONE >&2; exit 1'
evstub note-err     'echo NOTE-ERR >&2; exit 0'
evstub sleeper-one  'sleep 1; echo SLEPT-ONE'
evstub sleeper-two  'sleep 1; echo SLEPT-TWO'
printf '#!/bin/bash\nIN=$(cat)\nprintf "PROMPT:%%s\\n" "$(jq -r .prompt <<<"$IN")"\n' > "$TMP/ev-stubs/echo-prompt.sh"
{
  for f in "$TMP"/ev-stubs/*.sh; do printf '%s\tstubs\n' "$(basename "$f" .sh)"; done
  printf '@profile\tfull\tsession stubs\n@profile\tnone\tsession\n'
} > "$TMP/ev-components.tsv"
echo '#!/bin/bash' > "$TMP/ev-proj-ovr/.claude/hooks/block-a.sh"

# evplug NAME SPEC...: $TMP/NAME/hooks holds the real run.sh and resolver, the stub
# registry, every stub, and a hooks.json built from SPECs "Event;matcher;hook ..."
# (an empty matcher field = an entry with no matcher key).
evplug() {
  local d="$TMP/$1/hooks"
  shift
  mkdir -p "$d/lib"
  cp "$SCRIPT_DIR/run.sh" "$d/run.sh"
  cp "$SCRIPT_DIR/lib/components.sh" "$d/lib/components.sh"
  cp "$TMP/ev-components.tsv" "$d/components.tsv"
  cp "$TMP"/ev-stubs/*.sh "$d/"
  printf '%s\n' "$@" | jq -R -s '
    [split("\n")[] | select(length > 0) | split(";")
     | {ev: .[0], m: .[1], names: (.[2] | split(" "))}]
    | reduce .[] as $e ({hooks: {}};
        .hooks[$e.ev] += [(if $e.m == "" then {} else {matcher: $e.m} end)
          + {hooks: [$e.names[] | {type: "command", command: ("bash \"${CLAUDE_PLUGIN_ROOT}/hooks/run.sh\" " + .)}]}])' \
    > "$d/hooks.json"
}
pl() { jq -nc --arg t "$1" '{tool_name: $t, tool_input: {command: "x"}, cwd: "/tmp"}'; }
NOTOOL='{"hook_event_name":"Stop","session_id":"probe"}'
STARTUP='{"hook_event_name":"SessionStart","source":"startup","session_id":"probe"}'
PROMPT='{"hook_event_name":"UserPromptSubmit","prompt":"hello","session_id":"probe"}'
# ev PLUGIN EVENT PAYLOAD [NAME=value ...] → EVOUT, EVERR, EVRC. EV_PROJ overrides
# the project dir (default: no project copies).
ev() {
  local p=$1 evn=$2 payload=$3
  shift 3
  # From a file, not a pipe: run.sh may exit before reading stdin, and a pipe's
  # writer would then die of SIGPIPE (rc 141 under pipefail).
  printf '%s' "$payload" > "$TMP/ev-payload"
  EVOUT=$(env -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ATTENDED -u SYG_PROFILE \
    -u SYG_ENABLE -u SYG_DISABLE CLAUDE_PROJECT_DIR="${EV_PROJ:-$TMP/proj-without}" "$@" \
    bash "$TMP/$p/hooks/run.sh" --event "$evn" <"$TMP/ev-payload" 2>"$TMP/ev-err")
  EVRC=$?
  EVERR=$(cat "$TMP/ev-err")
}
ctxjson() { # $1 event, $2 additionalContext (literal \n escapes as JSON wants them)
  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}' "$1" "$2"
}

evplug ev-one "PreToolUse;Bash;quiet-one quiet-two block-a"
ev ev-one PreToolUse "$(pl Bash)"
check "event: one exit-2 stub among quiet ones blocks with its text" 2 "$EVRC" "" "$EVOUT" "BLOCK-A" "$EVERR"

evplug ev-two "PreToolUse;Bash;block-a-slow block-b"
ev ev-two PreToolUse "$(pl Bash)"
check "event: two blockers, both texts in hooks.json order (the first finishes last)" \
  2 "$EVRC" "" "$EVOUT" $'BLOCK-A\n\nBLOCK-B' "$EVERR"

evplug ev-warn "PreToolUse;Bash;warn-json warn-plain block-a"
ev ev-warn PreToolUse "$(pl Bash)"
check "event: a block keeps the siblings' warnings under 'Also from seyag hooks:'" \
  2 "$EVRC" "" "$EVOUT" $'BLOCK-A\n\nAlso from seyag hooks:\nWARN-JSON\n\nWARN-PLAIN' "$EVERR"

evplug ev-deny "PreToolUse;Bash;warn-json deny-json"
ev ev-deny PreToolUse "$(pl Bash)"
check "event: JSON permissionDecision deny blocks like exit 2" \
  2 "$EVRC" "" "$EVOUT" $'DENY-JSON\n\nAlso from seyag hooks:\nWARN-JSON' "$EVERR"

evplug ev-stop "Stop;;quiet-one stop-block"
ev ev-stop Stop "$NOTOOL"
check "event: JSON decision block on Stop blocks like exit 2" 2 "$EVRC" "" "$EVOUT" "STOP-BLOCK" "$EVERR"

evplug ev-ctx "UserPromptSubmit;;warn-json echo-prompt"
ev ev-ctx UserPromptSubmit "$PROMPT"
check "event: JSON context and plain-text context merge into one object, in order (stdin reached the hook)" \
  0 "$EVRC" "$(ctxjson UserPromptSubmit 'WARN-JSON\n\nPROMPT:hello')" "$EVOUT" "" "$EVERR"

# Event-shape fidelity: plain stdout is context only for SessionStart and
# UserPromptSubmit; additionalContext is never emitted for Stop.
evplug ev-fid "PreToolUse;Bash;warn-json warn-plain"
ev ev-fid PreToolUse "$(pl Bash)"
check "event: plain stdout on PreToolUse goes to stderr, not into the context" \
  0 "$EVRC" "$(ctxjson PreToolUse WARN-JSON)" "$EVOUT" "WARN-PLAIN" "$EVERR"
evplug ev-stopctx "Stop;;warn-json warn-plain sys-only"
ev ev-stopctx Stop "$NOTOOL"
check "event: on Stop, context and plain stdout go to stderr; only systemMessage is emitted" \
  0 "$EVRC" '{"systemMessage":"SYS-ONLY"}' "$EVOUT" $'WARN-JSON\nWARN-PLAIN' "$EVERR"

# permissionDecision "ask" is forwarded when nothing blocks; values the merge
# does not forward are named.
evplug ev-ask "PreToolUse;Bash;ask-json warn-json"
ev ev-ask PreToolUse "$(pl Bash)"
check "event: permissionDecision ask is forwarded with its reason" 0 "$EVRC" \
  '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"WARN-JSON","permissionDecision":"ask","permissionDecisionReason":"ASK-WHY"}}' \
  "$EVOUT" "" "$EVERR"
evplug ev-askblk "PreToolUse;Bash;ask-json block-a"
ev ev-askblk PreToolUse "$(pl Bash)"
check "event: on a block, an ask reason follows under 'Also from seyag hooks:'" \
  2 "$EVRC" "" "$EVOUT" $'BLOCK-A\n\nAlso from seyag hooks:\nASK-WHY' "$EVERR"
evplug ev-vals "PreToolUse;Bash;allow-json approve-json ctx-nonstring sys-nonstring"
ev ev-vals PreToolUse "$(pl Bash)"
check "event: allow, a non-block decision and non-string context or message are named on stderr" \
  0 "$EVRC" "" "$EVOUT" \
  "run.sh: seyag hook 'allow-json' emitted hookSpecificOutput.permissionDecision \"allow\" on PreToolUse, which event mode does not forward
run.sh: seyag hook 'approve-json' emitted decision \"approve\", which event mode does not forward
run.sh: seyag hook 'ctx-nonstring' emitted hookSpecificOutput.additionalContext that is not a string, which event mode does not forward
run.sh: seyag hook 'sys-nonstring' emitted systemMessage that is not a string, which event mode does not forward" "$EVERR"

evplug ev-blkout "PreToolUse;Bash;block-with-out warn-json"
ev ev-blkout PreToolUse "$(pl Bash)"
check "event: an exit-2 hook's stdout is ignored" \
  2 "$EVRC" "" "$EVOUT" $'BLOCK-C\n\nAlso from seyag hooks:\nWARN-JSON' "$EVERR"

evplug ev-skip "PreToolUse;Bash;missing-hook block-a"
ev ev-skip PreToolUse "$(pl Bash)"
check "event: skip notices print after the block text" \
  2 "$EVRC" "" "$EVOUT" $'BLOCK-A\nrun.sh: no such seyag hook \'missing-hook\'' "$EVERR"

mkdir -p "$TMP/ev-tmpdir"
ev ev-one PreToolUse "$(pl Bash)" TMPDIR="$TMP/ev-tmpdir"
if [ "$EVRC" = 2 ] && [ -z "$(ls -A "$TMP/ev-tmpdir")" ]; then
  echo "ok   [2]: event: the temp dir is removed"
else
  echo "FAIL [rc $EVRC, left: $(ls -A "$TMP/ev-tmpdir" | tr '\n' ' ')]: event: the temp dir is removed"
  fail=1
fi

# One hung hook: timed out and ignored; the other block still lands.
evplug ev-hang "PreToolUse;Bash;hang block-a"
mkdir -p "$TMP/ev-tmpdir-hang"
t0=$(date +%s%N)
ev ev-hang PreToolUse "$(pl Bash)" SYG_EVENT_HOOK_TIMEOUT=1 TMPDIR="$TMP/ev-tmpdir-hang"
ms=$((($(date +%s%N) - t0) / 1000000))
if [ "$EVRC" = 2 ] && [ "$EVERR" = "BLOCK-A" ] && [ "$ms" -lt 4000 ] && [ -z "$(ls -A "$TMP/ev-tmpdir-hang")" ]; then
  echo "ok   [2]: event: a hung hook times out, the other block lands (${ms} ms), temp dir removed"
else
  echo "FAIL [rc $EVRC, ${ms} ms, stderr '$EVERR', want rc 2 BLOCK-A under 4000 ms, temp dir empty]: event: a hung hook times out"
  fail=1
fi

# The merge itself failing (a jq that refuses -rn) keeps the exit-2 blocks.
mkdir -p "$TMP/jqshim"
printf '#!/bin/bash\nfor a; do [ "$a" = -rn ] && exit 5; done\nexec %q "$@"\n' "$(command -v jq)" > "$TMP/jqshim/jq"
chmod +x "$TMP/jqshim/jq"
ev ev-two PreToolUse "$(pl Bash)" PATH="$TMP/jqshim:$PATH"
check "event: a failed merge still blocks, blockers joined by a blank line" \
  2 "$EVRC" "" "$EVOUT" $'BLOCK-A\n\nBLOCK-B' "$EVERR"

# No jq at all: fail open.
mkdir -p "$TMP/nojq-bin"
pl Bash > "$TMP/ev-payload"
OUT=$(env -i PATH="$TMP/nojq-bin" CLAUDE_PROJECT_DIR="$TMP/proj-without" \
  "$BASH" "$TMP/ev-one/hooks/run.sh" --event PreToolUse <"$TMP/ev-payload" 2>"$TMP/ev-err")
RC=$?
check "event: no jq on PATH fails open" 0 "$RC" "" "$OUT" "" "$(cat "$TMP/ev-err")"
OUT=$(env -i PATH="$PATH" CLAUDE_PROJECT_DIR="$TMP/proj-without" \
  "$BASH" "$TMP/ev-one/hooks/run.sh" --event PreToolUse <"$TMP/ev-payload" 2>"$TMP/ev-err")
RC=$?
check "event: the same call with jq on PATH blocks (control)" 2 "$RC" "" "$OUT" "BLOCK-A" "$(cat "$TMP/ev-err")"

evplug ev-badjson "PreToolUse;Bash;block-a"
printf '{not json\n' > "$TMP/ev-badjson/hooks/hooks.json"
ev ev-badjson PreToolUse "$(pl Bash)"
check "event: unparsable hooks.json says so and runs nothing" \
  0 "$EVRC" "" "$EVOUT" "run.sh: hooks.json unparsable; event mode ran nothing" "$EVERR"

evplug ev-match "PreToolUse;Bash;block-a" "PreToolUse;Edit|Write|MultiEdit;block-edit"
ev ev-match PreToolUse "$(pl Edit)"
check "event: tool_name Edit selects only the Edit|Write|MultiEdit entry" 2 "$EVRC" "" "$EVOUT" "BLOCK-EDIT" "$EVERR"
ev ev-match PreToolUse "$(pl Read)"
check "event: tool_name Read selects nothing" 0 "$EVRC" "" "$EVOUT" "" "$EVERR"

evplug ev-simple "PreToolUse;Bas;block-b" "PreToolUse;mcp__.*;warn-json"
ev ev-simple PreToolUse "$(pl Bash)"
check "event: a simple matcher compares exactly (Bas does not select Bash)" 0 "$EVRC" "" "$EVOUT" "" "$EVERR"
ev ev-simple PreToolUse "$(pl mcp__srv__tool)"
check "event: a regex matcher selects a matching tool" 0 "$EVRC" "$(ctxjson PreToolUse WARN-JSON)" "$EVOUT" "" "$EVERR"

evplug ev-star "PreToolUse;*;warn-json-two" "PreToolUse;;warn-json"
ev ev-star PreToolUse "$(pl Read)"
check "event: matcher * and no matcher select every tool" \
  0 "$EVRC" "$(ctxjson PreToolUse 'WARN-JSON-TWO\n\nWARN-JSON')" "$EVOUT" "" "$EVERR"

evplug ev-notool "Stop;Bash;block-a"
ev ev-notool Stop "$NOTOOL"
check "event: a payload without tool_name selects every entry, matcher or not" 2 "$EVRC" "" "$EVOUT" "BLOCK-A" "$EVERR"

ev ev-one PreToolUse "$(pl Bash)" SYG_PROFILE=none
check "event: SYG_PROFILE=none runs nothing on PreToolUse" 0 "$EVRC" "" "$EVOUT" "" "$EVERR"

evplug ev-ovr "PreToolUse;Bash;block-a block-b"
EV_PROJ="$TMP/ev-proj-ovr" ev ev-ovr PreToolUse "$(pl Bash)"
check "event: a project copy of a hook skips that hook" 2 "$EVRC" "" "$EVOUT" "BLOCK-B" "$EVERR"

evplug ev-exit1 "PreToolUse;Bash;exit-one warn-json"
ev ev-exit1 PreToolUse "$(pl Bash)"
check "event: a hook exiting 1 is ignored, output and all" 0 "$EVRC" "$(ctxjson PreToolUse WARN-JSON)" "$EVOUT" "" "$EVERR"

evplug ev-nojson "PreToolUse;Bash;block-a"
rm "$TMP/ev-nojson/hooks/hooks.json"
ev ev-nojson PreToolUse "$(pl Bash)"
check "event: missing hooks.json exits 0" 0 "$EVRC" "" "$EVOUT" "" "$EVERR"

ev ev-one NoSuchEvent "$(pl Bash)"
check "event: unknown event exits 0" 0 "$EVRC" "" "$EVOUT" "" "$EVERR"
ev ev-one "" "$(pl Bash)"
check "event: empty event name exits 0" 0 "$EVRC" "" "$EVOUT" "" "$EVERR"

evplug ev-sys "SessionStart;;route-shaped warn-plain"
ev ev-sys SessionStart "$STARTUP"
check "event: systemMessage and additionalContext from a route-check-shaped hook, plus plain text, all kept" \
  0 "$EVRC" '{"systemMessage":"SYS-MSG","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"ROUTE-CTX\n\nWARN-PLAIN"}}' "$EVOUT" "" "$EVERR"
evplug ev-sysonly "SessionStart;;sys-only"
ev ev-sysonly SessionStart "$STARTUP"
check "event: a lone systemMessage is emitted alone" 0 "$EVRC" '{"systemMessage":"SYS-ONLY"}' "$EVOUT" "" "$EVERR"
evplug ev-sysblk "PreToolUse;Bash;route-shaped block-a"
ev ev-sysblk PreToolUse "$(pl Bash)"
check "event: on a block, systemMessage follows the sibling context on stderr" \
  2 "$EVRC" "" "$EVOUT" $'BLOCK-A\n\nAlso from seyag hooks:\nROUTE-CTX\n\nSYS-MSG' "$EVERR"

evplug ev-odd "PreToolUse;Bash;odd-key odd-nested"
ev ev-odd PreToolUse "$(pl Bash)"
check "event: a JSON key event mode does not forward is named on stderr, never dropped silently" \
  0 "$EVRC" "$(ctxjson PreToolUse ODD-CTX)" "$EVOUT" \
  $'run.sh: seyag hook \'odd-key\' emitted continue, which event mode does not forward\nrun.sh: seyag hook \'odd-nested\' emitted hookSpecificOutput.updatedInput, which event mode does not forward' "$EVERR"

evplug ev-note "PreToolUse;Bash;note-err warn-json" "PostToolUse;Bash;note-err block-a"
ev ev-note PreToolUse "$(pl Bash)"
check "event: an exit-0 hook's stderr passes through" 0 "$EVRC" "$(ctxjson PreToolUse WARN-JSON)" "$EVOUT" "NOTE-ERR" "$EVERR"
ev ev-note PostToolUse "$(pl Bash)"
check "event: an exit-0 hook's stderr passes through on a block too" 2 "$EVRC" "" "$EVOUT" $'BLOCK-A\n\nNOTE-ERR' "$EVERR"

evplug ev-par "UserPromptSubmit;;sleeper-one sleeper-two"
t0=$(date +%s%N)
ev ev-par UserPromptSubmit "$PROMPT"
ms=$((($(date +%s%N) - t0) / 1000000))
if [ "$EVRC" = 0 ] && [ "$ms" -lt 1800 ] && [ "$EVOUT" = "$(ctxjson UserPromptSubmit 'SLEPT-ONE\n\nSLEPT-TWO')" ]; then
  echo "ok   [0]: event: hooks run in parallel (two 1 s sleepers took ${ms} ms)"
else
  echo "FAIL [rc $EVRC, ${ms} ms, stdout '$EVOUT', want rc 0 under 1800 ms and both sleepers' output]: event: hooks run in parallel"
  fail=1
fi

# The real hooks: SessionStart in event mode still prints the version line first.
mkdir -p "$TMP/ev-rules" "$TMP/ev-state"
OUT=$(printf '%s' "$STARTUP" | env -u CLAUDE_CODE_ENTRYPOINT -u SYG_PROFILE -u SYG_ENABLE -u SYG_DISABLE -u CLAUDE_PLUGIN_ROOT \
  -u SYG_ROUTE_REQUIRED -u SYG_ROUTE_MARKER_FILE -u SYG_ROUTE_MARKER_FIELD \
  CLAUDE_PROJECT_DIR="$TMP/proj-without" SYG_USER_RULES_DIR="$TMP/ev-rules" SYG_STATE_DIR="$TMP/ev-state" \
  bash "$SCRIPT_DIR/run.sh" --event SessionStart 2>/dev/null)
RC=$?
if [ "$RC" = 0 ] && [[ "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$OUT" 2>/dev/null)" == "seyag plugin "* ]]; then
  echo "ok   [0]: event: real SessionStart context starts with 'seyag plugin '"
else
  echo "FAIL [rc $RC, out '$OUT']: event: real SessionStart context should start with 'seyag plugin '"
  fail=1
fi

exit $fail
