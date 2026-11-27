#!/bin/bash
# Hermetic probe for plugins/seyag/bin/claude-role: the role file verbs (--in-person, --json, --list,
# --set, --need, --need-done, --note, --next, --size), the hook-mode output and its 10000-unit cap,
# the config knobs (SYG_ROLE_DIR and its siblings) and the headless/task env vars. Every run points
# SYG_ROLE_DIR at a temp dir, with SYG_CONFIG=0 so no user config leaks in.
# Usage: tests/claude-role.probe.sh   (from anywhere)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CR="$REPO/plugins/seyag/bin/claude-role"
[ -x "$CR" ] || { echo "FAIL  $CR is not executable (chmod +x it)"; exit 1; }
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; }

# No ambient knob or session variable may leak into a case; each case sets what it tests.
unset CLAUDE_PID CLAUDE_ROLE_HEADLESS CLAUDE_ROLE_TASK CLAUDE_ROLE_NOW_EPOCH XDG_DATA_HOME \
      SYG_ROLE_CONTEXT_LINE SYG_ROLE_PREAMBLE_FILE SYG_NEEDS_OWNER_SECTION SYG_IN_PERSON_SECTION \
      SYG_ROLE_CONTEXT_CMD SYG_ROUTE_SHOW_CMD SYG_ROLE_HEADLESS_ROUTES SYG_ROLE_HEADLESS SYG_ROLE_TASK \
      SYG_ROLE_NOW_EPOCH
export SYG_CONFIG=0

home=$(mktemp -d "${TMPDIR:-/tmp}/claude-role-probe.XXXXXX")
trap 'rm -rf "$home"' EXIT
roles="$home/roles"
mkdir -p "$roles"
export SYG_ROLE_DIR="$roles"

# Nested frontmatter (the memory system's layout), an In Person section between two others.
cat > "$roles/alpha.md" <<'EOF'
---
metadata:
  role: "Alpha role"
  status: "busy"
---

## Next
- not a person item

## In Person
- Paste the script — unblocks renames (added 2026-09-27)
- Reboot once — confirms the fix (added 2026-09-26)
  continuation line, not a bullet

## Handoff
- also not a person item
EOF
# A role with no In Person section, and a README that isn't a role.
printf -- '---\nrole: Beta role\n---\n\n## Next\n- nothing\n' > "$roles/beta.md"
printf -- '# Roles\n\n## In Person\n- format example, not a role\n' > "$roles/README.md"
# A heading that only starts with the section name doesn't count.
printf -- '---\nrole: Gamma role\n---\n\n## In Person, historically\n- old note\n' > "$roles/gamma.md"

# An emptied section with a placeholder bullet has no items.
printf -- '---\nrole: Delta role\n---\n\n## In Person\n- (none)\n' > "$roles/delta.md"
# CRLF line endings (a file saved on Windows) must still parse, without a stray \r in the values.
printf -- '---\r\nrole: "Epsilon role"\r\nstatus: "idle"\r\n---\r\n\r\n## In Person\r\n- Sign in — unblocks sync (added 2026-09-27)\r\n' > "$roles/epsilon.md"

out=$("$CR" --in-person); rc=$?
[ $rc = 0 ] && ok "--in-person exits 0" || bad "--in-person exits 0 (rc $rc)"
grep -q "^Alpha role  (alpha.md)$" <<< "$out" && ok "role header printed" || bad "role header missing"
[ "$(grep -c '^  - ' <<< "$out")" = 3 ] && ok "exactly the 3 In Person bullets (alpha 2, epsilon 1)" || bad "bullet count: $out"
grep -q "Delta role" <<< "$out" && bad "placeholder bullet counted as an item" || ok "placeholder-only section omitted"
grep -q "^Epsilon role  (epsilon.md)$" <<< "$out" && ok "CRLF role listed" || bad "CRLF role missing"
grep -q $'\r' <<< "$out" && bad "stray CR in --in-person output" || ok "no CR in --in-person output"
grep -q "not a person item" <<< "$out" && bad "leaked a bullet from another section" || ok "other sections excluded"
grep -q "Beta role" <<< "$out" && bad "role with no In Person items printed" || ok "empty role omitted"
grep -q "format example" <<< "$out" && bad "README treated as a role" || ok "README skipped"
grep -q "old note" <<< "$out" && bad "look-alike heading matched" || ok "look-alike heading ignored"

json=$("$CR" --json); rc=$?
[ $rc = 0 ] && ok "--json exits 0" || bad "--json exits 0 (rc $rc)"
[ "$(jq '.roles | length' <<< "$json")" = 5 ] && ok "--json lists the 5 roles, not README" || bad "--json role count: $json"
got=$(jq -c '.roles[] | select(.file == "epsilon.md") | [.status, .deck[0].what]' <<< "$json")
[ "$got" = '["idle","Sign in"]' ] && ok "--json reads a CRLF role cleanly" || bad "--json CRLF role: $got"
got=$(jq -c '.roles[] | select(.file == "alpha.md") | [.status, .deck[0]]' <<< "$json")
[ "$got" = '["busy",{"what":"Paste the script","unblocks":"unblocks renames","added":"2026-09-27"}]' ] \
    && ok "--json splits a bullet into what/unblocks/added" || bad "--json bullet split: $got"
got=$(jq -r '.roles[] | select(.file == "alpha.md") | .next' <<< "$json")
[ "$got" = "- not a person item" ] && ok "--json carries the Next section" || bad "--json next: '$got'"

# --list: folder, role, the `parked:`, `privacy:` and `route:` fields (each empty when absent), README excluded.
printf -- '---\nmetadata:\n  role: "Zeta role"\n  parked: "her call 2026-10-04"\n---\n' > "$roles/zeta.md"
printf -- '---\nmetadata:\n  role: "Eta role"\n  privacy: "personal"\n---\n' > "$roles/eta.md"
printf -- '---\nmetadata:\n  role: "Theta role"\n  route: lane-two\n---\n' > "$roles/theta.md"
out=$("$CR" --list); rc=$?
[ $rc = 0 ] && ok "--list exits 0" || bad "--list exits 0 (rc $rc)"
grep -qxF $'zeta\tZeta role\ther call 2026-10-04\t\t' <<< "$out" && ok "--list carries the parked field" || bad "--list parked: $out"
grep -qxF $'eta\tEta role\t\tpersonal\t' <<< "$out" && ok "--list carries the privacy field" || bad "--list privacy: $out"
grep -qxF $'theta\tTheta role\t\t\tlane-two' <<< "$out" && ok "--list carries the route field" || bad "--list route: $out"
grep -qxF $'beta\tBeta role\t\t\t' <<< "$out" && ok "--list: plain role has empty third to fifth columns" || bad "--list plain: $out"
[ "$(wc -l <<< "$out")" = 8 ] && ok "--list: 8 roles, no README" || bad "--list count: $out"
rm "$roles/zeta.md" "$roles/eta.md" "$roles/theta.md"

# --list parses escaped and hand-written values exactly as field() does, and only frontmatter counts:
# a role: line in the body (after the closing ---) is not a role. A CRLF file lists cleanly, and a
# dated -archive- copy is not listed even with a role.
printf -- '---\nrole: "A\\tB"\nroute: %s\n---\n' "'it''s'" > "$roles/esc.md"
printf -- '---\nrole: "X\\n"\n---\n' > "$roles/escnl.md"
printf -- '---\nnot-a-key: x\n---\n\n## Charter\nrole: body line\n' > "$roles/bodyrole.md"
printf -- '---\r\nrole: "Old role"\r\n---\r\n' > "$roles/retired-archive-2026-01-01.md"
out=$("$CR" --list); rc=$?
[ $rc = 0 ] && ok "--list edge cases exit 0" || bad "--list edge cases rc: $rc"
grep -qxF $'esc\tA B\t\t\tit\'s' <<< "$out" && ok "--list: an escaped tab flattens to a space and single-quoted '' unquotes" || bad "--list escapes: $out"
grep -qxF $'escnl\tX\t\t\t' <<< "$out" && ok "--list: an escaped trailing newline flattens away" || bad "--list escnl: $out"
! grep -q '^bodyrole' <<< "$out" && ok "--list: a role: line in the body is not a role" || bad "--list bodyrole: $out"
grep -qxF $'epsilon\tEpsilon role\t\t\t' <<< "$out" && ok "--list: a CRLF file lists cleanly" || bad "--list CRLF: $out"
! grep -q 'Old role' <<< "$out" && ok "--list: a dated -archive- copy with a role is not listed" || bad "--list archive: $out"
rm "$roles/esc.md" "$roles/escnl.md" "$roles/bodyrole.md" "$roles/retired-archive-2026-01-01.md"

# --list is one awk process for the whole run and no cat or basename, however many roles (TASK-178):
# wrapper shims first on PATH log every exec of the three tools the old loop forked per file, so the
# counts must hold while the role files grow.
shim="$home/shim-bin"; mkdir -p "$shim"
execlog="$home/exec-count.log"
for tool in awk cat basename; do
    real=$(command -v "$tool")   # resolved before the shim dir is ever prepended
    cat > "$shim/$tool" <<EOF
#!/bin/bash
printf '%s\n' $tool >> "$execlog"
exec "$real" "\$@"
EOF
    chmod +x "$shim/$tool"
done
: > "$execlog"
rows1=$(PATH="$shim:$PATH" "$CR" --list | wc -l)
awk1=$(grep -c '^awk$' "$execlog"); cat1=$(grep -c '^cat$' "$execlog"); base1=$(grep -c '^basename$' "$execlog")
printf -- '---\nrole: "Extra one"\n---\n' > "$roles/extra1.md"
printf -- '---\nrole: "Extra two"\n---\n' > "$roles/extra2.md"
printf -- '---\nrole: "Extra three"\n---\n' > "$roles/extra3.md"
: > "$execlog"
rows2=$(PATH="$shim:$PATH" "$CR" --list | wc -l)
awk2=$(grep -c '^awk$' "$execlog"); cat2=$(grep -c '^cat$' "$execlog"); base2=$(grep -c '^basename$' "$execlog")
[ "$awk1" = 1 ] && [ "$awk1" = "$awk2" ] && [ "$cat1" = 0 ] && [ "$cat2" = 0 ] && [ "$base1" = 0 ] && [ "$base2" = 0 ] \
  && [ "$rows1" -gt 0 ] && [ "$rows2" = "$((rows1 + 3))" ] \
  && ok "--list: one awk process ($awk1) in both runs, no cat ($cat1/$cat2), no basename ($base1/$base2)" \
  || bad "--list processes: awk $awk1->$awk2 cat $cat1->$cat2 basename $base1->$base2 rows $rows1->$rows2"
rm "$roles/extra1.md" "$roles/extra2.md" "$roles/extra3.md"

# An empty role dir: --list exits 0 with no output and never reads stdin (awk with no file arguments
# would sit waiting on it); callers run it with stdin from long-lived pipes (TASK-178). Stdin is a
# process substitution whose sleep holds it open for 10 s; unlike a pipeline, nothing waits on it,
# so a hang shows as timeout's 124.
empty="$home/empty-roles"; mkdir -p "$empty"
out=$(SYG_ROLE_DIR="$empty" timeout 5 "$CR" --list < <(sleep 10 2>/dev/null) 2>&1); rc=$?
[ $rc = 0 ] && [ -z "$out" ] && ok "--list: an empty role dir exits 0 with no output, not hanging on stdin" \
  || bad "--list empty dir stdin: rc=$rc out=$out"
rmdir "$empty"

# An unreadable or dangling role file mid-list: gawk would die on it and drop every later row (and the
# one before it, flushed late) with exit 0. --list skips it with a note and still lists the rest.
bdir="$home/bad-roles"; mkdir -p "$bdir"
for n in a c e h; do printf -- '---\nrole: "R %s"\n---\n' "$n" > "$bdir/$n.md"; done
printf -- '---\nrole: "Unread"\n---\n' > "$bdir/d-unread.md"; chmod 000 "$bdir/d-unread.md"
ln -s "$bdir/missing-target.md" "$bdir/f-dangling.md"
err=$(SYG_ROLE_DIR="$bdir" "$CR" --list 2>&1 >"$home/bad.out"); rc=$?
want=$(printf 'a\tR a\t\t\t\nc\tR c\t\t\t\ne\tR e\t\t\t\nh\tR h\t\t\t')
if [ "$(id -u)" = 0 ]; then
    grep -q 'f-dangling.md: not a readable file' <<<"$err" && grep -q '^h	R h' "$home/bad.out" \
      && ok "--list: a dangling role file is skipped with a note (unreadable case skipped as root)" \
      || bad "--list bad files (root): rc=$rc err=[$err] out=[$(cat "$home/bad.out")]"
else
    [ $rc = 0 ] && [ "$(cat "$home/bad.out")" = "$want" ] \
      && grep -q 'd-unread.md: not a readable file' <<<"$err" && grep -q 'f-dangling.md: not a readable file' <<<"$err" \
      && ok "--list: unreadable and dangling role files are skipped with a note; the other four rows stay" \
      || bad "--list bad files: rc=$rc err=[$err] out=[$(cat "$home/bad.out")]"
