#!/bin/bash
# Canary for per-probe timeout in tests/run-probes.sh against a mutated copy of
# the tree: hung-probe timeout (124/137 + ceiling note + sibling probes PASS),
# missing-timeout-binary fallback note, startup banner (default and override),
# SYG_PROBE_TIMEOUT validation, and generous override.
# Usage: tests/probe-timeout.probe.sh   (from anywhere; never recurses into real probes)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

TMP=$(mktemp -d)
COPY="$TMP/repo"
HUNG_PIDFILE="$COPY/hung.pid"
leaked_pids=()
cleanup() {
  [ -s "$HUNG_PIDFILE" ] && leaked_pids+=("$(<"$HUNG_PIDFILE")")
  local p comm
  for p in ${leaked_pids[@]+"${leaked_pids[@]}"}; do
    comm=$(cat "/proc/$p/comm" 2>/dev/null) || continue
    case "$comm" in sleep | bash | timeout) kill -9 "$p" 2>/dev/null || true ;; esac
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$COPY/tests" "$COPY/plugins/seyag/hooks"
cp "$REPO/tests/run-probes.sh" "$COPY/tests/run-probes.sh"
chmod +x "$COPY/tests/run-probes.sh"
RUNNER="$COPY/tests/run-probes.sh"

cat >"$COPY/tests/acme-alpha.probe.sh" <<'EOF'
#!/bin/bash
exit 0
EOF

cat >"$COPY/tests/acme-beta.probe.sh" <<'EOF'
#!/bin/bash
exit 0
EOF

cat >"$COPY/tests/acme-sleeper.probe.sh" <<'EOF'
#!/bin/bash
echo "acme-sleeper: partial line before hang"
sleep 999 &
spid=$!
echo "$spid" >"$(dirname "${BASH_SOURCE[0]}")/../hung.pid"
wait "$spid"
EOF

# 1. Hung probe: SYG_PROBE_TIMEOUT=2 finishes fast, exits non-zero, names the
# sleeper probe with rc 124 or 137, prints the ceiling note + partial output,
# and both trivial probes still PASS. Outer timeout bounds red-first runs when
# the runner wrapper is reverted.
t0=$SECONDS
out=$(timeout -k 2 20 env SYG_PROBE_TIMEOUT=2 bash "$RUNNER" -j 2 2>"$TMP/hung.err")
rc=$?
elapsed=$((SECONDS - t0))
err=$(<"$TMP/hung.err")
[ -s "$HUNG_PIDFILE" ] && leaked_pids+=("$(<"$HUNG_PIDFILE")")
want_note="(SIGTERM/SIGKILL after the 2s per-probe ceiling — usually the timeout, but an external cancel looks the same; the probe's own output follows)"

if [ "$rc" -ne 0 ] && [ "$elapsed" -lt 15 ] \
  && grep -qE '^FAIL  acme-sleeper \(exit (124|137)\)$' <<<"$out" \
  && grep -qF "$want_note" <<<"$out" \
  && grep -qF 'acme-sleeper: partial line before hang' <<<"$out" \
  && grep -q '^PASS  acme-alpha$' <<<"$out" \
  && grep -q '^PASS  acme-beta$' <<<"$out" \
  && grep -q '^2 passed, 1 failed (of 3)$' <<<"$out"; then
  ok "hung probe: SYG_PROBE_TIMEOUT=2 finishes in ${elapsed}s (<15s), FAIL acme-sleeper (124/137) with ceiling note, trivial probes PASS"
else
  bad "hung probe (rc=$rc, elapsed=${elapsed}s): out=[$out] err=[$err]"
fi

# Remove the sleeper probe so healthy-suite cases run over the two trivial probes.
rm -f "$COPY/tests/acme-sleeper.probe.sh"

# 2. No-timeout-binary: PATH-shaved env emits the stderr note once and runs unbounded.
nb="$TMP/no-timeout-bin"
mkdir -p "$nb"
for t in bash cat mktemp rm dirname basename kill sed grep tr sort head wc env sleep nproc; do
  p=$(command -v "$t") && ln -sf "$p" "$nb/$t"
done
if PATH="$nb" command -v timeout >/dev/null 2>&1; then
  bad "no-timeout-binary: fixture PATH still contains timeout"
