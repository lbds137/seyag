#!/usr/bin/env bash
# Probe for bin/worker-sandbox and gate-sandbox's worker profile: real bwrap and pasta and a fake
# claude for the walls. The refusal cases run anywhere; the rest skip where pasta+bwrap can't build a
# sandbox (SYG_PROBE_REQUIRE_SANDBOX=1 makes that a failure).
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
B="$REPO/plugins/seyag/bin"
pass=0; fail=0
ok() { pass=$((pass+1)); echo "ok:   $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

T=$(realpath "$(mktemp -d)"); trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
export SYG_GATE_LOCK_FILE=$T/gate.lock
# worker-sandbox runs worker-tree-check first, which distrusts /tmp by default; the fixtures live there
export SYG_WORKER_TREE_CHECK_UNTRUSTED=/var/tmp:/dev/shm
M=$T/main; W=$T/tree
git init -q "$M"
git -C "$M" -c user.email=t@t -c user.name=t commit -q --allow-empty -m i
echo main-only-secret >"$M/.env"
git -C "$M" worktree add -q "$W"
export SYG_WORKER_SANDBOX_SCRATCH=$T/scratch; mkdir -p "$SYG_WORKER_SANDBOX_SCRATCH"
echo '{"env":{}}' >"$T/overlay.json"

fake() { # $1 = script body; becomes the program bound as claude
  printf '#!/bin/bash\n%s\n' "$1" >"$T/fake-claude"
  chmod +x "$T/fake-claude"
}
inside() { # the fake claude from the tree, with its output and exit code
  (cd "$W" && SYG_WORKER_SANDBOX_CLAUDE=$T/fake-claude "$B/worker-sandbox" --settings "$T/overlay.json" "$@" 2>"$T/err")
}

# Refusal cases first: both exit 125 before any sandbox is built, so they run on any host.
# 4b. A bad tree mode refuses (the fake claude must exist, or the 125 would be "claude not found")
fake 'exit 0'
out=$(cd "$W" && SYG_WORKER_SANDBOX_TREE=sideways SYG_WORKER_SANDBOX_CLAUDE=$T/fake-claude "$B/worker-sandbox" --settings "$T/overlay.json" 2>&1); rc=$?
[ "$rc" = 125 ] && [[ $out == *"must be rw or ro"* ]] && ok "a bad tree mode refuses (125) naming the rule, nothing runs" \
  || bad "bad tree mode: rc=$rc out=[$out]"

# 4c. A tree whose .git points at a gitdir that isn't registered for it: worker-tree-check refuses
# before any host git runs, and the fake claude (which writes a marker) never starts. A copy, not $W.
BT=$T/badtree; mkdir -p "$BT"; echo 'gitdir: /nonexistent/x' >"$BT/.git"
fake ': >"'"$T"'/bad-ran"; exit 0'
out=$(cd "$BT" && SYG_WORKER_SANDBOX_CLAUDE=$T/fake-claude "$B/worker-sandbox" --settings "$T/overlay.json" 2>&1); rc=$?
[ "$rc" = 125 ] && [[ $out == *"worker-tree-check refused"* ]] && [ ! -e "$T/bad-ran" ] \
  && ok "a tree with a forged gitfile refuses (125) via worker-tree-check; nothing ran" \
  || bad "forged gitfile: rc=$rc out=[$out] ran=$([ -e "$T/bad-ran" ] && echo yes || echo no)"

# 8. No pasta: refuses rather than run with another network (or none of the walls)
mkdir -p "$T/nopasta"
for t in bash env git realpath dirname basename id mkdir bwrap; do ln -s "$(command -v "$t")" "$T/nopasta/$t"; done
# gate-sandbox directly: worker-sandbox sets its own PATH, with /usr/bin on it
out=$(PATH=$T/nopasta SYG_GATE_SANDBOX_PROFILE=worker SYG_GATE_SANDBOX_SCRATCH=$SYG_WORKER_SANDBOX_SCRATCH "$B/gate-sandbox" "$W" -- /usr/bin/true 2>&1); rc=$?
[ "$rc" = 125 ] && [[ $out == *"pasta not found"* ]] && ok "no pasta: the worker profile refuses (125)" \
  || bad "no pasta: rc=$rc out=[$out]"

# 8b. No ip (iproute2): the wall is built with it, so the worker profile refuses rather than launch unwalled
mkdir -p "$T/noip"
for t in bash env git realpath dirname basename id mkdir bwrap pasta; do ln -s "$(command -v "$t")" "$T/noip/$t"; done
out=$(PATH=$T/noip SYG_GATE_SANDBOX_PROFILE=worker SYG_GATE_SANDBOX_SCRATCH=$SYG_WORKER_SANDBOX_SCRATCH "$B/gate-sandbox" "$W" -- /usr/bin/true 2>&1); rc=$?
[ "$rc" = 125 ] && [[ $out == *"ip (iproute2) not found"* ]] && ok "no ip: the worker profile refuses (125)" \
  || bad "no ip: rc=$rc out=[$out]"

# 8d. No bwrap: its own refusal, not the version one
mkdir -p "$T/nobwrap"
for t in bash env git realpath dirname basename id mkdir; do ln -s "$(command -v "$t")" "$T/nobwrap/$t"; done
printf '#!/bin/sh\nexit 0\n' >"$T/nobwrap/pasta"; cp "$T/nobwrap/pasta" "$T/nobwrap/ip"; chmod +x "$T/nobwrap/pasta" "$T/nobwrap/ip"
out=$(PATH=$T/nobwrap SYG_GATE_SANDBOX_PROFILE=worker SYG_GATE_SANDBOX_SCRATCH=$SYG_WORKER_SANDBOX_SCRATCH "$B/gate-sandbox" "$W" -- /usr/bin/true 2>&1); rc=$?
[ "$rc" = 125 ] && [[ $out == *"bwrap not found"* ]] && ok "no bwrap: the worker profile refuses (125) naming bwrap" \
  || bad "no bwrap: rc=$rc out=[$out]"

# Stubs for the host-side route queries: a fixture host, and the ways a query can't be trusted. A stub
# bwrap (help names --size) and pasta (exits 0) let the worker profile get as far as the wall on any host.
SB=$T/stubs; mkdir -p "$SB" "$T/fx" "$T/fx-no-lo"
printf '#!/bin/sh\necho "usage: bwrap [OPTION...] --size BYTES"\n' >"$SB/bwrap"
printf '#!/bin/sh\nexit 0\n' >"$SB/pasta"
chmod +x "$SB/bwrap" "$SB/pasta"
cat >"$T/fx/local4" <<'EOF'
local 127.0.0.0/8 dev lo table local proto kernel scope host src 127.0.0.1
local 127.0.0.1 dev lo table local proto kernel scope host src 127.0.0.1
local 192.168.50.45 dev wlan0 table local proto kernel scope host src 192.168.50.45
local 172.17.0.1 dev docker0 table local proto kernel scope host src 172.17.0.1
local 10.8.0.2 dev tun0 table local proto kernel scope host src 10.8.0.2
EOF
cat >"$T/fx/local6" <<'EOF'
local ::1 dev lo table local proto kernel metric 0 pref medium
local fd00::5 dev br0 table local proto kernel metric 0 pref medium
EOF
cat >"$T/fx/all4" <<'EOF'
default via 192.168.50.1 dev wlan0 proto dhcp src 192.168.50.45 metric 600
192.168.50.0/24 dev wlan0 proto kernel scope link src 192.168.50.45 metric 600
192.168.50.0/24 dev eth0 proto kernel scope link src 192.168.50.46 metric 100
172.17.0.0/16 dev docker0 proto kernel scope link src 172.17.0.1 linkdown
169.254.0.0/16 dev docker0 scope link metric 1000
10.8.0.1 dev tun0 proto kernel scope link src 10.8.0.2
100.64.0.0/10 dev tailscale0 table 52
10.20.0.0/16 dev wg0 scope link
default dev wg0 table 51820
224.0.0.0/4 dev eth0 scope link
unicast 10.99.0.0/16 dev br9 proto static
local 127.0.0.1 dev lo table local proto kernel scope host src 127.0.0.1
local 192.168.50.45 dev wlan0 table local proto kernel scope host src 192.168.50.45
broadcast 192.168.50.255 dev wlan0 table local proto kernel scope link src 192.168.50.45
EOF
cat >"$T/fx/all6" <<'EOF'
fd00::/64 dev br0 proto kernel metric 256 pref medium
fe80::/64 dev wlan0 proto kernel metric 256 pref medium
ff00::/8 dev eth0 proto kernel metric 256 pref medium
multicast ff00::/8 dev wlan0 table local proto kernel metric 256 pref medium
unreachable ::/96 dev lo proto kernel metric 1024 pref medium
local ::1 dev lo table local proto kernel metric 0 pref medium
local fd00::5 dev br0 table local proto kernel metric 0 pref medium
EOF
# Real `ip -o route show table all` shapes (iproute2 in a pasta namespace): a multipath route one of
# whose hops is a default dev (stays open), a route with an nhid (walled), and a prefixed local entry
printf '10.7.0.0/24 \\\tnexthop via 10.9.0.2 dev br7 weight 1 \\\tnexthop dev wlan0 weight 1 \n' >>"$T/fx/all4"
echo '10.6.0.0/24 nhid 5 via 10.9.0.3 dev br6' >>"$T/fx/all4"
echo 'local 10.4.0.0/24 dev lo table local scope host' >>"$T/fx/local4"
cp "$T/fx/all4" "$T/fx/all6" "$T/fx-no-lo/"
printf 'local 192.168.50.45 dev wlan0 table local proto kernel scope host src 192.168.50.45 \n' >"$T/fx-no-lo/local4"
printf 'local fd00::5 dev br0 table local proto kernel metric 0 pref medium\n' >"$T/fx-no-lo/local6"
mkdir -p "$T/ipstub" "$T/ipstub-no-lo"
for d in fx:ipstub fx-no-lo:ipstub-no-lo; do
  cat >"$T/${d#*:}/ip" <<EOF
#!/bin/bash
fx=$T/${d%:*}
[ -n "\${STUB_IP_FAIL:-}" ] && [[ "\$*" == *"\$STUB_IP_FAIL"* ]] && { echo "ip: boom" >&2; exit 1; }
case "\$*" in
  "-o -4 route show table local type local") cat "\$fx/local4" ;;
  "-o -6 route show table local type local") cat "\$fx/local6" ;;
  "-o -4 route show table all") cat "\$fx/all4" ;;
  "-o -6 route show table all") cat "\$fx/all6" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$T/${d#*:}/ip"
done

# 7d. --print-wall computes the set from a fixture host, no sandbox: the host's addresses (loopback
# excepted), and every route in any table through an interface with no default route. wlan0 and wg0
# carry default routes (wg0's in table 51820), so 192.168.50.0/24, which eth0 shares with wlan0, and
# wg0's 10.20.0.0/16 stay open, and so does the multipath 10.7.0.0/24 (one hop is on wlan0);
# link-local, multicast, defaults, loopback and type-keyword lines are skipped. 10.6.0.0/24 (an nhid
# route) is walled, and so is the prefixed local entry 10.4.0.0/24.
want='10.4.0.0/24
10.6.0.0/24
10.8.0.1/32
10.8.0.2/32
10.99.0.0/16
100.64.0.0/10
169.254.0.0/16
172.17.0.0/16
172.17.0.1/32
192.168.50.45/32
fd00::/64
fd00::5/128'
got=$(PATH=$T/ipstub:$PATH "$B/gate-sandbox" --print-wall 2>"$T/err"); rc=$?
[ "$rc" = 0 ] && [ "$(LC_ALL=C sort <<<"$got")" = "$want" ] \
  && ok "--print-wall: fixture host gives exactly the expected wall ($(grep -c . <<<"$want") prefixes)" \
  || bad "print-wall fixture: rc=$rc got=[$got] err=[$(cat "$T/err")]"
got=$(PATH=$T/ipstub:$PATH SYG_GATE_SANDBOX_WALL="198.51.100.0/24 203.0.113.9" "$B/gate-sandbox" --print-wall 2>"$T/err"); rc=$?
[ "$rc" = 0 ] && [ "$(LC_ALL=C sort <<<"$got")" = "$(LC_ALL=C sort <<<"$want
198.51.100.0/24
203.0.113.9")" ] \
  && ok "--print-wall: SYG_GATE_SANDBOX_WALL extras are in the set" \
  || bad "print-wall extras: rc=$rc got=[$got] err=[$(cat "$T/err")]"
# An extra entry must be an address or CIDR: a keyword such as `default` would wall everything.
# A shape-valid but kernel-invalid prefix length (10.0.0.0/33) passes here; the launch rejects it.
got=$(PATH=$T/ipstub:$PATH SYG_GATE_SANDBOX_WALL="default" "$B/gate-sandbox" --print-wall 2>"$T/err"); rc=$?
[ "$rc" = 125 ] && [ -z "$got" ] && grep -q 'SYG_GATE_SANDBOX_WALL: not an address or CIDR: default' "$T/err" \
  && ok "--print-wall refuses (125) a keyword in SYG_GATE_SANDBOX_WALL, printing nothing" \
  || bad "wall keyword: rc=$rc got=[$got] err=[$(cat "$T/err")]"
got=$(PATH=$T/ipstub:$PATH SYG_GATE_SANDBOX_WALL="10.0.0.0/33 fd12::/64 203.0.113.9" "$B/gate-sandbox" --print-wall 2>"$T/err"); rc=$?
[ "$rc" = 0 ] && grep -qFx 10.0.0.0/33 <<<"$got" && grep -qFx fd12::/64 <<<"$got" && grep -qFx 203.0.113.9 <<<"$got" \
  && ok "--print-wall accepts v4 and v6 CIDRs and a bare address (the prefix length's range is the kernel's)" \
  || bad "wall shape accepts: rc=$rc got=[$got] err=[$(cat "$T/err")]"
for badw in 'a.b.c.d' '10.0.0.0/8;x' '1.2.3' 'fd00::g'; do
  got=$(PATH=$T/ipstub:$PATH SYG_GATE_SANDBOX_WALL="$badw" "$B/gate-sandbox" --print-wall 2>"$T/err"); rc=$?
  [ "$rc" = 125 ] && [ -z "$got" ] && grep -qF "not an address or CIDR: $badw" "$T/err" \
    && ok "--print-wall refuses (125) the malformed wall entry [$badw]" \
    || bad "wall entry [$badw]: rc=$rc got=[$got] err=[$(cat "$T/err")]"
done

# 9. The route queries fail closed: an ip that errors on any query, or a local table without loopback
# (so the query or its parse saw no real data), refuses (125); a worker launch refuses with the same words.
for failq in "route show" "-6 route show table all" "-4 route show table local"; do
  got=$(PATH=$T/ipstub:$PATH STUB_IP_FAIL=$failq "$B/gate-sandbox" --print-wall 2>"$T/err"); rc=$?
  [ "$rc" = 125 ] && [ -z "$got" ] && grep -q "can't read the host's routes" "$T/err" \
    && ok "--print-wall refuses (125) when ip fails on [$failq]" \
    || bad "ip fails on [$failq]: rc=$rc got=[$got] err=[$(cat "$T/err")]"
done
out=$(PATH=$SB:$T/ipstub:$PATH STUB_IP_FAIL="route show" SYG_GATE_SANDBOX_PROFILE=worker SYG_GATE_SANDBOX_SCRATCH=$SYG_WORKER_SANDBOX_SCRATCH "$B/gate-sandbox" "$W" -- /usr/bin/true 2>&1); rc=$?
[ "$rc" = 125 ] && [[ $out == *"can't read the host's routes"* ]] && ok "a worker launch refuses (125) when the host's routes can't be read" \
  || bad "worker launch with failing ip: rc=$rc out=[$out]"
got=$(PATH=$T/ipstub-no-lo:$PATH "$B/gate-sandbox" --print-wall 2>"$T/err"); rc=$?
[ "$rc" = 125 ] && [ -z "$got" ] && grep -q "can't read the host's routes" "$T/err" \
  && ok "--print-wall refuses (125) when the local table lacks 127.0.0.1" \
  || bad "no loopback in local table: rc=$rc got=[$got] err=[$(cat "$T/err")]"
out=$(PATH=$SB:$T/ipstub-no-lo:$PATH SYG_GATE_SANDBOX_PROFILE=worker SYG_GATE_SANDBOX_SCRATCH=$SYG_WORKER_SANDBOX_SCRATCH "$B/gate-sandbox" "$W" -- /usr/bin/true 2>&1); rc=$?
[ "$rc" = 125 ] && [[ $out == *"can't read the host's routes"* ]] && ok "a worker launch refuses (125) when the local table lacks 127.0.0.1" \
  || bad "worker launch, no loopback: rc=$rc out=[$out]"

# 11. A bwrap too old for --size refuses naming the floor (stub: help without --size; ip and pasta stubs)
mkdir -p "$T/oldbwrap"
printf '#!/bin/sh\necho "usage: bwrap [OPTION...]"\n' >"$T/oldbwrap/bwrap"; chmod +x "$T/oldbwrap/bwrap"
cp "$SB/pasta" "$T/oldbwrap/pasta"; cp "$T/ipstub/ip" "$T/oldbwrap/ip"
for t in bash env git realpath dirname basename id mkdir grep; do ln -s "$(command -v "$t")" "$T/oldbwrap/$t"; done
out=$(PATH=$T/oldbwrap SYG_GATE_SANDBOX_PROFILE=worker SYG_GATE_SANDBOX_SCRATCH=$SYG_WORKER_SANDBOX_SCRATCH "$B/gate-sandbox" "$W" -- /usr/bin/true 2>&1); rc=$?
[ "$rc" = 125 ] && [[ $out == *"bubblewrap >= 0.10"* ]] && ok "a bwrap without --size refuses (125) naming >= 0.10" \
  || bad "old bwrap: rc=$rc out=[$out]"

# The rest build a real sandbox, with pasta for the network.
# shellcheck source=tests/sandbox-capable.sh
. "$REPO/tests/sandbox-capable.sh"
if ! syg_can_pasta; then
  echo "worker-sandbox probe: pass=$pass fail=$fail (sandbox cases not run)"
  [ "$fail" = 0 ] || exit 1
  syg_sandbox_skip "pasta+bwrap cannot build a worker sandbox here (nested sandbox?)"
fi

# 8c. A bad extra CIDR in the wall knob fails the launch rather than run with a smaller wall
fake 'echo ran; exit 0'
# (shape-valid, kernel-invalid: `ip route replace` fails inside the namespace; a malformed entry never gets that far)
out=$(cd "$W" && SYG_WORKER_SANDBOX_WALL=10.0.0.0/33 SYG_WORKER_SANDBOX_CLAUDE=$T/fake-claude "$B/worker-sandbox" --settings "$T/overlay.json" 2>"$T/err"); rc=$?
[ "$rc" = 125 ] && [ -z "$out" ] && grep -q 'cannot wall 10.0.0.0/33' "$T/err" \
  && ok "a kernel-invalid SYG_WORKER_SANDBOX_WALL entry refuses the launch (125), nothing runs" \
  || bad "bad wall entry: rc=$rc out=[$out] err=[$(cat "$T/err")]"
# 8e. A malformed entry is refused on the host before any sandbox starts (the fake claude would print)
out=$(cd "$W" && SYG_WORKER_SANDBOX_WALL=not-a-cidr SYG_WORKER_SANDBOX_CLAUDE=$T/fake-claude "$B/worker-sandbox" --settings "$T/overlay.json" 2>"$T/err"); rc=$?
[ "$rc" = 125 ] && [ -z "$out" ] && grep -q 'not an address or CIDR: not-a-cidr' "$T/err" \
  && ok "a malformed SYG_WORKER_SANDBOX_WALL entry refuses the launch (125) naming it, nothing runs" \
  || bad "malformed wall entry: rc=$rc out=[$out] err=[$(cat "$T/err")]"

# 1. --check builds the sandbox and runs nothing else
fake 'exit 0'
(cd "$W" && SYG_WORKER_SANDBOX_CLAUDE=$T/fake-claude "$B/worker-sandbox" --check) 2>"$T/err" && ok "--check builds the sandbox on this host" \
  || bad "--check failed: $(cat "$T/err")"

# 1b. A real worker run's stderr carries no pasta nameserver complaint (pasta runs with --dns none; the
# namespace resolves through the host's own resolver setup)
fake 'exit 0'
(cd "$W" && SYG_WORKER_SANDBOX_CLAUDE=$T/fake-claude "$B/worker-sandbox" --settings "$T/overlay.json") 2>"$T/err"; rc=$?
[ "$rc" = 0 ] && ! grep -q "Couldn't get any nameserver" "$T/err" \
  && ok "a worker run prints no pasta nameserver warning" \
  || bad "pasta dns warning: rc=$rc err=[$(cat "$T/err")]"

# 2. Exit code and argv come through; the overlay is a bound path, not a key in argv
fake 'printf "%s\n" "$@"; exit 7'
out=$(inside -p hello); rc=$?
[ "$rc" = 7 ] && [ "$(sed -n 2p <<<"$out")" = /run/worker/settings.json ] \
  && [ "$(sed -n 3,4p <<<"$out" | tr '\n' ' ')" = "--permission-mode bypassPermissions " ] \
  && [ "$(sed -n 6p <<<"$out")" = hello ] \
  && ok "claude's exit code and argv pass through pasta and bwrap; settings at the bound path, bypass set here" \
  || bad "exit or argv: rc=$rc out=[$out] err=[$(cat "$T/err")]"

# 2b. A descriptor the caller left open doesn't reach inside (nothing in worker-sandbox closes it: this
# row pins that the launch chain does, so a change of launcher shows up here)
fake '[ -e /proc/self/fd/9 ] && echo fd-inherited; echo done; exit 0'
out=$(inside 9>>"$T/open-fd"); rc=$?
[ "$out" = "done" ] && ok "an inherited descriptor doesn't reach the sandbox" \
  || bad "inherited fd: rc=$rc out=[$out] err=[$(cat "$T/err")]"

# 3. The tree is writable; its .git, .claude and the repo's git dir aren't, so no commit
fake 'touch in-tree; touch .git 2>/dev/null && echo gitfile-writable
touch .claude/planted 2>/dev/null && echo claude-dir-writable
git commit -q --allow-empty -m x 2>/dev/null && echo commit-worked
: >"$(git rev-parse --git-common-dir)/config" 2>/dev/null && echo common-writable
git log --oneline -1 >/dev/null && echo git-reads
exit 0'
gitfile_before=$(cat "$W/.git"); config_before=$(cat "$M/.git/config")
out=$(inside); rc=$?
[ "$rc" = 0 ] && [ -e "$W/in-tree" ] && [ "$out" = git-reads ] && [ "$(cat "$W/.git")" = "$gitfile_before" ] \
  && [ "$(cat "$M/.git/config")" = "$config_before" ] && [ ! -e "$W/.claude/planted" ] \
  && ok "tree writable; .git, .claude and the git dir refuse writes; git still reads" \
  || bad "write walls: rc=$rc out=[$out] err=[$(cat "$T/err")]"
rm -f "$W/in-tree"

# 4. A read-only tree refuses writes but keeps the scratch
fake 'touch in-tree 2>/dev/null && echo tree-writable; touch "$HOME/.claude/kept" && echo scratch-ok; exit 0'
out=$(cd "$W" && SYG_WORKER_SANDBOX_TREE=ro SYG_WORKER_SANDBOX_CLAUDE=$T/fake-claude "$B/worker-sandbox" --settings "$T/overlay.json" 2>"$T/err"); rc=$?
[ "$rc" = 0 ] && [ "$out" = scratch-ok ] && [ ! -e "$W/in-tree" ] && [ -e "$SYG_WORKER_SANDBOX_SCRATCH/kept" ] \
  && ok "SYG_WORKER_SANDBOX_TREE=ro: the tree refuses writes, the scratch takes them" \
  || bad "ro tree: rc=$rc out=[$out] err=[$(cat "$T/err")]"

# 5. Home, the main checkout, host sockets and the caller's environment are out of sight
# Each named path exists on this host (the control, or the row would prove nothing), and a fixture in
# home stands in for "another repo": a /tmp fixture would vanish with /tmp alone.
export XDG_CACHE_HOME=$HOME/.cache
made_cache=
[ -d "$HOME/.cache" ] || { mkdir -p "$HOME/.cache" && made_cache=1; }
H=$(mktemp -d "$HOME/.cache/worker-sandbox-probe.XXXXXX" 2>"$T/mktemp-err") || H=
# Only what the probe made goes: the fixture dir (when it exists) and a $HOME/.cache it created
trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"; [ -n "$H" ] && rm -rf "${H:?}"; [ -n "$made_cache" ] && rmdir "$HOME/.cache" 2>/dev/null' EXIT
if [ -z "$H" ]; then
  bad "hidden: couldn't create the fixture under $HOME/.cache: $(cat "$T/mktemp-err"); case not run"
else
  echo other-repo-secret >"${H:?}/secret"
  paths=("$H/secret")
  for p in "$HOME/.claude/settings.json" /run/user/"$(id -u)"; do
    [ -e "$p" ] && paths+=("$p") || echo "note: $p isn't on this host, so its row is only the fixture's"
  done
  export WORKER_PROBE_SECRET=caller-secret
  fake 'for p in '"$(printf '"%s" ' "${paths[@]}")"'; do [ -e "$p" ] && echo "visible: $p"; done
cat "'"$M"'/.env" 2>/dev/null && echo main-visible
[ -e /run/user ] && echo run-user-visible
[ -e /run/dbus ] && echo dbus-visible
[ -n "${WORKER_PROBE_SECRET:-}" ] && echo env-leaked
id -u; exit 0'
  out=$(inside); rc=$?
  unset WORKER_PROBE_SECRET
  [ "$rc" = 0 ] && [ "$out" = "$(id -u)" ] \
    && ok "home, main checkout, host sockets and caller env hidden; runs as the real uid (bypass mode refuses root)" \
    || bad "hidden: rc=$rc out=[$out] err=[$(cat "$T/err")]"
fi

# 5b. Untracked secret-shaped files read as empty; a tracked one, a fixture, reads as itself
echo real-key >"$W/.env"; mkdir -p "$W/svc"; echo real-key >"$W/svc/.env.local"; echo real-key >"$W/tls.pem"
mkdir -p "$W/a/b/c/d/e/f"; echo real-key >"$W/a/b/c/d/e/f/.env"
echo fixture-value >"$W/.env.test"
git -C "$W" add .env.test
fake 'for f in .env svc/.env.local tls.pem a/b/c/d/e/f/.env; do [ -s "$f" ] && echo "readable: $f"; done; cat .env.test; exit 0'
out=$(inside); rc=$?
[ "$rc" = 0 ] && [ "$out" = fixture-value ] && [ "$(cat "$W/.env")" = real-key ] && [ "$(cat "$W/a/b/c/d/e/f/.env")" = real-key ] \
  && ok "untracked .env, nested .env.local, .pem and a .env seven levels deep read as empty inside, unchanged on the host; tracked .env.test reads" \
  || bad "masking: rc=$rc out=[$out] err=[$(cat "$T/err")]"
git -C "$W" rm -q --cached .env.test; rm -rf "$W/.env" "$W/.env.test" "$W/svc" "$W/tls.pem" "$W/a"

# 6. A symlinked .claude or .git can't aim a bind elsewhere
mv "$W/.claude" "$T/claude-kept"
mkdir "$T/decoy"; ln -s "$T/decoy" "$W/.claude"
out=$(inside); rc=$?
[ "$rc" = 125 ] && grep -q '\.claude is a symlink' "$T/err" && ok "a symlinked .claude refuses (125)" \
  || bad "symlinked .claude: rc=$rc err=[$(cat "$T/err")]"
rm -f "$W/.claude"; mv "$T/claude-kept" "$W/.claude"
mv "$W/.git" "$T/git-kept"; ln -s "$T/git-kept" "$W/.git"
out=$(inside); rc=$?
# worker-sandbox's worker-tree-check refuses a symlinked .git before gate-sandbox runs ...
[ "$rc" = 125 ] && grep -q 'worker-tree-check refused' "$T/err" && ok "a symlinked .git refuses (125) via worker-tree-check" \
  || bad "symlinked .git via worker-sandbox: rc=$rc err=[$(cat "$T/err")]"
# ... so gate-sandbox's own refusal is pinned by a direct call
out=$(SYG_GATE_SANDBOX_PROFILE=worker SYG_GATE_SANDBOX_SCRATCH=$SYG_WORKER_SANDBOX_SCRATCH "$B/gate-sandbox" "$W" -- /usr/bin/true 2>&1); rc=$?
[ "$rc" = 125 ] && [[ $out == *".git is a symlink; refusing"* ]] && ok "gate-sandbox itself refuses a symlinked .git (125)" \
  || bad "symlinked .git in gate-sandbox: rc=$rc out=[$out]"
rm -f "$W/.git"; mv "$T/git-kept" "$W/.git"

# 6b. A planted node_modules symlink: the host doesn't write through it, and it isn't bound in
mkdir -p "$T/victim/node_modules"; echo dep >"$T/victim/node_modules/dep"
ln -s "$T/victim/node_modules" "$W/node_modules"
fake '[ -e node_modules/dep ] && echo followed; echo done; exit 0'
out=$(inside); rc=$?
[ "$out" = "done" ] && [ ! -e "$T/victim/node_modules/.vite-temp" ] \
  && ok "a planted node_modules symlink isn't followed or written through" \
  || bad "planted node_modules: rc=$rc out=[$out]"
rm -f "$W/node_modules"
# 6b (main). The same planted link, run from the MAIN checkout: there the link under judgment is the main's own
ln -s "$T/victim/node_modules" "$M/node_modules"
fake '[ -e node_modules/dep ] && echo followed; echo done; exit 0'
out=$(cd "$M" && SYG_WORKER_SANDBOX_CLAUDE=$T/fake-claude "$B/worker-sandbox" --settings "$T/overlay.json" 2>"$T/err"); rc=$?
[ "$out" = "done" ] && [ ! -e "$T/victim/node_modules/.vite-temp" ] \
  && ok "a planted node_modules symlink in the main checkout isn't followed or written through" \
  || bad "planted node_modules in main checkout: rc=$rc out=[$out] err=[$(cat "$T/err")]"
rm -f "$M/node_modules"; rmdir "$M/.claude" 2>/dev/null
# The one target it does follow: this repo's own main checkout, which gated worktrees really link to
mkdir -p "$M/node_modules"; echo dep >"$M/node_modules/dep"
ln -s "$M/node_modules" "$W/node_modules"
fake 'cat node_modules/dep; touch node_modules/planted 2>/dev/null && echo deps-writable; touch node_modules/.vite-temp/c.js && echo vite-scratch; exit 0'
out=$(inside); rc=$?
[ "$out" = $'dep\nvite-scratch' ] && [ ! -e "$M/node_modules/planted" ] && [ ! -e "$M/node_modules/.vite-temp/c.js" ] \
  && ok "a node_modules link to this repo's main checkout resolves, read-only, with vite's private scratch" \
  || bad "main checkout node_modules: rc=$rc out=[$out] err=[$(cat "$T/err")]"
rm -f "$W/node_modules"; rm -rf "$M/node_modules"

# 6c. Run from a bin/ inside the tree (a run on a tree that ships this bin directory): that bin/ goes on the inner PATH,
# gate-lock's way in, and stays off the one the host builds the sandbox with. A planted git there doesn't run.
mkdir -p "$W/bin"
cp "$B/worker-sandbox" "$B/gate-sandbox" "$B/gate-lock" "$B/worker-tree-check" "$W/bin/"
printf '#!/bin/sh\ntouch "%s"\nexit 1\n' "$T/planted-ran" >"$W/bin/git"; chmod +x "$W/bin/git"
fake 'gate-lock echo gate-lock-ran; exit 0'
out=$(cd "$W" && SYG_WORKER_SANDBOX_TREE=ro SYG_WORKER_SANDBOX_CLAUDE=$T/fake-claude "$W/bin/worker-sandbox" --settings "$T/overlay.json" 2>"$T/err"); rc=$?
[ "$rc" = 0 ] && [ "$out" = gate-lock-ran ] && [ ! -e "$T/planted-ran" ] \
  && ok "a bin/ in the tree is on the inner PATH only: gate-lock found, a planted git doesn't run on the host" \
  || bad "inner PATH: rc=$rc out=[$out] err=[$(cat "$T/err")] ran=$([ -e "$T/planted-ran" ] && echo yes)"
rm -rf "${W:?}/bin"

# 7. Host loopback: reachable on the host and under bare --share-net (the control), refused here.
# Every other address the host has right now goes through the same listener, IPv6 too.
python3 -c '
import socket, sys
s = socket.socket(socket.AF_INET6); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
s.bind(("::", 0)); s.listen(16); print(s.getsockname()[1], flush=True)
while True: s.accept()[0].close()
' >"$T/port" &
listener=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$T/port" ] && break; sleep 0.2; done
port=$(cat "$T/port")
addrs=$(ip -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -v '^fe80')
cat >"$T/connect.py" <<'PY'
import socket, sys
for a in sys.argv[2:]:
    s = socket.socket(socket.AF_INET6 if ":" in a else socket.AF_INET); s.settimeout(3)
    try:
        s.connect((a, int(sys.argv[1]))); print(a, "OPEN")
    except ConnectionRefusedError:
        print(a, "refused")
    except OSError as e:
        print(a, "error", e)
PY
# shellcheck disable=SC2086
control=$(bwrap --unshare-all --share-net --ro-bind / / --dev /dev --proc /proc --ro-bind "$T/connect.py" "$T/connect.py" -- python3 "$T/connect.py" "$port" $addrs 2>&1)
fake "python3 $T/connect.py $port $(tr '\n' ' ' <<<"$addrs"); exit 0"
out=$(cd "$W" && SYG_WORKER_SANDBOX_RO_BINDS=$T/connect.py SYG_WORKER_SANDBOX_CLAUDE=$T/fake-claude "$B/worker-sandbox" --settings "$T/overlay.json" 2>"$T/err"); rc=$?
kill "$listener" 2>/dev/null; wait "$listener" 2>/dev/null
n=$(wc -l <<<"$addrs")
# Every host address is walled: loopback and the copied address answer "refused" from the namespace
# itself, the rest "No route to host". Only those two count as closed: a timeout or another error is
# not proof of a wall, and each address must have printed a line.
all_closed=1
while read -r a; do
  line=$(awk -v a="$a" '$1 == a' <<<"$out" | head -1)
  [[ $line == "$a refused" || $line == *"No route to host"* ]] || all_closed=0
done <<<"$addrs"
[ "$(grep -c ' OPEN$' <<<"$control")" = "$n" ] && [ "$all_closed" = 1 ] \
  && ok "every host address unreachable from inside ($n); all $n open to bare --share-net (control)" \
  || bad "host addresses: control=[$control] rc=$rc out=[$out] err=[$(cat "$T/err")]"

# 7c. The knob is a live wall on any host: 192.0.2.1 (TEST-NET-1) is never routed to the host, so
# "No route to host" in under 2 s proves the route was applied (a bare timeout would not).
fake "python3 $T/connect.py 80 192.0.2.1; exit 0"
t0=$(date +%s%N)
out=$(cd "$W" && SYG_WORKER_SANDBOX_WALL=192.0.2.0/24 SYG_WORKER_SANDBOX_RO_BINDS=$T/connect.py SYG_WORKER_SANDBOX_CLAUDE=$T/fake-claude "$B/worker-sandbox" --settings "$T/overlay.json" 2>"$T/err"); rc=$?
ms=$(( ($(date +%s%N) - t0) / 1000000 ))
ctl=$(cd "$W" && SYG_WORKER_SANDBOX_RO_BINDS=$T/connect.py SYG_WORKER_SANDBOX_CLAUDE=$T/fake-claude "$B/worker-sandbox" --settings "$T/overlay.json" 2>>"$T/err")
[[ $out == *"No route to host"* ]] && [ "$ms" -lt 2000 ] && [[ $ctl != *"No route to host"* ]] \
  && ok "SYG_WORKER_SANDBOX_WALL=192.0.2.0/24: 'No route to host' in ${ms} ms; without it: [$ctl]" \
  || bad "wall knob live: rc=$rc ms=$ms out=[$out] ctl=[$ctl] err=[$(cat "$T/err")]"

# 7d2. Live route table: every prefix `gate-sandbox --print-wall` prints on this host is an unreachable
# route inside (the computation itself is pinned on a fixture host above; no logic is copied here).
# ip prints a host route without its /32 or /128.
expected=$(env -u SYG_GATE_SANDBOX_WALL "$B/gate-sandbox" --print-wall | awk '{ if ($0 ~ /:/) sub(/\/128$/, ""); else sub(/\/32$/, ""); print }')
fake 'ip -o route show type unreachable; ip -o -6 route show type unreachable; exit 0'
out=$(inside); rc=$?
got=$(awk '{print $2}' <<<"$out")
missing=
while read -r pfx; do
  [ -n "$pfx" ] || continue
  grep -qFx -- "$pfx" <<<"$got" || missing+=" $pfx"
done <<<"$expected"
[ "$rc" = 0 ] && [ -n "$expected" ] && [ -z "$missing" ] \
  && ok "every host-side wall prefix is an unreachable route inside ($(grep -c . <<<"$expected"))" \
  || bad "wall routes: rc=$rc missing=[$missing] expected=[$expected] out=[$out] err=[$(cat "$T/err")]"

# 7e. The worker can't undo the wall: no capabilities in its user namespace, so route and rule edits fail
# Each attempt must fail for the capability reason, not any other (a typo'd command also "fails").
fake 'for c in "route del unreachable 192.0.2.0/24" "route flush table main" "rule add from all lookup 99"; do
  e=$(ip $c 2>&1) && echo "worked: $c"
  case $e in *"Operation not permitted"*) ;; *) echo "not EPERM: $c: $e" ;; esac
