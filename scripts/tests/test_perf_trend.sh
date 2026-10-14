#!/usr/bin/env bash
# perf-trend.mjs: a test that got much slower than its history is named; noise, failures and
# a short history are not; a run is recorded once; an unreadable trend file is backed up.
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
R="$WORK_DIR/suite/.e2e/runs"
mk_run() { # <label> <mtime YYYYMMDDhhmm> <ms of A> <ms of B> <status of C>
  mkdir -p "$R/$1"
  cat > "$R/$1/report.json" <<J
{"run":{"results":[
 {"titlePath":["#1 AC-1: slow"],"status":"passed","attempts":[{"durationMs":$3}]},
 {"titlePath":["#2 AC-1: fast"],"status":"passed","durationMs":$4,"attempts":[{"durationMs":1}]},
 {"titlePath":["#3 AC-1: broken"],"status":"$5","attempts":[{"durationMs":60000}]},
 {"titlePath":["not selected"],"selected":false,"status":"passed","attempts":[{"durationMs":99999}]}]}}
J
  touch -t "$2" "$R/$1/report.json"
}
mk_run regression-b1 202610010300 4000 300 passed
mk_run regression-b2 202610020300 4100 310 passed
mk_run regression-b3 202610030300 3900 290 passed
mk_run regression-b4 202610040300 4000 300 passed
mk_run regression-b5 202610050300 9000 900 failed
mk_run confirm-b5 202610050400 99999 99999 passed

out="$(node "$SCRIPTS/perf-trend.mjs")"
assert "judges the newest regression run" '.latest == "regression-b5" and .tests == 2 and .perf_factor == 2' "$out"
assert "only the test past factor and floor (B is 3x but +600 ms; C failed)" '.slow_tests | length == 1 and .[0].title == "#1 AC-1: slow" and .[0].latest_ms == 9000 and .[0].median_ms == 4000 and .[0].runs == 4' "$out"
assert "the explanation names both numbers" '.slow_tests[0].explanation | test("9000 ms") and test("4000 ms")' "$out"
t="$WORK_DIR/perf/trend.json"
[ -f "$t" ] || { echo "  work/perf/trend.json not written"; FAILED=1; }
assert "history kept per test, confirm runs ignored" '.runs == ["regression-b1","regression-b2","regression-b3","regression-b4","regression-b5"] and (.tests["#1 AC-1: slow"].samples | length) == 5 and (.tests | has("not selected") | not)' "$(cat "$t")"
assert_eq "a second call changes nothing" "$out" "$(node "$SCRIPTS/perf-trend.mjs")"
assert "runs recorded once" '.runs | length == 5' "$(cat "$t")"
assert "--perf-factor raises the bar" '.slow_tests == []' "$(node "$SCRIPTS/perf-trend.mjs" --perf-factor 3)"
assert "fewer than three earlier runs is no trend" '.latest == "regression-b3" and .slow_tests == []' "$(node "$SCRIPTS/perf-trend.mjs" regression-b3)"

printf 'not json' > "$t"
node "$SCRIPTS/perf-trend.mjs" >/dev/null 2>&1
[ "$(ls "$WORK_DIR/backup" 2>/dev/null | grep -c '^perf-trend.json\.')" = 1 ] || { echo "  unreadable trend.json not backed up"; FAILED=1; }
assert "history rebuilt from the runs still on disk" '.runs | length == 5' "$(cat "$t")"
rm -rf "$R"
assert "no runs: nothing to judge" '.slow_tests == []' "$(node "$SCRIPTS/perf-trend.mjs")"
exit $FAILED
