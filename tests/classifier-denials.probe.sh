#!/usr/bin/env bash
# Hermetic probe for plugins/seyag/bin/classifier-denials: synthetic transcripts only, HOME and
# CLAUDE_PROJECTS_DIR pointed at tmp dirs. Pins the A/B split, the quoted-text exclusion, the --since
# cutoff, and the project-name prefix strip derived from $HOME (not a hard-coded home path).
# Usage: tests/classifier-denials.probe.sh   (from anywhere)
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
B="$REPO/plugins/seyag/bin/classifier-denials"
[ -x "$B" ] || { echo "FAIL: $B is not executable (chmod +x it)"; exit 1; }
export SYG_CONFIG=0
unset CLAUDE_PROJECTS_DIR CLAUDE_CONFIG_DIR
fail=0
ok()  { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/classifier-denials-probe.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
fakehome="$tmp/home"; mkdir -p "$fakehome"
proj="$tmp/projects"
hs=$(printf '%s' "$fakehome" | sed 's/[^A-Za-z0-9]/-/g')   # the slug Claude Code gives the home dir
mkdir -p "$proj/${hs}-Projects-alpha"
now=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
mk() { printf '{"type":"user","toolDenialKind":"automode-blocked","timestamp":"%s","message":{"content":[{"type":"tool_result","content":"Permission for this action was denied by the Claude Code auto mode classifier. Reason: %s. If you have other tasks that dont depend on this action, continue."}]}}\n' "$now" "$1"; }
f="$proj/${hs}-Projects-alpha/aaaaaaaa1111.jsonl"
{ mk "[Git Destructive]"; mk "[PII Data Handling]"; mk "Stage 2 classifier error - blocking based on stage 1 assessment (usually transient)"; mk "No reason provided"; } > "$f"
# the dominant real-world infra shape: "<model> is temporarily unavailable (timed out), so auto mode cannot determine ..."
printf '{"type":"user","toolDenialKind":"automode-unavailable","timestamp":"%s","message":{"content":[{"type":"tool_result","content":"vendor/model-x:nitro is temporarily unavailable (timed out), so auto mode cannot determine the safety of Bash right now. Wait a moment."}]}}\n' "$now" >> "$f"
printf '{"type":"user","timestamp":"%s","message":{"content":[{"type":"tool_result","content":"quoted: so auto mode cannot determine the safety of Bash; denied by the Claude Code auto mode classifier. Reason: [Git Destructive]. If you have other tasks"}]}}\n' "$now" >> "$f"

out=$(HOME="$fakehome" CLAUDE_PROJECTS_DIR="$proj" "$B" --since 1 2>&1)
chk() { if grep -q -- "$1" <<< "$out"; then ok "$2"; else bad "$2: missing [$1] in: $out"; fi; }
chk "A(policy)=2 B(infra)=3" "totals split A=2 B=3 (quoted text not counted)"
chk "^  alpha  *A=2 .*B=3" "project name has the home slug and Projects- prefix stripped"

old=$(HOME="$fakehome" CLAUDE_PROJECTS_DIR="$proj" "$B" --since 0.0000001 2>&1)
grep -q "A(policy)=0 B(infra)=0" <<< "$old" && ok "--since cutoff applied" || bad "cutoff not applied: $old"

# The strip comes from $HOME: a bare home-slug prefix (no Projects-) is stripped too, a
# different home's slug is left alone, and the literal slug of an unrelated home is not special.
mkdir -p "$proj/${hs}-gamma" "$proj/-home-other-Projects-delta"
mk "[Git Destructive]" > "$proj/${hs}-gamma/bbbbbbbb2222.jsonl"
mk "[Git Destructive]" > "$proj/-home-other-Projects-delta/cccccccc3333.jsonl"
out=$(HOME="$fakehome" CLAUDE_PROJECTS_DIR="$proj" "$B" --since 1 2>&1)
chk "^  gamma  *A=1" "bare home-slug prefix stripped"
chk "^  -home-other-Projects-delta  *A=1" "another home's slug is not stripped"

# --detail lists B-class events with the stripped project name.
out=$(HOME="$fakehome" CLAUDE_PROJECTS_DIR="$proj" "$B" --since 1 --detail 2>&1)
chk "^  B .* alpha aaaaaaaa " "--detail lists B events under the stripped name"

# Without CLAUDE_PROJECTS_DIR the root is CLAUDE_CONFIG_DIR/projects; with both set CLAUDE_PROJECTS_DIR wins.
mkdir -p "$tmp/cfg" "$tmp/emptycfg/projects"; ln -s "$proj" "$tmp/cfg/projects"
out=$(HOME="$fakehome" CLAUDE_CONFIG_DIR="$tmp/cfg" "$B" --since 1 2>&1)
chk "A(policy)=4 B(infra)=3" "default root is CLAUDE_CONFIG_DIR/projects"
out=$(HOME="$fakehome" CLAUDE_CONFIG_DIR="$tmp/emptycfg" CLAUDE_PROJECTS_DIR="$proj" "$B" --since 1 2>&1)
chk "A(policy)=4 B(infra)=3" "CLAUDE_PROJECTS_DIR wins over CLAUDE_CONFIG_DIR"

# The prefix strip is anchored to the start of the folder name: a slug in the middle stays.
mkdir -p "$proj/zz${hs}-Projects-mid"; mk "[Git Destructive]" > "$proj/zz${hs}-Projects-mid/dddddddd4444.jsonl"
out=$(HOME="$fakehome" CLAUDE_PROJECTS_DIR="$proj" "$B" --since 1 2>&1)
chk "^  zz-" "a home slug in the middle of a folder name is kept"

# Usage errors exit 2 with a message and the usage line, never a traceback or a silent ignore.
for args in "--since" "--since abc" "--since nan" "--bogus" "--detail extra"; do
  out=$(HOME="$fakehome" CLAUDE_PROJECTS_DIR="$proj" "$B" $args 2>&1 >/dev/null); rc=$?
  [ "$rc" = 2 ] && grep -q "^classifier-denials: " <<< "$out" && grep -q "^usage: classifier-denials" <<< "$out" && ! grep -q Traceback <<< "$out" \
    && ok "usage error exits 2: $args" || bad "usage error for '$args': rc $rc, $out"
done

exit $fail