else
  out=$(PATH="$nb" env -u SYG_PROBE_TIMEOUT bash "$RUNNER" 2>"$TMP/nb.err")
  rc=$?
  err=$(<"$TMP/nb.err")
  if [ "$rc" -eq 0 ] \
    && [ "$(grep -cF 'run-probes: no timeout binary on PATH; probes run without a per-probe limit' <<<"$err")" -eq 1 ] \
    && ! grep -qF 'probe timeout:' <<<"$err" \
    && grep -q '^PASS  acme-alpha$' <<<"$out" \
    && grep -q '^PASS  acme-beta$' <<<"$out" \
    && grep -q '^2 passed, 0 failed (of 2)$' <<<"$out"; then
    ok "no-timeout-binary: one stderr note (as banner), suite runs unbounded and trivial probes PASS"
  else
    bad "no-timeout-binary (rc=$rc): out=[$out] err=[$err]"
  fi
fi

# 3. Banner: effective value line appears with default when unset and with override when set.
out_def=$(env -u SYG_PROBE_TIMEOUT bash "$RUNNER" 2>"$TMP/banner-def.err")
rc_def=$?
err_def=$(<"$TMP/banner-def.err")
if [ "$rc_def" -eq 0 ] \
  && [ "$(grep -cF 'run-probes: probe timeout: 600s per probe (SYG_PROBE_TIMEOUT or default)' <<<"$err_def")" -eq 1 ]; then
  ok "banner (unset): prints default 600s per probe"
else
  bad "banner (unset, rc=$rc_def): out=[$out_def] err=[$err_def]"
fi

out_ovr=$(SYG_PROBE_TIMEOUT=45 bash "$RUNNER" 2>"$TMP/banner-ovr.err")
rc_ovr=$?
err_ovr=$(<"$TMP/banner-ovr.err")
if [ "$rc_ovr" -eq 0 ] \
  && [ "$(grep -cF 'run-probes: probe timeout: 45s per probe (SYG_PROBE_TIMEOUT or default)' <<<"$err_ovr")" -eq 1 ]; then
  ok "banner (override): prints SYG_PROBE_TIMEOUT=45s per probe"
else
  bad "banner (override, rc=$rc_ovr): out=[$out_ovr] err=[$err_ovr]"
fi

# 4. Env validation: non-numeric, zero, and negative values warn on stderr and fall back to 600s.
for bad_val in abc 0 -5; do
  out_v=$(SYG_PROBE_TIMEOUT="$bad_val" bash "$RUNNER" 2>"$TMP/val-$bad_val.err")
  rc_v=$?
  err_v=$(<"$TMP/val-$bad_val.err")
  if [ "$rc_v" -eq 0 ] \
    && grep -qF "run-probes: invalid SYG_PROBE_TIMEOUT='$bad_val' (must be a positive integer); falling back to default 600s" <<<"$err_v" \
    && grep -qF 'run-probes: probe timeout: 600s per probe (SYG_PROBE_TIMEOUT or default)' <<<"$err_v" \
    && grep -q '^PASS  acme-alpha$' <<<"$out_v" \
    && grep -q '^PASS  acme-beta$' <<<"$out_v" \
    && grep -q '^2 passed, 0 failed (of 2)$' <<<"$out_v"; then
    ok "env validation SYG_PROBE_TIMEOUT=$bad_val: stderr fallback note + suite PASS"
  else
    bad "env validation SYG_PROBE_TIMEOUT=$bad_val (rc=$rc_v): out=[$out_v] err=[$err_v]"
  fi
done

# 5. Generous override: SYG_PROBE_TIMEOUT=300 over copied tree passes both trivial probes.
out_gen=$(SYG_PROBE_TIMEOUT=300 bash "$RUNNER" 2>"$TMP/gen.err")
rc_gen=$?
err_gen=$(<"$TMP/gen.err")
if [ "$rc_gen" -eq 0 ] \
  && grep -qF 'run-probes: probe timeout: 300s per probe (SYG_PROBE_TIMEOUT or default)' <<<"$err_gen" \
  && grep -q '^PASS  acme-alpha$' <<<"$out_gen" \
  && grep -q '^PASS  acme-beta$' <<<"$out_gen" \
  && grep -q '^2 passed, 0 failed (of 2)$' <<<"$out_gen"; then
  ok "generous override SYG_PROBE_TIMEOUT=300: both trivial probes PASS"
else
  bad "generous override SYG_PROBE_TIMEOUT=300 (rc=$rc_gen): out=[$out_gen] err=[$err_gen]"
fi

exit "$fail"
