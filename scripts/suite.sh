#!/usr/bin/env bash
# suite.sh — the e2e test project under work/suite/: create it, run it, summarize.
# The agent calls it; the pre-flight never does. Conventions: docs/test-authoring.md.
#
#   suite.sh init                 create work/suite from scripts/suite-skeleton/ (missing
#                                 files only), install the pinned deps, pick the browser
#   suite.sh run <label> [--evidence full|failures] [--strict] [e2e run args…]
#                                 run against the nested platform; <label> names the output
#                                 dir (.e2e/runs/<label>) and the summary JSON on stdout.
#                                 `full` records video and a trace page for every test (issue
#                                 verification); `failures` (default) keeps them for failures.
#                                 --strict turns off criterion()'s judged fallback (red-green).
#                                 Extra args go to `e2e run`; a confirmation re-run adds
#                                 `--repeat-each 3 --no-cache`, and by_test[].stability reads it
#   suite.sh summary <label>      re-print the summary of an earlier run
#   suite.sh roles                the e2e identities the profile provided, as a JSON array
#                                 of role names (`["owner","member"]`) — names only, never a
#                                 value (docs/explorations.md → Identities)
#   suite.sh budget <claim-iso>   the per-issue budgets since the claim, JSON with `exceeded`
#
# The base URL is fixed to the nested platform; any APP_URL that is not localhost
# is refused (CLAUDE.md → Hard invariants: nested target only). After every run the
# credential values of work/env/credentials.env are masked in the run dir's text files
# and in every summary (lib/secrets.mjs; the audit's secrets_in_runs proves it).

set -u
export LC_ALL=C

HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
SUITE="$WORK/suite"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/config.sh" || { echo "cannot source lib/config.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib/profile.sh" || { echo "cannot source lib/profile.sh" >&2; exit 1; }
if ! . "$SCRIPT_DIR/log.sh" 2>/dev/null; then logev() { :; }; fi

E2E_VERSION="$(cfg e2e_version)"; E2E_VERSION="${E2E_VERSION:-0.17.0}"
E2E_WEB_VERSION="$(cfg e2e_web_version)"; E2E_WEB_VERSION="${E2E_WEB_VERSION:-0.12.0}"
E2E_MODEL="$(cfg e2e_model)"; E2E_MODEL="${E2E_MODEL:-claude-sonnet-5}"
APP_URL="${APP_URL:-$(profile_field '.app.url')}"

die() { echo "suite: $*" >&2; logev error suite_failed "$*"; exit 1; }
CRED="$WORK/env/credentials.env"
unsecret() { node "$SCRIPT_DIR/lib/secrets.mjs" filter "$CRED"; }  # stdin -> stdout, masked

cmd_init() {
  mkdir -p "$SUITE"
  # The core skeleton, then the profile's own suite/ files (fixtures, helpers); missing files only.
  local src pdir; pdir="$(profile_dir 2>/dev/null)"
  for src in "$SCRIPT_DIR/suite-skeleton" ${pdir:+"$pdir/suite"}; do
    [ -d "$src" ] || continue
    ( cd "$src" && find . -type f ) | while read -r f; do
      [ -e "$SUITE/$f" ] && continue
      mkdir -p "$SUITE/$(dirname "$f")" && cp "$src/$f" "$SUITE/$f"
    done
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
      || die "playwright-core $core differs from the image's $baked and its Chromium download failed (docs/black-box.md → Egress rules)"
    logev warn browser_download "playwright-core $core differs from the baked $baked; Chromium installed into $path"
  fi
  printf '%s\n' "$path" > "$SUITE/.browsers-path"
}

