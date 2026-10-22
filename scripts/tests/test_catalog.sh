#!/usr/bin/env bash
# scripts/catalog.mjs: items from criteria, tests, verdicts, nights, heals and flakes; the runs (nights,
# environment failures, issue and scenario runs) with their reports; the product map's hotspots; test-related
# content only (no request text, requester, notes, explanations, lessons); escaped data; a stable
# hash and `changed` against the published one; collections; coverage pages; drift nights; the
# image budget; the credential and token refusal; the verifier's CATALOG.md and test_catalog checks.
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
seed_work
W="$WORK_DIR"
printf -- '- profile: stub\n- target_repo: acme/widgets\n- display_name: QA Bot\n' > "$W/CONFIG.md"
printf '| tests/issue-42.e2e.ts | 42 | regression | 9c1e44a0f2b3 | 2026-10-03T08:12:40Z |\n| tests/scenario-7.e2e.ts | S-7 | exploratory | 1a2b3c4d5e6f | - |\n| tests/profile-sign-in.e2e.ts | P-sign-in | regression | 2b3c4d5e6f7a | 2026-10-05T03:00:00Z |\n' >> "$W/SUITE.md"
printf '| 42 | abc | c1 | b1 | partial | reported | 2026-10-02T14:03:11Z |\n' >> "$W/QA.md"
printf '| id | source | requester | thread | spec_hash | build | verdict | status | updated_utc |\n| --- | --- | --- | --- | --- | --- | --- | --- | --- |\n| S-7 | slack | U0SECRETUSER | C0SECRET/1728900000.000100 | s1 | c1 | passed | reported | 2026-10-04T10:03:11Z |\n| P-sign-in | profile | - | - | p1 | c1 | passed | reported | 2026-10-05T03:10:00Z |\n' > "$W/SCENARIOS.md"
printf '| utc | test | ac | build | old_hash | new_hash | basis |\n| --- | --- | --- | --- | --- | --- | --- |\n| 2026-10-10T03:30:00Z | tests/issue-42.e2e.ts | AC-1 | c2 | aaa | bbb | ui-map |\n' > "$W/HEALS.md"
printf '| utc | test | ac | build | runs | passes |\n| --- | --- | --- | --- | --- | --- |\n| 2026-10-11T03:30:00Z | tests/issue-42.e2e.ts | AC-1 | c3 | 3 | 2 |\n' > "$W/FLAKY.md"
printf '# Catalog collections\n\n| collection | members |\n| --- | --- |\n| Upload | #42, S-7 AC-1 |\n' > "$W/CATALOG.md"
echo 'LESSON-SECRET: the registry is slow' > "$W/LESSONS.md"
printf '2026-10-09T03:00:00Z ERROR: environment candidate=c2\n2026-10-10T03:00:00Z ran candidate=c2 unchanged=0 relearned=0 healed=1 needs_review=0 superseded=0 flaky=0 regression=0 blocked=0 drift=0\n2026-10-12T03:00:00Z ran candidate=c3 unchanged=1 relearned=0 healed=0 needs_review=0 superseded=0 flaky=0 regression=0 blocked=0 drift=0\n' > "$W/REGRESSION.log"
mkdir -p "$W/issues/42" "$W/scenarios/S-7" "$W/scenarios/P-sign-in" "$W/regression/c2" "$W/suite/tests" "$W/security/c1"
cat > "$W/issues/42/criteria-abc.md" <<'C'
# #42 — Rename <b>projects</b>
source: done-when        frozen_utc: 2026-10-02T13:40:02Z        ac_hash: abc

## AC-1 — a renamed project keeps its tasks
Given a project with one task
When the owner renames it
Then the project shows its new name with the task
surface: ui
testable: yes

## AC-2 — internal cache
Given nothing
When anything
Then the cache is warm
surface: api
testable: no — internal
C
cat > "$W/issues/42/explorations-abc.md" <<'C'
# #42 — explorations        frozen_utc: 2026-10-02T13:41:10Z        ac_hash: abc

