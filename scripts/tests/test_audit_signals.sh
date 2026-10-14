#!/usr/bin/env bash
# preflight.sh audit: needs-review signal items per week (Monday UTC) from the regression verdicts files.
. "$(dirname "$0")/lib.sh"
seed_work
echo '[]' > "$STUB_DIR/issues.json"
v() { # <build> <generated_utc> <signals json>
  mkdir -p "$WORK_DIR/regression/$1"
  printf '{"mode":"regression","candidate":"%s","generated_utc":"%s","acs":[],"context":{"signals":%s}}\n' "$1" "$2" "$3" > "$WORK_DIR/regression/$1/verdicts.json"
}
v b1 2026-10-06T03:10:00Z '{"console_errors_new":[{"route":"/","verdict":"needs-review"}],"slow_tests":[{"title":"t","verdict":"needs-review"}]}'
v b2 2026-10-11T03:10:00Z '{"failed_requests_new":[{"route":"/x","verdict":"needs-review"}],"slower_pages":[]}'
v b3 2026-10-13T03:10:00Z '{}'
mkdir -p "$WORK_DIR/regression/b4" && printf 'broken' > "$WORK_DIR/regression/b4/verdicts.json"
out="$(bash "$SCRIPTS/preflight.sh" audit)"
assert "weekly signal counts, an unreadable file skipped" '.stats.signals_by_week == {"2026-10-05":3,"2026-10-12":0}' "$out"
exit $FAILED
