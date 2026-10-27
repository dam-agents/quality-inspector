#!/usr/bin/env bash
# ui-diff.mjs + impact.mjs: a redesign is named precisely, an unchanged UI is silent, tests are mapped to it.
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
cat > "$SANDBOX/old.json" <<'J'
{"routes":{"/":{"headings":["Home"],"buttons":["Create agent","Update all"],"nav":[],"tabs":[],"inputs":[],"links":[]},
 "/settings":{"headings":["Settings"],"buttons":[],"nav":[],"tabs":["API keys","Usage"],"inputs":[],"links":[]},
 "/settings/usage":{"headings":["Usage"],"buttons":["Next month"],"nav":[],"tabs":["API keys","Usage"],"inputs":[],"links":[]},
 "/artifacts":{"headings":["Artifacts"],"buttons":[],"nav":[],"tabs":[],"inputs":[],"links":[]}}}
J
cat > "$SANDBOX/new.json" <<'J'
{"routes":{"/":{"headings":["Home"],"buttons":["Update all"],"nav":[],"tabs":[],"inputs":[],"links":[]},
 "/settings":{"headings":["Settings"],"buttons":[],"nav":[],"tabs":["Access tokens"],"inputs":[],"links":[]},
 "/artifacts":{"headings":["Artifacts"],"buttons":["Create agent"],"nav":[],"tabs":[],"inputs":[],"links":[]}}}
J
d="$(node "$SCRIPTS/ui-diff.mjs" "$SANDBOX/old.json" "$SANDBOX/new.json")"
assert "page removal" '.pages_removed == ["/settings/usage"]' "$d"
assert "same-place rename" '.renamed | length == 1 and .[0].from == "API keys" and .[0].to == "Access tokens" and .[0].basis == "same-place"' "$d"
assert "move" '.moved == [{"kind":"buttons","name":"Create agent","from":["/"],"to":["/artifacts"]}]' "$d"
assert "a tab that really went is still reported" '.removed == [{"kind":"tabs","name":"Usage","routes":["/settings","/settings/usage"]}] and .added == []' "$d"
assert "self diff is empty" '.unchanged == true' "$(node "$SCRIPTS/ui-diff.mjs" "$SANDBOX/old.json" "$SANDBOX/old.json")"
printf '%s' "$d" > "$SANDBOX/diff.json"
cat > "$SANDBOX/issue-1.e2e.ts" <<'T'
await app.open('/settings');
// AC-1 begin
await expect(screen.getByRole('tab', { name: 'API keys' })).toBeVisible();
// AC-1 end
T
printf "await app.open('/');\n" > "$SANDBOX/issue-2.e2e.ts"
i="$(node "$SCRIPTS/impact.mjs" "$SANDBOX/diff.json" "$SANDBOX/issue-1.e2e.ts" "$SANDBOX/issue-2.e2e.ts" "$SANDBOX/scenario-*.e2e.ts")"
assert "an unexpanded glob is skipped" '(.impacted | length) + (.clear | length) == 2' "$i"
assert "renamed tab hits the AC block" '.impacted[0].hits | map(select(.inAcBlock and (.change | test("Access tokens")))) | length == 1' "$i"
assert "untouched test is clear" '.clear | length == 1' "$i"

# Page signals: an old map without them is tolerated, and only what is new is reported.
assert "no signals in old-format maps" '.console_errors_new == [] and .failed_requests_new == [] and .slower_pages == []' "$d"
mkdir -p "$SANDBOX/m1" "$SANDBOX/m2"
cat > "$SANDBOX/m1/inventory.json" <<'J'
{"routes":{"/":{"headings":["Home"],"shot":"shots/root.png","console_errors":["TypeError: x is undefined"],
  "failed_requests":[{"method":"GET","path":"/api/health","status":404}],"timing":{"load_ms":800,"samples":1}},
 "/settings":{"headings":["Settings"],"shot":"shots/settings.png","console_errors":[],"failed_requests":[],"timing":{"load_ms":900,"samples":1}},
 "/usage":{"headings":["Usage"],"shot":"shots/usage.png","console_errors":[],"failed_requests":[],"timing":{"load_ms":300,"samples":1}}}}
