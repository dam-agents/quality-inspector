#!/usr/bin/env bash
# Predicted staleness (docs/maintenance.md → Predicted from the change context): ui-diff.mjs and
# iface-diff output through impact.mjs (the hit's type and block, a block line before a line outside)
# into maintenance.mjs predict — a gone page, a removed or renamed or moved control inside a block, one
# control in two blocks, a removed endpoint; a hit only outside the blocks, a tier that does not recur
# and a file with no SUITE.md row open nothing; a second predict of the same change refreshes the build
# and keeps a proposal the agent changed, of another change replaces the row with a new one; a triage row replaces a prediction and stops the next one; sweep closes
# a predicted break that did not happen (--unchanged, --absorbed).
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
seed_work
W="$WORK_DIR"
M() { node "$SCRIPTS/maintenance.mjs" "$@"; }
export QI_WORDS_DIR="$SANDBOX"
B() { local f; f="$(mktemp "$SANDBOX/quality-inspector-basis.XXXXXX")"; printf '%s' "$*" > "$f"; echo "$f"; }

cat > "$SANDBOX/old.json" <<'J'
{"routes":{"/":{"headings":["Home"],"buttons":["Create agent","Export report"],"nav":[],"tabs":[],"inputs":[],"links":[]},
 "/settings":{"headings":["Settings"],"buttons":["Save changes"],"nav":[],"tabs":["API keys","Usage"],"inputs":[],"links":[]},
 "/legacy":{"headings":["Legacy"],"buttons":[],"nav":[],"tabs":[],"inputs":[],"links":[]}}}
J
cat > "$SANDBOX/new.json" <<'J'
{"routes":{"/":{"headings":["Home"],"buttons":["Export reports"],"nav":[],"tabs":[],"inputs":[],"links":[]},
 "/settings":{"headings":["Settings"],"buttons":[],"nav":[],"tabs":["Access tokens","Usage"],"inputs":[],"links":[]},
 "/artifacts":{"headings":["Artifacts"],"buttons":["Create agent"],"nav":[],"tabs":[],"inputs":[],"links":[]}}}
J
node "$SCRIPTS/ui-diff.mjs" "$SANDBOX/old.json" "$SANDBOX/new.json" > "$SANDBOX/diff.json"
assert "the fixture's diff: a rename, a likely rename, a move, a removal, a gone page" \
  '(.renamed | map(.from + ">" + .to + ":" + (.basis // "text")) | sort) == ["API keys>Access tokens:same-place","Export report>Export reports:text"]
   and .moved[0].name == "Create agent" and .removed == [{"kind":"buttons","name":"Save changes","routes":["/settings"]}] and .pages_removed == ["/legacy"]' "$(cat "$SANDBOX/diff.json")"
echo '{"program":null,"endpoints_removed":[{"endpoint":"GET /api/v1/reports","path_remains":false}]}' > "$SANDBOX/iface.json"

