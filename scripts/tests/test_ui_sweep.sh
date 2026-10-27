#!/usr/bin/env bash
# UI sweep and the design findings register, offline: the sweep's plan (viewports, skipped
# routes, the localhost guard), the review plan's order, and merge — stable ids, resolution
# and reopening per swept page+viewport, DISMISSED.md, review entries, noticed items.
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
seed_work
D="$WORK_DIR/design"

# ---------------------------------------------------------------- sweep plan (dry run)
cat > "$SANDBOX/inv.json" <<'J'
{"base":"http://localhost:8080","build":"1.2.3","routes":{
  "/":{"example":"/","title":"Home"},
  "/projects/:id":{"example":"/projects/42","title":"Project"},
  "/broken":{"example":"/broken","error":"timeout"},
  "/sso":{"example":"/sso","redirected":"https://idp.example.com"}}}
J
p="$(node "$SCRIPTS/ui-sweep.mjs" "$SANDBOX/inv.json" --build c2 --dry-run)"
assert "default viewports, out under work/design/<build>" '.viewports == ["1440x900","768x1024","390x844"] and (.out | endswith("/design/c2"))' "$p"
assert "pages × viewports, errored and redirected skipped" '(.pages | length) == 6 and ([.pages[].pattern] | unique) == ["/","/projects/:id"] and ([.skipped[].pattern] == ["/broken","/sso"])' "$p"
assert "shot per page and viewport" '[.pages[] | select(.viewport=="390x844") | .shot | split("/") | last] == ["root@390x844.png","projects_id@390x844.png"]' "$p"
assert "base from the map" '.base == "http://localhost:8080"' "$p"
printf -- '- ui_sweep_viewports: 1280x800, 375x667\n' >> "$WORK_DIR/CONFIG.md"
p="$(node "$SCRIPTS/ui-sweep.mjs" "$SANDBOX/inv.json" --build c2 --dry-run --max-pages 1)"
assert "viewports from the config, --max-pages" '.viewports == ["1280x800","375x667"] and (.pages | length) == 2 and (.notes | length) == 1' "$p"
mkdir -p "$SANDBOX/prev/shots" && : > "$SANDBOX/prev/shots/root@1280x800.png"
p="$(node "$SCRIPTS/ui-sweep.mjs" "$SANDBOX/inv.json" --build c2 --dry-run --viewports 1280x800 --previous "$SANDBOX/prev")"
assert "flag beats config; a previous shot is found" '.viewports == ["1280x800"] and (.pages[0].previous_shot | endswith("prev/shots/root@1280x800.png")) and .pages[1].previous_shot == null' "$p"
for bad in 1280x80 12800x800 1x2,3x4 a,b 100x100,200x200,300x300,400x400,500x500; do
  node "$SCRIPTS/ui-sweep.mjs" "$SANDBOX/inv.json" --build c2 --dry-run --viewports "$bad" >/dev/null 2>&1
  assert_eq "invalid viewports '$bad' refused" 2 "$?"
done
node "$SCRIPTS/ui-sweep.mjs" "$SANDBOX/inv.json" --build c2 --dry-run --base http://staging.example.com >/dev/null 2>&1
assert_eq "a non-local base is refused" 2 "$?"
node "$SCRIPTS/ui-sweep.mjs" "$SANDBOX/inv.json" --build ../x --dry-run >/dev/null 2>&1
assert_eq "a build that is not a plain id is refused" 2 "$?"
# --pattern: one page of the map, every viewport (a recheck, docs/ui-sweep.md → Recheck).
p="$(node "$SCRIPTS/ui-sweep.mjs" "$SANDBOX/inv.json" --build c2 --dry-run --pattern /projects/:id --viewports 390x844)"
assert "--pattern sweeps that page only" '[.pages[] | "\(.pattern)@\(.viewport)"] == ["/projects/:id@390x844"]' "$p"
node "$SCRIPTS/ui-sweep.mjs" "$SANDBOX/inv.json" --build c2 --dry-run --pattern /nope >/dev/null 2>&1
assert_eq "a pattern the map does not have is refused" 2 "$?"
[ ! -e "$D/c2" ] || { echo "  a dry run wrote its out dir"; FAILED=1; }

