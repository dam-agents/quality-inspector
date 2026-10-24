#!/usr/bin/env bash
# scripts/issue-draft.mjs and scripts/rerun.mjs: a found issue's draft from a failed test (its
# criterion, its steps, the run's error, screenshots and video), a design finding (its crop and
# shot), a validation case and a stress check — one section each in one issue, the marker naming
# every problem, EVIDENCE_LINK where the evidence page goes, a "Done when"; never a verdict's notes
# or a run's credentials. And a run by hand recorded with each criterion's raw result.
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
seed_work
W="$WORK_DIR"; R="$W/suite/.e2e/runs"
printf -- '- profile: stub\n- target_repo: acme/widgets\n' > "$W/CONFIG.md"
printf '| 42 | abc | c3 | b1 | failed | reported | 2026-10-12T14:03:11Z |\n' >> "$W/QA.md"
mkdir -p "$W/issues/42" "$W/suite/tests" "$R/issue-42-candidate/artifacts/a1"
cat > "$W/issues/42/criteria-abc.md" <<'C'
# #42 — Rename projects
source: done-when        frozen_utc: 2026-10-02T13:40:02Z        ac_hash: abc

## AC-1 — a renamed project keeps its tasks
Given a project with one task
When the owner renames it
Then the project shows its new name with the task
surface: ui
testable: yes
C
echo '{"issue":42,"title":"Rename projects","candidate":"c2","baseline":"b1","candidate_run":"issue-42-old","verdict":"verified","generated_utc":"2026-10-02T14:00:00Z","acs":[{"id":"AC-1","verdict":"verified"}]}' > "$W/issues/42/verdicts-abc-c2.json"
echo '{"issue":42,"title":"Rename projects","candidate":"c3","baseline":"b1","candidate_run":"issue-42-candidate","verdict":"failed","generated_utc":"2026-10-12T14:00:00Z",
 "acs":[{"id":"AC-1","verdict":"failed","note":"NOTE-SECRET"}],"notes":["NOTE-SECRET"]}' > "$W/issues/42/verdicts-abc-c3.json"
cat > "$W/suite/tests/issue-42.e2e.ts" <<'T'
test('#42 AC-1: a renamed project keeps its tasks', { session: 'owner', tags: ['issue-42', 'ac-1'] },
  async ({ app, agent, screen }) => {
    await app.open('/projects');
    await agent.act('rename the project to Apollo-2');
    await app.screenshot('AC-1: the renamed project');
    // AC-1 begin
    await expect(screen.getByRole('heading', { name: 'Apollo-2' })).toBeVisible();
    // AC-1 end
  });
T
echo png > "$R/issue-42-candidate/artifacts/a1/still.png"; echo webm > "$R/issue-42-candidate/artifacts/a1/video.webm"
cat > "$R/issue-42-candidate/report.json" <<'J'
{"run":{"results":[{"tags":["issue-42","ac-1"],"status":"failed","titlePath":["#42 AC-1"],"attempts":[{"error":{"code":"assert","message":"expected heading Apollo-2 to be visible"},
 "steps":[{"api":"app.open","label":"/projects","status":"passed","artifacts":[]},{"api":"app.screenshot","label":"AC-1: the renamed project","status":"passed","artifacts":["s1"]},
          {"api":"expect","label":"heading Apollo-2","status":"failed","artifacts":[]}],
 "artifacts":[{"id":"s1","kind":"screenshot","path":"a1/still.png","producer":{"kind":"step"}},{"id":"v1","kind":"video","path":"a1/video.webm"}]}]}]}}
J
mkdir -p "$W/design/crops" "$W/design/c3/shots" "$W/validation/c3" "$W/stress/c3"
echo '{"findings":[{"id":"D-1","source":"sweep","check":"overflow-x","severity":"major","pattern":"/projects","viewport":"390x844","target":"table.list","saw":"The table is wider than the phone screen","shot":"design/c3/shots/p.png","crop":"design/crops/D-1.jpg","first_seen":"c2","last_seen":"c3","status":"open"}]}' > "$W/design/findings.json"
echo jpg > "$W/design/crops/D-1.jpg"; echo png > "$W/design/c3/shots/p.png"
printf '| id | category | updated_utc |\n| --- | --- | --- |\n| D-1 | layout | 2026-10-14T13:00:00Z |\n' > "$W/design/CATEGORIES.md"
echo '{"build":"c3","run":"validation-c3","cases":[{"id":"VAL-1","page":"/projects","form":"New project","field":"Name","kind":"html","oracle":"refused-or-intact","result":"finding","severity":"major","message":"[value-intact] the name lost its tags"}]}' > "$W/validation/c3/results.json"
echo '{"build":"c3","cases":[{"id":"VAL-1","example":"/projects/new","submit":"Create","value":"<b>x</b>","fill":{"Owner":"me"}}]}' > "$W/validation/c3/plan.json"
echo '{"build":"c3","config":{"concurrency":10,"duration_s":60},"checks":[{"id":"STRESS-API-2","target":"GET /api/projects","status":"fail","severity":"high","evidence":{"requests":900,"s5xx":3},"reason":"3 5xx answers under load"},{"id":"STRESS-API-2","target":"GET /api/files","status":"pass","severity":"high"}]}' > "$W/stress/c3/stress.json"

D="$SCRIPTS/issue-draft.mjs"
node "$D" '#42 AC-1; rm -rf ~' >/dev/null 2>&1; assert_eq "a malformed ref is a usage error" 2 "$?"
node "$D" '#99 AC-1' >/dev/null 2>&1; assert_eq "nothing known: exit 2" 2 "$?"

