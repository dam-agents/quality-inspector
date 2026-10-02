#!/usr/bin/env bash
# suite.sh — the e2e test project under work/suite/: create it, run it, summarize.
# The agent calls it; the pre-flight never does. Conventions: docs/test-authoring.md.
#
#   suite.sh init                 create work/suite from scripts/suite-skeleton/ (missing
#                                 files only), install the pinned deps, pick the browser
#   suite.sh run <label> [--evidence full|failures] [e2e run args…]
#                                 run against the nested platform; <label> names the output
#                                 dir (.e2e/runs/<label>) and the summary JSON on stdout.
#                                 `full` records video and a trace page for every test (issue
#                                 verification); `failures` (default) keeps them for failures
#   suite.sh summary <label>      re-print the summary of an earlier run
#
# The base URL is fixed to the nested platform; any APP_URL that is not localhost
# is refused (CLAUDE.md → Hard invariants: nested target only).

set -u
export LC_ALL=C

HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
SUITE="$WORK/suite"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/config.sh" || { echo "cannot source lib/config.sh" >&2; exit 1; }
if ! . "$SCRIPT_DIR/log.sh" 2>/dev/null; then logev() { :; }; fi

E2E_VERSION="$(cfg e2e_version)"; E2E_VERSION="${E2E_VERSION:-0.17.0}"
E2E_WEB_VERSION="$(cfg e2e_web_version)"; E2E_WEB_VERSION="${E2E_WEB_VERSION:-0.12.0}"
E2E_MODEL="$(cfg e2e_model)"; E2E_MODEL="${E2E_MODEL:-claude-sonnet-5}"
APP_URL="${APP_URL:-http://localhost:4444}"

die() { echo "suite: $*" >&2; logev error suite_failed "$*"; exit 1; }

cmd_init() {
  mkdir -p "$SUITE"
  ( cd "$SCRIPT_DIR/suite-skeleton" && find . -type f ) | while read -r f; do
    [ -e "$SUITE/$f" ] && continue
    mkdir -p "$SUITE/$(dirname "$f")" && cp "$SCRIPT_DIR/suite-skeleton/$f" "$SUITE/$f"
  done
  if [ "$(jq -r .version "$SUITE/node_modules/e2e/package.json" 2>/dev/null)" != "$E2E_VERSION" ] \
     || [ "$(jq -r .version "$SUITE/node_modules/@e2e-dev/web/package.json" 2>/dev/null)" != "$E2E_WEB_VERSION" ]; then
    ( cd "$SUITE" && npm install --no-audit --no-fund --save-exact -D \
        "e2e@$E2E_VERSION" "@e2e-dev/web@$E2E_WEB_VERSION" ai @ai-sdk/anthropic >/dev/null 2>"/tmp/quality-inspector-npm.err" ) \
      || { local e; e="$(tail -5 /tmp/quality-inspector-npm.err)"; rm -f /tmp/quality-inspector-npm.err; die "npm install failed: $e"; }
    rm -f /tmp/quality-inspector-npm.err
  fi
  pick_browser
  ( cd "$SUITE" && E2E_TELEMETRY_DISABLED=1 npx e2e telemetry disable >/dev/null 2>&1 ) || true
  echo "suite: ready at $SUITE (e2e $E2E_VERSION)" >&2
}

# @e2e-dev/web pins its own playwright-core. The image bakes one Chromium for one
# Playwright version; when the two differ, the matching Chromium goes into the home.
pick_browser() {
  local core baked path
  core="$(find "$SUITE/node_modules" -maxdepth 4 -path '*playwright-core/package.json' 2>/dev/null | head -1)"
  core="$(jq -r .version "$core" 2>/dev/null)"
  baked="$(playwright --version 2>/dev/null | awk '{print $2}')"
  if [ -n "$core" ] && [ "$core" = "$baked" ]; then
    path="${PLAYWRIGHT_BROWSERS_PATH:-/opt/ms-playwright}"
  else
    path="$HOME_DIR/.cache/ms-playwright"
    ( cd "$SUITE" && PLAYWRIGHT_BROWSERS_PATH="$path" npx playwright-core install chromium >/dev/null 2>&1 ) \
      || die "playwright-core $core differs from the image's $baked and its Chromium download failed (README → Black-box boundary)"
    logev warn browser_download "playwright-core $core differs from the baked $baked; Chromium installed into $path"
  fi
  printf '%s\n' "$path" > "$SUITE/.browsers-path"
}

