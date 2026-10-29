#!/bin/bash
# Hermetic probe for plugins/seyag/bin/lines-check and context-audit measure:
# live repo check plus canary fixture tree covering all D1-D4 and D8 invariants.
# Usage: tests/lines-check.probe.sh   (from anywhere)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO/plugins/seyag/bin/lines-check"
CA="$REPO/plugins/seyag/bin/context-audit"

TMP=$(mktemp -d)
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; [ -n "${2:-}" ] && printf '      got: %s\n' "$2"; fail=1; }

lc() { bash "$BIN" "$@" 2>&1; }

# Build a self-contained mini repo root under $TMP/$1 with its own baseline.
make_fixture() {
  local d="$TMP/$1"
  mkdir -p \
    "$d/plugins/seyag/rules" \
    "$d/plugins/seyag/skills/alpha" \
    "$d/plugins/seyag/skills/beta" \
    "$d/plugins/seyag/skills/gamma" \
    "$d/plugins/seyag/agents" \
    "$d/.github/baselines"

  cat >"$d/plugins/seyag/rules/core.md" <<'EOF'
# Core rules fixture
Rule line one.
Rule line two.
Rule line three.
Rule line four.
EOF

  cat >"$d/CLAUDE.md" <<'EOF'
# Project instructions
Inline backtick negative control: `acme@somehost` and `tool @not-an-import.md`.
```
@fenced-code-block.md
```
EOF

  cat >"$d/plugins/seyag/skills/alpha/SKILL.md" <<'EOF'
---
name: alpha
description: Plain scalar description for alpha skill
---
Body of alpha skill (lazy-loaded, not measured).
EOF

  cat >"$d/plugins/seyag/skills/beta/SKILL.md" <<'EOF'
---
name: beta
description: 'Single-quoted with it''s escaped quote'
---
Body of beta skill.
EOF

  cat >"$d/plugins/seyag/skills/gamma/SKILL.md" <<'EOF'
---
name: gamma
description: "Double-quoted with \"hi\" and \u0041"
---
Body of gamma skill.
EOF

  cat >"$d/plugins/seyag/agents/implementer.md" <<'EOF'
---
name: implementer
description: Agent description for implementer
---
Body of implementer agent.
EOF

  lc update-baseline --root "$d" >/dev/null
}

# 0. Live repo passes --check (exit 0) and prints instructions_total.
out=$(lc --check --root "$REPO")
rc=$?
if [ "$rc" -eq 0 ] && grep -qF 'instructions_total:' <<<"$out"; then
  ok "live repo passes --check (exit 0) and prints instructions_total"
else
  bad "live repo --check (rc=$rc)" "$out"
fi

# 1. Clean fixture passes --check (exit 0) and prints instructions_total + surfaces.
make_fixture base
out=$(lc --check --root "$TMP/base")
rc=$?
if [ "$rc" -eq 0 ] \
  && grep -qF 'instructions_total:' <<<"$out" \
  && grep -qF 'surface rules:' <<<"$out" \
  && grep -qF 'surface claude-md:' <<<"$out" \
  && grep -qF 'surface descriptions:' <<<"$out"; then
  ok "fixture baseline passes --check and prints instructions_total and all three surfaces"
else
  bad "fixture baseline --check (rc=$rc)" "$out"
fi

# 2. Canary 6 positive controls + D3 line arithmetic: decoded scalar byte lengths and unterminated line count.
mjson=$(python3 "$CA" measure --root "$TMP/base")
alpha_b=$(jq -r '.surfaces.descriptions.files[] | select(.path == "plugins/seyag/skills/alpha/SKILL.md") | .bytes' <<<"$mjson")
beta_b=$(jq -r '.surfaces.descriptions.files[] | select(.path == "plugins/seyag/skills/beta/SKILL.md") | .bytes' <<<"$mjson")
gamma_b=$(jq -r '.surfaces.descriptions.files[] | select(.path == "plugins/seyag/skills/gamma/SKILL.md") | .bytes' <<<"$mjson")
agent_b=$(jq -r '.surfaces.descriptions.files[] | select(.path == "plugins/seyag/agents/implementer.md") | .bytes' <<<"$mjson")
if [ "$alpha_b" = "40" ] && [ "$beta_b" = "37" ] && [ "$gamma_b" = "29" ] && [ "$agent_b" = "33" ]; then
  ok "positive scalar extraction: plain (40B), single-quoted ''->' (37B), double-quoted \\\" and \\u0041 (29B), agent plain (33B)"
