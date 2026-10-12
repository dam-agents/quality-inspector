#!/usr/bin/env bash
# e2e-mcp.sh — start the e2e MCP server for exploring the nested platform
# (docs/test-authoring.md → Finding the steps). Registered once at onboarding as the
# harness's `e2e` MCP server. Runs from work/suite so the suite's config and
# credentials apply; the target is always the nested platform on localhost.
set -u
WORK="${WORK_DIR:-${HOME:-/home/agent}/work}"
cd "$WORK/suite" || { echo "e2e-mcp: work/suite missing — run scripts/suite.sh init" >&2; exit 1; }
set -a
# shellcheck disable=SC1091
. "$WORK/env/credentials.env" || exit 1
set +a
export APP_URL=http://localhost:4444 E2E_TELEMETRY_DISABLED=1 NODE_USE_ENV_PROXY=1
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-injected-by-gateway}"
exec npx e2e mcp --headless "$@"
