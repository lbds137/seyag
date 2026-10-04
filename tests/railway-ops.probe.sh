#!/bin/bash
# Fixture check for plugins/seyag/bin/railway-ops. Hermetic: a mock GraphQL
# server (python http.server on 127.0.0.1, port 0) records every request body
# and auth header and answers from canned JSON keyed by operation name (and
# serviceId); a stub `railway` (RAILWAY_OPS_CLI) serves `status --json` from a
# fixture and records `logs` argv. Fake tokens exist only inside run(). The
# real railway CLI and the real API are never reached.
# Covers: ids resolution; names-only listing; vars set dry run (no request) vs
# --yes (variableUpsert, skipDeploys, Project-Access-Token); no value from
# argv; the protected-env rule; redeploy via the GQL mutation with resolved
# ids; rotate-secret (shared-tier upsert, redeploys only the services that
# carry the name, partial-failure guidance, value never printed); GraphQL
# errors shown except upsert text; the RAILWAY_TOKEN collision; logs cap and
# local grep; no fake token or fixture value in any output.
# Usage: tests/railway-ops.probe.sh

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RO="$REPO/plugins/seyag/bin/railway-ops"
[ -f "$RO" ] || { echo "railway-ops.probe: no railway-ops at $RO"; exit 2; }
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

T="$(mktemp -d)"
SRV_PID=""
cleanup() { [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
export NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost
mkdir -p "$T/proj/.git" "$T/proj/sub" "$T/bin"

# ---- mock GraphQL server ----
cat > "$T/mock.py" <<'PY'
import json, re, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
log, canned, portfile = sys.argv[1:4]
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
        try:
            body = json.loads(raw)
        except ValueError:
            body = {}
        m = re.search(r"(?:query|mutation)\s+(\w+)", body.get("query", ""))
        op = m.group(1) if m else "?"
        v = body.get("variables") or {}
        sid = v.get("serviceId") or (v.get("input") or {}).get("serviceId")
        with open(log, "a") as f:
            f.write(json.dumps({"op": op, "token": self.headers.get("Project-Access-Token"),
                                "auth": self.headers.get("Authorization"), "body": body}) + "\n")
        with open(canned) as f:
            c = json.load(f)
        try:
            with open(canned + ".over") as f:  # one '"KEY": JSON' per line, later lines win
                for line in f:
                    c.update(json.loads("{" + line + "}"))
        except FileNotFoundError:
            pass
        key = f"{op}:{sid or 'shared'}"
        resp = c.get(key) or c.get(op) or {"errors": [{"message": "mock: no canned response for " + key}]}
        if resp.get("_drop"):  # close the connection without any response
            self.close_connection = True
            return
        if resp.get("_redirect"):
            self.send_response(307)
            self.send_header("Location", resp["_redirect"])
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        out = json.dumps(resp).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)
    def log_message(self, *a):
        pass
srv = HTTPServer(("127.0.0.1", 0), H)
with open(portfile + ".tmp", "w") as f:
    f.write(str(srv.server_address[1]))
import os
os.rename(portfile + ".tmp", portfile)
srv.serve_forever()
PY
CANNED="$T/canned.json"; REQ="$T/req.log"
canned_default() {
cat > "$CANNED" <<'EOF'
{
  "Variables:shared": {"data": {"variables": {"ROT_KEY": "fixture-shared-aaa", "OTHER": "fixture-shared-bbb"}}},
  "Variables:svc-api": {"data": {"variables": {"ROT_KEY": "fixture-api-ccc", "PORT": "fixture-port-3000"}}},
  "Variables:svc-worker": {"data": {"variables": {"ROT_KEY": "fixture-worker-ddd"}}},
  "Variables:svc-web": {"data": {"variables": {"PORT": "fixture-port-8080"}}},
  "VariableUpsert": {"data": {"variableUpsert": true}},
  "VariableDelete": {"data": {"variableDelete": true}},
  "ServiceInstanceRedeploy": {"data": {"serviceInstanceRedeploy": true}}
}
EOF
}
canned_default
: > "$REQ"
python3 "$T/mock.py" "$REQ" "$CANNED" "$T/port" &
SRV_PID=$!
for _ in $(seq 1 50); do [ -s "$T/port" ] && break; sleep 0.1; done
[ -s "$T/port" ] || { echo "railway-ops.probe: mock server did not start"; exit 2; }
ENDPOINT="http://127.0.0.1:$(cat "$T/port")/graphql/v2"

# ---- stub railway CLI + fixtures ----
cat > "$T/status.json" <<'EOF'
{"id": "proj-1", "name": "demo", "workspace": {"id": "ws"}, "volumes": {"edges": []},
 "environments": {"edges": [{"node": {"id": "env-dev", "name": "development", "extra": 1}},
                            {"node": {"id": "env-prod", "name": "production"}}]},
 "services": {"edges": [{"node": {"id": "svc-api", "name": "api"}},
                        {"node": {"id": "svc-worker", "name": "worker"}},
                        {"node": {"id": "svc-web", "name": "web"}}]}}
EOF
printf '%s\n' '2026-10-04T10:00:00Z [INFO] boot ok' '2026-10-04T10:00:01Z [INFO] ERR-7 upstream failed' \
  '2026-10-04T10:00:02Z [INFO] request done' '2026-10-04T10:00:03Z [INFO] ERR-8 retry failed' > "$T/logs.txt"
cat > "$T/bin/railway" <<EOF
#!/bin/bash
case "\$1" in
  status) cat "$T/status.json" ;;
  logs) printf '%s\n' "\$*" >> "$T/cli-logs-args"; cat "$T/logs.txt" ;;
  redeploy) printf '%s\n' "\$*" >> "$T/cli-redeploy" ;;
  *) echo "stub: unexpected \$*" >&2; exit 9 ;;