else
  bad "positive scalar extraction byte counts (want 40/37/29/33, got $alpha_b/$beta_b/$gamma_b/$agent_b)" "$mjson"
fi

make_fixture unterminated
printf 'line1\nline2' >"$TMP/unterminated/plugins/seyag/rules/core.md"
ujson=$(python3 "$CA" measure --root "$TMP/unterminated")
ulines=$(jq -r '.surfaces.rules.lines' <<<"$ujson")
ubytes=$(jq -r '.surfaces.rules.bytes' <<<"$ujson")
if [ "$ulines" = "2" ] && [ "$ubytes" = "11" ]; then
  ok "D3 line arithmetic: newline-terminated plus final unterminated line counts 2 lines / 11 bytes"
else
  bad "D3 line arithmetic (want 2 lines / 11 bytes, got $ulines / $ubytes)" "$ujson"
fi

# 3. Canary 1a: over-budget lines-only -> fail (exit 1) naming surface + lines dimension.
make_fixture over-lines
for _ in $(seq 1 25); do echo "x"; done >"$TMP/over-lines/CLAUDE.md"
out=$(lc --check --root "$TMP/over-lines")
rc=$?
if [ "$rc" -eq 1 ] \
  && grep -qF "surface 'claude-md' over budget on lines" <<<"$out" \
  && grep -qF "update-baseline --surface claude-md" <<<"$out" \
  && ! grep -qF "over budget on bytes" <<<"$out"; then
  ok "canary 1a: lines-only breach exits 1 naming surface + lines dimension"
else
  bad "canary 1a lines-only breach (rc=$rc)" "$out"
fi
out_b1=$(lc --check --breakdown --root "$TMP/over-lines")
rc_b1=$?
if [ "$rc_b1" -eq 1 ] && grep -qF "Breakdown (worst-first by bytes):" <<<"$out_b1"; then
  ok "breakdown prints after an exit-1 outcome too"
else
  bad "breakdown after exit 1 (rc=$rc_b1)" "$out_b1"
fi

# 4. Canary 1b: over-budget bytes-only -> fail (exit 1) naming surface + bytes dimension.
make_fixture over-bytes
printf '%01500d\n' 0 >"$TMP/over-bytes/CLAUDE.md"
out=$(lc --check --root "$TMP/over-bytes")
rc=$?
if [ "$rc" -eq 1 ] \
  && grep -qF "surface 'claude-md' over budget on bytes" <<<"$out" \
  && grep -qF "update-baseline --surface claude-md" <<<"$out" \
  && ! grep -qF "over budget on lines" <<<"$out"; then
  ok "canary 1b: bytes-only breach exits 1 naming surface + bytes dimension"
else
  bad "canary 1b bytes-only breach (rc=$rc)" "$out"
fi

# 5. Canary 2: hollow measurement (glob matches zero files) -> fail (exit 1), and refresh refuses (exit 3).
make_fixture hollow
rm "$TMP/hollow/plugins/seyag/rules/core.md"
out=$(lc --check --root "$TMP/hollow")
rc=$?
if [ "$rc" -eq 1 ] && grep -qF "surface 'rules' hollow measurement" <<<"$out"; then
  ok "canary 2: hollow surface (0 matched files) fails --check with exit 1"
else
  bad "canary 2 hollow --check (rc=$rc)" "$out"
fi
out_up=$(lc update-baseline --root "$TMP/hollow")
rc_up=$?
if [ "$rc_up" -eq 3 ] && grep -qF "hollow" <<<"$out_up"; then
  ok "canary 2: update-baseline refuses hollow measurement with exit 3"
else
  bad "canary 2 hollow update-baseline (rc=$rc_up)" "$out_up"
fi

# 6. Canary 3: missing baseline file -> fail (exit 3) with refresh instruction.
make_fixture no-baseline
rm "$TMP/no-baseline/.github/baselines/lines-baseline.json"
out=$(lc --check --root "$TMP/no-baseline")
rc=$?
if [ "$rc" -eq 3 ] && grep -qF "missing baseline" <<<"$out" && grep -qF "update-baseline" <<<"$out"; then
  ok "canary 3: missing baseline exits 3 with refresh instruction"