# No browser is the module's failure (exit 3), never the environment's (exit 1: sign-in).
mkdir -p "$SANDBOX/nopw" "$SANDBOX/pw/node_modules/playwright-core"
echo '{"name":"suite"}' > "$SANDBOX/nopw/package.json"; cp "$SANDBOX/nopw/package.json" "$SANDBOX/pw/package.json"
echo '{"name":"playwright-core","main":"index.js"}' > "$SANDBOX/pw/node_modules/playwright-core/package.json"
echo 'module.exports = { chromium: { launch: async () => { throw new Error("Executable does not exist") } } };' > "$SANDBOX/pw/node_modules/playwright-core/index.js"
o="$(QI_PLAYWRIGHT_FROM="$SANDBOX/nopw/package.json" node "$SCRIPTS/ui-sweep.mjs" "$SANDBOX/inv.json" --build c2 --out "$SANDBOX/sw" 2>/dev/null)"
assert_eq "no playwright-core: exit 3" 3 "$?"
assert "no playwright-core: a JSON error" '.error | startswith("no browser: playwright-core")' "$o"
o="$(QI_PLAYWRIGHT_FROM="$SANDBOX/pw/package.json" node "$SCRIPTS/ui-sweep.mjs" "$SANDBOX/inv.json" --build c2 --out "$SANDBOX/sw" 2>/dev/null)"
assert_eq "chromium does not launch: exit 3" 3 "$?"
assert "chromium does not launch: a JSON error" '.error == "no browser: Executable does not exist"' "$o"
[ ! -e "$SANDBOX/sw" ] || { echo "  a sweep without a browser wrote its out dir"; FAILED=1; }

# ---------------------------------------------------------------- review plan
S1="$D/b1"; mkdir -p "$S1/shots"
cat > "$S1/sweep.json" <<'J'
{"build":"b1","generated_utc":"2026-10-20T03:00:00Z","base":"http://localhost:8080","viewports":["1440x900","390x844"],"axe":false,
 "pages":[
  {"pattern":"/","example":"/","viewport":"1440x900","shot":"shots/root@1440x900.png","changed":false,"cls":0,"findings":[
    {"check":"clipped-text","severity":"minor","target":"“Save changes” button","text":"Save changes","box":{"x":10,"y":20,"w":80,"h":30},"detail":"its text is 12px wider than its box"}]},
  {"pattern":"/","example":"/","viewport":"390x844","shot":"shots/root@390x844.png","changed":true,"diff":0.031,"cls":0.2,"findings":[
    {"check":"overflow-x","severity":"major","target":"the page","text":"","box":{"x":0,"y":0,"w":420,"h":844},"detail":"the page is 420px wide in a 390px viewport"},
    {"check":"tap-target","severity":"minor","target":"unnamed link to /settings","text":"","box":{"x":360,"y":10,"w":16,"h":16},"detail":"16×16px, below 24×24px"}]},
  {"pattern":"/projects/:id","example":"/projects/42","viewport":"1440x900","shot":"shots/projects_id@1440x900.png","changed":null,"cls":0,"findings":[]},
  {"pattern":"/projects/:id","example":"/projects/42","viewport":"390x844","shot":"shots/projects_id@390x844.png","changed":false,"cls":0,"findings":[
    {"check":"contrast","severity":"minor","target":"“Last edited 3 days ago” span","text":"","box":{"x":5,"y":5,"w":50,"h":10},"detail":"contrast 2.10:1, needs 4.5:1 (#aaaaaa on #ffffff)"},
    {"check":"no-name","severity":"major","target":"unnamed button in navigation “Main”","text":"","box":{"x":1,"y":1,"w":30,"h":30},"detail":"no aria-label"},
    {"check":"no-name","severity":"major","target":"unnamed button in navigation “Main”","text":"","box":{"x":40,"y":1,"w":30,"h":30},"detail":"no aria-label"}]},
  {"pattern":"/err","example":"/err","viewport":"1440x900","shot":null,"changed":null,"error":"timeout","findings":[]}],
 "counts":{"major":3,"minor":3,"pages":5},"notes":[]}
