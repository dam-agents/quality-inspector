#!/usr/bin/env bash
# preflight.sh — deterministic pre-flight for quality-inspector.
#
# The script DETECTS, it NEVER ACTS:
#
#   - NO external writes at all (list/GET calls only),
#   - NO git commit/push,
#   - local writes only: one line per call in work/<RUNTYPE>.log, the audit-mode
#     log retention sweep, and the daily media retention sweep (retention_sweep).
#
#   preflight.sh <mode>   -> one JSON object on stdout; everything else to stderr.
#   .nothing_to_do == true  -> the agent ends the run immediately.
#   otherwise               -> the agent processes the arrays per CLAUDE.md + docs/.
#
# Modes: issues (default) | regression | discovery | audit | benchmark | security | modules | slack.
# Requires: bash, jq, gh, curl, sed/grep/awk, GNU date (Linux pod).

set -u
export LC_ALL=C

MODE="${1:-issues}"
HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
NOW_EPOCH=$(date -u +%s)
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

LOGS=()
log() { LOGS+=("$1"); }
logs_json() { printf '%s\n' "${LOGS[@]:-}" | jq -R . | jq -sc '[.[] | select(length>0)]'; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/config.sh" || { echo "cannot source lib/config.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib/state.sh" || { echo "cannot source lib/state.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib/profile.sh" || { echo "cannot source lib/profile.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib/boundary.sh" || { echo "cannot source lib/boundary.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib/lock.sh" || { echo "cannot source lib/lock.sh" >&2; exit 1; }

iso2epoch() { date -d "$1" +%s 2>/dev/null \
              || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || echo 0; }

# ---------------------------------------------------------------- config ----
TARGET="${QI_TARGET_REPO:-$(cfg target_repo)}"
QA_LABEL="$(cfg qa_label)"; QA_LABEL="${QA_LABEL:-qa:ready}"
RETEST_LABEL="$(cfg retest_label)"; RETEST_LABEL="${RETEST_LABEL:-qa:retest}"
# Builds come from the product profile: {"candidate": …, "baseline": …|null}.
versions_json() { # [baseline-channel override, e.g. none]
  QI_BASELINE_OVERRIDE="${1:-}" profile_run versions | jq -ce 'select(.candidate != null and .candidate != "")' 2>/dev/null
}
MAX_ISSUES="$(reg max_issues_per_run)"; MAX_ISSUES="${MAX_ISSUES:-1}"
LOCK_TTL_MIN="$(cfg lock_ttl_min)"; LOCK_TTL_MIN="${LOCK_TTL_MIN:-180}"
case "$MAX_ISSUES" in (''|*[!0-9]*) MAX_ISSUES=1;; esac
case "$LOCK_TTL_MIN" in (''|*[!0-9]*) LOCK_TTL_MIN=180;; esac

# A [host/]owner/repo ref: the host part only when it has three segments.
GH_HOST_ARGS=(); REPO_PATH="$TARGET"
if [ "$(printf '%s' "$TARGET" | tr -cd '/' | wc -c | tr -d ' ')" = 2 ]; then
  GH_HOST_ARGS=(--hostname "${TARGET%%/*}"); REPO_PATH="${TARGET#*/}"
fi

runlog() { mkdir -p "$WORK" 2>/dev/null && printf '%s %s\n' "$NOW_ISO" "$2" >> "$WORK/$1.log" 2>/dev/null || true; }

fail_out() {  # nothing-to-do JSON with an error; the agent just logs it
  runlog "$(printf '%s' "$MODE" | tr '[:lower:]' '[:upper:]')" "ERROR: $1"
  jq -nc --arg mode "$MODE" --arg err "$1" --argjson logs "$(logs_json)" \
    '{mode:$mode, nothing_to_do:true, error:$err, logs:$logs}'
  exit 0
}

# Media retention, at most once a UTC day: raw e2e runs past the window go; a report keeps
# its text but loses media/ once past the window AND delivered (artifact.id present, or
# artifact reports disabled). Undelivered evidence is never deleted.
MEDIA_DAYS="$(cfg media_retention_days)"; case "$MEDIA_DAYS" in (''|*[!0-9]*) MEDIA_DAYS=14;; esac
retention_sweep() {
  local stamp="$WORK/.cache/retention-$(date -u +%Y-%m-%d)" n=0 d art
  [ -f "$stamp" ] && return 0
  mkdir -p "$WORK/.cache" && rm -f "$WORK"/.cache/retention-* && : > "$stamp"
  art="$(cfg artifact_reports)"
  while IFS= read -r d; do rm -rf "$d" && n=$((n+1)); done < <(find "$WORK/suite/.e2e/runs" -mindepth 1 -maxdepth 1 -type d -mtime +"$MEDIA_DAYS" 2>/dev/null)
  while IFS= read -r d; do
    local owner; owner="$(dirname "$(dirname "$d")")"
    if [ -f "$owner/artifact.id" ] || [ "$art" = disabled ]; then rm -rf "$d" && n=$((n+1)); fi
  done < <(find "$WORK/issues" "$WORK/scenarios" "$WORK/regression" "$WORK/security" -mindepth 3 -maxdepth 3 -type d -name media -mtime +"$MEDIA_DAYS" 2>/dev/null)
  # The UI sweep's full-page shots (docs/ui-sweep.md): the newest two builds' stay for the next
  # sweep's comparison; the findings keep their crops.
  while IFS= read -r d; do rm -rf "$d" && n=$((n+1)); done < <(ls -1dt "$WORK"/design/*/shots 2>/dev/null | tail -n +3 \
    | while IFS= read -r d; do [ -n "$(find "$d" -maxdepth 0 -mtime +"$MEDIA_DAYS" 2>/dev/null)" ] && printf '%s\n' "$d"; done)
  [ "$n" -gt 0 ] && log "retention: removed $n media directories older than ${MEDIA_DAYS}d"
  return 0
}

# The nested environment serves one run at a time (scripts/env.sh lock, lib/lock.sh). A
# holder whose session runs (or, liveness unknown, younger than the TTL) makes this
# occurrence idle; a dead or stale one is the next run's to take over. ENV_LOCK keeps the
# state for the issue scan: with no live holder, an in_progress row is an orphan.
ENV_LOCK=free
env_busy_out() {
  local held ts sess
  read -r ENV_LOCK held ts sess <<<"$(lock_state "$WORK/env/LOCK" "$LOCK_TTL_MIN")"
  case "$ENV_LOCK" in (live|held) ;; (*) return 0;; esac
  log "nested environment busy (held by $held since $ts$([ "$ENV_LOCK" = live ] && printf ', its session is running')) — next occurrence"
  runlog "$1" "busy holder=$held"
  jq -nc --arg mode "$MODE" --argjson logs "$(logs_json)" '{mode:$mode, nothing_to_do:true, logs:$logs}'
  exit 0
}

# Newest events-log timestamp mentioning `issue=<n>`, as epoch; 0 when none.
last_event_epoch() {
  local f ts
  ts="$(for f in "$WORK"/logs/events-*.jsonl; do [ -f "$f" ] && echo "$f"; done | sort | tail -2 \
        | xargs -r cat 2>/dev/null \
        | jq -r --arg re "issue=$1( |$)" 'select(.msg | test($re)) | .ts' 2>/dev/null | sort | tail -1)"
  [ -n "$ts" ] && iso2epoch "$ts" || echo 0
}

# ============================================================ ISSUES MODE ====
mode_issues() {
  [ -n "$TARGET" ] || fail_out "target_repo is not configured (work/CONFIG.md or QI_TARGET_REPO)"
  retention_sweep
  env_busy_out ISSUES

  local versions candidate baseline
  versions="$(versions_json 2>/tmp/quality-inspector-pf-e2.$$)" \
    || { local e; e="$(tail -3 /tmp/quality-inspector-pf-e2.$$ 2>/dev/null)"; rm -f /tmp/quality-inspector-pf-e2.$$; fail_out "cannot resolve product builds: $e"; }
  rm -f /tmp/quality-inspector-pf-e2.$$
  candidate="$(printf '%s' "$versions" | jq -r .candidate)"
  baseline="$(printf '%s' "$versions" | jq -r '.baseline // empty')"

  local listing
  listing="$(gh api ${GH_HOST_ARGS[@]+"${GH_HOST_ARGS[@]}"} -X GET "repos/$REPO_PATH/issues" \
      -f labels="$QA_LABEL" -f state=all -f per_page=100 2>/dev/null)" \
    || fail_out "issue listing failed for the target repository"
  printf '%s' "$listing" | jq -e 'type == "array"' >/dev/null 2>&1 \
    || fail_out "issue listing returned no array"

  local scan due reports deferred tmp="/tmp/quality-inspector-listing.$$"
  printf '%s' "$listing" > "$tmp"
  scan="$(QI_RETEST_LABEL="$RETEST_LABEL" QI_MAX_ISSUES="$MAX_ISSUES" QI_LOCK_TTL_MIN="$LOCK_TTL_MIN" QI_NOW_EPOCH="$NOW_EPOCH" QI_ENV_LOCK="$ENV_LOCK" \
          node "$SCRIPT_DIR/lib/scan-issues.mjs" "$tmp" "$WORK/QA.md" "$WORK/logs" 2>/dev/null)"
  rm -f "$tmp"
  [ -n "$scan" ] || fail_out "the issue scan failed (node scripts/lib/scan-issues.mjs)"
  due="$(jq -c .due <<<"$scan")"; reports="$(jq -c .reports <<<"$scan")"; deferred="$(jq -r .deferred <<<"$scan")"
  while IFS= read -r l; do log "$l"; done < <(jq -r '.logs[]' <<<"$scan")
  local scen sc; scen="$(scenarios_due)"; [ -n "$scen" ] || scen='[]'; sc="$(printf '%s' "$scen" | jq length)"
  [ "$sc" = 0 ] || log "$sc scenario(s) waiting: $(printf '%s' "$scen" | jq -r 'map(.id + " " + .kind) | join(", ")')"
  [ "$(scenario_runs_today)" -ge "$SCEN_CAP" ] && table_rows "$WORK/SCENARIOS.md" | grep -qE '\| *queued *\|' \
    && log "daily scenario cap reached ($SCEN_CAP) — queued scenarios wait for the next UTC day"
  local count rc; count="$(printf '%s' "$due" | jq length)"; rc="$(printf '%s' "$reports" | jq length)"
  runlog ISSUES "candidate=$candidate baseline=${baseline:-none} due=$count reports=$rc deferred=$deferred scenarios=$sc"
  jq -nc --arg mode issues --arg c "$candidate" --arg b "$baseline" \
    --argjson due "$due" --argjson rep "$reports" --argjson scen "$scen" --argjson logs "$(logs_json)" \
    '{mode:$mode, nothing_to_do:(($due|length)==0 and ($rep|length)==0 and ($scen|length)==0),
      candidate:$c, baseline:(if $b=="" then null else $b end),
      issues_due:$due, reports_due:$rep, scenarios_due:$scen, logs:$logs}'
}

# Scenarios this run takes over (docs/scenarios.md → Waiting scenarios): frozen and
# waiting for the environment, in_progress with no run holding the environment (ENV_LOCK
# free or dead) or past the TTL, or finished with an undelivered report. Oldest first. A
# full daily cap holds back the runs (not the deliveries), so a waiting queue does not wake
# a model every hour for nothing.
SCEN_CAP="$(cfg max_scenarios_per_day)"; case "$SCEN_CAP" in (''|*[!0-9]*) SCEN_CAP=10;; esac
scenarios_due() {
  local row id st upd kind full=0
  [ "$(scenario_runs_today)" -ge "$SCEN_CAP" ] && full=1
  table_rows "$WORK/SCENARIOS.md" | while IFS= read -r row; do
    [ -n "$row" ] || continue
    id="$(cell "$row" 1)"; st="$(cell "$row" 8)"; upd="$(cell "$row" 9)"; kind=""
    case "$st" in
      (queued) [ "$full" = 0 ] && kind=queued ;;
      (report_pending) kind=report ;;
      (in_progress) [ "$full" = 0 ] && { case "$ENV_LOCK" in (free|dead) true;; (*) false;; esac \
          || [ $(( (NOW_EPOCH - $(iso2epoch "$upd")) / 60 )) -ge "$LOCK_TTL_MIN" ]; } && kind=takeover ;;
    esac
    [ -n "$kind" ] && printf '%s\t%s\t%s\n' "$upd" "$id" "$kind"
  done | sort | jq -R 'split("\t") | {id: .[1], kind: .[2]}' | jq -sc .
}

# ======================================================== REGRESSION MODE ====
# The product team's scenarios (docs/regression.md → Profile scenarios): the profile's
# scenarios/<slug>.md against the `source=profile` rows of SCENARIOS.md. adopt[] — a file with
# no row, or whose text changed since its row's spec_hash (a `rejected` row waits for a new
# text, a `retired` one comes back as new; `retry` — the same text whose adoption ended
# failed, blocked or flaky, taken only on a new build); retire[] — a row whose file is gone. At most
# max_scenarios_per_run adoptions a night (authoring costs tokens), new and changed texts
# before retries; the rest wait. Sets PS to
# the worklist's `profile_scenarios` object, or `null` when profile_scenarios is disabled — not
# printed, so its warnings reach LOGS (a command substitution would lose them).
PS=null
profile_scenarios_work() {
  local on files rows adopt retire per n deferred
  on="$(cfg profile_scenarios)"
  case "$on" in (''|enabled) ;; (disabled) PS=null; return;;
    (*) log "WARN: profile_scenarios '$on' is not enabled|disabled — treated as enabled";; esac
  local err l
  mkdir -p "$WORK/.cache" && err="$(mktemp "$WORK/.cache/profile-scenarios.XXXXXX")" || err=/dev/null
  files="$(profile_scenarios 2>"$err" | jq -R 'split("\t") | {slug: .[0], spec_hash: .[1]}' | jq -sc .)"
  while IFS= read -r l; do [ -n "$l" ] && log "WARN: $l"; done < "$err"
  [ "$err" = /dev/null ] || rm -f "$err"
  rows="$(table_rows "$WORK/SCENARIOS.md" | while IFS= read -r r; do
      [ "$(cell "$r" 2)" = profile ] || continue
      printf '%s\t%s\t%s\t%s\n' "$(cell "$r" 1)" "$(cell "$r" 5)" "$(cell "$r" 8)" "$(cell "$r" 7)"
    done | jq -R 'split("\t") | {id: .[0], spec_hash: .[1], status: .[2], verdict: .[3]}' | jq -sc .)"
  per="$(reg max_scenarios_per_run)"; case "$per" in (''|*[!0-9]*) per=3;; esac
  adopt="$(jq -nc --argjson f "$files" --argjson r "$rows" '
    ($r | map({key: .id, value: .}) | from_entries) as $by
    | [$f[] | ("P-" + .slug) as $id | $by[$id] as $row
       | if $row == null or $row.status == "retired" then {id: $id, slug, spec_hash, kind: "new"}
         elif $row.spec_hash != .spec_hash then {id: $id, slug, spec_hash, kind: "changed"}
         elif $row.status == "reported" and ($row.verdict | IN("failed", "blocked", "flaky"))
           then {id: $id, slug, spec_hash, kind: "retry"}
         else empty end] | sort_by(.kind == "retry")')"
  retire="$(jq -nc --argjson f "$files" --argjson r "$rows" '
    ($f | map("P-" + .slug)) as $have | [$r[] | select(.status != "retired" and ((.id | IN($have[])) | not)) | .id]')"
  n="$(jq length <<<"$adopt")"; deferred=0
  if [ "$n" -gt "$per" ]; then
    deferred=$((n - per)); adopt="$(jq -c --argjson p "$per" '.[:$p]' <<<"$adopt")"
    log "$deferred profile scenario(s) wait for a later night (max_scenarios_per_run: $per)"
  fi
  PS="$(jq -nc --argjson a "$adopt" --argjson r "$retire" --argjson d "$deferred" --argjson t "$(jq length <<<"$files")" \
    '{files:$t, adopt:$a, retire:$r, deferred:$d}')"
}

mode_regression() {
  local tests last versions candidate drift confirm bisect ps ps_work=0 replay=true ch
  # Only the `regression` tier replays; exploratory, promotable, retired and quarantined never do.
  tests="$(table_rows "$WORK/SUITE.md" | awk -F'|' '{t=$2; tier=$4; gsub(/[ \t]/,"",t); gsub(/[ \t]/,"",tier)} tier=="regression" {print t}' \
           | jq -R . | jq -sc .)"
  profile_scenarios_work; ps="$PS"
  # Retries alone never make a night due: they ride along with a new build only.
  [ "$ps" != null ] && ps_work="$(jq '(.adopt | map(select(.kind != "retry")) | length) + (.retire | length)' <<<"$ps")"
  if [ "$(printf '%s' "$tests" | jq length)" = 0 ] && { [ "$ps" = null ] || [ "$(jq '(.adopt + .retire) | length' <<<"$ps")" = 0 ]; }; then
    log "no regression-tier tests yet"; runlog REGRESSION "skip=no-tests"
    jq -nc --argjson logs "$(logs_json)" '{mode:"regression", nothing_to_do:true, logs:$logs}'; return
  fi
  env_busy_out REGRESSION
  versions="$(versions_json none 2>/dev/null)" || fail_out "cannot resolve the candidate build"
  candidate="$(printf '%s' "$versions" | jq -r .candidate)"
  last="$(grep -o 'ran candidate=[^ ]*' "$WORK/REGRESSION.log" 2>/dev/null | tail -1 | cut -d= -f2)"
  if [ "$last" = "$candidate" ]; then
    if [ "$ps_work" = 0 ]; then
      log "candidate $candidate already regression-tested"; runlog REGRESSION "skip=same-candidate candidate=$candidate"
      jq -nc --arg c "$candidate" --argjson logs "$(logs_json)" '{mode:"regression", nothing_to_do:true, candidate:$c, logs:$logs}'; return
    fi
    # Same build, new or changed scenario texts: adopt and run those only, replay nothing else.
    replay=false; log "candidate $candidate already regression-tested — $ps_work profile scenario change(s) due"
    ps="$(jq -c '.adopt |= map(select(.kind != "retry"))' <<<"$ps")"
  elif [ "$(printf '%s' "$tests" | jq length)" = 0 ]; then
    # A new build, but no regression-tier test yet: only profile scenarios are due. A replay
    # with no --tag would run every file in tests/.
    replay=false; log "candidate $candidate is new, no regression-tier test yet — profile scenarios only"
  fi
  drift="$(bash "$SCRIPT_DIR/check-asserts.sh" --json 2>/dev/null | jq -c '.drift // []' 2>/dev/null)" || drift='null'
  [ -n "$drift" ] || drift='null'
  [ "$drift" = null ] && log "WARN: assertion drift check could not run"
  # Reverse red-green and bisection (docs/triage.md → Order of work, steps 5–6): off unless set.
  confirm="$(reg confirm_regressions)"; bisect="$(reg bisect_max_steps)"
  case "$confirm" in (enabled) confirm=true;; (''|disabled) confirm=false;;
    (*) log "WARN: confirm_regressions '$confirm' is not enabled|disabled — treated as disabled"; confirm=false;; esac
  case "$bisect" in (''|*[!0-9]*) [ -n "$bisect" ] && log "WARN: bisect_max_steps '$bisect' is not a number — treated as 0"; bisect=0;; esac
  if [ "$bisect" -gt 0 ] && [ "$confirm" = false ]; then
    log "WARN: bisect_max_steps ignored — bisection needs confirm_regressions: enabled"; bisect=0
  fi
  ch="$(cfg regression_channel)"
  [ "$replay" = true ] && log "candidate $candidate is new (last regression: ${last:-never}) — due"
  runlog REGRESSION "due candidate=$candidate tests=$(printf '%s' "$tests" | jq length) replay=$replay profile_scenarios=$ps_work"
  jq -nc --arg c "$candidate" --arg p "$last" --argjson t "$tests" --argjson d "$drift" --argjson logs "$(logs_json)" \
    --argjson cr "$confirm" --argjson bs "$((10#$bisect))" --argjson ps "$ps" --argjson rp "$replay" --arg ch "$ch" \
    '{mode:"regression", nothing_to_do:false, candidate:$c, previous_candidate:(if $p=="" then null else $p end),
      replay:$rp, tests:$t, assert_drift:$d, profile_scenarios:$ps, confirm_regressions:$cr, bisect_max_steps:$bs,
      channel:(if $ch == "" then null else $ch end), logs:$logs}'
}

# ============================================================= AUDIT MODE ====
# grep -c prints 0 AND exits 1 on no match; never let `|| echo 0` double it.
count_lines() { local n; n="$(grep -c -- "$1" "$2" 2>/dev/null)"; echo "${n:-0}"; }
CHECKS='[]'
POLICY_DENIED_WARN=3   # weekly policy_denied events above this are a warn
TOOL_LOOP_WARN=5       # one session's failures of one tool with one error at or above this are a loop
check() { CHECKS="$(printf '%s' "$CHECKS" | jq -c --arg id "$1" --arg s "$2" --arg d "$3" '. + [{id:$id, status:$s, detail:$d}]')"; }

# 0 = the request succeeded (reachable), 1 = refused/failed, 2 = held (timed out).
probe_gh() { timeout 20 gh api ${GH_HOST_ARGS[@]+"${GH_HOST_ARGS[@]}"} "$1" >/dev/null 2>&1; case $? in (0) return 0;; (124) return 2;; (*) return 1;; esac; }

epoch2iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
# "<used %> <free GiB>" of the home volume; nothing when df cannot tell.
disk_home() { df -Pk "$HOME_DIR" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {gsub("%","",$5); print $5, int($4/1048576)}'; }
MIN_FREE_GI="$(cfg min_free_disk_gi)"; case "$MIN_FREE_GI" in (''|*[!0-9]*) MIN_FREE_GI=10;; esac

# The ledger of external writes (docs/logging.md → Ledger of external writes) against
# GitHub: every marker comment the agent's login made this week, on an issue reported this
# week, has its `done` event; every `intent` has its `done`/`failed`. One comments GET per
# issue (the allowed issues endpoint), the newest LEDGER_CAP issues only.
LEDGER_CAP=20
ledger_reconcile() { # <login> <since-iso>
  local login="$1" since="$2" prefix pre ledger start csince issues total n c unrec="" dangling bad=0 seen=0 fresh scope
  if [ -z "$TARGET" ] || [ -z "$login" ]; then check ledger_reconcile warn "not measured — no target or no GitHub identity"; return; fi
  prefix="$(cfg marker_prefix)"; prefix="${prefix:-quality-inspector}"
  pre="$(printf '%s' "$prefix" | sed 's/[][\.*^$+?(){}|/]/\\&/g')"
  ledger="$(cat "$WORK"/logs/events-*.jsonl 2>/dev/null | jq -sc '[.[] | select(.event == "external_write")
    | . + ((.msg // "") | [scan("([a-z_]+)=([^ ]+)")] | map({(.[0]): .[1]}) | add // {})]' 2>/dev/null)"
  [ -n "$ledger" ] || ledger='[]'
  # comments older than the ledger itself (the 2.10.0 upgrade logs `ledger_start`) are not judged
  start="$(cat "$WORK"/logs/events-*.jsonl 2>/dev/null | jq -rs '[.[] | select(.event == "ledger_start") | .ts] | max // empty' 2>/dev/null)"
  csince="$since"; [ -n "$start" ] && [[ "$start" > "$since" ]] && csince="$start"
  issues="$(table_rows "$WORK/QA.md" | awk -F'|' -v since="$since" '{n=$2; s=$7; u=$8; gsub(/[ \t]/,"",n); gsub(/[ \t]/,"",s); gsub(/[ \t]/,"",u)}
            s=="reported" && u>=since {print u, n}' | sort -r | awk '{print $2}')"
  total="$(printf '%s\n' "$issues" | grep -c .)"
  for n in $(printf '%s\n' "$issues" | head -"$LEDGER_CAP"); do
    if ! c="$(gh api ${GH_HOST_ARGS[@]+"${GH_HOST_ARGS[@]}"} "repos/$REPO_PATH/issues/$n/comments?since=$since&per_page=100" 2>/dev/null)" \
       || ! printf '%s' "$c" | jq -e 'type == "array"' >/dev/null 2>&1; then bad=$((bad+1)); continue; fi
    seen=$((seen+1))
    unrec="$unrec$(printf '%s' "$c" | jq -r --arg login "$login" --arg since "$csince" --arg raw "<!-- $prefix" \
        --arg p "$pre" --arg n "$n" --argjson led "$ledger" '
      .[] | select(.user.login == $login and .created_at >= $since and ((.body // "") | contains($raw))) | (.body // "")
      | ((capture("<!-- " + $p + "-spec issue=[0-9]+ ac=(?<a>[^ ]+) -->") | {surface: "spec_comment", key: .a})
         // (capture("<!-- " + $p + " issue=[0-9]+ ac=(?<a>[^ ]+) build=(?<b>[^ ]+) -->") | {surface: "comment", key: "\(.a)@\(.b)"})
         // {surface: "comment", key: "?"})
      | . as $w | select([$led[] | select(.action == "done" and .issue == $n and .surface == $w.surface and .key == $w.key)] | length == 0)
      | " #\($n) \(.surface) \(.key)"' 2>/dev/null | tr '\n' ',')"
  done
  unrec="${unrec%,}"
  fresh="$(epoch2iso $((NOW_EPOCH - 900)))"   # an intent younger than 15 min may still be in flight
  dangling="$(jq -r --arg since "$since" --arg fresh "$fresh" '
    [.[] | select(.action == "done" or .action == "failed")] as $out
    | [.[] | select(.action == "intent" and .ts >= $since and .ts < $fresh) | . as $i
       | select([$out[] | select(.surface == $i.surface and .issue == $i.issue and .key == $i.key and .ts >= $i.ts)] | length == 0)
       | "\(.surface) issue=\(.issue) key=\(.key)"] | unique | join(", ")' <<<"$ledger" 2>/dev/null)"
  scope="$seen of $total reported issue(s) of the week checked (cap $LEDGER_CAP)"
  [ "$bad" = 0 ] || scope="$scope, $bad comment listing(s) failed"
  if [ -n "$unrec" ]; then check ledger_reconcile fail "unrecorded external write:$unrec${dangling:+; unfinished write: $dangling} — $scope"
  elif [ -n "$dangling" ]; then check ledger_reconcile warn "unfinished write: $dangling — $scope"
  elif [ "$bad" != 0 ]; then check ledger_reconcile warn "$scope"
  else check ledger_reconcile ok "every agent comment has its ledger entry — $scope"; fi
}

mode_audit() {
  local login week_ago
  week_ago="$(epoch2iso $((NOW_EPOCH - 7*86400)))"
  # connectivity & identity
  login="$(agent_login ${GH_HOST_ARGS[@]+"${GH_HOST_ARGS[@]}"})"
  if [ -n "$(cfg github_login)" ]; then check github_auth ok "identity from github_login"
  elif [ -n "$login" ]; then check github_auth ok "token resolves an identity"
  else check github_auth fail "gh api user failed — the GitHub connection is not injected (a GitHub App token: set github_login)"; fi
  if [ -n "$TARGET" ]; then
    if probe_gh "repos/$REPO_PATH/issues?per_page=1"; then check issues_read ok "issues endpoint reachable"
    else check issues_read fail "cannot list issues of the target repository"; fi
    # black-box boundary: each of these must be refused (docs/black-box.md)
    local status id detail
    while read -r status id detail; do
      [ "$status" = fail ] && detail="${detail%% — *} — $(boundary_fix "$detail")"
      check "$id" "$status" "$detail"
    done < <(boundary_probe "$TARGET")
  else
    check config_target fail "target_repo not configured"
  fi
  if profile_dir >/dev/null; then check profile ok "$(profile_field '.product') profile at $(profile_dir)"
  else check profile fail "profile '$(cfg profile)' is not installed"; fi
  versions_json >/dev/null 2>&1 && check builds ok "profile lists builds" || check builds fail "the profile cannot list builds"

  # environment
  if [ "$(profile_field '.requires.root')" = true ]; then
    [ "$(id -u)" = 0 ] && check vm_root ok "running as root (vm backend)" || check vm_root fail "not root — the profile needs the vm backend"
  fi
  local c; for c in $(profile_field '.requires.commands[]?'); do
    command -v "$c" >/dev/null 2>&1 && check "command:$c" ok "present" || check "command:$c" fail "$c missing"
  done
  local used free; read -r used free <<<"$(disk_home)"
  if [ -z "$used" ]; then check disk warn "not measured"
  elif [ "$free" -lt "$MIN_FREE_GI" ]; then check disk warn "home volume ${free}Gi free — env.sh up refuses below min_free_disk_gi ($MIN_FREE_GI)"
  elif [ "$used" -ge 85 ]; then check disk warn "home volume ${used}% used, ${free}Gi free"
  else check disk ok "home volume ${used}% used, ${free}Gi free"; fi
  [ -d "$WORK/.git" ] && check work_not_git fail "work/.git exists" || check work_not_git ok "work/ is a plain directory"
  # nested credentials left in raw runs (scripts/suite.sh masks them); paths only, never a value
  local sec; sec="$(node "$SCRIPT_DIR/lib/secrets.mjs" scan "$WORK/env/credentials.env" "$WORK/suite/.e2e/runs" 2>/dev/null)"
  if ! jq -e '.files | type == "array"' >/dev/null 2>&1 <<<"$sec"; then check secrets_in_runs warn "not measured"
  elif [ "$(jq '.files | length' <<<"$sec")" -gt 0 ]; then
    check secrets_in_runs fail "credential values in $(jq -r '(.files | length | tostring) + " file(s): " + (.files[:5] | join(", "))' <<<"$sec")"
  elif [ "$(jq .unmaskable <<<"$sec")" -gt 0 ]; then check secrets_in_runs warn "$(jq .unmaskable <<<"$sec") credential value(s) under 4 characters cannot be masked"
  else check secrets_in_runs ok "no credential value in run artefacts"; fi
  local tmpd; tmpd="$(ls -d /tmp/quality-inspector-* 2>/dev/null | wc -l | tr -d ' ')"
  [ "$tmpd" = 0 ] && check tmp_leftovers ok "none" || check tmp_leftovers warn "$tmpd leftover /tmp/quality-inspector-* entries"

  # state consistency
  local stale=0 r_upd
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    [ "$(cell "$row" 6)" = in_progress ] || continue
    r_upd="$(cell "$row" 7)"
    [ $(( (NOW_EPOCH - $(iso2epoch "$r_upd")) / 60 )) -ge "$LOCK_TTL_MIN" ] && stale=$((stale+1))
  done < <(table_rows "$WORK/QA.md")
  while IFS= read -r row; do
    [ -n "$row" ] && [ "$(cell "$row" 8)" = in_progress ] || continue
    [ $(( (NOW_EPOCH - $(iso2epoch "$(cell "$row" 9)")) / 60 )) -ge "$LOCK_TTL_MIN" ] && stale=$((stale+1))
  done < <(table_rows "$WORK/SCENARIOS.md")
  [ "$stale" = 0 ] && check stale_locks ok "none" || check stale_locks warn "$stale in_progress rows past the TTL"
  ledger_reconcile "$login" "$week_ago"
  local drift; drift="$(bash "$SCRIPT_DIR/check-asserts.sh" --json 2>/dev/null | jq -c '.drift // []' 2>/dev/null)"
  if [ -z "$drift" ]; then check assert_drift warn "not measured"
  elif [ "$drift" = '[]' ]; then check assert_drift ok "regression assertions match their promoted hashes"
  else check assert_drift fail "assertion blocks changed without promotion: $drift"; fi

  # coverage of the newest UI map by regression-tier tests — informational, never a fail
  local map cov=null
  map="$(ls -1t "$WORK"/inventory/*/inventory.json 2>/dev/null | head -1)"
  if [ -n "$map" ]; then
    cov="$(find "$WORK/suite/tests" \( -name 'issue-*.e2e.ts' -o -name 'scenario-*.e2e.ts' -o -name 'profile-*.e2e.ts' \) 2>/dev/null | sort \
           | xargs node "$SCRIPT_DIR/coverage.mjs" "$map" "$WORK/SUITE.md" 2>/dev/null \
           | jq -c '{pages:(.pages|length), covered:([.pages[]|select(.covered)]|length), uncovered:(.uncovered|length), nav_without_golden_path:(.nav_without_golden_path|length)}' 2>/dev/null)"
    [ -n "$cov" ] || cov=null
  fi
  if [ "$cov" = null ]; then
    [ -n "$map" ] && check coverage warn "coverage.mjs failed on $map" || check coverage ok "not measured — no UI map yet"
  else
    local cdet; cdet="$(jq -r '"pages \(.pages) · covered \(.covered) · uncovered \(.uncovered) · nav items without a golden path \(.nav_without_golden_path)"' <<<"$cov")"
    [ "$(jq -r .uncovered <<<"$cov")" = 0 ] && check coverage ok "$cdet" || check coverage warn "$cdet"
  fi

  # cadence: the issues pre-flight logs every call, declined ones included
  local last_iso; last_iso="$(tail -1 "$WORK/ISSUES.log" 2>/dev/null | cut -d' ' -f1)"
  if [ -z "$last_iso" ]; then check issues_cadence warn "ISSUES.log empty"
  elif [ $(( (NOW_EPOCH - $(iso2epoch "$last_iso")) / 3600 )) -ge 3 ]; then check issues_cadence warn "last issues pre-flight $last_iso"
  else check issues_cadence ok "last issues pre-flight $last_iso"; fi

  # definition
  [ -z "$(git -C "$HOME_DIR" status --porcelain 2>/dev/null)" ] && check definition_clean ok "clean" || check definition_clean warn "uncommitted definition changes"
  local v_co v_ad; v_co="$(head -1 "$HOME_DIR/VERSION" 2>/dev/null)"; v_ad="$(head -1 "$WORK/VERSION" 2>/dev/null)"
  [ "$v_co" = "${v_ad:-1.0.0}" ] && check version ok "$v_co adopted" || check version warn "checked out $v_co, adopted ${v_ad:-1.0.0}"

  # error signatures + retention
  local failures
  failures="$(cat "$WORK"/logs/events-*.jsonl 2>/dev/null | jq -sc --arg since "$week_ago" '
    [.[] | select(.level=="error" and .ts >= $since)
         | .sig = (.event + ": " + (.msg | gsub("[0-9]+"; "N") | .[0:120]))]
    | group_by(.sig) | map({signature: .[0].sig, count: length, first: (map(.ts)|min), last: (map(.ts)|max)})' 2>/dev/null)"
  [ -n "$failures" ] || failures='null'

  # harness policy (docs/black-box.md → Enforcement layers): registered, and how often it refused
  local ph denied n
  ph="$(bash "$SCRIPT_DIR/hooks/install.sh" --check 2>&1)" && check policy_hook ok "$ph" \
    || check policy_hook fail "$ph — run scripts/hooks/install.sh (ONBOARDING.md Step 2e)"
  # the work backup (docs/persistence.md → Backup & restore): the destination, and nothing left unpushed
  local wb; wb="$(bash "$SCRIPT_DIR/work-backup.sh" check 2>/dev/null)"
  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$wb"; then check work_backup warn "not measured"
  elif [ "$(jq -r .configured <<<"$wb")" != true ]; then check work_backup ok "local-only (work_repo not set)"
  elif jq -e '.problem' >/dev/null <<<"$wb"; then check work_backup fail "$(jq -r .problem <<<"$wb")"
  elif jq -e '.unbacked > 0 or .last_error' >/dev/null <<<"$wb"; then
    check work_backup warn "$(jq -r '"\(.unbacked) file(s) changed since the last push (\(.last_push_utc // "never"))" + (if .last_error then "; last error: " + .last_error.msg else "" end)' <<<"$wb")"
  else check work_backup ok "$(jq -r '"pushed to \(.repo) at \(.last_push_utc // "?")"' <<<"$wb")"; fi
  denied="$(cat "$WORK"/logs/events-*.jsonl 2>/dev/null | jq -rs --arg since "$week_ago" '
    [.[] | select(.event == "policy_denied" and .ts >= $since) | ((.msg | capture("rule=(?<r>[^ ]+)").r) // "?")]
    | "\(length) \(group_by(.) | map("\(.[0])×\(length)") | join(", "))"' 2>/dev/null)"
  n="${denied%% *}"
  case "$n" in
    (''|*[!0-9]*) check policy_denied warn "not measured";;
    (0) check policy_denied ok "no refusals this week";;
    (*) if [ "$n" -gt "$POLICY_DENIED_WARN" ]; then check policy_denied warn "$n refusals this week (${denied#* }) — injection attempts or a definition bug"
        else check policy_denied ok "$n refusals this week (${denied#* })"; fi;;
  esac

  # harness trace (docs/logging.md → Harness trace): the trace hook registered, turns that never
  # ended, work left mid-pipeline in its session, and failed tool calls by tool and by loop. A
  # turn or an item younger than lock_ttl_min may still run, and this session is running.
  local th trace turns7=null
  th="$(bash "$SCRIPT_DIR/hooks/install.sh" --check-trace 2>&1)" && check trace_hooks ok "$th" || check trace_hooks warn "$th"
  trace="$(cat "$WORK"/logs/events-*.jsonl 2>/dev/null | jq -sc --arg since "$week_ago" \
      --arg open "$(epoch2iso $((NOW_EPOCH - LOCK_TTL_MIN * 60)))" --arg self "${CLAUDE_CODE_SESSION_ID:-}" \
      --argjson loop "$TOOL_LOOP_WARN" '
    def kv($k): (capture("(^| )" + $k + "=(?<v>[^ ]+)") | .v) // null;
    def med: sort | if length == 0 then null else .[(length - 1) / 2 | floor] end;
    [.[] | select((.ts | type) == "string" and .ts >= $since and (.msg | type) == "string")] as $w
    | [$w | group_by(.run)[] | select(.[0].run != $self)
       | (map(select(.level == "error" or .event == "issue_abort" or .event == "scenario_abort")) | length == 0) as $silent
       | . as $r
       | { run: .[0].run, silent: $silent,
           unended: (([.[] | select(.event == "turn_start") | .ts] | max) as $s
                    | ([.[] | select(.event == "turn_end") | .ts] | max) as $e
                    | if $s != null and $s < $open and ($e == null or $e < $s)
                      then {job: ([.[] | select(.event == "turn_start")] | last | .job), ts: $s} else null end),
           open: ([ .[] | select((.event == "issue_start" or .event == "scenario_run") and .ts < $open)
                   | (if .event == "issue_start" then "#" + (.msg | kv("issue") // "?") else (.msg | kv("id") // "S-?") end) as $item
                   | select([$r[] | select(.event == "issue_done" or .event == "issue_abort" or .event == "scenario_done" or .event == "scenario_abort")
                             | if (.event | startswith("issue")) then "#" + (.msg | kv("issue") // "") else (.msg | kv("id") // "") end]
                            | index($item) | not)
                   | $item ] | unique),
           loops: ([ .[] | select(.event == "tool_failed")
                    | {tool: (.msg | kv("tool") // "?"),
                       sig: (.msg | (capture("err=(?<e>.*)$").e // "") | gsub("[0-9]+"; "N") | .[0:80])} ]
                  | group_by([.tool, .sig]) | map(select(length >= $loop) | {tool: .[0].tool, sig: .[0].sig, n: length})) } ] as $runs
    | [$w[] | select(.event == "turn_end")] as $ends
    | [$w[] | select(.event == "tool_failed") | .msg | kv("tool") // "?"] as $tf
    | { unended: [$runs[] | select(.unended) | {run, silent} + .unended],
        open: [$runs[] | select(.open | length > 0) | {run, silent, items: .open}],
        loops: [$runs[] | .run as $id | .loops[] | . + {run: $id}],
        api_errors: [$ends[] | .msg | kv("status") | select(. != null and . != "ok" and . != "interrupted")],
        failed_by_tool: ($tf | group_by(.) | map({key: .[0], value: length}) | from_entries),
        turns_7d: {turns: ([$w[] | select(.event == "turn_start")] | length),
                   by_kind: ([$w[] | select(.event == "turn_start") | .msg | kv("kind") // "?"] | group_by(.) | map({key: .[0], value: length}) | from_entries),
                   secs_p50: ([$ends[] | .msg | kv("secs") | select(. != null and test("^[0-9]+$")) | tonumber] | med),
                   tool_calls: ([$ends[] | .msg | kv("tools") | select(. != null) | tonumber] | add // 0),
                   tool_failures: ($tf | length)} }' 2>/dev/null)"
  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$trace"; then
    check unfinished_runs warn "not measured"; check tool_failures warn "not measured"
  else
    turns7="$(jq -c .turns_7d <<<"$trace")"
    local fin; fin="$(jq -r '
      def who: .run[0:8] + (if .silent then " (silent: no error logged)" else "" end);
      [ (if (.unended | length) > 0 then "\(.unended | length) turn(s) never ended: " + (.unended | map("\(.job) \(who) at \(.ts)") | join(", ")) else empty end),
        (if (.open | length) > 0 then "work left mid-pipeline: " + (.open | map("\(.items | join(",")) in \(who)") | join(", ")) else empty end),
        (if (.api_errors | length) > 0 then "\(.api_errors | length) turn(s) stopped on an API error (" + (.api_errors | group_by(.) | map("\(.[0])×\(length)") | join(", ")) + ")" else empty end)
      ] | join("; ")' <<<"$trace")"
    [ -z "$fin" ] && check unfinished_runs ok "every turn of the week ended, no work left mid-pipeline" || check unfinished_runs warn "$fin"
    local tfd; tfd="$(jq -r '"\(.turns_7d.tool_failures) failed tool calls in \(.turns_7d.turns) turns"
      + (if (.failed_by_tool | length) > 0 then " (" + (.failed_by_tool | to_entries | map("\(.key)×\(.value)") | join(", ")) + ")" else "" end)' <<<"$trace")"
    if jq -e '.loops | length > 0' >/dev/null <<<"$trace"; then
      check tool_failures warn "$tfd — loops: $(jq -r '.loops | map("\(.tool)×\(.n) in \(.run[0:8]): \(.sig)") | join("; ")' <<<"$trace")"
    else check tool_failures ok "$tfd"; fi
  fi
  find "$WORK/env/turns" -type f -mtime +14 -delete 2>/dev/null || true

  # criteria_injection: the week's frozen criteria quoting links, code or hidden comments, and
  # the issues and scenarios the agent logged as injection suspects (docs/acceptance-criteria.md);
  # a scenario's words come from anyone in a bound Slack conversation (docs/scenarios.md).
  local inj_files inj_events inj_scen inj_sev
  quoting() { find "$1" -mindepth 2 -maxdepth 2 -name 'criteria-*.md' -mtime -7 2>/dev/null \
    | while read -r f; do grep -qE 'https?://|www\.|^[[:space:]]*(```|~~~)|<!--' "$f" && basename "$(dirname "$f")"; done; }
  suspects() { cat "$WORK"/logs/events-*.jsonl 2>/dev/null | jq -r --arg since "$week_ago" --arg e "$1" --arg re "$2" \
    'select(.event == $e and .ts >= $since) | .msg | capture($re).n' 2>/dev/null; }
  inj_files="$(quoting "$WORK/issues" | sort -un | paste -sd, -)"
  inj_scen="$(quoting "$WORK/scenarios" | sort -u | paste -sd, -)"
  inj_files="${inj_files}${inj_files:+${inj_scen:+,}}${inj_scen}"
  inj_events="$(suspects issue_injection_suspect 'issue=(?<n>[0-9]+)' | sort -un | paste -sd, -)"
  inj_sev="$(suspects scenario_injection_suspect 'id=(?<n>S-[0-9]+|P-[a-z0-9-]+)' | sort -u | paste -sd, -)"
  if [ -z "$inj_files$inj_events$inj_sev" ]; then check criteria_injection ok "no injection suspects this week"
  else check criteria_injection warn "criteria quoting URLs/code/comments: ${inj_files:-none}; injection_suspect issues: ${inj_events:-none}${inj_sev:+; injection_suspect scenarios: $inj_sev}"; fi
  find "$WORK/logs" -name 'events-*.jsonl' -mtime +14 -delete 2>/dev/null || true
  # UI maps: the newest three builds; the newest is the next diff's starting point.
  ls -1dt "$WORK"/inventory/*/ 2>/dev/null | tail -n +4 | while read -r d; do rm -rf "$d"; done

  # stats
  local stats
  stats="$(table_rows "$WORK/QA.md" | awk -F'|' -v since="$week_ago" '{u=$8; v=$6; gsub(/[ \t]/,"",u); gsub(/[ \t]/,"",v)} u>=since {print v}' \
           | jq -R . | jq -sc 'group_by(.) | map({key:.[0], value:length}) | from_entries')"
  [ -n "$stats" ] || stats='{}'
  # scenarios touched this week, by source/verdict (docs/scenarios.md)
  local sstats
  sstats="$(table_rows "$WORK/SCENARIOS.md" | awk -F'|' -v since="$week_ago" '{u=$10; s=$3; v=$8; gsub(/[ \t]/,"",u); gsub(/[ \t]/,"",s); gsub(/[ \t]/,"",v)} u>=since {print s "/" v}' \
            | jq -R . | jq -sc 'group_by(.) | map({key:.[0], value:length}) | from_entries')"
  [ -n "$sstats" ] || sstats='{}'
  # needs-review signal items (context.signals, docs/triage.md) per week starting Monday
  # UTC, newest eight weeks, from the regression verdicts files; an unreadable file is skipped.
  local f sigweeks
  sigweeks="$(for f in "$WORK"/regression/*/verdicts.json; do [ -f "$f" ] && jq -c '
      select(.mode == "regression" and (.generated_utc | type) == "string")
      | ((.generated_utc | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) / 86400 | floor) as $d
      | {week: (($d - (($d + 3) % 7)) * 86400 | todate | .[0:10]),
         n: ([(.context.signals // {})[]? | arrays | .[] | select((.verdict // "needs-review") == "needs-review")] | length)}' "$f" 2>/dev/null; done \
    | jq -sc 'group_by(.week) | map({key: .[0].week, value: (map(.n) | add)}) | .[-8:] | from_entries' 2>/dev/null)"
  [ -n "$sigweeks" ] || sigweeks='{}'
  # speed and cost of the week: per finished issue its minutes and model steps (issue_done),
  # per install its seconds (env_up) — medians and totals (docs/logging.md).
  local cost
  cost="$(cat "$WORK"/logs/events-*.jsonl 2>/dev/null | jq -sc --arg since "$week_ago" '
      def med: sort | if length == 0 then null else .[(length - 1) / 2 | floor] end;
      def num($k): capture("(^| )" + $k + "=(?<v>[0-9]+)") | .v | tonumber;
      [.[] | select(.ts >= $since)] as $w
      | [$w[] | select(.event == "issue_done") | .msg] as $d
      | [$d[] | num("minutes")] as $m | [$d[] | num("model_steps")] as $k
      | [$w[] | select(.event == "env_up") | .msg | num("took_s")] as $u
      | {issues_done: ($d | length), minutes_p50: ($m | med), minutes_total: ($m | add // 0),
         model_steps_p50: ($k | med), model_steps_total: ($k | add // 0),
         installs: ($u | length), install_s_p50: ($u | med)}' 2>/dev/null)"
  [ -n "$cost" ] || cost=null
  stats="$(jq -nc --argjson v "$stats" --arg runs "$(count_lines '' "$WORK/ISSUES.log")" \
    --arg reg "$(count_lines 'ran candidate=' "$WORK/REGRESSION.log")" \
    --arg heals "$(count_lines '^| 20' "$WORK/HEALS.md")" --argjson sw "$sigweeks" \
    --argjson cov "$cov" --argjson sc "$sstats" --argjson cost "$cost" --argjson turns "${turns7:-null}" \
    '{verdicts_7d:$v, scenarios_7d:$sc, issues_preflights_total:($runs|tonumber), regression_runs_total:($reg|tonumber), heals_total:($heals|tonumber),
      signals_by_week:$sw, coverage:$cov, cost_7d:$cost, turns_7d:$turns}')"

  runlog AUDIT_PREFLIGHT "checks=$(printf '%s' "$CHECKS" | jq length)"
  jq -nc --argjson c "$CHECKS" --argjson f "$failures" --argjson s "$stats" --argjson logs "$(logs_json)" \
    '{mode:"audit", nothing_to_do:false, checks:$c, failures:$f, stats:$s, logs:$logs}'
}

# ========================================================== DISCOVERY MODE ====
# Due when scenario_discovery proposes, the candidate was not explored yet, and (for
# `run`) today's scenario cap leaves room. docs/scenarios.md → Discovery.
mode_discovery() {
  local mode versions candidate baseline last per runs budget
  mode="$(reg scenario_discovery)"
  case "$mode" in
    (propose|run) ;;
    (*) log "scenario discovery is disabled (scenario_discovery: ${mode:-disabled})"; runlog DISCOVERY "skip=disabled"
        jq -nc --argjson logs "$(logs_json)" '{mode:"discovery", nothing_to_do:true, logs:$logs}'; return ;;
  esac
  env_busy_out DISCOVERY
  versions="$(versions_json 2>/dev/null)" || fail_out "cannot resolve product builds"
  candidate="$(printf '%s' "$versions" | jq -r .candidate)"
  baseline="$(printf '%s' "$versions" | jq -r '.baseline // empty')"
  last="$(grep -o 'ran candidate=[^ ]*' "$WORK/DISCOVERY.log" 2>/dev/null | tail -1 | cut -d= -f2)"
  if [ "$last" = "$candidate" ]; then
    log "candidate $candidate already explored"; runlog DISCOVERY "skip=same-candidate candidate=$candidate"
    jq -nc --arg c "$candidate" --argjson logs "$(logs_json)" '{mode:"discovery", nothing_to_do:true, candidate:$c, logs:$logs}'; return
  fi
  per="$(reg max_scenarios_per_run)"; case "$per" in (''|*[!0-9]*) per=3;; esac
  budget="$per"
  if [ "$mode" = run ]; then
    runs="$(scenario_runs_today)"
    [ $((SCEN_CAP - runs)) -lt "$budget" ] && budget=$((SCEN_CAP - runs))
    [ "$budget" -lt 0 ] && budget=0
  fi
  if [ "$budget" = 0 ]; then
    log "no scenario budget left (max_scenarios_per_run / max_scenarios_per_day)"; runlog DISCOVERY "skip=budget candidate=$candidate"
    jq -nc --arg c "$candidate" --argjson logs "$(logs_json)" '{mode:"discovery", nothing_to_do:true, candidate:$c, logs:$logs}'; return
  fi
  log "candidate $candidate not explored yet (last: ${last:-never}) — due, budget $budget"
  runlog DISCOVERY "due candidate=$candidate budget=$budget"
  jq -nc --arg m "$mode" --arg c "$candidate" --arg b "$baseline" --arg p "$last" --argjson n "$budget" --argjson logs "$(logs_json)" \
    '{mode:"discovery", nothing_to_do:false, discovery:$m, candidate:$c, baseline:(if $b=="" then null else $b end),
      previous_candidate:(if $p=="" then null else $p end), budget:$n, logs:$logs}'
}

# ========================================================== BENCHMARK MODE ====
mode_benchmark() {
  local d; d="$(bash "$SCRIPT_DIR/benchmark.sh" due 2>/dev/null)" || fail_out "benchmark due-check failed"
  log "$(jq -r .reason <<<"$d")"
  runlog BENCHMARK "due=$(jq -r .due <<<"$d") cases=$(jq -r .cases <<<"$d")"
  jq -nc --argjson d "$d" --argjson logs "$(logs_json)" '{mode:"benchmark", nothing_to_do:($d.due | not), cases:$d.cases, last_run:$d.last_run, logs:$logs}'
}

# =========================================================== SECURITY MODE ====
# Due once per candidate build (docs/security.md). Keyed on `ran candidate=` in SECURITY.log.
mode_security() {
  if [ "$(reg security_checks)" = disabled ]; then
    log "security checks are disabled (security_checks: disabled)"; runlog SECURITY "skip=disabled"
    jq -nc --argjson logs "$(logs_json)" '{mode:"security", nothing_to_do:true, logs:$logs}'; return
  fi
  env_busy_out SECURITY
  local versions candidate last inv roles dep eng
  versions="$(versions_json none 2>/dev/null)" || fail_out "cannot resolve the candidate build"
  candidate="$(printf '%s' "$versions" | jq -r .candidate)"
  last="$(grep -o 'ran candidate=[^ ]*' "$WORK/SECURITY.log" 2>/dev/null | tail -1 | cut -d= -f2)"
  if [ "$last" = "$candidate" ]; then
    log "candidate $candidate already security-tested"; runlog SECURITY "skip=same-candidate candidate=$candidate"
    jq -nc --arg c "$candidate" --argjson logs "$(logs_json)" '{mode:"security", nothing_to_do:true, candidate:$c, logs:$logs}'; return
  fi
  # A map from before api_requests existed cannot drive the access checks: rebuild it.
  inv="$WORK/inventory/$candidate/inventory.json"; jq -e 'has("api_requests")' "$inv" >/dev/null 2>&1 || inv=""
  # Role names only, never values — the reader suite.sh roles uses (lib/profile.sh).
  roles="$(provided_roles "$WORK/env/credentials.env" 2>/dev/null)"
  eng="$(profile_field '.engine')"
  if [ "$eng" = helm-k3s ] || profile_field '.requires.commands[]?' | grep -qx kubectl; then dep=true; else dep=false; fi
  log "candidate $candidate is new (last security run: ${last:-never}) — due"
  runlog SECURITY "due candidate=$candidate inventory=$([ -n "$inv" ] && echo yes || echo no)"
  jq -nc --arg c "$candidate" --arg p "$last" --arg inv "$inv" --argjson roles "${roles:-[]}" --argjson dep "$dep" --argjson logs "$(logs_json)" \
    '{mode:"security", nothing_to_do:false, candidate:$c, previous_candidate:(if $p=="" then null else $p end),
      inventory:(if $inv=="" then null else $inv end), roles:$roles, deployment_checks:$dep, logs:$logs}'
}

# ============================================================ MODULES MODE ====
# The testing modules of the `modules` run (docs/modules.md): each switched-on module once per
# candidate (`weekly`: at most once in 7 days) keyed on `ran module=<id> candidate=` in
# MODULES.log, plus the queued feature-focus areas. The decision lives in modules.sh due.
mode_modules() {
  local versions candidate baseline d inv budget
  d="$(bash "$SCRIPT_DIR/modules.sh" due 2>/dev/null)" || fail_out "modules.sh due failed"
  if [ "$(jq -r '(.on | length) + (.focus | length)' <<<"$d")" = 0 ]; then
    log "no testing module is switched on and no focus is queued"; runlog MODULES "skip=disabled"
    jq -nc --argjson logs "$(logs_json)" '{mode:"modules", nothing_to_do:true, logs:$logs}'; return
  fi
  env_busy_out MODULES
  versions="$(versions_json 2>/dev/null)" || fail_out "cannot resolve the candidate build"
  candidate="$(printf '%s' "$versions" | jq -r .candidate)"
  baseline="$(printf '%s' "$versions" | jq -r '.baseline // empty')"
  d="$(bash "$SCRIPT_DIR/modules.sh" due "$candidate" 2>/dev/null)" || fail_out "modules.sh due failed"
  if [ "$(jq -r '(.due | length) + (.focus | length)' <<<"$d")" = 0 ]; then
    log "candidate $candidate: every switched-on module already ran on it, no focus queued"; runlog MODULES "skip=same-candidate candidate=$candidate"
    jq -nc --arg c "$candidate" --argjson logs "$(logs_json)" '{mode:"modules", nothing_to_do:true, candidate:$c, logs:$logs}'; return
  fi
  inv="$WORK/inventory/$candidate/inventory.json"; [ -f "$inv" ] || inv=""
  budget="$(reg modules_max_wallclock_min)"; case "$budget" in (''|*[!0-9]*) budget=90;; esac
  log "candidate $candidate: due $(jq -r '.due | join(",")' <<<"$d")$(jq -r 'if (.focus|length) > 0 then " focus " + (.focus | join(",")) else "" end' <<<"$d")"
  runlog MODULES "due candidate=$candidate modules=$(jq -r '.due | join(",")' <<<"$d") focus=$(jq -r '.focus | length' <<<"$d")"
  jq -nc --arg c "$candidate" --arg b "$baseline" --arg inv "$inv" --argjson d "$d" --argjson budget "$budget" --argjson logs "$(logs_json)" \
    '{mode:"modules", nothing_to_do:false, candidate:$c, baseline:(if $b == "" then null else $b end),
      modules_due:$d.due, previous:$d.previous, focus:$d.focus,
      inventory:(if $inv == "" then null else $inv end), max_wallclock_min:$budget, logs:$logs}'
}

# ============================================================= SLACK MODE ====
# What a Slack turn needs before it answers (docs/slack.md): who holds the environment and
# how many Slack tests already started today (UTC) against slack_tests_per_day. Never idle.
mode_slack() {
  local held ts sess today n max ch
  read -r ENV_LOCK held ts sess <<<"$(lock_state "$WORK/env/LOCK" "$LOCK_TTL_MIN")"
  today="$(date -u +%Y-%m-%d)"
  n="$(cat "$WORK/logs/events-$today.jsonl" 2>/dev/null | jq -s '[.[] | select(.event == "slack_test")] | length' 2>/dev/null)"
  max="$(cfg slack_tests_per_day)"; case "$max" in (''|*[!0-9]*) max=3;; esac
  ch="$(cfg slack_channel)"
  [ -n "$ch" ] || log "slack_channel is not set — Slack orders nothing"
  jq -nc --arg ch "$ch" --arg st "$ENV_LOCK" --arg h "$held" --arg s "$ts" --argjson n "${n:-0}" --argjson max "$max" --argjson logs "$(logs_json)" \
    '{mode:"slack", nothing_to_do:false, channel:(if $ch == "" then null else $ch end),
      environment:{state:$st, holder:(if $h == "-" then null else $h end), since:(if $s == "-" then null else $s end),
                   busy:($st == "live" or $st == "held")},
      tests_today:$n, max_tests_per_day:$max, quota_left:([$max - $n, 0] | max), logs:$logs}'
}

# ======================================================== BLACK-BOX GATE ====
# docs/black-box.md → The gate: the boundary probes and the policy hook's registration, once
# a day and after a definition or target change, cached in work/env/boundary.json. A probe
# that reaches a source surface, or a hook that no longer holds, stops every mode but the
# audit — no product is tested while the egress would let the code through or the harness
# would let the agent try. The run that first finds a breach (or a different one) wakes the
# agent to report it (`boundary_breach`, and `channel` for the Slack alert); later ones
# decline until the probes pass, except a Slack turn, where a person waits for the answer.
BOUNDARY_TTL_S=86400
boundary_gate() {
  local f="$WORK/env/boundary.json" v fails prev="" reported=false ph ch key
  [ -n "$TARGET" ] || return 0
  v="$(head -1 "$SCRIPT_DIR/../VERSION" 2>/dev/null)"
  if jq -e --arg v "$v" --arg t "$TARGET" --argjson now "$NOW_EPOCH" --argjson ttl "$BOUNDARY_TTL_S" \
       '.version == $v and .target == $t and ($now - .checked_epoch) < $ttl' "$f" >/dev/null 2>&1; then
    fails="$(jq -c '.fails // []' "$f")"; reported=true
  else
    prev="$(jq -c '.fails // []' "$f" 2>/dev/null)"
    fails="$( { boundary_probe "$TARGET" 2>/dev/null | sed -n 's/^fail //p'
                ph="$(bash "$SCRIPT_DIR/hooks/install.sh" --check 2>&1)" \
                  || printf 'policy_hook %s — bash "$HOME/scripts/hooks/install.sh" (ONBOARDING.md Step 2e), then start a new session\n' "$(printf '%s' "$ph" | head -1)"
              } | jq -R . | jq -sc '[.[] | select(length > 0)]')"
    mkdir -p "$WORK/env" && jq -nc --arg v "$v" --arg t "$TARGET" --arg at "$NOW_ISO" --argjson e "$NOW_EPOCH" --argjson f "$fails" \
      '{version:$v, target:$t, checked_utc:$at, checked_epoch:$e, fails:$f}' > "$f.tmp" && mv "$f.tmp" "$f"
    [ "$prev" = "$fails" ] && reported=true
  fi
  [ "$fails" = '[]' ] && return 0
  [ "$MODE" = slack ] && reported=false
  log "black-box gate: $(jq length <<<"$fails") breach(es) — no product is tested until the probes pass (work/env/boundary.json)"
  # The alert's conversation: the nightly summary's, else the one that orders tests; a Slack
  # turn answers its own thread instead.
  ch="$(cfg regression_channel)"; [ -n "$ch" ] || ch="$(cfg slack_channel)"; [ "$MODE" = slack ] && ch=""
  key="breach@$(printf '%s' "$fails" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-12)"
  jq -nc --arg mode "$MODE" --argjson r "$reported" --argjson f "$fails" --arg ch "$ch" --arg k "$key" --argjson logs "$(logs_json)" \
    '{mode:$mode, nothing_to_do:$r, boundary_breach:$f, channel:(if $ch == "" then null else $ch end), key:$k, logs:$logs}'
  return 1
}

# ========================================================= SESSION TITLE ====
# `title`: the name the run gives its session (docs/logging.md → Session titles), `<Verb>
# <object>` from issue numbers, scenario and module ids, build versions and counts alone —
# never from an issue's or a message's text. A Slack turn names its own (docs/slack.md).
TITLE_JQ='
  def safe: if type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._+-]{0,39}$") then . else null end;
  def on: (.candidate | safe) as $c | if $c then " on " + $c else "" end;
  def count(n; one): (n | tostring) + " " + one + (if n == 1 then "" else "s" end);
  def some(xs): if xs == [] then "" else " (" + (xs | join(", ")) + ")" end;
  def few: if length > 3 then .[:3] + ["+" + ((length - 3) | tostring) + " more"] else . end | join(" · ");
  def runname: {issues: "Issues run", regression: "Regression run", discovery: "Scenario discovery",
              audit: "Weekly audit", benchmark: "Benchmark run", security: "Security run",
              modules: "Modules run"}[.mode] // "Pre-flight";
  def issue: .issue | numbers | "issue #" + tostring;
  . + {title: ((
    if (.boundary_breach // []) != [] then "Report black-box breach"
    elif (.error // "") != "" then runname + ": pre-flight error"
    elif .mode == "slack" then null
    elif .nothing_to_do == true then runname + ": nothing to do"
    elif .mode == "issues" then
      ([(.issues_due // [])[] | issue as $i
         | ({retest: "Retest ", ac_changed: "Retest ", takeover: "Resume "}[.kind] // "Test ") + $i
           + (if .kind == "ac_changed" then " (ACs changed)" else "" end)]
       + [(.reports_due // [])[] | "Deliver report for " + issue]
       + [(.scenarios_due // [])[] | (.id | safe) as $s | select($s)
         | ({takeover: "Resume ", report: "Deliver report for "}[.kind] // "Test ") + "scenario " + $s]) | few
    elif .mode == "regression" then
      "Run regression" + on + some(
        (if .replay then [count(.tests | length; "test")] else [] end)
        + ((.profile_scenarios // {}) | ((.adopt // []) + (.retire // [])) | length
           | if . > 0 then [count(.; "profile scenario")] else [] end))
    elif .mode == "discovery" then "Discover scenarios" + on + (if .discovery == "propose" then " (propose only)" else "" end)
    elif .mode == "security" then "Run security checks" + on
    elif .mode == "modules" then
      "Run modules" + on + some([(.modules_due // [])[] | safe | select(.)]
        + ((.focus // []) | length | if . > 0 then [count(.; "focus area")] else [] end))
    elif .mode == "benchmark" then "Run benchmark" + some([.cases | numbers | count(.; "case")])
    elif .mode == "audit" then "Run weekly audit"
    else runname end) | if type == "string" then .[:200] else . end)}'

main() {
  case "$MODE" in (slack|benchmark|security|issues|regression|discovery|modules) boundary_gate || exit 0;; esac

  case "$MODE" in
    slack)      mode_slack ;;
    benchmark)  mode_benchmark ;;
    security)   mode_security ;;
    modules)    mode_modules ;;
    issues)     mode_issues ;;
    regression) mode_regression ;;
    discovery)  mode_discovery ;;
    audit)      mode_audit ;;
    *)          fail_out "unknown mode: $MODE" ;;
  esac
}

OUT="$(main)"
RC=$?
TITLED="$(jq -c "$TITLE_JQ" <<<"$OUT" 2>/dev/null)" && [ -n "$TITLED" ] && OUT="$TITLED"
printf '%s\n' "$OUT"
exit "$RC"
