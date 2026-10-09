#!/bin/bash
# Fixture check for plugins/seyag/bin/price-table — the managed modelPricing
# table generator. Covers: --emit shape (row count, four fields per row, in
# range, positive-control keys and rates), --merge (foreign keys survive,
# modelPricing replaced; unreadable/unparseable managed file fails loudly),
# --audit (default 30d window; covered ids not flagged; uncovered flagged with
# its file; <synthetic> markers skipped; garbage/naive timestamps never hide an
# id; --since both directions), --sync (4-field drift against a fixture OR
# models JSON incl. a cacheWrite drift and a :nitro alias resolution; no
# write; clean failure on a dead URL), --apply (the ! sudo install -D line
# printed, merged content in the tmpfile, no sudo run).
# Hermetic: fixture managed files, fixture projects dir and fixture models URL
# (file:// via PRICE_TABLE_MODELS_URL); no network, no real caches, no sudo.
# Timestamps are relative to now, so no fixture ever goes stale.
# Usage: tests/price-table.probe.sh

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PT="$REPO/plugins/seyag/bin/price-table"
[ -f "$PT" ] || { echo "price-table.probe: no price-table at $PT"; exit 2; }
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/proj/subagents" "$T/proj2" "$T/home/.claude"

recent=$(date -u -d '-1 day' +%Y-%m-%dT%H:%M:%SZ)
old=$(date -u -d '-60 days' +%Y-%m-%dT%H:%M:%SZ)
naive=$(date -u -d '-1 day' +%Y-%m-%dT%H:%M:%S)   # no offset: naive timestamp

# --emit: shape of the candidate
emit=$("$PT" --emit)
if python3 - "$emit" <<'PY'
import json, sys
o = json.loads(sys.argv[1])["modelPricing"]["overrides"]
rows = list(o.items())
assert len(rows) == 34, f"row count {len(rows)}"
for k, v in rows:
    assert set(v) == {"input", "output", "cacheRead", "cacheWrite"}, f"{k}: fields {sorted(v)}"
    assert all(isinstance(v[f], (int, float)) and 0 <= v[f] <= 10000 for f in v), f"{k}: {v}"
assert "~z-ai/glm-flash-latest:nitro" in o, "nitro key missing"
assert "~z-ai/glm-flash-latest" in o, "bare alias key missing"
assert "glm-5.3-flash[1m]" in o, "bracket-suffix key missing"
assert "google/gemini-3.1-flash-lite" in o, "gemini-lite key missing"
# corrected rates (the table's current OR values) pinned
assert o["~z-ai/glm-flash-latest"]["output"] == 0.083071, "alias output not the live rate"
assert o["~z-ai/glm-flash-latest:nitro"]["output"] == 0.083071, "nitro output not the live rate"
assert o["z-ai/glm-5.3"]["output"] == 6.00, "glm-5.3 output not the live rate"
assert o["~z-ai/glm-latest"]["output"] == 6.00, "glm-latest output not the live rate"
assert o["~openai/gpt-astra-latest"]["cacheWrite"] == 12.5, "astra cacheWrite"
assert o["~openai/gpt-sol-latest"]["cacheWrite"] == 2.5, "sol cacheWrite"
assert o["~openai/gpt-luna-latest"]["cacheWrite"] == 0.125, "luna cacheWrite"
assert o["~google/gemini-pro-latest"]["cacheWrite"] == 0.375, "gemini-pro cacheWrite"
assert o["~google/gemini-flash-latest"]["cacheWrite"] == 0.0416666666666667, "gemini-flash cacheWrite"
assert o["google/gemini-3.1-flash-lite"]["cacheWrite"] == 0.0833333333333333, "gemini-lite cacheWrite"
assert o["~anthropic/claude-fable-latest"]["cacheWrite"] == 12.5, "anthropic alias cacheWrite changed"
PY
then ok "--emit: 34 rows, four fields each in range, positive-control keys + corrected rates"
else bad "--emit: candidate shape"; fi
if echo "$emit" | python3 -c '
import json,sys
o=json.load(sys.stdin)["modelPricing"]["overrides"]
assert list(o)==sorted(o), "keys not sorted"
assert all(isinstance(x,(int,float)) for r in o.values() for x in r.values()), "string values"
'; then ok "--emit: keys sorted, numeric values"; else bad "--emit: sort/values"; fi

