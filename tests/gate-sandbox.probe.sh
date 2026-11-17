#!/usr/bin/env bash
# Probe for bin/gate-sandbox offline dependency binds:
# C1 auto-binds a symlinked $wt/node_modules read-only at $wt/node_modules;
# C2 ro-binds colon-separated SRC or SRC->DST entries from SYG_GATE_SANDBOX_RO_BINDS outside $wt.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
B="$REPO/plugins/seyag/bin"
pass=0; fail=0
ok() { pass=$((pass+1)); echo "ok:   $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

R=$T/repo; git init -q "$R"; git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m i
mkdir -p "$T/ro-a"

# Refusal cases first: gate-sandbox exits 125 before it builds a sandbox, so they run on any host.
# 3. C2: SRC->DST with DST inside $wt (or SRC inside $wt) refused, exit 125, message names the rule
out=$(SYG_GATE_SANDBOX_RO_BINDS="$T/ro-a->$R/sub" "$B/gate-sandbox" "$R" -- true 2>&1); rc=$?
mkdir -p "$R/in-wt"
out_src=$(SYG_GATE_SANDBOX_RO_BINDS="$R/in-wt->$T/out-dst" "$B/gate-sandbox" "$R" -- true 2>&1); rc_src=$?
[ $rc = 125 ] && [[ $out == *SYG_GATE_SANDBOX_RO_BINDS* ]] && [[ $out == *worktree* ]] \
  && [ $rc_src = 125 ] && [[ $out_src == *SYG_GATE_SANDBOX_RO_BINDS* ]] && [[ $out_src == *worktree* ]] \
  && ok "SYG_GATE_SANDBOX_RO_BINDS inside worktree refused with exit 125 and rule message" \
  || bad "inside-wt refusal: dst(rc=$rc out=[$out]) src(rc=$rc_src out=[$out_src])"

# 4. C2: non-existent SRC refused with exit 125 and a clear message
out=$(SYG_GATE_SANDBOX_RO_BINDS="$T/does-not-exist" "$B/gate-sandbox" "$R" -- true 2>&1); rc=$?
[ $rc = 125 ] && [[ $out == *SYG_GATE_SANDBOX_RO_BINDS* ]] && [[ $out == *does-not-exist* ]] \
  && ok "non-existent SRC in SYG_GATE_SANDBOX_RO_BINDS refused with exit 125" \
  || bad "non-existent SRC: rc=$rc out=[$out]"

# 4b. SYG_GATE_SANDBOX_ENV entries are variable names: a glob or anything else refuses, exit 125
out=$(SYG_GATE_SANDBOX_ENV='FOO_Y *' "$B/gate-sandbox" "$R" -- true 2>&1); rc=$?
[ $rc = 125 ] && [[ $out == *SYG_GATE_SANDBOX_ENV* ]] && [[ $out == *'*'* ]] \
  && ok "SYG_GATE_SANDBOX_ENV entry '*' refused with exit 125 naming the knob" \
  || bad "ENV name shape: rc=$rc out=[$out]"

# 4c. A SYG_GATE_SANDBOX_TOOLCHAIN entry resolving inside the worktree refused (the wt stays the only
# writable tree), exit 125, message names the rule
out=$(SYG_GATE_SANDBOX_TOOLCHAIN="$R/in-wt" "$B/gate-sandbox" "$R" -- true 2>&1); rc=$?
[ $rc = 125 ] && [[ $out == *SYG_GATE_SANDBOX_TOOLCHAIN* ]] && [[ $out == *"inside the worktree"* ]] \
  && ok "SYG_GATE_SANDBOX_TOOLCHAIN inside the worktree refused with exit 125 and rule message" \
  || bad "toolchain inside wt: rc=$rc out=[$out]"

# The rest need a real sandbox.
# shellcheck source=tests/sandbox-capable.sh
. "$REPO/tests/sandbox-capable.sh"
if ! syg_can_bwrap; then
  echo "gate-sandbox probe: $pass passed, $fail failed (sandbox cases not run)"
  [ "$fail" = 0 ] || exit 1
  syg_sandbox_skip "bwrap cannot build a namespace here"
fi

# 1. C1: fresh temp git repo, node_modules symlink to a fixture dep dir outside the worktree
mkdir -p "$T/deps/node_modules/fixdep"
printf '{"name":"fixdep","main":"index.js"}\n' >"$T/deps/node_modules/fixdep/package.json"
printf 'module.exports = 42;\n' >"$T/deps/node_modules/fixdep/index.js"
ln -s "$T/deps/node_modules" "$R/node_modules"

out=$("$B/gate-sandbox" "$R" -- node -e "console.log(require.resolve('fixdep'))" 2>&1); rc=$?
wout=$("$B/gate-sandbox" "$R" -- sh -c 'touch "$1/node_modules/fixdep/write-probe"' _ "$R" 2>&1); wrc=$?
[ $rc = 0 ] && [[ $out == *"fixdep/index.js"* ]] && [ $wrc != 0 ] && [ ! -e "$T/deps/node_modules/fixdep/write-probe" ] \
  && ok "symlinked node_modules resolves offline inside sandbox and is read-only" \
  || bad "symlinked node_modules: rc=$rc out=[$out] wrc=$wrc wout=[$wout]"

# Missing symlink target is skipped silently
ln -snf "$T/no-such-node-modules" "$R/node_modules"
out=$("$B/gate-sandbox" "$R" -- echo ok-dangling 2>&1); rc=$?
[ $rc = 0 ] && [ "$out" = ok-dangling ] \
  && ok "dangling node_modules symlink skipped silently" \
  || bad "dangling node_modules symlink: rc=$rc out=[$out]"
rm -f "$R/node_modules"

# 1b. C1b: vite's config-bundle scratch (<resolved node_modules>/.vite-temp) is writable inside,
# backed by a private host dir that dies with the run — never the main tree's node_modules.
# Red-first: with only the ro bind this write EROFSes (that is the vitest startup failure).
ln -s "$T/deps/node_modules" "$R/node_modules"
out=$("$B/gate-sandbox" "$R" -- sh -c 'mkdir -p "$1/node_modules/.vite-temp" && echo bundle >"$1/node_modules/.vite-temp/c.js" && cat "$1/node_modules/.vite-temp/c.js"' _ "$R" 2>&1); rc=$?
[ $rc = 0 ] && [[ $out == bundle ]] && [ ! -e "$T/deps/node_modules/.vite-temp/c.js" ] \
  && ok "node_modules/.vite-temp writable via private overlay, main tree untouched" \
  || bad ".vite-temp overlay: rc=$rc out=[$out]"
rm -f "$R/node_modules"

# 2. C2: SYG_GATE_SANDBOX_RO_BINDS dir visible inside (marker readable) and write into it fails (EROFS/EPERM)
mkdir -p "$T/ro-a" "$T/ro-b"
echo marker-a >"$T/ro-a/marker"
echo marker-b >"$T/ro-b/marker"
out=$(SYG_GATE_SANDBOX_RO_BINDS="$T/ro-a:$T/ro-b->$T/mounted-b" "$B/gate-sandbox" "$R" -- \
  sh -c 'cat "$1/marker" && cat "$2/marker" && printf "%s\n" "$SYG_GATE_SANDBOX_RO_BINDS"' _ "$T/ro-a" "$T/mounted-b" 2>&1); rc=$?
wout=$(SYG_GATE_SANDBOX_RO_BINDS="$T/ro-a:$T/ro-b->$T/mounted-b" "$B/gate-sandbox" "$R" -- \
  sh -c 'touch "$1/write-probe"' _ "$T/ro-a" 2>&1); wrc=$?
[ $rc = 0 ] && [[ $out == $'marker-a\nmarker-b\n'"$T/ro-a:$T/ro-b->$T/mounted-b" ]] \
  && [ $wrc != 0 ] && [ ! -e "$T/ro-a/write-probe" ] \
  && ok "SYG_GATE_SANDBOX_RO_BINDS mounts SRC and SRC->DST read-only and passes env var" \
  || bad "SYG_GATE_SANDBOX_RO_BINDS mount/ro: rc=$rc out=[$out] wrc=$wrc wout=[$wout]"

# 5. Var unset -> behavior unchanged
out=$(unset SYG_GATE_SANDBOX_RO_BINDS; "$B/gate-sandbox" "$R" -- sh -c 'echo ok >"$1/wt-write" && cat "$1/wt-write" && printf "%s" "${SYG_GATE_SANDBOX_RO_BINDS-unset}"' _ "$R" 2>&1); rc=$?
[ $rc = 0 ] && [ "$out" = $'ok\nunset' ] && [ -f "$R/wt-write" ] \
  && ok "SYG_GATE_SANDBOX_RO_BINDS unset leaves behavior unchanged" \
  || bad "unset behavior: rc=$rc out=[$out]"

# 6. SYG_GATE_SANDBOX_TOOLCHAIN: empty binds none; a list binds read-only
if [ -e "$HOME/.local/share/mise" ]; then
  out=$(SYG_GATE_SANDBOX_TOOLCHAIN='' "$B/gate-sandbox" "$R" -- sh -c '[ -e "$HOME/.local/share/mise" ] && echo visible; echo done' 2>&1); rc=$?
  [ $rc = 0 ] && [ "$out" = "done" ] \
    && ok "SYG_GATE_SANDBOX_TOOLCHAIN= (empty) leaves the mise dir out of the sandbox" \
    || bad "empty toolchain: rc=$rc out=[$out]"
else
  echo "note: $HOME/.local/share/mise isn't on this host, so the empty-TOOLCHAIN row is skipped"
fi
mkdir -p "$T/tc"; echo marker-tc >"$T/tc/marker"
out=$(SYG_GATE_SANDBOX_TOOLCHAIN=$T/tc "$B/gate-sandbox" "$R" -- sh -c 'cat "$1/marker"; touch "$1/w" 2>/dev/null && echo writable; exit 0' _ "$T/tc" 2>&1); rc=$?
[ $rc = 0 ] && [ "$out" = marker-tc ] && [ ! -e "$T/tc/w" ] \
  && ok "SYG_GATE_SANDBOX_TOOLCHAIN=DIR: the marker reads inside and the write fails" \
  || bad "toolchain list: rc=$rc out=[$out]"

# 6b. A toolchain entry that is a symlink binds its target at the entry's own path
ln -s "$T/tc" "$T/tc-link"
out=$(SYG_GATE_SANDBOX_TOOLCHAIN=$T/tc-link "$B/gate-sandbox" "$R" -- cat "$T/tc-link/marker" 2>&1); rc=$?
[ $rc = 0 ] && [ "$out" = marker-tc ] \
  && ok "SYG_GATE_SANDBOX_TOOLCHAIN symlink entry: its target reads at the configured path" \
  || bad "toolchain symlink: rc=$rc out=[$out]"

# 7. SYG_GATE_SANDBOX_ENV: the named variable passes, an unlisted one doesn't
out=$(FOO_Y=listed BAR_Y=unlisted SYG_GATE_SANDBOX_ENV="FOO_Y" "$B/gate-sandbox" "$R" -- sh -c 'echo "foo=${FOO_Y-unset} bar=${BAR_Y-unset}"' 2>&1); rc=$?
[ $rc = 0 ] && [ "$out" = "foo=listed bar=unset" ] \
  && ok "SYG_GATE_SANDBOX_ENV passes the named variable and not an unlisted one" \
  || bad "env knob: rc=$rc out=[$out]"
# 7b. The old unprefixed GATE_SANDBOX_ENV is not read
out=$(GATE_SANDBOX_ENV=FOO_Z FOO_Z=x "$B/gate-sandbox" "$R" -- sh -c 'echo "${FOO_Z-unset}"' 2>&1); rc=$?
[ $rc = 0 ] && [ "$out" = unset ] \
  && ok "the old GATE_SANDBOX_ENV name passes nothing" \
  || bad "old env name: rc=$rc out=[$out]"

# 8. vite's scratch dir is removed when gate-sandbox is signalled mid-run (a pin: bash runs the EXIT
# trap on an untrapped fatal signal, and bwrap dies with its parent), and fast
for sig in TERM HUP; do
  ln -s "$T/deps/node_modules" "$R/node_modules"
  mkdir -p "$T/vt-$sig"
  TMPDIR=$T/vt-$sig "$B/gate-sandbox" "$R" -- sh -c ': >"$1/up-'$sig'"; sleep 30' _ "$R" >/dev/null 2>&1 &
  gs=$!
  up=0
  for _ in $(seq 50); do [ -e "$R/up-$sig" ] && { up=1; break; }; sleep 0.1; done
  made=$(find "$T/vt-$sig" -maxdepth 1 -name 'gate-sandbox-vitetemp.*' | wc -l)
  t0=$(date +%s%N)  # the time bound below only says it doesn't hang until sleep 30
  kill -"$sig" "$gs"; wait "$gs" 2>/dev/null
  ms=$(( ($(date +%s%N) - t0) / 1000000 ))
  left=$(find "$T/vt-$sig" -maxdepth 1 -name 'gate-sandbox-vitetemp.*' | wc -l)
  [ "$up" = 1 ] && [ "$made" = 1 ] && [ "$left" = 0 ] && [ "$ms" -lt 20000 ] \
    && ok "$sig mid-run: the vite scratch dir existed ($made) and is gone, in ${ms} ms" \
    || bad "$sig vite cleanup: up=$up made=$made left=$left ms=$ms"
  rm -f "$R"/up-* "$R/node_modules"
done

echo "gate-sandbox probe: $pass passed, $fail failed"
[ "$fail" = 0 ]