## EX-1 (from AC-1, heuristic: roles-isolation)
Given a viewer
When the viewer opens the project
Expected renaming is not offered
surface: ui
requires: viewer
C
cat > "$W/issues/42/verdicts-abc-c1.json" <<'J'
{"issue":42,"title":"Rename <b>projects</b>","ac_hash":"abc","candidate":"c1","baseline":"b1","candidate_run":"cand","baseline_run":"base",
 "verdict":"partial","generated_utc":"2026-10-02T14:00:00Z",
 "acs":[{"id":"AC-1","name":"renamed","verdict":"verified"},{"id":"AC-2","name":"internal","testable":false,"verdict":"not-testable"}],
 "explorations":[{"id":"EX-1","verdict":"observation","note":"NOTE-SECRET"}],
 "notes":["NOTE-SECRET in the notes"]}
J
echo abc123 > "$W/issues/42/artifact.id"
cat > "$W/regression/c2/verdicts.json" <<'J'
{"mode":"regression","candidate":"c2","acs":[{"issue":42,"id":"AC-1","verdict":"healed","explanation":"EXPLAIN-SECRET the tab moved"}],
 "context":{"previous":"c1","issues":[{"number":40,"title":"Projects get tabs"}],"ui_diff":"- renamed tab \"Tasks\" → \"To-dos\" on /projects","signals":{"console_errors_new":["E1"],"slow_tests":[]}}}
J
printf '# S-7 — upload a <i>large</i> file\n\n## AC-1 — the upload finishes\nGiven a 50 MB file\nWhen the owner uploads it\nThen it is listed\nsurface: ui\ntestable: yes\n' > "$W/scenarios/S-7/criteria-s1.md"
echo 'REQUEST-SECRET please test the upload, my boss asked' > "$W/scenarios/S-7/request.md"
echo '{"scenario":"S-7","candidate":"c1","generated_utc":"2026-10-04T10:00:00Z","acs":[{"id":"AC-1","verdict":"passed"}],"notes":["NOTE-SECRET"]}' > "$W/scenarios/S-7/verdicts-s1-c1.json"
echo 'https://claude.ai/artifact/s7' > "$W/scenarios/S-7/artifact.id"
echo '{"candidate":"c1","counts":{"critical":0,"high":2,"medium":1},"findings":[{"id":"SEC-SECRET","explanation":"SEC-SECRET recipe"}]}' > "$W/security/c1/verdicts.json"
# The control center's sources: design findings with a crop, validation results, stress results.
mkdir -p "$W/design/crops" "$W/validation/c3" "$W/stress/c3"
echo '{"schema":"qi-design/v1","next_id":3,"findings":[{"id":"D-1","source":"sweep","check":"clipped-text","severity":"minor","suspect":false,"pattern":"/projects","viewport":"390x844","target":"“Rename” button","saw":"Text of “Rename” button is clipped","box":{"x":1,"y":2,"w":3,"h":4},"shot":"design/c3/shots/x.png","crop":"design/crops/D-1.jpg","first_seen":"c3","last_seen":"c3","status":"open","resolved_build":null},
 {"id":"D-2","source":"noticed","check":"noticed","severity":"minor","pattern":"/files","viewport":"-","saw":"An empty state says undefined","first_seen":"c2","last_seen":"c2","status":"dismissed"},{"id":"evil","saw":"x"}]}' > "$W/design/findings.json"
echo jpg > "$W/design/crops/D-1.jpg"
echo '{"build":"c3","run":"validation-c3","cases":[{"id":"VAL-1","page":"/projects","form":"New project","field":"Name","kind":"html","oracle":"refused-or-intact","result":"finding","severity":"major","message":"[value-intact] changed"},{"id":"VAL-2","page":"/projects","form":"New project","field":"Name","kind":"unicode","oracle":"refused-or-intact","result":"ok","severity":null,"message":null}]}' > "$W/validation/c3/results.json"
echo '{"build":"c3","config":{"concurrency":10,"duration_s":60},"counts":{"critical":0,"high":1},"checks":[{"id":"STRESS-API-2","target":"GET /api/projects","status":"fail","severity":"high","evidence":"3 of 900 answered 5xx"}]}' > "$W/stress/c3/stress.json"
cat > "$W/suite/tests/issue-42.e2e.ts" <<'T'
/** @qi-summary Renaming a project keeps its tasks.
 *  @qi-area projects */