J
r="$(node "$SCRIPTS/design-findings.mjs" review-plan "$S1/sweep.json")"
assert "changed first, then new, then most findings; errored page left out" '[.[] | "\(.pattern)@\(.viewport)"] == ["/@390x844","/projects/:id@1440x900","/projects/:id@390x844","/@1440x900"]' "$r"
assert "reasons and absolute shots" '(.[0].reason | test("changed")) and (.[1].reason | test("new")) and (.[2].reason | test("3 findings")) and (.[0].shot | startswith("/"))' "$r"
assert "--max 0 -> empty" '. == []' "$(node "$SCRIPTS/design-findings.mjs" review-plan "$S1/sweep.json" --max 0)"
printf -- '- ui_sweep_review_pages: 2\n' >> "$WORK_DIR/CONFIG.md"
assert "max from the config" 'length == 2' "$(node "$SCRIPTS/design-findings.mjs" review-plan "$S1/sweep.json")"

# ---------------------------------------------------------------- merge
mkdir -p "$WORK_DIR/issues/12" "$WORK_DIR/scenarios/S-3"
cat > "$WORK_DIR/issues/12/verdicts-abc-b1.json" <<'J'
{"verdicts":[{"ac":"AC-1","verdict":"verified","notes":"SECRET-NOTE-TEXT"}],"note":"SECRET-NOTE-TOO",
 "noticed":[{"where":"/projects/:id","saw":"The project list shows NaN items","shot":null,"notes":"SECRET-ITEM-NOTE"}]}
J
cat > "$WORK_DIR/scenarios/S-3/verdicts-def-b1.json" <<'J'
{"notes":["SECRET-SCENARIO-NOTE"],"noticed":[{"where":"/settings","saw":"Footer overlaps the Save button","shot":"shot.png"},{"where":"","saw":"no where"}]}
J
: > "$WORK_DIR/scenarios/S-3/shot.png"
echo '{"noticed":[{"where":"/judge","saw":"never read"}]}' > "$WORK_DIR/scenarios/S-3/judge-verdict-def-b1.json"
cat > "$SANDBOX/review.json" <<'J'
[{"pattern":"/","viewport":"1440x900","check":"review:alignment","severity":"minor","saw":"The header buttons sit 4px lower than the title","box":{"x":100,"y":10,"w":200,"h":40},"confidence":0.9},
 {"pattern":"/","viewport":"390x844","check":"review:legibility","severity":"major","saw":"Grey text on grey card","box":null,"confidence":0.4},
 {"pattern":"/","viewport":"1440x900","check":"alignment","severity":"minor","saw":"bad prefix","box":null,"confidence":0.9},
 {"pattern":"/","viewport":"1440x900","check":"review:vibes","severity":"minor","saw":"not in the rubric","box":null,"confidence":0.9},
 {"pattern":"/","viewport":"1440x900","check":"review:spacing","severity":"blocker","saw":"bad severity","box":null,"confidence":0.9},
 {"pattern":"/","viewport":"1440x900","check":"review:spacing","severity":"minor","saw":"no confidence","box":null},
 {"pattern":"/nope","viewport":"1440x900","check":"review:spacing","severity":"minor","saw":"not swept","box":null,"confidence":0.9}]
