#!/usr/bin/env bash
# scripts/catalog.mjs: items from criteria, tests, verdicts, nights, heals and flakes; the runs (nights,
# environment failures, issue and scenario runs) with their reports; the product map's hotspots; test-related
# content only (no request text, requester, notes, lessons; the agent's analysis and explanations travel); escaped data; a stable
# hash and `changed` against the published one; collections; coverage pages; drift nights; the
# image budget; the credential and token refusal; the verifier's CATALOG.md and test_catalog checks;
# the profile scenarios still to adopt.
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
seed_work
W="$WORK_DIR"
printf -- '- profile: stub\n- target_repo: acme/widgets\n- display_name: QA Bot\n' > "$W/CONFIG.md"
printf '| tests/issue-42.e2e.ts | 42 | regression | 9c1e44a0f2b3 | 2026-10-03T08:12:40Z |\n| tests/scenario-7.e2e.ts | S-7 | exploratory | 1a2b3c4d5e6f | - |\n| tests/profile-sign-in.e2e.ts | P-sign-in | regression | 2b3c4d5e6f7a | 2026-10-05T03:00:00Z |\n' >> "$W/SUITE.md"
printf '| 42 | abc | c1 | b1 | partial | reported | 2026-10-02T14:03:11Z |\n' >> "$W/QA.md"
printf '| id | source | requester | thread | spec_hash | build | verdict | status | updated_utc |\n| --- | --- | --- | --- | --- | --- | --- | --- | --- |\n| S-7 | slack | U0SECRETUSER | C0SECRET/1728900000.000100 | s1 | c1 | passed | reported | 2026-10-04T10:03:11Z |\n| P-sign-in | profile | - | - | p1 | c1 | passed | reported | 2026-10-05T03:10:00Z |\n| S-9 | dashboard | - | - | s9 | - | - | queued | 2026-10-22T08:00:00Z |\n| S-10 | slack | U0SECRETUSER | C0SECRET/1 | s10 | - | - | rejected | 2026-10-21T08:00:00Z |\n' > "$W/SCENARIOS.md"
printf '| utc | test | ac | build | old_hash | new_hash | basis |\n| --- | --- | --- | --- | --- | --- | --- |\n| 2026-10-10T03:30:00Z | tests/issue-42.e2e.ts | AC-1 | c2 | aaa | bbb | ui-map |\n' > "$W/HEALS.md"
printf '| utc | test | ac | build | runs | passes |\n| --- | --- | --- | --- | --- | --- |\n| 2026-10-11T03:30:00Z | tests/issue-42.e2e.ts | AC-1 | c3 | 3 | 2 |\n' > "$W/FLAKY.md"
printf '# Catalog collections\n\n| collection | members |\n| --- | --- |\n| Upload | #42, S-7 AC-1 |\n' > "$W/CATALOG.md"
echo 'LESSON-SECRET: the registry is slow' > "$W/LESSONS.md"
# The profile's scenarios: sign-in's text changed since its row (p1), upload has no row yet.
mkdir -p "$QI_PROFILE_DIR/scenarios"
printf '# Sign-in\n\n## AC-1 — Owner signs in\nThen the dashboard shows\n' > "$QI_PROFILE_DIR/scenarios/sign-in.md"
printf '# Upload a <b>file</b>\n\n## AC-1 — Upload\nThen the file is listed\n' > "$QI_PROFILE_DIR/scenarios/upload.md"
printf '2026-10-09T03:00:00Z ERROR: environment candidate=c2\n2026-10-10T03:00:00Z ran candidate=c2 unchanged=0 relearned=0 healed=1 needs_review=0 superseded=0 flaky=0 regression=0 blocked=0 drift=0\n2026-10-12T02:10:00Z due candidate=c3 tests=1\n2026-10-12T03:00:00Z ran candidate=c3 unchanged=1 relearned=0 healed=0 needs_review=0 superseded=0 flaky=0 regression=0 blocked=0 drift=0\n' > "$W/REGRESSION.log"
mkdir -p "$W/issues/42" "$W/scenarios/S-7" "$W/scenarios/P-sign-in" "$W/regression/c2" "$W/suite/tests" "$W/security/c1"
jq -n '{mode:"regression",verdict:"environment",candidate:"c2",utc:"2026-10-09T03:00:00Z",stage:"up",exit:4,cause:"The image pull was refused.",
  evidence:["pull refused","x"],repair:"Reset and up again: the same refusal.",next:"The operator adds the registry to the egress."}' > "$W/regression/c2/environment.json"
cat > "$W/issues/42/criteria-abc.md" <<'C'
# #42 — Rename <b>projects</b>
source: done-when        frozen_utc: 2026-10-02T13:40:02Z        ac_hash: abc
summary: The owner can rename a project. The tasks of the project stay with it.

## AC-1 — a renamed project keeps its tasks
quote: The owner renames a project. The tasks stay with it.
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

## Q-1 — who renames the project
about: AC-1
question: Does an editor rename a project, or only the owner?
says A: the issue — "When the owner renames it"
says B: a comment of 2026-10-02 — "an editor renames a project"
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
echo 'http://share.example/a/plain' > "$W/issues/42/artifact.url" # not https: the reference stays
cat > "$W/regression/c2/verdicts.json" <<'J'
{"mode":"regression","candidate":"c2","acs":[{"issue":42,"id":"AC-1","verdict":"healed","explanation":"The tab moved to the side bar."}],
 "analysis":{"summary":"One check was repaired.","next":null,"problems":[{"title":"The tab moved","about":["#42 AC-1","rm -rf /","#42"],"cause":"bogus","certainty":"high",
   "what":"The tab is not in the top bar.","where":"/projects","why":"The new build moved it.","fix":"Nothing: the agent repaired the check.","extra":"dropped"},{"what":"no title: dropped"}]},
 "context":{"previous":"c1","issues":[{"number":40,"title":"Projects get tabs"}],"ui_diff":"- renamed tab \"Tasks\" → \"To-dos\" on /projects","signals":{"console_errors_new":["E1"],"slow_tests":[]}}}
