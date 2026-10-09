#!/bin/bash
# Fixture check for bin/keys against a mock systemd-creds: no TPM, no real store.
# Usage: tests/keys.probe.sh   (from anywhere)

set -uo pipefail
K="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/plugins/seyag/bin/keys"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

# The mock "encrypts" to a header line plus the plaintext. It logs each call's argv
# with every element bracketed, then whether its stdin was /dev/null.
# MOCK_MODE: fail (rc 1, a TPM error), sleep (outlives the timeout), slow (0.5 s per
# call, then works), corrupt (the encrypted file decrypts to something else).
MOCK="$T/mock-creds"
cat > "$MOCK" <<'EOF'
#!/bin/bash
{ printf '[%s]' "$@"; [ "$(readlink /proc/self/fd/0)" = /dev/null ] && echo ' stdin=null' || echo ' stdin=pipe'; } >> "$MOCK_LOG"
case "${MOCK_MODE:-}" in
  fail) echo "TPM2 not available" >&2; exit 1 ;;
  sleep) exec sleep 5 ;;
  slow) sleep 0.5 ;;
esac
name=; for a in "$@"; do case "$a" in --name=*) name=${a#--name=} ;; esac; done
case "$1" in
  encrypt)
    dest=${*: -1}
    { echo "mock-cred:$name"; cat; if [ "${MOCK_MODE:-}" = corrupt ]; then echo extra; fi; } > "$dest" ;;
  decrypt)
    src=${*: -2:1}
    [ "$(head -n 1 "$src")" = "mock-cred:$name" ] || { echo "wrong credential name" >&2; exit 1; }
    tail -n +2 "$src" ;;
  *) echo "mock: unknown verb $1" >&2; exit 2 ;;
esac
EOF
chmod +x "$MOCK"

LOG="$T/creds.log"; : > "$LOG"
S="$T/store/keys.cred"
run() { env -i HOME="$T/home" PATH=/usr/bin:/bin XDG_RUNTIME_DIR="$T/run" \
  SYG_KEYS_STORE="$S" SYG_KEYS_CREDS_CMD="$MOCK" MOCK_LOG="$LOG" "$@"; }

# --- usage ---
h=$(run "$K" --help); rc=$?
[ $rc = 0 ] && grep -qF 'keys set NAME          prompts; input is hidden' <<<"$h" \
  && grep -qF 'SYG_KEYS_LEGACY_FILE' <<<"$h" && ok "--help prints the usage block" || bad "--help (rc $rc)"
run "$K" >/dev/null 2>&1; rc=$?
[ $rc = 2 ] && ok "no verb -> exit 2" || bad "no verb rc $rc"
e=$(run "$K" get lower_name 2>&1 >/dev/null); rc=$?
[ $rc = 2 ] && grep -qF 'NAME must match ^[A-Z][A-Z0-9_]*$' <<<"$e" && grep -qF 'got 10 characters' <<<"$e" && ! grep -qF lower_name <<<"$e" \
  && ok "a lowercase NAME is a usage error that reports its length, not the NAME" || bad "bad name rc $rc: $e"
o=$(run SYG_KEYS_STORE="$T/none/keys.cred" "$K" names 2>"$T/err"); rc=$?
[ $rc = 0 ] && [ -z "$o" ] && [ "$(cat "$T/err")" = "keys: no store at $T/none/keys.cred yet" ] \
  && ok "names with no store -> exit 0, the no-store message on stderr" || bad "names no store rc $rc out '$o': $(cat "$T/err")"

# --- set ---
o=$(printf '  fixture-key-value-1\r\n' | run "$K" set ALPHA_KEY); rc=$?
[ $rc = 0 ] && [ "$o" = "Stored ALPHA_KEY (19 characters) in $S; it now holds: ALPHA_KEY" ] \
  && ok "set from a pipe strips CR/LF and surrounding spaces" || bad "set rc $rc: $o"
[ "$(tail -n +2 "$S")" = "ALPHA_KEY=fixture-key-value-1" ] && ok "the store holds NAME=value" || bad "store content"
[ "$(stat -c %a "$S")" = 600 ] && [ "$(stat -c %a "$T/store")" = 700 ] && ok "store 0600 in a 0700 dir" \
  || bad "modes $(stat -c %a "$S") $(stat -c %a "$T/store")"