T="$W/suite/tests"; mkdir -p "$T"
# #1: a likely rename and a move inside blocks; a rename and a comment outside them.
cat > "$T/issue-1.e2e.ts" <<'X'
await app.open('/settings');
// go to API keys, then Export report
await screen.getByRole('button', { name: 'Export report' }).click();
// AC-1 begin
await expect(screen.getByRole('tab', { name: 'API keys' })).toBeVisible();
// AC-1 end
// AC-2 begin
await screen.getByRole('button', { name: 'Create agent' }).click();
// AC-2 end
X
# #2: a gone page, opened outside the block.
printf "await app.open('/legacy');\n// AC-1 begin\nawait expect(screen.getByText('Home')).toBeVisible();\n// AC-1 end\n" > "$T/issue-2.e2e.ts"
# #3 (promotable): its one block checks a removed control -> retire the test.
printf "// AC-1 begin\nawait screen.getByRole('button', { name: 'Save changes' }).click();\n// AC-1 end\n" > "$T/issue-3.e2e.ts"
# #4 (exploratory) and #6 (no SUITE.md row): the same hit, out of scope.
cp "$T/issue-3.e2e.ts" "$T/issue-4.e2e.ts"; cp "$T/issue-3.e2e.ts" "$T/issue-6.e2e.ts"
# #5: hits only outside its blocks.
printf "await screen.getByRole('button', { name: 'Export report' }).click();\nawait screen.getByRole('tab', { name: 'API keys' }).click();\n// AC-1 begin\nawait expect(screen.getByText('Usage')).toBeVisible();\n// AC-1 end\n" > "$T/issue-5.e2e.ts"
# S-7 (quarantined): a rename with textual likeness inside its block.
printf "// AC-1 begin\nawait screen.getByRole('button', { name: 'Export report' }).click();\n// AC-1 end\n" > "$T/scenario-7.e2e.ts"
# #8: one of two AC blocks obsolete, and a move inside an IN block.
printf "// AC-1 begin\nawait screen.getByRole('button', { name: 'Save changes' }).click();\n// AC-1 end\n// AC-2 begin\nawait expect(screen.getByText('Usage')).toBeVisible();\n// AC-2 end\n// IN-1 begin\nawait screen.getByRole('button', { name: 'Create agent' }).click();\n// IN-1 end\n" > "$T/issue-8.e2e.ts"
# #9: a removed endpoint, called outside its block.
printf "const r = await api.get('/api/v1/reports');\n// AC-1 begin\nexpect(r.ok).toBe(true);\n// AC-1 end\n" > "$T/issue-9.e2e.ts"
# #10: one removed control in both of its blocks -> retire; #11: one renamed control in both blocks.
printf "// AC-1 begin\nawait screen.getByRole('button', { name: 'Save changes' }).click();\n// AC-1 end\n// AC-2 begin\nawait expect(screen.getByRole('button', { name: 'Save changes' })).toBeDisabled();\n// AC-2 end\n" > "$T/issue-10.e2e.ts"
sed 's/Save changes/Export report/' "$T/issue-10.e2e.ts" > "$T/issue-11.e2e.ts"
for n in 1 2 5 8 9 10 11; do printf '| tests/issue-%s.e2e.ts | %s | regression | none | 2026-10-03T08:12:40Z |\n' "$n" "$n" >> "$W/SUITE.md"; done
printf '| tests/issue-3.e2e.ts | 3 | promotable | none | - |\n| tests/issue-4.e2e.ts | 4 | exploratory | none | - |\n| tests/scenario-7.e2e.ts | S-7 | quarantined | none | 2026-10-03T08:12:40Z |\n' >> "$W/SUITE.md"

I="$SANDBOX/impact.json"
node "$SCRIPTS/impact.mjs" "$SANDBOX/diff.json" --iface "$SANDBOX/iface.json" "$T"/issue-*.e2e.ts "$T"/scenario-*.e2e.ts > "$I"
i="$(cat "$I")"
assert "impact: a hit names its type and block, and the block line wins over an earlier line outside" \
  '.impacted[] | select(.test | endswith("issue-1.e2e.ts")) | .blocks == ["AC-1","AC-2"]
   and (.hits | map(select(.type == "renamed-likely")) | map([.block, .line, .inAcBlock]) == [[null, 2, false], ["AC-1", 5, true]])
   and (.hits | map(select(.type == "renamed")) | map([.block, .line]) == [[null, 2]])
   and (.hits | map(select(.type == "moved")) | .[0].block == "AC-2")' "$i"
assert "impact: one hit per block a control is named in" '.impacted[] | select(.test | endswith("issue-10.e2e.ts")) | .hits | map([.block, .line]) == [["AC-1", 2], ["AC-2", 5]]' "$i"
assert "impact: an IN block is a block" '.impacted[] | select(.test | endswith("issue-8.e2e.ts")) | .blocks == ["AC-1","AC-2","IN-1"] and (.hits | map(select(.type == "moved")) | .[0].block == "IN-1")' "$i"
assert "impact: an interface removal has its type" '.impacted[] | select(.test | endswith("issue-9.e2e.ts")) | .hits == [{"change":"endpoint GET /api/v1/reports removed","type":"endpoint-removed","line":1,"inAcBlock":false,"block":null}]' "$i"

before="$(cat "$W/MAINTENANCE.md" 2>/dev/null)"
dry="$(M predict --build c2 --impact "$I" --dry-run)"
assert "predict: the candidates, and nothing else" '[.candidates[] | .test + ":" + .kind + ":" + .proposal] | sort == ([
  "#1 AC-1:renamed:review", "#1 AC-2:moved:heal", "#2:obsolete:rewrite", "#3:obsolete:retire",
  "#8 AC-1:obsolete:rewrite", "#8 IN-1:moved:heal", "#9:obsolete:rewrite", "S-7 AC-1:renamed:heal",
  "#10:obsolete:retire", "#11 AC-1:renamed:heal", "#11 AC-2:renamed:heal"] | sort)' "$dry"
