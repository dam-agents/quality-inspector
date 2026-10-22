#!/usr/bin/env bash
# Validation module: the planner is offline and pure — cases per field type and constraint,
# fillers that cannot reach anyone, stable ids, a round-robin cap, every skip with its reason.
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
seed_work
jq '. + {"validation":{"exclude":["/admin"]}}' "$QI_PROFILE_DIR/profile.json" > "$SANDBOX/p.json" && mv "$SANDBOX/p.json" "$QI_PROFILE_DIR/profile.json"
P="$SCRIPTS/validation-plan.mjs"

cat > "$SANDBOX/inv.json" <<'J'
{"base":"http://localhost:8080","build":"1.2.3","routes":{
  "/projects/new":{"example":"/projects/new","forms":[{"name":"New project","submit":"Create","fields":[
    {"label":"Name","type":"text","name":"name","required":true,"minlength":null,"maxlength":50,"min":null,"max":null,"step":null,"pattern":null},
    {"label":"Owner email","type":"email","name":"email","required":true,"minlength":null,"maxlength":null,"min":null,"max":null,"step":null,"pattern":null},
    {"label":"Budget","type":"number","name":"budget","required":false,"minlength":null,"maxlength":null,"min":0,"max":100,"step":1,"pattern":null},
    {"label":"Website","type":"url","name":"web","required":false,"minlength":null,"maxlength":null,"min":null,"max":null,"step":null,"pattern":null},
    {"label":"Start","type":"date","name":"start","required":false,"minlength":null,"maxlength":null,"min":null,"max":null,"step":null,"pattern":null},
    {"label":"Code","type":"text","name":"code","required":false,"minlength":null,"maxlength":null,"min":null,"max":null,"step":null,"pattern":"[A-Z]{3}"},
    {"label":"Category","type":"select","name":"cat","required":true,"minlength":null,"maxlength":null,"min":null,"max":null,"step":null,"pattern":null},
    {"label":"I agree","type":"checkbox","name":"agree","required":true,"minlength":null,"maxlength":null,"min":null,"max":null,"step":null,"pattern":null}]}]},
  "/contact":{"example":"/contact","forms":[{"name":"Contact","submit":"Send","fields":[
    {"label":"Message","type":"textarea","name":"msg","required":true,"minlength":null,"maxlength":null,"min":null,"max":null,"step":null,"pattern":null}]}]},
  "/settings":{"example":"/settings","forms":[{"name":"Danger zone","submit":"Delete account","fields":[
    {"label":"Confirm","type":"text","name":"confirm","required":true}]}]},
  "/admin":{"example":"/admin","forms":[{"name":"Import","submit":"Import","fields":[{"label":"Source","type":"url","required":true}]}]},
  "/search":{"example":"/search","forms":[{"name":"form-1","submit":null,"fields":[{"label":"Search","type":"search","required":false}]}]},
  "/account":{"example":"/account","forms":[{"name":"Change password","submit":"Save","fields":[{"label":"New password","type":"password","required":true}]}]},
  "/broken":{"example":"/broken","error":"timeout"}}}
J

# ---------------------------------------------------------------- dry run
OUT="$SANDBOX/vout"
p="$(node "$P" "$SANDBOX/inv.json" --build 1.2.3 --out "$OUT" --dry-run)"
[ -e "$OUT" ] && { echo "  --dry-run wrote $OUT"; FAILED=1; }
[ -e "$WORK_DIR/validation" ] && { echo "  --dry-run wrote under work/validation"; FAILED=1; }
assert "build, base, two planned forms" '.build == "1.2.3" and .base == "http://localhost:8080" and .forms == 2' "$p"
kinds() { printf '%s' "$p" | jq -c --arg f "$1" '[.cases[] | select(.field == $f) | .kind]'; }
assert_eq "text with maxlength" '["required-empty","whitespace","max-len","max-len+1","unicode","rtl","emoji","html"]' "$(kinds Name)"
assert_eq "email: no free-text cases, wrong type" '["required-empty","whitespace","long","wrong-type"]' "$(kinds 'Owner email')"
assert_eq "number with min/max" '["wrong-type","num-below","num-above"]' "$(kinds Budget)"
assert_eq "optional url" '["whitespace","long","wrong-type"]' "$(kinds Website)"
assert_eq "date" '["wrong-type"]' "$(kinds Start)"
assert_eq "pattern" '["whitespace","long","unicode","rtl","emoji","html","pattern-miss"]' "$(kinds Code)"
assert_eq "required select: nothing to empty" '[]' "$(kinds Category)"
assert_eq "required checkbox" '["required-empty"]' "$(kinds 'I agree')"
assert_eq "textarea" '["required-empty","whitespace","long","unicode","rtl","emoji","html"]' "$(kinds Message)"
assert "values" '[.cases[] | select(.field=="Name")] as $n
  | ($n[] | select(.kind=="max-len") | .value | length) == 50 and ($n[] | select(.kind=="max-len+1") | .value | length) == 51
  and ($n[] | select(.kind=="max-len+1") | .maxlength) == 50
  and ([.cases[] | select(.kind=="long") | .value | length] | unique) == [5000]
  and (.cases[] | select(.field=="Budget" and .kind=="num-below") | .value) == "-1"
  and (.cases[] | select(.field=="Budget" and .kind=="num-above") | .value) == "101"
  and (.cases[] | select(.field=="Start") | .value) == "2026-13-45"
  and (.cases[] | select(.field=="Code" and .kind=="pattern-miss") | .value) == "!!!"' "$p"
