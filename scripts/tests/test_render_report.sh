#!/usr/bin/env bash
# render-report.mjs: every tested AC gets its video and captioned screenshot, and the header counts how
# many were tested; the setup test never appears;
# explorations and intent tests render apart from the verdict, and a verdicts file without them renders as before;
# noticed-in-passing items are listed outside the verdict; a baseline blocked reason and a
# regression's build interval are shown; a video with step times holds after each step (a stub page); a scenario's evidence is found by its own tag and
# carries the judge's reading, and a verified scenario is refused; proof.json names the
# screenshots behind each verdict on the sides that decide it, and evidence-sheet.mjs draws them
# from the report's media/ alone, or says why there is no picture.
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
R="$SANDBOX/runs"
mk_run() { # <label> <ac-1 status> [owner tag]
  local d="$R/$1/artifacts/web/t1/default/attempt-0"
  mkdir -p "$d/video" "$d/screenshots" "$R/$1/artifacts/web/setup/default/attempt-0/video"
  printf 'webm' > "$d/video/video.webm"; printf 'png' > "$d/screenshots/001-AC-1.png"
  printf 'webm' > "$R/$1/artifacts/web/setup/default/attempt-0/video/video.webm"
  cat > "$R/$1/report.json" <<J
{"run":{"results":[
 {"titlePath":["the owner signs in"],"tags":[],"status":"passed","attempts":[{"artifacts":[{"id":"s:0","kind":"video","path":"web/setup/default/attempt-0/video/video.webm","producer":{"kind":"attempt"}}],"steps":[]}]},
 {"titlePath":["#42 AC-1: renamed"],"tags":["${3:-issue-42}","ac-1"],"status":"$2","attempts":[{"durationMs":900,
  "error":$( [ "$2" = failed ] && echo '{"code":"ASSERTION_FAILED","message":"expected visible"}' || echo null ),
  "artifacts":[{"id":"a:0","kind":"screenshot","path":"web/t1/default/attempt-0/screenshots/001-AC-1.png","producer":{"kind":"step","stepId":"x:1"}},
               {"id":"a:1","kind":"video","path":"web/t1/default/attempt-0/video/video.webm","producer":{"kind":"attempt"}}],
  "steps":[{"id":"x:0","api":"app.open","label":"/","status":"passed","durationMs":10,"artifacts":[]},
           {"id":"x:1","api":"app.screenshot","label":"AC-1: the renamed agent","status":"passed","durationMs":20,"artifacts":["a:0"]}]}]}]}}
J
}
mk_run cand passed; mk_run base failed
cat > "$SANDBOX/v.json" <<'J'
{"issue":42,"title":"Rename <b>","ac_hash":"abc","candidate":"c1","baseline":"b1","candidate_run":"cand","baseline_run":"base",
 "verdict":"verified","acs":[{"id":"AC-1","name":"renamed","quote":"A renamed project keeps its tasks.","then":"the new name shows","testable":true,"verdict":"verified","baseline_blocked_reason":"absent"},
 {"id":"AC-2","name":"internal","testable":false,"verdict":"not-testable"}],
 "open_questions":[{"id":"Q-1","ac":"AC-2","question":"Does an editor rename a project?",
   "variants":[{"source":"the issue","quote":"the owner renames it"},{"source":"a comment of 2026-10-20","quote":"an editor renames it"}]}]}
