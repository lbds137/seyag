#!/usr/bin/env bash
# Hermetic probe for plugins/seyag/bin/resource-profile: fixture meminfo (SYG_MEM_GATE_MEMINFO)
# and CPU PSI (SYG_RESOURCE_PSI_CPU) files, SYG_CONFIG=0 except in the config cases, and
# XDG_CONFIG_HOME / CLAUDE_PROJECT_DIR pointed at tmp dirs. Each case is bounded by timeout.
# Usage: tests/resource-profile.probe.sh   (from anywhere)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RP="$REPO/plugins/seyag/bin/resource-profile"
[ -x "$RP" ] || { echo "FAIL  $RP is not executable (chmod +x it)"; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/resource-profile-probe.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; }

mkmem() {
  local avail_kb=$(($2 * 1024))
  {
    echo "MemTotal:        16305768 kB"
    echo "MemFree:          2345678 kB"
    echo "MemAvailable:    $avail_kb kB"
  } > "$1"
}

mkpsi() {
  {
    echo "some avg10=10.00 avg60=$2 avg300=15.00 total=123456"
    echo "full avg10=0.00 avg60=0.00 avg300=0.00 total=0"
  } > "$1"
}

mkmem "$tmp/mem3100" 3100
mkmem "$tmp/mem64000" 64000
mkmem "$tmp/mem500" 500
mkpsi "$tmp/psi-low" "12.34"
mkpsi "$tmp/psi-72" "72.10"
mkpsi "$tmp/psi-50" "50.00"
mkpsi "$tmp/psi-49" "49.99"

mkdir -p "$tmp/xdg-empty" "$tmp/proj-empty" "$tmp/home-empty"

BASE_ENV=(
  env
  -u SYG_RESOURCE_PROFILE
  -u SYG_MAX_PARALLEL
  -u SYG_RESOURCE_JOB_MB
  -u SYG_RESOURCE_CPU_PSI_MAX
  -u OMP_NUM_THREADS
  SYG_CONFIG=0
  HOME="$tmp/home-empty"
  XDG_CONFIG_HOME="$tmp/xdg-empty"
  CLAUDE_PROJECT_DIR="$tmp/proj-empty"
  SYG_MEM_GATE_MEMINFO="$tmp/mem3100"
  SYG_RESOURCE_PSI_CPU="$tmp/psi-low"
)

run() {
  timeout 5 "${BASE_ENV[@]}" "$@" > "$tmp/out" 2> "$tmp/err"
  rc=$?
}
out() { cat "$tmp/out"; }
err() { cat "$tmp/err"; }

# 1. unset -> --jobs 8 prints 8, empty stderr; bare line reads profile=normal ceiling=none source=unset.
run "$RP" --jobs 8
[ "$rc" = 0 ] && [ "$(out)" = "8" ] && [ ! -s "$tmp/err" ] \
  && ok "unset: --jobs 8 prints 8 with empty stderr" || bad "unset --jobs 8: rc=$rc out=$(out) err=$(err)"

run "$RP"
[ "$rc" = 0 ] && [ "$(out)" = "profile=normal ceiling=none source=unset" ] && [ ! -s "$tmp/err" ] \
  && ok "unset: bare output is profile=normal ceiling=none source=unset" || bad "unset bare: rc=$rc out=$(out) err=$(err)"

# 2. low -> --jobs 8 gives 1 plus clamp line; --jobs 1 gives 1 with no clamp line.
run env SYG_RESOURCE_PROFILE=low "$RP" --jobs 8
want_err="resource-profile: clamped jobs 8 -> 1 (SYG_RESOURCE_PROFILE=low)"
[ "$rc" = 0 ] && [ "$(out)" = "1" ] && [ "$(err)" = "$want_err" ] \
  && ok "low: --jobs 8 prints 1 with clamp line on stderr" || bad "low --jobs 8: rc=$rc out=$(out) err=$(err)"

