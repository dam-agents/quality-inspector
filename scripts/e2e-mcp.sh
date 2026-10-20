#!/usr/bin/env bash
# e2e-mcp.sh — start the e2e MCP server for exploring the nested product
# (docs/test-authoring.md → Finding the steps). Registered once at onboarding as the
# harness's `e2e` MCP server. Runs from work/suite so the suite's config and
# credentials apply; the target is always the profile's nested product on localhost.
set -u
WORK="${WORK_DIR:-${HOME:-/home/agent}/work}"
cd "$WORK/suite" || { echo "e2e-mcp: work/suite missing — run scripts/suite.sh init" >&2; exit 1; }
set -a
# shellcheck disable=SC1091
. "$WORK/env/credentials.env" || exit 1
set +a
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; CONFIG="$WORK/CONFIG.md"
. "$SCRIPT_DIR/lib/config.sh" && . "$SCRIPT_DIR/lib/profile.sh" || exit 1
APP_URL="$(profile_field '.app.url')"
case "$APP_URL" in (http://localhost*|http://127.0.0.1*) ;; (*) echo "e2e-mcp: refusing app url '$APP_URL' — nested product only" >&2; exit 1;; esac
export APP_URL E2E_TELEMETRY_DISABLED=1 NODE_USE_ENV_PROXY=1
# The model connection's placeholder, never a literal key (lib/profile.sh → model_auth).
while IFS='=' read -r k v; do [ -n "$k" ] && export "$k=$v"; done < <(model_auth)
# live_browser: explore in the browser the operator watches (lib/config.sh → live_cdp).
cdp="$(live_cdp)" && export E2E_CDP_ENDPOINT="$cdp"
exec npx e2e mcp "$@"
