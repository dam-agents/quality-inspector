#!/usr/bin/env bash
# Daily media sweep: old raw runs and old delivered report media go; undelivered evidence stays.
. "$(dirname "$0")/lib.sh"
seed_work
echo '[]' > "$STUB_DIR/issues.json"
old() { mkdir -p "$1"; touch -t 202001010000 "$1"; }
old "$WORK_DIR/suite/.e2e/runs/issue-1-candidate"
mkdir -p "$WORK_DIR/suite/.e2e/runs/issue-2-candidate"
old "$WORK_DIR/issues/1/report-a-c/media"; touch "$WORK_DIR/issues/1/artifact.id"; touch -t 202001010000 "$WORK_DIR/issues/1/report-a-c/media"
old "$WORK_DIR/issues/2/report-b-c/media"
old "$WORK_DIR/security/c1/report/media"; touch "$WORK_DIR/security/c1/artifact.id"; touch -t 202001010000 "$WORK_DIR/security/c1/report/media"
out="$(bash "$SCRIPTS/preflight.sh" issues)"
[ ! -d "$WORK_DIR/suite/.e2e/runs/issue-1-candidate" ] || { echo "  old raw run kept"; FAILED=1; }
[ -d "$WORK_DIR/suite/.e2e/runs/issue-2-candidate" ] || { echo "  fresh raw run deleted"; FAILED=1; }
[ ! -d "$WORK_DIR/issues/1/report-a-c/media" ] || { echo "  delivered old media kept"; FAILED=1; }
[ -d "$WORK_DIR/issues/2/report-b-c/media" ] || { echo "  undelivered evidence deleted"; FAILED=1; }
[ ! -d "$WORK_DIR/security/c1/report/media" ] || { echo "  delivered old security media kept"; FAILED=1; }
assert "sweep is logged" '.logs | map(select(test("retention: removed 3"))) | length == 1' "$out"
exit $FAILED
