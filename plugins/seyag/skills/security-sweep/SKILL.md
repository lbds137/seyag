---
name: security-sweep
description: "When `security-sweep` reports open GitHub security alerts (code scanning, dependabot, secret scanning) at session start or on request: give each alert a disposition — fix, dismiss with evidence (owner's call), or accept with reason — and report critical/high like a production finding. Use when the SessionStart security line appears, when asked about a repo's security alerts, or before a release."
---

# Security sweep (`seyag:security-sweep`)

`security-sweep` (on PATH from this plugin) queries open GitHub security alerts across `code-scanning`, `dependabot` and `secret-scanning`, which PR checks never show.

## 1. Running the tool

- `security-sweep` — inspects the cwd repo's `origin` remote (5-minute cache under `${XDG_STATE_HOME:-$HOME/.local/state}/seyag/security-sweep/`). The `origin` parser accepts only `github.com` (https/ssh); SSH host aliases and GHE hosts get `origin is not a github.com repo` — pass `-R owner/name` (or set `SYG_SECURITY_SWEEP_REPOS` for SessionStart) as the workaround.
- `security-sweep -R owner/name [-R ...]` or `--all-repos-from FILE` — inspects explicit repos (`#` comments in `FILE`; invalid `owner/name` tokens are skipped with a stderr warning while valid repos still run).
- `security-sweep --json` — machine-readable per-repo summary (`count` surfaces include alert `numbers` in cache order, plus deduped `rules` and `rules_critical_high` for `code-scanning`, deduped `packages` for `dependabot`, and `types` for `secret-scanning`; secret values are stripped at fetch time and never cached or printed). Each repo also carries `history` from closed code-scanning alerts: `dismissed`/`fixed` counts in the `--window DAYS` window (default 90), `outrun` (dismissed > fixed and dismissed >= 2; the session line lists such repos), all-time `dismissed_by_rule`, and `prior_dismissals` (per open alert number, the dismissed alerts with the same rule: number, dates, reason, path, comment).
- `security-sweep --strict` — for scripts/cron: exit `1` on any critical/high code-scanning alert or any open secret-scanning alert; exit `2` on any `error` surface with no cached fallback, a skipped invalid repo token, an unreadable/unparseable repo source, or an internal error (exit `1` wins when both hold: an alert exit can hide fetch errors, which stderr still names per surface and `--json` marks `error`; outside `--strict`, internal errors exit `1`); else `0`. Add `--no-cache` to bypass the 5-minute cache.

## 2. Dispositions (every open alert gets one)

**Before any dismissal ask, look up prior dismissals:** `security-sweep --json --no-cache -R owner/name` and read the repo's `history.prior_dismissals["<alert number>"]`. Every ask about a code-scanning alert quotes that lookup (the matching alerts, or "no prior dismissal of this rule").

1. **Fix now** — handle through the normal unit flow (remediate, test, verify the alert closes).
2. **Dismiss with evidence** — dismissal is a security-dimension decision, so it is the owner's call: present the alert, the concrete evidence (e.g., unreachable path, test-only fixture, false positive), the prior-dismissal lookup and a recommendation. Never dismiss an alert unasked, except a moved copy (below).
3. **Accept with reason** — record the accepted risk and reason in the project's tracking surface in the same session (core rules § *Everything not done gets a disposition when you decide*). Its dismissal uses reason `won't fix`, never `false positive`.

**Moved copy (owner ruling: dismiss without asking, cite and log).** An open code-scanning alert is a moved copy only when every check holds; any check that fails or cannot be verified makes it new, and new goes to the owner:
- a `prior_dismissals` entry has the same rule, is still dismissed, and its `fixed_at` is set (its code is gone from the default branch);
- git history shows the flagged lines moved or renamed from that entry's path to the new one in one change, not copied to an additional call site;
- the sink expression is the same and the alert's flow has no source the original's lacked.

Dependabot and secret-scanning alerts are never moved copies. To dismiss one, update the alert through the code-scanning API (`PATCH repos/<owner>/<name>/code-scanning/alerts/<n>`) with `state` `dismissed`, the original's `dismissed_reason`, and a `dismissed_comment` (at most 280 characters) that starts `Moved copy of #<original> (dismissed <YYYY-MM-DD>)`. In the same session, append one line to the project's tracking-surface entry titled `Security dismissal log` (create it on first use): date, repo, new and original alert numbers, rule, old → new path. §3 still applies: a critical/high moved copy is reported like any other.

**Second dismissal of a rule → structural fix.** When a dismissal (asked or moved copy) brings the rule's `dismissed_by_rule` count to 2 or more, file a task in the tracking surface in the same session for the structural fix (or add the alert to that rule's open task), in this order of preference:
- test-only or fixture paths: exclude them with `paths-ignore` or `query-filters` in a CodeQL config file. That needs advanced setup: `gh api repos/<owner>/<name>/code-scanning/default-setup --jq .state` prints `configured` under default setup, which takes no config file, so switching is the owner's call. The switch turns default setup off before the advanced workflow's first push (the two cannot run together), and where a workflow merges PRs with `GITHUB_TOKEN` (whose events trigger no workflow runs), the CodeQL workflow takes a `workflow_dispatch` trigger and the merging workflow dispatches it after each merge;
- a sink that is safe by design: route it through a sanitizer or guard CodeQL recognizes, or add a models-as-data extension;
- otherwise an accepted risk recorded per item 3.

## 3. Escalation and special cases

- **Critical/high or secret-scanning alerts:** any open critical/high alert or ANY open `secret-scanning` alert reports to the owner like a production finding through the formal channel alongside the prose report (core rules § *Talking to the owner*).
- **Secret-scanning alerts:** **rotate the secret first**, then clean git history only with the owner. Never print or echo the secret value.
- **`off` surfaces:** when a surface reports `off` (`Code scanning is not enabled`, `no analysis found`, `Advanced Security must be enabled`, `Secret scanning is disabled`, `Dependabot alerts are disabled` or `Dependabot alerts are not available for archived repositories`), mention it once; enabling scanning is the owner's call.

## 4. SessionStart opt-in wiring

- Set `SYG_SECURITY_SWEEP=1` (cwd repo) or `SYG_SECURITY_SWEEP_REPOS="owner/a owner/b"` in `.claude/settings.json` under `env` to run `security-sweep --session-line --cap 2` on `startup` and `clear` (a built-in 2 s cap, no `timeout` binary needed; on timeout a background `--warm-cache` run is detached; silent when clean or on error).
- `SYG_DISABLE=security` switches the SessionStart sweep off (and headless `sdk-*` runs skip `security` automatically).