esac
EOF
chmod +x "$T/bin/railway"
printf '%s\n' '{"envs": {"dev": "development", "prod": "production"}, "services": ["api", "worker"]}' > "$T/proj/.railway-ops.json"

ALL="$T/all"; : > "$ALL"
rc=0
# run [ARGS...]: from a subdir of the scratch project (config found upward), tokens set only here.
run() {
  (cd "$T/proj/sub" && RAILWAY_OPS_ENDPOINT="$ENDPOINT" RAILWAY_OPS_CLI="$T/bin/railway" \
    RAILWAY_PROJECT_TOKEN_DEV=fake-dev-token RAILWAY_PROJECT_TOKEN_PROD=fake-prod-token \
    SRC_VALUE=fixture-new-value-eee RAILWAY_OPS_ENDPOINT="${EP:-$ENDPOINT}" "$RO" "$@") >"$T/out" 2>"$T/err" <"${STDIN_FILE:-/dev/null}"
  rc=$?
  cat "$T/out" "$T/err" >> "$ALL"
}
# reqs EXPR...: one python spawn, one printed line per expression over the request log's rows.
reqs() { python3 - "$REQ" "$@" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
for e in sys.argv[2:]:
    print(eval(e))
PY
}
# over KEY JSON: overlay one canned response until the next reset (no python spawn).
over() { printf '"%s": %s\n' "$1" "$2" >> "$CANNED.over"; }
reset() { cat "$REQ" >> "$REQ.all"; : > "$REQ"; rm -f "$T/cli-logs-args" "$T/cli-redeploy" "$CANNED.over"; }

# 1. ids
reset; run ids dev --service api
[ $rc = 0 ] && grep -q "^project      demo  proj-1$" "$T/out" && grep -q "^environment  development  env-dev$" "$T/out" \
  && grep -q "^service      api  svc-api$" "$T/out" && [ ! -s "$REQ" ] \
  && ok "1 ids dev --service api resolves project, env and service ids by name from status --json (no API call)" \
  || bad "1 ids: rc=$rc $(cat "$T/out" "$T/err")"

# 2. vars list: names only
reset; run vars list dev --service api
[ $rc = 0 ] && [ "$(cat "$T/out")" = "$(printf 'PORT\nROT_KEY')" ] && ! grep -q "fixture-" "$T/out" "$T/err" \
  && [ "$(reqs '[r["body"]["variables"].get("serviceId") for r in rows]')" = "['svc-api']" ] \
  && ok "2 vars list prints sorted names only; no fixture value in the output" || bad "2 vars list: rc=$rc $(cat "$T/out" "$T/err")"
reset; run vars list dev
[ $rc = 2 ] && grep -q "exactly one of --service <name> or --shared" "$T/err" && [ ! -s "$REQ" ] \
  && ok "2b vars list with no scope is a usage error" || bad "2b no scope: rc=$rc $(cat "$T/err")"

# 3. vars set: dry run sends nothing; --yes sends variableUpsert with skipDeploys and the project-token header
reset; run vars set dev --shared NEWKEY --from-env SRC_VALUE
[ $rc = 0 ] && [ ! -s "$REQ" ] && grep -q "DRY RUN" "$T/out" \
  && ok "3a vars set without --yes sends no request (server log empty)" || bad "3a dry run: rc=$rc reqs=$(wc -l < "$REQ") $(cat "$T/err")"
