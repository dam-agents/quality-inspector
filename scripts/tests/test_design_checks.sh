#!/usr/bin/env bash
# Design checks (docs/design-checks.md), offline: the rules (Ref, the Design Desk message, the
# profile's `design` key, retired words, tokens, changed screens, the radar's patterns), which pull
# request builds are due and the ledger of those checked, the plans of design-check.mjs and
# consistency.mjs with no browser, and the outbox — opt-in, each Ref once, the most severe first,
# capped and floored, an unfinished send never repeated — and the `modules` pre-flight that lists the
# pull requests.
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
seed_work
DC="$SCRIPTS/design-check.mjs"; OB="$SCRIPTS/design-outbox.mjs"; CO="$SCRIPTS/consistency.mjs"
R() { node --input-type=module -e "import * as d from '$SCRIPTS/lib/design-rules.mjs'; $1"; }

# ---------------------------------------------------------------- rules
assert "a Ref is stable, readable, and names no run" '.a == .b and .a != .c and (.a | test("^qi-a11y-[0-9a-f]{10}$"))' \
  "$(R 'console.log(JSON.stringify({a: d.refOf("a11y", "color-contrast", "“Save” button", "dark"), b: d.refOf("a11y", "color-contrast", " “Save”  button", "dark"), c: d.refOf("a11y", "color-contrast", "“Save” button", "light")}))')"
F='{"ref":"qi-state-0123456789","check":"missing-state","severity":"high","title":"No error <b>message</b> & more","screen":"Agents","path":"/agents","what":"It fails.\nTwice <@U999>.","expected":"An error.","steps":["Open /agents.","Look."],"build":"PR #812"}'
msg="$(R "console.log(d.formatMessage($F, 'U0DESKBOT1'))")"
want="🧪 Automated test finding — Quality Inspector
No error &lt;b&gt;message&lt;/b&gt; &amp; more
Screen: Agents (/agents)
What happens: It fails. Twice &lt;@U999&gt;.
Expected: An error.
Steps: 1. Open /agents. 2. Look.
Build: PR #812
Check: missing-state
Severity: high
Ref: qi-state-0123456789
<@U0DESKBOT1>"
assert_eq "the message: the exact lines, product text escaped, the mention last" "$want" "$msg"
assert_eq "the first line is the marker, exactly" "🧪 Automated test finding — Quality Inspector" "$(printf '%s\n' "$msg" | head -1)"
R "try { d.formatMessage({...$F, check: 'vibes'}, 'U0DESKBOT1'); console.log('ok') } catch (e) { console.log(e.message) }" | grep -q 'invalid check'
assert_eq "a check outside the four is refused" 0 "$?"
R "try { d.formatMessage($F, '<!channel>'); console.log('ok') } catch (e) { console.log(e.message) }" | grep -q 'not a Slack member id'
assert_eq "a mention that is not a member id is refused" 0 "$?"
pd="$(R 'console.log(JSON.stringify(d.parseDesign({design: {retired_words: [{word: "Experiment", say: "Driver script"}, {word: "bad;word", say: "x"}, {word: "sandboxes"}],
  dark_theme: {local_storage: {key: "platform-theme", value: "dark"}}, tokens: {prefixes: ["--color-", "color"], spacing_step: "--spacing"}}})))')"
assert "design: valid parts kept, each bad one left out with a note" '[.retired[].word] == ["Experiment"] and .dark == {"mode":"local_storage","key":"platform-theme","value":"dark"}
  and .tokens == {"prefixes":["--color-"],"spacing_step":"--spacing"} and (.notes | length) == 3' "$pd"
assert "design: absent -> no words, the system dark theme, every token" '.retired == [] and .dark.mode == "color_scheme" and .tokens.prefixes == [] and .notes == []' "$(R 'console.log(JSON.stringify(d.parseDesign({})))')"
assert "design: none and a bad theme" '.[0].mode == "none" and .[1].mode == "color_scheme" and (.[2] | length) == 1' \
  "$(R 'console.log(JSON.stringify([d.parseDesign({design: {dark_theme: "none"}}).dark, d.parseDesign({design: {dark_theme: {html_attribute: {name: "onload", value: "x"}}}}).dark, d.parseDesign({design: {dark_theme: {html_attribute: {name: "onload", value: "x"}}}}).notes]))')"
