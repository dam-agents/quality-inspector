#!/usr/bin/env bash
# preflight.sh audit: needs-review signal items per week (Monday UTC) from the regression verdicts files;
# the week's speed and cost from issue_done and env_up events.
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
d="$(date -u +%Y-%m-%d)"; old="$(iso_ago $((8 * 1440)))"
{ for x in "40 100" "90 50" "60 200"; do set -- $x
    printf '{"ts":"%s","event":"issue_done","msg":"issue=1 verdict=verified minutes=%s model_steps=%s"}\n' "$(iso_ago 30)" "$1" "$2"; done
  printf '{"ts":"%s","event":"issue_done","msg":"issue=2 verdict=failed minutes=999 model_steps=999"}\n' "$old"
  printf '{"ts":"%s","event":"issue_done","msg":"issue=3 verdict=failed"}\n' "$(iso_ago 30)"
  printf '{"ts":"%s","event":"env_up","msg":"product at build 1.0.0 took_s=%s"}\n' "$(iso_ago 30)" 600 "$(iso_ago 20)" 900
} > "$WORK_DIR/logs/events-$d.jsonl"
out="$(bash "$SCRIPTS/preflight.sh" audit)"
assert "weekly signal counts, an unreadable file skipped" '.stats.signals_by_week == {"2026-10-05":3,"2026-10-12":0}' "$out"
assert "the week's speed and cost; an older event and a line without numbers skipped" '.stats.cost_7d == {"issues_done":4,"minutes_p50":60,"minutes_total":190,
  "model_steps_p50":100,"model_steps_total":350,"installs":2,"install_s_p50":600}' "$out"
exit $FAILED