J
m="$(node "$SCRIPTS/design-findings.mjs" merge "$S1/sweep.json" --review "$SANDBOX/review.json" --no-render)"
reg="$(cat "$D/findings.json")"
assert "first merge: 5 sweep (one deduped) + 2 review + 2 noticed" '.findings == 9 and .new == 9 and .open == 9 and .crops == 0' "$m"
assert "five review entries rejected with a note each" '[.notes[] | select(test("rejected"))] | length == 5' "$m"
assert "the bad prefix is named" '[.notes[] | select(test("check .alignment."))] | length == 1' "$m"
assert "register shape" '.schema == "qi-design/v1" and .next_id == 10 and ([.findings[].id] == ["D-1","D-2","D-3","D-4","D-5","D-6","D-7","D-8","D-9"]) and (.findings[0] | has("fingerprint","source","check","severity","suspect","pattern","viewport","target","saw","box","shot","crop","first_seen","last_seen","status","resolved_build"))' "$reg"
assert "fingerprints are 12 hex" 'all(.findings[]; .fingerprint | test("^[0-9a-f]{12}$"))' "$reg"
assert "a sentence for a sweep finding" '.findings[0].saw == "Text of “Save changes” button is clipped (its text is 12px wider than its box)" and .findings[0].shot == "design/b1/shots/root@1440x900.png"' "$reg"
assert "review: source, suspect from confidence" '[.findings[] | select(.source=="review") | [.check, .suspect]] == [["review:alignment",false],["review:legibility",true]]' "$reg"
assert "noticed: where as pattern, viewport -, minor, shot resolved beside its file" '[.findings[] | select(.source=="noticed") | [.pattern, .viewport, .check, .severity, .shot]] == [["/projects/:id","-","noticed","minor",null],["/settings","-","noticed","minor","scenarios/S-3/shot.png"]]' "$reg"
case "$reg" in *SECRET*|*judge*) echo "  a verdicts file's notes or a judge file reached the register"; FAILED=1;; esac
assert "real UTC timestamps" '.updated_utc | test("^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")' "$reg"
assert "first and last seen are builds: the sweep's, a noticed item's file name's" 'all(.findings[]; .first_seen == "b1" and .last_seen == "b1")' "$reg"

# recheck-plan: what "recheck D-<k>" sweeps, read from the register only.
rp="$(node "$SCRIPTS/design-findings.mjs" recheck-plan D-1)"
assert "recheck-plan: a sweep finding's page and viewport" '.id == "D-1" and .source == "sweep" and .sweep == {"pattern":"/","viewports":"1440x900"} and .review == false and .note == null' "$rp"
rid="$(jq -r '[.findings[] | select(.source=="review")][0].id' "$D/findings.json")"
assert "recheck-plan: a review finding is reviewed again" '.review == true and (.sweep.pattern | startswith("/"))' "$(node "$SCRIPTS/design-findings.mjs" recheck-plan "$rid")"
nid="$(jq -r '[.findings[] | select(.source=="noticed")][0].id' "$D/findings.json")"
assert "recheck-plan: a noticed item has no sweep" '.sweep == null and (.note | test("noticed"))' "$(node "$SCRIPTS/design-findings.mjs" recheck-plan "$nid")"
for bad in D-99 D-x "D-1;x" ""; do
  node "$SCRIPTS/design-findings.mjs" recheck-plan "$bad" >/dev/null 2>&1
  assert_eq "recheck-plan '$bad' refused" 2 "$?"
done

# Second merge of the same sweep: same ids, nothing new, first_seen kept.
cp "$D/findings.json" "$SANDBOX/reg1.json"
m="$(node "$SCRIPTS/design-findings.mjs" merge "$S1/sweep.json" --review "$SANDBOX/review.json" --no-render)"
assert "second merge: stable" '.findings == 9 and .new == 0 and .open == 9' "$m"
cmp -s "$SANDBOX/reg1.json" "$D/findings.json" || { echo "  a merge that saw nothing new changed findings.json"; FAILED=1; }

# The next build: / @1440x900 swept clean, / @390x844 not swept, projects @390x844 with one finding left.
S2="$D/b2"; mkdir -p "$S2/shots"
jq '.build="b2" | .pages |= map(select(.viewport=="1440x900" or .pattern=="/projects/:id"))
    | .pages |= map(if .pattern=="/" then .findings=[] elif .viewport=="390x844" then .findings |= map(select(.check=="no-name")) else . end)' \
  "$S1/sweep.json" > "$S2/sweep.json"
