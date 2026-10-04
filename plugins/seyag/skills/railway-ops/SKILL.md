---
name: railway-ops
description: 'Railway operations through the railway-ops CLI: explicit environment on every call, dry run by default, values never printed. Use when deploying, redeploying or restarting a Railway service, when setting, deleting, listing or rotating Railway env vars or secrets, when reading Railway logs, or when a Railway token or auth call fails.'
---

# Railway ops

`railway-ops` (on PATH from this plugin) wraps Railway's public GraphQL API and the `railway` CLI's read paths. Every write is a dry run until `--yes`. No verb prints a variable value. `railway-ops --help` is the full reference.

## 1. Token model

- Railway mints **project-scoped tokens per environment**. One token cannot reach both dev and prod, and there is no fallback between them.
- Send it as the `Project-Access-Token` header. `Authorization: Bearer` is for account tokens: a project token sent that way comes back HTTP 200 with a GraphQL "Not Authorized".
- The token lives in a local env var named by the config (default `RAILWAY_PROJECT_TOKEN_<ENV>`). Never set it on a Railway service and never commit it.
- Never name it `RAILWAY_TOKEN` or `RAILWAY_API_TOKEN`. Those are the CLI's own login variables, and pointing them at a project token breaks `railway status`, which id resolution depends on. The config loader refuses both names.

## 2. Traps (each with its fix)

- **`railway redeploy` acts on the LINKED environment** and has no `--environment` flag, so the same keystrokes can bounce prod. Fix: `railway-ops redeploy <env> <service>` (GraphQL with resolved ids).
- **The CLI cannot delete variables or manage shared ones.** Fix: `railway-ops vars delete`, and `vars set --shared`.
- **Every variable write triggers implicit deploys.** Fix: `vars set` and `rotate-secret` upsert with `skipDeploys: true`; then redeploy explicitly, in the order you choose.
- **Deploy rate limit** ("Service deployment rate limit exceeded") on bulk writes. Fix: skipDeploys plus one redeploy per service; on a hit, wait a few minutes.
- **`logs --lines` above ~5000 returns ZERO rows**, which looks exactly like "no matching logs". `railway-ops logs` refuses anything over 5000. To reach further back, go by deployment id.
- **Level greps are false-clean.** Railway renders every stdout line as `[INFO]`, whatever the app's level. Grep message text (`failed|error:|err=`), never the level.
- **The `--filter` DSL misses hyphenated tokens** (UUIDs) and quoted phrases. Fix: pull a window and grep locally (`--grep`, a Python regex). railway-ops never passes `--filter`.
- **Past deployments stay readable by id.** A REMOVED deployment still has its logs. Fix: `--deployment <id>`, with the id taken from the dashboard's deployment list. An empty result means debug the query, not "logs rolled off".
- **Override blindness.** A service list can't tell an inherited shared value from an override, so rotate-secret redeploys an overriding service, which keeps its own value.

## 3. Safe sequences

Read the dry-run plan first, every time. On a protected env, `--yes` alone is refused and needs `--confirm-protected <env>` too. A human reads the plan before that flag is typed.

**Set:**
```bash
railway-ops vars set dev --shared NEWKEY --from-env SRC_VALUE          # plan only
railway-ops vars set dev --shared NEWKEY --from-env SRC_VALUE --yes    # upsert, skipDeploys
railway-ops redeploy dev api --yes                                     # each service it printed
```
The value comes from an env var or `--from-stdin`, never argv. argv shows up in the process table and in shell history.

**Delete:**
```bash
railway-ops vars delete dev --service api OLD_KEY
railway-ops vars delete dev --service api OLD_KEY --yes
```
`VariableDelete` has no skipDeploys, so a delete may trigger deploys of the affected services: the one write here that can.

**Restart:**
```bash
railway-ops redeploy dev api --yes
railway-ops redeploy prod api --yes --confirm-protected prod
```

**Rotate** (an existing shared variable only; it never creates one):
```bash
railway-ops rotate-secret dev ROT_KEY          # plan: the services that carry the name
railway-ops rotate-secret dev ROT_KEY --yes    # generate, upsert shared, redeploy each
```
It refuses when no service carries the name. If a redeploy fails, the output names what succeeded. **Do not re-run it**: that mints a third value and widens the split; redeploy the lagging services with `railway-ops redeploy`. A verifier that accepts one value at a time still has a mismatch window during the redeploys; dual-accept staging is project-specific.

## 4. Which verb

| Need | Verb |
|---|---|
| ids for a dashboard or API call | `ids <env> [--service S]` |
| which variables exist at a scope | `vars list <env> --service S` or `--shared` |
| set one value | `vars set` (then `redeploy`) |
| remove one variable | `vars delete` |
| restart a service | `redeploy <env> <service>` |
| rotate a shared secret | `rotate-secret <env> NAME` |
| incident dig | `logs <env> [<service>] --lines N --grep RE [--deployment ID]` |

`logs` with no service sweeps the config's `services`; any failed window makes the exit non-zero.

## 5. Setting up a project

Commit a `.railway-ops.json` at the repo root. It holds no secrets: only names. railway-ops searches for it upward from the cwd to the git root, or takes `--config FILE`.

```json
{
  "envs": {"dev": "development", "prod": "production"},
  "protected": ["prod"],
  "token_env": {"dev": "MYAPP_RAILWAY_TOKEN_DEV", "prod": "MYAPP_RAILWAY_TOKEN_PROD"},
  "services": ["api", "worker"]
}
```

- `envs` maps a short name to the Railway environment name and is required. `protected` defaults to `["prod"]`; each entry must be an `envs` key, and any alias with the same Railway name is protected too. **`"protected": []` unprotects every env.** `token_env` defaults to `RAILWAY_PROJECT_TOKEN_<SHORT>`, one distinct variable per env. `services` is the default list for `logs`. Unknown keys are refused: a typo could unprotect an env.
- Ids resolve by name from `railway status --json`, so link the checkout to the project once with the CLI. Mint one project token per environment (dashboard: Project Settings, Tokens) and export each under its configured name.