done
awk '"'"'/^CapEff/ {print $2}'"'"' /proc/self/status
exit 0'
out=$(cd "$W" && SYG_WORKER_SANDBOX_WALL=192.0.2.0/24 SYG_WORKER_SANDBOX_CLAUDE=$T/fake-claude "$B/worker-sandbox" --settings "$T/overlay.json" 2>"$T/err"); rc=$?
[ "$rc" = 0 ] && [ "$out" = 0000000000000000 ] \
  && ok "the worker can't delete or flush routes or add rules; CapEff is zero" \
  || bad "undo the wall: rc=$rc out=[$out] err=[$(cat "$T/err")]"

# 7f. Knob rows: SYG_WORKER_SANDBOX_ENV passes the named variable only; SYG_WORKER_SANDBOX_PATH empty and custom
fake '[ -n "${FOO_X:-}" ] && echo "foo=$FOO_X"; [ -n "${BAR_X:-}" ] && echo bar-leaked; exit 0'
out=$(cd "$W" && FOO_X=1 BAR_X=2 SYG_WORKER_SANDBOX_ENV=FOO_X SYG_WORKER_SANDBOX_CLAUDE=$T/fake-claude "$B/worker-sandbox" --settings "$T/overlay.json" 2>"$T/err"); rc=$?
[ "$rc" = 0 ] && [ "$out" = foo=1 ] && ok "SYG_WORKER_SANDBOX_ENV passes the named variable and no other" \
  || bad "worker env knob: rc=$rc out=[$out] err=[$(cat "$T/err")]"