J
printf '# S-7 — upload a <i>large</i> file\n\n## AC-1 — the upload finishes\nquote: REQUEST-SECRET the owner uploads a large file\nGiven a 50 MB file\nWhen the owner uploads it\nThen it is listed\nsurface: ui\ntestable: yes\n' > "$W/scenarios/S-7/criteria-s1.md"
echo 'REQUEST-SECRET please test the upload, my boss asked' > "$W/scenarios/S-7/request.md"
echo '{"scenario":"S-7","candidate":"c1","started_utc":"2026-10-04T09:45:00Z","generated_utc":"2026-10-04T10:00:00Z","cost_usd":1.234,"acs":[{"id":"AC-1","verdict":"passed"}],"notes":["NOTE-SECRET"]}' > "$W/scenarios/S-7/verdicts-s1-c1.json"
echo 'https://claude.ai/artifact/s7' > "$W/scenarios/S-7/artifact.id"
echo '{"candidate":"c1","counts":{"critical":0,"high":2,"medium":1},"findings":[{"id":"SEC-SECRET","explanation":"SEC-SECRET recipe"}]}' > "$W/security/c1/verdicts.json"
# A report's share link (docs/reporting.md → Delivery step 1): the night's links; the security run's never.
echo night2 > "$W/regression/c2/artifact.id"; echo 'https://share.example/a/Night2Slug' > "$W/regression/c2/artifact.url"
echo sec1 > "$W/security/c1/artifact.id"; echo 'https://share.example/a/SecSlug' > "$W/security/c1/artifact.url"
# The control center's sources: design findings with a crop, validation results, stress results.
mkdir -p "$W/design/crops" "$W/validation/c3" "$W/stress/c3" "$W/focus/upload-c3"
echo '{"area":"Upload","build":"c3","checks":[{"id":"FX-1","heuristic":"negative-path","expected":"refused visibly","verdict":"observation","severity":"minor","note":"FOCUS-NOTE-SECRET"}]}' > "$W/focus/upload-c3/results.json"
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
echo '{"routes":{"/":{"title":"Home","navigates":{"Projects":"/projects","Files":"/files","Recent":"/files"},"links":["All files → /files"],"viewport":[1000,500],"boxes":[["nav","Projects",0,0,100,20],["headings","Welcome home",200,100,300,40],["links","All files",400,300,100,20],
   ["tabs","Recent",600,0,100,20],["rows","Quarterly plan",0,400,500,50,"/projects"]]},
 "/projects":{"title":"Projects","buttons":["Rename"],"viewport":[1000,500],"boxes":[["buttons","Rename",100,50,200,25],["tabs","Recent",600,0,100,20],["buttons","toString",0,0,50,20],["links","Files",0,100,50,20,"/files"],["tabs","Members",300,0,100,20],["headings","Members",0,200,100,20],["inputs","Members",0,250,100,20]],"navigates":{"Members":"/files"}},"/files":{"title":"Files"}}}' > "$W/inventory/c3/inventory.json"
echo '[{"number":42,"title":"Rename <b>projects</b>","state":"closed","labels":[{"name":"area:projects"}]},{"number":57,"title":"Upload progress","state":"open","labels":[]},{"number":63,"title":"Bulk delete","state":"open","labels":[]},{"number":65,"title":"A labelled pull request","state":"open","labels":[],"pull_request":{"url":"x"}},{"number":67,"title":"Retest in progress","state":"open","labels":[{"name":"qa:retest"}]}]' > "$STUB_DIR/issues.json"
# Overview → Activity: the lock (never its session), the rows on their way, the waiting issues, the schedules.
mkdir -p "$W/env"; echo 'issues 2026-10-22T19:35:00Z SESSION-SECRET-ID' > "$W/env/LOCK"
printf '| 57 | def | c4 | b1 | - | in_progress | 2026-10-22T19:50:00Z |\n| 67 | jkl | c4 | b1 | - | in_progress | 2026-10-22T19:40:00Z |\n' >> "$W/QA.md"
echo '{"taken_utc":"2026-10-22T15:00:00Z","schedules":{"quality-inspector-issues-1h":{"enabled":true,"cron":"7 * * * *","task":"TASK-SECRET"},"quality-inspector-audit-weekly":{"enabled":null,"cron":"0 7 * * 5"},"other-agent-job":{"enabled":true,"cron":"0 1 * * *"}}}' > "$W/schedules.json"

mkdir -p "$W/catalog/thumbs"; echo old > "$W/catalog/thumbs/issue-99-ac-1.jpg"; echo old > "$W/catalog/thumbs/issue-99-ac-1.full.webp"
printf '%s\n' '{"ts":"2026-10-02T14:05:00Z","run":"r","job":"issues","level":"info","event":"issue_done","msg":"issue=42 verdict=partial minutes=37 model_steps=120"}' \
  '{"ts":"2026-10-02T14:06:00Z","run":"r","job":"issues","level":"info","event":"issue_done","msg":"issue=420 verdict=failed minutes=5 model_steps=9"}' > "$W/logs/events-2026-10-02.jsonl"
out="$(node "$SCRIPTS/catalog.mjs")"; rc=$?
assert_eq "catalog exits 0" 0 "$rc"
assert "summary" '.items == 5 and .changed == true and (.hash | test("^[0-9a-f]{12}$")) and (.thumbnails | test("none due|unavailable")) and .notes == []' "$out"
[ -e "$W/catalog/thumbs/issue-99-ac-1.jpg" ] || [ -e "$W/catalog/thumbs/issue-99-ac-1.full.webp" ] && { echo "  a thumbnail of a gone item was kept"; FAILED=1; }
html="$(cat "$W/catalog/index.html")"
page_data() { node -e 'const h=require("fs").readFileSync(process.argv[1],"utf8");const m=h.match(/<script type="application\/json" id="qi-catalog-data">([\s\S]*?)<\/script>/);process.stdout.write(m[1])' "$W/catalog/index.html"; }
data="$(page_data)"
# A criterion quotes its source verbatim (docs/acceptance-criteria.md); a `## Q-<k>` section of a
# contradiction is no criterion.
assert "a criterion quotes its source, and a Q section is no criterion" '(.items[] | select(.key == "issue-42/AC-1") | .quote == "The owner renames a project. The tasks stay with it.")
  and ([.items[] | select(.key | test("/Q-"))] | length == 0)' "$data"
# The viewer's script parses: no test drives the page, so a syntax error would ship silently.
node -e 'const s=require("fs").readFileSync(process.argv[1],"utf8");require("fs").writeFileSync(process.argv[2],[...s.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((x)=>x[1]).join("\n"))' \
  "$SCRIPTS/catalog/viewer.html" "$SANDBOX/viewer.js" && node --check "$SANDBOX/viewer.js" 2>/dev/null
