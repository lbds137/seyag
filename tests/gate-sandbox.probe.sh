#!/usr/bin/env bash
# Probe for bin/gate-sandbox offline dependency binds and worker-profile gate locks:
# C1 auto-binds a symlinked $wt/node_modules read-only at $wt/node_modules;
# C2 ro-binds colon-separated SRC or SRC->DST entries from SYG_GATE_SANDBOX_RO_BINDS outside $wt;
# worker profile binds both the heavy gate lock and the light gate lock (gate-lock --light-path).
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
B="$REPO/plugins/seyag/bin"
pass=0; fail=0
ok() { pass=$((pass+1)); echo "ok:   $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }
T=$(realpath "$(mktemp -d)"); trap 'rm -rf "$T"' EXIT

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

# 4c-pin. A SYG_GATE_SANDBOX_TOOLCHAIN entry outside the worktree whose symlink resolves inside is
# refused with the exact "resolves inside the worktree" text
ln -s "$R/in-wt" "$T/ext-link"
out=$(SYG_GATE_SANDBOX_TOOLCHAIN="$T/ext-link" "$B/gate-sandbox" "$R" -- true 2>&1); rc=$?
rm -f "$T/ext-link"
[ $rc = 125 ] && [[ $out == *"SYG_GATE_SANDBOX_TOOLCHAIN: refused: resolves inside the worktree: $T/ext-link"* ]] \
  && ok "4c-pin: SYG_GATE_SANDBOX_TOOLCHAIN entry resolving inside the worktree refused with resolves-inside text" \
  || bad "4c-pin toolchain resolves inside wt: rc=$rc out=[$out]"

# G6. A SYG_GATE_SANDBOX_TOOLCHAIN symlink inside the worktree pointing outside is refused lexically
ln -s /usr/bin "$R/tc-in-wt"
out=$(SYG_GATE_SANDBOX_TOOLCHAIN="$R/tc-in-wt" "$B/gate-sandbox" "$R" -- true 2>&1); rc=$?
rm -f "$R/tc-in-wt"
[ $rc = 125 ] && [[ $out == *SYG_GATE_SANDBOX_TOOLCHAIN* ]] && [[ $out == *"inside the worktree"* ]] \
  && ok "G6: SYG_GATE_SANDBOX_TOOLCHAIN symlink inside the worktree refused with exit 125" \
  || bad "G6 toolchain symlink inside wt: rc=$rc out=[$out]"

# G6b. Component-walk refusal: an entry under $wt through an in-tree symlinked parent ($R/tcdir/bin
# with $R/tcdir -> $T/tc-out) is refused lexically, and an entry outside $wt whose symlinked parent
# resolves into $wt before a child symlink jumps back out ($T/ext-parent/back-out/bin) is refused via
# the symlinked-prefix check
mkdir -p "$T/tc-out/bin"
ln -s "$T/tc-out" "$R/tcdir"
out=$(SYG_GATE_SANDBOX_TOOLCHAIN="$R/tcdir/bin" "$B/gate-sandbox" "$R" -- true 2>&1); rc=$?
ln -s "$R/in-wt" "$T/ext-parent"
ln -s "$T/tc-out" "$R/in-wt/back-out"
out2=$(SYG_GATE_SANDBOX_TOOLCHAIN="$T/ext-parent/back-out/bin" "$B/gate-sandbox" "$R" -- true 2>&1); rc2=$?
rm -rf "$R/tcdir" "$T/ext-parent" "$R/in-wt/back-out" "$T/tc-out"
[ $rc = 125 ] && [[ $out == *"SYG_GATE_SANDBOX_TOOLCHAIN: refused: inside the worktree: $R/tcdir/bin"* ]] \
  && [ $rc2 = 125 ] && [[ $out2 == *"SYG_GATE_SANDBOX_TOOLCHAIN: refused: resolves inside the worktree: $T/ext-parent/back-out/bin"* ]] \
  && ok "G6b: SYG_GATE_SANDBOX_TOOLCHAIN component walk refuses in-tree and symlinked-prefix entries (exit 125)" \
  || bad "G6b prefix walk: in-tree(rc=$rc out=[$out]) sym-prefix(rc=$rc2 out=[$out2])"
out_dd=$(SYG_GATE_SANDBOX_TOOLCHAIN="$R/../shared" "$B/gate-sandbox" "$R" -- true 2>&1); rc_dd=$?
[ $rc_dd = 125 ] && [[ $out_dd == *"SYG_GATE_SANDBOX_TOOLCHAIN: refused: inside the worktree: $R/../shared"* ]] \
  && ok "G6b (..): SYG_GATE_SANDBOX_TOOLCHAIN entry \$wt/../shared refused with inside-the-worktree text (exit 125)" \
  || bad "G6b ..: rc=$rc_dd out=[$out_dd]"
out_dot=$(SYG_GATE_SANDBOX_TOOLCHAIN="$T/./repo/in-wt" "$B/gate-sandbox" "$R" -- true 2>&1); rc_dot=$?
[ $rc_dot = 125 ] && [[ $out_dot == *"SYG_GATE_SANDBOX_TOOLCHAIN: refused: resolves inside the worktree: $T/./repo/in-wt"* ]] \
  && ok "G6b (/./): SYG_GATE_SANDBOX_TOOLCHAIN entry with /./ resolving inside worktree refused with resolves-inside text (exit 125)" \
  || bad "G6b /./: rc=$rc_dot out=[$out_dot]"

# G6c. Entry spelled through a symlinked ancestor ($T/alias -> $T) reaching an in-tree planted
# symlink ($R/tools/bin -> $T/outside): non-symlink intermediate components ($T/alias/repo,
# $T/alias/repo/tools) must also be resolved so the walk refuses at $T/alias/repo
mkdir -p "$T/outside" "$R/tools"
ln -s "$T" "$T/alias"
ln -s "$T/outside" "$R/tools/bin"
out=$(SYG_GATE_SANDBOX_TOOLCHAIN="$T/alias/repo/tools/bin" "$B/gate-sandbox" "$R" -- true 2>&1); rc=$?
rm -rf "$T/alias" "$R/tools" "$T/outside"
[ $rc = 125 ] && [[ $out == *"SYG_GATE_SANDBOX_TOOLCHAIN: refused: resolves inside the worktree: $T/alias/repo/tools/bin"* ]] \
  && ok "G6c: SYG_GATE_SANDBOX_TOOLCHAIN entry through symlinked ancestor with in-tree plant refused (exit 125)" \
  || bad "G6c symlinked ancestor: rc=$rc out=[$out]"

# G6d. Hop-by-hop symlink splice walk: (1) an outside symlink chain passing through the worktree
# and hopping back out ($T/hop -> $R/tools/bin -> $T/outside) is refused at the in-tree hop, and
# (2) a stow-style symlinked ancestor into the tree whose in-tree landing hops back out
# ($T/stow-mise -> $R/mise -> $T/outside, entry $T/stow-mise/bin) is refused at the in-tree landing
mkdir -p "$T/outside/bin" "$R/tools"
ln -s "$T/outside" "$R/tools/bin"
ln -s "$R/tools/bin" "$T/hop"
out=$(SYG_GATE_SANDBOX_TOOLCHAIN="$T/hop" "$B/gate-sandbox" "$R" -- true 2>&1); rc=$?
ln -s "$T/outside" "$R/mise"
ln -s "$R/mise" "$T/stow-mise"
out2=$(SYG_GATE_SANDBOX_TOOLCHAIN="$T/stow-mise/bin" "$B/gate-sandbox" "$R" -- true 2>&1); rc2=$?
rm -rf "$T/hop" "$T/stow-mise" "$R/mise" "$R/tools" "$T/outside"
[ $rc = 125 ] && [[ $out == *"SYG_GATE_SANDBOX_TOOLCHAIN: refused: resolves inside the worktree: $T/hop"* ]] \
  && [ $rc2 = 125 ] && [[ $out2 == *"SYG_GATE_SANDBOX_TOOLCHAIN: refused: resolves inside the worktree: $T/stow-mise/bin"* ]] \
  && ok "G6d: SYG_GATE_SANDBOX_TOOLCHAIN hop-by-hop walk refuses chain-through-tree and stow-shape entries (exit 125)" \
  || bad "G6d hop-by-hop walk: chain(rc=$rc out=[$out]) stow(rc=$rc2 out=[$out2])"

# G6d-relative. Stow shape with relative symlink targets ($T/stow-mise -> repo/mise and
# $R/mise -> ../outside): exercises the relative-splice branch (pop acc to parent, splice target)
mkdir -p "$T/outside"
ln -s ../outside "$R/mise"
ln -s repo/mise "$T/stow-mise"
out=$(SYG_GATE_SANDBOX_TOOLCHAIN="$T/stow-mise" "$B/gate-sandbox" "$R" -- true 2>&1); rc=$?
rm -rf "$T/stow-mise" "$R/mise" "$T/outside"
[ $rc = 125 ] && [[ $out == *"SYG_GATE_SANDBOX_TOOLCHAIN: refused: resolves inside the worktree: $T/stow-mise"* ]] \
  && ok "G6d-relative: SYG_GATE_SANDBOX_TOOLCHAIN relative-target stow chain through worktree refused (exit 125)" \
  || bad "G6d-relative relative stow: rc=$rc out=[$out]"

# G6e. Child-symlink loop uses the same hop-by-hop walk: an outside toolchain entry with a child
# symlink whose chain passes through the worktree ($T/tc-child/cfg -> $R/in-wt/hop-out -> $T/outside)
# refuses the whole entry with exit 125
mkdir -p "$T/tc-child" "$T/outside"
ln -s "$T/outside" "$R/in-wt/hop-out"
ln -s "$R/in-wt/hop-out" "$T/tc-child/cfg"
out=$(SYG_GATE_SANDBOX_TOOLCHAIN="$T/tc-child" "$B/gate-sandbox" "$R" -- true 2>&1); rc=$?
rm -rf "$T/tc-child" "$R/in-wt/hop-out" "$T/outside"
[ $rc = 125 ] && [[ $out == *"SYG_GATE_SANDBOX_TOOLCHAIN: refused: resolves inside the worktree: $T/tc-child"* ]] \
  && ok "G6e: SYG_GATE_SANDBOX_TOOLCHAIN child symlink chain through worktree refuses entry (exit 125)" \
  || bad "G6e child chain through wt: rc=$rc out=[$out]"

# G4. A pre-launch 125 after vite_tmp mktemp cleans up gate-sandbox-vitetemp.*
mkdir -p "$T/g4-deps/node_modules" "$T/g4-tmp"
ln -s "$T/g4-deps/node_modules" "$R/node_modules"
out=$(TMPDIR="$T/g4-tmp" SYG_GATE_SANDBOX_RO_BINDS="$T/does-not-exist" "$B/gate-sandbox" "$R" -- true 2>&1); rc=$?
rm -f "$R/node_modules"
g4_left=$(find "$T/g4-tmp" -maxdepth 1 -name 'gate-sandbox-vitetemp.*' | wc -l)
[ $rc = 125 ] && [ "$g4_left" = 0 ] && [ -d "$T/g4-deps/node_modules/.vite-temp" ] \
  && ok "G4: pre-launch 125 after vite_tmp mktemp removes gate-sandbox-vitetemp.*" \
  || bad "G4 vitetemp leak: rc=$rc left=$g4_left out=[$out]"

# G1-G3c. SYG_GATE_SANDBOX_REPO anchors worker-tree-check to the main checkout before host git runs
M=$T/g1-main; S=$T/g1-sib; L=$T/g1-linked; N=$T/g1-other
git init -q "$M"; git -C "$M" -c user.email=t@t -c user.name=t commit -q --allow-empty -m i
git -C "$M" worktree add -q "$S" -b sib
git -C "$M" worktree add -q "$L" -b linked
git init -q "$N"; git -C "$N" -c user.email=t@t -c user.name=t commit -q --allow-empty -m i
rm -f "$S/.git"; git init -q "$S"
printf '#!/bin/sh\n: >"%s/g1-marker"\nexit 1\n' "$T" >"$T/g1-fsm"; chmod +x "$T/g1-fsm"
git -C "$S" config core.fsmonitor "$T/g1-fsm"
echo x >"$S/f"; git -C "$S" -c core.fsmonitor=false add f
"$B/worker-tree-check" "$S" >/dev/null 2>&1; g1_wtc=$?
rm -f "$T/g1-marker"
git -C "$S" status --short >/dev/null 2>&1
if [ "$g1_wtc" != 0 ] || [ ! -e "$T/g1-marker" ]; then
  bad "G1 control failed: wtc=$g1_wtc marker=$([ -e "$T/g1-marker" ] && echo yes || echo no)"
  exit 1
fi
ok "G1 control: no-flag worker-tree-check passes swapped sibling and git status runs its fsmonitor"
rm -f "$T/g1-marker"
stubdir=$T/g1-gitstub; stublog=$T/g1-git.log; mkdir -p "$stubdir"; : >"$stublog"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\nexit 127\n' "$stublog" >"$stubdir/git"; chmod +x "$stubdir/git"
out=$(PATH="$stubdir:$PATH" SYG_GATE_SANDBOX_REPO="$M" "$B/gate-sandbox" "$S" -- true 2>&1); rc=$?
[ $rc = 125 ] && [[ $out == *"worker-tree-check refused"* ]] && [ ! -e "$T/g1-marker" ] && [ ! -s "$stublog" ] \
  && ok "G1: SYG_GATE_SANDBOX_REPO refuses swapped sibling before host git runs (exit 125)" \
  || bad "G1 swapped sibling: rc=$rc marker=$([ -e "$T/g1-marker" ] && echo yes || echo no) gitlog=[$(cat "$stublog")] out=[$out]"

out=$(SYG_GATE_SANDBOX_REPO="$T/no-such-repo" "$B/gate-sandbox" "$R" -- true 2>&1); rc=$?
[ $rc = 125 ] && [[ $out == *"SYG_GATE_SANDBOX_REPO is not a directory: $T/no-such-repo"* ]] \
  && ok "G2: SYG_GATE_SANDBOX_REPO naming a missing directory refused with exit 125" \
  || bad "G2 missing repo dir: rc=$rc out=[$out]"

out=$(SYG_GATE_SANDBOX_REPO="$M" "$B/gate-sandbox" "$M" -- true 2>&1); rc=$?
[[ $out != *"worker-tree-check refused"* ]] && [[ $out != *"SYG_GATE_SANDBOX_REPO is not a directory"* ]] \
  && ok "G3: main checkout itself passes SYG_GATE_SANDBOX_REPO tree check" \
  || bad "G3 main checkout: rc=$rc out=[$out]"

out=$(SYG_GATE_SANDBOX_REPO="$M" "$B/gate-sandbox" "$L" -- true 2>&1); rc=$?
[[ $out != *"worker-tree-check refused"* ]] && [[ $out != *"SYG_GATE_SANDBOX_REPO is not a directory"* ]] \
  && ok "G3b: legitimate linked worktree passes SYG_GATE_SANDBOX_REPO=M tree check" \
  || bad "G3b legit linked worktree: rc=$rc out=[$out]"

out=$(SYG_GATE_SANDBOX_REPO="$N" "$B/gate-sandbox" "$L" -- true 2>&1); rc=$?
[ $rc = 125 ] && [[ $out == *"worker-tree-check refused"* ]] \
  && ok "G3c: linked worktree of M refused when SYG_GATE_SANDBOX_REPO names another repo N (exit 125)" \
  || bad "G3c wrong repo anchor: rc=$rc out=[$out]"

# G7. Worker profile binds both the heavy lock and the light lock (gate-lock --light-path -> /run/worker/gate.light.lock),
# and exits 125 when the light lock cannot be created.
mkdir -p "$T/g7-stub" "$T/g7-scratch"
: >"$T/g7-tun"
cat >"$T/g7-stub/bwrap" <<'EOF'
#!/bin/sh
if [ "${1:-}" = --help ]; then echo "usage: bwrap --size BYTES"; exit 0; fi
printf '%s\n' "$@"
exit 0
EOF
cat >"$T/g7-stub/pasta" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done
[ "${1:-}" = -- ] && shift
exec "$@"
EOF
cat >"$T/g7-stub/ip" <<'EOF'
#!/bin/sh
case "$*" in
  "-o -4 route show table local type local") echo "local 127.0.0.1 dev lo table local scope host" ;;
  "-o -6 route show table local type local"|"-o -4 route show table all"|"-o -6 route show table all") ;;
  "route replace unreachable "*) ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$T/g7-stub/bwrap" "$T/g7-stub/pasta" "$T/g7-stub/ip"