run env SYG_RESOURCE_PROFILE=low "$RP" --jobs 1
[ "$rc" = 0 ] && [ "$(out)" = "1" ] && [ ! -s "$tmp/err" ] \
  && ok "low: --jobs 1 prints 1 with no clamp line" || bad "low --jobs 1: rc=$rc out=$(out) err=$(err)"

# 3. normal plus SYG_MAX_PARALLEL=3 -> --jobs 8 gives 3.
run env SYG_RESOURCE_PROFILE=normal SYG_MAX_PARALLEL=3 "$RP" --jobs 8
want_err="resource-profile: clamped jobs 8 -> 3 (SYG_MAX_PARALLEL=3)"
[ "$rc" = 0 ] && [ "$(out)" = "3" ] && [ "$(err)" = "$want_err" ] \
  && ok "normal + SYG_MAX_PARALLEL=3: --jobs 8 gives 3 with clamp line" || bad "normal + max 3: rc=$rc out=$(out) err=$(err)"

# 4. auto memory: MemAvailable 3100 MB with JOB_MB 1024 gives 3; JOB_MB 4096 gives 1; 64000 MB and --jobs 4 gives 4 (never raises).
run env SYG_RESOURCE_PROFILE=auto "$RP" --jobs 8
want_err="resource-profile: clamped jobs 8 -> 3 (auto: MemAvailable 3100 MB / 1024 MB per job)"
[ "$rc" = 0 ] && [ "$(out)" = "3" ] && [ "$(err)" = "$want_err" ] \
  && ok "auto memory: 3100 MB / 1024 MB gives 3" || bad "auto mem 3100/1024: rc=$rc out=$(out) err=$(err)"

run env SYG_RESOURCE_PROFILE=auto SYG_RESOURCE_JOB_MB=4096 "$RP" --jobs 8
want_err="resource-profile: clamped jobs 8 -> 1 (auto: MemAvailable 3100 MB / 4096 MB per job)"
[ "$rc" = 0 ] && [ "$(out)" = "1" ] && [ "$(err)" = "$want_err" ] \
  && ok "auto memory: 3100 MB / 4096 MB floors at 1" || bad "auto mem 3100/4096: rc=$rc out=$(out) err=$(err)"

run env SYG_RESOURCE_PROFILE=auto SYG_MEM_GATE_MEMINFO="$tmp/mem64000" "$RP" --jobs 4
[ "$rc" = 0 ] && [ "$(out)" = "4" ] && [ ! -s "$tmp/err" ] \
  && ok "auto memory: 64000 MB with --jobs 4 gives 4 (never raises, no clamp line)" || bad "auto mem 64000: rc=$rc out=$(out) err=$(err)"

# 5. auto CPU: PSI avg60 72.10 -> 1 (reason prints 72.10); 50.00 -> 1; 49.99 -> no CPU clamp; missing PSI -> memory only, cpu:na.
run env SYG_RESOURCE_PROFILE=auto SYG_RESOURCE_PSI_CPU="$tmp/psi-72" "$RP" --jobs 8
want_err="resource-profile: clamped jobs 8 -> 1 (auto: cpu some avg60 72.10 >= 50)"
[ "$rc" = 0 ] && [ "$(out)" = "1" ] && [ "$(err)" = "$want_err" ] \
  && ok "auto CPU: avg60 72.10 clamps to 1 with exact '72.10' in reason" || bad "auto cpu 72.10: rc=$rc out=$(out) err=$(err)"

run env SYG_RESOURCE_PROFILE=auto SYG_RESOURCE_PSI_CPU="$tmp/psi-50" "$RP" --jobs 8
want_err="resource-profile: clamped jobs 8 -> 1 (auto: cpu some avg60 50.00 >= 50)"
[ "$rc" = 0 ] && [ "$(out)" = "1" ] && [ "$(err)" = "$want_err" ] \
  && ok "auto CPU: avg60 50.00 boundary clamps to 1" || bad "auto cpu 50.00: rc=$rc out=$(out) err=$(err)"

