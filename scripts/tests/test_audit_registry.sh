#!/usr/bin/env bash
# preflight.sh audit: the `features` and `maintenance` checks (docs/features.md, docs/maintenance.md) —
# ok with no file yet; warn for a member that does not run and for a proposal open over 14 days (a
# fresh one is not named); fail for a malformed registry or queue.
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
seed_work
echo '[]' > "$STUB_DIR/issues.json"
export HOME="$SANDBOX"
W="$WORK_DIR"
chk() { bash "$SCRIPTS/preflight.sh" audit | jq -c '[.checks[] | select(.id == "features" or .id == "maintenance")] | map({(.id): {status, detail}}) | add'; }
printf '| tests/issue-42.e2e.ts | 42 | regression | none | 2026-10-03T08:12:40Z |\n| tests/scenario-7.e2e.ts | S-7 | exploratory | c | - |\n' >> "$W/SUITE.md"

out="$(chk)"
assert "no registry and no queue yet: both ok" '.features.status == "ok" and .maintenance.status == "ok"' "$out"

FH='| feature | name | aliases | members | updated_utc |\n| --- | --- | --- | --- | --- |\n'
MH='| id | test | kind | build | basis | proposal | state | opened_utc | closed_utc |\n| --- | --- | --- | --- | --- | --- | --- | --- | --- |\n'
fresh="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf "# F\n\n$FH| upload | Upload | - | #42 AC-1, S-7 | $fresh |\n" > "$W/FEATURES.md"
printf "# M\n\n$MH| M-1 | #42 AC-1 | needs-review | c3 | ui-map | heal | open | 2026-01-02T03:00:00Z | - |\n| M-2 | #42 AC-1 | drift | c3 | x | re-promote | open | $fresh | - |\n| M-3 | S-7 | drift | c3 | x | retire | kept | 2026-01-02T03:00:00Z | 2026-01-03T03:00:00Z |\n" > "$W/MAINTENANCE.md"
out="$(chk)"
assert "a member that does not run warns, naming it" '.features.status == "warn" and (.features.detail | test("S-7 is exploratory"))' "$out"
assert "a proposal open over 14 days warns; a fresh one and a closed one are not named" \
  '.maintenance.status == "warn" and (.maintenance.detail | test("M-1$")) and (.maintenance.detail | test("M-2|M-3") | not)' "$out"

printf "# F\n\n$FH| upload | Upload | - | #42 AC-1 | $fresh |\n" > "$W/FEATURES.md"
printf "# M\n\n$MH| M-2 | #42 AC-1 | drift | c3 | x | re-promote | open | $fresh | - |\n" > "$W/MAINTENANCE.md"
out="$(chk)"
assert "well-formed and nothing old: both ok" '.features.status == "ok" and .maintenance.status == "ok"' "$out"

printf '# F\n\n| feature | name |\n| --- | --- |\n| upload | Upload |\n' > "$W/FEATURES.md"
printf "# M\n\n$MH| M-2 | #42 AC-1 | broken | c3 | x | re-promote | open | $fresh | - |\n" > "$W/MAINTENANCE.md"
out="$(chk)"
assert "a changed header and a bad kind: both fail" '.features.status == "fail" and .maintenance.status == "fail" and (.maintenance.detail | test("kind"))' "$out"
exit $FAILED
