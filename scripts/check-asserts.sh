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
# `// EX-<k> begin|end` blocks (docs/explorations.md) are hashed apart and never count
# toward the AC hash, so explorations may evolve without drifting a promoted test.
#
#   check-asserts.sh --hash <test-file>          -> prints the file's AC assert hash (none without AC blocks)
#   check-asserts.sh --ex-hash <test-file>       -> prints the file's EX block hash (none without EX blocks)
#   check-asserts.sh --json                      -> {"drift":[...], "unmarked":[...]} for regression rows
#                                                   (exploratory, promotable, retired, quarantined: never)
#   check-asserts.sh --agent-asserts <test-file> -> the AC ids whose block calls agent.assert, one per
#                                                   line; empty = promotable (docs/regression.md → Tiers)
#   check-asserts.sh --lint <test-file>          -> {"unique_ids":[...], "no_unique_ref":["AC-2",...],
#                                                   "ex_with_issue_tag":["EX-1",...]}: AC blocks naming no
#                                                   identifier the file declares with unique( — informational
#                                                   (docs/test-authoring.md); EX blocks whose test carries an
#                                                   exact issue-<n> tag, so AC runs select them — fix before
#                                                   red-green (docs/explorations.md → Tests)
#
# Read-only. Exit 0 unless the arguments are wrong.

set -u
export LC_ALL=C

HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
SUITE="$WORK/suite"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/state.sh" || { echo "cannot source lib/state.sh" >&2; exit 2; }

# Concatenated, whitespace-normalized <kind> blocks (AC or EX) in file order, each
# prefixed with its id.
blocks() { # <AC|EX> <file>
  awk -v k="$1" '
    $0 ~ "//[ \t]*" k "-[0-9]+[ \t]+begin" { id=$0; sub(/.*\/\/[ \t]*/, "", id); sub(/[ \t]+begin.*/, "", id); on=1; print "#" id; next }
    $0 ~ "//[ \t]*" k "-[0-9]+[ \t]+end"   { on=0; next }
    on { gsub(/[ \t]+/, " "); sub(/^ /, ""); sub(/ $/, ""); if (length($0)) print }
  ' "$2"
}

file_hash() { # <file> [AC|EX]
  local b; b="$(blocks "${2:-AC}" "$1")"
  [ -n "$b" ] || { echo none; return; }
  text_hash "$b"
}

# Identifiers declared as `const|let|var <id> = [await] unique(`, one per line.
unique_ids() {
  grep -oE '(const|let|var)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*(await[[:space:]]+)?unique\(' "$1" \
    | sed -E 's/^(const|let|var)[[:space:]]+([A-Za-z_][A-Za-z0-9_]*).*/\2/' | sort -u
}

# AC ids, one per line, whose block mentions none of the identifiers (space-separated) —
# an object key (`{ name: … }`) or a property (`x.name`) is not a mention.
lint_blocks() { # <file> <ids>
  awk -v ids="$2" '
    BEGIN { n = split(ids, I, " ") }
    match($0, /\/\/[ \t]*AC-[0-9]+[ \t]+begin/) { id=$0; sub(/.*\/\/[ \t]*/, "", id); sub(/[ \t]+begin.*/, "", id); on=1; hit=0; next }
    match($0, /\/\/[ \t]*AC-[0-9]+[ \t]+end/)   { if (on && !hit) print id; on=0; next }
    on { l=$0; gsub(/[A-Za-z_][A-Za-z0-9_]*[ \t]*:/, "", l); gsub(/\.[A-Za-z_][A-Za-z0-9_]*/, "", l)  # object keys, .props
         for (i = 1; i <= n; i++) if (I[i] != "" && match(l, "(^|[^A-Za-z0-9_])" I[i] "([^A-Za-z0-9_]|$)")) hit=1 }
  ' "$1"
}

# EX ids, one per line, whose test — the nearest `tags:` line above the block — carries an
# exact `issue-<n>` tag (an exploration's tag is `issue-<n>-ex`).
ex_with_issue_tag() { # <file>
  awk -v q="'" '
    /tags[ \t]*:/ { t = $0 }
    match($0, /\/\/[ \t]*EX-[0-9]+[ \t]+begin/) { id=$0; sub(/.*\/\/[ \t]*/, "", id); sub(/[ \t]+begin.*/, "", id)
      if (t ~ ("[\"`" q "]issue-[0-9]+[\"`" q "]")) print id }
  ' "$1"
}

case "${1:-}" in
  --lint)
    [ -f "${2:-}" ] || { echo "usage: $0 --lint <test-file>" >&2; exit 2; }
    ids="$(unique_ids "$2")"
    jq -nc --arg ids "$ids" --arg bad "$(lint_blocks "$2" "$(printf '%s' "$ids" | tr '\n' ' ')")" --arg ex "$(ex_with_issue_tag "$2")" \
      '{unique_ids: ($ids | split("\n") | map(select(length > 0))), no_unique_ref: ($bad | split("\n") | map(select(length > 0))),
        ex_with_issue_tag: ($ex | split("\n") | map(select(length > 0)))}' ;;
  --hash)
    [ -f "${2:-}" ] || { echo "usage: $0 --hash <test-file>" >&2; exit 2; }
    file_hash "$2" ;;
  --ex-hash)
    [ -f "${2:-}" ] || { echo "usage: $0 --ex-hash <test-file>" >&2; exit 2; }
    file_hash "$2" EX ;;
  --agent-asserts)
    [ -f "${2:-}" ] || { echo "usage: $0 --agent-asserts <test-file>" >&2; exit 2; }
    blocks AC "$2" | awk '/^#AC-/ {id=substr($0, 2); next} /agent\.assert/ && !seen[id]++ {print id}' ;;
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
  *) echo "usage: $0 --hash <test-file> | --ex-hash <test-file> | --agent-asserts <test-file> | --json | --lint <test-file>" >&2; exit 2 ;;
esac