enc=$(grep '^\[encrypt\]' "$LOG")
grep -qF '[--tpm2-pcrs=]' <<<"$enc" && ok "encrypt passes --tpm2-pcrs= with an empty value (not PCR-bound)" || bad "pcrs: $enc"
grep -qF '[--with-key=host+tpm2]' <<<"$enc" && grep -qF '[--name=keys]' <<<"$enc" && grep -qF '[--user]' <<<"$enc" \
  && ok "encrypt passes --with-key=host+tpm2 --name=keys --user" || bad "encrypt argv: $enc"
grep -q '^\[decrypt\]\[--user\]\[--name=keys\]\[.*\]\[-\] stdin=null$' "$LOG" \
  && ok "the verify decrypt runs with stdin on /dev/null" || bad "decrypt argv/stdin: $(grep decrypt "$LOG")"

printf 'fixture-key-value-2' | run "$K" set BETA_KEY >/dev/null || bad "set BETA_KEY"
f=$(LC_ALL=C ls -A "$T/store" | tr '\n' ' ')
[ "$f" = ".keys.cred.lock keys.cred " ] && [ "$(stat -c %a "$T/store/.keys.cred.lock")" = 600 ] \
  && ok "two names, one .cred file beside its 0600 lock, no temp left behind" || bad "store dir holds: $f"
printf 'fixture-key-value-3\n' | run "$K" set ALPHA_KEY >/dev/null || bad "replace ALPHA_KEY"
[ "$(run "$K" names)" = "$(printf 'BETA_KEY\nALPHA_KEY')" ] && ok "replacing a NAME keeps its siblings" || bad "names: $(run "$K" names)"
[ "$(run "$K" get ALPHA_KEY; echo .)" = "$(printf 'fixture-key-value-3\n.')" ] && [ "$(run "$K" get BETA_KEY)" = fixture-key-value-2 ] \
  && ok "get prints exactly the replaced value plus one newline, and the sibling's" || bad "get after replace"
printf 'fixture=with=equals' | run "$K" set GAMMA_KEY >/dev/null
[ "$(run "$K" get GAMMA_KEY)" = fixture=with=equals ] && ok "a value containing = round-trips (first-= split)" || bad "equals value"

sum=$(md5sum "$S")
e=$(run "$K" set DELTA_KEY </dev/null 2>&1); rc=$?
[ $rc = 1 ] && grep -qF 'no value given for DELTA_KEY; nothing stored' <<<"$e" && [ "$(md5sum "$S")" = "$sum" ] \
  && ok "an empty value is an error and stores nothing" || bad "empty value rc $rc: $e"
e=$(printf 'fix\xffture' | run "$K" set DELTA_KEY 2>&1); rc=$?
[ $rc = 1 ] && [ "$e" = "keys: the value for DELTA_KEY is not UTF-8 text; nothing stored" ] && [ "$(md5sum "$S")" = "$sum" ] \
  && ok "a non-UTF-8 value -> exit 1, one clean line, store unchanged" || bad "non-utf8 rc $rc: $e"
e=$(run "$K" set DELTA_KEY <&- 2>&1); rc=$?
[ $rc = 1 ] && [ "$e" = "keys: no value given for DELTA_KEY (stdin is closed); nothing stored" ] && [ "$(md5sum "$S")" = "$sum" ] \
  && ok "a closed stdin -> exit 1, one clean line, store unchanged" || bad "closed stdin rc $rc: $e"
printf 'fixture\tkey with  spaces \n' | run "$K" set THETA_KEY >/dev/null || bad "set THETA_KEY"
[ "$(run "$K" get THETA_KEY; echo .)" = "$(printf 'fixturekey with  spaces\n.')" ] \
  && ok "tabs are removed and interior spaces kept" || bad "tab/space value: $(run "$K" get THETA_KEY | od -c)"
run "$K" delete THETA_KEY >/dev/null || bad "delete THETA_KEY"

# --- get: env > store > legacy ---
L="$T/legacy.env"
printf '# a comment line\nALPHA_KEY=fixture-legacy-alpha\nDELTA_KEY=fixture-legacy-delta\n' > "$L"
[ "$(run ALPHA_KEY=fixture-env-alpha SYG_KEYS_LEGACY_FILE="$L" "$K" get ALPHA_KEY)" = fixture-env-alpha ] \
  && ok "the env var beats the store and the legacy file" || bad "env first"