# --json: machine-readable shape
if python3 - "$PT" <<'PY'
import json, subprocess, sys
o = json.loads(subprocess.run([sys.argv[1], "--json"], capture_output=True, text=True).stdout)
assert set(o) == {"table", "or_keys"}, f"keys {sorted(o)}"
assert len(o["table"]) == 34, "row count"
assert len(o["or_keys"]) == 18, f"or_keys count {len(o['or_keys'])}"
assert "~z-ai/glm-flash-latest:nitro" in o["or_keys"], "nitro not an or_key"
assert "glm-5.3-flash" not in o["or_keys"], "z.ai-direct key is not an or_key"
PY
then ok "--json: table + or_keys, 34 rows, 18 OR keys"; else bad "--json: shape"; fi
"$PT" --json | jq -e '.table["claude-haiku-5-5"] == {input:0.1,output:0.5,cacheRead:0.01,cacheWrite:0.125}' >/dev/null \
  && ok "--json: claude-haiku-5-5 priced (0.1 / 0.5 / 0.01 / 0.125)" || bad "--json: claude-haiku-5-5 row"
"$PT" --json | jq -e '.table["google/gemini-3.8-flash"].input == 0.75 and .table["google/gemini-3.1-pro-preview"] == {input:2,output:12,cacheRead:0.2,cacheWrite:0.375}
    and (.or_keys | index("google/gemini-3.8-flash")) != null and (.or_keys | index("google/gemini-3.1-pro-preview")) != null' >/dev/null \
  && ok "--json: gemini-3.8-flash and gemini-3.1-pro-preview priced and OR-checked" || bad "--json: new gemini rows"

# --merge: foreign key survives, modelPricing replaced wholesale
mg="$T/managed.json"
printf '%s' '{"permissions":{"deny":["Bash(rm)"]},"modelPricing":{"overrides":{"stale":{"input":1,"output":1,"cacheRead":1,"cacheWrite":1}}}}' > "$mg"
if PRICE_TABLE_MANAGED_FILE="$mg" "$PT" --merge > "$T/merged.json" \
   && python3 - "$T/merged.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
assert m["permissions"] == {"deny": ["Bash(rm)"]}, "foreign key lost"
assert "stale" not in m["modelPricing"]["overrides"], "stale row survived"
assert len(m["modelPricing"]["overrides"]) == 34, "merge did not replace wholesale"
PY
then ok "--merge: foreign key kept, stale modelPricing replaced wholesale"; else bad "--merge"; fi
if PRICE_TABLE_MANAGED_FILE="$T/absent.json" "$PT" --merge | python3 -c '
import json,sys
m=json.load(sys.stdin)
assert list(m)==["modelPricing"], "missing-file merge printed extra keys"
'; then ok "--merge: missing managed file -> bare modelPricing candidate"; else bad "--merge: missing file"; fi

# S1: unreadable and unparseable managed files fail loudly, never silently {}
printf 'not json at all' > "$T/bad.json"
printf '[1,2]' > "$T/list.json"
printf 'x' > "$T/noperm.json"
chmod 000 "$T/noperm.json" 2>/dev/null
for f in bad list; do
    if PRICE_TABLE_MANAGED_FILE="$T/$f.json" "$PT" --merge > "$T/out" 2>&1; then
        bad "--merge: invalid JSON ($f) did not fail"
    elif grep -q 'Traceback' "$T/out" || ! grep -q '^price-table:' "$T/out"; then
        bad "--merge: invalid JSON ($f) not a clean one-line error: $(cat "$T/out")"
    else
        ok "--merge: invalid JSON ($f) fails loudly and cleanly"
    fi
done
# Skip when chmod doesn't stick (root, or a filesystem that ignores it): the
# file is then readable and the assertion would false-FAIL.
if cat "$T/noperm.json" >/dev/null 2>&1; then
    ok "--merge: unreadable managed file skipped (chmod 000 does not stick here)"
