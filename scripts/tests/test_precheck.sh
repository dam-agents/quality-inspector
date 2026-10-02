#!/usr/bin/env bash
# precheck.sh: decline only on a sure nothing_to_do; everything else fails open.
. "$(dirname "$0")/lib.sh"
H="$SANDBOX/home"; mkdir -p "$H/scripts"; cp "$SCRIPTS/precheck.sh" "$H/scripts/"
run() { printf '%s\n' "$1" > "$SANDBOX/out"; printf '#!/usr/bin/env bash\ncat "%s"\n' "$SANDBOX/out" > "$H/scripts/preflight.sh"
        HOME="$H" bash "$H/scripts/precheck.sh" issues >/dev/null 2>&1; echo $?; }
assert_eq "quiet -> decline" 1 "$(run '{"mode":"issues","nothing_to_do":true,"logs":[]}')"
assert_eq "worklist -> run" 0 "$(run '{"mode":"issues","nothing_to_do":false,"issues_due":[{"issue":1}]}')"
assert_eq "error -> run" 0 "$(run '{"mode":"issues","nothing_to_do":true,"error":"boom"}')"
assert_eq "not JSON -> run" 0 "$(run 'garbage')"
rm -f "$H/scripts/preflight.sh"
HOME="$H" bash "$H/scripts/precheck.sh" issues >/dev/null 2>&1; assert_eq "missing pre-flight -> run" 0 "$?"
exit $FAILED
