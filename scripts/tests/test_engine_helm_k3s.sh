#!/usr/bin/env bash
# helm-k3s engine: channels pick the right builds from both registry APIs; --between lists the builds
# between two, oldest first; a failed registry request or a page that is not JSON fails the command;
# values fill placeholders and overlays.
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
  overlays:[{when:"mock", values:{mock:{repo:"{{config_repo:mock}}", tag:"{{config_tag:mock}}"}}}]}'; }
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
c "$(cfg oci | jq -c '.app_port = 9090')" | grep -q '^FAIL app.url answers on port 8080, app_port is 9090' \
  || { echo "  check: app_port must match app.url"; FAILED=1; }
c "$(cfg oci | jq -c '.channels.main.order = "time"')" | grep -q "^FAIL channel 'main': order time needs registry_api quay" \
  || { echo "  check: order time needs quay"; FAILED=1; }
c "$(cfg oci | jq -c '.credentials.users = {}')" | grep -q '^FAIL credentials.users.owner' \
  || { echo "  check: the owner account is required"; FAILED=1; }
exit $FAILED