elif PRICE_TABLE_MANAGED_FILE="$T/noperm.json" "$PT" --merge > "$T/out" 2>&1; then
    bad "--merge: unreadable managed file did not fail"
elif grep -q 'Traceback' "$T/out" || ! grep -q '^price-table:' "$T/out"; then
    bad "--merge: unreadable file not a clean one-line error: $(cat "$T/out")"
else
    ok "--merge: unreadable managed file fails loudly and cleanly"
fi
chmod 600 "$T/noperm.json" 2>/dev/null || true

# --audit: fixture corpus, timestamps relative to now.
# main: covered ids only. subagent: an uncovered id (recent), a <synthetic>
# marker, and an uncovered id on a garbage-timestamp line. extra: an uncovered
# id with a naive timestamp. proj2: an uncovered id 60 days back.
printf '%s\n' \
  "{\"type\":\"assistant\",\"message\":{\"model\":\"glm-5.3-flash\"},\"timestamp\":\"$recent\"}" \
  "{\"type\":\"assistant\",\"message\":{\"model\":\"z-ai/glm-5.3-flash\"},\"timestamp\":\"$recent\"}" \
  "{\"type\":\"assistant\",\"message\":{\"model\":\"glm-5.3-flash[1m]\"},\"timestamp\":\"$recent\"}" \
  "{\"type\":\"assistant\",\"message\":{\"model\":\"~z-ai/glm-flash-latest:nitro\"},\"timestamp\":\"$recent\"}" \
  "{\"type\":\"assistant\",\"message\":{\"model\":\"claude-opus-4-8-20251001[1m]\"},\"timestamp\":\"$recent\"}" \
  > "$T/proj/main.jsonl"
printf '%s\n' \
  "{\"type\":\"assistant\",\"message\":{\"model\":\"brand-new-model\"},\"timestamp\":\"$recent\"}" \
  "{\"type\":\"assistant\",\"message\":{\"model\":\"<synthetic>\"},\"timestamp\":\"$recent\"}" \
  '{"type":"assistant","message":{"model":"also-uncovered"},"timestamp":"not-a-timestamp"}' \
  "{\"type\":\"assistant\",\"message\":{\"model\":\"claude-haiku-4-5-20251001\"},\"timestamp\":\"$recent\"}" \
  "{\"type\":\"assistant\",\"message\":{\"model\":\"z-ai/glm-5.3-flash-20260826\"},\"timestamp\":\"$recent\"}" \
  > "$T/proj/subagents/agent-1.jsonl"
printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"model\":\"naive-model\"},\"timestamp\":\"$naive\"}" \
  > "$T/proj/extra.jsonl"
printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"model\":\"old-model\"},\"timestamp\":\"$old\"}" \
  > "$T/proj2/main.jsonl"
mkdir -p "$T/proj/mined-corpus"
printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"model\":\"corpus-only-model\"},\"timestamp\":\"$recent\"}" \
  > "$T/proj/mined-corpus/c.jsonl"

# Default (30d) audit: the two recent uncovered ids and the naive-ts one
# flagged; old-model outside the default window NOT flagged (this line is the
# default-window pin); covered ids and the marker never flagged.
aout=$(CLAUDE_PROJECTS_DIR="$T" "$PT" --audit 2>&1); rc=$?
if [ "$rc" = 1 ]; then ok "--audit: exit 1 on uncovered ids (default window)"; else bad "--audit: exit $rc, want 1: $aout"; fi
for u in brand-new-model also-uncovered naive-model; do
    grep -q "uncovered: $u" <<<"$aout" && ok "--audit: $u flagged with its file" \
                                                 || bad "--audit: $u missing from: $aout"
done
grep -q 'subagents/agent-1.jsonl' <<<"$aout" && ok "--audit: file of the uncovered id named" || bad "--audit: file not named: $aout"
grep -q 'old-model' <<<"$aout" && bad "--audit: 60-day-old id outside the default 30d window still flagged: $aout" \
                                || ok "--audit: 60-day-old id outside the default window not flagged"
