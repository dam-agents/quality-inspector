#!/usr/bin/env bash
# preflight.sh regression: no tests, same candidate, new candidate with drift.
. "$(dirname "$0")/lib.sh"
seed_work
out="$(bash "$SCRIPTS/preflight.sh" regression)"
assert "no regression tests -> idle" '.nothing_to_do==true' "$out"

mkdir -p "$WORK_DIR/suite/tests"
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
exit $FAILED