summarize() { # <report.json> <label>
  jq -c --arg label "$2" '
    .run as $r
    | [$r.results[]? | select(.selected != false) | {
        title: (.titlePath | join(" › ")),
        file: (.file // .source.file // null),
        tags: (.tags // []),
        status,
        code: ([.attempts[]?.error.code // empty] | last // null),
        judged: (if .status == "passed" then [.attempts[-1].steps[]? | select((.api | startswith("expect.")) and .status == "failed") | .label] else [] end),
        relearned: [.attempts[-1].steps[]? | select(.cache.mode == "agent-concluded" or .cache.mode == "missed") | .label]
      }] as $res
    | [$r.results[]?.attempts[]?.steps[]?.cache.mode // empty] as $modes
    | ($res | group_by(.title) | map({title: .[0].title, tags: .[0].tags, runs: length,
         passes: (map(select(.status == "passed")) | length),
         codes: ([.[].code // empty] | unique)})
       | map(. + {stability: (if .passes == .runs then "stable-pass" elif .passes == 0 then "stable-fail" else "flaky" end)})) as $by
    | {label: $label, status: $r.status, exit_code: $r.exitCode, summary: $r.summary,
       results: $res, by_test: $by,
       cache: {replayed: ($modes | map(select(. == "self-finalized")) | length),
               handed_off: ($modes | map(select(. == "agent-concluded")) | length),
               missed: ($modes | map(select(. == "missed")) | length)}}' "$1"
}

cmd_run() {
  local label="${1:?label}"; shift
  local evidence=failures rec
  local strict=0
  while :; do case "${1:-}" in
    (--evidence) evidence="${2:?full|failures}"; shift 2;;
    (--strict) strict=1; shift;;
    (*) break;;
  esac; done
  case "$evidence" in (full) rec=on;; (failures) rec=retain-on-failure;; (*) die "--evidence must be full or failures";; esac
  case "$label" in (*[!A-Za-z0-9._-]*) die "label must be [A-Za-z0-9._-]";; esac
  case "$APP_URL" in
    (http://localhost:*|http://localhost/*|http://localhost|http://127.0.0.1:*) ;;
    (*) die "refusing APP_URL=$APP_URL — only the nested platform on localhost is a test target";;
  esac
  [ -d "$SUITE/node_modules/e2e" ] || die "suite not initialized — run: bash \"\$HOME/scripts/suite.sh\" init"
  [ -f "$CRED" ] || die "work/env/credentials.env missing — run: bash \"\$HOME/scripts/env.sh\" init"
  local out=".e2e/runs/$label"
  (
    cd "$SUITE" || exit 1
    set -a; . "$CRED"; set +a
    export APP_URL E2E_MODEL E2E_TELEMETRY_DISABLED=1 NODE_USE_ENV_PROXY=1 QI_STRICT="$strict"
    # Model calls leave through the gateway, which injects the provider credential.
    export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-injected-by-gateway}"
    PLAYWRIGHT_BROWSERS_PATH="$(cat .browsers-path 2>/dev/null || echo "${PLAYWRIGHT_BROWSERS_PATH:-/opt/ms-playwright}")"
    export PLAYWRIGHT_BROWSERS_PATH
    npx e2e run "$@" --output "$out" --reporter list --trace="$rec" --video="$rec" \
      >"/tmp/quality-inspector-run-$label.log" 2>&1
  )
  local rc=$?
  if [ ! -f "$SUITE/$out/report.json" ]; then
    local e; e="$(tail -20 "/tmp/quality-inspector-run-$label.log" 2>/dev/null | unsecret)"; rm -f "/tmp/quality-inspector-run-$label.log"
    [ -d "$SUITE/$out" ] && node "$SCRIPT_DIR/lib/secrets.mjs" mask "$CRED" "$SUITE/$out"
    die "e2e produced no report (exit $rc): $e"
  fi
  mv -f "/tmp/quality-inspector-run-$label.log" "$SUITE/$out/run.log" 2>/dev/null || true
  # run.log and report.json carry agent-step params — the setup test's password among them.
  node "$SCRIPT_DIR/lib/secrets.mjs" mask "$CRED" "$SUITE/$out" \
    || die "masking credentials in $out failed — publish nothing from it (audit: secrets_in_runs)"
  logev info suite_run "$label exit=$rc"
  masked_summary "$SUITE/$out/report.json" "$label"
}

# A role is provided when credentials.env sets a non-empty E2E_USER_<ROLE>_USERNAME (lib/profile.sh).
cmd_roles() {
  local f="$WORK/env/credentials.env"
  [ -f "$f" ] || die "work/env/credentials.env missing — run: bash \"\$HOME/scripts/env.sh\" init"
  provided_roles "$f"
}

# The summary on stdout is masked too; fails when either half of the pipe failed.
masked_summary() { summarize "$1" "$2" | unsecret; [ "${PIPESTATUS[0]}${PIPESTATUS[1]}" = 00 ]; }
cmd_summary() { local f="$SUITE/.e2e/runs/${1:?label}/report.json"; [ -f "$f" ] || die "no report for $1"; masked_summary "$f" "$1"; }

# Per-issue budgets (docs/nested-env.md → Budgets): minutes since the claim, and the
# model-backed steps — agent.act / agent.assert not replayed from the cache — of every run
# written since then (the environment lock makes those runs this issue's).
cmd_budget() { # <claim-iso>
  local since="${1:-}" wall cap se el f m n=0 steps=0 k
  wall="$(cfg max_wallclock_min_per_issue)"; case "$wall" in (''|*[!0-9]*) wall=150;; esac
  cap="$(cfg max_model_steps_per_issue)"; case "$cap" in (''|*[!0-9]*) cap=400;; esac
  se="$(date -u -d "$since" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$since" +%s 2>/dev/null)"
  [ -n "$se" ] || { echo "suite: budget needs the claim time as ISO UTC, got '$since'" >&2; exit 2; }
  el=$(( ($(date -u +%s) - se) / 60 ))
  while IFS= read -r f; do
    m="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)"; [ "${m:-0}" -ge "$se" ] || continue
    k="$(jq '[.run.results[]?.attempts[]? | .. | objects | (.api? // "") as $a
              | select(($a == "agent.act" or $a == "agent.assert") and .cache.mode? != "self-finalized")] | length' "$f" 2>/dev/null)"
    n=$((n+1)); steps=$((steps + ${k:-0}))
  done < <(find "$SUITE/.e2e/runs" -mindepth 2 -maxdepth 2 -name report.json 2>/dev/null)
  jq -nc --arg s "$since" --argjson el "$el" --argjson w "$wall" --argjson n "$n" --argjson k "$steps" --argjson c "$cap" \
    '{since:$s, elapsed_min:$el, max_wallclock_min:$w, runs:$n, model_steps:$k, max_model_steps:$c,
      exceeded: ([if $el > $w then "wallclock" else empty end, if $k > $c then "model_steps" else empty end])}'
}

case "${1:-}" in
  init)    cmd_init ;;
  run)     shift; cmd_run "$@" ;;
  summary) cmd_summary "${2:-}" ;;
  roles)   cmd_roles ;;
  budget)  cmd_budget "${2:-}" ;;
  *) echo "usage: $0 init | run <label> [--evidence full|failures] [--strict] [e2e run args…] | summary <label> | roles | budget <claim-iso>" >&2; exit 2 ;;
esac
