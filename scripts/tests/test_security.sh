#!/usr/bin/env bash
# Security run: the pre-flight is due once per candidate; the planner is offline and frozen;
# the report is severity-sorted, escaped, and never produces an issue comment.
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
seed_work
mkdir -p "$WORK_DIR/env"
printf 'E2E_USER_OWNER_USERNAME=qa\nE2E_USER_OWNER_PASSWORD=owner-secret-pw\nE2E_USER_OUTSIDER_USERNAME=out\nE2E_USER_OUTSIDER_PASSWORD=out-secret-pw\n' > "$WORK_DIR/env/credentials.env"
# `export`, quotes and an empty role, read as suite.sh roles reads them (lib/profile.sh).
printf 'export E2E_USER_MEMBER_USERNAME="mem"\nE2E_USER_MEMBER_PASSWORD='"'"'mem-secret-pw'"'"'\nE2E_USER_VIEWER_USERNAME=""\n' >> "$WORK_DIR/env/credentials.env"

# ---------------------------------------------------------------- pre-flight
out="$(bash "$SCRIPTS/preflight.sh" security)"
assert "never run -> due" '.mode=="security" and .nothing_to_do==false and .candidate=="0.0.0-main.bbb2222" and .previous_candidate==null' "$out"
assert "no map yet -> inventory null" '.inventory == null' "$out"
assert "role names only, the suite.sh roles reading" '.roles == ["member","outsider","owner"] and (tostring | test("secret-pw") | not)' "$out"
assert "stub profile has no deployment" '.deployment_checks == false' "$out"
mkdir -p "$WORK_DIR/inventory/0.0.0-main.bbb2222"
echo '{"routes":{}}' > "$WORK_DIR/inventory/0.0.0-main.bbb2222/inventory.json"
assert "a map without api_requests counts as missing" '.inventory == null' "$(bash "$SCRIPTS/preflight.sh" security)"
echo '{"routes":{},"api_requests":[]}' > "$WORK_DIR/inventory/0.0.0-main.bbb2222/inventory.json"
assert "the candidate's map is handed over" '.inventory | test("inventory/0.0.0-main.bbb2222/inventory.json$")' "$(bash "$SCRIPTS/preflight.sh" security)"
echo "2026-10-11T04:00:00Z ran candidate=0.0.0-main.aaa1111 critical=0 high=1 medium=0 low=2 info=0 skipped=3" >> "$WORK_DIR/SECURITY.log"
assert "previous candidate from the log" '.nothing_to_do==false and .previous_candidate=="0.0.0-main.aaa1111"' "$(bash "$SCRIPTS/preflight.sh" security)"
echo "2026-10-12T04:00:00Z ran candidate=0.0.0-main.bbb2222 critical=0 high=0 medium=0 low=0 info=0 skipped=3" >> "$WORK_DIR/SECURITY.log"
assert "same candidate -> idle" '.nothing_to_do==true' "$(bash "$SCRIPTS/preflight.sh" security)"
echo '{"candidate":"0.0.0-main.ccc3333","baseline":"0.2.19"}' > "$STUB_DIR/versions.json"
printf 'operator %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$WORK_DIR/env/LOCK"
assert "busy environment -> idle" '.nothing_to_do==true and (.logs | map(select(test("busy"))) | length == 1)' "$(bash "$SCRIPTS/preflight.sh" security)"
rm -f "$WORK_DIR/env/LOCK"
echo "- security_checks: disabled" >> "$WORK_DIR/CONFIG.md"
assert "disabled -> idle, says so" '.nothing_to_do==true and (.logs[0] | test("disabled"))' "$(bash "$SCRIPTS/preflight.sh" security)"
H="$SANDBOX/home"; mkdir -p "$H/scripts"; cp -R "$SCRIPTS/." "$H/scripts/"
HOME="$H" bash "$H/scripts/precheck.sh" security >/dev/null 2>&1; assert_eq "precheck declines when disabled" 1 "$?"

# ---------------------------------------------------------------- planner (offline)
cat > "$SANDBOX/inv.json" <<'J'
{"build":"1.2.3","routes":{
  "/":{"example":"/","headings":["Home"],"buttons":["New project"]},
  "/projects/:id":{"example":"/projects/42","headings":["Project"]},
  "/broken":{"example":"/broken","error":"timeout"}},
 "api_requests":[
  {"method":"GET","path_pattern":"/api/projects","example_path":"/api/projects"},
  {"method":"GET","path_pattern":"/api/projects/:id","example_path":"/api/projects/42?view=full"},
  {"method":"POST","path_pattern":"/api/projects","example_path":"/api/projects"},
  {"method":"DELETE","path_pattern":"/api/projects/:id","example_path":"/api/projects/42"}]}