J
# The target repository: an AC names its source issue and links it (docs/reporting.md).
printf -- '- target_repo: acme/widgets\n' > "$WORK_DIR/CONFIG.md"
out="$(QI_RUNS_ROOT="$R" node "$SCRIPTS/render-report.mjs" "$SANDBOX/v.json" "$SANDBOX/out")"
assert "two videos, two screenshots" '.videos == 2 and .screenshots == 2' "$out"
h="$(cat "$SANDBOX/out/index.html")"
case "$h" in *'<a href="https://github.com/acme/widgets/issues/42"'*'#42</a> AC-1 — renamed'*) ;; *) echo "  an AC does not link its source issue"; FAILED=1;; esac
case "$h" in *'id="zoom"'*'data-z="in"'*'Enlarge the video'*) ;; *) echo "  the in-page viewer of screenshots and videos is missing"; FAILED=1;; esac
case "$h" in *'target="_blank"'*|*'<a href="media/'*'<img'*) echo "  a screenshot links its file (a strict viewer opens an empty page, the file downloads)"; FAILED=1;; esac
case "$h" in *'From the source</b> “A renamed project keeps its tasks.”'*) ;; *) echo "  an AC does not quote its source"; FAILED=1;; esac
case "$h" in *'Open questions (1)'*'Q-1'*'Does an editor rename a project?'*'the owner renames it'*'an editor renames it'*) ;; *) echo "  the open questions are missing"; FAILED=1;; esac
case "$h" in *'<video controls'*'poster="media/'*) ;; *) echo "  no video with a poster"; FAILED=1;; esac
case "$h" in *'AC-1: the renamed agent'*) ;; *) echo "  screenshot caption missing"; FAILED=1;; esac
case "$h" in *'Rename &lt;b&gt;'*) ;; *) echo "  title not escaped"; FAILED=1;; esac
case "$h" in *ASSERTION_FAILED*) ;; *) echo "  baseline error missing"; FAILED=1;; esac
[ "$(ls "$SANDBOX/out/media" | wc -l | tr -d ' ')" = 4 ] || { echo "  expected exactly the two AC-1 videos and screenshots (setup test must not be published)"; FAILED=1; }
grep -q '| AC-1 | renamed | passed | failed | verified |' "$SANDBOX/out/comment.md" || { echo "  comment row missing"; FAILED=1; }
grep -q 'criteria ac=abc · 1 of 2 criteria tested$' "$SANDBOX/out/comment.md" || { echo "  comment: tested count missing (a not-testable AC is not tested)"; FAILED=1; }
case "$h" in *'1 of 2 criteria tested'*) ;; *) echo "  page: tested count missing"; FAILED=1;; esac
case "$h" in *'the function is not there'*) ;; *) echo "  baseline blocked reason not rendered"; FAILED=1;; esac
# Backward compatibility: no "explorations" field → no section, no comment line, no new output keys.
assert "no exploration keys without explorations" 'has("explorations") | not' "$out"
case "$h" in *'Beyond the criteria'*) echo "  explorations section rendered without explorations"; FAILED=1;; esac
grep -q 'beyond the criteria' "$SANDBOX/out/comment.md" && { echo "  explorations comment line without explorations"; FAILED=1; }

# Step times: with the video's start and every step's own, the video carries each step's
# [start, end] in seconds, and the viewer pauses after each step; without them it plays as recorded.
case "$h" in *'data-steps='*) echo "  data-steps without step times"; FAILED=1;; esac
case "$h" in *'Pause after each step'*) ;; *) echo "  the pause after each step is missing from the viewer"; FAILED=1;; esac
cp -R "$R/cand" "$R/cand-t"
jq '(.run.results[1].attempts[0].artifacts[] | select(.kind == "video")).startedAt = "2026-10-27T10:00:00.000Z"
  | .run.results[1].attempts[0].steps[0].startedAt = "2026-10-27T10:00:00.100Z"
  | .run.results[1].attempts[0].steps[1].startedAt = "2026-10-27T10:00:01.500Z"' "$R/cand/report.json" > "$R/cand-t/report.json"
jq '.candidate_run = "cand-t"' "$SANDBOX/v.json" > "$SANDBOX/v-t.json"
QI_RUNS_ROOT="$R" node "$SCRIPTS/render-report.mjs" "$SANDBOX/v-t.json" "$SANDBOX/out-t" >/dev/null
grep -q 'data-steps="\[\[0.1,0.11\],\[1.5,1.52\]\]"' "$SANDBOX/out-t/index.html" || { echo "  the candidate video does not carry its step times"; FAILED=1; }
[ "$(grep -o 'data-steps=' "$SANDBOX/out-t/index.html" | wc -l | tr -d ' ')" = 1 ] || { echo "  the baseline video without step times carries them"; FAILED=1; }