fi
chmod 600 "$bdir/d-unread.md"; rm -f "$bdir"/*.md "$home/bad.out"; rmdir "$bdir"

# "## Needs Owner": what waits on the owner anywhere (read, rule, answer). --json carries it as .needs,
# with an optional (due DATE); --in-person stays in-person only.
cat > "$roles/iota.md" <<'EOF'
---
role: Iota role
---

## Needs Owner
- Read the report — on a phone, before therapy (due 2026-10-13) (added 2026-10-11)
- Rule on the label
- (none)
- Reversed (added 2026-10-11) (due 2026-10-14)
- Sloppy date (due 2026-1-3)

## In Person
- Reboot — applies the kernel (added 2026-10-10)
EOF
json=$("$CR" --json)
got=$(jq -c '.roles[] | select(.file == "iota.md") | .needs' <<< "$json")
[ "$got" = '[{"what":"Read the report","unblocks":"on a phone, before therapy","added":"2026-10-11","due":"2026-10-13"},{"what":"Rule on the label","unblocks":"","added":"","due":""},{"what":"Reversed","unblocks":"","added":"2026-10-11","due":"2026-10-14"},{"what":"Sloppy date (due 2026-1-3)","unblocks":"","added":"","due":""}]' ] \
    && ok "--json .needs splits what/unblocks/due/added, skips placeholders" || bad "--json needs: $got"
got=$(jq -c '.roles[] | select(.file == "iota.md") | [.deck[].what]' <<< "$json")
[ "$got" = '["Reboot"]' ] && ok "--json .deck keeps only the In Person bullets" || bad "--json deck with needs: $got"
got=$(jq -c '.roles[] | select(.file == "alpha.md") | .needs' <<< "$json")
[ "$got" = '[]' ] && ok "--json .needs is [] without the section" || bad "--json needs absent: $got"
out=$("$CR" --in-person)
grep -q "Read the report" <<< "$out" && bad "--in-person leaked a Needs Owner bullet" || ok "--in-person stays in-person only"
rm "$roles/iota.md"

# --set refuses a status led by today's date and a guessed clock time in the future.
today=$(date +%F); fut=$(date -d '+30 min' +%H:%M); past=$(date -d '-30 min' +%H:%M)
if [ "$(date -d '+30 min' +%F)" = "$today" ] && [ "$(date -d '-30 min' +%F)" = "$today" ]; then
    "$CR" --set status="$today ~$fut: guessed" --file "$roles/epsilon.md" 2>/dev/null \
        && bad "--set accepted a future leading time" || ok "--set refuses a future leading time"
    grep -q "guessed" "$roles/epsilon.md" && bad "refused status was written anyway" || ok "refused status not written"
    "$CR" --set status="$today $past: real" --file "$roles/epsilon.md" \
        && ok "--set accepts a past leading time" || bad "--set refused a past leading time"
    "$CR" --set status="paused until the 23:59 reset" --file "$roles/epsilon.md" \
        && ok "--set accepts a future time inside the text" || bad "--set refused a mid-text future time"
    md=$(date +%m-%d)
    "$CR" --set status="$md $fut guessed short" --file "$roles/epsilon.md" 2>/dev/null \
        && bad "--set accepted a future MM-DD leading time" || ok "--set refuses a future MM-DD leading time"
    "$CR" --set status="$md $past real short" --file "$roles/epsilon.md" >/dev/null \
        && ok "--set accepts a past MM-DD leading time" || bad "--set refused a past MM-DD leading time"
    # --handoff FILE: a line-leading stamp (bullet `- **MM-DD HH:MM` or the heading's parenthetical)
    # dated today and later than now is a guessed time; a dated schedule mid-line is not.
    printf '## Handoff (trimmed %s %s)\n- ok\n' "$md" "$fut" > "$home/fut-h1.md"
    printf '## Handoff\n- **%s %s:** guessed note\n' "$md" "$fut" > "$home/fut-h2.md"
    printf '## Handoff (trimmed 5 notes; %s %s)\n- ok\n' "$md" "$fut" > "$home/fut-h4.md"
    printf '## Handoff\n```\n- **%s %s:** fenced example\n```\n' "$md" "$fut" > "$home/fut-h5.md"
    "$CR" --set --handoff "$home/fut-h5.md" --file "$roles/epsilon.md" >/dev/null \
        && ok "--handoff ignores a future stamp inside a code fence" || bad "--handoff refused a fenced stamp"
    printf '## Handoff (trimmed %s %s)\n- **%s %s:** real\n- the burn opens %s %s\n' "$md" "$past" "$md" "$past" "$md" "$fut" > "$home/fut-h3.md"
    for h in fut-h1 fut-h2 fut-h4; do
        before=$(cat "$roles/epsilon.md")
        err=$("$CR" --set --handoff "$home/$h.md" --file "$roles/epsilon.md" 2>&1) \
            && bad "--handoff accepted a future stamp ($h)" \
            || { grep -q "run \`date\`" <<< "$err" && [ "$(cat "$roles/epsilon.md")" = "$before" ] \
                 && ok "--handoff refuses a future stamp, file untouched ($h)" || bad "--handoff future ($h): $err"; }
    done
    "$CR" --set --handoff "$home/fut-h3.md" --file "$roles/epsilon.md" >/dev/null \
        && ok "--handoff accepts past stamps and a dated future schedule mid-line" || bad "--handoff refused fut-h3"
else
    ok "future-time checks skipped within 30 min of midnight"
fi

# --set route= / parked=: config fields, validated, and not a check-in (updated isn't stamped).
cat > "$roles/kappa.md" <<'EOF'
---
metadata:
  role: "Kappa role"
  status: "idle"
  updated: 2026-01-01 00:00
---
EOF
"$CR" --set route=lane-one --file "$roles/kappa.md" \
    && ok "--set accepts a known route" || bad "--set refused lane-one"
grep -qx '  route: "lane-one"' "$roles/kappa.md" && ok "route written at the role fields' indent" || bad "route line: $(grep route "$roles/kappa.md")"
grep -qx '  updated: 2026-01-01 00:00' "$roles/kappa.md" && ok "route= leaves updated alone" || bad "route= stamped updated"
"$CR" --set parked="Owner: parked for the test" --file "$roles/kappa.md" \
    && ok "--set accepts parked=" || bad "--set refused parked="
got=$("$CR" --list | awk -F'\t' '$1 == "kappa" { print $3 "|" $5 }')
[ "$got" = "Owner: parked for the test|lane-one" ] && ok "--list reads back parked and route" || bad "--list kappa: $got"
for r in -h --help "lane-two extra" "ZAI" 'a_b'; do
    err=$("$CR" --set route="$r" --file "$roles/kappa.md" 2>&1) && bad "--set accepted route $r" || ok "--set refuses route $r"
    [ -n "$err" ] && ok "route $r refusal says why" || bad "route $r refused silently"
done
grep -qx '  route: "lane-one"' "$roles/kappa.md" && ok "refused routes leave the file alone" || bad "a refused route was written"
"$CR" --set route= parked= --file "$roles/kappa.md" && ok "--set clears route and parked" || bad "--set route= parked= failed"
got=$("$CR" --list | awk -F'\t' '$1 == "kappa" { print $3 "|" $5 }')
[ "$got" = "|" ] && ok "cleared fields read back empty" || bad "cleared kappa: $got"
"$CR" --set status="checked" route=lane-two --file "$roles/kappa.md" >/dev/null
grep -q '  updated: 2026-01-01 00:00' "$roles/kappa.md" && bad "status= with route= didn't stamp updated" || ok "status= still stamps updated alongside route="
# status_at: its own age stamp, bumped by every status= write (same text included), by no other verb.
cat > "$roles/lam.md" <<'EOF'
---
metadata:
  role: "Lam role"
  status: "steady"
  updated: 2026-01-01 00:00
  status_at: 2026-01-01 00:00
---

## Handoff

## Next
EOF
"$CR" --set holds="x" --file "$roles/lam.md" >/dev/null
grep -qx '  status_at: 2026-01-01 00:00' "$roles/lam.md" && ok "holds= leaves status_at alone" || bad "holds= touched status_at"
"$CR" --note "n" --file "$roles/lam.md" >/dev/null
grep -qx '  status_at: 2026-01-01 00:00' "$roles/lam.md" && ok "--note leaves status_at alone" || bad "--note touched status_at"
"$CR" --next "m" --file "$roles/lam.md" >/dev/null
grep -qx '  status_at: 2026-01-01 00:00' "$roles/lam.md" && ok "--next leaves status_at alone" || bad "--next touched status_at"
"$CR" --set status="steady" --file "$roles/lam.md" >/dev/null
[ "$(grep -c '^  status_at: ' "$roles/lam.md")" = 1 ] && ! grep -qx '  status_at: 2026-01-01 00:00' "$roles/lam.md" \
    && grep -qE '^  status_at: [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$' "$roles/lam.md" \
    && ok "same-text status= restamps status_at" || bad "same-text status= status_at: $(grep status_at "$roles/lam.md")"
lam_at=$(sed -n 's/^  status_at: //p' "$roles/lam.md")
json_at=$("$CR" --json | jq -r '.roles[] | select(.file == "lam.md") | .status_at')
[ -n "$lam_at" ] && [ "$json_at" = "$lam_at" ] && ok "--json carries status_at" || bad "--json status_at '$json_at' vs file '$lam_at'"
printf -- '---\nrole: "Mu"\n---\n\n## Next\n- none\n' > "$roles/mu.md"
mu_at=$("$CR" --json | jq -r '.roles[] | select(.file == "mu.md") | .status_at')
[ "$mu_at" = "" ] && ok "--json status_at is empty for a role without it" || bad "--json status_at for mu: '$mu_at'"
printf -- '---\nrole: "Nu role"\nstatus: "a"\nupdated: 2026-01-01 00:00\n---\n' > "$roles/nu.md"
"$CR" --set status="b" --file "$roles/nu.md" >/dev/null
grep -qE '^status_at: [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$' "$roles/nu.md" && ok "top-level status= writes a bare status_at" || bad "top-level status_at: $(cat "$roles/nu.md")"
cp "$roles/lam.md" "$home/lam.before"
"$CR" --set status_at="x" --file "$roles/lam.md" >/dev/null 2>&1 && bad "--set accepted status_at=" || ok "--set refuses status_at="
cmp -s "$roles/lam.md" "$home/lam.before" && ok "refused status_at leaves the file unchanged" || bad "refused status_at changed the file"
# Through a symlink (as from ~/.local/bin), the tool still finds its sibling lib/next_due.py and
# hooks/lib/config-env.sh: --size counts the "Due now" line of a due bullet.
ln -s "$CR" "$home/claude-role-link"
printf -- '---\nrole: "Link role"\n---\n\n## Next\n- overdue step (due 2020-01-01)\n' > "$roles/link.md"
via_link=$("$home/claude-role-link" --size --file "$roles/link.md" 2>&1)
direct=$("$CR" --size --file "$roles/link.md" 2>&1)
grep -q '^link.md: [0-9]*/10000 chars at session start' <<< "$via_link" && [ "$via_link" = "$direct" ] \
    && ok "a symlinked claude-role finds lib/next_due.py" || bad "symlinked --size: '$via_link' vs '$direct'"
rm "$roles/link.md"

# --handoff FILE replaces the Handoff section (heading to the next ## heading) and nothing else;
# every write prints the file's size against the session-start limit.
printf '\n## Charter\nkeep me\n\n## Handoff (old)\n- old line\n\n## Next\n1. keep me too\n' >> "$roles/kappa.md"
printf '## Handoff (new)\n- new line\n' > "$home/h.md"
out=$("$CR" --set --handoff "$home/h.md" --file "$roles/kappa.md")
grep -q 'old line' "$roles/kappa.md" && bad "--handoff kept the old section" || ok "--handoff drops the old section"
[ "$(sed -n '/^## Charter/,$p' "$roles/kappa.md")" = "$(printf '## Charter\nkeep me\n\n## Handoff (new)\n- new line\n\n## Next\n1. keep me too')" ] \
    && ok "--handoff replaces only its section" || bad "--handoff body: $(sed -n '/^## Charter/,$p' "$roles/kappa.md")"
[[ "$out" =~ ^kappa\.md:\ [0-9]+/10000\ chars\ at\ session\ start\ \(rendered,\ not\ wc\ bytes\)$ ]] && ok "--set prints chars/10000 at session start" || bad "--set size line: $out"
hook_u16=$(echo '{"source":"startup","cwd":"'"$home"'/Projects/kappa"}' | "$CR" \
    | python3 -c 'import sys; print(len(sys.stdin.buffer.read().decode("utf-8").encode("utf-16-le")) // 2)')
[ "$out" = "kappa.md: $hook_u16/10000 chars at session start (rendered, not wc bytes)" ] \
    && ok "size line N equals UTF-16 length of actual hook stdout" || bad "size $out vs hook $hook_u16"
printf 'no heading\n' > "$home/bad.md"
"$CR" --set --handoff "$home/bad.md" --file "$roles/kappa.md" 2>/dev/null && bad "--handoff took a file without a Handoff heading" || ok "--handoff needs its heading"
printf '## Handoff\n- x\n\n## Next\n- smuggled\n' > "$home/bad.md"
"$CR" --set --handoff "$home/bad.md" --file "$roles/kappa.md" 2>/dev/null && bad "--handoff took a second section" || ok "--handoff refuses a second section"
grep -q 'smuggled' "$roles/kappa.md" && bad "a refused handoff was written" || ok "refused handoffs leave the file alone"
# A line that merely opens with an inline code span is no fence: the sections after it survive.
printf -- '---\nrole: "Xi"\n---\n\n## Handoff (old)\n- wrapped\n````span` then text\n\n## Next\n1. keep\n\n## Needs Owner\n- keep too\n' > "$roles/xi.md"
"$CR" --set --handoff "$home/h.md" --file "$roles/xi.md" >/dev/null
[ "$(sed -n '/^## Handoff/,$p' "$roles/xi.md")" = "$(printf '## Handoff (new)\n- new line\n\n## Next\n1. keep\n\n## Needs Owner\n- keep too')" ] \
    && ok "--handoff: an inline span at line start keeps later sections" || bad "--handoff ate sections: $(sed -n '/^## Handoff/,$p' "$roles/xi.md")"
# A real fence still hides a heading inside it, including a shorter fence inside a longer one.
printf -- '---\nrole: "Omi"\n---\n\n## Handoff (old)\n````sh\n```\n## not a section\n```\n````\n\n## Next\n1. keep\n' > "$roles/omi.md"
"$CR" --set --handoff "$home/h.md" --file "$roles/omi.md" >/dev/null
[ "$(sed -n '/^## Handoff/,$p' "$roles/omi.md")" = "$(printf '## Handoff (new)\n- new line\n\n## Next\n1. keep')" ] \
    && ok "--handoff: a heading inside a fence doesn't count" || bad "--handoff fence: $(sed -n '/^## Handoff/,$p' "$roles/omi.md")"
# An unclosed fence would hide every later section, so the write is refused and the file left alone.
printf -- '---\nrole: "Pi"\n---\n\n## Handoff (old)\n```\nnever closed\n\n## Next\n1. keep\n' > "$roles/pi.md"
before=$(cat "$roles/pi.md")
out=$("$CR" --set --handoff "$home/h.md" --file "$roles/pi.md" 2>&1) && bad "--handoff wrote past an unclosed fence" || ok "--handoff exits nonzero on an unclosed fence"
grep -q 'pi.md has an unclosed code fence' <<< "$out" && ok "--handoff names the unclosed fence" || bad "unclosed fence message: $out"
[ "$(cat "$roles/pi.md")" = "$before" ] && ok "a refused unclosed fence leaves the file alone" || bad "unclosed fence changed the file"
# A new handoff with an unclosed fence would hide the sections after it, so it's refused too.
printf '## Handoff (new)\n```\nnever closed\n' > "$home/open.md"
printf -- '---\nrole: "Rho"\n---\n\n## Handoff (old)\n- old\n\n## Next\n1. keep\n' > "$roles/rho.md"
before=$(cat "$roles/rho.md")
out=$("$CR" --set --handoff "$home/open.md" --file "$roles/rho.md" 2>&1) && bad "--handoff took an unclosed fence in the new text" || ok "--handoff exits nonzero on an unclosed new fence"
grep -q 'open.md has an unclosed code fence' <<< "$out" && ok "--handoff names the new file's fence" || bad "new fence message: $out"
[ "$(cat "$roles/rho.md")" = "$before" ] && ok "a refused new fence leaves the file alone" || bad "new fence changed the file"
# Tilde fences hide headings; an info-string line doesn't close a fence; a closer may have trailing
# spaces; four-space-indented backticks are no fence, so they can't leave one open.
printf -- '---\nrole: "Sigma"\n---\n\n## Handoff (old)\n~~~\n## tilde\n~~~\n```sh\n```sh\n## info\n```  \n    ```\n\n## Next\n1. keep\n' > "$roles/sigma.md"
"$CR" --set --handoff "$home/h.md" --file "$roles/sigma.md" >/dev/null
[ "$(sed -n '/^## Handoff/,$p' "$roles/sigma.md")" = "$(printf '## Handoff (new)\n- new line\n\n## Next\n1. keep')" ] \
    && ok "--handoff: tilde, info-string, trailing-space and indented cases" || bad "--handoff fence forms: $(sed -n '/^## Handoff/,$p' "$roles/sigma.md")"
