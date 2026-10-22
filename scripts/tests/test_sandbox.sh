#!/usr/bin/env bash
# sandbox.sh (docs/profile-contract.md → `sandbox`): status names the credentials and never a
# value, template adds only the missing lines at mode 600, guide prints the profile's file,
# check runs the profile's bin/sandbox masked; a malformed manifest is refused. And every
# E2E_SANDBOX_ value — a `_B64` one decoded too — is masked in run artefacts.
. "$(dirname "$0")/lib.sh"
seed_work
CRED="$WORK_DIR/env/credentials.env"
SB() { bash "$SCRIPTS/sandbox.sh" "$@"; }

# No sandbox declared: nothing to do, the check says so and passes.
assert "no sandbox → declared false" '.declared == false and .accounts == []' "$(SB status)"
assert_eq "no sandbox → check passes" "the profile declares no sandbox accounts" "$(SB check)"

mkdir -p "$QI_PROFILE_DIR/sandbox"
echo "1. Create the organization." > "$QI_PROFILE_DIR/sandbox/github.md"
cat > "$QI_PROFILE_DIR/profile.json" <<'J'
{"schema":"qi-profile/v1","product":"Stub","app":{"url":"http://localhost:8080"},
 "sandbox":{"accounts":[
   {"id":"github","what":"an organization","guide":"sandbox/github.md","credentials":["APP_ID","PRIVATE_KEY_B64"]},
   {"id":"slack","what":"a workspace","guide":"sandbox/slack.md","credentials":["HUMAN_TOKEN"]}]}}
J
( umask 077; printf 'E2E_USER_OWNER_USERNAME=owner\nE2E_USER_OWNER_PASSWORD=pw-owner-1234\nE2E_SANDBOX_GITHUB_APP_ID="42"\n' > "$CRED" )
st="$(SB status)"
assert "status names each credential and whether it is set" \
  '.declared and ([.accounts[].credentials[] | "\(.name)=\(.set)"] == ["E2E_SANDBOX_GITHUB_APP_ID=true","E2E_SANDBOX_GITHUB_PRIVATE_KEY_B64=false","E2E_SANDBOX_SLACK_HUMAN_TOKEN=false"])' "$st"
assert "a missing guide is a problem" '.problems == ["account slack: its guide sandbox/slack.md is missing from the profile"]' "$st"
printf '%s' "$st" | grep -q '42' && { echo "  assertion failed: status never prints a value"; FAILED=1; }

assert_eq "template adds the missing lines only" "E2E_SANDBOX_GITHUB_PRIVATE_KEY_B64
E2E_SANDBOX_SLACK_HUMAN_TOKEN" "$(SB template)"
assert_eq "template is idempotent" "" "$(SB template)"
# A file the operator saved without a final newline keeps its last value whole.
cp "$CRED" "$SANDBOX/cred.bak"; grep -v '^E2E_SANDBOX_SLACK_HUMAN_TOKEN=' "$SANDBOX/cred.bak" > "$CRED"
printf 'QI_SECRET_Y=efgh' >> "$CRED"
assert_eq "template after a missing final newline" "E2E_SANDBOX_SLACK_HUMAN_TOKEN" "$(SB template)"
assert_eq "the last value stays whole" "1 1" "$(grep -c '^QI_SECRET_Y=efgh$' "$CRED") $(grep -c '^E2E_SANDBOX_SLACK_HUMAN_TOKEN=$' "$CRED")"
mv "$SANDBOX/cred.bak" "$CRED"; chmod 600 "$CRED"
assert_eq "the file stays mode 600" 600 "$(stat -c %a "$CRED" 2>/dev/null || stat -f %Lp "$CRED")"
assert_eq "existing lines are kept" 1 "$(grep -c '^E2E_SANDBOX_GITHUB_APP_ID="42"$' "$CRED")"

assert_eq "guide prints the profile's file" "1. Create the organization." "$(SB guide github)"
SB guide nope >/dev/null 2>&1; assert_eq "an unknown account is a usage error" 2 "$?"
ln -s /etc/passwd "$QI_PROFILE_DIR/sandbox/slack.md"
SB guide slack >/dev/null 2>&1; assert_eq "a symlinked guide is refused" 1 "$?"
rm -f "$QI_PROFILE_DIR/sandbox/slack.md"