assert_eq "the viewer's script parses" 0 "$?"
# A run's window is {from, to} with a build tag and a time at each end (docs/regression.md -> step 7):
# it prints as text, never `[object Object]`. A side panel opens at half the screen (docs/catalog.md).
win="$(node -e 'const s=require("fs").readFileSync(process.argv[1],"utf8");const f=(s.match(/^function winText\([\s\S]*?^}$/m)||[""])[0];eval(f);process.stdout.write(winText({from:{tag:"c1",utc:"2026-10-24T02:02:55Z"},to:{tag:"c2",utc:"2026-10-25T21:36:01Z"}}))' "$SCRIPTS/catalog/viewer.html" 2>/dev/null)"
assert_eq "the viewer: a run's window as text, never [object Object]" "c1 · 2026-10-24 02:02 → c2 · 2026-10-25 21:36" "$win"
dw=0
grep -q 'width:min(var(--dw,max(360px,50vw)),100%)' "$SCRIPTS/catalog/viewer.html" && grep -q 'right:min(var(--dw,max(360px,50vw)),100%)' "$SCRIPTS/catalog/viewer.html" && dw=1
assert_eq "the viewer: a side panel opens at half the screen" 1 "$dw"
# Every move to another place is a history step the browser's back undoes, with an in-memory "back" where
# the frame may not touch the history (docs/catalog.md → Links and navigation).
nav="$(node -e 'const s=require("fs").readFileSync(process.argv[1],"utf8");
process.stdout.write([/history\[push \? .pushState. : .replaceState.\]/, /addEventListener\(.popstate./, /^function back\(\)/m, /^function originDrawer\(/m, /onclick: back \}/].map((re)=>re.test(s)?1:0).join(""))' "$SCRIPTS/catalog/viewer.html" 2>/dev/null)"
assert_eq "the viewer: history steps, popstate, back, the origin panel" 11111 "$nav"
# Nothing goes to the agent but from the box at the bottom: one sendPrompt call, inside askAgent.
send="$(node -e 'const s=require("fs").readFileSync(process.argv[1],"utf8");const calls=[...s.matchAll(/\.sendPrompt\(/g)].length;
const box=(s.match(/^function askAgent\([\s\S]*?^}$/m)||[""])[0];process.stdout.write(`${calls}:${(box.match(/\.sendPrompt\(/g)||[]).length}`)' "$SCRIPTS/catalog/viewer.html" 2>/dev/null)"
assert_eq "the viewer sends to the agent only from the box" "1:1" "$send"
# A filter of a view refines the place: the run-type chips and a picked map control add no history step.
refine="$(node -e 'const s=require("fs").readFileSync(process.argv[1],"utf8");
process.stdout.write([/go\(\{ rt: /.test(s), /go\(\{ hs: /.test(s), /onclick: \(\) => pickRt\(k\)/.test(s), /pickHs\(S\.hs === k/.test(s)].map((x)=>x?1:0).join(""))' "$SCRIPTS/catalog/viewer.html" 2>/dev/null)"
assert_eq "the viewer: a run type and a map control are refinements, not steps" 0011 "$refine"
# A scenario request the page sends has one shape (docs/scenarios.md → A request from the dashboard).
scen="$(node -e 'const s=require("fs").readFileSync(process.argv[1],"utf8");const m=s.match(/^const SCEN_RE = (\/.*\/);$/m);const re=eval(m[1]);
const w="Rename a project and save: the new name shows in the list.";
const t=[`test this scenario: On the page /projects/:id, the button "Save": ${w}`, `test this scenario: On the page /: ${w}\nAnd then the list is sorted.`,
  "test this scenario: On the page /projects: too short", `promote #42: ${w}`, `test this scenario: On the page /x, the button "a"b": ${w}`,
  `test this scenario: On the page /x: ${w}\u0007`, `test this scenario: On the page /x: ${"a".repeat(2001)}`];
process.stdout.write(t.map((x)=>re.test(x)?1:0).join(""))' "$SCRIPTS/catalog/viewer.html" 2>/dev/null)"
assert_eq "a scenario request: the composed shape only, bounded, no control characters" 1100000 "$scen"
# The Test builder's steps go out as that scenario request, or as the operator's live walk in the same
# bounded shape (docs/catalog.md → Test builder, docs/on-demand.md → "walk these steps live").
walk="$(node -e 'const s=require("fs").readFileSync(process.argv[1],"utf8");const re=eval(s.match(/^const WALK_RE = (\/.*\/);$/m)[1]);
const sc=eval(s.match(/^const SCEN_RE = (\/.*\/);$/m)[1]);
const w="1. Open: /agents\n2. Do: Click the button \"Send\"\n3. Check: The chat shows the message";
const t=[`walk these steps live: On the page /agents: ${w}`, `walk these steps live: On the page /agents, the button "Send": ${w}`, "walk these steps live: On the page /: short",
  `walk these steps live: On the page /x: ${w}\u0007`, `walk these steps live: On the page https://x.example/: ${w}`, `walk these steps live: On the page /x: ${"a".repeat(2001)}`];
process.stdout.write(t.map((x)=>re.test(x)?1:0).join("") + (sc.test(`test this scenario: On the page /agents: ${w}`)?1:0)
  + [/allowed = \(t\) => CMD_RE\.test\(t\) \|\| SCEN_RE\.test\(t\) \|\| WALK_RE\.test\(t\);/, /\[.builder., .Test builder., /, /builder: viewBuilder \}/].map((r)=>r.test(s)?1:0).join(""))' "$SCRIPTS/catalog/viewer.html" 2>/dev/null)"
assert_eq "the Test builder: its walk command bounded like a request, its steps a scenario request, the view drawn" 1000001111 "$walk"
# A report opens only by its own link: the page never asks the agent to open one (docs/catalog.md → Content).
cmd="$(node -e 'const s=require("fs").readFileSync(process.argv[1],"utf8");const re=eval(s.match(/^const CMD_RE = (\/.*\/);$/m)[1]);
process.stdout.write([re.test("open the report abc123"), /open the report/.test(s), /sendPrompt\(c\)/.test(s)].map((x)=>x?1:0).join(""))' "$SCRIPTS/catalog/viewer.html" 2>/dev/null)"
assert_eq "no command opens a report" 000 "$cmd"
# Each kind of control says what it does (docs/catalog.md → Explained on the page): a move, a new tab, a command.
kinds="$(node -e 'const s=require("fs").readFileSync(process.argv[1],"utf8");
process.stdout.write([/^function goLink\(/m, /^const extLink = /m, /class: .btn agent., type: .button., .data-kind.: .agent./, /^const prepBtn = /m, /^function showTip\(/m].map((re)=>re.test(s)?1:0).join(""))' "$SCRIPTS/catalog/viewer.html" 2>/dev/null)"
assert_eq "the viewer: go links, new-tab links, agent commands, prepared commands, tooltips" 11111 "$kinds"
# A link to another site opens by the page's script, also in a frame; with no new tab, a box shows the address.
ext="$(node -e 'const s=require("fs").readFileSync(process.argv[1],"utf8");
process.stdout.write([/^function openExt\(/m, /window\.open\(href, ._blank.\)/, /^\s*linkBox\(href\);/m, /document\.addEventListener\(.click., \(e\) => \{\n\s*if \(e\.defaultPrevented/].map((re)=>re.test(s)?1:0).join(""))' "$SCRIPTS/catalog/viewer.html" 2>/dev/null)"
assert_eq "the viewer opens a link to another site by its script, else shows its address" 1111 "$ext"
# Day / night (docs/catalog.md → Day / night): the system's dark tokens and the switch's dark tokens are the same set.
dark="$(node -e 'const s=require("fs").readFileSync(process.argv[1],"utf8");
const sys=(s.match(/@media \(prefers-color-scheme:dark\)\{:root:not\(\[data-theme=light\]\)\{([^}]*)\}\}/)||[])[1];
const pick=(s.match(/:root\[data-theme=dark\]\{([^}]*)\}/)||[])[1];
process.stdout.write(sys&&pick&&sys.includes("--bg:")&&sys===pick?"same":"differ")' "$SCRIPTS/catalog/viewer.html" 2>/dev/null)"
assert_eq "the viewer: the dark colours of the system and of the switch are the same" same "$dark"
# Gherkin (docs/catalog.md → Gherkin): criteria only, in their frozen words, the ref named when a list spans origins.
gk="$(node -e 'const s=require("fs").readFileSync(process.argv[1],"utf8");
const fn=(s.match(/^function gherkinText\([\s\S]*?^}$/m)||[""])[0];
const str=(v)=>(v==null?"":String(v)), num=(r)=>{const m=str(r).match(/\d+/);return m?+m[0]:0;};
const gherkinText=eval(`(${fn})`);
process.stdout.write(gherkinText("Upload", [
 {kind:"criterion",ref:"S-7",id:"AC-1",name:"listed",given:"a file",when:"they upload\n it",then:"it is listed",testable:true},
 {kind:"exploration",ref:"#42",id:"EX-1",name:"x",given:"g",when:"w",then:"t"},
 {kind:"criterion",ref:"#42",id:"AC-2",name:"cache",given:null,when:"w",then:"t",testable:false}]))' "$SCRIPTS/catalog/viewer.html" 2>/dev/null)"
assert_eq "the viewer: Copy as Gherkin" "# Exported from the test catalog.
# The frozen acceptance criteria, in words. No step definitions run them.
Feature: Upload

  @not-testable
  Scenario: #42 AC-2 — cache
    When w
    Then t

  Scenario: S-7 AC-1 — listed
    Given a file
    When they upload it
    Then it is listed" "$gk"
assert "activity: lock without its session, rows on their way, waiting issues, own schedules only" '.activity.lock == {"owner":"issues","since":"2026-10-22T19:35:00Z"}
  and ([.activity.issues[] | {issue, status, build}] == [{"issue":57,"status":"in_progress","build":"c4"},{"issue":67,"status":"in_progress","build":"c4"}])
  and .activity.budget_min == 150
  and .activity.schedules.list == [{"name":"quality-inspector-issues-1h","enabled":true,"cron":"7 * * * *"},{"name":"quality-inspector-audit-weekly","enabled":null,"cron":"0 7 * * 5"}]' "$data"
assert "activity: waiting holds the open issues only — no pull request, no issue already in progress" '.activity.waiting == [{"issue":63,"title":"Bulk delete","kind":"new"}]' "$data"
case "$html" in (*SESSION-SECRET-ID*|*TASK-SECRET*) echo "  the lock's session or a schedule's task reached the page"; FAILED=1;; esac
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
assert "an environment failure: its step, cause, repair, next step and evidence" '.runs[2].failure == {"stage":"up","exit":4,"cause":"The image pull was refused.","repair":"Reset and up again: the same refusal.","next":"The operator adds the registry to the egress.","evidence":["pull refused","x"]}
  and .runs[1].failure == null' "$data"
assert "a run's length: a night from its due line, an issue run from issue_done, a scenario from its file with its cost" '[.runs[] | [.secs, .cost_usd]]
  == [[3000,null],[null,null],[null,null],[900,1.23],[2220,null]]' "$data"
assert "a night: its entries, change context and signal counts, its report" '.runs[1] | .entries == [{"key":"issue-42/AC-1","value":"healed","cause":null,"why":"The tab moved to the side bar."}] and .previous == "c1"
  and .issues == [{"number":40,"title":"Projects get tabs"}] and (.ui_diff | test("To-dos")) and .signals == {"console_errors_new":1,"slow_tests":0} and .report == "https://share.example/a/Night2Slug" and .counts.healed == 1' "$data"
assert "an issue run: its verdicts and report; a scenario run: its link" '(.runs[4] | .entries == [{"key":"issue-42/AC-1","value":"verified","cause":null},{"key":"issue-42/AC-2","value":"not-testable","cause":null},{"key":"issue-42/EX-1","value":"observation","cause":null}]
  and .report == "platform://artifacts/abc123" and .baseline == "b1") and .runs[3].report == "https://claude.ai/artifact/s7"
  and (.items[] | select(.key == "scenario-7/AC-1") | .evidence) == "https://claude.ai/artifact/s7"' "$data"
assert "hotspots: a page-only control names its tests; a nav item stands for its page" '(.pages[] | select(.pattern == "/projects") | .viewport == [1000,500]
  and .hotspots[0] == {"kind":"buttons","name":"Rename","box":[0.1,0.1,0.2,0.05],"items":["issue-42/AC-1","issue-42/EX-1"]})
  and (.pages[] | select(.pattern == "/") | .hotspots[0:2] == [{"kind":"nav","name":"Projects","box":[0,0,0.1,0.04],"to":"/projects","items":["issue-42/AC-1","issue-42/EX-1"]},
    {"kind":"headings","name":"Welcome home","box":[0.2,0.2,0.3,0.08],"items":[]}])
  and (.pages[] | select(.pattern == "/") | .hotspots[2] | .kind == "links" and .name == "All files" and .to == "/files") and (.pages[] | select(.pattern == "/files") | .hotspots == [])' "$data"
assert "hotspots: a tab walks where it led on its own page, a list row and a link where their link leads; nothing by an inherited name, nor for a heading or a field of a clicked tab's name" '(.pages[] | select(.pattern == "/") | .hotspots[3:5] == [{"kind":"tabs","name":"Recent","box":[0.6,0,0.1,0.04],"to":"/files","items":["scenario-7/AC-1"]},
    {"kind":"rows","name":"Quarterly plan","box":[0,0.8,0.5,0.1],"to":"/projects","items":["issue-42/AC-1","issue-42/EX-1"]}])
  and (.pages[] | select(.pattern == "/projects") | (.hotspots[1] | has("to") | not) and (.hotspots[2] | has("to") | not) and .hotspots[3].to == "/files" and [.hotspots[4:7][] | .to] == ["/files",null,null])' "$data"
assert "collections" '.collections == [{"name":"Upload","members":["#42","S-7 AC-1"]}]' "$data"
assert "control center: the modules' state" '(.modules.modules | length) == 12 and (.modules.modules[] | select(.id == "ui-sweep") | .state == "disabled") and .interactive == false and (.modules | has("generated_utc") | not)' "$data"
assert "design findings: register fields, a crop, nothing else" '(.design | length) == 2 and (.design[0] | .id == "D-1" and .saw == "Text of “Rename” button is clipped" and (.crop | test("^i[0-9]+$")) and (has("shot") | not) and (has("box") | not))
  and .design[1].status == "dismissed" and .design[1].crop == null' "$data"
assert "findings: validation and stress as they are, security only counted" '.findings.validation.cases[0].message == "[value-intact] changed" and .findings.stress.checks[0].id == "STRESS-API-2"
  and .findings.security == {"candidate":"c1","utc":null,"counts":{"critical":0,"high":2,"medium":1},"report":"platform://artifacts/sec1"}' "$data"
assert "requests on their way: id, source, state — never the requester or thread" '.findings.requests == [{"id":"S-9","source":"dashboard","status":"queued","build":null,"verdict":null,"utc":"2026-10-22T08:00:00Z","title":null},
  {"id":"S-10","source":"slack","status":"rejected","build":null,"verdict":null,"utc":"2026-10-21T08:00:00Z","title":null}]' "$data"
assert "profile scenarios to adopt: id, the file's title, kind and when, in the nightly order" '.findings.profile_queue == {"cap":3,"list":[
  {"id":"P-sign-in","title":"Sign-in","kind":"changed","when":"next"},{"id":"P-upload","title":"Upload a <b>file</b>","kind":"new","when":"next"}]}' "$data"
assert "a focus run, its checks without their notes" '.findings.focus == [{"run":"upload-c3","area":"Upload","build":"c3","utc":null,"checks":[{"id":"FX-1","heuristic":"negative-path","given":null,"when":null,"expected":"refused visibly","verdict":"observation","severity":"minor"}]}]' "$data"
assert "areas for a focus" '.areas | index("projects") != null and index("files") != null' "$data"
assert "coverage pages" '[.pages[] | {pattern, covered, nav}] | (map(select(.pattern == "/projects"))[0] == {"pattern":"/projects","covered":"regression","nav":"Projects"})
  and (map(select(.pattern == "/files"))[0].covered == "exploratory")' "$data"
# The agent's analysis and its sentence on a result are written for the page (docs/reporting.md →
# The agent's analysis): text only, a bad cause or reference dropped, a problem without a title dropped.
assert "a night: the agent's analysis" '.runs[1].analysis == {"summary":"One check was repaired.","next":null,"problems":[{"title":"The tab moved","cause":null,"certainty":"high",
  "about":["#42 AC-1","#42"],"what":"The tab is not in the top bar.","where":"/projects","why":"The new build moved it.","fix":"Nothing: the agent repaired the check."}]}
  and .runs[4].analysis == null' "$data"