# no Handoff section yet: it goes in before ## Next
printf -- '---\nrole: "Lambda"\n---\n\n## Charter\nc\n\n## Next\n1. n\n' > "$roles/lambda.md"
"$CR" --set --handoff "$home/h.md" --file "$roles/lambda.md" >/dev/null
[ "$(sed -n '/^## Charter/,$p' "$roles/lambda.md")" = "$(printf '## Charter\nc\n\n## Handoff (new)\n- new line\n\n## Next\n1. n')" ] \
    && ok "--handoff inserts before ## Next" || bad "--handoff insert: $(sed -n '/^## Charter/,$p' "$roles/lambda.md")"
# Handoff as the last section: the file's final newline survives (and a missing one stays missing)
printf -- '---\nrole: "Mu"\n---\n\n## Next\n1. n\n\n## Handoff (old)\n- old\n' > "$roles/mu.md"
"$CR" --set --handoff "$home/h.md" --file "$roles/mu.md" >/dev/null
[ "$(tail -c 11 "$roles/mu.md")" = "- new line" ] && [ -z "$(tail -c 1 "$roles/mu.md")" ] && [ "$(tail -c 2 "$roles/mu.md" | wc -l)" = 1 ] \
    && ok "--handoff keeps the final newline when Handoff is last" || bad "--handoff last-section tail: $(tail -c 20 "$roles/mu.md" | od -An -c)"
printf -- '---\nrole: "Mu"\n---\n\n## Handoff (old)\n- old' > "$roles/mu.md"
"$CR" --set --handoff "$home/h.md" --file "$roles/mu.md" >/dev/null
[ "$(tail -c 1 "$roles/mu.md")" = "e" ] && ok "--handoff adds no newline the file didn't have" || bad "--handoff no-newline tail: $(tail -c 5 "$roles/mu.md" | od -An -c)"
# no Handoff and no Next: appended last, after a blank line
printf -- '---\nrole: "Mu"\n---\n\n## Charter\nc\n' > "$roles/mu.md"
"$CR" --set --handoff "$home/h.md" --file "$roles/mu.md" >/dev/null
[ "$(sed -n '/^## Charter/,$p' "$roles/mu.md")" = "$(printf '## Charter\nc\n\n## Handoff (new)\n- new line')" ] && [ -z "$(tail -c 1 "$roles/mu.md")" ] \
    && ok "--handoff appends after a blank line, newline kept" || bad "--handoff append: $(sed -n '/^## Charter/,$p' "$roles/mu.md" | od -c | tail -3)"
# a `## Handoff` inside a code fence is not the section; `## Handoffs` is not a Handoff heading
printf -- '---\nrole: "Mu"\n---\n\n## Charter\n```\n## Handoff\nexample\n```\n\n## Handoffs log\n- keep\n\n## Handoff (old)\n- old\n' > "$roles/mu.md"
"$CR" --set --handoff "$home/h.md" --file "$roles/mu.md" >/dev/null
grep -q '^example$' "$roles/mu.md" && grep -q '^- keep$' "$roles/mu.md" && ! grep -q '^- old$' "$roles/mu.md" \
    && ok "--handoff skips fenced and look-alike headings" || bad "--handoff fence/look-alike: $(sed -n '/^## Charter/,$p' "$roles/mu.md")"
# two Handoff sections: refused, file untouched
printf -- '---\nrole: "Mu"\n---\n\n## Handoff (a)\n- a\n\n## Handoff (b)\n- b\n' > "$roles/mu.md"
before=$(cat "$roles/mu.md")
"$CR" --set --handoff "$home/h.md" --file "$roles/mu.md" 2>/dev/null && bad "--handoff took a file with two Handoff sections" || ok "--handoff refuses two Handoff sections"
[ "$(cat "$roles/mu.md")" = "$before" ] && ok "two-Handoff refusal leaves the file alone" || bad "two-Handoff file changed"
"$CR" --set --handoff "$home/absent.md" --file "$roles/mu.md" 2>/dev/null && bad "--handoff took a missing file" || ok "--handoff refuses a missing file"
"$CR" --set --file "$roles/mu.md" --handoff 2>/dev/null && bad "--handoff with no FILE was accepted" || ok "--handoff needs a FILE"
rm "$roles/kappa.md" "$roles/lambda.md" "$roles/mu.md"

# Hook mode prints its guidance literally: a `command` in the text must not run inside the heredoc.
out=$(echo '{"source":"clear","cwd":"'"$home"'/Projects/alpha"}' | "$CR")
grep -qF 'comes from `date`, never a guess' <<< "$out" && ok "hook text keeps \`date\` literal" || bad "hook text: $(grep -F 'comes from' <<< "$out")"
grep -qF '"## Needs Owner"' <<< "$out" && ok "hook text names the Needs Owner section" || bad "hook text lacks Needs Owner"
# A headless run (a launcher sets SYG_ROLE_HEADLESS=1) in a role's folder gets no role identity:
# a worker in a repo worktree was told it was that repo's session and trimmed its role file.
out=$(echo '{"source":"startup","cwd":"'"$home"'/Projects/alpha"}' | SYG_ROLE_CONTEXT_LINE='[Ctx] machine line' SYG_ROLE_HEADLESS=1 "$CR")
[ "$(sed -n 1p <<< "$out")" = '[Ctx] machine line' ] && ! grep -qF 'You are the' <<< "$out" \
  && grep -qF 'not a role session' <<< "$out" && ! grep -qF 'Alpha role' <<< "$out" \
  && ok "hook: a headless run gets the context line, no role identity, never the role file" || bad "hook headless: $out"
# A named task session (a launcher sets SYG_ROLE_TASK) runs in a role's folder but is not that role:
# it hears its task name and no role identity.
out=$(echo '{"source":"startup","cwd":"'"$home"'/Projects/alpha"}' | SYG_ROLE_CONTEXT_LINE='[Ctx] machine line' SYG_ROLE_TASK="Weekly mining" "$CR")
[ "$(sed -n 1p <<< "$out")" = '[Ctx] machine line' ] \
  && ! grep -qF 'You are the' <<< "$out" && grep -qF '"Weekly mining" task session' <<< "$out" \
  && grep -qF 'not a role session' <<< "$out" && ! grep -qF 'Alpha role' <<< "$out" \
  && ok "hook: a task session hears its task name and the context line, never the role file" || bad "hook task: $out"
# The pre-0.3.176 names are not read any more.
out=$(echo '{"source":"startup","cwd":"'"$home"'/Projects/alpha"}' | CLAUDE_ROLE_HEADLESS=1 "$CR")
grep -qF 'You are the "Alpha role" session' <<< "$out" && ! grep -qF 'Headless run' <<< "$out" \
  && ok "hook: CLAUDE_ROLE_HEADLESS is ignored" || bad "hook old headless name honoured: $out"
out=$(echo '{"source":"startup","cwd":"'"$home"'/Projects/alpha"}' | CLAUDE_ROLE_TASK="Old task" "$CR")
grep -qF 'You are the "Alpha role" session' <<< "$out" && ! grep -qF 'task session' <<< "$out" \
  && ok "hook: CLAUDE_ROLE_TASK is ignored" || bad "hook old task name honoured: $out"

# --set writes the calling session's role (its process cwd via CLAUDE_PID), not the shell's cwd: a
# session that cd's into another repo must not overwrite that repo's role.
mkdir -p "$home/Projects/mine" "$home/Projects/theirs"
for r in mine theirs; do printf -- '---\nmetadata:\n  role: "%s"\n  status: "old"\n---\n' "$r" > "$roles/$r.md"; done
(cd "$home/Projects/mine" && exec sleep 30) & sess=$!
sleep 0.2
(cd "$home/Projects/theirs" && CLAUDE_PID=$sess "$CR" --set status="from mine" >/dev/null)
kill "$sess" 2>/dev/null; wait "$sess" 2>/dev/null
grep -q 'status: "from mine"' "$roles/mine.md" && grep -q 'status: "old"' "$roles/theirs.md" \
  && ok "--set follows the session's own folder, not the cwd it was run from" \
  || bad "--set wrote the cwd's role (mine: $(grep status "$roles/mine.md"); theirs: $(grep status "$roles/theirs.md"))"
(cd "$home/Projects/theirs" && CLAUDE_PID='' "$CR" --set status="no session" >/dev/null)
grep -q 'status: "no session"' "$roles/theirs.md" && ok "--set without CLAUDE_PID still uses the cwd" \
  || bad "--set without CLAUDE_PID: $(grep status "$roles/theirs.md")"

# 10. CLAUDE_PID resolution works for --need as for --set.
(cd "$home/Projects/mine" && exec sleep 30) & sess=$!
sleep 0.2
(cd "$home/Projects/theirs" && CLAUDE_PID=$sess "$CR" --need "Review PR — unblocks merge" >/dev/null)
kill "$sess" 2>/dev/null; wait "$sess" 2>/dev/null
grep -q '^- Review PR — unblocks merge (added ' "$roles/mine.md" && ! grep -q 'Review PR' "$roles/theirs.md" \
  && ok "--need follows CLAUDE_PID to the session's folder" \
  || bad "--need CLAUDE_PID: mine=$(cat "$roles/mine.md") theirs=$(cat "$roles/theirs.md")"
rm "$roles/mine.md" "$roles/theirs.md"

# 1. A role file under 8000 bytes whose render exceeds 10000 gets the warning from hook mode, not the file.
python3 - "$roles/under8k.md" <<'PY'
import sys
body = "x" * 6700
# The long role name counts twice (the preamble names it too), which is what carries the render past
# the cap: a short name no longer gets there under 8000 bytes.
name = "Under8k role " + "n" * 1100
open(sys.argv[1], "w").write(f'---\nrole: "{name}"\n---\n\n## Charter\n{body}\nUNDER8K_BODY_MARKER\n')
PY
[ "$(wc -c < "$roles/under8k.md")" -lt 8000 ] && ok "under8k fixture is under 8000 bytes" || bad "under8k bytes: $(wc -c < "$roles/under8k.md")"
out=$(echo '{"source":"startup","cwd":"'"$home"'/Projects/under8k"}' | "$CR")
grep -qF 'renders to ' <<< "$out" && grep -qF '/10000 characters at session start, and Claude Code replaces hook output past 10000 characters with a 2 KB preview.' <<< "$out" \
  && ! grep -qF 'UNDER8K_BODY_MARKER' <<< "$out" \
  && ok "hook warns on <8000-byte file whose render exceeds 10000 chars" || bad "under8k hook: $out"
rm "$roles/under8k.md"

# 2 & 3. Multibyte fixture (em-dashes) over 8000 bytes whose render is <= 10000 units is shown whole;
# emoji fixture counts 2 UTF-16 units per emoji; size line N matches hook stdout UTF-16 length.
python3 - "$roles/emdash.md" <<'PY'
import sys
dashes = ("—" * 70 + "\n") * 40   # 2800 em-dashes = 8400 bytes, ~2840 UTF-16 units
open(sys.argv[1], "w").write(f'---\nrole: "Emdash role"\nstatus: "ok"\n---\n\n## Charter\n{dashes}EMDASH_MARKER\n')
PY
[ "$(wc -c < "$roles/emdash.md")" -gt 8000 ] && ok "emdash fixture is over 8000 bytes" || bad "emdash bytes: $(wc -c < "$roles/emdash.md")"
out=$(echo '{"source":"startup","cwd":"'"$home"'/Projects/emdash"}' | "$CR")
grep -qF 'EMDASH_MARKER' <<< "$out" && ! grep -qF 'replaces hook output' <<< "$out" \
  && ok "hook shows >8000-byte multibyte file whole when render <= 10000 units" || bad "emdash hook: $out"
sz_line=$("$CR" --set status="ok" --file "$roles/emdash.md")
hook_u16=$(echo '{"source":"startup","cwd":"'"$home"'/Projects/emdash"}' | "$CR" \
    | python3 -c 'import sys; print(len(sys.stdin.buffer.read().decode("utf-8").encode("utf-16-le")) // 2)')
[ "$sz_line" = "emdash.md: $hook_u16/10000 chars at session start (rendered, not wc bytes)" ] \
  && ok "emdash size line matches hook stdout UTF-16 units" || bad "emdash size '$sz_line' vs $hook_u16"

