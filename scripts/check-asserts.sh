#!/usr/bin/env bash
# check-asserts.sh — guard the frozen assertions of the suite.
#
# Every test file marks the assertions derived from an acceptance criterion with
#   // AC-<k> begin
#   ...expect / agent.assert lines...
#   // AC-<k> end
# The hash of those blocks is recorded in work/SUITE.md when a test is promoted.
# A repair may change navigation, locators and agent.act steps freely; a changed
# AC block is drift until the operator re-promotes (docs/test-authoring.md).
#
#   check-asserts.sh --hash <test-file>   -> prints the file's assert hash
#   check-asserts.sh --json               -> {"drift":[...], "unmarked":[...]} for regression rows
#
# Read-only. Exit 0 unless the arguments are wrong.

set -u
export LC_ALL=C

HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
SUITE="$WORK/suite"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/state.sh" || { echo "cannot source lib/state.sh" >&2; exit 2; }

# Concatenated, whitespace-normalized AC blocks in file order, each prefixed with its id.
ac_blocks() {
  awk '
    match($0, /\/\/[ \t]*AC-[0-9]+[ \t]+begin/) { id=$0; sub(/.*\/\/[ \t]*/, "", id); sub(/[ \t]+begin.*/, "", id); on=1; print "#" id; next }
    match($0, /\/\/[ \t]*AC-[0-9]+[ \t]+end/)   { on=0; next }
    on { gsub(/[ \t]+/, " "); sub(/^ /, ""); sub(/ $/, ""); if (length($0)) print }
  ' "$1"
}

file_hash() {
  local blocks; blocks="$(ac_blocks "$1")"
  [ -n "$blocks" ] || { echo none; return; }
  text_hash "$blocks"
}

case "${1:-}" in
  --hash)
    [ -f "${2:-}" ] || { echo "usage: $0 --hash <test-file>" >&2; exit 2; }
    file_hash "$2" ;;
  --json)
    drift='[]'; unmarked='[]'
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      t="$(cell "$row" 1)"; tier="$(cell "$row" 3)"; want="$(cell "$row" 4)"
      [ "$tier" = regression ] || continue
      f="$SUITE/$t"
      if [ ! -f "$f" ]; then
        drift="$(printf '%s' "$drift" | jq -c --arg t "$t" '. + [{test:$t, problem:"file missing"}]')"; continue
      fi
      got="$(file_hash "$f")"
      if [ "$got" = none ]; then
        unmarked="$(printf '%s' "$unmarked" | jq -c --arg t "$t" '. + [$t]')"
      elif [ "$got" != "$want" ]; then
        drift="$(printf '%s' "$drift" | jq -c --arg t "$t" --arg w "$want" --arg g "$got" '. + [{test:$t, expected:$w, actual:$g}]')"
      fi
    done < <(table_rows "$WORK/SUITE.md")
    jq -nc --argjson d "$drift" --argjson u "$unmarked" '{drift:$d, unmarked:$u}' ;;
  *) echo "usage: $0 --hash <test-file> | --json" >&2; exit 2 ;;
esac
