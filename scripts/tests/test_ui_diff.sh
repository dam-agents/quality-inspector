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
i="$(node "$SCRIPTS/impact.mjs" "$SANDBOX/diff.json" "$SANDBOX/issue-1.e2e.ts" "$SANDBOX/issue-2.e2e.ts")"
assert "renamed tab hits the AC block" '.impacted[0].hits | map(select(.inAcBlock and (.change | test("Access tokens")))) | length == 1' "$i"
assert "untouched test is clear" '.clear | length == 1' "$i"
exit $FAILED