g7_lock="$T/g7-gate.lock"
g7_want_light=$(SYG_GATE_LOCK_FILE="$g7_lock" "$B/gate-lock" --light-path)
g7_out=$(PATH="$T/g7-stub:$PATH" SYG_GATE_SANDBOX_PROFILE=worker SYG_GATE_SANDBOX_SCRATCH="$T/g7-scratch" \
  SYG_GATE_SANDBOX_TUN="$T/g7-tun" SYG_GATE_LOCK_FILE="$g7_lock" "$B/gate-sandbox" "$R" -- true 2>&1)
g7_rc=$?
g7_bound_src=$(awk '$0 == "/run/worker/gate.light.lock" {print prev; exit} {prev=$0}' <<<"$g7_out")
mkdir -p "$T/g7-bad.light.lock"
g7_bad_out=$(PATH="$T/g7-stub:$PATH" SYG_GATE_SANDBOX_PROFILE=worker SYG_GATE_SANDBOX_SCRATCH="$T/g7-scratch" \
  SYG_GATE_SANDBOX_TUN="$T/g7-tun" SYG_GATE_LOCK_FILE="$T/g7-bad.lock" "$B/gate-sandbox" "$R" -- true 2>&1)
g7_bad_rc=$?
if [ "$g7_rc" = 0 ] && [ -n "$g7_want_light" ] && [ -f "$g7_want_light" ] \
  && [ "$g7_bound_src" = "$g7_want_light" ] && [ "$g7_bad_rc" = 125 ]; then
  ok "G7: worker profile creates and binds gate-lock --light-path to /run/worker/gate.light.lock (125 if unopenable)"
