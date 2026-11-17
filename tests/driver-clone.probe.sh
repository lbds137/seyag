#!/bin/bash
# Hermetic probe for plugins/seyag/bin/driver-clone: a lane is cloned from the base's origin, gets a
# role file stub (base route, Charter pointing at the base's split) and one in-person trust bullet;
# with SYG_PROJECT_NAMES_FILE set it also gets a names row, without it the base short name is the
# base role's role: field and no table is written. --dry-run and every refusal change nothing.
# Runs against a throwaway projects dir (SYG_DRIVER_CLONE_PROJECTS), role dir (SYG_ROLE_DIR) and a
# local bare repo as origin; claude-role is a stub (SYG_DRIVER_CLONE_ROLE_BIN). No network.
# Usage: tests/driver-clone.probe.sh   (from anywhere)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DC="$REPO/plugins/seyag/bin/driver-clone"
[ -x "$DC" ] || { echo "FAIL  $DC is not executable (chmod +x it)"; exit 1; }
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; }

unset CLAUDE_PID SYG_PROJECT_NAMES_FILE SYG_DRIVER_CLONE_START_HINT SYG_NEEDS_OWNER_SECTION SYG_IN_PERSON_SECTION XDG_DATA_HOME
export SYG_CONFIG=0

T=$(mktemp -d "${TMPDIR:-/tmp}/driver-clone-probe.XXXXXX"); trap 'rm -rf "$T"' EXIT
P=$T/projects R=$T/roles N=$T/names.tsv
mkdir -p "$P" "$R"
export SYG_DRIVER_CLONE_PROJECTS=$P SYG_ROLE_DIR=$R
printf '# header\nwidget\tWidget\nlone\tLone\n' > "$N"
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$P/widget" 2>/dev/null
git -C "$P/widget" -c user.name=p -c user.email=p@example.invalid commit -q --allow-empty -m init
git -C "$P/widget" push -q origin HEAD 2>/dev/null
git clone -q "$T/origin.git" "$P/lone" 2>/dev/null   # a checkout with no lone.md role file
printf -- '---\nname: ""\nmetadata:\n  role: Widget\n  route: "route-one"\n---\n\n## Charter\nx\n' > "$R/widget.md"
cat > "$T/role-stub" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/role-calls"
EOF
chmod +x "$T/role-stub"
export SYG_DRIVER_CLONE_ROLE_BIN=$T/role-stub

# ---- names file set: today's behaviour ----------------------------------------------------------
export SYG_PROJECT_NAMES_FILE=$N

out=$("$DC" widget b --name "Widget B" --dry-run 2>&1); rc=$?
[ $rc = 0 ] && grep -q 'dry run, nothing changed' <<<"$out" && [ ! -e "$P/widget-b" ] && [ ! -e "$R/widget-b.md" ] \
  && ! grep -q widget-b "$N" && [ ! -e "$T/role-calls" ] \
  && ok "--dry-run: plan printed, nothing created" || bad "--dry-run (rc $rc): $out"
grep -q 'route: route-one' <<<"$out" && grep -q 'names row widget-b → Widget B' <<<"$out" \
  && ok "--dry-run names the base role's route and the names row" || bad "--dry-run plan: $out"

out=$("$DC" widget b --name "Widget B" 2>&1); rc=$?
[ $rc = 0 ] && ok "real run exits 0" || bad "real run (rc $rc): $out"
[ "$(git -C "$P/widget-b" remote get-url origin 2>&1)" = "$T/origin.git" ] && ok "clone's origin is the base's origin" \
  || bad "clone origin: $(git -C "$P/widget-b" remote get-url origin 2>&1)"
f=$R/widget-b.md
grep -qx '  role: "Widget B"' "$f" && grep -qx '  route: "route-one"' "$f" && ok "role stub: role and the base route" \
  || bad "role stub fields: $(sed -n 1,10p "$f" 2>&1)"
