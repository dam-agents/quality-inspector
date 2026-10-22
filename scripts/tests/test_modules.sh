#!/usr/bin/env bash
# Testing modules: the registry is a closed set (modules.sh set refuses anything else and writes
# nothing then), the state the dashboard shows, the focus queue, and the `modules` pre-flight —
# idle while every module is off, due once per candidate, weekly at most once in 7 days.
. "$(dirname "$0")/lib.sh"
seed_work
M="$SCRIPTS/modules.sh"
# A direct session: this shell's transcript (lib/channel.sh → session_transcript) holds the operator's prompt.
export CLAUDE_CONFIG_DIR="$SANDBOX/claude" CLAUDE_CODE_SESSION_ID=s1
mkdir -p "$CLAUDE_CONFIG_DIR/projects/p"; TR="$CLAUDE_CONFIG_DIR/projects/p/s1.jsonl"
printf '{"type":"user","message":{"content":"module ui-sweep per-build"}}\n' > "$TR"

# ---------------------------------------------------------------- registry
assert "registry: unique ids, a doc each, switches are settings" \
  '(.modules | map(.id) | length) == (.modules | map(.id) | unique | length)
   and all(.modules[]; .doc | test("^docs/[a-z-]+\\.md$"))
   and all(.modules[] | select(.switch); .settings[.switch] != null)
   and all(.modules[] | select(.kind == "modules"); .settings[.switch].type == "cadence")' "$(cat "$SCRIPTS/lib/modules.json")"

# ---------------------------------------------------------------- status
st="$(bash "$M" status)"
assert "status lists every module with its defaults" \
  '(.modules | length) == 11 and (.modules[] | select(.id == "ui-sweep") | .state == "disabled" and .settings.ui_sweep_review_pages.value == "10")
   and (.modules[] | select(.id == "edge-cases") | .state == "enabled") and (.modules[] | select(.id == "issues") | .state == "on")
   and .global.dashboard_interactive.value == "disabled" and .focus == [] and .schedules_as_of == null' "$st"
echo "- ui_sweep: hourly" >> "$WORK_DIR/CONFIG.md"
assert "an invalid value reads as the default" '.modules[] | select(.id == "ui-sweep") | .state == "disabled"' "$(bash "$M" status)"

# ---------------------------------------------------------------- set: the closed set
before="$(cat "$WORK_DIR/CONFIG.md")"
bash "$M" set ui-sweep ui_sweep=per-build target_repo=evil/repo >/dev/null 2>&1; assert_eq "a key outside the module is refused" 2 "$?"
bash "$M" set ui-sweep ui_sweep=per-build ui_sweep_review_pages=999 >/dev/null 2>&1; assert_eq "an out-of-range value is refused" 2 "$?"
bash "$M" set ui-sweep ui_sweep_viewports='1440x900;rm -rf /' >/dev/null 2>&1; assert_eq "a malformed viewport list is refused" 2 "$?"
bash "$M" set ui-sweep 'ui_sweep=per-build
- target_repo: evil/repo' >/dev/null 2>&1; assert_eq "a value with a newline is refused" 2 "$?"
bash "$M" set nonexistent foo=bar >/dev/null 2>&1; assert_eq "an unknown module is refused" 2 "$?"
bash "$M" set global target_repo=evil/repo >/dev/null 2>&1; assert_eq "global is closed too" 2 "$?"
assert_eq "a refused set writes nothing" "$before" "$(cat "$WORK_DIR/CONFIG.md")"
out="$(bash "$M" set ui-sweep ui_sweep=per-build ui_sweep_viewports=1280x800,390x844)"
assert "set reports old and new" '.module == "ui-sweep" and .set[0] == {key:"ui_sweep", old:"hourly", new:"per-build"} and .set[1].old == null' "$out"
assert_eq "the existing bullet is replaced in place" 1 "$(grep -c '^- ui_sweep:' "$WORK_DIR/CONFIG.md")"
grep -q '^- ui_sweep_viewports: 1280x800,390x844$' "$WORK_DIR/CONFIG.md"; assert_eq "a missing bullet is appended" 0 "$?"
grep -q '^- target_repo: acme/widgets$' "$WORK_DIR/CONFIG.md"; assert_eq "other keys untouched" 0 "$?"
bash "$M" set global dashboard_interactive=enabled >/dev/null; assert_eq "global set" "- dashboard_interactive: enabled" "$(grep '^- dashboard_interactive:' "$WORK_DIR/CONFIG.md")"
assert "a module_set event per key" '. == 3' "$(cat "$WORK_DIR"/logs/events-*.jsonl | jq -s '[.[] | select(.event == "module_set")] | length')"