hits="$(R 'const w = d.parseDesign({design: {retired_words: [{word: "Experiment", say: "Driver script"}, {word: "experiment agent", say: "agent"}, {word: "image", say: "agent"}]}}).retired;
  console.log(JSON.stringify(d.findRetired([{text: "Your EXPERIMENT runs", target: "a"}, {text: "Experimental mode", target: "b"}, {text: "an experiment  agent", target: "c"}, {text: "experiment", target: "d"}, {text: "imagery"}], w)))')"
assert "retired words: whole words, any case, a phrase over spaces; one hit per word with its count" \
  'map([.word, .count, .target]) == [["Experiment",3,"a"],["experiment agent",1,"c"]]' "$hits"
off="$(R 'console.log(JSON.stringify(d.offTokens({colors: [[37,99,235],[17,24,39]], lengths: [14,16,24], step: 4},
  [{prop: "color", value: [37,99,236], count: 9}, {prop: "color", value: [255,0,170], count: 2}, {prop: "font-size", value: 13, count: 5},
   {prop: "font-size", value: 14, count: 3}, {prop: "radius", value: 8, count: 1}, {prop: "radius", value: 1, count: 1}, {prop: "background", value: [255,0,170], count: 7}])))')"
assert "tokens: off-token uses, most used first; near colours, token sizes and step multiples pass" 'map([.prop, .count]) == [["background",7],["font-size",5],["color",2]]' "$off"
assert "tokens: none on the page -> no finding" '. == []' "$(R 'console.log(JSON.stringify(d.offTokens({colors: [], lengths: [], step: null}, [{prop: "color", value: [1,2,3], count: 1}])))')"
cat > "$SANDBOX/base.json" <<'J'
{"build":"0.0.0-main.12","routes":{"/":{"example":"/","headings":["Dashboard"],"buttons":["Create"]},"/agents":{"example":"/agents","title":"Agents — App","buttons":["Add agent"]},
 "/gone":{"example":"/gone"}}}
J
cat > "$SANDBOX/pr.json" <<'J'
{"build":"0.0.0-pr.812.3","base":"http://localhost:8080","routes":{"/":{"example":"/","headings":["Dashboard"],"buttons":["Create"]},
 "/agents":{"example":"/agents","title":"Agents — App","buttons":["New agent"]},"/runs":{"example":"/runs","headings":["Runs"]},
 "/runs/:id":{"example":"/runs/7","headings":["Run 7"]},"/broken":{"example":"/broken","error":"timeout"},"/sso":{"example":"/sso","redirected":"https://idp.example"}}}
J
assert "changed screens: new ones first, then most changed; same, errored and redirected left out" \
  'map([.pattern, .title]) == [["/runs","Runs"],["/runs/:id","Run 7"],["/agents","Agents — App"]] and .[2].reason == "2 controls added, removed or renamed"' \
  "$(R "import('node:fs').then(fs => console.log(JSON.stringify(d.changedPages(JSON.parse(fs.readFileSync('$SANDBOX/base.json')), JSON.parse(fs.readFileSync('$SANDBOX/pr.json'))))))")"
OBS='[{"kind":"empty-state","group":"","sig":"a","label":"picture, title","pattern":"/runs","title":"Runs","example":{"crop":"c1"}},
  {"kind":"empty-state","group":"","sig":"b","label":"text only","pattern":"/secrets","title":"Secrets","example":{"crop":"c2"}},
  {"kind":"empty-state","group":"","sig":"a","label":"picture, title","pattern":"/keys","title":"Keys","example":{"crop":"c1"}},
  {"kind":"button","group":"filled","sig":"x","label":"6px","pattern":"/runs","title":"Runs","example":{}},
  {"kind":"button","group":"filled","sig":"y","label":"pill","pattern":"/runs","title":"Runs","example":{}},
  {"kind":"page-header","group":"","sig":"h","label":"24px","pattern":"/runs","title":"Runs","example":{}},
  {"kind":"page-header","group":"","sig":"h","label":"24px","pattern":"/keys","title":"Keys","example":{}},
  {"kind":"spacing","group":"","sig":"s1","label":"24","pattern":"/runs","title":"Runs","example":{}},
  {"kind":"spacing","group":"","sig":"s2","label":"32","pattern":"/keys","title":"Keys","example":{}}]'
