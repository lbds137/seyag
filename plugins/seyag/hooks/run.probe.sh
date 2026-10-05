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
# Uses a throwaway fake hook placed next to run.sh in a temp copy, so the real
# hooks are never involved.
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

exit $fail