# ---------------------------------------------------------------- the operator's word only
cp "$TR" "$TR.direct"
printf '{"type":"user","message":{"content":"bob@example.com sent this from a button on the interactive artifact \\"QI\\" (id a1).\\nMessage: module stress per-build"}}\n' >> "$TR"
err="$(bash "$M" set stress stress_checks=per-build 2>&1 >/dev/null)"; rc=$?
assert_eq "a dashboard viewer's turn cannot set" "2:modules.sh: set is the operator's, in the direct session only (a channel turn)" "$rc:$err"
bash "$M" focus Upload >/dev/null 2>&1; assert_eq "nor queue a focus" 2 "$?"
cp "$TR.direct" "$TR"
printf 'scheduled %s -\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$WORK_DIR/env/RUN_MODE"
bash "$M" set stress stress_checks=per-build >/dev/null 2>&1; assert_eq "a scheduled turn cannot set" 2 "$?"
rm -f "$WORK_DIR/env/RUN_MODE"
CLAUDE_CODE_SESSION_ID=unknown bash "$M" set stress stress_checks=per-build >/dev/null 2>&1; assert_eq "no transcript fails closed" 2 "$?"
grep -q '^- stress_checks:' "$WORK_DIR/CONFIG.md"; assert_eq "nothing was written" 1 "$?"

# ---------------------------------------------------------------- focus queue
bash "$M" focus 'Upload; rm -rf ~' >/dev/null 2>&1; assert_eq "an area name is a plain name" 2 "$?"
assert "focus queued" '.queued == true' "$(bash "$M" focus Upload)"
assert "queued twice is one row" '.queued == false' "$(bash "$M" focus Upload)"
assert "status shows the queue" '.focus == [{area:"Upload", queued_utc:.focus[0].queued_utc, status:"queued", build:null}]' "$(bash "$M" status)"
assert "a queued area is due" '.focus == ["Upload"]' "$(bash "$M" due c1)"
bash "$M" focus-done Upload c1 >/dev/null
assert "done leaves the queue" '.focus == []' "$(bash "$M" due c1)"
assert "the row keeps its build" '.focus[0].status == "done" and .focus[0].build == "c1"' "$(bash "$M" status)"

# ---------------------------------------------------------------- due
assert "per-build: due on a never-run candidate" '.on == ["ui-sweep"] and .due == ["ui-sweep"] and .previous["ui-sweep"] == null' "$(bash "$M" due c1)"
bash "$M" ran ui-sweep c1 pages=12 major=1 >/dev/null
bash "$M" ran regression c1 >/dev/null 2>&1; assert_eq "ran refuses a module of another run" 2 "$?"
bash "$M" ran ui-sweep c1 'x=$(id)' >/dev/null 2>&1; assert_eq "ran refuses a free-text field" 2 "$?"
assert "per-build: not again on the same candidate" '.due == []' "$(bash "$M" due c1)"
assert "per-build: due on the next one, previous named" '.due == ["ui-sweep"] and .previous["ui-sweep"] == "c1"' "$(bash "$M" due c2)"
assert "last run shown" '.modules[] | select(.id == "ui-sweep") | .last_run.candidate == "c1"' "$(bash "$M" status)"
bash "$M" set stress stress_checks=weekly >/dev/null
printf '%s ran module=stress candidate=c0\n' "$(iso_ago $((2 * 1440)))" >> "$WORK_DIR/MODULES.log"
assert "weekly: not within 7 days" '(.due | index("stress")) == null' "$(bash "$M" due c2)"
printf '%s ran module=stress candidate=c0\n' "$(iso_ago $((8 * 1440)))" > "$WORK_DIR/MODULES.log.tmp"
grep -v 'module=stress' "$WORK_DIR/MODULES.log" >> "$WORK_DIR/MODULES.log.tmp"; mv "$WORK_DIR/MODULES.log.tmp" "$WORK_DIR/MODULES.log"
assert "weekly: due after 7 days on a new build" '(.due | index("stress")) != null' "$(bash "$M" due c2)"