# The player's holds, on a stub page: a hold names the step and says the video continues; with the
# box off and on again, a passed hold does not come back; at the end, the caption does not promise more.
hold="$(node --input-type=module -e '
import vm from "node:vm";
const { VIEWER_HTML } = await import(process.argv[1]);
const src = VIEWER_HTML.split("<script>")[1].split("</script>")[0];
const on = () => { const l = {}; return { l, addEventListener: (k, f) => (l[k] ??= []).push(f), fire: (k) => (l[k] ?? []).forEach((f) => f({})) }; };
const node = (tag) => { const n = { tagName: tag, ...on(), children: [], dataset: {}, textContent: "", cls: new Set(),
  setAttribute() {}, append(...c) { n.children.push(...c); }, after(c) { n.next = c; }, insertBefore() {}, querySelector: () => node("SPAN"), querySelectorAll: () => [] };
  n.classList = { toggle: (c, b) => (b ? n.cls.add(c) : n.cls.delete(c)), contains: (c) => n.cls.has(c) || String(n.className ?? "").split(" ").includes(c) };
  Object.defineProperty(n, "nextElementSibling", { get: () => n.next }); return n; };
const items = [1, 2, 3].map((k) => { const li = node("LI"); li.textContent = "step " + k; li.cloneNode = () => ({ ...li, querySelectorAll: () => [] }); return li; });
const v = node("VIDEO"); v.dataset.steps = "[[0,1],[1,2],[2,3]]"; v.duration = 10; v.currentTime = 0; v.paused = false;
v.pause = () => { v.paused = true; }; v.play = () => { v.paused = false; };
v.closest = () => ({ querySelectorAll: () => items });
const doc = { ...on(), getElementById: () => node("DIV"), createElement: node, createComment: node, activeElement: null,
  querySelectorAll: (q) => (q.includes("video") ? [v] : []) };
vm.runInNewContext(src, { document: doc, addEventListener() {}, requestAnimationFrame() {}, setTimeout: () => 1, clearTimeout() {}, Map, JSON, Math, Array, Infinity });
const bar = v.next, now = bar.children[0], cb = bar.children[1].children[0];
const at = (t) => { v.currentTime = t; v.fire("timeupdate"); };
const out = [];
at(1.35); out.push(v.paused, now.textContent);
cb.checked = false; cb.fire("change"); at(2.5); out.push(v.paused);
cb.checked = true; cb.fire("change"); at(2.6); out.push(v.paused);
v.paused = true; v.fire("ended"); out.push(now.textContent);
console.log(JSON.stringify(out));
' "$SCRIPTS/lib/media-viewer.mjs" 2>&1)"
[ "$hold" = '[true,"Step 1 of 3 done: step 1 — the video continues in a moment",false,false,"Step 3 of 3 done: step 3"]' ] \
  || { echo "  the player's holds: $hold"; FAILED=1; }

# proof.json: a verified AC shows baseline and candidate, a not-testable one nothing; it stays out of media/.
pf="$(cat "$SANDBOX/out/proof.json")"
assert "proof: the verified AC on both sides, from media/" '.mode == "issue" and .subject == "#42" and (.rows | length) == 1 and .rows[0].id == "AC-1"
  and ([.rows[0].shots[].side] == ["baseline","candidate"]) and ([.rows[0].shots[].state] == ["failed","passed"])
  and all(.rows[0].shots[]; (.src | startswith("media/")) and (.caption | startswith("AC-1:"))) and .left_out == 0' "$pf"
assert "render-report counts the proof rows" '.proof == 1' "$out"

# evidence-sheet.mjs: no proof.json is an error; no browser, no screen to show or a src outside
# media/ is no picture, with the reason, and never a stale one.
node "$SCRIPTS/evidence-sheet.mjs" "$SANDBOX/nothing" >/dev/null; assert_eq "evidence-sheet: no proof.json" 1 "$?"
es="$(node "$SCRIPTS/evidence-sheet.mjs" "$SANDBOX/out")"
assert "evidence-sheet: no playwright-core, no picture" '.sheet == null and .rows == 1 and (.reason | startswith("unavailable"))' "$es"
cp -R "$SANDBOX/out" "$SANDBOX/out-es"; printf 'stale' > "$SANDBOX/out-es/evidence.png"
jq '.rows[0].shots |= map(.src = "../../outside.png")' "$SANDBOX/out/proof.json" > "$SANDBOX/out-es/proof.json"
es="$(node "$SCRIPTS/evidence-sheet.mjs" "$SANDBOX/out-es")"
assert "evidence-sheet: a src outside media/ is never read" '.sheet == null and .rows == 0 and (.reason | startswith("no criterion"))' "$es"
[ -f "$SANDBOX/out-es/evidence.png" ] && { echo "  a stale evidence.png survived"; FAILED=1; }

