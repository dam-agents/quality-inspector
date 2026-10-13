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
exit $FAILED