printf -- '---\nrole: "Emoji role"\nstatus: "base"\n---\n\n## Charter\nhi\n' > "$roles/emoji.md"
s1=$("$CR" --set status="base" --file "$roles/emoji.md")
s2=$("$CR" --set status="base 🙂🙂🙂🙂🙂" --file "$roles/emoji.md")
n1=${s1#emoji.md: }; n1=${n1%/10000*}
n2=${s2#emoji.md: }; n2=${n2%/10000*}
[ $((n2 - n1)) -eq 11 ] && grep -q 'status: "base 🙂🙂🙂🙂🙂"' "$roles/emoji.md" \
  && ok "emoji fixture counts 2 UTF-16 units per emoji (1 space + 5 emojis = 11)" || bad "emoji delta: $n1 -> $n2"
rm "$roles/emdash.md" "$roles/emoji.md"

# 4. Refusal: growth past the cap exits 1, leaves the file byte-identical, names over-by and largest
# sections (fence-aware). Same-size or shrinking write on an over-cap file passes. route=/parked=
# pass on an over-cap file. Status growth on an over-cap file refuses.
today_stamp=$(date '+%F %H:%M')
python3 - "$roles/cap.md" "$today_stamp" <<'PY'
import sys
path, stamp = sys.argv[1], sys.argv[2]
charter = "c" * 400
handoff = "```sh\n## Ignored fenced heading\n" + ("h" * 6000) + "\n```\n"
nxt = "n" * 2100
open(path, "w").write(
    f'---\nrole: "Cap role"\nstatus: "busy"\nupdated: {stamp}\n---\n\n'
    f'## Charter\n{charter}\n\n## Handoff\n{handoff}\n\n## Next\n{nxt}\n'
)
PY
before=$(cat "$roles/cap.md")
err=$("$CR" --note "$(printf '%0200d' 0)" --file "$roles/cap.md" 2>&1); rc=$?
[ $rc = 1 ] && ok "growth past 10000 exits 1" || bad "growth past 10000 rc=$rc ($err)"
[ "$(cat "$roles/cap.md")" = "$before" ] && ok "refused write leaves file byte-identical" || bad "refused write modified cap.md"
[[ "$err" =~ ^claude-role:\ refused,\ nothing\ written:\ cap\.md\ would\ render\ [0-9]+/10000\ chars\ at\ session\ start\ \(over\ by\ [0-9]+\)\.\ Largest\ sections:\ Handoff\ [0-9]+,\ Next\ [0-9]+,\ Charter\ [0-9]+\.\ Trim\ one\ \(rewrite\ Handoff,\ don\'t\ append\),\ then\ rerun\.$ ]] \
  && ok "refusal names over-by and top 3 fence-aware sections in order" || bad "refusal message: $err"

# Over-cap file: already > 10000 units.
python3 - "$roles/over.md" "$today_stamp" <<'PY'
import sys
path, stamp = sys.argv[1], sys.argv[2]
open(path, "w").write(
    f'---\nrole: "Over role"\nstatus: "busy"\nupdated: {stamp}\n---\n\n'
    f'## Charter\n{"c" * 500}\n\n## Handoff\n{"h" * 6300}\n\n## Next\n{"n" * 2200}\n'
)
PY
out=$("$CR" --set route=lane-two parked="parked while over cap" --file "$roles/over.md" 2>&1); rc=$?
[ $rc = 0 ] && grep -q '^route: "lane-two"$' "$roles/over.md" && grep -q '^parked: "parked while over cap"$' "$roles/over.md" \
  && ok "route=/parked= pass on an over-cap file" || bad "route/parked on over-cap: rc=$rc $out"
# Refresh updated to current minute so status change has zero timestamp delta.
sed -i "s/^updated: .*/updated: $(date '+%F %H:%M')/" "$roles/over.md"
# The stamp allowance is exact: one character of status growth on the write that inserts status_at refuses.
cp "$roles/over.md" "$roles/over1.md"
"$CR" --set status="busyx" --file "$roles/over1.md" >/dev/null 2>&1; rc=$?
[ $rc = 1 ] && cmp -s "$roles/over.md" "$roles/over1.md" \
  && ok "first status= write that grows the text by one char still refuses on an over-cap file" || bad "stamp allowance let growth through: rc=$rc"
rm "$roles/over1.md"
out=$("$CR" --set status="idle" --file "$roles/over.md" 2>&1); rc=$?
[ $rc = 0 ] && grep -q '^status: "idle"$' "$roles/over.md" \
  && ok "same-size write on an over-cap file passes" || bad "same-size on over-cap: rc=$rc $out"
grep -qE '^status_at: [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$' "$roles/over.md" \
  && ok "an over-cap file's first status= write adds status_at" || bad "over-cap first status= wrote no status_at: $(grep status_at "$roles/over.md")"
out=$("$CR" --set status="ok" --file "$roles/over.md" 2>&1); rc=$?
[ $rc = 0 ] && grep -q '^status: "ok"$' "$roles/over.md" \
  && ok "shrinking write on an over-cap file passes" || bad "shrinking on over-cap: rc=$rc $out"
before_over=$(cat "$roles/over.md")
err=$("$CR" --set status="growing status on an already over-cap file" --file "$roles/over.md" 2>&1); rc=$?
[ $rc = 1 ] && [ "$(cat "$roles/over.md")" = "$before_over" ] \
  && ok "status growth on an over-cap file refuses and leaves file unchanged" || bad "status growth on over-cap: rc=$rc $err"

# Over-cap file with no updated: line; a holds= write that changes nothing else passes and adds updated: (a stamp, not growth).
python3 - "$roles/over-noupd.md" <<'PY'
import sys
path = sys.argv[1]
open(path, "w").write(
    f'---\nrole: "Over role"\nstatus: "busy"\nholds: "h"\n---\n\n'
    f'## Charter\n{"c" * 500}\n\n## Handoff\n{"h" * 6300}\n\n## Next\n{"n" * 2200}\n'
)
PY
cp "$roles/over-noupd.md" "$roles/over-noupd.before"
# The cap guard: one char of holds growth on this fixture refuses (so the fixture really is over cap).
cp "$roles/over-noupd.md" "$roles/over-noupd1.md"
out=$("$CR" --set holds="hh" --file "$roles/over-noupd1.md" 2>&1); rc=$?
[ $rc = 1 ] && cmp -s "$roles/over-noupd.md" "$roles/over-noupd1.md" \
  && ok "over-noupd fixture is over the cap: one char of holds growth refuses" || bad "over-noupd fixture not over cap: rc=$rc $out"
rm "$roles/over-noupd1.md"
out=$("$CR" --set holds="h" --file "$roles/over-noupd.md" 2>&1); rc=$?
# Byte-exact: the file minus the inserted updated: line equals the pre-write file.
[ $rc = 0 ] && grep -q '^updated: ' "$roles/over-noupd.md" \
  && grep -v '^updated: ' "$roles/over-noupd.md" | cmp -s - "$roles/over-noupd.before" \
  && ok "over-cap file without updated: a holds= write that changes nothing else passes and adds updated:" \
  || bad "over-cap file without updated: rc=$rc $out (file minus updated: line changed, or no updated: line)"
rm "$roles/over-noupd.md" "$roles/over-noupd.before"
rm "$roles/cap.md" "$roles/over.md"

# 5. --need: Needs and --deck targets, tag order with --due, date stamp equals date +%F,
# placeholder - (none), Nothing open. and _(nothing pending)_ replaced, section created in the
# right place, duplicate not re-added, kept (added) date, --json reads back what/unblocks/added/due.
today=$(date +%F)
printf -- '---\nrole: "Need role"\nstatus: "working"\n---\n\n## Charter\nc\n\n## In Person\n- (none)\n' > "$roles/need.md"
# Missing ## Needs Owner is created before ## In Person.
out=$("$CR" --need "Approve schema — unblocks migration" --due 2026-11-20 --file "$roles/need.md")
grep -q "^- Approve schema — unblocks migration (due 2026-11-20) (added $today)$" "$roles/need.md" \
  && ok "--need writes bullet with (due D) (added TODAY)" || bad "--need bullet: $(cat "$roles/need.md")"
[ "$(grep -n '^## ' "$roles/need.md" | awk -F: '{print $2}' | paste -sd, -)" = "## Charter,## Needs Owner,## In Person" ] \
  && ok "--need creates ## Needs Owner before ## In Person" || bad "section order: $(grep '^## ' "$roles/need.md")"
# --deck replaces - (none) in ## In Person.
out=$("$CR" --need "- Plug in YubiKey — unblocks signing" --deck --file "$roles/need.md")
grep -q "^- Plug in YubiKey — unblocks signing (added $today)$" "$roles/need.md" && ! grep -q '(none)' "$roles/need.md" \
  && ok "--need --deck strips leading '- ' and replaces - (none)" || bad "--need --deck: $(cat "$roles/need.md")"
# Duplicate (ignoring tags) is not re-added, prints already there, exits 0.
out=$("$CR" --need "Approve schema — unblocks migration" --file "$roles/need.md"); rc=$?
[ $rc = 0 ] && grep -q '^already there: - Approve schema — unblocks migration' <<< "$out" \
  && [ "$(grep -c 'Approve schema' "$roles/need.md")" = 1 ] \
  && ok "--need does not re-add a duplicate bullet" || bad "--need duplicate: rc=$rc out=$out"
# Kept (added YYYY-MM-DD) date gets no second tag.
"$CR" --need "Old ask — unblocks archive (added 2026-08-15)" --file "$roles/need.md" >/dev/null
grep -q '^- Old ask — unblocks archive (added 2026-08-15)$' "$roles/need.md" \
  && ok "--need keeps existing (added YYYY-MM-DD) without a second tag" || bad "kept added: $(cat "$roles/need.md")"
# --json reads back the new bullet with what/unblocks/added/due.
got=$("$CR" --json | jq -c '.roles[] | select(.file == "need.md") | [.needs[0], .deck[0]]')
[ "$got" = '[{"what":"Approve schema","unblocks":"unblocks migration","added":"'"$today"'","due":"2026-11-20"},{"what":"Plug in YubiKey","unblocks":"unblocks signing","added":"'"$today"'"}]' ] \
  && ok "--json reads back --need bullets with what/unblocks/added/due" || bad "--json need.md: $got"

# Filler shapes `Nothing open.` and `_(nothing pending)_`, and section creation at end without final newline.
printf -- '---\nrole: "Filler1"\n---\n\n## Needs Owner\nNothing open.\n\n## In Person\n_(nothing pending)_' > "$roles/filler.md"
"$CR" --need "First need" --file "$roles/filler.md" >/dev/null
"$CR" --need "First visit" --deck --file "$roles/filler.md" >/dev/null
! grep -qi 'nothing' "$roles/filler.md" && grep -q "^- First need (added $today)$" "$roles/filler.md" \
  && grep -q "^- First visit (added $today)$" "$roles/filler.md" && [ -n "$(tail -c 1 "$roles/filler.md")" ] \
  && ok "--need replaces Nothing open. and _(nothing pending)_ and preserves no-final-newline" \
  || bad "filler replacement: $(cat "$roles/filler.md")"
# Missing sections created at end when neither exists.
printf -- '---\nrole: "NoSec"\n---\n\n## Charter\nc\n' > "$roles/filler.md"
"$CR" --need "End need" --file "$roles/filler.md" >/dev/null
"$CR" --need "End deck" --deck --file "$roles/filler.md" >/dev/null
[ "$(grep '^## ' "$roles/filler.md" | paste -sd, -)" = "## Charter,## Needs Owner,## In Person" ] \
  && ok "--need creates missing Needs Owner and In Person at the end" || bad "end creation: $(cat "$roles/filler.md")"
rm "$roles/need.md" "$roles/filler.md"

# 6. --need-done: one match with continuation lines removed and heading kept; zero and several
# refuse with the file unchanged; a bullet inside a code fence is not matched.
cat > "$roles/done.md" <<'EOF'
---
role: "Done role"
status: "working"
---

## Needs Owner
- Pick the color — unblocks theme (added 2026-10-01)
  indented detail line 1
  indented detail line 2
- Shared word alpha (added 2026-10-02)
```
- Fenced ghost bullet (added 2026-10-03)
```

## In Person
- Shared word beta (added 2026-10-04)
EOF
before_done=$(cat "$roles/done.md")
# Zero matches (including trying to match the fenced bullet): exits 1, lists all bullets, file unchanged.
err=$("$CR" --need-done "fenced ghost" --file "$roles/done.md" 2>&1); rc=$?
[ $rc = 1 ] && [ "$(cat "$roles/done.md")" = "$before_done" ] \
  && grep -q "Pick the color" <<< "$err" && ! grep -q "Fenced ghost" <<< "$err" \
  && ok "--need-done ignores fenced bullets and lists all candidates on zero match" || bad "need-done zero: rc=$rc $err"
# Several matches: exits 1, lists matches, file unchanged.
err=$("$CR" --need-done "SHARED WORD" --file "$roles/done.md" 2>&1); rc=$?
[ $rc = 1 ] && [ "$(cat "$roles/done.md")" = "$before_done" ] \
  && grep -q "Shared word alpha" <<< "$err" && grep -q "Shared word beta" <<< "$err" && ! grep -q "Pick the color" <<< "$err" \
  && ok "--need-done refuses multiple matches and lists only the matching bullets" || bad "need-done several: rc=$rc $err"
# Single match: deletes bullet and continuation lines, keeps heading, prints removed:.
out=$("$CR" --need-done "pick the color" --file "$roles/done.md"); rc=$?
[ $rc = 0 ] && grep -q '^removed: - Pick the color — unblocks theme (added 2026-10-01)$' <<< "$out" \
  && ! grep -q 'Pick the color' "$roles/done.md" && ! grep -q 'indented detail' "$roles/done.md" \
  && grep -q '^## Needs Owner$' "$roles/done.md" && grep -q 'Shared word alpha' "$roles/done.md" \
  && ok "--need-done removes matched bullet and its continuation lines, keeping heading" \
  || bad "need-done single: rc=$rc out=$out file=$(cat "$roles/done.md")"
rm "$roles/done.md"

# 7. --note: appended inside Handoff not after Next, section created before Next, stamp format,
# a two-Handoff file refused.
printf -- '---\nrole: "Note role"\n---\n\n## Charter\nc\n\n## Next\n1. step\n' > "$roles/note.md"
"$CR" --note "created handoff note" --file "$roles/note.md" >/dev/null
[ "$(grep '^## ' "$roles/note.md" | paste -sd, -)" = "## Charter,## Handoff,## Next" ] \
  && grep -Eq '^- \*\*[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:\*\* created handoff note$' "$roles/note.md" \
  && ok "--note creates ## Handoff before ## Next with stamped bullet" || bad "--note create: $(cat "$roles/note.md")"
"$CR" --note "second handoff note" --file "$roles/note.md" >/dev/null
# Verify second note is inside Handoff (before ## Next), not after ## Next.
[ "$(sed -n '/^## Next/,$p' "$roles/note.md")" = "$(printf '## Next\n1. step')" ] \
  && [ "$(grep -c 'handoff note' "$roles/note.md")" = 2 ] \
  && ok "--note appends inside Handoff before ## Next" || bad "--note append position: $(cat "$roles/note.md")"
printf -- '---\nrole: "TwoH"\n---\n\n## Handoff (1)\n- a\n\n## Handoff (2)\n- b\n' > "$roles/note.md"
before_note=$(cat "$roles/note.md")
"$CR" --note "nope" --file "$roles/note.md" 2>/dev/null; rc=$?
[ $rc = 1 ] && [ "$(cat "$roles/note.md")" = "$before_note" ] \
  && ok "--note refuses a file with two Handoff sections" || bad "--note two Handoff: rc=$rc"
rm "$roles/note.md"

# 8. Combination: --set status= with --need and --note is one write; a refusal of any part writes nothing.
printf -- '---\nrole: "Combo role"\nstatus: "old"\n---\n\n## Handoff\n- start\n\n## Next\n1. go\n' > "$roles/combo.md"
out=$("$CR" --set status="new status" --need "Combo ask — unblocks ship" --note "combo checkpoint" --file "$roles/combo.md"); rc=$?
[ $rc = 0 ] && [ "$(wc -l <<< "$out")" = 1 ] \
  && grep -q '^status: "new status"$' "$roles/combo.md" \
  && grep -q "^- Combo ask — unblocks ship (added $today)$" "$roles/combo.md" \
  && grep -Eq '^- \*\*[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:\*\* combo checkpoint$' "$roles/combo.md" \
  && ok "combined --set, --need, and --note writes all three in one pass" || bad "combo write: rc=$rc out=$out file=$(cat "$roles/combo.md")"
# Refusal of one part (e.g. --need-done with no match, or two Handoffs) writes nothing at all.
before_combo=$(cat "$roles/combo.md")
"$CR" --set status="should not land" --need "should not land" --need-done "nonexistent bullet" --file "$roles/combo.md" 2>/dev/null; rc=$?
[ $rc = 1 ] && [ "$(cat "$roles/combo.md")" = "$before_combo" ] \
  && ok "combined write is atomic: refusal of one part writes nothing" || bad "combo partial write: rc=$rc $(cat "$roles/combo.md")"
# The cap refuses the whole combined write too: the status and the note don't land without the need.
{ printf -- '---\nrole: "Combo role"\nstatus: "old"\n---\n\n## Handoff\n- start\n'; head -c 8400 /dev/zero | tr '\0' 'x'; printf '\n'; } > "$roles/combo.md"
before_combo=$(cat "$roles/combo.md")
out=$("$CR" --set status="should not land" --note "$(head -c 400 /dev/zero | tr '\0' 'y')" --need "should not land" --file "$roles/combo.md" 2>&1); rc=$?
[ $rc = 1 ] && grep -q 'refused, nothing written' <<< "$out" && [ "$(cat "$roles/combo.md")" = "$before_combo" ] \
  && ok "combined write past the cap writes nothing" || bad "combo cap: rc=$rc out=$out"
rm "$roles/combo.md"

# An unclosed fence stops the writes that find a section; a checkpoint or a park still gets through.
printf -- '---\nrole: "Open fence"\nstatus: "old"\n---\n\n## Charter\n```\nnever closed\n\n## Needs Owner\n- real ask\n' > "$roles/openf.md"
before_fence=$(cat "$roles/openf.md")
for args in '--need|x' '--need-done|real' '--note|x'; do
    out=$("$CR" "${args%|*}" "${args#*|}" --file "$roles/openf.md" 2>&1); rc=$?
    [ $rc = 1 ] && grep -q 'unclosed code fence' <<< "$out" && [ "$(cat "$roles/openf.md")" = "$before_fence" ] \
      && ok "${args%|*} refuses an unclosed fence, file unchanged" || bad "${args%|*} open fence: rc=$rc $out"
done
"$CR" --set status="still checkpoints" --file "$roles/openf.md" >/dev/null \
  && grep -q '^status: "still checkpoints"$' "$roles/openf.md" \
  && ok "--set status= still writes past an unclosed fence" || bad "--set blocked by an open fence"
"$CR" --set parked="her call" --file "$roles/openf.md" >/dev/null \
  && grep -q '^parked: "her call"$' "$roles/openf.md" \
  && ok "--set parked= still writes past an unclosed fence" || bad "parked= blocked by an open fence"
rm "$roles/openf.md"

# Filler set off by blank lines leaves one blank before the next section, not two; filler that is
# the file's last line doesn't trip the removal.
printf -- '---\nrole: "Filler"\n---\n\n## Needs Owner\n\nNothing open.\n\n## Handoff\n- h\n' > "$roles/fill.md"
"$CR" --need "Ask" --file "$roles/fill.md" >/dev/null; rc=$?
[ $rc = 0 ] && [ "$(sed -n '/^## Needs Owner/,$p' "$roles/fill.md")" = "$(printf '## Needs Owner\n- Ask (added %s)\n\n## Handoff\n- h' "$today")" ] \
  && ok "--need: filler between blanks leaves a single blank" || bad "filler blanks: rc=$rc $(sed -n '/^## Needs Owner/,$p' "$roles/fill.md")"
printf -- '---\nrole: "Filler"\n---\n\n## Needs Owner\n\n- (none)' > "$roles/fill.md"
"$CR" --need "Ask" --file "$roles/fill.md" >/dev/null; rc=$?
[ $rc = 0 ] && [ "$(sed -n '/^## Needs Owner/,$p' "$roles/fill.md")" = "$(printf '## Needs Owner\n- Ask (added %s)' "$today")" ] \
  && ok "--need: filler as the file's last line" || bad "filler at EOF: rc=$rc $(sed -n '/^## Needs Owner/,$p' "$roles/fill.md")"
rm "$roles/fill.md"
[ -n "$("$CR" --help | sed -n '$p')" ] && ok "--help ends on text" || bad "--help ends on a blank line"

# 9. A repeated verb, --due without --need, multi-line text, a bad date, and an unknown flag each
# exit 2 with the file unchanged; --help exits 0.
printf -- '---\nrole: "Err role"\nstatus: "clean"\n---\n\n## Needs Owner\n- existing (added 2026-10-01)\n' > "$roles/err.md"
before_err=$(cat "$roles/err.md")
check_exit2() {
    local label=$1; shift
    "$CR" "$@" --file "$roles/err.md" 2>/dev/null; local rc=$?
    [ $rc = 2 ] && [ "$(cat "$roles/err.md")" = "$before_err" ] \
      && ok "exit 2 + unchanged: $label" || bad "$label: expected rc=2 and unchanged file, got rc=$rc"
}
check_exit2 "repeated --need" --need "one" --need "two"
check_exit2 "repeated --note" --note "one" --note "two"
check_exit2 "repeated --need-done" --need-done "one" --need-done "two"
check_exit2 "repeated --set" --set status="a" --set status="b"
check_exit2 "--due without --need" --set status="a" --due 2026-11-20
check_exit2 "--deck without --need" --set status="a" --deck
check_exit2 "--due with existing (added)" --need "item (added 2026-10-01)" --due 2026-11-20
check_exit2 "multi-line --need" --need $'line 1\nline 2'
check_exit2 "multi-line --note" --note $'line 1\nline 2'
check_exit2 "empty --need" --need ""
check_exit2 "empty --note" --note ""
check_exit2 "empty --need-done" --need-done ""
check_exit2 "bad --due (non-leap Feb 29)" --need "x" --due 2026-02-29
check_exit2 "bad --due (month 13)" --need "x" --due 2026-13-01
check_exit2 "bad --due (format)" --need "x" --due 2026-1-3
check_exit2 "unknown top-level flag" --bogus-flag
check_exit2 "unknown --set flag" --set --bogus-flag
rm "$roles/err.md"

help_out=$("$CR" --help); rc=$?
[ $rc = 0 ] && grep -q -- '--need' <<< "$help_out" && grep -q -- '--note' <<< "$help_out" \
  && grep -q -- '--size' <<< "$help_out" && grep -q -- '--next' <<< "$help_out" && grep -q -- '10000' <<< "$help_out" \
  && ok "--help exits 0 and documents new verbs and 10000 measure" || bad "--help: rc=$rc $help_out"

# 11. --size: line format, N equals a no-op-equivalent --set, file is byte-identical (no write).
now_stamp=$(date '+%F %H:%M')
printf -- '---\nrole: "Size role"\nstatus: "steady"\nupdated: %s\nstatus_at: %s\n---\n\n## Charter\nsize check\n' "$now_stamp" "$now_stamp" > "$roles/size.md"
before_sz=$(cat "$roles/size.md")
sz_out=$("$CR" --size --file "$roles/size.md"); rc=$?
[ $rc = 0 ] && [[ "$sz_out" =~ ^size\.md:\ ([0-9]+)/10000\ chars\ at\ session\ start\ \(headroom\ (-?[0-9]+)\)$ ]] \
  && ok "--size prints '<basename>: N/10000 chars at session start (headroom H)'" || bad "--size format: rc=$rc out=$sz_out"
sz_n=${BASH_REMATCH[1]:-0}; sz_h=${BASH_REMATCH[2]:-0}
[ "$(cat "$roles/size.md")" = "$before_sz" ] && ok "--size does not modify the role file" || bad "--size modified size.md"
set_out=$("$CR" --set status="steady" --file "$roles/size.md")
[ "$set_out" = "size.md: $sz_n/10000 chars at session start (rendered, not wc bytes)" ] && [ "$sz_h" = "$((10000 - sz_n))" ] \
  && ok "--size N and headroom match no-op --set size line" || bad "--size N=$sz_n H=$sz_h vs --set '$set_out'"
"$CR" --size --file "$roles/nonexistent.md" 2>/dev/null; rc=$?
[ $rc = 1 ] && ok "--size exits 1 when there is no role file" || bad "--size missing file rc=$rc"
rm "$roles/size.md"

# 12. --next: appends into existing Next, creates Next before Needs Owner when absent, refuses multi-line
# with exit 2, combines with --note in one call.
printf -- '---\nrole: "Next role"\n---\n\n## Charter\nc\n\n## Next\n- first step\n\n## Needs Owner\n- ask\n' > "$roles/next.md"
"$CR" --next "- second step" --file "$roles/next.md" >/dev/null; rc=$?
[ $rc = 0 ] && [ "$(sed -n '/^## Next/,/^## Needs Owner/p' "$roles/next.md")" = "$(printf '## Next\n- first step\n- second step\n\n## Needs Owner')" ] \
  && ok "--next strips leading '- ' and appends into existing ## Next" || bad "--next append: $(cat "$roles/next.md")"
printf -- '---\nrole: "Next role"\n---\n\n## Charter\nc\n\n## Needs Owner\n- ask\n' > "$roles/next.md"
"$CR" --next "created step" --file "$roles/next.md" >/dev/null; rc=$?
[ $rc = 0 ] && [ "$(grep '^## ' "$roles/next.md" | paste -sd, -)" = "## Charter,## Next,## Needs Owner" ] \
  && grep -q '^- created step$' "$roles/next.md" \
  && ok "--next creates ## Next before ## Needs Owner when absent" || bad "--next create: $(cat "$roles/next.md")"
before_next=$(cat "$roles/next.md")
"$CR" --next $'line 1\nline 2' --file "$roles/next.md" 2>/dev/null; rc=$?
[ $rc = 2 ] && [ "$(cat "$roles/next.md")" = "$before_next" ] \
  && ok "--next refuses multi-line TEXT with exit 2" || bad "--next multi-line: rc=$rc"
"$CR" --note "paired handoff note" --next "paired next bullet" --file "$roles/next.md" >/dev/null; rc=$?
[ $rc = 0 ] && grep -Eq '^- \*\*[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:\*\* paired handoff note$' "$roles/next.md" \
  && grep -q '^- paired next bullet$' "$roles/next.md" \
  && ok "--next combines with --note in one call" || bad "--next + --note: $(cat "$roles/next.md")"
rm "$roles/next.md"

# 13. Auto-archive at the cap: moves oldest stamped notes (with continuation lines) to archive, keeps
# curated bullet, remaining notes, and newly added note.
today=$(date +%F)
python3 - "$roles/arch.md" <<'PY'
import sys
path = sys.argv[1]
n1 = "- **11-01 09:00:** oldest note one " + ("a" * 200) + "\n  indented continuation for note one"
n2 = "- **11-02 10:00:** middle note two " + ("b" * 200)
n3 = "- **11-03 11:00:** newest note three " + ("c" * 200)
open(path, "w").write(
    '---\nrole: "Arch role"\nstatus: "busy"\n---\n\n'
    f'## Charter\n{"x" * 6500}\n\n'
    '## Handoff\n'
    '- Curated non-stamped bullet stays\n'
    f'{n1}\n{n2}\n{n3}\n\n'
    '## Next\n- keep going\n'
)
PY
# Adjust Charter padding using --size so the fixture sits 10 chars below the 10000 cap before the write:
# the new note (~294 chars) then overshoots by more than note one (~272 with its continuation), so
# exactly two notes must move. The base Charter starts well under 9990 (the rendered head, e.g. the
# context line, grows over time); a fixture already past it would skew the count below.
sz_line=$("$CR" --size --file "$roles/arch.md")
cur_n=${sz_line#arch.md: }; cur_n=${cur_n%/10000*}
pad=$((9990 - cur_n))
[ "$pad" -ge 0 ] || bad "auto-archive fixture starts at $cur_n, past 9990: shrink its base Charter"
if [ "$pad" -gt 0 ]; then
    python3 - "$roles/arch.md" "$pad" <<'PY'
import sys
p, k = sys.argv[1], int(sys.argv[2])
s = open(p).read().replace("## Charter\n", "## Charter\n" + ("x" * k), 1)
open(p, "w").write(s)
PY
fi
arch_file="$roles/archive/arch-handoff-archive-$today.md"
out=$("$CR" --note "fresh note added at cap $(printf '%0250d' 0)" --file "$roles/arch.md"); rc=$?
[ $rc = 0 ] && ok "auto-archive write at cap exits 0" || bad "auto-archive rc=$rc out=$out"
grep -q '^- Curated non-stamped bullet stays$' "$roles/arch.md" \
  && grep -q 'fresh note added at cap' "$roles/arch.md" \
  && grep -q 'newest note three' "$roles/arch.md" \
  && ! grep -q 'oldest note one' "$roles/arch.md" \
  && ! grep -q 'middle note two' "$roles/arch.md" \
  && ok "auto-archive keeps curated bullet, un-moved note, and new note" || bad "auto-archive role body: $(grep '^- ' "$roles/arch.md")"
! grep -q 'indented continuation for note one' "$roles/arch.md" \
  && grep -q '^  indented continuation for note one$' "$arch_file" \
  && ok "auto-archive moves continuation line with its note" || bad "auto-archive continuation: $(cat "$arch_file")"
grep -q '^# arch Handoff archive$' "$arch_file" \
  && grep -Eq '^## Moved by claude-role [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} \(oldest Handoff notes, verbatim, to fit the 10000 cap\)$' "$arch_file" \
  && grep -q '^- \*\*11-01 09:00:\*\* oldest note one ' "$arch_file" \
  && grep -q '^- \*\*11-02 10:00:\*\* middle note two ' "$arch_file" \
  && ! grep -q 'newest note three' "$arch_file" \
  && ! grep -q 'Curated non-stamped' "$arch_file" \
  && ok "archive file holds moved notes verbatim under the Moved heading" || bad "archive content: $(cat "$arch_file")"
nl=$'\n'
[[ "$out" =~ ^archived\ 2\ oldest\ Handoff\ notes\ to\ archive/arch-handoff-archive-${today}\.md${nl}arch\.md:\ ([0-9]+)/10000\ chars\ at\ session\ start\ \(rendered,\ not\ wc\ bytes\)$ ]] \
  && [ "${BASH_REMATCH[1]}" -le 10000 ] \
  && ok "auto-archive prints 'archived K ...' before size line with final size <= 10000" || bad "auto-archive stdout: $out"

# --handoff FILE over the cap is still refused, even when the file has stamped notes.
before_arch=$(cat "$roles/arch.md")
before_arch_file=$(cat "$arch_file")
printf '## Handoff\n- replacement %s\n' "$(printf '%01200d' 0)" > "$home/big-h.md"
err=$("$CR" --set --handoff "$home/big-h.md" --file "$roles/arch.md" 2>&1); rc=$?
[ $rc = 1 ] && grep -q 'refused, nothing written' <<< "$err" \
  && [ "$(cat "$roles/arch.md")" = "$before_arch" ] && [ "$(cat "$arch_file")" = "$before_arch_file" ] \
  && ok "--handoff FILE over the cap is refused even when stamped notes exist" || bad "--handoff over cap: rc=$rc $err"
rm "$roles/arch.md" "$arch_file" "$home/big-h.md"

# Second fixture with no stamped notes and a too-long --note is refused, with role file and nonexistent archive untouched.
python3 - "$roles/nonotes.md" <<'PY'
import sys
open(sys.argv[1], "w").write(
    '---\nrole: "NoNotes role"\nstatus: "busy"\n---\n\n'
    f'## Charter\n{"c" * 4800}\n\n'
    f'## Handoff\n- Curated bullet without timestamp {"h" * 3800}\n\n'
    '## Next\n- step\n'
)
PY
before_nn=$(cat "$roles/nonotes.md")
nn_arch="$roles/archive/nonotes-handoff-archive-$today.md"   # case 13 already made $roles/archive, so the file check is the signal
err=$("$CR" --note "$(printf '%0400d' 0)" --file "$roles/nonotes.md" 2>&1); rc=$?
[ $rc = 1 ] && grep -q 'refused, nothing written' <<< "$err" \
  && [ "$(cat "$roles/nonotes.md")" = "$before_nn" ] && [ ! -e "$nn_arch" ] \
  && ok "no-stamped-notes fixture over cap is refused with file and archive untouched" || bad "no-stamped-notes: rc=$rc $err"
rm "$roles/nonotes.md"

# Mixed-stamp Handoffs: the archiver must see all four stamp forms (bold/plain, with or without the
# MM-DD date) and roll the oldest note in document order, not just the bold dated ones (TASK-405).
# Pad a fixture's Charter so it sits just under the 10000 cap before the write: the rendered head
# grows over time, so the fixture is measured, never hard-coded.
pad_under_cap() {
    local f=$1 target=${2:-9990} sz cur pad
    sz=$("$CR" --size --file "$f"); cur=${sz#*: }; cur=${cur%/10000*}
    pad=$((target - cur))
    if [ "$pad" -lt 0 ]; then bad "fixture $(basename "$f") renders at $cur, already past $target"; return 1; fi
    if [ "$pad" -gt 0 ]; then
        python3 - "$f" "$pad" <<'PY'
import sys
p, k = sys.argv[1], int(sys.argv[2])
s = open(p).read().replace("## Charter\n", "## Charter\n" + ("x" * k), 1)
open(p, "w").write(s)
PY
    fi
}
# The regression itself: an OLD PLAIN dated note followed by a NEWER BOLD dated note used to roll
# only the bold one. The first note in document order — here the plain one — must move.
mmdd_stamp=$(date '+%m-%d %H:%M')
python3 - "$roles/mixed.md" "$mmdd_stamp" <<'PY'
import sys
path, stamp = sys.argv[1], sys.argv[2]
open(path, "w").write(
    '---\nrole: "Mixed role"\nstatus: "busy"\n---\n\n'
    f'## Charter\n{"x" * 6500}\n\n'
    '## Handoff\n'
    f'- 11-20 08:00: old plain note {"a" * 400}\n'
    '  indented continuation, archived verbatim\n'
    f'- **{stamp}:** newer bold note {"b" * 400}\n\n'
    '## Next\n- keep going\n'
)
PY
pad_under_cap "$roles/mixed.md"
mixed_arch="$roles/archive/mixed-handoff-archive-$today.md"
out=$("$CR" --note "pushes mixed over the cap $(printf '%0250d' 0)" --file "$roles/mixed.md"); rc=$?
[ $rc = 0 ] && grep -q '^archived 1 oldest Handoff notes' <<< "$out" \
  && ! grep -q 'old plain note' "$roles/mixed.md" \
  && grep -q 'newer bold note' "$roles/mixed.md" \
  && grep -q '^- 11-20 08:00: old plain note ' "$mixed_arch" \
  && grep -q '^  indented continuation, archived verbatim$' "$mixed_arch" \
  && ! grep -q 'newer bold note' "$mixed_arch" \
  && ok "mixed stamps: the oldest (plain) note is archived, the newer bold note stays" \
  || bad "mixed stamps: rc=$rc out=$out arch=$(cat "$mixed_arch" 2>/dev/null)"
[[ "$out" =~ ^archived\ 1\ oldest\ Handoff\ notes\ to\ archive/mixed-handoff-archive-${today}\.md${nl}mixed\.md:\ [0-9]+/10000\ chars\ at\ session\ start\ \(rendered,\ not\ wc\ bytes\)$ ]] \
  && ok "mixed-stamp archive stdout matches the updated size-line shape" || bad "mixed stdout: $out"
rm -f "$roles/mixed.md" "$mixed_arch"
# A file whose notes are ALL plain dated still rolls its oldest, with no cap refusal.
python3 - "$roles/plain.md" <<'PY'
import sys
open(sys.argv[1], "w").write(
    '---\nrole: "Plain role"\nstatus: "busy"\n---\n\n'
    f'## Charter\n{"p" * 6500}\n\n'
    '## Handoff\n'
    f'- 11-18 07:30: plain oldest {"c" * 400}\n'
    f'- 11-19 09:45: plain newer {"d" * 400}\n\n'
    '## Next\n- step\n'
)
PY
pad_under_cap "$roles/plain.md"
plain_arch="$roles/archive/plain-handoff-archive-$today.md"
out=$("$CR" --note "pushes plain over the cap $(printf '%0250d' 0)" --file "$roles/plain.md"); rc=$?
[ $rc = 0 ] && grep -q '^archived 1 oldest Handoff notes' <<< "$out" \
  && grep -q '^- 11-18 07:30: plain oldest ' "$plain_arch" \
  && ! grep -q 'plain oldest' "$roles/plain.md" \
  && grep -q 'plain newer' "$roles/plain.md" \
  && ok "plain-only notes roll the oldest without a cap refusal" || bad "plain-only: rc=$rc out=$out"
rm -f "$roles/plain.md" "$plain_arch"
# Bare-time notes (no MM-DD date), plain and bold, are candidates too: the first one moves.
python3 - "$roles/bare.md" <<'PY'
import sys
open(sys.argv[1], "w").write(
    '---\nrole: "Bare role"\nstatus: "busy"\n---\n\n'
    f'## Charter\n{"q" * 6500}\n\n'
    '## Handoff\n'
    f'- 09:15: bare plain note {"e" * 400}\n'
    f'- **10:30:** bare bold note {"f" * 400}\n\n'
    '## Next\n- step\n'
)
PY
pad_under_cap "$roles/bare.md"
bare_arch="$roles/archive/bare-handoff-archive-$today.md"
out=$("$CR" --note "pushes bare over the cap $(printf '%0250d' 0)" --file "$roles/bare.md"); rc=$?
[ $rc = 0 ] && grep -q '^archived 1 oldest Handoff notes' <<< "$out" \
  && grep -q '^- 09:15: bare plain note ' "$bare_arch" \
  && ! grep -q 'bare plain note' "$roles/bare.md" \
  && grep -q '^- \*\*10:30:\*\* bare bold note' "$roles/bare.md" \
  && ok "bare-time notes (plain and bold) are archive candidates" || bad "bare-time: rc=$rc out=$out"
rm -f "$roles/bare.md" "$bare_arch"
# Non-stamp bullets in the Handoff — a bold word, a "Fix: ..." line — are never rolled.
python3 - "$roles/curated.md" <<'PY'
import sys
open(sys.argv[1], "w").write(
    '---\nrole: "Curated role"\nstatus: "busy"\n---\n\n'
    f'## Charter\n{"r" * 6500}\n\n'
    '## Handoff\n'
    '- **State**\n'
    '- Fix: parse things later\n'
    f'- 11-21 12:00: the only stamped note {"g" * 400}\n\n'
    '## Next\n- step\n'
)
PY
pad_under_cap "$roles/curated.md"
curated_arch="$roles/archive/curated-handoff-archive-$today.md"
out=$("$CR" --note "pushes curated over the cap $(printf '%0250d' 0)" --file "$roles/curated.md"); rc=$?
[ $rc = 0 ] && grep -q '^archived 1 oldest Handoff notes' <<< "$out" \
  && grep -q '^- \*\*State\*\*$' "$roles/curated.md" \
  && grep -q '^- Fix: parse things later$' "$roles/curated.md" \
  && ! grep -q 'State' "$curated_arch" && ! grep -q 'parse things' "$curated_arch" \
  && grep -q 'the only stamped note' "$curated_arch" \
  && ok "non-stamp bullets stay in the role file; only the stamped note moves" \
  || bad "non-stamp: rc=$rc out=$out arch=$(cat "$curated_arch" 2>/dev/null)"
rm -f "$roles/curated.md" "$curated_arch"

# A --next that pushes the file over the cap archives too; a note lookalike inside a code fence
# in the Handoff is never moved; `## Next steps` is not the Next section.
python3 - "$roles/fence.md" <<'PY'
import sys
open(sys.argv[1], "w").write(
    '---\nrole: "Fence role"\nstatus: "busy"\n---\n\n'
    f'## Charter\n{"x" * 7000}\n\n'
    '## Handoff\n```\n- **10-30 08:00:** fenced lookalike stays\n- 10-15 12:00: fenced plain lookalike stays\n```\n'
    f'- **11-01 09:00:** real old note {"r" * 300}\n\n'
    '## Next steps\n- not the Next section\n'
)
PY
sz_line=$("$CR" --size --file "$roles/fence.md")
cur_n=${sz_line#fence.md: }; cur_n=${cur_n%/10000*}
python3 - "$roles/fence.md" "$((9950 - cur_n))" <<'PY'
import sys
p, k = sys.argv[1], int(sys.argv[2])
s = open(p).read().replace("## Charter\n", "## Charter\n" + ("x" * k), 1)
open(p, "w").write(s)
PY
fence_arch="$roles/archive/fence-handoff-archive-$today.md"
out=$("$CR" --next "pushes over the cap $(printf '%0150d' 0)" --file "$roles/fence.md"); rc=$?
[ $rc = 0 ] && grep -q '^archived 1 oldest Handoff notes' <<< "$out" \
  && grep -q 'fenced lookalike stays' "$roles/fence.md" && ! grep -q 'fenced lookalike' "$fence_arch" \
  && grep -q '^- 10-15 12:00: fenced plain lookalike stays$' "$roles/fence.md" \
  && ! grep -q 'fenced plain lookalike' "$fence_arch" \
  && grep -q 'real old note' "$fence_arch" && ! grep -q 'real old note' "$roles/fence.md" \
  && ok "--next over the cap archives the oldest real note and never a fenced lookalike (bold or plain)" || bad "--next archive/fence: rc=$rc $out"
steps_body=$(awk '/^## Next steps$/{s=1;next} /^## /{s=0} s' "$roles/fence.md")
grep -q 'pushes over the cap' <<< "$steps_body" \
  && bad "--next appended into '## Next steps'" || ok "--next ignores '## Next steps' and makes its own ## Next"
grep -qx '## Next' "$roles/fence.md" && ok "--next created an exact ## Next section" || bad "no exact ## Next: $(grep '^## ' "$roles/fence.md")"
rm -f "$roles/fence.md" "$fence_arch"

# A dated -archive- copy of a role (a hand-made byte copy named <stem>-archive-YYYY-MM-DD.md, frontmatter and
# all) is not a second role: --list, --board and --json each count it out. A role whose own name merely
# contains -archive- (data-archive-owner.md, role Keeper) still lists. Positive control: the same file
# without -archive- in its name is read as a second role, so the fixture is read at all.
rd=$(mktemp -d "$home/retired.XXXXXX")
printf -- '---\nrole: Real\nstatus: "idle"\n---\n\n## Next\n- step\n' > "$rd/real.md"
cp "$rd/real.md" "$rd/real-retired-archive-2026-01-01.md"
printf -- '---\nrole: Keeper\nstatus: "idle"\n---\n\n## Next\n- step\n' > "$rd/data-archive-owner.md"
out=$(SYG_ROLE_DIR="$rd" "$CR" --list)
[ "$(wc -l <<< "$out")" = 2 ] && grep -qxF $'real\tReal\t\t\t' <<< "$out" && grep -qxF $'data-archive-owner\tKeeper\t\t\t' <<< "$out" \
  && ok "--list: a dated -archive- copy is not a second role; a -archive- role name still lists" || bad "--list archive copy: $out"
board=$(SYG_ROLE_DIR="$rd" "$CR" --board)
grep -q '(real.md,' <<< "$board" && grep -q '(data-archive-owner.md,' <<< "$board" && ! grep -q 'real-retired-archive' <<< "$board" \
  && ok "--board: shows real.md and data-archive-owner.md, not the dated -archive- copy" || bad "--board archive copy: $board"
[ "$(SYG_ROLE_DIR="$rd" "$CR" --json | jq '.roles | length')" = 2 ] \
  && ok "--json: a dated -archive- copy is not a second role" || bad "--json archive copy: $(SYG_ROLE_DIR="$rd" "$CR" --json)"
cp "$rd/real.md" "$rd/real-copy.md"
[ "$(SYG_ROLE_DIR="$rd" "$CR" --list | awk -F'\t' '$2 == "Real"' | wc -l)" = 2 ] \
  && ok "positive control: a copy without -archive- is a second Real row" || bad "positive control: $(SYG_ROLE_DIR="$rd" "$CR" --list)"

# 14. Unknown argument: exit 2, and stderr holds both the error line and a usage line (e.g. claude-role --size).
err_top=$("$CR" --unknown-top 2>&1); rc_top=$?
[ $rc_top = 2 ] && grep -q "claude-role: unknown argument '--unknown-top'" <<< "$err_top" \
  && grep -q "claude-role --size" <<< "$err_top" \
  && ok "unknown top-level argument exits 2 with error and usage on stderr" || bad "unknown top: rc=$rc_top $err_top"
err_set=$("$CR" --set --unknown-sub 2>&1); rc_set=$?
[ $rc_set = 2 ] && grep -q "claude-role --set: unknown argument '--unknown-sub'" <<< "$err_set" \
  && grep -q "claude-role --size" <<< "$err_set" \
  && ok "unknown --set argument exits 2 with error and usage on stderr" || bad "unknown set: rc=$rc_set $err_set"

# 15. Due-time Next items (w1108-30): --next --due with both forms, bad date/time refusals,
# (due already in TEXT refused, --due with both verbs refused, later-today due accepted,
# SessionStart "Due now" lines with SYG_ROLE_NOW_EPOCH before and after, fenced (due …) and
# ## Next steps ignored, --size counting Due now lines, and preamble/usage text.
printf -- '---\nrole: "Due role"\nstatus: "ready"\n---\n\n## Charter\nc\n\n## Next\n- existing step\n' > "$roles/due.md"
"$CR" --next "dispatch round 3" --due "2026-11-08 17:04" --file "$roles/due.md" >/dev/null; rc=$?
[ $rc = 0 ] && grep -qxF -- '- dispatch round 3 (due 2026-11-08 17:04)' "$roles/due.md" \
  && ok "--next --due 'YYYY-MM-DD HH:MM' appends bullet with due date and time" || bad "--next --due datetime: rc=$rc $(cat "$roles/due.md")"
"$CR" --next "date-only step" --due 2026-11-09 --file "$roles/due.md" >/dev/null; rc=$?
[ $rc = 0 ] && grep -qxF -- '- date-only step (due 2026-11-09)' "$roles/due.md" \
  && ok "--next --due YYYY-MM-DD appends bullet with date-only due" || bad "--next --due date: rc=$rc $(cat "$roles/due.md")"

before_due=$(cat "$roles/due.md")
check_due_exit2() {
    local label=$1; shift
    "$CR" "$@" --file "$roles/due.md" 2>/dev/null; local rc=$?
    [ $rc = 2 ] && [ "$(cat "$roles/due.md")" = "$before_due" ] \
      && ok "exit 2 + unchanged: $label" || bad "$label: expected rc=2 and unchanged file, got rc=$rc"
}
check_due_exit2 "--next --due non-leap Feb 29" --next "x" --due "2026-02-29 10:00"
check_due_exit2 "--next --due month 13" --next "x" --due "2026-13-01 10:00"
check_due_exit2 "--next --due hour 24" --next "x" --due "2026-11-08 24:00"
check_due_exit2 "--next --due minute 60" --next "x" --due "2026-11-08 12:60"
check_due_exit2 "--next --due 1-digit hour" --next "x" --due "2026-11-08 9:00"
check_due_exit2 "--need --due with HH:MM" --need "ask" --due "2026-11-08 17:04"
check_due_exit2 "--next TEXT already carrying (due with --due" --next "task (due 2026-11-08)" --due 2026-11-09
check_due_exit2 "--next TEXT already carrying (due without --due" --next "task (due 2026-11-08)"
check_due_exit2 "--due with both --need and --next" --need "ask" --next "step" --due 2026-11-08

today=$(date +%F); fut=$(date -d '+30 min' +%H:%M)
if [ "$(date -d '+30 min' +%F)" = "$today" ]; then
    "$CR" --next "later today step" --due "$today $fut" --file "$roles/due.md" >/dev/null; rc=$?
    [ $rc = 0 ] && grep -qxF -- "- later today step (due $today $fut)" "$roles/due.md" \
      && ok "--next --due accepts a later-today time without tripping future_today" \
      || bad "--next --due later-today: rc=$rc $(cat "$roles/due.md")"
else
    ok "--next --due later-today check skipped within 30 min of midnight"
fi

cat > "$roles/duehook.md" <<'EOF'
---
role: "DueHook role"
status: "idle"
---

## Charter
charter body

## Next
- first due item (due 2026-11-08 17:04) then (due 2026-11-08 23:59)
  1. numbered date-only (due 2026-11-08)
```
- fenced item (due 2020-01-01 00:00)
```
- future item (due 2026-11-09 09:00)

## Next steps
- wrong section item (due 2020-01-01 00:00)
EOF
ep_before=$(date -d '2026-11-07 23:00:00' +%s)
ep_mid=$(date -d '2026-11-08 12:00:00' +%s)
ep_after=$(date -d '2026-11-08 18:00:00' +%s)

out_before=$(echo '{"source":"startup","cwd":"'"$home"'/Projects/duehook"}' | SYG_ROLE_NOW_EPOCH="$ep_before" "$CR")
! grep -q '^Due now (' <<< "$out_before" && ! grep -q '^Do the due item first;' <<< "$out_before" \
  && ok "hook before due time prints no Due now lines" || bad "hook before due: $out_before"

out_mid=$(echo '{"source":"startup","cwd":"'"$home"'/Projects/duehook"}' | SYG_ROLE_NOW_EPOCH="$ep_mid" "$CR")
grep -qxF 'Due now (## Next, due 2026-11-08 00:00): numbered date-only (due 2026-11-08)' <<< "$out_mid" \
  && grep -qxF 'Do the due item first; when done, delete its bullet or drop its (due …) marker.' <<< "$out_mid" \
  && ! grep -q 'Due now (.*first due item' <<< "$out_mid" \
  && ! grep -q 'Due now (.*fenced item' <<< "$out_mid" \
  && ! grep -q 'Due now (.*wrong section' <<< "$out_mid" \
  && ok "hook at midday prints date-only Due now, ignores future, fenced, and ## Next steps" \
  || bad "hook midday: $out_mid"

out_after=$(echo '{"source":"startup","cwd":"'"$home"'/Projects/duehook"}' | SYG_ROLE_NOW_EPOCH="$ep_after" "$CR")
grep -qxF 'Due now (## Next, due 2026-11-08 17:04): first due item (due 2026-11-08 17:04) then (due 2026-11-08 23:59)' <<< "$out_after" \
  && grep -qxF 'Due now (## Next, due 2026-11-08 00:00): numbered date-only (due 2026-11-08)' <<< "$out_after" \
  && grep -qxF 'Do the due item first; when done, delete its bullet or drop its (due …) marker.' <<< "$out_after" \
  && ! grep -q 'Due now (.*fenced item' <<< "$out_after" \
  && ! grep -q 'Due now (.*wrong section' <<< "$out_after" \
  && ! grep -q 'Due now (.*future item' <<< "$out_after" \
  && ok "hook after due time prints both due bullets (first marker wins) and instruction line" \
  || bad "hook after: $out_after"

# Order check: Due now appears after preamble and before the role file's leading ---.
ln_pre=$(awk '/^\[Role\] You are the "DueHook role" session\./{print NR; exit}' <<< "$out_after")
ln_due=$(awk '/^Due now \(/{print NR; exit}' <<< "$out_after")
ln_do=$(awk '/^Do the due item first;/{print NR; exit}' <<< "$out_after")
ln_fm=$(awk '/^---$/{print NR; exit}' <<< "$out_after")
[ -n "$ln_pre" ] && [ -n "$ln_due" ] && [ -n "$ln_do" ] && [ -n "$ln_fm" ] \
  && [ "$ln_pre" -lt "$ln_due" ] && [ "$ln_due" -lt "$ln_do" ] && [ "$ln_do" -lt "$ln_fm" ] \
  && ok "hook places Due now block after preamble and before the role file" \
  || bad "hook Due now order: pre=$ln_pre due=$ln_due do=$ln_do fm=$ln_fm"

# --size counts the Due now lines too.
sz_before=$(SYG_ROLE_NOW_EPOCH="$ep_before" "$CR" --size --file "$roles/duehook.md")
sz_after=$(SYG_ROLE_NOW_EPOCH="$ep_after" "$CR" --size --file "$roles/duehook.md")
u16_before=$(printf '%s\n' "$out_before" | python3 -c 'import sys; print(len(sys.stdin.buffer.read().decode("utf-8").encode("utf-16-le")) // 2)')
u16_after=$(printf '%s\n' "$out_after" | python3 -c 'import sys; print(len(sys.stdin.buffer.read().decode("utf-8").encode("utf-16-le")) // 2)')
[ "$sz_before" = "duehook.md: $u16_before/10000 chars at session start (headroom $((10000 - u16_before)))" ] \
  && [ "$sz_after" = "duehook.md: $u16_after/10000 chars at session start (headroom $((10000 - u16_after)))" ] \
  && [ "$u16_after" -gt "$u16_before" ] \
  && ok "--size counts the Due now lines and matches hook output before and after due time" \
  || bad "--size Due now: before='$sz_before' ($u16_before) after='$sz_after' ($u16_after)"

grep -qF -- '--due "YYYY-MM-DD HH:MM"' <<< "$out_before" \
  && ok "preamble documents --next --due" || bad "preamble --due text missing"
help_due=$("$CR" --help)
grep -qF -- '--due DATE[ HH:MM]' <<< "$help_due" \
  && ok "--help documents --next TEXT [--due DATE[ HH:MM]]" || bad "--help --next --due missing: $help_due"
rm -f "$roles/due.md" "$roles/duehook.md"

# ---- Knobs: defaults, then each configured -----------------------------------------------------
hook() { echo '{"source":"startup","cwd":"'"$home"'/Projects/'"$1"'"}' | "$CR"; }   # hook REPO-FOLDER
u16() { python3 -c 'import sys; print(len(sys.stdin.buffer.read().decode("utf-8").encode("utf-16-le")) // 2)'; }

# Defaults: no context line (and no blank first line), the built-in block, "Needs Owner" / "In Person".
printf -- '---\nrole: "Dflt role"\nstatus: "idle"\n---\n\n## Charter\nc\n' > "$roles/dflt.md"
hook dflt > "$home/dflt.out"
[ "$(sed -n 1p "$home/dflt.out")" = '[Role] You are the "Dflt role" session. Your role file is '"$roles"'/dflt.md; its contents follow.' ] \
  && ok "defaults: hook output starts with the [Role] line (no context line, no blank first line)" || bad "defaults head: $(head -c 120 "$home/dflt.out")"
grep -qF 'writes "## Needs Owner"; add `--in-person`' "$home/dflt.out" && grep -qF 'which writes "## In Person"' "$home/dflt.out" \
  && ok "defaults: the built-in block names Needs Owner and In Person" || bad "defaults block: $(grep -F -- '--need ' "$home/dflt.out")"
"$CR" --need "Default ask" --file "$roles/dflt.md" >/dev/null
"$CR" --need "In-person ask" --in-person --file "$roles/dflt.md" >/dev/null
"$CR" --need "Alias-flag ask" --deck --file "$roles/dflt.md" >/dev/null
[ "$(grep '^## ' "$roles/dflt.md" | paste -sd, -)" = "## Charter,## Needs Owner,## In Person" ] \
  && [ "$(sed -n '/^## In Person/,$p' "$roles/dflt.md" | grep -c '^- ')" = 2 ] \
  && ok "defaults: --need writes ## Needs Owner; --in-person and --deck both write ## In Person" || bad "defaults sections: $(cat "$roles/dflt.md")"
err=$("$CR" --need "x" --in-person --deck --file "$roles/dflt.md" 2>&1); rc=$?
[ $rc = 2 ] && grep -q 'given more than once' <<< "$err" && ok "--in-person and --deck together count as given more than once" || bad "double flag: rc=$rc $err"
err=$("$CR" --set status=ok --in-person --file "$roles/dflt.md" 2>&1); rc=$?
[ $rc = 2 ] && grep -q -- '--in-person requires --need' <<< "$err" && ok "--in-person without --need exits 2" || bad "--in-person alone: rc=$rc $err"
rm "$roles/dflt.md"

# Configured: SYG_ROLE_CONTEXT_LINE + a template file, byte-exact against an expected file. The role
# name carries & and \1 (bash 5.2 expands & in ${t//pat/$v}; sed-style \1 must stay literal), the
# template ends in a blank line, and {unknown} / {{role}} show the single literal pass.
role_name='Amp & \1 role'
printf -- '---\nrole: "%s"\nstatus: "idle"\n---\n\n## Charter\nc\n' "$role_name" > "$roles/cfg.md"
printf 'TPL {role}|{path}|{needs}|{in_person}|{role}\nline & \\1 {unknown} {{role}}\n\n' > "$home/tpl"
{ printf '[Ctx] configured line\n'
  printf 'TPL %s|%s|Asks|Onsite|%s\n' "$role_name" "$roles/cfg.md" "$role_name"
  printf 'line & \\1 {unknown} {%s}\n\n' "$role_name"
  cat "$roles/cfg.md"; } > "$home/cfg.expect"
export_cfg() { SYG_ROLE_CONTEXT_LINE='[Ctx] configured line' SYG_ROLE_PREAMBLE_FILE="$home/tpl" SYG_NEEDS_OWNER_SECTION=Asks SYG_IN_PERSON_SECTION=Onsite "$@"; }
export_cfg bash -c "echo '{\"source\":\"startup\",\"cwd\":\"$home/Projects/cfg\"}' | '$CR'" > "$home/cfg.out"
cmp -s "$home/cfg.out" "$home/cfg.expect" && ok "configured: hook output is byte-exact (context line, substituted template with its trailing blank line, role file)" \
  || bad "configured hook differs: $(diff "$home/cfg.expect" "$home/cfg.out" | head -c 600)"
grep -qF 'TPL Amp & \1 role|' "$home/cfg.out" && ok "configured: a role name with & and \\1 comes through literally" || bad "literal role name: $(sed -n 2p "$home/cfg.out")"
n_hook=$(u16 < "$home/cfg.out")
n_size=$(export_cfg "$CR" --size --file "$roles/cfg.md" | sed 's/^cfg.md: \([0-9]*\)\/.*/\1/')
[ "$n_hook" = "$n_size" ] && ok "configured: --size equals the UTF-16 length of the hook output ($n_size)" || bad "configured size: --size $n_size vs hook $n_hook"
printf 'no trailing newline: {role}' > "$home/tpl2"
{ printf 'no trailing newline: %s' "$role_name"; cat "$roles/cfg.md"; } > "$home/cfg2.expect"
SYG_ROLE_PREAMBLE_FILE="$home/tpl2" bash -c "echo '{\"source\":\"startup\",\"cwd\":\"$home/Projects/cfg\"}' | '$CR'" > "$home/cfg2.out"
cmp -s "$home/cfg2.out" "$home/cfg2.expect" && ok "configured: a template without a final newline is emitted as written" || bad "no-newline template: $(od -c "$home/cfg2.out" | head -3)"
err=$(SYG_ROLE_PREAMBLE_FILE="$home/absent.tpl" bash -c "echo '{\"source\":\"startup\",\"cwd\":\"$home/Projects/cfg\"}' | '$CR'" 2>&1 >"$home/cfg3.out")
grep -qF "claude-role: SYG_ROLE_PREAMBLE_FILE $home/absent.tpl is unreadable; using the built-in text" <<< "$err" \
  && grep -q '^\[Role\] You are the "Amp & \\1 role" session' "$home/cfg3.out" \
  && ok "an unreadable template warns on stderr and falls back to the built-in text" || bad "unreadable template: err=$err out=$(head -c 120 "$home/cfg3.out")"
rm "$roles/cfg.md"
# A template holding a raw Latin-1 byte (not UTF-8): --size and --set must not crash, and --size
# counts exactly as the hook does (it decodes with errors="replace": one unit per bad byte).
printf 'caf\351 {role}\n\n' > "$home/tpl-latin"
printf -- '---\nrole: "Latin role"\nstatus: "idle"\n---\n' > "$roles/latin.md"
latin_hook=$(echo '{"source":"startup","cwd":"'"$home"'/Projects/latin"}' | SYG_ROLE_PREAMBLE_FILE="$home/tpl-latin" "$CR" | python3 -c 'import sys; print(len(sys.stdin.buffer.read().decode("utf-8", "replace").encode("utf-16-le")) // 2)')
latin_size=$(SYG_ROLE_PREAMBLE_FILE="$home/tpl-latin" "$CR" --size --file "$roles/latin.md" 2>&1); rc=$?
[ $rc = 0 ] && [ "$latin_size" = "latin.md: $latin_hook/10000 chars at session start (headroom $((10000 - latin_hook)))" ] \
  && ok "non-UTF-8 template: --size exits 0 and equals the hook's own measure ($latin_hook)" || bad "latin --size: rc=$rc '$latin_size' vs hook $latin_hook"
latin_set=$(SYG_ROLE_PREAMBLE_FILE="$home/tpl-latin" "$CR" --set status=x --file "$roles/latin.md" 2>&1); rc=$?
latin_after=$(echo '{"source":"startup","cwd":"'"$home"'/Projects/latin"}' | SYG_ROLE_PREAMBLE_FILE="$home/tpl-latin" "$CR" | python3 -c 'import sys; print(len(sys.stdin.buffer.read().decode("utf-8", "replace").encode("utf-16-le")) // 2)')
[ $rc = 0 ] && [ "$latin_set" = "latin.md: $latin_after/10000 chars at session start (rendered, not wc bytes)" ] && grep -q 'status: "x"' "$roles/latin.md" \
  && ok "non-UTF-8 template: --set succeeds and prints the hook's count for the rewritten file" || bad "latin --set: rc=$rc $latin_set"
rm "$roles/latin.md"

# Section knobs drive --need, --need-done, --json (.needs/.deck) and the --in-person list.
cat > "$roles/sec.md" <<'EOF'
---
role: "Sec role"
---

## Asks
- Read it — unblocks x (added 2026-10-01)

## Onsite
- Plug it in — unblocks y (added 2026-10-02)

## Needs Owner
- default-named ghost

## In Person
- default-named ghost two
EOF
export SYG_NEEDS_OWNER_SECTION=Asks SYG_IN_PERSON_SECTION=Onsite
got=$("$CR" --json | jq -c '.roles[] | select(.file == "sec.md") | [.needs[0].what, .deck[0].what, (.needs | length), (.deck | length)]')
[ "$got" = '["Read it","Plug it in",1,1]' ] && ok "knobs: --json .needs/.deck read the configured sections only" || bad "knob json: $got"
out=$("$CR" --in-person | awk '/^Sec role/{f=1} f')
grep -q 'Plug it in' <<< "$out" && ! grep -q 'ghost' <<< "$out" && ok "knobs: --in-person lists the configured section" || bad "knob --in-person: $out"
"$CR" --need "New ask" --file "$roles/sec.md" >/dev/null; "$CR" --need "New visit" --in-person --file "$roles/sec.md" >/dev/null
[ "$(sed -n '/^## Asks/,/^## Onsite/p' "$roles/sec.md" | grep -c 'New ask')" = 1 ] && [ "$(sed -n '/^## Onsite/,/^## Needs Owner/p' "$roles/sec.md" | grep -c 'New visit')" = 1 ] \
  && ok "knobs: --need and --need --in-person append under the configured headings" || bad "knob --need: $(cat "$roles/sec.md")"
out=$("$CR" --need-done "plug it in" --file "$roles/sec.md"); rc=$?
[ $rc = 0 ] && grep -q '^removed: - Plug it in' <<< "$out" && ok "knobs: --need-done finds a bullet in the configured in-person section" || bad "knob --need-done: rc=$rc $out"
out=$("$CR" --need-done "default-named" --file "$roles/sec.md" 2>&1); rc=$?
[ $rc = 1 ] && grep -q 'no bullet matches' <<< "$out" && ok "knobs: --need-done does not scan the default-named sections" || bad "knob ghost --need-done: rc=$rc $out"
unset SYG_NEEDS_OWNER_SECTION SYG_IN_PERSON_SECTION
rm "$roles/sec.md"

# SYG_ROLE_CONTEXT_CMD: unset -> no context lines and no unavailable line; a stub printing JSON -> a
# context: line per role; a failing stub -> the unavailable line naming the knob.
printf -- '---\nrole: "Ctx role"\n---\n' > "$roles/ctx.md"
out=$("$CR" --board)
! grep -q 'context' <<< "$out" && grep -q '^Ctx role  (ctx.md' <<< "$out" && ok "context cmd unset: no context lines, no unavailable line" || bad "context unset: $out"
printf '[{"folder":"ctx","tokens":123456,"flagged":true,"flag_at":100000},{"folder":"ctx","tokens":5000,"flagged":false,"flag_at":100000}]\n' > "$home/ctx.json"
out=$(SYG_ROLE_CONTEXT_CMD="cat '$home/ctx.json'" "$CR" --board | awk '/^Ctx role/{f=1} f')
grep -qxF '    context: 123k COMPACT (over 100k), 5k' <<< "$out" && ! grep -q 'unavailable' <<< "$out" \
  && ok "context cmd: a JSON-printing stub gives the context: line" || bad "context stub: $out"
out=$(SYG_ROLE_CONTEXT_CMD="cat '$home/ctx.json'" "$CR" --board | awk '/^Alpha role/{f=1} f' | sed -n 4p)
[ "$out" = '    context: -' ] && ok "context cmd: a role with no running session shows '-'" || bad "context dash: '$out'"
out=$(SYG_ROLE_CONTEXT_CMD="exit 3" "$CR" --board)
grep -qxF '(context sizes unavailable: SYG_ROLE_CONTEXT_CMD failed)' <<< "$out" && ! grep -q '    context:' <<< "$out" \
  && ok "context cmd: a failing stub prints the unavailable line naming the knob" || bad "context failing: $out"
rm "$roles/ctx.md"

# Route validation knobs: SYG_ROUTE_SHOW_CMD (a failing check refuses with its message) and
# SYG_ROLE_HEADLESS_ROUTES (whitespace- or comma-separated names a role session can't take).
printf -- '---\nrole: "Route role"\nstatus: "idle"\n---\n' > "$roles/route.md"
"$CR" --set route=any-well-shaped-name --file "$roles/route.md" && grep -q 'route: "any-well-shaped-name"' "$roles/route.md" \
  && ok "route: SYG_ROUTE_SHOW_CMD unset accepts a well-shaped name" || bad "route unset: $(cat "$roles/route.md")"
printf '#!/bin/bash\necho "x: nope $1" >&2\nexit 1\n' > "$home/show-fail"; chmod +x "$home/show-fail"
err=$(SYG_ROUTE_SHOW_CMD="$home/show-fail" "$CR" --set route=preset-q --file "$roles/route.md" 2>&1); rc=$?
[ $rc = 2 ] && grep -qF "route 'preset-q' refused: nope preset-q" <<< "$err" && grep -q 'route: "any-well-shaped-name"' "$roles/route.md" \
  && ok "route: a failing SYG_ROUTE_SHOW_CMD refuses with its message (leading 'x: ' dropped), file untouched" || bad "route show fail: rc=$rc $err"
printf '#!/bin/bash\nexit 0\n' > "$home/show-ok"; chmod +x "$home/show-ok"
SYG_ROUTE_SHOW_CMD="$home/show-ok" "$CR" --set route=preset-q --file "$roles/route.md" >/dev/null && grep -q 'route: "preset-q"' "$roles/route.md" \
  && ok "route: a succeeding SYG_ROUTE_SHOW_CMD accepts" || bad "route show ok: $(cat "$roles/route.md")"
for r in a-api b; do
    err=$(SYG_ROLE_HEADLESS_ROUTES="a-api, b" "$CR" --set route=$r --file "$roles/route.md" 2>&1); rc=$?
    [ $rc = 2 ] && grep -qF "route $r is headless only; a role session can't take it" <<< "$err" && ok "route: SYG_ROLE_HEADLESS_ROUTES refuses $r" || bad "headless $r: rc=$rc $err"
done
err=$(SYG_ROLE_HEADLESS_ROUTES="a-api,b" "$CR" --set route=c --file "$roles/route.md" 2>&1) && ok "route: a name outside SYG_ROLE_HEADLESS_ROUTES passes" || bad "headless other: $err"
grep -q 'route: "c"' "$roles/route.md" || bad "route c not written"
rm "$roles/route.md"

# A role dir that doesn't exist: the read verbs exit 1 with a message; hook mode stays silent.
missing="$home/no-such-dir"
for v in --list --board --json --in-person --deck; do
    err=$(SYG_ROLE_DIR="$missing" "$CR" $v 2>&1 >/dev/null); rc=$?
    [ $rc = 1 ] && [ "$err" = "claude-role: no role dir at $missing (set SYG_ROLE_DIR)" ] && ok "missing role dir: $v exits 1 with the message" || bad "missing dir $v: rc=$rc $err"
done
out=$(echo '{"source":"startup","cwd":"'"$home"'/Projects/dflt"}' | SYG_ROLE_DIR="$missing" "$CR" 2>&1); rc=$?
[ $rc = 0 ] && [ -z "$out" ] && ok "missing role dir: hook mode exits 0 and prints nothing" || bad "missing dir hook: rc=$rc out=$out"
out=$(echo '{"source":"startup","cwd":"'"$home"'/Projects/dflt"}' | SYG_ROLE_DIR="$missing" SYG_ROLE_CONTEXT_LINE='[Ctx] only' "$CR" 2>&1); rc=$?
[ $rc = 0 ] && [ "$out" = '[Ctx] only' ] && ok "missing role dir: hook mode prints only the context line when one is set" || bad "missing dir hook ctx: rc=$rc out=$out"
mkdir "$home/empty-dir"
err=$(SYG_ROLE_DIR="$home/empty-dir" "$CR" --list 2>&1); rc=$?
[ $rc = 0 ] && [ -z "$err" ] && ok "an empty role dir lists nothing, quietly" || bad "empty role dir: rc=$rc $err"

# Python isolation: a json.py / re.py / datetime.py in the caller's cwd must not shadow the stdlib in
# --set, --size or the hook (each python runs with -I), and next_due.py still imports.
shadow="$home/shadow"; mkdir -p "$shadow"
for m in json re datetime; do printf 'open("%s/marker-%s", "a").close()\n' "$shadow" "$m" > "$shadow/$m.py"; done
printf -- '---\nrole: "Iso role"\nstatus: "idle"\n---\n\n## Next\n- overdue (due 2020-01-01)\n' > "$roles/iso.md"
iso_set=$(cd "$shadow" && "$CR" --set status=x --file "$roles/iso.md" 2>&1); rc=$?
[ $rc = 0 ] && [[ "$iso_set" =~ ^iso\.md:\ [0-9]+/10000\ chars\ at\ session\ start\ \(rendered,\ not\ wc\ bytes\)$ ]] && grep -q 'status: "x"' "$roles/iso.md" \
  && ok "isolation: --set from a cwd with json.py/re.py/datetime.py works" || bad "isolation --set: rc=$rc $iso_set"
iso_size=$(cd "$shadow" && "$CR" --size --file "$roles/iso.md" 2>&1); rc=$?
[ $rc = 0 ] && [[ "$iso_size" =~ ^iso\.md:\ [0-9]+/10000\ chars ]] && ok "isolation: --size from the shadowed cwd works" || bad "isolation --size: rc=$rc $iso_size"
iso_hook=$(cd "$shadow" && echo '{"source":"startup","cwd":"'"$home"'/Projects/iso"}' | "$CR" 2>&1); rc=$?
[ $rc = 0 ] && grep -qF 'Due now (## Next' <<< "$iso_hook" && grep -qF 'You are the "Iso role" session' <<< "$iso_hook" \
  && ok "isolation: the hook from the shadowed cwd works and still reads next_due.py" || bad "isolation hook: rc=$rc $(head -c 300 <<< "$iso_hook")"
markers=("$shadow"/marker-*)
[ -e "${markers[0]}" ] && bad "isolation: a shadow module ran (${markers[*]##*/})" || ok "isolation: no shadow module ran"
rm -f "$roles/iso.md"

# A non-UTF-8 role FILE: --size counts as the hook does; --set refuses in one line, file untouched.
printf -- '---\nrole: "Bytes role"\nstatus: "idle"\n---\n\ncaf\351\n' > "$roles/bytes.md"
bytes_hook=$(echo '{"source":"startup","cwd":"'"$home"'/Projects/bytes"}' | "$CR" | python3 -c 'import sys; print(len(sys.stdin.buffer.read().decode("utf-8", "replace").encode("utf-16-le")) // 2)')
bytes_size=$("$CR" --size --file "$roles/bytes.md" 2>&1); rc=$?
[ $rc = 0 ] && [ "$bytes_size" = "bytes.md: $bytes_hook/10000 chars at session start (headroom $((10000 - bytes_hook)))" ] \
  && ok "non-UTF-8 role file: --size exits 0 and equals the hook's measure ($bytes_hook)" || bad "bytes --size: rc=$rc '$bytes_size' vs $bytes_hook"
before_bytes=$(cksum < "$roles/bytes.md")
bytes_set=$("$CR" --set status=x --file "$roles/bytes.md" 2>&1); rc=$?
[ $rc = 1 ] && [ "$bytes_set" = "claude-role --set: $roles/bytes.md is not UTF-8; fix its encoding first" ] && [ "$(cksum < "$roles/bytes.md")" = "$before_bytes" ] \
  && ok "non-UTF-8 role file: --set exits 1 with a one-line message, file unchanged" || bad "bytes --set: rc=$rc '$bytes_set'"
rm -f "$roles/bytes.md"

# lib/next_due.py directly: the json form for one due and one not-due bullet.
printf -- '---\nrole: "Due json"\n---\n\n## Next\n- due one (due 2026-11-08 17:04)\n- later one (due 2026-11-09 09:00)\n' > "$home/duejson.md"
ep=$(date -d '2026-11-08 18:00:00' +%s)
got=$(python3 -I "$REPO/plugins/seyag/lib/next_due.py" json "$home/duejson.md" "$ep")
want='[{"stamp": "2026-11-08 17:04", "age": "56m ago", "text": "due one (due 2026-11-08 17:04)"}]'
[ "$got" = "$want" ] && ok "next_due.py json: one due bullet as {stamp, age, text}, the not-due one omitted" || bad "next_due json: $got"

echo "claude-role probe: $pass passed, $fail failed"
[ "$fail" = 0 ]