m="$(node "$SCRIPTS/design-findings.mjs" merge "$S2/sweep.json" --no-render)"
reg="$(cat "$D/findings.json")"
assert "resolved: clipped text (/ @1440) and contrast (projects @390)" '[.findings[] | select(.status=="resolved") | [.id, .resolved_build]] == [["D-1","b2"],["D-4","b2"]]' "$reg"
assert "a page not swept is untouched" '[.findings[] | select(.pattern=="/" and .viewport=="390x844") | .status] | all(. == "open")' "$reg"
assert "no review this merge: review findings untouched" '[.findings[] | select(.source=="review") | .status] == ["open","open"]' "$reg"
assert "noticed never resolved" '[.findings[] | select(.source=="noticed") | .status] == ["open","open"]' "$reg"
assert "counts" '.resolved == 2 and .new == 0' "$m"
assert "seen again in b2: last_seen b2, first_seen kept" '[.findings[] | select(.check=="no-name") | [.first_seen, .last_seen]] == [["b1","b2"]]' "$reg"
assert "not seen in b2: last_seen kept" '[.findings[] | select(.id=="D-1" or .source=="noticed") | .last_seen] | all(. == "b1")' "$reg"

# A review of b2 covering / @1440x900 without the alignment finding resolves it.
echo '[]' > "$SANDBOX/empty.json"
printf -- '- ui_sweep_review_pages: 10\n' > "$SANDBOX/cfg" && grep -v ui_sweep_review_pages "$WORK_DIR/CONFIG.md" >> "$SANDBOX/cfg" && mv "$SANDBOX/cfg" "$WORK_DIR/CONFIG.md"
node "$SCRIPTS/design-findings.mjs" merge "$S2/sweep.json" --review "$SANDBOX/empty.json" --no-render >/dev/null
assert "a covered page's review finding resolves" '[.findings[] | select(.source=="review") | .status] == ["resolved","open"]' "$(cat "$D/findings.json")"

# Seen again: reopened, same id.
m="$(node "$SCRIPTS/design-findings.mjs" merge "$S1/sweep.json" --no-render)"
reg="$(cat "$D/findings.json")"
assert "reopened with the same ids" '[.findings[] | select(.id=="D-1" or .id=="D-4") | [.status, .resolved_build]] == [["open",null],["open",null]]' "$reg"
assert "no new id on reopening" '.new == 0 and .findings == 9' "$m"

# DISMISSED.md: applied on every merge, and only from there.
printf '| id | dismissed_utc |\n| --- | --- |\n| D-2 | 2026-10-21T10:00:00Z |\n| D-99 | 2026-10-21T10:00:00Z |\n' > "$D/DISMISSED.md"
m="$(node "$SCRIPTS/design-findings.mjs" merge "$S1/sweep.json" --no-render)"
assert "dismissed from the file" '.dismissed == 1' "$m"
assert "D-2 dismissed" '.findings[] | select(.id=="D-2") | .status == "dismissed"' "$(cat "$D/findings.json")"
m="$(node "$SCRIPTS/design-findings.mjs" merge "$S2/sweep.json" --no-render)"
assert "still dismissed after another merge" '.findings[] | select(.id=="D-2") | .status == "dismissed"' "$(cat "$D/findings.json")"
printf '| id | dismissed_utc |\n| --- | --- |\n' > "$D/DISMISSED.md"
node "$SCRIPTS/design-findings.mjs" merge "$S1/sweep.json" --no-render >/dev/null
assert "off the file -> back to open" '.findings[] | select(.id=="D-2") | .status == "open"' "$(cat "$D/findings.json")"