summarize() { # <report.json> <label>
  jq -c --arg label "$2" '
    .run as $r
    | [$r.results[]? | {
        title: (.titlePath | join(" › ")),
        file: (.file // .source.file // null),
        tags: (.tags // []),
        status,
        code: ([.attempts[]?.error.code // empty] | last // null)
      }] as $res
    | [$r.results[]?.attempts[]?.steps[]?.cache.mode // empty] as $modes
    | {label: $label, status: $r.status, exit_code: $r.exitCode, summary: $r.summary,
       results: $res,
       cache: {replayed: ($modes | map(select(. == "self-finalized")) | length),
               handed_off: ($modes | map(select(. == "agent-concluded")) | length),
               missed: ($modes | map(select(. == "missed")) | length)}}' "$1"
}

cmd_run() {
  local label="${1:?label}"; shift
  local evidence=failures rec
  if [ "${1:-}" = --evidence ]; then evidence="${2:?full|failures}"; shift 2; fi
  case "$evidence" in (full) rec=on;; (failures) rec=retain-on-failure;; (*) die "--evidence must be full or failures";; esac
  case "$label" in (*[!A-Za-z0-9._-]*) die "label must be [A-Za-z0-9._-]";; esac
  case "$APP_URL" in
    (http://localhost:*|http://localhost/*|http://localhost|http://127.0.0.1:*) ;;
    (*) die "refusing APP_URL=$APP_URL — only the nested platform on localhost is a test target";;
  esac
  [ -d "$SUITE/node_modules/e2e" ] || die "suite not initialized — run: bash \"\$HOME/scripts/suite.sh\" init"
  [ -f "$WORK/env/credentials.env" ] || die "work/env/credentials.env missing — run: bash \"\$HOME/scripts/env.sh\" init"
  local out=".e2e/runs/$label"
  (
    cd "$SUITE" || exit 1
    set -a; . "$WORK/env/credentials.env"; set +a
    export APP_URL E2E_MODEL E2E_TELEMETRY_DISABLED=1 NODE_USE_ENV_PROXY=1
    # Model calls leave through the gateway, which injects the provider credential.
    export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-injected-by-gateway}"
    PLAYWRIGHT_BROWSERS_PATH="$(cat .browsers-path 2>/dev/null || echo "${PLAYWRIGHT_BROWSERS_PATH:-/opt/ms-playwright}")"
    export PLAYWRIGHT_BROWSERS_PATH
    npx e2e run "$@" --output "$out" --reporter list --trace="$rec" --video="$rec" \
      >"/tmp/quality-inspector-run-$label.log" 2>&1
  )
  local rc=$?
  if [ ! -f "$SUITE/$out/report.json" ]; then
    local e; e="$(tail -20 "/tmp/quality-inspector-run-$label.log" 2>/dev/null)"; rm -f "/tmp/quality-inspector-run-$label.log"
    die "e2e produced no report (exit $rc): $e"
  fi
  mv -f "/tmp/quality-inspector-run-$label.log" "$SUITE/$out/run.log" 2>/dev/null || true
  logev info suite_run "$label exit=$rc"
  summarize "$SUITE/$out/report.json" "$label"
}

cmd_summary() { local f="$SUITE/.e2e/runs/${1:?label}/report.json"; [ -f "$f" ] || die "no report for $1"; summarize "$f" "$1"; }

case "${1:-}" in
  init)    cmd_init ;;
  run)     shift; cmd_run "$@" ;;
  summary) cmd_summary "${2:-}" ;;
  *) echo "usage: $0 init | run <label> [--evidence full|failures] [e2e run args…] | summary <label>" >&2; exit 2 ;;
esac
