#!/bin/bash
# Fixture check for lesson-claim-check.sh and turn_scan.bash_write_targets.
# Usage: plugins/seyag/hooks/lesson-claim-check.probe.sh   (from anywhere)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$SCRIPT_DIR/lesson-claim-check.sh"
HOOK_LIB="$SCRIPT_DIR/lib"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export PYTHONDONTWRITEBYTECODE=1

# Fixture paths are invented, under $TMP.
unset SYG_LESSON_SURFACE_RE SYG_LESSON_FILING_RE SYG_LESSON_CLAIM_RE

# Build a transcript: one user turn + optional Edit(file) + a final text block.
mktx() { # $1=out $2=text $3=edited_file(optional)
  {
    echo '{"type":"user","isMeta":null,"message":{"content":"go"}}'
    [ -n "${3:-}" ] && printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"%s"}}]}}\n' "$3"
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":%s}]}}\n' "$(printf '%s' "$2" | python3 -I -B -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  } | tee "$1" >/dev/null
}

# Same, but the write is a Bash tool_use.
mktx_bash() { # $1=out $2=text $3=bash_command
  {
    echo '{"type":"user","isMeta":null,"message":{"content":"go"}}'
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":%s}}]}}\n' "$(printf '%s' "$3" | python3 -I -B -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":%s}]}}\n' "$(printf '%s' "$2" | python3 -I -B -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  } | tee "$1" >/dev/null
}

# Same, but the write is an arbitrary file tool (Write, MultiEdit, ...).
mktx_tool() { # $1=out $2=text $3=tool_name $4=file_path
  {
    echo '{"type":"user","isMeta":null,"message":{"content":"go"}}'
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"%s","input":{"file_path":"%s"}}]}}\n' "$3" "$4"
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":%s}]}}\n' "$(printf '%s' "$2" | python3 -I -B -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  } | tee "$1" >/dev/null
}

# Same, but the tool is SendMessage.
mktx_msg() { # $1=out $2=text $3=message
  {
    echo '{"type":"user","isMeta":null,"message":{"content":"go"}}'
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"SendMessage","input":{"to":"peer","summary":"note","message":%s}}]}}\n' "$(printf '%s' "$3" | python3 -I -B -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":%s}]}}\n' "$(printf '%s' "$2" | python3 -I -B -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  } | tee "$1" >/dev/null
}

fail=0
check() { # $1=expected_exit $2=label $3=transcript $4=stop_active
  echo "{\"stop_hook_active\":${4:-false},\"transcript_path\":\"$3\"}" | bash "$HOOK" >/dev/null 2>&1
  local got=$?
  if [ "$got" != "$1" ]; then echo "FAIL [$got≠$1]: $2"; fail=1; else echo "ok   [$got]: $2"; fi
}

