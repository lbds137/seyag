---
name: doc-audit
description: 'Freshness and cost audit for the always-loaded context and the shared memory on this machine: stale memory entries, entries in the wrong layer, broken paths and links, and always-loaded passages that no longer earn their tokens. Use periodically, after a burst of new memories or rules, when sessions feel slow to start, or when the owner asks whether the memory or rules need a cleanup.'
---

# Doc Audit

Checks that what every session loads is accurate and worth its cost, and that the shared memory holds only what belongs there. The deliverable is a set of proposed moves, cuts and fixes with evidence. Nothing is deleted or promoted without the owner's yes (core rules § Fix recurring failures structurally: when a memory is promoted, propose deleting it and delete only on her yes).

## The layers

| Layer | Loads | Who may change it |
|---|---|---|
| `~/.claude/CLAUDE.md` | every session | only the owner approves edits |
| seyag `rules/core.md` (via `~/.claude/rules/seyag-core.md`) | every session | seyag repo; probes green before push |
| shared memory index `MEMORY.md` (`autoMemoryDirectory`) | every session | any session, one line per memory |
| memory files | when recalled | any session; deletion needs the owner's yes |
| a project's `CLAUDE.md` and `.claude/rules/` | sessions in that project | that project's session (send it the proposal) |
| plugin skills, project skills | their descriptions every session, the body on invoke | their repo |
| role files `claude-memory/roles/<folder>.md` | every session in that folder (the `claude-role` SessionStart hook) | that role's session; checkpoints via `claude-role --set` |
| other SessionStart hook output | every session | the hook's repo (`context-audit weigh` counts it from the newest transcript) |
| `~/Documents/dev-docs` env doc | on purpose | Deck management role |

Pick a destination by audience: every session on the machine (seyag rule, skill or env doc), one project's contributors (that project's rules), one person's context (memory).

## Step 1: measure

```bash
context-audit weigh ~/Projects/<project>   # what a session there loads up front, largest first
context-audit refs                         # memory: missing paths, dangling [[links]], non-slug names, index drift
```

Run `weigh` for each project with an active session (the up-front set differs per folder), and note any MEMORY.md load-cap warning it prints: lines past the cap are invisible to every session. `refs` findings are for triage, not mechanical fixes:
- a missing path is stale (fix or delete the claim), moved (point it at the new place, found by grep, not by memory), or deliberately recorded as gone (keep it);
- a dangling `[[link]]` is a misspelling (the hint suggests the target), or a memory worth writing;
- a non-slug `name:` gets rewritten as kebab-case, and every `[[link]]` to the old name updated in the same change.

**Trigger:** after any change that adds to the up-front set (a rule, CLAUDE.md, the memory index, a skill description, a SessionStart hook's output), run `context-audit weigh <project> --budget <bytes>` (or set `CONTEXT_AUDIT_BUDGET`) before the PR; exit 1 means the set grew past the budget, so cut before adding.

## Step 2: memory audit

Read each memory file and give it one verdict:

| Verdict | When | Action |
|---|---|---|
| Keep | per-person context, a preference that doesn't generalize, time-bound state, a pointer to an external resource | none; tighten its index line if it runs long |
| Promote to a rule | "always do X" for every session (seyag rule) or one project (that project's rule) | write the rule first, then propose deleting the memory |
| Promote to a skill | a multi-step procedure | write the skill step first, then propose deleting the memory |
| Move to a doc | a machine fact someone looks up on purpose (env doc) | write the doc first, then propose deleting the memory |
| Delete | stale, resolved, or already said verbatim in a rule, skill or doc | propose it, with the line that makes it redundant |

**Write the destination before proposing the deletion, and check it carries the whole intent**, including the exception or failure case the memory records. A memory proposed for deletion as "carried elsewhere" is quoted from its carrier at a commit ref (`git show <ref>:<path>`), not a working tree, in the same line as the proposal. A deleted memory whose nuance never reached the destination is lost. If the destination can't take the nuance yet, the verdict is Keep. An approved deletion removes the memory file AND its `MEMORY.md` line in the same change. Commit to `claude-memory` by explicit paths, never `git add -A`: other sessions write there too.

Before calling an entry stale, check it against the code or the machine (the file, flag or unit it names still exists?). A memory that reads fluently can still be wrong.

## Step 3: economy pass

Take the `weigh` ranking for the busiest project, and work the top 3 always-loaded files the audit may change (skip `~/.claude/CLAUDE.md` unless the owner asked). For each passage ask:

1. **Is it narrative rather than a constraint?** Incident stories, dates and "this happened twice" belong in git, not in always-loaded text.
2. **Would a reader act differently without it?** If not, it costs tokens to be agreed with.
3. **Is it said in more than one layer?** Keep one canonical statement at the layer that loads when needed; link from the others.
4. **Has a hook or check made it structural?** Then the prose is a weaker second copy.

A "yes" to 1, 3 or 4, or a "no" to 2, is a cut. Cut text goes nowhere: git keeps it. Re-run `weigh` and quote the before/after bytes in the change; a trim with no number is indistinguishable from a reshuffle. Cuts to the seyag rules go through the repo's normal gate (probes, and the owner sees the change reported).

**This pass defaults to cutting, and the owner sees the list.** The agent that has been adding rules is a biased judge of what's excess, and the corpus only ever grows otherwise. When a passage is genuinely contested, cut it and say so in the report: the owner restoring one line is cheaper than the corpus keeping ten.

## Step 4: accuracy spot-checks

For each plugin skill and each always-loaded file changed since the last audit: every path it names exists, every command block still runs as written (run it in the state it's written for), and every tool it names is on PATH.

## Report

Lead with the numbers (bytes per surface before and after, findings per category). Then one line per proposed move, cut or deletion with its evidence and its verdict. Ask the owner once for the deletions and promotions as a list. After her answer:
- apply the approved ones, destination first;
- send project-rule proposals to the owning session as a message pointing at a file, not as an edit;
- record every proposal's disposition (done, rejected with the reason, or deferred with a trigger) in the Deck management role file, with the audit's date and the `weigh` totals. That line is the baseline the next audit's Step 4 ("changed since the last audit") and byte comparison read.

## Anti-patterns

| Don't | Do instead |
|---|---|
| Delete a memory before its destination has the nuance | Destination first, then propose the deletion |
| Edit another project's rules from here | Send that project's session the proposal |
| Move cut text to an archive file | Git holds it |
| Trim without numbers | `context-audit weigh` before and after |
| Call a memory stale from its wording | Check the file, flag or unit it names |