# Error at the check (docs/reporting.md): a pass on a screen that shows an error is blocked, the
# report quotes the message; a baseline that stopped in setup is no red and no longer "inconclusive".
jq '.verdict = "blocked" | .acs[0] += {verdict: "blocked", baseline_blocked_reason: "setup", cause: "environment",
  error_at_check: "the VM runner <cannot> be scheduled"}' "$SANDBOX/v.json" > "$SANDBOX/ve.json"
QI_RUNS_ROOT="$R" node "$SCRIPTS/render-report.mjs" "$SANDBOX/ve.json" "$SANDBOX/oute" >/dev/null
he="$(cat "$SANDBOX/oute/index.html")"
case "$he" in *'Error at the check:</b> “the VM runner &lt;cannot&gt; be scheduled”'*'the pass does not count'*) ;; *) echo "  error at the check not rendered"; FAILED=1;; esac
case "$he" in *'in the test setup. This is not a red, so the test cannot prove the change.'*) ;; *) echo "  setup baseline reason not rendered"; FAILED=1;; esac
case "$he" in *'stays inconclusive'*) echo "  a stopped baseline still claims inconclusive"; FAILED=1;; esac
case "$h" in *'Error at the check'*) echo "  error at the check rendered without error_at_check"; FAILED=1;; esac

# Explorations: their own run, tagged issue-<n>-ex + ex-<k>; candidate only, never in the verdict.
d="$R/expl/artifacts/web/ex1/default/attempt-0"
mkdir -p "$d/video" "$d/screenshots"
printf 'webm' > "$d/video/video.webm"; printf 'png' > "$d/screenshots/001-EX-1.png"
cat > "$R/expl/report.json" <<'J'
{"run":{"results":[
 {"titlePath":["#42 EX-1: a viewer cannot rename"],"tags":["issue-42-ex","ex-1","from-ac-1"],"status":"failed","attempts":[{"durationMs":700,
  "error":{"code":"ASSERTION_FAILED","message":"rename offered to viewer"},
  "artifacts":[{"id":"e:0","kind":"screenshot","path":"web/ex1/default/attempt-0/screenshots/001-EX-1.png","producer":{"kind":"step","stepId":"y:1"}},
               {"id":"e:1","kind":"video","path":"web/ex1/default/attempt-0/video/video.webm","producer":{"kind":"attempt"}}],
  "steps":[{"id":"y:1","api":"app.screenshot","label":"EX-1: the agent page as the viewer","status":"passed","durationMs":20,"artifacts":["e:0"]}]}]},
 {"titlePath":["#42 EX-2: rename survives reload"],"tags":["issue-42-ex","ex-2","from-ac-1"],"status":"passed","attempts":[{"durationMs":500,"artifacts":[],"steps":[]}]}]}}
J
jq '. + {explorations_run: "expl", ex_hash: "e0e0e0e0e0e0", explorations: [
  {id:"EX-1", from_ac:"AC-1", heuristic:"roles-isolation", given:"a viewer", when:"opens the agent", expected:"no rename <action>", surface:"ui", verdict:"observation", severity:"major", note:"confirmed 3/3"},
  {id:"EX-2", from_ac:"AC-1", heuristic:"persistence", given:"a renamed agent", when:"reload", expected:"new name stays", surface:"ui", verdict:"observed-ok", severity:null}]}' \
  "$SANDBOX/v.json" > "$SANDBOX/vx.json"
out="$(QI_RUNS_ROOT="$R" node "$SCRIPTS/render-report.mjs" "$SANDBOX/vx.json" "$SANDBOX/outx")"
assert "explorations counted apart from the ACs" '.videos == 2 and .screenshots == 2 and .explorations == 2 and .observations == 1 and .exploration_videos == 1' "$out"
hx="$(cat "$SANDBOX/outx/index.html")"
case "$hx" in *'Beyond the criteria'*'Not part of the verdict'*) ;; *) echo "  explorations section or its label missing"; FAILED=1;; esac
case "$hx" in *'rename offered to viewer'*'EX-1: the agent page as the viewer'*) ;; *) echo "  EX evidence missing"; FAILED=1;; esac
case "$hx" in *'no rename &lt;action&gt;'*) ;; *) echo "  EX expected not escaped"; FAILED=1;; esac
case "$hx" in *'<h1>#42 — Rename &lt;b&gt;</h1><span class="badge ok">Verified</span>'*) ;; *) echo "  an observation changed the issue verdict"; FAILED=1;; esac
[ "$(ls "$SANDBOX/outx/media" | wc -l | tr -d ' ')" = 6 ] || { echo "  expected the AC media plus EX-1's video and screenshot"; FAILED=1; }
grep -qx '2 explorations beyond the criteria: 1 observations (see evidence)' "$SANDBOX/outx/comment.md" || { echo "  explorations comment line missing"; FAILED=1; }
[ "$(grep -c 'EX-' "$SANDBOX/outx/comment.md")" = 0 ] || { echo "  the comment must not list explorations"; FAILED=1; }