import { test } from '@e2e-dev/web';
test('#42 AC-1: a renamed project keeps its tasks', { session: 'owner', tags: ['issue-42', 'ac-1'] },
  async ({ app, agent, screen }) => {
    await app.open('/projects');
    await agent.act('rename the project {name} to {name}-2', { params: { name } });
    await app.screenshot('AC-1: the renamed project');
    // AC-1 begin
    await criterion('AC-1', 'the project shows its new name', { agent, app }, async () => {
      await expect(screen.getByRole('heading', { name: `${name}-2` })).toBeVisible();
    });
    // AC-1 end
  });
test('#42 EX-1: a viewer cannot rename', { session: 'viewer', tags: ['issue-42-ex', 'ex-1', 'from-ac-1'] },
  async ({ app, agent, screen }) => {
    await app.open('/projects');
    // EX-1 begin
    await agent.assert('renaming is not offered');
    // EX-1 end
  });
T
printf '# P-sign-in — the owner signs in\n\n## AC-1 — the dashboard shows\nGiven the sign-in page\nWhen the owner signs in\nThen the dashboard shows\nsurface: ui\ntestable: yes\n' > "$W/scenarios/P-sign-in/criteria-p1.md"
echo 'SOURCE-SECRET verbatim text' > "$W/scenarios/P-sign-in/source-p1.md"
cat > "$W/suite/tests/profile-sign-in.e2e.ts" <<'T'
test('P-sign-in AC-1: the dashboard shows', { session: 'owner', tags: ['profile-sign-in', 'ac-1'] },
  async ({ app }) => { await app.open('/'); });
T
cat > "$W/suite/tests/scenario-7.e2e.ts" <<'T'
/** @qi-summary Big uploads finish. @qi-area files */
test('S-7 AC-1: the upload finishes', { session: 'owner', tags: ['scenario-7', 'ac-1'] },
  async ({ app, agent }) => { await app.open('/files'); await agent.act('upload a large file'); });
T
mkdir -p "$W/inventory/c3"
echo '{"routes":{"/":{"title":"Home","navigates":{"Projects":"/projects","Files":"/files"},"viewport":[1000,500],"boxes":[["nav","Projects",0,0,100,20],["headings","Welcome home",200,100,300,40]]},
 "/projects":{"title":"Projects","buttons":["Rename"],"viewport":[1000,500],"boxes":[["buttons","Rename",100,50,200,25]]},"/files":{"title":"Files"}}}' > "$W/inventory/c3/inventory.json"
echo '[{"number":42,"title":"Rename <b>projects</b>","state":"closed","labels":[{"name":"area:projects"}]}]' > "$STUB_DIR/issues.json"