reset; run vars set dev --shared NEWKEY --from-env SRC_VALUE --yes
[ $rc = 0 ] && [ "$(reqs '(lambda r, i: (r["op"], i.get("skipDeploys"), "serviceId" in i, r["token"] == "fake-dev-token", r["auth"], i["value"] == "fixture-new-value-eee"))(rows[0], rows[0]["body"]["variables"]["input"])')" = "('VariableUpsert', True, False, True, None, True)" ] \
  && ok "3b --yes sends variableUpsert (shared: no serviceId) with skipDeploys: true and Project-Access-Token: fake-dev-token, no Authorization" \
  || bad "3b upsert: rc=$rc $(cat "$T/err") ops=$(reqs '[(r["op"], r["token"] is not None, r["auth"] is not None) for r in rows]')"
grep -q "No service carries \"NEWKEY\" yet" "$T/out" && ok "3c after a shared set, the redeploy-needed list is derived (none carry NEWKEY)" || bad "3c redeploy list: $(cat "$T/out")"
reset; printf 'fixture-stdin-value-fff\n' > "$T/stdin"; STDIN_FILE="$T/stdin" run vars set dev --service api PORT --from-stdin --yes
[ $rc = 0 ] && [ "$(reqs '(rows[0]["body"]["variables"]["input"]["value"], rows[0]["body"]["variables"]["input"]["serviceId"])')" = "('fixture-stdin-value-fff', 'svc-api')" ] \
  && grep -q "railway-ops redeploy dev api --yes$" "$T/out" \
  && ok "3d --from-stdin (trailing newline stripped) to a service scope, then the redeploy command for that service" || bad "3d stdin: rc=$rc $(cat "$T/out" "$T/err")"

# 3e. vars delete: dry run sends nothing; --yes sends variableDelete at the named scope
reset; run vars delete dev --service api OLD_KEY
[ $rc = 0 ] && [ ! -s "$REQ" ] && grep -q "DRY RUN" "$T/out" && ok "3e vars delete without --yes sends no request" || bad "3e: rc=$rc $(cat "$T/err")"
reset; run vars delete dev --service api OLD_KEY --yes
[ $rc = 0 ] && [ "$(reqs '[(r["op"], r["body"]["variables"]["input"]) for r in rows]')" = "[('VariableDelete', {'projectId': 'proj-1', 'environmentId': 'env-dev', 'serviceId': 'svc-api', 'name': 'OLD_KEY'})]" ] \
  && ok "3f vars delete --yes sends variableDelete with the resolved project, env and service ids" || bad "3f: rc=$rc $(cat "$T/err")"

# 4. never a value from argv
reset; run vars set dev NEWKEY some-value --shared --yes
[ $rc = 2 ] && grep -q "never comes from argv" "$T/err" && [ ! -s "$REQ" ] \
  && ok "4 vars set dev NAME value is a usage error (exit 2, no request)" || bad "4 argv value: rc=$rc $(cat "$T/err")"

# 5. protected env
reset; run redeploy prod api --yes
[ $rc = 2 ] && grep -q "protected env" "$T/err" && [ ! -s "$REQ" ] \
  && ok "5a redeploy prod --yes alone is refused (exit 2, no request)" || bad "5a: rc=$rc reqs=$(wc -l < "$REQ") $(cat "$T/err")"
reset; run vars delete prod --shared OLD --yes
[ $rc = 2 ] && grep -q "protected env" "$T/err" && [ ! -s "$REQ" ] \
  && ok "5b vars delete prod --yes alone is refused too" || bad "5b: rc=$rc $(cat "$T/err")"
reset; run redeploy prod api --yes --confirm-protected dev
[ $rc = 2 ] && grep -q "does not match" "$T/err" && [ ! -s "$REQ" ] \
  && ok "5c --confirm-protected dev against prod is refused" || bad "5c: rc=$rc $(cat "$T/err")"
reset; run redeploy prod api --yes --confirm-protected prod
[ $rc = 0 ] && [ "$(reqs '[(r["op"], r["token"], r["body"]["variables"]) for r in rows]')" = "[('ServiceInstanceRedeploy', 'fake-prod-token', {'environmentId': 'env-prod', 'serviceId': 'svc-api'})]" ] \
  && ok "5d --yes --confirm-protected prod proceeds with the prod token and prod ids" || bad "5d: rc=$rc $(cat "$T/err") $(reqs '[r["op"] for r in rows]')"
reset; run redeploy prod api
[ $rc = 0 ] && [ ! -s "$REQ" ] && grep -q -- "--yes --confirm-protected prod to execute" "$T/out" \
  && ok "5e a protected dry run is allowed, sends nothing, and names the confirm flag" || bad "5e: rc=$rc $(cat "$T/out" "$T/err")"