# the old unprefixed WORKER_SANDBOX_ENV is not read
out=$(cd "$W" && FOO_X=1 BAR_X=2 WORKER_SANDBOX_ENV=BAR_X SYG_WORKER_SANDBOX_ENV=FOO_X SYG_WORKER_SANDBOX_CLAUDE=$T/fake-claude "$B/worker-sandbox" --settings "$T/overlay.json" 2>"$T/err"); rc=$?
[ "$rc" = 0 ] && [ "$out" = foo=1 ] && ok "the old WORKER_SANDBOX_ENV name passes nothing" \
  || bad "old worker env name: rc=$rc out=[$out] err=[$(cat "$T/err")]"
fake 'echo "$PATH"; exit 0'
out=$(cd "$W" && SYG_WORKER_SANDBOX_PATH='' SYG_WORKER_SANDBOX_CLAUDE=$T/fake-claude "$B/worker-sandbox" --settings "$T/overlay.json" 2>"$T/err"); rc=$?
[ "$rc" = 0 ] && [[ $out == *"/usr/bin:/bin" ]] && [[ $out != *::* && $out != *: ]] \
  && ok "an empty SYG_WORKER_SANDBOX_PATH gives the default tail, no empty entry" \
  || bad "empty worker PATH: rc=$rc out=[$out] err=[$(cat "$T/err")]"
