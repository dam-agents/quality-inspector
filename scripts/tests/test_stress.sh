#!/usr/bin/env bash
# Stress module: the plan is GET-only, deduped, bounded and clamped to the hard caps; the
# guard refuses a non-local base; a tiny real run against a local stub server judges the
# api and health phases and compares p95 with a previous run (docs/stress.md).
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
seed_work

# ---------------------------------------------------------------- plan (offline)
jq -n '{build:"1.2.3",
  routes:{"/":{example:"/"},"/broken":{example:"/broken",error:"timeout"},"/away":{example:"/away",redirected:"http://sso.example"},
          "/projects/:id":{example:"/projects/42"},"/a":{example:"/a"},"/b":{example:"/b"},"/c":{example:"/c"},"/d":{example:"/d"}},
  api_requests:([{method:"POST",path_pattern:"/api/items",example_path:"/api/items"},
       {method:"GET",path_pattern:"/api/items/0",example_path:"/api/items/0?page=1"},
       {method:"GET",path_pattern:"/api/items/0",example_path:"/api/items/0?page=2"},
       {method:"GET",path_pattern:"/api/other",example_path:"/api/items/0?page=1"},
       {method:"DELETE",path_pattern:"/api/items/:id",example_path:"/api/items/3"}]
    + [range(1;40) | {method:"GET",path_pattern:"/api/items/\(.)",example_path:"/api/items/\(.)?page=1"}])}' > "$SANDBOX/inv.json"
p="$(node "$SCRIPTS/stress.mjs" --dry-run "$SANDBOX/inv.json" --base http://localhost:8080)"
assert "build from the map, base kept" '.build == "1.2.3" and .base == "http://localhost:8080"' "$p"
assert "defaults: 10 workers, 60 s, 5 pages, 20000 requests" '.config == {concurrency:10,duration_s:60,pages:5,requests_cap:20000,contexts:5}' "$p"
assert "GET only, never a write" '[.endpoints[].method] | unique == ["GET"]' "$p"
assert "writes are named in a note" '.notes | map(select(test("DELETE, POST"))) | length == 1' "$p"
assert "deduped by pattern and example, at most 30" '(.endpoints | length) == 30 and ([.endpoints[].target] | unique | length) == 30 and .endpoints[0].path == "/api/items/0?page=1" and .endpoints[1].target == "GET /api/items/1"' "$p"
assert "the cut to 30 is noted" '.notes | map(select(test("first 30"))) | length == 1' "$p"
assert "pages skip errored and redirected routes" '[.pages[].target] == ["/","/projects/:id","/a","/b","/c"]' "$p"
p="$(node "$SCRIPTS/stress.mjs" --dry-run "$SANDBOX/inv.json" --base http://127.0.0.1:8080 --concurrency 500 --duration 9999 --pages 2 --build c9)"
assert "flags above the caps are clamped" '.config.concurrency == 50 and .config.duration_s == 300 and .config.contexts == 5 and .build == "c9"' "$p"
assert "each clamp is noted" '(.notes | map(select(test("clamped"))) | length) == 2' "$p"
assert "--pages limits the pages" '[.pages[].target] == ["/","/projects/:id"]' "$p"
printf -- '- stress_max_concurrency: 3\n- stress_duration_s: 7\n' >> "$WORK_DIR/CONFIG.md"
p="$(node "$SCRIPTS/stress.mjs" --dry-run "$SANDBOX/inv.json" --base http://localhost:8080)"
assert "config keys are read" '.config.concurrency == 3 and .config.duration_s == 7 and .config.contexts == 3' "$p"
printf -- '- stress_max_concurrency: 80\n' > "$WORK_DIR/CONFIG.md"
assert "the config is clamped too" '.config.concurrency == 50 and (.notes | map(select(test("clamped"))) | length) == 1' \
  "$(node "$SCRIPTS/stress.mjs" --dry-run "$SANDBOX/inv.json" --base http://localhost:8080)"
node "$SCRIPTS/stress.mjs" --dry-run "$SANDBOX/inv.json" --base http://staging.example.com >/dev/null 2>&1
assert_eq "a non-local base is refused" 2 "$?"
echo '{"routes":{}}' > "$SANDBOX/nobuild.json"
node "$SCRIPTS/stress.mjs" --dry-run "$SANDBOX/nobuild.json" --base http://localhost:8080 >/dev/null 2>&1
assert_eq "no build anywhere is a usage error" 2 "$?"

