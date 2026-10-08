---
name: advisor
description: 'One strong-lane opinion for a knot the current lane can''t crack: distill the sub-problem, dispatch a single strong-model subagent for an answer, and weigh it like any reviewer''s. Use when the current lane keeps failing on one problem, when you want a stronger model''s opinion on one problem, when escalating one question to the strong lane, or before burning more rounds on a failing approach.'
---

# Advisor

A knot too hard for the session's current lane gets ONE opinion from the strongest configured model, in one dispatch. This is the fleet's gateway-agnostic take on Claude Code's native /advisor pattern, which is Anthropic-API-only and unusable on routed gateway lanes.

## When to escalate

- Repeated failed attempts on the same problem.
- A reasoning-class question the working model keeps fumbling.
- A decision that needs a stronger model's read before committing work.

The skill is INVOKED — by the session or the owner. **There is no auto-trigger, no hook, no server dependency.**

## Package, don't dump

Distill the SUB-PROBLEM and the minimal context needed to reason about it: the files, excerpts, error text, and what was already tried. **The whole transcript is NEVER handed over.** The reason is context economy: the advisor prices by tokens too, and a transcript is the caller's framing, not the problem.

## Dispatch

ONE subagent (the Agent tool's general-purpose type, or the session's equivalent), with **the strong-lane model, always passed explicitly as the Agent `model` (on the Anthropic lane `fable`, or `opus` when Fable is capped; on a routed gateway, the alias whose `ANTHROPIC_DEFAULT_<ALIAS>_MODEL` names that gateway's strongest model: `env | grep '^ANTHROPIC_DEFAULT_.*_MODEL='` lists them, and no output means the aliases mean what they say), never defaulted by omission**. (The strong lane, not the role map's worker pick: the advisor's whole point is the strongest model whatever the role map says.) Where the Agent tool cannot reach the strong lane (the session is routed to a gateway whose subagents share its lane), the project may configure a first-party worker command — a headless CLI dispatch on another route; the package and the single-opinion discipline are unchanged. Ask for an answer: the reasoning, the recommendation, the checks that would falsify it.

> **The advisor ANSWERS; it never edits files, never spawns further agents, never commits — the CALLER stays driver and implements.**

## Weigh the answer

The guidance comes back to the caller, who weighs it like any reviewer's: advisors give the principle; the code gives the target (core.md § Advisors). Record any correction to the advisor's reading where the next session will look.

## Routing

> One strong opinion = subagent override (this skill); a diverse panel / debate / second-opinion-CLASS question = council MCP (seyag:council). Neither replaces the other.

## Guardrails

> **ONE subagent per escalation.** No fan-out, no parallel advisors, no re-rolls until-you-like-the-answer (a re-roll = a new escalation decision, made consciously).

> **Usage-gate discipline:** the same `claude-usage --ok 90` gate that governs any dispatch governs this one; the advisor rides the strong lane's meter, which is usually the scarcer one.

> **When-NOT:** work that is hard for the WHOLE SESSION (hours of big-lane design, a whole domain the lane can't hold) goes to an owner-placed strong session — the strong-lane placement policy — not to advisor-pull. The advisor is for ONE knot, not for relocating a session's whole job.

> **Escalation convention** (deputy-set, owner-tightenable): free under the usage gate, consistent with all subagent dispatch.