else
  bad "G7 worker light lock: rc=$g7_rc want=[$g7_want_light] bound=[$g7_bound_src] bad_rc=$g7_bad_rc bad_out=[$g7_bad_out]"
fi

# The rest need a real sandbox.
# shellcheck source=tests/sandbox-capable.sh
. "$REPO/tests/sandbox-capable.sh"
if ! syg_can_bwrap; then
  echo "gate-sandbox probe: $pass passed, $fail failed (sandbox cases not run)"
  [ "$fail" = 0 ] || exit 1
  syg_sandbox_skip "bwrap cannot build a namespace here"
fi

# G3d. Anchored default-profile run on the legitimate linked worktree passes and builds the sandbox
out=$(SYG_GATE_SANDBOX_REPO="$M" "$B/gate-sandbox" "$L" -- true 2>&1); rc=$?
[ $rc = 0 ] \
  && ok "G3d: SYG_GATE_SANDBOX_REPO=\$M on legitimate linked worktree builds sandbox (rc 0)" \
  || bad "G3d anchored default-profile: rc=$rc out=[$out]"

# G6d-relative positive control: an outside toolchain entry whose relative symlink chain stays
# outside ($T/rel-entry -> rel-link -> real-dir) resolves without refusing, binds the target, and
# is reachable at the configured entry path inside the sandbox
mkdir -p "$T/real-dir"
echo marker-rel >"$T/real-dir/marker"
ln -s real-dir "$T/rel-link"
ln -s rel-link "$T/rel-entry"
out=$(SYG_GATE_SANDBOX_TOOLCHAIN="$T/rel-entry" "$B/gate-sandbox" "$R" -- cat "$T/rel-entry/marker" 2>&1); rc=$?
rm -rf "$T/rel-entry" "$T/rel-link" "$T/real-dir"
[ $rc = 0 ] && [ "$out" = marker-rel ] \
  && ok "G6d-relative positive control: relative symlink chain outside worktree binds target and reads marker (rc 0)" \
  || bad "G6d-relative positive control: rc=$rc out=[$out]"