# ---------------------------------------------------------------- a tiny real run
cat > "$SANDBOX/server.js" <<'JS'
const http = require('http'); let flaky = 0;
const s = http.createServer((q, r) => {
  if (q.url.startsWith('/api/flaky')) { r.statusCode = flaky++ % 3 === 0 ? 500 : 200; return r.end('{}'); }
  if (q.url.startsWith('/api/slow')) return setTimeout(() => r.end('{}'), 1200);
  r.end(q.url.startsWith('/api/') ? '{}' : '<html><body>ok</body></html>');
});
s.listen(0, '127.0.0.1', () => require('fs').writeFileSync(process.argv[2], String(s.address().port)));
JS
node "$SANDBOX/server.js" "$SANDBOX/port" & SRV=$!
trap 'kill $SRV 2>/dev/null; rm -rf "$SANDBOX"' EXIT
for _ in $(seq 50); do [ -s "$SANDBOX/port" ] && break; sleep 0.1; done
PORT="$(cat "$SANDBOX/port")"
cat > "$SANDBOX/live.json" <<'J'
{"build":"c1","routes":{"/":{"example":"/"}},
 "api_requests":[{"method":"GET","path_pattern":"/api/ok","example_path":"/api/ok"},
  {"method":"GET","path_pattern":"/api/flaky","example_path":"/api/flaky"},
  {"method":"GET","path_pattern":"/api/slow","example_path":"/api/slow"},
  {"method":"POST","path_pattern":"/api/ok","example_path":"/api/ok"}]}
J
# No Playwright where the test points (deterministic, whatever the container has).
o="$(QI_PLAYWRIGHT_FROM="$SANDBOX/no-pw/package.json" node "$SCRIPTS/stress.mjs" "$SANDBOX/live.json" --base "http://127.0.0.1:$PORT" \
      --skip-signin --duration 2 --concurrency 3 --out "$SANDBOX/s1")"
assert "summary printed" '.stress | test("s1/stress.json$")' "$o"
r="$(cat "$SANDBOX/s1/stress.json")"
c() { printf '[.checks[] | select(.id=="%s" and .target=="%s") | .status] == ["%s"]' "$1" "$2" "$3"; }
assert "flaky endpoint: error rate over 1%" "$(c STRESS-API-1 'GET /api/flaky' fail)" "$r"
assert "flaky endpoint: 5xx" "$(c STRESS-API-2 'GET /api/flaky' fail)" "$r"
for t in 'GET /api/ok' 'GET /api/slow'; do
  assert "$t: no errors" "$(c STRESS-API-1 "$t" pass)" "$r"
  assert "$t: no 5xx" "$(c STRESS-API-2 "$t" pass)" "$r"
done
assert "the product answers after the load" "$(c STRESS-HEALTH-1 / pass)" "$r"
assert "no previous -> p95 comparison skipped" '[.checks[] | select(.id=="STRESS-API-3") | .status] | unique == ["skipped"]' "$r"
assert "no Playwright -> ui skipped with the reason" '[.checks[] | select(.id | startswith("STRESS-UI-")) | .reason] == ["playwright unavailable","playwright unavailable"]' "$r"
assert "metrics per endpoint" '.metrics.api | (keys == ["GET /api/flaky","GET /api/ok","GET /api/slow"]) and (.["GET /api/slow"].p95 >= 1200) and (.["GET /api/flaky"].s5xx >= 1) and (.["GET /api/ok"].count > 0)' "$r"
assert "the run shape" '.build == "c1" and .config == {concurrency:3,duration_s:2,pages:5,requests_cap:20000} and (.counts | keys == ["critical","flaky","high","low","medium","passed","skipped"]) and .counts.high == 2 and .counts.critical == 0 and .counts.flaky == 0 and (has("confirms") | not)' "$r"
assert "no write was replayed" '.metrics.api | keys | map(select(startswith("POST"))) == []' "$r"
# The confirmation: the first run is kept, a check that failed there and passes now is flaky.
jq '(.checks[] | select(.id=="STRESS-API-1" and .target=="GET /api/ok")) |= (.status = "fail" | .reason = "error rate 5.0% > 1%")' \
  "$SANDBOX/s1/stress.json" > "$SANDBOX/s1/stress.first.json"
o="$(QI_PLAYWRIGHT_FROM="$SANDBOX/no-pw/package.json" node "$SCRIPTS/stress.mjs" "$SANDBOX/live.json" --base "http://127.0.0.1:$PORT" \
      --skip-signin --duration 2 --concurrency 3 --out "$SANDBOX/s1" --confirm "$SANDBOX/s1/stress.first.json")"