# Intent tests (docs/intent.md): red-green like a criterion, found by issue-<n> + in-<k> in the same
# runs; their own section and comment line; never the issue verdict. Here IN-1 fails on the
# candidate while every AC is verified: the letter holds, the goal does not.
for side in cand base; do
  jq '.run.results += [{"titlePath":["#42 IN-1: the next answer comes from Fast"],"tags":["issue-42","in-1"],"status":"failed","attempts":[{"durationMs":800,
    "error":{"code":"ASSERTION_FAILED","message":"answer names Default"},"artifacts":[],"steps":[]}]}]' "$R/$side/report.json" > "$R/$side/r.tmp" && mv "$R/$side/r.tmp" "$R/$side/report.json"
done
jq '. + {intent_verdict: "not-met", intents: [{id:"IN-1", name:"the next answer comes from <Fast>", goal:"so that answers come faster", given:"a conversation", when:"pick Fast, then ask", then:"the answer names Fast", covers:["AC-1"], surface:"ui", testable:true, verdict:"failed", baseline_blocked_reason:null}]}' \
  "$SANDBOX/v.json" > "$SANDBOX/vi.json"
out="$(QI_RUNS_ROOT="$R" node "$SCRIPTS/render-report.mjs" "$SANDBOX/vi.json" "$SANDBOX/outi")"
assert "intents counted apart from the ACs" '.acs == 2 and .intents == 1 and .intent_verdict == "not-met"' "$out"
hi="$(cat "$SANDBOX/outi/index.html")"
case "$hi" in *'What the author wanted — intent not met'*'Not part of the verdict'*'The criteria are true, but the goal is not met'*) ;; *) echo "  intent section, its label or the letter-not-goal line missing"; FAILED=1;; esac
case "$hi" in *'answer names Default'*) ;; *) echo "  IN evidence missing"; FAILED=1;; esac
case "$hi" in *'from &lt;Fast&gt;'*'<b>Goal</b> so that answers come faster'*) ;; *) echo "  IN name not escaped or goal missing"; FAILED=1;; esac
case "$hi" in *'<h1>#42 — Rename &lt;b&gt;</h1><span class="badge ok">Verified</span>'*) ;; *) echo "  an intent test changed the issue verdict"; FAILED=1;; esac
grep -qx 'Intent (what the author wanted): not met — IN-1 failed. The criteria are true, but the goal is not met.' "$SANDBOX/outi/comment.md" || { echo "  intent comment line missing"; FAILED=1; }
grep -q '| IN-1 |' "$SANDBOX/outi/comment.md" && { echo "  the AC table must not list intent tests"; FAILED=1; }
assert "no intent keys without intents" 'has("intents") | not' "$(QI_RUNS_ROOT="$R" node "$SCRIPTS/render-report.mjs" "$SANDBOX/v.json" "$SANDBOX/out-noin")"
case "$(cat "$SANDBOX/out-noin/index.html")" in *'What the author wanted'*) echo "  intent section rendered without intents"; FAILED=1;; esac
jq '. + {intent_verdict: "none", intents: []}' "$SANDBOX/v.json" > "$SANDBOX/vn.json"
QI_RUNS_ROOT="$R" node "$SCRIPTS/render-report.mjs" "$SANDBOX/vn.json" "$SANDBOX/outn" >/dev/null
case "$(cat "$SANDBOX/outn/index.html")" in *'intent none'*'states no purpose beyond its criteria'*) ;; *) echo "  intent none not rendered"; FAILED=1;; esac
grep -qx 'Intent (what the author wanted): none' "$SANDBOX/outn/comment.md" || { echo "  intent none comment line missing"; FAILED=1; }