[ "$(run SYG_KEYS_LEGACY_FILE="$L" "$K" get ALPHA_KEY)" = fixture-key-value-3 ] && ok "the store beats the legacy file" || bad "store second"
[ "$(run ALPHA_KEY= SYG_KEYS_LEGACY_FILE="$L" "$K" get ALPHA_KEY)" = fixture-key-value-3 ] && ok "an empty env var counts as unset" || bad "empty env"
[ "$(run SYG_KEYS_LEGACY_FILE="$L" "$K" get DELTA_KEY)" = fixture-legacy-delta ] && ok "a NAME not stored falls to the legacy file" || bad "legacy third"
lines=$(wc -l < "$LOG")
[ "$(run SYG_KEYS_STORE="$T/none/keys.cred" SYG_KEYS_CREDS_CMD="$T/no-such-creds" SYG_KEYS_LEGACY_FILE="$L" "$K" get ALPHA_KEY)" = fixture-legacy-alpha ] \
  && [ "$(wc -l < "$LOG")" = "$lines" ] && ok "with no store, the legacy file is read without systemd-creds" || bad "legacy without creds"
[ "$(md5sum < "$L")" = "$(printf '# a comment line\nALPHA_KEY=fixture-legacy-alpha\nDELTA_KEY=fixture-legacy-delta\n' | md5sum)" ] \
  && ok "the legacy file is left untouched" || bad "legacy file changed"

o=$(run SYG_KEYS_LEGACY_FILE="$L" "$K" get EPSILON_KEY 2>"$T/err"); rc=$?
[ $rc = 1 ] && [ -z "$o" ] && [ "$(cat "$T/err")" = "keys: EPSILON_KEY is not set (no env var, no stored key, no legacy file)" ] \
  && ok "a NAME found nowhere -> exit 1, the not-set message, empty stdout" || bad "missing rc $rc out '$o': $(cat "$T/err")"

# --- delete ---
o=$(run "$K" delete GAMMA_KEY); rc=$?
[ $rc = 0 ] && [ "$o" = "Deleted GAMMA_KEY from $S" ] && [ "$(run "$K" names)" = "$(printf 'BETA_KEY\nALPHA_KEY')" ] \
  && ok "delete removes one NAME and keeps the rest" || bad "delete rc $rc: $o"
e=$(run "$K" delete GAMMA_KEY 2>&1); rc=$?
[ $rc = 1 ] && grep -qF "GAMMA_KEY is not stored in $S; nothing deleted" <<<"$e" && ok "deleting a missing NAME -> exit 1" || bad "delete missing rc $rc: $e"
run "$K" delete ALPHA_KEY >/dev/null
[ "$(run SYG_KEYS_LEGACY_FILE="$L" "$K" get ALPHA_KEY)" = fixture-legacy-alpha ] && ok "a NAME deleted from the store falls to the legacy file" || bad "legacy after delete"

# --- malformed store lines are skipped and never printed ---
printf 'mock-cred:keys\nfixture-malformed-no-equals\nlower=fixture-lower\n\nBETA_KEY=fixture-key-value-2\n' > "$S"
o=$(run "$K" names 2>&1)
[ "$o" = BETA_KEY ] && ok "names skips blank and malformed lines without printing them" || bad "malformed names: $o"
o=$(run "$K" get lower 2>&1); [ $? = 2 ] && ! grep -q fixture-lower <<<"$o" && ok "get refuses a malformed NAME and never prints its stored value" || bad "lower get: $o"

# --- failures are loud ---
sum=$(md5sum "$S")
o=$(run MOCK_MODE=fail "$K" get BETA_KEY 2>"$T/err"); rc=$?
[ $rc = 1 ] && [ -z "$o" ] && grep -qF 'systemd-creds decrypt of '"$S"' failed (exit 1): TPM2 not available' "$T/err" \
  && ok "TPM unavailable: get exits 1 with the creds error and empty stdout" || bad "tpm fail rc $rc out '$o': $(cat "$T/err")"
DECRYPT_HINT='Likely causes: SYG_KEYS_NAME differs from the name used when it was encrypted, the TPM is unavailable or was reset, or the file was written by another user or machine.'
o=$(run MOCK_MODE=fail SYG_KEYS_LEGACY_FILE="$L" "$K" get ALPHA_KEY 2>"$T/err"); rc=$?
[ $rc = 1 ] && [ -z "$o" ] && grep -qF 'systemd-creds decrypt of '"$S"' failed (exit 1): TPM2 not available' "$T/err" \
  && ok "a failed decrypt never falls through to the legacy file (exit 1, empty stdout)" || bad "legacy fallthrough rc $rc out '$o': $(cat "$T/err")"