rad="$(R "console.log(JSON.stringify(d.clusterRadar($OBS, '0.0.0-main.12')))")"
assert "radar: one finding per pattern whose kinds differ on two screens or more" 'map(.ref) == ["qi-radar-empty-state","qi-radar-spacing"]' "$rad"
assert "radar: kinds most screens first; the screen is the odd one; valid findings" '.[0] | .variants[0].pages == ["/runs","/keys"] and .variants[1].pages == ["/secrets"]
  and .screen == "Secrets" and .path == "/secrets" and .severity == "medium" and .check == "radar" and .build == "0.0.0-main.12" and (.what | test("2 kinds"))' "$rad"
assert "radar: margins are low" '.[1].severity == "low"' "$rad"
assert_eq "radar findings are valid messages" "[]" "$(R "console.log(JSON.stringify(d.clusterRadar($OBS, 'b1').flatMap((f) => d.validFinding(f))))")"

# ---------------------------------------------------------------- due: which pull request builds
cat > "$QI_PROFILE_DIR/bin/versions" <<'S'
#!/usr/bin/env bash
if [ "${1:-}" = --prs ]; then
  shift; [ -n "${STUB_PR_RC:-}" ] && { echo "no builds" >&2; exit "$STUB_PR_RC"; }
  [ -f "$STUB_DIR/pr-builds.json" ] || { jq -c . "$STUB_DIR/versions.json"; exit 0; }
  printf '%s\n' "$@" >> "$STUB_DIR/prs.calls"
  jq -nc --argjson b "$(cat "$STUB_DIR/pr-builds.json")" '$ARGS.positional | reduce .[] as $n ({}; . + {($n): ($b[$n] // null)})' --args "$@"; exit 0
fi
jq -c --arg b "$QI_BASELINE_CHANNEL" 'if $b == "none" then .baseline = null else . end' "$STUB_DIR/versions.json"
S
cat > "$QI_PROFILE_DIR/bin/build-time" <<'S'
#!/usr/bin/env bash
jq -er --arg b "$1" '.[$b] // empty' "$STUB_DIR/build-times.json" 2>/dev/null || { echo "unknown build" >&2; exit 1; }
S
C=0.0.0-main.bbb2222
M1="$(iso_ago 600)"; M2="$(iso_ago 300)"
jq -nc --arg m1 "$M1" --arg m2 "$M2" --arg old "$(iso_ago $((40 * 1440)))" '
  def p($n; $labels; $state; $draft; $t; $m): {number: $n, title: "t", body: "b", labels: $labels, state: $state, draft: $draft, updated_at: $t, merged_at: $m};
  {prs: [p(812; ["qa:design","ui"]; "open"; false; "2026-10-30T10:00:00Z"; null), p(815; ["qa:design"]; "open"; false; "2026-10-30T12:00:00Z"; null),
         p(816; ["qa:design"]; "open"; true; "2026-10-30T13:00:00Z"; null), p(818; ["ui"]; "open"; false; "2026-10-30T15:00:00Z"; null),
         p(819; ["qa:design"]; "open"; false; "2026-10-30T09:00:00Z"; null),
         p(820; ["qa:design"]; "merged"; false; $m2; $m2), p(817; ["qa:design"]; "merged"; false; $m1; $m1),
         p(821; ["qa:design"]; "merged"; false; $old; $old), p(822; ["ui"]; "merged"; false; $m1; $m1)], truncated: false}' > "$SANDBOX/prs.json"
