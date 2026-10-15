#!/usr/bin/env bash
# The model credential of agent steps (docs/test-authoring.md → Model access): model_auth passes
# the platform's placeholders on, model_probe sends them in the connection's own header, and
# suite.sh refuses a config that sends none.
. "$(dirname "$0")/lib.sh"
seed_work
export HOME="$SANDBOX/home"; mkdir -p "$HOME/.platform" "$SANDBOX/bin"
unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN PLATFORM_PROVIDER
lib() { ( . "$SCRIPTS/lib/config.sh"; . "$SCRIPTS/lib/profile.sh"; CONFIG="$WORK_DIR/CONFIG.md" "$@" ); }

# model_auth: the environment first, with its base URL; nothing set and no provider = nothing.
assert_eq "no connection, nothing" "" "$(lib model_auth)"
assert_eq "auth token and base from the environment" \
  "$(printf 'ANTHROPIC_BASE_URL=https://llm.example\nANTHROPIC_AUTH_TOKEN=sk-platform:conn:c1')" \
  "$(ANTHROPIC_BASE_URL=https://llm.example ANTHROPIC_AUTH_TOKEN=sk-platform:conn:c1 lib model_auth)"
# Else the runtime env of the agent's provider: only the model variables, never another one.
echo '{"providers":[{"id":"p1","env":{"ANTHROPIC_API_KEY":"platform:conn:p1","GH_TOKEN":"x","ANTHROPIC_BASE_URL":""}},
  {"id":"p2","env":{"ANTHROPIC_AUTH_TOKEN":"platform:conn:p2"}}]}' > "$HOME/.platform/runtime-env.json"
assert_eq "runtime env of PLATFORM_PROVIDER" "ANTHROPIC_API_KEY=platform:conn:p1" "$(PLATFORM_PROVIDER=p1 lib model_auth)"

# model_probe: a stub curl records the request and answers with $CURL_CODE.
cat > "$SANDBOX/bin/curl" <<'S'
#!/usr/bin/env bash
out=; while [ $# -gt 0 ]; do
  case "$1" in (-o) out="$2"; shift;; (-H) echo "H $2" >> "$CURL_LOG"; shift;; (-d) echo "D $2" >> "$CURL_LOG"; shift;;
    (https://*) echo "U $1" >> "$CURL_LOG";; esac; shift; done
printf '%s' "${CURL_BODY:-{\}}" > "$out"; printf '%s' "$CURL_CODE"
S
chmod +x "$SANDBOX/bin/curl"
export CURL_LOG="$SANDBOX/curl.log"
probe() { : > "$CURL_LOG"; PATH="$SANDBOX/bin:$PATH" lib model_probe; }
assert_eq "no connection: nothing sent" "none|https://api.anthropic.com/v1||claude-sonnet-5|" "$(probe)"
[ -s "$CURL_LOG" ] && { echo "  a probe without a connection sent a request"; FAILED=1; }

r="$(ANTHROPIC_BASE_URL=https://llm.example/ ANTHROPIC_AUTH_TOKEN=sk-platform:conn:c1 CURL_CODE=200 probe)"
assert_eq "proxy with an auth token" "200|https://llm.example/v1|ANTHROPIC_AUTH_TOKEN|claude-sonnet-5|" "$r"
grep -qx 'U https://llm.example/v1/messages' "$CURL_LOG" || { echo "  not sent to <base>/v1/messages"; FAILED=1; }
grep -qx 'H Authorization: Bearer sk-platform:conn:c1' "$CURL_LOG" || { echo "  auth token not sent as Bearer"; FAILED=1; }
grep -q '^H x-api-key' "$CURL_LOG" && { echo "  an auth-token connection must not send x-api-key"; FAILED=1; }
grep -q '"model":"claude-sonnet-5"' "$CURL_LOG" || { echo "  the probe does not ask for e2e_model"; FAILED=1; }

echo "- e2e_model: claude-opus-5" >> "$WORK_DIR/CONFIG.md"
r="$(ANTHROPIC_API_KEY=platform:conn:k1 CURL_CODE=401 CURL_BODY='{"error":{"message":"Invalid proxy server token passed"}}' probe)"
assert_eq "api key, refused" "401|https://api.anthropic.com/v1|ANTHROPIC_API_KEY|claude-opus-5|Invalid proxy server token passed" "$r"
grep -qx 'H x-api-key: platform:conn:k1' "$CURL_LOG" || { echo "  api key not sent as x-api-key"; FAILED=1; }

ANTHROPIC_BASE_URL=https://llm.example/v1 CLAUDE_CODE_OAUTH_TOKEN=platform:conn:o1 CURL_CODE=200 probe >/dev/null
grep -qx 'U https://llm.example/v1/messages' "$CURL_LOG" || { echo "  a base ending in /v1 got another /v1"; FAILED=1; }
grep -qx 'H anthropic-beta: oauth-2025-04-20' "$CURL_LOG" || { echo "  oauth token without its beta header"; FAILED=1; }

# suite.sh run: a config from before 2.22.0 is refused; the skeleton's is not.
mkdir -p "$WORK_DIR/env" "$WORK_DIR/suite/node_modules/e2e"
echo 'E2E_USER_OWNER_USERNAME=owner' > "$WORK_DIR/env/credentials.env"
echo "import { anthropic } from '@ai-sdk/anthropic';" > "$WORK_DIR/suite/e2e.config.ts"
err="$(bash "$SCRIPTS/suite.sh" run stale 2>&1 >/dev/null)"
case "$err" in *"predates 2.22.0"*) ;; *) echo "  a stale e2e.config.ts was not refused: $err"; FAILED=1;; esac
grep -q 'createAnthropic' "$SCRIPTS/suite-skeleton/e2e.config.ts" || { echo "  the skeleton lacks the 2.22.0 marker"; FAILED=1; }
grep -q 'injected-by-gateway' "$SCRIPTS/suite.sh" "$SCRIPTS/e2e-mcp.sh" "$SCRIPTS/verify-onboarding.sh" \
  && { echo "  a literal key is still sent somewhere"; FAILED=1; }
exit $FAILED
