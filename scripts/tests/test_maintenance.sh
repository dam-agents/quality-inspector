#!/usr/bin/env bash
# scripts/maintenance.mjs: open (one open row per test and kind, a second open updates it), the
# refusals, close (once, a closed state), sweep (drift no longer measured, a tier changed back, a test
# gone, a test passed unchanged — and nothing else), an unreadable SUITE.md (nothing swept), the mutex,
# check. The audit's `maintenance` check: test_audit_registry.sh.
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
seed_work
W="$WORK_DIR"
M() { node "$SCRIPTS/maintenance.mjs" "$@"; }
# The basis reaches the script only through a file (docs/maintenance.md): B <text> writes it, prints its path.
export QI_WORDS_DIR="$SANDBOX"   # stands for /tmp (lib/words.mjs)
B() { local f; f="$(mktemp "$SANDBOX/quality-inspector-basis.XXXXXX")"; printf '%s' "$*" > "$f"; echo "$f"; }
printf '| tests/issue-42.e2e.ts | 42 | regression | none | 2026-10-03T08:12:40Z |\n| tests/issue-51.e2e.ts | 51 | quarantined | b | 2026-10-03T08:12:40Z |\n| tests/scenario-7.e2e.ts | S-7 | retired | c | - |\n| tests/issue-60.e2e.ts | 60 | regression | none | 2026-10-03T08:12:40Z |\n' >> "$W/SUITE.md"

assert "check: no queue yet is fine" '.ok' "$(M check)"
out="$(M open '#42' AC-1 --kind needs-review --build c3 --proposal heal --basis-file "$(B 'ui-map: tab "API keys" → "Access tokens"')")"
assert "open: M-1" '.id == "M-1" and .opened' "$out"
out="$(M open '#42 AC-1' --kind needs-review --build c4 --proposal review --basis-file "$(B 'fails on c3 | as well')")"
assert "open again: the same row, updated" '.id == "M-1" and .opened == false' "$out"
assert "the row: build, basis without the pipe, proposal" '.proposals[0] | .build == "c4" and .basis == "fails on c3 as well" and .proposal == "review" and .state == "open" and .closed_utc == "-"' "$(M list)"
M open '#51' --kind quarantined --build c4 --proposal re-promote --basis-file "$(B 'flaky on c3 and c4')" >/dev/null
M open S-7 AC-1 --kind superseded --build c4 --proposal retire --basis-file "$(B '#77: "the export button is gone"')" >/dev/null
M open '#99' --kind drift --build c4 --proposal re-promote --basis-file "$(B 'AC-2 block changed')" >/dev/null
M open '#60' AC-1 --kind fighting --build c4 --proposal rewrite --basis-file "$(B 'third heal in October')" >/dev/null

before="$(cat "$W/MAINTENANCE.md")"
M open '#42' --kind broken --build c4 --proposal heal --basis-file "$(B x)" 2>/dev/null; assert_eq "an unknown kind: exit 2" 2 "$?"
M open '#42' --kind drift --build c4 --proposal heal 2>/dev/null; assert_eq "no basis: exit 2" 2 "$?"
M open '#42' --kind drift --build c4 --proposal heal --basis "it's" 2>/dev/null; assert_eq "a basis on the command line: exit 2" 2 "$?"
printf 'x' > "$SANDBOX/quality-inspector-basis.txt"
M open '#42' --kind drift --build c4 --proposal heal --basis-file "$SANDBOX/quality-inspector-basis.txt" 2>/dev/null; assert_eq "a fixed basis path: exit 2" 2 "$?"
[ -e "$SANDBOX/quality-inspector-basis.txt" ] || { echo "  a refused basis file was removed"; FAILED=1; }
rm -f "$SANDBOX/quality-inspector-basis.txt"
M open 'D-1' --kind drift --build c4 --proposal heal --basis-file "$(B x)" 2>/dev/null; assert_eq "not a test: exit 2" 2 "$?"
M close M-9 accepted 2>/dev/null; assert_eq "an unknown id: exit 2" 2 "$?"
M close M-1 open 2>/dev/null; assert_eq "open is not a closed state: exit 2" 2 "$?"
assert_eq "refusals leave the file as it was" "$before" "$(cat "$W/MAINTENANCE.md")"
[ -e "$W/MAINTENANCE.md.lock" ] && { echo "  a refused write left its lock"; FAILED=1; }
echo 1 > "$W/MAINTENANCE.md.lock"
M close M-1 kept 2>/dev/null; assert_eq "a held lock: exit 1" 1 "$?"
bf="$(B 'held')"; M open '#42' --kind drift --build c4 --proposal heal --basis-file "$bf" 2>/dev/null; assert_eq "a held lock on open: exit 1" 1 "$?"
[ -e "$bf" ] && { echo "  a held lock left the call's basis file"; FAILED=1; }
assert_eq "a held lock: nothing written" "$before" "$(cat "$W/MAINTENANCE.md")"
rm -f "$W/MAINTENANCE.md.lock"
# An unhydrated work/ (no SUITE.md) never resolves the queue.
mv "$W/SUITE.md" "$W/SUITE.md.away"
M sweep --unchanged '#60' 2>/dev/null; assert_eq "sweep with no SUITE.md: exit 1" 1 "$?"
assert_eq "sweep with no SUITE.md: nothing changed" "$before" "$(cat "$W/MAINTENANCE.md")"
mv "$W/SUITE.md.away" "$W/SUITE.md"