for h in '## Charter' '## Handoff' '## Next' '## Needs Owner' '## In Person'; do
  grep -qx "$h" "$f" || bad "role stub lacks $h"
done
grep -q 'authoritative in widget.md' "$f" && ok "Charter points at the split in widget.md" || bad "Charter pointer: $(grep -A1 '## Charter' "$f")"
grep -qF 'seyag skills/delegation § "Parallel work: three tiers", tier 3' "$f" && ok "Charter keeps the delegation skill pointer" || bad "delegation pointer: $(grep -A1 '## Charter' "$f")"
grep -qE '^  updated: [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$' "$f" && ok "updated is stamped" || bad "updated: $(grep updated "$f")"
grep -qF 'new lane of Widget:' "$f" && ok "names set: the short name comes from the table" || bad "status line: $(grep status "$f")"
[ "$(grep -c "^widget-b	Widget B$" "$N")" = 1 ] && ok "one names row widget-b → Widget B" || bad "names: $(cat "$N")"
[ "$(wc -l < "$T/role-calls")" = 1 ] \
  && grep -qxF -- "--need Run claude once in $P/widget-b and accept the folder-trust prompt — unblocks starting Widget B (driver-clone) --in-person" "$T/role-calls" \
  && ok "one trust bullet via claude-role --need --in-person" || bad "claude-role calls: $(cat "$T/role-calls" 2>&1)"
grep -qF "then: start a session in $P/widget-b" <<<"$out" && ok "closing line: then: <default hint>" || bad "closing line: $out"

# The hint and the section names are knobs.
git clone -q "$T/origin.git" "$P/gadget" 2>/dev/null
printf -- '---\nrole: "Gadget Prime"\nroute: z-lane\n---\n' > "$R/gadget.md"
out=$(SYG_DRIVER_CLONE_START_HINT="launch gadget-c now" SYG_NEEDS_OWNER_SECTION=Asks SYG_IN_PERSON_SECTION=Onsite SYG_PROJECT_NAMES_FILE='' "$DC" gadget c --name "Gadget C" 2>&1); rc=$?
grep -qF "then: launch gadget-c now" <<<"$out" && grep -qx '## Asks' "$R/gadget-c.md" && grep -qx '## Onsite' "$R/gadget-c.md" \
  && ! grep -q '## Needs Owner' "$R/gadget-c.md" && ok "SYG_DRIVER_CLONE_START_HINT and the section knobs are honoured" || bad "knobs (rc $rc): $out"

# ---- names file unset: no table ------------------------------------------------------------------
before_names=$(cat "$N")
out=$(SYG_PROJECT_NAMES_FILE='' "$DC" gadget d --name "Gadget D" --dry-run 2>&1); rc=$?
[ $rc = 0 ] && grep -q 'dry run, nothing changed' <<<"$out" && ! grep -q 'names row' <<<"$out" && [ ! -e "$P/gadget-d" ] \
  && ok "names unset: the plan has no names row" || bad "unset dry-run (rc $rc): $out"
out=$(SYG_PROJECT_NAMES_FILE='' "$DC" gadget d --name "Gadget D" 2>&1); rc=$?
[ $rc = 0 ] && [ -d "$P/gadget-d/.git" ] && ok "names unset: real run exits 0 and clones" || bad "unset real run (rc $rc): $out"
grep -qF 'new lane of Gadget Prime:' "$R/gadget-d.md" && ok "names unset: the short name is the base role's role: field" || bad "unset status: $(grep status "$R/gadget-d.md")"
grep -qx '  route: "z-lane"' "$R/gadget-d.md" && ok "flat base frontmatter: route carries over" || bad "flat route: $(grep route "$R/gadget-d.md" 2>&1)"
[ "$(cat "$N")" = "$before_names" ] && ok "names unset: no table is written" || bad "names table changed: $(cat "$N")"
grep -qF 'then: start a session in' <<<"$out" && ! grep -q 'Commit the new row' <<<"$out" && ok "names unset: the done line has no commit-the-row step" || bad "unset done line: $out"
printf -- '---\nroute: z-lane\n---\n' > "$R/norole.md"; git clone -q "$T/origin.git" "$P/norole" 2>/dev/null
out=$(SYG_PROJECT_NAMES_FILE='' "$DC" norole b --name "No Role B" 2>&1); rc=$?
[ $rc != 0 ] && grep -qF 'has no role: field' <<<"$out" && [ ! -e "$P/norole-b" ] && [ ! -e "$R/norole-b.md" ] \
  && ok "names unset: a base role with no role: field is refused, nothing created" || bad "no role: field (rc $rc): $out"

