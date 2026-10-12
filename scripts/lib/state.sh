#!/usr/bin/env bash
# state.sh — readers for the quality-inspector state tables and the issue-text hash.
# Sourced by preflight.sh, verify-onboarding.sh and check-asserts.sh; the table
# shapes are documented in ONBOARDING.md Step 2 (the seeds) and must match here.
# Expects $WORK to be set by the caller.

# Header lines of each table, verbatim — the verifier compares against these.
QA_HEADER='| issue | ac_hash | candidate | baseline | verdict | status | updated_utc |'
SUITE_HEADER='| test | issue | tier | assert_hash | promoted_utc |'
HEALS_HEADER='| utc | test | ac | build | old_hash | new_hash | basis |'

# Data rows of a markdown table file (everything after the header + separator).
table_rows() { grep '^|' "$1" 2>/dev/null | tail -n +3; }

# Cell <n> (1-based) of a table row, trimmed.
cell() { printf '%s\n' "$1" | awk -F'|' -v n="$(( $2 + 1 ))" '{gsub(/^[ \t]+|[ \t]+$/, "", $n); print $n}'; }

# The QA.md row of one issue, or nothing.
qa_row() { table_rows "$WORK/QA.md" | awk -F'|' -v id="$1" '{x=$2; gsub(/[ \t]/,"",x)} x==id {print; exit}'; }

# The text an AC freeze reads: the "Done when" section when present (up to the next
# heading of the same or a higher level), else the whole body. Title prepended.
issue_spec_text() { # <title> <body>
  local title="$1" body="$2" section
  section="$(printf '%s\n' "$body" | tr -d '\r' | awk '
    /^#{1,6}[ \t]+[Dd]one[ \t]+[Ww]hen[ \t]*$/ { on=1; lvl=index($0," ")-1; next }
    on && /^#{1,6}[ \t]/ { l=index($0," ")-1; if (l<=lvl) exit }
    on { print }')"
  if [ -n "$(printf '%s' "$section" | tr -d '[:space:]')" ]; then
    printf '%s\n%s\n' "$title" "$section"
  else
    printf '%s\n%s\n' "$title" "$body" | tr -d '\r'
  fi
}

has_done_when() { printf '%s\n' "$1" | grep -qiE '^#{1,6}[[:space:]]+done[[:space:]]+when[[:space:]]*$'; }

# 12-hex hash of a text, whitespace-normalized so a reflow is not a spec change.
text_hash() { printf '%s' "$1" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//' \
              | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-12; }