grep -q 'corpus-only-model' <<<"$aout" && bad "--audit: mined-corpus id flagged: $aout" \
                                       || ok "--audit: mined-corpus skipped"
grep -q '<synthetic>' <<<"$aout" && bad "--audit: marker id flagged: $aout" \
                                 || ok "--audit: <synthetic> marker id skipped"
grep -q 'claude-haiku-4-5-20251001' <<<"$aout" && bad "--audit: claude-* dated snapshot flagged (bare row covers it): $aout" \
                                               || ok "--audit: claude-* dated snapshot covered by its bare row"
grep -q 'claude-opus-4-8-20251001\[1m\]' <<<"$aout" && bad "--audit: combined dated+bracket form flagged (bracket then date strip): $aout" \
                                                 || ok "--audit: combined dated+bracket form covered (bracket then date strip)"
grep -q 'z-ai/glm-5.3-flash-20260826' <<<"$aout" && ok "--audit: OR permaslug flagged (no strip on non-claude ids)" \
                                                 || bad "--audit: OR permaslug not flagged: $aout"
grep -E 'uncovered: (glm-5\.3-flash|z-ai/glm-5\.3-flash|glm-5\.3-flash\[1m\]|~z-ai/glm-flash-latest:nitro)( |$)' <<<"$aout" \
  && bad "--audit: covered id flagged: $aout" \
  || ok "--audit: covered ids (bare, slug, [1m], nitro alias) not flagged"

# --since 90d: window mechanism in the other direction.
aout90=$(CLAUDE_PROJECTS_DIR="$T" "$PT" --audit --since 90d 2>&1); rc90=$?
if [ "$rc90" = 1 ] && grep -q 'uncovered: old-model' <<<"$aout90"; then
    ok "--audit --since 90d: old-model flagged inside the widened window"
else
    bad "--audit --since 90d: exit $rc90: $aout90"
fi
# --since 7d: recent ids still in, old out.
aout7=$(CLAUDE_PROJECTS_DIR="$T" "$PT" --audit --since 7d 2>&1); rc7=$?
if [ "$rc7" = 1 ]; then ok "--audit --since 7d: exit 1"; else bad "--audit --since 7d: exit $rc7"; fi
grep -q 'brand-new-model' <<<"$aout7" || bad "--audit --since 7d: brand-new-model lost: $aout7"
grep -q 'also-uncovered' <<<"$aout7" && ok "--audit --since 7d: garbage-timestamp entry not hidden by the window" \
                                     || bad "--audit --since 7d: garbage-timestamp id skipped: $aout7"
grep -q 'old-model' <<<"$aout7" && bad "--audit --since 7d: pre-window entry not filtered: $aout7" \
                                || ok "--audit --since 7d: pre-window entry filtered"
# B2: no projects dir -> clean error, not a traceback.
if CLAUDE_PROJECTS_DIR="$T/no-such-root" "$PT" --audit > "$T/out" 2>&1; then
    bad "--audit: missing projects dir did not fail"
elif grep -q 'Traceback' "$T/out" || ! grep -q '^price-table:' "$T/out"; then
    bad "--audit: missing projects dir not a clean error: $(cat "$T/out")"
else
    ok "--audit: missing projects dir fails with a clean one-line error"
fi