check_lam() { # $1=expected_exit $2=label $3=transcript $4=lam $5=stop_active
  local lam_json
  lam_json=$(printf '%s' "$4" | python3 -I -B -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
  echo "{\"stop_hook_active\":${5:-false},\"transcript_path\":\"$3\",\"last_assistant_message\":$lam_json}" | bash "$HOOK" >/dev/null 2>&1
  local got=$?
  if [ "$got" != "$1" ]; then echo "FAIL [$got≠$1]: $2"; fail=1; else echo "ok   [$got]: $2"; fi
}

CLAIM="One lesson, now in my notes: next time I'll name the branch worktree-x."

# ── Block (2) cases ──────────────────────────────────────────────────────────
mktx "$TMP/b1.jsonl" "$CLAIM" "$TMP/proj/notes/roles/me.md"
check 2 "block: claim + Edit of role-file-shaped notes path" "$TMP/b1.jsonl"

mktx "$TMP/b2.jsonl" "$CLAIM"
check 2 "block: claim + no tool use" "$TMP/b2.jsonl"

mktx "$TMP/b3.jsonl" "I'll make sure to run the gate first." "$TMP/home/memory/feedback_x.md"
check 2 "block: 'I'll make sure to...' + Edit of memory path" "$TMP/b3.jsonl"

mktx_bash "$TMP/b4.jsonl" "$CLAIM" "grep -n foo plugins/x/hooks/a.sh 2>&1"
check 2 "block: claim + read-only Bash grep with 2>&1 stderr redirect" "$TMP/b4.jsonl"

mktx_bash "$TMP/b5.jsonl" "$CLAIM" "cat rules/core.md > /dev/null"
check 2 "block: claim + Bash cat of rules/core.md redirected to /dev/null" "$TMP/b5.jsonl"

mktx_msg "$TMP/b6.jsonl" "$CLAIM" "0.3.206 shipped, please reload"
check 2 "block: claim + status SendMessage (not a filing)" "$TMP/b6.jsonl"

mktx "$TMP/b7.jsonl" "That won't happen again."
check 2 "block: 'That won't happen again.' alone" "$TMP/b7.jsonl"

mktx "$TMP/b8.jsonl" "Lesson learned: check the base first."
check 2 "block: 'Lesson learned: check the base first.' alone" "$TMP/b8.jsonl"

mktx "$TMP/b9.jsonl" "I've learned my lesson here."
check 2 "block: 'I've learned my lesson here.' alone" "$TMP/b9.jsonl"

mktx "$TMP/b10.jsonl" "All green, merged."
check_lam 2 "block: LAM envelope carries a claim while transcript text has none (LAM wins)" "$TMP/b10.jsonl" "That won't happen again."

# ── Round 1: per-paragraph verdict, H3 filing, M2 families, M3 quotes ────────
mktx "$TMP/m1.jsonl" "Next time I'll check the base first.

The CI lint step is not enforced on forks."
check 2 "block: paragraph 1 claims, paragraph 2 is honest (verdict per paragraph)" "$TMP/m1.jsonl"

mktx_msg "$TMP/h3a.jsonl" "$CLAIM" "Can you check the file I edited?"
check 2 "block: SendMessage 'Can you check the file I edited?' is not a filing" "$TMP/h3a.jsonl"
mktx_msg "$TMP/h3b.jsonl" "$CLAIM" "I tracked it down: the hook was misconfigured."
check 2 "block: SendMessage 'I tracked it down: the hook was misconfigured.' is not a filing" "$TMP/h3b.jsonl"
mktx_msg "$TMP/h3c.jsonl" "$CLAIM" "The gate passed; filed the PR."
check 2 "block: SendMessage 'The gate passed; filed the PR.' is not a filing" "$TMP/h3c.jsonl"
mktx_msg "$TMP/h3d.jsonl" "$CLAIM" "Reloaded; the rule file is in place, check it."
check 2 "block: SendMessage 'Reloaded; the rule file is in place, check it.' is not a filing" "$TMP/h3d.jsonl"

mktx "$TMP/m2a.jsonl" "I won't make that mistake again."
check 2 "block: never-again family ('I won't ... again')" "$TMP/m2a.jsonl"
mktx "$TMP/m2b.jsonl" "I'll always check the base before the gate."
check 2 "block: I'll + commitment adverb ('I'll always ...')" "$TMP/m2b.jsonl"
mktx "$TMP/m2c.jsonl" "I'll be more careful with the base."
check 2 "block: I'll + 'be more careful'" "$TMP/m2c.jsonl"
mktx "$TMP/m2d.jsonl" "Moving forward, I'll check the base first."
check 2 "block: time marker 'moving forward' + I'll" "$TMP/m2d.jsonl"
mktx "$TMP/m2e.jsonl" "Henceforth I'll check the base."
check 2 "block: time marker 'henceforth' + I'll" "$TMP/m2e.jsonl"
mktx "$TMP/m2f.jsonl" "Going forward, always check the base."
check 2 "block: bare imperative 'Going forward, always ...'" "$TMP/m2f.jsonl"
mktx "$TMP/m2g.jsonl" "Noted for next time."
check 2 "block: 'Noted for next time.'" "$TMP/m2g.jsonl"
mktx "$TMP/m2h.jsonl" "Remembered for next session."
check 2 "block: 'Remembered for next session.'" "$TMP/m2h.jsonl"
mktx "$TMP/m2i.jsonl" "Lesson: check the base first."
check 2 "block: line-leading 'Lesson:' label" "$TMP/m2i.jsonl"
mktx "$TMP/m2j.jsonl" "- **Takeaway:** check the base first."
check 2 "block: line-leading bulleted bold 'Takeaway:' label" "$TMP/m2j.jsonl"
mktx "$TMP/m2k.jsonl" "The lesson learned here is to check the base."
check 2 "block: mid-sentence 'The lesson learned here'" "$TMP/m2k.jsonl"
mktx "$TMP/m2l.jsonl" "Hard lesson learned."
check 2 "block: 'Hard lesson learned.'" "$TMP/m2l.jsonl"
mktx "$TMP/p11b.jsonl" "## Lesson learned
Check the base first."
check 2 "pinned known fire: '## Lesson learned' heading + prose (line-leading singular blocks)" "$TMP/p11b.jsonl"

mktx "$TMP/m3.jsonl" "He said \"x. Next time I'll check the base. Then \"y\" done."
check 2 "block: long/sentence-bearing quote no longer swallows the claim" "$TMP/m3.jsonl"

mktx "$TMP/c1.jsonl" "One lesson, now in my notes: next time I'll name the trial branch worktree-x."
check 2 "block: 'One lesson, now in my notes: next time I'll name the trial branch worktree-x.'" "$TMP/c1.jsonl"
mktx "$TMP/c2.jsonl" "Next time I'll check first and launch after."
check 2 "block: 'Next time I'll check first and launch after.'" "$TMP/c2.jsonl"
mktx "$TMP/c3.jsonl" "I'll name the branch worktree-x next time."
check 2 "block: 'I'll name the branch worktree-x next time.'" "$TMP/c3.jsonl"

mktx_bash "$TMP/h1.jsonl" "$CLAIM" "grep -c '>' hooks/x.sh"
check 2 "block: H1 quoted '>' in grep is not a redirect (hook level)" "$TMP/h1.jsonl"
mktx_bash "$TMP/h2.jsonl" "$CLAIM" "git commit -m \"fix open('rules/x.md', 'w') bug\""
check 2 "block: H2 script-write text inside git commit -m is only mentioned (hook level)" "$TMP/h2.jsonl"

# ── Round 2: credit only what is provable ────────────────────────────────────
mktx_bash "$TMP/r2a.jsonl" "$CLAIM" "grep -c '>' hooks/x.sh # check it's there"
check 2 "block: r2 comment with an apostrophe after a quoted '>' (ambiguous, no credit)" "$TMP/r2a.jsonl"
mktx_bash "$TMP/r2b.jsonl" "$CLAIM" 'grep \> hooks/x.sh'
check 2 "block: r2 escaped \\> is an argument, not a redirect" "$TMP/r2b.jsonl"
mktx_bash "$TMP/r2c.jsonl" "$CLAIM" 'cd hooks && ./t.sh && cd .. && echo n >> notes.md'
check 2 "block: r2 cd hooks && cd .. then append to notes.md (no cd tracking)" "$TMP/r2c.jsonl"
mktx_bash "$TMP/r2d.jsonl" "$CLAIM" 'cd hooks && ./t.sh && cd && echo n >> notes.md'
check 2 "block: r2 cd hooks then bare cd then append to notes.md" "$TMP/r2d.jsonl"
mktx_bash "$TMP/r2e.jsonl" "$CLAIM" 'bash -c "echo n > notes.md" && cd hooks && ls'
check 2 "block: r2 bash -c write to notes.md, no recursion into bash -c" "$TMP/r2e.jsonl"
mktx_bash "$TMP/r2f.jsonl" "$CLAIM" 'git commit -m '\''document bash and $(echo > hooks/a.sh)'\'''
check 2 "block: r2 \$(...) inside single quotes is inert, no substitution credit" "$TMP/r2f.jsonl"
mktx_bash "$TMP/r2g.jsonl" "$CLAIM" 'grep -rn "backlog task create" plugins/'
check 2 "block: r2 grep of a quoted tracker-CLI string (not a filing)" "$TMP/r2g.jsonl"
mktx_bash "$TMP/r2h.jsonl" "$CLAIM" 'git commit -m "credit backlog task create in hook"'
check 2 "block: r2 git commit message mentioning a tracker-CLI filing (not a filing)" "$TMP/r2h.jsonl"

# CLAIM_RE: a dot inside a filename no longer ends the gap; a condition clause after 'next time' is a claim.
mktx "$TMP/r2i.jsonl" "I'll check CLAUDE.md next time."
check 2 "block: r2 dotted filename inside the claim gap ('I'll check CLAUDE.md next time.')" "$TMP/r2i.jsonl"
mktx "$TMP/r2j.jsonl" "I won't edit rules/core.md directly again."
check 2 "block: r2 dotted filename inside the never-again gap" "$TMP/r2j.jsonl"
mktx "$TMP/r2k.jsonl" "Next time this happens, I'll check the base first."
check 2 "block: r2 'Next time <condition>, I'll ...' (condition clause)" "$TMP/r2k.jsonl"
mktx "$TMP/r2k2.jsonl" "Next time it happens, I'll check the base first."
check 2 "block: condition clause opening with 'it'" "$TMP/r2k2.jsonl"
# Replay-observed false stops (third-person "won't … again"; a next-session to-do):
mktx "$TMP/rp1.jsonl" "The cron was a one-shot and won't fire again."
check 0 "pass: third-person 'won't fire again' is not a claim" "$TMP/rp1.jsonl"
mktx "$TMP/rp2.jsonl" "Next session I'll confirm the timer ran."
check 0 "pass: 'Next session I'll …' is a scheduled to-do" "$TMP/rp2.jsonl"
mktx "$TMP/rp3.jsonl" "I won't bring it up again unless you do."
check 2 "block: first-person 'I won't … again' commitment" "$TMP/rp3.jsonl"

# Quote strip: an odd count of ASCII double quotes on a line strips nothing from it.
mktx "$TMP/r2l.jsonl" 'Fixed the stray " token, so next time I'\''ll check the "foo" case first.'
check 2 "block: r2 stray unpaired quote does not swallow the claim" "$TMP/r2l.jsonl"

# ── Pass (0) cases ───────────────────────────────────────────────────────────
mktx "$TMP/p1.jsonl" "$CLAIM" "$TMP/proj/plugins/x/hooks/new-guard.sh"
check 0 "pass: claim + Edit of hooks/new-guard.sh" "$TMP/p1.jsonl"

mktx_tool "$TMP/p2.jsonl" "$CLAIM" Write "$TMP/proj/.claude/rules/x.md"
check 0 "pass: claim + Write of .claude/rules/x.md" "$TMP/p2.jsonl"

mktx "$TMP/p3.jsonl" "$CLAIM" "$TMP/proj/CLAUDE.md"
check 0 "pass: claim + Edit of CLAUDE.md" "$TMP/p3.jsonl"

mktx_tool "$TMP/p4.jsonl" "$CLAIM" Write "$TMP/proj/backlog/tasks/task-9 - x.md"
check 0 "pass: claim + Write of backlog/tasks/task-9 - x.md" "$TMP/p4.jsonl"

mktx_bash "$TMP/p5.jsonl" "$CLAIM" "backlog task create 'Guard for X'"
check 0 "pass: claim + Bash backlog task create" "$TMP/p5.jsonl"

mktx_bash "$TMP/p6.jsonl" "$CLAIM" "cd $TMP/proj && sed -i 's/a/b/' skills/x/SKILL.md"
check 0 "pass: claim + Bash cd && sed -i on skills/x/SKILL.md" "$TMP/p6.jsonl"

mktx_bash "$TMP/p7.jsonl" "$CLAIM" "printf x >> hooks/x.sh"
check 0 "pass: claim + Bash append redirect >> hooks/x.sh" "$TMP/p7.jsonl"

mktx_bash "$TMP/p8.jsonl" "$CLAIM" "cp /tmp/a $TMP/proj/rules/new.md"
check 0 "pass: claim + Bash cp to rules/new.md" "$TMP/p8.jsonl"

mktx_msg "$TMP/p9.jsonl" "$CLAIM" "Please file a hook for this: block X when Y."
check 0 "pass: claim + SendMessage filing a hook" "$TMP/p9.jsonl"

mktx "$TMP/p10.jsonl" "A lesson from the incident doc: the reaper runs at 2am."
check 0 "pass: no claim vocabulary (a lesson FROM a doc)" "$TMP/p10.jsonl"

mktx "$TMP/p11.jsonl" "## Lessons learned
12 lessons learned this week; 4 filed."
check 0 "pass: mining vocabulary ('## Lessons learned' + '12 lessons learned')" "$TMP/p11.jsonl"

mktx "$TMP/p12.jsonl" 'The hook fires on "next time I'\''ll" and "won'\''t happen again".'
check 0 "pass: quoted phrase list" "$TMP/p12.jsonl"

mktx "$TMP/p13.jsonl" "> next time I'll remember
That was the old closing."
check 0 "pass: blockquote line followed by non-claim prose" "$TMP/p13.jsonl"

mktx "$TMP/p14.jsonl" "Nothing enforces this yet, so I won't claim I'll remember it."
check 0 "pass: honest disclaimer" "$TMP/p14.jsonl"

TICK=$(printf '\140')
mktx "$TMP/p15.jsonl" "The phrase ${TICK}I'll remember to${TICK} is in CLAIM_RE."
check 0 "pass: claim phrase inside an inline code span" "$TMP/p15.jsonl"

mktx "$TMP/p16.jsonl" "All green, merged."
check 0 "pass: no-claim close" "$TMP/p16.jsonl"

mktx "$TMP/nm4.jsonl" "I've noted it in the handoff and will close the row next commit."
check 0 "pass: 'I've noted it in the handoff ...' records a to-do, not a behaviour change" "$TMP/nm4.jsonl"
mktx "$TMP/nm5.jsonl" "I'll apply it the next time I restart A."
check 0 "pass: 'I'll apply it the next time I restart A.' (next time ends no clause)" "$TMP/nm5.jsonl"
mktx "$TMP/nm6.jsonl" "I'll watch for that and bring the switch back to you if it happens."
check 0 "pass: 'I'll watch for that and bring the switch back ...' (no watch family)" "$TMP/nm6.jsonl"
mktx "$TMP/nm7.jsonl" "The API never returns that again after the fix."
check 0 "pass: 'The API never returns that again after the fix.' (no first person)" "$TMP/nm7.jsonl"

PYHD=$(printf '%s\n' "PYTHONDONTWRITEBYTECODE=1 python3 - <<'EOF'" "open('hooks/a.sh', 'w')" "EOF")
mktx_bash "$TMP/r2p1.jsonl" "$CLAIM" "$PYHD"
check 0 "pass: r2 env assignment before a python heredoc writes hooks/a.sh" "$TMP/r2p1.jsonl"

mktx_bash "$TMP/r2p2.jsonl" "$CLAIM" "cat b >'backlog/tasks/task-9 - x.md'"
check 0 "pass: r2 glued redirect to a quoted backlog path with spaces" "$TMP/r2p2.jsonl"

mktx_bash "$TMP/r2p3.jsonl" "$CLAIM" "cp -t rules a.md"
check 0 "pass: r2 cp -t DIR (no trailing slash) credits rules/" "$TMP/r2p3.jsonl"

mktx_bash "$TMP/r2p4.jsonl" "$CLAIM" "pnpm tracker task create 'Guard for X'"
check 0 "pass: r2 pnpm tracker task create" "$TMP/r2p4.jsonl"

check 0 "pass: stop_hook_active true with a claim" "$TMP/b2.jsonl" true

# Process-shaped near misses:
mktx "$TMP/nm1.jsonl" "I'll rerun the probe once CI is green."
check 0 "pass: process-shaped near miss ('I'll rerun the probe once CI is green.')" "$TMP/nm1.jsonl"

mktx "$TMP/nm2.jsonl" "I'll remember the PR number in the changelog fill."
check 2 "pinned known fire: process-shaped 'I'll remember the PR number...' (CLAIM_RE alt 1)" "$TMP/nm2.jsonl"

# Knob overrides and invalid-regex fallbacks:
SYG_LESSON_SURFACE_RE='notes/' check 0 "knob override: SYG_LESSON_SURFACE_RE='notes/' credits the notes edit" "$TMP/b1.jsonl"
SYG_LESSON_SURFACE_RE='(unclosed[' check 0 "knob fallback: invalid SYG_LESSON_SURFACE_RE falls back to default (hooks/ passes)" "$TMP/p1.jsonl"
SYG_LESSON_SURFACE_RE='(unclosed[' check 2 "knob fallback: invalid SYG_LESSON_SURFACE_RE falls back to default (notes/ blocks)" "$TMP/b1.jsonl"
SYG_LESSON_FILING_RE='(unclosed[' check 0 "knob fallback: invalid SYG_LESSON_FILING_RE falls back to default (filing passes)" "$TMP/p9.jsonl"
SYG_LESSON_FILING_RE='(unclosed[' check 2 "knob fallback: invalid SYG_LESSON_FILING_RE falls back to default (status blocks)" "$TMP/b6.jsonl"
SYG_LESSON_CLAIM_RE='(unclosed[' check 2 "knob fallback: invalid SYG_LESSON_CLAIM_RE falls back to default (claim blocks)" "$TMP/b7.jsonl"
SYG_LESSON_CLAIM_RE='zzz' check 0 "knob override: SYG_LESSON_CLAIM_RE='zzz' passes 'won't happen again'" "$TMP/b7.jsonl"

# Banner check: title line and rule citation.
BANNER=$(echo "{\"stop_hook_active\":false,\"transcript_path\":\"$TMP/b2.jsonl\"}" | bash "$HOOK" 2>&1 >/dev/null)
if grep -qF 'LESSON CLAIM — a behaviour-change claim with no enforcing artifact this turn' <<<"$BANNER" \
  && grep -qF 'rules/core.md § "Fix recurring failures structurally"' <<<"$BANNER"; then
  echo "ok   [2]: banner carries pinned title line and rules/core.md citation"
else
  echo "FAIL: banner missing title line or rules/core.md citation"; fail=1
fi

# ── bash_write_targets unit cases ────────────────────────────────────────────
bwt_check() { # $1=cmd $2=expected_repr
  local got
  got=$(HOOK_LIB="$HOOK_LIB" CMD="$1" python3 -I -B -c '
import os, sys
sys.path.insert(0, os.environ["HOOK_LIB"])
from turn_scan import bash_write_targets
print(repr(bash_write_targets(os.environ["CMD"])))
')
  if [ "$got" = "$2" ]; then
    echo "ok   [bwt]: $1 -> $got"
  else
    echo "FAIL [bwt]: $1 -> got $got, want $2"
    fail=1
  fi
}

bwt_check '2>&1' "[]"
bwt_check '>&2' "[]"
bwt_check 'a > b' "['b']"
bwt_check 'x | tee -a p q' "['p', 'q']"
bwt_check 'sed -i -e s/a/b/ f g' "['f', 'g']"
bwt_check 'sed -i s/a/b/ f' "['f']"
bwt_check 'cd d && echo > e' "['e']"
bwt_check 'cp a b c/' "['c/']"
bwt_check 'python3 -c "open('\''o.md'\'','\''w'\'')"' "['o.md']"

bwt_check "grep -c '>' hooks/x.sh" "[]"
bwt_check "echo '>' rules/core.md" "[]"
bwt_check "grep '>hooks/' f" "[]"
bwt_check "grep -rn \"open('hooks/a.sh','w')\" ." "[]"
bwt_check "git commit -m \"fix open('rules/x.md', 'w') bug\"" "[]"
bwt_check $'cat <<\'EOF\'\nwriteFileSync(\'hooks/x\', d)\nEOF' "[]"
bwt_check $'python3 - <<\'EOF\'\nopen(\'o.md\',\'w\')\nEOF' "['o.md']"
bwt_check "echo x > 'hooks/y'" "['hooks/y']"
bwt_check "bash -c \"echo > hooks/w\"" "[]"
bwt_check "cp -t /tmp rules/core.md" "['/tmp/']"
bwt_check "cp -t rules/ a.md" "['rules/']"

# Round 2: no cd tracking, no recursion, an ambiguous command gives no credit.
bwt_check 'cd hooks && ./t.sh && cd .. && echo n >> notes.md' "['notes.md']"
bwt_check 'cd hooks && ./t.sh && cd && echo n >> notes.md' "['notes.md']"
bwt_check 'bash -c "echo n > notes.md" && cd hooks && ls' "[]"
bwt_check "grep -c '>' hooks/x.sh # check it's there" "[]"
bwt_check 'grep \> hooks/x.sh' "[]"
bwt_check "git commit -m 'document bash and \$(echo > hooks/a.sh)'" "[]"
bwt_check 'grep -rn "backlog task create" plugins/' "[]"
bwt_check $'echo x > hooks/a.sh\n# it\'s step 1' "[]"
bwt_check $'PYTHONDONTWRITEBYTECODE=1 python3 - <<\'EOF\'\nopen(\'hooks/a.sh\', \'w\')\nEOF' "['hooks/a.sh']"
bwt_check "cat b >'backlog/tasks/task-9 - x.md'" "['backlog/tasks/task-9 - x.md']"

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
