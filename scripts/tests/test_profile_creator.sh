#!/usr/bin/env bash
# qi-profile-creator: check-profile.mjs passes a complete profile, fails each contract break,
# warns on black-box hints, catches unfilled templates, and runs the read-only commands with
# --live; the bin/ templates pick the right builds from a stubbed registry.
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
CORE="$(cd "$SCRIPTS/.." && pwd)"
SKILL="$CORE/skills/qi-profile-creator"
CHECK="$SKILL/scripts/check-profile.mjs"

# A complete helm-k3s profile at $SANDBOX/<n>/.quality-inspector/qi-profile-acme.
helm_profile() {
  local d="$SANDBOX/$1/.quality-inspector/qi-profile-acme"; mkdir -p "$d"
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
grep -q '^PASS  location: .quality-inspector/qi-profile-acme$' <<<"$out" || { echo "  the profile's location must pass"; FAILED=1; }
mkdir -p "$SANDBOX/qa" && cp -R "$P" "$SANDBOX/qa/"
check "$SANDBOX/qa/qi-profile-acme" | grep -q '^WARN  location: qa/qi-profile-acme — the platform installs a profile only from .quality-inspector/' \
  || { echo "  a profile outside .quality-inspector/ must warn"; FAILED=1; }
assert_eq "complete profile: engine check ran" 1 "$(grep -c "helm-k3s's check is clean" <<<"$out")"
assert_eq "complete profile: no black-box hint" "" "$(grep -E 'source paths|code host' <<<"$out")"

# Black-box hints: what a user could not have written.
P="$(helm_profile hint)"; printf '\nSign-in is handled in src/server/auth.ts.\n' >> "$P/SKILL.md"
check "$P" | grep -q '^WARN  SKILL.md: looks like source paths — src/server/auth.ts' || { echo "  a source path in SKILL.md must warn"; FAILED=1; }
P="$(helm_profile ownhelper)"; printf '\nThe test person writes through suite/lib/sandbox.ts.\n' >> "$P/SKILL.md"
check "$P" | grep -q 'looks like source paths' && { echo "  the profile's own suite/ helper is no source path"; FAILED=1; }
P="$(helm_profile link)"; printf '\nDesign: https://github.com/acme/app/blob/main/docs/design.md\n' >> "$P/SKILL.md"
check "$P" | grep -q '^WARN  SKILL.md: links into a code host' || { echo "  a code-host link in SKILL.md must warn"; FAILED=1; }

# The optional contract keys: known, and their shapes checked.
P="$(helm_profile keys)"
edit "$P" '.interfaces = {"cli":"acme","openapi":"/api/openapi.json"} | .security = {"entity":"project"} | .boundary.packages = ["@acme"]'
out="$(check "$P")"
assert_eq "interfaces, security: no unknown-key WARN" "" "$(grep 'unknown key' <<<"$out")"
grep -q '^PASS  boundary: .*1 package(s)' <<<"$out" || { echo "  boundary.packages not reported"; FAILED=1; }
P="$(helm_profile canary)"; edit "$P" '.canary = {"thing":"agent, under New agent","field":"name"}'
out="$(check "$P")"
grep -q '^PASS  canary: agent, under New agent, text in its name' <<<"$out" || { echo "  a canary object not reported"; FAILED=1; }
grep -q "unknown key 'canary'" <<<"$out" && { echo "  canary is a contract key"; FAILED=1; }
P="$(helm_profile canary-bad)"; edit "$P" '.canary = {"field":"name"}'
check "$P" | grep -q '^FAIL  canary.thing' || { echo "  a canary without its object must fail"; FAILED=1; }
P="$(helm_profile expected)"; edit "$P" '.expected_requests = [{"method":"GET","path":"/api/slack/install/status","status":404,"why":"the QA install sets no Slack app"}]'
out="$(check "$P")"
grep -q '^PASS  expected_requests: GET /api/slack/install/status → 404' <<<"$out" || { echo "  expected_requests not reported"; FAILED=1; }
grep -q "unknown key 'expected_requests'" <<<"$out" && { echo "  expected_requests is a contract key"; FAILED=1; }
P="$(helm_profile expected-bad)"; edit "$P" '.expected_requests = [{"method":"get","path":"/api/*?x=1","status":200}]'
out="$(check "$P")"
for k in method path status why; do grep -q "^FAIL  expected_requests\[0\]\.$k" <<<"$out" || { echo "  a bad expected_requests.$k must fail"; FAILED=1; }; done
P="$(helm_profile environment)"; edit "$P" '.environment = {"endpoints":[{"name":"app","port":4400},{"name":"keycloak","port":4400}],"storage":"60Gi","account":"owner"}'
out="$(check "$P")"
grep -q '^PASS  environment: app:4400, keycloak:4400, 60Gi' <<<"$out" || { echo "  environment not reported: $(grep environment <<<"$out")"; FAILED=1; }
grep -q "unknown key 'environment'" <<<"$out" && { echo "  environment is a contract key"; FAILED=1; }
P="$(helm_profile environment-bad)"; edit "$P" '.environment = {"endpoints":[{"name":"Key-cloak","port":0}],"storage":"60G","account":"nobody"}'
out="$(check "$P")"
for k in "endpoints\\[0\\]\\.name" "endpoints\\[0\\]\\.port" "endpoints: needs 'app'" "storage" "account"; do
  grep -q "^FAIL  environment\.$k" <<<"$out" || { echo "  a bad environment.$k must fail"; FAILED=1; }
done
P="$(helm_profile opcreds)"; edit "$P" '.operator_credentials = [{"name":"LITELLM_CURVE_BENDER_TOKEN","what":"a CurveBender API key","required":false}]'
out="$(check "$P")"
grep -q '^PASS  operator_credentials: 1 — E2E_LITELLM_CURVE_BENDER_TOKEN' <<<"$out" || { echo "  operator_credentials not reported"; FAILED=1; }
grep -q "unknown key 'operator_credentials'" <<<"$out" && { echo "  operator_credentials is a contract key"; FAILED=1; }
P="$(helm_profile opcreds-bad)"
edit "$P" '.operator_credentials = [{"name":"lower-case","what":"x"},{"name":"DUP","what":"x"},{"name":"DUP","what":"y"},{"name":"REQ_TOKEN","what":"z","required":"yes"},{"name":"MODEL_PROXY","what":"w"}]'
out="$(check "$P")"
grep -q '^FAIL  operator_credentials\[0\]: name must be' <<<"$out" || { echo "  a bad operator_credentials name must fail"; FAILED=1; }
grep -q '^FAIL  operator credential DUP: declared twice' <<<"$out" || { echo "  a duplicate operator credential must fail"; FAILED=1; }
grep -q '^FAIL  operator credential REQ_TOKEN: required must be' <<<"$out" || { echo "  a non-boolean required must fail"; FAILED=1; }
grep -q '^FAIL  operator credential MODEL_PROXY: name needs a PASSWORD, TOKEN, SECRET or KEY segment' <<<"$out" || { echo "  a name secrets.mjs would not mask must fail"; FAILED=1; }
P="$(helm_profile validation)"; edit "$P" '.validation = {"exclude":["/admin"]}'
check "$P" | grep -q "unknown key 'validation'" && { echo "  validation is a contract key"; FAILED=1; }
P="$(helm_profile canary-none)"; edit "$P" '.canary = {"none":"nothing a user names"}'
check "$P" | grep -q '^PASS  canary: none — nothing a user names' || { echo "  canary.none not reported"; FAILED=1; }
{ grep -q 'QI_CANARY_THING' "$SCRIPTS/suite.sh" && grep -q 'QI_CANARY_THING' "$SCRIPTS/suite-skeleton/tests/canary.e2e.ts"; } \
  || { echo "  the canary object does not reach the test"; FAILED=1; }
P="$(helm_profile pk)"; edit "$P" '.boundary.packages = "@acme"'
check "$P" | grep -q '^FAIL  boundary.packages' || { echo "  boundary.packages that is not a list must fail"; FAILED=1; }
P="$(helm_profile api)"; edit "$P" '.interfaces = {"openapi":"api/openapi.json"}'
check "$P" | grep -q '^FAIL  interfaces.openapi' || { echo "  an openapi path outside app.url must fail"; FAILED=1; }

# Egress entries as scripts/egress-rules.sh reads them: verdict, method *, pathPattern.
P="$(helm_profile egress)"
edit "$P" '.egress += [{"host":"downloads.acme.example","method":"*","verdict":"allow","pathPattern":"/tools/releases/*","why":"a tool"}]'
out="$(check "$P")"
assert_eq "egress: method *, verdict and pathPattern pass" "" "$(grep '^FAIL  egress' <<<"$out")"
grep -q '^PASS  egress lands: 3 by prompt, 0 by hand' <<<"$out" || { echo "  how the egress lands not reported"; FAILED=1; }
# How each rule lands, by the core's egress-rules.sh: a GitHub host outside the sandbox
# shapes is refused (a release download too), one the kit already allows is redundant.
P="$(helm_profile egressgh)"
edit "$P" '.egress += [{"host":"github.com","method":"GET","path":"/acme/tools/releases/download/*","why":"a tool"}]'
check "$P" | grep -q '^FAIL  egress GET github.com /acme/tools/releases/download/\*: refused' \
  || { echo "  a github.com release download in a profile must fail as refused"; FAILED=1; }
P="$(helm_profile egressbad)"; edit "$P" '.egress += [{"host":"x.example","verdict":"maybe","pathPattern":"tools/*","why":"x"}]'
out="$(check "$P")"
grep -q "^FAIL  egress\[2\] (x.example): verdict 'maybe'" <<<"$out" || { echo "  an unknown egress verdict must fail"; FAILED=1; }
grep -q '^FAIL  egress\[2\] (x.example): pathPattern must be' <<<"$out" || { echo "  a relative pathPattern must fail"; FAILED=1; }

# Sandbox accounts: their shape, their guide on disk, a placeholder naming a config key.
P="$(helm_profile sandbox)"; mkdir -p "$P/sandbox"; echo "Create it." > "$P/sandbox/github.md"
edit "$P" '.sandbox = {"accounts":[{"id":"github","what":"an organization","guide":"sandbox/github.md","credentials":["APP_ID"]}]}
  | .config.sb_repo = {"default":"","about":"the sandbox repository","ask":true}
  | .egress += [{"host":"api.github.com","method":"POST","path":"/repos/{profile.sb_repo}/labels","why":"the labels"}]'
out="$(check "$P")"
assert_eq "sandbox: no FAIL" "" "$(grep '^FAIL' <<<"$out")"
grep -q '^WARN  egress POST api.github.com /repos/{profile.sb_repo}/labels: its profile key has no value' <<<"$out" \
  || { echo "  an egress rule naming an unset key must warn, not fail"; FAILED=1; }
check --set sb_repo=qi-sbx/sandbox "$P" | grep -q '^PASS  egress lands: 2 by prompt, 1 by hand' \
  || { echo "  a sandbox repository rule lands by hand"; FAILED=1; }
edit "$P" '.egress += [{"host":"api.github.com","method":"GET","path":"/repos/{profile.sb_repo}/issues","why":"read the issue"}]'
check --set sb_repo=qi-sbx/sandbox "$P" | grep -q '^WARN  egress GET api.github.com /repos/qi-sbx/sandbox/issues: the kit already allows it' \
  || { echo "  a rule the kit already allows must warn"; FAILED=1; }
check --set sb_repo=qi-sbx/sand_box "$P" | grep -q '^FAIL  egress POST api.github.com /repos/{profile.sb_repo}/labels: refused' \
  || { echo "  a set value that is not a plain name must fail as refused"; FAILED=1; }
grep -q '^PASS  sandbox: 1 account(s) — github' <<<"$out" || { echo "  a sandbox must pass"; FAILED=1; }
grep -q '^WARN  sandbox: no bin/sandbox' <<<"$out" || { echo "  a sandbox without bin/sandbox must warn"; FAILED=1; }
P="$(helm_profile sandboxbad)"
edit "$P" '.sandbox = {"accounts":[{"id":"Git","what":"x","guide":"g.md","credentials":["a"]},{"id":"slack","what":"","guide":"sandbox/slack.md","credentials":[]}]}
  | .egress += [{"host":"api.github.com","method":"POST","path":"/repos/{profile.nope}/issues","why":"x"}]'
out="$(check "$P")"
for want in '^FAIL  Git: id must be' '^FAIL  sandbox slack: no what' '^FAIL  sandbox slack: sandbox/slack.md is missing' \
  '^FAIL  sandbox slack: credentials must be' '^FAIL  egress (api.github.com): {profile.nope} names no config key'; do
  grep -q "$want" <<<"$out" || { echo "  missing: $want"; FAILED=1; }
done

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

# A profile is fetched by directory: a symlink or a submodule inside it fails.
P="$(helm_profile symlink)"; mkdir -p "$P/suite"; ln -s ../README.md "$P/suite/fixture.md"
check "$P" | grep -q '^FAIL  suite/fixture.md: a symlink' || { echo "  a symlink in the profile must fail"; FAILED=1; }
P="$(helm_profile submodule)"; mkdir -p "$P/suite/vendor"; echo 'gitdir: ../../.git/modules/vendor' > "$P/suite/vendor/.git"
check "$P" | grep -q '^FAIL  suite/vendor: a git submodule' || { echo "  a submodule in the profile must fail"; FAILED=1; }

# scenarios/: <slug>.md files with a title and AC blocks of Given/When/Then.
P="$(helm_profile scen)"; mkdir -p "$P/scenarios"
printf '# Sign-in\n\n## AC-1 — the dashboard shows\nGiven the sign-in page\nWhen the owner signs in\nThen the dashboard shows\n' > "$P/scenarios/sign-in.md"
out="$(check "$P")"
printf '%s\n' "$out" | grep -q '^PASS  scenarios/: 1 scenario' || { echo "  a good scenario must pass"; FAILED=1; }
printf '# X\n\n## AC-2 — y\nGiven a\nThen b\nsee https://example.com\n' > "$P/scenarios/bad.md"; printf 'x\n' > "$P/scenarios/Bad_Name.md"
out="$(check "$P")"
for want in '^FAIL  scenarios/Bad_Name.md: not <slug>.md' '^FAIL  scenarios/bad.md: AC blocks are not numbered' '^FAIL  scenarios/bad.md AC-2: no "When' '^WARN  scenarios/bad.md: a URL'; do
  printf '%s\n' "$out" | grep -q "$want" || { echo "  scenario check missing: $want"; FAILED=1; }
done

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

# The bin/versions and bin/build-time templates against a stub OCI registry: two tag pages
# (Link header), an anonymous token, an index manifest whose first entry is an attestation.
mkdir -p "$SANDBOX/reg"
cat > "$SANDBOX/reg/curl" <<'S'
#!/usr/bin/env bash
hdr=""; url=""; auth=""; prev=""
for a in "$@"; do
  [ "$prev" = -D ] && hdr="$a"
  case "$a" in (https://*) url="$a";; ("Authorization: Bearer t") auth=1;; esac
  prev="$a"
done
case "$url" in
  (https://reg.example/v2/) printf 'HTTP/1.1 401\r\nWww-Authenticate: Bearer realm="https://reg.example/token",service="reg.example"\r\n\r\n'; exit 0;;
  (https://reg.example/token\?*) echo '{"token":"t"}'; exit 0;;
  (*/v2/acme/app/tags/list\?n=1000)
    [ -n "$auth" ] || exit 22
    printf 'Link: </v2/acme/app/tags/list?n=1000&last=b>; rel="next"\r\n' > "$hdr"
    echo '{"tags":["1.2.0","1.10.0","0.0.0-main.9","latest","v1.9.9"]}'; exit 0;;
  (*/v2/acme/app/tags/list\?n=1000\&last=b)
    [ -n "$auth" ] && [ "${STUB_FAIL_PAGE2:-0}" = 0 ] || exit 22
    : > "$hdr"
    echo '{"tags":["1.9.3","0.0.0-main.10","0.0.0-main.8","1.11.0-rc.1","0.0.0-main.7"]}'; exit 0;;
  (*/manifests/1.10.0) echo '{"manifests":[{"digest":"sha256:att","platform":{"os":"unknown"}},{"digest":"sha256:amd","platform":{"os":"linux"}}]}'; exit 0;;
  (*/manifests/sha256:amd) echo '{"config":{"digest":"sha256:cfg"}}'; exit 0;;
  (*/blobs/sha256:cfg) echo '{"created":"2026-10-01T10:00:00.123456789Z"}'; exit 0;;
  (*/manifests/1.2.0) echo '{"annotations":{"org.opencontainers.image.created":"2026-09-01T08:00:00Z"}}'; exit 0;;
  (*/manifests/1.9.3) echo '{"config":{"digest":"sha256:none"}}'; exit 0;;
esac
exit 22
S
chmod +x "$SANDBOX/reg/curl"
TB="$SANDBOX/tb"; mkdir -p "$TB"
cp "$SKILL/templates/bin/versions.template" "$TB/versions"; cp "$SKILL/templates/bin/build-time.template" "$TB/build-time"
# A copy whose release channel also matches v-prefixed tags: the semver sort strips the v.
sed "s/release) echo '^\[0-9\]/release) echo '^v?[0-9]/" "$TB/versions" > "$TB/versions-v"
grep -q "release) echo '^v?" "$TB/versions-v" || { echo "  test setup: the v-prefix copy did not change"; FAILED=1; }
tv() { # <script> <candidate channel> <baseline channel> [args…]
  local s="$1" c="$2" b="$3"; shift 3
  PATH="$SANDBOX/reg:$PATH" QI_PROFILE_CONFIG='{"image_ref":"reg.example/acme/app"}' \
    QI_CANDIDATE_CHANNEL="$c" QI_BASELINE_CHANNEL="$b" bash "$TB/$s" "$@" 2>/dev/null
}
assert "versions: defaults, both pages, numeric and semver order" '. == {"candidate":"0.0.0-main.10","baseline":"1.10.0"}' "$(tv versions '' '')"
assert "versions: same channel, the build before" '. == {"candidate":"1.10.0","baseline":"1.9.3"}' "$(tv versions release release)"
assert "versions: baseline none" '. == {"candidate":"0.0.0-main.10","baseline":null}' "$(tv versions main none)"
assert "versions: a v prefix sorts as semver" '. == {"candidate":"1.10.0","baseline":"v1.9.9"}' "$(tv versions-v release release)"
STUB_FAIL_PAGE2=1 tv versions '' '' >/dev/null && { echo "  versions: a failed page must fail, never shorten the listing"; FAILED=1; }
tv versions nightly '' >/dev/null && { echo "  versions: an unknown channel must fail"; FAILED=1; }
assert "versions --between, numeric order" '. == ["0.0.0-main.8","0.0.0-main.9"]' "$(tv versions '' '' --between 0.0.0-main.7 0.0.0-main.10)"
assert "versions --between, semver order" '. == ["1.9.3"]' "$(tv versions '' '' --between 1.2.0 1.10.0)"
assert "versions --between adjacent builds" '. == []' "$(tv versions '' '' --between 0.0.0-main.9 0.0.0-main.10)"
tv versions '' '' --between 1.2.0 0.0.0-main.10 >/dev/null && { echo "  versions --between two channels must fail"; FAILED=1; }
tv versions '' '' --between 0.0.0-main.10 0.0.0-main.7 >/dev/null && { echo "  versions --between a reversed pair must fail"; FAILED=1; }
tv versions '' '' --between 0.0.0-main.7 0.0.0-main.99 >/dev/null && { echo "  versions --between an unknown build must fail"; FAILED=1; }
assert_eq "build-time: through an index, past the attestation" "2026-10-01T10:00:00Z" "$(tv build-time '' '' 1.10.0)"
assert_eq "build-time: the manifest annotation" "2026-09-01T08:00:00Z" "$(tv build-time '' '' 1.2.0)"
tv build-time '' '' 1.9.3 >/dev/null && { echo "  build-time: no recorded time must fail, never print one"; FAILED=1; }
tv build-time '' '' 9.9.9 >/dev/null && { echo "  build-time: an unknown build must fail"; FAILED=1; }

# The bin/env template's generic part: init and status, app.url from profile.json.
EP="$SANDBOX/envp"; mkdir -p "$EP"; echo '{"app":{"url":"http://localhost:3000"}}' > "$EP/profile.json"
te() { QI_ENV_DIR="$SANDBOX/envd" QI_PROFILE_DIR="$1" QI_PROFILE_CONFIG='{}' bash "$SKILL/templates/bin/env.template" "${@:2}"; }
te "$EP" init 2>/dev/null
assert_eq "env init: credentials.env mode 600" "-rw-------" "$(ls -l "$SANDBOX/envd/credentials.env" | cut -c1-10)"
assert_eq "env init: the owner pair" "2" "$(grep -cE '^E2E_USER_OWNER_(USERNAME|PASSWORD)=.' "$SANDBOX/envd/credentials.env")"
assert "env status: the contract's shape" '. == {"running":false,"build":null,"ui_http":"000"}' "$(te "$EP" status 2>/dev/null)"
mkdir -p "$SANDBOX/nourl"; echo '{}' > "$SANDBOX/nourl/profile.json"
te "$SANDBOX/nourl" status >/dev/null 2>&1 && { echo "  env: a profile without app.url must fail"; FAILED=1; }

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

# A profile installed through the platform is plain files: no exec bit needed, its #! line
# (else bash) starts it, as scripts/lib/profile.sh → profile_run does.
P="$(own_profile noexec)"; chmod -x "$P/bin/"*
out="$(check --live "$P")"; rc=$?
assert_eq "own bin/ without its exec bit passes, --live too" 0 "$rc"
grep -q '^PASS  live: candidate 2.0.0-main.7, baseline 1.9.0' <<<"$out" || { echo "  --live must start a plain-file bin/ through its #! line"; FAILED=1; }
P="$(own_profile noshebang)"; printf 'echo 2026-10-01T10:00:00Z\n' > "$P/bin/build-time"
out="$(check --live "$P")"
grep -q '^WARN  bin/build-time: no #! line — it runs through bash' <<<"$out" || { echo "  a bin/ without #! must warn"; FAILED=1; }
grep -q '^PASS  live: 2.0.0-main.7 published 2026-10-01T10:00:00Z' <<<"$out" || { echo "  a bin/ without #! runs through bash"; FAILED=1; }
P="$(own_profile python)"; printf '#!/usr/bin/env python3\nprint("2026-10-01T10:00:00Z")\n' > "$P/bin/build-time"
check "$P" | grep -q '^WARN  bin/build-time: runs through python3, which requires.commands does not list' \
  || { echo "  an interpreter missing from requires.commands must warn"; FAILED=1; }

ls -d "${TMPDIR:-/tmp}"/quality-inspector-check-* 2>/dev/null | grep -q . && { echo "  scratch directories left behind"; FAILED=1; }
exit $FAILED
