#!/usr/bin/env bash
# qi-profile-creator: check-profile.mjs passes a complete profile, fails each contract break,
# catches unfilled templates, and runs the read-only commands with --live.
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
CORE="$(cd "$SCRIPTS/.." && pwd)"
SKILL="$CORE/skills/qi-profile-creator"
CHECK="$SKILL/scripts/check-profile.mjs"

# A complete helm-k3s profile at $SANDBOX/<n>/qi-profile-acme.
helm_profile() {
  local d="$SANDBOX/$1/qi-profile-acme"; mkdir -p "$d"
  cat > "$d/profile.json" <<'J'
{"schema":"qi-profile/v1","product":"Acme","app":{"url":"http://localhost:8080"},"issues":{"provider":"github"},
 "engine":"helm-k3s",
 "engine_config":{"chart":"{{config:chart_ref}}","registry_api":"oci","release":"acme","namespace":"default",
   "app_port":8080,"traefik_port":true,
   "channels":{"main":{"tag":"^0\\.0\\.0-main\\.[0-9]+$","order":"numeric-suffix"},"release":{"tag":"^[0-9]+\\.[0-9]+\\.[0-9]+$","order":"semver"}},
   "default_candidate":"main","default_baseline":"release","helm_version":"v3.19.0",
   "credentials":{"users":{"owner":{"username":"qa-owner"}},"secrets":["admin"]},
   "values":{"auth":{"admin":"{{secret:admin}}","user":{"name":"{{user:owner.username}}","password":"{{user:owner.password}}"}}},
   "overlays":[{"when":"mock_image","values":{"mock":{"repo":"{{config_repo:mock_image}}","tag":"{{config_tag:mock_image}}"}}}]},
 "boundary":{"github_paths":["actions/runs?per_page=1"],"urls":[]},
 "egress":[{"host":"ghcr.io","method":"GET","why":"chart and images"},{"host":"get.helm.sh","method":"GET","why":"helm"}],
 "requires":{"root":true,"commands":["k3s","curl","jq","node"],"memory_gi":8},
 "config":{"chart_ref":{"default":"oci://ghcr.io/acme/charts/acme","about":"OCI chart the builds come from"},
           "mock_image":{"default":"","about":"image of a mock backend; empty = none","ask":true}}}
J
  printf -- '---\nname: qi-profile-acme\ndescription: >-\n  Product profile for testing Acme with the quality-inspector agent.\n---\n\n# Acme\n\n## What the nested install cannot do\n\n- No email.\n' > "$d/SKILL.md"
  echo '# qi-profile-acme' > "$d/README.md"
  printf '%s\n' "$d"
}
check() { node "$CHECK" --core "$CORE" "$@"; }
edit() { local f="$1/profile.json"; jq "$2" "$f" > "$f.tmp" && mv "$f.tmp" "$f"; }

P="$(helm_profile ok)"
out="$(check "$P")"; rc=$?
assert_eq "complete profile passes" 0 "$rc"
assert_eq "complete profile: no FAIL" "" "$(grep '^FAIL' <<<"$out")"
assert_eq "complete profile: engine check ran" 1 "$(grep -c "helm-k3s's check is clean" <<<"$out")"

P="$(helm_profile url)"; edit "$P" '.app.url = "https://acme.example.com"'
check "$P" | grep -q '^FAIL  app.url' || { echo "  a non-local app.url must fail"; FAILED=1; }

P="$(helm_profile name)"; sed -i.bak 's/^name: .*/name: acme/' "$P/SKILL.md"; rm -f "$P/SKILL.md.bak"
check "$P" | grep -q "^FAIL  SKILL.md: name 'acme' differs" || { echo "  a SKILL.md name other than the directory must fail"; FAILED=1; }

P="$(helm_profile placeholder)"; edit "$P" '.engine_config.values.x = "{{config:nope}}"'
check "$P" | grep -q "^FAIL  engine_config: placeholders: unknown config key 'nope'" || { echo "  an unknown config placeholder must fail"; FAILED=1; }

P="$(helm_profile owner)"; edit "$P" '.engine_config.credentials.users = {"admin":{"username":"qa-admin"}}'
check "$P" | grep -q '^FAIL  engine_config: credentials.users.owner' || { echo "  a profile without the owner account must fail"; FAILED=1; }

