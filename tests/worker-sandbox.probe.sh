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
[ "$rc" = 125 ] && ok "a bad tree mode refuses (125), nothing runs" || bad "bad tree mode: rc=$rc out=[$out]"

# 8. No pasta: refuses rather than run with another network (or none of the walls)
mkdir -p "$T/nopasta"
for t in bash env git realpath dirname basename id mkdir bwrap; do ln -s "$(command -v "$t")" "$T/nopasta/$t"; done
# gate-sandbox directly: worker-sandbox sets its own PATH, with /usr/bin on it
out=$(PATH=$T/nopasta SYG_GATE_SANDBOX_PROFILE=worker SYG_GATE_SANDBOX_SCRATCH=$SYG_WORKER_SANDBOX_SCRATCH "$B/gate-sandbox" "$W" -- /usr/bin/true 2>&1); rc=$?
[ "$rc" = 125 ] && [[ $out == *"pasta not found"* ]] && ok "no pasta: the worker profile refuses (125)" \
  || bad "no pasta: rc=$rc out=[$out]"

# The rest build a real sandbox, with pasta for the network.
# shellcheck source=tests/sandbox-capable.sh
. "$REPO/tests/sandbox-capable.sh"
if ! syg_can_pasta; then
  echo "worker-sandbox probe: pass=$pass fail=$fail (sandbox cases not run)"
  [ "$fail" = 0 ] || exit 1
  syg_sandbox_skip "pasta+bwrap cannot build a worker sandbox here (nested sandbox?)"
fi

# 1. --check builds the sandbox and runs nothing else
fake 'exit 0'
(cd "$W" && SYG_WORKER_SANDBOX_CLAUDE=$T/fake-claude "$B/worker-sandbox" --check) 2>"$T/err" && ok "--check builds the sandbox on this host" \
  || bad "--check failed: $(cat "$T/err")"

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
echo fixture-value >"$W/.env.test"
git -C "$W" add .env.test
fake 'for f in .env svc/.env.local tls.pem; do [ -s "$f" ] && echo "readable: $f"; done; cat .env.test; exit 0'
out=$(inside); rc=$?
[ "$rc" = 0 ] && [ "$out" = fixture-value ] && [ "$(cat "$W/.env")" = real-key ] \
  && ok "untracked .env, nested .env.local and .pem read as empty inside, unchanged on the host; tracked .env.test reads" \
  || bad "masking: rc=$rc out=[$out] err=[$(cat "$T/err")]"
git -C "$W" rm -q --cached .env.test; rm -rf "$W/.env" "$W/.env.test" "$W/svc" "$W/tls.pem"

# 6. A symlinked .claude or .git can't aim a bind elsewhere
mv "$W/.claude" "$T/claude-kept"
mkdir "$T/decoy"; ln -s "$T/decoy" "$W/.claude"
out=$(inside); rc=$?
[ "$rc" = 125 ] && grep -q 'symlink' "$T/err" && ok "a symlinked .claude refuses (125)" \
  || bad "symlinked .claude: rc=$rc err=[$(cat "$T/err")]"
rm -f "$W/.claude"; mv "$T/claude-kept" "$W/.claude"
mv "$W/.git" "$T/git-kept"; ln -s "$T/git-kept" "$W/.git"
out=$(inside); rc=$?
[ "$rc" = 125 ] && grep -q 'symlink' "$T/err" && ok "a symlinked .git refuses (125)" \
  || bad "symlinked .git: rc=$rc err=[$(cat "$T/err")]"
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
cp "$B/worker-sandbox" "$B/gate-sandbox" "$B/gate-lock" "$W/bin/"
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
# What holds: loopback and the address(es) pasta copies into its namespace (the namespace itself
# answers "refused" there). The host's other addresses stay reachable: a known gap, the wall-hardening
# unit's. The copied set comes from the same pasta launcher line gate-sandbox uses.
copied=$(pasta --config-net --quiet --no-map-gw -t none -u none -T none -U none -- ip -o addr show 2>/dev/null \
  | awk '$2 != "lo" {print $4}' | cut -d/ -f1 | grep -v '^fe80')
walled=$(printf '%s\n' 127.0.0.1 ::1 "$copied" | grep -v '^$' | sort -u)
walled_n=0; walled_ok=1; others=0
while read -r a; do
  if grep -qFx "$a" <<<"$walled"; then
    walled_n=$((walled_n+1))
    grep -qFx "$a refused" <<<"$out" || walled_ok=0
  else
    others=$((others+1))
    echo "note: host address $a is $(awk -v a="$a" '$1 == a {print $2}' <<<"$out" | head -1) from inside (known gap, wall-hardening unit)"
  fi
done <<<"$addrs"
# Refused, not just "failed": a namespace with no network at all would time out or say unreachable
[ "$(grep -c ' OPEN$' <<<"$control")" = "$n" ] && [ "$walled_ok" = 1 ] && [ "$walled_n" -ge 2 ] \
  && ok "loopback and pasta's copied address refused ($walled_n); $others other host address(es) reachable (known gap); all $n open to bare --share-net (control)" \
  || bad "host addresses: control=[$control] rc=$rc out=[$out] copied=[$copied] err=[$(cat "$T/err")]"

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
