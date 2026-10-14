#!/usr/bin/env bash
# scripts/catalog.mjs: items from criteria, tests, verdicts, nights, heals and flakes; test-related
# content only (no request text, requester, notes, explanations, lessons); escaped data; a stable
# hash and `changed` against the published one; collections; coverage pages.
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
seed_work
W="$WORK_DIR"
printf -- '- profile: stub\n- target_repo: acme/widgets\n- display_name: QA Bot\n' > "$W/CONFIG.md"
printf '| tests/issue-42.e2e.ts | 42 | regression | 9c1e44a0f2b3 | 2026-10-03T08:12:40Z |\n| tests/scenario-7.e2e.ts | S-7 | exploratory | 1a2b3c4d5e6f | - |\n' >> "$W/SUITE.md"
printf '| 42 | abc | c1 | b1 | partial | reported | 2026-10-02T14:03:11Z |\n' >> "$W/QA.md"
printf '| id | source | requester | thread | spec_hash | build | verdict | status | updated_utc |\n| --- | --- | --- | --- | --- | --- | --- | --- | --- |\n| S-7 | slack | U0SECRETUSER | C0SECRET/1728900000.000100 | s1 | c1 | passed | reported | 2026-10-04T10:03:11Z |\n' > "$W/SCENARIOS.md"
printf '| utc | test | ac | build | old_hash | new_hash | basis |\n| --- | --- | --- | --- | --- | --- | --- |\n| 2026-10-10T03:30:00Z | tests/issue-42.e2e.ts | AC-1 | c2 | aaa | bbb | ui-map |\n' > "$W/HEALS.md"
printf '| utc | test | ac | build | runs | passes |\n| --- | --- | --- | --- | --- | --- |\n| 2026-10-11T03:30:00Z | tests/issue-42.e2e.ts | AC-1 | c3 | 3 | 2 |\n' > "$W/FLAKY.md"
printf '# Catalog collections\n\n| collection | members |\n| --- | --- |\n| Upload | #42, S-7 AC-1 |\n' > "$W/CATALOG.md"
echo 'LESSON-SECRET: the registry is slow' > "$W/LESSONS.md"
printf '2026-10-10T03:00:00Z ran candidate=c2 unchanged=0 relearned=0 healed=1 needs_review=0 superseded=0 flaky=0 regression=0 blocked=0 drift=0\n2026-10-12T03:00:00Z ran candidate=c3 unchanged=1 relearned=0 healed=0 needs_review=0 superseded=0 flaky=0 regression=0 blocked=0 drift=0\n' > "$W/REGRESSION.log"
mkdir -p "$W/issues/42" "$W/scenarios/S-7" "$W/regression/c2" "$W/suite/tests" "$W/security/c1"
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
{"mode":"regression","candidate":"c2","acs":[{"issue":42,"id":"AC-1","verdict":"healed","explanation":"EXPLAIN-SECRET the tab moved"}]}
J
printf '# S-7 — upload a <i>large</i> file\n\n## AC-1 — the upload finishes\nGiven a 50 MB file\nWhen the owner uploads it\nThen it is listed\nsurface: ui\ntestable: yes\n' > "$W/scenarios/S-7/criteria-s1.md"
echo 'REQUEST-SECRET please test the upload, my boss asked' > "$W/scenarios/S-7/request.md"
echo '{"scenario":"S-7","candidate":"c1","generated_utc":"2026-10-04T10:00:00Z","acs":[{"id":"AC-1","verdict":"passed"}],"notes":["NOTE-SECRET"]}' > "$W/scenarios/S-7/verdicts-s1-c1.json"
echo '{"findings":[{"id":"SEC-SECRET"}]}' > "$W/security/c1/verdicts.json"
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
cat > "$W/suite/tests/scenario-7.e2e.ts" <<'T'
/** @qi-summary Big uploads finish. @qi-area files */
test('S-7 AC-1: the upload finishes', { session: 'owner', tags: ['scenario-7', 'ac-1'] },
  async ({ app, agent }) => { await app.open('/files'); await agent.act('upload a large file'); });
T
mkdir -p "$W/inventory/c3"
echo '{"routes":{"/":{"title":"Home","navigates":{"Projects":"/projects","Files":"/files"}},"/projects":{"title":"Projects","buttons":["Rename"]},"/files":{"title":"Files"}}}' > "$W/inventory/c3/inventory.json"
echo '[{"number":42,"title":"Rename <b>projects</b>","state":"closed","labels":[{"name":"area:projects"}]}]' > "$STUB_DIR/issues.json"

out="$(node "$SCRIPTS/catalog.mjs")"; rc=$?
assert_eq "catalog exits 0" 0 "$rc"
assert "summary" '.items == 4 and .changed == true and (.hash | test("^[0-9a-f]{12}$")) and (.thumbnails | test("none due|unavailable"))' "$out"
html="$(cat "$W/catalog/index.html")"
data="$(node -e 'const h=require("fs").readFileSync(process.argv[1],"utf8");const m=h.match(/<script type="application\/json" id="qi-catalog-data">([\s\S]*?)<\/script>/);process.stdout.write(m[1])' "$W/catalog/index.html")"
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
assert "nights and builds" '(.nights | length) == 2 and .nights[0].counts.healed == 1 and ([.builds[].id] | index("c3")) != null' "$data"
assert "collections" '.collections == [{"name":"Upload","members":["#42","S-7 AC-1"]}]' "$data"
assert "coverage pages" '[.pages[] | {pattern, covered, nav}] | (map(select(.pattern == "/projects"))[0] == {"pattern":"/projects","covered":"regression","nav":"Projects"})
  and (map(select(.pattern == "/files"))[0].covered == "exploratory")' "$data"
for secret in U0SECRETUSER C0SECRET REQUEST-SECRET NOTE-SECRET EXPLAIN-SECRET LESSON-SECRET SEC-SECRET; do
  case "$html" in (*"$secret"*) echo "  not test-related, must not be in the page: $secret"; FAILED=1;; esac
done
case "$html" in (*'<b>projects'*|*'<i>large'*) echo "  data not escaped inside the page"; FAILED=1;; esac

# Stable hash; `changed` follows the published hash.
h1="$(jq -r .hash <<<"$out")"; echo "$h1" > "$W/catalog/published.hash"
out2="$(node "$SCRIPTS/catalog.mjs")"
assert "same data, same hash, unchanged" '.hash == "'"$h1"'" and .changed == false' "$out2"
printf '| Smoke | #42 AC-1 |\n' >> "$W/CATALOG.md"
assert "a collection change changes the hash" '.changed == true' "$(node "$SCRIPTS/catalog.mjs")"
exit $FAILED