# --sync: fixture OR models JSON. z-ai/glm-5.3-flash output drifts (9.99);
# ~openai/gpt-luna-latest cacheWrite drifts (0.125 -> 0.225); ~z-ai alias rows
# carry the live 0.000000083071 completion (no drift); :nitro absent from the
# feed and resolved via its bare alias; the z-ai rows publish no cache-write
# field (their cacheWrite is never checked).
models="$T/models.json"
python3 - "$models" <<'PY'
import json, sys
rows = [
    ("z-ai/glm-5.3-flash", "0.00000015", "0.00000999", "0.00000003", None),
    ("z-ai/glm-5.3", "0.00000005", "0.000006", "0.000000049", None),
    ("~z-ai/glm-flash-latest", "0.000000032", "0.000000083071", "0.00000001", None),
    ("~z-ai/glm-latest", "0.00000005", "0.000006", "0.000000049", None),
    ("~anthropic/claude-fable-latest", "0.00001", "0.00005", "0.00000025", "0.0000125"),
    ("~openai/gpt-sol-latest", "0.000002", "0.00001", "0.0000001", "0.0000025"),
    ("~openai/gpt-luna-latest", "0.0000001", "0.0000005", "0.00000001", "0.000000225"),
    ("~google/gemini-flash-latest", "0.00000075", "0.00000375", "0.000000075", "0.0000000416666666666667"),
    ("google/gemini-3.1-flash-lite", "0.00000025", "0.0000015", "0.000000025", "0.0000000833333333333333"),
]
out = []
for mid, prompt, completion, cr, cw in rows:
    p = {"prompt": prompt, "completion": completion, "input_cache_read": cr}
    if cw is not None:
        p["input_cache_write"] = cw
    out.append({"id": mid, "pricing": p})
json.dump({"data": out}, open(sys.argv[1], "w"))
PY
before=$(find "$T" -type f | sort)
sout=$(PRICE_TABLE_MODELS_URL="file://$models" "$PT" --sync 2>&1); rc=$?
if [ "$rc" = 0 ]; then ok "--sync: exit 0"; else bad "--sync: exit $rc: $sout"; fi
grep -q 'z-ai/glm-5.3-flash output: table 0.5 -> live 9.99' <<<"$sout" \
  && ok "--sync: prompt-rate drift reported with table vs live" || bad "--sync: output drift report wrong: $sout"
grep -q '~openai/gpt-luna-latest cacheWrite: table 0.125 -> live 0.225' <<<"$sout" \
  && ok "--sync: cacheWrite drift checked and reported" || bad "--sync: cacheWrite drift missing: $sout"
grep -q '10 row(s) checked' <<<"$sout" && ok "--sync: summary states rows checked" || bad "--sync: summary wrong: $(head -1 <<<"$sout")"
grep -q ':nitro' <<<"$(grep 'not in the feed' <<<"$sout")" && bad "--sync: nitro not resolved via its bare alias: $sout" \
                                                           || ok "--sync: :nitro resolved via its bare alias (not in the missing list)"
grep -q 'z-ai/glm-5.3 cacheWrite' <<<"$sout" && bad "--sync: checked unpublished z-ai cacheWrite: $sout" \
                                             || ok "--sync: z-ai cacheWrite (unpublished) left table-specified"
if python3 - "$PT" "$models" <<'PY'
import json, sys, subprocess, os
pt, mx = sys.argv[1], sys.argv[2]
env = dict(os.environ, PRICE_TABLE_MODELS_URL="file://" + mx)
out = subprocess.run([pt, "--sync"], capture_output=True, text=True, env=env).stdout
c = json.loads(out[out.index("{"):])["modelPricing"]["overrides"]
assert abs(c["z-ai/glm-5.3-flash"]["output"] - 9.99) < 1e-9, "output drift not in candidate"
assert abs(c["~openai/gpt-luna-latest"]["cacheWrite"] - 0.225) < 1e-9, "cacheWrite drift not in candidate"
assert c["z-ai/glm-5.3-flash"]["cacheWrite"] == 0.15, "sync touched unpublished cacheWrite"
assert c["~z-ai/glm-flash-latest"]["output"] == 0.083071, "non-drift row changed"
PY
then ok "--sync: updated candidate has the drifts, untouched rows and unpublished cacheWrite intact"
else bad "--sync: updated candidate wrong"; fi
[ "$before" = "$(find "$T" -type f | sort)" ] && ok "--sync: wrote nothing (no new or changed fixture files)" || bad "--sync: wrote something: $(diff <(echo "$before") <(find "$T" -type f | sort))"
# S6: dead URL -> clean one-line failure.
if PRICE_TABLE_MODELS_URL="file://$T/no-such-models.json" "$PT" --sync > "$T/out" 2>&1; then
    bad "--sync: dead URL did not fail"