# Noticed in passing: listed with its screenshot, escaped, counted once in the comment, never in the verdict.
printf 'png' > "$SANDBOX/noticed.png"
jq --arg shot "$SANDBOX/noticed.png" '. + {noticed: [{where: "/settings", saw: "a 500 <error> page after saving", shot: $shot}, {where: "the agent list", saw: "the count is off by one", shot: null}]}' \
  "$SANDBOX/v.json" > "$SANDBOX/vn.json"
out="$(QI_RUNS_ROOT="$R" node "$SCRIPTS/render-report.mjs" "$SANDBOX/vn.json" "$SANDBOX/outn")"
assert "noticed counted apart" '.noticed == 2 and .videos == 2' "$out"
hn="$(cat "$SANDBOX/outn/index.html")"
case "$hn" in *'Noticed in passing'*'Not tested, not part of the verdict'*'a 500 &lt;error&gt; page'*'media/noticed-1-noticed.png'*) ;; *) echo "  noticed section, label, escaping or screenshot missing"; FAILED=1;; esac
case "$hn" in *'<span class="badge ok">Verified</span>'*) ;; *) echo "  a noticed item changed the issue verdict"; FAILED=1;; esac
grep -qx '2 noticed in passing, not tested (see evidence)' "$SANDBOX/outn/comment.md" || { echo "  noticed comment line missing"; FAILED=1; }
grep -q '500' "$SANDBOX/outn/comment.md" && { echo "  the comment must not list what was noticed"; FAILED=1; }
case "$h" in *'Noticed in passing'*) echo "  noticed section rendered without noticed items"; FAILED=1;; esac

# Regression mode: signals no test covers are listed under "What changed", escaped, with the new map's screenshot.
printf 'png' > "$SANDBOX/settings.png"
cat > "$SANDBOX/r.json" <<J
{"mode":"regression","candidate":"c2","candidate_run":"cand","verdict":"needs-review","acs":[],
 "context":{"previous":"c1","issues":[],"ui_diff":"No UI change between the two builds.","signals":{
  "console_errors_new":[{"route":"/settings","errors":["Error: <img onerror=x>"],"shot":"$SANDBOX/settings.png","verdict":"needs-review","explanation":"absent on c1"}],
  "failed_requests_new":[{"route":"/settings","requests":[{"method":"POST","path":"/api/keys/:id","status":500}],"verdict":"needs-review"}],
  "slower_pages":[],"slow_tests":[{"title":"#1 AC-1: slow","latest_ms":9000,"median_ms":4000,"verdict":"needs-review","explanation":"took 9000 ms, 2.3x its median of 4000 ms"}]}}}
J
QI_RUNS_ROOT="$R" node "$SCRIPTS/render-report.mjs" "$SANDBOX/r.json" "$SANDBOX/rout" >/dev/null
h="$(cat "$SANDBOX/rout/index.html")"
case "$h" in *'Signals no test covers'*'Error: &lt;img onerror=x&gt;'*'media/signal-1-settings.png'*'POST /api/keys/:id → 500'*'took 9000 ms'*) ;; *) echo "  signals list missing or unescaped"; FAILED=1;; esac
case "$h" in *'<img onerror'*) echo "  signal text not escaped"; FAILED=1;; esac
[ -f "$SANDBOX/rout/media/signal-1-settings.png" ] || { echo "  signal screenshot not copied"; FAILED=1; }
[ -f "$SANDBOX/rout/proof.json" ] && { echo "  a regression run's report wrote proof.json"; FAILED=1; }

# Regression mode: a reworked criterion has its own badge.
echo '{"mode":"regression","candidate":"c2","candidate_run":"cand","verdict":"unchanged","context":{"previous":"c1","issues":[]},"acs":[{"issue":42,"id":"AC-1","name":"n","then":"t","verdict":"reworked","explanation":"#3810 replaces the channel ID field"}]}' > "$SANDBOX/rw.json"
QI_RUNS_ROOT="$R" node "$SCRIPTS/render-report.mjs" "$SANDBOX/rw.json" "$SANDBOX/rwout" >/dev/null
grep -q 'UI changed · steps rewritten' "$SANDBOX/rwout/index.html" || { echo "  the reworked badge is missing"; FAILED=1; }