else
  bad "canary 3 missing baseline (rc=$rc)" "$out"
fi

# 7. Canary 4a: baseline missing a canonical surface -> fail (exit 3, union iteration).
make_fixture missing-surface
jq 'del(.surfaces.descriptions)' "$TMP/missing-surface/.github/baselines/lines-baseline.json" \
  >"$TMP/missing-surface/b.tmp" && mv "$TMP/missing-surface/b.tmp" "$TMP/missing-surface/.github/baselines/lines-baseline.json"
out=$(lc --check --root "$TMP/missing-surface")
rc=$?
if [ "$rc" -eq 3 ] && grep -qF "canonical surface 'descriptions' is missing from baseline" <<<"$out"; then
  ok "canary 4a: baseline missing a canonical surface exits 3 via union iteration"
else
  bad "canary 4a missing canonical surface (rc=$rc)" "$out"
fi

# 8. Canary 4b: stray surface in baseline -> fail (exit 3, union iteration).
make_fixture stray-surface
jq '.surfaces.obsolete = {lines: 10, grace_lines: 2, bytes: 100, grace_bytes: 20}' \
  "$TMP/stray-surface/.github/baselines/lines-baseline.json" \
  >"$TMP/stray-surface/b.tmp" && mv "$TMP/stray-surface/b.tmp" "$TMP/stray-surface/.github/baselines/lines-baseline.json"
out=$(lc --check --root "$TMP/stray-surface")
rc=$?
if [ "$rc" -eq 3 ] && grep -qF "surface 'obsolete' in baseline is not measured by this tool" <<<"$out"; then
  ok "canary 4b: stray baseline entry exits 3 via union iteration"
else
  bad "canary 4b stray baseline entry (rc=$rc)" "$out"
fi

# 9. Canary 5: grace inflation passes --check by design, and delta/gap output shows the gap.
make_fixture grace-inflation
jq '.surfaces.rules.grace_lines = 400 | .surfaces.rules.grace_bytes = 40000' \
  "$TMP/grace-inflation/.github/baselines/lines-baseline.json" \
  >"$TMP/grace-inflation/b.tmp" && mv "$TMP/grace-inflation/b.tmp" "$TMP/grace-inflation/.github/baselines/lines-baseline.json"
printf 'Extra rule line A.\nExtra rule line B.\n' >>"$TMP/grace-inflation/plugins/seyag/rules/core.md"
out=$(lc --check --root "$TMP/grace-inflation")
rc=$?
out_dry=$(lc update-baseline --dry-run --root "$TMP/grace-inflation")
rc_dry=$?
if [ "$rc" -eq 0 ] \
  && grep -qF 'surface rules: lines 7/405 (baseline 5, delta +2, grace +400, gap 398)' <<<"$out" \
  && [ "$rc_dry" -eq 0 ] \
  && grep -qF 'delta rules: lines 5 -> 7 (+2, grace +400, limit 407)' <<<"$out_dry"; then
  ok "canary 5: grace inflation passes --check and delta/gap output quantifies the gap"
else
  bad "canary 5 grace inflation (rc=$rc, rc_dry=$rc_dry)" "$out / $out_dry"
fi

# 10. Canary 6 negative controls: folded description, missing description key, malformed frontmatter each refuse (exit 1).
make_fixture refused-folded
cat >"$TMP/refused-folded/plugins/seyag/skills/alpha/SKILL.md" <<'EOF'
---
name: alpha
description: >
  Folded line one
  Folded line two
---
Body.
EOF
out=$(lc --check --root "$TMP/refused-folded")
rc=$?
if [ "$rc" -eq 1 ] && grep -qF "measurement-refused" <<<"$out" && grep -qF "alpha/SKILL.md" <<<"$out"; then
  ok "canary 6a: folded multi-line description refuses with exit 1"
else
  bad "canary 6a folded description (rc=$rc)" "$out"
fi

