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

# bin/check: offline validation of engine_config (README → Check).
mkdir -p "$SANDBOX/pd" && echo '{"app":{"url":"http://localhost:8080"}}' > "$SANDBOX/pd/profile.json"
PCFG='{"img":"x","mock":""}'
c() { QI_ENGINE_CONFIG="$1" QI_PROFILE_CONFIG="$PCFG" QI_PROFILE_DIR="$SANDBOX/pd" bash "$ENG/bin/check"; }
out="$(c "$(cfg oci)")"; rc=$?
assert_eq "check: a complete config passes" "0 " "$rc $(grep '^FAIL' <<<"$out")"
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
c "$(cfg oci | jq -c '.app_port = 9090')" | grep -q '^FAIL app.url answers on port 8080, app_port is 9090' \
  || { echo "  check: app_port must match app.url"; FAILED=1; }
c "$(cfg oci | jq -c '.channels.main.order = "time"')" | grep -q "^FAIL channel 'main': order time needs registry_api quay" \
  || { echo "  check: order time needs quay"; FAILED=1; }
c "$(cfg oci | jq -c '.credentials.users = {}')" | grep -q '^FAIL credentials.users.owner' \
  || { echo "  check: the owner account is required"; FAILED=1; }
touch "$SANDBOX/pd/marker.yaml"
mf() { cfg oci | jq -c --argjson m "$1" '.prerequisites = [{kind:"manifest", name:"m"} + $m]'; }
out="$(c "$(mf '{"file":"marker.yaml"}')")"; rc=$?
assert_eq "check: a manifest file of the profile passes" "0 " "$rc $(grep '^FAIL' <<<"$out")"
c "$(mf '{"file":"../marker.yaml"}')" | grep -q '^FAIL prerequisite 1 (m): file must be a path inside the profile directory' \
  || { echo "  check: a manifest file outside the profile must fail"; FAILED=1; }
c "$(mf '{"file":"marker.yaml","url":"https://x.example/m.yaml"}')" | grep -q '^FAIL prerequisite 1 (m): manifest needs exactly one of url and file' \
  || { echo "  check: a manifest with both url and file must fail"; FAILED=1; }
exit $FAILED
