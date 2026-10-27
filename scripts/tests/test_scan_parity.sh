#!/usr/bin/env bash
# scan-issues.mjs and lib/state.sh must agree on the spec text and its hash — the on-demand
# path hashes with the shell, the pre-flight with node, and a mismatch re-tests every issue.
. "$(dirname "$0")/lib.sh"
. "$SCRIPTS/lib/state.sh"
check() { # <title> <body>
  local sh nd
  sh="$(text_hash "$(issue_spec_text "$1" "$2")")"
  nd="$(node --input-type=module -e "import('$SCRIPTS/lib/scan-issues.mjs').then(m => console.log(m.textHash(m.specText(process.argv[1], process.argv[2]))))" "$1" "$2")"
  assert_eq "parity: $1" "$sh" "$nd"
}
check "Section" "Intro

## Done when

- the agent keeps its sessions
-   tabs  survive reloads

## Notes
ignore"
check "Nested" "### Done when
- a
#### detail
- b
### Next
x"
check "No section" "just a body
with two lines"
check "CRLF" $'## Done when\r\n- crlf item\r\n'
# The operator's answers join the hashed text, in both implementations.
printf '2026-10-26 — #42 Q-1: the comment applies\n2026-10-26 — #43 Q-1: other\nnote\n' > "$SANDBOX/op.md"
sh="$(text_hash "$(issue_spec_text T $'- a'; operator_answers 42 "$SANDBOX/op.md")")"
nd="$(node --input-type=module -e "import('$SCRIPTS/lib/scan-issues.mjs').then(m => { const a = m.operatorAnswers(process.argv[1], 42); console.log(m.textHash(m.specText('T', '- a') + a + '\\n')) })" "$(cat "$SANDBOX/op.md")")"
assert_eq "parity with an operator answer" "$sh" "$nd"
assert_eq "an answer changes the hash" 1 "$([ "$sh" != "$(text_hash "$(issue_spec_text T $'- a')")" ] && echo 1 || echo 0)"
exit $FAILED