assert "a result's sentence in the history of its test case" '[.items[] | select(.key == "issue-42/AC-1") | .history[] | select(.build == "c2")][0].why == "The tab moved to the side bar."' "$data"
for secret in U0SECRETUSER C0SECRET REQUEST-SECRET SOURCE-SECRET NOTE-SECRET LESSON-SECRET SEC-SECRET FOCUS-NOTE-SECRET; do
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
# The product map's page shots come after the regression tier's stills and the design crops, before the other stills.
cp "$W/catalog/thumbs/issue-42-ac-1.jpg" "$W/catalog/thumbs/map-projects.jpg"
out="$(QI_CATALOG_IMG_BUDGET=2600 node "$SCRIPTS/catalog.mjs")"; data="$(page_data)"
assert "the regression still, the design crop and the page shot fit; one is dropped" '.images == 3 and .dropped_images == 1' "$out"
assert "the page shot wins over a non-regression still" '(.items[] | select(.key == "issue-42/AC-1") | .still) != null
  and (.pages[] | select(.pattern == "/projects") | .shot) != null and (.items[] | select(.key == "scenario-7/AC-1") | .still) == null' "$data"
rm -f "$W/catalog/thumbs/map-projects.jpg"
# The sharp copies: after every small one, in the same order; a place keeps its small one when its sharp copy does not fit.
head -c 900 /dev/zero | tr '\0' 'y' > "$W/catalog/thumbs/issue-42-ac-1.full.webp"
out="$(node "$SCRIPTS/catalog.mjs")"; data="$(page_data)"
assert "a sharp copy is embedded beside its small one" '.images == 4 and .sharp_images == 1 and .sharp_dropped == 0' "$out"
assert "the sharp copy is a WebP, the small one stays" '(.items[] | select(.key == "issue-42/AC-1") | .still != null and .still_sharp != null and .still != .still_sharp)
  and (.images[(.items[] | select(.key == "issue-42/AC-1") | .still_sharp)] | startswith("data:image/webp;base64,"))
  and (.items[] | select(.key == "scenario-7/AC-1") | .still_sharp == null)' "$data"