# Regression mode: a confirmed regression's build interval and the interface diff.
cat > "$SANDBOX/r2.json" <<'J'
{"mode":"regression","candidate":"c2","candidate_run":"cand","verdict":"regression",
 "context":{"previous":"c1","issues":[],"iface_diff":"- removed flag --force of widgets agents rm"},
 "acs":[{"issue":42,"id":"AC-1","name":"renamed","then":"the new name shows","verdict":"regression",
         "explanation":"passes on c1, fails on c2","regressed_between":{"from":"c1.5","to":"c2","builds_between":0}}],
 "analysis":{"summary":"One <b>regression</b>: the rename does not save.","next":"Send it to the team.","problems":[{"title":"The rename does not save","about":["#42 AC-1"],
   "cause":"product","what":"The new name shows, then the old name.","where":"/projects","why":"PUT /api/projects answered 500.","fix":"The product team repairs the save.","certainty":"high"}]}}
J
QI_RUNS_ROOT="$R" node "$SCRIPTS/render-report.mjs" "$SANDBOX/r2.json" "$SANDBOX/rout2" >/dev/null
h="$(cat "$SANDBOX/rout2/index.html")"
case "$h" in *'Regressed between</b> <code>c1.5</code> (passes) and <code>c2</code> (fails) · adjacent builds'*) ;; *) echo "  regressed_between not rendered"; FAILED=1;; esac
case "$h" in *'removed flag --force'*) ;; *) echo "  interface diff not rendered"; FAILED=1;; esac
# The agent's analysis (docs/reporting.md → The agent's analysis): above the table, escaped.
case "$h" in *'What the agent found'*'One &lt;b&gt;regression'*'Product defect'*'The rename does not save'*'Probable cause</dt><dd>PUT /api/projects answered 500. (certainty: high)'*'How to repair it'*'Next step:</b> Send it to the team.'*'<table>'*) ;; *) echo "  the agent's analysis missing, unescaped or below the table"; FAILED=1;; esac
grep -q 'What the agent found' "$SANDBOX/rout/index.html" && { echo "  a report without an analysis shows the section"; FAILED=1; }

# Scenario mode: tests tagged scenario-<k>, the judge's reading, the channel reply as comment.md.
mk_run s-cand failed scenario-7; mk_run s-base passed scenario-7
cat > "$SANDBOX/s.json" <<'J'
{"mode":"scenario","scenario":"S-7","title":"Export the usage table","source":"slack","spec_hash":"def","candidate":"c1","baseline":"b1",
 "candidate_run":"s-cand","baseline_run":"s-base","verdict":"regression",
 "acs":[{"id":"AC-1","name":"csv downloads","then":"a CSV file downloads","testable":true,"verdict":"regression",
         "judge":{"agree":true,"call":"product-defect","reason":"the AC-1 screenshot shows no download"}}]}
J
out="$(QI_RUNS_ROOT="$R" node "$SCRIPTS/render-report.mjs" "$SANDBOX/s.json" "$SANDBOX/s-out")"
assert "scenario: both sides found by the scenario tag" '.videos == 2 and .screenshots == 2' "$out"
h="$(cat "$SANDBOX/s-out/index.html")"
case "$h" in *'S-7 — Export the usage table'*) ;; *) echo "  scenario title missing"; FAILED=1;; esac
case "$h" in *'agrees (product-defect)'*) ;; *) echo "  judge reading missing"; FAILED=1;; esac
case "$h" in *'Open questions'*) echo "  open questions rendered without open_questions"; FAILED=1;; esac
grep -q '^• AC-1 csv downloads — regression$' "$SANDBOX/s-out/comment.md" || { echo "  scenario reply line missing"; FAILED=1; }
assert "scenario proof: a regression shows the last release passing and the build failing" '.mode == "scenario" and .subject == "S-7"
  and ([.rows[0].shots[] | [.side, .state, .build]] == [["baseline","passed","b1"],["candidate","failed","c1"]])' "$(cat "$SANDBOX/s-out/proof.json")"