out=$(cd "$W" && SYG_WORKER_SANDBOX_PATH=/opt/x:/usr/bin:/bin SYG_WORKER_SANDBOX_CLAUDE=$T/fake-claude "$B/worker-sandbox" --settings "$T/overlay.json" 2>"$T/err"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "/run/worker/bin:/opt/x:/usr/bin:/bin" ] \
  && ok "a custom SYG_WORKER_SANDBOX_PATH follows the bin directory" \
  || bad "custom worker PATH: rc=$rc out=[$out] want=[/run/worker/bin:/opt/x:/usr/bin:/bin] err=[$(cat "$T/err")]"

# 7b. The internet does work: the wall above isn't just "no network". Skipped when the host is offline.
netprobe='import socket
try:
    socket.create_connection(("one.one.one.one", 443), timeout=8); print("OPEN")
except OSError as e:
    print("closed", e)'
# The sandbox resolves names only through nss-resolve or a non-loopback nameserver in resolv.conf
resolver_path=
if grep -E '^hosts:.*\bresolve\b' /etc/nsswitch.conf >/dev/null 2>&1 && [ -S /run/systemd/resolve/io.systemd.Resolve ]; then
  resolver_path=1
elif awk '$1 == "nameserver" && $2 !~ /^(127\.|::1$)/ {f=1} END {exit !f}' /etc/resolv.conf 2>/dev/null; then
  resolver_path=1