assert "oracles" '([.cases[] | select(.kind=="required-empty" or .kind=="wrong-type" or .kind=="max-len+1" or .kind=="num-below" or .kind=="pattern-miss") | .oracle] | unique) == ["refused-visibly"]
  and ([.cases[] | select(.kind=="unicode" or .kind=="html" or .kind=="long" or .kind=="max-len") | .oracle] | unique) == ["refused-or-intact"]
  and (.cases[] | select(.field=="Name" and .kind=="whitespace") | .oracle) == "refused-visibly"
  and (.cases[] | select(.field=="Website" and .kind=="whitespace") | .oracle) == "refused-or-intact"
  and ([.cases[] | select(.kind=="duplicate-submit") | .oracle] | unique) == ["single-effect"]' "$p"
assert "one duplicate-submit per form, filling every field" '[.cases[] | select(.kind=="duplicate-submit") | .form] == ["Contact","New project"]
  and (.cases[] | select(.kind=="duplicate-submit" and .form=="New project") | .field == null and (.fill | keys | length) == 8)' "$p"
assert "fillers: the other required fields, unreachable addresses" '.cases[] | select(.field=="Name" and .kind=="unicode")
  | (.id | ltrimstr("VAL-")) as $k | .fill == {"Owner email": "qa-val-\($k)@example.invalid", "Category": {"select":"first"}, "I agree": {"check":true}}' "$p"
assert "duplicate-submit fillers" '.cases[] | select(.kind=="duplicate-submit" and .form=="New project") | .fill as $f
  | $f.Budget == "0" and $f.Website == "https://example.invalid/qa" and $f.Start == "2026-01-15" and ($f.Name | test("^qa-val-[0-9]+$"))' "$p"
assert "case shape" '.cases[0] | keys == ["example","field","fill","form","id","kind","oracle","page","submit","type","value"]' "$p"
assert "ids: page, form, field, kind order" '[.cases[].id] == [range(1; (.cases | length) + 1) | "VAL-\(.)"]
  and .cases[0].page == "/contact" and .cases[0].kind == "required-empty"
  and ([.cases[] | select(.page=="/projects/new") | .field] | map(select(. != null)) | . == (. | sort))' "$p"
assert "skips with reasons" '(.skipped | map({(.page): .reason}) | add) as $s
  | ($s["/settings"] | test("destructive")) and ($s["/admin"] | test("validation.exclude")) and ($s["/search"] | test("no submit"))
  and ($s["/account"] | test("password")) and (.skipped | length) == 4' "$p"
p2="$(node "$P" "$SANDBOX/inv.json" --build 1.2.3 --dry-run)"
assert_eq "stable ids across runs" "$(printf '%s' "$p" | jq -c '.cases')" "$(printf '%s' "$p2" | jq -c '.cases')"

# ---------------------------------------------------------------- the cap
c="$(node "$P" "$SANDBOX/inv.json" --build 1.2.3 --max-cases 3 --dry-run)"
assert "--max-cases round-robins over forms" '(.cases | length) == 3 and ([.cases[].form] | unique) == ["Contact","New project"]
  and (.notes | map(select(test("capped at 3 of"))) | length) == 1' "$c"
full_id="$(printf '%s' "$p" | jq -r '.cases[] | select(.field=="Budget" and .kind=="wrong-type") | .id')"
assert "a capped case keeps its id" "[.cases[] | select(.field==\"Budget\") | .id] == [\"$full_id\"]" "$c"
c="$(node "$P" "$SANDBOX/inv.json" --build 1.2.3 --max-cases 7 --dry-run)"
assert "within a form, round-robin over fields" '[.cases[] | select(.form=="New project") | .field] | unique | length == 3' "$c"
echo "- validation_max_cases: 4" >> "$WORK_DIR/CONFIG.md"
assert "cap from the config" '(.cases | length) == 4' "$(node "$P" "$SANDBOX/inv.json" --build 1.2.3 --dry-run)"