setmaps() { # the UI maps of earlier builds, the older first
  rm -rf "$WORK_DIR/inventory"
  for b in "$@"; do mkdir -p "$WORK_DIR/inventory/$b"; echo '{"routes":{}}' > "$WORK_DIR/inventory/$b/inventory.json"; done
}
times() { jq -nc --arg c "$1" --arg c0 "$(iso_ago 1440)" --arg c1 "$(iso_ago 400)" '{"0.0.0-main.10": $c0, "0.0.0-main.11": $c1} + (if $c == "" then {} else {"0.0.0-main.bbb2222": $c} end)' > "$STUB_DIR/build-times.json"; }
setmaps 0.0.0-main.10 0.0.0-main.11; times "$(iso_ago 60)"
due() { node "$DC" due "$SANDBOX/prs.json" --candidate "$C"; }
out="$(due)"
assert "merged: every labelled one of 30 days, together, on the candidate that carries them, against a map from before the first merge" \
  '.due == [{"kind":"merged","prs":[817,820],"build":"0.0.0-main.bbb2222","against":"0.0.0-main.10","label":"0.0.0-main.bbb2222 (PR #817, #820)","updated_at":"'"$M2"'"}]' "$out"
assert "a profile whose bin/versions ignores --prs: open ones wait for their merge, said once" \
  '.waiting == [] and (.logs | map(select(test("#815, #812, #819 are checked after the merge"))) | length) == 1' "$out"
assert "--prs not implemented (exit 2): the same" '(.logs | map(select(test("checked after the merge"))) | length) == 1' "$(STUB_PR_RC=2 due)"
assert "a failed lookup: the open ones wait with the error; the merged go on" '([.waiting[].reason | test("cannot list")] == [true,true,true]) and (.due[0].kind == "merged")' "$(STUB_PR_RC=1 due)"
times "$(iso_ago 450)"
assert "merged after the candidate: waits for the next main build" '.due[0].prs == [817] and ([.waiting[] | select(.pr == 820) | .reason | test("merged after")] == [true])' "$(due)"
times ""
assert "the candidate's publish time unknown: they wait" '.due == [] and ([.waiting[].reason | test("publish time")] == [true,true])' "$(due)"
times "$(iso_ago 60)"; setmaps 0.0.0-main.11
assert "no map from before the first merge: they wait" '.due == [] and ([.waiting[].reason | test("no UI map")] == [true,true])' "$(due)"
setmaps 0.0.0-main.10 0.0.0-main.11
echo '{"812":"0.0.0-pr.812.3","815":"0.0.0-pr.815.1","819":null}' > "$STUB_DIR/pr-builds.json"
out="$(due)"
pb() { jq -c '[.due[] | select(.kind == "pr-build")]'; }
assert "pr-build: open, labelled, not draft; the updated last first; one a run by default; the merged entry first" \
  '(.due | map(.kind)) == ["merged","pr-build"] and .due[1] == {"kind":"pr-build","prs":[815],"build":"0.0.0-pr.815.1","against":"0.0.0-main.bbb2222","label":"PR #815","updated_at":"2026-10-30T12:00:00Z"}
   and ([.waiting[] | [.pr, .reason]] == [[812,"over design_check_max_prs (1) this run"],[819,"no build of this pull request yet"]])' "$out"
grep -qx 816 "$STUB_DIR/prs.calls" && { echo "  a draft was looked up"; FAILED=1; }
grep -qxE '81[78]|82[012]' "$STUB_DIR/prs.calls" && { echo "  a merged or unlabelled pull request was looked up"; FAILED=1; }
printf -- '- design_check_max_prs: 2\n' >> "$WORK_DIR/CONFIG.md"
assert "design_check_max_prs" '[.[].prs[0]] == [815,812]' "$(due | pb)"
assert "done: one ledger row per pull request" '.recorded == [817,820]' "$(node "$DC" done 817,820 "$C" --findings 4)"
assert "done twice: not again" '.recorded == []' "$(node "$DC" done 817 "$C" --findings 4)"
assert "a checked merged pull request is never due again" '(.due | map(.kind)) == ["pr-build","pr-build"]' "$(due)"
node "$DC" done 815 0.0.0-pr.815.1 --findings 4 >/dev/null
out="$(due)"
assert "a checked build is never due again" '[.due[].prs[0]] == [812] and (.logs | map(select(test("PR #815: build 0.0.0-pr.815.1 already checked"))) | length) == 1' "$out"
echo '{"812":"0.0.0-pr.812.3","815":"0.0.0-pr.815.2"}' > "$STUB_DIR/pr-builds.json"
assert "a new push is a new build: due" '[.due[].prs[0]] == [815,812]' "$(due)"
echo '{"812":"../../x","815":"0.0.0-pr.815.2"}' > "$STUB_DIR/pr-builds.json"
assert "a build that is no plain id waits" '([.waiting[] | select(.pr == 812) | .reason | test("not a plain id")] == [true])' "$(due)"
printf -- '- design_label: design:review\n' >> "$WORK_DIR/CONFIG.md"
assert "design_label from the config" '.due == [] and .waiting == [] and (.logs[0] | test("design:review"))' "$(due)"
node "$DC" due "$SANDBOX/prs.json" >/dev/null 2>&1; assert_eq "due without --candidate is refused" 2 "$?"
for bad in "0 b --findings 1" "8x b --findings 1" "812,x b --findings 1" "812 ../b --findings 1" "812 b --findings -1" "812 b"; do
  node "$DC" done $bad >/dev/null 2>&1; assert_eq "done '$bad' refused" 2 "$?"
