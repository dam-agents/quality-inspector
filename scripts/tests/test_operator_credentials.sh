#!/usr/bin/env bash
# Operator-filled credentials (docs/profile-contract.md → `operator_credentials`): env.sh init
# seeds each missing `E2E_<NAME>` line empty at mode 600, never touches an existing value, and
# verify-onboarding.sh reports each as set, required-missing or optional-missing.
. "$(dirname "$0")/lib.sh"
seed_work
CRED="$WORK_DIR/env/credentials.env"

cat > "$QI_PROFILE_DIR/profile.json" <<'J'
{"schema":"qi-profile/v1","product":"Stub","app":{"url":"http://localhost:8080"},
 "operator_credentials":[
   {"name":"LITELLM_CURVE_BENDER_TOKEN","what":"a CurveBender API key"},
   {"name":"EXTRA_SERVICE_KEY","what":"a second value","required":true},
   {"name":"MODEL_PROXY","what":"a name secrets.mjs would not mask"}]}
J
# The profile's bin/env init writes the credential file, as the contract says.
cat > "$QI_PROFILE_DIR/bin/env" <<'S'
#!/usr/bin/env bash
[ "${1:-}" = init ] || { echo '{"running":false,"build":null,"ui_http":"000"}'; exit 0; }
f="$QI_ENV_DIR/credentials.env"
[ -f "$f" ] || { umask 077; printf 'E2E_USER_OWNER_USERNAME=owner\nE2E_USER_OWNER_PASSWORD=pw-owner-1234\n' > "$f"; }
exit 0
S
chmod +x "$QI_PROFILE_DIR/bin/env"

out="$(bash "$SCRIPTS/env.sh" init 2>&1)"
case "$out" in *"fill E2E_LITELLM_CURVE_BENDER_TOKEN"*) :;; *) echo "  init does not name the seeded line: $out"; FAILED=1;; esac
assert_eq "seeds one empty line per credential" "1 1" \
  "$(grep -c '^E2E_LITELLM_CURVE_BENDER_TOKEN=$' "$CRED") $(grep -c '^E2E_EXTRA_SERVICE_KEY=$' "$CRED")"
assert_eq "a name with no secret segment is not seeded" 0 "$(grep -c '^E2E_MODEL_PROXY=' "$CRED")"
assert_eq "the file stays mode 600" 600 "$(stat -c %a "$CRED" 2>/dev/null || stat -f %Lp "$CRED")"
assert_eq "the profile's own lines are kept" 1 "$(grep -c '^E2E_USER_OWNER_PASSWORD=pw-owner-1234$' "$CRED")"

# A second init adds nothing, and an existing value is never touched.
sed -i.bak 's/^E2E_EXTRA_SERVICE_KEY=$/E2E_EXTRA_SERVICE_KEY=keep-me/' "$CRED"; rm -f "$CRED.bak"; chmod 600 "$CRED"
bash "$SCRIPTS/env.sh" init >/dev/null 2>&1
assert_eq "init is idempotent" "1 1" \
  "$(grep -c '^E2E_LITELLM_CURVE_BENDER_TOKEN=$' "$CRED") $(grep -c '^E2E_EXTRA_SERVICE_KEY=keep-me$' "$CRED")"

# verify-onboarding --config: set → ok, optional-missing → warn.
o="$(bash "$SCRIPTS/verify-onboarding.sh" --config 2>&1)"
case "$o" in *"ok   operator_credential:EXTRA_SERVICE_KEY"*) :;; *) echo "  a set credential is not reported: $(printf '%s' "$o" | grep operator_credential)"; FAILED=1;; esac
case "$o" in *"warn operator_credential:LITELLM_CURVE_BENDER_TOKEN"*) :;; *) echo "  a missing optional credential is not a warn"; FAILED=1;; esac
case "$o" in *"FAIL operator_credential:MODEL_PROXY — not a valid name"*) :;; *) echo "  a name with no secret segment is not a FAIL"; FAILED=1;; esac

# Clear both: the required one FAILs, the optional one still only warns.
sed -i.bak 's/^E2E_EXTRA_SERVICE_KEY=.*/E2E_EXTRA_SERVICE_KEY=/' "$CRED"; rm -f "$CRED.bak"; chmod 600 "$CRED"
o="$(bash "$SCRIPTS/verify-onboarding.sh" --config 2>&1)"
case "$o" in *"FAIL operator_credential:EXTRA_SERVICE_KEY"*) :;; *) echo "  a missing required credential is not a FAIL"; FAILED=1;; esac
case "$o" in *"warn operator_credential:LITELLM_CURVE_BENDER_TOKEN"*) :;; *) echo "  the optional line is not a warn"; FAILED=1;; esac
exit $FAILED