make_fixture refused-missing
cat >"$TMP/refused-missing/plugins/seyag/skills/alpha/SKILL.md" <<'EOF'
---
name: alpha
---
Body without description.
EOF
out=$(lc --check --root "$TMP/refused-missing")
rc=$?
if [ "$rc" -eq 1 ] && grep -qF "measurement-refused" <<<"$out" && grep -qF "missing description key" <<<"$out"; then
  ok "canary 6b: missing description: key refuses with exit 1"
else
  bad "canary 6b missing description key (rc=$rc)" "$out"
fi

make_fixture refused-malformed
cat >"$TMP/refused-malformed/plugins/seyag/skills/alpha/SKILL.md" <<'EOF'
---
name: alpha
description: Unclosed frontmatter
Body without closing fence.
EOF
out=$(lc --check --root "$TMP/refused-malformed")
rc=$?
if [ "$rc" -eq 1 ] && grep -qF "measurement-refused" <<<"$out"; then
  ok "canary 6c: malformed frontmatter refuses with exit 1"
else
  bad "canary 6c malformed frontmatter (rc=$rc)" "$out"
fi

# 11. Canary 7: @-import in a measured file fails (exit 1); inline backtick token in base fixture passed.
make_fixture import-ban
printf '\nSee @./imported-doc.md for more.\n' >>"$TMP/import-ban/CLAUDE.md"
out=$(lc --check --root "$TMP/import-ban")
rc=$?
if [ "$rc" -eq 1 ] && grep -qF "@-import found in measured file: CLAUDE.md: @./imported-doc.md" <<<"$out"; then
  ok "canary 7: @-import in measured file exits 1 while inline backtick tokens in base fixture pass"
else
  bad "canary 7 @-import ban (rc=$rc)" "$out"
fi

# 12. Canary 8: subdirectory under a measured glob fails loud (exit 1).
make_fixture nested-dir
mkdir -p "$TMP/nested-dir/plugins/seyag/rules/sub"
out=$(lc --check --root "$TMP/nested-dir")
rc=$?
if [ "$rc" -eq 1 ] && grep -qF "nested directory under measured glob: plugins/seyag/rules/sub" <<<"$out"; then
  ok "canary 8: subdirectory under measured glob exits 1"
else
  bad "canary 8 nested directory (rc=$rc)" "$out"
fi

# 12b. Skills-internal directories are OUT of the guard's perimeter: the
# descriptions glob is fixed-depth, so a skill's references/ or scripts/ hides
# nothing from it, and their content is lazy-loaded (unmeasured by design).
make_fixture skill-subdir-ok
mkdir -p "$TMP/skill-subdir-ok/plugins/seyag/skills/alpha/references"
printf 'Reference text.\n' >"$TMP/skill-subdir-ok/plugins/seyag/skills/alpha/references/api.md"
out_ssk=$(lc --check --root "$TMP/skill-subdir-ok")
rc_ssk=$?
if [ "$rc_ssk" -eq 0 ]; then
  ok "skill-internal directories (references/) stay out of the nested-dir guard"
else
  bad "skill-internal directory over-reach (rc=$rc_ssk)" "$out_ssk"
fi

# 12c. A skill directory without SKILL.md is malformed and fails under its own name.
make_fixture malformed-skill
rm "$TMP/malformed-skill/plugins/seyag/skills/alpha/SKILL.md"
out_msk=$(lc --check --root "$TMP/malformed-skill")
rc_msk=$?
if [ "$rc_msk" -eq 1 ] && grep -qF "malformed skill directory (no SKILL.md)" <<<"$out_msk"; then
  ok "skill directory without SKILL.md fails with its own reason"
else
  bad "malformed skill directory (rc=$rc_msk)" "$out_msk"
fi

# 12d. A missing agents/ directory fails loud (deleting the last agent must not
# silently shrink the descriptions surface).
make_fixture missing-agents
rm -rf "$TMP/missing-agents/plugins/seyag/agents"
out_mag=$(lc --check --root "$TMP/missing-agents")
rc_mag=$?
if [ "$rc_mag" -eq 1 ] && grep -qF "plugins/seyag/agents" <<<"$out_mag"; then
  ok "missing agents directory fails loud instead of silently shrinking descriptions"
else
  bad "missing agents directory (rc=$rc_mag)" "$out_mag"
fi