# 6. redeploy: GraphQL mutation with resolved ids, never the CLI's linked env
reset; run redeploy dev api --yes
[ $rc = 0 ] && [ "$(reqs '[(r["op"], r["body"]["variables"]) for r in rows]')" = "[('ServiceInstanceRedeploy', {'environmentId': 'env-dev', 'serviceId': 'svc-api'})]" ] \
  && [ ! -e "$T/cli-redeploy" ] \
  && ok "6 redeploy dev api --yes sends serviceInstanceRedeploy with environmentId env-dev and serviceId svc-api; railway redeploy never runs" \
  || bad "6 redeploy: rc=$rc $(cat "$T/err") reqs=$(reqs '[(r["op"], r["body"].get("variables")) for r in rows]') cli=$(cat "$T/cli-redeploy" 2>/dev/null)"

# 7. rotate-secret
reset; run rotate-secret dev ROT_KEY
[ $rc = 0 ] && [ "$(reqs '[r["op"] for r in rows]')" = "['Variables', 'Variables', 'Variables', 'Variables']" ] && grep -q "Affected services (carry the name): api, worker$" "$T/out" \
  && ok "7a rotate-secret dry run reads names only (no mutation) and plans api, worker" || bad "7a: rc=$rc $(cat "$T/out" "$T/err")"
reset; run rotate-secret dev ROT_KEY --yes
{ read -r SEQ; read -r SKIP; read -r VAL; } < <(reqs '[(r["op"], r["body"]["variables"].get("serviceId") or r["body"]["variables"].get("input", {}).get("serviceId")) for r in rows]' \
  'rows[4]["body"]["variables"]["input"]["skipDeploys"]' 'rows[4]["body"]["variables"]["input"]["value"]' 2>/dev/null)
[ $rc = 0 ] && [ "$SEQ" = "[('Variables', None), ('Variables', 'svc-api'), ('Variables', 'svc-worker'), ('Variables', 'svc-web'), ('VariableUpsert', None), ('ServiceInstanceRedeploy', 'svc-api'), ('ServiceInstanceRedeploy', 'svc-worker')]" ] \
  && [ "$SKIP" = True ] \
  && ok "7b --yes: shared-tier upsert (no serviceId, skipDeploys), then redeploys only api and worker (web lacks the name)" || bad "7b: rc=$rc seq=$SEQ $(cat "$T/err")"