# ---- refusals (names set): each leaves the fixture as it was ---------------------------------------
# Each fixture makes exactly one condition true and each asserts its own message; a refused run
# leaves the names table and claude-role untouched and clones nothing.
mkdir "$P/widget-d"                                              # clone folder only
: > "$R/widget-e.md"                                             # role file only
printf 'widget-f\tWidget F\n' >> "$N"                            # names row only
git init -q "$P/noorigin"; printf -- '---\nrole: N\n---\n' > "$R/noorigin.md"
printf 'noorigin\tNo Origin\n' >> "$N"
git clone -q "$T/origin.git" "$P/norow" 2>/dev/null; printf -- '---\nrole: R\n---\n' > "$R/norow.md"
before=$(md5sum "$N" "$T/role-calls")
refuse() {  # refuse WHY WANT-TEXT DIR-THAT-MUST-NOT-APPEAR ARGS...
  local why=$1 want=$2 nodir=$3; shift 3
  out=$("$DC" "$@" 2>&1); rc=$?
  [ $rc != 0 ] && grep -qF -- "$want" <<<"$out" && [ "$(md5sum "$N" "$T/role-calls")" = "$before" ] \
    && { [ -z "$nodir" ] || [ ! -e "$nodir" ]; } && ok "refuses $why" || bad "$why (rc $rc): $out"
}
refuse "an existing clone folder" "$P/widget-d already exists" "" widget d --name "Widget D"
refuse "an existing role file" "$R/widget-e.md already exists" "$P/widget-e" widget e --name "Widget E"
refuse "an existing names row" "already has a widget-f row" "$P/widget-f" widget f --name "Widget F"
refuse "a base with no role file" "no base role file" "$P/lone-b" lone b --name "Lone B"
refuse "a missing base checkout" "no base checkout" "" nosuch b --name "X"
refuse "a base with no origin" "has no origin remote" "$P/noorigin-b" noorigin b --name "N B"
refuse "a base with no names row" "has no row for norow" "$P/norow-b" norow b --name "R B"
refuse "a REPO that is a path" "must be a folder name" "" ../x b --name "X"
refuse "an uppercase lane" "lowercase letters and digits" "$P/widget-B" widget B --name "Widget B"
refuse "a missing --name" "usage:" "$P/widget-c" widget c
refuse "a quote in --name" "can't hold a quote" "$P/widget-c" widget c --name 'Wi"dget'
refuse "a backslash in --name" "backslash" "$P/widget-c" widget c --name 'Wi\dget'
refuse "a tab in --name" "tab" "$P/widget-c" widget c --name "Wi$(printf '\t')dget"
out=$(SYG_PROJECT_NAMES_FILE="$T/absent.tsv" "$DC" widget g --name "Widget G" 2>&1); rc=$?
[ $rc != 0 ] && grep -qF "no names table at $T/absent.tsv" <<<"$out" && [ ! -e "$P/widget-g" ] \
  && ok "refuses a SYG_PROJECT_NAMES_FILE that does not exist" || bad "absent names file (rc $rc): $out"

