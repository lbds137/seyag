---
name: discord-design-language
description: 'Discord bot UI design language: the 3-second ack window, ephemeral-vs-public defaults, the customId delimiter invariant, fixed button order, the slash-command verb table, and server-side permission checks on destructive confirms. Use when building or reviewing Discord bot UI in any project.'
---

# Discord Bot UI Design Language

Distilled from Tzurot's codified Discord rules and YAGPDB consultations (2026-09-30; YAGPDB second-implementer review folded 2026-10-01); lifted as the first template of the Seyag poaching pattern (Tzurot drafts generic material, seyag packages it).

**How to use:** treat each numbered rule as the default. Deviations are allowed when a project records the reason where it deviates. Every Discord term is defined inline where it first appears — a session that has never driven a bot can apply every rule here without prior Discord knowledge.

---
## 1. The 3-second acknowledgment window

An **interaction** is any user action the bot must answer: a slash command, a button press, a select-menu pick, a modal submission, an autocomplete keystroke. Discord requires the bot to **acknowledge** (send the first empty/holding response for) an interaction within 3 seconds or the client shows the user a failure.

- **The budget is indivisible.** Any async work — database lookup, cache read, HTTP call — belongs *after* the ack, never before. A lookup that takes 50 ms today takes seconds under load, and the window doesn't distinguish "cheap" from "expensive" async work.
- **Defer first, then process.** The standard shape: acknowledge immediately with a holding response (**defer** — `deferReply` for a new reply, `deferUpdate` for editing the message the component lives on), do the async work, then edit the holding response with the real content.
- **The modal carve-out:** a handler that answers with a **modal** (a popup form the bot opens in response to an interaction) *cannot* defer: the modal and the deferral share the interaction's single response slot, so a deferred handler can never open one. Such a handler keeps its whole answer inside the 3-second window. "Defer first" is the default shape, not a universal one — deferring and then opening a modal is a runtime error, not a slow path.
- **Synchronous guards may run before the ack** when their only job is deciding whether this handler claims the interaction at all (parsing the button id, prefix checks). Anything that `await`s may not.
- **Nested routers:** if a top-level router must do async work (e.g. a session lookup) to pick a downstream handler, the *router* acks first. Downstream handlers then guard against double-acknowledging (`if not deferred and not replied: defer`) so they stay callable standalone (tests, direct dispatch). Don't remove a downstream defer to "simplify" — that couples the handler to one caller's contract.

## 2. Response visibility: ephemeral vs public

An **ephemeral** response is visible only to the user who triggered the interaction; a **public** response is visible to everyone in the channel.

- **Ephemeral by default for:** settings screens, error messages, dashboards, anything carrying per-user data. **Public for:** displays others might want to see (leaderboards, rich result cards, announcements).
- When in doubt, ephemeral — a wrong public message is seen by everyone; a wrong ephemeral message is seen by one person.
- **When an ephemeral migration replaces a public flow, record where the audit trail went.** Ephemeralizing a formerly public response silently deletes the public record of who changed what; that's an owner-visible trade to rule on deliberately, not a side effect to discover later.

## 3. Components, buttons, and the customId invariant

A **component** is an interactive element attached to a message (button, select menu). Every component carries a **customId** — a project-defined string (max 100 characters) returned to the bot when the component is used. The customId is the *entire* routing and state mechanism; the bot receives it cold on every process.

### 3a. The delimiter invariant (the one hard rule)

> **A customId delimiter must be a character that cannot occur in any segment the project encodes into the id.**

- Tzurot uses `::` (double-colon) because its slugs may contain `-`, which rules out `-`; single `:` is safe because slugs never contain colons... but double-colon also survives a future colon-bearing segment.
- YAGPDB uses single `:` with colon-free segments (`ca:stale:2` = pager `ca`, view `stale`, page `2`) — established by its `channel_activity_pager` and holding because its segments are enums and integers.
- The failure shape the invariant prevents: a segment containing the delimiter, splitting into more parts than the parser expects. Whatever you choose, the parser asserts the expected part count and rejects the rest.
- **Encode state in one of three homes, never in in-process closures** — processes restart and replicas race; the id must carry everything needed to route from cold:
  1. *the customId itself* — for bounded, delimiter-safe state (enums, ids, page numbers);
  2. *the message's own fields* — e.g. a footer carrying a slug that would blow the id's length budget;
  3. *a server-side pointer* — the id carries only a spawner id + spawn timestamp (`editdel:<uid>:<stamp>:go`), pointing at a one-per-spawner record the handler reads and consumes per press. This is the home for state that is unbounded (free-form user strings), delimiter-unsafe, or escaping-hostile to parse back out of a message.
