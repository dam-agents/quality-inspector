#!/usr/bin/env bash
# precheck.sh: decline only on a sure nothing_to_do; everything else fails open.
. "$(dirname "$0")/lib.sh"
H="$SANDBOX/home"; mkdir -p "$H/scripts"; cp "$SCRIPTS/precheck.sh" "$H/scripts/"
run() { printf '%s\n' "$1" > "$SANDBOX/out"; printf '#!/usr/bin/env bash\ncat "%s"\n' "$SANDBOX/out" > "$H/scripts/preflight.sh"
        HOME="$H" bash "$H/scripts/precheck.sh" issues >/dev/null 2>&1; echo $?; }
M="$WORK_DIR/env/RUN_MODE"
assert_eq "quiet -> decline" 1 "$(run '{"mode":"issues","nothing_to_do":true,"logs":[]}')"
[ ! -e "$M" ] || { echo "  a decline wrote the run marker"; FAILED=1; }
QI_PRECHECK_PROBE=1 run '{"mode":"issues","nothing_to_do":false,"issues_due":[{"issue":1}]}' >/dev/null
[ ! -e "$M" ] || { echo "  a probe wrote the run marker"; FAILED=1; }
assert_eq "worklist -> run" 0 "$(PLATFORM_SCHEDULE_ID=s1 run '{"mode":"issues","nothing_to_do":false,"issues_due":[{"issue":1}]}')"
grep -qE '^scheduled [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z s1$' "$M" 2>/dev/null || { echo "  a run did not write the run marker"; FAILED=1; }
rm -f "$M"; HOME="$H" bash "$H/scripts/precheck.sh" audit >/dev/null 2>&1; assert_eq "audit -> run" 0 "$?"
[ -e "$M" ] || { echo "  the audit did not write the run marker"; FAILED=1; }
assert_eq "error -> run" 0 "$(run '{"mode":"issues","nothing_to_do":true,"error":"boom"}')"
assert_eq "not JSON -> run" 0 "$(run 'garbage')"
# A Slack turn marks itself (docs/slack.md) and is never declined, even on nothing_to_do.
rm -f "$M"; printf '%s\n' '{"mode":"slack","nothing_to_do":true}' > "$SANDBOX/out"
o="$(HOME="$H" bash "$H/scripts/precheck.sh" slack 2>/dev/null)"; assert_eq "slack -> run" 0 "$?"
assert "slack -> the pre-flight's JSON" '.mode == "slack"' "$o"
grep -qE '^slack [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z -$' "$M" 2>/dev/null || { echo "  a Slack turn did not write its run marker"; FAILED=1; }
rm -f "$H/scripts/preflight.sh"
HOME="$H" bash "$H/scripts/precheck.sh" issues >/dev/null 2>&1; assert_eq "missing pre-flight -> run" 0 "$?"
exit $FAILED