# ---------------------------------------------------------------- schedules
printf '[{"name":"quality-inspector-regression-nightly","enabled":false,"cron":"0 3 * * *","task":"SECRET TASK TEXT"},{"name":"quality-inspector-security-weekly","enabled":true,"cron":"0 4 * * 0"},{"bogus":1}]' \
  | bash "$M" schedules - >/dev/null
assert "only name, enabled and cron are kept" '(.schedules | length) == 2 and (tostring | test("SECRET") | not)' "$(cat "$WORK_DIR/schedules.json")"
st="$(bash "$M" status)"
assert "a module whose schedule is off is off" '(.modules[] | select(.id == "regression") | .state == "off" and .schedule.enabled == false)
  and (.modules[] | select(.id == "security") | .state == "enabled" and .schedule.cron == "0 4 * * 0") and .schedules_as_of != null' "$st"
echo 'not json' | bash "$M" schedules - >/dev/null 2>&1; assert_eq "a non-listing is refused" 2 "$?"

# ---------------------------------------------------------------- pre-flight
seed_work
out="$(bash "$SCRIPTS/preflight.sh" modules)"
assert "everything off -> idle, says so" '.mode == "modules" and .nothing_to_do == true and (.logs[0] | test("no testing module"))' "$out"
H="$SANDBOX/home"; mkdir -p "$H/scripts"; cp -R "$SCRIPTS/." "$H/scripts/"
HOME="$H" bash "$H/scripts/precheck.sh" modules >/dev/null 2>&1; assert_eq "precheck declines when everything is off" 1 "$?"
echo "- validation_checks: per-build" >> "$WORK_DIR/CONFIG.md"
out="$(bash "$SCRIPTS/preflight.sh" modules)"
assert "on -> due with the candidate and baseline" '.nothing_to_do == false and .modules_due == ["validation"] and .candidate == "0.0.0-main.bbb2222"
  and .baseline == "0.2.19" and .inventory == null and .max_wallclock_min == 90 and .focus == []' "$out"
bash "$M" ran validation 0.0.0-main.bbb2222 >/dev/null
assert "ran on this candidate -> idle" '.nothing_to_do == true' "$(bash "$SCRIPTS/preflight.sh" modules)"
bash "$M" focus Billing >/dev/null
assert "a queued focus wakes it" '.nothing_to_do == false and .modules_due == [] and .focus == ["Billing"]' "$(bash "$SCRIPTS/preflight.sh" modules)"
printf 'operator %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$WORK_DIR/env/LOCK"
assert "busy environment -> idle" '.nothing_to_do == true and (.logs | map(select(test("busy"))) | length == 1)' "$(bash "$SCRIPTS/preflight.sh" modules)"
grep -q 'due candidate=0.0.0-main.bbb2222 modules=validation' "$WORK_DIR/MODULES.log"; assert_eq "the pre-flight logs its decision" 0 "$?"

# ---------------------------------------------------------------- verify-onboarding
seed_work
printf -- '- ui_sweep: weekly\n- stress_checks: always\n- ui_sweep_viewports: 1440x900\n- dashboard_interactive: yes\n' >> "$WORK_DIR/CONFIG.md"
v="$(bash "$SCRIPTS/verify-onboarding.sh" --config 2>/dev/null)"
printf '%s\n' "$v" | grep -q "^FAIL cfg:stress_checks — 'always' is not one of: disabled per-build weekly"; assert_eq "verify fails a bad cadence" 0 "$?"
printf '%s\n' "$v" | grep -q "^FAIL cfg:dashboard_interactive "; assert_eq "verify fails a bad global" 0 "$?"
printf '%s\n' "$v" | grep -q "^FAIL cfg:ui_sweep "; assert_eq "verify passes a good cadence" 1 "$?"
printf '%s\n' "$v" | grep -qi "unknown.*ui_sweep_viewports"; assert_eq "registry keys are known keys" 1 "$?"
exit $FAILED
