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
# Modes: issues (default) | regression | audit | benchmark | security.
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
MAX_ISSUES="$(cfg max_issues_per_run)"; MAX_ISSUES="${MAX_ISSUES:-1}"
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
  done < <(find "$WORK/issues" "$WORK/regression" "$WORK/security" -mindepth 3 -maxdepth 3 -type d -name media -mtime +"$MEDIA_DAYS" 2>/dev/null)
  [ "$n" -gt 0 ] && log "retention: removed $n media directories older than ${MEDIA_DAYS}d"
  return 0
}

# The nested environment serves one run at a time (scripts/env.sh lock). A live
# holder makes this occurrence idle; a lock past the TTL is the holder's to take over.
env_busy_out() {
  local held ts
  [ -f "$WORK/env/LOCK" ] || return 0
  read -r held ts < "$WORK/env/LOCK" 2>/dev/null || return 0
  [ $(( (NOW_EPOCH - $(iso2epoch "$ts")) / 60 )) -ge "$LOCK_TTL_MIN" ] && return 0
  log "nested environment busy (held by $held since $ts) — next occurrence"
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
  scan="$(QI_RETEST_LABEL="$RETEST_LABEL" QI_MAX_ISSUES="$MAX_ISSUES" QI_LOCK_TTL_MIN="$LOCK_TTL_MIN" QI_NOW_EPOCH="$NOW_EPOCH" \
          node "$SCRIPT_DIR/lib/scan-issues.mjs" "$tmp" "$WORK/QA.md" "$WORK/logs" 2>/dev/null)"
  rm -f "$tmp"
  [ -n "$scan" ] || fail_out "the issue scan failed (node scripts/lib/scan-issues.mjs)"
  due="$(jq -c .due <<<"$scan")"; reports="$(jq -c .reports <<<"$scan")"; deferred="$(jq -r .deferred <<<"$scan")"
  while IFS= read -r l; do log "$l"; done < <(jq -r '.logs[]' <<<"$scan")
  local count rc; count="$(printf '%s' "$due" | jq length)"; rc="$(printf '%s' "$reports" | jq length)"
  runlog ISSUES "candidate=$candidate baseline=${baseline:-none} due=$count reports=$rc deferred=$deferred"
  jq -nc --arg mode issues --arg c "$candidate" --arg b "$baseline" \
    --argjson due "$due" --argjson rep "$reports" --argjson logs "$(logs_json)" \
    '{mode:$mode, nothing_to_do:(($due|length)==0 and ($rep|length)==0),
      candidate:$c, baseline:(if $b=="" then null else $b end),
      issues_due:$due, reports_due:$rep, logs:$logs}'
}

# ======================================================== REGRESSION MODE ====
mode_regression() {
  local tests last versions candidate drift
  # Only the `regression` tier replays; exploratory, promotable, retired and quarantined never do.
  tests="$(table_rows "$WORK/SUITE.md" | awk -F'|' '{t=$2; tier=$4; gsub(/[ \t]/,"",t); gsub(/[ \t]/,"",tier)} tier=="regression" {print t}' \
           | jq -R . | jq -sc .)"
  if [ "$(printf '%s' "$tests" | jq length)" = 0 ]; then
    log "no regression-tier tests yet"; runlog REGRESSION "skip=no-tests"
    jq -nc --argjson logs "$(logs_json)" '{mode:"regression", nothing_to_do:true, logs:$logs}'; return
  fi
  env_busy_out REGRESSION
  versions="$(versions_json none 2>/dev/null)" || fail_out "cannot resolve the candidate build"
  candidate="$(printf '%s' "$versions" | jq -r .candidate)"
  last="$(grep -o 'ran candidate=[^ ]*' "$WORK/REGRESSION.log" 2>/dev/null | tail -1 | cut -d= -f2)"
  if [ "$last" = "$candidate" ]; then
    log "candidate $candidate already regression-tested"; runlog REGRESSION "skip=same-candidate candidate=$candidate"
    jq -nc --arg c "$candidate" --argjson logs "$(logs_json)" '{mode:"regression", nothing_to_do:true, candidate:$c, logs:$logs}'; return
  fi
  drift="$(bash "$SCRIPT_DIR/check-asserts.sh" --json 2>/dev/null | jq -c '.drift // []' 2>/dev/null)" || drift='null'
  [ -n "$drift" ] || drift='null'
  [ "$drift" = null ] && log "WARN: assertion drift check could not run"
  log "candidate $candidate is new (last regression: ${last:-never}) — due"
  runlog REGRESSION "due candidate=$candidate tests=$(printf '%s' "$tests" | jq length)"
  jq -nc --arg c "$candidate" --arg p "$last" --argjson t "$tests" --argjson d "$drift" --argjson logs "$(logs_json)" \
    '{mode:"regression", nothing_to_do:false, candidate:$c, previous_candidate:(if $p=="" then null else $p end),
      tests:$t, assert_drift:$d, logs:$logs}'
}