J
cat > "$SANDBOX/m2/inventory.json" <<'J'
{"routes":{"/":{"headings":["Home"],"shot":"shots/root.png","console_errors":["TypeError: x is undefined"],
  "failed_requests":[{"method":"GET","path":"/api/health","status":404}],"timing":{"load_ms":1500,"samples":1}},
 "/settings":{"headings":["Settings"],"shot":"shots/settings.png","console_errors":["Error: <script>boom</script> N"],
  "failed_requests":[{"method":"POST","path":"/api/keys/:id","status":500}],"timing":{"load_ms":2950,"samples":1}},
 "/usage":{"headings":["Usage"],"shot":"shots/usage.png","console_errors":[],"failed_requests":[],"timing":{"load_ms":900,"samples":1}}}}
J
s="$(node "$SCRIPTS/ui-diff.mjs" "$SANDBOX/m1/inventory.json" "$SANDBOX/m2/inventory.json")"
assert "new console error on its page, the known one is not" '.console_errors_new == [{"route":"/settings","errors":["Error: <script>boom</script> N"],"shot":"'"$SANDBOX"'/m2/shots/settings.png"}]' "$s"
assert "new failed request" '.failed_requests_new | length == 1 and .[0].route == "/settings" and .[0].requests == [{"method":"POST","path":"/api/keys/:id","status":500}]' "$s"
assert "slower page needs factor and floor (/ under 2x, /usage under +1000 ms)" '.slower_pages == [{"route":"/settings","old_load_ms":900,"new_load_ms":2950,"factor":3.3}]' "$s"
assert "--perf-factor raises the bar" '.slower_pages == [] and .unchanged == true' "$(node "$SCRIPTS/ui-diff.mjs" --perf-factor 4 "$SANDBOX/m1/inventory.json" "$SANDBOX/m2/inventory.json")"
assert "identical maps: no signals" '.console_errors_new == [] and .failed_requests_new == [] and .slower_pages == []' "$(node "$SCRIPTS/ui-diff.mjs" "$SANDBOX/m2/inventory.json" "$SANDBOX/m2/inventory.json")"
assert "old map without signals vs a new one: none reported" '.console_errors_new == [] and .slower_pages == []' "$(node "$SCRIPTS/ui-diff.mjs" "$SANDBOX/old.json" "$SANDBOX/m2/inventory.json")"
# A failed request the profile declares expected is never new; a near miss (other status) still is.
mkdir -p "$SANDBOX/xp"
echo '{"expected_requests":[{"method":"POST","path":"/api/keys/:id","status":500,"why":"no key store in the QA install"}]}' > "$SANDBOX/xp/profile.json"
assert "expected request: not new" '.failed_requests_new == []' "$(QI_PROFILE_DIR="$SANDBOX/xp" node "$SCRIPTS/ui-diff.mjs" "$SANDBOX/m1/inventory.json" "$SANDBOX/m2/inventory.json")"
echo '{"expected_requests":[{"method":"POST","path":"/api/keys/:id","status":404,"why":"x"},{"method":"POST","path":"/api/keys/*","status":500,"why":"wildcards are not patterns"}]}' > "$SANDBOX/xp/profile.json"
assert "other status or a wildcard: still new" '.failed_requests_new | length == 1' "$(QI_PROFILE_DIR="$SANDBOX/xp" node "$SCRIPTS/ui-diff.mjs" "$SANDBOX/m1/inventory.json" "$SANDBOX/m2/inventory.json")"
m="$(node "$SCRIPTS/ui-diff.mjs" "$SANDBOX/m1/inventory.json" "$SANDBOX/m2/inventory.json" --md)"
case "$m" in *'**New console errors:**'*'`/settings`: Error: <script>boom</script> N'*'**New failed requests:**'*'POST /api/keys/:id → 500'*'**Slower pages**'*'900 ms → 2950 ms'*) ;; *) echo "  --md lacks the signals: $m"; FAILED=1;; esac
exit $FAILED