fi
if [ -z "$resolver_path" ]; then
  echo "SKIP: no resolver path for the sandbox on this host (loopback-only resolv.conf without nss-resolve)"
elif [ "$(python3 -c "$netprobe" 2>&1)" = OPEN ]; then
  printf '%s\n' "$netprobe" >"$T/net.py"
  fake "python3 $T/net.py; exit 0"
  out=$(cd "$W" && SYG_WORKER_SANDBOX_RO_BINDS=$T/net.py SYG_WORKER_SANDBOX_CLAUDE=$T/fake-claude "$B/worker-sandbox" --settings "$T/overlay.json" 2>"$T/err"); rc=$?
  [ "$out" = OPEN ] && ok "the internet answers by name from inside" \
    || bad "internet from inside: rc=$rc out=[$out] err=[$(cat "$T/err")]"
else
  echo "SKIP: this host is offline, so internet from inside wasn't checked"
fi

# 9. The gate lock is the host's: held there, it's busy inside
# flock -E names "busy" apart from "couldn't open the file", which must not read as a held lock.
lock_probe='flock -n -E 75 "$SYG_GATE_LOCK_FILE" true; case $? in 0) echo lock-free ;; 75) echo lock-busy ;; *) echo lock-unusable ;; esac'
fake "$lock_probe; gate-lock echo gate-lock-ran; exit 0"
out=$(inside); rc=$?
[ "$out" = $'lock-free\ngate-lock-ran' ] && ok "gate-lock runs inside when the lock is free" \
  || bad "gate-lock free: rc=$rc out=[$out] err=[$(cat "$T/err")]"
fake "$lock_probe; exit 0"
out=$( { flock 9; inside; } 9>>"$SYG_GATE_LOCK_FILE"); rc=$?
[ "$out" = lock-busy ] && ok "a lock held on the host is busy inside: workers queue with every other gate" \
  || bad "gate-lock shared: rc=$rc out=[$out]"

echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
