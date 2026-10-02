#!/usr/bin/env bash
# check-asserts.sh: only AC blocks count, whitespace does not.
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
printf 'no blocks\n' > "$f"
assert_eq "a file without blocks hashes to none" none "$(bash "$SCRIPTS/check-asserts.sh" --hash "$f")"
exit $FAILED