r="$(cat "$SANDBOX/s1/stress.json")"
assert "failed first, passes now -> flaky with both reasons" '[.checks[] | select(.id=="STRESS-API-1" and .target=="GET /api/ok") | [.status, (.reason | test("first run \\(error rate 5.0%"))]] == [["flaky",true]]' "$r"
assert "failed first, fails again -> still fail" "$(c STRESS-API-1 'GET /api/flaky' fail)" "$r"
assert "passed first -> not flaky" "$(c STRESS-API-1 'GET /api/slow' pass)" "$r"
assert "flaky counted apart, not a finding" '.counts.flaky == 1 and .counts.high == 2 and (.confirms | endswith("stress.first.json"))' "$r"
assert "the summary counts flaky" '.flaky == 1 and .failed == 2' "$o"
assert "the first run is kept" '[.checks[] | select(.status=="flaky")] == []' "$(cat "$SANDBOX/s1/stress.first.json")"
QI_PLAYWRIGHT_FROM="$SANDBOX/no-pw/package.json" node "$SCRIPTS/stress.mjs" "$SANDBOX/live.json" --base "http://127.0.0.1:$PORT" \
  --skip-signin --duration 1 --concurrency 3 --out "$SANDBOX/s1" --confirm "$SANDBOX/s1/stress.first.json" --pages 0 >/dev/null
assert "other settings than the first run -> a note" '.notes | map(select(test("other settings"))) | length == 1' "$(cat "$SANDBOX/s1/stress.json")"
jq '.build = "c0"' "$SANDBOX/s1/stress.first.json" > "$SANDBOX/other.json"
node "$SCRIPTS/stress.mjs" "$SANDBOX/live.json" --base "http://127.0.0.1:$PORT" --skip-signin --out "$SANDBOX/s4" --confirm "$SANDBOX/other.json" >/dev/null 2>&1
assert_eq "--confirm of another build is refused" 2 "$?"
node "$SCRIPTS/stress.mjs" "$SANDBOX/live.json" --base "http://127.0.0.1:$PORT" --skip-signin --out "$SANDBOX/s4" --confirm "$SANDBOX/missing.json" >/dev/null 2>&1
assert_eq "an unreadable --confirm is refused" 2 "$?"
[ ! -e "$SANDBOX/s4/stress.json" ] || { echo "  a refused --confirm must not write a result"; FAILED=1; }
echo '{"metrics":{"api":{"GET /api/ok":{"p95":5000},"GET /api/slow":{"p95":100}},"ui":{}}}' > "$SANDBOX/prev.json"
QI_PLAYWRIGHT_FROM="$SANDBOX/no-pw/package.json" node "$SCRIPTS/stress.mjs" "$SANDBOX/live.json" --base "http://127.0.0.1:$PORT" \
  --skip-signin --duration 2 --concurrency 3 --pages 0 --previous "$SANDBOX/prev.json" --out "$SANDBOX/s2" >/dev/null
r="$(cat "$SANDBOX/s2/stress.json")"
assert "slow endpoint: p95 > 2x and +1000 ms -> fail" "$(c STRESS-API-3 'GET /api/slow' fail)" "$r"
assert "ok endpoint: faster than before -> pass" "$(c STRESS-API-3 'GET /api/ok' pass)" "$r"
assert "not in the previous run -> skipped" "$(c STRESS-API-3 'GET /api/flaky' skipped)" "$r"
assert "--pages 0 -> ui skipped, no pages" '[.checks[] | select(.id | startswith("STRESS-UI-")) | .reason] == ["no pages","no pages"]' "$r"
o="$(QI_PLAYWRIGHT_FROM="$SANDBOX/no-pw/package.json" node "$SCRIPTS/stress.mjs" "$SANDBOX/live.json" --base "http://127.0.0.1:$PORT" \
      --duration 1 --out "$SANDBOX/s3" 2>/dev/null)"
assert_eq "no browser for the sign-in -> exit 3, the module failed" 3 "$?"
assert "the reason is printed" '.error | startswith("no browser: playwright unavailable")' "$o"
[ ! -e "$SANDBOX/s3/stress.json" ] || { echo "  a run without a browser must not write a result"; FAILED=1; }
# Exit 1 needs a running browser whose sign-in failed: wherever Playwright launches here.
if node -e "require('module').createRequire('$WORK_DIR/suite/package.json')('playwright-core')" 2>/dev/null; then
  node "$SCRIPTS/stress.mjs" "$SANDBOX/live.json" --base "http://127.0.0.1:$PORT" --duration 1 --out "$SANDBOX/s5" >/dev/null 2>&1
  rc=$?; [ "$rc" = 3 ] || assert_eq "no OWNER account in a running browser -> exit 1" 1 "$rc"
  [ ! -e "$SANDBOX/s5/stress.json" ] || { echo "  a failed sign-in must not write a result"; FAILED=1; }
fi
exit $FAILED