mkdir -p "$W/catalog/thumbs"; echo old > "$W/catalog/thumbs/issue-99-ac-1.jpg"
out="$(node "$SCRIPTS/catalog.mjs")"; rc=$?
assert_eq "catalog exits 0" 0 "$rc"
assert "summary" '.items == 5 and .changed == true and (.hash | test("^[0-9a-f]{12}$")) and (.thumbnails | test("none due|unavailable")) and .notes == []' "$out"
[ -e "$W/catalog/thumbs/issue-99-ac-1.jpg" ] && { echo "  a thumbnail of a gone item was kept"; FAILED=1; }
html="$(cat "$W/catalog/index.html")"
page_data() { node -e 'const h=require("fs").readFileSync(process.argv[1],"utf8");const m=h.match(/<script type="application\/json" id="qi-catalog-data">([\s\S]*?)<\/script>/);process.stdout.write(m[1])' "$W/catalog/index.html"; }
data="$(page_data)"
assert "schema and header" '.schema == "qi-catalog/v1" and .agent.display_name == "QA Bot" and .target == "acme/widgets" and .issue_url == "https://github.com/acme/widgets/issues/{n}"' "$data"
i='.items[] | select(.key == "issue-42/AC-1")'
assert "AC-1 from criteria, test and SUITE" "$i"' | .tier == "regression" and .then == "the project shows its new name with the task" and .area == "projects"
  and .summary == "Renaming a project keeps its tasks." and .session == "owner" and .pages == ["/projects"] and .evidence == "platform://artifacts/abc123"
  and .origin.title == "Rename <b>projects</b>" and .origin.labels == ["area:projects"] and .origin.state == "closed"' "$data"
assert "AC-1 steps" "$i"' | [.steps[].kind] == ["open","act","shot","expect"] and (.steps[1].text | test("\\{name\\}-2"))' "$data"
assert "AC-1 history: issue verdict, healed night, implied unchanged night" "$i"' | [.history[] | .run + ":" + .value] == ["issue:verified","regression:healed","regression:unchanged"] and .verdict.build == "c3"' "$data"
assert "AC-1 heals and flakes" "$i"' | .heals == [{"utc":"2026-10-10T03:30:00Z","build":"c2","basis":"ui-map"}] and .flaky[0].passes == 2' "$data"
assert "AC-2 not testable" '.items[] | select(.key == "issue-42/AC-2") | .testable == false and .tier == "untracked" and .verdict.value == "not-testable"' "$data"
assert "EX-1 exploration" '.items[] | select(.key == "issue-42/EX-1") | .kind == "exploration" and .tier == "exploratory" and (.history | all(.run != "regression")) and .session == "viewer" and .then == "renaming is not offered" and .checks.agent_asserts == 1' "$data"
assert "scenario item" '.items[] | select(.key == "scenario-7/AC-1") | .origin == {"kind":"scenario","ref":"S-7","title":"upload a <i>large</i> file","source":"slack"} and .verdict.value == "passed"
  and .summary == "Big uploads finish." and .area == "files" and [.steps[].kind] == ["open","act"]' "$data"
assert "profile scenario item" '.items[] | select(.key == "profile-sign-in/AC-1") | .origin == {"kind":"scenario","ref":"P-sign-in","title":"the owner signs in","source":"profile"} and .tier == "regression" and .then == "the dashboard shows"' "$data"
assert "nights and builds" '(.nights | length) == 2 and .nights[0].counts.healed == 1 and ([.builds[].id] | index("c3")) != null' "$data"
assert "runs: newest first; nights, an environment failure, issue and scenario runs" '[.runs[] | .type + ":" + (.ref // "-") + ":" + .build + ":" + .verdict]
  == ["regression:-:c3:unchanged","regression:-:c2:healed","regression:-:c2:environment","scenario:S-7:c1:passed","issue:#42:c1:partial"]' "$data"
assert "a night: its entries, change context and signal counts, its report" '.runs[1] | .entries == [{"key":"issue-42/AC-1","value":"healed"}] and .previous == "c1"
  and .issues == [{"number":40,"title":"Projects get tabs"}] and (.ui_diff | test("To-dos")) and .signals == {"console_errors_new":1,"slow_tests":0} and .report == null and .counts.healed == 1' "$data"
assert "an issue run: its verdicts and report; a scenario run: its link" '(.runs[4] | .entries == [{"key":"issue-42/AC-1","value":"verified"},{"key":"issue-42/AC-2","value":"not-testable"},{"key":"issue-42/EX-1","value":"observation"}]
  and .report == "platform://artifacts/abc123" and .baseline == "b1") and .runs[3].report == "https://claude.ai/artifact/s7"
  and (.items[] | select(.key == "scenario-7/AC-1") | .evidence) == "https://claude.ai/artifact/s7"' "$data"
