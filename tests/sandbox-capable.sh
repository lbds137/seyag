# shellcheck shell=bash
# Sourced by probes that need a real bubblewrap (and, for the worker profile, pasta) sandbox.
# SYG_PROBE_REQUIRE_SANDBOX=1 (set in CI) turns "this host can't sandbox" from a skip into a failure,
# so a runner that lost its sandbox support can't pass the sandbox probes by skipping them.

# Can bwrap build a namespace here (false inside another sandbox without user namespaces)?
syg_can_bwrap() {
  bwrap --die-with-parent --unshare-all --new-session --ro-bind / / --dev /dev --proc /proc true >/dev/null 2>&1
}

# Can pasta give a bwrap namespace a network here (false inside a nested sandbox)?
syg_can_pasta() {
  pasta --config-net --quiet --no-map-gw -t none -u none -T none -U none -- \
    bwrap --unshare-all --share-net --uid "$(id -u)" --gid "$(id -g)" \
    --ro-bind / / --dev /dev --proc /proc true >/dev/null 2>&1
}

# syg_sandbox_skip REASON: end the probe, as a failure when a sandbox is required, else as a skip.
syg_sandbox_skip() {
  if [ "${SYG_PROBE_REQUIRE_SANDBOX:-}" = 1 ]; then
    echo "FAIL: sandbox required but unavailable: $1"
    exit 1
  fi
  echo "SKIP: $1"
  exit 0
}