done
assert "PRS.md: the ledger's shape" '. == "| 815 | 0.0.0-pr.815.1 | 4 |"' "$(jq -Rr 'select(startswith("| 815"))' "$WORK_DIR/design-checks/PRS.md" | sed -E 's/ \| [0-9TZ:-]+ \|$/ |/' | jq -R .)"

# ---------------------------------------------------------------- run: the plans, no browser
p="$(node "$DC" run "$SANDBOX/pr.json" --against "$SANDBOX/base.json" --pr 812 --build 0.0.0-pr.812.3 --dry-run)"
assert "check plan: the changed screens, the label, the default out" '[.pages[].pattern] == ["/runs","/runs/:id","/agents"] and .label == "PR #812" and .prs == [812] and .max_pages == 6
  and (.out | endswith("/design-checks/pr-812/0.0.0-pr.812.3")) and .base == "http://localhost:8080" and .dark_theme.mode == "color_scheme"' "$p"
printf -- '- design_check_max_pages: 2\n' >> "$WORK_DIR/CONFIG.md"
assert "check plan: design_check_max_pages" '(.pages | length) == 2 and .over == 1' "$(node "$DC" run "$SANDBOX/pr.json" --against "$SANDBOX/base.json" --pr 812 --build b1 --dry-run)"
assert "check plan: --pattern" '[.pages[] | [.pattern, .reason]] == [["/","asked for"]]' "$(node "$DC" run "$SANDBOX/pr.json" --against "$SANDBOX/base.json" --pr 812 --build b1 --pattern / --dry-run)"
node "$DC" run "$SANDBOX/pr.json" --against "$SANDBOX/base.json" --pr 812 --build b1 --pattern /broken --dry-run >/dev/null 2>&1; assert_eq "a pattern the map skips is refused" 2 "$?"
node "$DC" run "$SANDBOX/pr.json" --against "$SANDBOX/base.json" --pr 812 --build b1 --pattern /nope --dry-run >/dev/null 2>&1; assert_eq "a pattern the map lacks is refused" 2 "$?"
node "$DC" run "$SANDBOX/pr.json" --against "$SANDBOX/base.json" --pr 812 --build b1 --base http://staging.example.com --dry-run >/dev/null 2>&1; assert_eq "a non-local base is refused" 2 "$?"
node "$DC" run "$SANDBOX/pr.json" --against "$SANDBOX/base.json" --pr 812 --build ../x --dry-run >/dev/null 2>&1; assert_eq "a build that is not a plain id is refused" 2 "$?"
node "$DC" run "$SANDBOX/pr.json" --pr 812 --build b1 --dry-run >/dev/null 2>&1; assert_eq "no --against is refused" 2 "$?"
assert "check plan on main: the build and its pull requests, out under main/" '.label == "0.0.0-main.12 (PR #817, #820)" and .prs == [817,820] and (.out | endswith("/design-checks/main/0.0.0-main.12"))' \
  "$(node "$DC" run "$SANDBOX/pr.json" --against "$SANDBOX/base.json" --pr 817 --pr 820 --build 0.0.0-main.12 --on-main --dry-run)"
