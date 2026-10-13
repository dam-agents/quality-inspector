#!/usr/bin/env bash
# helm-k3s engine: channels pick the right builds from both registry APIs; values fill placeholders and overlays.
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
ENG="$SCRIPTS/../engines/helm-k3s"
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/curl" <<'S'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in
  *quay.io/api/v1/*) cat "$STUB_DIR/quay.json"; exit 0;;
  *"/v2/"*"/tags/list"*) echo '{"tags":["1.0.0","1.2.0","1.10.0","0.0.0-main.9","0.0.0-main.10","latest"]}'; exit 0;;
  *"/v2/") exit 0;;
esac; done
exit 22
S
chmod +x "$SANDBOX/bin/curl"
cat > "$STUB_DIR/quay.json" <<'J'
{"tags":[{"name":"0.0.0-main.12","start_ts":500},{"name":"1.1.0","start_ts":400},{"name":"0.0.0-main.11","start_ts":300},{"name":"1.0.0","start_ts":200}],"has_additional":false}
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
printf 'E2E_USER_OWNER_USERNAME=qa\nE2E_USER_OWNER_PASSWORD=pw\nQI_SECRET_ADMIN=s\n' > "$SANDBOX/cred.env"
r() { QI_PROFILE_CONFIG="$1" node "$ENG/lib/render.mjs" config <<<"$(cfg oci)" | node "$ENG/lib/render.mjs" values "$SANDBOX/cred.env"; }
assert "values filled, overlay off" '. == {"port":"8080","user":"qa","pw":"pw","admin":"s","image":"x"}' "$(r '{"img":"x","mock":""}')"
assert "overlay on, image ref split" '.mock == {"repo":"reg.example/acme/mock","tag":"v2"}' "$(r '{"img":"x","mock":"reg.example/acme/mock:v2"}')"
exit $FAILED
