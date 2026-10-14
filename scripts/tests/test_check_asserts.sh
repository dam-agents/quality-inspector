#!/usr/bin/env bash
# check-asserts.sh: only AC blocks count, whitespace does not; EX blocks hash apart; agent.assert inside an AC block is named; --lint names blocks without unique() data and EX blocks an AC run selects.
. "$(dirname "$0")/lib.sh"
f="$SANDBOX/t.e2e.ts"
printf 'await agent.act("a");\n// AC-1 begin\nawait expect(x).toBeVisible();\n// AC-1 end\n' > "$f"
h1="$(bash "$SCRIPTS/check-asserts.sh" --hash "$f")"
printf 'await agent.act("something else entirely");\n  // AC-1 begin\n    await   expect(x).toBeVisible();\n// AC-1 end\n' > "$f"
h2="$(bash "$SCRIPTS/check-asserts.sh" --hash "$f")"
assert_eq "steps and indentation do not change the hash" "$h1" "$h2"
printf '// AC-1 begin\nawait expect(x).toHaveText("b");\n// AC-1 end\n' > "$f"
h3="$(bash "$SCRIPTS/check-asserts.sh" --hash "$f")"
[ "$h1" != "$h3" ] || { echo "  a changed assertion must change the hash"; FAILED=1; }
printf '// AC-1 begin\nawait expect(x).toBeVisible();\n// AC-1 end\nawait agent.assert("setup");\n// AC-2 begin\nawait agent.assert("y");\nawait agent.assert("z");\n// AC-2 end\n' > "$f"
assert_eq "agent.assert only counts inside AC blocks, once per AC" AC-2 "$(bash "$SCRIPTS/check-asserts.sh" --agent-asserts "$f")"
printf 'no blocks\n' > "$f"
assert_eq "a file without blocks hashes to none" none "$(bash "$SCRIPTS/check-asserts.sh" --hash "$f")"
# EX blocks (docs/explorations.md) never change the AC hash, and hash on their own.
printf '// AC-1 begin\nawait expect(x).toBeVisible();\n// AC-1 end\n' > "$f"
assert_eq "a file with only AC blocks has no EX hash" none "$(bash "$SCRIPTS/check-asserts.sh" --ex-hash "$f")"
printf '// AC-1 begin\nawait expect(x).toBeVisible();\n// AC-1 end\n// EX-1 begin\nawait expect(y).toHaveCount(1);\n// EX-1 end\n' > "$f"
assert_eq "an EX block does not change the AC hash" "$h1" "$(bash "$SCRIPTS/check-asserts.sh" --hash "$f")"
e1="$(bash "$SCRIPTS/check-asserts.sh" --ex-hash "$f")"
[ "$e1" != none ] && [ "$e1" != "$h1" ] || { echo "  the EX hash must be its own value"; FAILED=1; }
printf '// AC-1 begin\nawait expect(x).toBeVisible();\n// AC-1 end\n// EX-1 begin\nawait expect(y).toHaveCount(2);\n// EX-1 end\n' > "$f"
e2="$(bash "$SCRIPTS/check-asserts.sh" --ex-hash "$f")"
[ "$e1" != "$e2" ] || { echo "  a changed EX check must change the EX hash"; FAILED=1; }
assert_eq "a changed EX check leaves the AC hash alone" "$h1" "$(bash "$SCRIPTS/check-asserts.sh" --hash "$f")"
# A promoted file whose EX blocks changed is not drift.
mkdir -p "$WORK_DIR/suite/tests"; cp "$f" "$WORK_DIR/suite/tests/issue-42.e2e.ts"
printf '| test | issue | tier | assert_hash | promoted_utc |\n| --- | --- | --- | --- | --- |\n| tests/issue-42.e2e.ts | 42 | regression | %s | 2026-10-03T08:12:40Z |\n' "$h1" > "$WORK_DIR/SUITE.md"
assert "EX edits are not drift" '.drift == [] and .unmarked == []' "$(bash "$SCRIPTS/check-asserts.sh" --json)"
cat > "$f" <<'T'
const name = unique(`qa-${Date.now()}`);
let other_id = await unique('x');
// AC-1 begin
await expect(screen.getByRole('heading', { name: `${name}-2` })).toBeVisible();
// AC-1 end
// AC-2 begin
await expect(screen.getByRole('heading', { name: 'Settings' })).toBeVisible();
// AC-2 end
// AC-3 begin
await expect(screen.getByText(other_idx)).toBeVisible();
// AC-3 end
T
l="$(bash "$SCRIPTS/check-asserts.sh" --lint "$f")"
assert "lint finds the unique() identifiers" '.unique_ids == ["name","other_id"]' "$l"
assert "lint lists static-only and near-miss blocks" '.no_unique_ref == ["AC-2","AC-3"]' "$l"
printf '// AC-1 begin\nawait expect(x).toBeVisible();\n// AC-1 end\n' > "$f"
assert "no unique() at all lists every block" '.no_unique_ref == ["AC-1"] and .unique_ids == []' "$(bash "$SCRIPTS/check-asserts.sh" --lint "$f")"
# An EX test tagged issue-<n> would run in red-green and nightly (docs/explorations.md → Tests).
cat > "$f" <<'T'
test('#42 AC-1: x', { session: 'owner', tags: ['issue-42', 'ac-1'] }, async () => {
  // AC-1 begin
  await expect(x).toBeVisible();
  // AC-1 end
});
test('#42 EX-1: y', { session: 'viewer', tags: ['issue-42-ex', 'ex-1', 'from-ac-1'] }, async () => {
  // EX-1 begin
  await expect(y).toHaveCount(0);
  // EX-1 end
});
test('#42 EX-2: z', { tags: ["issue-42", 'ex-2', 'from-ac-1'] }, async () => {
  // EX-2 begin
  await expect(z).toBeVisible();
  // EX-2 end
});
T
assert "lint names only the EX block whose test carries issue-<n>" '.ex_with_issue_tag == ["EX-2"]' "$(bash "$SCRIPTS/check-asserts.sh" --lint "$f")"
exit $FAILED