node "$DC" run "$SANDBOX/pr.json" --against "$SANDBOX/base.json" --pr 817 --pr 820 --build b1 --dry-run >/dev/null 2>&1; assert_eq "several --pr only on main" 2 "$?"
c="$(node "$CO" "$SANDBOX/pr.json" --build 0.0.0-main.12 --dry-run)"
assert "radar plan: screens without a :param first, the default out" '[.pages[].pattern] == ["/","/agents","/runs","/runs/:id"] and .max_pages == 40 and (.out | endswith("/design-checks/radar/0.0.0-main.12"))' "$c"
printf -- '- consistency_max_pages: 5\n' >> "$WORK_DIR/CONFIG.md"
assert "radar plan: consistency_max_pages" '.max_pages == 5' "$(node "$CO" "$SANDBOX/pr.json" --build b1 --dry-run)"
node "$CO" "$SANDBOX/pr.json" --build b1 --base http://staging.example.com --dry-run >/dev/null 2>&1; assert_eq "radar: a non-local base is refused" 2 "$?"
mkdir -p "$SANDBOX/nopw"; echo '{"name":"suite"}' > "$SANDBOX/nopw/package.json"
o="$(QI_PLAYWRIGHT_FROM="$SANDBOX/nopw/package.json" node "$DC" run "$SANDBOX/pr.json" --against "$SANDBOX/base.json" --pr 812 --build b9 --out "$SANDBOX/dc" 2>/dev/null)"
assert_eq "check: no playwright-core -> exit 3" 3 "$?"
assert "check: no browser is a JSON error" '.error | startswith("no browser: playwright-core")' "$o"
o="$(QI_PLAYWRIGHT_FROM="$SANDBOX/nopw/package.json" node "$CO" "$SANDBOX/pr.json" --build b9 --out "$SANDBOX/co" 2>/dev/null)"
assert_eq "radar: no playwright-core -> exit 3" 3 "$?"
[ ! -e "$SANDBOX/dc" ] && [ ! -e "$SANDBOX/co" ] || { echo "  a run without a browser wrote its out dir"; FAILED=1; }

# ---------------------------------------------------------------- the outbox
mkdir -p "$SANDBOX/c/shots" "$SANDBOX/r"; : > "$SANDBOX/c/shots/a.png"; : > "$SANDBOX/r/qi-radar-spacing.png"
node --input-type=module -e "
const f = (ref, check, severity, extra = {}) => ({ ref, check, severity, title: 'T ' + ref, screen: 'Agents', path: '/agents', what: 'W.', expected: 'E.', steps: ['Open /agents.'], build: 'PR #812', ...extra });
console.log(JSON.stringify({ findings: [
  f('qi-token-0000000001', 'consistency', 'low'), f('qi-a11y-0000000002', 'accessibility', 'medium', { attachment: 'shots/a.png' }),
  f('qi-state-0000000003', 'missing-state', 'high', { attachment: 'shots/missing.png' }), f('qi-state-0000000004', 'missing-state', 'medium'),
  f('qi-word-0000000005', 'consistency', 'medium'), f('qi-a11y-0000000006', 'accessibility', 'high'), { ref: 'qi-bad', check: 'x' },
  f('qi-focus-0000000007', 'accessibility', 'medium'), f('qi-state-0000000008', 'missing-state', 'medium')] }));" > "$SANDBOX/c/check.json"
node --input-type=module -e "
console.log(JSON.stringify({ findings: [{ ref: 'qi-radar-spacing', check: 'radar', severity: 'low', title: 'Margins', screen: 'Keys', path: '/keys', what: 'W.', expected: 'E.', steps: ['Open /keys.'], build: '0.0.0-main.12', attachment: 'qi-radar-spacing.png' },
  { ref: 'qi-a11y-0000000002', check: 'accessibility', severity: 'medium', title: 'dup', screen: 'S', path: '/s', what: 'W.', expected: 'E.', steps: ['x'], build: 'b' }] }));" > "$SANDBOX/r/radar.json"