- **The 100-char ceiling is post-tax.** The ceiling is the framework's, minus any prefix it stamps onto every id before delivery (one engine prefixes 10 characters of `templates-` and strips it before matching, so that project's real budget is 90) — know the prefix before designing the segments, or discover the limit by Discord refusal.

### 3b. Button text and layout

- **Set the label and the emoji separately** (label "Back", emoji `◀️`), never inline as "◀️ Back" — inline emoji renders as a skinny, misaligned button.

### 3c. Button order (fixed)

1. Primary actions (Edit, Save, Lock/Unlock)
2. View actions (Details, Refresh)
3. Navigation (Back, page counters)
4. Destructive (Delete) — **always last**, styled as the danger/destructive button

Muscle memory matters more than context: a user who has pressed "the last button" once should never be surprised twice.

## 4. Slash command vocabulary

A **slash command** is a user-invoked command (`/name`) with typed **options**; a **subcommand** is a named verb under one command (`/db view`). Canonical subcommand verbs, in preference order:

| Verb      | Meaning                                   | Notes                                          |
| --------- | ----------------------------------------- | ---------------------------------------------- |
| `browse`  | Paginated list with a select-menu jump    | Preferred for listing things                   |
| `view`    | Single-item detail                        |                                                |
| `create`  | Make a new item                           |                                                |
| `edit`    | Modify an item (opens an editor)          |                                                |
| `delete`  | Remove an item                            | Must confirm (§ 5)                             |
| `list`    | Simple flat list                          | Legacy; use `browse` for anything new          |
| `export`  | Bulk output as a file (dumps, logs)       | The file-shaped sibling of `view`              |

**Root-verb collision rule:** when the root command itself carries the verb (`/edit`), verb subcommands collide (`/edit edit`); there the subcommands name the OBJECT (`/edit rule`, `/edit entry`), and `delete` stays a verb exception. The verb table wins everywhere else — cross-project muscle memory is the point — but not at this collision.

**Options are short lowercase nouns** (`category`, `key`, `rule`) — they read as fields, not sentences.

**The vocabulary is portable across domains** — proven by the YAGPDB `/db` spec mapping: `get`→`view`, `keys`→`browse`, `set`/`add`/`remove`/`delete` keep their names, `dump`→`export`. When a project's existing verb doesn't map, rename toward the table; the table wins because cross-project muscle memory is the point.

**Autocomplete** (type-ahead suggestions while filling an option): respond within the same 3-second window — use a ~2.5 s internal budget so the bot's own slowness never eats it — and cap the suggestion list (Discord allows 25).

## 5. Destructive actions confirm, and the server decides

- **Every delete confirms first** — a confirmation component the user must press, stating what will be destroyed.
- **A modal cannot confirm.** Modals hold no buttons — only labels, text displays and form inputs (text inputs, select menus, radio groups, checkboxes, file uploads) — and the platform refuses answering a modal submission with another modal — so a delete that lives inside a form flow must leave the form path entirely: it becomes a confirmation *message* (danger button last + a secondary Dismiss) with its own component handler. Don't try to put the confirm inside the modal; the shape is forced, adopt it directly.
- **The permission check runs server-side, at the confirm handler, on every press** — never trust that the client only shows the button to entitled users (anyone can craft a component press). Pattern (the "spawner-gated dismiss"): only the user who spawned the message may dismiss it, verified by comparing the presser's id to the spawner id *carried in the customId or message fields*, re-checked per press — together with the continued existence of the server-side state the press claims.
- **Freshness backstop:** carry the spawn timestamp in the confirm id and refuse stale confirms (one project refuses confirms older than one hour) — cheap insurance against zombie UI left over from before a state change.

## 6. Quiet-success and pagination patterns

- **Quiet success:** for operations that take a while, acknowledge immediately, run the work in the background, and report completion with minimal noise (a single edit or short-lived ephemeral). Don't leave users staring at a holding message, and don't spray progress spam.
- **Page-counter pattern:** a paginated view is one message whose buttons re-render it — the customId carries the state (`pager:view:page`), the handler replaces the message content in place (`update`), and Back/Next move the counter. No per-page new messages.

## 7. Scope of this skill

This is a design language, not a library. Rules here are defaults a project adopts or records a deviation from; implementation mechanics (routers, session managers, embed builders) stay in each project. Tzurot's TypeScript utilities, for instance, are Tzurot's.
