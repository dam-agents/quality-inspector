#!/usr/bin/env bash
# coverage.mjs: a page counts as covered only through a regression-tier test that opens it or
# names a control only that page shows; nav items lead to pages; the audit reports counts,
# scenario tests included.
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
seed_work
mkdir -p "$WORK_DIR/inventory/0.0.0-main.bbb2222" "$WORK_DIR/suite/tests"
map="$WORK_DIR/inventory/0.0.0-main.bbb2222/inventory.json"
cat > "$map" <<'J'
{"build":"0.0.0-main.bbb2222","generated_utc":"2026-10-14T03:00:00Z","routes":{
 "/":{"title":"Home","headings":["Home"],"nav":["Projects","Settings","Reports"],"buttons":["Create project"],"tabs":[],"inputs":[],
      "links":["Projects → /projects","Settings → /settings"],"navigates":{"Reports":"/reports"}},
 "/projects":{"title":"Projects","headings":["Projects"],"nav":["Projects","Settings","Reports"],"buttons":["New project","Save"],"tabs":[],"inputs":[],
      "links":["Projects → /projects","Open → /projects/42"]},
 "/projects/:id":{"title":"Project","headings":[],"nav":[],"buttons":["Archive project"],"tabs":["Members"],"inputs":[],"links":["Projects → /projects"]},
 "/settings":{"title":"Settings","headings":["Settings"],"nav":[],"buttons":["Save"],"tabs":["API keys","Usage"],"inputs":[],"links":[]},
 "/reports":{"title":"Reports","headings":["Reports"],"nav":[],"buttons":[],"tabs":[],"inputs":["Period"],"links":[]}}}
J
cat > "$WORK_DIR/suite/tests/issue-1.e2e.ts" <<'T'
await app.open('/settings');
// later: the New project flow
await agent.act('press Save, then use "Archive project" on the first project');
// AC-1 begin
await expect(screen.getByRole('tab', { name: 'API keys' })).toBeVisible();
// AC-1 end
T
printf "await app.open('/reports');\n" > "$WORK_DIR/suite/tests/issue-2.e2e.ts"
cat >> "$WORK_DIR/SUITE.md" <<'R'
| tests/issue-1.e2e.ts | 1 | regression | 9c1e44a0f2b3 | 2026-10-01T00:00:00Z |
| tests/issue-2.e2e.ts | 2 | promotable | 51d0e2aa7c90 | - |
R
tests=("$WORK_DIR"/suite/tests/issue-*.e2e.ts)
c="$(node "$SCRIPTS/coverage.mjs" "$map" "$WORK_DIR/SUITE.md" "${tests[@]}")"
assert "opened by URL" '.pages[] | select(.pattern=="/settings") | .covered and .tests==[{"test":"tests/issue-1.e2e.ts","tier":"regression"}]' "$c"
assert "a quoted control only one page shows covers it" '.pages[] | select(.pattern=="/projects/:id") | .covered' "$c"
assert "a shared label (Save) and an unquoted mention cover nothing" '.pages[] | select(.pattern=="/projects") | .covered | not' "$c"
assert "a non-regression test is listed, not counted" '.pages[] | select(.pattern=="/reports") | (.covered | not) and .tests[0].tier=="promotable"' "$c"
assert "uncovered pages" '.uncovered == ["/","/projects","/reports"]' "$c"
assert "nav items without a golden path, via links and clicks" '.nav_without_golden_path == [{"item":"Projects","target":"/projects"},{"item":"Reports","target":"/reports"}]' "$c"
m="$(node "$SCRIPTS/coverage.mjs" "$map" "$WORK_DIR/SUITE.md" "${tests[@]}" --md)"
. "$SCRIPTS/lib/state.sh"
assert_eq "COVERAGE.md header is the seeded one" "$COVERAGE_HEADER" "$(printf '%s\n' "$m" | grep '^|' | head -1)"
assert_eq "one row per page" 5 "$(printf '%s\n' "$m" | grep -c '^| /')"
none="$(node "$SCRIPTS/coverage.mjs" "$map" "$WORK_DIR/SUITE.md" "$WORK_DIR/suite/tests/none-*.e2e.ts")"
assert "no tests yet: everything uncovered" '.uncovered | length == 5' "$none"

echo '[]' > "$STUB_DIR/issues.json"
a="$(HOME="$SANDBOX" bash "$SCRIPTS/preflight.sh" audit)"
assert "audit reports the counts as a warn" '.checks[] | select(.id=="coverage") | .status=="warn" and (.detail | test("pages 5 · covered 2 · uncovered 3 · nav items without a golden path 2"))' "$a"
assert "audit stats carry the counts" '.stats.coverage == {"pages":5,"covered":2,"uncovered":3,"nav_without_golden_path":2}' "$a"

# A promoted scenario test covers pages in the audit as it does in work/COVERAGE.md.
printf "await app.open('/reports');\n" > "$WORK_DIR/suite/tests/scenario-7.e2e.ts"
echo '| tests/scenario-7.e2e.ts | S-7 | regression | 1b2c3d4e5f60 | 2026-10-02T00:00:00Z |' >> "$WORK_DIR/SUITE.md"
a="$(HOME="$SANDBOX" bash "$SCRIPTS/preflight.sh" audit)"
assert "audit counts a regression-tier scenario test" '.stats.coverage == {"pages":5,"covered":3,"uncovered":2,"nav_without_golden_path":1}' "$a"
exit $FAILED
