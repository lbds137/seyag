#!/bin/bash
# Fixture check for bin/context-audit against a throwaway HOME.
# Usage: tests/context-audit.probe.sh   (from anywhere)

set -uo pipefail
CA="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/plugins/seyag/bin/context-audit"
T=$(mktemp -d); trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; [ -n "${2:-}" ] && printf '      got: %s\n' "$2"; fail=1; }
run() { env -i HOME="$T" PATH=/usr/bin:/bin CONTEXT_AUDIT_MOUNTS="$T/mounts" "$CA" "$@" 2>&1; }
pad() { printf "%0${2}d" 0 > "$1"; }

# Layout: user CLAUDE.md + a nested user rule, a parent CLAUDE.md above the project, the project's
# CLAUDE.md, .claude/CLAUDE.md, CLAUDE.local.md, an always rule, a paths: rule, and an @import.
mkdir -p "$T/.claude/rules/sub" "$T/mem" "$T/work/proj/.claude/rules" "$T/exists" "$T/fakemount" "$T/gdrive/inner"
echo '{"autoMemoryDirectory": "~/mem"}' > "$T/.claude/settings.json"
pad "$T/.claude/CLAUDE.md" 400
pad "$T/.claude/rules/core.md" 800
pad "$T/.claude/rules/sub/nested.md" 50
pad "$T/work/CLAUDE.md" 70
printf 'see @imported.md\n' > "$T/work/proj/CLAUDE.md"
pad "$T/work/proj/imported.md" 90
pad "$T/work/proj/.claude/CLAUDE.md" 60
pad "$T/work/proj/CLAUDE.local.md" 40
pad "$T/work/proj/.claude/rules/a.md" 200
printf -- '---\npaths:\n  - "src/**"\n---\nonly for src\n' > "$T/work/proj/.claude/rules/scoped.md"
printf 'none /x fusectl rw 0 0\nremote: %s fuse.rclone rw 0 0\n' "$T/fakemount" > "$T/mounts"
ln -s "$T/gdrive" "$T/linked"
echo x > "$T/gdrive/inner/file"; chmod 000 "$T/gdrive" "$T/fakemount"   # any stat inside raises

mem() { printf -- '---\nname: %s\n---\n%s\n' "$2" "$3" > "$T/mem/$1.md"; }
mem good-one good-one 'links [[other-thing]] and [[stale_file]], ok path ~/exists'
mem other_thing other-thing "regex [[^\]] is no link; missing ~/nope/file.txt; dangling [[no-such-memory]]; mounts: ~/gdrive/inner/file $T/gdrive ~/work/../gdrive/inner ~/linked/inner/file $T/fakemount/f"
mem stale_file 'Not A Slug' 'near miss [[not-a-slug-x]] and [[good_one]] and [[stale-file]]'
mem under_score under_score 'fine'
mem orphan orphan-memory 'not listed in the index'
printf -- '- [G](good-one.md)\n- [O](other_thing.md)\n- [S](stale_file.md)\n- [U](under_score.md)\n- [Gone](gone.md)\nindex names ~/index-missing/x\n' > "$T/mem/MEMORY.md"
for i in $(seq 1 205); do echo "- line $i" >> "$T/mem/MEMORY.md"; done

W=$(run weigh "$T/work/proj")
# shellcheck disable=SC2088 # the tilde is literal text in the output under test
grep -q 'user CLAUDE.md' <<<"$W" && [ "$(grep -c '~/.claude/CLAUDE.md' <<<"$W")" = 1 ] && ok "user CLAUDE.md counted once" || bad "user CLAUDE.md" "$W"
grep -q 'project CLAUDE.md .*~/work/CLAUDE.md' <<<"$W" && ok "walks up to a parent CLAUDE.md" || bad "parent walk" "$W"
# shellcheck disable=SC2088 # the tilde is literal text in the output under test
grep -q '~/work/proj/.claude/CLAUDE.md' <<<"$W" && ok "counts .claude/CLAUDE.md" || bad ".claude/CLAUDE.md" "$W"
grep -q 'CLAUDE.local.md' <<<"$W" && ok "counts CLAUDE.local.md" || bad "CLAUDE.local.md" "$W"
grep -q 'user rule .*sub/nested.md' <<<"$W" && ok "finds nested user rules (recursive)" || bad "nested rule" "$W"
grep -q '@import .*imported.md' <<<"$W" && ok "follows an @import" || bad "@import" "$W"
grep -q 'on demand (paths: rule).*scoped.md' <<<"$W" && ! grep -q 'project rule .*scoped.md' <<<"$W" && ok "a paths: rule is on demand, not up front" || bad "paths: rule" "$W"
grep -q 'memory index .*~/mem/MEMORY.md' <<<"$W" && grep -q 'note: MEMORY.md is .* lines' <<<"$W" && ok "memory index found, load cap flagged" || bad "memory cap" "$W"
sizes=$(grep -E '^ +[0-9]+ B ' <<<"$W" | grep -v TOTAL | awk '{print $1}')
[ "$sizes" = "$(sort -rn <<<"$sizes")" ] && [ "$(wc -l <<<"$sizes")" -ge 5 ] && ok "sorts largest first" || bad "sort order" "$W"

R=$(run refs)
# shellcheck disable=SC2088 # the tilde is literal text in the output under test
grep -q 'missing path .*other_thing.md: ~/nope/file.txt' <<<"$R" && ok "reports a missing path" || bad "missing path" "$R"
grep -q 'missing path .*MEMORY.md: ~/index-missing/x' <<<"$R" && ok "scans MEMORY.md itself for paths" || bad "MEMORY.md paths" "$R"
# shellcheck disable=SC2088 # the tilde is literal text in the output under test
grep -q '~/exists' <<<"$R" && bad "reported an existing path" "$R" || ok "passes an existing path"
grep -v 'memory files,' <<<"$R" | grep -q 'gdrive\|linked\|fakemount' && bad "looked into a mount (a stat there would fail and be reported)" "$R" \
  || ok "never stats into ~/gdrive, a mount-table rclone mount, or a symlink into one"
grep -q 'dangling link .*\[\[no-such-memory\]\]' <<<"$R" && ok "reports a dangling link" || bad "dangling link" "$R"
grep -q '\[\[\^' <<<"$R" && bad "treated a regex as a link" "$R" || ok "ignores regex text in brackets"
grep -q 'other-thing\]\]\|: \[\[stale_file\]\]' <<<"$R" && bad "flagged a link by name or file stem" "$R" || ok "passes links by name and by file stem"
grep -q '\[\[good_one\]\]  (did you mean \[\[good-one\]\]?)' <<<"$R" && ok "hints a slug near match" || bad "near-match hint" "$R"
grep -q 'stale-file\]\].*did you mean' <<<"$R" && bad "hinted a non-slug name" "$R" || ok "never hints a non-slug name"
grep -q "name not a slug .*stale_file.md: name: 'Not A Slug'" <<<"$R" && ok "reports a spaced name" || bad "spaced name" "$R"
grep -q "name not a slug .*under_score.md" <<<"$R" && ok "reports an underscore name" || bad "underscore name" "$R"
grep -q 'index → missing file: gone.md' <<<"$R" && ok "reports an index line with no file" || bad "index missing" "$R"
grep -q 'not in index .*orphan.md' <<<"$R" && ok "reports a memory missing from the index" || bad "orphan" "$R"
run refs "$T/nowhere" >/dev/null; [ $? != 0 ] && ok "refs on a missing dir exits non-zero" || bad "missing dir exit"
exit $fail
