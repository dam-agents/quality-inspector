#!/usr/bin/env bash
# Shared helpers for the offline tests: a sandboxed WORK_DIR, stubbed CLIs, a stub profile.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$TESTS_DIR/.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export WORK_DIR="$SANDBOX/work" STUB_DIR="$SANDBOX/stub" PATH="$TESTS_DIR/bin:$PATH"
unset QI_TARGET_REPO
mkdir -p "$WORK_DIR/logs" "$STUB_DIR"
# The harness settings the black-box gate checks: the policy hook registered, as onboarding leaves it.
export QI_CLAUDE_SETTINGS="$SANDBOX/claude-settings.json"
bash "$SCRIPTS/hooks/install.sh" >/dev/null 2>&1
FAILED=0
assert() { # <description> <jq filter that must be true> <json>
  if printf '%s' "$3" | jq -e "$2" >/dev/null 2>&1; then :; else
    echo "  assertion failed: $1"; echo "    filter: $2"; echo "    json: $3"; FAILED=1; fi
}
assert_eq() { [ "$2" = "$3" ] || { echo "  assertion failed: $1 (expected '$2', got '$3')"; FAILED=1; }; }

# A stub product profile (docs/profile-contract.md); builds come from $STUB_DIR/versions.json.
stub_profile() {
  local pd="$SANDBOX/profile"
  mkdir -p "$pd/bin"
  cat > "$pd/profile.json" <<'J'
{"schema":"qi-profile/v1","product":"Stub","app":{"url":"http://localhost:8080"},
 "boundary":{"github_paths":["actions/runs"]},"config":{"image":{"default":"stub/img"}}}
J
  cat > "$pd/bin/versions" <<'S'
#!/usr/bin/env bash
[ "${STUB_VERSIONS_FAIL:-0}" = 1 ] && { echo "registry down" >&2; exit 1; }
jq -c --arg b "$QI_BASELINE_CHANNEL" 'if $b == "none" then .baseline = null else . end' "$STUB_DIR/versions.json"
S
  cat > "$pd/bin/build-time" <<'S'
#!/usr/bin/env bash
echo 2026-10-01T00:00:00Z
S
  cat > "$pd/bin/env" <<'S'
#!/usr/bin/env bash
echo '{"running":false,"build":null,"ui_http":"000"}'
S
  chmod +x "$pd/bin/"*
  export QI_PROFILE_DIR="$pd"
  echo '{"candidate":"0.0.0-main.bbb2222","baseline":"0.2.19"}' > "$STUB_DIR/versions.json"
}

seed_work() {
  cat > "$WORK_DIR/CONFIG.md" <<CFG
- target_repo: acme/widgets
- max_issues_per_run: ${1:-5}
CFG
  printf '| issue | ac_hash | candidate | baseline | verdict | status | updated_utc |\n| --- | --- | --- | --- | --- | --- | --- |\n' > "$WORK_DIR/QA.md"
  printf '| test | issue | tier | assert_hash | promoted_utc |\n| --- | --- | --- | --- | --- |\n' > "$WORK_DIR/SUITE.md"
  stub_profile
  seed_gate
}
# A fresh, passed black-box gate (scripts/preflight.sh → boundary_gate) for acme/widgets, so a
# test probes the boundary only when it means to.
seed_gate() {
  mkdir -p "$WORK_DIR/env"
  jq -nc --arg v "$(head -1 "$SCRIPTS/../VERSION")" --argjson e "$(date -u +%s)" \
    '{version:$v, target:"acme/widgets", checked_utc:"-", checked_epoch:$e, fails:[]}' > "$WORK_DIR/env/boundary.json"
}
iso_ago() { date -u -d "@$(( $(date -u +%s) - $1 * 60 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || date -u -r $(( $(date -u +%s) - $1 * 60 )) +%Y-%m-%dT%H:%M:%SZ; }