# A new finding gets the next id; noticed-only merges without a sweep; a stale crop goes.
mkdir -p "$D/crops" && : > "$D/crops/D-77.jpg"
cat > "$WORK_DIR/issues/12/verdicts-abc-b2.json" <<'J'
{"noticed":[{"where":"/","saw":"The logo is blurry","shot":null}]}
J
m="$(node "$SCRIPTS/design-findings.mjs" merge --noticed-only --no-render)"
reg="$(cat "$D/findings.json")"
assert "noticed-only: one new, next id, nothing resolved" '.new == 1 and .findings == 10' "$m"
assert "the new id is D-10" '.findings[-1].id == "D-10" and .findings[-1].source == "noticed" and .next_id == 11' "$reg"
assert "a noticed item's builds from its verdicts file name" '.findings[-1] | .first_seen == "b2" and .last_seen == "b2"' "$reg"
[ ! -e "$D/crops/D-77.jpg" ] || { echo "  the crop of an id not in the register was kept"; FAILED=1; }
# Two noticed-only merges in a row: the second does not rewrite the register.
cp "$D/findings.json" "$SANDBOX/reg2.json"; touch -t 202001010000 "$D/findings.json"; touch -t 202101010000 "$SANDBOX/mark"
node "$SCRIPTS/design-findings.mjs" merge --noticed-only --no-render >/dev/null
cmp -s "$SANDBOX/reg2.json" "$D/findings.json" || { echo "  a second noticed-only merge changed findings.json"; FAILED=1; }
[ -n "$(find "$D/findings.json" ! -newer "$SANDBOX/mark")" ] || { echo "  a second noticed-only merge rewrote findings.json"; FAILED=1; }
# A noticed item seen again in a later build: last_seen moves, first_seen stays.
cat > "$WORK_DIR/issues/12/verdicts-abc-b3.json" <<'J'
{"noticed":[{"where":"/","saw":"The logo is blurry","shot":null}]}
J
touch -t 203001010000 "$WORK_DIR/issues/12/verdicts-abc-b3.json"
node "$SCRIPTS/design-findings.mjs" merge --noticed-only --no-render >/dev/null
assert "noticed again in b3" '.findings[] | select(.id=="D-10") | .first_seen == "b2" and .last_seen == "b3"' "$(cat "$D/findings.json")"
rm "$WORK_DIR/issues/12/verdicts-abc-b3.json"

# A check resolves only where it ran: a11y only where axe ran on the page; an errored page resolves nothing.
S4="$D/b4"; mkdir -p "$S4/shots"
cat > "$S4/sweep.json" <<'J'
{"build":"b4","viewports":["1440x900","390x844"],"axe":true,"pages":[
  {"pattern":"/forms","viewport":"1440x900","shot":"shots/forms@1440x900.png","axe":true,"cls":0,"findings":[
    {"check":"a11y:label","severity":"major","target":"“Email” input","box":null,"detail":"Form elements must have labels"},
    {"check":"contrast","severity":"minor","target":"“Hint” span","box":null,"detail":"contrast 2.10:1"}]},
  {"pattern":"/forms","viewport":"390x844","shot":"shots/forms@390x844.png","axe":true,"cls":0,"findings":[
    {"check":"a11y:label","severity":"major","target":"“Email” input","box":null,"detail":"Form elements must have labels"}]},
  {"pattern":"/err","viewport":"1440x900","shot":"shots/err@1440x900.png","axe":true,"cls":0,"findings":[
    {"check":"clipped-text","severity":"minor","target":"“Title” heading","box":null,"detail":"cut"}]}]}
J
m="$(node "$SCRIPTS/design-findings.mjs" merge "$S4/sweep.json" --no-render)"
assert "b4: four new" '.new == 4' "$m"
jq '.build="b5" | .axe=false | .pages |= map(.findings=[] | if .pattern=="/err" then .error="timeout" elif .viewport=="1440x900" then .axe=false else . end)' \
  "$S4/sweep.json" > "$SANDBOX/b5.json"
node "$SCRIPTS/design-findings.mjs" merge "$SANDBOX/b5.json" --no-render >/dev/null
reg="$(cat "$D/findings.json")"
assert "axe did not run on the page: its a11y finding stays open" '.findings[] | select(.pattern=="/forms" and .viewport=="1440x900" and .check=="a11y:label") | .status == "open" and .resolved_build == null' "$reg"
assert "another check on that page resolves" '.findings[] | select(.pattern=="/forms" and .check=="contrast") | .status == "resolved" and .resolved_build == "b5"' "$reg"
assert "axe ran on the page: its a11y finding resolves" '.findings[] | select(.pattern=="/forms" and .viewport=="390x844") | .status == "resolved"' "$reg"
assert "an errored page resolves nothing" '.findings[] | select(.pattern=="/err") | .status == "open" and .last_seen == "b4"' "$reg"
node "$SCRIPTS/design-findings.mjs" merge >/dev/null 2>&1
assert_eq "merge without a sweep or --noticed-only is a usage error" 2 "$?"
ls "$D"/*.tmp >/dev/null 2>&1 && { echo "  a tmp file was left"; FAILED=1; }
exit $FAILED