head -c 20000 /dev/zero | tr '\0' 'y' > "$W/catalog/thumbs/issue-42-ac-1.full.webp"
out="$(QI_CATALOG_IMG_BUDGET=10000 node "$SCRIPTS/catalog.mjs")"; data="$(page_data)"
assert "a sharp copy that does not fit: every small one stays" '.images == 3 and .dropped_images == 0 and .sharp_images == 0 and .sharp_dropped == 1' "$out"
assert "the place shows its small one" '(.items[] | select(.key == "issue-42/AC-1") | .still != null and .still_sharp == null)' "$data"
rm -f "$W/catalog/thumbs/issue-42-ac-1.full.webp"

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
# A failed issue listing leaves the waiting issues unknown, never an empty queue.
STUB_GH_FAIL=1 node "$SCRIPTS/catalog.mjs" >/dev/null 2>&1
assert "activity: a failed listing is unknown, not empty" '.activity.waiting == null' "$(page_data)"

# Managing from the page: a run by hand joins the history (its raw result, never its message), the
# found issues, the design triage, the labels a new issue gets; the commands' closed set.
mkdir -p "$W/reruns/scenario-7"
echo '{"label":"rerun-scenario-7-c3-1200","ref":"S-7 AC-1","build":"c3","utc":"2026-10-14T12:00:00Z","results":{"AC-1":{"status":"failed","error":"RERUN-ERROR-SECRET"},"bogus":{"status":"failed"}}}' > "$W/reruns/scenario-7/rerun-scenario-7-c3-1200.json"
printf '| ref | issue | url | build | labels | created_utc |\n| --- | --- | --- | --- | --- | --- |\n| S-7 AC-1 | #101 | https://github.com/acme/widgets/issues/101 | c3 | qa:found,architect:fix | 2026-10-14T13:00:00Z | The upload / never ends |\n| D-1 | #101 | https://github.com/acme/widgets/issues/101 | c3 | qa:found,architect:fix | 2026-10-14T13:00:00Z |\n| D-9 | #x | javascript:alert(1) | c3 | - | - |\n' > "$W/FOUND.md"
printf '| id | category | updated_utc |\n| --- | --- | --- |\n| D-1 | layout | 2026-10-14T13:00:00Z |\n| D-2 | Not A Slug | 2026-10-14T13:00:00Z |\n' > "$W/design/CATEGORIES.md"
printf '| id | dismissed_utc | reason |\n| --- | --- | --- |\n| D-2 | 2026-10-14T13:00:00Z | duplicate |\n' > "$W/design/DISMISSED.md"
printf -- '- fix_label: architect:fix\n' >> "$W/CONFIG.md"
node "$SCRIPTS/catalog.mjs" >/dev/null; assert_eq "a build with the triage and a run by hand" 0 "$?"
data="$(page_data)"
assert "a run by hand: in the history and the runs, its raw result only" '(.items[] | select(.key == "scenario-7/AC-1") | .history[-1] == {"build":"c3","run":"rerun","value":"failed","utc":"2026-10-14T12:00:00Z","cause":null})
  and ([.runs[] | select(.type == "rerun")] | length == 1 and .[0].ref == "S-7" and .[0].entries == [{"key":"scenario-7/AC-1","value":"failed","cause":null}] and .[0].report == null)' "$data"