# check: no bin/sandbox → exit 3; the profile's check runs with QI_ENV_DIR, its output masked.
SB check >/dev/null; assert_eq "no bin/sandbox → exit 3" 3 "$?"
KEY="$(printf -- '-----BEGIN KEY-----\nMIIEowIBAAKCAQEAsandboxsecretline\n-----END KEY-----\n' | base64 | tr -d '\n')"
sed -i.bak "s#^E2E_SANDBOX_GITHUB_PRIVATE_KEY_B64=.*#E2E_SANDBOX_GITHUB_PRIVATE_KEY_B64=$KEY#; s#^E2E_SANDBOX_SLACK_HUMAN_TOKEN=.*#E2E_SANDBOX_SLACK_HUMAN_TOKEN=xoxp-human-9999#" "$CRED"
rm -f "$CRED.bak"
cat > "$QI_PROFILE_DIR/bin/sandbox" <<'S'
#!/usr/bin/env bash
. "$QI_ENV_DIR/credentials.env"
echo "ok github app $E2E_SANDBOX_GITHUB_APP_ID"
echo "FAIL slack token $E2E_SANDBOX_SLACK_HUMAN_TOKEN refused"
exit 1
S
chmod +x "$QI_PROFILE_DIR/bin/sandbox"
chmod -x "$QI_PROFILE_DIR/bin/sandbox"
SB check >/dev/null; assert_eq "a bin/sandbox without its exec bit still runs (its #! names bash)" 1 "$?"
# Without the exec bit the #! line picks the interpreter, not bash; no #! line → bash.
cp "$QI_PROFILE_DIR/bin/sandbox" "$SANDBOX/sandbox.sh.bak"
printf '#!/usr/bin/env node\nconsole.log("ok node ran"); process.exit(0)\n' > "$QI_PROFILE_DIR/bin/sandbox"
assert_eq "a plain-file bin/sandbox with a node #! runs through node" "ok node ran" "$(SB check)"
printf 'echo "ok no shebang"; [ -n "$BASH_VERSION" ] || exit 9\n' > "$QI_PROFILE_DIR/bin/sandbox"
assert_eq "a plain-file bin/sandbox with no #! runs through bash" "ok no shebang" "$(SB check)"
printf '#!\necho no\n' > "$QI_PROFILE_DIR/bin/sandbox"
SB check >/dev/null 2>&1; assert_eq "a #! line with no interpreter is refused" 3 "$?"
mv "$SANDBOX/sandbox.sh.bak" "$QI_PROFILE_DIR/bin/sandbox"
mv "$QI_PROFILE_DIR/bin/sandbox" "$SANDBOX/sandbox-real"
ln -s "$SANDBOX/sandbox-real" "$QI_PROFILE_DIR/bin/sandbox"; chmod +x "$SANDBOX/sandbox-real"
SB check >/dev/null 2>&1; assert_eq "a symlinked bin/sandbox does not count → exit 3" 3 "$?"
rm -f "$QI_PROFILE_DIR/bin/sandbox"; mv "$SANDBOX/sandbox-real" "$QI_PROFILE_DIR/bin/sandbox"
chmod +x "$QI_PROFILE_DIR/bin/sandbox"
out="$(SB check)"; rc=$?
assert_eq "a failing check exits non-zero" 1 "$rc"
assert_eq "its output is masked (a value under 4 characters is not)" "ok github app 42
FAIL slack token *** refused" "$out"

# Masking in run artefacts: every E2E_SANDBOX_ value, and a _B64 one decoded, line by line.
mkdir -p "$SANDBOX/run"
printf 'typed MIIEowIBAAKCAQEAsandboxsecretline and xoxp-human-9999 and %s\n' "$KEY" > "$SANDBOX/run/run.log"
node "$SCRIPTS/lib/secrets.mjs" mask "$CRED" "$SANDBOX/run"
assert_eq "sandbox values are masked, the decoded key too" "typed *** and *** and ***" "$(cat "$SANDBOX/run/run.log")"

# verify-onboarding.sh --config: every credential set, else a FAIL naming the empty lines;
# a refused profile egress rule fails too.
echo "Join the workspace." > "$QI_PROFILE_DIR/sandbox/slack.md"
vo() { bash "$SCRIPTS/verify-onboarding.sh" --config 2>/dev/null | grep -E ' (sandbox|profile_egress)'; }
assert_eq "all set → ok" "ok   sandbox_credentials — github, slack set" "$(vo)"
sed -i.bak 's#^E2E_SANDBOX_SLACK_HUMAN_TOKEN=.*#E2E_SANDBOX_SLACK_HUMAN_TOKEN=#' "$CRED"; rm -f "$CRED.bak"
vo | grep -q '^FAIL sandbox_credentials — not set: E2E_SANDBOX_SLACK_HUMAN_TOKEN — fix: .*never in chat$' \
  || { echo "  assertion failed: an empty credential fails, by name"; FAILED=1; }
jq '.egress = [{"host":"github.com","method":"GET","path":"/sb/qa/*","why":"x"}]' "$QI_PROFILE_DIR/profile.json" > "$SANDBOX/p.json" && mv "$SANDBOX/p.json" "$QI_PROFILE_DIR/profile.json"
vo | grep -q '^FAIL profile_egress:github.com — /sb/qa/\* refused: a GitHub host other than its API' \
  || { echo "  assertion failed: a refused profile egress rule fails"; FAILED=1; }

# A malformed manifest is refused with exit 2.
jq '.sandbox.accounts[0].id = "Git Hub"' "$QI_PROFILE_DIR/profile.json" > "$SANDBOX/p.json" && mv "$SANDBOX/p.json" "$QI_PROFILE_DIR/profile.json"
SB status >/dev/null 2>&1; assert_eq "a bad id is refused" 2 "$?"
jq '.sandbox.accounts[0].id = "github" | .sandbox.accounts[0].guide = "../x.md"' "$QI_PROFILE_DIR/profile.json" > "$SANDBOX/p.json" && mv "$SANDBOX/p.json" "$QI_PROFILE_DIR/profile.json"
SB status >/dev/null 2>&1; assert_eq "a guide outside sandbox/ is refused" 2 "$?"
jq '.sandbox.accounts = {}' "$QI_PROFILE_DIR/profile.json" > "$SANDBOX/p.json" && mv "$SANDBOX/p.json" "$QI_PROFILE_DIR/profile.json"
SB status >/dev/null 2>&1; assert_eq "accounts that are no list are refused" 2 "$?"

exit $FAILED
