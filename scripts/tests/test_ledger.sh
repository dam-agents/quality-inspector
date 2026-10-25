#!/usr/bin/env bash
# Audit ledger_reconcile: recorded comment -> ok; unrecorded comment -> fail; dangling intent -> warn; the cap.
. "$(dirname "$0")/lib.sh"
seed_work
export HOME="$SANDBOX/home"; mkdir -p "$HOME"
echo '[]' > "$STUB_DIR/issues.json"
EV="$WORK_DIR/logs/events-$(date -u +%Y-%m-%d).jsonl"
ev() { jq -cn --arg ts "$1" --arg msg "$2" '{ts:$ts, run:"r", job:"issues", level:"info", event:"external_write", msg:$msg}' >> "$EV"; }
row() { echo "| $1 | ac$1 | c1 | b1 | verified | $2 | $3 |" >> "$WORK_DIR/QA.md"; }
reconcile() { : > "$STUB_DIR/gh.calls"; bash "$SCRIPTS/preflight.sh" audit | jq -c '.checks[] | select(.id == "ledger_reconcile")'; }
comment() { # <login> <created> <body>
  jq -cn --arg l "$1" --arg c "$2" --arg b "$3" '{user:{login:$l}, created_at:$c, body:$b}'; }

row 42 reported "$(iso_ago 60)"; row 43 reported "$(iso_ago 120)"
row 44 reported "$(iso_ago $((10*1440)))"; row 45 report_pending "$(iso_ago 30)"
ev "$(iso_ago 70)" "surface=comment action=intent issue=42 key=ac42@c1 target=acme/widgets"
ev "$(iso_ago 70)" "surface=comment action=done issue=42 key=ac42@c1 target=acme/widgets"
{ comment qa-bot "$(iso_ago 70)" $'Verified.\n<!-- quality-inspector issue=42 ac=ac42 build=c1 -->\n<!-- quality-inspector-data {"issue":42} -->'
  comment alice "$(iso_ago 50)" '<!-- quality-inspector issue=42 ac=zz build=c9 --> quoted by a human'
  comment qa-bot "$(iso_ago $((9*1440)))" '<!-- quality-inspector issue=42 ac=old build=c0 -->'
  comment qa-bot "$(iso_ago 40)" 'a plain reply without a marker'; } | jq -sc . > "$STUB_DIR/comments-42.json"

out="$(reconcile)"
assert "recorded -> ok" '.status == "ok" and (.detail | test("2 of 2"))' "$out"
assert_eq "one comments GET per reported issue of the week" "2" "$(grep -c '/issues/[0-9]*/comments' "$STUB_DIR/gh.calls")"
grep -q 'issues/44/comments\|issues/45/comments' "$STUB_DIR/gh.calls" && { echo "  listed an issue outside the scope"; FAILED=1; }

jq -cn --arg ts "$(iso_ago 110)" '{ts:$ts, run:"u", job:"session", level:"info", event:"ledger_start", msg:"upgrade"}' >> "$EV"
{ comment qa-bot "$(iso_ago 100)" '<!-- quality-inspector-spec issue=43 ac=ac43 -->'
  comment qa-bot "$(iso_ago 115)" '<!-- quality-inspector issue=43 ac=pre build=c0 -->'; } | jq -sc . > "$STUB_DIR/comments-43.json"
out="$(reconcile)"
assert "unrecorded comment -> fail; one older than ledger_start is not judged" \
  '.status == "fail" and (.detail | test("^unrecorded external write: #43 spec_comment ac43 —"))' "$out"

rm -f "$STUB_DIR/comments-43.json"
ev "$(iso_ago 60)" "surface=label action=intent issue=42 key=qa:retest target=acme/widgets"
ev "$(iso_ago 5)" "surface=artifact action=intent issue=43 key=ac43@c1 target=artifact:new"
ev "$(iso_ago 300)" "surface=artifact action=intent issue=43 key=ac43@c0 target=artifact:new"
ev "$(iso_ago 299)" "surface=artifact action=failed issue=43 key=ac43@c0 target=artifact:new"
for n in $(seq 100 124); do row "$n" reported "$(iso_ago $((n - 95)))"; done
out="$(reconcile)"
assert "dangling intent -> warn, in-flight and failed ones are not" \
  '.status == "warn" and (.detail | test("^unfinished write: label issue=42 key=qa:retest — 20 of 27 .*cap 20"))' "$out"
assert_eq "capped at 20 issues" "20" "$(grep -c '/issues/[0-9]*/comments' "$STUB_DIR/gh.calls")"
grep -q 'issues/42/comments' "$STUB_DIR/gh.calls" && { echo "  the cap kept an older issue over newer ones"; FAILED=1; }
exit $FAILED