# 13. Canary 9: fixture isolation (files under tests/ never enter measurement; symlink into tests/ exits 1).
make_fixture fixture-iso
mkdir -p "$TMP/fixture-iso/tests/fixtures/plugins/seyag/rules"
printf '%05000d\n' 0 >"$TMP/fixture-iso/tests/fixtures/plugins/seyag/rules/huge.md"
out=$(lc --check --root "$TMP/fixture-iso")
rc=$?
iso_paths=$(python3 "$CA" measure --root "$TMP/fixture-iso" | jq -r '.surfaces[].files[].path' | grep -c '^tests/' || true)
ln -s "../../../tests/fixtures/plugins/seyag/rules/huge.md" "$TMP/fixture-iso/plugins/seyag/rules/leak.md"
out_leak=$(lc --check --root "$TMP/fixture-iso")
rc_leak=$?
if [ "$rc" -eq 0 ] && [ "$iso_paths" = "0" ] && [ "$rc_leak" -eq 1 ]; then
  ok "canary 9: tests/ paths never enter measurement (0 hits, exit 0) and linked leak fails (exit 1)"
else
  bad "canary 9 fixture isolation (rc=$rc, iso_paths=$iso_paths, rc_leak=$rc_leak)" "$out / $out_leak"
fi

# 14. Canary 10: invalid baseline schema (exit 3) and atomic write preservation on failed refresh.
make_fixture bad-schema
jq '.surfaces.rules.grace_lines = -1' "$TMP/bad-schema/.github/baselines/lines-baseline.json" \
  >"$TMP/bad-schema/b.tmp" && mv "$TMP/bad-schema/b.tmp" "$TMP/bad-schema/.github/baselines/lines-baseline.json"
out=$(lc --check --root "$TMP/bad-schema")
rc=$?
jq '.surfaces.rules.grace_lines = 5 | .surfaces.rules.extra_key = 1' "$TMP/bad-schema/.github/baselines/lines-baseline.json" \
  >"$TMP/bad-schema/b.tmp" && mv "$TMP/bad-schema/b.tmp" "$TMP/bad-schema/.github/baselines/lines-baseline.json"
out_unk=$(lc --check --root "$TMP/bad-schema")
rc_unk=$?
if [ "$rc" -eq 3 ] && grep -qF "invalid baseline schema" <<<"$out" \
  && [ "$rc_unk" -eq 3 ] && grep -qF "unknown keys" <<<"$out_unk"; then
  ok "canary 10a: negative grace and unknown baseline keys fail schema validation with exit 3"
else
  bad "canary 10a invalid baseline schema (rc=$rc, rc_unk=$rc_unk)" "$out / $out_unk"
fi

make_fixture atomic-refresh
before_base=$(cat "$TMP/atomic-refresh/.github/baselines/lines-baseline.json")
rm "$TMP/atomic-refresh/CLAUDE.md"
out_at=$(lc update-baseline --root "$TMP/atomic-refresh")
rc_at=$?
after_base=$(cat "$TMP/atomic-refresh/.github/baselines/lines-baseline.json")
leftover_tmp=$(find "$TMP/atomic-refresh/.github/baselines" -name '*.tmp.*' | wc -l)
if [ "$rc_at" -eq 3 ] && [ "$before_base" = "$after_base" ] && [ "$leftover_tmp" -eq 0 ]; then
  ok "canary 10b: failed refresh exits 3 and leaves existing baseline untouched with no temp files"
else
  bad "canary 10b atomic refresh (rc=$rc_at, leftover=$leftover_tmp)" "$out_at"
fi

# 15. Scoped refresh preserves other entries verbatim + warns on gaps; unscoped refresh prunes strays.
make_fixture refresh-modes
jq '.surfaces["claude-md"].grace_bytes = 999' "$TMP/refresh-modes/.github/baselines/lines-baseline.json" \
  >"$TMP/refresh-modes/b.tmp" && mv "$TMP/refresh-modes/b.tmp" "$TMP/refresh-modes/.github/baselines/lines-baseline.json"