out="$(node "$D" '#42 AC-1')"; assert_eq "one problem" 0 "$?"
dir="$(jq -r .dir <<<"$out")"
assert "the newest failure, its run's media" '.refs == ["#42 AC-1"] and .build == "c3" and .images == 1 and .video == 1 and .labels == ["qa:found"] and .missing == []' "$out"
body="$(cat "$dir/body.md")"
case "$body" in (*'<!-- quality-inspector-found refs="#42 AC-1" build=c3 -->'*) ;; (*) echo "  the marker names the problem and the build"; FAILED=1;; esac
for want in '## The problem' 'expected heading Apollo-2 to be visible' '## The correct function' 'Source: #42 (Rename projects), acceptance criterion AC-1.' \
    '**Then** the project shows its new name with the task' '## Steps to reproduce' 'with the `owner` role' '2. Open `/projects`.' '3. Rename the project to Apollo-2' \
    'The test passed last on build `c2`' 'EVIDENCE_LINK' '## Done when' '- Given a project with one task, when the owner renames it, then the project shows its new name with the task'; do
  case "$body" in (*"$want"*) ;; (*) echo "  the body lacks: $want"; FAILED=1;; esac
done
case "$body$(cat "$dir/evidence/index.html")" in (*NOTE-SECRET*) echo "  a verdict's note reached the draft"; FAILED=1;; esac
[ -f "$dir/evidence/media/42-ac-1-1.png" ] && [ -f "$dir/evidence/media/42-ac-1-video.webm" ] || { echo "  the still and the video are beside the evidence page"; FAILED=1; }
grep -q 'src="media/42-ac-1-1.png"' "$dir/evidence/index.html" || { echo "  the evidence page shows the still"; FAILED=1; }
# Published as one private file (skills/create-issue step 3): the still and the video inline, the still
# once — its link to the full image goes with media/.
pub="$(node "$SCRIPTS/report-media.mjs" publish "$dir/evidence" private)"
assert "the evidence page becomes one file" '.inlined == 2 and .left_out == []' "$pub"
grep -q '"media/' "$dir/evidence/publish.html" && { echo "  the published evidence page links media/"; FAILED=1; }
[ "$(grep -o 'data:image/png;base64,' "$dir/evidence/publish.html" | wc -l | tr -d ' ')" = 1 ] || { echo "  the still is not inline exactly once"; FAILED=1; }

out="$(node "$D" '#42 AC-1, D-1, VAL-1, STRESS-API-2, D-404' --fix)"
dir="$(jq -r .dir <<<"$out")"
assert "four problems in one draft, the unknown one named" '.refs == ["#42 AC-1","D-1","VAL-1","STRESS-API-2"] and .missing == ["D-404"] and .images == 3
  and (.notes | any(test("fix_label is not set")))' "$out"
body="$(cat "$dir/body.md")"
case "$body" in (*'refs="#42 AC-1; D-1; VAL-1; STRESS-API-2" build=c3'*) ;; (*) echo "  the marker names every problem"; FAILED=1;; esac
for want in '## #42 AC-1 —' '## D-1 —' '## VAL-1 —' '## STRESS-API-2 —' 'Category: `layout`.' 'in a browser window of 390x844' 'is not wider than the screen' \
    'Put `<b>x</b>` into `Name`' 'Put values into the other required fields: `Owner` = `me`' 'Open `/projects/new`.' '`GET /api/projects`: 3 5xx answers under load' '(D-1)' '(STRESS-API-2)'; do
  case "$body" in (*"$want"*) ;; (*) echo "  the body lacks: $want"; FAILED=1;; esac
done
case "$body" in (*'GET /api/files'*) echo "  a target the check passed on is no problem"; FAILED=1;; esac
assert "title names the count and the build" 'startswith("4 problems on build c3: ")' "$(jq -Rs . < "$dir/title.txt")"

printf -- '- fix_label: architect:fix\n' >> "$W/CONFIG.md"
printf '| ref | issue | url | build | labels | created_utc |\n| --- | --- | --- | --- | --- | --- |\n| D-1 | #101 | https://github.com/acme/widgets/issues/101 | c3 | qa:found | 2026-10-14T13:00:00Z |\n' > "$W/FOUND.md"
assert "--fix with fix_label; an earlier issue named" '.labels == ["qa:found","architect:fix"] and .already == [{"ref":"D-1","issue":"#101","url":"https://github.com/acme/widgets/issues/101"}]' "$(node "$D" 'D-1' --fix)"

# A run by hand: each criterion's raw result, written under work/reruns/<test>/.
mkdir -p "$R/rerun-issue-42-c3-1200"
cp "$R/issue-42-candidate/report.json" "$R/rerun-issue-42-c3-1200/report.json"
node "$SCRIPTS/rerun.mjs" rerun-issue-42-c3-1200 '#42' >/dev/null 2>&1; assert_eq "rerun: --build is required" 2 "$?"
out="$(node "$SCRIPTS/rerun.mjs" rerun-issue-42-c3-1200 '#42 AC-1' --build c3)"
assert "rerun: the record" '.ref == "#42 AC-1" and .results == {"AC-1":{"status":"failed","error":"expected heading Apollo-2 to be visible"}}' "$out"
assert "rerun: kept under the test's stem" '.label == "rerun-issue-42-c3-1200" and .build == "c3" and (.utc | test("Z$"))' "$(cat "$W/reruns/issue-42/rerun-issue-42-c3-1200.json")"
out="$(node "$D" '#42 AC-1')"
assert "a run by hand is the newest failure a draft cites" '.build == "c3"' "$out"
grep -q 'manual run' "$(jq -r .dir <<<"$out")/body.md" || { echo "  the draft names the run by hand"; FAILED=1; }
exit $FAILED