plan() { node "$OB" plan "$SANDBOX/c/check.json" "$SANDBOX/r/radar.json"; }
out="$(plan)"
assert "off by default: nothing goes, what would go is counted" '.sending == false and .reason == "design_desk_findings is not enabled" and .due == [] and .ready == 7 and .held.below_floor == 2 and .held.invalid == 1' "$out"
printf -- '- design_desk_findings: enabled\n' >> "$WORK_DIR/CONFIG.md"
assert "on, with no channel: nothing goes" '.sending == false and (.reason | test("design_desk_channel"))' "$(plan)"
printf -- '- design_desk_channel: C0DESK0001\n- design_desk_bot: not-an-id\n' >> "$WORK_DIR/CONFIG.md"
assert "on, with no valid bot: nothing goes" '.sending == false and (.reason | test("design_desk_bot"))' "$(plan)"
sed -i.bak 's/^- design_desk_bot: .*/- design_desk_bot: U0DESKBOT1/' "$WORK_DIR/CONFIG.md"
out="$(plan)"
assert "the most severe first, then missing state, accessibility, consistency; five at most; medium and up" \
  '[.due[].ref] == ["qi-state-0000000003","qi-a11y-0000000006","qi-state-0000000004","qi-state-0000000008","qi-a11y-0000000002"] and .held.over_cap == 2 and .held.below_floor == 2 and .channel == "C0DESK0001"' "$out"
assert "each message: the marker first, the mention last, its Ref" 'all(.due[]; (.text | split("\n")) as $l | $l[0] == "🧪 Automated test finding — Quality Inspector" and $l[-1] == "<@U0DESKBOT1>" and ($l[-2] == "Ref: " + .ref))' "$out"
assert "attachments: absolute when the file is there, else null" '(.due[4].attachment | endswith("/c/shots/a.png")) and .due[0].attachment == null' "$out"
assert "a Ref in two files goes once, from the first" '[.due[] | select(.ref == "qi-a11y-0000000002") | .text | contains("T qi-a11y")] == [true]' "$out"
printf -- '- design_desk_max_per_run: 2\n- design_desk_min_severity: low\n' >> "$WORK_DIR/CONFIG.md"
out="$(plan)"
assert "max per run and the floor from the config" '(.due | length) == 2 and .held.below_floor == 0 and .ready == 9' "$out"
assert "record: sent" '.recorded == true' "$(node "$OB" record qi-state-0000000003 --status sent --check missing-state --severity high --build "PR #812")"
assert "record: held back by the agent's look" '.recorded == true' "$(node "$OB" record qi-a11y-0000000006 --status held --check accessibility --severity high --build "PR #812" --note "the shot shows a focus ring")"
assert "record: never twice" '.recorded == false' "$(node "$OB" record qi-state-0000000003 --status sent --check missing-state --severity high --build "PR #812")"
for bad in "qi-x --status sent --check radar --severity low --build b" "qi-radar-spacing --status maybe --check radar --severity low --build b" \
           "qi-radar-spacing --status sent --check vibes --severity low --build b" "qi-radar-spacing --status sent --check radar --severity urgent --build b"; do
  node "$OB" record $bad >/dev/null 2>&1; assert_eq "record '$bad' refused" 2 "$?"
done
out="$(plan)"
assert "a sent or held Ref is never planned again" '.held.sent == 2 and ([.due[].ref] | index("qi-state-0000000003") == null and index("qi-a11y-0000000006") == null)' "$out"
# An intent with no outcome may have gone out, a done whose record did not run went out: never
# again. One that failed goes again.
printf '%s\n' '{"ts":"2026-10-31T04:40:00Z","level":"info","event":"external_write","msg":"surface=slack action=intent issue=- key=design@qi-state-0000000004 target=C0DESK0001"}' \
  '{"ts":"2026-10-31T04:40:01Z","level":"info","event":"external_write","msg":"surface=slack action=intent issue=- key=design@qi-state-0000000008 target=C0DESK0001"}' \
  '{"ts":"2026-10-31T04:40:02Z","level":"error","event":"external_write","msg":"surface=slack action=failed issue=- key=design@qi-state-0000000008 target=C0DESK0001"}' \
  '{"ts":"2026-10-31T04:40:03Z","level":"info","event":"external_write","msg":"surface=slack action=intent issue=- key=design@qi-a11y-0000000002 target=C0DESK0001"}' \
  '{"ts":"2026-10-31T04:40:04Z","level":"info","event":"external_write","msg":"surface=slack action=done issue=- key=design@qi-a11y-0000000002 target=C0DESK0001"}' \
  > "$WORK_DIR/logs/events-2026-10-31.jsonl"