e=$(run SYG_KEYS_NAME=other-cred "$K" get BETA_KEY 2>&1); rc=$?
[ $rc = 1 ] && grep -qF "failed (exit 1): wrong credential name. $DECRYPT_HINT" <<<"$e" && ! grep -qF SYG_KEYS_WITH_KEY <<<"$e" \
  && ok "a decrypt failure names its likely causes, without the encrypt hint" || bad "decrypt hint rc $rc: $e"
e=$(printf 'fixture-key-value-4' | run MOCK_MODE=fail SYG_KEYS_STORE="$T/encfail/keys.cred" "$K" set BETA_KEY 2>&1); rc=$?
[ $rc = 1 ] && grep -qF "failed (exit 1): TPM2 not available. Without a TPM, set SYG_KEYS_WITH_KEY=host and re-store the keys." <<<"$e" \
  && ! grep -qF 'Likely causes' <<<"$e" && [ ! -e "$T/encfail/keys.cred" ] \
  && ok "an encrypt failure gives the SYG_KEYS_WITH_KEY hint and stores nothing" || bad "encrypt hint rc $rc: $e"
printf 'fixture-key-value-4' | run MOCK_MODE=fail "$K" set BETA_KEY >/dev/null 2>&1; rc=$?
[ $rc = 1 ] && [ "$(md5sum "$S")" = "$sum" ] && ok "TPM unavailable: set exits 1 and stores nothing" || bad "tpm fail set rc $rc"
e=$(printf 'fixture-key-value-4' | run MOCK_MODE=corrupt "$K" set BETA_KEY 2>&1); rc=$?
[ $rc = 1 ] && grep -qF 'the new keys.cred did not decrypt back to the same content; nothing stored' <<<"$e" \
  && [ "$(md5sum "$S")" = "$sum" ] && [ "$(LC_ALL=C ls -A "$T/store" | tr '\n' ' ')" = ".keys.cred.lock keys.cred " ] \
  && ok "a store that doesn't verify is not swapped in, and its temp file is removed" || bad "corrupt rc $rc: $e"
e=$(run SYG_KEYS_CREDS_CMD="$T/no-such-creds" "$K" get BETA_KEY 2>&1); rc=$?
[ $rc = 1 ] && grep -qF 'not found: keys needs systemd-creds' <<<"$e" && ok "a missing systemd-creds is named" || bad "no creds rc $rc: $e"

# --- the stall marker and the lock ---
M="$T/run/seyag-keys/tpm-stalled"
e=$(run MOCK_MODE=sleep SYG_KEYS_TIMEOUT_S=1 "$K" get BETA_KEY 2>&1); rc=$?
[ $rc = 1 ] && grep -qF 'timed out after 1 s' <<<"$e" && [ -e "$M" ] && ok "a timeout fails loudly and leaves the stall marker" || bad "timeout rc $rc: $e"
lines=$(wc -l < "$LOG")
e=$(run "$K" get BETA_KEY 2>&1); rc=$?
[ $rc = 1 ] && grep -qF 'the TPM is busy or stuck' <<<"$e" && [ "$(wc -l < "$LOG")" = "$lines" ] \
  && ok "while the marker stands, calls fail fast without touching the TPM" || bad "stalled rc $rc: $e"
o=$(run SYG_KEYS_STALL_S=30 SYG_KEYS_LEGACY_FILE="$L" "$K" get ALPHA_KEY 2>"$T/err"); rc=$?
[ $rc = 1 ] && [ -z "$o" ] && grep -qF 'the TPM is busy or stuck' "$T/err" \
  && ok "while the marker stands, get never falls through to the legacy file" || bad "stalled legacy rc $rc out '$o': $(cat "$T/err")"
[ "$(run SYG_KEYS_STALL_S=0 "$K" get BETA_KEY)" = fixture-key-value-2 ] && [ ! -e "$M" ] \
  && ok "after the stall window, a good decrypt clears the marker" || bad "stall expiry"
( flock "$T/run/seyag-keys/tpm.lock" sh -c "touch '$T/held'; sleep 2" ) &
for _ in $(seq 50); do [ -e "$T/held" ] && break; sleep 0.1; done
e=$(run SYG_KEYS_LOCK_WAIT_S=0.3 "$K" get BETA_KEY 2>&1); rc=$?
[ $rc = 1 ] && grep -qF 'the TPM is busy or stuck' <<<"$e" && ok "a held lock past the wait fails loudly" || bad "lock rc $rc: $e"
wait
e=$(timeout 5 env -i HOME="$T/home" PATH=/usr/bin:/bin XDG_RUNTIME_DIR="$T/run" SYG_KEYS_STORE="$S" \
  SYG_KEYS_CREDS_CMD="$MOCK" MOCK_LOG="$LOG" SYG_KEYS_LOCK_WAIT_S=nan "$K" get BETA_KEY 2>&1); rc=$?