if [ ${#VAL} -ge 40 ]; then
  ok "7c (positive control: the generated value is in the mock's recorded body, ${#VAL} chars)"
  if grep -rqF -- "$VAL" "$ALL" "$T/out" "$T/err"; then bad "7c the generated value leaked into captured output"
  elif grep -rlF --exclude='req.log*' -- "$VAL" "$T" >/dev/null; then bad "7c the generated value appears in a file other than the request log: $(grep -rlF --exclude='req.log*' -- "$VAL" "$T")"
  else ok "7c the generated value appears in no output and no file other than the mock's request log"; fi
else bad "7c could not read the generated value from the request log (got ${#VAL} chars)"; fi
reset; over ServiceInstanceRedeploy:svc-worker '{"errors": [{"message": "deploy rate limit"}]}'
run rotate-secret dev ROT_KEY --yes
[ $rc = 1 ] && grep -q "Services redeployed: api$" "$T/out" && grep -q "worker: Railway API returned errors (status 200): deploy rate limit" "$T/err" \
  && grep -q "Do NOT re-run this command" "$T/err" && grep -q "THIRD value" "$T/err" \
  && ok "7d partial redeploy failure: exit 1, names what succeeded and the failure, do-NOT-re-run guidance" || bad "7d: rc=$rc $(cat "$T/out" "$T/err")"
reset; run rotate-secret dev MISSING --yes
[ $rc = 2 ] && grep -q "does not create one" "$T/err" && [ "$(reqs '[r["op"] for r in rows]')" = "['Variables']" ] \
  && ok "7e rotating a name that is not shared is refused before any mutation" || bad "7e: rc=$rc $(cat "$T/err")"
reset; run rotate-secret dev OTHER --yes
[ $rc = 2 ] && grep -q "No service in Railway development carries \"OTHER\"" "$T/err" && [ "$(reqs '"VariableUpsert" in [r["op"] for r in rows]')" = False ] \
  && ok "7f a shared name no service carries is refused, no upsert" || bad "7f: rc=$rc $(cat "$T/err")"

# 8. GraphQL errors: messages shown, except upsert text (can echo the value)
reset; over Variables:svc-api '{"errors": [{"message": "service is sleeping"}]}'
over VariableUpsert '{"errors": [{"message": "invalid value fixture-new-value-eee for NEWKEY"}]}'
run vars list dev --service api
[ $rc = 1 ] && grep -q "Railway API returned errors (status 200): service is sleeping" "$T/err" \
  && ok "8a GraphQL errors -> exit 1 with the message shown" || bad "8a: rc=$rc $(cat "$T/err")"
run vars set dev --shared NEWKEY --from-env SRC_VALUE --yes
[ $rc = 1 ] && grep -q "withheld" "$T/err" && ! grep -q -e "fixture-new-value-eee" -e "invalid value" "$T/out" "$T/err" \
  && ok "8b an upsert error message carrying the value is dropped (generic withheld message, exit 1)" || bad "8b: rc=$rc $(cat "$T/err")"

# 9. token_env collision with the CLI's own login variables
for v in RAILWAY_TOKEN RAILWAY_API_TOKEN; do
  printf '{"envs": {"dev": "development"}, "protected": [], "token_env": {"dev": "%s"}}\n' "$v" > "$T/bad.json"
  reset; run --config "$T/bad.json" ids dev
  [ $rc = 2 ] && grep -q "is $v, the railway CLI's own login variable" "$T/err" && grep -q "breaks \`railway status\`" "$T/err" \
    && ok "9 token_env = $v -> exit 2 with the explanation" || bad "9 $v: rc=$rc $(cat "$T/err")"
done
# the full config the skill shows: every key valid; a token_env name is honoured
cat > "$T/full.json" <<'EOF'
{
  "envs": {"dev": "development", "prod": "production"},
  "protected": ["prod"],
  "token_env": {"dev": "MYAPP_RAILWAY_TOKEN_DEV", "prod": "MYAPP_RAILWAY_TOKEN_PROD"},
  "services": ["api", "worker"]
}
EOF
reset; run --config "$T/full.json" ids dev
r1=$rc; run --config "$T/full.json" vars list dev --shared
[ $r1 = 0 ] && [ $rc = 2 ] && grep -q "MYAPP_RAILWAY_TOKEN_DEV is not set" "$T/err" && [ ! -s "$REQ" ] \
  && ok "9a the skill's full config parses, and its token_env name is the one required" || bad "9a: r1=$r1 rc=$rc $(cat "$T/err")"
printf '{"envs": {"dev": "development"}, "protect": ["dev"]}\n' > "$T/typo.json"
reset; run --config "$T/typo.json" ids dev
[ $rc = 2 ] && grep -q "unknown key(s) protect" "$T/err" && ok "9b an unknown config key (typo) is refused" || bad "9b: rc=$rc $(cat "$T/err")"
reset; (cd "$T/proj/sub" && RAILWAY_OPS_ENDPOINT="$ENDPOINT" RAILWAY_OPS_CLI="$T/bin/railway" "$RO" vars list dev --shared) >"$T/out" 2>"$T/err"; rc=$?; cat "$T/out" "$T/err" >> "$ALL"
[ $rc = 2 ] && grep -q "RAILWAY_PROJECT_TOKEN_DEV is not set" "$T/err" && [ ! -s "$REQ" ] \
  && ok "9c a missing token exits 2 naming the default variable, before any request" || bad "9c: rc=$rc $(cat "$T/err")"

# 10. logs: cap, explicit env/service, local grep
reset; run logs dev api --lines 6000
[ $rc = 2 ] && grep -q "ZERO rows" "$T/err" && [ ! -e "$T/cli-logs-args" ] \
  && ok "10a logs --lines 6000 is refused before the CLI runs" || bad "10a: rc=$rc $(cat "$T/err")"
reset; run logs dev api --lines 100 --grep 'ERR-[0-9]'
[ $rc = 0 ] && [ "$(cat "$T/cli-logs-args")" = "logs --environment development --service api --lines 100" ] \
  && [ "$(cat "$T/out")" = "$(printf '%s\n%s' '2026-10-04T10:00:01Z [INFO] ERR-7 upstream failed' '2026-10-04T10:00:03Z [INFO] ERR-8 retry failed')" ] \
  && ! grep -q -- "--filter" "$T/cli-logs-args" \
  && ok "10b logs --lines 100 --grep passes explicit --environment/--service, no --filter, filters locally (2 of 4)" || bad "10b: rc=$rc args=$(cat "$T/cli-logs-args" 2>/dev/null) $(cat "$T/out" "$T/err")"
reset; run logs dev --deployment dep-123
[ $rc = 0 ] && [ "$(cat "$T/cli-logs-args")" = "$(printf '%s\n%s' 'logs dep-123 --environment development --service api --lines 500' 'logs dep-123 --environment development --service worker --lines 500')" ] \
  && grep -q "^== worker ==$" "$T/out" \
  && ok "10c no service sweeps the config's services; --deployment goes first as the positional id" || bad "10c: rc=$rc $(cat "$T/cli-logs-args" 2>/dev/null) $(cat "$T/err")"

# 12. protection holes: stray protected entries, aliases, [] and shared token variables
cfg() { printf '%s\n' "$1" > "$T/c.json"; }
cfg '{"envs": {"prod": "production", "live": "production"}, "protected": ["prd"]}'
reset; run --config "$T/c.json" redeploy prod api --yes
[ $rc = 2 ] && grep -q '"protected" names prd, not a key in "envs"' "$T/err" && [ ! -s "$REQ" ] \
  && ok "12a a protected entry that is not an envs key is refused (exit 2, no request)" || bad "12a: rc=$rc $(cat "$T/err")"
cfg '{"envs": {"dev": "development", "prod": "production", "live": "production"}, "protected": ["prod"]}'
reset; run --config "$T/c.json" redeploy live api --yes
[ $rc = 2 ] && grep -q '"live" is a protected env' "$T/err" && grep -q -- "--yes --confirm-protected live once" "$T/err" && [ ! -s "$REQ" ] \
  && ok "12b an alias of a protected env's Railway name is protected too (--yes refused, names --confirm-protected live)" || bad "12b: rc=$rc $(cat "$T/err")"
cfg '{"envs": {"dev": "development", "prod": "production"}, "protected": []}'
reset; run --config "$T/c.json" redeploy prod api --yes
[ $rc = 0 ] && [ "$(reqs '[r["op"] for r in rows]')" = "['ServiceInstanceRedeploy']" ] \
  && "$RO" --help | grep -q '\[\] UNPROTECTS EVERY env' && grep -qF '`"protected": []` unprotects every env' "$REPO/plugins/seyag/skills/railway-ops/SKILL.md" \
  && ok "12c \"protected\": [] is allowed and unprotects everything, and --help and the skill both say so" || bad "12c: rc=$rc $(cat "$T/err")"
cfg '{"envs": {"dev": "development", "prod": "production"}, "token_env": {"dev": "SHARED_TOK", "prod": "SHARED_TOK"}}'
reset; run --config "$T/c.json" ids dev
r1=$rc; e1=$(cat "$T/err")
cfg '{"envs": {"dev": "development", "prod": "production"}, "token_env": {"dev": "RAILWAY_PROJECT_TOKEN_PROD"}}'
run --config "$T/c.json" ids dev
[ $r1 = 2 ] && [[ $e1 == *'both read their token from SHARED_TOK'* ]] && [ $rc = 2 ] && grep -q "both read their token from RAILWAY_PROJECT_TOKEN_PROD" "$T/err" \
  && ok "12d two envs naming one token variable are refused (explicitly, or against another env's default)" || bad "12d: r1=$r1 $e1 rc=$rc $(cat "$T/err")"
cfg '{"envs": {"dev": "development", "live": "production"}}'
reset; run --config "$T/c.json" ids dev
[ $rc = 2 ] && grep -q 'set "protected"' "$T/err" && ok "12e no prod key and no explicit protected is refused (the default would protect nothing)" || bad "12e: rc=$rc $(cat "$T/err")"

# 13. vars set and rotate-secret on prod with --yes alone
reset; run vars set prod --shared NEWKEY --from-env SRC_VALUE --yes
[ $rc = 2 ] && grep -q "protected env" "$T/err" && [ ! -s "$REQ" ] \
  && ok "13a vars set prod --yes without --confirm-protected: exit 2, empty request log" || bad "13a: rc=$rc reqs=$(wc -l < "$REQ") $(cat "$T/err")"
reset; run rotate-secret prod ROT_KEY --yes
[ $rc = 2 ] && grep -q "protected env" "$T/err" && [ ! -s "$REQ" ] \
  && ok "13b rotate-secret prod --yes without --confirm-protected: exit 2, empty request log" || bad "13b: rc=$rc reqs=$(wc -l < "$REQ") $(cat "$T/err")"

# 14. stdin that is not UTF-8
reset; printf '\xff\xfefixture-badutf8-ggg\n' > "$T/stdin-bad"; STDIN_FILE="$T/stdin-bad" run vars set dev --shared NEWKEY --from-stdin --yes
[ $rc = 2 ] && grep -q "stdin is not valid UTF-8" "$T/err" && ! grep -q -e Traceback -e badutf8 "$T/out" "$T/err" && [ ! -s "$REQ" ] \
  && ok "14 invalid UTF-8 on stdin: exit 2, fixed message, no traceback, no byte of the value" || bad "14: rc=$rc $(cat "$T/err")"

# 15. transport failures: dropped connection, redirect
reset; over Variables:svc-api '{"_drop": true}'
run vars list dev --service api
[ $rc = 1 ] && grep -q "Railway API connection failed" "$T/err" && ! grep -q Traceback "$T/err" \
  && ok "15a a dropped connection is exit 1 with a fixed message, no traceback" || bad "15a: rc=$rc $(cat "$T/err")"
reset; over ServiceInstanceRedeploy:svc-worker '{"_drop": true}'
run rotate-secret dev ROT_KEY --yes
[ $rc = 1 ] && grep -q "Services redeployed: api$" "$T/out" && grep -q "worker: Railway API connection failed" "$T/err" \
  && grep -q "Do NOT re-run this command" "$T/err" && ! grep -q Traceback "$T/err" \
  && ok "15b a connection dropped on a redeploy after a good upsert takes the partial-failure path (do NOT re-run)" || bad "15b: rc=$rc $(cat "$T/out" "$T/err")"
reset; over Variables:svc-api '{"_redirect": "http://127.0.0.1:9/elsewhere"}'
run vars list dev --service api
[ $rc = 1 ] && grep -q "redirect (HTTP 307); not followed" "$T/err" && [ "$(grep -c . "$REQ")" = 1 ] \
  && ok "15c a 3xx is not followed: exit 1, one request only, the token not re-sent" || bad "15c: rc=$rc reqs=$(grep -c . "$REQ") $(cat "$T/err")"

# 16. endpoint and --deployment hardening
n=0
# .invalid never resolves, so even a regressed guard cannot send the fake token anywhere real.
for ep in http://railway-ops-probe.invalid/graphql http://127.0.0.1.invalid/x ftp://127.0.0.1/x; do
  reset; EP="$ep" run vars list dev --shared
  [ $rc = 2 ] && grep -q "RAILWAY_OPS_ENDPOINT must be https" "$T/err" && [ ! -s "$REQ" ] && n=$((n + 1))
done
[ $n = 3 ] && ok "16a a non-https endpoint that is not loopback http is refused (3 of 3 shapes, exit 2)" || bad "16a: $n of 3 refused; last: $(cat "$T/err")"
reset; run logs dev api --deployment=-x
[ $rc = 2 ] && grep -q "not starting with '-'" "$T/err" && [ ! -e "$T/cli-logs-args" ] \
  && ok "16c a --deployment value starting with - is refused before the CLI runs" || bad "16c: rc=$rc $(cat "$T/err")"

# 17. no verb reports failure for a completed write; dry runs need no token; CLI launch failures are one line
reset; over Variables:svc-api '{"errors": [{"message": "service is sleeping"}]}'
run vars set dev --shared NEWKEY --from-env SRC_VALUE --yes
[ $rc = 0 ] && grep -q '^Set "NEWKEY" (shared (project-level)) in Railway development; no deploy was triggered\.$' "$T/out" \
  && grep -q 'Could not determine which services carry "NEWKEY" (listing variables for service "api" failed: .*service is sleeping' "$T/out" \
  && grep -q 'railway-ops vars list dev --service <S>, then redeploy the ones that carry it\.' "$T/out" \
  && ! grep -q Traceback "$T/err" \
  && [ "$(reqs '"VariableUpsert" in [r["op"] for r in rows]')" = True ] \
  && ok "17a shared vars set --yes whose post-write listing fails: exit 0, success line and Could-not-determine line printed, upsert in the request log" \
  || bad "17a: rc=$rc reqs=$(reqs '[r["op"] for r in rows]') $(cat "$T/out" "$T/err")"
# positive control: the same write with a working listing prints the none-carry line and not the fallback
reset; run vars set dev --shared NEWKEY --from-env SRC_VALUE --yes
[ $rc = 0 ] && ! grep -q "Could not determine" "$T/out" && grep -q 'No service carries "NEWKEY" yet' "$T/out" \
  && ok "17a2 (positive control: with a working listing the fallback line is absent)" || bad "17a2: rc=$rc $(cat "$T/out" "$T/err")"

# dry runs with the token variable unset: plan printed, NOT-set line, no GraphQL request
run_nt() {
  (cd "$T/proj/sub" && env -u RAILWAY_PROJECT_TOKEN_DEV -u RAILWAY_PROJECT_TOKEN_PROD \
    RAILWAY_OPS_ENDPOINT="$ENDPOINT" RAILWAY_OPS_CLI="$T/bin/railway" SRC_VALUE=fixture-new-value-eee "$RO" "$@") >"$T/out" 2>"$T/err" <"${STDIN_FILE:-/dev/null}"
  rc=$?
  cat "$T/out" "$T/err" >> "$ALL"
}
n=0
for verb in "vars set dev --shared NEWKEY --from-env SRC_VALUE" "vars delete dev --service api OLD_KEY" "redeploy dev api"; do
  reset; run_nt $verb
  [ $rc = 0 ] && grep -q "DRY RUN" "$T/out" && grep -q '^  Token: \$RAILWAY_PROJECT_TOKEN_DEV is NOT set (a --yes run needs it)$' "$T/out" \
    && [ ! -s "$REQ" ] && n=$((n + 1)) || echo "17b miss: $verb rc=$rc $(cat "$T/out" "$T/err")"
done
[ $n = 3 ] && ok "17b vars set / vars delete / redeploy dry runs with the token unset: exit 0, NOT-set line, empty request log (3 of 3)" || bad "17b: $n of 3"
reset; run_nt vars set dev --shared NEWKEY --from-env SRC_VALUE --yes
[ $rc = 2 ] && grep -q "RAILWAY_PROJECT_TOKEN_DEV is not set" "$T/err" && [ ! -s "$REQ" ] \
  && ok "17b2 (positive control: the same verb with --yes and no token is still refused, exit 2, no request)" || bad "17b2: rc=$rc $(cat "$T/err")"
n=0
for verb in "vars set dev --shared NEWKEY --from-env SRC_VALUE" "vars delete dev --service api OLD_KEY" "redeploy dev api"; do
  reset; run $verb
  [ $rc = 0 ] && grep -q '^  Token: \$RAILWAY_PROJECT_TOKEN_DEV is set$' "$T/out" && ! grep -q "NOT set" "$T/out" \
    && ! grep -qF fake-dev-token "$T/out" "$T/err" && [ ! -s "$REQ" ] && n=$((n + 1)) || echo "17c miss: $verb rc=$rc $(cat "$T/out" "$T/err")"
done
[ $n = 3 ] && ok "17c the same three dry runs with the token set print the is-set line and never the token value (3 of 3)" || bad "17c: $n of 3"
reset; run_nt rotate-secret dev ROT_KEY
[ $rc = 2 ] && grep -q "RAILWAY_PROJECT_TOKEN_DEV is not set" "$T/err" && [ ! -s "$REQ" ] \
  && ok "17d rotate-secret dry run with the token unset still refuses (exit 2, its plan reads the API)" || bad "17d: rc=$rc $(cat "$T/err")"

# an existing non-executable CLI path: one-line usage error, never a traceback
: > "$T/notexec"; chmod 644 "$T/notexec"
n=0
for verb in "ids dev" "logs dev api"; do
  reset
  (cd "$T/proj/sub" && RAILWAY_OPS_ENDPOINT="$ENDPOINT" RAILWAY_OPS_CLI="$T/notexec" RAILWAY_PROJECT_TOKEN_DEV=fake-dev-token "$RO" $verb) >"$T/out" 2>"$T/err"; rc=$?
  cat "$T/out" "$T/err" >> "$ALL"
  [ $rc = 2 ] && grep -q "could not run the railway CLI ($T/notexec): " "$T/err" && ! grep -q Traceback "$T/err" && n=$((n + 1)) || echo "17e miss: $verb rc=$rc $(cat "$T/err")"
done
[ $n = 2 ] && ok "17e RAILWAY_OPS_CLI at a non-executable file: ids and logs exit 2 with 'could not run the railway CLI', no traceback (2 of 2)" || bad "17e: $n of 2"
reset
(cd "$T/proj/sub" && RAILWAY_OPS_ENDPOINT="$ENDPOINT" RAILWAY_OPS_CLI="$T/no-such-cli" RAILWAY_PROJECT_TOKEN_DEV=fake-dev-token "$RO" ids dev) >"$T/out" 2>"$T/err"; rc=$?
[ $rc = 2 ] && grep -q "railway CLI not found" "$T/err" \
  && ok "17e2 (positive control: a missing CLI path keeps its own 'not found' message)" || bad "17e2: rc=$rc $(cat "$T/err")"

# 11. no secret in any captured output
if grep -qF -e fake-dev-token -e fake-prod-token "$ALL"; then bad "11 a fake token value appears in captured output"
else ok "11 no fake token value appears in any captured stdout/stderr"; fi
if grep -q "fixture-" "$ALL"; then bad "11b a fixture variable value appears in captured output: $(grep -m1 -o 'fixture-[a-z0-9-]*' "$ALL")"
else ok "11b no fixture variable value appears in any captured stdout/stderr"; fi
reset
grep -qF fake-dev-token "$REQ.all" && grep -qF fake-prod-token "$REQ.all" \
  && ok "11c (positive control: the mock received both fake tokens, so the absence above is meaningful)" || bad "11c positive control"

# help documents the seams
"$RO" --help > "$T/help" 2>&1; hrc=$?
[ $hrc = 0 ] && grep -q RAILWAY_OPS_ENDPOINT "$T/help" && grep -q RAILWAY_OPS_CLI "$T/help" \
  && ok "--help exits 0 and documents both test seams" || bad "--help: rc=$hrc"

kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""
echo "---"
[ "$fail" -eq 0 ] && echo "railway-ops: all checks passed" || echo "railway-ops: FAILURES above"
exit "$fail"