# A failing claude-role keeps the lane and prints the trust step to file by hand. (The undo after a
# failed role write is untested: the -w precheck blocks the cheap way to make that write fail.)
git clone -q "$T/origin.git" "$P/flat" 2>/dev/null
printf -- '---\nrole: Flat\nroute: z-lane\n---\n' > "$R/flat.md"
printf 'flat\tFlat\n' >> "$N"
printf '#!/bin/bash\nexit 1\n' > "$T/role-fail"; chmod +x "$T/role-fail"
out=$(SYG_DRIVER_CLONE_ROLE_BIN=$T/role-fail "$DC" flat b --name "Flat B" 2>&1); rc=$?
[ $rc = 0 ] && grep -q "file the trust step by hand: Run claude once in $P/flat-b" <<<"$out" && [ -d "$P/flat-b" ] \
  && ok "failing claude-role: lane kept, trust step printed" || bad "claude-role failure (rc $rc): $out"

# The base short name is validated like --name, on both paths: one layer of quotes is stripped, a
# backslash (or quote, tab, CR) is refused before anything is cloned.
git clone -q "$T/origin.git" "$P/quoted" 2>/dev/null; printf -- "---\nrole: 'Quoted Base'\n---\n" > "$R/quoted.md"
out=$(SYG_PROJECT_NAMES_FILE='' "$DC" quoted b --name "Quoted B" 2>&1); rc=$?
[ $rc = 0 ] && grep -qF 'new lane of Quoted Base:' "$R/quoted-b.md" && ok "a single-quoted role: value is stripped to its text" || bad "single-quoted role (rc $rc): $out / $(grep status "$R/quoted-b.md" 2>&1)"
git clone -q "$T/origin.git" "$P/slashy" 2>/dev/null; printf -- '---\nrole: "Sla\\\\shy"\n---\n' > "$R/slashy.md"
out=$(SYG_PROJECT_NAMES_FILE='' "$DC" slashy b --name "Slashy B" 2>&1); rc=$?
[ $rc != 0 ] && grep -qF "can't hold a quote, backslash" <<<"$out" && [ ! -e "$P/slashy-b" ] && [ ! -e "$R/slashy-b.md" ] \
  && ok "a role: value with a backslash is refused, nothing cloned" || bad "backslash role (rc $rc): $out"
git clone -q "$T/origin.git" "$P/slashn" 2>/dev/null; printf -- '---\nrole: Plain\n---\n' > "$R/slashn.md"; printf 'slashn\tBad\\Name\n' >> "$N"
out=$("$DC" slashn b --name "Slashn B" 2>&1); rc=$?
[ $rc != 0 ] && grep -qF "can't hold a quote, backslash" <<<"$out" && [ ! -e "$P/slashn-b" ] \
  && ok "a names-file short name with a backslash is refused, nothing cloned" || bad "backslash names row (rc $rc): $out"

# With no seam the role bin is the sibling claude-role: run from a folder that has a role file, the
# trust bullet lands in that role's own in-person section.
unset SYG_DRIVER_CLONE_ROLE_BIN
mkdir "$P/runner"; printf -- '---\nrole: "Runner"\n---\n\n## Charter\nc\n' > "$R/runner.md"
git clone -q "$T/origin.git" "$P/sib" 2>/dev/null; printf -- '---\nrole: Sib\n---\n' > "$R/sib.md"
out=$(cd "$P/runner" && SYG_PROJECT_NAMES_FILE='' "$DC" sib b --name "Sib B" 2>&1); rc=$?
[ $rc = 0 ] && grep -qx '## In Person' "$R/runner.md" && grep -qF -- "- Run claude once in $P/sib-b and accept the folder-trust prompt" "$R/runner.md" \
  && ok "the default role bin is the sibling claude-role (the bullet lands in the caller's role file)" || bad "sibling role bin (rc $rc): $out / $(cat "$R/runner.md")"

echo "driver-clone probe: $pass passed, $fail failed"
[ "$fail" = 0 ]