[ $rc = 2 ] && [ "$e" = "keys: SYG_KEYS_LOCK_WAIT_S='nan' is not a finite, non-negative number of seconds (keys --help for usage)" ] \
  && ok "a non-finite lock wait is a usage error, not a hang" || bad "nan wait rc $rc: $e"

# --- the lock dirs resist tampering ---
mkdir -p "$T/run2/seyag-keys"; chmod 700 "$T/run2/seyag-keys"; echo fixture-victim > "$T/victim"
ln -s "$T/victim" "$T/run2/seyag-keys/tpm.lock"
o=$(run XDG_RUNTIME_DIR="$T/run2" "$K" get BETA_KEY 2>"$T/err"); rc=$?
[ $rc = 1 ] && [ -z "$o" ] && grep -qF "cannot open the TPM lock in $T/run2/seyag-keys" "$T/err" && [ "$(cat "$T/victim")" = fixture-victim ] \
  && ok "a symlinked tpm.lock is refused and its target left untouched" || bad "symlinked lock rc $rc, victim '$(cat "$T/victim")': $(cat "$T/err")"
mkdir -p "$T/run3/seyag-keys"; chmod 777 "$T/run3/seyag-keys"
e=$(run XDG_RUNTIME_DIR="$T/run3" "$K" get BETA_KEY 2>&1); rc=$?
[ $rc = 1 ] && grep -qF "refusing the TPM lock dir $T/run3/seyag-keys" <<<"$e" \
  && ok "a group/world-accessible TPM lock dir is refused" || bad "open lock dir rc $rc: $e"

# --- two writers with different runtime dirs keep both keys ---
R="$T/race/keys.cred"; mkdir -m 777 "$T/race"
printf 'fixture-race-a' | run MOCK_MODE=slow SYG_KEYS_STORE="$R" XDG_RUNTIME_DIR="$T/r1" "$K" set AAA_KEY >"$T/race-a" 2>&1 &
pa=$!
sleep 0.2
printf 'fixture-race-b' | run MOCK_MODE=slow SYG_KEYS_STORE="$R" XDG_RUNTIME_DIR="$T/r2" "$K" set BBB_KEY >"$T/race-b" 2>&1 &
pb=$!
wait $pa; ra=$?; wait $pb; rb=$?
names=$(run SYG_KEYS_STORE="$R" "$K" names | sort | tr '\n' ' ')
[ $ra = 0 ] && [ $rb = 0 ] && [ "$names" = "AAA_KEY BBB_KEY " ] && [ "$(stat -c %a "$T/race")" = 700 ] \
  && ok "two concurrent sets with different runtime dirs both land, and the store dir is tightened to 0700" \
  || bad "race rc $ra/$rb names '$names' dir $(stat -c %a "$T/race"): $(cat "$T/race-a" "$T/race-b")"

# --- configuration ---
CLOG="$T/config.log"; : > "$CLOG"
printf 'fixture-key-value-5' | env -i HOME="$T/home" PATH=/usr/bin:/bin XDG_RUNTIME_DIR="$T/run" \
  SYG_KEYS_CREDS_CMD="$MOCK" MOCK_LOG="$CLOG" SYG_KEYS_WITH_KEY=host SYG_KEYS_NAME=fixture-cred "$K" set ZETA_KEY >/dev/null
D="$T/home/.local/share/keys/keys.cred"
[ -f "$D" ] && [ "$(stat -c %a "$(dirname "$D")")" = 700 ] && ok "the default store is ~/.local/share/keys/keys.cred" || bad "default store"
grep -qF '[--with-key=host]' "$CLOG" && grep -qF '[--name=fixture-cred]' "$CLOG" \
  && ok "SYG_KEYS_WITH_KEY and SYG_KEYS_NAME reach systemd-creds" || bad "config argv: $(cat "$CLOG")"

# --- over every call above: set, get, names and delete alike ---
grep -qE '[A-Z]+_KEY|fixture-(key|legacy|race|victim)' "$LOG" "$CLOG" && bad "a key NAME or value reached systemd-creds argv: $(grep -hE '[A-Z]+_KEY|fixture-(key|legacy|race|victim)' "$LOG" "$CLOG" | head -n 3)" \
  || ok "no key NAME or value in any systemd-creds argv, over the whole run"

exit $fail