assert "predict: the basis is the diff line" '.candidates[] | select(.test == "#2") | .basis == "ui-map: page /legacy removed" and .file == "tests/issue-2.e2e.ts" and .line == 1' "$dry"
assert "predict: an interface basis" '.candidates[] | select(.test == "#9") | .basis == "iface: endpoint GET /api/v1/reports removed"' "$dry"
assert_eq "predict --dry-run writes nothing" "$before" "$(cat "$W/MAINTENANCE.md" 2>/dev/null)"

out="$(M predict --build c2 --impact "$I")"
assert "predict: eleven rows opened" '(.opened | length) == 11 and .updated == [] and .skipped == []' "$out"
assert "the rows: open, on the build" '[.proposals[] | select(.state == "open" and .build == "c2")] | length == 11' "$(M list)"
assert "check: the predicted kinds are well-formed" '.ok' "$(M check)"
id() { M list --open | jq -r --arg t "$1" --arg k "$2" '.proposals[] | select(.test == $t and .kind == $k) | .id'; }
# The agent finds the S-7 repair would touch a matcher and opens it again as review (docs/maintenance.md).
b7="$(M list --open | jq -r '.proposals[] | select(.test == "S-7 AC-1") | .basis')"
M open 'S-7 AC-1' --kind renamed --build c2 --proposal review --basis-file "$(B "$b7")" >/dev/null
out="$(M predict --build c3 --impact "$I")"
assert "predict again: the same rows, updated" '.opened == [] and (.updated | length) == 11 and .replaced == []' "$out"
assert "predict again: the build refreshed, the review proposal kept" ".proposals[] | select(.test == \"S-7 AC-1\") | .proposal == \"review\" and .build == \"c3\" and .basis == $(jq -n --arg b "$b7" '$b')" "$(M list --open)"
# Another change in the same block (a later build renames another control of #11 AC-1): the old row,
# whose diff repairs the old change, is resolved, and a new row opens for the new change.
r11a="$(M list --open | jq -r '.proposals[] | select(.test == "#11 AC-1" and .kind == "renamed") | .id')"
jq '(.impacted[] | select(.test | endswith("issue-11.e2e.ts")) | .hits[] | select(.block == "AC-1") | .change) = "buttons \"Export\" renamed to \"Download\""' "$I" > "$SANDBOX/impact2.json"
out="$(M predict --build c4 --impact "$SANDBOX/impact2.json")"
assert "predict: another change replaces the row and opens a new one" ".replaced == [\"$r11a\"] and (.opened | length) == 1 and (.updated | length) == 10" "$out"
assert "the new row: the new basis, the proposal of the prediction" '[.proposals[] | select(.test == "#11 AC-1" and .kind == "renamed")] | length == 1 and .[0].basis == "ui-map: buttons \"Export\" renamed to \"Download\"" and .[0].proposal == "heal" and .[0].build == "c4"' "$(M list --open)"
assert "the old row: resolved" ".proposals[] | select(.id == \"$r11a\") | .state == \"resolved\"" "$(M list)"

# The night's triage confirms #1 AC-1 as needs-review: its prediction is replaced, the AC-2 one is not.
r11="$(id '#1 AC-1' renamed)"; r12="$(id '#1 AC-2' moved)"
out="$(M open '#1 AC-1' --kind needs-review --build c3 --proposal heal --basis-file "$(B 'ui-map: tab "API keys" renamed')")"
assert "a triage row replaces the prediction of its block only" ".opened and .replaced == [\"$r11\"]" "$out"
assert "the replaced row is resolved" ".proposals[] | select(.id == \"$r11\") | .state == \"resolved\"" "$(M list)"
out="$(M predict --build c4 --impact "$SANDBOX/impact2.json")"
assert "predict: a block with an open triage row is skipped" '.skipped == ["#1 AC-1"] and .opened == []' "$out"
# A triage row of the whole test replaces every prediction of it.
r8a="$(id '#8 AC-1' obsolete)"; r8i="$(id '#8 IN-1' moved)"
sed -i.bak 's/| tests\/issue-8.e2e.ts | 8 | regression |/| tests\/issue-8.e2e.ts | 8 | retired |/' "$W/SUITE.md"
out="$(M open '#8' --kind superseded --build c3 --proposal retire --basis-file "$(B '#80: "the save button is gone"')")"
assert "a whole-test triage row replaces each block's prediction" "(.replaced | sort) == ([\"$r8a\",\"$r8i\"] | sort)" "$out"