# ============================================================= AUDIT MODE ====
# grep -c prints 0 AND exits 1 on no match; never let `|| echo 0` double it.
count_lines() { local n; n="$(grep -c -- "$1" "$2" 2>/dev/null)"; echo "${n:-0}"; }
CHECKS='[]'
POLICY_DENIED_WARN=3   # weekly policy_denied events above this are a warn
check() { CHECKS="$(printf '%s' "$CHECKS" | jq -c --arg id "$1" --arg s "$2" --arg d "$3" '. + [{id:$id, status:$s, detail:$d}]')"; }

# 0 = the request succeeded (reachable), 1 = refused/failed, 2 = held (timed out).
probe_gh() { timeout 20 gh api ${GH_HOST_ARGS[@]+"${GH_HOST_ARGS[@]}"} "$1" >/dev/null 2>&1; case $? in (0) return 0;; (124) return 2;; (*) return 1;; esac; }
probe_url() { local c; c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$1" 2>/dev/null)"
  case "$c" in (2??) return 0;; (000) return 2;; (*) return 1;; esac; }

mode_audit() {
  # connectivity & identity
  if gh api ${GH_HOST_ARGS[@]+"${GH_HOST_ARGS[@]}"} user --jq .login >/dev/null 2>&1; then check github_auth ok "token resolves an identity"
  else check github_auth fail "gh api user failed — the GitHub connection is not injected"; fi
  if [ -n "$TARGET" ]; then
    if probe_gh "repos/$REPO_PATH/issues?per_page=1"; then check issues_read ok "issues endpoint reachable"
    else check issues_read fail "cannot list issues of the target repository"; fi
    # black-box boundary: each of these must be refused (docs/black-box.md)
    local kind target r
    while read -r kind target; do
      if [ "$kind" = gh ]; then probe_gh "$target"; else probe_url "$target"; fi; r=$?
      case $r in
        (0) check "boundary:${target%%\?*}" fail "source surface is reachable — add the deny rule (README → Black-box boundary)";;
        (2) check "boundary:${target%%\?*}" warn "request was held, not denied — make the rule an explicit deny";;
        (*) check "boundary:${target%%\?*}" ok "refused";;
      esac
    done < <(boundary_targets "$REPO_PATH")
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
  local used; used="$(df -P "$HOME_DIR" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')"
  if [ -z "$used" ]; then check disk warn "not measured"
  elif [ "$used" -ge 85 ]; then check disk warn "home volume ${used}% used"
  else check disk ok "home volume ${used}% used"; fi
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
  [ "$stale" = 0 ] && check stale_locks ok "none" || check stale_locks warn "$stale in_progress rows past the TTL"
  local drift; drift="$(bash "$SCRIPT_DIR/check-asserts.sh" --json 2>/dev/null | jq -c '.drift // []' 2>/dev/null)"
  if [ -z "$drift" ]; then check assert_drift warn "not measured"
  elif [ "$drift" = '[]' ]; then check assert_drift ok "regression assertions match their promoted hashes"
  else check assert_drift fail "assertion blocks changed without promotion: $drift"; fi

  # coverage of the newest UI map by regression-tier tests — informational, never a fail
  local map cov=null
  map="$(ls -1t "$WORK"/inventory/*/inventory.json 2>/dev/null | head -1)"
  if [ -n "$map" ]; then
    cov="$(find "$WORK/suite/tests" -name 'issue-*.e2e.ts' 2>/dev/null | sort \
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
  local week_ago failures
  week_ago="$(date -u -d "@$((NOW_EPOCH - 7*86400))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r $((NOW_EPOCH - 7*86400)) +%Y-%m-%dT%H:%M:%SZ)"
  failures="$(cat "$WORK"/logs/events-*.jsonl 2>/dev/null | jq -sc --arg since "$week_ago" '
    [.[] | select(.level=="error" and .ts >= $since)
         | .sig = (.event + ": " + (.msg | gsub("[0-9]+"; "N") | .[0:120]))]
    | group_by(.sig) | map({signature: .[0].sig, count: length, first: (map(.ts)|min), last: (map(.ts)|max)})' 2>/dev/null)"
  [ -n "$failures" ] || failures='null'

  # harness policy (docs/black-box.md → Enforcement layers): registered, and how often it refused
  local ph denied n
  ph="$(bash "$SCRIPT_DIR/hooks/install.sh" --check 2>&1)" && check policy_hook ok "$ph" \
    || check policy_hook fail "$ph — run scripts/hooks/install.sh (ONBOARDING.md Step 2e)"
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

  # criteria_injection: the week's frozen criteria quoting links, code or hidden comments, and
  # the issues the agent logged as injection suspects (docs/acceptance-criteria.md).
  local inj_files inj_events
  inj_files="$(find "$WORK/issues" -mindepth 2 -maxdepth 2 -name 'criteria-*.md' -mtime -7 2>/dev/null \
    | while read -r f; do grep -qE 'https?://|www\.|^[[:space:]]*(```|~~~)|<!--' "$f" && basename "$(dirname "$f")"; done | sort -un | paste -sd, -)"
  inj_events="$(cat "$WORK"/logs/events-*.jsonl 2>/dev/null | jq -r --arg since "$week_ago" \
    'select(.event == "issue_injection_suspect" and .ts >= $since) | .msg | capture("issue=(?<n>[0-9]+)").n' 2>/dev/null \
    | sort -un | paste -sd, -)"
  if [ -z "$inj_files$inj_events" ]; then check criteria_injection ok "no injection suspects this week"
  else check criteria_injection warn "criteria quoting URLs/code/comments: ${inj_files:-none}; injection_suspect issues: ${inj_events:-none}"; fi
  find "$WORK/logs" -name 'events-*.jsonl' -mtime +14 -delete 2>/dev/null || true
  # UI maps: the newest three builds; the newest is the next diff's starting point.
  ls -1dt "$WORK"/inventory/*/ 2>/dev/null | tail -n +4 | while read -r d; do rm -rf "$d"; done

  # stats
  local stats
  stats="$(table_rows "$WORK/QA.md" | awk -F'|' -v since="$week_ago" '{u=$8; v=$6; gsub(/[ \t]/,"",u); gsub(/[ \t]/,"",v)} u>=since {print v}' \
           | jq -R . | jq -sc 'group_by(.) | map({key:.[0], value:length}) | from_entries')"
  [ -n "$stats" ] || stats='{}'
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
  stats="$(jq -nc --argjson v "$stats" --arg runs "$(count_lines '' "$WORK/ISSUES.log")" \
    --arg reg "$(count_lines 'ran candidate=' "$WORK/REGRESSION.log")" \
    --arg heals "$(count_lines '^| 20' "$WORK/HEALS.md")" --argjson sw "$sigweeks" \
    --argjson cov "$cov" \
    '{verdicts_7d:$v, issues_preflights_total:($runs|tonumber), regression_runs_total:($reg|tonumber), heals_total:($heals|tonumber),
      signals_by_week:$sw, coverage:$cov}')"

  runlog AUDIT_PREFLIGHT "checks=$(printf '%s' "$CHECKS" | jq length)"
  jq -nc --argjson c "$CHECKS" --argjson f "$failures" --argjson s "$stats" --argjson logs "$(logs_json)" \
    '{mode:"audit", nothing_to_do:false, checks:$c, failures:$f, stats:$s, logs:$logs}'
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
  if [ "$(cfg security_checks)" = disabled ]; then
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
  # Role names only, never values (docs/profile-contract.md → The bin/ contract).
  roles="$(sed -n 's/^E2E_USER_\([A-Z0-9]*\)_USERNAME=..*/\1/p' "$WORK/env/credentials.env" 2>/dev/null | tr '[:upper:]' '[:lower:]' | jq -R . | jq -sc .)"
  eng="$(profile_field '.engine')"
  if [ "$eng" = helm-k3s ] || profile_field '.requires.commands[]?' | grep -qx kubectl; then dep=true; else dep=false; fi
  log "candidate $candidate is new (last security run: ${last:-never}) — due"
  runlog SECURITY "due candidate=$candidate inventory=$([ -n "$inv" ] && echo yes || echo no)"
  jq -nc --arg c "$candidate" --arg p "$last" --arg inv "$inv" --argjson roles "${roles:-[]}" --argjson dep "$dep" --argjson logs "$(logs_json)" \
    '{mode:"security", nothing_to_do:false, candidate:$c, previous_candidate:(if $p=="" then null else $p end),
      inventory:(if $inv=="" then null else $inv end), roles:$roles, deployment_checks:$dep, logs:$logs}'
}

case "$MODE" in
  benchmark)  mode_benchmark ;;
  security)   mode_security ;;
  issues)     mode_issues ;;
  regression) mode_regression ;;
  audit)      mode_audit ;;
  *)          fail_out "unknown mode: $MODE" ;;
esac
