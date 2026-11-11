#!/bin/bash
# Wiring parity: every hook has a probe and a hooks.json entry, every probe and
# hooks.json entry has a hook script, and every executable bin tool has a
# tests/<tool>.probe.sh; and run.sh --event runs exactly the hooks hooks.json
# wires, in order. The checker takes a root dir so the probe can prove it fails
# on mutated copies of the tree.
# Usage: tests/hook-wiring.probe.sh   (from anywhere)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Exemptions: "<kind>:<name>  reason", one per entry. Kinds: hook-probe,
# hook-wired, bin-probe, probe-hook. An entry needs a reason.
EXEMPT=(
  "bin-probe:zai-spend  alias symlink to zai-usage, kept for PATH callers; tests/zai-usage.probe.sh pins both"
  "probe-hook:pr-merge-review-check-review  second half of the pr-merge-review-check probe split (perf13a): one hook, two probe files, balanced probe shards"
)

fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

exempt() {
  local e
  for e in "${EXEMPT[@]+"${EXEMPT[@]}"}"; do
    [ "${e%% *}" = "$1" ] && return 0
  done
  return 1
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# run.sh's syntax-ok stamps go under the cache dir: every run.sh call here writes
# to the probe's own cache, never the real ~/.cache/seyag.
export XDG_CACHE_HOME="$TMP/xdg-cache"

# The hook name in a hooks.json command: the word after `hooks/run.sh"`. run.sh
# --event parses it the same way; check_root's dispatch check pins the agreement.
parse_names() { sed -n 's/.*hooks\/run\.sh" *\([A-Za-z0-9._-][A-Za-z0-9._-]*\).*/\1/p'; }

# check_root ROOT [dispatch]: print one line per offender; exit 1 if any. With
# `dispatch`, also run ROOT's run.sh --event against stub hooks (slower).
check_root() {
  local root=$1 mode=${2:-} hooks bad_n=0 f name wired
  hooks="$root/plugins/seyag/hooks"
  report() { echo "$1"; bad_n=$((bad_n + 1)); }

  if ! wired=$(jq -r '.. | .command? // empty' "$hooks/hooks.json" 2>&1 | parse_names); then
    echo "hooks.json unreadable"; return 1
  fi
  [ -n "$wired" ] || report "hooks.json names no hooks (command strings not parsed)"

  # Dispatcher parity: every hook script becomes a stub that blocks with its own
  # name, and each event runs with a payload that has no tool_name (so every entry
  # is selected). The blockers' text, in order, must be the names parsed above.
  if [ "$mode" = dispatch ]; then
    local st ev got want
    st=$(mktemp -d "$TMP/dispatch.XXXXXX")
    mkdir -p "$st/hooks/lib" "$st/proj"
    cp "$hooks/run.sh" "$hooks/hooks.json" "$st/hooks/"
    cp "$hooks/lib/components.sh" "$st/hooks/lib/" 2>/dev/null
    cp "$hooks/components.tsv" "$st/hooks/" 2>/dev/null
    for f in "$hooks"/*.sh; do
      name=$(basename "$f" .sh)
      case "$name" in run | *.probe) continue ;; esac
      printf '#!/bin/bash\necho %s >&2\nexit 2\n' "$name" > "$st/hooks/$name.sh"
    done
    while IFS= read -r ev; do
      want=$(jq -r --arg ev "$ev" '.hooks[$ev][].hooks[].command? // empty' "$hooks/hooks.json" | parse_names | sed '$!G')
      got=$(env -u SYG_PROFILE -u SYG_ENABLE -u SYG_DISABLE -u CLAUDE_CODE_ENTRYPOINT CLAUDE_PROJECT_DIR="$st/proj" \
        bash "$st/hooks/run.sh" --event "$ev" <<<'{}' 2>&1 >/dev/null)
      [ "$got" = "$want" ] \
        || report "run.sh --event $ev runs [$(tr '\n' ' ' <<<"$got")] but hooks.json wires [$(tr '\n' ' ' <<<"$want")]"
    done < <(jq -r '.hooks | keys[]' "$hooks/hooks.json")
  fi

  for f in "$hooks"/*.sh; do
    [ -e "$f" ] || continue
    name=$(basename "$f" .sh)
    case "$name" in *.probe) continue ;; esac
    [ -e "$hooks/$name.probe.sh" ] || exempt "hook-probe:$name" \
      || report "hook $name has no $name.probe.sh"
    [ "$name" = run ] && continue
    grep -qxF "$name" <<<"$wired" || exempt "hook-wired:$name" \
      || report "hook $name is not wired in hooks.json"
  done
  for f in "$hooks"/*.probe.sh; do
    [ -e "$f" ] || continue
    name=$(basename "$f" .probe.sh)
    [ -e "$hooks/$name.sh" ] || exempt "probe-hook:$name" \
      || report "probe $name.probe.sh has no $name.sh"
  done
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ -e "$hooks/$name.sh" ] || report "hooks.json names $name but $name.sh is missing"
  done <<<"$wired"
  # Components: every wired hook has exactly one line in components.tsv, every
  # tsv hook line names an existing hook script that hooks.json wires, and every
  # hook line has a non-empty component that the `full` profile lists (else the
  # default would switch that hook off).
  local tsv="$hooks/components.tsv" tsv_hooks="" kind a rest n full=""
  if [ ! -r "$tsv" ]; then
    report "components.tsv is missing or unreadable"
  else
    while IFS=$'\t' read -r kind a rest || [ -n "$kind" ]; do
      case "$kind" in
        '' | '#'*) ;;
        @profile) [ "$a" = full ] && full=" $rest " ;;
        *) tsv_hooks+="$kind"$'\n' ;;
      esac
    done <"$tsv"
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      n=$(grep -cxF "$name" <<<"$tsv_hooks")
      [ "$n" -eq 1 ] || report "hook $name appears $n times in components.tsv (want 1)"
    done <<<"$wired"
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      [ -e "$hooks/$name.sh" ] || report "components.tsv names $name but $name.sh is missing"
      # Reverse parity: a registry line for a hook hooks.json never runs is dead.
      grep -qxF "$name" <<<"$wired" || report "components.tsv names $name but hooks.json does not wire it"
    done <<<"$tsv_hooks"
    while IFS=$'\t' read -r kind a rest || [ -n "$kind" ]; do
      case "$kind" in '' | '#'*) continue ;; @profile) continue ;; esac
      # An empty component leaves the hook outside every profile and SYG_DISABLE.
      [ -n "$a" ] || { report "components.tsv: $kind has an empty component"; continue; }
      case "$full" in *" $a "*) ;; *) report "components.tsv: $kind uses component $a, which the full profile lacks" ;; esac
    done <"$tsv"
    # The resolver's headless fallback list must equal the registry's hooks of the
    # headless-off components, or a missing registry would change headless behavior.
    # The lib is sourced in a subshell, so the values are the ones the resolver uses.
    local lib="$hooks/lib/components.sh" off_comps off_hooks want_hooks
    # shellcheck source=/dev/null
    off_comps=$(source "$lib" >/dev/null 2>&1 && printf '%s' "${SYG_HEADLESS_OFF:-}")
    # shellcheck source=/dev/null
    off_hooks=$(source "$lib" >/dev/null 2>&1 && printf '%s' "${SYG_HEADLESS_OFF_HOOKS:-}")
    if [ -z "$off_comps" ] || [ -z "$off_hooks" ]; then
      report "lib/components.sh lacks SYG_HEADLESS_OFF or SYG_HEADLESS_OFF_HOOKS"
    else
      want_hooks=$(while IFS=$'\t' read -r kind a rest || [ -n "$kind" ]; do
        a=${a%$'\r'}
        case "$kind" in '' | '#'*) continue ;; @profile) continue ;; esac
        case " $off_comps " in *" $a "*) printf '%s\n' "$kind" ;; esac
      done <"$tsv" | sort)
      [ "$(tr ' ' '\n' <<<"$off_hooks" | sort)" = "$want_hooks" ] \
        || report "SYG_HEADLESS_OFF_HOOKS differs from the components.tsv hooks of: $off_comps"
    fi
  fi
  for f in "$root"/plugins/seyag/bin/*; do
    [ -f "$f" ] && [ -x "$f" ] || continue
    name=$(basename "$f")
    [ -e "$root/tests/$name.probe.sh" ] || exempt "bin-probe:$name" \
      || report "bin tool $name has no tests/$name.probe.sh"
  done
  [ "$bad_n" -eq 0 ]
}

out=$(check_root "$REPO" dispatch)
if [ $? -eq 0 ]; then
  ok "every hook and bin tool is probed and wired; run.sh --event runs exactly the wired hooks"
else
  while IFS= read -r l; do bad "$l"; done <<<"$out"
fi

# Positive controls: each mutation of a temp copy must be reported.
mutant() { # mutant NAME -> fresh copy at $TMP/NAME
  mkdir -p "$TMP/$1/plugins/seyag" "$TMP/$1/tests"
  cp -R "$REPO/plugins/seyag/hooks" "$REPO/plugins/seyag/bin" "$TMP/$1/plugins/seyag/"
  cp "$REPO"/tests/*.probe.sh "$TMP/$1/tests/"
}
expect() { # expect NAME NEEDLE [dispatch]
  local o
  o=$(check_root "$TMP/$1" "${3:-}"); local rc=$?
  if [ "$rc" -ne 0 ] && grep -qF -- "$2" <<<"$o"; then
    ok "control $1: reported ($2)"
  else
    bad "control $1: not reported (rc=$rc, wanted '$2'): $o"
  fi
}

# A trailing flag after the hook name: both parses still take the name.
mutant trailing-flag
jq '(.. | select(type == "object" and ((.command? // "") | tostring | endswith("run.sh\" publish-gate"))) | .command) += " --flag"' \
  "$REPO/plugins/seyag/hooks/hooks.json" > "$TMP/trailing-flag/plugins/seyag/hooks/hooks.json"
if ! grep -qF 'publish-gate --flag' "$TMP/trailing-flag/plugins/seyag/hooks/hooks.json"; then
  bad "control trailing-flag: the mutation did not apply"
elif o=$(check_root "$TMP/trailing-flag" dispatch); then
  ok "control trailing-flag: a command with a trailing --flag still parses to its hook in both parses"
else
  bad "control trailing-flag: reported, but both parses should agree: $o"
fi
# The same tree with run.sh taking the last word instead: the parses disagree.
mutant dispatch-drift
cp "$TMP/trailing-flag/plugins/seyag/hooks/hooks.json" "$TMP/dispatch-drift/plugins/seyag/hooks/hooks.json"
sed '/capture("hooks\/run/c\   | (((.command // "") | tostring | split(" ") | last) // "") as $n' \
  "$REPO/plugins/seyag/hooks/run.sh" > "$TMP/dispatch-drift/plugins/seyag/hooks/run.sh"
if grep -qF 'split(" ") | last' "$TMP/dispatch-drift/plugins/seyag/hooks/run.sh"; then
  expect dispatch-drift "run.sh --event PreToolUse runs" dispatch
else
  bad "control dispatch-drift: the mutation did not apply"
fi

mutant no-hook-probe;  rm "$TMP/no-hook-probe/plugins/seyag/hooks/publish-gate.probe.sh"
expect no-hook-probe "hook publish-gate has no publish-gate.probe.sh"

mutant orphan-probe;   echo : > "$TMP/orphan-probe/plugins/seyag/hooks/ghost.probe.sh"
expect orphan-probe "probe ghost.probe.sh has no ghost.sh"

mutant unwired
jq 'del(.. | select(type == "object" and ((.command? // "") | tostring | endswith("run.sh\" publish-gate"))))' \
  "$REPO/plugins/seyag/hooks/hooks.json" > "$TMP/unwired/plugins/seyag/hooks/hooks.json"
expect unwired "hook publish-gate is not wired in hooks.json"

mutant no-bin-probe;   rm "$TMP/no-bin-probe/tests/safe-clean.probe.sh"
expect no-bin-probe "bin tool safe-clean has no tests/safe-clean.probe.sh"

mutant missing-script; rm "$TMP/missing-script/plugins/seyag/hooks/publish-gate.sh" "$TMP/missing-script/plugins/seyag/hooks/publish-gate.probe.sh"
expect missing-script "hooks.json names publish-gate but publish-gate.sh is missing"

mutant tsv-unlisted;   grep -v '^publish-gate	' "$REPO/plugins/seyag/hooks/components.tsv" > "$TMP/tsv-unlisted/plugins/seyag/hooks/components.tsv"
expect tsv-unlisted "hook publish-gate appears 0 times in components.tsv (want 1)"

mutant tsv-duplicate;  printf 'publish-gate\tguards-outbound\n' >> "$TMP/tsv-duplicate/plugins/seyag/hooks/components.tsv"
expect tsv-duplicate "hook publish-gate appears 2 times in components.tsv (want 1)"

mutant tsv-ghost;      printf 'ghost-guard\tguards-shell\n' >> "$TMP/tsv-ghost/plugins/seyag/hooks/components.tsv"
expect tsv-ghost "components.tsv names ghost-guard but ghost-guard.sh is missing"

mutant tsv-missing;    rm "$TMP/tsv-missing/plugins/seyag/hooks/components.tsv"
expect tsv-missing "components.tsv is missing or unreadable"

mutant tsv-off-full;   sed 's/^publish-gate\t.*/publish-gate\tghost-component/' "$REPO/plugins/seyag/hooks/components.tsv" > "$TMP/tsv-off-full/plugins/seyag/hooks/components.tsv"
expect tsv-off-full "publish-gate uses component ghost-component, which the full profile lacks"

mutant tsv-empty-component; sed 's/^publish-gate\t.*/publish-gate\t/' "$REPO/plugins/seyag/hooks/components.tsv" > "$TMP/tsv-empty-component/plugins/seyag/hooks/components.tsv"
expect tsv-empty-component "components.tsv: publish-gate has an empty component"

mutant tsv-unwired
jq 'del(.. | select(type == "object" and ((.command? // "") | tostring | endswith("run.sh\" publish-gate"))))' \
  "$REPO/plugins/seyag/hooks/hooks.json" > "$TMP/tsv-unwired/plugins/seyag/hooks/hooks.json"
expect tsv-unwired "components.tsv names publish-gate but hooks.json does not wire it"

mutant headless-drift; sed 's/ context-size-reminder"$/"/' "$REPO/plugins/seyag/hooks/lib/components.sh" > "$TMP/headless-drift/plugins/seyag/hooks/lib/components.sh"
expect headless-drift "SYG_HEADLESS_OFF_HOOKS differs from the components.tsv hooks of: turn-shape context"

mutant headless-moved; sed 's/^turn-end-shape-gate\tturn-shape/turn-end-shape-gate\tguards-shell/' "$REPO/plugins/seyag/hooks/components.tsv" > "$TMP/headless-moved/plugins/seyag/hooks/components.tsv"
expect headless-moved "SYG_HEADLESS_OFF_HOOKS differs from the components.tsv hooks of: turn-shape context"

# Event-mode degradations. A stub tree in which the first PreToolUse hook asks
# with no reason and every other hook is silent.
hooks="$REPO/plugins/seyag/hooks"
em="$TMP/event-mode"
mkdir -p "$em/hooks/lib" "$em/proj"
cp "$hooks/run.sh" "$hooks/hooks.json" "$em/hooks/"
cp "$hooks/lib/components.sh" "$em/hooks/lib/" 2>/dev/null
cp "$hooks/components.tsv" "$em/hooks/" 2>/dev/null
asker=$(jq -r '.hooks.PreToolUse[].hooks[].command? // empty' "$hooks/hooks.json" | parse_names | head -n 1)
for f in "$hooks"/*.sh; do
  name=$(basename "$f" .sh)
  case "$name" in run | *.probe) continue ;; esac
  printf '#!/bin/bash\nexit 0\n' > "$em/hooks/$name.sh"
done
printf '#!/bin/bash\necho %s\nexit 0\n' \
  "'{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\"}}'" > "$em/hooks/$asker.sh"
em_run() { env -u SYG_PROFILE -u SYG_ENABLE -u SYG_DISABLE -u CLAUDE_CODE_ENTRYPOINT CLAUDE_PROJECT_DIR="$em/proj" \
  bash "$em/hooks/run.sh" --event PreToolUse <<<'{}'; }

# A reason-less ask is merged with a filled reason, as a reason-less block is.
out=$(em_run 2>/dev/null)
[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out" 2>/dev/null)" = ask ] \
  && jq -e '.hookSpecificOutput.permissionDecisionReason | strings | contains("asked without a reason")' <<<"$out" >/dev/null 2>&1 \
  && ok "event mode: an ask hook with no reason is merged with a filled reason" \
  || bad "event mode reason-less ask: $out"

# No timeout binary: one stderr note, and the event still runs unbounded.
nb="$TMP/no-timeout-bin"
mkdir -p "$nb"
for t in bash jq cat mktemp rm dirname kill sed grep tr sort head wc env; do
  p=$(command -v "$t") && ln -sf "$p" "$nb/$t"
done
if PATH="$nb" command -v timeout >/dev/null 2>&1; then
  bad "event mode no-timeout: the fixture PATH still has a timeout binary"
else
  err=$(PATH="$nb" em_run 2>&1 >"$TMP/no-timeout.out")
  [ "$(grep -cF 'no timeout binary on PATH' <<<"$err")" -eq 1 ] \
    && jq -e '.hookSpecificOutput.permissionDecision == "ask"' "$TMP/no-timeout.out" >/dev/null 2>&1 \
    && ok "event mode: no timeout binary -> one stderr note, the event still runs" \
    || bad "event mode no-timeout: stderr [$err] stdout [$(cat "$TMP/no-timeout.out")]"
fi

# --- Syntax-ok stamp: run.sh skips bash -n while a stamp under the cache dir is newer
# than the hook. Each row gets its own tree and cache. Stubs exit 0, except the hook
# named SY, which each row rewrites.
SY=recursive-rm-guard
sy_tree() { # sy_tree DIR: run.sh, its registry, and an exit-0 stub for every hook
  local t=$1 f n
  mkdir -p "$t/hooks/lib" "$t/proj"
  cp "$hooks/run.sh" "$hooks/hooks.json" "$t/hooks/"
  cp "$hooks/lib/components.sh" "$t/hooks/lib/" 2>/dev/null
  cp "$hooks/components.tsv" "$t/hooks/" 2>/dev/null
  for f in "$hooks"/*.sh; do
    n=$(basename "$f" .sh)
    case "$n" in run | *.probe) continue ;; esac
    printf '#!/bin/bash\nexit 0\n' > "$t/hooks/$n.sh"
  done
}
sy_run() { # sy_run DIR CACHE [ARG...]: a single-hook run, payload {} on stdin
  local t=$1 c=$2
  shift 2
  env -u SYG_PROFILE -u SYG_ENABLE -u SYG_DISABLE -u CLAUDE_CODE_ENTRYPOINT \
    XDG_CACHE_HOME="$c" CLAUDE_PROJECT_DIR="$t/proj" bash "$t/hooks/run.sh" "$@" <<<'{}'
}
sy_nocache() { # sy_nocache DIR: no HOME and no XDG_CACHE_HOME, so no cache dir
  env -u HOME -u XDG_CACHE_HOME -u SYG_PROFILE -u SYG_ENABLE -u SYG_DISABLE -u CLAUDE_CODE_ENTRYPOINT \
    CLAUDE_PROJECT_DIR="$1/proj" bash "$1/hooks/run.sh" "$SY" <<<'{}'
}
sy_stamp() { echo "$2/seyag/syntax-ok$1/hooks/$SY.sh"; } # sy_stamp DIR CACHE
sy_pending() { # sy_pending DIR CACHE: 0 when a `<stamp>.<pid>` write is left behind
  local f
  for f in "$(dirname "$(sy_stamp "$1" "$2")")"/*.[0-9]*; do [ -e "$f" ] && return 0; done
  return 1
}

# a. a broken hook is skipped with the message and gets no stamp
t="$TMP/sy-a"; c="$TMP/cache-a"; sy_tree "$t"; printf 'if then\n' > "$t/hooks/$SY.sh"
err=$(sy_run "$t" "$c" "$SY" 2>&1 >/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$err" = "run.sh: seyag hook '$SY' has a syntax error; skipped" ] \
  && [ ! -e "$(sy_stamp "$t" "$c")" ] && ! sy_pending "$t" "$c" \
  && ok "syntax-ok stamp: a broken hook is skipped with the message and gets no stamp" \
  || bad "syntax-ok stamp: broken hook rc=$rc err=[$err]"

# b. a valid hook runs, its stamp lands at the mirrored path, and no pending write is left
t="$TMP/sy-b"; c="$TMP/cache-b"; sy_tree "$t"; printf 'echo ran >&2\nexit 0\n' > "$t/hooks/$SY.sh"
err=$(sy_run "$t" "$c" "$SY" 2>&1 >/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$err" = ran ] && [ -f "$(sy_stamp "$t" "$c")" ] && ! sy_pending "$t" "$c" \
  && ok "syntax-ok stamp: a valid hook runs, its stamp is written, no pending write is left" \
  || bad "syntax-ok stamp: valid hook rc=$rc err=[$err]"

# c. the stamp is honoured: a broken hook whose mtime is older than its stamp skips
# bash -n, so bash itself runs it and fails. This pins the documented limit: an mtime
# set backwards past the stamp (cp -p, tar, rsync -t, touch -d) skips the check.
t="$TMP/sy-c"; c="$TMP/cache-c"; sy_tree "$t"; printf 'echo ran >&2\nexit 0\n' > "$t/hooks/$SY.sh"
sy_run "$t" "$c" "$SY" >/dev/null 2>&1
printf 'if then\n' > "$t/hooks/$SY.sh"; touch -d '-1 hour' "$t/hooks/$SY.sh"
err=$(sy_run "$t" "$c" "$SY" 2>&1 >/dev/null); rc=$?
[ "$rc" -ne 0 ] && ! grep -qF 'has a syntax error; skipped' <<<"$err" \
  && ok "syntax-ok stamp: a stamp newer than the hook skips bash -n (mtime set backwards)" \
  || bad "syntax-ok stamp: stamp not honoured rc=$rc err=[$err]"

# d. a hook edited after its stamp (mtime newer) is checked again and skipped
t="$TMP/sy-d"; c="$TMP/cache-d"; sy_tree "$t"; printf 'echo ran >&2\nexit 0\n' > "$t/hooks/$SY.sh"
sy_run "$t" "$c" "$SY" >/dev/null 2>&1
printf 'if then\n' > "$t/hooks/$SY.sh"; touch -d '+1 minute' "$t/hooks/$SY.sh"
err=$(sy_run "$t" "$c" "$SY" 2>&1 >/dev/null); rc=$?
[ "$rc" -eq 0 ] && grep -qF "run.sh: seyag hook '$SY' has a syntax error; skipped" <<<"$err" \
  && ok "syntax-ok stamp: a hook newer than its stamp is re-checked and skipped" \
  || bad "syntax-ok stamp: newer broken hook rc=$rc err=[$err]"

# e. no cache dir: nothing to stamp, so bash -n runs on every call (broken skipped, valid runs)
t="$TMP/sy-e"; sy_tree "$t"; printf 'if then\n' > "$t/hooks/$SY.sh"
err=$(sy_nocache "$t" 2>&1 >/dev/null); rc=$?
printf 'echo ran >&2\nexit 0\n' > "$t/hooks/$SY.sh"
err2=$(sy_nocache "$t" 2>&1 >/dev/null); rc2=$?
[ "$rc" -eq 0 ] && grep -qF 'has a syntax error; skipped' <<<"$err" && [ "$rc2" -eq 0 ] && grep -qxF ran <<<"$err2" \
  && ok "syntax-ok stamp: no cache dir -> bash -n runs each call (broken skipped, valid runs)" \
  || bad "syntax-ok stamp: no cache dir rc=$rc err=[$err] rc2=$rc2 err2=[$err2]"

# f. a relative invocation (cd into hooks/) still runs a valid hook
t="$TMP/sy-f"; c="$TMP/cache-f"; sy_tree "$t"; printf 'echo ran >&2\nexit 0\n' > "$t/hooks/$SY.sh"
err=$(cd "$t/hooks" && env -u SYG_PROFILE -u SYG_ENABLE -u SYG_DISABLE -u CLAUDE_CODE_ENTRYPOINT \
  XDG_CACHE_HOME="$c" CLAUDE_PROJECT_DIR="$t/proj" bash run.sh "$SY" <<<'{}' 2>&1 >/dev/null); rc=$?
# A relative invocation keys the stamp by `$PWD/./hooks/NAME.sh`. Without the
# `[[ $DIR == /* ]]` line it would key by the relative `./NAME.sh`, so this row goes red.
[ "$rc" -eq 0 ] && grep -qxF ran <<<"$err" \
  && [ -f "$c/seyag/syntax-ok$t/hooks/./$SY.sh" ] \
  && ok "relative invocation: a valid hook runs" \
  || bad "relative invocation: rc=$rc err=[$err]"

# g. event mode from a relative invocation still runs its hooks ($SY is a PreToolUse hook)
t="$TMP/sy-g"; c="$TMP/cache-g"; sy_tree "$t"; printf 'echo ran >&2\nexit 0\n' > "$t/hooks/$SY.sh"
err=$(cd "$t/hooks" && env -u SYG_PROFILE -u SYG_ENABLE -u SYG_DISABLE -u CLAUDE_CODE_ENTRYPOINT \
  XDG_CACHE_HOME="$c" CLAUDE_PROJECT_DIR="$t/proj" bash run.sh --event PreToolUse <<<'{}' 2>&1 >/dev/null); rc=$?
[ "$rc" -eq 0 ] && grep -qxF ran <<<"$err" \
  && ok "event mode from a relative invocation runs its hooks" \
  || bad "event mode relative: rc=$rc err=[$err]"

# h. a cache dir that is a regular file: no stamp can be written, so the syntax check
# runs on every call and the messages stay exact.
t="$TMP/sy-h"; c="$TMP/cache-file-h"; sy_tree "$t"; : > "$c"; printf 'if then\n' > "$t/hooks/$SY.sh"
err=$(sy_run "$t" "$c" "$SY" 2>&1 >/dev/null); rc=$?
printf 'echo ran >&2\nexit 0\n' > "$t/hooks/$SY.sh"
err2=$(sy_run "$t" "$c" "$SY" 2>&1 >/dev/null); rc2=$?
[ "$rc" -eq 0 ] && [ "$err" = "run.sh: seyag hook '$SY' has a syntax error; skipped" ] \
  && [ "$rc2" -eq 0 ] && [ "$err2" = ran ] \
  && ok "syntax-ok stamp: a cache dir that is a file -> broken skipped, valid runs, exact messages" \
  || bad "syntax-ok stamp: file cache dir rc=$rc err=[$err] rc2=$rc2 err2=[$err2]"

# i. a hook path with a `..` component takes the plain bash -n branch: no stamp dir.
t="$TMP/sy-i"; c="$TMP/cache-i"; sy_tree "$t"; printf 'echo ran >&2\nexit 0\n' > "$t/hooks/$SY.sh"
err=$(env -u SYG_PROFILE -u SYG_ENABLE -u SYG_DISABLE -u CLAUDE_CODE_ENTRYPOINT \
  XDG_CACHE_HOME="$c" CLAUDE_PROJECT_DIR="$t/proj" bash "$t/hooks/../hooks/run.sh" "$SY" <<<'{}' 2>&1 >/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$err" = ran ] && [ ! -e "$c/seyag/syntax-ok" ] \
  && ok "syntax-ok stamp: a .. hook path runs and writes no stamp dir" \
  || bad "syntax-ok stamp: .. path rc=$rc err=[$err]"

[ "$fail" -eq 0 ]