# sweep: #1 AC-2 replayed unchanged (its predicted move did not break it), S-7 healed by the triage —
# and --absorbed never closes a triage row.
r7="$(id 'S-7 AC-1' renamed)"; r9="$(id '#9' obsolete)"; nr1="$(id '#1 AC-1' needs-review)"
out="$(M sweep --unchanged '#1 AC-2' --absorbed 'S-7 AC-1' --absorbed '#1 AC-1')"
assert "sweep: a predicted break that did not happen, and one the triage absorbed" "(.resolved | sort) == ([\"$r12\",\"$r7\"] | sort)" "$out"
assert "sweep: --absorbed leaves the needs-review row open" ".proposals[] | select(.id == \"$nr1\") | .state == \"open\"" "$(M list)"
assert "sweep: a bare row stays while only a block passed" '.resolved == []' "$(M sweep --unchanged '#9 AC-1')"
assert "sweep: the whole test passed" ".resolved == [\"$r9\"]" "$(M sweep --unchanged '#9')"

# Refusals: no SUITE.md (exit 1, nothing written), an impact file that is not JSON, no build.
before="$(cat "$W/MAINTENANCE.md")"
mv "$W/SUITE.md" "$W/SUITE.md.away"
M predict --build c4 --impact "$I" 2>/dev/null; assert_eq "predict with no SUITE.md: exit 1" 1 "$?"
mv "$W/SUITE.md.away" "$W/SUITE.md"
echo 'not json' > "$SANDBOX/bad.json"
M predict --build c4 --impact "$SANDBOX/bad.json" 2>/dev/null; assert_eq "predict with a bad impact file: exit 2" 2 "$?"
echo '{"impacted":{}}' > "$SANDBOX/bad.json"
M predict --build c4 --impact "$SANDBOX/bad.json" 2>/dev/null; assert_eq "predict with JSON of another shape: exit 2" 2 "$?"
M predict --build c4 --impact "$SANDBOX/none.json" 2>/dev/null; assert_eq "predict with no impact file: exit 2" 2 "$?"
M predict --impact "$I" 2>/dev/null; assert_eq "predict without --build: exit 2" 2 "$?"
assert_eq "refusals leave the file as it was" "$before" "$(cat "$W/MAINTENANCE.md")"
[ -e "$W/MAINTENANCE.md.lock" ] && { echo "  a refused predict left its lock"; FAILED=1; }
assert "check: still well-formed" '.ok' "$(M check)"

# The catalog explains every kind and proposal the queue can hold: a row of a kind it does not know
# is dropped from the dashboard (viewer.html filters by MAINT_KIND).
missing="$(node -e '
const fs = require("fs"); const m = fs.readFileSync(process.argv[1], "utf8"); const v = fs.readFileSync(process.argv[2], "utf8");
const list = (re, src) => [...(re.exec(src)?.[1] ?? "").matchAll(/\x27([a-z-]+)\x27/g)].map((x) => x[1]);
const kinds = [...list(/const TRIAGE = \[([^\]]*)\]/, m), "drift", ...list(/const PREDICTED = \[([^\]]*)\]/, m)];
const props = list(/const PROPOSALS = \[([^\]]*)\]/, m);
const keys = (name) => { const body = new RegExp(`const ${name} = \\{([\\s\\S]*?)\\};`).exec(v)?.[1] ?? ""; return [...body.matchAll(/(?:^|,)\s*\x27?([a-z-]+)\x27?\s*:/g)].map((x) => x[1]); };
const k = keys("MAINT_KIND"); const p = keys("MAINT_PROP");
console.log([...kinds.filter((x) => !k.includes(x)), ...props.filter((x) => !p.includes(x))].join(" ") || (kinds.length < 8 || props.length < 5 ? "none parsed" : ""));
' "$SCRIPTS/maintenance.mjs" "$SCRIPTS/catalog/viewer.html")"
assert_eq "viewer.html explains every maintenance kind and proposal" "" "$missing"
exit $FAILED
