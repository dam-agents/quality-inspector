#!/usr/bin/env bash
# One test case, several checks (scripts/lib/walk.mjs, docs/test-authoring.md → One walk, several checks):
# a result's tags name the criteria it checks, the stills `<id>: …` put them in order; a walk stops at
# the check that failed — the ones before it passed, the ones after it are not reached. A test of one
# criterion keeps its own status. suite.sh's summary, rerun.mjs and catalog.mjs read it the same way.
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
WALK="$SCRIPTS/lib/walk.mjs"
st() { printf '{"api":"app.screenshot","label":"%s"}' "$1"; }
cat > "$SANDBOX/report.json" <<JSON
{"run":{"status":"failed","results":[
 {"tags":["issue-42","ac-3","ac-1","ac-2"],"status":"failed","attempts":[{"steps":[{"api":"app.open","label":"/"},$(st 'AC-1: x'),{"api":"expect","label":"a"},$(st 'AC-2: y'),{"api":"expect","label":"b","status":"failed"},$(st 'AC-2: the failing check [mark 1,2,3,4]'),$(st 'AC-3: z')]}]},
 {"tags":["issue-42","ac-4"],"status":"timed-out","attempts":[{"steps":[]}]},
 {"tags":["issue-42","ac-5","ac-6"],"status":"failed","attempts":[{"steps":[{"api":"app.open","label":"/","status":"failed"},$(st 'AC-5: x'),$(st 'AC-6: y')]}]},
 {"tags":["issue-42","ac-7","ac-8"],"status":"failed","attempts":[{"steps":[$(st 'AC-7: x'),$(st 'AC-8: y'),{"api":"expect","label":"c","status":"failed"}]}]},
 {"tags":["issue-42","ac-9","in-1"],"status":"passed","attempts":[{"steps":[]}]}]}}
JSON
r="$(node "$WALK" "$SANDBOX/report.json")"
assert "in the walk's order; the failing check's still names it; after it not reached" '.[0] == [{"id":"AC-1","status":"passed"},{"id":"AC-2","status":"failed"},{"id":"AC-3","status":"not-reached"}]' "$r"
assert "one criterion: the test's own status" '.[1] == [{"id":"AC-4","status":"timed-out"}]' "$r"
assert "a walk that stopped before its first check reaches none" '.[2] == [{"id":"AC-5","status":"not-reached"},{"id":"AC-6","status":"not-reached"}]' "$r"
assert "no still of the failing check: the last check before the failed step" '.[3] == [{"id":"AC-7","status":"passed"},{"id":"AC-8","status":"failed"}]' "$r"
assert "a passed walk: every check passed, an intent among them" '.[4] == [{"id":"AC-9","status":"passed"},{"id":"IN-1","status":"passed"}]' "$r"
assert_eq "a report that cannot be read: no checks" "[]" "$(node "$WALK" "$SANDBOX/none.json")"

# rerun.mjs: each check its own row; only the check that stopped the walk carries the error.
mkdir -p "$SANDBOX/work/suite/.e2e/runs/r1"; cp "$SANDBOX/report.json" "$SANDBOX/work/suite/.e2e/runs/r1/report.json"
WORK_DIR="$SANDBOX/work" node "$SCRIPTS/rerun.mjs" r1 '#42' --build b1 >/dev/null 2>&1
f="$SANDBOX/work/reruns/issue-42/r1.json"
if [ -f "$f" ]; then
  assert "rerun: passed, failed and blocked by the walk" '.results["AC-1"].status == "passed" and .results["AC-2"].status == "failed" and .results["AC-3"].status == "blocked" and (.results["AC-3"].error | test("not reached"))' "$(cat "$f")"
else echo "  assertion failed: rerun.mjs wrote no file"; FAILED=1; fi
exit $FAILED