# G6d-relative-misresolve: relative targets whose correct splice (against the link's parent) stays
# outside the worktree, but whose mis-resolution against / ($T/rel-root -> ${R#/}/in-wt) or against
# the link itself ($T/rel-self/sub with $T/rel-self -> rel-dir and $T/rel-dir/rel-dir -> $R/in-wt)
# lands inside the worktree and falsely refuses with 125
rel_r=${R#/}; rel_top=${rel_r%%/*}
mkdir -p "$T/$rel_r/in-wt" "$T/rel-dir/sub"
ln -s "$rel_r/in-wt" "$T/rel-root"
ln -s "$R/in-wt" "$T/rel-dir/rel-dir"
ln -s rel-dir "$T/rel-self"
out=$(SYG_GATE_SANDBOX_TOOLCHAIN="$T/rel-root:$T/rel-self/sub" "$B/gate-sandbox" "$R" -- true 2>&1); rc=$?
rm -rf "$T/rel-root" "$T/rel-self" "$T/rel-dir" "${rel_top:+"$T/$rel_top"}"
[ $rc = 0 ] \
  && ok "G6d-relative-misresolve: relative chain outside worktree not falsely refused as in-tree (rc 0)" \
  || bad "G6d-relative-misresolve: rc=$rc out=[$out]"

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