run env SYG_RESOURCE_PROFILE=auto SYG_RESOURCE_PSI_CPU="$tmp/psi-49" "$RP" --jobs 8
want_err="resource-profile: clamped jobs 8 -> 3 (auto: MemAvailable 3100 MB / 1024 MB per job)"
[ "$rc" = 0 ] && [ "$(out)" = "3" ] && [ "$(err)" = "$want_err" ] \
  && ok "auto CPU: avg60 49.99 does not trigger CPU clamp (memory ceiling 3 applies)" || bad "auto cpu 49.99: rc=$rc out=$(out) err=$(err)"

run env SYG_RESOURCE_PROFILE=auto SYG_RESOURCE_PSI_CPU="$tmp/no-such-psi" OMP_NUM_THREADS=8 "$RP"
[ "$rc" = 0 ] && [ "$(out)" = "profile=low ceiling=3 source=env auto=mem:3100MB,cpu:na" ] && [ ! -s "$tmp/err" ] \
  && ok "auto CPU: missing PSI file uses memory only and reports cpu:na" || bad "auto missing psi: rc=$rc out=$(out) err=$(err)"

# 6. tie: auto with CPU pressure (-> 1) plus SYG_MAX_PARALLEL=1 -> reason names SYG_MAX_PARALLEL=1.
run env SYG_RESOURCE_PROFILE=auto SYG_RESOURCE_PSI_CPU="$tmp/psi-72" SYG_MAX_PARALLEL=1 "$RP" --jobs 8
want_err="resource-profile: clamped jobs 8 -> 1 (SYG_MAX_PARALLEL=1)"
[ "$rc" = 0 ] && [ "$(out)" = "1" ] && [ "$(err)" = "$want_err" ] \
  && ok "tie: auto CPU pressure (1) + SYG_MAX_PARALLEL=1 names SYG_MAX_PARALLEL=1" || bad "tie maxp vs cpu: rc=$rc out=$(out) err=$(err)"

# CPU (1) ties memory (500 MB / 1024 MB floors at 1): the CPU reason wins.
run env SYG_RESOURCE_PROFILE=auto SYG_RESOURCE_PSI_CPU="$tmp/psi-72" SYG_MEM_GATE_MEMINFO="$tmp/mem500" "$RP" --jobs 8
want_err="resource-profile: clamped jobs 8 -> 1 (auto: cpu some avg60 72.10 >= 50)"
[ "$rc" = 0 ] && [ "$(out)" = "1" ] && [ "$(err)" = "$want_err" ] \
  && ok "tie: auto CPU pressure (1) + memory ceiling 1 names the CPU reason" || bad "tie cpu vs mem: rc=$rc out=$(out) err=$(err)"

# 7. --profile: auto with ceiling below nproc prints low (OMP_NUM_THREADS forces nproc).
run env SYG_RESOURCE_PROFILE=auto OMP_NUM_THREADS=8 "$RP" --profile
[ "$rc" = 0 ] && [ "$(out)" = "low" ] && [ ! -s "$tmp/err" ] \
  && ok "--profile: auto with ceiling 3 < nproc 8 prints low" || bad "--profile low: rc=$rc out=$(out) err=$(err)"

run env SYG_RESOURCE_PROFILE=auto OMP_NUM_THREADS=2 "$RP" --profile
[ "$rc" = 0 ] && [ "$(out)" = "normal" ] && [ ! -s "$tmp/err" ] \
  && ok "--profile: auto with ceiling 3 >= nproc 2 prints normal" || bad "--profile normal: rc=$rc out=$(out) err=$(err)"

# 8. bad values: SYG_RESOURCE_PROFILE=fast warns and counts as unset; SYG_MAX_PARALLEL=0 and =x warn and are ignored.
run env SYG_RESOURCE_PROFILE=fast "$RP" --jobs 8
want_err="resource-profile: ignoring SYG_RESOURCE_PROFILE='fast' (expected low, normal or auto)"
[ "$rc" = 0 ] && [ "$(out)" = "8" ] && [ "$(err)" = "$want_err" ] \
  && ok "bad value: SYG_RESOURCE_PROFILE=fast warns and counts as unset" || bad "bad profile fast: rc=$rc out=$(out) err=$(err)"