# sweep: #99 has no SUITE row (gone), #51 is still quarantined (stays), S-7 still retired (stays),
# #60 AC-1 passed unchanged (resolved), #42 AC-1 not named (stays).
out="$(M sweep --unchanged '#60')"
assert "sweep: a test gone and a test passed unchanged" '.resolved == ["M-4","M-5"]' "$out"
sed -i.bak 's/| tests\/issue-51.e2e.ts | 51 | quarantined |/| tests\/issue-51.e2e.ts | 51 | regression |/' "$W/SUITE.md"
assert "sweep: the quarantine undone" '.resolved == ["M-2"]' "$(M sweep)"
assert "close: once" '.state == "kept"' "$(M close M-3 kept)"
M close M-3 retired 2>/dev/null; assert_eq "close: a closed row again, exit 2" 2 "$?"
assert "list --open: what is left" '[.proposals[].id] == ["M-1"]' "$(M list --open)"
assert "an intent test is a test" '.opened' "$(M open '#42' IN-1 --kind needs-review --build c5 --proposal review --basis-file "$(B 'IN-1 judged on c5')")"
M open 'S-7 IN-1' --kind drift --build c5 --proposal heal --basis-file "$(B x)" 2>/dev/null; assert_eq "a scenario has no intent test: exit 2" 2 "$?"
assert "check: well-formed" '.ok' "$(M check)"
ls "$SANDBOX" | grep -q '^quality-inspector-basis\.[A-Za-z0-9]' && { echo "  a basis file stayed after its call"; FAILED=1; }

# The drift branch of sweep: #61's blocks match their promoted hash (drift gone: resolved), #62's do
# not (still drifts: stays open), and a check-asserts.sh that fails leaves every drift row open.
mkdir -p "$W/suite/tests"
printf "test('#6x AC-1', async () => {\n  // AC-1 begin\n  await expect(x).toBeVisible();\n  // AC-1 end\n});\n" > "$W/suite/tests/issue-61.e2e.ts"
cp "$W/suite/tests/issue-61.e2e.ts" "$W/suite/tests/issue-62.e2e.ts"
h="$(bash "$SCRIPTS/check-asserts.sh" --hash "$W/suite/tests/issue-61.e2e.ts")"
printf '| tests/issue-61.e2e.ts | 61 | regression | %s | 2026-10-03T08:12:40Z |\n| tests/issue-62.e2e.ts | 62 | regression | 000000000000 | 2026-10-03T08:12:40Z |\n' "$h" >> "$W/SUITE.md"
d61="$(M open '#61' --kind drift --build c5 --proposal re-promote --basis-file "$(B 'AC-1 block changed')" | jq -r .id)"
d62="$(M open '#62' --kind drift --build c5 --proposal re-promote --basis-file "$(B 'AC-1 block changed')" | jq -r .id)"
mkdir -p "$SANDBOX/nojq"; printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/nojq/jq"; chmod +x "$SANDBOX/nojq/jq"
out="$(PATH="$SANDBOX/nojq:$PATH" M sweep)"
assert "sweep: a failed drift measure resolves no drift row, and says so" '.resolved == [] and (.notes | length == 1) and (.notes[0] | test("drift not measured"))' "$out"
out="$(M sweep)"
assert "sweep: the drift that is gone is resolved, the one that stays is not" ".resolved == [\"$d61\"]" "$out"
assert "the drifting test's row stays open" "[.proposals[] | select(.state == \"open\") | .id] | index(\"$d62\") != null" "$(M list)"

# A rework row (a step before the block the agent could not rewrite alone): the night that absorbs the
# test (reworked) resolves it, a test only named elsewhere does not.
r61="$(M open '#61 AC-1' --kind rework --build c5 --proposal review --basis-file "$(B '#3810: the channel is bound in the chat client')" | jq -r .id)"
r62="$(M open '#62 AC-1' --kind rework --build c5 --proposal rewrite --basis-file "$(B '#3810: the Channel ID field is gone')" | jq -r .id)"
out="$(M sweep --absorbed '#61 AC-1')"
assert "sweep: an absorbed test resolves its rework row only" ".resolved == [\"$r61\"]" "$out"
assert "sweep: a passed-unchanged test resolves its rework row" ".resolved == [\"$r62\"]" "$(M sweep --unchanged '#62')"

printf '| M-1 | #42 AC-1 | drift | c4 | x | heal | open | 2026-10-25T00:00:00Z | - |\n' >> "$W/MAINTENANCE.md"
assert "check: a duplicate id is a problem" '.ok == false' "$(M check)"
exit $FAILED