out="$(plan)"
assert "an unfinished send counts as sent; a failed one goes again" '.held.unsure == 1 and ([.due[].ref] | index("qi-state-0000000008") == 0) and (.logs | map(select(test("qi-state-0000000004"))) | length) == 1' "$out"
assert "a done send with no SENT.md row counts as sent" '.held.sent == 3 and ([.due[].ref] == ["qi-state-0000000008","qi-focus-0000000007"]) and (.logs | map(select(test("qi-a11y-0000000002.*SENT.md has no row"))) | length) == 1' "$out"
assert "check: the ledgers are well-formed" '.ok == true' "$(node "$OB" check)"
printf '| qi-state-0000000003 | sent | missing-state | high | b | - | 2026-10-31T04:41:00Z |\n' >> "$WORK_DIR/design-checks/SENT.md"
assert "check: a Ref recorded twice fails" '.ok == false and (.problems | map(select(test("recorded twice"))) | length) == 1' "$(node "$OB" check)"
sed -i.bak 's/^| ref | status |/| ref | state |/' "$WORK_DIR/design-checks/SENT.md"
node "$OB" plan "$SANDBOX/c/check.json" >/dev/null 2>&1; assert_eq "a changed ledger header stops the plan" 1 "$?"
assert "check: a changed header fails" '.ok == false and (.problems[0] | test("header changed"))' "$(node "$OB" check)"

# ---------------------------------------------------------------- the modules pre-flight
seed_work
printf -- '- design_checks: enabled\n' >> "$WORK_DIR/CONFIG.md"
node -e 'const p = (n, labels, state, t) => ({ number: n, title: "PR " + n, body: "b", labels: labels.map((name) => ({ name })), state, draft: false, updated_at: t, pull_request: { merged_at: null } });
  console.log(JSON.stringify([p(812, ["qa:design"], "open", "2026-10-30T10:00:00Z"), p(813, [], "open", "2026-10-30T11:00:00Z")]));' > "$STUB_DIR/issues.json"
rm -rf "$WORK_DIR/inventory"
cat > "$QI_PROFILE_DIR/bin/versions" <<'S'
#!/usr/bin/env bash
[ "${1:-}" = --prs ] && { echo '{"812":"0.0.0-pr.812.3"}'; exit 0; }
jq -c . "$STUB_DIR/versions.json"
S
out="$(bash "$SCRIPTS/preflight.sh" modules)"
assert "design-check on: the labelled pull request's build is due, named in the title" '.nothing_to_do == false and .modules_due == ["design-check"]
  and .design_checks_due == [{"kind":"pr-build","prs":[812],"build":"0.0.0-pr.812.3","against":"0.0.0-main.bbb2222","label":"PR #812","updated_at":"2026-10-30T10:00:00Z"}]
  and .title == "Run modules on 0.0.0-main.bbb2222 (design-check, PR #812)"' "$out"
grep -q 'prs=812' "$WORK_DIR/MODULES.log"; assert_eq "the pre-flight logs the pull requests" 0 "$?"
ls /tmp/quality-inspector-design.* >/dev/null 2>&1 && { echo "  the listing's temp file stayed"; FAILED=1; }
node "$DC" done 812 0.0.0-pr.812.3 --findings 0 >/dev/null
out="$(bash "$SCRIPTS/preflight.sh" modules)"
assert "its build checked: idle, says why" '.nothing_to_do == true and (.logs | map(select(test("already checked"))) | length) == 1' "$out"
STUB_GH_FAIL=1 bash "$SCRIPTS/preflight.sh" modules > "$SANDBOX/pf.json"
assert "no listing: idle, never an error of the run" '.nothing_to_do == true and (.logs | map(select(test("cannot list"))) | length) == 1' "$(cat "$SANDBOX/pf.json")"
exit $FAILED
