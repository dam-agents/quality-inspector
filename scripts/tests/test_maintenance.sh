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
B() { printf '%s' "$*" > "$SANDBOX/basis.txt"; echo "$SANDBOX/basis.txt"; }
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
M open 'D-1' --kind drift --build c4 --proposal heal --basis-file "$(B x)" 2>/dev/null; assert_eq "not a test: exit 2" 2 "$?"
M close M-9 accepted 2>/dev/null; assert_eq "an unknown id: exit 2" 2 "$?"
M close M-1 open 2>/dev/null; assert_eq "open is not a closed state: exit 2" 2 "$?"
assert_eq "refusals leave the file as it was" "$before" "$(cat "$W/MAINTENANCE.md")"
[ -e "$W/MAINTENANCE.md.lock" ] && { echo "  a refused write left its lock"; FAILED=1; }
echo 1 > "$W/MAINTENANCE.md.lock"
M close M-1 kept 2>/dev/null; assert_eq "a held lock: exit 1" 1 "$?"
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
assert "check: well-formed" '.ok' "$(M check)"
printf '| M-1 | #42 AC-1 | drift | c4 | x | heal | open | 2026-10-25T00:00:00Z | - |\n' >> "$W/MAINTENANCE.md"
assert "check: a duplicate id is a problem" '.ok == false' "$(M check)"
exit $FAILED