J
p="$(node "$SCRIPTS/security-checks.mjs" --dry-run "$SANDBOX/inv.json")"
assert "base from the profile, build from the map" '.base == "http://localhost:8080" and .build == "1.2.3"' "$p"
assert "no secret in the plan" 'tostring | test("secret-pw") | not' "$p"
assert "one SEC-AUTH-1 per reachable page" '[.plan[] | select(.id=="SEC-AUTH-1") | .target] == ["/","/projects/:id"]' "$p"
assert "every non-DELETE request replayed anonymously" '[.plan[] | select(.id=="SEC-AUTHZ-1") | .target] == ["GET /api/projects","GET /api/projects/:id","POST /api/projects"]' "$p"
assert "DELETE is never replayed" '[.skipped[] | select(.target=="DELETE /api/projects/:id")] | length == 3' "$p"
assert "no VIEWER -> SEC-AUTHZ-2 skipped" '.skipped[] | select(.id=="SEC-AUTHZ-2") | .reason | test("VIEWER")' "$p"
assert "OUTSIDER replays only id paths" '[.plan[] | select(.id=="SEC-AUTHZ-3") | .target] == ["GET /api/projects/:id"]' "$p"
assert "LEAK-1 walks the GETs as owner" '[.plan[] | select(.id=="SEC-LEAK-1") | .as] == ["owner","owner"]' "$p"
assert "ERR-1 probes the API prefix and a malformed id" '[.plan[] | select(.id=="SEC-ERR-1") | .path] == ["/qa-sec-missing-page","/api/qa-sec-missing","/api/projects/%27%22%3C%00"]' "$p"
assert "brute force uses OUTSIDER, never OWNER" '.plan[] | select(.id=="SEC-BRUTE-1") | .as == "outsider" and (.target | test("^10 "))' "$p"
assert "no entity -> e2e checks skipped with the reason" '.e2e_checks == [] and ([.skipped[] | select(.id=="SEC-XSS-1") | .reason | test("security.entity")] == [true])' "$p"
assert "no k8s -> deployment checks skipped" '[.skipped[] | select(.id | startswith("SEC-DEP-"))] | length == 5' "$p"
assert "every catalogue id is planned or skipped" '([.plan[].id] + [.skipped[].id] | unique | length) == 23' "$p"
jq '. + {"engine":"helm-k3s","engine_config":{"namespace":"acme"},"security":{"entity":"project"}}' "$QI_PROFILE_DIR/profile.json" > "$SANDBOX/p.json" && mv "$SANDBOX/p.json" "$QI_PROFILE_DIR/profile.json"
printf -- '- security_failed_logins: 6\n' >> "$WORK_DIR/CONFIG.md"
p="$(node "$SCRIPTS/security-checks.mjs" --dry-run "$SANDBOX/inv.json")"
assert "entity -> XSS and input tests, no helper -> XSS-2 skipped" '.e2e_checks == ["SEC-XSS-1","SEC-INPUT-1"] and (.skipped[] | select(.id=="SEC-XSS-2") | .reason | test("security-api"))' "$p"
assert "helm-k3s -> deployment planned in its namespace" '[.plan[] | select(.id | startswith("SEC-DEP-")) | .target] | unique == ["namespace acme"]' "$p"
assert "failed logins from the config" '.failed_logins == 6' "$p"
node "$SCRIPTS/security-checks.mjs" --dry-run "$SANDBOX/inv.json" --base http://staging.example.com >/dev/null 2>&1
assert_eq "a non-local base is refused" 2 "$?"

# ---------------------------------------------------------------- report
cat > "$SANDBOX/sv.json" <<'J'
{"mode":"security","candidate":"c1","generated_utc":"2026-10-14T04:30:00Z","candidate_run":"none",
 "counts":{"critical":1,"high":0,"medium":0,"low":1,"info":0,"skipped":1},
 "findings":[
  {"id":"SEC-HDR-2","target":"/","status":"fail","severity":"low","evidence":{"missing":["GET /"]},"explanation":"no nosniff"},
  {"id":"SEC-AUTHZ-2","target":"*","status":"skipped","severity":"medium","evidence":{},"explanation":"no VIEWER account"},
  {"id":"SEC-XSS-1","target":"project name","status":"fail","severity":"critical","evidence":{"request":"<script>alert(1)</script>"},"explanation":"the payload <b>ran</b>","tag":"sec-xss-1"}]}
J
o="$(QI_RUNS_ROOT="$SANDBOX/none" node "$SCRIPTS/render-report.mjs" "$SANDBOX/sv.json" "$SANDBOX/sout")"
assert "security page rendered" '.findings == 3 and .failed == 2' "$o"
h="$(cat "$SANDBOX/sout/index.html")"
case "$h" in *SEC-XSS-1*SEC-HDR-2*SEC-AUTHZ-2*) ;; *) echo "  not severity-sorted (critical, low, then skipped)"; FAILED=1;; esac
case "$h" in *'<script>alert'*|*'<b>ran'*) echo "  evidence or explanation not escaped"; FAILED=1;; esac
case "$h" in *'&lt;script&gt;alert(1)&lt;/script&gt;'*) ;; *) echo "  escaped evidence missing"; FAILED=1;; esac
[ ! -e "$SANDBOX/sout/comment.md" ] || { echo "  a security report must never produce an issue comment"; FAILED=1; }
exit $FAILED