# ---------------------------------------------------------------- write, guard, usage
s="$(node "$P" "$SANDBOX/inv.json" --build 1.2.3)"
assert "summary names the plan" '.plan | endswith("/validation/1.2.3/plan.json")' "$s"
assert "summary counts" '.forms == 2 and .cases == 4 and .skipped == 4 and (.notes | length) == 1' "$s"
assert "plan.json written" '.build == "1.2.3" and (.cases | length) == 4 and (.generated_utc | test("^[0-9-]+T[0-9:]+Z$"))' "$(cat "$WORK_DIR/validation/1.2.3/plan.json" 2>/dev/null)"
node "$P" "$SANDBOX/inv.json" --build 1.2.3 --base http://staging.example.com --dry-run >/dev/null 2>&1
assert_eq "a non-local --base is refused" 2 "$?"
jq '.base = "https://app.example.com"' "$SANDBOX/inv.json" > "$SANDBOX/remote.json"
node "$P" "$SANDBOX/remote.json" --build 1.2.3 --dry-run >/dev/null 2>&1
assert_eq "a non-local inventory base is refused" 2 "$?"
jq 'del(.build)' "$SANDBOX/inv.json" > "$SANDBOX/nobuild.json"
node "$P" "$SANDBOX/nobuild.json" --dry-run >/dev/null 2>&1
assert_eq "no build -> usage" 2 "$?"
echo '{"base":"http://localhost","routes":{"/":{"example":"/","inputs":["Search"]}}}' > "$SANDBOX/old.json"
assert "a map without forms says so" '.forms == 0 and .cases == [] and (.notes[0] | test("no forms"))' "$(node "$P" "$SANDBOX/old.json" --build 9 --dry-run)"

# The e2e half and the map stay wired to the same plan and the same DANGER.
grep -q 'QI_VALIDATION_INPUT' "$SCRIPTS/suite-skeleton/tests/validation.e2e.ts" || { echo "  validation.e2e.ts does not read QI_VALIDATION_INPUT"; FAILED=1; }
grep -q "from './lib/danger.mjs'" "$SCRIPTS/ui-inventory.mjs" || { echo "  ui-inventory.mjs does not use lib/danger.mjs"; FAILED=1; }
grep -q 'const DANGER' "$SCRIPTS/ui-inventory.mjs" && { echo "  ui-inventory.mjs keeps its own DANGER"; FAILED=1; }
# ---------------------------------------------------------------- results from the runs
R="$SCRIPTS/validation-results.mjs"; PL="$WORK_DIR/validation/1.2.3/plan.json"
export QI_RUNS_ROOT="$SANDBOX/runs"; mkdir -p "$QI_RUNS_ROOT/v1" "$QI_RUNS_ROOT/v1c"
ids=($(jq -r '.cases[].id | ascii_downcase' "$PL"))
jq -nc --arg a "${ids[0]}" --arg b "${ids[1]}" --arg c "${ids[2]}" '{run:{results:[
  {tags:["validation",$a], status:"passed", attempts:[{}]},
  {tags:["validation",$b], status:"failed", attempts:[{error:{message:"[value-intact] the field holds a different value\nExpected …"}}]},
  {tags:["validation",$c], status:"failed", attempts:[{error:{message:"[setup] Upload button not found"}}]}]}}' > "$QI_RUNS_ROOT/v1/report.json"
s="$(node "$R" "$PL" --run v1)"
assert "outcomes and severity from the oracle prefix" '.cases == 4 and .ok == 1 and .major == 1 and .blocked == 2 and .flaky == 0' "$s"
assert "results.json beside the plan" '.run == "v1" and (.cases[1] | .result == "finding" and .severity == "major" and (.message | test("^\\[value-intact\\]")))
  and .cases[2].result == "blocked" and .cases[3].message == "not run"' "$(cat "$WORK_DIR/validation/1.2.3/results.json")"
jq -nc --arg b "${ids[1]}" '{run:{results:[{tags:["validation",$b], status:"passed", attempts:[{}]},{tags:["validation",$b], status:"failed", attempts:[{}]}]}}' > "$QI_RUNS_ROOT/v1c/report.json"
assert "a confirmation that passes once makes it flaky" '.major == 0 and .flaky == 1' "$(node "$R" "$PL" --run v1 --confirm v1c)"
node "$R" "$PL" >/dev/null 2>&1; assert_eq "no run label -> usage" 2 "$?"
exit $FAILED
