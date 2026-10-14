#!/usr/bin/env bash
# preflight.sh regression: no tests, same candidate, new candidate with drift, confirmation settings; promotable never replays.
. "$(dirname "$0")/lib.sh"
seed_work
mkdir -p "$WORK_DIR/suite/tests"
# A promotable file is queued for the operator: not replayed, its hash not drift-checked.
printf '// AC-1 begin\nawait agent.assert("x");\n// AC-1 end\n' > "$WORK_DIR/suite/tests/issue-8.e2e.ts"
echo "| tests/issue-8.e2e.ts | 8 | promotable | 000000000000 | - |" >> "$WORK_DIR/SUITE.md"
out="$(bash "$SCRIPTS/preflight.sh" regression)"
assert "no regression tests (promotable only) -> idle" '.nothing_to_do==true' "$out"

cat > "$WORK_DIR/suite/tests/issue-7.e2e.ts" <<'T'
// AC-1 begin
await expect(x).toBeVisible();
// AC-1 end
T
h="$(bash "$SCRIPTS/check-asserts.sh" --hash "$WORK_DIR/suite/tests/issue-7.e2e.ts")"
echo "| tests/issue-7.e2e.ts | 7 | regression | $h | 2026-10-01T00:00:00Z |" >> "$WORK_DIR/SUITE.md"
out="$(bash "$SCRIPTS/preflight.sh" regression)"
assert "new candidate -> due" '.nothing_to_do==false and .candidate=="0.0.0-main.bbb2222" and .tests==["tests/issue-7.e2e.ts"] and .assert_drift==[]' "$out"

echo "2026-10-01T03:00:00Z ran candidate=0.0.0-main.bbb2222 passed=1 failed=0" >> "$WORK_DIR/REGRESSION.log"
out="$(bash "$SCRIPTS/preflight.sh" regression)"
assert "same candidate -> idle" '.nothing_to_do==true' "$out"

echo "2026-10-01T03:00:00Z ran candidate=0.0.0-main.aaa1111 passed=1 failed=0" >> "$WORK_DIR/REGRESSION.log"
sed -i.bak 's/toBeVisible()/toBeHidden()/' "$WORK_DIR/suite/tests/issue-7.e2e.ts"
out="$(bash "$SCRIPTS/preflight.sh" regression)"
assert "changed AC block is drift" '.assert_drift | length == 1 and .[0].test=="tests/issue-7.e2e.ts"' "$out"
assert "promotable is never replayed" '.tests == ["tests/issue-7.e2e.ts"]' "$out"
assert "previous candidate is the last one tested" '.previous_candidate == "0.0.0-main.aaa1111"' "$out"
assert "confirmation and bisection off by default" '.confirm_regressions == false and .bisect_max_steps == 0' "$out"
echo "- bisect_max_steps: 4" >> "$WORK_DIR/CONFIG.md"
out="$(bash "$SCRIPTS/preflight.sh" regression)"
assert "bisection without confirmation is ignored" '.bisect_max_steps == 0 and (.logs | map(select(test("needs confirm_regressions"))) | length == 1)' "$out"
echo "- confirm_regressions: enabled" >> "$WORK_DIR/CONFIG.md"
out="$(bash "$SCRIPTS/preflight.sh" regression)"
assert "confirmation and bisection on" '.confirm_regressions == true and .bisect_max_steps == 4' "$out"
exit $FAILED