assert "found issues: a row per problem, a non-https address dropped" '[.found[] | .ref + ":" + (.issue|tostring)] == ["S-7 AC-1:101","D-1:101"] and .found[0].labels == ["qa:found","architect:fix"] and .found[0].title == "The upload / never ends" and .found[1].title == null' "$data"
assert "design triage: a category, a dismissal reason, a malformed category dropped" '(.design[] | select(.id == "D-1") | .category == "layout" and .dismiss_reason == null)
  and (.design[] | select(.id == "D-2") | .category == null)' "$data"
assert "the labels a new issue gets" '.issue_labels == {"found":"qa:found","fix":"architect:fix"}' "$data"
case "$(cat "$W/catalog/index.html")" in (*RERUN-ERROR-SECRET*) echo "  a run by hand's error message reached the page"; FAILED=1;; esac
cmd="$(node -e 'const s=require("fs").readFileSync(process.argv[1],"utf8");const re=eval(s.match(/^const CMD_RE = (\/.*\/);$/m)[1]);
const t=["run #42", "run #42 AC-1", "run S-7 AC-1", "run P-sign-in", "create issue for #42 AC-1", "create issue for #42 AC-1, D-3, VAL-2, STRESS-API-2, S-7 AC-1 for the architect",
  "categorize D-3 layout", "categorize D-3 -", "dismiss D-3 as wont-fix", "reopen D-3", "add #42 AC-1 to the collection Upload", "remove S-7 from the collection My set",
  "run #42; rm -rf ~", "create issue for #42", "create issue for D-3 for everyone", "categorize D-3 Layout", "dismiss D-3 as boring", `create issue for ${Array(21).fill("D-1").join(", ")}`, "add #42 to the collection ../x",
  "run feature renaming", "accept M-1", "keep M-12", "run feature Bad Id", "accept M-1; rm -rf ~",
  "run #42 IN-1", "create issue for #42 IN-1", "add #42 IN-1 to the collection Goals", "run S-7 IN-1", "create issue for S-7 IN-1"];
process.stdout.write(t.map((x)=>re.test(x)?1:0).join(""))' "$SCRIPTS/catalog/viewer.html" 2>/dev/null)"
assert_eq "the managing commands: their shapes only, at most 20 problems" 11111111111100000001110011100 "$cmd"

# The agent's features, the open maintenance proposals and a feature run (docs/features.md,
# docs/maintenance.md): a malformed feature id and a closed proposal stay out; a feature run joins the
# runs and the history with its criteria's raw results, a malformed key dropped.
printf '# Features\n\n| feature | name | aliases | members | updated_utc |\n| --- | --- | --- | --- | --- |\n| renaming | Renaming projects | Přejmenování | #42 AC-1, S-7 | 2026-10-20T00:00:00Z |\n| Bad Id | x | - | #42 | - |\n' > "$W/FEATURES.md"
printf '# Maintenance\n\n| id | test | kind | build | basis | proposal | state | opened_utc | closed_utc |\n| --- | --- | --- | --- | --- | --- | --- | --- | --- |\n| M-1 | #42 AC-1 | needs-review | c3 | ui-map: tab moved | heal | open | 2026-10-20T00:00:00Z | - |\n| M-2 | S-7 | drift | c3 | x | re-promote | kept | 2026-10-20T00:00:00Z | 2026-10-21T00:00:00Z |\n' > "$W/MAINTENANCE.md"
mkdir -p "$W/reruns/feature-renaming"
echo '{"label":"feature-renaming-c3-1300","feature":"renaming","build":"c3","utc":"2026-10-14T13:00:00Z","results":{"issue-42/AC-1":{"status":"passed","error":null},"../x/AC-1":{"status":"failed"}}}' > "$W/reruns/feature-renaming/feature-renaming-c3-1300.json"
node "$SCRIPTS/catalog.mjs" >/dev/null; assert_eq "a build with features, maintenance and a feature run" 0 "$?"
data="$(page_data)"
assert "features: the well-formed rows" '.features == [{"id":"renaming","name":"Renaming projects","aliases":["Přejmenování"],"members":["#42 AC-1","S-7"]}]' "$data"
assert "maintenance: the open proposals only" '[.maintenance[] | .id + ":" + .test + ":" + .kind + ":" + .proposal + ":" + .basis] == ["M-1:#42 AC-1:needs-review:heal:ui-map: tab moved"]' "$data"
assert "a feature run: in the runs and the history" '([.runs[] | select(.type == "feature")] | length == 1 and .[0].ref == "renaming" and .[0].entries == [{"key":"issue-42/AC-1","value":"passed","cause":null}])
  and (.items[] | select(.key == "issue-42/AC-1") | [.history[] | select(.run == "feature")] | length == 1)' "$data"