elif grep -q 'Traceback' "$T/out" || ! grep -q '^price-table:' "$T/out"; then
    bad "--sync: dead URL not a clean one-line error: $(cat "$T/out")"
else
    ok "--sync: dead URL fails with a clean one-line error"
fi
# S2: empty feed -> no-rows-checked failure, not a false "no drift".
printf '{"data": []}' > "$T/empty.json"
if PRICE_TABLE_MODELS_URL="file://$T/empty.json" "$PT" --sync > "$T/out" 2>&1; then
    bad "--sync: empty feed did not fail"
elif ! grep -q 'no OR rows checked' "$T/out"; then
    bad "--sync: empty feed message wrong: $(cat "$T/out")"
else
    ok "--sync: empty feed reports no OR rows checked and exits nonzero"
fi

# --apply: merged tmpfile, the ! line with the tmpfile path, -D, no sudo run.
PATH_NOSUDO="$T/nosudo"
mkdir -p "$PATH_NOSUDO"
printf '#!/bin/bash\necho "SUDO-RAN $*" >> %s/sudo-ran\nexit 0\n' "$T" > "$PATH_NOSUDO/sudo"
chmod +x "$PATH_NOSUDO/sudo"
apout=$(PRICE_TABLE_MANAGED_FILE="$mg" PATH="$PATH_NOSUDO:$PATH" "$PT" --apply)
line=$(echo "$apout" | tail -1)
tmp=$(echo "$apout" | head -1)
if [ "$line" = "! sudo install -D -m 644 $tmp $mg" ]; then
    ok "--apply: the ! sudo install -D line printed with the tmpfile path and the merged-from managed path"
else
    bad "--apply: line shape wrong: $line"
fi
[ -f "$tmp" ] || bad "--apply: tmpfile missing"
if jq -e '.permissions == {"deny":["Bash(rm)"]} and (.modelPricing.overrides | length == 34)' "$tmp" >/dev/null 2>&1; then
    ok "--apply: existing managed file's foreign keys survive into the tmpfile"
else
    bad "--apply: tmpfile did not merge the existing managed content: $(cat "$tmp")"
fi
rm "$tmp"
apout2=$(PRICE_TABLE_MANAGED_FILE="$T/absent.json" PATH="$PATH_NOSUDO:$PATH" "$PT" --apply)
line2=$(echo "$apout2" | tail -1)
tmp2=$(echo "$apout2" | head -1)
if [ "$line2" = "! sudo install -D -m 644 $tmp2 $T/absent.json" ]; then
    ok "--apply: absent managed file -> bare candidate, ! line names that same path"
else
    bad "--apply: absent-file line shape wrong: $line2"
fi
if jq -e 'keys == ["modelPricing"] and (.modelPricing.overrides | length == 34)' "$tmp2" >/dev/null 2>&1; then
    ok "--apply: absent managed file -> bare candidate in tmpfile"
else
    bad "--apply: absent-file tmpfile wrong: $(cat "$tmp2")"
fi
rm "$tmp2"
# S1: --apply on a broken managed file fails loudly, before any tmpfile exists.
tmpcount=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'price-table-*.json' 2>/dev/null | wc -l)
if PRICE_TABLE_MANAGED_FILE="$T/bad.json" PATH="$PATH_NOSUDO:$PATH" "$PT" --apply > "$T/out" 2>&1; then
    bad "--apply: broken managed file did not fail"
elif grep -q 'Traceback' "$T/out" || ! grep -q '^price-table:' "$T/out"; then
    bad "--apply: broken managed file not a clean one-line error: $(cat "$T/out")"
elif [ "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'price-table-*.json' 2>/dev/null | wc -l)" != "$tmpcount" ]; then
    bad "--apply: failure leaked a tmpfile"
else
    ok "--apply: broken managed file fails loudly, no tmpfile leaked"
fi
[ -f "$T/sudo-ran" ] && bad "--apply: sudo stub was invoked" || ok "--apply: sudo never ran"

if [ "$fail" = 0 ]; then echo "price-table.probe: PASS"; else echo "price-table.probe: FAIL"; exit 1; fi