P="$(helm_profile secret)"; edit "$P" '.engine_config.values.auth.admin = {"password":"hunter2hunter2"}'
check "$P" | grep -q '^FAIL  profile.json: looks like a literal credential' || { echo "  a literal password must fail"; FAILED=1; }

P="$(helm_profile key)"; edit "$P" '.config.ChartRef = {"default":"x","about":"y"}'
check "$P" | grep -q '^FAIL  config.ChartRef' || { echo "  a config key that placeholders cannot match must fail"; FAILED=1; }

P="$(helm_profile set)"
check --set nope=1 "$P" | grep -q '^FAIL  --set nope' || { echo "  --set of an undeclared key must fail"; FAILED=1; }

# Unfilled templates fail on their markers.
T="$SANDBOX/tpl/qi-profile-acme"; mkdir -p "$T"
cp "$SKILL/templates/profile.helm-k3s.json.template" "$T/profile.json"
cp "$SKILL/templates/SKILL.md.template" "$T/SKILL.md"
cp "$SKILL/templates/README.md.template" "$T/README.md"
out="$(check "$T")"; rc=$?
assert_eq "unfilled templates fail" 1 "$rc"
for f in profile.json SKILL.md README.md; do
  grep -q "^FAIL  $f: [0-9]* unresolved template marker" <<<"$out" || { echo "  markers in $f not reported"; FAILED=1; }
done
for f in "$SKILL"/templates/*.json.template; do jq -e . "$f" >/dev/null || { echo "  $f is not JSON"; FAILED=1; }; done
for f in "$SKILL"/templates/bin/*.template; do bash -n "$f" || { echo "  $f: bash -n"; FAILED=1; }; done

# Own bin/ and --live: the read-only commands run, the acting one never.
own_profile() {
  local d="$SANDBOX/$1/qi-profile-own"; mkdir -p "$d/bin"
  echo '{"schema":"qi-profile/v1","product":"Own","app":{"url":"http://127.0.0.1:3000"},"issues":{"provider":"github"},"egress":[{"host":"ghcr.io","why":"images"}],"requires":{"commands":["curl"]},"config":{}}' > "$d/profile.json"
  printf -- '---\nname: qi-profile-own\ndescription: quality-inspector profile of Own.\n---\n\n## What it cannot do\n' > "$d/SKILL.md"
  echo '# own' > "$d/README.md"
  cat > "$d/bin/versions" <<'S'
#!/usr/bin/env bash
jq -nc --arg b "${QI_BASELINE_CHANNEL:-release}" '{candidate:"2.0.0-main.7", baseline:(if $b == "none" then null else "1.9.0" end)}'
S
  printf '#!/usr/bin/env bash\necho %s\n' "${2:-2026-10-01T10:00:00Z}" > "$d/bin/build-time"
  printf '#!/usr/bin/env bash\ntouch "$QI_PROFILE_DIR/ENV_RAN"\n' > "$d/bin/env"
  chmod +x "$d/bin/"*
  printf '%s\n' "$d"
}
P="$(own_profile live)"
out="$(check --live "$P")"; rc=$?
assert_eq "own bin/ with --live passes" 0 "$rc"
grep -q '^PASS  live: candidate 2.0.0-main.7, baseline 1.9.0' <<<"$out" || { echo "  live builds not reported"; FAILED=1; }
grep -q '^PASS  live: baseline none gives no baseline' <<<"$out" || { echo "  baseline none not checked"; FAILED=1; }
[ -e "$P/ENV_RAN" ] && { echo "  --live must never run bin/env"; FAILED=1; }

P="$(own_profile badtime yesterday)"
check --live "$P" | grep -q "^FAIL  live: bin/build-time 2.0.0-main.7 — 'yesterday' is not ISO-8601 UTC" \
  || { echo "  a non-ISO build time must fail"; FAILED=1; }

P="$(own_profile noexec)"; chmod -x "$P/bin/build-time"
check "$P" | grep -q '^FAIL  bin/build-time: not executable' || { echo "  a non-executable command must fail"; FAILED=1; }

ls -d "${TMPDIR:-/tmp}"/quality-inspector-check-* 2>/dev/null | grep -q . && { echo "  scratch directories left behind"; FAILED=1; }
exit $FAILED