# An intent test (docs/intent.md): its own item kind, its goal from intent-<ac_hash>.md, its verdict from
# "intents" in the history, never mixed into the criteria.
cat > "$W/issues/42/intent-abc.md" <<'C'
# #42 — intent        frozen_utc: 2026-10-02T13:41:30Z        ac_hash: abc

## IN-1 — a renamed project is found by its new name
Goal "so that a team finds a project by the name it uses now"
Given a project with one task
When the owner renames it, then searches for the new name
Then the search lists the renamed project
covers: AC-1
surface: ui
testable: yes
C
jq '. + {intent_verdict: "met", intents: [{id: "IN-1", verdict: "verified"}]}' "$W/issues/42/verdicts-abc-c1.json" > "$W/v.tmp" && mv "$W/v.tmp" "$W/issues/42/verdicts-abc-c1.json"
node "$SCRIPTS/catalog.mjs" >/dev/null; assert_eq "a build with an intent test" 0 "$?"
data="$(page_data)"
assert "an intent test is its own item, with its goal and its verdict" '(.items[] | select(.key == "issue-42/IN-1") | .kind == "intent" and .goal == "\"so that a team finds a project by the name it uses now\"" and .then == "the search lists the renamed project" and ([.history[] | select(.run == "issue")][-1].value == "verified"))
  and ([.items[] | select(.key == "issue-42/AC-1") | .kind] == ["criterion"])' "$data"
# An intent test run by hand ("run #42 IN-1") and in a feature run joins its history; a scenario has no IN.
mkdir -p "$W/reruns/issue-42"
echo '{"label":"rerun-issue-42-c3-1400","ref":"#42 IN-1","build":"c3","utc":"2026-10-14T14:00:00Z","results":{"IN-1":{"status":"failed","error":null}}}' > "$W/reruns/issue-42/rerun-issue-42-c3-1400.json"
echo '{"label":"feature-renaming-c3-1500","feature":"renaming","build":"c3","utc":"2026-10-14T15:00:00Z","results":{"issue-42/IN-1":{"status":"passed","error":null},"scenario-7/IN-1":{"status":"failed"}}}' > "$W/reruns/feature-renaming/feature-renaming-c3-1500.json"
node "$SCRIPTS/catalog.mjs" >/dev/null; assert_eq "a build with intent test runs by hand" 0 "$?"
data="$(page_data)"
assert "an intent test run by hand and in a feature run: in its history; a scenario's IN key dropped" '(.items[] | select(.key == "issue-42/IN-1") | [.history[] | select(.run == "rerun" or .run == "feature") | .run + ":" + .value] == ["rerun:failed","feature:passed"])
  and ([.runs[] | select(.type == "feature" and .utc == "2026-10-14T15:00:00Z")][0].entries == [{"key":"issue-42/IN-1","value":"passed","cause":null}])' "$data"

# An issue's summary (the criteria file's `summary:` line) on its origin; a scenario has none.
assert "an issue's summary from its frozen criteria" '(.items[] | select(.key == "issue-42/AC-1") | .origin.summary == "The owner can rename a project. The tasks of the project stay with it.")
  and (.items[] | select(.key == "scenario-7/AC-1") | .origin | has("summary") | not)' "$data"
# The cause of a result that is not a pass (docs/reporting.md → Cause of a failure): the verdict's own,
# else a failed is product and a needs-review test; an unknown value or a pass has none.
jq -n '{issue:42,title:"Rename",ac_hash:"abc",candidate:"c9",verdict:"failed",generated_utc:"2026-10-20T10:00:00Z",
  acs:[{id:"AC-1",verdict:"blocked",cause:"environment"},{id:"AC-2",verdict:"failed"}],intents:[{id:"IN-1",verdict:"flaky",cause:"bogus"}],
  explorations:[{id:"EX-1",verdict:"observed-ok",cause:"test"}]}' > "$W/issues/42/verdicts-abc-c9.json"
printf '| 42 | abc | c9 | b1 | failed | reported | 2026-10-20T10:00:00Z |\n' >> "$W/QA.md"
node "$SCRIPTS/catalog.mjs" >/dev/null; assert_eq "a build with causes" 0 "$?"
data="$(page_data)"
assert "causes: given, by default, none" '([.runs[] | select(.type == "issue" and .build == "c9")][0].entries | map(.key + ":" + (.cause // "-"))) == ["issue-42/AC-1:environment","issue-42/AC-2:product","issue-42/IN-1:-","issue-42/EX-1:-"]
  and (.items[] | select(.key == "issue-42/AC-1") | .verdict.cause == "environment")' "$data"
# A night's entry: its own cause, else a regression is product and a needs-review test.
jq '.acs += [{issue:42,id:"IN-1",verdict:"needs-review"}]' "$W/regression/c2/verdicts.json" > "$W/v.tmp" && mv "$W/v.tmp" "$W/regression/c2/verdicts.json"
node "$SCRIPTS/catalog.mjs" >/dev/null; data="$(page_data)"
# A night of only reworked tests: its counts and its top verdict.
printf '2026-10-14T03:00:00Z ran candidate=c5 unchanged=0 relearned=0 healed=0 reworked=1 needs_review=0 superseded=0 flaky=0 regression=0 blocked=0 drift=0\n' >> "$W/REGRESSION.log"
node "$SCRIPTS/catalog.mjs" >/dev/null; rdata="$(page_data)"
assert "a reworked night: its count and top verdict" '[.runs[] | select(.type == "regression" and .build == "c5")][0] | .counts.reworked == 1 and .verdict == "reworked"' "$rdata"
# The repair rule of the viewer: a test cause repairs and does not highlight a bug issue; product and
# environment causes, or an open proposal, give no repair.
rp="$(node -e 'const s=require("fs").readFileSync(process.argv[1],"utf8");const f=(s.match(/^function repairOf\([\s\S]*?^}$/m)||[""])[0];eval(f);
const r=(...a)=>{const x=repairOf(...a);return (x.repair?"R":"-")+(x.hotBug?"B":"-")};
process.stdout.write([r(true,"test",true,false),r(true,"unknown",true,false),r(true,"product",true,false),r(true,"environment",true,false),r(true,"test",true,true),r(true,"test",false,false),r(false,"test",true,false)].join(" "))' "$SCRIPTS/catalog/viewer.html" 2>/dev/null)"
assert_eq "repair rule: test, unknown, product, environment, open proposal, no file, passing" "R- RB -B -- -- -- --" "$rp"
assert "a night's causes" '([.runs[] | select(.type == "regression" and .build == "c2" and .verdict != "environment")][0].entries | map(.key + ":" + (.cause // "-")) | sort) == ["issue-42/AC-1:-","issue-42/IN-1:test"]' "$data"
# The agent's text never carries a scenario's request or its requester (docs/catalog.md → Never): a field
# that repeats 6 words in a row of a request, or names a requester or thread, is dropped, and a note says so.
jq '.acs[0].explanation = "The requester asked: please test the upload, my boss asked. EXPLAIN-QUOTE-CANARY"
  | .analysis.summary = "Asked by U0SECRETUSER. EXPLAIN-WHO-CANARY" | .analysis.problems[0].why = "The new build moved it."' "$W/regression/c2/verdicts.json" > "$W/v.tmp" && mv "$W/v.tmp" "$W/regression/c2/verdicts.json"
