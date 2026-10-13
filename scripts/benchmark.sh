#!/usr/bin/env bash
# benchmark.sh — measure the agent against cases whose right answer is known
# (docs/benchmark.md). Deterministic bookkeeping only; the agent runs the cases.
#
#   benchmark.sh due                 one JSON object: {due, reason, cases, last_run}
#   benchmark.sh prepare <run-id>    write work/benchmark/runs/<run-id>/<case>/input.json per
#                                    case — everything but the expected answers
#   benchmark.sh score <run-id>      compare each case's verdicts.json with its expected
#                                    answers; JSON summary on stdout, one line appended to
#                                    work/benchmark/history.jsonl
#
# work/benchmark/cases.json is the operator's ground truth. Inputs never carry it, and the
# pipeline that runs a case never reads it.

set -u
export LC_ALL=C

HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
B="$WORK/benchmark"
CASES="$B/cases.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/config.sh" || { echo "cannot source lib/config.sh" >&2; exit 1; }

die() { echo "benchmark: $*" >&2; exit 1; }
fingerprint() { printf '%s %s %s %s' "$(head -1 "$HOME_DIR/VERSION" 2>/dev/null)" "$(cfg e2e_version)" "$(cfg e2e_model)" "$(cfg profile)"; }

cmd_due() {
  local n last fp lastfp age
  n="$(jq 'length' "$CASES" 2>/dev/null || echo 0)"
  [ "$n" -gt 0 ] 2>/dev/null || { jq -nc '{due:false, reason:"no cases in work/benchmark/cases.json", cases:0, last_run:null}'; return; }
  last="$(tail -1 "$B/history.jsonl" 2>/dev/null)"
  if [ -z "$last" ]; then jq -nc --argjson n "$n" '{due:true, reason:"never run", cases:$n, last_run:null}'; return; fi
  fp="$(fingerprint)"; lastfp="$(jq -r '.fingerprint // ""' <<<"$last")"
  age=$(( ($(date -u +%s) - $(date -u -d "$(jq -r .utc <<<"$last")" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$(jq -r .utc <<<"$last")" +%s)) / 86400 ))
  if [ "$fp" != "$lastfp" ]; then jq -nc --argjson n "$n" --arg r "definition, e2e, model or profile changed ($lastfp → $fp)" --argjson l "$last" '{due:true, reason:$r, cases:$n, last_run:$l.utc}'
  elif [ "$age" -ge 28 ]; then jq -nc --argjson n "$n" --arg r "last run ${age} days ago" --argjson l "$last" '{due:true, reason:$r, cases:$n, last_run:$l.utc}'
  else jq -nc --argjson n "$n" --arg r "ran ${age} days ago with the same setup" --argjson l "$last" '{due:false, reason:$r, cases:$n, last_run:$l.utc}'; fi
}

cmd_prepare() {
  local run="${1:?run-id}" id
  [ -f "$CASES" ] || die "no $CASES"
  jq -e 'type == "array" and all(.[]; .id and (.type == "issue" or .type == "criteria") and .expected)' "$CASES" >/dev/null \
    || die "cases.json: every case needs id, type issue|criteria, expected"
  for id in $(jq -r '.[].id' "$CASES"); do
    mkdir -p "$B/runs/$run/$id"
    jq --arg id "$id" '.[] | select(.id == $id) | del(.expected, .note) | . + {tag: ("issue-bench-" + .id)}' "$CASES" \
      > "$B/runs/$run/$id/input.json"
  done
  jq -nc --arg r "$run" --argjson n "$(jq length "$CASES")" '{run:$r, prepared:$n, dir:("work/benchmark/runs/" + $r)}'
}

cmd_score() {
  local run="${1:?run-id}" dir="$B/runs/${1:-}" per='[]' id exp got v
  [ -d "$dir" ] || die "no run $run"
  for id in $(jq -r '.[].id' "$CASES"); do
    exp="$(jq -c --arg id "$id" '.[] | select(.id == $id) | .expected' "$CASES")"
    v="$dir/$id/verdicts.json"
    if [ -f "$v" ]; then got="$(jq -c '{verdict, acs: ([.acs[]? | {(.id): .verdict}] | add // {}), minutes: .minutes, cost_usd: .cost_usd}' "$v")"
    else got='{"verdict":null,"acs":{},"missing":true}'; fi
    per="$(jq -c --arg id "$id" --argjson e "$exp" --argjson g "$got" '. + [{
      id:$id, expected:$e, got:$g,
      issue_match: (if $e.verdict then ($e.verdict == $g.verdict) else null end),
      ac: [($e.acs // {}) | to_entries[] | {ac:.key, expected:.value, got:($g.acs[.key] // null)}]
    }]' <<<"$per")"
  done
  local fp; fp="$(fingerprint)"
  jq -c --arg run "$run" --arg utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg fp "$fp" '
    [.[].ac[]] as $acs
    | {run:$run, utc:$utc, fingerprint:$fp, cases:length,
       missing: (map(select(.got.missing)) | length),
       issue_accuracy: ((map(select(.issue_match != null)) | if length == 0 then null else (map(select(.issue_match)) | length) / length end)),
       ac_total: ($acs | length),
       ac_accuracy: (if ($acs | length) == 0 then null else ($acs | map(select(.expected == .got)) | length) / ($acs | length) end),
       false_verified: ($acs | map(select(.got == "verified" and .expected != "verified")) | length),
       false_failed:   ($acs | map(select(.got == "failed" and .expected != "failed")) | length),
       blocked_rate: (if ($acs | length) == 0 then null else ($acs | map(select(.got == "blocked" or .got == "flaky")) | length) / ($acs | length) end),
       minutes: (map(.got.minutes // 0) | add), cost_usd: (map(.got.cost_usd // 0) | add),
       per_case: .}' <<<"$per" | tee -a "$B/history.jsonl"
}

case "${1:-}" in
  due)     cmd_due ;;
  prepare) cmd_prepare "${2:-}" ;;
  score)   cmd_score "${2:-}" ;;
  *) echo "usage: $0 due | prepare <run-id> | score <run-id>" >&2; exit 2 ;;
esac
