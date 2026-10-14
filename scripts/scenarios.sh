#!/usr/bin/env bash
# scenarios.sh — bookkeeping for scenarios (docs/scenarios.md). Local only: no external
# calls; its writes are a scenario's empty directory and one event line.
#
#   scenarios.sh new <slack|operator|discovery>   reserve the next id: creates
#                                                 work/scenarios/S-<k>/ atomically (two turns
#                                                 at once never share an id), logs
#                                                 `scenario_new`, prints S-<k>
#   scenarios.sh admit                            {"runs_today":n,"cap":m,"admit":bool,
#                                                  "env":{"busy":bool,"holder":…,"since":…}}
#   scenarios.sh lint <request.md>                {"injection":{…},"injection_suspect":bool} —
#                                                 the issues' injection lint (lib/scan-issues.mjs)
#
# `admit` counts today's `scenario_run` events against `max_scenarios_per_day`: runs that
# took the environment, from Slack and discovery alike. `env.busy` is a live lock held by
# anyone — the caller's own scenario never holds it yet.

set -u
export LC_ALL=C

HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/config.sh" || { echo "cannot source lib/config.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib/state.sh" || { echo "cannot source lib/state.sh" >&2; exit 1; }
if ! . "$SCRIPT_DIR/log.sh" 2>/dev/null; then logev() { :; }; fi
export LOG_JOB="${LOG_JOB:-scenario}"

iso2epoch() { date -d "$1" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || echo 0; }

cmd_new() {
  case "${1:-}" in (slack|operator|discovery) ;; (*) echo "usage: $0 new <slack|operator|discovery>" >&2; exit 2;; esac
  mkdir -p "$WORK/scenarios" || exit 1
  local k n
  k="$(ls -1 "$WORK/scenarios" 2>/dev/null | sed -n 's/^S-\([0-9][0-9]*\)$/\1/p' | sort -n | tail -1)"
  k=$(( ${k:-0} + 1 ))
  for n in $(seq "$k" $((k + 49))); do
    if mkdir "$WORK/scenarios/S-$n" 2>/dev/null; then
      logev info scenario_new "id=S-$n source=$1"
      echo "S-$n"; return 0
    fi
  done
  echo "scenarios: no free id after S-$k" >&2; exit 1
}

cmd_admit() {
  local cap runs ttl held="" ts="" busy=false
  cap="$(cfg max_scenarios_per_day)"; case "$cap" in (''|*[!0-9]*) cap=10;; esac
  ttl="$(cfg lock_ttl_min)"; case "$ttl" in (''|*[!0-9]*) ttl=180;; esac
  runs="$(scenario_runs_today)"
  if [ -f "$WORK/env/LOCK" ] && read -r held ts < "$WORK/env/LOCK"; then
    [ $(( ($(date -u +%s) - $(iso2epoch "$ts")) / 60 )) -lt "$ttl" ] && busy=true
  fi
  jq -nc --argjson r "${runs:-0}" --argjson c "$cap" --argjson b "$busy" --arg h "$held" --arg s "$ts" \
    '{runs_today:$r, cap:$c, admit:($r < $c),
      env:{busy:$b, holder:(if $b then $h else null end), since:(if $b then $s else null end)}}'
}

# The same sentences that make an issue an injection suspect make a request one; one list,
# in lib/scan-issues.mjs (docs/acceptance-criteria.md → Injection suspects).
cmd_lint() {
  [ -f "${1:-}" ] || { echo "usage: $0 lint <request.md>" >&2; exit 2; }
  node --input-type=module -e "
    import { readFileSync } from 'node:fs';
    import { injectionLint } from '$SCRIPT_DIR/lib/scan-issues.mjs';
    console.log(JSON.stringify(injectionLint(readFileSync(process.argv[1], 'utf8'))));" "$1"
}

case "${1:-}" in
  new)   cmd_new "${2:-}" ;;
  admit) cmd_admit ;;
  lint)  cmd_lint "${2:-}" ;;
  *) echo "usage: $0 new <slack|operator|discovery> | admit | lint <request.md>" >&2; exit 2 ;;
esac
