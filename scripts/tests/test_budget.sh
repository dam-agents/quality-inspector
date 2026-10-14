#!/usr/bin/env bash
# suite.sh budget: model-backed steps of the runs since the claim, minutes since it, what is exceeded.
. "$(dirname "$0")/lib.sh"
seed_work
R="$WORK_DIR/suite/.e2e/runs"; mkdir -p "$R/issue-1-candidate" "$R/old-run"
jq -nc '{run:{results:[{attempts:[{steps:[
  {api:"agent.act", cache:{mode:"self-finalized"}},
  {api:"agent.act", cache:{mode:"missed"}},
  {api:"agent.assert"},
  {api:"expect.toBeVisible"},
  {api:"test.step", steps:[{api:"agent.act", cache:{mode:"agent-concluded"}}]}]}]}]}}' > "$R/issue-1-candidate/report.json"
jq -nc '{run:{results:[{attempts:[{steps:[range(50) | {api:"agent.act"}]}]}]}}' > "$R/old-run/report.json"
touch -t 202001010000 "$R/old-run/report.json"
b() { bash "$SCRIPTS/suite.sh" budget "$1"; }

out="$(b "$(iso_ago 30)")"
assert "replays and runs before the claim do not count" '.runs == 1 and .model_steps == 3 and .exceeded == []' "$out"
assert "defaults" '.max_wallclock_min == 150 and .max_model_steps == 400 and (.elapsed_min | . >= 29 and . <= 31)' "$out"
out="$(b "$(iso_ago 200)")"
assert "wall clock over the default 150" '.exceeded == ["wallclock"]' "$out"
echo "- max_model_steps_per_issue: 2" >> "$WORK_DIR/CONFIG.md"
assert "configured step cap" '.exceeded == ["model_steps"]' "$(b "$(iso_ago 30)")"
bash "$SCRIPTS/suite.sh" budget nonsense >/dev/null 2>&1; assert_eq "bad claim time -> usage error" 2 "$?"
exit $FAILED