assert "hotspots: a page-only control names its tests; a nav item stands for its page" '(.pages[] | select(.pattern == "/projects") | .viewport == [1000,500]
  and .hotspots[0] == {"kind":"buttons","name":"Rename","box":[0.1,0.1,0.2,0.05],"items":["issue-42/AC-1","issue-42/EX-1"]})
  and (.pages[] | select(.pattern == "/") | .hotspots == [{"kind":"nav","name":"Projects","box":[0,0,0.1,0.04],"to":"/projects","items":["issue-42/AC-1","issue-42/EX-1"]},
    {"kind":"headings","name":"Welcome home","box":[0.2,0.2,0.3,0.08],"items":[]}]) and (.pages[] | select(.pattern == "/files") | .hotspots == [])' "$data"
assert "collections" '.collections == [{"name":"Upload","members":["#42","S-7 AC-1"]}]' "$data"
assert "control center: the modules' state" '(.modules.modules | length) == 11 and (.modules.modules[] | select(.id == "ui-sweep") | .state == "disabled") and .interactive == false and (.modules | has("generated_utc") | not)' "$data"
assert "design findings: register fields, a crop, nothing else" '(.design | length) == 2 and (.design[0] | .id == "D-1" and .saw == "Text of “Rename” button is clipped" and (.crop | test("^i[0-9]+$")) and (has("shot") | not) and (has("box") | not))
  and .design[1].status == "dismissed" and .design[1].crop == null' "$data"
assert "findings: validation and stress as they are, security only counted" '.findings.validation.cases[0].message == "[value-intact] changed" and .findings.stress.checks[0].id == "STRESS-API-2"
  and .findings.security == {"candidate":"c1","utc":null,"counts":{"critical":0,"high":2,"medium":1},"report":null}' "$data"
assert "areas for a focus" '.areas | index("projects") != null and index("files") != null' "$data"
assert "coverage pages" '[.pages[] | {pattern, covered, nav}] | (map(select(.pattern == "/projects"))[0] == {"pattern":"/projects","covered":"regression","nav":"Projects"})
  and (map(select(.pattern == "/files"))[0].covered == "exploratory")' "$data"
for secret in U0SECRETUSER C0SECRET REQUEST-SECRET SOURCE-SECRET NOTE-SECRET EXPLAIN-SECRET LESSON-SECRET SEC-SECRET; do
  case "$html" in (*"$secret"*) echo "  not test-related, must not be in the page: $secret"; FAILED=1;; esac
done
case "$html" in (*'<b>projects'*|*'<i>large'*) echo "  data not escaped inside the page"; FAILED=1;; esac

# Stable hash; `changed` follows the published hash.
h1="$(jq -r .hash <<<"$out")"; echo "$h1" > "$W/catalog/published.hash"
out2="$(node "$SCRIPTS/catalog.mjs")"
assert "same data, same hash, unchanged" '.hash == "'"$h1"'" and .changed == false' "$out2"
assert "a failed issues listing is a note, not a failure" '.notes | any(test("issue labels and state unavailable"))' "$(STUB_GH_FAIL=1 node "$SCRIPTS/catalog.mjs")"
printf '| Smoke | #42 AC-1 |\n' >> "$W/CATALOG.md"
assert "a collection change changes the hash" '.changed == true' "$(node "$SCRIPTS/catalog.mjs")"

# A drifted file is not run: the trailing nights that skipped a drift show `drift`, not `unchanged`.
printf '2026-10-13T03:00:00Z ran candidate=c4 unchanged=0 relearned=0 healed=0 needs_review=0 superseded=0 flaky=0 regression=0 blocked=0 drift=1\n' >> "$W/REGRESSION.log"
node "$SCRIPTS/catalog.mjs" >/dev/null; data="$(page_data)"
assert "a drifted test's skipped night is drift, its run nights stay" "$i"' | .drift == true and ([.history[] | select(.run == "regression") | .value] == ["healed","unchanged","drift"]) and .verdict.value == "drift"' "$data"

