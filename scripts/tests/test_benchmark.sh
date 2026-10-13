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
exit $FAILED
