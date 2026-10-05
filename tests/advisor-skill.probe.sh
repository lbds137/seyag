#!/bin/bash
# Advisor-skill guardrail lint: the advisor skill is prose, so its guardrails
# are pinned by exact marker phrases. A future editor deleting a guardrail
# (routing rule, ONE-subagent cap, usage gate, when-NOT placement, transcript
# rule, caller-stays-driver, non-goals, model default) must fail this probe.
# name == dirname is NOT checked here: tests/skill-name-lint.probe.sh already
# covers it for every skill. Usage: tests/advisor-skill.probe.sh   (from anywhere)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$REPO/plugins/seyag/skills/advisor/SKILL.md"
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

[ -f "$SKILL" ] || { bad "advisor skill missing: $SKILL"; exit 1; }

# has <guardrail-name> <pinned phrase>
has() {
  local name=$1 phrase=$2
  if grep -qF -- "$phrase" "$SKILL"; then
    ok "advisor: $name present"
  else
    bad "advisor: missing guardrail '$name' (pinned phrase not found: $phrase)"
  fi
}

has "routing rule" "One strong opinion = subagent override (this skill); a diverse panel / debate / second-opinion-CLASS question = council MCP (seyag:council). Neither replaces the other."
has "ONE-subagent cap" "ONE subagent per escalation"
has "no re-rolls" "no re-rolls until-you-like-the-answer"
has "usage gate" "claude-usage --ok 90"
has "usage-gate rationale" "the advisor rides the strong lane's meter, which is usually the scarcer one"
has "when-NOT / strong-lane placement" "the strong-lane placement policy"
has "advisor is for ONE knot" "The advisor is for ONE knot, not for relocating a session's whole job"
has "never-the-transcript" "The whole transcript is NEVER handed over"
has "caller stays driver" "never edits files, never spawns further agents, never commits"
has "non-goals" "no auto-trigger, no hook, no server dependency"
has "model default (strong-lane role)" "the strong-lane model, always passed explicitly as the Agent \`model\` (on the Anthropic lane \`fable\`, or \`opus\` when Fable is capped; on a routed gateway, the alias whose \`ANTHROPIC_DEFAULT_<ALIAS>_MODEL\` names that gateway's strongest model: \`env | grep '^ANTHROPIC_DEFAULT_.*_MODEL='\` lists them, and no output means the aliases mean what they say), never defaulted by omission"

if [ "$fail" -ne 0 ]; then exit 1; fi
ok "advisor skill: all guardrails pinned"