# Images within the budget, the regression tier first; the rest is dropped.
head -c 900 /dev/zero | tr '\0' 'x' > "$W/catalog/thumbs/issue-42-ac-1.jpg"; cp "$W/catalog/thumbs/issue-42-ac-1.jpg" "$W/catalog/thumbs/scenario-7-ac-1.jpg"
out="$(QI_CATALOG_IMG_BUDGET=2000 node "$SCRIPTS/catalog.mjs")"; data="$(page_data)"
assert "the regression still and a design crop fit, the other still is dropped" '.images == 2 and .dropped_images == 1' "$out"
assert "a design crop comes before the other tiers' stills" '.design[0].crop != null' "$data"
assert "the regression-tier still wins the budget" '(.items[] | select(.key == "issue-42/AC-1") | .still) != null and (.items[] | select(.key == "scenario-7/AC-1") | .still) == null' "$data"
assert "all fit in the default budget" '.images == 3 and .dropped_images == 0' "$(node "$SCRIPTS/catalog.mjs")"

# A credential value or a token in the data refuses the page; the last page stays.
cp "$W/catalog/index.html" "$SANDBOX/last.html"
mkdir -p "$W/env"; printf 'E2E_USER_OWNER_PASSWORD=s3cret-value\n' > "$W/env/credentials.env"
cp "$W/suite/tests/scenario-7.e2e.ts" "$SANDBOX/scenario-7.e2e.ts"
printf "test('S-7 AC-2: sign in', {}, async ({ agent }) => { await agent.act('type s3cret-value'); });\n" >> "$W/suite/tests/scenario-7.e2e.ts"
out="$(node "$SCRIPTS/catalog.mjs")"; rc=$?
assert_eq "a credential value refuses the page" 1 "$rc"
assert "refused, not changed" '(.refused | test("credential")) and .changed == false' "$out"
cmp -s "$W/catalog/index.html" "$SANDBOX/last.html" || { echo "  the refused page replaced the last one"; FAILED=1; }
cp "$SANDBOX/scenario-7.e2e.ts" "$W/suite/tests/scenario-7.e2e.ts"
printf "test('S-7 AC-2: token', {}, async ({ agent }) => { await agent.act('use ghp_%s'); });\n" "$(head -c 36 /dev/zero | tr '\0' 'a')" >> "$W/suite/tests/scenario-7.e2e.ts"
node "$SCRIPTS/catalog.mjs" >/dev/null; assert_eq "a token refuses the page" 1 "$?"
cp "$SANDBOX/scenario-7.e2e.ts" "$W/suite/tests/scenario-7.e2e.ts"
node "$SCRIPTS/catalog.mjs" >/dev/null; assert_eq "a clean source builds again" 0 "$?"

# The verifier: the CATALOG.md header and the test_catalog value.
v="$(HOME="$SANDBOX" bash "$SCRIPTS/verify-onboarding.sh" 2>/dev/null | grep ' catalog_collections ')"
case "$v" in (ok*) ;; (*) echo "  an intact CATALOG.md fails the verifier: $v"; FAILED=1;; esac
sed -i.bak 's/^| collection | members |$/| name | members |/' "$W/CATALOG.md" && rm -f "$W/CATALOG.md.bak"
v="$(HOME="$SANDBOX" bash "$SCRIPTS/verify-onboarding.sh" 2>/dev/null | grep ' catalog_collections ')"
case "$v" in (FAIL*) ;; (*) echo "  a changed CATALOG.md header passes the verifier: $v"; FAILED=1;; esac
printf -- '- test_catalog: maybe\n' >> "$W/CONFIG.md"
bash "$SCRIPTS/verify-onboarding.sh" --config 2>/dev/null | grep -q '^FAIL cfg:test_catalog ' \
  || { echo "  assertion failed: verify-onboarding --config fails test_catalog: maybe"; FAILED=1; }
exit $FAILED