old_claude_entry=$(jq -cS '.surfaces["claude-md"]' "$TMP/refresh-modes/.github/baselines/lines-baseline.json")
printf 'Added rule line.\n' >>"$TMP/refresh-modes/plugins/seyag/rules/core.md"
printf 'Added claude line.\n' >>"$TMP/refresh-modes/CLAUDE.md"
out_sc=$(lc update-baseline --surface rules --root "$TMP/refresh-modes")
rc_sc=$?
new_rules_lines=$(jq -r '.surfaces.rules.lines' "$TMP/refresh-modes/.github/baselines/lines-baseline.json")
new_claude_entry=$(jq -cS '.surfaces["claude-md"]' "$TMP/refresh-modes/.github/baselines/lines-baseline.json")
if [ "$rc_sc" -eq 0 ] && [ "$new_rules_lines" = "6" ] && [ "$old_claude_entry" = "$new_claude_entry" ]; then
  ok "scoped refresh updates target surface and preserves other surface entries verbatim"
else
  bad "scoped refresh verbatim preservation (rc=$rc_sc, rules_lines=$new_rules_lines)" "$out_sc"
fi

jq 'del(.surfaces.descriptions)' "$TMP/refresh-modes/.github/baselines/lines-baseline.json" \
  >"$TMP/refresh-modes/b.tmp" && mv "$TMP/refresh-modes/b.tmp" "$TMP/refresh-modes/.github/baselines/lines-baseline.json"
out_gap=$(lc update-baseline --surface rules --root "$TMP/refresh-modes")
rc_gap=$?
if [ "$rc_gap" -eq 0 ] && grep -qF "WARN: canonical surface 'descriptions' is missing" <<<"$out_gap"; then
  ok "scoped refresh warns when another canonical surface is missing from baseline"
else
  bad "scoped refresh gap warning (rc=$rc_gap)" "$out_gap"
fi

jq '.surfaces.stray_one = {lines: 1, grace_lines: 1, bytes: 10, grace_bytes: 10}' \
  "$TMP/refresh-modes/.github/baselines/lines-baseline.json" \
  >"$TMP/refresh-modes/b.tmp" && mv "$TMP/refresh-modes/b.tmp" "$TMP/refresh-modes/.github/baselines/lines-baseline.json"
out_sc_stray=$(lc update-baseline --surface rules --root "$TMP/refresh-modes")
rc_sc_stray=$?
out_unscoped=$(lc update-baseline --root "$TMP/refresh-modes")
rc_unscoped=$?
has_stray=$(jq -r '.surfaces | has("stray_one")' "$TMP/refresh-modes/.github/baselines/lines-baseline.json")
has_desc=$(jq -r '.surfaces | has("descriptions")' "$TMP/refresh-modes/.github/baselines/lines-baseline.json")
if [ "$rc_sc_stray" -eq 3 ] && [ "$rc_unscoped" -eq 0 ] \
  && grep -qF "delta stray_one: pruned stray surface" <<<"$out_unscoped" \
  && [ "$has_stray" = "false" ] && [ "$has_desc" = "true" ]; then
  ok "scoped refresh rejects stray entries (exit 3); unscoped refresh prunes strays and restores canonical set"
else
  bad "unscoped prune strays (rc_sc=$rc_sc_stray, rc_un=$rc_unscoped, stray=$has_stray, desc=$has_desc)" "$out_sc_stray / $out_unscoped"
fi

# 16. Shrink guard, drift check, >=60000 tripwire WARN, --breakdown after broken exit, and missing jq/python3.
make_fixture shrink
for _ in $(seq 1 20); do echo "rule line content"; done >"$TMP/shrink/plugins/seyag/rules/core.md"
lc update-baseline --root "$TMP/shrink" >/dev/null
echo "tiny" >"$TMP/shrink/plugins/seyag/rules/core.md"
out_sh=$(lc update-baseline --root "$TMP/shrink")
rc_sh=$?
if [ "$rc_sh" -eq 0 ] && grep -qF "WARN: shrink guard: surface 'rules' dropped by more than half" <<<"$out_sh"; then
  ok "shrink guard warns when a surface drops by more than half without an impl_version bump"
else
  bad "shrink guard (rc=$rc_sh)" "$out_sh"
fi

make_fixture drift
jq '.meta.config_hash = "0000000000000000"' "$TMP/drift/.github/baselines/lines-baseline.json" \
  >"$TMP/drift/b.tmp" && mv "$TMP/drift/b.tmp" "$TMP/drift/.github/baselines/lines-baseline.json"
