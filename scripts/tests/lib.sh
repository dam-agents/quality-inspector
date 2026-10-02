#!/usr/bin/env bash
# Shared helpers for the offline tests: a sandboxed WORK_DIR and stubbed CLIs.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$TESTS_DIR/.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export WORK_DIR="$SANDBOX/work" STUB_DIR="$SANDBOX/stub" PATH="$TESTS_DIR/bin:$PATH"
unset QI_TARGET_REPO
mkdir -p "$WORK_DIR/logs" "$STUB_DIR"
FAILED=0
assert() { # <description> <jq filter that must be true> <json>
  if printf '%s' "$3" | jq -e "$2" >/dev/null 2>&1; then :; else
    echo "  assertion failed: $1"; echo "    filter: $2"; echo "    json: $3"; FAILED=1; fi
}
assert_eq() { [ "$2" = "$3" ] || { echo "  assertion failed: $1 (expected '$2', got '$3')"; FAILED=1; }; }
seed_work() {
  cat > "$WORK_DIR/CONFIG.md" <<CFG
- target_repo: acme/widgets
- max_issues_per_run: ${1:-5}
CFG
  printf '| issue | ac_hash | candidate | baseline | verdict | status | updated_utc |\n| --- | --- | --- | --- | --- | --- | --- |\n' > "$WORK_DIR/QA.md"
  printf '| test | issue | tier | assert_hash | promoted_utc |\n| --- | --- | --- | --- | --- |\n' > "$WORK_DIR/SUITE.md"
  cat > "$STUB_DIR/quay.json" <<'Q'
{"tags":[{"name":"0.2.18","start_ts":100},{"name":"0.2.19","start_ts":200},
 {"name":"0.0.0-main.aaa1111","start_ts":300},{"name":"0.0.0-main.bbb2222","start_ts":400},{"name":"latest","start_ts":500}]}
Q
}
iso_ago() { date -u -d "@$(( $(date -u +%s) - $1 * 60 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || date -u -r $(( $(date -u +%s) - $1 * 60 )) +%Y-%m-%dT%H:%M:%SZ; }