for bad_mp in 0 x 18446744073709551617; do
  run env SYG_MAX_PARALLEL="$bad_mp" "$RP" --jobs 8
  want_err="resource-profile: ignoring SYG_MAX_PARALLEL='$bad_mp' (expected a positive integer)"
  [ "$rc" = 0 ] && [ "$(out)" = "8" ] && [ "$(err)" = "$want_err" ] \
    && ok "bad value: SYG_MAX_PARALLEL=$bad_mp warns and is ignored" || bad "bad SYG_MAX_PARALLEL=$bad_mp: rc=$rc out=$(out) err=$(err)"
done

# 9. usage: --jobs 0, --jobs x, --bogus exit 2; --help exits 0.
for bad_args in "--jobs 0" "--jobs x" "--jobs 99999999999999999999" "--bogus"; do
  # shellcheck disable=SC2086 # intentional word splitting of flag + arg pair
  run "$RP" $bad_args
  [ "$rc" = 2 ] && [ -s "$tmp/err" ] \
    && ok "usage: '$bad_args' exits 2" || bad "usage '$bad_args': rc=$rc out=$(out) err=$(err)"
done

run "$RP" --help
[ "$rc" = 0 ] && grep -q "resource-profile --jobs N" "$tmp/out" && [ ! -s "$tmp/err" ] \
  && ok "usage: --help exits 0 with usage on stdout" || bad "usage --help: rc=$rc out=$(out) err=$(err)"

# 10. config: user config applies (source=config), project file is refused with host-knob warnings, env wins over user config.
U_CFG="$tmp/xdg-cfg"
P_CFG="$tmp/proj-cfg"
mkdir -p "$U_CFG/seyag" "$P_CFG/.claude"
printf 'syg_resource_profile = "low"\n' > "$U_CFG/seyag/config.toml"

run env -u SYG_CONFIG XDG_CONFIG_HOME="$U_CFG" CLAUDE_PROJECT_DIR="$tmp/proj-empty" "$RP"
[ "$rc" = 0 ] && [ "$(out)" = "profile=low ceiling=1 source=config" ] && [ ! -s "$tmp/err" ] \
  && ok "config: user config syg_resource_profile = \"low\" gives ceiling=1 source=config" || bad "user config bare: rc=$rc out=$(out) err=$(err)"

cat > "$P_CFG/.claude/seyag.toml" <<'EOF'
syg_resource_profile = "normal"
[syg]
max_parallel = 9
EOF

run env -u SYG_CONFIG XDG_CONFIG_HOME="$U_CFG" CLAUDE_PROJECT_DIR="$P_CFG" "$RP"
want_err=$(printf '%s\n%s' \
  "seyag config: $P_CFG/.claude/seyag.toml: line 1: 'SYG_RESOURCE_PROFILE' cannot be set from project scope (host knob)" \
  "seyag config: $P_CFG/.claude/seyag.toml: line 3: 'SYG_MAX_PARALLEL' cannot be set from project scope (host knob)")
[ "$rc" = 0 ] && [ "$(out)" = "profile=low ceiling=1 source=config" ] && [ "$(err)" = "$want_err" ] \
  && ok "config: project file host knobs refused with exact warnings and user's low still applies" || bad "project config refusal: rc=$rc out=$(out) err=$(err)"

run env -u SYG_CONFIG SYG_RESOURCE_PROFILE=normal XDG_CONFIG_HOME="$U_CFG" CLAUDE_PROJECT_DIR="$tmp/proj-empty" "$RP"
[ "$rc" = 0 ] && [ "$(out)" = "profile=normal ceiling=none source=env" ] && [ ! -s "$tmp/err" ] \
  && ok "config: env SYG_RESOURCE_PROFILE=normal wins over user config low (source=env)" || bad "env over user config: rc=$rc out=$(out) err=$(err)"

echo "resource-profile probe: $pass passed, $fail failed"
[ "$fail" = 0 ]