out_dr=$(lc --check --root "$TMP/drift")
rc_dr=$?
if [ "$rc_dr" -eq 3 ] && grep -qF "the measurement changed; refresh the baseline" <<<"$out_dr"; then
  ok "drift check exits 3 with 'the measurement changed; refresh the baseline'"
else
  bad "drift check (rc=$rc_dr)" "$out_dr"
fi

# 16b. Scoped refresh refuses a drifted baseline: stamping the new measurement
# hash over entries it did not re-measure would bless stale numbers as current.
make_fixture drift-scoped
jq '.meta.config_hash = "0000000000000000"' "$TMP/drift-scoped/.github/baselines/lines-baseline.json" \
  >"$TMP/drift-scoped/b.tmp" && mv "$TMP/drift-scoped/b.tmp" "$TMP/drift-scoped/.github/baselines/lines-baseline.json"
before_drift=$(cat "$TMP/drift-scoped/.github/baselines/lines-baseline.json")
out_dsc=$(lc update-baseline --surface rules --root "$TMP/drift-scoped")
rc_dsc=$?
after_drift=$(cat "$TMP/drift-scoped/.github/baselines/lines-baseline.json")
if [ "$rc_dsc" -eq 3 ] \
  && grep -qF "scoped refresh would stamp the new measurement" <<<"$out_dsc" \
  && [ "$before_drift" = "$after_drift" ]; then
  ok "scoped refresh refuses a drifted baseline (exit 3, baseline untouched)"
else
  bad "scoped refresh drift refusal (rc=$rc_dsc)" "$out_dsc"
fi

make_fixture tripwire
printf '%060500d\n' 0 >"$TMP/tripwire/plugins/seyag/rules/core.md"
lc update-baseline --root "$TMP/tripwire" >/dev/null
out_tw=$(lc --check --breakdown --root "$TMP/tripwire")
rc_tw=$?
out_brk_fail=$(lc --check --breakdown --root "$TMP/drift")
rc_brk_fail=$?
if [ "$rc_tw" -eq 0 ] \
  && grep -qF "WARN: instructions_total" <<<"$out_tw" \
  && grep -qF "Breakdown (worst-first by bytes):" <<<"$out_tw" \
  && [ "$rc_brk_fail" -eq 3 ] \
  && grep -qF "Breakdown (worst-first by bytes):" <<<"$out_brk_fail"; then
  ok "tripwire WARNs non-gating at >=60000 and --breakdown prints after both pass and broken-state exits"
else
  bad "tripwire / breakdown (rc_tw=$rc_tw, rc_brk_fail=$rc_brk_fail)" "$out_tw / $out_brk_fail"
fi

# Missing jq / python3 on PATH -> one-line error, non-zero exit.
no_jq="$TMP/no-jq-bin"
no_py="$TMP/no-py-bin"
mkdir -p "$no_jq" "$no_py"
for t in bash cat mktemp rm dirname sed grep tr sort head wc env python3; do
  p=$(command -v "$t" 2>/dev/null) && [ -n "$p" ] && ln -sf "$p" "$no_jq/$t"
done
for t in bash cat mktemp rm dirname sed grep tr sort head wc env jq; do
  p=$(command -v "$t" 2>/dev/null) && [ -n "$p" ] && ln -sf "$p" "$no_py/$t"
done
out_jq=$(PATH="$no_jq" bash "$BIN" --check --root "$TMP/base" 2>&1)
rc_jq=$?
out_py=$(PATH="$no_py" bash "$BIN" --check --root "$TMP/base" 2>&1)
rc_py=$?
if [ "$rc_jq" -ne 0 ] && [ "$(wc -l <<<"$out_jq")" -eq 1 ] && grep -qF "jq" <<<"$out_jq" \
  && [ "$rc_py" -ne 0 ] && [ "$(wc -l <<<"$out_py")" -eq 1 ] && grep -qF "python3" <<<"$out_py"; then
  ok "missing jq or python3 fails loud with a one-line error and non-zero exit"
else
  bad "missing jq/python3 (rc_jq=$rc_jq [$out_jq], rc_py=$rc_py [$out_py])"
fi

exit "$fail"
