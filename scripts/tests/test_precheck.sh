#!/usr/bin/env bash
# precheck.sh: decline only on a sure nothing_to_do; everything else fails open, and every run
# it lets through opens with the scheduled frame (lib/channel.sh) and writes no marker.
. "$(dirname "$0")/lib.sh"
H="$SANDBOX/home"; mkdir -p "$H/scripts/lib"; cp "$SCRIPTS/precheck.sh" "$H/scripts/"; cp "$SCRIPTS/lib/channel.sh" "$H/scripts/lib/"
run() { printf '%s\n' "$1" > "$SANDBOX/out"; printf '#!/usr/bin/env bash\ncat "%s"\n' "$SANDBOX/out" > "$H/scripts/preflight.sh"
        HOME="$H" bash "$H/scripts/precheck.sh" issues > "$SANDBOX/stdout" 2>/dev/null; echo $?; }
M="$WORK_DIR/env/RUN_MODE"
assert_eq "quiet -> decline" 1 "$(run '{"mode":"issues","nothing_to_do":true,"logs":[]}')"
assert_eq "worklist -> run" 0 "$(PLATFORM_SCHEDULE_ID=s1 run '{"mode":"issues","nothing_to_do":false,"issues_due":[{"issue":1}]}')"
assert_eq "a run opens with the scheduled frame" "<qi-scheduled-run>issues</qi-scheduled-run>" "$(head -1 "$SANDBOX/stdout")"
assert "then the worklist" '.issues_due[0].issue == 1' "$(tail -n +2 "$SANDBOX/stdout")"
[ ! -e "$M" ] || { echo "  a run wrote a run marker"; FAILED=1; }
( . "$SCRIPTS/lib/channel.sh"; T="$SANDBOX/t.jsonl"
  jq -nc --rawfile p "$SANDBOX/stdout" '{type:"user", message:{content:("QA issues run.\n" + $p)}}' > "$T"
  transcript_is_scheduled "$T" ) || { echo "  lib/channel.sh does not read the frame the Precheck prints"; FAILED=1; }
o="$(HOME="$H" bash "$H/scripts/precheck.sh" audit 2>/dev/null)"; assert_eq "audit -> run" 0 "$?"
assert_eq "the audit carries the frame alone" "<qi-scheduled-run>audit</qi-scheduled-run>" "$o"
mv "$H/scripts/lib/channel.sh" "$SANDBOX/channel.sh"
run '{"mode":"issues","nothing_to_do":false,"issues_due":[{"issue":1}]}' >/dev/null
assert_eq "without lib/channel.sh the frame is the same" "<qi-scheduled-run>issues</qi-scheduled-run>" "$(head -1 "$SANDBOX/stdout")"
mv "$SANDBOX/channel.sh" "$H/scripts/lib/channel.sh"
assert_eq "error -> run" 0 "$(run '{"mode":"issues","nothing_to_do":true,"error":"boom"}')"
assert_eq "not JSON -> run" 0 "$(run 'garbage')"
# A Slack turn is never declined, even on nothing_to_do, and writes no marker of its own: the
# policy hook knows it by its transcript. `slack <n>` marks the issue a Slack test delivers to
# (docs/slack.md) — only with a channel, a free environment, quota left and a session id.
rm -f "$M"; printf '%s\n' '{"mode":"slack","nothing_to_do":true,"channel":"C0123ABCD","environment":{"busy":false},"quota_left":1}' > "$SANDBOX/out"
o="$(HOME="$H" bash "$H/scripts/precheck.sh" slack 2>/dev/null)"; assert_eq "slack -> run" 0 "$?"
assert "slack -> the pre-flight's JSON alone, no frame" '.mode == "slack"' "$o"
[ ! -e "$M" ] || { echo "  a Slack turn without an issue wrote a run marker"; FAILED=1; }
o="$(HOME="$H" CLAUDE_CODE_SESSION_ID=sess-1 bash "$H/scripts/precheck.sh" slack 42 2>/dev/null)"
assert "slack 42 -> marked" '.marked == 42' "$o"
grep -qE '^slack [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z - 42 sess-1$' "$M" 2>/dev/null || { echo "  slack 42 did not write its run marker: $(cat "$M" 2>/dev/null)"; FAILED=1; }
for bad in '{"mode":"slack","channel":"C0123ABCD","environment":{"busy":true},"quota_left":1}' \
           '{"mode":"slack","channel":"C0123ABCD","environment":{"busy":false},"quota_left":0}' \
           '{"mode":"slack","channel":null,"environment":{"busy":false},"quota_left":1}'; do
  rm -f "$M"; printf '%s\n' "$bad" > "$SANDBOX/out"
  o="$(HOME="$H" bash "$H/scripts/precheck.sh" slack 42 2>/dev/null)"
  assert "slack 42 refused: $bad" '.marked == null' "$o"
  [ ! -e "$M" ] || { echo "  slack 42 marked although $bad"; FAILED=1; }
done
printf '%s\n' '{"mode":"slack","channel":"C0123ABCD","environment":{"busy":false},"quota_left":1}' > "$SANDBOX/out"
rm -f "$M"; o="$(HOME="$H" CLAUDE_CODE_SESSION_ID= bash "$H/scripts/precheck.sh" slack 42 2>/dev/null)"
assert "slack 42 without a session id -> not marked" '.marked == null' "$o"
[ ! -e "$M" ] || { echo "  slack 42 marked without a session"; FAILED=1; }
o="$(HOME="$H" bash "$H/scripts/precheck.sh" slack '7;rm' 2>/dev/null)"
assert "slack <not a number> -> an error, no marker" '.marked == null and (.error | test("not an issue number"))' "$o"
[ ! -e "$M" ] || { echo "  slack with a bad issue wrote a run marker"; FAILED=1; }
rm -f "$H/scripts/preflight.sh"
HOME="$H" bash "$H/scripts/precheck.sh" issues >/dev/null 2>&1; assert_eq "missing pre-flight -> run" 0 "$?"
exit $FAILED
