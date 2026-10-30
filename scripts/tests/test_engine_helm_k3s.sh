#!/usr/bin/env bash
# helm-k3s engine: channels pick the right builds from both registry APIs; --between lists the builds
# between two, oldest first; a failed registry request or a page that is not JSON fails the command;
# values fill placeholders and overlays; `up` returns at once for the build already up with the
# same values, and a failed upgrade never leaves a build recorded.
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
ENG="$SCRIPTS/../engines/helm-k3s"
mkdir -p "$SANDBOX/bin"
# STUB_OCI_PAGED=ok|fail splits the /v2 listing into two pages (Link header via -D), the second failing
# on `fail`; STUB_QUAY_PAGED=ok|bad splits the quay listing into two pages, the second not JSON on
# `bad`; STUB_MANIFEST_FAIL=1 fails the manifest request.
cat > "$SANDBOX/bin/curl" <<'S'
#!/usr/bin/env bash
hdr=/dev/null; prev=""
for a in "$@"; do [ "$prev" = -D ] && hdr="$a"; prev="$a"; done
for a in "$@"; do case "$a" in
  *quay.io/api/v1/*"&page="[12]) [ -n "${STUB_QUAY_PAGED:-}" ] || { cat "$STUB_DIR/quay.json"; exit 0; }
    case "$a" in
      *1) echo '{"tags":[{"name":"0.0.0-main.12","start_ts":500}],"has_additional":true}';;
      *) [ "$STUB_QUAY_PAGED" = ok ] || { echo '<html>proxy error</html>'; exit 0; }
         echo '{"tags":[{"name":"1.1.0","start_ts":400},{"name":"1.0.0","start_ts":200}],"has_additional":false}';;
    esac; exit 0;;
  *quay.io/api/v1/*) cat "$STUB_DIR/quay.json"; exit 0;;
  *"/v2/"*"/tags/list"*"last="*) [ "${STUB_OCI_PAGED:-}" = ok ] || exit 22
    echo '{"tags":["1.2.0","1.10.0","0.0.0-main.9","0.0.0-main.10","0.0.0-main.8","latest"]}'; exit 0;;
  *"/v2/"*"/tags/list"*) if [ -n "${STUB_OCI_PAGED:-}" ]; then
      printf 'Link: </v2/acme/chart/tags/list?n=1000&last=1.0.0>; rel="next"\r\n' > "$hdr"
      echo '{"tags":["0.0.0-main.7","1.0.0"]}'
    else echo '{"tags":["1.0.0","1.2.0","1.10.0","0.0.0-main.7","0.0.0-main.9","0.0.0-main.10","0.0.0-main.8","latest"]}'; fi
    exit 0;;
  *"/v2/"*"/manifests/"*) [ "${STUB_MANIFEST_FAIL:-0}" = 1 ] && exit 22
    echo '{"annotations":{"org.opencontainers.image.created":"2026-10-01T00:00:00Z"}}'; exit 0;;
  *"/v2/") exit 0;;
esac; done
exit 22
S
chmod +x "$SANDBOX/bin/curl"
cat > "$STUB_DIR/quay.json" <<'J'
{"tags":[{"name":"0.0.0-main.12","start_ts":500},{"name":"1.1.0","start_ts":400},{"name":"0.0.0-main.11","start_ts":300},{"name":"1.0.0","start_ts":200},{"name":"0.0.0-main.10","start_ts":100}],"has_additional":false}
J
cfg() { jq -nc --arg api "$1" '{chart:"oci://reg.example/acme/chart", registry_api:$api,
  channels:{main:{tag:"^0\\.0\\.0-main\\.[0-9]+$", order:"numeric-suffix"}, release:{tag:"^[0-9]+\\.[0-9]+\\.[0-9]+$", order:"semver"}},
  default_candidate:"main", default_baseline:"release", app_port:8080,
  credentials:{users:{owner:{username:"qa"}}, secrets:["admin"]},
  values:{port:"{{app_port}}", user:"{{user:owner.username}}", pw:"{{user:owner.password}}", admin:"{{secret:admin}}", image:"{{config:img}}"},
  overlays:[{when:"mock", values:{mock:{repo:"{{config_repo:mock}}", tag:"{{config_tag:mock}}"}}},
            {when:"@model", values:{llm:{key:"{{model:key}}", kind:"{{model:kind}}", base:"{{model:base_url}}", proxy:"{{proxy:https}}", no:"{{proxy:no}}"}}}]}'; }
v() { PATH="$SANDBOX/bin:$PATH" QI_ENGINE_CONFIG="$(cfg "$1")" QI_PROFILE_CONFIG='{"img":"x","mock":""}' \
      QI_CANDIDATE_CHANNEL="$2" QI_BASELINE_CHANNEL="$3" bash "$ENG/bin/versions"; }
assert "quay main vs release" '. == {"candidate":"0.0.0-main.12","baseline":"1.1.0"}' "$(v quay "" "")"
assert "quay release vs the release before" '. == {"candidate":"1.1.0","baseline":"1.0.0"}' "$(v quay release release)"
assert "oci sorts numerically, not lexically" '. == {"candidate":"0.0.0-main.10","baseline":"1.10.0"}' "$(v oci main release)"
assert "no baseline" '.baseline == null' "$(v oci main none)"
# A failed page must fail the listing, never end it early with a wrong candidate (profile-contract: never a guess).
vp() { ( export STUB_OCI_PAGED="$1"; v oci main release 2>/dev/null ); }
assert "oci follows the Link header" '. == {"candidate":"0.0.0-main.10","baseline":"1.10.0"}' "$(vp ok)"
vp fail >/dev/null && { echo "  a failed second page must fail bin/versions"; FAILED=1; }
vq() { ( export STUB_QUAY_PAGED="$1"; v quay "" "" 2>/dev/null ); }
assert "quay reads the next page" '. == {"candidate":"0.0.0-main.12","baseline":"1.1.0"}' "$(vq ok)"
vq bad >/dev/null && { echo "  a quay page that is not JSON must fail bin/versions"; FAILED=1; }
bt() { PATH="$SANDBOX/bin:$PATH" QI_ENGINE_CONFIG="$(cfg oci)" QI_PROFILE_CONFIG='{"img":"x","mock":""}' \
       STUB_MANIFEST_FAIL="$1" bash "$ENG/bin/build-time" 1.0.0 2>/dev/null; }
assert_eq "oci publish time" 2026-10-01T00:00:00Z "$(bt 0)"
bt 1 >/dev/null && { echo "  a failed manifest request must fail bin/build-time"; FAILED=1; }
vb() { PATH="$SANDBOX/bin:$PATH" QI_ENGINE_CONFIG="$(cfg "$1")" QI_PROFILE_CONFIG='{"img":"x","mock":""}' \
       QI_CANDIDATE_CHANNEL="" QI_BASELINE_CHANNEL="" bash "$ENG/bin/versions" --between "$2" "$3" 2>/dev/null; }
assert "oci between, numeric order" '. == ["0.0.0-main.8","0.0.0-main.9"]' "$(vb oci 0.0.0-main.7 0.0.0-main.10)"
assert "oci between, semver order" '. == ["1.2.0"]' "$(vb oci 1.0.0 1.10.0)"
assert "oci between across pages keeps page 1" '. == ["0.0.0-main.8","0.0.0-main.9"]' \
  "$(export STUB_OCI_PAGED=ok; vb oci 0.0.0-main.7 0.0.0-main.10)"
assert "quay between" '. == ["0.0.0-main.11"]' "$(vb quay 0.0.0-main.10 0.0.0-main.12)"
assert "adjacent builds" '. == []' "$(vb quay 0.0.0-main.11 0.0.0-main.12)"
vb oci 0.0.0-main.7 0.0.0-main.99 >/dev/null && { echo "  --between an unknown build must fail"; FAILED=1; }
vb oci 1.0.0 0.0.0-main.10 >/dev/null && { echo "  --between two channels must fail"; FAILED=1; }
vb oci 0.0.0-main.10 0.0.0-main.7 >/dev/null && { echo "  --between a reversed pair must fail"; FAILED=1; }
# env.sh between: a profile whose bin/versions ignores --between counts as not implemented (exit 2).
stub_profile
bash "$SCRIPTS/env.sh" between a b >/dev/null 2>&1; assert_eq "no --between -> exit 2" 2 "$?"
printf 'E2E_USER_OWNER_USERNAME=qa\nE2E_USER_OWNER_PASSWORD=pw\nQI_SECRET_ADMIN=s\n' > "$SANDBOX/cred.env"
r() { QI_PROFILE_CONFIG="$1" node "$ENG/lib/render.mjs" config <<<"$(cfg oci)" | node "$ENG/lib/render.mjs" values "$SANDBOX/cred.env"; }
assert "values filled, overlay off" '. == {"port":"8080","user":"qa","pw":"pw","admin":"s","image":"x"}' "$(r '{"img":"x","mock":""}')"
assert "overlay on, image ref split" '.mock == {"repo":"reg.example/acme/mock","tag":"v2"}' "$(r '{"img":"x","mock":"reg.example/acme/mock:v2"}')"
# The lent model (scripts/lib/profile.sh → model_env): its overlay and placeholders only while lent.
assert "no lent model, no llm values" 'has("llm") | not' "$(QI_MODEL_KEY= r '{"img":"x","mock":""}')"
assert "lent model fills its overlay" '.llm.key == "platform:conn:p1" and .llm.kind == "oauth" and .llm.base == "" and .llm.proxy == "http://gw:3128"
  and (.llm.no | startswith("corp.example,localhost") and contains(".cluster.local"))' \
  "$(QI_MODEL_KEY=platform:conn:p1 QI_MODEL_KIND=oauth QI_MODEL_BASE_URL= HTTPS_PROXY=http://gw:3128 NO_PROXY=corp.example r '{"img":"x","mock":""}')"
# A sandbox account (docs/profile-contract.md → sandbox): its overlay is on only while every
# E2E_SANDBOX_<ID>_* line of $QI_ENV_DIR/credentials.env is filled; its placeholders take the
# values, one layer of quotes off.
SBE="$SANDBOX/sbenv"; mkdir -p "$SBE"
sbcfg() { cfg oci | jq -c '.overlays += [{when:"@sandbox:slack", values:{slack:{bot:"{{sandbox:slack.BOT_TOKEN}}", app:"{{sandbox:slack.APP_TOKEN}}"}}}]'; }
rs() { QI_ENV_DIR="$SBE" QI_PROFILE_CONFIG='{"img":"x","mock":""}' node "$ENG/lib/render.mjs" config <<<"$(sbcfg)" \
       | node "$ENG/lib/render.mjs" values "$SBE/credentials.env"; }
cp "$SANDBOX/cred.env" "$SBE/credentials.env"
assert "no sandbox lines, overlay off" 'has("slack") | not' "$(rs)"
printf 'E2E_SANDBOX_SLACK_BOT_TOKEN="xoxb-1"\nE2E_SANDBOX_SLACK_APP_TOKEN=\n' >> "$SBE/credentials.env"
assert "a sandbox line still empty, overlay off" 'has("slack") | not' "$(rs)"
sed -i.bak 's/^E2E_SANDBOX_SLACK_APP_TOKEN=$/export E2E_SANDBOX_SLACK_APP_TOKEN=xapp-2/' "$SBE/credentials.env"
assert "every sandbox line filled, overlay on" '.slack == {"bot":"xoxb-1","app":"xapp-2"}' "$(rs)"

# "@environment" (docs/nested-env.md → Where the product runs): on only in a platform
# Environment, where {{env_url:<endpoint>}} and {{env_scheme}} take its addresses.
envcfg() { cfg oci | jq -c '.overlays += [{when:"@environment", values:{urls:{ui:"{{env_url:app}}", kc:"{{env_url:keycloak}}"}, scheme:"{{env_scheme}}"}}]'; }
re() { QI_PROFILE_CONFIG='{"img":"x","mock":""}' node "$ENG/lib/render.mjs" config <<<"$(envcfg)" \
       | node "$ENG/lib/render.mjs" values "$SANDBOX/cred.env" 2>&1; }
assert "in this VM, no environment values" 'has("urls") | not' "$(re)"
assert "in an Environment, its addresses" '.urls == {"ui":"https://app-x.env.test","kc":"https://keycloak-x.env.test"} and .scheme == "https"' \
  "$(QI_NESTED_TARGET=environment QI_ENV_ENDPOINTS='{"app":"https://app-x.env.test/","keycloak":"https://keycloak-x.env.test"}' re)"
# An overlay's `tags`: only for the builds that match.
rt() { QI_BUILD="$1" QI_PROFILE_CONFIG='{"img":"x","mock":"reg.example/m:v1"}' node "$ENG/lib/render.mjs" config <<<"$(cfg oci | jq -c '.overlays[0].tags = "^2\\."')"; }
assert "tags: a matching build takes the overlay" '.values.mock.tag == "v1"' "$(rt 2.0.0)"
assert "tags: another build does not" '.values | has("mock") | not' "$(rt 1.9.0)"
assert "tags: no build named (not an up) takes it" '.values.mock.tag == "v1"' "$(rt '')"
QI_NESTED_TARGET=environment QI_ENV_ENDPOINTS='{"app":"https://app-x.env.test"}' re | grep -q "{{env_url:keycloak}}: the Environment has no address for endpoint 'keycloak'" \
  || { echo "  a missing endpoint address must fail the render"; FAILED=1; }

# {{gateway_ip}}: the VM gateway's address from the environment; rendering fails without one.
gi() { jq -nc '{values:{cidr:"{{gateway_ip}}/32"}}' | QI_GATEWAY_IP="$1" node "$ENG/lib/render.mjs" values "$SANDBOX/cred.env" 2>&1; }
assert "gateway_ip fills the value" '.cidr == "10.0.2.3/32"' "$(gi 10.0.2.3)"
gi "" | grep -q "{{gateway_ip}}: the VM's gateway address did not resolve" || { echo "  an unresolved gateway_ip must fail"; FAILED=1; }
gi "not-an-ip" >/dev/null && { echo "  a gateway_ip that is no IPv4 address must fail"; FAILED=1; }

# model_env: off by default; on, the placeholder and the kind from the provider's variables — never a value.
seed_work
mkdir -p "$SANDBOX/home/.platform"
echo '{"providers":[{"id":"p1","env":{"CLAUDE_CODE_OAUTH_TOKEN":"secret-token"}}]}' > "$SANDBOX/home/.platform/runtime-env.json"
me() { ( . "$SCRIPTS/lib/config.sh"; . "$SCRIPTS/lib/profile.sh"; HOME="$SANDBOX/home" PLATFORM_PROVIDER=p1 model_env ); }
assert_eq "lend_model off" "||" "$(CONFIG="$WORK_DIR/CONFIG.md" me)"
echo "- lend_model: enabled" >> "$WORK_DIR/CONFIG.md"
assert_eq "lend_model on" "platform:conn:p1|oauth|" "$(CONFIG="$WORK_DIR/CONFIG.md" me)"

# up: stubbed cluster (ready), UI (200) and helm (pull unpacks, upgrade fails).
E="$SANDBOX/envd"; U="$SANDBOX/upbin"; mkdir -p "$E" "$U"
printf 'E2E_USER_OWNER_USERNAME=qa\nE2E_USER_OWNER_PASSWORD=pw\nQI_SECRET_ADMIN=s\n' > "$E/credentials.env"
printf '#!/usr/bin/env bash\nexit 0\n' > "$U/k3s"
printf '#!/usr/bin/env bash\nprintf 200\n' > "$U/curl"
cat > "$U/helm" <<'S'
#!/usr/bin/env bash
case "$1" in
  version) echo "v3.19.0+gstub";;
  pull) while [ $# -gt 0 ]; do [ "$1" = --untardir ] && mkdir -p "$2/chart"; shift; done;;
  *) echo "stub: upgrade refused" >&2; exit 1;;
esac
S
chmod +x "$U"/*
up() { PATH="$U:$PATH" HOME="$SANDBOX/home" QI_ENV_DIR="$E" QI_ENGINE_CONFIG="$(cfg oci)" QI_PROFILE_CONFIG="$1" \
       bash "$ENG/bin/env" up 1.0.0 2>"$SANDBOX/uperr" >/dev/null; echo $?; }
assert_eq "a first install runs (and its stubbed upgrade fails)" 1 "$(up '{"img":"x","mock":""}')"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/k3s.log"\n' "$SANDBOX" > "$U/k3s"
PATH="$U:$PATH" HOME="$SANDBOX/home" QI_ENV_DIR="$SANDBOX/envf" QI_PROFILE_DIR="$SANDBOX/pd" QI_PROFILE_CONFIG='{"img":"x","mock":""}' \
  QI_ENGINE_CONFIG="$(cfg oci | jq -c '.prerequisites = [{kind:"manifest", name:"m", file:"marker.yaml"}]')" \
  bash "$ENG/bin/env" up 1.0.0 >/dev/null 2>&1
grep -qx "kubectl apply -f $SANDBOX/pd/marker.yaml" "$SANDBOX/k3s.log" || { echo "  up: a manifest file is applied from the profile directory"; FAILED=1; }
printf '#!/usr/bin/env bash\nexit 0\n' > "$U/k3s"
grep -q 'helm upgrade to 1.0.0 failed' "$SANDBOX/uperr" || { echo "  no upgrade failure: $(cat "$SANDBOX/uperr")"; FAILED=1; }
[ -f "$E/STATE.json" ] && { echo "  a failed upgrade left a build recorded"; FAILED=1; }
h="$( (sha256sum || shasum -a 256) < "$E/values.json" 2>/dev/null | cut -c1-12)"
printf '{"build":"1.0.0","values":"%s","installed_utc":"x"}\n' "$h" > "$E/STATE.json"
assert_eq "the same build and values: already up" 0 "$(up '{"img":"x","mock":""}')"
grep -q 'already up' "$SANDBOX/uperr" || { echo "  fast path not taken: $(cat "$SANDBOX/uperr")"; FAILED=1; }
assert_eq "other values: installs again" 1 "$(up '{"img":"y","mock":""}')"
[ -f "$E/STATE.json" ] && { echo "  the old build stayed recorded through a failed upgrade"; FAILED=1; }

# Images no container uses: removed by every reset, and after an up only below prune_below_gi free.
G="$SANDBOX/okbin"; mkdir -p "$G"; cp "$U/curl" "$G/curl"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/k3s-ok.log"\n' "$SANDBOX" > "$G/k3s"
printf '#!/usr/bin/env bash\n[ "$1" = version ] && echo "v3.19.0+gstub"\n[ "$1" = pull ] && while [ $# -gt 0 ]; do [ "$1" = --untardir ] && mkdir -p "$2/chart"; shift; done\nexit 0\n' > "$G/helm"
chmod +x "$G"/*
okup() { rm -f "$SANDBOX/k3s-ok.log" "$SANDBOX/envg/STATE.json"
  PATH="$G:$PATH" HOME="$SANDBOX/home" QI_ENV_DIR="$SANDBOX/envg" QI_PROFILE_CONFIG='{"img":"x","mock":""}' \
    QI_ENGINE_CONFIG="$(cfg oci | jq -c --argjson p "$1" '.prune_below_gi = $p')" bash "$ENG/bin/env" up 1.0.0 >/dev/null 2>&1; echo $?; }
assert_eq "an up with the stubbed cluster succeeds" 0 "$(okup 1000000)"
grep -qx "crictl rmi --prune" "$SANDBOX/k3s-ok.log" || { echo "  up below prune_below_gi free: unused images must be removed"; FAILED=1; }
assert_eq "an up with room to spare succeeds" 0 "$(okup 0)"
grep -q "crictl" "$SANDBOX/k3s-ok.log" && { echo "  up above prune_below_gi free: images must stay"; FAILED=1; }
rm -f "$SANDBOX/k3s-ok.log"
PATH="$G:$PATH" HOME="$SANDBOX/home" QI_ENV_DIR="$SANDBOX/envg" QI_PROFILE_CONFIG='{"img":"x","mock":""}' QI_ENGINE_CONFIG="$(cfg oci)" \
  bash "$ENG/bin/env" reset >/dev/null 2>"$SANDBOX/reseterr"
grep -qx "crictl rmi --prune" "$SANDBOX/k3s-ok.log" || { echo "  reset: unused images must be removed: $(cat "$SANDBOX/reseterr")"; FAILED=1; }

# status: `kvm` appears only when the profile asks for it, as whether this VM has the device.
st() { PATH="$G:$PATH" HOME="$SANDBOX/home" QI_ENV_DIR="$SANDBOX/envg" QI_PROFILE_CONFIG='{"img":"x","mock":""}' \
  QI_ENGINE_CONFIG="$1" bash "$ENG/bin/env" status 2>/dev/null; }
assert "status: no kvm key without kvm" 'has("kvm") | not' "$(st "$(cfg oci)")"
kv=false; [ -e /dev/kvm ] && kv=true
assert "status: kvm is whether /dev/kvm exists" ".kvm == $kv" "$(st "$(cfg oci | jq -c '.kvm = true')")"

# bin/check: offline validation of engine_config (README → Check).
mkdir -p "$SANDBOX/pd" && echo '{"app":{"url":"http://localhost:8080"}}' > "$SANDBOX/pd/profile.json"
PCFG='{"img":"x","mock":""}'
c() { QI_ENGINE_CONFIG="$1" QI_PROFILE_CONFIG="$PCFG" QI_PROFILE_DIR="$SANDBOX/pd" bash "$ENG/bin/check"; }
out="$(c "$(cfg oci)")"; rc=$?
assert_eq "check: a complete config passes" "0 " "$rc $(grep '^FAIL' <<<"$out")"
out="$(c "$(cfg oci | jq -c '.prune_below_gi = 10')")"; rc=$?
assert_eq "check: prune_below_gi is a known key" "0 " "$rc $(grep -E '^FAIL|unknown key' <<<"$out")"
for bad in '10.5' '-1' '"10"'; do
  c "$(cfg oci | jq -c --argjson p "$bad" '.prune_below_gi = $p')" | grep -q '^FAIL prune_below_gi ' \
    || { echo "  check: prune_below_gi $bad must fail"; FAILED=1; }
done
c "$(cfg oci | jq -c '.default_candidate = "nightly"')" | grep -q "^FAIL default_candidate 'nightly' is not a channel" \
  || { echo "  check: an unknown default channel must fail"; FAILED=1; }
c "$(cfg oci | jq -c '.overlays[0].when = "nope"')" | grep -q "^FAIL overlay when 'nope' is not a profile config key" \
  || { echo "  check: an overlay on an unknown key must fail"; FAILED=1; }
c "$(cfg oci | jq -c '.overlays[0].values.mock.x = "{{secret:missing}}"')" | grep -q '^FAIL values with every overlay on: credentials have no QI_SECRET_MISSING' \
  || { echo "  check: a placeholder inside an overlay must be rendered too"; FAILED=1; }
# A "@model" overlay is valid and rendered only in the "every overlay on" pass, even when the
# caller's own environment lends a model.
out="$(QI_MODEL_KEY=caller c "$(cfg oci | jq -c '.overlays[1].values.llm.x = "{{secret:missing}}"')")"
grep -q '^FAIL values with every overlay on: credentials have no QI_SECRET_MISSING' <<<"$out" \
  || { echo "  check: a @model overlay must be rendered with every overlay on"; FAILED=1; }
grep -q '^FAIL values: ' <<<"$out" && { echo "  check: the defaults render must lend no model"; FAILED=1; }
# A "@sandbox:<id>" overlay is valid and rendered only with every overlay on, with throw-away
# credentials for its placeholders; another "@" word is not.
out="$(c "$(sbcfg)")"; rc=$?
assert_eq "check: a @sandbox overlay passes" "0 " "$rc $(grep '^FAIL' <<<"$out")"
out="$(c "$(sbcfg | jq -c '.overlays[2].values.slack.x = "{{secret:missing}}"')")"
grep -q '^FAIL values with every overlay on: credentials have no QI_SECRET_MISSING' <<<"$out" \
  || { echo "  check: a @sandbox overlay must be rendered with every overlay on"; FAILED=1; }
grep -q '^FAIL values: ' <<<"$out" && { echo "  check: the defaults render must have every sandbox off"; FAILED=1; }
c "$(sbcfg | jq -c '.overlays[2].when = "@sandbox:Bad"')" | grep -q "^FAIL overlay when '@sandbox:Bad' is not" \
  || { echo "  check: a bad sandbox id must fail"; FAILED=1; }
c "$(cfg oci | jq -c '.app_port = 9090')" | grep -q '^FAIL app.url answers on port 8080, app_port is 9090' \
  || { echo "  check: app_port must match app.url"; FAILED=1; }
c "$(cfg oci | jq -c '.channels.main.order = "time"')" | grep -q "^FAIL channel 'main': order time needs registry_api quay" \
  || { echo "  check: order time needs quay"; FAILED=1; }
c "$(cfg oci | jq -c '.credentials.users = {}')" | grep -q '^FAIL credentials.users.owner' \
  || { echo "  check: the owner account is required"; FAILED=1; }
out="$(c "$(cfg oci | jq -c '.kvm = true | .host_dirs = ["/var/lib/vm-images"]')")"; rc=$?
assert_eq "check: kvm and host_dirs are known keys" "0 " "$rc $(grep -E '^FAIL|unknown key' <<<"$out")"
c "$(cfg oci | jq -c '.kvm = "yes"')" | grep -q '^FAIL kvm must be true or false' \
  || { echo "  check: a kvm that is no boolean must fail"; FAILED=1; }
for bad in '"/var/lib/x"' '["var/lib/x"]' '["/var/lib/../etc"]' '["/var/lib"]' '["/"]' '["/var/lib/rancher/k3s"]' \
           '["/var/lib/kubelet/pods"]' '["/home/agent/x"]' '["/etc"]' '["/x", "/x/"]'; do
  c "$(cfg oci | jq -c --argjson h "$bad" '.host_dirs = $h')" | grep -q '^FAIL host_dirs' \
    || { echo "  check: host_dirs $bad must fail"; FAILED=1; }
done
c "$(cfg oci | jq -c '.overlays[0].tags = "("')" | grep -q "^FAIL overlay 'mock': tags '(' is not a regex" || { echo "  check: a bad tags regex must fail"; FAILED=1; }
# environment_bridge and the "@environment" overlay, against the profile's environment endpoints.
jq '. + {environment:{endpoints:[{name:"app",port:4400},{name:"keycloak",port:4400}]}}' "$SANDBOX/pd/profile.json" > "$SANDBOX/pd/p.tmp" && mv "$SANDBOX/pd/p.tmp" "$SANDBOX/pd/profile.json"
out="$(c "$(envcfg | jq -c '.environment_bridge = {image:"mirror.example/envoy:v1", port:4400}')")"; rc=$?
assert_eq "check: an @environment overlay and a bridge pass" "0 " "$rc $(grep -E '^FAIL|unknown key' <<<"$out")"
c "$(envcfg | jq -c '.overlays[2].values.urls.x = "{{env_url:share}}"')" | grep -q "^FAIL values with every overlay on: {{env_url:share}}: the Environment has no address" \
  || { echo "  check: an endpoint the profile does not declare must fail"; FAILED=1; }
c "$(cfg oci | jq -c '.environment_bridge = {image:"e:1", port:4401}')" | grep -q "^FAIL environment endpoint 'app' is on port 4400, the bridge on 4401" \
  || { echo "  check: the endpoints must share the bridge's port"; FAILED=1; }
c "$(cfg oci | jq -c '.environment_bridge = {image:"e:1", port:8080}')" | grep -q '^FAIL environment_bridge.port must differ from app_port' \
  || { echo "  check: the bridge's port is not app_port"; FAILED=1; }
jq 'del(.environment)' "$SANDBOX/pd/profile.json" > "$SANDBOX/pd/p.tmp" && mv "$SANDBOX/pd/p.tmp" "$SANDBOX/pd/profile.json"
touch "$SANDBOX/pd/marker.yaml"
mf() { cfg oci | jq -c --argjson m "$1" '.prerequisites = [{kind:"manifest", name:"m"} + $m]'; }
out="$(c "$(mf '{"file":"marker.yaml"}')")"; rc=$?
assert_eq "check: a manifest file of the profile passes" "0 " "$rc $(grep '^FAIL' <<<"$out")"
c "$(mf '{"file":"../marker.yaml"}')" | grep -q '^FAIL prerequisite 1 (m): file must be a path inside the profile directory' \
  || { echo "  check: a manifest file outside the profile must fail"; FAILED=1; }
c "$(mf '{"file":"marker.yaml","url":"https://x.example/m.yaml"}')" | grep -q '^FAIL prerequisite 1 (m): manifest needs exactly one of url and file' \
  || { echo "  check: a manifest with both url and file must fail"; FAILED=1; }
c "$(mf '{"url":"https://x.example/m.yaml","file":5}')" | grep -q '^FAIL prerequisite 1 (m): manifest needs exactly one of url and file' \
  || { echo "  check: a non-string file beside a url must fail"; FAILED=1; }
exit $FAILED
