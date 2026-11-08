---
name: security-sweep
description: "When `security-sweep` reports open GitHub security alerts (code scanning, dependabot, secret scanning) at session start or on request: give each alert a disposition — fix, dismiss with evidence (owner's call), or accept with reason — and report critical/high like a production finding. Use when the SessionStart security line appears, when asked about a repo's security alerts, or before a release."
---

# Security sweep (`seyag:security-sweep`)

`security-sweep` (on PATH from this plugin) queries open GitHub security alerts across `code-scanning`, `dependabot` and `secret-scanning`, which PR checks never show.

## 1. Running the tool

- `security-sweep` — inspects the cwd repo's `origin` remote (5-minute cache under `${XDG_STATE_HOME:-$HOME/.local/state}/seyag/security-sweep/`). The `origin` parser accepts only `github.com` (https/ssh); SSH host aliases and GHE hosts get `origin is not a github.com repo` — pass `-R owner/name` (or set `SYG_SECURITY_SWEEP_REPOS` for SessionStart) as the workaround.
- `security-sweep -R owner/name [-R ...]` or `--all-repos-from FILE` — inspects explicit repos (`#` comments in `FILE`; invalid `owner/name` tokens are skipped with a stderr warning while valid repos still run).
- `security-sweep --json` — machine-readable per-repo summary (`count` surfaces include alert `numbers` in cache order, plus deduped `rules` and `rules_critical_high` for `code-scanning`, deduped `packages` for `dependabot`, and `types` for `secret-scanning`; secret values are stripped at fetch time and never cached or printed).
- `security-sweep --strict` — for scripts/cron: exit `1` on any critical/high code-scanning alert or any open secret-scanning alert; exit `2` on any `error` surface with no cached fallback, a skipped invalid repo token, an unreadable/unparseable repo source, or an internal error (exit `1` wins when both hold: an alert exit can hide fetch errors, which stderr still names per surface and `--json` marks `error`; outside `--strict`, internal errors exit `1`); else `0`. Add `--no-cache` to bypass the 5-minute cache.

## 2. Dispositions (every open alert gets one)

1. **Fix now** — handle through the normal unit flow (remediate, test, verify the alert closes).
2. **Dismiss with evidence** — dismissal is a security-dimension decision, so it is the owner's call: present the alert, the concrete evidence (e.g., unreachable path, test-only fixture, false positive) and a recommendation. Never dismiss an alert unasked.
3. **Accept with reason** — record the accepted risk and reason in the project's tracking surface in the same session (core rules § *Everything not done gets a disposition when you decide*).

## 3. Escalation and special cases

- **Critical/high or secret-scanning alerts:** any open critical/high alert or ANY open `secret-scanning` alert reports to the owner like a production finding through the formal channel alongside the prose report (core rules § *Talking to the owner*).
- **Secret-scanning alerts:** **rotate the secret first**, then clean git history only with the owner. Never print or echo the secret value.
- **`off` surfaces:** when a surface reports `off` (`Code scanning is not enabled`, `no analysis found`, `Advanced Security must be enabled`, `Secret scanning is disabled`, `Dependabot alerts are disabled` or `Dependabot alerts are not available for archived repositories`), mention it once; enabling scanning is the owner's call.

## 4. SessionStart opt-in wiring

- Set `SYG_SECURITY_SWEEP=1` (cwd repo) or `SYG_SECURITY_SWEEP_REPOS="owner/a owner/b"` in `.claude/settings.json` under `env` to run `security-sweep --session-line --cap 2` on `startup` and `clear` (a built-in 2 s cap, no `timeout` binary needed; on timeout a background `--warm-cache` run is detached; silent when clean or on error).
- `SYG_DISABLE=security` switches the SessionStart sweep off (and headless `sdk-*` runs skip `security` automatically).