out="$(node "$SCRIPTS/catalog.mjs")"; data="$(page_data)"; html="$(cat "$W/catalog/index.html")"
for secret in EXPLAIN-QUOTE-CANARY EXPLAIN-WHO-CANARY U0SECRETUSER "my boss asked"; do
  case "$html" in (*"$secret"*) echo "  a request's words or its requester reached the page in the agent's text: $secret"; FAILED=1;; esac
done
assert "the agent's text that quotes a request is dropped, the rest kept, a note says so" '[.runs[] | select(.type == "regression" and .build == "c2" and .verdict != "environment")][0]
  | (.analysis.summary == null and .analysis.problems[0].why == "The new build moved it." and ([.entries[] | select(.key == "issue-42/AC-1")][0] | has("why") | not))' "$data"
assert "a note counts the dropped texts" '.notes | any(test("^2 text\\(s\\) of the agent.s analysis left out"))' "$out"
# The mark on a still (docs/reporting.md → The mark): the test's marked still wins and is framed in a
# cached copy; else the agent's `mark` frames the AC still; with neither, the plain still and no copy.
mkdir -p "$W/suite/.e2e/runs/cand/artifacts/a"
for f in s1 s2; do node --input-type=module -e "import { encodePng } from '$SCRIPTS/lib/shot-mark.mjs'; import { writeFileSync } from 'node:fs';
writeFileSync('$W/suite/.e2e/runs/cand/artifacts/a/$f.png', encodePng({ w: 20, h: 20, bpp: 3, color: 2, px: Buffer.alloc(1200, 255) }));"; done
cat > "$W/suite/.e2e/runs/cand/report.json" <<'J'
{"run":{"results":[{"tags":["issue-42","ac-1"],"status":"failed","attempts":[{"artifacts":[{"id":"1","kind":"screenshot","path":"a/s1.png"},{"id":"2","kind":"screenshot","path":"a/s2.png"}],
 "steps":[{"api":"app.screenshot","label":"AC-1: the page","artifacts":["1"]},{"api":"app.screenshot","label":"AC-1: the failing check [mark 2,2,5,5]","artifacts":["2"]}]}]}]}}
J
node "$SCRIPTS/catalog.mjs" >/dev/null; data="$(page_data)"
assert "the test's mark wins" '(.items[] | select(.key == "issue-42/AC-1") | .marked == "test" and .mark_saw == null)' "$data"
[ "$(ls "$W/catalog/thumbs" | grep -c '^issue-42-ac-1\.mark-[0-9a-f]*\.png$')" = 1 ] || { echo "  the framed copy of the still is not cached"; FAILED=1; }
jq '.run.results[0].attempts[0].steps |= .[:1]' "$W/suite/.e2e/runs/cand/report.json" > "$W/r.tmp" && mv "$W/r.tmp" "$W/suite/.e2e/runs/cand/report.json"
jq '.acs[0].mark = {box: {x: 1, y: 1, w: 4, h: 4}, saw: "The <b>Chat</b> control shows."}' "$W/issues/42/verdicts-abc-c1.json" > "$W/v.tmp" && mv "$W/v.tmp" "$W/issues/42/verdicts-abc-c1.json"
node "$SCRIPTS/catalog.mjs" >/dev/null; data="$(page_data)"
assert "else the agent's mark, with its sentence" '(.items[] | select(.key == "issue-42/AC-1") | .marked == "agent" and .mark_saw == "The <b>Chat</b> control shows.")' "$data"
[ "$(ls "$W/catalog/thumbs" | grep -c '^issue-42-ac-1\.mark-')" = 1 ] || { echo "  the stale framed copy was kept"; FAILED=1; }
jq 'del(.acs[0].mark)' "$W/issues/42/verdicts-abc-c1.json" > "$W/v.tmp" && mv "$W/v.tmp" "$W/issues/42/verdicts-abc-c1.json"
node "$SCRIPTS/catalog.mjs" >/dev/null; data="$(page_data)"
assert "no mark: the plain still" '(.items[] | select(.key == "issue-42/AC-1") | .marked == null)' "$data"
ls "$W/catalog/thumbs" | grep -q '\.mark-' && { echo "  a framed copy without its mark was kept"; FAILED=1; }
# A test's frame that cannot be drawn (its box is off the still): the agent's mark, else the plain still.
cat > "$W/suite/.e2e/runs/cand/report.json" <<'J'
{"run":{"results":[{"tags":["issue-42","ac-1"],"status":"failed","attempts":[{"artifacts":[{"id":"1","kind":"screenshot","path":"a/s1.png"},{"id":"2","kind":"screenshot","path":"a/s2.png"}],
 "steps":[{"api":"app.screenshot","label":"AC-1: the page","artifacts":["1"]},{"api":"app.screenshot","label":"AC-1: the failing check [mark 50,50,2,2]","artifacts":["2"]}]}]}]}}
J
node "$SCRIPTS/catalog.mjs" >/dev/null; data="$(page_data)"
assert "an undrawn test frame: the plain still, not marked" '(.items[] | select(.key == "issue-42/AC-1") | .marked == null)' "$data"
jq '.acs[0].mark = {box: {x: 1, y: 1, w: 4, h: 4}, saw: "The Chat control shows."}' "$W/issues/42/verdicts-abc-c1.json" > "$W/v.tmp" && mv "$W/v.tmp" "$W/issues/42/verdicts-abc-c1.json"
node "$SCRIPTS/catalog.mjs" >/dev/null; data="$(page_data)"
assert "an undrawn test frame: the agent's mark is tried" '(.items[] | select(.key == "issue-42/AC-1") | .marked == "agent")' "$data"
exit $FAILED