# A profile scenario: evidence by its profile-<slug> tag, the request shown verbatim from its
# source-<spec_hash>.md; a request_file outside work/scenarios/ is never read.
mk_run p-cand passed profile-sign-in
mkdir -p "$WORK_DIR/scenarios/P-sign-in"
printf '# Sign-in\nWhen the owner signs in <b>now</b>\n' > "$WORK_DIR/scenarios/P-sign-in/source-abc.md"
cat > "$SANDBOX/p.json" <<'J'
{"mode":"scenario","scenario":"P-sign-in","title":"Sign-in","source":"profile","spec_hash":"abc","candidate":"c1",
 "candidate_run":"p-cand","verdict":"passed","request_file":"scenarios/P-sign-in/source-abc.md",
 "acs":[{"id":"AC-1","name":"owner signs in","then":"the dashboard shows","testable":true,"verdict":"passed"}]}
J
out="$(QI_RUNS_ROOT="$R" node "$SCRIPTS/render-report.mjs" "$SANDBOX/p.json" "$SANDBOX/p-out")"
assert "profile scenario: evidence found by the profile tag" '.videos == 1' "$out"
assert "profile scenario proof: a passed AC on the build only" '[.rows[0].shots[].side] == ["candidate"]' "$(cat "$SANDBOX/p-out/proof.json")"
h="$(cat "$SANDBOX/p-out/index.html")"
case "$h" in *'The request, verbatim'*'When the owner signs in &lt;b&gt;now&lt;/b&gt;'*) ;; *) echo "  verbatim request missing or unescaped"; FAILED=1;; esac
echo secret > "$SANDBOX/outside.md"
jq '.request_file = "scenarios/../../outside.md"' "$SANDBOX/p.json" > "$SANDBOX/p-esc.json"
QI_RUNS_ROOT="$R" node "$SCRIPTS/render-report.mjs" "$SANDBOX/p-esc.json" "$SANDBOX/p-esc-out" >/dev/null
case "$(cat "$SANDBOX/p-esc-out/index.html")" in *secret*|*'The request, verbatim'*) echo "  a request_file outside work/scenarios/ was read"; FAILED=1;; esac

# A scenario is never verified: refused before anything is written, the earlier report kept.
jq '.verdict = "passed" | .acs[0].verdict = "verified"' "$SANDBOX/s.json" > "$SANDBOX/s-ver.json"
QI_RUNS_ROOT="$R" node "$SCRIPTS/render-report.mjs" "$SANDBOX/s-ver.json" "$SANDBOX/s-out" >/dev/null 2>&1
assert_eq "a verified scenario AC is refused" 2 "$?"
[ -f "$SANDBOX/s-out/index.html" ] || { echo "  the refused render removed the earlier report"; FAILED=1; }
# A kept Environment (docs/nested-env.md → Kept for a person): where and until when, the account's
# name — never anything that is not an https address.
jq '. + {environment: {url: "https://app-qi-1.env.example", expires_utc: "2026-11-02T10:00:00Z", account: "qa-viewer", password: "pw-secret"}}' "$SANDBOX/v.json" > "$SANDBOX/vk.json"
QI_RUNS_ROOT="$R" node "$SCRIPTS/render-report.mjs" "$SANDBOX/vk.json" "$SANDBOX/outk" >/dev/null
grep -q 'Examine the build yourself' "$SANDBOX/outk/index.html" && grep -q 'href="https://app-qi-1.env.example"' "$SANDBOX/outk/index.html" \
  || { echo "  kept: the page links the Environment"; FAILED=1; }
grep -qx 'Examine the build yourself until 2026-11-02: https://app-qi-1.env.example (account qa-viewer)' "$SANDBOX/outk/comment.md" \
  || { echo "  kept: the comment names it: $(cat "$SANDBOX/outk/comment.md")"; FAILED=1; }
grep -q pw-secret "$SANDBOX/outk/index.html" "$SANDBOX/outk/comment.md" && { echo "  kept: never a password"; FAILED=1; }
jq '. + {environment: {url: "javascript:alert(1)"}}' "$SANDBOX/v.json" > "$SANDBOX/vk2.json"
QI_RUNS_ROOT="$R" node "$SCRIPTS/render-report.mjs" "$SANDBOX/vk2.json" "$SANDBOX/outk2" >/dev/null
grep -q 'Examine the build yourself' "$SANDBOX/outk2/index.html" && { echo "  kept: only an https address is shown"; FAILED=1; }
grep -q 'Examine the build yourself' "$SANDBOX/out/index.html" 2>/dev/null && { echo "  no environment: no section"; FAILED=1; }

exit $FAILED
