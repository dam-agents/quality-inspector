#!/usr/bin/env bash
# benchmark.sh: inputs never carry the answers; scoring counts false verdicts; due-ness follows setup changes.
. "$(dirname "$0")/lib.sh"
seed_work
B="$WORK_DIR/benchmark"; mkdir -p "$B"
assert "no cases -> not due" '.due == false' "$(bash "$SCRIPTS/benchmark.sh" due)"
cat > "$B/cases.json" <<'J'
[{"id":"real","type":"issue","issue":7,"candidate":"c","baseline":"b","expected":{"verdict":"verified","acs":{"AC-1":"verified"}},"note":"secret note"},
 {"id":"control","type":"criteria","build":"c","criteria":[{"id":"AC-1","then":"a unicorn"}],"expected":{"acs":{"AC-1":"failed"}}}]
J
assert "never run -> due" '.due == true' "$(bash "$SCRIPTS/benchmark.sh" due)"
bash "$SCRIPTS/benchmark.sh" prepare r1 >/dev/null
assert "input carries no expected answer and no note" 'has("expected") | not' "$(cat "$B/runs/r1/real/input.json")"
assert "input carries its tag" '.tag == "issue-bench-real" and (has("note") | not)' "$(cat "$B/runs/r1/real/input.json")"
echo '{"verdict":"verified","acs":[{"id":"AC-1","verdict":"verified"}],"minutes":30,"cost_usd":2}' > "$B/runs/r1/real/verdicts.json"
echo '{"verdict":"verified","acs":[{"id":"AC-1","verdict":"verified"}],"minutes":10,"cost_usd":1}' > "$B/runs/r1/control/verdicts.json"
s="$(bash "$SCRIPTS/benchmark.sh" score r1)"
assert "one false verified, half the ACs right" '.false_verified == 1 and .ac_accuracy == 0.5 and .issue_accuracy == 1 and .cost_usd == 3' "$s"
assert "same setup, just ran -> not due" '.due == false' "$(bash "$SCRIPTS/benchmark.sh" due)"
echo "- e2e_model: another-model" >> "$WORK_DIR/CONFIG.md"
assert "model change -> due" '.due == true and (.reason | test("changed"))' "$(bash "$SCRIPTS/benchmark.sh" due)"
# Escape cases (docs/benchmark.md → Escape cases): graded by stage, a stage holds only while the one before held.
cat > "$B/cases.json" <<'J'
[{"id":"escape-E-1","type":"issue","issue":42,"candidate":"c","baseline":"b","expected":{"bug":"An upload of a file with a long name stops at 99 %."}},
 {"id":"escape-E-2","type":"issue","issue":43,"candidate":"c","expected":{"bug":"The viewer can delete a folder."}},
 {"id":"escape-E-3","type":"issue","issue":44,"candidate":"c","expected":{"bug":"The count is wrong after a reload."}}]
J
bash "$SCRIPTS/benchmark.sh" prepare r2 >/dev/null
assert "an escape input carries no bug" '(has("expected") | not) and .issue == 42' "$(cat "$B/runs/r2/escape-E-1/input.json")"
for c in escape-E-1 escape-E-2 escape-E-3; do echo '{"verdict":"verified","acs":[]}' > "$B/runs/r2/$c/verdicts.json"; done
echo '{"stages":{"criteria":true,"test":true,"flagged":true,"reported":true}}' > "$B/runs/r2/escape-E-1/grade.json"
echo '{"stages":{"criteria":true,"test":false,"flagged":true,"reported":true}}' > "$B/runs/r2/escape-E-2/grade.json"
s="$(bash "$SCRIPTS/benchmark.sh" score r2)"
assert "recall per stage over the graded cases" '.escape_cases == 3 and .escape_recall == {"criteria":1,"test":0.5,"flagged":0.5,"reported":0.5}' "$s"
assert "lost_at: none, the test stage, ungraded" '[.per_case[].lost_at] == [null, "test", "ungraded"]' "$s"
echo '[{"id":"x","type":"issue","expected":{"bug":7}}]' > "$B/cases.json"
bash "$SCRIPTS/benchmark.sh" prepare r3 >/dev/null 2>&1; assert_eq "a bug that is no sentence is refused" 1 "$?"
exit $FAILED
